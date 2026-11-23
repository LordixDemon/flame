import 'package:flame/components.dart';
import 'package:flame_3d/camera.dart';
import 'package:meta/meta.dart';

/// Shared ancestor/explicit [CameraComponent3D] lookup helpers for camera rig
/// components ([CameraDollyTrack3D], [CameraShake3D],
/// [OrbitCameraController3D], [SpringArmCamera3D]).
@internal
mixin CameraRigSupport on Component {
  /// Explicit camera passed to the rig constructor, if any.
  @protected
  CameraComponent3D? get explicitCamera;

  CameraComponent3D? _mountedCamera;

  /// Clears any cached ancestor camera reference (call from `onMount`).
  @protected
  void resetMountedCamera() {
    _mountedCamera = null;
  }

  /// Resolves [explicitCamera], cached ancestor camera, or first ancestor
  /// [CameraComponent3D] without throwing.
  @protected
  CameraComponent3D? resolveCamera() {
    if (explicitCamera case final explicit?) {
      return explicit;
    }
    if (_mountedCamera case final mounted?) {
      return mounted;
    }
    for (final ancestor in ancestors()) {
      if (ancestor is CameraComponent3D) {
        return _mountedCamera = ancestor;
      }
    }
    return null;
  }

  /// Resolves the active [CameraComponent3D] or throws a clear [StateError]
  /// naming [componentName].
  @protected
  CameraComponent3D requireCamera(String componentName) {
    final resolved = resolveCamera();
    if (resolved == null) {
      throw StateError(
        '$componentName requires a CameraComponent3D passed to its '
        'constructor or present as an ancestor.',
      );
    }
    return resolved;
  }
}

final Vector3 _zRef = Vector3(0, 0, 1);
final Vector3 _negYRef = Vector3(0, -1, 0);

/// Builds horizontal basis vectors [axisX] and [axisZ] perpendicular to unit
/// [upAxis] for orbit and spring-arm camera rigs.
@internal
void buildCameraHorizontalFrame(
  Vector3 upAxis,
  Vector3 axisX,
  Vector3 axisZ,
) {
  final ref = upAxis.z.abs() < 0.9 ? _zRef : _negYRef;
  upAxis.crossInto(ref, axisX);
  axisX.normalize();
  axisX.crossInto(upAxis, axisZ);
  axisZ.normalize();
}
