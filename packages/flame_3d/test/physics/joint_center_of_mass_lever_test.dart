import 'package:flame_3d/collisions.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/physics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Joints use the center of mass as lever origin', () {
    test('a ball socket holds an off-center compound body at its anchor', () {
      final world = PhysicsWorld3D(
        autoStep: false,
        velocityIterations: 12,
        positionIterations: 5,
      );
      final pivot = RigidBody3D(
        bodyType: BodyType3D.static,
        shape: SphereShape3D(radius: 0.05),
        position: Vector3(0, 5, 0),
      );
      // Nine tenths of the mass sit one meter out along +X.
      final arm = RigidBody3D(
        shape: CompoundShape3D([
          CompoundChildShape3D(
            shape: BoxShape3D(halfExtents: Vector3.all(0.1)),
          ),
          CompoundChildShape3D(
            shape: BoxShape3D(halfExtents: Vector3.all(0.1)),
            position: Vector3(1, 0, 0),
            massWeight: 9,
          ),
        ]),
        position: Vector3(0, 5, 0),
        canSleep: false,
      );
      expect(arm.localCenterOfMass.x, closeTo(0.9, 1e-6));
      world
        ..addBody(pivot)
        ..addBody(arm)
        ..addJoint(
          BallSocketJoint3D(
            bodyA: pivot,
            bodyB: arm,
            localAnchorA: Vector3.zero(),
            localAnchorB: Vector3.zero(),
          ),
        );
      for (var i = 0; i < 120; i++) {
        world.step(1 / 60);
        // The arm's origin is the anchor: it stays at the pivot.
        expect(arm.position.distanceTo(pivot.position), lessThan(0.03));
      }
      // And it swung down.
      expect(arm.worldCenterOfMass.y, lessThan(4.5));
    });
  });
}
