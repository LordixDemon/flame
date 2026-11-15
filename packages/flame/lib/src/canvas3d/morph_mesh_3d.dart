import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame/src/canvas3d/mesh_3d.dart';
import 'package:flame/src/game/game.dart';

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
/// `BatchMeshRenderer3D.enqueueMorphMesh` without constructing per-frame
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
