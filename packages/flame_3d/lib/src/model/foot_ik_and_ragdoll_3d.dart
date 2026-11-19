import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame_3d/collisions.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/model.dart';
import 'package:flame_3d/physics.dart';

/// Forward-And-Backward Reaching Inverse Kinematics (`FABRIK`) solver for
/// arbitrary `N`-bone chains (`chainNodeIndices.length >= 2`) with optional
/// per-joint angular cone limits.
class FabrikIkConstraint3D({
  required List<int> chainNodeIndices,
  Vector3? targetPosition,
  var int maxIterations = 12,
  var double tolerance = 1e-3,
  var double? maxConeAngleRad,
  List<double>? jointMaxConeAnglesRad,
  double weight = 1.0,
}) extends BoneModifier3D {
  /// Resolves [chainNodeNames] against [model] and constructs a
  /// [FabrikIkConstraint3D].
  factory FabrikIkConstraint3D.byNames({
    required Model model,
    required List<String> chainNodeNames,
    Vector3? targetPosition,
    int maxIterations = 12,
    double tolerance = 1e-3,
    double? maxConeAngleRad,
    List<double>? jointMaxConeAnglesRad,
    double weight = 1.0,
  }) {
    final indices = <int>[];
    for (final name in chainNodeNames) {
      final idx = model.nodeIndexByName(name);
      if (idx == null) {
        throw ArgumentError('Model does not contain bone "$name"');
      }
      indices.add(idx);
    }
    return FabrikIkConstraint3D(
      chainNodeIndices: indices,
      targetPosition: targetPosition,
      maxIterations: maxIterations,
      tolerance: tolerance,
      maxConeAngleRad: maxConeAngleRad,
      jointMaxConeAnglesRad: jointMaxConeAnglesRad,
      weight: weight,
    );
  }

  this
    : assert(
        chainNodeIndices.length >= 2,
        'chainNodeIndices must contain at least 2 joints',
      ),
      assert(maxIterations >= 1, 'maxIterations must be >= 1'),
      assert(tolerance >= 0, 'tolerance must be non-negative') {
    this.weight = weight;
  }

  /// Ordered node indices from chain root (`0`) to end-effector (`N - 1`).
  final List<int> chainNodeIndices = List<int>.unmodifiable(chainNodeIndices);

  /// World-space target position for the tip (`chainNodeIndices.last`).
  final Vector3 targetPosition = targetPosition?.clone() ?? Vector3.zero();

  /// Optional per-joint maximum bend angle in radians (falls back to
  /// [maxConeAngleRad] when `null` or shorter than the chain).
  final List<double>? jointMaxConeAnglesRad = jointMaxConeAnglesRad != null
      ? List<double>.unmodifiable(jointMaxConeAnglesRad)
      : null;

  late final Float64List _pos = Float64List(chainNodeIndices.length * 3);
  late final Float64List _origPos = Float64List(
    chainNodeIndices.length * 3,
  );
  late final Float64List _lengths = Float64List(
    chainNodeIndices.length - 1,
  );

  final Vector3 _targetM = Vector3.zero();
  final Vector3 _axisDir = Vector3.zero();
  final Vector3 _candDir = Vector3.zero();
  final Vector3 _perp = Vector3.zero();
  final Vector3 _fromDir = Vector3.zero();
  final Vector3 _toDir = Vector3.zero();
  final Quaternion _deltaQ = Quaternion.identity();
  final Matrix4 _oldCombined = Matrix4.identity();

  double? _coneLimitAt(int jointIdx) {
    final perJoint = jointMaxConeAnglesRad;
    if (perJoint != null && jointIdx < perJoint.length) {
      return perJoint[jointIdx];
    }
    return maxConeAngleRad;
  }

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

    final n = chainNodeIndices.length;
    for (var i = 0; i < n; i++) {
      final node = workspace.nodesByIndex[chainNodeIndices[i]];
      if (node == null) {
        return;
      }
      final s = node.combinedTransform.storage;
      final o = i * 3;
      _pos[o] = s[12];
      _pos[o + 1] = s[13];
      _pos[o + 2] = s[14];
      _origPos[o] = s[12];
      _origPos[o + 1] = s[13];
      _origPos[o + 2] = s[14];
    }

    var totalLen = 0.0;
    for (var i = 0; i < n - 1; i++) {
      final o0 = i * 3;
      final o1 = (i + 1) * 3;
      final dx = _pos[o1] - _pos[o0];
      final dy = _pos[o1 + 1] - _pos[o0 + 1];
      final dz = _pos[o1 + 2] - _pos[o0 + 2];
      final len = math.sqrt(dx * dx + dy * dy + dz * dz);
      if (len < 1e-6) {
        return;
      }
      _lengths[i] = len;
      totalLen += len;
    }

    _targetM.setFrom(targetPosition);
    invWorldMatrix.transform3(_targetM);

    final rootX = _origPos[0];
    final rootY = _origPos[1];
    final rootZ = _origPos[2];

    // Precompute root bone's animated direction as cone axis (`i == 0`).
    final initDx = _origPos[3] - rootX;
    final initDy = _origPos[4] - rootY;
    final initDz = _origPos[5] - rootZ;
    final initLen = math.sqrt(
      initDx * initDx + initDy * initDy + initDz * initDz,
    );
    final rootRefX = initDx / initLen;
    final rootRefY = initDy / initLen;
    final rootRefZ = initDz / initLen;

    final hasConeLimits =
        maxConeAngleRad != null ||
        (jointMaxConeAnglesRad != null && jointMaxConeAnglesRad!.isNotEmpty);

    final distRootToTarget = math.sqrt(
      (_targetM.x - rootX) * (_targetM.x - rootX) +
          (_targetM.y - rootY) * (_targetM.y - rootY) +
          (_targetM.z - rootZ) * (_targetM.z - rootZ),
    );

    if (!hasConeLimits && distRootToTarget >= totalLen - 1e-6) {
      // Unreachable without cone constraints: stretch straight toward target.
      if (distRootToTarget > 1e-8) {
        final ux = (_targetM.x - rootX) / distRootToTarget;
        final uy = (_targetM.y - rootY) / distRootToTarget;
        final uz = (_targetM.z - rootZ) / distRootToTarget;
        for (var i = 0; i < n - 1; i++) {
          final o0 = i * 3;
          final o1 = (i + 1) * 3;
          final d = _lengths[i];
          _pos[o1] = _pos[o0] + ux * d;
          _pos[o1 + 1] = _pos[o0 + 1] + uy * d;
          _pos[o1 + 2] = _pos[o0 + 2] + uz * d;
        }
      }
    } else {
      final tol2 = tolerance * tolerance;
      final lastOff = (n - 1) * 3;
      for (var iter = 0; iter < maxIterations; iter++) {
        final ex = _pos[lastOff] - _targetM.x;
        final ey = _pos[lastOff + 1] - _targetM.y;
        final ez = _pos[lastOff + 2] - _targetM.z;
        if (ex * ex + ey * ey + ez * ez <= tol2) {
          break;
        }

        // 1. Backward reaching pass (`end-effector -> root`).
        _pos[lastOff] = _targetM.x;
        _pos[lastOff + 1] = _targetM.y;
        _pos[lastOff + 2] = _targetM.z;
        for (var i = n - 2; i >= 0; i--) {
          final o0 = i * 3;
          final o1 = (i + 1) * 3;
          final rx = _pos[o0] - _pos[o1];
          final ry = _pos[o0 + 1] - _pos[o1 + 1];
          final rz = _pos[o0 + 2] - _pos[o1 + 2];
          final rLen = math.sqrt(rx * rx + ry * ry + rz * rz);
          final d = _lengths[i];
          if (rLen > 1e-9) {
            final s = d / rLen;
            _pos[o0] = _pos[o1] + rx * s;
            _pos[o0 + 1] = _pos[o1 + 1] + ry * s;
            _pos[o0 + 2] = _pos[o1 + 2] + rz * s;
          } else {
            _pos[o0] = _pos[o1];
            _pos[o0 + 1] = _pos[o1 + 1] - d;
            _pos[o0 + 2] = _pos[o1 + 2];
          }
        }

        // 2. Forward reaching pass (`root -> end-effector`) with cone limits.
        _pos[0] = rootX;
        _pos[1] = rootY;
        _pos[2] = rootZ;
        for (var i = 0; i < n - 1; i++) {
          final o0 = i * 3;
          final o1 = (i + 1) * 3;
          var cx = _pos[o1] - _pos[o0];
          var cy = _pos[o1 + 1] - _pos[o0 + 1];
          var cz = _pos[o1 + 2] - _pos[o0 + 2];
          final cLen = math.sqrt(cx * cx + cy * cy + cz * cz);
          if (cLen > 1e-9) {
            cx /= cLen;
            cy /= cLen;
            cz /= cLen;
          } else {
            cx = rootRefX;
            cy = rootRefY;
            cz = rootRefZ;
          }

          final maxCone = _coneLimitAt(i);
          if (maxCone != null && maxCone < math.pi - 1e-5) {
            if (i == 0) {
              _axisDir.setValues(rootRefX, rootRefY, rootRefZ);
            } else {
              final op = (i - 1) * 3;
              _axisDir.setValues(
                _pos[o0] - _pos[op],
                _pos[o0 + 1] - _pos[op + 1],
                _pos[o0 + 2] - _pos[op + 2],
              );
              if (_axisDir.length2 > 1e-12) {
                _axisDir.normalize();
              } else {
                _axisDir.setValues(rootRefX, rootRefY, rootRefZ);
              }
            }
            _candDir.setValues(cx, cy, cz);
            _clampDirectionToCone(_axisDir, _candDir, maxCone, _perp);
            cx = _candDir.x;
            cy = _candDir.y;
            cz = _candDir.z;
          }

          final d = _lengths[i];
          _pos[o1] = _pos[o0] + cx * d;
          _pos[o1 + 1] = _pos[o0 + 1] + cy * d;
          _pos[o1 + 2] = _pos[o0 + 2] + cz * d;
        }
      }
    }

    // 3. Apply solved joint directions into `workspace` in parent-to-child
    // order, propagating each delta to descendants.
    for (var i = 0; i < n - 1; i++) {
      final curIdx = chainNodeIndices[i];
      final nextIdx = chainNodeIndices[i + 1];
      final curNode = workspace.nodesByIndex[curIdx]!;
      final nextNode = workspace.nodesByIndex[nextIdx]!;
      final cm = curNode.combinedTransform;
      final nm = nextNode.combinedTransform;

      _fromDir.setValues(
        nm.storage[12] - cm.storage[12],
        nm.storage[13] - cm.storage[13],
        nm.storage[14] - cm.storage[14],
      );
      final o0 = i * 3;
      final o1 = (i + 1) * 3;
      _toDir.setValues(
        _pos[o1] - _pos[o0],
        _pos[o1 + 1] - _pos[o0 + 1],
        _pos[o1 + 2] - _pos[o0 + 2],
      );
      if (_fromDir.length2 < 1e-12 || _toDir.length2 < 1e-12) {
        continue;
      }
      _fromDir.normalize();
      _toDir.normalize();

      _oldCombined.setFrom(cm);
      BoneModifier3D.swingRotationInto(
        _fromDir,
        _toDir,
        _deltaQ,
        blendWeight: w,
      );
      BoneModifier3D.rotateCombinedAroundOrigin(cm, _deltaQ);
      BoneModifier3D.propagateDeltaToDescendants(
        model,
        workspace,
        curIdx,
        _oldCombined,
        cm,
      );
    }
  }

  static void _clampDirectionToCone(
    Vector3 axis,
    Vector3 candidateInOut,
    double maxAngleRad,
    Vector3 perpScratch,
  ) {
    final clampedLimit = maxAngleRad.clamp(0.0, math.pi);
    final dot = axis.dot(candidateInOut).clamp(-1.0, 1.0);
    final angle = math.acos(dot);
    if (angle <= clampedLimit) {
      return;
    }
    if (clampedLimit <= 1e-6) {
      candidateInOut.setFrom(axis);
      return;
    }
    perpScratch
      ..setFrom(candidateInOut)
      ..addScaled(axis, -dot);
    if (perpScratch.length2 < 1e-12) {
      if (axis.x.abs() < 0.9) {
        perpScratch.setValues(0.0, -axis.z, axis.y);
      } else {
        perpScratch.setValues(-axis.z, 0.0, axis.x);
      }
    }
    perpScratch.normalize();
    final ca = math.cos(clampedLimit);
    final sa = math.sin(clampedLimit);
    candidateInOut
      ..setValues(
        axis.x * ca + perpScratch.x * sa,
        axis.y * ca + perpScratch.y * sa,
        axis.z * ca + perpScratch.z * sa,
      )
      ..normalize();
  }
}

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

  // Scratch vectors for analytic 2-bone leg IK.
  final Vector3 _pRoot = Vector3.zero();
  final Vector3 _pMid = Vector3.zero();
  final Vector3 _pTip = Vector3.zero();
  final Vector3 _targetM = Vector3.zero();
  final Vector3 _poleM = Vector3.zero();
  final Vector3 _dirTarget = Vector3.zero();
  final Vector3 _poleProj = Vector3.zero();
  final Vector3 _newMid = Vector3.zero();
  final Vector3 _oldUpper = Vector3.zero();
  final Vector3 _newUpper = Vector3.zero();
  final Vector3 _curLower = Vector3.zero();
  final Vector3 _newLower = Vector3.zero();
  final Vector3 _goalTip = Vector3.zero();
  final Quaternion _qRoot = Quaternion.identity();
  final Quaternion _qMid = Quaternion.identity();
  final Matrix4 _oldRootM = Matrix4.identity();
  final Matrix4 _oldMidM = Matrix4.identity();

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

    _solveTwoBoneIk(
      model: model,
      workspace: workspace,
      invWorldMatrix: invWorldMatrix,
      rIdx: leg.$1,
      mIdx: leg.$2,
      tIdx: leg.$3,
      targetWorld: _targetFootWorld,
      poleWorld: _poleWorld,
      w: blendWeight,
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

  void _solveTwoBoneIk({
    required Model model,
    required ModelPoseWorkspace workspace,
    required Matrix4 invWorldMatrix,
    required int rIdx,
    required int mIdx,
    required int tIdx,
    required Vector3 targetWorld,
    required Vector3 poleWorld,
    required double w,
  }) {
    final rm = workspace.nodesByIndex[rIdx]!.combinedTransform;
    final mm = workspace.nodesByIndex[mIdx]!.combinedTransform;
    final tm = workspace.nodesByIndex[tIdx]!.combinedTransform;
    _pRoot.setValues(rm.storage[12], rm.storage[13], rm.storage[14]);
    _pMid.setValues(mm.storage[12], mm.storage[13], mm.storage[14]);
    _pTip.setValues(tm.storage[12], tm.storage[13], tm.storage[14]);

    final lenA = (_pMid - _pRoot).length;
    final lenB = (_pTip - _pMid).length;
    if (lenA < 1e-5 || lenB < 1e-5) {
      return;
    }

    _targetM.setFrom(targetWorld);
    invWorldMatrix.transform3(_targetM);
    _poleM.setFrom(poleWorld);
    invWorldMatrix.transform3(_poleM);

    _dirTarget
      ..setFrom(_targetM)
      ..sub(_pRoot);
    final rawDist = _dirTarget.length;
    if (rawDist < 1e-6) {
      return;
    }
    _dirTarget.scale(1.0 / rawDist);

    final minReach = (lenA - lenB).abs() + 1e-4;
    final maxReach = lenA + lenB - 1e-4;
    final clampedDist = rawDist.clamp(minReach, maxReach);

    final cosAlpha =
        ((lenA * lenA + clampedDist * clampedDist - lenB * lenB) /
                (2.0 * lenA * clampedDist))
            .clamp(-1.0, 1.0);
    final sinAlpha = math.sqrt(math.max(0.0, 1.0 - cosAlpha * cosAlpha));

    _poleProj
      ..setFrom(_poleM)
      ..sub(_pRoot);
    final proj = _poleProj.dot(_dirTarget);
    _poleProj.addScaled(_dirTarget, -proj);
    if (_poleProj.length2 < 1e-8) {
      if (_dirTarget.x.abs() < 0.9) {
        _poleProj.setFrom(_dirTarget.cross(Vector3(1, 0, 0)));
      } else {
        _poleProj.setFrom(_dirTarget.cross(Vector3(0, 1, 0)));
      }
    }
    _poleProj.normalize();

    _newMid
      ..setFrom(_pRoot)
      ..addScaled(_dirTarget, lenA * cosAlpha)
      ..addScaled(_poleProj, lenA * sinAlpha);

    _oldUpper
      ..setFrom(_pMid)
      ..sub(_pRoot)
      ..normalize();
    _newUpper
      ..setFrom(_newMid)
      ..sub(_pRoot)
      ..normalize();
    _oldRootM.setFrom(rm);
    BoneModifier3D.swingRotationInto(
      _oldUpper,
      _newUpper,
      _qRoot,
      blendWeight: w,
    );
    BoneModifier3D.rotateCombinedAroundOrigin(rm, _qRoot);
    BoneModifier3D.propagateDeltaToDescendants(
      model,
      workspace,
      rIdx,
      _oldRootM,
      rm,
    );

    _pMid.setValues(mm.storage[12], mm.storage[13], mm.storage[14]);
    _pTip.setValues(tm.storage[12], tm.storage[13], tm.storage[14]);
    _goalTip
      ..setFrom(_pRoot)
      ..addScaled(_dirTarget, clampedDist);

    _curLower
      ..setFrom(_pTip)
      ..sub(_pMid);
    _newLower
      ..setFrom(_goalTip)
      ..sub(_pMid);
    if (_curLower.length2 < 1e-10 || _newLower.length2 < 1e-10) {
      return;
    }
    _curLower.normalize();
    _newLower.normalize();

    _oldMidM.setFrom(mm);
    BoneModifier3D.swingRotationInto(
      _curLower,
      _newLower,
      _qMid,
      blendWeight: w,
    );
    BoneModifier3D.rotateCombinedAroundOrigin(mm, _qMid);
    BoneModifier3D.propagateDeltaToDescendants(
      model,
      workspace,
      mIdx,
      _oldMidM,
      mm,
    );
  }
}

/// Active simulation state of a [RagdollController3D].
enum RagdollMode3D() {
  /// Kinematic rigid bodies track animated skeleton bones every frame.
  kinematicFollow,

  /// Dynamic rigid bodies simulate under gravity, contacts, and joints and
  /// write world limb poses back into [ModelPoseWorkspace].
  ragdoll,

  /// Frozen ragdoll snapshot smoothly Slerps/blends back into the live
  /// [AnimationState] over `blendDuration`.
  recoveringToAnimation,
}

/// Constraint type connecting a ragdoll limb to its parent ragdoll limb.
enum RagdollJointType3D() {
  /// 3-DOF spherical constraint ([BallSocketJoint3D]) for hips/spine/shoulders.
  ballSocket,

  /// 1-DOF revolute constraint ([HingeJoint3D]) for knees and elbows.
  hinge,
}

/// Per-bone capsule and joint descriptor for [RagdollController3D].
class RagdollBoneConfig3D({
  required final int nodeIndex,
  final int? endNodeIndex,
  final double radius = 0.08,
  final double mass = 2.0,
  final RagdollJointType3D jointType = RagdollJointType3D.ballSocket,
  Vector3? hingeAxisLocal,
  final double? minAngle,
  final double? maxAngle,
}) {
  /// Local hinge rotation axis when [jointType] is [RagdollJointType3D.hinge].
  final Vector3 hingeAxisLocal =
      (hingeAxisLocal?.clone() ?? Vector3(1.0, 0.0, 0.0))..normalize();
}

class _RagdollLimb({
  required final RagdollBoneConfig3D config,
  required final RigidBody3D body,
  required final Vector3 localMidOffset,
  required final Quaternion boneToCapsuleRot,
  required final Quaternion capsuleToBoneRot,
  required final Vector3 restScale,
}) {
  final Vector3 prevBodyPos = Vector3.zero();
  final Quaternion prevBodyRot = Quaternion.identity();
  bool hasPrev = false;
}

/// Articulated skeletal ragdoll controller bridging a [ModelComponent] and a
/// [PhysicsWorld3D] across [RagdollMode3D.kinematicFollow],
/// [RagdollMode3D.ragdoll], and [RagdollMode3D.recoveringToAnimation].
class RagdollController3D({
  required final ModelComponent modelComponent,
  required final PhysicsWorld3D physicsWorld,
  List<RagdollBoneConfig3D>? boneConfigs,
  final double defaultRadius = 0.08,
  final double defaultBoneLength = 0.28,
  final int collisionLayer = 2,
  final int collisionMask = 0xFFFFFFFF,
}) extends BoneModifier3D {
  this {
    _buildRig(boneConfigs);
    if (!modelComponent.boneModifiers.contains(this)) {
      modelComponent.boneModifiers.add(this);
    }
    // Seed initial kinematic transforms from current animated pose.
    modelComponent.markPoseDirty();
    modelComponent.evaluatePose();
  }

  final List<_RagdollLimb> _limbs = [];
  final Map<int, _RagdollLimb> _limbByNode = {};
  final List<Joint3D> _joints = [];

  RagdollMode3D _mode = RagdollMode3D.kinematicFollow;
  double _recoveryElapsed = 0.0;
  double _recoveryDuration = 0.45;
  final Map<int, Vector3> _frozenLocalTranslations = {};
  final Map<int, Quaternion> _frozenLocalRotations = {};

  final Matrix4 _boneWorld = Matrix4.identity();
  final Matrix4 _oldCombined = Matrix4.identity();
  final Matrix4 _invParent = Matrix4.identity();
  final Matrix4 _localMat = Matrix4.identity();
  final Vector3 _scratchPos = Vector3.zero();
  final Quaternion _scratchRot = Quaternion.identity();
  final Vector3 _scratchScale = Vector3.all(1.0);
  final Vector3 _animLocalT = Vector3.zero();
  final Quaternion _animLocalR = Quaternion.identity();
  final Vector3 _animLocalS = Vector3.all(1.0);
  final Vector3 _blendT = Vector3.zero();
  final Quaternion _blendR = Quaternion.identity();

  /// Current operating mode of this ragdoll.
  RagdollMode3D get mode => _mode;

  /// Progress in `[0, 1]` while in [RagdollMode3D.recoveringToAnimation].
  double get recoveryProgress => _mode == RagdollMode3D.recoveringToAnimation
      ? (_recoveryDuration > 1e-6
            ? (_recoveryElapsed / _recoveryDuration).clamp(0.0, 1.0)
            : 1.0)
      : 1.0;

  /// Articulated [RigidBody3D] limbs managed by this controller.
  List<RigidBody3D> get bodies =>
      List<RigidBody3D>.unmodifiable([for (final l in _limbs) l.body]);

  /// Articulated [Joint3D] constraints connecting [bodies].
  List<Joint3D> get joints => List<Joint3D>.unmodifiable(_joints);

  /// Returns the [RigidBody3D] associated with [nodeIndex], or `null`.
  RigidBody3D? bodyForBone(int nodeIndex) => _limbByNode[nodeIndex]?.body;

  /// Switches limbs to dynamic rigid-body simulation, transferring tracked
  /// animated velocities and optionally applying [impulse] at
  /// [hitBoneNodeIndex] (or the root limb when `null`).
  void activateRagdoll({
    Vector3? impulse,
    int? hitBoneNodeIndex,
  }) {
    if (_limbs.isEmpty) {
      return;
    }
    if (_mode != RagdollMode3D.ragdoll) {
      // Ensure kinematic transforms match the latest animated pose before
      // switching to dynamic.
      modelComponent.evaluatePose();
      for (final limb in _limbs) {
        limb.body
          ..bodyType = BodyType3D.dynamic
          ..canSleep = false
          ..wakeUp();
      }
      _mode = RagdollMode3D.ragdoll;
    }

    if (impulse != null) {
      final targetLimb = hitBoneNodeIndex != null
          ? (_limbByNode[hitBoneNodeIndex] ?? _limbs.first)
          : _limbs.first;
      targetLimb.body.applyImpulse(impulse);
    }
    modelComponent.markPoseDirty();
  }

  /// Snapshots the resting ragdoll pose, returns all limb bodies to kinematic
  /// mode, and smoothly Slerps/blends into the live [AnimationState] over
  /// [blendDuration] seconds.
  void recoverToAnimation({double blendDuration = 0.45}) {
    if (_limbs.isEmpty || _mode == RagdollMode3D.kinematicFollow) {
      return;
    }

    // Ensure workspace holds the latest ragdoll pose before snapshotting.
    final workspace = modelComponent.evaluatePose();
    _frozenLocalTranslations.clear();
    _frozenLocalRotations.clear();

    for (final processed in workspace.orderedNodes) {
      final node = processed.node;
      final pIdx = node.parentNodeIndex;
      if (pIdx != null && workspace.nodesByIndex[pIdx] != null) {
        _invParent.copyInverse(
          workspace.nodesByIndex[pIdx]!.combinedTransform,
        );
        _localMat
          ..setFrom(_invParent)
          ..multiply(processed.combinedTransform);
      } else {
        _localMat.setFrom(processed.combinedTransform);
      }
      final t = Vector3.zero();
      final r = Quaternion.identity();
      final s = Vector3.all(1.0);
      _localMat.decompose(t, r, s);
      if (r.length2 > 1e-12) {
        r.normalize();
      }
      _frozenLocalTranslations[node.nodeIndex] = t;
      _frozenLocalRotations[node.nodeIndex] = r;
    }

    for (final limb in _limbs) {
      limb.body
        ..bodyType = BodyType3D.kinematic
        ..linearVelocity.setZero()
        ..angularVelocity.setZero();
      limb.hasPrev = false;
    }

    if (blendDuration <= 0.0) {
      _mode = RagdollMode3D.kinematicFollow;
      _recoveryDuration = 0.0;
      _recoveryElapsed = 0.0;
    } else {
      _mode = RagdollMode3D.recoveringToAnimation;
      _recoveryDuration = blendDuration;
      _recoveryElapsed = 0.0;
    }
    modelComponent.markPoseDirty();
  }

  /// Explicitly marks the owning [ModelComponent] pose dirty and re-evaluates
  /// it against the latest simulated physics body transforms.
  void syncFromPhysics() {
    modelComponent.markPoseDirty();
    modelComponent.evaluatePose();
  }

  /// Removes all ragdoll bodies, joints, and modifier hooks.
  void dispose() {
    for (final j in _joints) {
      physicsWorld.removeJoint(j);
    }
    _joints.clear();
    for (final l in _limbs) {
      physicsWorld.removeBody(l.body);
    }
    _limbs.clear();
    _limbByNode.clear();
    modelComponent.boneModifiers.remove(this);
  }

  @override
  void apply(
    Model model,
    ModelPoseWorkspace workspace,
    Matrix4 worldMatrix,
    Matrix4 invWorldMatrix,
    double dt,
  ) {
    if (_limbs.isEmpty || weight <= 0.0) {
      return;
    }

    switch (_mode) {
      case RagdollMode3D.kinematicFollow:
        _syncBodiesFromWorkspace(workspace, worldMatrix, dt);

      case RagdollMode3D.ragdoll:
        _writeBodiesIntoWorkspace(model, workspace, invWorldMatrix);

      case RagdollMode3D.recoveringToAnimation:
        if (dt > 0.0) {
          _recoveryElapsed += dt;
        }
        final rawT = _recoveryDuration > 1e-6
            ? (_recoveryElapsed / _recoveryDuration).clamp(0.0, 1.0)
            : 1.0;
        // Smoothstep S-curve for natural stand-up transition.
        final smoothT = rawT * rawT * (3.0 - 2.0 * rawT);

        for (final processed in workspace.orderedNodes) {
          final node = processed.node;
          final idx = node.nodeIndex;
          final frozenR = _frozenLocalRotations[idx];
          final frozenT = _frozenLocalTranslations[idx];
          if (frozenR == null || frozenT == null) {
            continue;
          }

          final pIdx = node.parentNodeIndex;
          if (pIdx != null && workspace.nodesByIndex[pIdx] != null) {
            _invParent.copyInverse(
              workspace.nodesByIndex[pIdx]!.combinedTransform,
            );
            _localMat
              ..setFrom(_invParent)
              ..multiply(processed.combinedTransform);
          } else {
            _localMat.setFrom(processed.combinedTransform);
          }
          _localMat.decompose(_animLocalT, _animLocalR, _animLocalS);

          _blendT.setValues(
            frozenT.x + (_animLocalT.x - frozenT.x) * smoothT,
            frozenT.y + (_animLocalT.y - frozenT.y) * smoothT,
            frozenT.z + (_animLocalT.z - frozenT.z) * smoothT,
          );
          AnimationInterpolation.slerpQuaternionsInto(
            frozenR,
            _animLocalR,
            smoothT,
            _blendR,
          );
          _localMat.setFromTranslationRotationScale(
            _blendT,
            _blendR,
            _animLocalS,
          );

          if (pIdx != null && workspace.nodesByIndex[pIdx] != null) {
            processed.combinedTransform
              ..setFrom(workspace.nodesByIndex[pIdx]!.combinedTransform)
              ..multiply(_localMat);
          } else {
            processed.combinedTransform.setFrom(_localMat);
          }
        }

        _syncBodiesFromWorkspace(workspace, worldMatrix, dt);
        if (rawT >= 1.0) {
          _mode = RagdollMode3D.kinematicFollow;
        }
    }
  }

  void _syncBodiesFromWorkspace(
    ModelPoseWorkspace workspace,
    Matrix4 worldMatrix,
    double dt,
  ) {
    for (var i = 0; i < _limbs.length; i++) {
      final limb = _limbs[i];
      final processed = workspace.nodesByIndex[limb.config.nodeIndex];
      if (processed == null) {
        continue;
      }
      _boneWorld
        ..setFrom(worldMatrix)
        ..multiply(processed.combinedTransform);
      _extractWorldPosRot(_boneWorld, _scratchPos, _scratchRot);

      // `Q_body = Q_bone * Q_boneToCapsule`
      // `P_body = P_bone + Q_bone * localMidOffset`
      final bodyRot = (_scratchRot * limb.boneToCapsuleRot)..normalize();
      final offsetWorld = limb.localMidOffset.clone();
      _rotateByQuat(_scratchRot, offsetWorld);
      final bodyPos = _scratchPos + offsetWorld;

      if (limb.hasPrev && dt > 1e-6) {
        final invDt = 1.0 / dt;
        limb.body.linearVelocity.setValues(
          (bodyPos.x - limb.prevBodyPos.x) * invDt,
          (bodyPos.y - limb.prevBodyPos.y) * invDt,
          (bodyPos.z - limb.prevBodyPos.z) * invDt,
        );
        var dq = bodyRot * limb.prevBodyRot.conjugated();
        if (dq.w < 0.0) {
          dq = dq.scaled(-1.0);
        }
        final sinHalf = math.sqrt(dq.x * dq.x + dq.y * dq.y + dq.z * dq.z);
        if (sinHalf > 1e-6) {
          final angle = 2.0 * math.atan2(sinHalf, dq.w);
          final scaleW = (angle * invDt) / sinHalf;
          limb.body.angularVelocity.setValues(
            dq.x * scaleW,
            dq.y * scaleW,
            dq.z * scaleW,
          );
        } else {
          limb.body.angularVelocity.setZero();
        }
      }

      limb.body.bodyPosition.setFrom(bodyPos);
      limb.body.bodyRotation.setFrom(bodyRot);
      limb.prevBodyPos.setFrom(bodyPos);
      limb.prevBodyRot.setFrom(bodyRot);
      limb.hasPrev = true;
    }
  }

  void _writeBodiesIntoWorkspace(
    Model model,
    ModelPoseWorkspace workspace,
    Matrix4 invWorldMatrix,
  ) {
    final w = weight.clamp(0.0, 1.0);
    for (var i = 0; i < _limbs.length; i++) {
      final limb = _limbs[i];
      final idx = limb.config.nodeIndex;
      final processed = workspace.nodesByIndex[idx];
      if (processed == null) {
        continue;
      }

      final bodyPos = limb.body.bodyPosition;
      final bodyRot = limb.body.bodyRotation;

      // Recover world bone transform from simulated capsule body:
      // `Q_boneWorld = Q_body * Q_capsuleToBone`
      // `P_boneWorld = P_body - Q_boneWorld * localMidOffset`
      final boneRotWorld = (bodyRot * limb.capsuleToBoneRot)..normalize();
      final midWorld = limb.localMidOffset.clone();
      _rotateByQuat(boneRotWorld, midWorld);
      final bonePosWorld = bodyPos - midWorld;

      _boneWorld.setFromTranslationRotationScale(
        bonePosWorld,
        boneRotWorld,
        limb.restScale,
      );

      _localMat
        ..setFrom(invWorldMatrix)
        ..multiply(_boneWorld);

      final cm = processed.combinedTransform;
      _oldCombined.setFrom(cm);
      if (w >= 1.0 - 1e-6) {
        cm.setFrom(_localMat);
      } else {
        cm.decompose(_animLocalT, _animLocalR, _animLocalS);
        _localMat.decompose(_scratchPos, _scratchRot, _scratchScale);
        _blendT.setValues(
          _animLocalT.x + (_scratchPos.x - _animLocalT.x) * w,
          _animLocalT.y + (_scratchPos.y - _animLocalT.y) * w,
          _animLocalT.z + (_scratchPos.z - _animLocalT.z) * w,
        );
        AnimationInterpolation.slerpQuaternionsInto(
          _animLocalR,
          _scratchRot,
          w,
          _blendR,
        );
        cm.setFromTranslationRotationScale(_blendT, _blendR, _animLocalS);
      }

      BoneModifier3D.propagateDeltaToDescendants(
        model,
        workspace,
        idx,
        _oldCombined,
        cm,
      );
    }
  }

  void _buildRig(List<RagdollBoneConfig3D>? explicitConfigs) {
    final model = modelComponent.model;
    final workspace = ModelPoseWorkspace.forModel(model);
    model.evaluateInto(AnimationState(), workspace);
    final compWorld = modelComponent.worldTransformMatrix;

    // Map parent -> children in topological order.
    final childrenByNode = <int, List<int>>{};
    for (final node in model.processingOrder) {
      final p = node.parentNodeIndex;
      if (p != null) {
        (childrenByNode[p] ??= []).add(node.nodeIndex);
      }
    }

    final configs =
        explicitConfigs ?? _autoDetectBoneConfigs(model, childrenByNode);

    for (final cfg in configs) {
      final processed = workspace.nodesByIndex[cfg.nodeIndex];
      if (processed == null) {
        continue;
      }
      final boneWorldMat = compWorld.clone()
        ..multiply(processed.combinedTransform);
      final pStart = Vector3.zero();
      final qBone = Quaternion.identity();
      _extractWorldPosRot(boneWorldMat, pStart, qBone);

      Vector3 pEnd;
      final childIdx =
          cfg.endNodeIndex ??
          (childrenByNode[cfg.nodeIndex]?.isNotEmpty ?? false
              ? childrenByNode[cfg.nodeIndex]!.first
              : null);
      if (childIdx != null && workspace.nodesByIndex[childIdx] != null) {
        final childWorld = compWorld.clone()
          ..multiply(workspace.nodesByIndex[childIdx]!.combinedTransform);
        pEnd = childWorld.getTranslation();
      } else {
        final axis = Vector3(0.0, defaultBoneLength, 0.0);
        _rotateByQuat(qBone, axis);
        pEnd = pStart + axis;
      }

      var segVec = pEnd - pStart;
      var segLen = segVec.length;
      if (segLen < 1e-4) {
        segVec = Vector3(0.0, defaultBoneLength, 0.0);
        _rotateByQuat(qBone, segVec);
        segLen = segVec.length;
        pEnd = pStart + segVec;
      }

      final pMid = (pStart + pEnd)..scale(0.5);
      final localMidOffset = pMid - pStart;
      _unrotateByQuat(qBone, localMidOffset);

      final localAxisDir = segVec.normalized();
      _unrotateByQuat(qBone, localAxisDir);
      localAxisDir.normalize();

      final boneToCap = Quaternion.identity();
      BoneModifier3D.swingRotationInto(
        Vector3(0.0, 1.0, 0.0),
        localAxisDir,
        boneToCap,
      );
      final capToBone = boneToCap.conjugated();

      final r = math.max(0.02, cfg.radius);
      final totalHeight = math.max(2.0 * r + 0.02, segLen);
      final qBody = (qBone * boneToCap)..normalize();

      final body = RigidBody3D(
        shape: CapsuleShape3D(radius: r, height: totalHeight),
        bodyType: BodyType3D.kinematic,
        mass: cfg.mass,
        friction: 0.6,
        linearDamping: 0.15,
        angularDamping: 0.25,
        syncParent: false,
        collisionLayer: collisionLayer,
        collisionMask: collisionMask,
        position: pMid,
        rotation: qBody,
      );
      physicsWorld.addBody(body);

      final limb = _RagdollLimb(
        config: cfg,
        body: body,
        localMidOffset: localMidOffset,
        boneToCapsuleRot: boneToCap,
        capsuleToBoneRot: capToBone,
        restScale: processed.node.restScale.clone(),
      );
      _limbs.add(limb);
      _limbByNode[cfg.nodeIndex] = limb;
    }

    // Connect each limb to its nearest ragdoll ancestor limb via HingeJoint3D
    // or BallSocketJoint3D anchored at the child bone's world pivot.
    for (final limb in _limbs) {
      final node = model.nodes[limb.config.nodeIndex]!;
      var pIdx = node.parentNodeIndex;
      _RagdollLimb? parentLimb;
      while (pIdx != null) {
        parentLimb = _limbByNode[pIdx];
        if (parentLimb != null) {
          break;
        }
        pIdx = model.nodes[pIdx]?.parentNodeIndex;
      }
      if (parentLimb == null) {
        continue;
      }

      final childWorldMat = compWorld.clone()
        ..multiply(workspace.nodesByIndex[node.nodeIndex]!.combinedTransform);
      final pivotWorld = childWorldMat.getTranslation();

      final anchorA = pivotWorld - parentLimb.body.bodyPosition;
      _unrotateByQuat(parentLimb.body.bodyRotation, anchorA);

      final anchorB = pivotWorld - limb.body.bodyPosition;
      _unrotateByQuat(limb.body.bodyRotation, anchorB);

      final Joint3D joint;
      if (limb.config.jointType == RagdollJointType3D.hinge) {
        // Transform bone-local hinge axis into parent body's local frame.
        final childBoneRot = Quaternion.identity();
        _extractWorldPosRot(childWorldMat, _scratchPos, childBoneRot);
        final worldHingeAxis = limb.config.hingeAxisLocal.clone();
        _rotateByQuat(childBoneRot, worldHingeAxis);
        final axisInA = worldHingeAxis.clone();
        _unrotateByQuat(parentLimb.body.bodyRotation, axisInA);
        if (axisInA.length2 > 1e-10) {
          axisInA.normalize();
        } else {
          axisInA.setValues(1.0, 0.0, 0.0);
        }
        joint = HingeJoint3D(
          bodyA: parentLimb.body,
          bodyB: limb.body,
          localAnchorA: anchorA,
          localAnchorB: anchorB,
          localAxisA: axisInA,
          minAngle: limb.config.minAngle,
          maxAngle: limb.config.maxAngle,
        );
      } else {
        joint = BallSocketJoint3D(
          bodyA: parentLimb.body,
          bodyB: limb.body,
          localAnchorA: anchorA,
          localAnchorB: anchorB,
        );
      }
      physicsWorld.addJoint(joint);
      _joints.add(joint);
    }
  }

  List<RagdollBoneConfig3D> _autoDetectBoneConfigs(
    Model model,
    Map<int, List<int>> childrenByNode,
  ) {
    final configs = <RagdollBoneConfig3D>[];
    for (final node in model.processingOrder) {
      final kids = childrenByNode[node.nodeIndex];
      final hasChildren = kids != null && kids.isNotEmpty;
      // Include internal bones and leaf limb bones that have a parent bone
      // (skipping pure mesh-only root wrappers when a skeleton is present).
      if (!hasChildren &&
          node.parentNodeIndex == null &&
          model.nodes.length > 1) {
        continue;
      }
      if (!hasChildren && node.mesh != null && node.joints.isNotEmpty) {
        continue;
      }
      final lower = (node.name ?? '').toLowerCase();
      final isHinge =
          lower.contains('calf') ||
          lower.contains('shin') ||
          lower.contains('lowerleg') ||
          lower.contains('forearm') ||
          lower.contains('lowerarm') ||
          lower.contains('knee') ||
          lower.contains('elbow');
      configs.add(
        RagdollBoneConfig3D(
          nodeIndex: node.nodeIndex,
          endNodeIndex: hasChildren ? kids.first : null,
          radius: defaultRadius,
          mass: node.parentNodeIndex == null ? 4.0 : 2.0,
          jointType: isHinge
              ? RagdollJointType3D.hinge
              : RagdollJointType3D.ballSocket,
          minAngle: isHinge ? -2.2 : null,
          maxAngle: isHinge ? 2.2 : null,
        ),
      );
    }
    return configs;
  }

  static void _extractWorldPosRot(
    Matrix4 m,
    Vector3 posOut,
    Quaternion rotOut,
  ) {
    final s = m.storage;
    posOut.setValues(s[12], s[13], s[14]);
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
    final rMat = Matrix3(c0x, c0y, c0z, c1x, c1y, c1z, c2x, c2y, c2z);
    rotOut.setFromRotation(rMat);
    if (rotOut.length2 > 1e-12) {
      rotOut.normalize();
    } else {
      rotOut.setValues(0.0, 0.0, 0.0, 1.0);
    }
  }

  static void _rotateByQuat(Quaternion q, Vector3 v) {
    final qx = q.x;
    final qy = q.y;
    final qz = q.z;
    final qw = q.w;
    final tx = 2.0 * (qy * v.z - qz * v.y);
    final ty = 2.0 * (qz * v.x - qx * v.z);
    final tz = 2.0 * (qx * v.y - qy * v.x);
    v.setValues(
      v.x + qw * tx + (qy * tz - qz * ty),
      v.y + qw * ty + (qz * tx - qx * tz),
      v.z + qw * tz + (qx * ty - qy * tx),
    );
  }

  static void _unrotateByQuat(Quaternion q, Vector3 v) {
    final qx = -q.x;
    final qy = -q.y;
    final qz = -q.z;
    final qw = q.w;
    final tx = 2.0 * (qy * v.z - qz * v.y);
    final ty = 2.0 * (qz * v.x - qx * v.z);
    final tz = 2.0 * (qx * v.y - qy * v.x);
    v.setValues(
      v.x + qw * tx + (qy * tz - qz * ty),
      v.y + qw * ty + (qz * tx - qx * tz),
      v.z + qw * tz + (qx * ty - qy * tx),
    );
  }
}
