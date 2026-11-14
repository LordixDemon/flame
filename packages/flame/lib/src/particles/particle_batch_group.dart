import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flame/components.dart';
import 'package:flame/src/particles/particle_emitter_component.dart';
import 'package:flame/src/particles/particle_renderer.dart';

/// Container component that merges compatible child [ParticleEmitterComponent]s
/// sharing `(Image, BlendMode)` into a single GPU [Canvas.drawRawAtlas] call
/// per frame.
///
/// Emitters with custom `CallbackParticleRenderer`, anisotropic velocity
/// stretch, non-uniform scale, or non-empty child hierarchies seamlessly fall
/// back to their own `renderTree` in exact priority/sortKey order.
class ParticleBatchGroup({
  var bool batchingEnabled = true,
  int initialCapacity = 512,
  super.children,
  super.priority,
  super.sortKey,
  super.key,
}) extends Component {
  Float32List _sharedTransforms = Float32List(max(64, initialCapacity) * 4);
  Float32List _sharedRects = Float32List(max(64, initialCapacity) * 4);
  Int32List _sharedColors = Int32List(max(64, initialCapacity));
  final Paint _batchPaint = Paint();

  int _lastBatchedEmitterCount = 0;
  int _lastAtlasDrawCalls = 0;

  /// Number of child [ParticleEmitterComponent]s merged on the most recent
  /// render pass.
  int get lastBatchedEmitterCount => _lastBatchedEmitterCount;

  /// Number of batched `Canvas.drawRawAtlas` calls issued on the most recent
  /// render pass.
  int get lastAtlasDrawCalls => _lastAtlasDrawCalls;

  void _ensureCapacity(int neededParticles) {
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

  @override
  void renderTree(Canvas canvas) {
    render(canvas);
    if (!hasChildren) {
      _lastBatchedEmitterCount = 0;
      _lastAtlasDrawCalls = 0;
      return;
    }
    if (!batchingEnabled) {
      _lastBatchedEmitterCount = 0;
      _lastAtlasDrawCalls = 0;
      for (final child in children) {
        child.renderTree(canvas);
      }
      return;
    }

    Image? activeTexture;
    BlendMode? activeBlendMode;
    var activeFilterQuality = FilterQuality.none;
    var bufferedParticles = 0;
    var batchedEmitters = 0;
    var atlasDraws = 0;

    void flushActiveBatch() {
      if (bufferedParticles == 0 || activeTexture == null) {
        bufferedParticles = 0;
        activeTexture = null;
        activeBlendMode = null;
        return;
      }
      _batchPaint
        ..blendMode = activeBlendMode ?? BlendMode.srcOver
        ..filterQuality = activeFilterQuality;
      canvas.drawRawAtlas(
        activeTexture!,
        Float32List.sublistView(_sharedTransforms, 0, bufferedParticles * 4),
        Float32List.sublistView(_sharedRects, 0, bufferedParticles * 4),
        Int32List.sublistView(_sharedColors, 0, bufferedParticles),
        BlendMode.modulate,
        null,
        _batchPaint,
      );
      atlasDraws++;
      bufferedParticles = 0;
      activeTexture = null;
      activeBlendMode = null;
    }

    for (final child in children) {
      if (child is HasVisibility && !child.isVisible) {
        continue;
      }
      if (child is ParticleEmitterComponent &&
          !child.hasChildren &&
          child.anchor == Anchor.topLeft &&
          (child.scale.x - child.scale.y).abs() < 1e-5 &&
          child.scale.x > 0) {
        final r = child.renderer;
        if (r is TextureParticleRenderer &&
            r.canBatchInAtlas(child.particles)) {
          final count = child.particles.length;
          if (count == 0) {
            batchedEmitters++;
            continue;
          }
          final tex = r.texture!;
          final blend = r.paint.blendMode;
          final fq = r.paint.filterQuality;
          if (activeTexture != null &&
              (!identical(activeTexture, tex) ||
                  activeBlendMode != blend ||
                  activeFilterQuality != fq)) {
            flushActiveBatch();
          }
          activeTexture = tex;
          activeBlendMode = blend;
          activeFilterQuality = fq;

          _ensureCapacity(bufferedParticles + count);
          final ang = child.angle;
          final cosA = ang == 0 ? 1.0 : cos(ang);
          final sinA = ang == 0 ? 0.0 : sin(ang);
          bufferedParticles = r.appendToSharedAtlas(
            particles: child.particles,
            outTransforms: _sharedTransforms,
            outRects: _sharedRects,
            outColors: _sharedColors,
            startSlot: bufferedParticles,
            offsetX: child.position.x,
            offsetY: child.position.y,
            cosA: cosA,
            sinA: sinA,
            uniformScale: child.scale.x,
          );
          batchedEmitters++;
          continue;
        }
      }

      flushActiveBatch();
      child.renderTree(canvas);
    }

    flushActiveBatch();
    _lastBatchedEmitterCount = batchedEmitters;
    _lastAtlasDrawCalls = atlasDraws;
  }
}
