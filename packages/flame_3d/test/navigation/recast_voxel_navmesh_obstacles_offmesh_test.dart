import 'dart:typed_data';

import 'package:flame_3d/core.dart';
import 'package:flame_3d/navigation.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('NavMeshBuilder3D Recast voxelization, headroom & radius erosion', () {
    test(
      'voxelizes triangle soup, filters low ceilings, erodes agentRadius from '
      'walls/ledges, connects stairs <= maxClimb, and separates sheer cliffs',
      () {
        final sources = <NavMeshGeometrySource3D>[
          // 1. Main courtyard floor `[-6..6] x [-6..6]` at `y = 0`.
          _makeQuadSource(
            Vector3(-6.0, 0.0, -6.0),
            Vector3(6.0, 0.0, -6.0),
            Vector3(6.0, 0.0, 6.0),
            Vector3(-6.0, 0.0, 6.0),
          ),

          // 2. Partition wall along `z = 0` (`z in [-0.25..0.25]`, height
          // `2.5m`) with:
          // - Narrow slit on the left (`x in [-2.5 .. -2.1]`, width `0.4m <
          //   2 * agentRadius = 0.7m` -> must be eroded closed!), and
          // - Wide doorway on the right (`x in [1.5 .. 3.5]`, width `2.0m` ->
          //   stays open!).
          _makeBoxSource(
            Aabb3.minMax(
              Vector3(-6.0, 0.0, -0.25),
              Vector3(-2.5, 2.5, 0.25),
            ),
          ),
          _makeBoxSource(
            Aabb3.minMax(
              Vector3(-2.1, 0.0, -0.25),
              Vector3(1.5, 2.5, 0.25),
            ),
          ),
          _makeBoxSource(
            Aabb3.minMax(
              Vector3(3.5, 0.0, -0.25),
              Vector3(6.0, 2.5, 0.25),
            ),
          ),

          // 3. Low-ceiling overhang `[ -5..-2 ] x [ 2..5 ]` at `y = 1.0..1.2`
          // (`headroom = 1.0m < agentHeight = 1.8m` -> blocks ground underneath
          // while its top deck at `y = 1.2m` is walkable!).
          _makeBoxSource(
            Aabb3.minMax(
              Vector3(-5.0, 1.0, 2.0),
              Vector3(-2.0, 1.2, 5.0),
            ),
          ),

          // 4. Walkable 3-step staircase rising along `+X` (`x = 6..9`,
          // `z = 2..5`) in `0.35m <= maxClimb = 0.45m` increments up to an
          // elevated terrace `[9..13] x [2..5]` at `y = 1.05m`!
          _makeQuadSource(
            Vector3(6.0, 0.35, 2.0),
            Vector3(7.0, 0.35, 2.0),
            Vector3(7.0, 0.35, 5.0),
            Vector3(6.0, 0.35, 5.0),
          ),
          _makeQuadSource(
            Vector3(7.0, 0.7, 2.0),
            Vector3(8.0, 0.7, 2.0),
            Vector3(8.0, 0.7, 5.0),
            Vector3(7.0, 0.7, 5.0),
          ),
          _makeQuadSource(
            Vector3(8.0, 1.05, 2.0),
            Vector3(13.0, 1.05, 2.0),
            Vector3(13.0, 1.05, 5.0),
            Vector3(8.0, 1.05, 5.0),
          ),

          // 5. Disconnected high cliff `[9..13] x [-5..-2]` at `y = 2.0m`
          // (`dh = 2.0m > maxClimb = 0.45m` -> unreachable without a link!).
          _makeQuadSource(
            Vector3(9.0, 2.0, -5.0),
            Vector3(13.0, 2.0, -5.0),
            Vector3(13.0, 2.0, -2.0),
            Vector3(9.0, 2.0, -2.0),
          ),
        ];

        final navMesh = NavMeshBuilder3D.fromGeometry(sources);
        expect(navMesh.polyCount, greaterThan(400));

        // Agent routes from south (`(-3, 0, -3)`) to north (`(-3, 0, 1.2)`)
        // through the wide east doorway (`x in [1.5..3.5]`), NOT through the
        // narrow `0.4m` slit at `x = -2.3`!
        final doorPath = navMesh.findPath(
          Vector3(-3.0, 0.0, -3.0),
          Vector3(-1.0, 0.0, 1.5),
        );
        expect(doorPath, isNotEmpty);
        final maxWayX = doorPath
            .map((p) => p.x)
            .reduce((a, b) => a > b ? a : b);
        expect(maxWayX, greaterThan(1.5));

        // Ground underneath the `y = 1.0m` low ceiling `(-3.5, 0, 3.5)` was
        // filtered out (`sampleHeightAt` at `y = 0` only sees the `y = 1.2m`
        // roof deck, not `y = 0`)!
        final roofSample = navMesh.sampleHeightAt(Vector3(-3.5, 0.0, 3.5));
        expect(roofSample, closeTo(1.2, 0.05));

        // Staircase (`0.35m` steps `<= maxClimb = 0.45m`) is seamlessly
        // reachable up to the `y = 1.05m` terrace!
        final stairPath = navMesh.findPath(
          Vector3(4.5, 0.0, 3.5),
          Vector3(11.0, 1.05, 3.5),
        );
        expect(stairPath.length, greaterThanOrEqualTo(2));
        expect(stairPath.last.y, closeTo(1.05, 0.05));

        // Sheer `2.0m` cliff (`> maxClimb`) is isolated and unreachable!
        final cliffPath = navMesh.findPath(
          Vector3(4.5, 0.0, -3.5),
          Vector3(11.0, 2.0, -3.5),
        );
        expect(cliffPath, isEmpty);
      },
    );
  });

  group('NavMesh3D area costs, dynamic obstacles & OffMeshLink3D', () {
    test(
      'setRegionCostInAabb detours around high-cost mud and NavMeshObstacle3D '
      'dynamically blocks/unblocks a gate in O(log P)',
      () {
        final sources = [
          _makeQuadSource(
            Vector3(-8.0, 0.0, -8.0),
            Vector3(8.0, 0.0, -8.0),
            Vector3(8.0, 0.0, 8.0),
            Vector3(-8.0, 0.0, 8.0),
          ),
          // Central wall leaving two passages at `z = 0`:
          // - Center gate (`x in [-1.5 .. 1.5]`), and
          // - Far east detour (`x in [5.0 .. 7.5]`).
          _makeBoxSource(
            Aabb3.minMax(
              Vector3(-8.0, 0.0, -0.3),
              Vector3(-1.5, 2.5, 0.3),
            ),
          ),
          _makeBoxSource(
            Aabb3.minMax(
              Vector3(1.5, 0.0, -0.3),
              Vector3(5.0, 2.5, 0.3),
            ),
          ),
        ];
        final navMesh = NavMeshBuilder3D.fromGeometry(
          sources,
          config: const NavMeshBuildConfig3D(agentRadius: 0.25),
        );

        final start = Vector3(0.0, 0.0, -4.5);
        final goal = Vector3(0.0, 0.0, 4.5);

        // 1. Open gate & uniform cost `1.0`: goes straight through `x ~ 0`.
        final directPath = navMesh.findPath(start, goal);
        expect(directPath, isNotEmpty);
        expect(_pathLength(directPath), lessThan(10.0));

        // 2. Mark the center gate passage as deep mud (`cost = 12.0`): A* now
        // prefers the clean `cost = 1.0` east road (`x > 5.0`)!
        final mudBox = Aabb3.minMax(
          Vector3(-1.8, -0.5, -1.5),
          Vector3(1.8, 1.0, 1.5),
        );
        final mudCount = navMesh.setRegionCostInAabb(mudBox, 12.0);
        expect(mudCount, greaterThan(0));

        final roadDetour = navMesh.findPath(start, goal);
        expect(roadDetour, isNotEmpty);
        expect(
          roadDetour.any((wp) => wp.x > 4.8),
          isTrue,
        );

        // Restore mud cost to `1.0` -> back to direct shortcut!
        navMesh.setRegionCostInAabb(mudBox, 1.0);
        expect(_pathLength(navMesh.findPath(start, goal)), lessThan(10.0));

        // 3. Close a dynamic `NavMeshObstacle3D` gate across `[-1.6 .. 1.6]`:
        // reroutes around east corridor; removing/opening restores shortcut!
        final gate = NavMeshObstacle3D(
          center: Vector3(0.0, 0.5, 0.0),
          halfExtents: Vector3(1.8, 1.0, 0.6),
        );
        navMesh.addObstacle(gate);
        expect(navMesh.blockedPolygonCount, greaterThan(0));

        final closedGatePath = navMesh.findPath(start, goal);
        expect(closedGatePath, isNotEmpty);
        expect(closedGatePath.any((wp) => wp.x > 4.8), isTrue);

        // Slide gate aside via `updateObstacle` -> shortcut reopens!
        gate.center.setValues(-6.0, 0.5, 0.0);
        navMesh.updateObstacle(gate);
        expect(_pathLength(navMesh.findPath(start, goal)), lessThan(10.0));

        navMesh.removeObstacle(gate);
        expect(navMesh.blockedPolygonCount, 0);
      },
    );

    test(
      'OffMeshLink3D traverses jump gaps and ladders with segmented linkTag '
      'waypoints and honors bidirectional flag',
      () {
        // Three separate platforms:
        // - Island A (`[-6..-2] x [-2..2]` at `y = 0`),
        // - Island B (`[2..6] x [-2..2]` at `y = 0`),
        // - Sniper Tower C (`[2..6] x [3..6]` at `y = 4.0`).
        final mesh = Mesh()
          ..addSurface(
            Surface(
              vertices: [
                ..._quadVertices(
                  Vector3(-6, 0, -2),
                  Vector3(-2, 0, -2),
                  Vector3(-2, 0, 2),
                  Vector3(-6, 0, 2),
                ),
                ..._quadVertices(
                  Vector3(2, 0, -2),
                  Vector3(6, 0, -2),
                  Vector3(6, 0, 2),
                  Vector3(2, 0, 2),
                ),
                ..._quadVertices(
                  Vector3(2, 4, 3),
                  Vector3(6, 4, 3),
                  Vector3(6, 4, 6),
                  Vector3(2, 4, 6),
                ),
              ],
              indices: [
                0, 3, 2, 0, 2, 1, // Island A
                4, 7, 6, 4, 6, 5, // Island B
                8, 11, 10, 8, 10, 9, // Tower C
              ],
            ),
          );
        final navMesh = NavMesh3D.fromMesh(mesh);

        // Disconnected before adding links.
        expect(
          navMesh.findPath(Vector3(-5, 0, 0), Vector3(4, 4, 5)),
          isEmpty,
        );

        final jumpLink = OffMeshLink3D(
          start: Vector3(-2.1, 0.0, 0.0),
          end: Vector3(2.1, 0.0, 0.0),
        );
        final oneWayLadder = OffMeshLink3D(
          start: Vector3(4.0, 0.0, 1.9),
          end: Vector3(4.0, 4.0, 3.1),
          bidirectional: false,
          costMultiplier: 1.5,
          linkTag: 'ladder',
        );

        navMesh
          ..addOffMeshLink(jumpLink)
          ..addOffMeshLink(oneWayLadder);

        final segments = navMesh.findSegmentedPath(
          Vector3(-5.0, 0.0, 0.0),
          Vector3(4.0, 4.0, 5.0),
        );
        // Walk A -> 'jump' -> Walk B -> 'ladder' -> Walk C = 5 segments!
        expect(segments.length, 5);
        expect(segments[0].isOffMeshLink, isFalse);
        expect(segments[1].isOffMeshLink, isTrue);
        expect(segments[1].linkTag, 'jump');
        expect(segments[2].isOffMeshLink, isFalse);
        expect(segments[3].isOffMeshLink, isTrue);
        expect(segments[3].linkTag, 'ladder');
        expect(segments[4].isOffMeshLink, isFalse);

        final flatPath = navMesh.findPath(
          Vector3(-5.0, 0.0, 0.0),
          Vector3(4.0, 4.0, 5.0),
        );
        expect(
          flatPath.first.distanceTo(Vector3(-5.0, 0.0, 0.0)),
          lessThan(1e-3),
        );
        expect(
          flatPath.last.distanceTo(Vector3(4.0, 4.0, 5.0)),
          lessThan(1e-3),
        );

        // Reverse direction (`Tower C -> Island A`) is blocked because
        // `oneWayLadder.bidirectional == false`, while `Island B -> Island A`
        // succeeds because `jumpLink.bidirectional == true`!
        expect(
          navMesh.findPath(Vector3(4.0, 4.0, 5.0), Vector3(-5.0, 0.0, 0.0)),
          isEmpty,
        );
        expect(
          navMesh.findPath(Vector3(5.0, 0.0, 0.0), Vector3(-5.0, 0.0, 0.0)),
          isNotEmpty,
        );
      },
    );
  });
}

List<Vertex> _quadVertices(
  Vector3 p00,
  Vector3 p10,
  Vector3 p11,
  Vector3 p01,
) {
  return [
    Vertex(position: p00, texCoord: Vector2.zero()),
    Vertex(position: p10, texCoord: Vector2.zero()),
    Vertex(position: p11, texCoord: Vector2.zero()),
    Vertex(position: p01, texCoord: Vector2.zero()),
  ];
}

NavMeshGeometrySource3D _makeQuadSource(
  Vector3 p00,
  Vector3 p10,
  Vector3 p11,
  Vector3 p01,
) {
  final pos = Float32List.fromList([
    p00.x,
    p00.y,
    p00.z,
    p10.x,
    p10.y,
    p10.z,
    p11.x,
    p11.y,
    p11.z,
    p01.x,
    p01.y,
    p01.z,
  ]);
  return NavMeshGeometrySource3D(
    positions: pos,
    indices: const [0, 3, 2, 0, 2, 1],
  );
}

NavMeshGeometrySource3D _makeBoxSource(Aabb3 box) {
  final min = box.min;
  final max = box.max;
  // 8 corners of AABB.
  final pos = Float32List.fromList([
    min.x, min.y, min.z, // 0
    max.x, min.y, min.z, // 1
    max.x, min.y, max.z, // 2
    min.x, min.y, max.z, // 3
    min.x, max.y, min.z, // 4
    max.x, max.y, min.z, // 5
    max.x, max.y, max.z, // 6
    min.x, max.y, max.z, // 7
  ]);
  // 6 outward CCW faces (12 triangles).
  const indices = <int>[
    // Top (+Y)
    4, 7, 6, 4, 6, 5,
    // Bottom (-Y)
    0, 1, 2, 0, 2, 3,
    // Front (+Z)
    3, 2, 6, 3, 6, 7,
    // Back (-Z)
    1, 0, 4, 1, 4, 5,
    // Right (+X)
    1, 5, 6, 1, 6, 2,
    // Left (-X)
    0, 3, 7, 0, 7, 4,
  ];
  return NavMeshGeometrySource3D(positions: pos, indices: indices);
}

double _pathLength(List<Vector3> pts) {
  var sum = 0.0;
  for (var i = 0; i < pts.length - 1; i++) {
    sum += pts[i].distanceTo(pts[i + 1]);
  }
  return sum;
}
