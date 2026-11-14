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

/// Mixin enabling a [Component] inside a `World` to participate in 3D raycast
/// event picking (`TapCallbacks`, `HoverCallbacks`, `DragCallbacks`) ordered
/// by true camera ray distance `t` when `CameraComponent.rayProjector3D` is
/// configured.
mixin SpatialHitbox3D on Component {
  /// Whether 3D ray hit-testing is enabled on this component.
  bool spatialHitEnabled = true;

  double? _lastHitDistance3D;
  (double, double, double)? _lastHitPoint3D;
  bool _isActiveSpatialRayHit = false;

  /// Distance `t` along the camera ray from the most recent successful 3D hit.
  double? get lastHitDistance3D => _lastHitDistance3D;

  /// World `(x, y, z)` coordinates of the most recent successful 3D hit.
  (double, double, double)? get lastHitPoint3D => _lastHitPoint3D;

  /// Whether the currently dispatching pointer/hover event matched this
  /// component via a 3D ray intersection rather than 2D bounds.
  @internal
  bool get isActiveSpatialRayHit => _isActiveSpatialRayHit;

  @internal
  set isActiveSpatialRayHit(bool value) => _isActiveSpatialRayHit = value;

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
}
