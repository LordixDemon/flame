part of 'foot_ik_and_ragdoll_3d.dart';

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
