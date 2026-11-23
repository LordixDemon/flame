part of 'procedural_rigging_3d.dart';

/// Smoothly rotates a bone (such as a head, turret, or eye) so its local
/// [forwardAxis] aims toward [targetWorld], clamped to [maxAngle] radians.
class LookAtConstraint3D({
  required final String nodeName,
  Vector3? targetWorld,
  Vector3? forwardAxis,
  var double maxAngle = 1.25,
  double weight = 1.0,
}) extends BoneModifier3D {
  this {
    this.weight = weight;
  }

  /// World-space point to aim at.
  final Vector3 targetWorld = targetWorld?.clone() ?? Vector3.zero();

  /// Bone-local axis pointing forward (`(0, 0, 1)` by default).
  final Vector3 forwardAxis = (forwardAxis?.clone() ?? Vector3(0, 0, 1))
    ..normalize();

  int? _cachedIndex;
  final Vector3 _targetModel = Vector3.zero();
  final Vector3 _origin = Vector3.zero();
  final Vector3 _curForward = Vector3.zero();
  final Vector3 _desired = Vector3.zero();
  final Quaternion _deltaQ = Quaternion.identity();

  @override
  void apply(
    Model model,
    ModelPoseWorkspace workspace,
    Matrix4 worldMatrix,
    Matrix4 invWorldMatrix,
    double dt,
  ) {
    if (weight <= 0.0) {
      return;
    }
    final idx = _cachedIndex ??= model.nodeIndexByName(nodeName);
    if (idx == null) {
      return;
    }
    final processed = workspace.nodesByIndex[idx];
    if (processed == null) {
      return;
    }

    final m = processed.combinedTransform;
    _origin.setValues(m.storage[12], m.storage[13], m.storage[14]);

    _targetModel.setFrom(targetWorld);
    invWorldMatrix.transform3(_targetModel);
    _desired
      ..setFrom(_targetModel)
      ..sub(_origin);
    final dist2 = _desired.length2;
    if (dist2 < 1e-10) {
      return;
    }
    _desired.scale(1.0 / math.sqrt(dist2));

    _curForward.setFrom(forwardAxis);
    m.rotate3(_curForward);
    final fLen2 = _curForward.length2;
    if (fLen2 < 1e-10) {
      return;
    }
    _curForward.scale(1.0 / math.sqrt(fLen2));

    BoneModifier3D.swingRotationInto(
      _curForward,
      _desired,
      _deltaQ,
      maxAngle: maxAngle,
      blendWeight: weight,
    );
    BoneModifier3D.rotateAndPropagateToDescendants(workspace, idx, m, _deltaQ);
  }
}

/// Damped Hooke-spring secondary-motion bone modifier for hair, capes, tails,
/// antennas, and foliage attachments.
class SpringBone3D({
  required final String nodeName,
  Vector3? localTipOffset,
  var double stiffness = 180.0,
  var double damping = 14.0,
  Vector3? gravity,
  var double maxAngle = 0.85,
  double weight = 1.0,
}) extends BoneModifier3D {
  this {
    this.weight = weight;
  }

  /// Bone-local vector from the bone pivot to its simulated tip.
  final Vector3 localTipOffset = localTipOffset?.clone() ?? Vector3(0, 0.5, 0);

  /// Constant world-space acceleration (such as gravity or wind) pulling the
  /// simulated tip.
  final Vector3 gravity = gravity?.clone() ?? Vector3.zero();

  int? _cachedIndex;
  bool _initialized = false;
  final Vector3 _simTipWorld = Vector3.zero();
  final Vector3 _velWorld = Vector3.zero();

  final Vector3 _pivotModel = Vector3.zero();
  final Vector3 _pivotWorld = Vector3.zero();
  final Vector3 _restTipModel = Vector3.zero();
  final Vector3 _restTipWorld = Vector3.zero();
  final Vector3 _simTipModel = Vector3.zero();
  final Vector3 _fromDir = Vector3.zero();
  final Vector3 _toDir = Vector3.zero();
  final Quaternion _deltaQ = Quaternion.identity();

  /// Resets the spring tip to rest on the next evaluation.
  void reset() {
    _initialized = false;
    _velWorld.setZero();
  }

  /// Current world-space position of the simulated spring tip.
  Vector3 get currentTipWorld => _simTipWorld;

  @override
  void apply(
    Model model,
    ModelPoseWorkspace workspace,
    Matrix4 worldMatrix,
    Matrix4 invWorldMatrix,
    double dt,
  ) {
    if (weight <= 0.0) {
      return;
    }
    final idx = _cachedIndex ??= model.nodeIndexByName(nodeName);
    if (idx == null) {
      return;
    }
    final processed = workspace.nodesByIndex[idx];
    if (processed == null) {
      return;
    }

    final m = processed.combinedTransform;
    _pivotModel.setValues(m.storage[12], m.storage[13], m.storage[14]);
    _restTipModel.setFrom(localTipOffset);
    m.transform3(_restTipModel);

    _pivotWorld.setFrom(_pivotModel);
    worldMatrix.transform3(_pivotWorld);
    _restTipWorld.setFrom(_restTipModel);
    worldMatrix.transform3(_restTipWorld);

    final rodLen = _restTipWorld.distanceTo(_pivotWorld);
    if (rodLen < 1e-6) {
      return;
    }

    if (!_initialized) {
      _simTipWorld.setFrom(_restTipWorld);
      _velWorld.setZero();
      _initialized = true;
      return;
    }

    final stepDt = dt.clamp(0.0, 0.05);
    if (stepDt > 0.0) {
      final ax =
          (_restTipWorld.x - _simTipWorld.x) * stiffness +
          gravity.x -
          _velWorld.x * damping;
      final ay =
          (_restTipWorld.y - _simTipWorld.y) * stiffness +
          gravity.y -
          _velWorld.y * damping;
      final az =
          (_restTipWorld.z - _simTipWorld.z) * stiffness +
          gravity.z -
          _velWorld.z * damping;

      _velWorld.setValues(
        _velWorld.x + ax * stepDt,
        _velWorld.y + ay * stepDt,
        _velWorld.z + az * stepDt,
      );
      _simTipWorld.setValues(
        _simTipWorld.x + _velWorld.x * stepDt,
        _simTipWorld.y + _velWorld.y * stepDt,
        _simTipWorld.z + _velWorld.z * stepDt,
      );

      // Distance constraint keeps the bone length invariant.
      final dx = _simTipWorld.x - _pivotWorld.x;
      final dy = _simTipWorld.y - _pivotWorld.y;
      final dz = _simTipWorld.z - _pivotWorld.z;
      final dLen = math.sqrt(dx * dx + dy * dy + dz * dz);
      if (dLen > 1e-6) {
        final s = rodLen / dLen;
        _simTipWorld.setValues(
          _pivotWorld.x + dx * s,
          _pivotWorld.y + dy * s,
          _pivotWorld.z + dz * s,
        );
      } else {
        _simTipWorld.setFrom(_restTipWorld);
      }
    }

    _simTipModel.setFrom(_simTipWorld);
    invWorldMatrix.transform3(_simTipModel);

    _fromDir
      ..setFrom(_restTipModel)
      ..sub(_pivotModel);
    _toDir
      ..setFrom(_simTipModel)
      ..sub(_pivotModel);
    if (_fromDir.length2 < 1e-10 || _toDir.length2 < 1e-10) {
      return;
    }
    _fromDir.normalize();
    _toDir.normalize();

    BoneModifier3D.swingRotationInto(
      _fromDir,
      _toDir,
      _deltaQ,
      maxAngle: maxAngle,
      blendWeight: weight,
    );
    BoneModifier3D.rotateAndPropagateToDescendants(workspace, idx, m, _deltaQ);
  }
}

/// Analytic Law-of-Cosines two-bone Inverse Kinematics solver for limbs
/// (`root` -> `mid` -> `tip`, such as shoulder-elbow-hand or hip-knee-foot)
/// with a world-space [poleWorld] bend-direction hint.
class TwoBoneIkConstraint3D({
  required final String rootNodeName,
  required final String midNodeName,
  required final String tipNodeName,
  Vector3? targetWorld,
  Vector3? poleWorld,
  double weight = 1.0,
}) extends BoneModifier3D {
  this {
    this.weight = weight;
  }

  /// Desired world-space position of the `tip` joint.
  final Vector3 targetWorld = targetWorld?.clone() ?? Vector3.zero();

  /// World-space pole target steering the knee/elbow bend plane.
  final Vector3 poleWorld = poleWorld?.clone() ?? Vector3(0, 0, 1);

  int? _rootIdx;
  int? _midIdx;
  int? _tipIdx;

  @override
  void apply(
    Model model,
    ModelPoseWorkspace workspace,
    Matrix4 worldMatrix,
    Matrix4 invWorldMatrix,
    double dt,
  ) {
    final w = weight.clamp(0.0, 1.0);
    if (w <= 0.0) {
      return;
    }
    final rIdx = _rootIdx ??= model.nodeIndexByName(rootNodeName);
    final mIdx = _midIdx ??= model.nodeIndexByName(midNodeName);
    final tIdx = _tipIdx ??= model.nodeIndexByName(tipNodeName);
    if (rIdx == null || mIdx == null || tIdx == null) {
      return;
    }
    BoneModifier3D.solveTwoBoneIk(
      model: model,
      workspace: workspace,
      invWorldMatrix: invWorldMatrix,
      rootIndex: rIdx,
      midIndex: mIdx,
      tipIndex: tIdx,
      targetWorld: targetWorld,
      poleWorld: poleWorld,
      blendWeight: w,
    );
  }
}
