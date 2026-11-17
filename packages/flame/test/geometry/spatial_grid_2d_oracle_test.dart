import 'dart:math';
import 'dart:ui' show Rect;

import 'package:flame/geometry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('SpatialGrid2D queries match a brute-force search with negative '
      'coordinates, items larger than a cell, moves and removals', () {
    final rng = Random(5);
    for (var round = 0; round < 60; round++) {
      final cell = [8.0, 32.0, 128.0][rng.nextInt(3)];
      final grid = SpatialGrid2D<int>(cellSize: cell, initialCapacity: 4);
      final boxes = <int, Rect>{};
      Rect randRect() {
        final x = rng.nextDouble() * 800 - 400;
        final y = rng.nextDouble() * 800 - 400;
        final big = rng.nextInt(5) == 0;
        final w = rng.nextInt(6) == 0
            ? 0.0
            : rng.nextDouble() * (big ? 500 : 40);
        final h = rng.nextInt(6) == 0
            ? 0.0
            : rng.nextDouble() * (big ? 500 : 40);
        return Rect.fromLTWH(x, y, w, h);
      }

      for (var step = 0; step < 300; step++) {
        final r = rng.nextInt(10);
        if (r < 5 || boxes.isEmpty) {
          final id = rng.nextInt(60);
          final rect = randRect();
          boxes[id] = rect;
          grid.upsertRect(id, rect);
        } else if (r < 7) {
          final id = boxes.keys.elementAt(rng.nextInt(boxes.length));
          boxes.remove(id);
          expect(grid.remove(id), isTrue);
        } else {
          final out = <int>[];
          if (r == 7) {
            final q = randRect();
            grid.queryRect(q, out);
            final want = [
              for (final e in boxes.entries)
                if (e.value.right >= q.left &&
                    e.value.left <= q.right &&
                    e.value.bottom >= q.top &&
                    e.value.top <= q.bottom)
                  e.key,
            ];
            expect(
              out.toSet(),
              want.toSet(),
              reason: 'rect round $round step $step',
            );
            expect(out.length, want.length);
          } else if (r == 8) {
            final x = rng.nextDouble() * 800 - 400;
            final y = rng.nextDouble() * 800 - 400;
            grid.queryPoint(x, y, out);
            final want = [
              for (final e in boxes.entries)
                if (x >= e.value.left &&
                    x <= e.value.right &&
                    y >= e.value.top &&
                    y <= e.value.bottom)
                  e.key,
            ];
            expect(out.toSet(), want.toSet());
            expect(out.length, want.length);
          } else {
            final x = rng.nextDouble() * 800 - 400;
            final y = rng.nextDouble() * 800 - 400;
            final rad = rng.nextDouble() * 300;
            grid.queryRadius(x, y, rad, out);
            final want = <int>[];
            for (final e in boxes.entries) {
              final nx = x.clamp(e.value.left, e.value.right);
              final ny = y.clamp(e.value.top, e.value.bottom);
              if ((x - nx) * (x - nx) + (y - ny) * (y - ny) <= rad * rad) {
                want.add(e.key);
              }
            }
            expect(out.toSet(), want.toSet());
            expect(out.length, want.length);
          }
        }
        expect(grid.itemCount, boxes.length);
      }
      for (final id in boxes.keys.toList()) {
        grid.remove(id);
      }
      expect(
        grid.nonEmptyCellCount,
        0,
        reason: 'cells leak after removing all',
      );
    }
  });
}
