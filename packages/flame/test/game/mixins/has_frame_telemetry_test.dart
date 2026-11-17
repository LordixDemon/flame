import 'package:flame/game.dart';
import 'package:flutter_test/flutter_test.dart';

class _TelemetryGame() extends FlameGame with HasFrameTelemetry;

void main() {
  group('HasFrameTelemetry', () {
    test('records one sample per frame delta', () async {
      final game = _TelemetryGame()..onGameResize(Vector2(320, 240));
      await game.start();
      final samplesAfterStart = game.telemetrySampleCount;

      for (var i = 0; i < 5; i++) {
        game.update(1 / 60);
      }
      expect(game.telemetrySampleCount, samplesAfterStart + 5);
      expect(
        game.telemetrySampleMsAt(game.telemetrySampleCount - 1),
        closeTo(16.67, 0.01),
      );
      expect(game.worstFrameMs, closeTo(16.67, 0.01));
    });

    test('zero-delta updates are not counted as frames', () async {
      final game = _TelemetryGame()..onGameResize(Vector2(320, 240));
      // `start` runs the first update with a delta of zero.
      await game.start();
      expect(game.telemetrySampleCount, 0);

      for (var i = 0; i < 30; i++) {
        game.update(1 / 60);
      }
      final samples = game.telemetrySampleCount;
      final smoothed = game.smoothedFrameMs;

      // A resize of the game widget updates the game with a delta of zero.
      game
        ..onGameResize(Vector2(640, 480))
        ..update(0)
        ..update(0);
      expect(game.telemetrySampleCount, samples);
      expect(game.smoothedFrameMs, smoothed);
    });
  });
}
