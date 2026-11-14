import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame/src/canvas3d/mesh_3d.dart';
import 'package:flame/src/game/game.dart';

/// Allocation-free 3D quaternion and `3x3` rotation matrix math utilities for
/// gimbal-lock-free `canvas3d` orientation, SLERP blending, and skeletal
/// skinning.
abstract final class Quaternion3D._() {
  /// Identity unit quaternion `(0, 0, 0, 1)`.
  static const (double, double, double, double) identity = (0.0, 0.0, 0.0, 1.0);

  /// Normalizes `(qx, qy, qz, qw)` onto the unit 3-sphere.
  static (double, double, double, double) normalize(
    double qx,
    double qy,
    double qz,
    double qw,
  ) {
    final len = math.sqrt(qx * qx + qy * qy + qz * qz + qw * qw);
    if (len <= 1e-9) {
      return identity;
    }
    final inv = 1.0 / len;
    return (qx * inv, qy * inv, qz * inv, qw * inv);
  }

  /// Creates a unit quaternion rotating by [angleRad] around `(ax, ay, az)`.
  static (double, double, double, double) fromAxisAngle(
    double ax,
    double ay,
    double az,
    double angleRad,
  ) {
    final len = math.sqrt(ax * ax + ay * ay + az * az);
    if (len <= 1e-9) {
      return identity;
    }
    final half = angleRad * 0.5;
    final s = math.sin(half) / len;
    return (ax * s, ay * s, az * s, math.cos(half));
  }

  /// Creates a unit quaternion matching `canvas3d`'s intrinsic Euler convention
  /// `R = Rz(yaw) * Ry(pitch) * Rx(roll)`.
  static (double, double, double, double) fromEuler({
    double yawRad = 0.0,
    double pitchRad = 0.0,
    double rollRad = 0.0,
  }) {
    final cy = math.cos(yawRad * 0.5);
    final sy = math.sin(yawRad * 0.5);
    final cp = math.cos(pitchRad * 0.5);
    final sp = math.sin(pitchRad * 0.5);
    final cr = math.cos(rollRad * 0.5);
    final sr = math.sin(rollRad * 0.5);

    return (
      sr * cp * cy - cr * sp * sy,
      cr * sp * cy + sr * cp * sy,
      cr * cp * sy - sr * sp * cy,
      cr * cp * cy + sr * sp * sy,
    );
  }

  /// Hamilton product `a * b` (applying rotation `b` in local space followed by
  /// `a`).
  static (double, double, double, double) multiply(
    (double, double, double, double) a,
    (double, double, double, double) b,
  ) {
    final (ax, ay, az, aw) = a;
    final (bx, by, bz, bw) = b;
    return (
      aw * bx + ax * bw + ay * bz - az * by,
      aw * by - ax * bz + ay * bw + az * bx,
      aw * bz + ax * by - ay * bx + az * bw,
      aw * bw - ax * bx - ay * by - az * bz,
    );
  }

  /// Shortest-arc spherical linear interpolation between unit quaternions [a]
  /// and [b] at `t` (`0.0 .. 1.0`).
  static (double, double, double, double) slerp(
    (double, double, double, double) a,
    (double, double, double, double) b,
    double t,
  ) {
    final u = t.clamp(0.0, 1.0);
    final (ax, ay, az, aw) = a;
    var (bx, by, bz, bw) = b;
    var dot = ax * bx + ay * by + az * bz + aw * bw;
    if (dot < 0.0) {
      dot = -dot;
      bx = -bx;
      by = -by;
      bz = -bz;
      bw = -bw;
    }
    if (dot > 0.9995) {
      return normalize(
        ax + (bx - ax) * u,
        ay + (by - ay) * u,
        az + (bz - az) * u,
        aw + (bw - aw) * u,
      );
    }
    final theta0 = math.acos(dot.clamp(-1.0, 1.0));
    final theta = theta0 * u;
    final sinTheta = math.sin(theta);
    final sinTheta0 = math.sin(theta0);
    final s0 = math.cos(theta) - dot * sinTheta / sinTheta0;
    final s1 = sinTheta / sinTheta0;
    return (
      s0 * ax + s1 * bx,
      s0 * ay + s1 * by,
      s0 * az + s1 * bz,
      s0 * aw + s1 * bw,
    );
  }

  /// Writes the row-major `3x3` rotation matrix for `(qx, qy, qz, qw)` into
  /// [out] at [offset] (requires `out.length >= offset + 9`).
  static void writeMatrix3(
    double qx,
    double qy,
    double qz,
    double qw,
    Float32List out, [
    int offset = 0,
  ]) {
    final (x, y, z, w) = normalize(qx, qy, qz, qw);
    final xx = x * x;
    final yy = y * y;
    final zz = z * z;
    final xy = x * y;
    final xz = x * z;
    final yz = y * z;
    final wx = w * x;
    final wy = w * y;
    final wz = w * z;

    out[offset] = 1.0 - 2.0 * (yy + zz);
    out[offset + 1] = 2.0 * (xy - wz);
    out[offset + 2] = 2.0 * (xz + wy);
    out[offset + 3] = 2.0 * (xy + wz);
    out[offset + 4] = 1.0 - 2.0 * (xx + zz);
    out[offset + 5] = 2.0 * (yz - wx);
    out[offset + 6] = 2.0 * (xz - wy);
    out[offset + 7] = 2.0 * (yz + wx);
    out[offset + 8] = 1.0 - 2.0 * (xx + yy);
  }

  /// Writes `R = Rz(yaw) * Ry(pitch) * Rx(roll)` into [out] at [offset].
  static void writeEulerMatrix3({
    required double yawRad,
    required double pitchRad,
    required double rollRad,
    required Float32List out,
    int offset = 0,
  }) {
    final cy = math.cos(yawRad);
    final sy = math.sin(yawRad);
    final cp = math.cos(pitchRad);
    final sp = math.sin(pitchRad);
    final cr = math.cos(rollRad);
    final sr = math.sin(rollRad);

    out[offset] = cy * cp;
    out[offset + 1] = cy * sp * sr - sy * cr;
    out[offset + 2] = cy * sp * cr + sy * sr;
    out[offset + 3] = sy * cp;
    out[offset + 4] = sy * sp * sr + cy * cr;
    out[offset + 5] = sy * sp * cr - cy * sr;
    out[offset + 6] = -sp;
    out[offset + 7] = cp * sr;
    out[offset + 8] = cp * cr;
  }

  /// Multiplies two row-major `3x3` matrices `out = a * b`.
  static void multiplyMatrix3(
    Float32List a,
    int aOff,
    Float32List b,
    int bOff,
    Float32List out,
    int outOff,
  ) {
    final a00 = a[aOff];
    final a01 = a[aOff + 1];
    final a02 = a[aOff + 2];
    final a10 = a[aOff + 3];
    final a11 = a[aOff + 4];
    final a12 = a[aOff + 5];
    final a20 = a[aOff + 6];
    final a21 = a[aOff + 7];
    final a22 = a[aOff + 8];

    final b00 = b[bOff];
    final b01 = b[bOff + 1];
    final b02 = b[bOff + 2];
    final b10 = b[bOff + 3];
    final b11 = b[bOff + 4];
    final b12 = b[bOff + 5];
    final b20 = b[bOff + 6];
    final b21 = b[bOff + 7];
    final b22 = b[bOff + 8];

    out[outOff] = a00 * b00 + a01 * b10 + a02 * b20;
    out[outOff + 1] = a00 * b01 + a01 * b11 + a02 * b21;
    out[outOff + 2] = a00 * b02 + a01 * b12 + a02 * b22;
    out[outOff + 3] = a10 * b00 + a11 * b10 + a12 * b20;
    out[outOff + 4] = a10 * b01 + a11 * b11 + a12 * b21;
    out[outOff + 5] = a10 * b02 + a11 * b12 + a12 * b22;
    out[outOff + 6] = a20 * b00 + a21 * b10 + a22 * b20;
    out[outOff + 7] = a20 * b01 + a21 * b11 + a22 * b21;
    out[outOff + 8] = a20 * b02 + a21 * b12 + a22 * b22;
  }
}

/// Per-vertex additive blendshape / morph delta buffer (`x, y, z` triples) for
/// [MorphMeshWorkspace3D].
class MorphTarget3D({
  required final Float32List positionDeltas,
  final Float32List? normalDeltas,
  final String name = '',
}) {
  this
    : assert(
        positionDeltas.length % 3 == 0,
        'positionDeltas length must be a multiple of 3',
      ),
      assert(
        normalDeltas == null || normalDeltas.length == positionDeltas.length,
        'normalDeltas length must match positionDeltas length',
      ) {
    var maxDelta = 0.0;
    for (var i = 0; i < positionDeltas.length; i += 3) {
      final dx = positionDeltas[i];
      final dy = positionDeltas[i + 1];
      final dz = positionDeltas[i + 2];
      final d = math.sqrt(dx * dx + dy * dy + dz * dz);
      if (d > maxDelta) {
        maxDelta = d;
      }
    }
    maxDisplacement = maxDelta;
  }

  /// Maximum Euclidean vertex displacement across all vertices in this target,
  /// used to inflate frustum-culling bounds without scanning vertices per
  /// frame.
  late final double maxDisplacement;
}

/// Pre-allocated zero-GC blendshape workspace that evaluates weighted
/// [MorphTarget3D]s against [baseMesh] and feeds deformed buffers directly into
/// `BatchMeshRenderer3D.enqueueDeformedMesh` without constructing per-frame
/// [Mesh3D] instances.
class MorphMeshWorkspace3D({
  required final Mesh3D baseMesh,
  required final List<MorphTarget3D> targets,
}) {
  this {
    for (var i = 0; i < targets.length; i++) {
      assert(
        targets[i].positionDeltas.length == baseMesh.positions.length,
        'MorphTarget3D[$i] vertex count must match baseMesh.vertexCount',
      );
    }
    deformedPositions.setAll(0, baseMesh.positions);
    deformedNormals.setAll(0, baseMesh.normals);
    _recomputeConservativeBounds();
  }

  /// Deformed vertex positions (`vertexCount * 3`).
  late final Float32List deformedPositions = Float32List(
    baseMesh.positions.length,
  );

  /// Deformed unit vertex normals (`vertexCount * 3`).
  late final Float32List deformedNormals = Float32List(baseMesh.normals.length);

  late final Float32List _weights = Float32List(targets.length);
  bool _dirty = false;
  double _boundingRadius = 0.0;
  double _minZ = 0.0;
  double _maxZ = 0.0;

  /// Conservative bounding sphere radius covering active morph weights.
  double get boundingRadius => _boundingRadius;

  /// Conservative minimum local Z covering active morph weights.
  double get minZ => _minZ;

  /// Conservative maximum local Z covering active morph weights.
  double get maxZ => _maxZ;

  /// Reads current weight of morph target [index].
  double weightAt(int index) => _weights[index];

  /// Sets the blend weight of morph target [index] (commonly `0.0 .. 1.0`,
  /// negative or overshoot `> 1.0` values also supported for squash-stretch).
  void setWeight(int index, double weight) {
    if ((_weights[index] - weight).abs() <= 1e-6) {
      return;
    }
    _weights[index] = weight;
    _dirty = true;
    Game.notifyVisualMutation();
  }

  /// Sets the blend weight of the first morph target matching [name].
  bool setWeightByName(String name, double weight) {
    for (var i = 0; i < targets.length; i++) {
      if (targets[i].name == name) {
        setWeight(i, weight);
        return true;
      }
    }
    return false;
  }

  void _recomputeConservativeBounds() {
    var extra = 0.0;
    for (var i = 0; i < targets.length; i++) {
      final w = _weights[i].abs();
      if (w > 1e-6) {
        extra += w * targets[i].maxDisplacement;
      }
    }
    _boundingRadius = baseMesh.boundingRadius + extra;
    _minZ = baseMesh.minZ - extra;
    _maxZ = baseMesh.maxZ + extra;
  }

  /// Evaluates any dirty morph target weights into [deformedPositions] and
  /// [deformedNormals] with `0` heap allocations, returning `true` if buffers
  /// were updated.
  bool evaluateIfDirty() {
    if (!_dirty) {
      return false;
    }
    _dirty = false;
    _recomputeConservativeBounds();

    final basePos = baseMesh.positions;
    final baseNrm = baseMesh.normals;
    deformedPositions.setAll(0, basePos);
    deformedNormals.setAll(0, baseNrm);

    var anyNormalDelta = false;
    for (var t = 0; t < targets.length; t++) {
      final w = _weights[t];
      if (w.abs() <= 1e-6) {
        continue;
      }
      final pDeltas = targets[t].positionDeltas;
      for (var i = 0; i < pDeltas.length; i++) {
        deformedPositions[i] += pDeltas[i] * w;
      }
      final nDeltas = targets[t].normalDeltas;
      if (nDeltas != null) {
        anyNormalDelta = true;
        for (var i = 0; i < nDeltas.length; i++) {
          deformedNormals[i] += nDeltas[i] * w;
        }
      }
    }

    if (anyNormalDelta) {
      for (var i = 0; i < deformedNormals.length; i += 3) {
        final nx = deformedNormals[i];
        final ny = deformedNormals[i + 1];
        final nz = deformedNormals[i + 2];
        final len = math.sqrt(nx * nx + ny * ny + nz * nz);
        if (len > 1e-7) {
          final inv = 1.0 / len;
          deformedNormals[i] = nx * inv;
          deformedNormals[i + 1] = ny * inv;
          deformedNormals[i + 2] = nz * inv;
        }
      }
    }
    return true;
  }
}

/// Hierarchical skeletal bone definition for [SkinnedMeshWorkspace3D].
class Bone3D({
  required this.name,
  this.parentIndex = -1,
  this.bindLocalX = 0.0,
  this.bindLocalY = 0.0,
  this.bindLocalZ = 0.0,
}) {
  /// Bone identifier.
  final String name;

  /// Parent bone index (`-1` for root bone; `parentIndex < index`).
  final int parentIndex;

  /// Rest/bind-pose local X offset relative to parent bone.
  final double bindLocalX;

  /// Rest/bind-pose local Y offset relative to parent bone.
  final double bindLocalY;

  /// Rest/bind-pose local Z offset relative to parent bone.
  final double bindLocalZ;
}

/// Zero-allocation Linear Blend Skinning (LBS, up to 2 bone influences per
/// vertex) workspace transforming a [Mesh3D] by an animated [Bone3D] hierarchy
/// directly into `BatchMeshRenderer3D.enqueueDeformedMesh`.
class SkinnedMeshWorkspace3D({
  required final Mesh3D baseMesh,
  required final List<Bone3D> bones,
  required final Uint16List boneIndices0,
  Uint16List? boneIndices1,
  Float32List? boneWeights0,
}) {
  this
    : assert(bones.isNotEmpty, 'bones must not be empty'),
      assert(
        boneIndices0.length == baseMesh.vertexCount,
        'boneIndices0 length must equal baseMesh.vertexCount',
      ) {
    final vCount = baseMesh.vertexCount;
    _boneIdx1 = boneIndices1 ?? Uint16List(vCount);
    _boneW0 = boneWeights0 ?? (Float32List(vCount)..fillRange(0, vCount, 1.0));
    assert(_boneIdx1.length == vCount, 'boneIndices1 length mismatch');
    assert(_boneW0.length == vCount, 'boneWeights0 length mismatch');

    final bCount = bones.length;
    _localTx = Float32List(bCount * 3);
    _localQuat = Float32List(bCount * 4);
    _bindInvX = Float32List(bCount);
    _bindInvY = Float32List(bCount);
    _bindInvZ = Float32List(bCount);
    _worldRot = Float32List(bCount * 9);
    _worldTx = Float32List(bCount * 3);
    _skinTx = Float32List(bCount * 3);

    for (var b = 0; b < bCount; b++) {
      final bone = bones[b];
      assert(
        bone.parentIndex >= -1 && bone.parentIndex < b,
        'Bone[$b].parentIndex must be -1 or < $b',
      );
      _localTx[b * 3] = bone.bindLocalX;
      _localTx[b * 3 + 1] = bone.bindLocalY;
      _localTx[b * 3 + 2] = bone.bindLocalZ;
      _localQuat[b * 4 + 3] = 1.0;

      if (bone.parentIndex < 0) {
        _worldTx[b * 3] = bone.bindLocalX;
        _worldTx[b * 3 + 1] = bone.bindLocalY;
        _worldTx[b * 3 + 2] = bone.bindLocalZ;
      } else {
        final p = bone.parentIndex * 3;
        _worldTx[b * 3] = _worldTx[p] + bone.bindLocalX;
        _worldTx[b * 3 + 1] = _worldTx[p + 1] + bone.bindLocalY;
        _worldTx[b * 3 + 2] = _worldTx[p + 2] + bone.bindLocalZ;
      }
      _bindInvX[b] = -_worldTx[b * 3];
      _bindInvY[b] = -_worldTx[b * 3 + 1];
      _bindInvZ[b] = -_worldTx[b * 3 + 2];
    }

    skinnedPositions.setAll(0, baseMesh.positions);
    skinnedNormals.setAll(0, baseMesh.normals);
  }

  /// Skinned vertex positions (`vertexCount * 3`).
  late final Float32List skinnedPositions = Float32List(
    baseMesh.positions.length,
  );

  /// Skinned unit vertex normals (`vertexCount * 3`).
  late final Float32List skinnedNormals = Float32List(baseMesh.normals.length);

  late final Uint16List _boneIdx1;
  late final Float32List _boneW0;
  late final Float32List _localTx;
  late final Float32List _localQuat;
  late final Float32List _bindInvX;
  late final Float32List _bindInvY;
  late final Float32List _bindInvZ;
  late final Float32List _worldRot;
  late final Float32List _worldTx;
  late final Float32List _skinTx;
  final Float32List _scratchRot = Float32List(9);

  bool _poseDirty = true;
  double _boundingRadius = 0.0;
  double _minZ = 0.0;
  double _maxZ = 0.0;

  /// Conservative bounding radius after skinning.
  double get boundingRadius =>
      _boundingRadius > 0.0 ? _boundingRadius : baseMesh.boundingRadius * 1.5;

  /// Minimum local Z after latest skinning pass.
  double get minZ => _minZ;

  /// Maximum local Z after latest skinning pass.
  double get maxZ => _maxZ;

  /// Sets local pose rotation (unit quaternion) and optional local translation
  /// offset `(dx, dy, dz)` relative to bind pose for bone [boneIndex].
  void setBonePose(
    int boneIndex, {
    double qx = 0.0,
    double qy = 0.0,
    double qz = 0.0,
    double qw = 1.0,
    double dx = 0.0,
    double dy = 0.0,
    double dz = 0.0,
  }) {
    final bone = bones[boneIndex];
    final tBase = boneIndex * 3;
    final qBase = boneIndex * 4;
    _localTx[tBase] = bone.bindLocalX + dx;
    _localTx[tBase + 1] = bone.bindLocalY + dy;
    _localTx[tBase + 2] = bone.bindLocalZ + dz;
    final (nx, ny, nz, nw) = Quaternion3D.normalize(qx, qy, qz, qw);
    _localQuat[qBase] = nx;
    _localQuat[qBase + 1] = ny;
    _localQuat[qBase + 2] = nz;
    _localQuat[qBase + 3] = nw;
    _poseDirty = true;
    Game.notifyVisualMutation();
  }

  /// Resets all bones to rest bind pose.
  void resetToBindPose() {
    for (var b = 0; b < bones.length; b++) {
      setBonePose(b);
    }
  }

  /// Evaluates bone hierarchy and linear blend skinning into [skinnedPositions]
  /// and [skinnedNormals] with `0` heap allocations when pose changed.
  bool evaluateIfDirty() {
    if (!_poseDirty) {
      return false;
    }
    _poseDirty = false;

    for (var b = 0; b < bones.length; b++) {
      final pIdx = bones[b].parentIndex;
      final qOff = b * 4;
      final rOff = b * 9;
      final tOff = b * 3;
      final lx = _localTx[tOff];
      final ly = _localTx[tOff + 1];
      final lz = _localTx[tOff + 2];

      if (pIdx < 0) {
        Quaternion3D.writeMatrix3(
          _localQuat[qOff],
          _localQuat[qOff + 1],
          _localQuat[qOff + 2],
          _localQuat[qOff + 3],
          _worldRot,
          rOff,
        );
        _worldTx[tOff] = lx;
        _worldTx[tOff + 1] = ly;
        _worldTx[tOff + 2] = lz;
      } else {
        Quaternion3D.writeMatrix3(
          _localQuat[qOff],
          _localQuat[qOff + 1],
          _localQuat[qOff + 2],
          _localQuat[qOff + 3],
          _scratchRot,
        );
        final pROff = pIdx * 9;
        final pTOff = pIdx * 3;
        Quaternion3D.multiplyMatrix3(
          _worldRot,
          pROff,
          _scratchRot,
          0,
          _worldRot,
          rOff,
        );
        _worldTx[tOff] =
            _worldTx[pTOff] +
            _worldRot[pROff] * lx +
            _worldRot[pROff + 1] * ly +
            _worldRot[pROff + 2] * lz;
        _worldTx[tOff + 1] =
            _worldTx[pTOff + 1] +
            _worldRot[pROff + 3] * lx +
            _worldRot[pROff + 4] * ly +
            _worldRot[pROff + 5] * lz;
        _worldTx[tOff + 2] =
            _worldTx[pTOff + 2] +
            _worldRot[pROff + 6] * lx +
            _worldRot[pROff + 7] * ly +
            _worldRot[pROff + 8] * lz;
      }

      // Skinning translation: worldTx + worldRot * bindInvTranslation
      final bx = _bindInvX[b];
      final by = _bindInvY[b];
      final bz = _bindInvZ[b];
      _skinTx[tOff] =
          _worldTx[tOff] +
          _worldRot[rOff] * bx +
          _worldRot[rOff + 1] * by +
          _worldRot[rOff + 2] * bz;
      _skinTx[tOff + 1] =
          _worldTx[tOff + 1] +
          _worldRot[rOff + 3] * bx +
          _worldRot[rOff + 4] * by +
          _worldRot[rOff + 5] * bz;
      _skinTx[tOff + 2] =
          _worldTx[tOff + 2] +
          _worldRot[rOff + 6] * bx +
          _worldRot[rOff + 7] * by +
          _worldRot[rOff + 8] * bz;
    }

    final srcPos = baseMesh.positions;
    final srcNrm = baseMesh.normals;
    final vCount = baseMesh.vertexCount;
    var maxR2 = 0.0;
    var loZ = double.infinity;
    var hiZ = double.negativeInfinity;

    for (var v = 0; v < vCount; v++) {
      final pBase = v * 3;
      final px = srcPos[pBase];
      final py = srcPos[pBase + 1];
      final pz = srcPos[pBase + 2];
      final nx = srcNrm[pBase];
      final ny = srcNrm[pBase + 1];
      final nz = srcNrm[pBase + 2];

      final b0 = boneIndices0[v];
      final w0 = _boneW0[v];
      final w1 = 1.0 - w0;
      final r0 = b0 * 9;
      final t0 = b0 * 3;

      var ox =
          (_worldRot[r0] * px +
              _worldRot[r0 + 1] * py +
              _worldRot[r0 + 2] * pz +
              _skinTx[t0]) *
          w0;
      var oy =
          (_worldRot[r0 + 3] * px +
              _worldRot[r0 + 4] * py +
              _worldRot[r0 + 5] * pz +
              _skinTx[t0 + 1]) *
          w0;
      var oz =
          (_worldRot[r0 + 6] * px +
              _worldRot[r0 + 7] * py +
              _worldRot[r0 + 8] * pz +
              _skinTx[t0 + 2]) *
          w0;

      var onx =
          (_worldRot[r0] * nx +
              _worldRot[r0 + 1] * ny +
              _worldRot[r0 + 2] * nz) *
          w0;
      var ony =
          (_worldRot[r0 + 3] * nx +
              _worldRot[r0 + 4] * ny +
              _worldRot[r0 + 5] * nz) *
          w0;
      var onz =
          (_worldRot[r0 + 6] * nx +
              _worldRot[r0 + 7] * ny +
              _worldRot[r0 + 8] * nz) *
          w0;

      if (w1 > 1e-6) {
        final b1 = _boneIdx1[v];
        final r1 = b1 * 9;
        final t1 = b1 * 3;
        ox +=
            (_worldRot[r1] * px +
                _worldRot[r1 + 1] * py +
                _worldRot[r1 + 2] * pz +
                _skinTx[t1]) *
            w1;
        oy +=
            (_worldRot[r1 + 3] * px +
                _worldRot[r1 + 4] * py +
                _worldRot[r1 + 5] * pz +
                _skinTx[t1 + 1]) *
            w1;
        oz +=
            (_worldRot[r1 + 6] * px +
                _worldRot[r1 + 7] * py +
                _worldRot[r1 + 8] * pz +
                _skinTx[t1 + 2]) *
            w1;
        onx +=
            (_worldRot[r1] * nx +
                _worldRot[r1 + 1] * ny +
                _worldRot[r1 + 2] * nz) *
            w1;
        ony +=
            (_worldRot[r1 + 3] * nx +
                _worldRot[r1 + 4] * ny +
                _worldRot[r1 + 5] * nz) *
            w1;
        onz +=
            (_worldRot[r1 + 6] * nx +
                _worldRot[r1 + 7] * ny +
                _worldRot[r1 + 8] * nz) *
            w1;
      }

      skinnedPositions[pBase] = ox;
      skinnedPositions[pBase + 1] = oy;
      skinnedPositions[pBase + 2] = oz;

      final nLen = math.sqrt(onx * onx + ony * ony + onz * onz);
      if (nLen > 1e-7) {
        final inv = 1.0 / nLen;
        skinnedNormals[pBase] = onx * inv;
        skinnedNormals[pBase + 1] = ony * inv;
        skinnedNormals[pBase + 2] = onz * inv;
      } else {
        skinnedNormals[pBase] = 0.0;
        skinnedNormals[pBase + 1] = 0.0;
        skinnedNormals[pBase + 2] = 1.0;
      }

      final r2 = ox * ox + oy * oy + oz * oz;
      if (r2 > maxR2) {
        maxR2 = r2;
      }
      if (oz < loZ) {
        loZ = oz;
      }
      if (oz > hiZ) {
        hiZ = oz;
      }
    }

    _boundingRadius = math.sqrt(maxR2);
    _minZ = loZ.isFinite ? loZ : 0.0;
    _maxZ = hiZ.isFinite ? hiZ : 0.0;
    return true;
  }
}
