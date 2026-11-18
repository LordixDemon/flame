import 'dart:math' as math;

import 'package:flame/components.dart';

import 'frame_scene.dart';

/// Times the phases of a frame of [FrameSceneGame]: the update, the render
/// into a picture, a coalesced hover and a tap hit-test, in microseconds per
/// frame (the median of several runs).
///
/// ```console
/// flutter test benchmark/frame_scene_benchmark.dart
/// ```
///
/// `flutter test` runs JIT code with asserts, so the numbers are only good for
/// comparing two versions on the same machine; `frame_scene_app.dart` runs the
/// same scene in a profile build.
Future<void> main() async {
  final report = await FrameSceneTimings.measure();
  // ignore: avoid_print
  print(report);
}

/// The time per frame of each phase of [FrameSceneGame].
class FrameSceneTimings({
  required final double update,
  required final double render,
  required final double hover,
  required final double hitTest,
  required final int frames,
  required final int components,
}) {
  /// Runs the scene for [warmupFrames] and then [runs] times [frames] frames,
  /// and returns the median time of each phase.
  static Future<FrameSceneTimings> measure({
    int warmupFrames = 600,
    int frames = 1200,
    int runs = 5,
  }) async {
    final game = await FrameSceneGame.create();
    final points = _hoverPath(frames);
    for (var i = 0; i < warmupFrames; i++) {
      game.hover(points[i % frames].x, points[i % frames].y);
      game.step();
      game.renderFrame();
      game.hitTest(points[(i * 7) % frames]);
    }
    final update = <double>[];
    final render = <double>[];
    final hover = <double>[];
    final hit = <double>[];
    final watch = Stopwatch();
    for (var run = 0; run < runs; run++) {
      var tUpdate = 0;
      var tRender = 0;
      var tHover = 0;
      var tHit = 0;
      for (var i = 0; i < frames; i++) {
        final p = points[i];
        watch
          ..reset()
          ..start();
        game.hover(p.x, p.y);
        tHover += watch.elapsedMicroseconds;
        watch
          ..reset()
          ..start();
        game.step();
        tUpdate += watch.elapsedMicroseconds;
        watch
          ..reset()
          ..start();
        game.renderFrame();
        tRender += watch.elapsedMicroseconds;
        watch
          ..reset()
          ..start();
        game.hitTest(points[(i * 7) % frames]);
        tHit += watch.elapsedMicroseconds;
      }
      update.add(tUpdate / frames);
      render.add(tRender / frames);
      hover.add(tHover / frames);
      hit.add(tHit / frames);
    }
    return FrameSceneTimings(
      update: _median(update),
      render: _median(render),
      hover: _median(hover),
      hitTest: _median(hit),
      frames: frames,
      components: game.descendants().length,
    );
  }

  /// A mouse path that sweeps the screen in a figure eight.
  static List<Vector2> _hoverPath(int count) {
    final size = FrameSceneGame.screenSize;
    return [
      for (var i = 0; i < count; i++)
        Vector2(
          size.x * (0.5 + 0.45 * math.sin(i * 0.013)),
          size.y * (0.5 + 0.45 * math.sin(i * 0.026)),
        ),
    ];
  }

  static double _median(List<double> values) {
    final sorted = [...values]..sort();
    return sorted[sorted.length ~/ 2];
  }

  @override
  String toString() {
    String f(double v) => v.toStringAsFixed(1).padLeft(8);
    final title =
        'Frame scene: $components components, median of runs of $frames '
        'frames, microseconds per frame';
    return [
      title,
      '  update   ${f(update)}',
      '  render   ${f(render)}',
      '  hover    ${f(hover)}',
      '  hit test ${f(hitTest)}',
      '  total    ${f(update + render + hover + hitTest)}',
    ].join('\n');
  }
}
