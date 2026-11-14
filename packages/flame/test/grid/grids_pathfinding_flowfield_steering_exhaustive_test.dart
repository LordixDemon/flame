import 'dart:math' as math;

import 'package:flame/grid.dart';
import 'package:flame/navigation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';

void main() {
  group('Square, Isometric & Hex GridTopologies + AutoTileBitmask', () {
    test(
      'SquareGridTopology negative coords, LOS obstacle stop & distances',
      () {
        final grid = SquareGridTopology(
          cellWidth: 32,
          cellHeight: 32,
          origin: Vector2(10, -20),
        );
        final pt = Vector2.zero();
        const negCell = GridCell(-3, -4, 2);
        grid.cellToWorldCenter(negCell, pt);
        expect(grid.worldToCell(pt.x, pt.y, elevation: 2), negCell);

        final n4 = <GridCell>[];
        final n8 = <GridCell>[];
        grid.neighbors4(negCell, n4);
        grid.neighbors8(negCell, n8);
        expect(n4.length, 4);
        expect(n8.length, 8);
        expect(
          SquareGridTopology.manhattanDistance(
            const GridCell(-2, 3),
            const GridCell(4, -1),
          ),
          10,
        );
        expect(
          SquareGridTopology.chebyshevDistance(
            const GridCell(-2, 3),
            const GridCell(4, -1),
          ),
          6,
        );

        final ray = <GridCell>[];
        expect(
          SquareGridTopology.traceLineOfSight(
            const GridCell(0, 0),
            const GridCell(5, 0),
            ray,
            isBlocked: (c) => c.col == 3,
          ),
          isFalse,
        );
        expect(ray.last, const GridCell(3, 0));
      },
    );

    test(
      'IsometricGridTopology roundtrips positive/negative coords & elevations',
      () {
        final iso = IsometricGridTopology(
          tileWidth: 96,
          tileHeight: 48,
          elevationStep: 18,
          origin: Vector2(200, 100),
        );
        final center = Vector2.zero();
        for (final z in <int>[-2, 0, 3]) {
          for (var r = -4; r <= 4; r++) {
            for (var c = -4; c <= 4; c++) {
              final cell = GridCell(c, r, z);
              iso.cellToWorldCenter(cell, center);
              expect(
                iso.worldToCell(center.x + 2.5, center.y - 1.5, elevation: z),
                cell,
              );
            }
          }
        }
      },
    );

    test(
      'HexGridTopology pointyTop/flatTop cube rounding, hexRing & hexSpiral',
      () {
        for (final orient in HexOrientation.values) {
          final hex = HexGridTopology(hexRadius: 36, orientation: orient);
          final center = Vector2.zero();
          for (var q = -3; q <= 3; q++) {
            for (var r = -3; r <= 3; r++) {
              final cell = GridCell(q, r, 1);
              hex.cellToWorldCenter(cell, center);
              // Off-center jitter inside hexagon apothem rounds back cleanly.
              expect(
                hex.worldToCell(center.x + 8, center.y - 7, elevation: 1),
                cell,
              );
            }
          }

          final ring = <GridCell>[];
          hex.hexRing(const GridCell(2, -1), 0, ring);
          expect(ring, <GridCell>[const GridCell(2, -1)]);
          hex.hexRing(const GridCell(2, -1), 3, ring);
          expect(ring.length, 18);
          for (final c in ring) {
            expect(HexGridTopology.hexDistance(const GridCell(2, -1), c), 3);
          }

          // hexSpiral(R) yields 1 + 3*R*(R+1) unique cells (`1, 7, 19, 37`).
          final spiral = <GridCell>[];
          for (final (r, expectedCount) in <(int, int)>[
            (0, 1),
            (1, 7),
            (2, 19),
            (3, 37),
          ]) {
            hex.hexSpiral(const GridCell(0, 0), r, spiral);
            expect(spiral.length, expectedCount);
            expect(spiral.toSet().length, expectedCount);
          }
        }
      },
    );

    test(
      'AutoTileBitmask corner-gates diagonal bits in 8-bit Wang blob mode',
      () {
        // North, East, and NorthEast are land, while South and West are water.
        final land = <(int, int)>{(5, 5), (5, 4), (6, 5), (6, 4), (4, 4)};
        // Note `(4, 4)` is NorthWest, but West `(4, 5)` is missing so NW must
        // be gated OFF!
        final m4 = AutoTileBitmask.compute4Bit(
          5,
          5,
          (c, r) => land.contains((c, r)),
        );
        final m8 = AutoTileBitmask.compute8BitBlob(
          5,
          5,
          (c, r) => land.contains((c, r)),
        );
        expect(m4, AutoTileBitmask.north | AutoTileBitmask.east);
        expect(
          m8,
          AutoTileBitmask.north |
              AutoTileBitmask.east |
              AutoTileBitmask.northEast,
        );
        expect(m8 & AutoTileBitmask.northWest, 0);
      },
    );
  });

  group('AStarGridPathfinder, GraphPathfinder, FlowField2D & Avoidance', () {
    test(
      'AStarGridPathfinder handles weighted detour, corners & 500-run reuse',
      () {
        final pf = AStarGridPathfinder(width: 12, height: 12);
        final path = <GridCell>[];

        // Blocked start returns false by default, true when allowBlockedStart!
        pf.setBlocked(1, 1, blocked: true);
        expect(
          pf.findPath(const GridCell(1, 1), const GridCell(3, 1), path),
          isFalse,
        );
        expect(
          pf.findPath(
            const GridCell(1, 1),
            const GridCell(3, 1),
            path,
            allowBlockedStart: true,
          ),
          isTrue,
        );
        expect(path.first, const GridCell(1, 1));
        expect(path.last, const GridCell(3, 1));

        // Diagonal corner-cutting prevention vs permissive mode.
        pf
          ..resetGrid()
          ..allowDiagonal = true
          ..setBlocked(2, 1, blocked: true)
          ..setBlocked(1, 2, blocked: true);
        pf.preventCornerCutting = true;
        expect(
          pf.findPath(const GridCell(1, 1), const GridCell(2, 2), path),
          isTrue,
        );
        expect(path.length, greaterThan(2)); // cannot squeeze diagonally!

        pf.preventCornerCutting = false;
        expect(
          pf.findPath(const GridCell(1, 1), const GridCell(2, 2), path),
          isTrue,
        );
        expect(path.length, 2);

        // Weighted swamp row forces road detour!
        pf
          ..resetGrid()
          ..allowDiagonal = false;
        for (var c = 1; c <= 5; c++) {
          pf.setCellWeight(c, 2, 20.0); // heavy swamp along direct y=2 line
        }
        expect(
          pf.findPath(const GridCell(0, 2), const GridCell(6, 2), path),
          isTrue,
        );
        expect(path.any((c) => c.row != 2), isTrue);

        // 500-iteration stamp reuse stress without resetting allocations.
        pf.resetGrid();
        for (var i = 0; i < 500; i++) {
          expect(
            pf.findPath(
              GridCell(i % 4, (i ~/ 4) % 4),
              GridCell(11 - (i % 4), 11 - ((i ~/ 4) % 4)),
              path,
            ),
            isTrue,
          );
        }
      },
    );

    test(
      'GraphPathfinder solves branching exact-step reachability & A* path',
      () {
        final graph = GraphPathfinder<String>()
          ..addDirectedEdge('start', 'fork')
          ..addDirectedEdge('fork', 'shortcut_1', cost: 1.0)
          ..addDirectedEdge('shortcut_1', 'goal', cost: 1.0)
          ..addDirectedEdge('fork', 'long_1', cost: 0.4)
          ..addDirectedEdge('long_1', 'long_2', cost: 0.4)
          ..addDirectedEdge('long_2', 'goal', cost: 0.4);

        expect(graph.reachableInExactSteps('start', 0), <String>{'start'});
        expect(
          graph.reachableInExactSteps('start', 2),
          <String>{'shortcut_1', 'long_1'},
        );
        expect(
          graph.reachableInExactSteps('start', 3),
          <String>{'goal', 'long_2'},
        );

        final shortest = <String>[];
        expect(
          graph.findShortestPath(
            'start',
            'goal',
            shortest,
            heuristic: (_, _) => 0.0,
          ),
          isTrue,
        );
        // 1 + 0.4*3 = 2.2 < 1 + 1 + 1 = 3.0!
        expect(
          shortest,
          <String>['start', 'fork', 'long_1', 'long_2', 'goal'],
        );
        expect(graph.findShortestPath('goal', 'start', shortest), isFalse);
      },
    );

    test(
      'FlowField2D, FormationSlots & 30-agent coincident SeparationSteering2D',
      () {
        final ff = FlowField2D(width: 8, height: 8);
        // Seal (7, 7) inside an unreachable pocket.
        ff
          ..setBlocked(6, 7, blocked: true)
          ..setBlocked(7, 6, blocked: true)
          ..setBlocked(6, 6, blocked: true)
          ..bake(const <GridCell>[GridCell(0, 0)]);

        expect(ff.costAt(0, 0), 0.0);
        expect(ff.costAt(7, 7).isInfinite, isTrue);
        final flow = Vector2.zero();
        ff.sampleDirection(3, 0, flow);
        expect(flow.x, closeTo(-1.0, 1e-5));
        ff.sampleDirection(7, 7, flow);
        expect(flow, Vector2.zero());

        // FormationSlots produces distinct non-overlapping slots across all
        // patterns.
        for (final pat in FormationPattern.values) {
          final pts = <Vector2>[];
          for (var i = 0; i < 6; i++) {
            final slot = Vector2.zero();
            FormationSlots.computeSlotOffset(
              slotIndex: i,
              totalCount: 6,
              out: slot,
              radius: 20,
              pattern: pat,
            );
            for (final prev in pts) {
              expect(slot.distanceTo(prev), greaterThan(2.0));
            }
            pts.add(slot);
          }
        }

        // 24 agents spawned at the EXACT same coordinate `(50, 50)` separate
        // deterministically via Golden-angle symmetry breaking with zero NaNs!
        final agents = List<Vector2>.generate(24, (_) => Vector2(50, 50));
        final steer = Vector2.zero();
        for (var step = 0; step < 30; step++) {
          for (var i = 0; i < agents.length; i++) {
            SeparationSteering2D.computeSeparation(
              agentPosition: agents[i],
              neighborPositions: agents,
              separationRadius: 16.0,
              outForce: steer,
              maxForce: 120.0,
            );
            expect(steer.x.isNaN || steer.y.isNaN, isFalse);
            agents[i].addScaled(steer, 1 / 60);
          }
        }
        var maxSpread = 0.0;
        for (var i = 1; i < agents.length; i++) {
          maxSpread = math.max(maxSpread, agents[0].distanceTo(agents[i]));
        }
        expect(maxSpread, greaterThan(4.0));
      },
    );
  });
}
