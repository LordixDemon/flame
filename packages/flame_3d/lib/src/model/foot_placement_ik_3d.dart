part of 'foot_ik_and_ragdoll_3d.dart';

/// World-space surface contact returned to [FootPlacementIk3D]'s ground query.
class GroundHit3D({
  required final Vector3 point,
  required final Vector3 normal,
  final double? distance,
});

/// Ground raycast callback signature used by [FootPlacementIk3D].
typedef GroundRaycastCallback3D = GroundHit3D? Function(
  Vector3 rayOrigin,
  double maxDist,
);

/// Terrain-adaptive biped foot-placement IK modifier.
///
/// Raycasts beneath both feet, smoothly damps vertical pelvis offset
/// ([hipsOffsetY]) so the lower foot reaches down slopes/stairs without
/// hyperextending, solves 2-bone knee IK for both legs, and tilts ankles to
/// match ground surface normals.
class FootPlacementIk3D({
  required final int hipsNodeIndex,
  required final (int thigh, int calf, int foot) leftLeg,
  required final (int thigh, int calf, int foot) rightLeg,
  required final GroundRaycastCallback3D groundQuery,
  var double rayOriginHeight = 0.6,
  var double rayMaxDistance = 1.5,
  var double footHeightOffset = 0.0,
  var double maxHipsDrop = 0.5,
  var double pelvisSmoothing = 14.0,
  var double maxFootTiltRad = 0.75,
  Vector3? kneeForwardModel,
  double weight = 1.0,
}) extends BoneModifier3D {
  /// Constructs a [FootPlacementIk3D] from mapped leg/pelvis slots on
  /// [profile].
  factory FootPlacementIk3D.fromHumanoid(
    HumanoidProfile3D profile, {
    required GroundRaycastCallback3D groundQuery,
    double rayOriginHeight = 0.6,
    double rayMaxDistance = 1.5,
    double footHeightOffset = 0.0,
    double maxHipsDrop = 0.5,
    double pelvisSmoothing = 14.0,
    double maxFootTiltRad = 0.75,
    Vector3? kneeForwardModel,
    double weight = 1.0,
  }) {
    int req(HumanoidBone3D b) {
      final idx = profile.nodeIndexFor(b);
      if (idx == null) {
        throw ArgumentError(
          'HumanoidProfile3D missing required bone ${b.name}',
        );
      }
      return idx;
    }

    return FootPlacementIk3D(
      hipsNodeIndex: req(HumanoidBone3D.hips),
      leftLeg: (
        req(HumanoidBone3D.leftUpperLeg),
        req(HumanoidBone3D.leftLowerLeg),
        req(HumanoidBone3D.leftFoot),
      ),
      rightLeg: (
        req(HumanoidBone3D.rightUpperLeg),
        req(HumanoidBone3D.rightLowerLeg),
        req(HumanoidBone3D.rightFoot),
      ),
      groundQuery: groundQuery,
      rayOriginHeight: rayOriginHeight,
      rayMaxDistance: rayMaxDistance,
      footHeightOffset: footHeightOffset,
      maxHipsDrop: maxHipsDrop,
      pelvisSmoothing: pelvisSmoothing,
      maxFootTiltRad: maxFootTiltRad,
      kneeForwardModel: kneeForwardModel,
      weight: weight,
    );
  }

  this {
    this.weight = weight;
  }

  /// Model-space forward pole direction steering knee bend (`+Z` by default).
  final Vector3 kneeForwardModel =
      (kneeForwardModel?.clone() ?? Vector3(0.0, 0.0, 1.0))..normalize();

  double _hipsOffsetY = 0.0;

  /// Current smoothed vertical pelvis offset in world units (`<= 0` when
  /// dropping pelvis so the lower leg reaches down a slope/step).
  double get hipsOffsetY => _hipsOffsetY;

  /// Resets smoothed pelvis offset to `0`.
  void reset() {
    _hipsOffsetY = 0.0;
  }

  final Vector3 _footWorldL = Vector3.zero();
  final Vector3 _footWorldR = Vector3.zero();
  final Vector3 _rayOrigin = Vector3.zero();
  final Vector3 _pelvisWorld = Vector3.zero();
  final Vector3 _pelvisModelNext = Vector3.zero();
  final Vector3 _upModel = Vector3.zero();
  final Vector3 _normalModel = Vector3.zero();
  final Vector3 _targetFootWorld = Vector3.zero();
  final Vector3 _poleWorld = Vector3.zero();
  final Vector3 _kneeWorld = Vector3.zero();
  final Quaternion _footQ = Quaternion.identity();
  final Matrix4 _oldMat = Matrix4.identity();

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

    final hipsNode = workspace.nodesByIndex[hipsNodeIndex];
    final lFootNode = workspace.nodesByIndex[leftLeg.$3];
    final rFootNode = workspace.nodesByIndex[rightLeg.$3];
    if (hipsNode == null || lFootNode == null || rFootNode == null) {
      return;
    }

    // 1. Sample animated foot world positions & cast downward ground rays.
    final lfm = lFootNode.combinedTransform.storage;
    _footWorldL.setValues(lfm[12], lfm[13], lfm[14]);
    worldMatrix.transform3(_footWorldL);

    final rfm = rFootNode.combinedTransform.storage;
    _footWorldR.setValues(rfm[12], rfm[13], rfm[14]);
    worldMatrix.transform3(_footWorldR);

    final rootWorldY = worldMatrix.storage[13];
    final animLiftL = math.max(
      0.0,
      _footWorldL.y - (rootWorldY + footHeightOffset),
    );
    final animLiftR = math.max(
      0.0,
      _footWorldR.y - (rootWorldY + footHeightOffset),
    );

    _rayOrigin.setValues(
      _footWorldL.x,
      _footWorldL.y + rayOriginHeight,
      _footWorldL.z,
    );
    final hitL = groundQuery(_rayOrigin, rayOriginHeight + rayMaxDistance);

    _rayOrigin.setValues(
      _footWorldR.x,
      _footWorldR.y + rayOriginHeight,
      _footWorldR.z,
    );
    final hitR = groundQuery(_rayOrigin, rayOriginHeight + rayMaxDistance);

    if (hitL == null && hitR == null) {
      final damp = dt > 0.0
          ? (1.0 - math.exp(-pelvisSmoothing * dt)).clamp(0.0, 1.0)
          : 1.0;
      _hipsOffsetY += (0.0 - _hipsOffsetY) * damp;
      return;
    }

    final targetYL = hitL != null
        ? hitL.point.y + footHeightOffset + animLiftL
        : _footWorldL.y;
    final targetYR = hitR != null
        ? hitR.point.y + footHeightOffset + animLiftR
        : _footWorldR.y;

    final deltaYL = hitL != null ? targetYL - _footWorldL.y : 0.0;
    final deltaYR = hitR != null ? targetYR - _footWorldR.y : 0.0;

    final rawPelvisShift = math.min(0.0, math.min(deltaYL, deltaYR));
    final desiredOffset = (rawPelvisShift * w).clamp(-maxHipsDrop, 0.0);

    final alpha = dt > 0.0 && pelvisSmoothing > 0.0
        ? (1.0 - math.exp(-pelvisSmoothing * dt)).clamp(0.0, 1.0)
        : 1.0;
    _hipsOffsetY += (desiredOffset - _hipsOffsetY) * alpha;

    // 2. Shift pelvis vertically in world space and propagate to leg subtrees.
    if (_hipsOffsetY.abs() > 1e-6) {
      final hm = hipsNode.combinedTransform;
      _oldMat.setFrom(hm);
      _pelvisWorld.setValues(hm.storage[12], hm.storage[13], hm.storage[14]);
      worldMatrix.transform3(_pelvisWorld);
      _pelvisWorld.y += _hipsOffsetY;
      _pelvisModelNext.setFrom(_pelvisWorld);
      invWorldMatrix.transform3(_pelvisModelNext);
      hm.storage[12] = _pelvisModelNext.x;
      hm.storage[13] = _pelvisModelNext.y;
      hm.storage[14] = _pelvisModelNext.z;
      BoneModifier3D.propagateDeltaToDescendants(
        model,
        workspace,
        hipsNodeIndex,
        _oldMat,
        hm,
      );
    }

    // 3. Solve 2-bone knee IK + ground normal foot alignment for each leg.
    if (hitL != null) {
      _solveLegAndFoot(
        model: model,
        workspace: workspace,
        worldMatrix: worldMatrix,
        invWorldMatrix: invWorldMatrix,
        leg: leftLeg,
        footTargetWorldX: _footWorldL.x,
        footTargetWorldY: targetYL,
        footTargetWorldZ: _footWorldL.z,
        groundNormalWorld: hitL.normal,
        blendWeight: w,
      );
    }
    if (hitR != null) {
      _solveLegAndFoot(
        model: model,
        workspace: workspace,
        worldMatrix: worldMatrix,
        invWorldMatrix: invWorldMatrix,
        leg: rightLeg,
        footTargetWorldX: _footWorldR.x,
        footTargetWorldY: targetYR,
        footTargetWorldZ: _footWorldR.z,
        groundNormalWorld: hitR.normal,
        blendWeight: w,
      );
    }
  }

  void _solveLegAndFoot({
    required Model model,
    required ModelPoseWorkspace workspace,
    required Matrix4 worldMatrix,
    required Matrix4 invWorldMatrix,
    required (int thigh, int calf, int foot) leg,
    required double footTargetWorldX,
    required double footTargetWorldY,
    required double footTargetWorldZ,
    required Vector3 groundNormalWorld,
    required double blendWeight,
  }) {
    final thighNode = workspace.nodesByIndex[leg.$1];
    final calfNode = workspace.nodesByIndex[leg.$2];
    final footNode = workspace.nodesByIndex[leg.$3];
    if (thighNode == null || calfNode == null || footNode == null) {
      return;
    }

    final cm = calfNode.combinedTransform.storage;
    _kneeWorld.setValues(
      cm[12] + kneeForwardModel.x * 1.5,
      cm[13] + kneeForwardModel.y * 1.5,
      cm[14] + kneeForwardModel.z * 1.5,
    );
    worldMatrix.transform3(_kneeWorld);
    _poleWorld.setFrom(_kneeWorld);
    _targetFootWorld.setValues(
      footTargetWorldX,
      footTargetWorldY,
      footTargetWorldZ,
    );

    BoneModifier3D.solveTwoBoneIk(
      model: model,
      workspace: workspace,
      invWorldMatrix: invWorldMatrix,
      rootIndex: leg.$1,
      midIndex: leg.$2,
      tipIndex: leg.$3,
      targetWorld: _targetFootWorld,
      poleWorld: _poleWorld,
      blendWeight: blendWeight,
    );

    // Align foot orientation to ground normal.
    _upModel.setValues(0.0, 1.0, 0.0);
    invWorldMatrix.rotate3(_upModel);
    _normalModel.setFrom(groundNormalWorld);
    invWorldMatrix.rotate3(_normalModel);
    if (_upModel.length2 > 1e-10 && _normalModel.length2 > 1e-10) {
      _upModel.normalize();
      _normalModel.normalize();
      final fm = footNode.combinedTransform;
      _oldMat.setFrom(fm);
      BoneModifier3D.swingRotationInto(
        _upModel,
        _normalModel,
        _footQ,
        maxAngle: maxFootTiltRad,
        blendWeight: blendWeight,
      );
      BoneModifier3D.rotateCombinedAroundOrigin(fm, _footQ);
      BoneModifier3D.propagateDeltaToDescendants(
        model,
        workspace,
        leg.$3,
        _oldMat,
        fm,
      );
    }
  }
}
