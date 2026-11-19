import 'dart:math' as math;

import 'package:flame_3d/collisions.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/physics.dart';
import 'package:flutter_test/flutter_test.dart';

/// A cube of half-size [h] whose 12 edges are bevelled by [c].
List<Vector3> _chamferedCube(double h, double c) {
  final b = h - c;
  return [
    for (final sx in const [-1.0, 1.0])
      for (final sy in const [-1.0, 1.0])
        for (final sz in const [-1.0, 1.0]) ...[
          Vector3(sx * h, sy * b, sz * b),
          Vector3(sx * b, sy * h, sz * b),
          Vector3(sx * b, sy * b, sz * h),
        ],
  ];
}

List<Vector3> _icosahedron(double r) {
  const t = 1.618033988749895;
  return [
    for (final v in [
      Vector3(-1, t, 0),
      Vector3(1, t, 0),
      Vector3(-1, -t, 0),
      Vector3(1, -t, 0),
      Vector3(0, -1, t),
      Vector3(0, 1, t),
      Vector3(0, -1, -t),
      Vector3(0, 1, -t),
      Vector3(t, 0, -1),
      Vector3(t, 0, 1),
      Vector3(-t, 0, -1),
      Vector3(-t, 0, 1),
    ])
      v.normalized()..scale(r),
  ];
}

class _ThrowStats() {
  int slept = 0;
  int maxSteps = 0;
  int totalSteps = 0;
  int tilted = 0;
  double maxPenetration = 0;
  late final List<int> counts;

  double get meanSeconds => totalSteps / slept / 60;
}

/// Throws one die [throws] times (seeds `1000..`) onto a large box floor with
/// the default world settings, and reads the face pointing up.
_ThrowStats _throwMany(
  Shape3D shape,
  List<Vector3> faceNormals,
  List<Vector3> corners,
  int throws,
) {
  final stats = _ThrowStats()..counts = List.filled(faceNormals.length, 0);
  final upCos = math.cos(8 * math.pi / 180);
  for (var s = 0; s < throws; s++) {
    final world = PhysicsWorld3D(autoStep: false);
    final floor = RigidBody3D(
      bodyType: BodyType3D.static,
      shape: BoxShape3D(halfExtents: Vector3(60, 0.5, 60)),
      position: Vector3(0, -0.5, 0),
      friction: 0.6,
      restitution: 0.35,
    );
    final die = RigidBody3D(shape: shape, friction: 0.6, restitution: 0.35);
    world
      ..addBody(floor)
      ..addBody(die)
      ..throwDice3D([die], seed: 1000 + s);
    var steps = 0;
    while (!die.isSleeping && steps < 1200) {
      world.step(1 / 60);
      steps++;
    }
    if (!die.isSleeping) {
      continue;
    }
    stats
      ..slept += 1
      ..totalSteps += steps
      ..maxSteps = math.max(stats.maxSteps, steps);
    final m = die.bodyWorldMatrix;
    for (final v in corners) {
      stats.maxPenetration = math.max(
        stats.maxPenetration,
        -m.transformed3(v).y,
      );
    }
    final r = die.bodyRotation.asRotationMatrix();
    var best = 0;
    var bestUp = -2.0;
    for (var f = 0; f < faceNormals.length; f++) {
      final up = r.transformed(faceNormals[f]).y;
      if (up > bestUp) {
        bestUp = up;
        best = f;
      }
    }
    if (bestUp < upCos) {
      stats.tilted++;
    }
    stats.counts[best]++;
  }
  return stats;
}

double _chiSquare(List<int> counts) {
  final total = counts.fold<int>(0, (a, b) => a + b);
  final expected = total / counts.length;
  var chi = 0.0;
  for (final c in counts) {
    chi += (c - expected) * (c - expected) / expected;
  }
  return chi;
}

final _axisNormals = [
  Vector3(1, 0, 0),
  Vector3(-1, 0, 0),
  Vector3(0, 1, 0),
  Vector3(0, -1, 0),
  Vector3(0, 0, 1),
  Vector3(0, 0, -1),
];

void main() {
  group('Convex hull dice come to rest with the default settings', () {
    test(
      '2000 seeded throws of a bevelled hull d6: every die sleeps within '
      '7.5 s, the faces are fair and the die does not sink',
      () {
        final vertices = _chamferedCube(0.25, 0.02);
        final stats = _throwMany(
          ConvexHullShape3D(vertices: vertices),
          _axisNormals,
          vertices,
          2000,
        );
        expect(stats.slept, 2000);
        expect(stats.maxSteps, lessThanOrEqualTo(450));
        // Five degrees of freedom: 20.5 is the 0.1 % critical value.
        expect(_chiSquare(stats.counts), lessThan(20.5));
        // Resting depth stays within the solver slop (4 mm by default).
        expect(stats.maxPenetration, lessThan(0.0045));
        // A bevel strip is a (narrow) stable face: rare rests on it.
        expect(stats.tilted, lessThan(30));
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test('a hull d6 settles about as fast as a box d6', () {
      final boxStats = _throwMany(
        BoxShape3D(halfExtents: Vector3.all(0.25)),
        _axisNormals,
        _chamferedCube(0.25, 0),
        300,
      );
      final hullStats = _throwMany(
        ConvexHullShape3D(vertices: _chamferedCube(0.25, 0)),
        _axisNormals,
        _chamferedCube(0.25, 0),
        300,
      );
      expect(boxStats.slept, 300);
      expect(hullStats.slept, 300);
      expect(hullStats.meanSeconds, lessThan(boxStats.meanSeconds * 1.15));
      expect(hullStats.maxPenetration, lessThan(0.0045));
    });

    test('d8 and d20 hulls settle fairly', () {
      final d8Vertices = [
        Vector3(0.3, 0, 0),
        Vector3(-0.3, 0, 0),
        Vector3(0, 0.3, 0),
        Vector3(0, -0.3, 0),
        Vector3(0, 0, 0.3),
        Vector3(0, 0, -0.3),
      ];
      final d8 = ConvexHullShape3D(vertices: d8Vertices);
      final d8Stats = _throwMany(
        d8,
        [for (var f = 0; f < d8.faceCount; f++) d8.faceNormal(f)],
        d8Vertices,
        400,
      );
      expect(d8Stats.slept, 400);
      expect(d8Stats.tilted, 0);
      expect(_chiSquare(d8Stats.counts), lessThan(24.3)); // df 7

      final d20Vertices = _icosahedron(0.3);
      final d20 = ConvexHullShape3D(vertices: d20Vertices);
      final d20Stats = _throwMany(
        d20,
        [for (var f = 0; f < d20.faceCount; f++) d20.faceNormal(f)],
        d20Vertices,
        600,
      );
      expect(d20Stats.slept, 600);
      expect(d20Stats.tilted, 0);
      expect(_chiSquare(d20Stats.counts), lessThan(43.8)); // df 19
      expect(d20Stats.maxPenetration, lessThan(0.0045));
    });
  });

  group('Box stacks', () {
    test('a column of six boxes stands and sleeps with the defaults', () {
      final world = PhysicsWorld3D(autoStep: false);
      world.addBody(
        RigidBody3D(
          bodyType: BodyType3D.static,
          shape: BoxShape3D(halfExtents: Vector3(10, 0.5, 10)),
          position: Vector3(0, -0.5, 0),
          friction: 0.6,
        ),
      );
      final boxes = [
        for (var i = 0; i < 6; i++)
          RigidBody3D(
            shape: BoxShape3D(halfExtents: Vector3.all(0.25)),
            position: Vector3(0, 0.25 + i * 0.5, 0),
            friction: 0.6,
          ),
      ];
      boxes.forEach(world.addBody);
      var maxDrift = 0.0;
      var asleepAt = -1;
      for (var s = 0; s < 600; s++) {
        world.step(1 / 60);
        for (final b in boxes) {
          maxDrift = math.max(
            maxDrift,
            math.sqrt(
              b.position.x * b.position.x + b.position.z * b.position.z,
            ),
          );
        }
        if (asleepAt < 0 && boxes.every((b) => b.isSleeping)) {
          asleepAt = s;
        }
      }
      expect(maxDrift, lessThan(0.04));
      expect(asleepAt, inInclusiveRange(0, 180));
      expect(boxes.last.position.y, closeTo(2.75, 0.02));
    });

    test('touching bodies fall asleep together and wake together', () {
      final world = PhysicsWorld3D(autoStep: false);
      world.addBody(
        RigidBody3D(
          bodyType: BodyType3D.static,
          shape: BoxShape3D(halfExtents: Vector3(10, 0.5, 10)),
          position: Vector3(0, -0.5, 0),
        ),
      );
      final lower = RigidBody3D(
        shape: BoxShape3D(halfExtents: Vector3.all(0.25)),
        position: Vector3(0, 0.25, 0),
      );
      final upper = RigidBody3D(
        shape: BoxShape3D(halfExtents: Vector3.all(0.25)),
        position: Vector3(0, 0.75, 0),
      );
      world
        ..addBody(lower)
        ..addBody(upper);
      var first = -1;
      for (var s = 0; s < 120 && !(lower.isSleeping && upper.isSleeping); s++) {
        world.step(1 / 60);
        if (first < 0 && (lower.isSleeping || upper.isSleeping)) {
          first = s;
          expect(lower.isSleeping, upper.isSleeping);
        }
      }
      expect(lower.isSleeping && upper.isSleeping, isTrue);

      // Pushing the lower box wakes the box resting on it.
      lower.applyImpulse(Vector3(0.5, 0, 0));
      world.step(1 / 60);
      expect(upper.isSleeping, isFalse);
    });
  });
}
