import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame_3d/collisions.dart';
import 'package:flame_3d/core.dart';
import 'package:flutter_test/flutter_test.dart';

/// A cube of half-size [h] whose 12 edges are bevelled by [c]: 6 square
/// faces, 12 bevel strips and 8 corner triangles (24 vertices).
List<Vector3> chamferedCube(double h, double c) {
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

List<Vector3> icosahedron(double r) {
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

List<Vector3> octahedron(double r) => [
  Vector3(r, 0, 0),
  Vector3(-r, 0, 0),
  Vector3(0, r, 0),
  Vector3(0, -r, 0),
  Vector3(0, 0, r),
  Vector3(0, 0, -r),
];

Matrix4 _pose(Vector3 position, [Quaternion? rotation]) => Matrix4.compose(
  position,
  rotation ?? Quaternion.identity(),
  Vector3(1, 1, 1),
);

void main() {
  group('Face contact manifolds', () {
    final floor = BoxShape3D(halfExtents: Vector3(5, 0.5, 5));
    final floorAt = _pose(Vector3(0, -0.5, 0));

    test('a hull face resting on a box gives four contact points', () {
      final die = ConvexHullShape3D(vertices: chamferedCube(0.25, 0.04));
      final m = Narrowphase3D.test(
        die,
        _pose(Vector3(0.3, 0.248, -0.2)),
        floor,
        floorAt,
      )!;
      expect(m.contacts, hasLength(4));
      expect(m.normal.y, closeTo(-1, 1e-9)); // from the die toward the floor
      for (final c in m.contacts) {
        expect(c.penetrationDepth, closeTo(0.002, 1e-6));
        expect(c.pointB.y, closeTo(0, 1e-9));
      }
      // The corners of the die's bottom square (half-size 0.25 - 0.04).
      final xs = [for (final c in m.contacts) c.pointA.x - 0.3]..sort();
      expect(xs.first, closeTo(-0.21, 1e-6));
      expect(xs.last, closeTo(0.21, 1e-6));
    });

    test('hull on hull and hull on a tilted face', () {
      final a = ConvexHullShape3D(vertices: chamferedCube(0.25, 0.04));
      final b = ConvexHullShape3D(vertices: chamferedCube(0.25, 0.04));
      final stacked = Narrowphase3D.test(
        a,
        _pose(Vector3.zero()),
        b,
        _pose(Vector3(0.05, 0.497, 0)),
      )!;
      expect(stacked.contacts, hasLength(4));
      expect(stacked.normal.y, closeTo(1, 1e-9));

      // A die balanced on an edge touches the floor along that edge.
      final onEdge = Narrowphase3D.test(
        a,
        _pose(
          Vector3(0, 0.25 * math.sqrt2 - 0.03, 0),
          Quaternion.axisAngle(Vector3(0, 0, 1), math.pi / 4),
        ),
        floor,
        floorAt,
      )!;
      expect(onEdge.contacts.length, inInclusiveRange(2, 4));
      for (final c in onEdge.contacts) {
        expect(c.pointA.x.abs(), lessThan(0.03));
      }

      // Edge across edge keeps the single EPA point.
      final crossed = Narrowphase3D.test(
        BoxShape3D(halfExtents: Vector3.all(0.25)),
        _pose(
          Vector3.zero(),
          Quaternion.axisAngle(Vector3(0, 0, 1), math.pi / 4),
        ),
        ConvexHullShape3D(vertices: chamferedCube(0.25, 0)),
        _pose(
          Vector3(0, 0.25 * math.sqrt2 * 2 - 0.01, 0),
          Quaternion.axisAngle(Vector3(1, 0, 0), math.pi / 4),
        ),
      )!;
      expect(crossed.contacts, hasLength(1));
    });

    test('feature ids stay the same while the same features touch', () {
      final die = ConvexHullShape3D(vertices: chamferedCube(0.25, 0.04));
      Set<int> ids(double dx, double angle) {
        final m = Narrowphase3D.test(
          die,
          _pose(
            Vector3(dx, 0.247, 0),
            Quaternion.axisAngle(Vector3(0, 1, 0), angle),
          ),
          floor,
          floorAt,
        )!;
        return {for (final c in m.contacts) c.featureId};
      }

      final base = ids(0, 0);
      expect(base, hasLength(4));
      expect(ids(0.01, 0.02), base);

      // Two equal boxes stacked edge on edge (corners exactly on the side
      // planes) keep their ids under float noise.
      final box = BoxShape3D(halfExtents: Vector3.all(0.25));
      Set<int> boxIds(double tilt) {
        final m = Narrowphase3D.test(
          box,
          _pose(Vector3.zero()),
          box,
          _pose(
            Vector3(0, 0.499, 0),
            Quaternion.axisAngle(Vector3(1, 0, 0), tilt),
          ),
        )!;
        return {for (final c in m.contacts) c.featureId};
      }

      final boxBase = boxIds(0);
      expect(boxBase, hasLength(4));
      expect(boxIds(1e-6), boxBase);
      expect(boxIds(-1e-6), boxBase);
    });

    test('hull faces on heightfield triangles give several points', () {
      final terrain = HeightfieldShape3D(
        heights: Float32List(16),
        columns: 4,
        rows: 4,
        width: 6,
        depth: 6,
      );
      final die = ConvexHullShape3D(vertices: chamferedCube(0.25, 0.04));
      final all = Narrowphase3D.testAll(
        die,
        _pose(Vector3(0.1, 0.248, 0.1)),
        terrain,
        _pose(Vector3.zero()),
      );
      var points = 0;
      for (final m in all) {
        points += m.contacts.length;
      }
      expect(points, greaterThanOrEqualTo(3));
    });
  });
}
