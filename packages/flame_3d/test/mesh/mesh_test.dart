import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame_3d/core.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_fakes/fake_gpu_backend.dart';

Surface _triangle(Vector3 a, Vector3 b, Vector3 c) {
  return Surface(
    vertices: [
      for (final p in [a, b, c]) Vertex(position: p, texCoord: Vector2.zero()),
    ],
    indices: [0, 1, 2],
  );
}

TerrainMesh3D _terrain(TerrainUpAxis upAxis) {
  const columns = 6;
  const rows = 5;
  final heights = Float32List(columns * rows);
  for (var i = 0; i < heights.length; i++) {
    heights[i] = math.sin(i * 0.7) * 0.4;
  }
  return TerrainMesh3D(
    columns: columns,
    rows: rows,
    width: 4,
    depth: 3,
    heights: heights,
    upAxis: upAxis,
  );
}

void main() {
  setUp(FakeGpuBackend.new);

  group('Mesh', () {
    test('bounds every surface without changing their own bounds', () {
      final first = _triangle(
        Vector3.zero(),
        Vector3(1, 0, 0),
        Vector3(0, 1, 0),
      );
      final second = _triangle(
        Vector3(5, 5, 5),
        Vector3(6, 5, 5),
        Vector3(5, 6, 5),
      );
      final mesh = Mesh()
        ..addSurface(first)
        ..addSurface(second);

      expect(mesh.aabb.min, Vector3.zero());
      expect(mesh.aabb.max, Vector3(6, 6, 5));
      expect(first.aabb.max, Vector3(1, 1, 0));
      expect(second.aabb.min, Vector3(5, 5, 5));
    });
  });

  group('built-in meshes', () {
    // Front faces are counter-clockwise: the normal given by the winding
    // must point out of the (convex) mesh, and agree with the vertex normals.
    final meshes = {
      'CuboidMesh': () => CuboidMesh(size: Vector3(1, 2, 3)),
      'PlaneMesh': () => PlaneMesh(size: Vector2(2, 3)),
      'SphereMesh': () => SphereMesh(radius: 1, segments: 12),
      'CylinderMesh': () => CylinderMesh(radius: 1, height: 2),
      'ConeMesh': () => ConeMesh(
        radius: 1,
        height: 2,
        segments: 12,
        material: Material.defaultMaterial,
      ),
    };

    for (final MapEntry(key: name, value: create) in meshes.entries) {
      test('$name has outward, counter-clockwise front faces', () {
        final mesh = create();
        final center = (mesh.aabb.min + mesh.aabb.max) / 2;
        for (final surface in mesh.surfaces) {
          final stride = surface.layout.strideInFloats;
          final data = surface.vertexData;
          Vector3 position(int i) => Vector3(
            data[i * stride],
            data[i * stride + 1],
            data[i * stride + 2],
          );
          Vector3 normal(int i) => Vector3(
            data[i * stride + 9],
            data[i * stride + 10],
            data[i * stride + 11],
          );
          for (var t = 0; t < surface.indexCount; t += 3) {
            final a = surface.indices[t];
            final b = surface.indices[t + 1];
            final c = surface.indices[t + 2];
            final face = (position(b) - position(a)).cross(
              position(c) - position(a),
            );
            if (face.length < 1e-9) {
              continue;
            }
            final centroid = (position(a) + position(b) + position(c)) / 3;
            final outward = name == 'PlaneMesh'
                ? Vector3(0, 1, 0)
                : centroid - center;
            expect(
              face.dot(outward),
              greaterThan(0),
              reason: 'triangle ${t ~/ 3} faces inwards',
            );
            for (final vertex in [a, b, c]) {
              expect(
                normal(vertex).dot(face),
                greaterThan(0),
                reason: 'vertex $vertex has an inward normal',
              );
            }
          }
        }
      });
    }

    // Meshes that are not convex: the winding must agree with the vertex
    // normals, which point out of the surface.
    final curved = {
      'TorusMesh': () => TorusMesh(majorSegments: 12, minorSegments: 8),
      'TubeSplineMesh': () => TubeSplineMesh(
        spline: CatmullRomSpline3D([
          Vector3.zero(),
          Vector3(1, 0.5, 0),
          Vector3(2, 0, 1),
          Vector3(3, 1, 1),
        ]),
        tubularSegments: 12,
        radialSegments: 6,
      ),
      'CapsuleMesh': () => CapsuleMesh(radius: 0.5, height: 2, segments: 8),
      'TerrainMesh3D (y up)': () => _terrain(TerrainUpAxis.y),
      'TerrainMesh3D (z up)': () => _terrain(TerrainUpAxis.z),
    };

    for (final MapEntry(key: name, value: create) in curved.entries) {
      test('$name winds every front face along its normals', () {
        final mesh = create();
        for (final surface in mesh.surfaces) {
          final stride = surface.layout.strideInFloats;
          final data = surface.vertexData;
          Vector3 position(int i) => Vector3(
            data[i * stride],
            data[i * stride + 1],
            data[i * stride + 2],
          );
          Vector3 normal(int i) => Vector3(
            data[i * stride + 9],
            data[i * stride + 10],
            data[i * stride + 11],
          );
          var checked = 0;
          for (var t = 0; t < surface.indexCount; t += 3) {
            final a = surface.indices[t];
            final b = surface.indices[t + 1];
            final c = surface.indices[t + 2];
            final face = (position(b) - position(a)).cross(
              position(c) - position(a),
            );
            if (face.length < 1e-9) {
              continue;
            }
            final averaged = normal(a) + normal(b) + normal(c);
            expect(
              averaged.dot(face),
              greaterThan(0),
              reason: 'triangle ${t ~/ 3} is wound against its normals',
            );
            checked++;
          }
          expect(checked, greaterThan(0));
        }
      });
    }

    test('TubeSplineMesh keeps its cross-sections across the curve', () {
      final spline = CatmullRomSpline3D([
        Vector3.zero(),
        Vector3(1, 0.5, 0),
        Vector3(2, 0, 1),
        Vector3(3, 1, 1),
      ]);
      const tubular = 24;
      const radial = 6;
      final surface = TubeSplineMesh(
        spline: spline,
        tubularSegments: tubular,
        radialSegments: radial,
      ).surfaces.single;
      final stride = surface.layout.strideInFloats;
      final data = surface.vertexData;
      for (var i = 0; i <= tubular; i++) {
        final tangent = spline.sampleTangent(i / tubular)..normalize();
        for (var j = 0; j <= radial; j++) {
          final o = (i * (radial + 1) + j) * stride;
          final normal = Vector3(data[o + 9], data[o + 10], data[o + 11]);
          expect(
            normal.dot(tangent).abs(),
            lessThan(1e-3),
            reason: 'ring $i leans along the curve',
          );
        }
      }
    });

    test('CylinderMesh caps and side span the whole cylinder', () {
      final mesh = CylinderMesh(radius: 2, height: 4, segments: 8);
      final surface = mesh.surfaces.single;

      expect(mesh.aabb.min.y, -2);
      expect(mesh.aabb.max.y, 2);
      // 8 side quads and two 8-triangle caps.
      expect(surface.indexCount, (8 * 2 + 8 * 2) * 3);
    });
  });
}
