import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flame/src/particles/particle_buffer.dart';
import 'package:meta/meta.dart';

/// Draws the live particles of an emitter component.
///
/// Extend [TextureParticleRenderer] for batched texture rendering, or extend
/// this class (or use [CallbackParticleRenderer]) for full canvas access.
abstract class ParticleRenderer() {
  /// Called once when the owning component loads. Override to prepare
  /// textures or other resources.
  FutureOr<void> onLoad() {}

  /// Releases any private native resources owned exclusively by this renderer.
  void dispose() {}

  /// Renders all live particles in [particles]. The canvas is already
  /// transformed to the emitter component's local coordinate system.
  void render(Canvas canvas, ParticleBuffer particles);
}

/// A renderer that delegates to a callback, for effects that need direct
/// canvas access.
///
/// Nothing is batched, so this is slower than the texture renderers; prefer
/// those for large particle counts.
class CallbackParticleRenderer(
  /// Called every frame with the canvas, already transformed to the emitter
  /// component's local coordinate system, and the live particles.
  final void Function(Canvas canvas, ParticleBuffer particles) renderCallback,
) extends ParticleRenderer {
  @override
  void render(Canvas canvas, ParticleBuffer particles) {
    renderCallback(canvas, particles);
  }
}

/// Base class for renderers that draw every particle as a transformed,
/// tinted copy of a texture region, batched into one [Canvas.drawRawAtlas]
/// call (or [Canvas.drawVertices] calls of up to 16383 quads when anisotropic
/// velocity stretch is active).
///
/// Each particle is drawn centered on its position, rotated by its rotation,
/// and scaled so that the texture region's width matches the particle's
/// current size; the height follows the region's aspect ratio. Velocity
/// stretch lengthens the particle along its width. This holds for every draw
/// path, so a particle keeps its size when it starts or stops being
/// stretched or is merged into a `ParticleBatchGroup`.
abstract class TextureParticleRenderer({BlendMode? blendMode, Paint? paint})
    extends ParticleRenderer {
  /// Creates a texture renderer.
  ///
  /// [blendMode] controls how particles composite onto the canvas; use
  /// [BlendMode.plus] for additive glow effects. [paint] can be provided to
  /// customize other paint properties.
  this {
    if (blendMode != null) {
      this.paint.blendMode = blendMode;
    }
  }

  /// The paint used for the batched draw call.
  final Paint paint = paint ?? Paint();

  /// The texture to draw, or null while the renderer has not loaded yet.
  Image? get texture;

  /// Default region of [texture] to draw, in texture pixels.
  Rect get srcRect;

  /// Whether subclasses select a distinct source rectangle per particle via
  /// [frameRectForParticle] (e.g. flipbooks or random sprite variants).
  bool get hasPerParticleRects => false;

  /// Returns the texture region for particle [index] when
  /// [hasPerParticleRects] is `true`.
  Rect frameRectForParticle(ParticleBuffer particles, int index) => srcRect;

  Float32List _transforms = Float32List(0);
  Float32List _rects = Float32List(0);

  Float32List _quadPositions = Float32List(0);
  Float32List _quadUvs = Float32List(0);
  Int32List _quadColors = Int32List(0);
  Uint16List _quadIndices = Uint16List(0);
  Image? _cachedShaderTexture;
  ImageShader? _cachedImageShader;

  @override
  void dispose() {
    _cachedImageShader?.dispose();
    _cachedImageShader = null;
    _cachedShaderTexture = null;
    super.dispose();
  }

  /// Whether this renderer can merge its particles into a shared
  /// `ParticleBatchGroup` `drawRawAtlas` call.
  @internal
  bool canBatchInAtlas(ParticleBuffer particles) =>
      !particles.hasStretch && canBatchAsQuads(particles);

  /// Whether this renderer can merge its particles (including stretched or
  /// non-uniformly scaled/flipped particles) into a shared
  /// `ParticleBatchGroup` `Canvas.drawVertices` quad call.
  ///
  /// A shared batch reproduces the [paint]'s blend mode, filter quality and
  /// opacity; a paint that carries anything else that changes the result (a
  /// filter, a shader, inverted colors) keeps its emitter out of the batch.
  @internal
  bool canBatchAsQuads(ParticleBuffer particles) =>
      texture != null &&
      paint.colorFilter == null &&
      paint.imageFilter == null &&
      paint.maskFilter == null &&
      paint.shader == null &&
      !paint.invertColors;

  /// Returns a cached [ImageShader] bound to the current [texture] with zero
  /// per-frame allocations.
  @internal
  ImageShader ensureCachedImageShader(Image tex) {
    if (!identical(_cachedShaderTexture, tex) || _cachedImageShader == null) {
      _cachedImageShader?.dispose();
      _cachedShaderTexture = tex;
      _cachedImageShader = ImageShader(
        tex,
        TileMode.clamp,
        TileMode.clamp,
        Float64List.fromList(const <double>[
          1, 0, 0, 0, //
          0, 1, 0, 0, //
          0, 0, 1, 0, //
          0, 0, 0, 1, //
        ]),
      );
    }
    return _cachedImageShader!;
  }

  /// Appends [particles] transformed by similarity matrix
  /// `(m00 = s*cosA, m01 = s*sinA, tx = offsetX, ty = offsetY)` into the
  /// caller's shared `drawRawAtlas` buffers starting at particle slot
  /// [startSlot], returning the updated slot count.
  @internal
  int appendToSharedAtlas({
    required ParticleBuffer particles,
    required Float32List outTransforms,
    required Float32List outRects,
    required Int32List outColors,
    required int startSlot,
    required double offsetX,
    required double offsetY,
    required double cosA,
    required double sinA,
    required double uniformScale,
  }) {
    final count = particles.length;
    if (count == 0) {
      return startSlot;
    }
    final m00 = cosA * uniformScale;
    final m01 = sinA * uniformScale;
    final perParticle = hasPerParticleRects;
    final defaultSrc = srcRect;
    final defaultAnchorX = defaultSrc.width * 0.5;
    final defaultAnchorY = defaultSrc.height * 0.5;
    final defaultInvW = defaultSrc.width > 0 ? 1.0 / defaultSrc.width : 1.0;

    for (var i = 0; i < count; i++) {
      final slot = startSlot + i;
      final j = slot * 4;
      final Rect src;
      final double anchorX;
      final double anchorY;
      final double invW;
      if (perParticle) {
        src = frameRectForParticle(particles, i);
        anchorX = src.width * 0.5;
        anchorY = src.height * 0.5;
        invW = src.width > 0 ? 1.0 / src.width : 1.0;
      } else {
        src = defaultSrc;
        anchorX = defaultAnchorX;
        anchorY = defaultAnchorY;
        invW = defaultInvW;
      }

      final lx = particles.posX[i];
      final ly = particles.posY[i];
      final wx = offsetX + lx * m00 - ly * m01;
      final wy = offsetY + lx * m01 + ly * m00;

      final localScale = particles.size[i] * invW;
      final rot = particles.rotation[i];
      final cR = cos(rot);
      final sR = sin(rot);
      final scos = (cR * m00 - sR * m01) * localScale;
      final ssin = (sR * m00 + cR * m01) * localScale;

      outTransforms[j] = scos;
      outTransforms[j + 1] = ssin;
      outTransforms[j + 2] = wx - scos * anchorX + ssin * anchorY;
      outTransforms[j + 3] = wy - ssin * anchorX - scos * anchorY;

      outRects[j] = src.left;
      outRects[j + 1] = src.top;
      outRects[j + 2] = src.right;
      outRects[j + 3] = src.bottom;
      outColors[slot] = particles.color[i];
    }
    return startSlot + count;
  }

  /// Appends `[startParticle .. startParticle + particleCount)` as 2D textured
  /// quads transformed by the general `2x3` affine matrix
  /// `(m00, m01, m10, m11, tx, ty)` into shared `Vertices.raw` buffers starting
  /// at quad slot [startQuadSlot], returning the updated quad slot count.
  @internal
  int appendToSharedQuads({
    required ParticleBuffer particles,
    required int startParticle,
    required int particleCount,
    required Float32List outPositions,
    required Float32List outUvs,
    required Int32List outColors,
    required int startQuadSlot,
    required double m00,
    required double m01,
    required double m10,
    required double m11,
    required double tx,
    required double ty,
  }) {
    if (particleCount <= 0) {
      return startQuadSlot;
    }
    final perParticle = hasPerParticleRects;
    final defaultSrc = srcRect;

    for (var k = 0; k < particleCount; k++) {
      final i = startParticle + k;
      final qSlot = startQuadSlot + k;
      final src = perParticle ? frameRectForParticle(particles, i) : defaultSrc;
      // Same convention as the atlas path: the region's width equals the
      // particle size, and stretch lengthens it along the width.
      final halfSize = particles.size[i] * 0.5;
      final halfW = halfSize * max(1.0, particles.stretch[i]);
      final halfH = halfSize * (src.width > 0 ? src.height / src.width : 1.0);
      final rot = particles.rotation[i];
      final c = cos(rot);
      final s = sin(rot);
      final px = particles.posX[i];
      final py = particles.posY[i];

      final ux = c * halfW;
      final uy = s * halfW;
      final vx = -s * halfH;
      final vy = c * halfH;

      final lx0 = px - ux - vx;
      final ly0 = py - uy - vy;
      final lx1 = px + ux - vx;
      final ly1 = py + uy - vy;
      final lx2 = px + ux + vx;
      final ly2 = py + uy + vy;
      final lx3 = px - ux + vx;
      final ly3 = py - uy + vy;

      final pBase = qSlot * 8;
      outPositions[pBase] = tx + m00 * lx0 + m10 * ly0;
      outPositions[pBase + 1] = ty + m01 * lx0 + m11 * ly0;
      outPositions[pBase + 2] = tx + m00 * lx1 + m10 * ly1;
      outPositions[pBase + 3] = ty + m01 * lx1 + m11 * ly1;
      outPositions[pBase + 4] = tx + m00 * lx2 + m10 * ly2;
      outPositions[pBase + 5] = ty + m01 * lx2 + m11 * ly2;
      outPositions[pBase + 6] = tx + m00 * lx3 + m10 * ly3;
      outPositions[pBase + 7] = ty + m01 * lx3 + m11 * ly3;

      outUvs[pBase] = src.left;
      outUvs[pBase + 1] = src.top;
      outUvs[pBase + 2] = src.right;
      outUvs[pBase + 3] = src.top;
      outUvs[pBase + 4] = src.right;
      outUvs[pBase + 5] = src.bottom;
      outUvs[pBase + 6] = src.left;
      outUvs[pBase + 7] = src.bottom;

      final col = particles.color[i];
      final cBase = qSlot * 4;
      outColors[cBase] = col;
      outColors[cBase + 1] = col;
      outColors[cBase + 2] = col;
      outColors[cBase + 3] = col;
    }
    return startQuadSlot + particleCount;
  }

  @override
  void render(Canvas canvas, ParticleBuffer particles) {
    final texture = this.texture;
    final count = particles.length;
    if (texture == null || count == 0) {
      return;
    }
    if (particles.hasStretch) {
      _renderStretchedVertices(canvas, texture, particles, count);
      return;
    }
    if (_transforms.length < count * 4) {
      _transforms = Float32List(particles.capacity * 4);
      _rects = Float32List(particles.capacity * 4);
    }
    final perParticle = hasPerParticleRects;
    final defaultSrc = srcRect;
    final defaultAnchorX = defaultSrc.width / 2;
    final defaultAnchorY = defaultSrc.height / 2;
    final defaultInvWidth = defaultSrc.width > 0 ? 1 / defaultSrc.width : 1.0;

    for (var i = 0; i < count; i++) {
      final Rect src;
      final double anchorX;
      final double anchorY;
      final double invWidth;
      if (perParticle) {
        src = frameRectForParticle(particles, i);
        anchorX = src.width / 2;
        anchorY = src.height / 2;
        invWidth = src.width > 0 ? 1 / src.width : 1.0;
      } else {
        src = defaultSrc;
        anchorX = defaultAnchorX;
        anchorY = defaultAnchorY;
        invWidth = defaultInvWidth;
      }
      final scale = particles.size[i] * invWidth;
      final rotation = particles.rotation[i];
      final scos = cos(rotation) * scale;
      final ssin = sin(rotation) * scale;
      final j = i * 4;
      _transforms[j] = scos;
      _transforms[j + 1] = ssin;
      _transforms[j + 2] = particles.posX[i] - scos * anchorX + ssin * anchorY;
      _transforms[j + 3] = particles.posY[i] - ssin * anchorX - scos * anchorY;
      _rects[j] = src.left;
      _rects[j + 1] = src.top;
      _rects[j + 2] = src.right;
      _rects[j + 3] = src.bottom;
    }
    canvas.drawRawAtlas(
      texture,
      Float32List.sublistView(_transforms, 0, count * 4),
      Float32List.sublistView(_rects, 0, count * 4),
      Int32List.sublistView(particles.color, 0, count),
      BlendMode.modulate,
      null,
      paint,
    );
  }

  static const int _maxQuadsPerDraw = 16383;

  void _renderStretchedVertices(
    Canvas canvas,
    Image texture,
    ParticleBuffer particles,
    int count,
  ) {
    // 16-bit indices address at most 16383 quads, so larger particle counts
    // are drawn in several calls.
    final quadCap = min(max(particles.capacity, count), _maxQuadsPerDraw);
    if (_quadColors.length < quadCap * 4) {
      _quadPositions = Float32List(quadCap * 8);
      _quadUvs = Float32List(quadCap * 8);
      _quadColors = Int32List(quadCap * 4);
      _quadIndices = Uint16List(quadCap * 6);
      for (var q = 0; q < quadCap; q++) {
        final b = q * 4;
        final k = q * 6;
        _quadIndices[k] = b;
        _quadIndices[k + 1] = b + 1;
        _quadIndices[k + 2] = b + 2;
        _quadIndices[k + 3] = b;
        _quadIndices[k + 4] = b + 2;
        _quadIndices[k + 5] = b + 3;
      }
    }

    final savedShader = paint.shader;
    paint.shader = ensureCachedImageShader(texture);
    try {
      for (var start = 0; start < count; start += quadCap) {
        final chunk = min(quadCap, count - start);
        appendToSharedQuads(
          particles: particles,
          startParticle: start,
          particleCount: chunk,
          outPositions: _quadPositions,
          outUvs: _quadUvs,
          outColors: _quadColors,
          startQuadSlot: 0,
          m00: 1,
          m01: 0,
          m10: 0,
          m11: 1,
          tx: 0,
          ty: 0,
        );
        final vertices = Vertices.raw(
          VertexMode.triangles,
          Float32List.sublistView(_quadPositions, 0, chunk * 8),
          textureCoordinates: Float32List.sublistView(_quadUvs, 0, chunk * 8),
          colors: Int32List.sublistView(_quadColors, 0, chunk * 4),
          indices: Uint16List.sublistView(_quadIndices, 0, chunk * 6),
        );
        try {
          canvas.drawVertices(vertices, BlendMode.modulate, paint);
        } finally {
          vertices.dispose();
        }
      }
    } finally {
      paint.shader = savedShader;
    }
  }
}
