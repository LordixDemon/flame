import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/src/rendering/light_2d_layer.dart';

/// Sampled or procedural 3D surface normal `(nx, ny, nz)` (`+X` right, `+Y`
/// down in 2D canvas space, `+Z` out of the screen toward the viewer).
class const SurfaceNormal2D(this.nx, this.ny, this.nz) {
  static const SurfaceNormal2D flat = SurfaceNormal2D(0.0, 0.0, 1.0);

  final double nx;
  final double ny;
  final double nz;

  /// Decodes a tangent-space RGBA normal map pixel (`R -> X`, `G -> Y`,
  /// `B -> Z`, where `128, 128, 255` is flat `(0, 0, 1)`).
  factory SurfaceNormal2D.fromRgbBytes(
    int r,
    int g,
    int b, {
    bool flipGreenY = false,
  }) {
    var x = (r / 255.0) * 2.0 - 1.0;
    var y = (g / 255.0) * 2.0 - 1.0;
    if (flipGreenY) {
      y = -y;
    }
    var z = (b / 255.0) * 2.0 - 1.0;
    final len = math.sqrt(x * x + y * y + z * z);
    if (len > 1e-6) {
      x /= len;
      y /= len;
      z /= len;
    } else {
      x = 0.0;
      y = 0.0;
      z = 1.0;
    }
    return SurfaceNormal2D(x, y, z);
  }
}

/// 2D normal-lit sprite batcher computing directional / point `dot(N, L)`
/// bevel & surface relief lighting across `PointLight2D` sources and
/// flushing into `1` `Canvas.drawVertices` GPU call.
///
/// Queuing sprites writes into pre-allocated typed buffers (they grow by
/// doubling up to [maxSprites]) and allocates nothing per sprite.
class NormalMappedSpriteBatch({
  required this.diffuseAtlas,
  this.ambientColor = const ui.Color(0xFF404860),
  this.defaultLightHeightZ = 48.0,
  int initialSpriteCapacity = 64,
}) {
  final ui.Image diffuseAtlas;
  ui.Color ambientColor;
  double defaultLightHeightZ;

  late final ui.ImageShader _shader = ui.ImageShader(
    diffuseAtlas,
    ui.TileMode.clamp,
    ui.TileMode.clamp,
    Float64List.fromList(const <double>[
      1,
      0,
      0,
      0,
      0,
      1,
      0,
      0,
      0,
      0,
      1,
      0,
      0,
      0,
      0,
      1,
    ]),
  );

  final ui.Paint _paint = ui.Paint()..filterQuality = ui.FilterQuality.low;

  Float32List _positions = Float32List(initialSpriteCapacity * 8);
  Float32List _uvs = Float32List(initialSpriteCapacity * 8);
  Int32List _colors = Int32List(initialSpriteCapacity * 4);
  Uint16List _indices = _buildQuadIndices(initialSpriteCapacity);

  int _spriteCount = 0;
  int _lastDrawCalls = 0;

  int get spriteCount => _spriteCount;
  int get lastDrawCalls => _lastDrawCalls;

  /// Most quads one batch can hold: 4 vertices each under 16-bit indices.
  static const int maxSprites = 16383;

  static Uint16List _buildQuadIndices(int quadCap) {
    final safeCap = math.min(quadCap, maxSprites);
    final idx = Uint16List(safeCap * 6);
    for (var i = 0; i < safeCap; i++) {
      final v = i * 4;
      final o = i * 6;
      idx[o] = v;
      idx[o + 1] = v + 1;
      idx[o + 2] = v + 2;
      idx[o + 3] = v;
      idx[o + 4] = v + 2;
      idx[o + 5] = v + 3;
    }
    return idx;
  }

  void _ensureCapacity(int neededSprites) {
    final curCap = _colors.length ~/ 4;
    if (neededSprites <= curCap) {
      return;
    }
    var nextCap = math.max(16, curCap * 2);
    while (nextCap < neededSprites) {
      nextCap *= 2;
    }
    nextCap = math.min(nextCap, maxSprites);
    _positions = Float32List(nextCap * 8)
      ..setRange(0, _spriteCount * 8, _positions);
    _uvs = Float32List(nextCap * 8)..setRange(0, _spriteCount * 8, _uvs);
    _colors = Int32List(nextCap * 4)..setRange(0, _spriteCount * 4, _colors);
    _indices = _buildQuadIndices(nextCap);
  }

  /// Clears queued quads for a new frame.
  void clear() {
    _spriteCount = 0;
  }

  /// Evaluates exact `dot(N, L)` lighting color at 2D world point `(wx, wy)`
  /// with surface normal [normal] against [ambientColor] and [lights].
  ui.Color evaluateLitColor({
    required double wx,
    required double wy,
    required SurfaceNormal2D normal,
    required List<PointLight2D> lights,
    ui.Color baseTint = const ui.Color(0xFFFFFFFF),
    double opacity = 1.0,
  }) {
    return ui.Color(
      _litArgb(
        wx,
        wy,
        normal.nx,
        normal.ny,
        normal.nz,
        lights,
        baseTint,
        opacity,
      ),
    );
  }

  /// Allocation-free core of [evaluateLitColor] returning packed ARGB.
  int _litArgb(
    double wx,
    double wy,
    double nx,
    double ny,
    double nz,
    List<PointLight2D> lights,
    ui.Color baseTint,
    double opacity,
  ) {
    var accR = ambientColor.r;
    var accG = ambientColor.g;
    var accB = ambientColor.b;

    for (var i = 0; i < lights.length; i++) {
      final l = lights[i];
      if (!l.enabled || l.intensity <= 0.0 || l.radius <= 0.0) {
        continue;
      }
      final dx = l.position.x - wx;
      final dy = l.position.y - wy;
      final dist2D = math.sqrt(dx * dx + dy * dy);
      if (dist2D >= l.radius) {
        continue;
      }
      final dz = defaultLightHeightZ;
      final len3 = math.sqrt(dx * dx + dy * dy + dz * dz);
      if (len3 <= 1e-9) {
        // Light exactly on the surface point with zero height: no direction.
        continue;
      }
      final invLen3 = 1.0 / len3;
      final ndotl = (nx * dx + ny * dy + nz * dz) * invLen3;
      if (ndotl <= 0.0) {
        continue;
      }
      final falloff = 1.0 - (dist2D / l.radius);
      final atten = falloff * falloff * l.intensity * ndotl;
      accR += l.color.r * atten;
      accG += l.color.g * atten;
      accB += l.color.b * atten;
    }

    final r = (accR * baseTint.r * 255.0).round().clamp(0, 255);
    final g = (accG * baseTint.g * 255.0).round().clamp(0, 255);
    final b = (accB * baseTint.b * 255.0).round().clamp(0, 255);
    final a = (baseTint.a * opacity.clamp(0.0, 1.0) * 255.0).round().clamp(
      0,
      255,
    );
    return (a << 24) | (r << 16) | (g << 8) | b;
  }

  /// Adds a sprite quad `[dstRect]` sampling `[srcRect]` with either uniform
  /// [faceNormal] or spherical/bevel [bevelCurvature] (`0.0 .. 1.0`, curving
  /// corner normals outward so torches catch crisp bright edges on stone tiles,
  /// chests, pillars, and tokens!).
  ///
  /// Allocates nothing per call once the batch has grown to its working
  /// capacity. A batch holds at most [maxSprites] quads (16-bit vertex
  /// indices); further calls before the next [clear] are ignored.
  void addLitSprite({
    required ui.Rect srcRect,
    required ui.Rect dstRect,
    required List<PointLight2D> lights,
    SurfaceNormal2D faceNormal = SurfaceNormal2D.flat,
    double bevelCurvature = 0.45,
    ui.Color tint = const ui.Color(0xFFFFFFFF),
    double opacity = 1.0,
  }) {
    if (_spriteCount >= maxSprites || opacity <= 0.0) {
      return;
    }
    _ensureCapacity(_spriteCount + 1);

    final slot = _spriteCount++;
    final pBase = slot * 8;
    _positions[pBase] = dstRect.left;
    _positions[pBase + 1] = dstRect.top;
    _positions[pBase + 2] = dstRect.right;
    _positions[pBase + 3] = dstRect.top;
    _positions[pBase + 4] = dstRect.right;
    _positions[pBase + 5] = dstRect.bottom;
    _positions[pBase + 6] = dstRect.left;
    _positions[pBase + 7] = dstRect.bottom;

    _uvs[pBase] = srcRect.left;
    _uvs[pBase + 1] = srcRect.top;
    _uvs[pBase + 2] = srcRect.right;
    _uvs[pBase + 3] = srcRect.top;
    _uvs[pBase + 4] = srcRect.right;
    _uvs[pBase + 5] = srcRect.bottom;
    _uvs[pBase + 6] = srcRect.left;
    _uvs[pBase + 7] = srcRect.bottom;

    final bev = bevelCurvature.clamp(0.0, 0.95) * 0.70710678;
    final cBase = slot * 4;
    // Corners in vertex order: top-left, top-right, bottom-right, bottom-left.
    for (var c = 0; c < 4; c++) {
      final onRight = c == 1 || c == 2;
      final onBottom = c >= 2;
      var nx = faceNormal.nx + (onRight ? bev : -bev);
      var ny = faceNormal.ny + (onBottom ? bev : -bev);
      var nz = faceNormal.nz;
      final len = math.sqrt(nx * nx + ny * ny + nz * nz);
      if (len > 1e-6) {
        nx /= len;
        ny /= len;
        nz /= len;
      }
      _colors[cBase + c] = _litArgb(
        onRight ? dstRect.right : dstRect.left,
        onBottom ? dstRect.bottom : dstRect.top,
        nx,
        ny,
        nz,
        lights,
        tint,
        opacity,
      );
    }
  }

  /// Flushes all queued lit quads in `1` `Canvas.drawVertices` GPU call.
  void flush(ui.Canvas canvas) {
    _lastDrawCalls = 0;
    if (_spriteCount == 0) {
      return;
    }
    _paint.shader = _shader;
    final vertices = ui.Vertices.raw(
      ui.VertexMode.triangles,
      Float32List.sublistView(_positions, 0, _spriteCount * 8),
      textureCoordinates: Float32List.sublistView(_uvs, 0, _spriteCount * 8),
      colors: Int32List.sublistView(_colors, 0, _spriteCount * 4),
      indices: Uint16List.sublistView(_indices, 0, _spriteCount * 6),
    );
    canvas.drawVertices(vertices, ui.BlendMode.modulate, _paint);
    vertices.dispose();
    _lastDrawCalls = 1;
  }

  void dispose() {
    _shader.dispose();
  }
}
