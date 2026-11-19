import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame_3d/core.dart';
import 'package:flame_3d/navigation.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('NavMesh3D path quality', () {
    test(
      'paths across an open voxel floor are straight in every direction',
      () {
        final navMesh = NavMeshBuilder3D.fromGeometry([
          _quad(-10, -10, 10, 10, 0),
        ]);
        expect(navMesh.polyCount, greaterThan(10000));

        for (var i = 0; i < 16; i++) {
          final angle = i * math.pi / 8 + 0.13;
          final start = Vector3(8 * math.cos(angle), 0, 8 * math.sin(angle));
          final goal = -start;
          final path = navMesh.findPath(start, goal);
          expect(path, isNotEmpty);
          expect(
            _length(path),
            closeTo(start.distanceTo(goal), 1e-6),
            reason: 'direction $i',
          );
          expect(path, hasLength(2), reason: 'direction $i');
        }

        // The probe from the audit: 27.5 m with 18 waypoints before.
        final diagonal = navMesh.findPath(Vector3(-8, 0, 8), Vector3(8, 0, -8));
        expect(_length(diagonal), closeTo(math.sqrt(512), 1e-6));
        expect(diagonal, hasLength(2));
      },
    );

    test(
      'paths across a terrain mesh from NavMesh3D.fromMesh are straight',
      () {
        final terrain = TerrainMesh3D(
          columns: 41,
          rows: 41,
          width: 20,
          depth: 20,
          heights: Float32List(41 * 41),
        );
        final navMesh = NavMesh3D.fromMesh(terrain);
        final start = Vector3(-8, 0, 8);
        final goal = Vector3(8, 0, -8);
        final path = navMesh.findPath(start, goal);
        expect(_length(path), closeTo(start.distanceTo(goal), 1e-6));
        expect(path, hasLength(2));
      },
    );

    test('a path around a pillar bends only at the pillar corners', () {
      final navMesh = NavMeshBuilder3D.fromGeometry(
        [
          _quad(-10, -10, 10, 10, 0),
          _box(Aabb3.minMax(Vector3(-1, 0, -1), Vector3(1, 2, 1))),
        ],
        config: const NavMeshBuildConfig3D(agentRadius: 0),
      );
      final start = Vector3(-6, 0, -0.5);
      final goal = Vector3(6, 0, 0.5);
      final path = navMesh.findPath(start, goal);
      expect(path, isNotEmpty);
      // Two corners of the 2 x 2 m pillar (the voxelized pillar may be up to
      // one cell larger), nothing else.
      expect(path, hasLength(4));
      for (final corner in path.sublist(1, 3)) {
        expect(corner.x.abs(), closeTo(1.0, 0.3));
        expect(corner.z.abs(), closeTo(1.0, 0.3));
      }
      // The taut path around the pillar from these points is about 12.6 m.
      expect(_length(path), lessThan(12.9));
    });

    test('collinear corridor corners are not reported as waypoints', () {
      // A 1 m wide corridor bending once: the path has exactly one corner.
      final navMesh = NavMeshBuilder3D.fromGeometry(
        [_quad(0, 0, 10, 1, 0), _quad(9, 1, 10, 10, 0)],
        config: const NavMeshBuildConfig3D(agentRadius: 0),
      );
      final path = navMesh.findPath(Vector3(0.5, 0, 0.5), Vector3(9.5, 0, 9.5));
      // The inner corner of the L, rounded to the voxel cells.
      expect(path, hasLength(3));
      expect(path[1].x, closeTo(9.0, 0.26));
      expect(path[1].z, closeTo(1.0, 0.26));
    });

    test('high-cost polygons are not crossed to straighten a path', () {
      final navMesh = NavMeshBuilder3D.fromGeometry([
        _quad(-10, -10, 10, 10, 0),
      ], config: const NavMeshBuildConfig3D(agentRadius: 0));
      // A strip of deep mud across the middle with a dry gap at x in [6, 8].
      navMesh
        ..setRegionCostInAabb(
          Aabb3.minMax(Vector3(-10, -1, -1), Vector3(6, 1, 1)),
          50,
        )
        ..setRegionCostInAabb(
          Aabb3.minMax(Vector3(8, -1, -1), Vector3(10, 1, 1)),
          50,
        );
      final path = navMesh.findPath(Vector3(-6, 0, -6), Vector3(-6, 0, 6));
      expect(path, isNotEmpty);
      expect(path.any((p) => p.x > 5.5), isTrue);
    });
  });

  group('NavMesh3D search state', () {
    test('repeated queries reuse the search state and agree', () {
      final navMesh = NavMeshBuilder3D.fromGeometry([
        _quad(-10, -10, 10, 10, 0),
        _box(Aabb3.minMax(Vector3(-4, 0, -0.3), Vector3(10, 2, 0.3))),
      ]);
      final first = navMesh.findPath(Vector3(5, 0, -5), Vector3(5, 0, 5));
      for (var i = 0; i < 50; i++) {
        navMesh.findPath(Vector3(-8, 0, -8), Vector3(-8, 0, 8));
        final again = navMesh.findPath(Vector3(5, 0, -5), Vector3(5, 0, 5));
        expect(again.length, first.length);
        for (var k = 0; k < first.length; k++) {
          expect(again[k].distanceTo(first[k]), lessThan(1e-9));
        }
      }
    });

    test('polygonCosts is read-only so the search stays admissible', () {
      final navMesh = NavMeshBuilder3D.fromGeometry([_quad(0, 0, 2, 2, 0)]);
      expect(navMesh.polygonCosts[0], 1.0);
      expect(() => navMesh.polygonCosts[0] = 0.1, throwsUnsupportedError);
      navMesh.setPolygonCost(0, 0.1);
      expect(navMesh.polygonCosts[0], closeTo(0.1, 1e-6));
    });
  });

  group('OffMeshLink3D changes', () {
    NavMesh3D twoIslands() {
      return NavMeshBuilder3D.fromGeometry([
        _quad(-6, -2, -2, 2, 0),
        _quad(2, -2, 6, 2, 0),
      ], config: const NavMeshBuildConfig3D(agentRadius: 0));
    }

    test('enabling a link that was created disabled connects it', () {
      final navMesh = twoIslands();
      final link = OffMeshLink3D(
        start: Vector3(-2.1, 0, 0),
        end: Vector3(2.1, 0, 0),
        enabled: false,
      );
      navMesh.addOffMeshLink(link);
      final a = Vector3(-5, 0, 0);
      final b = Vector3(5, 0, 0);
      expect(navMesh.findPath(a, b), isEmpty);
      link.enabled = true;
      expect(navMesh.findPath(a, b), isNotEmpty);
      link.enabled = false;
      expect(navMesh.findPath(a, b), isEmpty);
    });

    test('moving a link end point in place re-routes to the new point', () {
      final navMesh = twoIslands();
      final link = OffMeshLink3D(
        start: Vector3(-2.1, 0, 0),
        end: Vector3(2.1, 0, -1.5),
      );
      navMesh.addOffMeshLink(link);
      final before = navMesh.findSegmentedPath(
        Vector3(-5, 0, 0),
        Vector3(5, 0, 0),
      );
      expect(before[1].waypoints.last.z, closeTo(-1.5, 1e-3));

      link.end.setValues(2.1, 0, 1.5);
      final after = navMesh.findSegmentedPath(
        Vector3(-5, 0, 0),
        Vector3(5, 0, 0),
      );
      expect(after[1].isOffMeshLink, isTrue);
      expect(after[1].waypoints.last.z, closeTo(1.5, 1e-3));
    });

    test('an end point beyond snapRadius leaves the link unconnected', () {
      final navMesh = twoIslands();
      final far = OffMeshLink3D(
        start: Vector3(-2.1, 0, 0),
        end: Vector3(4, 5, 0),
        snapRadius: 1,
      );
      navMesh.addOffMeshLink(far);
      expect(navMesh.findPath(Vector3(-5, 0, 0), Vector3(5, 0, 0)), isEmpty);
      far.end.setValues(4, 0.5, 0);
      expect(
        navMesh.findPath(Vector3(-5, 0, 0), Vector3(5, 0, 0)),
        isNotEmpty,
      );
    });
  });

  group('Height sampling and crowds', () {
    test('sampleHeightAt picks the nearest layer under a bridge', () {
      final navMesh = NavMeshBuilder3D.fromGeometry([
        _quad(-5, -5, 5, 5, 0),
        _quad(-1, -5, 1, 5, 3),
      ], config: const NavMeshBuildConfig3D(agentRadius: 0));
      expect(navMesh.sampleHeightAt(Vector3(0, 0.2, 0)), closeTo(0, 0.05));
      expect(navMesh.sampleHeightAt(Vector3(0, 2.8, 0)), closeTo(3, 0.05));
      expect(navMesh.sampleHeightAt(Vector3(3, 2.8, 0)), closeTo(0, 0.05));
      expect(navMesh.sampleHeightAt(Vector3(7, 0, 0)), isNull);
    });

    test('sampleHeightAt works for a navmesh with a Z up axis', () {
      final mesh = Mesh()
        ..addSurface(
          Surface(
            vertices: [
              Vertex(position: Vector3(-5, -5, 1), texCoord: Vector2.zero()),
              Vertex(position: Vector3(5, -5, 1), texCoord: Vector2.zero()),
              Vertex(position: Vector3(5, 5, 2), texCoord: Vector2.zero()),
              Vertex(position: Vector3(-5, 5, 2), texCoord: Vector2.zero()),
            ],
            indices: [0, 1, 2, 0, 2, 3],
          ),
        );
      final navMesh = NavMesh3D.fromMesh(mesh, upAxis: Vector3(0, 0, 1));
      expect(navMesh.polyCount, 2);
      expect(navMesh.sampleHeightAt(Vector3(0, 0, 10)), closeTo(1.5, 1e-6));
      expect(navMesh.sampleHeightAt(Vector3(0, 6, 0)), isNull);
    });

    test('crowd steering on a large voxel navmesh stays cheap', () {
      final navMesh = NavMeshBuilder3D.fromGeometry([
        _quad(-30, -30, 30, 30, 0),
      ]);
      expect(navMesh.polyCount, greaterThan(100000));
      final crowd = CrowdSteering3D(navMesh: navMesh);
      final rng = math.Random(7);
      for (var i = 0; i < 50; i++) {
        final agent = CrowdAgent3D(
          position: Vector3(
            rng.nextDouble() * 50 - 25,
            0,
            rng.nextDouble() * 50 - 25,
          ),
        )..setPath([Vector3.zero(), Vector3(25, 0, 25)]);
        crowd.addAgent(agent);
      }
      // Time updates with and without the mesh, interleaved so that both see
      // the same machine load. Before the fix the mesh made an update about
      // 40 times slower here (every polygon tested for every agent: ~32 ms
      // against ~0.7 ms).
      for (var i = 0; i < 5; i++) {
        crowd.update(1 / 60);
      }
      final withMesh = Stopwatch();
      final withoutMesh = Stopwatch();
      for (var round = 0; round < 6; round++) {
        crowd.navMesh = navMesh;
        withMesh.start();
        for (var i = 0; i < 5; i++) {
          crowd.update(1 / 60);
        }
        withMesh.stop();
        crowd.navMesh = null;
        withoutMesh.start();
        for (var i = 0; i < 5; i++) {
          crowd.update(1 / 60);
        }
        withoutMesh.stop();
      }
      crowd
        ..navMesh = navMesh
        ..update(1 / 60);
      expect(
        withMesh.elapsedMicroseconds,
        lessThan(withoutMesh.elapsedMicroseconds * 4 + 30 * 1000),
      );
      for (final agent in crowd.agents) {
        expect(agent.position.y, closeTo(0, 1e-3));
      }
    });
  });
}

NavMeshGeometrySource3D _quad(
  double x0,
  double z0,
  double x1,
  double z1,
  double y,
) {
  return NavMeshGeometrySource3D(
    positions: Float32List.fromList([
      x0, y, z0, //
      x1, y, z0, //
      x1, y, z1, //
      x0, y, z1, //
    ]),
    indices: const [0, 3, 2, 0, 2, 1],
  );
}

NavMeshGeometrySource3D _box(Aabb3 box) {
  final min = box.min;
  final max = box.max;
  return NavMeshGeometrySource3D(
    positions: Float32List.fromList([
      min.x, min.y, min.z, //
      max.x, min.y, min.z, //
      max.x, min.y, max.z, //
      min.x, min.y, max.z, //
      min.x, max.y, min.z, //
      max.x, max.y, min.z, //
      max.x, max.y, max.z, //
      min.x, max.y, max.z, //
    ]),
    indices: const [
      4, 7, 6, 4, 6, 5, //
      0, 1, 2, 0, 2, 3, //
      3, 2, 6, 3, 6, 7, //
      1, 0, 4, 1, 4, 5, //
      1, 5, 6, 1, 6, 2, //
      0, 3, 7, 0, 7, 4, //
    ],
  );
}

double _length(List<Vector3> pts) {
  var sum = 0.0;
  for (var i = 0; i < pts.length - 1; i++) {
    sum += pts[i].distanceTo(pts[i + 1]);
  }
  return sum;
}
