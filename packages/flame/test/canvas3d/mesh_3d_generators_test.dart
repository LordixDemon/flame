import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame/canvas3d.dart';
import 'package:flutter_test/flutter_test.dart';

/// Signed volume of a closed mesh by the divergence theorem: positive when
/// its counter-clockwise triangles face outwards.
double _signedVolume(Mesh3D m) {
  var sum = 0.0;
  final p = m.positions;
  for (var i = 0; i < m.indices.length; i += 3) {
    final a = m.indices[i] * 3;
    final b = m.indices[i + 1] * 3;
    final c = m.indices[i + 2] * 3;
    sum +=
        p[a] * (p[b + 1] * p[c + 2] - p[b + 2] * p[c + 1]) -
        p[a + 1] * (p[b] * p[c + 2] - p[b + 2] * p[c]) +
        p[a + 2] * (p[b] * p[c + 1] - p[b + 1] * p[c]);
  }
  return sum / 6.0;
}

/// Every normal is unit length, and every triangle's geometric (winding)
/// normal agrees with the normals stored on its vertices.
void _expectConsistentNormalsAndWinding(
  Mesh3D m, {
  bool allowPoleTriangles = false,
}) {
  for (var v = 0; v < m.vertexCount; v++) {
    final n = m.normals;
    final len = math.sqrt(
      n[v * 3] * n[v * 3] +
          n[v * 3 + 1] * n[v * 3 + 1] +
          n[v * 3 + 2] * n[v * 3 + 2],
    );
    expect(len, closeTo(1.0, 1e-5), reason: 'normal of vertex $v');
  }
  final p = m.positions;
  final n = m.normals;
  for (var i = 0; i < m.indices.length; i += 3) {
    final a = m.indices[i] * 3;
    final b = m.indices[i + 1] * 3;
    final c = m.indices[i + 2] * 3;
    final e1x = p[b] - p[a];
    final e1y = p[b + 1] - p[a + 1];
    final e1z = p[b + 2] - p[a + 2];
    final e2x = p[c] - p[a];
    final e2y = p[c + 1] - p[a + 1];
    final e2z = p[c + 2] - p[a + 2];
    final fx = e1y * e2z - e1z * e2y;
    final fy = e1z * e2x - e1x * e2z;
    final fz = e1x * e2y - e1y * e2x;
    final area = math.sqrt(fx * fx + fy * fy + fz * fz);
    if (allowPoleTriangles && area < 1e-9) {
      continue; // A sphere's pole fans collapse to a point.
    }
    expect(area, greaterThan(1e-9), reason: 'triangle ${i ~/ 3} is degenerate');
    for (final k in <int>[a, b, c]) {
      final dot = (fx * n[k] + fy * n[k + 1] + fz * n[k + 2]) / area;
      expect(dot, greaterThan(0.0), reason: 'triangle ${i ~/ 3} winding');
    }
  }
}

void _expectUvsInUnitSquare(Mesh3D m) {
  expect(m.uvs, isNotNull);
  expect(m.uvs!.length, m.vertexCount * 2);
  for (final u in m.uvs!) {
    expect(u, inInclusiveRange(0.0, 1.0));
  }
}

/// Every vertex normal points away from the interior point returned by
/// [interiorPointOf].
void _expectPointsAwayFrom(
  Mesh3D m,
  List<double> Function(double x, double y, double z) interiorPointOf,
) {
  final p = m.positions;
  final n = m.normals;
  for (var v = 0; v < m.vertexCount; v++) {
    final c = interiorPointOf(p[v * 3], p[v * 3 + 1], p[v * 3 + 2]);
    final dot =
        (p[v * 3] - c[0]) * n[v * 3] +
        (p[v * 3 + 1] - c[1]) * n[v * 3 + 1] +
        (p[v * 3 + 2] - c[2]) * n[v * 3 + 2];
    expect(dot, greaterThanOrEqualTo(-1e-6), reason: 'vertex $v');
  }
}

bool _insidePolygon(List<double> poly, double x, double y) {
  var inside = false;
  final n = poly.length ~/ 2;
  for (var i = 0, j = n - 1; i < n; j = i++) {
    final xi = poly[i * 2];
    final yi = poly[i * 2 + 1];
    final xj = poly[j * 2];
    final yj = poly[j * 2 + 1];
    if ((yi > y) != (yj > y) && x < (xj - xi) * (y - yi) / (yj - yi) + xi) {
      inside = !inside;
    }
  }
  return inside;
}

int _maxIndex(Mesh3D mesh) {
  var maxIdx = 0;
  for (final i in mesh.indices) {
    if (i > maxIdx) {
      maxIdx = i;
    }
  }
  return maxIdx;
}

void main() {
  group('generators and the 16-bit index limit', () {
    test('uvSphere(256 x 256) is refused and names partitionByVertexLimit', () {
      expect(
        () => Mesh3D.uvSphere(segments: 256, rings: 256),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            allOf(contains('partitionByVertexLimit'), contains('66049')),
          ),
        ),
      );
    });

    test('prism(sides: 11000) is refused and names partitionByVertexLimit', () {
      expect(
        () => Mesh3D.prism(sides: 11000),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('partitionByVertexLimit'),
          ),
        ),
      );
    });

    test('the new generators refuse oversized tessellations too', () {
      expect(
        () => Mesh3D.cylinder(segments: 40000),
        throwsA(isA<ArgumentError>()),
      );
      expect(() => Mesh3D.cone(segments: 40000), throwsA(isA<ArgumentError>()));
      expect(
        () => Mesh3D.torus(majorSegments: 300, minorSegments: 300),
        throwsA(isA<ArgumentError>()),
      );
      final ring = <double>[];
      for (var i = 0; i < 20000; i++) {
        final a = 2 * math.pi * i / 20000;
        ring
          ..add(math.cos(a))
          ..add(math.sin(a));
      }
      expect(
        () => Mesh3D.extrudePolygon(outline: ring),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('partitionByVertexLimit'),
          ),
        ),
      );
    });

    test('the largest tessellation that fits keeps its indices intact', () {
      // 255 x 255 gives 256 * 256 = 65,536 vertices: one too many.
      expect(
        () => Mesh3D.uvSphere(segments: 255, rings: 255),
        throwsA(isA<ArgumentError>()),
      );
      final sphere = Mesh3D.uvSphere(segments: 255, rings: 254);
      expect(sphere.vertexCount, 256 * 255);
      expect(_maxIndex(sphere), sphere.vertexCount - 1);
      final prism = Mesh3D.prism(sides: 10922);
      expect(prism.vertexCount, 6 * 10922 + 2);
      expect(_maxIndex(prism), prism.vertexCount - 1);
    });
  });

  group('Mesh3D.uvSphere', () {
    test('carries UVs and unit outward normals', () {
      final s = Mesh3D.uvSphere(radius: 2, segments: 12, rings: 8);
      _expectUvsInUnitSquare(s);
      expect(s.uvs![0], 0.0);
      expect(s.uvs![1], 0.0);
      _expectConsistentNormalsAndWinding(s, allowPoleTriangles: true);
    });
  });

  group('Mesh3D.cylinder', () {
    test('counts, bounds and uvs', () {
      final m = Mesh3D.cylinder(radiusTop: 0.4, baseZ: 1);
      expect(m.vertexCount, 2 * 17 + 17 + 17);
      expect(m.triangleCount, 4 * 16);
      expect(m.minX, closeTo(-0.5, 1e-6));
      expect(m.maxX, closeTo(0.5, 1e-6));
      expect(m.minY, closeTo(-0.5, 1e-6));
      expect(m.maxY, closeTo(0.5, 1e-6));
      expect(m.minZ, closeTo(1, 1e-6));
      expect(m.maxZ, closeTo(2, 1e-6));
      _expectUvsInUnitSquare(m);
    });

    test('normals are unit, point away from the axis and agree with the '
        'winding', () {
      final m = Mesh3D.cylinder(segments: 12, height: 2);
      _expectConsistentNormalsAndWinding(m);
      _expectPointsAwayFrom(m, (x, y, z) => <double>[0, 0, 1]);
      expect(_signedVolume(m), greaterThan(0));
      // A 12-gon inscribed in the unit-circle disc of radius 0.5.
      expect(
        _signedVolume(m),
        closeTo(0.5 * 12 * 0.5 * 0.5 * math.sin(2 * math.pi / 12) * 2, 1e-5),
      );
    });

    test('a frustum leans its side normals and stays closed', () {
      final m = Mesh3D.cylinder(radiusTop: 0.2, radiusBottom: 0.6, segments: 8);
      _expectConsistentNormalsAndWinding(m);
      for (var s = 0; s < 8; s++) {
        // Side vertices (before the caps): the normal tilts upwards.
        expect(m.normals[s * 6 + 2], greaterThan(0));
      }
      expect(_signedVolume(m), greaterThan(0));
    });

    test('capless and a negative height build downwards, outward facing', () {
      final open = Mesh3D.cylinder(
        segments: 8,
        capTop: false,
        capBottom: false,
      );
      expect(open.vertexCount, 2 * 9);
      expect(open.triangleCount, 16);
      final down = Mesh3D.cylinder(segments: 8, height: -2, baseZ: 1);
      expect(down.minZ, closeTo(-1, 1e-6));
      expect(down.maxZ, closeTo(1, 1e-6));
      _expectConsistentNormalsAndWinding(down);
      expect(_signedVolume(down), greaterThan(0));
    });

    test('rejects bad parameters and clamps segments', () {
      expect(() => Mesh3D.cylinder(radiusTop: -1), throwsArgumentError);
      expect(() => Mesh3D.cylinder(height: double.nan), throwsArgumentError);
      expect(
        () => Mesh3D.cylinder(radiusTop: 0, radiusBottom: 0),
        throwsArgumentError,
      );
      expect(Mesh3D.cylinder(segments: 1).triangleCount, 4 * 3);
    });
  });

  group('Mesh3D.cone', () {
    test('counts and bounds', () {
      final m = Mesh3D.cone(height: 2, segments: 10, baseZ: -1);
      expect(m.vertexCount, 11 + 10 + 11);
      expect(m.triangleCount, 20);
      expect(m.minZ, closeTo(-1, 1e-6));
      expect(m.maxZ, closeTo(1, 1e-6));
      expect(m.maxX, closeTo(0.5, 1e-6));
      _expectUvsInUnitSquare(m);
      expect(Mesh3D.cone(capBottom: false, segments: 10).triangleCount, 10);
    });

    test('normals are unit, outward and agree with the winding', () {
      final m = Mesh3D.cone(segments: 12, height: 1.5);
      _expectConsistentNormalsAndWinding(m);
      _expectPointsAwayFrom(m, (x, y, z) => <double>[0, 0, 0.4]);
      // Side normals lean upwards by the slope of the wall.
      expect(m.normals[2], closeTo(0.5 / math.sqrt(1.5 * 1.5 + 0.25), 1e-6));
      expect(_signedVolume(m), greaterThan(0));
      expect(
        _signedVolume(m),
        closeTo(1.5 * 0.5 * 12 * 0.25 * math.sin(2 * math.pi / 12) / 3, 1e-5),
      );
    });

    test('a negative height points the apex downwards', () {
      final m = Mesh3D.cone(segments: 8, height: -1, baseZ: 2);
      expect(m.minZ, closeTo(1, 1e-6));
      expect(m.maxZ, closeTo(2, 1e-6));
      _expectConsistentNormalsAndWinding(m);
      expect(_signedVolume(m), greaterThan(0));
    });

    test('rejects bad parameters', () {
      expect(() => Mesh3D.cone(radius: -0.1), throwsArgumentError);
      expect(() => Mesh3D.cone(height: double.infinity), throwsArgumentError);
    });
  });

  group('Mesh3D.torus', () {
    test('counts and bounds', () {
      final m = Mesh3D.torus(
        majorRadius: 1,
        minorRadius: 0.25,
        majorSegments: 16,
        minorSegments: 8,
        centerZ: 3,
      );
      expect(m.vertexCount, 17 * 9);
      expect(m.triangleCount, 16 * 8 * 2);
      expect(m.minX, closeTo(-1.25, 1e-6));
      expect(m.maxX, closeTo(1.25, 1e-6));
      expect(m.minZ, closeTo(2.75, 1e-6));
      expect(m.maxZ, closeTo(3.25, 1e-6));
      _expectUvsInUnitSquare(m);
    });

    test('normals are unit, point away from the tube core and agree with the '
        'winding', () {
      final m = Mesh3D.torus(
        majorRadius: 1,
        minorRadius: 0.3,
        majorSegments: 20,
        minorSegments: 10,
      );
      _expectConsistentNormalsAndWinding(m);
      _expectPointsAwayFrom(m, (x, y, z) {
        final r = math.sqrt(x * x + y * y);
        return <double>[x / r, y / r, 0];
      });
      expect(_signedVolume(m), greaterThan(0));
      // The coarse tessellation stays within 10% of 2 pi^2 R r^2.
      expect(_signedVolume(m), closeTo(2 * math.pi * math.pi * 0.09, 0.18));
    });

    test('rejects bad parameters and clamps segments', () {
      expect(() => Mesh3D.torus(majorRadius: -1), throwsArgumentError);
      expect(() => Mesh3D.torus(minorRadius: double.nan), throwsArgumentError);
      expect(
        Mesh3D.torus(majorSegments: 0, minorSegments: 0).triangleCount,
        3 * 3 * 2,
      );
    });
  });

  group('Mesh3D.extrudePolygon', () {
    const square = <double>[0, 0, 2, 0, 2, 2, 0, 2];

    test('counts and bounds of a square', () {
      final m = Mesh3D.extrudePolygon(
        outline: square,
        height: 3,
        baseZ: 1,
      );
      expect(m.vertexCount, 4 * 4 + 4 + 4);
      expect(m.triangleCount, 8 + 2 + 2);
      expect(m.minX, 0);
      expect(m.maxX, 2);
      expect(m.minZ, 1);
      expect(m.maxZ, 4);
      _expectUvsInUnitSquare(m);
      expect(_signedVolume(m), closeTo(12, 1e-5));
      _expectConsistentNormalsAndWinding(m);
    });

    test('winding direction of the outline does not matter', () {
      final cw = Mesh3D.extrudePolygon(
        outline: const <double>[0, 0, 0, 2, 2, 2, 2, 0],
      );
      _expectConsistentNormalsAndWinding(cw);
      expect(_signedVolume(cw), closeTo(4, 1e-5));
      final closed = Mesh3D.extrudePolygon(
        outline: const <double>[0, 0, 2, 0, 2, 2, 0, 2, 0, 0],
      );
      expect(closed.vertexCount, 24);
    });

    test('a concave L shape has the right volume, outward walls and caps', () {
      const l = <double>[0, 0, 4, 0, 4, 1, 1, 1, 1, 3, 0, 3];
      final m = Mesh3D.extrudePolygon(outline: l, height: 2);
      expect(m.vertexCount, 6 * 4 + 6 + 6);
      expect(m.triangleCount, 12 + 4 + 4);
      // Area 4 + 2 = 6.
      expect(_signedVolume(m), closeTo(12, 1e-5));
      _expectConsistentNormalsAndWinding(m);
      // Each wall's outside is outside the polygon; each cap normal is +-Z.
      final p = m.positions;
      final n = m.normals;
      for (var v = 0; v < m.vertexCount; v++) {
        if (n[v * 3 + 2] != 0) {
          continue;
        }
        final x = p[v * 3] + n[v * 3] * 1e-3;
        final y = p[v * 3 + 1] + n[v * 3 + 1] * 1e-3;
        // Nudge along the wall so the probe is not on a corner's other edge.
        expect(_insidePolygon(l, x, y), isFalse, reason: 'wall vertex $v');
      }
    });

    test('capless and a negative height', () {
      final walls = Mesh3D.extrudePolygon(
        outline: square,
        capTop: false,
        capBottom: false,
      );
      expect(walls.vertexCount, 16);
      expect(walls.triangleCount, 8);
      final down = Mesh3D.extrudePolygon(outline: square, height: -1, baseZ: 1);
      expect(down.minZ, 0);
      expect(down.maxZ, 1);
      expect(_signedVolume(down), closeTo(4, 1e-5));
      _expectConsistentNormalsAndWinding(down);
    });

    test('rejects bad outlines', () {
      expect(
        () => Mesh3D.extrudePolygon(outline: const <double>[0, 0, 1, 0, 1]),
        throwsArgumentError,
      );
      expect(
        () => Mesh3D.extrudePolygon(outline: const <double>[0, 0, 1, 0]),
        throwsArgumentError,
      );
      expect(
        () => Mesh3D.extrudePolygon(outline: const <double>[0, 0, 1, 1, 2, 2]),
        throwsArgumentError,
      );
      expect(
        () => Mesh3D.extrudePolygon(
          outline: const <double>[0, 0, 1, 0, double.nan, 1],
        ),
        throwsArgumentError,
      );
    });
  });

  test('every generated mesh builds a usable BVH and bounding radius', () {
    final meshes = <Mesh3D>[
      Mesh3D.cylinder(),
      Mesh3D.cone(),
      Mesh3D.torus(),
      Mesh3D.extrudePolygon(outline: const <double>[0, 0, 1, 0, 0, 1]),
    ];
    for (final m in meshes) {
      expect(m.bvh, isNotNull);
      expect(m.boundingRadius, greaterThan(0));
      expect(m.indices, isA<Uint16List>());
    }
  });
}
