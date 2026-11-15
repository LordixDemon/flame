import 'dart:ui';

import 'package:flame/game.dart';
import 'package:flame/geometry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RenderWarmupQueue', () {
    test(
      'warms textures, vertices, and custom pipelines with progress',
      () async {
        final rec = PictureRecorder();
        Canvas(rec).drawCircle(
          const Offset(8, 8),
          6,
          Paint()..color = const Color(0xFFFFFFFF),
        );
        final pic = rec.endRecording();
        final tex = pic.toImageSync(16, 16);
        pic.dispose();
        addTearDown(tex.dispose);

        var customInvoked = 0;
        final progresses = <double>[];
        final queue = RenderWarmupQueue()
          ..addTexture(tex)
          ..addVertices()
          ..addCustom((canvas, bounds) {
            customInvoked++;
            canvas.drawOval(bounds, Paint()..color = const Color(0xFF44AAFF));
          });

        final game = FlameGame();
        await game.warmupRenderPipelines(
          queue,
          tasksPerYield: 1,
          onProgress: progresses.add,
        );

        expect(queue.warmedTextureCount, 1);
        expect(queue.completedTaskCount, 3);
        expect(customInvoked, 1);
        expect(progresses.length, 3);
        expect(progresses.last, closeTo(1.0, 1e-6));
      },
    );
  });

  group('SpatialGrid2D', () {
    test(
      'queries points, rects, and radii without duplicate entries',
      () {
        final grid = SpatialGrid2D<String>(cellSize: 64.0)
          ..upsertPoint('origin', 0, 0)
          ..upsertPoint('negCorner', -180, -190)
          // Multi-cell rect spanning cells (-1,-1) through (1,1):
          ..upsertRect('bigBridge', const Rect.fromLTRB(-40, -40, 90, 90))
          ..upsertPoint('farEast', 420, 10);

        expect(grid.itemCount, 4);

        final out = <String>[];
        final ptHits = grid.queryPoint(10, 10, out);
        expect(ptHits, 1);
        expect(out, ['bigBridge']);

        // Rect query spanning multiple cells must deduplicate 'bigBridge'!
        out.clear();
        final rectHits = grid.queryRect(
          const Rect.fromLTRB(-50, -50, 100, 100),
          out,
        );
        expect(rectHits, 2);
        expect(out.toSet(), {'origin', 'bigBridge'});
        expect(out.length, 2);

        // Radius query around (-180, -190) finds only 'negCorner'.
        out.clear();
        final radHits = grid.queryRadius(-175, -185, 20, out);
        expect(radHits, 1);
        expect(out, ['negCorner']);

        // Moving an item updates its cell buckets cleanly.
        grid.upsertPoint('farEast', 5, 5);
        out.clear();
        grid.queryRadius(0, 0, 15, out);
        expect(out.toSet(), {'origin', 'bigBridge', 'farEast'});

        // Removing an item unlinks it from all cells.
        expect(grid.remove('bigBridge'), isTrue);
        expect(grid.itemCount, 3);
        out.clear();
        grid.queryPoint(50, 50, out);
        expect(out, isEmpty);
      },
    );
  });
}
