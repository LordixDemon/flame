import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flame/camera.dart';
import 'package:flame/extensions.dart';
import 'package:flame/rendering.dart';
import 'package:flame/src/collisions/hitboxes/shape_hitbox.dart';
import 'package:flame/src/components/core/component.dart';
import 'package:flame/src/components/mixins/coordinate_transform.dart';
import 'package:flame/src/components/mixins/has_decorator.dart';
import 'package:flame/src/components/mixins/has_paint.dart';
import 'package:flame/src/components/mixins/snapshot.dart';
import 'package:flame/src/components/position_component.dart';
import 'package:flame/src/components/sprite_animation_component.dart';
import 'package:flame/src/components/sprite_component.dart';
import 'package:flame/src/sprite_batch.dart';
import 'package:meta/meta.dart';

/// Descriptor returned by [SpriteBatchItemProvider] for custom components that
/// participate in [HasAutoBatchedChildren] GPU sprite batching.
@immutable
class const SpriteBatchEntry({
  required final Image image,
  required final Rect sourceRect,
  final Color color = const Color(0xFFFFFFFF),
  final BlendMode blendMode = BlendMode.srcOver,
});

/// Mixin allowing custom [PositionComponent] subclasses (beyond
/// [SpriteComponent] and [SpriteAnimationComponent]) to participate in
/// [HasAutoBatchedChildren] GPU batching.
mixin SpriteBatchItemProvider on PositionComponent {
  /// Returns the current frame's atlas [Image], source [Rect], tint [Color],
  /// and canvas [BlendMode], or `null` to fall back to individual rendering.
  SpriteBatchEntry? provideSpriteBatchItem();
}

/// Mixin enabling children of a [Component] to be automatically batched into
/// shared [Canvas.drawAtlas] (and optionally affine [Canvas.drawVertices] when
/// [allowAffineVerticesBatching] is `true`) calls per `(Image, BlendMode)`
/// within each priority group.
mixin HasAutoBatchedChildren on Component {
  /// When `false`, every child is rendered individually (no batching).
  bool batchingEnabled = true;

  /// When `true`, sprites with non-uniform `scale` (`scale.x != scale.y`) or
  /// aspect-stretched `size` are batched into a shared [Canvas.drawVertices]
  /// textured quad buffer instead of falling back to individual draws.
  ///
  /// Defaults to `false` to preserve strict `drawAtlas`-only fallback semantics
  /// unless opted into.
  bool allowAffineVerticesBatching = false;

  /// When `true` (default), automatically supplies
  /// `CameraComponent.currentCamera?.visibleWorldRect` as `cullRect` to
  /// `Canvas.drawAtlas` whenever this container renders directly in `World`
  /// coordinates so Impeller/Skia skips offscreen atlas quads in hardware.
  bool autoCullRect = true;

  Rect? _lastEffectiveCullRect;

  /// Effective `cullRect` passed to `drawAtlas` on the most recent flush.
  @visibleForTesting
  Rect? get lastEffectiveCullRect => _lastEffectiveCullRect;

  // Atlas accumulators keyed by (Image, BlendMode).
  final Map<(Image, BlendMode), _BatchAccumulator> _accumulators = {};

  // Affine quad accumulators keyed by (Image, BlendMode).
  final Map<(Image, BlendMode), _AffineQuadAccumulator> _affineAccumulators =
      {};

  // Priority of the child group currently being accumulated.
  int? _currentPriority;

  // Blend mode of the pending batches. Children are only regrouped (by image)
  // while they share a blend mode, so the draw order of children with
  // different blend modes is always the child order.
  BlendMode? _pendingBlendMode;

  static const Set<BlendMode> _supportedBlendModes = {
    BlendMode.srcOver,
    BlendMode.plus,
    BlendMode.screen,
    BlendMode.multiply,
    BlendMode.modulate,
    BlendMode.lighten,
    BlendMode.darken,
  };

  @override
  @protected
  void renderChild(Canvas canvas, Component child) {
    if (!batchingEnabled) {
      super.renderChild(canvas, child);
      return;
    }

    final activePass = CameraComponent.currentRenderPass;
    if (child is! MultiPassComponent &&
        !CameraComponent.paintsOrdinaryComponents(activePass)) {
      _flushAll(canvas);
      super.renderChild(canvas, child);
      return;
    }

    final childPriority = child.priority;
    if (_currentPriority != null && childPriority != _currentPriority) {
      _flushAll(canvas);
    }
    _currentPriority = childPriority;

    final batchInfo = _tryGetBatchInfo(
      child,
      allowAffine: allowAffineVerticesBatching,
    );
    if (batchInfo != null) {
      _accumulateChild(child as PositionComponent, batchInfo, canvas);
      if (child.debugMode) {
        for (final hitbox in child.children.whereType<ShapeHitbox>()) {
          canvas.save();
          canvas.transform2D(child.transform);
          hitbox.renderDebugMode(canvas);
          canvas.restore();
        }
      }
    } else {
      _flushAll(canvas);
      super.renderChild(canvas, child);
    }
  }

  @override
  @protected
  void afterChildrenRendered(Canvas canvas) {
    _flushAll(canvas);
    _currentPriority = null;
    super.afterChildrenRendered(canvas);
  }

  @mustCallSuper
  @override
  void onRemove() {
    for (final affine in _affineAccumulators.values) {
      affine.dispose();
    }
    _affineAccumulators.clear();
    super.onRemove();
  }

  void _accumulateChild(
    PositionComponent child,
    _BatchInfo info,
    Canvas canvas,
  ) {
    final key = (info.image, info.blendMode);
    if (_pendingBlendMode != null && _pendingBlendMode != info.blendMode) {
      _flushAll(canvas);
    }
    _pendingBlendMode = info.blendMode;
    if (info.requiresAffineVertices) {
      // Flush any pending drawAtlas batches first to preserve z-order.
      _flushAtlasOnly(canvas);
      final acc = _affineAccumulators[key] ??= _AffineQuadAccumulator(
        info.image,
        info.blendMode,
      );
      acc.accumulate(child, info.sourceRect, info.rawColor);
    } else {
      if (_affineAccumulators.values.any((a) => !a.isEmpty)) {
        _flushAffineOnly(canvas);
      }
      final acc = _accumulators[key] ??= _BatchAccumulator(
        info.image,
        info.blendMode,
      );
      acc.accumulate(
        info.sourceRect,
        _toRSTransform(child, info.sourceRect),
        info.rawColor,
      );
    }
  }

  Rect? _resolveAutoWorldCullRect() {
    if (!autoCullRect) {
      return null;
    }
    final camera = CameraComponent.currentCamera;
    if (camera == null || camera.parent == null) {
      return null;
    }
    final targetWorld = camera.world;
    if (targetWorld == null) {
      return null;
    }
    Component? cursor = this;
    while (cursor != null) {
      if (identical(cursor, targetWorld)) {
        return camera.visibleWorldRect;
      }
      if (cursor is PositionComponent) {
        final t = cursor.transform;
        if (!t.position.isZero() ||
            !t.offset.isZero() ||
            t.angle != 0.0 ||
            t.scale.x != 1.0 ||
            t.scale.y != 1.0) {
          return null;
        }
      } else if (cursor is CoordinateTransform) {
        return null;
      }
      cursor = cursor.parent;
    }
    return null;
  }

  void _flushAtlasOnly(Canvas canvas) {
    final cullRect = _resolveAutoWorldCullRect();
    _lastEffectiveCullRect = cullRect;
    for (final acc in _accumulators.values) {
      acc.flush(canvas, cullRect: cullRect);
    }
  }

  void _flushAffineOnly(Canvas canvas) {
    for (final acc in _affineAccumulators.values) {
      acc.flush(canvas);
    }
  }

  void _flushAll(Canvas canvas) {
    _flushAtlasOnly(canvas);
    _flushAffineOnly(canvas);
    _pendingBlendMode = null;
  }

  static _BatchInfo? _tryGetBatchInfo(
    Component component, {
    required bool allowAffine,
  }) {
    if (!component.isMounted) {
      return null;
    }

    if (component is HasDecorator && component.decorator != null) {
      return null;
    }

    final isBuiltInSprite =
        component is SpriteComponent || component is SpriteAnimationComponent;
    final isCustomProvider = component is SpriteBatchItemProvider;
    if (!isBuiltInSprite && !isCustomProvider) {
      return null;
    }

    final positionComponent = component as PositionComponent;
    final decorator = positionComponent.decorator;
    if (decorator is! Transform2DDecorator || !decorator.isLastDecorator) {
      return null;
    }

    if (positionComponent.children.any((child) => child is! ShapeHitbox)) {
      return null;
    }

    if (positionComponent is Snapshot && positionComponent.renderSnapshot) {
      return null;
    }

    final Image image;
    final Rect sourceRect;
    final Color rawColor;
    final BlendMode blendMode;

    if (component is SpriteBatchItemProvider) {
      final entry = component.provideSpriteBatchItem();
      if (entry == null) {
        return null;
      }
      if (!_supportedBlendModes.contains(entry.blendMode)) {
        return null;
      }
      image = entry.image;
      sourceRect = entry.sourceRect;
      rawColor = entry.color;
      blendMode = entry.blendMode;
    } else {
      final hasPaint = component as HasPaint;
      final paint = hasPaint.paint;
      if (paint.colorFilter != null ||
          paint.shader != null ||
          paint.imageFilter != null ||
          paint.maskFilter != null ||
          !_supportedBlendModes.contains(paint.blendMode) ||
          hasPaint.paintLayers.length > 1) {
        return null;
      }

      if (component is SpriteComponent) {
        final sprite = component.sprite;
        if (sprite == null) {
          return null;
        }
        image = sprite.image;
        sourceRect = sprite.src;
      } else {
        final ticker = (component as SpriteAnimationComponent).animationTicker;
        if (ticker == null) {
          return null;
        }
        final frame = ticker.currentFrame;
        image = frame.sprite.image;
        sourceRect = frame.sprite.src;
      }
      rawColor = paint.color;
      blendMode = paint.blendMode;
    }

    final sourceWidth = sourceRect.width;
    final sourceHeight = sourceRect.height;
    if (sourceWidth <= 0 || sourceHeight <= 0) {
      return null;
    }

    final nonUniformScale =
        positionComponent.scale.x != positionComponent.scale.y;
    final aspectMismatch =
        (positionComponent.size.x * sourceHeight -
                positionComponent.size.y * sourceWidth)
            .abs() >
        0.5;
    final requiresAffine = nonUniformScale || aspectMismatch;
    if (requiresAffine && !allowAffine) {
      return null;
    }
    if (requiresAffine &&
        (positionComponent.size.x == 0 || positionComponent.size.y == 0)) {
      return null;
    }

    return _BatchInfo(
      image: image,
      sourceRect: sourceRect,
      rawColor: rawColor,
      blendMode: blendMode,
      requiresAffineVertices: requiresAffine,
    );
  }

  static RSTransform _toRSTransform(PositionComponent component, Rect source) {
    final effectiveScale = component.scale.x * component.size.x / source.width;
    final totalAngle = component.angle + component.nativeAngle;
    final cosA = math.cos(totalAngle) * effectiveScale;
    final sinA = math.sin(totalAngle) * effectiveScale;

    final anchorX = component.anchor.x * source.width;
    final anchorY = component.anchor.y * source.height;

    return RSTransform(
      cosA,
      sinA,
      component.position.x - cosA * anchorX + sinA * anchorY,
      component.position.y - sinA * anchorX - cosA * anchorY,
    );
  }
}

class _BatchAccumulator(Image atlas, final BlendMode blendMode) {
  final SpriteBatch batch = SpriteBatch(atlas);
  final Paint _paint = Paint()..blendMode = blendMode;
  final List<(Rect, RSTransform, Color)> _items = [];
  bool _anyTint = false;

  void accumulate(Rect source, RSTransform transform, Color color) {
    _items.add((source, transform, color));
    if (color != _white) {
      _anyTint = true;
    }
  }

  static const Color _white = Color(0xFFFFFFFF);

  void flush(Canvas canvas, {Rect? cullRect}) {
    if (_items.isEmpty) {
      return;
    }
    for (final (source, transform, color) in _items) {
      // Without any tint the colors are left out altogether. Otherwise the
      // sprite is modulated by its color (so that opacity and tint apply to
      // the sprite, like on the affine path), and untinted sprites are
      // modulated by opaque white.
      batch.addTransform(
        source: source,
        transform: transform,
        color: _anyTint ? color : null,
      );
    }
    batch.render(
      canvas,
      blendMode: BlendMode.modulate,
      cullRect: cullRect,
      paint: blendMode == BlendMode.srcOver ? null : _paint,
    );
    batch.clear();
    _items.clear();
    _anyTint = false;
  }
}

class _AffineQuadAccumulator(
  final Image atlas,
  final BlendMode blendMode,
) {
  static final Float64List _identityMatrix64 = Float64List.fromList(const [
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
  ]);

  ImageShader? _shader;
  final Paint _paint = Paint()
    ..blendMode = blendMode
    ..filterQuality = FilterQuality.low;

  int _quadCount = 0;
  Float32List _positions = Float32List(64 * 8);
  Float32List _uvs = Float32List(64 * 8);
  Int32List _colors = Int32List(64 * 4);
  Uint16List _indices = _buildQuadIndices(64);

  bool get isEmpty => _quadCount == 0;

  static Uint16List _buildQuadIndices(int quadCapacity) {
    final out = Uint16List(quadCapacity * 6);
    for (var q = 0; q < quadCapacity; q++) {
      final v = q * 4;
      final i = q * 6;
      out[i] = v;
      out[i + 1] = v + 1;
      out[i + 2] = v + 2;
      out[i + 3] = v;
      out[i + 4] = v + 2;
      out[i + 5] = v + 3;
    }
    return out;
  }

  void _ensureCapacity(int neededQuads) {
    final currentCap = _colors.length ~/ 4;
    if (neededQuads <= currentCap) {
      return;
    }
    var nextCap = currentCap * 2;
    while (nextCap < neededQuads) {
      nextCap *= 2;
    }
    _positions = Float32List(nextCap * 8)
      ..setRange(0, _quadCount * 8, _positions);
    _uvs = Float32List(nextCap * 8)..setRange(0, _quadCount * 8, _uvs);
    _colors = Int32List(nextCap * 4)..setRange(0, _quadCount * 4, _colors);
    _indices = _buildQuadIndices(nextCap);
  }

  void accumulate(PositionComponent component, Rect src, Color color) {
    _ensureCapacity(_quadCount + 1);

    final m = component.transformMatrix.storage;
    final m0 = m[0];
    final m1 = m[1];
    final m4 = m[4];
    final m5 = m[5];
    final tx = m[12];
    final ty = m[13];

    final w = component.size.x;
    final h = component.size.y;

    final pBase = _quadCount * 8;
    // (0, 0)
    _positions[pBase] = tx;
    _positions[pBase + 1] = ty;
    // (w, 0)
    _positions[pBase + 2] = m0 * w + tx;
    _positions[pBase + 3] = m1 * w + ty;
    // (w, h)
    _positions[pBase + 4] = m0 * w + m4 * h + tx;
    _positions[pBase + 5] = m1 * w + m5 * h + ty;
    // (0, h)
    _positions[pBase + 6] = m4 * h + tx;
    _positions[pBase + 7] = m5 * h + ty;

    _uvs[pBase] = src.left;
    _uvs[pBase + 1] = src.top;
    _uvs[pBase + 2] = src.right;
    _uvs[pBase + 3] = src.top;
    _uvs[pBase + 4] = src.right;
    _uvs[pBase + 5] = src.bottom;
    _uvs[pBase + 6] = src.left;
    _uvs[pBase + 7] = src.bottom;

    final cBase = _quadCount * 4;
    final argb = color.toARGB32();
    _colors[cBase] = argb;
    _colors[cBase + 1] = argb;
    _colors[cBase + 2] = argb;
    _colors[cBase + 3] = argb;

    _quadCount++;
  }

  void flush(Canvas canvas) {
    if (_quadCount == 0) {
      return;
    }
    final shader = _shader ??= ImageShader(
      atlas,
      TileMode.clamp,
      TileMode.clamp,
      _identityMatrix64,
    );
    _paint.shader = shader;
    final vertices = Vertices.raw(
      VertexMode.triangles,
      Float32List.sublistView(_positions, 0, _quadCount * 8),
      textureCoordinates: Float32List.sublistView(_uvs, 0, _quadCount * 8),
      colors: Int32List.sublistView(_colors, 0, _quadCount * 4),
      indices: Uint16List.sublistView(_indices, 0, _quadCount * 6),
    );
    canvas.drawVertices(vertices, BlendMode.modulate, _paint);
    vertices.dispose();
    _quadCount = 0;
  }

  void dispose() {
    _shader?.dispose();
    _shader = null;
    _quadCount = 0;
  }
}

class _BatchInfo({
  required final Image image,
  required final Rect sourceRect,
  required final Color rawColor,
  required final BlendMode blendMode,
  required final bool requiresAffineVertices,
});
