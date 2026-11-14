import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flame/components.dart';
import 'package:flame/src/particles/particle_emitter_component.dart';
import 'package:flame/src/particles/particle_renderer.dart';

/// Marker mixin for custom [Component] or [PositionComponent] containers whose
/// `render` method performs no custom canvas drawing, allowing an ancestor
/// [ParticleBatchGroup] to traverse through them and coalesce nested
/// [ParticleEmitterComponent] children into shared GPU batches.
mixin BatchTransparentContainer on Component;

/// Container component that merges compatible descendant
/// [ParticleEmitterComponent]s sharing `(Image, BlendMode, FilterQuality)` into
/// minimal GPU draw calls per frame:
/// - **Shared `Canvas.drawRawAtlas`** for unstretched emitters with any
///   [Anchor], any `angle`, positive uniform scale, and nested container
///   hierarchies.
/// - **Shared `Canvas.drawVertices`** (`lastQuadBatchDrawCalls`) for emitters
///   with anisotropic `velocityStretch` (`particles.hasStretch`) or
///   non-uniform/mirrored scale.
///
/// Emitters with custom [CallbackParticleRenderer], custom `ColorFilter` /
/// `ImageFilter` / `Shader`, or non-empty child hierarchies seamlessly fall
/// back to their own `renderTree` in exact priority/sortKey order.
class ParticleBatchGroup({
  var bool batchingEnabled = true,
  var bool recursiveBatching = true,
  int initialCapacity = 512,
  super.children,
  super.priority,
  super.sortKey,
  super.key,
}) extends Component {
  static const int _maxQuadsPerDraw = 16383;

  Float32List _sharedTransforms = Float32List(max(64, initialCapacity) * 4);
  Float32List _sharedRects = Float32List(max(64, initialCapacity) * 4);
  Int32List _sharedColors = Int32List(max(64, initialCapacity));

  Float32List _sharedQuadPositions = Float32List(0);
  Float32List _sharedQuadUvs = Float32List(0);
  Int32List _sharedQuadColors = Int32List(0);
  Uint16List _sharedQuadIndices = Uint16List(0);

  final Paint _batchPaint = Paint();

  int _lastBatchedEmitterCount = 0;
  int _lastAtlasDrawCalls = 0;
  int _lastQuadBatchDrawCalls = 0;

  /// Number of descendant [ParticleEmitterComponent]s merged on the most recent
  /// render pass.
  int get lastBatchedEmitterCount => _lastBatchedEmitterCount;

  /// Number of batched `Canvas.drawRawAtlas` calls issued on the most recent
  /// render pass.
  int get lastAtlasDrawCalls => _lastAtlasDrawCalls;

  /// Number of batched `Canvas.drawVertices` quad calls issued for stretched or
  /// non-uniformly scaled emitters on the most recent render pass.
  int get lastQuadBatchDrawCalls => _lastQuadBatchDrawCalls;

  void _ensureAtlasCapacity(int neededParticles) {
    if (_sharedColors.length >= neededParticles) {
      return;
    }
    var cap = _sharedColors.length * 2;
    while (cap < neededParticles) {
      cap *= 2;
    }
    _sharedTransforms = Float32List(cap * 4)
      ..setRange(0, _sharedColors.length * 4, _sharedTransforms);
    _sharedRects = Float32List(cap * 4)
      ..setRange(0, _sharedColors.length * 4, _sharedRects);
    _sharedColors = Int32List(cap)
      ..setRange(0, _sharedColors.length, _sharedColors);
  }

  void _ensureQuadCapacity(int neededQuads) {
    final targetQuads = min(_maxQuadsPerDraw, neededQuads);
    final currentQuads = _sharedQuadColors.length ~/ 4;
    if (currentQuads >= targetQuads) {
      return;
    }
    var cap = max(64, currentQuads == 0 ? 64 : currentQuads * 2);
    while (cap < targetQuads) {
      cap *= 2;
    }
    cap = min(_maxQuadsPerDraw, cap);

    final nextPos = Float32List(cap * 8);
    final nextUvs = Float32List(cap * 8);
    final nextCols = Int32List(cap * 4);
    if (currentQuads > 0) {
      nextPos.setRange(0, currentQuads * 8, _sharedQuadPositions);
      nextUvs.setRange(0, currentQuads * 8, _sharedQuadUvs);
      nextCols.setRange(0, currentQuads * 4, _sharedQuadColors);
    }
    _sharedQuadPositions = nextPos;
    _sharedQuadUvs = nextUvs;
    _sharedQuadColors = nextCols;

    final nextIndices = Uint16List(cap * 6);
    for (var q = 0; q < cap; q++) {
      final b = q * 4;
      final k = q * 6;
      nextIndices[k] = b;
      nextIndices[k + 1] = b + 1;
      nextIndices[k + 2] = b + 2;
      nextIndices[k + 3] = b;
      nextIndices[k + 4] = b + 2;
      nextIndices[k + 5] = b + 3;
    }
    _sharedQuadIndices = nextIndices;
  }

  bool _isPureContainer(Component c) {
    if (!recursiveBatching || !c.hasChildren || c.debugMode) {
      return false;
    }
    if (c is PositionComponent && !c.decorator.isLastDecorator) {
      return false;
    }
    return c.runtimeType == Component ||
        c.runtimeType == PositionComponent ||
        c is ParticleBatchGroup ||
        c is BatchTransparentContainer;
  }

  static bool _isPositiveSimilarity(
    double m00,
    double m01,
    double m10,
    double m11,
  ) {
    // Positive similarity matrix has m10 == -m01, m11 == m00, det > 0.
    final det = m00 * m11 - m01 * m10;
    if (det <= 1e-10) {
      return false;
    }
    return (m00 - m11).abs() <= 1e-4 && (m01 + m10).abs() <= 1e-4;
  }

  @override
  void renderTree(Canvas canvas) {
    render(canvas);
    if (!hasChildren) {
      _lastBatchedEmitterCount = 0;
      _lastAtlasDrawCalls = 0;
      _lastQuadBatchDrawCalls = 0;
      return;
    }
    if (!batchingEnabled) {
      _lastBatchedEmitterCount = 0;
      _lastAtlasDrawCalls = 0;
      _lastQuadBatchDrawCalls = 0;
      for (final child in children) {
        child.renderTree(canvas);
      }
      return;
    }

    Image? activeTexture;
    ImageShader? activeQuadShader;
    BlendMode? activeBlendMode;
    var activeFilterQuality = FilterQuality.none;
    var activeIsQuadMode = false;
    var bufferedAtlasParticles = 0;
    var bufferedQuads = 0;
    var batchedEmitters = 0;
    var atlasDraws = 0;
    var quadDraws = 0;

    void flushActiveBatch() {
      if (activeTexture == null) {
        bufferedAtlasParticles = 0;
        bufferedQuads = 0;
        return;
      }
      if (!activeIsQuadMode && bufferedAtlasParticles > 0) {
        _batchPaint
          ..shader = null
          ..blendMode = activeBlendMode ?? BlendMode.srcOver
          ..filterQuality = activeFilterQuality;
        canvas.drawRawAtlas(
          activeTexture!,
          Float32List.sublistView(
            _sharedTransforms,
            0,
            bufferedAtlasParticles * 4,
          ),
          Float32List.sublistView(_sharedRects, 0, bufferedAtlasParticles * 4),
          Int32List.sublistView(_sharedColors, 0, bufferedAtlasParticles),
          BlendMode.modulate,
          null,
          _batchPaint,
        );
        atlasDraws++;
      } else if (activeIsQuadMode &&
          bufferedQuads > 0 &&
          activeQuadShader != null) {
        _batchPaint
          ..shader = activeQuadShader
          ..blendMode = activeBlendMode ?? BlendMode.srcOver
          ..filterQuality = activeFilterQuality;
        final vertices = Vertices.raw(
          VertexMode.triangles,
          Float32List.sublistView(_sharedQuadPositions, 0, bufferedQuads * 8),
          textureCoordinates: Float32List.sublistView(
            _sharedQuadUvs,
            0,
            bufferedQuads * 8,
          ),
          colors: Int32List.sublistView(
            _sharedQuadColors,
            0,
            bufferedQuads * 4,
          ),
          indices: Uint16List.sublistView(
            _sharedQuadIndices,
            0,
            bufferedQuads * 6,
          ),
        );
        try {
          canvas.drawVertices(vertices, BlendMode.modulate, _batchPaint);
        } finally {
          vertices.dispose();
          _batchPaint.shader = null;
        }
        quadDraws++;
      }
      bufferedAtlasParticles = 0;
      bufferedQuads = 0;
      activeTexture = null;
      activeQuadShader = null;
      activeBlendMode = null;
    }

    void renderFallbackInSpace(
      Component component,
      double pM00,
      double pM01,
      double pM10,
      double pM11,
      double pTx,
      double pTy, {
      required bool isIdentityParent,
    }) {
      flushActiveBatch();
      if (isIdentityParent) {
        component.renderTree(canvas);
        return;
      }
      canvas.save();
      canvas.transform(
        Float64List.fromList(<double>[
          pM00, pM01, 0.0, 0.0, //
          pM10, pM11, 0.0, 0.0, //
          0.0, 0.0, 1.0, 0.0, //
          pTx, pTy, 0.0, 1.0, //
        ]),
      );
      try {
        component.renderTree(canvas);
      } finally {
        canvas.restore();
      }
    }

    void visitChildren(
      Iterable<Component> list,
      double pM00,
      double pM01,
      double pM10,
      double pM11,
      double pTx,
      double pTy, {
      required bool isIdentityParent,
    }) {
      for (final child in list) {
        if (!child.isActiveForCurrentGraphicsTier) {
          continue;
        }
        if (child is HasVisibility && !child.isVisible) {
          continue;
        }

        if (child is ParticleEmitterComponent &&
            !child.hasChildren &&
            !child.debugMode &&
            child.decorator.isLastDecorator) {
          final r = child.renderer;
          if (r is TextureParticleRenderer &&
              r.canBatchAsQuads(child.particles)) {
            final s = child.transform.transformMatrix.storage;
            final cM00 = s[0];
            final cM01 = s[1];
            final cM10 = s[4];
            final cM11 = s[5];
            final cTx = s[12];
            final cTy = s[13];

            final m00 = isIdentityParent ? cM00 : (pM00 * cM00 + pM10 * cM01);
            final m01 = isIdentityParent ? cM01 : (pM01 * cM00 + pM11 * cM01);
            final m10 = isIdentityParent ? cM10 : (pM00 * cM10 + pM10 * cM11);
            final m11 = isIdentityParent ? cM11 : (pM01 * cM10 + pM11 * cM11);
            final tx = isIdentityParent ? cTx : (pTx + pM00 * cTx + pM10 * cTy);
            final ty = isIdentityParent ? cTy : (pTy + pM01 * cTx + pM11 * cTy);

            final count = child.particles.length;
            if (count == 0) {
              batchedEmitters++;
              continue;
            }

            final useAtlas =
                r.canBatchInAtlas(child.particles) &&
                _isPositiveSimilarity(m00, m01, m10, m11);
            final wantQuadMode = !useAtlas;
            final tex = r.texture!;
            final blend = r.paint.blendMode;
            final fq = r.paint.filterQuality;

            if (activeTexture != null &&
                (!identical(activeTexture, tex) ||
                    activeBlendMode != blend ||
                    activeFilterQuality != fq ||
                    activeIsQuadMode != wantQuadMode)) {
              flushActiveBatch();
            }

            if (!wantQuadMode) {
              activeTexture = tex;
              activeBlendMode = blend;
              activeFilterQuality = fq;
              activeIsQuadMode = false;
              _ensureAtlasCapacity(bufferedAtlasParticles + count);
              // Pass m00 as cosA and m01 as sinA with uniformScale = 1.0 since
              // m00 = scale * cos(angle) and m01 = scale * sin(angle).
              bufferedAtlasParticles = r.appendToSharedAtlas(
                particles: child.particles,
                outTransforms: _sharedTransforms,
                outRects: _sharedRects,
                outColors: _sharedColors,
                startSlot: bufferedAtlasParticles,
                offsetX: tx,
                offsetY: ty,
                cosA: m00,
                sinA: m01,
                uniformScale: 1.0,
              );
              batchedEmitters++;
              continue;
            } else {
              var offset = 0;
              while (offset < count) {
                final room = _maxQuadsPerDraw - bufferedQuads;
                if (room <= 0) {
                  flushActiveBatch();
                }
                final chunk = min(
                  count - offset,
                  _maxQuadsPerDraw - bufferedQuads,
                );
                activeTexture = tex;
                activeQuadShader = r.ensureCachedImageShader(tex);
                activeBlendMode = blend;
                activeFilterQuality = fq;
                activeIsQuadMode = true;
                _ensureQuadCapacity(bufferedQuads + chunk);
                bufferedQuads = r.appendToSharedQuads(
                  particles: child.particles,
                  startParticle: offset,
                  particleCount: chunk,
                  outPositions: _sharedQuadPositions,
                  outUvs: _sharedQuadUvs,
                  outColors: _sharedQuadColors,
                  startQuadSlot: bufferedQuads,
                  m00: m00,
                  m01: m01,
                  m10: m10,
                  m11: m11,
                  tx: tx,
                  ty: ty,
                );
                offset += chunk;
              }
              batchedEmitters++;
              continue;
            }
          }
        }

        if (_isPureContainer(child)) {
          if (child is PositionComponent) {
            final s = child.transform.transformMatrix.storage;
            final cM00 = s[0];
            final cM01 = s[1];
            final cM10 = s[4];
            final cM11 = s[5];
            final cTx = s[12];
            final cTy = s[13];
            final m00 = isIdentityParent ? cM00 : (pM00 * cM00 + pM10 * cM01);
            final m01 = isIdentityParent ? cM01 : (pM01 * cM00 + pM11 * cM01);
            final m10 = isIdentityParent ? cM10 : (pM00 * cM10 + pM10 * cM11);
            final m11 = isIdentityParent ? cM11 : (pM01 * cM10 + pM11 * cM11);
            final tx = isIdentityParent ? cTx : (pTx + pM00 * cTx + pM10 * cTy);
            final ty = isIdentityParent ? cTy : (pTy + pM01 * cTx + pM11 * cTy);
            visitChildren(
              child.children,
              m00,
              m01,
              m10,
              m11,
              tx,
              ty,
              isIdentityParent: false,
            );
          } else {
            visitChildren(
              child.children,
              pM00,
              pM01,
              pM10,
              pM11,
              pTx,
              pTy,
              isIdentityParent: isIdentityParent,
            );
          }
          continue;
        }

        renderFallbackInSpace(
          child,
          pM00,
          pM01,
          pM10,
          pM11,
          pTx,
          pTy,
          isIdentityParent: isIdentityParent,
        );
      }
    }

    visitChildren(
      children,
      1.0,
      0.0,
      0.0,
      1.0,
      0.0,
      0.0,
      isIdentityParent: true,
    );
    flushActiveBatch();
    _lastBatchedEmitterCount = batchedEmitters;
    _lastAtlasDrawCalls = atlasDraws;
    _lastQuadBatchDrawCalls = quadDraws;
  }
}
