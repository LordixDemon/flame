part of 'ragdoll_controller_3d.dart';

extension _RagdollRigBuilder on RagdollController3D {
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
        rotateVectorByQuat(qBone, axis, axis);
        pEnd = pStart + axis;
      }

      var segVec = pEnd - pStart;
      var segLen = segVec.length;
      if (segLen < 1e-4) {
        segVec = Vector3(0.0, defaultBoneLength, 0.0);
        rotateVectorByQuat(qBone, segVec, segVec);
        segLen = segVec.length;
        pEnd = pStart + segVec;
      }

      final pMid = (pStart + pEnd)..scale(0.5);
      final localMidOffset = pMid - pStart;
      unrotateVectorByQuat(qBone, localMidOffset, localMidOffset);

      final localAxisDir = segVec.normalized();
      unrotateVectorByQuat(qBone, localAxisDir, localAxisDir);
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

    for (final node in model.processingOrder) {
      final isLimb = _limbByNode.containsKey(node.nodeIndex);
      var pIdx = node.parentNodeIndex;
      var markedNearestNonLimb = false;
      while (pIdx != null) {
        final parentLimb = _limbByNode[pIdx];
        if (parentLimb != null) {
          parentLimb.hasAnyDescendants = true;
          if (!isLimb && !markedNearestNonLimb) {
            parentLimb.hasNonLimbDescendants = true;
            markedNearestNonLimb = true;
          } else if (isLimb) {
            markedNearestNonLimb = true;
          }
        }
        pIdx = model.nodes[pIdx]?.parentNodeIndex;
      }
    }

    // Connect each limb to its nearest ragdoll ancestor limb via HingeJoint3D
    // or BallSocketJoint3D anchored at the child bone's world pivot.
    for (final limb in _limbs) {
      final node = model.nodes[limb.config.nodeIndex];
      if (node == null) {
        continue;
      }
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
      unrotateVectorByQuat(parentLimb.body.bodyRotation, anchorA, anchorA);

      final anchorB = pivotWorld - limb.body.bodyPosition;
      unrotateVectorByQuat(limb.body.bodyRotation, anchorB, anchorB);

      final Joint3D joint;
      if (limb.config.jointType == RagdollJointType3D.hinge) {
        // Transform bone-local hinge axis into parent body's local frame.
        final childBoneRot = Quaternion.identity();
        _extractWorldPosRot(childWorldMat, _scratchPos, childBoneRot);
        final worldHingeAxis = limb.config.hingeAxisLocal.clone();
        rotateVectorByQuat(childBoneRot, worldHingeAxis, worldHingeAxis);
        final axisInA = worldHingeAxis.clone();
        unrotateVectorByQuat(parentLimb.body.bodyRotation, axisInA, axisInA);
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

  void _extractWorldPosRot(
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
    final rMat = _rotationScratch
      ..setValues(c0x, c0y, c0z, c1x, c1y, c1z, c2x, c2y, c2z);
    rotOut.setFromRotation(rMat);
    if (rotOut.length2 > 1e-12) {
      rotOut.normalize();
    } else {
      rotOut.setValues(0.0, 0.0, 0.0, 1.0);
    }
  }
}

/// Writes `a * b` into [out] (which may be [a] or [b]) without allocating,
/// with the convention of `Quaternion.operator *`.
void _multiplyRagdollQuatInto(Quaternion a, Quaternion b, Quaternion out) {
  final x = a.x;
  final y = a.y;
  final z = a.z;
  final w = a.w;
  final ox = b.x;
  final oy = b.y;
  final oz = b.z;
  final ow = b.w;
  out.setValues(
    w * ox + x * ow + y * oz - z * oy,
    w * oy + y * ow + z * ox - x * oz,
    w * oz + z * ow + x * oy - y * ox,
    w * ow - x * ox - y * oy - z * oz,
  );
}
