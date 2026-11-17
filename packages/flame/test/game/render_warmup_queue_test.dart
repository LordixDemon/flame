import 'dart:ui';

import 'package:flame/game.dart';
import 'package:flutter_test/flutter_test.dart';

void _drawDot(Canvas canvas, Rect bounds) {
  canvas.drawCircle(
    bounds.center,
    2,
    Paint()..color = const Color(0xFF44AAFF),
  );
}

void main() {
  group('RenderWarmupQueue', () {
    test('awaitRasterization waits for every chunk to be drawn', () async {
      var draws = 0;
      final progress = <double>[];
      final queue = RenderWarmupQueue()
        ..addVertices()
        ..addCustom((canvas, bounds) {
          draws++;
          _drawDot(canvas, bounds);
        })
        ..addCustom((canvas, bounds) {
          draws++;
          _drawDot(canvas, bounds);
        });

      await queue.warmupAll(
        tasksPerYield: 2,
        onProgress: progress.add,
        awaitRasterization: true,
      );

      expect(draws, 2);
      expect(queue.completedTaskCount, 3);
      expect(progress, [closeTo(2 / 3, 1e-9), 1.0]);
    });

    test(
      'FlameGame.warmupRenderPipelines passes awaitRasterization on',
      () async {
        var draws = 0;
        final queue = RenderWarmupQueue()
          ..addCustom((canvas, bounds) {
            draws++;
            _drawDot(canvas, bounds);
          });

        await FlameGame().warmupRenderPipelines(
          queue,
          awaitRasterization: true,
        );

        expect(draws, 1);
        expect(queue.completedTaskCount, 1);
      },
    );

    test('the passes queued at the start run even if the queue is cleared '
        'meanwhile', () async {
      var draws = 0;
      final queue = RenderWarmupQueue();
      for (var i = 0; i < 4; i++) {
        queue.addCustom((canvas, bounds) {
          draws++;
          _drawDot(canvas, bounds);
        });
      }

      final done = queue.warmupAll(tasksPerYield: 1);
      // The first chunk has run; the others wait for the event loop.
      queue.clear();
      await done;

      expect(draws, 4);
      expect(queue.length, 0);
    });

    test('a pass that throws does not leave the recording open', () async {
      final queue = RenderWarmupQueue()
        ..addCustom(_drawDot)
        ..addCustom((canvas, bounds) => throw StateError('broken pass'));

      expect(queue.warmupAllSync, throwsStateError);
      await expectLater(queue.warmupAll(), throwsStateError);

      // The queue is still usable afterwards.
      queue
        ..clear()
        ..addCustom(_drawDot)
        ..warmupAllSync();
      expect(queue.completedTaskCount, 3);
    });
  });
}
