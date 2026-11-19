import 'dart:math' as math;

import 'package:flame_3d/collisions.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/model.dart';
import 'package:flame_3d/physics.dart';
import 'package:flutter_test/flutter_test.dart';

ModelAnimation _translationClip(
  String name, {
  required double duration,
  required Vector3 start,
  required Vector3 end,
  int nodeIndex = 0,
  List<AnimationEvent3D> events = const [],
}) {
  return ModelAnimation(
    name: name,
    events: events,
    nodes: {
      nodeIndex: NodeAnimation(
        channels: [
          AnimationController(
            animation: TranslationAnimationSpline.from(
              interpolation: AnimationInterpolation.linear,
              times: [0.0, duration],
              values: [start, end],
            ),
          ),
        ],
      ),
    },
  );
}

Model _singleNodeModel(List<ModelAnimation> animations) {
  return Model(
    nodes: {
      0: ModelNode(
        name: 'Root',
        nodeIndex: 0,
        parentNodeIndex: null,
        transform: Matrix4.identity(),
        mesh: null,
        joints: const {},
      ),
    },
    animations: animations,
  );
}

Model _buildChainRig(int count, {double segLength = 0.5}) {
  final nodes = <int, ModelNode>{};
  for (var i = 0; i < count; i++) {
    nodes[i] = ModelNode(
      name: 'Joint_$i',
      nodeIndex: i,
      parentNodeIndex: i == 0 ? null : i - 1,
      transform: i == 0
          ? Matrix4.identity()
          : Matrix4.translationValues(0.0, segLength, 0.0),
      mesh: null,
      joints: const {},
    );
  }
  return Model(nodes: nodes, animations: const []);
}

Model _buildBipedRig({
  required double scale,
  String prefix = '',
  Quaternion? upperArmRestRot,
}) {
  final armRot = upperArmRestRot ?? Quaternion.identity();
  Matrix4 trs(Vector3 t, [Quaternion? r]) {
    return Matrix4.compose(
      t * scale,
      r ?? Quaternion.identity(),
      Vector3.all(1.0),
    );
  }

  return Model(
    nodes: {
      0: ModelNode(
        name: '${prefix}Hips',
        nodeIndex: 0,
        parentNodeIndex: null,
        transform: trs(Vector3(0.0, 1.0, 0.0)),
        mesh: null,
        joints: const {},
      ),
      1: ModelNode(
        name: '${prefix}Spine',
        nodeIndex: 1,
        parentNodeIndex: 0,
        transform: trs(Vector3(0.0, 0.25, 0.0)),
        mesh: null,
        joints: const {},
      ),
      2: ModelNode(
        name: '${prefix}Chest',
        nodeIndex: 2,
        parentNodeIndex: 1,
        transform: trs(Vector3(0.0, 0.25, 0.0)),
        mesh: null,
        joints: const {},
      ),
      3: ModelNode(
        name: '${prefix}Head',
        nodeIndex: 3,
        parentNodeIndex: 2,
        transform: trs(Vector3(0.0, 0.25, 0.0)),
        mesh: null,
        joints: const {},
      ),
      4: ModelNode(
        name: '${prefix}LeftArm',
        nodeIndex: 4,
        parentNodeIndex: 2,
        transform: trs(Vector3(-0.2, 0.15, 0.0), armRot),
        mesh: null,
        joints: const {},
      ),
      5: ModelNode(
        name: '${prefix}LeftForeArm',
        nodeIndex: 5,
        parentNodeIndex: 4,
        transform: Matrix4.translationValues(-0.3 * scale, 0.0, 0.0),
        mesh: null,
        joints: const {},
      ),
      6: ModelNode(
        name: '${prefix}LeftUpLeg',
        nodeIndex: 6,
        parentNodeIndex: 0,
        transform: trs(Vector3(-0.15, 0.0, 0.0)),
        mesh: null,
        joints: const {},
      ),
      7: ModelNode(
        name: '${prefix}LeftLeg',
        nodeIndex: 7,
        parentNodeIndex: 6,
        transform: trs(Vector3(0.0, -0.5, 0.0)),
        mesh: null,
        joints: const {},
      ),
      8: ModelNode(
        name: '${prefix}LeftFoot',
        nodeIndex: 8,
        parentNodeIndex: 7,
        transform: trs(Vector3(0.0, -0.5, 0.0)),
        mesh: null,
        joints: const {},
      ),
      9: ModelNode(
        name: '${prefix}RightUpLeg',
        nodeIndex: 9,
        parentNodeIndex: 0,
        transform: trs(Vector3(0.15, 0.0, 0.0)),
        mesh: null,
        joints: const {},
      ),
      10: ModelNode(
        name: '${prefix}RightLeg',
        nodeIndex: 10,
        parentNodeIndex: 9,
        transform: trs(Vector3(0.0, -0.5, 0.0)),
        mesh: null,
        joints: const {},
      ),
      11: ModelNode(
        name: '${prefix}RightFoot',
        nodeIndex: 11,
        parentNodeIndex: 10,
        transform: trs(Vector3(0.0, -0.5, 0.0)),
        mesh: null,
        joints: const {},
      ),
    },
    animations: const [],
  );
}

void main() {
  group('AnimationStateMachine3D (Declarative AnimGraph / HFSM)', () {
    test(
      'evaluates blackboard params, 1D/2D blend spaces, nested SubStateMachine3D, '
      'any-state triggers, exitTime, and phase-synced gait transfer',
      () {
        final idle = _translationClip(
          'idle',
          duration: 1.0,
          start: Vector3.zero(),
          end: Vector3.zero(),
        );
        final walk = _translationClip(
          'walk',
          duration: 1.2,
          start: Vector3.zero(),
          end: Vector3(4.0, 0.0, 0.0),
        );
        final run = _translationClip(
          'run',
          duration: 0.6,
          start: Vector3.zero(),
          end: Vector3(12.0, 0.0, 0.0),
        );
        final strafeL = _translationClip(
          'strafeL',
          duration: 1.0,
          start: Vector3(-2.0, 0.0, 0.0),
          end: Vector3(-2.0, 0.0, 0.0),
        );
        final strafeR = _translationClip(
          'strafeR',
          duration: 1.0,
          start: Vector3(2.0, 0.0, 0.0),
          end: Vector3(2.0, 0.0, 0.0),
        );
        final slash1 = _translationClip(
          'slash1',
          duration: 0.5,
          start: Vector3(0.0, 1.0, 0.0),
          end: Vector3(0.0, 2.0, 0.0),
        );
        final slash2 = _translationClip(
          'slash2',
          duration: 0.5,
          start: Vector3(0.0, 3.0, 0.0),
          end: Vector3(0.0, 4.0, 0.0),
        );
        final hitReact = _translationClip(
          'hit',
          duration: 0.4,
          start: Vector3(0.0, 0.0, -3.0),
          end: Vector3.zero(),
        );

        final loco1D = BlendSpace1D(
          samples: [
            BlendSample1D(animation: idle, position: 0.0),
            BlendSample1D(animation: walk, position: 2.0),
          ],
        );
        final strafe2D = BlendSpace2D(
          samples: [
            BlendSample2D(animation: strafeL, point: Vector2(-1.0, 0.0)),
            BlendSample2D(animation: strafeR, point: Vector2(1.0, 0.0)),
          ],
        );

        final combatSub = SubStateMachine3D(
          name: 'combat',
          initialState: 'slash1',
          states: [
            ClipAnimState3D(
              name: 'slash1',
              animation: slash1,
              playMode: AnimationPlayMode.once,
            ),
            ClipAnimState3D(
              name: 'slash2',
              animation: slash2,
              playMode: AnimationPlayMode.once,
            ),
          ],
          transitions: [
            AnimTransition3D(
              fromState: 'slash1',
              toState: 'slash2',
              exitTime: 0.8,
              crossFadeDuration: 0.1,
              conditions: const [AnimCondition3D.equals('comboStep', 2)],
            ),
          ],
        );

        final sm = AnimationStateMachine3D(
          initialState: 'loco',
          states: [
            Blend1DAnimState3D(
              name: 'loco',
              space: loco1D,
              parameter: 'speed',
              syncGroup: 'gait',
            ),
            ClipAnimState3D(
              name: 'sprint',
              animation: run,
              syncGroup: 'gait',
            ),
            Blend2DAnimState3D(
              name: 'lockOn',
              space: strafe2D,
              paramX: 'moveX',
              paramY: 'moveY',
            ),
            combatSub,
            ClipAnimState3D(
              name: 'hit',
              animation: hitReact,
              playMode: AnimationPlayMode.once,
            ),
          ],
          transitions: [
            AnimTransition3D(
              fromState: AnimTransition3D.anyState,
              toState: 'hit',
              crossFadeDuration: 0.05,
              canTransitionToSelf: true,
              conditions: const [AnimCondition3D.onTrigger('takeHit')],
            ),
            AnimTransition3D(
              fromState: 'hit',
              toState: 'loco',
              exitTime: 1.0,
              crossFadeDuration: 0.1,
            ),
            AnimTransition3D(
              fromState: 'loco',
              toState: 'sprint',
              crossFadeDuration: 0.15,
              syncNormalizedPhase: true,
              conditions: const [AnimCondition3D.greater('speed', 4.5)],
            ),
            AnimTransition3D(
              fromState: 'sprint',
              toState: 'lockOn',
              crossFadeDuration: 0.0,
              conditions: const [AnimCondition3D.ifTrue('lockedOn')],
            ),
            AnimTransition3D(
              fromState: 'lockOn',
              toState: 'combat',
              crossFadeDuration: 0.0,
              conditions: const [AnimCondition3D.onTrigger('attack')],
            ),
            AnimTransition3D(
              fromState: 'combat',
              toState: 'loco',
              exitTime: 1.0,
              crossFadeDuration: 0.1,
              conditions: const [AnimCondition3D.ifFalse('lockedOn')],
            ),
          ],
        );

        final model = _singleNodeModel([
          idle,
          walk,
          run,
          strafeL,
          strafeR,
          slash1,
          slash2,
          hitReact,
        ]);
        final comp = ModelComponent(model: model, stateMachine: sm);
        expect(sm.currentStateName, 'loco');

        // 1. Walk inside BlendSpace1D to 50% gait phase (`0.6s / 1.2s = 0.5`).
        sm.setFloat('speed', 2.0);
        comp.update(0.6);
        expect(comp.animationState.normalizedPhase, closeTo(0.5, 1e-4));

        // 2. Increase speed > 4.5 -> transitions to `sprint` (dur 0.6s) with
        // `syncNormalizedPhase: true`, transferring phase 0.5 -> clock 0.3s!
        sm.setFloat('speed', 5.5);
        comp.update(0.0);
        expect(sm.currentStateName, 'sprint');
        expect(comp.animationState.clock, closeTo(0.3, 1e-4));
        expect(comp.animationState.isCrossFading, isTrue);

        // 3. Switch to 2D BlendSpace (`lockOn`) and verify `(moveX, moveY)`.
        sm
          ..setBool('lockedOn', true)
          ..setFloat('moveX', 1.0)
          ..setFloat('moveY', 0.0);
        comp.update(0.05);
        expect(sm.currentStateName, 'lockOn');
        expect(comp.nodeTransform(0)!.getTranslation().x, closeTo(2.0, 1e-4));

        // 4. Enter nested `SubStateMachine3D` (`combat/slash1`) via trigger,
        // verifying trigger auto-consumption!
        sm
          ..setInt('comboStep', 2)
          ..setTrigger('attack');
        expect(sm.isTriggerSet('attack'), isTrue);
        comp.update(0.01);
        expect(sm.isTriggerSet('attack'), isFalse);
        expect(sm.activeStatePath, ['combat', 'slash1']);

        // Before `exitTime: 0.8` (`0.4s`), stays in `slash1`.
        comp.update(0.25);
        expect(sm.currentStateName, 'slash1');

        // Crossing `0.4s` (`>= 80%` of `0.5s`) advances to `combat/slash2`!
        comp.update(0.2);
        expect(sm.activeStatePath, ['combat', 'slash2']);

        // 5. Global `'any'` trigger interrupts `combat/slash2` into `hit` AND
        // supports `canTransitionToSelf: true` re-triggering!
        sm.setTrigger('takeHit');
        comp.update(0.1);
        expect(sm.currentStateName, 'hit');
        final prevTransitions = sm.transitionCount;
        sm.setTrigger('takeHit');
        comp.update(0.05);
        expect(sm.currentStateName, 'hit');
        expect(sm.transitionCount, prevTransitions + 1);

        // Finishing `hit` (`0.4s`) auto-exits at `exitTime: 1.0` to `loco`.
        sm.setFloat('speed', 0.0);
        comp.update(0.5);
        expect(sm.currentStateName, 'loco');

        // Verify `resetTrigger` clears an armed trigger before firing.
        sm
          ..setTrigger('takeHit')
          ..resetTrigger('takeHit');
        expect(sm.isTriggerSet('takeHit'), isFalse);
      },
    );
  });

  group('HumanoidProfile3D & AnimationRetargeter3D', () {
    test(
      'autoDetect maps Mixamo / VRM / Rigify skeletons and retargetClip '
      'conjugates differing rest rotations + scales hips translation',
      () {
        // Source rig: Mixamo naming, scale 1.0 (`hipsRestHeight = 1.0`), AND
        // LeftArm has a 90-degree Z local bind rotation!
        final srcBindRot = Quaternion.axisAngle(
          Vector3(0.0, 0.0, 1.0),
          -math.pi * 0.5,
        );
        final srcModel = _buildBipedRig(
          scale: 1.0,
          prefix: 'mixamorig:',
          upperArmRestRot: srcBindRot,
        );
        // Target rig: VRM naming, 1.8x taller (`hipsRestHeight = 1.8`), with
        // identity LeftUpperArm bind rotation!
        final vrmModel = Model(
          nodes: {
            0: ModelNode(
              name: 'J_Bip_C_Hips',
              nodeIndex: 0,
              parentNodeIndex: null,
              transform: Matrix4.translationValues(0.0, 1.8, 0.0),
              mesh: null,
              joints: const {},
            ),
            1: ModelNode(
              name: 'J_Bip_C_Spine',
              nodeIndex: 1,
              parentNodeIndex: 0,
              transform: Matrix4.translationValues(0.0, 0.45, 0.0),
              mesh: null,
              joints: const {},
            ),
            2: ModelNode(
              name: 'J_Bip_C_Chest',
              nodeIndex: 2,
              parentNodeIndex: 1,
              transform: Matrix4.translationValues(0.0, 0.45, 0.0),
              mesh: null,
              joints: const {},
            ),
            4: ModelNode(
              name: 'J_Bip_L_UpperArm',
              nodeIndex: 4,
              parentNodeIndex: 2,
              transform: Matrix4.translationValues(-0.36, 0.27, 0.0),
              mesh: null,
              joints: const {},
            ),
            5: ModelNode(
              name: 'J_Bip_L_LowerArm',
              nodeIndex: 5,
              parentNodeIndex: 4,
              transform: Matrix4.translationValues(-0.54, 0.0, 0.0),
              mesh: null,
              joints: const {},
            ),
          },
          animations: const [],
        );

        final srcProfile = HumanoidProfile3D.autoDetect(srcModel);
        final dstProfile = HumanoidProfile3D.autoDetect(vrmModel);

        expect(srcProfile.nodeIndexFor(HumanoidBone3D.hips), 0);
        expect(srcProfile.nodeIndexFor(HumanoidBone3D.leftUpperArm), 4);
        expect(srcProfile.nodeIndexFor(HumanoidBone3D.leftLowerLeg), 7);
        expect(dstProfile.nodeIndexFor(HumanoidBone3D.hips), 0);
        expect(dstProfile.nodeIndexFor(HumanoidBone3D.leftUpperArm), 4);
        expect(srcProfile.hipsRestHeight, closeTo(1.0, 1e-5));
        expect(dstProfile.hipsRestHeight, closeTo(1.8, 1e-5));

        // Also check Rigify naming (`DEF-thigh.L`, `DEF-shin.L`, `DEF-foot.L`).
        final rigifyModel = Model(
          nodes: {
            0: ModelNode(
              name: 'DEF-spine',
              nodeIndex: 0,
              parentNodeIndex: null,
              transform: Matrix4.translationValues(0.0, 0.95, 0.0),
              mesh: null,
              joints: const {},
            ),
            1: ModelNode(
              name: 'DEF-thigh.L',
              nodeIndex: 1,
              parentNodeIndex: 0,
              transform: Matrix4.identity(),
              mesh: null,
              joints: const {},
            ),
            2: ModelNode(
              name: 'DEF-shin.L',
              nodeIndex: 2,
              parentNodeIndex: 1,
              transform: Matrix4.identity(),
              mesh: null,
              joints: const {},
            ),
            3: ModelNode(
              name: 'DEF-foot.L',
              nodeIndex: 3,
              parentNodeIndex: 2,
              transform: Matrix4.identity(),
              mesh: null,
              joints: const {},
            ),
          },
          animations: const [],
        );
        final rigifyProfile = HumanoidProfile3D.autoDetect(rigifyModel);
        expect(rigifyProfile.nodeIndexFor(HumanoidBone3D.hips), 0);
        expect(rigifyProfile.nodeIndexFor(HumanoidBone3D.leftUpperLeg), 1);
        expect(rigifyProfile.nodeIndexFor(HumanoidBone3D.leftLowerLeg), 2);
        expect(rigifyProfile.nodeIndexFor(HumanoidBone3D.leftFoot), 3);

        // Animate source rig:
        // - Hips steps +0.5m forward along +Z and +0.1m up (`y: 1.0 -> 1.1`).
        // - LeftArm swings +90 deg around world +Y (`Ry(+pi/2) * srcBindRot`),
        //   turning the `-X` T-pose arm forward to point along `+Z`!
        final worldSwingY90 = Quaternion.axisAngle(
          Vector3(0.0, 1.0, 0.0),
          math.pi * 0.5,
        );
        final srcAnimatedArmRot = (worldSwingY90 * srcBindRot)..normalize();

        final srcClip = ModelAnimation(
          name: 'lunge',
          events: [AnimationEvent3D(name: 'plant', time: 0.5)],
          nodes: {
            0: NodeAnimation(
              channels: [
                AnimationController(
                  animation: TranslationAnimationSpline.from(
                    interpolation: AnimationInterpolation.linear,
                    times: const [0.0, 1.0],
                    values: [
                      Vector3(0.0, 1.0, 0.0),
                      Vector3(0.0, 1.1, 0.5),
                    ],
                  ),
                ),
              ],
            ),
            4: NodeAnimation(
              channels: [
                AnimationController(
                  animation: RotationAnimationSpline.from(
                    interpolation: AnimationInterpolation.linear,
                    times: const [0.0, 1.0],
                    values: [srcBindRot, srcAnimatedArmRot],
                  ),
                ),
              ],
            ),
          },
        );

        final retargeted = AnimationRetargeter3D.retargetClip(
          srcClip,
          sourceProfile: srcProfile,
          targetProfile: dstProfile,
          newName: 'vrm_lunge',
        );
        expect(retargeted.name, 'vrm_lunge');
        expect(retargeted.events, hasLength(1));

        final targetComp = ModelComponent(model: vrmModel);
        targetComp.animationState
          ..startAnimation(retargeted, mode: AnimationPlayMode.once)
          ..clock = 1.0;
        targetComp.markPoseDirty();
        final ws = targetComp.evaluatePose();

        // Target hips: `1.8 + 0.1 * 1.8 = 1.98` Y, `0.5 * 1.8 = 0.9` Z!
        final dstHipsPos = ws.nodesByIndex[0]!.combinedTransform
            .getTranslation();
        expect(dstHipsPos.y, closeTo(1.98, 1e-4));
        expect(dstHipsPos.z, closeTo(0.9, 1e-4));

        // Target LeftLowerArm (`(-0.54, 0, 0)` from LeftUpperArm in T-pose):
        // after `Ry(+90 deg)` swing around LeftUpperArm, forearm pivot lies
        // `+0.54` forward in `+Z` from LeftUpperArm!
        final upperPos = ws.nodesByIndex[4]!.combinedTransform.getTranslation();
        final lowerPos = ws.nodesByIndex[5]!.combinedTransform.getTranslation();
        final armDir = (lowerPos - upperPos)..normalize();
        expect(armDir.z, closeTo(1.0, 1e-4));
        expect(armDir.x.abs(), lessThan(1e-4));
      },
    );
  });

  group('FabrikIkConstraint3D, FootPlacementIk3D & RagdollController3D', () {
    test(
      'FabrikIkConstraint3D solves 5-joint chain to target and enforces '
      'maxConeAngleRad joint limits',
      () {
        final model = _buildChainRig(5); // Total reach = 2.0m.
        final comp = ModelComponent(model: model);
        final target = Vector3(1.1, 1.1, 0.3);
        final fabrik = FabrikIkConstraint3D(
          chainNodeIndices: const [0, 1, 2, 3, 4],
          targetPosition: target,
          maxIterations: 20,
          tolerance: 1e-4,
        );
        comp.boneModifiers.add(fabrik);
        comp.update(0.016);
        final ws = comp.evaluatePose();

        final tipPos = ws.nodesByIndex[4]!.combinedTransform.getTranslation();
        expect(tipPos.distanceTo(target), lessThan(2e-3));

        // Now restrict each joint to a tight `0.25 rad` (~14 deg) cone and aim
        // steeply downward at `(0.5, -1.5, 0)`: every consecutive segment angle
        // must remain `<= 0.25 + 1e-3` rad!
        fabrik
          ..maxConeAngleRad = 0.25
          ..targetPosition.setValues(0.5, -1.5, 0.0);
        comp.markPoseDirty();
        final coneWs = comp.evaluatePose();

        var prevDir = Vector3(0.0, 1.0, 0.0);
        for (var i = 0; i < 4; i++) {
          final p0 = coneWs.nodesByIndex[i]!.combinedTransform.getTranslation();
          final p1 = coneWs.nodesByIndex[i + 1]!.combinedTransform
              .getTranslation();
          final segDir = (p1 - p0)..normalize();
          final bendAngle = math.acos(prevDir.dot(segDir).clamp(-1.0, 1.0));
          expect(bendAngle, lessThanOrEqualTo(0.25 + 1e-3));
          prevDir = segDir;
        }
      },
    );

    test(
      'FootPlacementIk3D damps pelvis on slopes/stairs, solves leg IK, and '
      'aligns ankles to surface normals',
      () {
        final biped = _buildBipedRig(scale: 1.0);
        final profile = HumanoidProfile3D.autoDetect(biped);
        final slopeNormal = Vector3(0.35, 0.9, 0.0)..normalize();

        final footIk = FootPlacementIk3D.fromHumanoid(
          profile,
          pelvisSmoothing: 20.0,
          groundQuery: (rayOrigin, maxDist) {
            if (rayOrigin.x < 0.0) {
              // Left foot on a raised `+0.2` step.
              return GroundHit3D(
                point: Vector3(rayOrigin.x, 0.2, rayOrigin.z),
                normal: Vector3(0.0, 1.0, 0.0),
              );
            }
            // Right foot on a lower `-0.18` sloped ramp.
            return GroundHit3D(
              point: Vector3(rayOrigin.x, -0.18, rayOrigin.z),
              normal: slopeNormal,
            );
          },
        );

        final comp = ModelComponent(model: biped);
        comp.boneModifiers.add(footIk);

        // Step several frames so exponential pelvis damping converges smoothly.
        comp.update(0.02);
        final firstOffset = footIk.hipsOffsetY;
        expect(firstOffset, lessThan(0.0));
        expect(firstOffset, greaterThan(-0.18));

        for (var i = 0; i < 30; i++) {
          comp.update(0.02);
        }
        expect(footIk.hipsOffsetY, closeTo(-0.18, 1e-2));

        final ws = comp.evaluatePose();
        final leftFootPos = ws.nodesByIndex[8]!.combinedTransform
            .getTranslation();
        final rightFootPos = ws.nodesByIndex[11]!.combinedTransform
            .getTranslation();
        expect(leftFootPos.y, closeTo(0.2, 1e-2));
        expect(rightFootPos.y, closeTo(-0.18, 1e-2));

        // Right foot's local +Y axis tilts to match `slopeNormal`!
        final rightFootUp = Vector3(0.0, 1.0, 0.0);
        ws.nodesByIndex[11]!.combinedTransform.rotate3(rightFootUp);
        rightFootUp.normalize();
        expect(rightFootUp.dot(slopeNormal), greaterThan(0.99));
      },
    );

    test(
      'RagdollController3D transitions kinematicFollow -> dynamic ragdoll -> '
      'smooth recoveringToAnimation blend',
      () {
        final biped = _buildBipedRig(scale: 1.0);
        final standWalk = ModelAnimation(
          name: 'move',
          nodes: {
            0: NodeAnimation(
              channels: [
                AnimationController(
                  animation: TranslationAnimationSpline.from(
                    interpolation: AnimationInterpolation.linear,
                    times: const [0.0, 1.0],
                    values: [
                      Vector3(0.0, 1.2, 0.0),
                      Vector3(2.0, 1.2, 0.0),
                    ],
                  ),
                ),
              ],
            ),
          },
        );
        final model = Model(nodes: biped.nodes, animations: [standWalk]);
        final comp = ModelComponent(model: model)..playAnimationByName('move');

        final physics = PhysicsWorld3D(autoStep: false);
        // Add static ground floor at `y = 0` (`top = 0.0`).
        final floor = RigidBody3D(
          shape: BoxShape3D(halfExtents: Vector3(20.0, 0.5, 20.0)),
          bodyType: BodyType3D.static,
          position: Vector3(0.0, -0.5, 0.0),
        );
        physics.addBody(floor);

        final ragdoll = RagdollController3D(
          modelComponent: comp,
          physicsWorld: physics,
        );
        expect(ragdoll.mode, RagdollMode3D.kinematicFollow);
        expect(ragdoll.bodies, isNotEmpty);
        expect(ragdoll.joints, isNotEmpty);

        // 1. Advance animation in `kinematicFollow` so kinematic bodies track
        // the `+2 m/s` horizontal bone velocity!
        comp.update(0.1);
        comp.update(0.1);
        final hipsBody = ragdoll.bodyForBone(0)!;
        expect(hipsBody.bodyType, BodyType3D.kinematic);
        expect(hipsBody.linearVelocity.x, closeTo(2.0, 0.1));

        // 2. Activate ragdoll with an additional upward/sideways hit impulse!
        ragdoll.activateRagdoll(
          impulse: Vector3(4.0, 2.0, 0.0),
          hitBoneNodeIndex: 2,
        );
        expect(ragdoll.mode, RagdollMode3D.ragdoll);
        expect(hipsBody.bodyType, BodyType3D.dynamic);
        expect(ragdoll.bodyForBone(2)!.linearVelocity.x, greaterThan(2.5));

        final preFallHipsY = comp.nodeTransform(0)!.getTranslation().y;
        for (var step = 0; step < 60; step++) {
          physics.step(1.0 / 60.0);
        }
        ragdoll.syncFromPhysics();
        final fallenHipsPos = comp.nodeTransform(0)!.getTranslation();
        expect(fallenHipsPos.y, lessThan(preFallHipsY - 0.3));
        expect(fallenHipsPos.y, greaterThan(-0.1)); // Stopped by floor!

        // 3. Recover smoothly back into live `AnimationState` over `0.4s`!
        ragdoll.recoverToAnimation(blendDuration: 0.4);
        expect(ragdoll.mode, RagdollMode3D.recoveringToAnimation);
        expect(hipsBody.bodyType, BodyType3D.kinematic);

        // Halfway through recovery (`0.2s`), pelvis Y is smoothly mid-way
        // between fallen ragdoll height and animated `1.2` height!
        comp.update(0.2);
        final midRecoverY = comp.nodeTransform(0)!.getTranslation().y;
        expect(midRecoverY, greaterThan(fallenHipsPos.y + 0.1));
        expect(midRecoverY, lessThan(1.19));

        // Completing recovery (`+0.25s`) returns to `kinematicFollow` at `1.2`!
        comp.update(0.25);
        expect(ragdoll.mode, RagdollMode3D.kinematicFollow);
        expect(comp.nodeTransform(0)!.getTranslation().y, closeTo(1.2, 1e-3));

        ragdoll.dispose();
        expect(comp.boneModifiers.contains(ragdoll), isFalse);
      },
    );
  });
}
