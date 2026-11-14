import 'package:flame/collisions.dart';
import 'package:flame/geometry.dart';
import 'package:flutter/widgets.dart';

/// Collision detection modification to support a Quad Tree broadphase.
///
/// Do not use standard [items] list for components. Instead adds all components
/// into [QuadTreeBroadphase] class.
class QuadTreeCollisionDetection({
  required Rect mapDimensions,
  required ExternalBroadphaseCheck onComponentTypeCheck,
  required ExternalMinDistanceCheck minimumDistanceCheck,
  int maxObjects = 25,
  int maxDepth = 10,
}) extends StandardCollisionDetection<QuadTreeBroadphase> {
  this
    : super(
        broadphase: QuadTreeBroadphase(
          mainBoxSize: mapDimensions,
          maxObjects: maxObjects,
          maxDepth: maxDepth,
          broadphaseCheck: onComponentTypeCheck,
          minimumDistanceCheck: minimumDistanceCheck,
        ),
      );

  final _listenerCollisionType = <ShapeHitbox, VoidCallback>{};
  final _scheduledUpdate = <ShapeHitbox>{};

  @override
  void add(ShapeHitbox item) {
    item.onAabbChanged = () => _scheduledUpdate.add(item);
    void listenerCollisionType() {
      if (item.isMounted) {
        if (item.collisionType == CollisionType.active) {
          broadphase.activeHitboxes.add(item);
        } else {
          broadphase.activeHitboxes.remove(item);
        }
      }
    }

    item.collisionTypeNotifier.addListener(listenerCollisionType);
    _listenerCollisionType[item] = listenerCollisionType;

    super.add(item);
  }

  @override
  void addAll(Iterable<ShapeHitbox> items) {
    for (final item in items) {
      add(item);
    }
  }

  @override
  void remove(ShapeHitbox item) {
    item.onAabbChanged = null;
    final listenerCollisionType = _listenerCollisionType[item];
    if (listenerCollisionType != null) {
      item.collisionTypeNotifier.removeListener(listenerCollisionType);
      _listenerCollisionType.remove(item);
    }

    super.remove(item);
  }

  @override
  void removeAll(Iterable<ShapeHitbox> items) {
    broadphase.clear();
    for (final item in items) {
      remove(item);
    }
  }

  void _flushScheduledUpdates() {
    if (_scheduledUpdate.isEmpty) {
      return;
    }
    for (final hitbox in _scheduledUpdate) {
      broadphase.updateTransform(hitbox);
    }
    _scheduledUpdate.clear();
  }

  @override
  void run() {
    _flushScheduledUpdates();
    super.run();
  }

  @override
  RaycastResult<ShapeHitbox>? raycast(
    Ray2 ray, {
    double? maxDistance,
    int collisionMask = 0xFFFFFFFF,
    bool Function(ShapeHitbox candidate)? hitboxFilter,
    List<ShapeHitbox>? ignoreHitboxes,
    RaycastResult<ShapeHitbox>? out,
  }) {
    _flushScheduledUpdates();
    return super.raycast(
      ray,
      maxDistance: maxDistance,
      collisionMask: collisionMask,
      hitboxFilter: hitboxFilter,
      ignoreHitboxes: ignoreHitboxes,
      out: out,
    );
  }
}
