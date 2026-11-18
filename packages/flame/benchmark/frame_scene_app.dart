import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flame/components.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'frame_scene.dart';

/// The app that `tool/measure_frame_scene.dart` runs in a profile build, so
/// that it can time the phases of a frame of [FrameSceneGame] and count what
/// they allocate in AOT code, like a game has.
///
/// It does nothing by itself: it registers the service extension
/// `ext.flame.frameScene`, which runs frames of the scene.
///
/// To run it by hand, from a directory with a macOS runner (see the README):
///
///     flutter run -d macos --profile -t <path to this file>
void main() {
  developer.registerExtension('ext.flame.frameScene', _handle);
  runApp(const SizedBox());
}

FrameSceneGame? _game;
int _frame = 0;

/// The phases that `ext.flame.frameScene` can run, by name.
///
/// Every phase runs the whole frame, so that the scene keeps moving the same
/// way whatever is measured; only the named phase is timed.
const _phases = ['frame', 'update', 'render', 'hover', 'hitTest', 'none'];

/// Runs frames of the scene, with the arguments (all strings):
///
/// - `phase`: the phase to time, one of [_phases]; `none` runs nothing, as a
///   control for counting allocations.
/// - `frames`: the number of frames.
///
/// It returns the microseconds that the phase took over all the frames.
Future<developer.ServiceExtensionResponse> _handle(
  String method,
  Map<String, String> parameters,
) async {
  final phase = parameters['phase'] ?? 'frame';
  if (!_phases.contains(phase)) {
    return developer.ServiceExtensionResponse.error(
      developer.ServiceExtensionResponse.invalidParams,
      'Unknown phase $phase',
    );
  }
  final frames = int.parse(parameters['frames'] ?? '0');
  final game = _game ??= await FrameSceneGame.create();
  final size = FrameSceneGame.screenSize;
  final point = Vector2.zero();
  final watch = Stopwatch();
  var micros = 0;
  if (phase != 'none') {
    for (var i = 0; i < frames; i++) {
      final f = _frame++;
      final x = size.x * (0.5 + 0.45 * _wave(f * 0.013));
      final y = size.y * (0.5 + 0.45 * _wave(f * 0.026));
      if (phase == 'hover' || phase == 'frame') {
        watch.reset();
        watch.start();
      }
      game.hover(x, y);
      if (phase == 'hover') {
        micros += watch.elapsedMicroseconds;
      }
      if (phase == 'update') {
        watch.reset();
        watch.start();
      }
      game.step();
      if (phase == 'update') {
        micros += watch.elapsedMicroseconds;
      }
      if (phase == 'render') {
        watch.reset();
        watch.start();
      }
      game.renderFrame();
      if (phase == 'render') {
        micros += watch.elapsedMicroseconds;
      }
      if (phase == 'hitTest') {
        watch.reset();
        watch.start();
      }
      point.setValues(size.x - x, size.y - y);
      game.hitTest(point);
      if (phase == 'hitTest' || phase == 'frame') {
        micros += watch.elapsedMicroseconds;
      }
    }
  }
  return developer.ServiceExtensionResponse.result(
    jsonEncode({
      'micros': micros,
      'frames': frames,
      'components': game.descendants().length,
      'profileMode': kProfileMode,
    }),
  );
}

/// A triangle wave in `[-1, 1]`, cheaper than a sine and with no allocation.
double _wave(double t) {
  final f = t - t.floorToDouble();
  return f < 0.5 ? 4 * f - 1 : 3 - 4 * f;
}
