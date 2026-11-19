import 'dart:math' as math;

import 'package:flame_3d/collisions.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/physics.dart';
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
  group('ConvexHullShape3D faces', () {
    test('merges coplanar triangles into polygon faces', () {
      final cube = ConvexHullShape3D(
        vertices: [
          for (final x in const [-0.5, 0.5])
            for (final y in const [-0.5, 0.5])
              for (final z in const [-0.5, 0.5]) Vector3(x, y, z),
          Vector3(0.1, 0.1, 0.1), // inside: ignored
          Vector3(0.5, 0.0, 0.0), // on a face: ignored
        ],
      );
      expect(cube.faceCount, 6);
      for (var f = 0; f < 6; f++) {
        expect(cube.faceVertexIndices(f), hasLength(4));
      }

      final chamfered = ConvexHullShape3D(vertices: chamferedCube(0.25, 0.04));
      expect(chamfered.faceCount, 26);
      var squares = 0;
      var triangles = 0;
      for (var f = 0; f < chamfered.faceCount; f++) {
        final n = chamfered.faceNormal(f);
        expect(n.length, closeTo(1, 1e-6));
        final corners = chamfered.faceVertexIndices(f);
        if (corners.length == 3) {
          triangles++;
        }
        if (n.x.abs() > 0.999 || n.y.abs() > 0.999 || n.z.abs() > 0.999) {
          squares++;
        }
        // Corners run counter-clockwise around the outward normal.
        final v = chamfered.vertices;
        final e1 = v[corners[1]] - v[corners[0]];
        final e2 = v[corners[2]] - v[corners[1]];
        expect(e1.cross(e2).dot(n), greaterThan(0));
      }
      expect(squares, 6);
      expect(triangles, 8);

      expect(ConvexHullShape3D(vertices: icosahedron(0.3)).faceCount, 20);
      expect(ConvexHullShape3D(vertices: octahedron(0.3)).faceCount, 8);
    });

    test('degenerate point sets have no faces but still collide', () {
      final flat = ConvexHullShape3D(
        vertices: [
          Vector3(0, 0, 0),
          Vector3(1, 0, 0),
          Vector3(0, 1, 0),
          Vector3(1, 1, 0),
        ],
      );
      expect(flat.faceCount, 0);
      expect(() => flat.faceNormal(0), throwsRangeError);
      final floor = BoxShape3D(halfExtents: Vector3(2, 0.5, 2));
      final m = Narrowphase3D.test(
        flat,
        _pose(Vector3(0, 0.49, 0), Quaternion.axisAngle(Vector3(1, 0, 0), 1)),
        floor,
        _pose(Vector3.zero()),
      );
      expect(m, isNotNull);
    });
  });

  group('ConvexHullShape3D mass properties come from the hull', () {
    test('volume, center of mass and inertia tensor are exact', () {
      final cube = ConvexHullShape3D(
        vertices: [
          for (final x in const [-0.5, 0.5])
            for (final y in const [-0.5, 0.5])
              for (final z in const [-0.5, 0.5]) Vector3(x, y, z),
        ],
      );
      expect(cube.estimateLocalVolume(), closeTo(1.0, 1e-9));
      final cubeI = cube.computeLocalInertiaDiagonal(6);
      expect(cubeI.x, closeTo(1.0, 1e-6)); // m (a^2 + a^2) / 12
      expect(cubeI.y, closeTo(1.0, 1e-6));

      // Right tetrahedron: the center of mass is the vertex mean and the
      // tensor has products of inertia.
      final tet = ConvexHullShape3D(
        vertices: [
          Vector3(0, 0, 0),
          Vector3(1, 0, 0),
          Vector3(0, 1, 0),
          Vector3(0, 0, 1),
        ],
      );
      expect(tet.estimateLocalVolume(), closeTo(1 / 6, 1e-9));
      expect(tet.localCenterOfMass.x, closeTo(0.25, 1e-6));
      expect(tet.localCenterOfMass.y, closeTo(0.25, 1e-6));
      expect(tet.localCenterOfMass.z, closeTo(0.25, 1e-6));
      final t = tet.computeLocalInertiaTensor(1).storage;
      expect(t[0], closeTo(3 / 40, 1e-6));
      expect(t[1], closeTo(1 / 80, 1e-6)); // Ixy = -m * cov(x, y)
      expect(t[5], closeTo(1 / 80, 1e-6));

      // The default CCD sphere is the true inradius about the center of
      // mass (an octahedron's, not its circumradius).
      final d8 = ConvexHullShape3D(vertices: octahedron(0.3));
      expect(d8.inscribedSphereRadius, closeTo(0.3 / math.sqrt(3), 1e-6));
      expect(d8.estimateLocalVolume(), closeTo(4 / 3 * 0.027, 1e-6));
      final d20 = ConvexHullShape3D(vertices: icosahedron(0.3));
      expect(d20.inscribedSphereRadius, closeTo(0.3 * 0.7946544722, 1e-5));
    });

    test('a hull body with an off-center mass uses the full tensor', () {
      final tet = ConvexHullShape3D(
        vertices: [
          Vector3(0, 0, 0),
          Vector3(1, 0, 0),
          Vector3(0, 1, 0),
          Vector3(0, 0, 1),
        ],
      );
      final body = RigidBody3D(shape: tet, mass: 2);
      expect(body.hasCenterOfMassOffset, isTrue);
      expect(body.localCenterOfMass.x, closeTo(0.25, 1e-6));
      final inv = body.worldInvInertia.storage;
      expect(inv[1].abs(), greaterThan(1e-3)); // products of inertia
    });
  });
}
