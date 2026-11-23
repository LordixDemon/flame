import 'dart:typed_data';

import 'package:flame_3d/collisions.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/navigation.dart';
import 'package:flame_3d/physics.dart';
import 'package:flutter_test/flutter_test.dart';

class _RecordingForceSolver(
  this.forceStage,
  this.log,
) implements PhysicsForceSolver3D {
  @override
  final PhysicsForceStage3D forceStage;

  final List<String> log;

  @override
  void applyForces(PhysicsWorld3D world, double dt) {
    log.add('${forceStage.name}:${world.activeBodies.length}');
    if (forceStage == PhysicsForceStage3D.preIntegration) {
      for (final body in world.activeBodies) {
        if (body.bodyType == BodyType3D.dynamic) {
          body.applyForce(Vector3(0, 5.0, 0));
        }
      }
    }
  }
}

void main() {
  group('Wave 4.2 physics and navigation refactoring', () {
    test(
      'PhysicsForceSolver3D stages run in order and wrap buoyancy/vehicle',
      () {
        final log = <String>[];
        final pre = _RecordingForceSolver(
          PhysicsForceStage3D.preIntegration,
          log,
        );
        final post = _RecordingForceSolver(
          PhysicsForceStage3D.postBroadphase,
          log,
        );
        final world = PhysicsWorld3D(gravity: Vector3.zero());
        final body = RigidBody3D(
          shape: BoxShape3D(halfExtents: Vector3.all(0.5)),
          position: Vector3(0, -0.5, 0),
          mass: 2.0,
          canSleep: false,
        );
        world
          ..addBody(body)
          ..addForceSolver(post)
          ..addForceSolver(pre);
        expect(world.forceSolvers, hasLength(2));

        world.step(1.0 / 60.0);
        expect(log, ['preIntegration:1', 'postBroadphase:1']);
        expect(body.linearVelocity.y, greaterThan(0.0));

        world.removeForceSolver(pre);
        expect(world.forceSolvers, [post]);

        // BuoyancyVolume3D and RaycastVehicle3D implement PhysicsForceSolver3D.
        final water = BuoyancyVolume3D(fluidDensity: 4.0);
        expect(water.forceStage, PhysicsForceStage3D.preIntegration);
        final submerged = RigidBody3D(
          shape: BoxShape3D(halfExtents: Vector3.all(0.5)),
          position: Vector3(0, -0.5, 0),
          mass: 2.0,
          canSleep: false,
        );
        final waterWorld = PhysicsWorld3D()
          ..addBody(submerged)
          ..addForceSolver(water);
        waterWorld.step(1.0 / 60.0);
        expect(submerged.linearVelocity.y, greaterThan(0.0));

        final chassis = RigidBody3D(
          shape: BoxShape3D(halfExtents: Vector3(1, 0.4, 2)),
          position: Vector3(0, 2, 0),
          mass: 10.0,
        );
        final ground = RigidBody3D(
          bodyType: BodyType3D.static,
          shape: BoxShape3D(halfExtents: Vector3(10, 0.5, 10)),
          position: Vector3(0, 1.2, 0),
        );
        final vehicle = RaycastVehicle3D.fourWheel(chassis: chassis);
        expect(vehicle.forceStage, PhysicsForceStage3D.postBroadphase);
        final carWorld = PhysicsWorld3D()
          ..addBody(chassis)
          ..addBody(ground)
          ..addForceSolver(vehicle);
        carWorld.step(1.0 / 60.0);
        expect(vehicle.wheelStates.any((w) => w.isGrounded), isTrue);
      },
    );

    test(
      'HingeJoint3D, FixedJoint3D, SliderJoint3D, and contacts step cleanly',
      () {
        final anchor = RigidBody3D(
          bodyType: BodyType3D.static,
          shape: BoxShape3D(halfExtents: Vector3.all(0.5)),
          position: Vector3.zero(),
        );
        final hinged = RigidBody3D(
          shape: BoxShape3D(halfExtents: Vector3.all(0.5)),
          position: Vector3(2, 0, 0),
          canSleep: false,
        );
        final fixedChild = RigidBody3D(
          shape: SphereShape3D(radius: 0.4),
          position: Vector3(0, 2, 0),
          canSleep: false,
        );
        final slid = RigidBody3D(
          shape: BoxShape3D(halfExtents: Vector3.all(0.4)),
          position: Vector3(0, 0, 2),
          canSleep: false,
        );
        final floor = RigidBody3D(
          bodyType: BodyType3D.static,
          shape: BoxShape3D(halfExtents: Vector3(10, 0.5, 10)),
          position: Vector3(0, -1.5, 0),
        );
        final world = PhysicsWorld3D()
          ..addBody(anchor)
          ..addBody(hinged)
          ..addBody(fixedChild)
          ..addBody(slid)
          ..addBody(floor)
          ..addJoint(
            HingeJoint3D(
              bodyA: anchor,
              bodyB: hinged,
              localAnchorA: Vector3(2, 0, 0),
            ),
          )
          ..addJoint(FixedJoint3D(bodyA: anchor, bodyB: fixedChild))
          ..addJoint(
            SliderJoint3D(
              bodyA: anchor,
              bodyB: slid,
              localAnchorA: Vector3(0, 0, 2),
              localAxisA: Vector3(0, 0, 1),
              minDistance: -0.5,
              maxDistance: 1.0,
            ),
          );

        for (var i = 0; i < 15; i++) {
          world.step(1.0 / 60.0);
        }
        expect(hinged.position.x, greaterThan(0.5));
        expect(fixedChild.position.y, closeTo(2.0, 0.1));
        expect(slid.position.z, closeTo(2.0, 0.6));
      },
    );

    test(
      'XpbdCloth3D and XpbdRope3D step and update surfaces via split parts',
      () {
        final cloth = XpbdCloth3D(
          columns: 4,
          rows: 4,
          width: 1.5,
          height: 1.5,
          windVelocity: Vector3(0, 0, 2),
        );
        final beforeClothY = cloth.getVertexPosition(15).y;
        cloth.step(1.0 / 60.0);
        expect(cloth.getVertexPosition(15).y, isNot(equals(beforeClothY)));
        expect(cloth.computeLocalAabb(), isNotNull);

        final rope = XpbdRope3D(
          startPoint: Vector3(0, 2, 0),
          endPoint: Vector3(2, 2, 0),
          segmentCount: 5,
        );
        final beforeRopeTipY = rope.getParticlePosition(5).y;
        for (var i = 0; i < 5; i++) {
          rope.step(1.0 / 60.0);
        }
        expect(rope.getParticlePosition(5).y, lessThan(beforeRopeTipY));
        expect(rope.computeLocalAabb(), isNotNull);
      },
    );

    test(
      'NavMesh3D with NavQueryContext3D, builder, and crowd steering work',
      () {
        final positions = Float32List.fromList([
          -4,
          0,
          -4,
          4,
          0,
          -4,
          4,
          0,
          4,
          -4,
          0,
          4,
        ]);
        final nav = NavMeshBuilder3D.fromGeometry([
          NavMeshGeometrySource3D(
            positions: positions,
            indices: [0, 3, 2, 0, 2, 1],
          ),
        ]);
        expect(nav.polyCount, greaterThan(0));

        final ctxA = NavQueryContext3D();
        final ctxB = NavQueryContext3D();
        final defaultPath = nav.findPath(Vector3(-2, 0, -2), Vector3(2, 0, 2));
        final pathA = nav.findPath(
          Vector3(-2, 0, -2),
          Vector3(2, 0, 2),
          context: ctxA,
        );
        final pathB = nav.findPath(
          Vector3(2, 0, -2),
          Vector3(-2, 0, 2),
          context: ctxB,
        );
        expect(pathA.length, defaultPath.length);
        expect(pathA.first.distanceTo(pathB.first), greaterThan(1.0));
        expect(ctxA.cornerPoints, isNotEmpty);

        final agentA = CrowdAgent3D(position: Vector3(-2, 0, 0))
          ..setPath([Vector3(2, 0, 0)]);
        final agentB = CrowdAgent3D(position: Vector3(2, 0, 0))
          ..setPath([Vector3(-2, 0, 0)]);
        final crowd = CrowdSteering3D()
          ..addAgent(agentA)
          ..addAgent(agentB);
        crowd.update(0.1);
        expect(agentA.position.x, greaterThan(-2.0));
        expect(agentB.position.x, lessThan(2.0));
      },
    );
  });
}
