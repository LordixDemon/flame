part of 'model_component.dart';

extension _ModelComponentPose on ModelComponent {
  void _evaluateAnimatedMorphTargets() {
    if (_morphNodes.isEmpty ||
        (!_animation.hasActiveEvaluation && _animation.layers.isEmpty)) {
      return;
    }
    for (var i = 0; i < _morphNodes.length; i++) {
      final node = _morphNodes[i];
      final targetCount = _animation.sampleNodeMorphWeights(
        node.nodeIndex,
        _morphScratch,
      );
      if (targetCount > 0) {
        _applyMorphWeights(node, _morphScratch, targetCount);
      }
    }
  }

  void _applyMorphWeights(ModelNode node, List<double> weights, int count) {
    final applied = _appliedMorphWeights[node.nodeIndex];
    if (applied != null && applied.length == count) {
      var same = true;
      for (var k = 0; k < count; k++) {
        if (applied[k] != weights[k]) {
          same = false;
          break;
        }
      }
      if (same) {
        return;
      }
    }
    final mesh = _ownMeshes[node.nodeIndex] ??= _copyMorphedSurfaces(
      node.mesh!,
    );
    for (final surface in mesh.surfaces) {
      if (surface.morphTargets.isNotEmpty) {
        surface.applyMorphWeights(weights, targetCount: count);
      }
    }
    mesh.updateBounds();
    final store = applied != null && applied.length == count
        ? applied
        : (_appliedMorphWeights[node.nodeIndex] = List<double>.filled(
            count,
            0.0,
          ));
    for (var k = 0; k < count; k++) {
      store[k] = weights[k];
    }
  }

  void _applyRootMotionStep(RootMotionExtractor3D extractor) {
    // The deltas are in the model's space: `position` and `rotation`
    // are in the parent's, so the step goes through this component's
    // own rotation and scale (right under any parent transform), and
    // the turn applies about the model's up axis.
    final step = _rootMotionStep
      ..setFrom(extractor.deltaPositionLocal)
      ..multiply(scale);
    // `rotation * step * conjugate(rotation)`, as the component's
    // matrix turns it (vector_math's `Quaternion.rotate` turns by the
    // inverse).
    final qx = rotation.x;
    final qy = rotation.y;
    final qz = rotation.z;
    final qw = rotation.w;
    final tx = 2.0 * (qy * step.z - qz * step.y);
    final ty = 2.0 * (qz * step.x - qx * step.z);
    final tz = 2.0 * (qx * step.y - qy * step.x);
    step.setValues(
      step.x + qw * tx + (qy * tz - qz * ty),
      step.y + qw * ty + (qz * tx - qx * tz),
      step.z + qw * tz + (qx * ty - qy * tx),
    );
    position.add(step);
    if (extractor.deltaYawRad.abs() > 1e-9) {
      final up = extractor.horizontalPlane == RootMotionPlane3D.xz
          ? ModelComponent._upY
          : ModelComponent._upZ;
      _yawDeltaQ.setAxisAngle(up, extractor.deltaYawRad);
      final x = rotation.x;
      final y = rotation.y;
      final z = rotation.z;
      final w = rotation.w;
      final ox = _yawDeltaQ.x;
      final oy = _yawDeltaQ.y;
      final oz = _yawDeltaQ.z;
      final ow = _yawDeltaQ.w;
      rotation
        ..setValues(
          w * ox + x * ow + y * oz - z * oy,
          w * oy + y * ow + z * ox - x * oz,
          w * oz + z * ow + x * oy - y * ox,
          w * ow - x * ox - y * oy - z * oz,
        )
        ..normalize();
    }
  }

  RayHit3D? _raycastImpl(
    Ray worldRay, {
    double maxDistance = double.infinity,
    CullMode? cullMode,
  }) {
    final workspace = evaluatePose();
    final world = worldTransformMatrix;
    final hasHidden = _hiddenNodes.isNotEmpty;
    final nodes = workspace.orderedNodes;
    RayHit3D? best;
    var limit = maxDistance;
    for (var i = 0; i < nodes.length; i++) {
      final node = nodes[i];
      if (hasHidden && _hiddenNodes.contains(node.node.nodeIndex)) {
        continue;
      }
      final mesh = _meshOf(node.node);
      if (mesh == null) {
        continue;
      }
      _nodeTransform
        ..setFrom(world)
        ..multiply(node.combinedTransform);
      final hit = RayHit3D.intersectMesh(
        owner: this,
        mesh: mesh,
        modelMatrix: _nodeTransform,
        worldRay: worldRay,
        maxDistance: limit,
        cullMode: cullMode,
      );
      if (hit != null && hit.distance < limit) {
        limit = hit.distance;
        best = hit;
      }
    }
    return best;
  }

  AnimationLayer3D _addOverlayLayerImpl({
    required Set<String> boneNames,
    bool includeDescendants = true,
    double weight = 1.0,
  }) {
    final indices = <int>{};
    for (final name in boneNames) {
      final idx = model.nodeIndexByName(name);
      if (idx != null) {
        indices.add(idx);
      }
    }
    if (includeDescendants && indices.isNotEmpty) {
      for (final node in model.processingOrder) {
        final p = node.parentNodeIndex;
        if (p != null && indices.contains(p)) {
          indices.add(node.nodeIndex);
        }
      }
    }
    final layer = AnimationLayer3D(nodeIndices: indices, weight: weight);
    _animation.layers.add(layer);
    _markPoseChanged();
    return layer;
  }
}

Mesh _copyMorphedSurfaces(Mesh shared) {
  final mesh = Mesh();
  for (final surface in shared.surfaces) {
    mesh.addSurface(
      surface.morphTargets.isEmpty ? surface : surface.copyWithOwnVertices(),
    );
  }
  return mesh;
}
