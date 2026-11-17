import 'dart:ui';

import 'package:flame/components.dart';
import 'package:flame/post_process.dart';
import 'package:flame_test/flame_test.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a 0.1% change of the visible rect size does not teleport rain drops',
    () {
      final rain = WeatherPrecipitationLayer(
        particleCount: 64,
        windVelocityX: -42,
        fallSpeedY: 320,
      );
      // One minute of play.
      for (var i = 0; i < 3600; i++) {
        rain.update(1 / 60);
      }

      // The camera zooms by 0.1% around its centre (800x600 -> 800.8x600.6).
      const before = Rect.fromLTWH(0, 0, 800, 600);
      final after = Rect.fromCenter(
        center: before.center,
        width: 800.8,
        height: 600.6,
      );

      var worstJump = 0.0;
      var jumped = 0;
      for (var i = 0; i < 64; i++) {
        final a = rain.sampleDropPosition(i, before);
        final b = rain.sampleDropPosition(i, after);
        final d = (a - b).distance;
        // A drop that merely crossed the wrap seam moves by about one view
        // size; ignore those (there can only be a few) and look at the rest.
        if (d > 500) {
          continue;
        }
        if (d > 2.0) {
          jumped++;
        }
        if (d > worstJump) {
          worstJump = d;
        }
      }
      expect(
        jumped,
        0,
        reason:
            'no time passed between the two samples, the view grew by less '
            'than 1 px, yet $jumped of 64 drops moved by more than 2 px '
            '(worst ${worstJump.toStringAsFixed(1)} px)',
      );
    },
  );

  testWithFlameGame(
    'onDropImpact points lie inside the camera-visible world rect',
    (game) async {
      game.onGameResize(Vector2(400, 300));
      final impacts = <Offset>[];
      final rain = WeatherPrecipitationLayer(
        splashRate: 120,
        onDropImpact: (x, y) => impacts.add(Offset(x, y)),
      );
      await game.world.ensureAdd(rain);
      // Look at a part of the world far away from the default fallbackBounds
      // (0, 0, 800, 600).
      game.camera.viewfinder.position = Vector2(5000, 5000);
      await game.ready();

      for (var i = 0; i < 30; i++) {
        game.update(1 / 60);
        final recorder = PictureRecorder();
        game.render(Canvas(recorder));
        recorder.endRecording().dispose();
      }

      final visible = game.camera.visibleWorldRect;
      expect(impacts, isNotEmpty);
      final outside = impacts.where((p) => !visible.contains(p)).length;
      expect(
        outside,
        0,
        reason:
            '$outside of ${impacts.length} impacts are outside the visible '
            'rect $visible (first: ${impacts.first})',
      );
    },
  );

  test('changing the wind does not teleport the drops', () {
    final rain = WeatherPrecipitationLayer(particleCount: 64);
    for (var i = 0; i < 600; i++) {
      rain.update(1 / 60);
    }
    const view = Rect.fromLTWH(0, 0, 800, 600);
    final before = [
      for (var i = 0; i < 64; i++) rain.sampleDropPosition(i, view),
    ];
    rain
      ..windVelocityX = 90
      ..fallSpeedY = 200
      ..update(1 / 60);
    for (var i = 0; i < 64; i++) {
      final moved = (rain.sampleDropPosition(i, view) - before[i]).distance;
      // One frame at under 500 px/s; wrapping across the seam is the only
      // way to move further.
      if (moved < 400) {
        expect(moved, lessThan(12));
      }
    }
  });
}
