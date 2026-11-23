import 'dart:math' as math;

import 'package:flame_3d/collisions.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/physics.dart';
import 'package:flame_3d/src/extensions/geometry_math.dart';
import 'package:flame_3d/src/model/animation_state.dart';
import 'package:flame_3d/src/model/model.dart';
import 'package:flame_3d/src/model/model_component.dart';
import 'package:flame_3d/src/model/procedural_rigging_3d.dart';

part 'ragdoll_rig_builder_3d.dart';

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
  final Matrix4 delta = Matrix4.identity();
  bool hasPrev = false;
  bool hasAnyDescendants = false;
  bool hasNonLimbDescendants = false;
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
  ModelPoseWorkspace? _cachedWorkspace;
  List<_RagdollLimb?> _limbByOrderIndex = const [];
  List<_RagdollLimb?> _propagatedLimb = const [];

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
  final Quaternion _bodyRot = Quaternion.identity();
  final Quaternion _deltaRot = Quaternion.identity();
  final Vector3 _bodyPos = Vector3.zero();
  final Vector3 _offsetWorld = Vector3.zero();
  final Vector3 _animLocalT = Vector3.zero();
  final Quaternion _animLocalR = Quaternion.identity();
  final Vector3 _animLocalS = Vector3.all(1.0);
  final Vector3 _blendT = Vector3.zero();
  final Quaternion _blendR = Quaternion.identity();
  final Matrix3 _rotationScratch = Matrix3.zero();

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
      final bodyRot = _bodyRot;
      _multiplyRagdollQuatInto(_scratchRot, limb.boneToCapsuleRot, bodyRot);
      bodyRot.normalize();
      final offsetWorld = _offsetWorld..setFrom(limb.localMidOffset);
      rotateVectorByQuat(_scratchRot, offsetWorld, offsetWorld);
      final bodyPos = _bodyPos
        ..setFrom(_scratchPos)
        ..add(offsetWorld);

      if (limb.hasPrev && dt > 1e-6) {
        final invDt = 1.0 / dt;
        limb.body.linearVelocity.setValues(
          (bodyPos.x - limb.prevBodyPos.x) * invDt,
          (bodyPos.y - limb.prevBodyPos.y) * invDt,
          (bodyPos.z - limb.prevBodyPos.z) * invDt,
        );
        final dq = _deltaRot..setFrom(limb.prevBodyRot);
        dq.conjugate();
        _multiplyRagdollQuatInto(bodyRot, dq, dq);
        if (dq.w < 0.0) {
          dq.scale(-1.0);
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
    final ordered = workspace.orderedNodes;
    final len = ordered.length;
    if (!identical(_cachedWorkspace, workspace)) {
      _cachedWorkspace = workspace;
      _limbByOrderIndex = List<_RagdollLimb?>.generate(
        len,
        (i) => _limbByNode[ordered[i].node.nodeIndex],
        growable: false,
      );
      _propagatedLimb = List<_RagdollLimb?>.filled(len, null);
    }

    final parentOrder = workspace.parentOrderIndex;
    final limbByOrder = _limbByOrderIndex;
    final propagated = _propagatedLimb;
    final w = weight.clamp(0.0, 1.0);
    final fullWeight = w >= 1.0 - 1e-6;

    for (var i = 0; i < len; i++) {
      final p = parentOrder[i];
      final parentLimb = p >= 0 ? propagated[p] : null;
      final limb = limbByOrder[i];

      if (limb == null) {
        propagated[i] = parentLimb;
        if (parentLimb != null) {
          final cm = ordered[i].combinedTransform;
          _boneWorld
            ..setFrom(parentLimb.delta)
            ..multiply(cm);
          cm.setFrom(_boneWorld);
        }
        continue;
      }

      final bodyPos = limb.body.bodyPosition;
      final bodyRot = limb.body.bodyRotation;

      // Recover world bone transform from simulated capsule body:
      // `Q_boneWorld = Q_body * Q_capsuleToBone`
      // `P_boneWorld = P_body - Q_boneWorld * localMidOffset`
      final boneRotWorld = _bodyRot;
      _multiplyRagdollQuatInto(bodyRot, limb.capsuleToBoneRot, boneRotWorld);
      boneRotWorld.normalize();
      final midWorld = _offsetWorld..setFrom(limb.localMidOffset);
      rotateVectorByQuat(boneRotWorld, midWorld, midWorld);
      final bonePosWorld = _bodyPos
        ..setFrom(bodyPos)
        ..sub(midWorld);

      _boneWorld.setFromTranslationRotationScale(
        bonePosWorld,
        boneRotWorld,
        limb.restScale,
      );

      _localMat
        ..setFrom(invWorldMatrix)
        ..multiply(_boneWorld);

      final cm = ordered[i].combinedTransform;
      final needDelta = fullWeight
          ? limb.hasNonLimbDescendants
          : limb.hasAnyDescendants;
      if (needDelta) {
        _oldCombined.setFrom(cm);
      }

      if (fullWeight) {
        cm.setFrom(_localMat);
      } else {
        if (parentLimb != null) {
          _boneWorld
            ..setFrom(parentLimb.delta)
            ..multiply(cm);
          cm.setFrom(_boneWorld);
        }
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

      if (needDelta) {
        _invParent.copyInverse(_oldCombined);
        limb.delta
          ..setFrom(cm)
          ..multiply(_invParent);
        propagated[i] = limb;
      } else {
        propagated[i] = null;
      }
    }
  }
}
