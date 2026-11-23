import 'dart:math' as math;

import 'package:flame/components.dart' show Component, HasWorldRef;
import 'package:flame_3d/camera.dart' show World3D;
import 'package:flame_3d/collisions.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/src/extensions/geometry_math.dart';
import 'package:meta/meta.dart';

part 'collision_system_3d.dart';

/// Mixin on [Component3D] receiving 3D collider contact lifecycle callbacks
/// from [CollisionSystem3D].
mixin CollisionCallbacks3D on Component3D {
  /// Invoked on the step when this component's collider begins overlapping
  /// [other].
  ///
  /// `manifold.normal` points from this component's collider toward [other].
  void onCollisionStart3D(Collider3D other, CollisionManifold3D manifold) {}

  /// Invoked on every step while this component's collider continues
  /// overlapping [other].
  void onCollision3D(Collider3D other, CollisionManifold3D manifold) {}

  /// Invoked when this component's collider stops overlapping [other] (or when
  /// either collider is removed).
  void onCollisionEnd3D(Collider3D other) {}
}

/// A 3D collision volume attachable to any [Component3D] (or usable standalone
/// in a [World3D]).
class Collider3D({
  required Shape3D shape,
  Vector3? localOffset,
  var int collisionLayer = 1,
  var int collisionMask = 0xFFFFFFFF,
  var bool isTrigger = false,
  var bool isStatic = false,
  var PhysicsMaterial3D? material,
  super.position,
  super.scale,
  super.rotation,
  super.children,
}) extends Component3D {
  Shape3D _shape = shape;

  /// Geometric collision shape in local space.
  Shape3D get shape => _shape;
  set shape(Shape3D value) {
    if (identical(value, _shape)) {
      return;
    }
    _shape = value;
    markAabbDirty();
  }

  /// Additional local-space translation offset of [shape] relative to this
  /// component's origin.
  final Vector3 localOffset = localOffset?.clone() ?? Vector3.zero();

  final Matrix4 _colliderWorldMatrix = Matrix4.identity();
  final Aabb3 _colliderWorldAabb = Aabb3();
  final Aabb3 _localShapeAabb = Aabb3();

  int _cachedMatrixVersion = -1;
  Component? _cachedMatrixParent;
  double _cachedOffsetX = double.nan;
  double _cachedOffsetY = 0.0;
  double _cachedOffsetZ = 0.0;
  int _colliderMatrixRev = 0;
  Shape3D? _cachedAabbShape;
  int _cachedAabbMatrixRev = -1;

  /// The collision systems this collider registered with when it mounted.
  @internal
  final List<CollisionSystem3D> enclosingCollisionSystems = [];

  @override
  void onMount() {
    super.onMount();
    CollisionSystem3D.attachToEnclosingSystems(this);
  }

  @override
  void onRemove() {
    for (var i = 0; i < enclosingCollisionSystems.length; i++) {
      enclosingCollisionSystems[i].unregisterMountedCollider(this);
    }
    enclosingCollisionSystems.clear();
    super.onRemove();
  }

  /// The logical owner component of this collider: its parent [Component3D] if
  /// attached as a child, or `this` when standalone.
  Component3D get hostComponent {
    final p = parent;
    return p is Component3D ? p : this;
  }

  bool _refreshColliderWorldMatrix() {
    final p = parent;
    final ver = worldTransformVersion;
    final ox = localOffset.x;
    final oy = localOffset.y;
    final oz = localOffset.z;
    if ((isMounted || p == null) &&
        ver == _cachedMatrixVersion &&
        identical(p, _cachedMatrixParent) &&
        ox == _cachedOffsetX &&
        oy == _cachedOffsetY &&
        oz == _cachedOffsetZ) {
      return false;
    }
    _cachedMatrixVersion = ver;
    _cachedMatrixParent = p;
    _cachedOffsetX = ox;
    _cachedOffsetY = oy;
    _cachedOffsetZ = oz;
    final w = worldTransformMatrix;
    final m = w.storage;
    _colliderWorldMatrix.setFrom(w);
    if (ox != 0.0 || oy != 0.0 || oz != 0.0) {
      final out = _colliderWorldMatrix.storage;
      out[12] = m[0] * ox + m[4] * oy + m[8] * oz + m[12];
      out[13] = m[1] * ox + m[5] * oy + m[9] * oz + m[13];
      out[14] = m[2] * ox + m[6] * oy + m[10] * oz + m[14];
    }
    _colliderMatrixRev++;
    return true;
  }

  /// Recomputes [_colliderWorldAabb] only when the collider's transform,
  /// [localOffset], or [shape] changed; returns whether the AABB was refreshed.
  @internal
  bool refreshCachedWorldAabb() {
    final matChanged = _refreshColliderWorldMatrix();
    if (!matChanged &&
        _cachedAabbMatrixRev == _colliderMatrixRev &&
        identical(_cachedAabbShape, _shape)) {
      return false;
    }
    _cachedAabbMatrixRev = _colliderMatrixRev;
    _cachedAabbShape = _shape;
    _shape.computeWorldAabb(_colliderWorldMatrix, _colliderWorldAabb);
    return true;
  }

  /// Last world-space AABB computed by [colliderWorldAabb] or
  /// [refreshCachedWorldAabb].
  @internal
  Aabb3 get cachedWorldAabb => _colliderWorldAabb;

  /// World transformation matrix of [shape], combining [worldTransformMatrix]
  /// with [localOffset].
  Matrix4 get colliderWorldMatrix {
    _refreshColliderWorldMatrix();
    return _colliderWorldMatrix;
  }

  /// Computes and returns the world-space AABB of [shape] at
  /// [colliderWorldMatrix].
  Aabb3 get colliderWorldAabb {
    refreshCachedWorldAabb();
    return _colliderWorldAabb;
  }

  /// Returns `true` when 32-bit layer/mask filtering allows contact with
  /// [other].
  bool canCollideWith(Collider3D other) {
    if (identical(this, other) ||
        identical(hostComponent, other.hostComponent)) {
      return false;
    }
    if (isStatic && other.isStatic) {
      return false;
    }
    return (collisionLayer & other.collisionMask) != 0 &&
        (other.collisionLayer & collisionMask) != 0;
  }

  @override
  Aabb3? computeLocalAabb() {
    _shape.computeLocalAabb(out: _localShapeAabb);
    _localShapeAabb.min.add(localOffset);
    _localShapeAabb.max.add(localOffset);
    return _localShapeAabb;
  }
}

/// Sensor collider (`isTrigger: true`) firing [onEnter3D], [onStay3D], and
/// [onExit3D] callbacks without physical blocking.
class TriggerVolume3D({
  required super.shape,
  super.localOffset,
  super.collisionLayer,
  super.collisionMask,
  super.isStatic,
  super.material,
  super.position,
  super.scale,
  super.rotation,
  super.children,
  final void Function(Collider3D other, CollisionManifold3D manifold)?
  onEnter3D,
  final void Function(Collider3D other, CollisionManifold3D manifold)? onStay3D,
  final void Function(Collider3D other)? onExit3D,
}) extends Collider3D {
  this : super(isTrigger: true);

  /// Called when [other] enters this trigger volume.
  void handleEnter3D(Collider3D other, CollisionManifold3D manifold) {
    onEnter3D?.call(other, manifold);
  }

  /// Called each step while [other] stays inside this trigger volume.
  void handleStay3D(Collider3D other, CollisionManifold3D manifold) {
    onStay3D?.call(other, manifold);
  }

  /// Called when [other] exits this trigger volume.
  void handleExit3D(Collider3D other) {
    onExit3D?.call(other);
  }
}

/// Ray hit result returned by [CollisionSystem3D.raycastColliders] and
/// [CollisionSystem3D.raycastAllColliders].
class ColliderRayHit3D({
  required final Collider3D collider,
  required final double distance,
  required final Vector3 point,
  required final Vector3 normal,
});
