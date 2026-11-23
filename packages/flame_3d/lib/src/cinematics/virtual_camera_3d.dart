import 'dart:math' as math;

import 'package:flame/components.dart' show Component, HasWorldRef;
import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/src/extensions/geometry_math.dart';
import 'package:flame_3d/src/parser/gltf/animation_interpolation.dart';
import 'package:flutter/animation.dart' show Curve, Curves;
import 'package:meta/meta.dart';

/// A prioritized virtual camera shot node in 3D space evaluated by a
/// [VirtualCameraBrain3D].
class VirtualCamera3D({
  int priority = 0,
  var bool enabled = true,
  var double fovY = 60.0,
  var Component3D? lookAtTarget,
  Vector3? lookAtOffset,
  var double damping = 0.0,
  var double blendWeight = 1.0,
  var double? blendDurationOverride,
  var Curve? blendCurveOverride,
  Vector3? up,
  super.position,
  super.rotation,
  super.scale,
  super.children,
  super.cameraMask,
}) extends Component3D {
  this {
    this.priority = priority;
  }

  /// World-space offset added to [lookAtTarget]'s origin when aiming.
  final Vector3 lookAtOffset = lookAtOffset?.clone() ?? Vector3.zero();

  /// Reference world up vector used when aiming at [lookAtTarget].
  final Vector3 up = (up?.clone() ?? Vector3(0.0, 1.0, 0.0))..normalize();

  final Vector3 _smoothedPos = Vector3.zero();
  final Quaternion _smoothedRot = Quaternion.identity();
  bool _hasSmoothed = false;

  final Vector3 _rawPos = Vector3.zero();
  final Quaternion _rawRot = Quaternion.identity();
  final Vector3 _aimTarget = Vector3.zero();
  final Vector3 _fwd = Vector3.zero();
  final Vector3 _right = Vector3.zero();
  final Vector3 _camUp = Vector3.zero();
  final Matrix3 _rotMat = Matrix3.identity();

  // The cameras mounted under each world, in the order they were mounted,
  // so that a brain finds them without walking the world.
  static final Expando<List<VirtualCamera3D>> _mountedByWorld = Expando();
  World3D? _mountedWorld;

  /// The [VirtualCamera3D]s mounted under [world], in the order they were
  /// mounted.
  @internal
  static List<VirtualCamera3D> mountedIn(World3D world) =>
      _mountedByWorld[world] ?? const [];

  @override
  void onMount() {
    super.onMount();
    final world = worldOrNull;
    if (world != null) {
      (_mountedByWorld[world] ??= []).add(this);
      _mountedWorld = world;
    }
  }

  @override
  void onRemove() {
    final world = _mountedWorld;
    if (world != null) {
      _mountedByWorld[world]?.remove(this);
      _mountedWorld = null;
    }
    super.onRemove();
  }

  /// Resets internal damping history so the next evaluation snaps immediately.
  void resetDampingState() {
    _hasSmoothed = false;
  }

  /// Evaluates this virtual camera's world eye position and right-handed
  /// orientation (looking down local `-Z`) into [outPos] and [outRot].
  void evaluateShotPose(double dt, Vector3 outPos, Quaternion outRot) {
    final wm = worldTransformMatrix;
    final s = wm.storage;
    _rawPos.setValues(s[12], s[13], s[14]);

    if (lookAtTarget case final targetComp?) {
      final ts = targetComp.worldTransformMatrix.storage;
      _aimTarget.setValues(
        ts[12] + lookAtOffset.x,
        ts[13] + lookAtOffset.y,
        ts[14] + lookAtOffset.z,
      );
      _fwd
        ..setFrom(_aimTarget)
        ..sub(_rawPos);
      if (_fwd.length2 > 1e-12) {
        _fwd.normalize();
        _right.setFrom(_fwd.cross(up));
        if (_right.length2 < 1e-10) {
          final fallbackUp = _fwd.y.abs() < 0.9
              ? Vector3(0.0, 1.0, 0.0)
              : Vector3(0.0, 0.0, 1.0);
          _right.setFrom(_fwd.cross(fallbackUp));
        }
        _right.normalize();
        _camUp
          ..setFrom(_right.cross(_fwd))
          ..normalize();
        // Right-handed view basis: +X = right, +Y = camUp, +Z = -fwd.
        _rotMat.setValues(
          _right.x,
          _right.y,
          _right.z,
          _camUp.x,
          _camUp.y,
          _camUp.z,
          -_fwd.x,
          -_fwd.y,
          -_fwd.z,
        );
        _rawRot.setFromRotation(_rotMat);
        if (_rawRot.length2 > 1e-12) {
          _rawRot.normalize();
        } else {
          _rawRot.setValues(0.0, 0.0, 0.0, 1.0);
        }
      } else {
        _extractWorldRotation(wm, _rawRot);
      }
    } else {
      _extractWorldRotation(wm, _rawRot);
    }

    if (damping > 0.0 && _hasSmoothed && dt > 0.0) {
      final alpha = (1.0 - math.exp(-damping * dt)).clamp(0.0, 1.0);
      _smoothedPos.setValues(
        _smoothedPos.x + (_rawPos.x - _smoothedPos.x) * alpha,
        _smoothedPos.y + (_rawPos.y - _smoothedPos.y) * alpha,
        _smoothedPos.z + (_rawPos.z - _smoothedPos.z) * alpha,
      );
      AnimationInterpolation.slerpQuaternionsInto(
        _smoothedRot,
        _rawRot,
        alpha,
        _smoothedRot,
      );
    } else {
      _smoothedPos.setFrom(_rawPos);
      _smoothedRot.setFrom(_rawRot);
      _hasSmoothed = true;
    }

    outPos.setFrom(_smoothedPos);
    outRot.setFrom(_smoothedRot);
  }

  static void _extractWorldRotation(Matrix4 m, Quaternion out) {
    final s = m.storage;
    var c0x = s[0];
    var c0y = s[1];
    var c0z = s[2];
    var c1x = s[4];
    var c1y = s[5];
    var c1z = s[6];
    var c2x = s[8];
    var c2y = s[9];
    var c2z = s[10];
    final l0 = math.sqrt(c0x * c0x + c0y * c0y + c0z * c0z);
    final l1 = math.sqrt(c1x * c1x + c1y * c1y + c1z * c1z);
    final l2 = math.sqrt(c2x * c2x + c2y * c2y + c2z * c2z);
    if (l0 > 1e-12) {
      c0x /= l0;
      c0y /= l0;
      c0z /= l0;
    }
    if (l1 > 1e-12) {
      c1x /= l1;
      c1y /= l1;
      c1z /= l1;
    }
    if (l2 > 1e-12) {
      c2x /= l2;
      c2y /= l2;
      c2z /= l2;
    }
    final mat = Matrix3(c0x, c0y, c0z, c1x, c1y, c1z, c2x, c2y, c2z);
    out.setFromRotation(mat);
    if (out.length2 > 1e-12) {
      out.normalize();
    } else {
      out.setValues(0.0, 0.0, 0.0, 1.0);
    }
  }
}

/// Director brain driving a [CameraComponent3D] from prioritized
/// [VirtualCamera3D] shots with smooth position, shortest-arc Quaternion SLERP,
/// and `fovY` cross-blending.
class VirtualCameraBrain3D({
  required final CameraComponent3D camera,
  List<VirtualCamera3D> cameras = const [],
  var double blendDuration = 0.5,
  var Curve blendCurve = Curves.easeInOut,
  var World3D? world,
  super.priority,
}) extends Component with HasWorldRef<World3D> {
  this {
    _registered.addAll(cameras);
  }

  final List<VirtualCamera3D> _registered = [];
  final List<VirtualCamera3D> _candidates = [];

  VirtualCamera3D? _activeCamera;
  VirtualCamera3D? _previousCamera;

  final Vector3 _currentPos = Vector3.zero();
  final Quaternion _currentRot = Quaternion.identity();
  double _currentFovY = 60.0;
  bool _hasCurrent = false;

  final Vector3 _fromPos = Vector3.zero();
  final Quaternion _fromRot = Quaternion.identity();
  double _fromFovY = 60.0;

  double _activeBlendDuration = 0.0;
  double _blendElapsed = 0.0;
  Curve _activeCurve = Curves.easeInOut;

  final Vector3 _goalPos = Vector3.zero();
  final Quaternion _goalRot = Quaternion.identity();
  final Vector3 _fwdScratch = Vector3.zero();
  final Vector3 _upScratch = Vector3.zero();

  /// Currently winning [VirtualCamera3D], or `null` when none are enabled.
  VirtualCamera3D? get activeCamera => _activeCamera;

  /// Outgoing [VirtualCamera3D] during an active cross-blend, or `null`.
  VirtualCamera3D? get previousCamera => _previousCamera;

  /// Whether a camera-to-camera cross-blend is currently in progress.
  bool get isBlending =>
      _activeBlendDuration > 0.0 && _blendElapsed < _activeBlendDuration;

  /// Normalized `[0, 1]` progress of the active cross-blend (`1` if settled).
  double get blendProgress => _activeBlendDuration > 1e-9
      ? (_blendElapsed / _activeBlendDuration).clamp(0.0, 1.0)
      : 1.0;

  /// Explicitly registers [vcam] with this brain (in addition to any mounted
  /// [VirtualCamera3D]s discovered in [World3D]).
  void registerCamera(VirtualCamera3D vcam) {
    if (!_registered.contains(vcam)) {
      _registered.add(vcam);
    }
  }

  /// Unregisters [vcam] from this brain.
  void unregisterCamera(VirtualCamera3D vcam) {
    _registered.remove(vcam);
  }

  @override
  void update(double dt) {
    super.update(dt);
    evaluate(dt);
  }

  /// Evaluates all candidate [VirtualCamera3D]s, selects the highest-priority
  /// enabled shot, advances any cross-blend by [dt], and writes the resulting
  /// pose & `fovY` onto [camera].
  void evaluate(double dt) {
    _collectCandidates(_candidates);
    VirtualCamera3D? winner;
    for (var i = 0; i < _candidates.length; i++) {
      final c = _candidates[i];
      if (!c.enabled || c.blendWeight <= 0.0) {
        continue;
      }
      if (winner == null || c.priority > winner.priority) {
        winner = c;
      }
    }

    if (winner == null) {
      _activeCamera = null;
      _previousCamera = null;
      _activeBlendDuration = 0.0;
      _blendElapsed = 0.0;
      return;
    }

    if (!identical(winner, _activeCamera)) {
      final hadPrevious = _activeCamera != null && _hasCurrent;
      _previousCamera = _activeCamera;
      _activeCamera = winner;

      if (hadPrevious) {
        _fromPos.setFrom(_currentPos);
        _fromRot.setFrom(_currentRot);
        _fromFovY = _currentFovY;
        _activeBlendDuration = math.max(
          0.0,
          winner.blendDurationOverride ?? blendDuration,
        );
        _activeCurve = winner.blendCurveOverride ?? blendCurve;
        _blendElapsed = 0.0;
      } else {
        // Seed baseline from output camera when blendWeight < 1, otherwise cut.
        _fromPos.setFrom(camera.position);
        _fromRot.setFrom(camera.rotation);
        _fromFovY = camera.fovY;
        _activeBlendDuration = 0.0;
        _blendElapsed = 0.0;
      }
    }

    winner.evaluateShotPose(dt, _goalPos, _goalRot);
    final goalFov = winner.fovY;
    final weight = winner.blendWeight.clamp(0.0, 1.0);

    double t;
    if (_activeBlendDuration > 1e-9) {
      if (dt > 0.0) {
        _blendElapsed = math.min(_activeBlendDuration, _blendElapsed + dt);
      }
      final raw = (_blendElapsed / _activeBlendDuration).clamp(0.0, 1.0);
      t = _activeCurve.transform(raw).clamp(0.0, 1.0) * weight;
      if (_blendElapsed >= _activeBlendDuration) {
        _activeBlendDuration = 0.0;
        _previousCamera = null;
      }
    } else {
      t = weight;
    }

    if (!_hasCurrent || t >= 1.0 - 1e-7) {
      _currentPos.setFrom(_goalPos);
      _currentRot.setFrom(_goalRot);
      _currentFovY = goalFov;
    } else {
      _currentPos.setValues(
        _fromPos.x + (_goalPos.x - _fromPos.x) * t,
        _fromPos.y + (_goalPos.y - _fromPos.y) * t,
        _fromPos.z + (_goalPos.z - _fromPos.z) * t,
      );
      AnimationInterpolation.slerpQuaternionsInto(
        _fromRot,
        _goalRot,
        t,
        _currentRot,
      );
      _currentFovY = _fromFovY + (goalFov - _fromFovY) * t;
    }
    _hasCurrent = true;

    _applyToOutputCamera();
  }

  void _applyToOutputCamera() {
    _fwdScratch.setValues(0.0, 0.0, -1.0);
    rotateVectorByQuat(_currentRot, _fwdScratch, _fwdScratch);
    _upScratch.setValues(0.0, 1.0, 0.0);
    rotateVectorByQuat(_currentRot, _upScratch, _upScratch);

    camera.position.setFrom(_currentPos);
    camera.target.setValues(
      _currentPos.x + _fwdScratch.x,
      _currentPos.y + _fwdScratch.y,
      _currentPos.z + _fwdScratch.z,
    );
    camera.up = _upScratch;
    camera.rotation.setFrom(_currentRot);
    camera.fovY = _currentFovY;
  }

  void _collectCandidates(List<VirtualCamera3D> out) {
    out
      ..clear()
      ..addAll(_registered);

    var rootWorld = world ?? camera.world;
    if (rootWorld == null && isMounted) {
      for (final anc in ancestors()) {
        if (anc is World3D) {
          rootWorld = anc;
          break;
        }
      }
    }
    if (rootWorld != null) {
      final registered = _registered;
      for (final c in VirtualCamera3D.mountedIn(rootWorld)) {
        if (registered.isEmpty || !registered.contains(c)) {
          out.add(c);
        }
      }
    }
  }
}
