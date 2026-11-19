import 'dart:math' as math;

import 'package:flame/game.dart' show FlameGame;
import 'package:flame_3d/camera.dart';
import 'package:flame_3d/collisions.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/physics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_test/flame_test.dart';
import 'package:flutter_test/flutter_test.dart';

RigidBody3D _floor({double friction = 0.6, double restitution = 0.0}) =>
    RigidBody3D(
      bodyType: BodyType3D.static,
      shape: BoxShape3D(halfExtents: Vector3(20, 0.5, 20)),
      position: Vector3(0, -0.5, 0),
      friction: friction,
      restitution: restitution,
    );

double _kineticEnergy(RigidBody3D b) {
  final lin = 0.5 * b.mass * b.linearVelocity.length2;
  // 0.5 w . I w with I = (worldInvInertia)^-1.
  final inertia = Matrix3.copy(b.worldInvInertia)..invert();
  final iw = inertia.transformed(b.angularVelocity);
  return lin + 0.5 * b.angularVelocity.dot(iw);
}

FlameGame _game() => FlameGame(world: World3D());

void main() {
  group('Sleeping, kinematic and static partners', () {
    test('a moving kinematic body wakes and pushes a sleeping body', () {
      final world = PhysicsWorld3D(autoStep: false);
      final crate = RigidBody3D(
        shape: BoxShape3D(halfExtents: Vector3.all(0.25)),
        position: Vector3(0, 0.25, 0),
      );
      final pusher = RigidBody3D(
        bodyType: BodyType3D.kinematic,
        shape: BoxShape3D(halfExtents: Vector3(0.1, 0.4, 0.6)),
        position: Vector3(-1, 0.4, 0),
      );
      world
        ..addBody(_floor())
        ..addBody(crate)
        ..addBody(pusher);
      for (var i = 0; i < 90 && !crate.isSleeping; i++) {
        world.step(1 / 60);
      }
      expect(crate.isSleeping, isTrue);

      pusher.linearVelocity.setValues(2, 0, 0);
      for (var i = 0; i < 40; i++) {
        world.step(1 / 60);
      }
      // The pusher (at x = -1 + 2 * 40 / 60) carried the crate ahead of it.
      expect(crate.position.x, greaterThan(pusher.position.x + 0.3));
      expect(crate.position.x, greaterThan(0.3));
    });

    test('a sleeping partner counts as immovable in the effective mass', () {
      final world = PhysicsWorld3D(
        autoStep: false,
        velocityIterations: 1,
        positionIterations: 0,
        sleepLinearThreshold: 0.2,
      );
      final base = RigidBody3D(
        shape: BoxShape3D(halfExtents: Vector3.all(0.25)),
        position: Vector3(0, 0.25, 0),
      )..putToSleep();
      final ball = RigidBody3D(
        shape: SphereShape3D(radius: 0.25),
        position: Vector3(0, 0.749, 0),
        linearVelocity: Vector3(0, -0.05, 0),
      )..sleepTimer = 0.1; // settling, so it does not wake the base
      world
        ..addBody(_floor())
        ..addBody(base)
        ..addBody(ball)
        ..step(1 / 60);
      expect(base.isSleeping, isTrue);
      // One iteration stops the ball on the immovable base.
      expect(ball.linearVelocity.y.abs(), lessThan(0.01));
    });
  });

  group('Static colliders are solid for rigid bodies', () {
    test('a box rests on a static Collider3D floor', () {
      for (final ccd in [false, true]) {
        final colliders = CollisionSystem3D(autoStep: false)
          ..register(
            Collider3D(
              shape: BoxShape3D(halfExtents: Vector3(10, 0.5, 10)),
              position: Vector3(0, -0.5, 0),
              isStatic: true,
            ),
          );
        final world = PhysicsWorld3D(
          autoStep: false,
          collisionSystem: colliders,
        );
        final box = RigidBody3D(
          shape: BoxShape3D(halfExtents: Vector3.all(0.25)),
          position: Vector3(0, 2, 0),
          ccdEnabled: ccd,
        );
        world.addBody(box);
        for (var i = 0; i < 180; i++) {
          world.step(1 / 60);
        }
        expect(box.position.y, closeTo(0.25, 0.006), reason: 'ccd: $ccd');
        expect(box.isSleeping, isTrue, reason: 'ccd: $ccd');
      }
    });

    test('triggers and non-static colliders do not hold bodies up', () {
      final colliders = CollisionSystem3D(autoStep: false)
        ..register(
          TriggerVolume3D(
            shape: BoxShape3D(halfExtents: Vector3(10, 0.5, 10)),
            position: Vector3(0, -0.5, 0),
            isStatic: true,
          ),
        )
        ..register(
          Collider3D(
            shape: BoxShape3D(halfExtents: Vector3(10, 0.5, 10)),
            position: Vector3(0, -2.5, 0),
          ),
        );
      final world = PhysicsWorld3D(autoStep: false, collisionSystem: colliders);
      final box = RigidBody3D(
        shape: BoxShape3D(halfExtents: Vector3.all(0.25)),
      );
      world.addBody(box);
      for (var i = 0; i < 90; i++) {
        world.step(1 / 60);
      }
      expect(box.position.y, lessThan(-3));
    });
  });

  group('Continuous collision detection', () {
    test('a hull uses its inradius: a face-down d8 stops on its face', () {
      final world = PhysicsWorld3D(autoStep: false);
      final d8 = RigidBody3D(
        shape: ConvexHullShape3D(
          vertices: [
            Vector3(0.3, 0, 0),
            Vector3(-0.3, 0, 0),
            Vector3(0, 0.3, 0),
            Vector3(0, -0.3, 0),
            Vector3(0, 0, 0.3),
            Vector3(0, 0, -0.3),
          ],
        ),
        position: Vector3(0, 1.5, 0),
        linearVelocity: Vector3(0, -15, 0),
        ccdEnabled: true,
      );
      // Turn the face with normal (1, 1, 1) / sqrt(3) to point down.
      final from = Vector3(1, 1, 1).normalized();
      final to = Vector3(0, -1, 0);
      final axis = from.cross(to)..normalize();
      d8.bodyRotation.setFrom(
        Quaternion.axisAngle(axis, math.acos(from.dot(to))),
      );
      world
        ..addBody(_floor())
        ..addBody(d8);
      var lowest = double.infinity;
      for (var i = 0; i < 30; i++) {
        world.step(1 / 60);
        lowest = math.min(lowest, d8.position.y);
      }
      final inradius = 0.3 / math.sqrt(3);
      expect(lowest, closeTo(inradius, 0.012));
      expect(d8.position.y, closeTo(inradius, 0.012));
    });

    test('an impact on a static collider does not add energy', () {
      final colliders = CollisionSystem3D(autoStep: false)
        ..register(
          Collider3D(
            shape: BoxShape3D(halfExtents: Vector3(20, 0.5, 20)),
            position: Vector3(0, -0.5, 0),
            isStatic: true,
            material: const PhysicsMaterial3D(friction: 1, restitution: 0),
          ),
        );
      final world = PhysicsWorld3D(
        autoStep: false,
        gravity: Vector3.zero(),
        collisionSystem: colliders,
      );
      final ball = RigidBody3D(
        shape: SphereShape3D(radius: 0.1),
        position: Vector3(0, 1, 0),
        linearVelocity: Vector3(20, -30, 0),
        friction: 1,
        linearDamping: 0,
        angularDamping: 0,
        ccdEnabled: true,
        canSleep: false,
      );
      world.addBody(ball);
      // The vertical energy is absorbed (restitution 0); friction may only
      // take energy from the sliding motion, never add to it.
      final slidingEnergy = 0.5 * ball.mass * 20 * 20;
      for (var i = 0; i < 4; i++) {
        world.step(1 / 60);
      }
      expect(ball.linearVelocity.y.abs(), lessThan(0.5));
      expect(_kineticEnergy(ball), lessThanOrEqualTo(slidingEnergy * 1.001));
      expect(ball.position.y, greaterThan(0.09));
    });
  });

  group('Snapshots', () {
    (PhysicsWorld3D, List<RigidBody3D>) build() {
      final colliders = CollisionSystem3D(autoStep: false)
        ..register(
          Collider3D(
            shape: BoxShape3D(halfExtents: Vector3(0.2, 1, 4)),
            position: Vector3(-1.2, 1, 0),
            isStatic: true,
          ),
        );
      final world = PhysicsWorld3D(autoStep: false, collisionSystem: colliders);
      world.addBody(_floor(restitution: 0.3));
      final hull = ConvexHullShape3D(
        vertices: [
          for (final x in const [-0.25, 0.25])
            for (final y in const [-0.25, 0.25])
              for (final z in const [-0.25, 0.25]) Vector3(x, y, z),
        ],
      );
      final dice = [
        for (var i = 0; i < 4; i++)
          RigidBody3D(
            shape: i.isEven ? hull : BoxShape3D(halfExtents: Vector3.all(0.25)),
            friction: 0.6,
            restitution: 0.3,
          ),
      ];
      dice.forEach(world.addBody);
      world.throwDice3D(
        dice,
        seed: 77,
        throwVelocity: Vector3(-3, -1, -1),
      );
      return (world, dice);
    }

    List<double> state(List<RigidBody3D> bodies) => [
      for (final b in bodies) ...[
        b.position.x,
        b.position.y,
        b.position.z,
        b.rotation.x,
        b.rotation.y,
        b.rotation.z,
        b.rotation.w,
        b.linearVelocity.x,
        b.angularVelocity.y,
      ],
    ];

    test('restoring into an identically built new world reproduces the run '
        'bit for bit', () {
      final (worldA, diceA) = build();
      for (var i = 0; i < 70; i++) {
        worldA.step(1 / 60);
      }
      final snapshot = worldA.saveSnapshot();
      for (var i = 0; i < 90; i++) {
        worldA.step(1 / 60);
      }
      final expected = state(diceA);

      final (worldB, diceB) = build();
      worldB.restoreSnapshot(snapshot);
      for (var i = 0; i < 90; i++) {
        worldB.step(1 / 60);
      }
      expect(state(diceB), expected);
      expect(worldB.tick, worldA.tick);
    });

    test('bodies removed or added after the snapshot keep to themselves', () {
      final world = PhysicsWorld3D(autoStep: false);
      final a = RigidBody3D(
        shape: SphereShape3D(radius: 0.2),
        position: Vector3(0, 3, 0),
      );
      final b = RigidBody3D(
        shape: SphereShape3D(radius: 0.2),
        position: Vector3(2, 3, 0),
      );
      world
        ..addBody(a)
        ..addBody(b);
      for (var i = 0; i < 10; i++) {
        world.step(1 / 60);
      }
      final snapshot = world.saveSnapshot();
      world.removeBody(b);
      final c = RigidBody3D(
        shape: SphereShape3D(radius: 0.2),
        position: Vector3(-5, 7, 0),
      );
      world.addBody(c);
      world.restoreSnapshot(snapshot);
      expect(c.position.x, -5);
      expect(c.position.y, 7);
      expect(a.position.y, lessThan(3));
    });
  });

  group('Mounted components register with the physics world', () {
    testWithGame('bodies and buoyancy volumes join and leave on mount', _game, (
      game,
    ) async {
      final world = game.world as World3D;
      final physics = PhysicsWorld3D(autoStep: false);
      await world.ensureAdd(physics);
      final floor = _floor();
      final crate = RigidBody3D(
        shape: BoxShape3D(halfExtents: Vector3.all(0.25)),
        mass: 0.05, // light: floats
      );
      final holder = MeshComponent(
        mesh: CuboidMesh(size: Vector3.all(0.5)),
        position: Vector3(0, 0.5, 0),
        children: [crate],
      );
      final sea = BuoyancyVolume3D(fluidDensity: 1000, baseWaterLevel: 1);
      await world.ensureAddAll([floor, holder, sea]);

      expect(physics.collectBodies(), containsAll([floor, crate]));
      expect(physics.buoyancyVolumes, [sea]);
      for (var i = 0; i < 60; i++) {
        physics.step(1 / 60);
      }
      // Lifted by the mounted buoyancy volume: the host moved up.
      expect(holder.position.y, greaterThan(0.6));

      holder.removeFromParent();
      sea.removeFromParent();
      await game.ready();
      expect(physics.collectBodies(), [floor]);
      expect(physics.buoyancyVolumes, isEmpty);
    });
  });
}
