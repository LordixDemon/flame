import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame_3d/collisions.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/physics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RigidBody3D.ccdEnabled anti-tunneling at 150 m/s', () {
    test(
      'eliminates tunneling of fast die/projectile against 0.02m thin wall '
      'and floor',
      () {
        // 1. Control without CCD: 150 m/s projectile tunnels straight through a
        // 0.02m (`halfExtents.x = 0.01`) thin wall at `x = 1.2` in one 1/60s
        // step (`displacement = 2.5m >> 0.02m`).
        final worldNoCcd = PhysicsWorld3D(gravity: Vector3.zero());
        final thinWallA = RigidBody3D(
          bodyType: BodyType3D.static,
          shape: BoxShape3D(halfExtents: Vector3(0.01, 2.0, 2.0)),
          position: Vector3(1.2, 0.0, 0.0),
        );
        final bulletNoCcd = RigidBody3D(
          shape: BoxShape3D(halfExtents: Vector3.all(0.08)),
          position: Vector3(0.0, 0.0, 0.0),
          linearVelocity: Vector3(150.0, 0.0, 0.0),
        );
        worldNoCcd
          ..addBody(thinWallA)
          ..addBody(bulletNoCcd)
          ..step(1.0 / 60.0);
        expect(bulletNoCcd.position.x, greaterThan(2.0)); // Tunneled!

        // 2. With `ccdEnabled: true`: stopped and bounced cleanly in front of
        // BOTH a 0.02m thin wall (`x = 1.2`) and a 0.02m thin floor (`y = 0`)!
        final worldCcd = PhysicsWorld3D();
        final thinWall = RigidBody3D(
          bodyType: BodyType3D.static,
          shape: BoxShape3D(halfExtents: Vector3(0.01, 3.0, 3.0)),
          position: Vector3(1.2, 1.0, 0.0),
          restitution: 0.5,
        );
        final thinFloor = RigidBody3D(
          bodyType: BodyType3D.static,
          shape: BoxShape3D(halfExtents: Vector3(5.0, 0.01, 5.0)),
          position: Vector3(0.0, 0.0, 0.0),
          restitution: 0.4,
        );
        final fastDie = RigidBody3D(
          shape: BoxShape3D(halfExtents: Vector3.all(0.08)),
          position: Vector3(0.0, 1.5, 0.0),
          linearVelocity: Vector3(150.0, -150.0, 0.0),
          restitution: 0.5,
          ccdEnabled: true,
          canSleep: false,
        );
        worldCcd
          ..addBody(thinWall)
          ..addBody(thinFloor)
          ..addBody(fastDie);

        for (var i = 0; i < 30; i++) {
          worldCcd.step(1.0 / 60.0);
          // Never crosses `x = 1.2` wall or falls below `y = 0.0` floor!
          expect(fastDie.position.x, lessThan(1.2));
          expect(fastDie.position.y, greaterThan(0.0));
        }
      },
    );
  });

  group('Complete 3D Joint Suite (Fixed, Slider, ConeTwist, Generic6Dof)', () {
    test(
      'FixedJoint3D locks 6-DOF pose and SliderJoint3D drives motor within '
      'limits',
      () {
        final world = PhysicsWorld3D(
          velocityIterations: 12,
          positionIterations: 6,
        );
        final anchorWall = RigidBody3D(
          bodyType: BodyType3D.static,
          shape: BoxShape3D(halfExtents: Vector3.all(0.2)),
          position: Vector3(0.0, 4.0, 0.0),
        );
        final cantilever = RigidBody3D(
          shape: BoxShape3D(halfExtents: Vector3(0.8, 0.15, 0.15)),
          position: Vector3(1.0, 4.0, 0.0),
          canSleep: false,
        );
        final weld = FixedJoint3D(bodyA: anchorWall, bodyB: cantilever);

        final railBase = RigidBody3D(
          bodyType: BodyType3D.static,
          shape: BoxShape3D(halfExtents: Vector3.all(0.2)),
          position: Vector3(0.0, 1.5, 0.0),
        );
        final carriage = RigidBody3D(
          shape: BoxShape3D(halfExtents: Vector3.all(0.25)),
          position: Vector3(0.0, 1.5, 0.0),
          canSleep: false,
        );
        final slider = SliderJoint3D(
          bodyA: railBase,
          bodyB: carriage,
          worldAxis: Vector3(1.0, 0.0, 0.0),
          minDistance: -0.5,
          maxDistance: 1.8,
          motorSpeed: 3.0,
          maxMotorForce: 45.0,
        );

        world
          ..addBody(anchorWall)
          ..addBody(cantilever)
          ..addJoint(weld)
          ..addBody(railBase)
          ..addBody(carriage)
          ..addJoint(slider);

        for (var i = 0; i < 90; i++) {
          world.step(1.0 / 60.0);
        }

        // Cantilever stayed locked horizontally at `(1.0, 4.0, 0.0)`.
        expect(cantilever.position.x, closeTo(1.0, 0.04));
        expect(cantilever.position.y, closeTo(4.0, 0.04));

        // Slider motor drove carriage to upper stop `maxDistance = 1.8` without
        // vertical sag!
        expect(slider.currentDistance, closeTo(1.8, 0.05));
        expect(carriage.position.y, closeTo(1.5, 0.04));
      },
    );

    test(
      'ConeTwistJoint3D clamps swing/twist and Generic6DofJoint3D springs '
      'converge to equilibrium',
      () {
        final world = PhysicsWorld3D(
          velocityIterations: 12,
          positionIterations: 6,
        );
        final pelvis = RigidBody3D(
          bodyType: BodyType3D.static,
          shape: SphereShape3D(radius: 0.15),
          position: Vector3(0.0, 5.0, 0.0),
        );
        // Limb extending along +X, gravity pulls it downward around -Z (swing),
        // plus an applied twist impulse around +X!
        final thigh = RigidBody3D(
          shape: CapsuleShape3D(radius: 0.12, height: 1.0, axis: Axis3D.x),
          position: Vector3(0.5, 5.0, 0.0),
          angularDamping: 0.6,
          canSleep: false,
        );
        const maxSwing = math.pi / 6; // 30 deg cone
        const maxTwist = math.pi / 9; // 20 deg twist
        final coneTwist = ConeTwistJoint3D(
          bodyA: pelvis,
          bodyB: thigh,
          localAnchorA: Vector3.zero(),
          localAnchorB: Vector3(-0.5, 0.0, 0.0),
          localAxisA: Vector3(1.0, 0.0, 0.0),
          swingLimitRad: maxSwing,
          minTwistRad: -maxTwist,
          maxTwistRad: maxTwist,
        );

        // Generic6DofJoint3D: X & Z locked (`0..0`), Y free within `[-2..2]`
        // with vertical spring (`k = 80 N/m`, `c = 12 N*s/m`) supporting a
        // `1 kg` mass (`static sag = m*g / k = 9.81 / 80 ~ -0.1226m`)!
        final mount = RigidBody3D(
          bodyType: BodyType3D.static,
          shape: SphereShape3D(radius: 0.1),
          position: Vector3(4.0, 5.0, 0.0),
        );
        final sprungMass = RigidBody3D(
          shape: BoxShape3D(halfExtents: Vector3.all(0.2)),
          position: Vector3(4.0, 4.2, 0.0), // Displaced -0.8m initially
          canSleep: false,
        );
        final sixDof = Generic6DofJoint3D(
          bodyA: mount,
          bodyB: sprungMass,
          linearLowerLimit: Vector3(0.0, -2.0, 0.0),
          linearUpperLimit: Vector3(0.0, 2.0, 0.0),
          linearSpringStiffness: Vector3(0.0, 80.0, 0.0),
          linearSpringDamping: Vector3(0.0, 12.0, 0.0),
        );

        world
          ..addBody(pelvis)
          ..addBody(thigh)
          ..addJoint(coneTwist)
          ..addBody(mount)
          ..addBody(sprungMass)
          ..addJoint(sixDof);

        thigh.applyTorqueImpulse(Vector3(6.0, 0.0, 0.0));

        for (var i = 0; i < 150; i++) {
          world.step(1.0 / 60.0);
        }

        expect(coneTwist.swingAngle, lessThanOrEqualTo(maxSwing + 0.08));
        expect(coneTwist.twistAngle.abs(), lessThanOrEqualTo(maxTwist + 0.08));

        expect(sprungMass.position.x, closeTo(4.0, 0.03));
        expect(sprungMass.position.z, closeTo(0.0, 0.03));
        expect(sixDof.currentLinearOffset.y, closeTo(-9.81 / 80.0, 0.05));
      },
    );
  });

  group('BuoyancyVolume3D & RaycastVehicle3D', () {
    test(
      'BuoyancyVolume3D floats multi-pontoon boat on waves while dense weight '
      'sinks',
      () {
        final world = PhysicsWorld3D();
        final ocean = BuoyancyVolume3D(
          fluidDensity: 3.0,
          linearDrag: 3.0,
          angularDrag: 2.5,
          waterSurfaceHeight: (x, z, time) =>
              0.25 * math.sin(x * 0.8 + time * 2.0),
        );
        final boat = RigidBody3D(
          shape: BoxShape3D(halfExtents: Vector3(1.0, 0.3, 1.5)),
          position: Vector3(0.0, 1.2, 0.0),
          mass: 2.5,
          canSleep: false,
        );
        final heavyAnchor = RigidBody3D(
          shape: SphereShape3D(radius: 0.3),
          position: Vector3(4.0, 0.5, 0.0),
          mass: 40.0,
          canSleep: false,
        );

        world
          ..addBuoyancyVolume(ocean)
          ..addBody(boat)
          ..addBody(heavyAnchor);

        for (var i = 0; i < 180; i++) {
          world.step(1.0 / 60.0);
        }

        // Boat floats right around the `y ~ 0` wave surface and pitches/rolls
        // slightly with the traveling sine wave!
        expect(boat.position.y, greaterThan(-0.5));
        expect(boat.position.y, lessThan(0.6));
        expect(boat.rotation.z.abs(), greaterThan(0.005));

        // Heavy iron anchor sank deep underwater!
        expect(heavyAnchor.position.y, lessThan(-4.0));
      },
    );

    test(
      'RaycastVehicle3D 4-wheel suspension settles, accelerates, steers, and '
      'brakes',
      () {
        final world = PhysicsWorld3D();
        final ground = RigidBody3D(
          bodyType: BodyType3D.static,
          shape: BoxShape3D(halfExtents: Vector3(80.0, 0.5, 80.0)),
          position: Vector3(0.0, -0.5, 0.0),
          friction: 0.9,
        );
        final chassis = RigidBody3D(
          shape: BoxShape3D(halfExtents: Vector3(0.9, 0.3, 1.6)),
          position: Vector3(0.0, 0.9, 0.0),
          mass: 120.0,
          canSleep: false,
        );
        final car = RaycastVehicle3D.fourWheel(
          chassis: chassis,
          connectionHeight: -0.1,
          restLength: 0.45,
          engineForce: 16.0,
          maxBrakeForce: 20.0,
        );

        world
          ..addBody(ground)
          ..addBody(chassis)
          ..addVehicle(car);

        // Settle suspension on flat ground (`30` frames).
        for (var i = 0; i < 30; i++) {
          world.step(1.0 / 60.0);
        }
        expect(car.groundedWheelCount, 4);

        // Accelerate forward (`throttle = 1.0`) then steer (`steering = 0.5`).
        car.throttle = 1.0;
        for (var i = 0; i < 60; i++) {
          world.step(1.0 / 60.0);
        }
        final speedBeforeBrake = car.forwardSpeed;
        expect(speedBeforeBrake, greaterThan(4.0));
        expect(chassis.position.z, greaterThan(2.0));

        car.steering = 0.6;
        for (var i = 0; i < 45; i++) {
          world.step(1.0 / 60.0);
        }
        // Steering induced lateral yaw & curved trajectory!
        expect(chassis.position.x.abs(), greaterThan(0.25));

        // Cut throttle and apply full brakes (`brake = 1.0`).
        car
          ..throttle = 0.0
          ..steering = 0.0
          ..brake = 1.0;
        for (var i = 0; i < 60; i++) {
          world.step(1.0 / 60.0);
        }
        expect(car.forwardSpeed.abs(), lessThan(speedBeforeBrake * 0.35));
      },
    );
  });

  group('XpbdCloth3D & XpbdRope3D zero-GC soft-body simulation', () {
    test(
      'XpbdCloth3D billows in wind, drapes over sphere/capsule colliders, and '
      'updates Surface normals',
      () {
        // 1. Hanging banner billowing in `+Z` wind.
        final banner = XpbdCloth3D(
          columns: 8,
          rows: 8,
          width: 1.6,
          height: 1.6,
          pinTopEdge: true,
          windVelocity: Vector3(0.0, 0.0, 8.0),
        );
        for (var i = 0; i < 45; i++) {
          banner.step(1.0 / 60.0);
        }
        // Bottom row (`r = 7`) billowed forward in `+Z` while top (`r = 0`)
        // stayed pinned at `z == 0`!
        expect(
          banner.getVertexPosition(banner.vertexIndex(3, 0)).z,
          closeTo(0.0, 1e-6),
        );
        expect(
          banner.getVertexPosition(banner.vertexIndex(3, 7)).z,
          greaterThan(0.15),
        );
        expect(
          banner.getVertexNormal(banner.vertexIndex(3, 4)).length,
          closeTo(1.0, 1e-4),
        );

        // 2. Horizontal cloth sheet dropped onto a sphere collider (`r = 0.5`).
        final sphereObs = XpbdSphereCollider3D(
          center: Vector3(0.0, -0.5, 0.0),
          radius: 0.5,
        );
        final drape = XpbdCloth3D(
          columns: 9,
          rows: 9,
          width: 1.8,
          height: 1.8,
          startHorizontal: true,
          pinTopCorners: false,
          sphereColliders: [sphereObs],
        );
        for (var i = 0; i < 45; i++) {
          drape.step(1.0 / 60.0);
        }
        // Every cloth vertex must remain outside the sphere (`>= 0.5`)!
        for (var v = 0; v < drape.vertexCount; v++) {
          final p = drape.getVertexPosition(v);
          expect(p.distanceTo(sphereObs.center), greaterThanOrEqualTo(0.495));
        }

        // 3. XpbdRope3D suspending a dynamic RigidBody3D weight & clearing a
        // capsule obstacle.
        final phys = PhysicsWorld3D();
        final weight = RigidBody3D(
          shape: SphereShape3D(radius: 0.15),
          position: Vector3(1.2, 3.0, 0.0),
          mass: 0.6,
          canSleep: false,
        );
        phys.addBody(weight);
        final rope = XpbdRope3D(
          startPoint: Vector3(0.0, 3.0, 0.0),
          endPoint: Vector3(1.2, 3.0, 0.0),
          segmentCount: 12,
          attachedBody: weight,
          capsuleColliders: [
            XpbdCapsuleCollider3D(
              pointA: Vector3(0.4, 2.5, -1.0),
              pointB: Vector3(0.4, 2.5, 1.0),
              radius: 0.15,
            ),
          ],
        );
        for (var i = 0; i < 60; i++) {
          phys.step(1.0 / 60.0);
          rope.step(1.0 / 60.0);
        }
        // Weight stays suspended near rope length (`~1.2m`) from `(0, 3, 0)`
        // instead of freefalling `-4.9m` to `y = -1.9`!
        expect(
          weight.position.distanceTo(Vector3(0.0, 3.0, 0.0)),
          lessThan(1.45),
        );
        expect(weight.position.y, greaterThan(1.5));
      },
    );
  });

  group('PhysicsSnapshot3D & PhysicsSnapshotRingBuffer3D rollback', () {
    test(
      'encodes P3DS + CRC32, detects bit corruption, and reproduces '
      'bit-exact trajectories after N-frame rollback',
      () {
        final world = PhysicsWorld3D();
        final floor = RigidBody3D(
          bodyType: BodyType3D.static,
          shape: BoxShape3D(halfExtents: Vector3(12.0, 0.5, 12.0)),
          position: Vector3(0.0, -0.5, 0.0),
          friction: 0.65,
          restitution: 0.35,
        );
        final bodies = <RigidBody3D>[
          for (var i = 0; i < 4; i++)
            RigidBody3D(
              shape: i.isEven
                  ? BoxShape3D(halfExtents: Vector3.all(0.28))
                  : SphereShape3D(radius: 0.28),
              friction: 0.65,
              restitution: 0.35,
            ),
        ];
        world.addBody(floor);
        for (final b in bodies) {
          world.addBody(b);
        }
        world.throwDice3D(bodies, seed: 20261119);

        final ring = PhysicsSnapshotRingBuffer3D(capacity: 32);

        // Advance to tick 50, recording rolling snapshots.
        for (var step = 0; step < 50; step++) {
          world.step(1.0 / 60.0);
          ring.capture(world);
        }
        expect(world.tick, 50);
        expect(ring.length, 32);
        expect(ring.latestTick, 50);

        final snapAt50 = world.saveSnapshot();
        // Verify `'P3DS'` magic and CRC32 validation.
        expect(
          String.fromCharCodes(snapAt50.sublist(0, 4)),
          equals('P3DS'),
        );
        expect(PhysicsSnapshot3D.verifyChecksum(snapAt50), isTrue);
        expect(PhysicsSnapshot3D.peekTick(snapAt50), 50);

        final corrupted = Uint8List.fromList(snapAt50);
        corrupted[24] ^= 0xFF;
        expect(PhysicsSnapshot3D.verifyChecksum(corrupted), isFalse);
        expect(
          () => world.restoreSnapshot(corrupted),
          throwsFormatException,
        );

        // Simulate 40 future frames (`tick 50 -> 90`) and record exact end
        // state.
        for (var step = 0; step < 40; step++) {
          world.step(1.0 / 60.0);
          if (step < 15) {
            ring.capture(world);
          }
        }
        expect(world.tick, 90);

        final expectedStates = [
          for (final b in bodies)
            (
              b.position.clone(),
              b.rotation.clone(),
              b.linearVelocity.clone(),
              b.angularVelocity.clone(),
              b.sleepTimer,
              b.isSleeping,
            ),
        ];

        // Roll back to tick 50 via `ring.rollbackToTick` and re-simulate 40
        // frames!
        expect(ring.rollbackToTick(world, 50), isTrue);
        expect(world.tick, 50);

        for (var step = 0; step < 40; step++) {
          world.step(1.0 / 60.0);
        }
        expect(world.tick, 90);

        // Every single float/double bit must match identically!
        for (var i = 0; i < bodies.length; i++) {
          final b = bodies[i];
          final exp = expectedStates[i];
          expect(b.position.x, equals(exp.$1.x));
          expect(b.position.y, equals(exp.$1.y));
          expect(b.position.z, equals(exp.$1.z));
          expect(b.rotation.x, equals(exp.$2.x));
          expect(b.rotation.y, equals(exp.$2.y));
          expect(b.rotation.z, equals(exp.$2.z));
          expect(b.rotation.w, equals(exp.$2.w));
          expect(b.linearVelocity.x, equals(exp.$3.x));
          expect(b.linearVelocity.y, equals(exp.$3.y));
          expect(b.linearVelocity.z, equals(exp.$3.z));
          expect(b.angularVelocity.x, equals(exp.$4.x));
          expect(b.angularVelocity.y, equals(exp.$4.y));
          expect(b.angularVelocity.z, equals(exp.$4.z));
          expect(b.sleepTimer, equals(exp.$5));
          expect(b.isSleeping, equals(exp.$6));
        }
      },
    );
  });
}
