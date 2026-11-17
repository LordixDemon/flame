import 'dart:math';

import 'package:flame/components.dart';
import 'package:flame/grid.dart';
import 'package:flame/navigation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('HexGridTopology maps every point to the nearest cell center', () {
    final rng = Random(9);
    for (final o in HexOrientation.values) {
      final hex = HexGridTopology(
        hexRadius: 37,
        orientation: o,
        origin: Vector2(13, -7),
      );
      final c = Vector2.zero();
      for (var i = 0; i < 4000; i++) {
        final cell = GridCell(rng.nextInt(40) - 20, rng.nextInt(40) - 20);
        hex.cellToWorldCenter(cell, c);
        expect(hex.worldToCell(c.x, c.y), cell);
        // random point: returned cell must be the nearest centre
        final px = rng.nextDouble() * 2000 - 1000;
        final py = rng.nextDouble() * 2000 - 1000;
        final got = hex.worldToCell(px, py);
        hex.cellToWorldCenter(got, c);
        final dGot = (c.x - px) * (c.x - px) + (c.y - py) * (c.y - py);
        final nb = <GridCell>[];
        hex.neighbors6(got, nb);
        for (final n in nb) {
          hex.cellToWorldCenter(n, c);
          final d = (c.x - px) * (c.x - px) + (c.y - py) * (c.y - py);
          expect(
            dGot <= d + 1e-6,
            isTrue,
            reason: '$o ($px,$py) -> $got but $n nearer',
          );
        }
      }
      final ring = <GridCell>[];
      for (var r = 1; r < 6; r++) {
        hex.hexRing(const GridCell(2, -3), r, ring);
        expect(ring.length, 6 * r);
        expect(ring.toSet().length, 6 * r);
        for (final cell in ring) {
          expect(HexGridTopology.hexDistance(cell, const GridCell(2, -3)), r);
        }
      }
    }
  });

  test('AStarGridPathfinder takes a cheap road instead of the direct line', () {
    // 9 x 2 grid. Row 0 is a road (weight 0.1), row 1 is plain ground.
    //   start (0, 1) ......... goal (8, 1)
    // direct along row 1: 8 steps * 1.0                    = 8.0
    // via the road: up 0.1 + 8 * 0.1 along row 0 + down 1.0 = 1.9
    final grid = AStarGridPathfinder(width: 9, height: 2);
    for (var x = 0; x < 9; x++) {
      grid.setCellWeight(x, 0, 0.1);
    }

    final path = <GridCell>[];
    expect(
      grid.findPath(const GridCell(0, 1), const GridCell(8, 1), path),
      isTrue,
    );
    var cost = 0.0;
    for (var i = 1; i < path.length; i++) {
      cost += path[i].row == 0 ? 0.1 : 1.0;
    }
    expect(cost, closeTo(1.9, 1e-4), reason: '$path');

    // Raising the road back to plain ground makes the direct line best again.
    for (var x = 0; x < 9; x++) {
      grid.setCellWeight(x, 0, 1.0);
    }
    expect(
      grid.findPath(const GridCell(0, 1), const GridCell(8, 1), path),
      isTrue,
    );
    expect(path.length, 9);
  });

  test('AStarGridPathfinder paths cost the same as Dijkstra, 4-way and 8-way, '
      'with cell weights below and above 1', () {
    final rng = Random(17);
    for (var round = 0; round < 400; round++) {
      final w = 3 + rng.nextInt(10);
      final h = 3 + rng.nextInt(10);
      final diag = rng.nextBool();
      final cut = rng.nextBool();
      final astar = AStarGridPathfinder(
        width: w,
        height: h,
        allowDiagonal: diag,
        preventCornerCutting: cut,
      );
      final blocked = List<bool>.filled(w * h, false);
      final weight = List<double>.filled(w * h, 1.0);
      for (var i = 0; i < w * h; i++) {
        if (rng.nextInt(4) == 0) {
          blocked[i] = true;
          astar.setBlocked(i % w, i ~/ w, blocked: true);
        } else if (rng.nextInt(3) == 0) {
          weight[i] = const [0.1, 0.25, 0.5, 2.0, 3.0, 5.0][rng.nextInt(6)];
          astar.setCellWeight(i % w, i ~/ w, weight[i]);
        }
      }
      for (var q = 0; q < 6; q++) {
        final s = rng.nextInt(w * h);
        final g = rng.nextInt(w * h);
        if (blocked[s] || blocked[g]) {
          continue;
        }
        // Dijkstra
        final dist = List<double>.filled(w * h, double.infinity);
        final done = List<bool>.filled(w * h, false);
        dist[s] = 0;
        bool isB(int x, int y) =>
            x < 0 || y < 0 || x >= w || y >= h || blocked[y * w + x];
        while (true) {
          var best = -1;
          for (var i = 0; i < w * h; i++) {
            if (!done[i] &&
                dist[i].isFinite &&
                (best < 0 || dist[i] < dist[best])) {
              best = i;
            }
          }
          if (best < 0) {
            break;
          }
          done[best] = true;
          final cx = best % w;
          final cy = best ~/ w;
          for (var dy = -1; dy <= 1; dy++) {
            for (var dx = -1; dx <= 1; dx++) {
              if (dx == 0 && dy == 0) {
                continue;
              }
              final isDiag = dx != 0 && dy != 0;
              if (isDiag && !diag) {
                continue;
              }
              final nx = cx + dx;
              final ny = cy + dy;
              if (isB(nx, ny)) {
                continue;
              }
              if (isDiag && cut && (isB(cx + dx, cy) || isB(cx, cy + dy))) {
                continue;
              }
              final nd =
                  dist[best] +
                  (isDiag ? 1.4142135623730951 : 1.0) * weight[ny * w + nx];
              if (nd < dist[ny * w + nx]) {
                dist[ny * w + nx] = nd;
              }
            }
          }
        }
        final path = <GridCell>[];
        final found = astar.findPath(
          GridCell(s % w, s ~/ w),
          GridCell(g % w, g ~/ w),
          path,
        );
        expect(found, dist[g].isFinite, reason: 'round $round');
        if (found) {
          var cost = 0.0;
          for (var i = 1; i < path.length; i++) {
            final a = path[i - 1];
            final b = path[i];
            final isDiag = a.col != b.col && a.row != b.row;
            cost +=
                (isDiag ? 1.4142135623730951 : 1.0) * weight[b.row * w + b.col];
          }
          expect(
            cost,
            closeTo(dist[g], 1e-3),
            reason: 'round $round diag=$diag cut=$cut',
          );
        }
      }
    }
  });
}
