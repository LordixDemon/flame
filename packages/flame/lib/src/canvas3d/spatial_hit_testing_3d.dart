import 'dart:typed_data';

import 'package:flame/src/camera/world.dart';
import 'package:flame/src/canvas3d/mesh_3d.dart';
import 'package:flame/src/canvas3d/raycast_3d.dart';
import 'package:flame/src/components/core/component.dart';
import 'package:flame/src/extensions/vector2.dart';
import 'package:meta/meta.dart';

/// Projects a 2D viewport & world pointer position into a 3D world-space
/// picking [Ray3D] for a `CameraComponent`.
typedef CameraRayProjector3D = Ray3D? Function(
  Vector2 viewportPoint,
  Vector2 worldPoint,
);

/// Mixin enabling a [Component] inside a `World` to participate in `O(k)`
/// indexed 3D raycast event picking (`TapCallbacks`, `HoverCallbacks`,
/// `DragCallbacks`, `DropTargetCallbacks`) ordered by true camera ray distance
/// `t` when `CameraComponent.rayProjector3D` is configured.
mixin SpatialHitbox3D on Component {
  /// Whether 3D ray hit-testing is enabled on this component.
  bool spatialHitEnabled = true;

  double? _lastHitDistance3D;
  (double, double, double)? _lastHitPoint3D;
  bool _isActiveSpatialRayHit = false;
  World? _registeredSpatialWorld;

  /// Optional world-space `(cx, cy, cz, radius)` 3D bounding sphere checked in
  /// `O(1)` before invoking [intersectRay3D] (for example to skip expensive
  /// Möller–Trumbore triangle mesh raycasts on misses).
  (double cx, double cy, double cz, double radius)? get boundingSphere3D =>
      null;

  /// Distance `t` along the camera ray from the most recent successful 3D hit.
  double? get lastHitDistance3D => _lastHitDistance3D;

  /// World `(x, y, z)` coordinates of the most recent successful 3D hit.
  (double, double, double)? get lastHitPoint3D => _lastHitPoint3D;

  /// Whether the currently dispatching pointer/hover/drop event matched this
  /// component via a 3D ray intersection rather than 2D bounds.
  @internal
  bool get isActiveSpatialRayHit => _isActiveSpatialRayHit;

  @internal
  set isActiveSpatialRayHit(bool value) => _isActiveSpatialRayHit = value;

  @override
  @mustCallSuper
  void onMount() {
    super.onMount();
    var cursor = parent;
    while (cursor != null) {
      if (cursor is World) {
        _registeredSpatialWorld = cursor;
        cursor.registerSpatialHitbox3D(this);
        break;
      }
      cursor = cursor.parent;
    }
  }

  @override
  @mustCallSuper
  void onRemove() {
    _registeredSpatialWorld?.unregisterSpatialHitbox3D(this);
    _registeredSpatialWorld = null;
    super.onRemove();
  }

  /// Records hit metadata when picked by `CameraComponent`.
  @internal
  void recordSpatialHit3D(Ray3D ray, double distance) {
    _lastHitDistance3D = distance;
    _lastHitPoint3D = ray.pointAt(distance);
  }

  /// Returns the non-negative ray distance `t` if [ray] intersects this
  /// component's 3D volume/mesh, or `null` on a miss.
  double? intersectRay3D(Ray3D ray);

  /// Convenience helper intersecting [ray] against a world-space 3D AABB.
  @protected
  double? intersectWorldAabb3D(
    Ray3D ray, {
    required double minX,
    required double minY,
    required double minZ,
    required double maxX,
    required double maxY,
    required double maxZ,
    double maxDistance = double.infinity,
  }) {
    return Raycaster3D.intersectAabbDistance(
      ray,
      minX: minX,
      minY: minY,
      minZ: minZ,
      maxX: maxX,
      maxY: maxY,
      maxZ: maxZ,
      maxDistance: maxDistance,
    );
  }

  /// Convenience helper intersecting [ray] against [mesh] using its flat
  /// `O(log T)` [Mesh3D.bvh] under full 3D rotation and non-uniform scale.
  @protected
  double? intersectMesh3D(
    Ray3D ray,
    Mesh3D mesh, {
    required double worldX,
    required double worldY,
    double worldZ = 0.0,
    double scaleX = 1.0,
    double scaleY = 1.0,
    double scaleZ = 1.0,
    double yawRad = 0.0,
    double pitchRad = 0.0,
    double rollRad = 0.0,
    (double, double, double, double)? rotationQuat,
    Float32List? rotationMatrix3,
    double maxDistance = double.infinity,
    bool cullBackfaces = true,
  }) {
    final hit = Raycaster3D.raycastMeshTransform(
      ray,
      mesh,
      worldX: worldX,
      worldY: worldY,
      worldZ: worldZ,
      scaleX: scaleX,
      scaleY: scaleY,
      scaleZ: scaleZ,
      yawRad: yawRad,
      pitchRad: pitchRad,
      rollRad: rollRad,
      rotationQuat: rotationQuat,
      rotationMatrix3: rotationMatrix3,
      maxDistance: maxDistance,
      cullBackfaces: cullBackfaces,
    );
    return hit?.$1;
  }
}
