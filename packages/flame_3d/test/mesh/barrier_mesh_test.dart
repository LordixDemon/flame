import 'dart:math' as math;

import 'package:flame_3d/core.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter_test/flutter_test.dart';

/// The vertices of [mesh]'s surface: position, wall coordinates and normal.
List<(Vector3, Vector2, Vector3)> _vertices(BarrierMesh mesh) {
  final surface = mesh.surfaces.single;
  final data = surface.vertexData;
  final stride = BarrierMesh.layout.strideInFloats;
  return [
    for (var i = 0; i < surface.vertexCount; i++)
      (
        Vector3(data[i * stride], data[i * stride + 1], data[i * stride + 2]),
        Vector2(data[i * stride + 3], data[i * stride + 4]),
        Vector3(
          data[i * stride + 5],
          data[i * stride + 6],
          data[i * stride + 7],
        ),
      ),
  ];
}

/// Checks that every triangle of [mesh] faces the way its vertex normals
/// point (counter-clockwise seen from outside), and returns how many
/// triangles are not degenerate.
int _expectOutwardWinding(BarrierMesh mesh) {
  final vertices = _vertices(mesh);
  final indices = mesh.surfaces.single.indices;
  var faces = 0;
  for (var t = 0; t < indices.length; t += 3) {
    final (a, _, na) = vertices[indices[t]];
    final (b, _, nb) = vertices[indices[t + 1]];
    final (c, _, nc) = vertices[indices[t + 2]];
    final face = (b - a).cross(c - a);
    if (face.length < 1e-9) {
      continue;
    }
    faces++;
    expect(face.dot(na + nb + nc), greaterThan(0), reason: 'triangle $t');
  }
  return faces;
}

void main() {
  group('BarrierMesh', () {
    test('lays out a position, wall coordinates and a normal', () {
      expect(BarrierMesh.layout.strideInFloats, 8);
      expect(
        [for (final a in BarrierMesh.layout.attributes) a.name],
        ['vertexPosition', 'vertexTexCoord', 'vertexNormal'],
      );
      final mesh = BarrierMesh.ring(radius: 1, height: 1);
      expect(mesh.surfaces.single.layout, BarrierMesh.layout);
    });

    group('roundedRectangle', () {
      const width = 6.0;
      const depth = 4.0;
      const height = 0.8;
      const radius = 0.5;
      const segments = 6;
      final mesh = BarrierMesh.roundedRectangle(
        width: width,
        depth: depth,
        height: height,
        cornerRadius: radius,
        cornerSegments: segments,
      );

      test('measures its length along its foot', () {
        // The straight sides, and each corner's chords.
        final chord = 2 * radius * math.sin(math.pi / 4 / segments);
        final expected =
            2 * (width - 2 * radius) +
            2 * (depth - 2 * radius) +
            4 * segments * chord;
        expect(mesh.length, closeTo(expected, 1e-9));
        expect(mesh.height, height);
        expect(mesh.shape, BarrierMeshShape.roundedRectangle);
      });

      test('stands on its foot with distances from 0 to its length', () {
        final vertices = _vertices(mesh);
        var previous = -1.0;
        for (final (position, wall, _) in vertices) {
          expect(wall.x, greaterThanOrEqualTo(previous - 1e-6));
          previous = wall.x;
          expect(wall.y == 0 || wall.y == 1, isTrue);
          expect(position.y, closeTo(wall.y * height, 1e-6));
          expect(position.x.abs(), lessThanOrEqualTo(width / 2 + 1e-6));
          expect(position.z.abs(), lessThanOrEqualTo(depth / 2 + 1e-6));
        }
        // It starts and ends at the middle of the +x side.
        expect(vertices.first.$1, Vector3(width / 2, 0, 0));
        expect(vertices.first.$2.x, 0);
        expect(vertices.last.$1.x, closeTo(width / 2, 1e-6));
        expect(vertices.last.$1.z, closeTo(0, 1e-6));
        expect(vertices.last.$2.x, closeTo(mesh.length, 1e-5));
      });

      test('runs counter-clockwise seen from above, from +x towards -z', () {
        final vertices = _vertices(mesh);
        final (second, _, _) = vertices[2];
        expect(second.x, closeTo(width / 2, 1e-6));
        expect(second.z, lessThan(0));
      });

      test('has unit normals pointing out, and faces facing out', () {
        for (final (position, _, normal) in _vertices(mesh)) {
          expect(normal.length, closeTo(1, 1e-6));
          expect(normal.y, 0);
          expect(
            normal.x * position.x / width + normal.z * position.z / depth,
            greaterThan(0),
          );
        }
        // Four sides (the +x side in two halves, where the loop starts) and
        // four corners of six segments, two triangles each.
        expect(_expectOutwardWinding(mesh), (5 + 4 * segments) * 2);
      });

      test('has sharp corners with the normal of each side', () {
        final sharp = BarrierMesh.roundedRectangle(
          width: 2,
          depth: 1,
          height: 1,
        );
        expect(sharp.length, closeTo(6, 1e-9));
        final corners = _vertices(sharp)
            .where(
              (v) =>
                  v.$2.y == 0 &&
                  (v.$1.x.abs() - 1).abs() < 1e-9 &&
                  (v.$1.z.abs() - 0.5).abs() < 1e-9,
            )
            .toList();
        // Two foot vertices per corner, with the normals of its two sides.
        expect(corners, hasLength(8));
        for (final (_, _, normal) in corners) {
          expect(normal.x.abs() + normal.z.abs(), closeTo(1, 1e-9));
        }
        expect(_expectOutwardWinding(sharp), 10);
      });

      test('gives points on the wall by distance and height', () {
        final p = mesh.pointOnWall(0, 0.5);
        expect(p, Vector3(width / 2, height / 2, 0));
        // Half way round: the middle of the -x side.
        final q = mesh.pointOnWall(mesh.length / 2, 0);
        expect(q.x, closeTo(-width / 2, 1e-6));
        expect(q.z, closeTo(0, 1e-6));
        // Distances wrap around the loop.
        final r = mesh.pointOnWall(mesh.length + 0.3, 1);
        final s = mesh.pointOnWall(0.3, 1, Vector3.zero());
        expect(r.x, closeTo(s.x, 1e-6));
        expect(r.y, closeTo(height, 1e-6));
        expect(r.z, closeTo(-0.3, 1e-6));
      });

      test('rejects sizes that are not positive', () {
        expect(
          () => BarrierMesh.roundedRectangle(width: 0, depth: 1, height: 1),
          throwsArgumentError,
        );
        expect(
          () => BarrierMesh.roundedRectangle(
            width: 1,
            depth: 1,
            height: 1,
            cornerSegments: 0,
          ),
          throwsArgumentError,
        );
      });
    });

    group('ring', () {
      test('is a band around a circle', () {
        const segments = 32;
        final ring = BarrierMesh.ring(
          radius: 2,
          height: 0.5,
          segments: segments,
        );
        expect(
          ring.length,
          closeTo(segments * 2 * 2 * math.sin(math.pi / segments), 1e-9),
        );
        final vertices = _vertices(ring);
        expect(vertices, hasLength((segments + 1) * 2));
        for (final (position, wall, normal) in vertices) {
          expect(
            math.sqrt(position.x * position.x + position.z * position.z),
            closeTo(2, 1e-6),
          );
          expect(position.y, closeTo(wall.y * 0.5, 1e-6));
          expect(normal.x, closeTo(position.x / 2, 1e-6));
          expect(normal.z, closeTo(position.z / 2, 1e-6));
        }
        expect(vertices.first.$1, Vector3(2, 0, 0));
        expect(vertices.last.$1, Vector3(2, 0.5, 0));
        expect(_expectOutwardWinding(ring), segments * 2);
      });

      test('rejects too few segments', () {
        expect(
          () => BarrierMesh.ring(radius: 1, height: 1, segments: 2),
          throwsArgumentError,
        );
      });
    });

    group('dome', () {
      const segments = 24;
      const rings = 8;
      final dome = BarrierMesh.dome(
        radius: 1.5,
        segments: segments,
        rings: rings,
      );

      test('is the upper half of a sphere, by elevation from its rim', () {
        final vertices = _vertices(dome);
        expect(vertices, hasLength((segments + 1) * (rings + 1)));
        for (final (position, wall, normal) in vertices) {
          expect(position.length, closeTo(1.5, 1e-5));
          expect(position.y, greaterThanOrEqualTo(-1e-9));
          expect(
            math.asin((position.y / 1.5).clamp(-1, 1)) / (math.pi / 2),
            closeTo(wall.y, 1e-5),
          );
          expect((normal - position / 1.5).length, lessThan(1e-5));
        }
        expect(dome.height, 1.5);
        expect(dome.shape, BarrierMeshShape.dome);
      });

      test('meets at its pole with one triangle per segment', () {
        expect(
          dome.surfaces.single.indices.length ~/ 3,
          segments * (2 * rings - 1),
        );
        expect(_expectOutwardWinding(dome), segments * (2 * rings - 1));
        final pole = dome.pointOnWall(1, 1);
        expect(pole.x, closeTo(0, 1e-6));
        expect(pole.y, closeTo(1.5, 1e-6));
        expect(pole.z, closeTo(0, 1e-6));
        final rim = dome.pointOnWall(0, 0);
        expect(rim, Vector3(1.5, 0, 0));
      });

      test('refuses more vertices than 16-bit indices reach', () {
        expect(
          () => BarrierMesh.dome(radius: 1, segments: 1024, rings: 64),
          throwsArgumentError,
        );
      });
    });
  });
}
