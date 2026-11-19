import 'package:flame_3d/collisions.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/physics.dart';
import 'package:flutter_test/flutter_test.dart';

RigidBody3D _floor({double friction = 0.6, double restitution = 0.0}) =>
    RigidBody3D(
      bodyType: BodyType3D.static,
      shape: BoxShape3D(halfExtents: Vector3(20, 0.5, 20)),
      position: Vector3(0, -0.5, 0),
      friction: friction,
      restitution: restitution,
    );

void main() {
  group('Vehicles', () {
    test('a custom axle sets the rolling direction', () {
      final world = PhysicsWorld3D(autoStep: false);
      final chassis = RigidBody3D(
        shape: BoxShape3D(halfExtents: Vector3(0.9, 0.3, 0.9)),
        mass: 100,
        position: Vector3(0, 0.9, 0),
        canSleep: false,
      );
      // Axles along Z: the wheels roll along X, whatever forwardAxisLocal.
      final car = RaycastVehicle3D(
        chassis: chassis,
        wheels: [
          for (final (x, z) in const [
            (-0.8, 0.8),
            (0.8, 0.8),
            (-0.8, -0.8),
            (0.8, -0.8),
          ])
            WheelSpec3D(
              connectionPointLocal: Vector3(x, -0.1, z),
              axleDirectionLocal: Vector3(0, 0, 1),
            ),
        ],
      )..throttle = 1;
      world
        ..addBody(_floor())
        ..addBody(chassis)
        ..addVehicle(car);
      for (var i = 0; i < 90; i++) {
        world.step(1 / 60);
      }
      expect(chassis.position.x.abs(), greaterThan(0.5));
      expect(chassis.position.z.abs(), lessThan(chassis.position.x.abs() / 5));
    });

    test('fourWheel lays the wheels out along forwardAxisLocal', () {
      final car = RaycastVehicle3D.fourWheel(
        chassis: RigidBody3D(shape: BoxShape3D(halfExtents: Vector3.all(1))),
        forwardAxisLocal: Vector3(1, 0, 0),
        connectionHeight: -0.1,
      );
      final front = car.wheels.where((w) => w.isSteerable).toList();
      expect(front, hasLength(2));
      for (final w in front) {
        expect(w.connectionPointLocal.x, closeTo(1.25, 1e-6));
        expect(w.connectionPointLocal.z.abs(), closeTo(0.85, 1e-6));
        expect(w.connectionPointLocal.y, closeTo(-0.1, 1e-6));
      }
      // Facing +Z (the default) keeps the historical layout.
      final zCar = RaycastVehicle3D.fourWheel(
        chassis: RigidBody3D(shape: BoxShape3D(halfExtents: Vector3.all(1))),
      );
      expect(zCar.wheels[0].connectionPointLocal, Vector3(-0.85, 0, 1.25));
      expect(zCar.wheels[3].connectionPointLocal, Vector3(0.85, 0, -1.25));
    });
  });
}
