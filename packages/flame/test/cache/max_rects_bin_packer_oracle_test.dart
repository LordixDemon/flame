import 'dart:math';

import 'package:flame/cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('MaxRectsBinPacker never overlaps rectangles or leaves the bin', () {
    final rng = Random(3);
    for (var round = 0; round < 300; round++) {
      final w = 32 << rng.nextInt(4);
      final h = 32 << rng.nextInt(4);
      final packer = MaxRectsBinPacker(binWidth: w, binHeight: h);
      final placed = <PackedAtlasRect>[];
      for (var i = 0; i < 80; i++) {
        final rw = 1 + rng.nextInt(w ~/ 3);
        final rh = 1 + rng.nextInt(h ~/ 3);
        final r = packer.insert(rw, rh);
        if (r == null) {
          continue;
        }
        expect(
          r.x >= 0 && r.y >= 0 && r.x + r.width <= w && r.y + r.height <= h,
          isTrue,
        );
        for (final o in placed) {
          final overlap =
              r.x < o.x + o.width &&
              o.x < r.x + r.width &&
              r.y < o.y + o.height &&
              o.y < r.y + r.height;
          expect(overlap, isFalse, reason: 'round $round');
        }
        placed.add(r);
      }
    }
  });
}
