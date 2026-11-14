import 'dart:ui';

import 'package:flame/src/camera/camera_component.dart';
import 'package:flame/src/components/core/component.dart';
import 'package:flame/src/components/mixins/coordinate_transform.dart';
import 'package:flame/src/components/mixins/image_retainer.dart';
import 'package:flame/src/components/position_component.dart';
import 'package:flame/src/sprite_batch.dart';
import 'package:meta/meta.dart';

/// A component that renders a [SpriteBatch], which can also be set later.
class SpriteBatchComponent({
  var SpriteBatch? _spriteBatch,
  var BlendMode? blendMode,
  var Rect? cullRect,
  var bool autoCullRect = true,
  var Paint? paint,
  super.key,
  super.children,
  super.priority,
}) extends Component with ImageRetainer {
  /// The atlas that was retained at the last render, so that a [SpriteBatch]
  /// that swaps its atlas for a flipped one gets the new atlas retained.
  Image? _retainedAtlas;

  Rect? _lastEffectiveCullRect;

  /// Effective `cullRect` passed to `SpriteBatch.render` on the most recent
  /// [render] call.
  @visibleForTesting
  Rect? get lastEffectiveCullRect => _lastEffectiveCullRect;

  /// The [SpriteBatch] that this component renders.
  SpriteBatch? get spriteBatch => _spriteBatch;

  set spriteBatch(SpriteBatch? value) {
    _spriteBatch = value;
    updateRetainedImages();
  }

  @override
  Iterable<Image> get retainedImages {
    final atlas = _spriteBatch?.atlas;
    return atlas == null ? const [] : [atlas];
  }

  @override
  @mustCallSuper
  void onMount() {
    assert(
      spriteBatch != null,
      'You have to set spriteBatch in either the constructor or in onLoad',
    );
    super.onMount();
  }

  Rect? _resolveAutoWorldCullRect() {
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
        if (t.position.x != 0.0 ||
            t.position.y != 0.0 ||
            t.offset.x != 0.0 ||
            t.offset.y != 0.0 ||
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

  @mustCallSuper
  @override
  void render(Canvas canvas) {
    final spriteBatch = _spriteBatch;
    if (spriteBatch == null) {
      return;
    }
    if (!identical(spriteBatch.atlas, _retainedAtlas)) {
      _retainedAtlas = spriteBatch.atlas;
      updateRetainedImages();
    }
    final effectiveCull =
        cullRect ?? (autoCullRect ? _resolveAutoWorldCullRect() : null);
    _lastEffectiveCullRect = effectiveCull;
    spriteBatch.render(
      canvas,
      blendMode: blendMode,
      cullRect: effectiveCull,
      paint: paint,
    );
  }
}
