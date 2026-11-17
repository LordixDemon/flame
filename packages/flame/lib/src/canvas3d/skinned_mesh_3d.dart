import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame/src/canvas3d/mesh_3d.dart';
import 'package:flame/src/canvas3d/quaternion_3d.dart';
import 'package:flame/src/game/game.dart';

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

/// Zero-allocation Linear Blend Skinning (LBS, up to 4 glTF-compatible bone
/// influences per vertex + per-bone squash/stretch scale) workspace
/// transforming a [Mesh3D] by an animated [Bone3D] hierarchy directly into
/// `BatchMeshRenderer3D.enqueueSkinnedMesh`.
///
/// Weights are normalised per vertex: with only `boneWeights0` the second
/// influence gets `1 - w0`; with any of `boneWeights1..3` the four weights
/// are rescaled to sum to `1`. The constructor throws a [RangeError] when a
/// weighted influence names a bone that is not in `bones`.
class SkinnedMeshWorkspace3D({
  required final Mesh3D baseMesh,
  required final List<Bone3D> bones,
  required final Uint16List boneIndices0,
  Uint16List? boneIndices1,
  Uint16List? boneIndices2,
  Uint16List? boneIndices3,
  Float32List? boneWeights0,
  Float32List? boneWeights1,
  Float32List? boneWeights2,
  Float32List? boneWeights3,
}) {
  this
    : assert(bones.isNotEmpty, 'bones must not be empty'),
      assert(
        boneIndices0.length == baseMesh.vertexCount,
        'boneIndices0 length must equal baseMesh.vertexCount',
      ) {
    final vCount = baseMesh.vertexCount;
    _boneIdx1 = boneIndices1 ?? Uint16List(vCount);
    _boneIdx2 = boneIndices2 ?? Uint16List(vCount);
    _boneIdx3 = boneIndices3 ?? Uint16List(vCount);
    assert(_boneIdx1.length == vCount, 'boneIndices1 length mismatch');
    assert(_boneIdx2.length == vCount, 'boneIndices2 length mismatch');
    assert(_boneIdx3.length == vCount, 'boneIndices3 length mismatch');

    _hasFourBoneWeights =
        boneWeights1 != null || boneWeights2 != null || boneWeights3 != null;
    _boneW0 = Float32List(vCount);
    _boneW1 = Float32List(vCount);
    _boneW2 = Float32List(vCount);
    _boneW3 = Float32List(vCount);

    if (!_hasFourBoneWeights) {
      if (boneWeights0 != null) {
        assert(boneWeights0.length == vCount, 'boneWeights0 length mismatch');
        for (var v = 0; v < vCount; v++) {
          final w0 = boneWeights0[v].clamp(0.0, 1.0);
          _boneW0[v] = w0;
          _boneW1[v] = 1.0 - w0;
        }
      } else {
        _boneW0.fillRange(0, vCount, 1.0);
      }
    } else {
      for (var v = 0; v < vCount; v++) {
        final w0 = math.max(0.0, boneWeights0 != null ? boneWeights0[v] : 1.0);
        final w1 = math.max(0.0, boneWeights1 != null ? boneWeights1[v] : 0.0);
        final w2 = math.max(0.0, boneWeights2 != null ? boneWeights2[v] : 0.0);
        final w3 = math.max(0.0, boneWeights3 != null ? boneWeights3[v] : 0.0);
        final sum = w0 + w1 + w2 + w3;
        if (sum > 1e-7) {
          final inv = 1.0 / sum;
          _boneW0[v] = w0 * inv;
          _boneW1[v] = w1 * inv;
          _boneW2[v] = w2 * inv;
          _boneW3[v] = w3 * inv;
        } else {
          _boneW0[v] = 1.0;
        }
      }
    }

    final bCount = bones.length;
    _localTx = Float32List(bCount * 3);
    _localQuat = Float32List(bCount * 4);
    _localScale = Float32List(bCount * 3)..fillRange(0, bCount * 3, 1.0);
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

    // Every influence that carries weight must name an existing bone;
    // otherwise `evaluateIfDirty` would fail later with an out-of-range read
    // deep inside the skinning loop. Influences with zero weight are never
    // read (apart from the primary one) and may hold any index.
    for (var v = 0; v < vCount; v++) {
      _checkBoneIndex(boneIndices0[v], bCount, v, 0);
      if (_boneW1[v] > 1e-6) {
        _checkBoneIndex(_boneIdx1[v], bCount, v, 1);
      }
      if (_boneW2[v] > 1e-6) {
        _checkBoneIndex(_boneIdx2[v], bCount, v, 2);
      }
      if (_boneW3[v] > 1e-6) {
        _checkBoneIndex(_boneIdx3[v], bCount, v, 3);
      }
    }

    skinnedPositions.setAll(0, baseMesh.positions);
    skinnedNormals.setAll(0, baseMesh.normals);
  }

  static void _checkBoneIndex(int bone, int boneCount, int vertex, int slot) {
    if (bone >= boneCount) {
      throw RangeError(
        'boneIndices$slot[$vertex] = $bone, but the skeleton has only '
        '$boneCount bones',
      );
    }
  }

  /// Skinned vertex positions (`vertexCount * 3`).
  late final Float32List skinnedPositions = Float32List(
    baseMesh.positions.length,
  );

  /// Skinned unit vertex normals (`vertexCount * 3`).
  late final Float32List skinnedNormals = Float32List(baseMesh.normals.length);

  late final Uint16List _boneIdx1;
  late final Uint16List _boneIdx2;
  late final Uint16List _boneIdx3;
  late final Float32List _boneW0;
  late final Float32List _boneW1;
  late final Float32List _boneW2;
  late final Float32List _boneW3;
  late final bool _hasFourBoneWeights;
  late final Float32List _localTx;
  late final Float32List _localQuat;
  late final Float32List _localScale;
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

  /// Finds the index of the bone named [name], or `-1` if absent.
  int findBoneIndex(String name) {
    for (var i = 0; i < bones.length; i++) {
      if (bones[i].name == name) {
        return i;
      }
    }
    return -1;
  }

  /// Reads the current local pose `(dx, dy, dz, qx, qy, qz, qw, sx, sy, sz)` of
  /// [boneIndex] relative to its rest bind translation.
  ({
    double dx,
    double dy,
    double dz,
    double qx,
    double qy,
    double qz,
    double qw,
    double sx,
    double sy,
    double sz,
  })
  getBoneLocalPose(int boneIndex) {
    final bone = bones[boneIndex];
    final tBase = boneIndex * 3;
    final qBase = boneIndex * 4;
    return (
      dx: _localTx[tBase] - bone.bindLocalX,
      dy: _localTx[tBase + 1] - bone.bindLocalY,
      dz: _localTx[tBase + 2] - bone.bindLocalZ,
      qx: _localQuat[qBase],
      qy: _localQuat[qBase + 1],
      qz: _localQuat[qBase + 2],
      qw: _localQuat[qBase + 3],
      sx: _localScale[tBase],
      sy: _localScale[tBase + 1],
      sz: _localScale[tBase + 2],
    );
  }

  /// Sets local pose rotation (unit quaternion), optional local translation
  /// offset `(dx, dy, dz)` relative to bind pose, and optional local scale
  /// `(sx, sy, sz)` for bone [boneIndex].
  void setBonePose(
    int boneIndex, {
    double qx = 0.0,
    double qy = 0.0,
    double qz = 0.0,
    double qw = 1.0,
    double dx = 0.0,
    double dy = 0.0,
    double dz = 0.0,
    double sx = 1.0,
    double sy = 1.0,
    double sz = 1.0,
  }) {
    final bone = bones[boneIndex];
    final tBase = boneIndex * 3;
    final qBase = boneIndex * 4;
    _localTx[tBase] = bone.bindLocalX + dx;
    _localTx[tBase + 1] = bone.bindLocalY + dy;
    _localTx[tBase + 2] = bone.bindLocalZ + dz;
    _localScale[tBase] = sx;
    _localScale[tBase + 1] = sy;
    _localScale[tBase + 2] = sz;
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

  /// Evaluates bone hierarchy and linear blend skinning (up to 4 bone
  /// influences per vertex) into [skinnedPositions] and [skinnedNormals] with
  /// `0` heap allocations when pose changed.
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
      final sx = _localScale[tOff];
      final sy = _localScale[tOff + 1];
      final sz = _localScale[tOff + 2];

      Quaternion3D.writeMatrix3(
        _localQuat[qOff],
        _localQuat[qOff + 1],
        _localQuat[qOff + 2],
        _localQuat[qOff + 3],
        _scratchRot,
      );
      if (sx != 1.0 || sy != 1.0 || sz != 1.0) {
        _scratchRot[0] *= sx;
        _scratchRot[3] *= sx;
        _scratchRot[6] *= sx;
        _scratchRot[1] *= sy;
        _scratchRot[4] *= sy;
        _scratchRot[7] *= sy;
        _scratchRot[2] *= sz;
        _scratchRot[5] *= sz;
        _scratchRot[8] *= sz;
      }

      if (pIdx < 0) {
        for (var k = 0; k < 9; k++) {
          _worldRot[rOff + k] = _scratchRot[k];
        }
        _worldTx[tOff] = lx;
        _worldTx[tOff + 1] = ly;
        _worldTx[tOff + 2] = lz;
      } else {
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
      final w1 = _boneW1[v];
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

      if (_hasFourBoneWeights) {
        final w2 = _boneW2[v];
        if (w2 > 1e-6) {
          final b2 = _boneIdx2[v];
          final r2 = b2 * 9;
          final t2 = b2 * 3;
          ox +=
              (_worldRot[r2] * px +
                  _worldRot[r2 + 1] * py +
                  _worldRot[r2 + 2] * pz +
                  _skinTx[t2]) *
              w2;
          oy +=
              (_worldRot[r2 + 3] * px +
                  _worldRot[r2 + 4] * py +
                  _worldRot[r2 + 5] * pz +
                  _skinTx[t2 + 1]) *
              w2;
          oz +=
              (_worldRot[r2 + 6] * px +
                  _worldRot[r2 + 7] * py +
                  _worldRot[r2 + 8] * pz +
                  _skinTx[t2 + 2]) *
              w2;
          onx +=
              (_worldRot[r2] * nx +
                  _worldRot[r2 + 1] * ny +
                  _worldRot[r2 + 2] * nz) *
              w2;
          ony +=
              (_worldRot[r2 + 3] * nx +
                  _worldRot[r2 + 4] * ny +
                  _worldRot[r2 + 5] * nz) *
              w2;
          onz +=
              (_worldRot[r2 + 6] * nx +
                  _worldRot[r2 + 7] * ny +
                  _worldRot[r2 + 8] * nz) *
              w2;
        }
        final w3 = _boneW3[v];
        if (w3 > 1e-6) {
          final b3 = _boneIdx3[v];
          final r3 = b3 * 9;
          final t3 = b3 * 3;
          ox +=
              (_worldRot[r3] * px +
                  _worldRot[r3 + 1] * py +
                  _worldRot[r3 + 2] * pz +
                  _skinTx[t3]) *
              w3;
          oy +=
              (_worldRot[r3 + 3] * px +
                  _worldRot[r3 + 4] * py +
                  _worldRot[r3 + 5] * pz +
                  _skinTx[t3 + 1]) *
              w3;
          oz +=
              (_worldRot[r3 + 6] * px +
                  _worldRot[r3 + 7] * py +
                  _worldRot[r3 + 8] * pz +
                  _skinTx[t3 + 2]) *
              w3;
          onx +=
              (_worldRot[r3] * nx +
                  _worldRot[r3 + 1] * ny +
                  _worldRot[r3 + 2] * nz) *
              w3;
          ony +=
              (_worldRot[r3 + 3] * nx +
                  _worldRot[r3 + 4] * ny +
                  _worldRot[r3 + 5] * nz) *
              w3;
          onz +=
              (_worldRot[r3 + 6] * nx +
                  _worldRot[r3 + 7] * ny +
                  _worldRot[r3 + 8] * nz) *
              w3;
        }
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
