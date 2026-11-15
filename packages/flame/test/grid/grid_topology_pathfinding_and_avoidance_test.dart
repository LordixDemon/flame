import 'package:flame/grid.dart';
import 'package:flame/navigation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';

void main() {
  group('Grid Topologies, AutoTileBitmask, Pathfinding & Avoidance', () {
    test(
      'Square, Isometric (with elevation) & HexGridTopology roundtrip '
      'coordinates and line-of-sight',
      () {
        final los = <GridCell>[];
        expect(
          SquareGridTopology.traceLineOfSight(
            const GridCell(0, 0),
            const GridCell(3, 3),
            los,
            isBlocked: (c) => c == const GridCell(2, 2),
          ),
          isFalse,
        );
        expect(
          SquareGridTopology.traceLineOfSight(
            const GridCell(0, 0),
            const GridCell(3, 0),
            los,
          ),
          isTrue,
        );
        expect(los.length, 4);

        final iso = IsometricGridTopology(elevationStep: 20);
        final worldPt = Vector2.zero();
        const elevatedCell = GridCell(4, -2, 3);
        iso.cellToWorldCenter(elevatedCell, worldPt);
        expect(
          iso.worldToCell(worldPt.x, worldPt.y, elevation: 3),
          elevatedCell,
        );

        for (final orient in HexOrientation.values) {
          final hex = HexGridTopology(hexRadius: 36, orientation: orient);
          const target = GridCell(3, -1);
          hex.cellToWorldCenter(target, worldPt);
          expect(hex.worldToCell(worldPt.x, worldPt.y), target);
        }

        final ring = <GridCell>[];
        HexGridTopology().hexRing(const GridCell(0, 0), 2, ring);
        expect(ring.length, 12);
        for (final cell in ring) {
          expect(HexGridTopology.hexDistance(const GridCell(0, 0), cell), 2);
        }

        // Corner-gated 8-bit blob auto-tile: NE bit only set if N and E match!
        final maskCornerBlocked = AutoTileBitmask.compute8BitBlob(
          0,
          0,
          (c, r) => (c == 0 && r == -1) || (c == 1 && r == -1), // N + NE, no E
        );
        expect(maskCornerBlocked & AutoTileBitmask.north, isNonZero);
        expect(maskCornerBlocked & AutoTileBitmask.northEast, 0);

        final maskCornerOpen = AutoTileBitmask.compute8BitBlob(
          0,
          0,
          (c, r) =>
              (c == 0 && r == -1) || (c == 1 && r == 0) || (c == 1 && r == -1),
        );
        expect(maskCornerOpen & AutoTileBitmask.northEast, isNonZero);
      },
    );

    test(
      'AStarGridPathfinder routes around walls & respects anti-corner-cutting '
      'and weights',
      () {
        final astar = AStarGridPathfinder(
          width: 8,
          height: 8,
          allowDiagonal: true,
        );
        // Vertical wall at col = 3 from row 0..5.
        for (var r = 0; r <= 5; r++) {
          astar.setBlocked(3, r, blocked: true);
        }

        final path = <GridCell>[];
        expect(
          astar.findPath(const GridCell(1, 2), const GridCell(5, 2), path),
          isTrue,
        );
        expect(path.first, const GridCell(1, 2));
        expect(path.last, const GridCell(5, 2));
        for (final step in path) {
          expect(astar.isBlocked(step.col, step.row), isFalse);
        }

        // Prefer road (weight 0.5) over swamp (weight 10.0).
        astar.resetGrid();
        astar.allowDiagonal = false;
        astar.setCellWeight(1, 0, 10.0);
        astar.setCellWeight(0, 1, 0.5);
        astar.setCellWeight(1, 1, 0.5);
        expect(
          astar.findPath(const GridCell(0, 0), const GridCell(1, 1), path),
          isTrue,
        );
        expect(
          path,
          const <GridCell>[GridCell(0, 0), GridCell(0, 1), GridCell(1, 1)],
        );
      },
    );

    test(
      'GraphPathfinder computes branching exact-step reachability & '
      'FlowField2D steers around obstacles',
      () {
        final board = GraphPathfinder<String>()
          ..addDirectedEdge('start', 'fork')
          ..addDirectedEdge('fork', 'upper_1')
          ..addDirectedEdge('fork', 'lower_1')
          ..addDirectedEdge('upper_1', 'upper_2')
          ..addDirectedEdge('lower_1', 'portal', cost: 0.2)
          ..addDirectedEdge('portal', 'goal', cost: 0.2)
          ..addDirectedEdge('upper_2', 'goal', cost: 5.0);

        expect(
          board.reachableInExactSteps('start', 2),
          <String>{'upper_1', 'lower_1'},
        );

        final bestRoute = <String>[];
        expect(board.findShortestPath('start', 'goal', bestRoute), isTrue);
        expect(
          bestRoute,
          <String>['start', 'fork', 'lower_1', 'portal', 'goal'],
        );

        final flow = FlowField2D(width: 6, height: 6)
          ..setBlocked(2, 0, blocked: true)
          ..setBlocked(2, 1, blocked: true)
          ..setBlocked(2, 2, blocked: true)
          ..bake(const <GridCell>[GridCell(4, 1)]);

        final dir = Vector2.zero();
        flow.sampleDirection(0, 1, dir);
        expect(dir.length, closeTo(1.0, 1e-4));
        expect(flow.costAt(4, 1), 0.0);
        expect(flow.costAt(0, 1).isFinite, isTrue);
      },
    );

    test(
      'FormationSlots & SeparationSteering2D arrange co-located tokens and '
      'repel overlapping agents',
      () {
        final slotA = Vector2.zero();
        final slotB = Vector2.zero();
        FormationSlots.computeSlotOffset(
          slotIndex: 0,
          totalCount: 1,
          out: slotA,
        );
        expect(slotA, Vector2.zero());

        FormationSlots.computeSlotOffset(
          slotIndex: 0,
          totalCount: 4,
          radius: 20,
          out: slotA,
        );
        FormationSlots.computeSlotOffset(
          slotIndex: 2,
          totalCount: 4,
          radius: 20,
          out: slotB,
        );
        expect(slotA.distanceTo(slotB), closeTo(40.0, 1e-4));

        final force = Vector2.zero();
        SeparationSteering2D.computeSeparation(
          agentPosition: Vector2(10, 0),
          neighborPositions: <Vector2>[Vector2(0, 0)],
          separationRadius: 30,
          outForce: force,
          maxForce: 100,
        );
        expect(force.x, greaterThan(0));
        expect(force.y, closeTo(0.0, 1e-5));
      },
    );
  });
}
