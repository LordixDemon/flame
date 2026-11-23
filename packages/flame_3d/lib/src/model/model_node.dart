import 'package:flame_3d/core.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/src/model/animation_state.dart';

/// A node wraps over a mesh as part of a 3D model, including its joints and
/// local transformations.
class ModelNode {
  final String? name;
  final int nodeIndex;
  final int? parentNodeIndex;
  final Matrix4 transform;
  final Mesh? mesh;
  final Map<int, ModelJoint> joints;

  /// Rest-pose TRS components decomposed once from [transform] for
  /// allocation-free animation blending.
  final Vector3 restTranslation = Vector3.zero();
  final Quaternion restRotation = Quaternion.identity();
  final Vector3 restScale = Vector3.all(1.0);

  ModelNode({
    required this.name,
    required this.nodeIndex,
    required this.parentNodeIndex,
    required this.transform,
    required this.mesh,
    required this.joints,
  }) {
    transform.decompose(restTranslation, restRotation, restScale);
  }

  List<int> get dependencies => [
    ?parentNodeIndex,
    for (final joint in joints.values) joint.nodeIndex,
  ];

  ModelNode.simple({
    required this.nodeIndex,
    required this.mesh,
  }) : name = null,
       parentNodeIndex = null,
       transform = Matrix4.identity(),
       joints = {};

  /// Ordered global joint indices per surface index, computed once on first
  /// access so per-frame skinning never sorts or allocates lists.
  late final Map<int, List<int>> orderedJointIndicesPerSurface =
      _buildOrderedJointIndices();

  Map<int, List<int>> _buildOrderedJointIndices() {
    final result = <int, List<int>>{};
    final surfaces = mesh?.surfaces;
    if (surfaces == null) {
      return result;
    }
    var index = 0;
    for (final surface in surfaces) {
      final map = surface.jointMap;
      if (map != null) {
        final entries = map.entries.toList()
          ..sort((a, b) => a.value.compareTo(b.value));
        final ordered = List<int>.generate(
          entries.length,
          (i) => entries[i].key,
          growable: false,
        );
        for (final jointIndex in ordered) {
          if (!joints.containsKey(jointIndex)) {
            throw StateError('Missing joint $jointIndex');
          }
        }
        result[index] = ordered;
      }
      index++;
    }
    return result;
  }

  void processNode(
    Map<int, ProcessedNode> processedNodes,
    AnimationState animation,
  ) {
    final resultMatrix = Matrix4.identity();
    evaluateNodeInto(processedNodes, animation, resultMatrix, _scratchLocal);
    final jointTransforms = computeJointsPerSurface(
      processedNodes,
      nodeCombinedTransform: resultMatrix,
    );

    processedNodes[nodeIndex] = ProcessedNode(
      node: this,
      combinedTransform: resultMatrix,
      jointTransforms: jointTransforms,
    );
  }

  /// Writes `parentCombined * animatedLocal` into [combinedOut] without
  /// allocating.
  void evaluateNodeInto(
    Map<int, ProcessedNode> processedNodes,
    AnimationState animation,
    Matrix4 combinedOut,
    Matrix4 localScratch,
  ) {
    animation.writeNodeTransform(
      nodeIndex,
      restTranslation,
      restRotation,
      restScale,
      transform,
      localScratch,
    );
    final parentIdx = parentNodeIndex;
    if (parentIdx != null) {
      combinedOut
        ..setFrom(processedNodes[parentIdx]!.combinedTransform)
        ..multiply(localScratch);
    } else {
      combinedOut.setFrom(localScratch);
    }
  }

  /// Updates the preallocated [jointTransformsOut] matrices in place without
  /// allocating.
  ///
  /// The matrices are relative to this node, see [computeJointsPerSurface].
  /// This node's own entry in [processedNodes] must already hold its combined
  /// transform for the current pose.
  void updateJointsInPlace(
    Map<int, ProcessedNode> processedNodes,
    Map<int, List<Matrix4>> jointTransformsOut,
  ) {
    final meshInverse = _meshSpaceInverse(
      processedNodes[nodeIndex]?.combinedTransform,
    );
    for (final entry in orderedJointIndicesPerSurface.entries) {
      final ordered = entry.value;
      final outList = jointTransformsOut[entry.key]!;
      for (var i = 0; i < ordered.length; i++) {
        final joint = joints[ordered[i]]!;
        _writeJointMatrix(
          outList[i],
          joint,
          processedNodes[joint.nodeIndex],
          meshInverse,
        );
      }
    }
  }

  /// Computes the joint matrices of every skinned surface of this node, by
  /// surface index, in the order of each surface's `Surface.jointMap`.
  ///
  /// glTF skins a mesh with its joints only: the transform of the node that
  /// carries the skinned mesh is ignored. Renderers, however, draw a node's
  /// mesh with the node's combined transform (`ModelComponent`,
  /// `SkinnedCrowdBatch3D`), so every matrix is made relative to this node:
  ///
  /// `inverse(nodeCombined) * jointCombined * inverseBindMatrix`
  ///
  /// and `nodeCombined * matrix` is the joint's model-space skinning matrix,
  /// whatever transform this node or its ancestors have. When this node's
  /// combined transform is singular (a zero scale), the matrices stay in model
  /// space and the mesh collapses with the node.
  ///
  /// [nodeCombinedTransform] is this node's combined transform for the pose in
  /// [processedNodes]; when `null`, it is read from this node's entry in
  /// [processedNodes] (identity when absent).
  Map<int, List<Matrix4>> computeJointsPerSurface(
    Map<int, ProcessedNode> processedNodes, {
    Matrix4? nodeCombinedTransform,
  }) {
    final meshInverse = _meshSpaceInverse(
      nodeCombinedTransform ?? processedNodes[nodeIndex]?.combinedTransform,
    );
    final jointTransformsPerSurface = <int, List<Matrix4>>{};
    for (final entry in orderedJointIndicesPerSurface.entries) {
      final ordered = entry.value;
      final list = List<Matrix4>.generate(ordered.length, (i) {
        final joint = joints[ordered[i]]!;
        final out = Matrix4.identity();
        _writeJointMatrix(
          out,
          joint,
          processedNodes[joint.nodeIndex],
          meshInverse,
        );
        return out;
      }, growable: false);
      jointTransformsPerSurface[entry.key] = list;
    }
    return jointTransformsPerSurface;
  }

  /// Writes the inverse of [combined] into a shared scratch matrix and returns
  /// it, or returns `null` when no correction is needed (no skin, identity or
  /// singular transform).
  Matrix4? _meshSpaceInverse(Matrix4? combined) {
    if (combined == null || joints.isEmpty || combined.isIdentity()) {
      return null;
    }
    final determinant = _meshInverse.copyInverse(combined);
    return determinant == 0.0 ? null : _meshInverse;
  }

  static void _writeJointMatrix(
    Matrix4 out,
    ModelJoint joint,
    ProcessedNode? jointNode,
    Matrix4? meshInverse,
  ) {
    if (meshInverse != null) {
      out.setFrom(meshInverse);
      if (jointNode != null) {
        out.multiply(jointNode.combinedTransform);
      }
      out.multiply(joint.inverseBindMatrix);
    } else if (jointNode != null) {
      out
        ..setFrom(jointNode.combinedTransform)
        ..multiply(joint.inverseBindMatrix);
    } else {
      out.setFrom(joint.inverseBindMatrix);
    }
  }

  static final Matrix4 _meshInverse = Matrix4.identity();
  static final Matrix4 _scratchLocal = Matrix4.identity();
}

/// A single joint inside a [ModelNode].
class ModelJoint({
  required final int nodeIndex,
  required final Matrix4 inverseBindMatrix,
});

/// A post-processed node including the final transforms after animations are
/// applied.
///
/// [combinedTransform] is the node's transform in the model's space.
/// [jointTransforms] holds, by surface index, the joint matrices of the node's
/// skinned surfaces, relative to the node: draw the mesh with
/// `componentWorld * combinedTransform` and these matrices (see
/// [ModelNode.computeJointsPerSurface]).
class ProcessedNode({
  required final ModelNode node,
  required final Matrix4 combinedTransform,
  required final Map<int, List<Matrix4>> jointTransforms,
});
