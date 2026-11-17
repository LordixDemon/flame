import 'dart:ui' show Size;

import 'package:flame/game.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Game.displayMetrics', () {
    test('reports the effective pixel ratio, canvas and refresh rate', () {
      final game = FlameGame()
        ..onGameResize(Vector2(800, 600))
        ..overrideDisplayMetrics(devicePixelRatio: 3.0, refreshRate: 120.0)
        ..maxDevicePixelRatio = 2.0;

      final metrics = game.displayMetrics;
      expect(metrics.devicePixelRatio, 2.0);
      expect(metrics.physicalSize, const Size(1600, 1200));
      expect(metrics.logicalSize, const Size(800, 600));
      expect(metrics.refreshRate, 120.0);
      expect(metrics.devicePixelRatio, game.devicePixelRatio);
      expect(metrics.refreshRate, game.displayRefreshRate);

      // It is a snapshot: later changes produce a different one.
      game.maxDevicePixelRatio = 1.0;
      expect(game.displayMetrics, isNot(metrics));
      expect(game.displayMetrics.physicalSize, const Size(800, 600));
      expect(metrics.devicePixelRatio, 2.0);
    });

    test('has an empty physical size before the first layout', () {
      final game = FlameGame()..overrideDisplayMetrics(devicePixelRatio: 2.0);
      expect(game.hasLayout, isFalse);
      expect(game.displayMetrics.physicalSize, Size.zero);
      expect(game.displayMetrics.devicePixelRatio, 2.0);
    });
  });

  group('Game.maxDevicePixelRatio', () {
    test('a changed cap repaints an on-demand scene', () async {
      final game = FlameGame()
        ..idleRenderMode = IdleRenderMode.onDemand
        ..overrideDisplayMetrics(devicePixelRatio: 3.0)
        ..onGameResize(Vector2(800, 600));
      await game.start();

      game.update(1 / 60);
      expect(game.shouldRenderThisTick(1 / 60), isTrue);
      game.onFrameRendered();
      game.update(1 / 60);
      expect(game.shouldRenderThisTick(1 / 60), isFalse);

      // The cap is a plain value that nothing announces.
      game.maxDevicePixelRatio = 1.5;
      expect(game.devicePixelRatio, 1.5);
      game.update(1 / 60);
      expect(game.shouldRenderThisTick(1 / 60), isTrue);
      game.onFrameRendered();

      game.update(1 / 60);
      expect(game.shouldRenderThisTick(1 / 60), isFalse);
    });
  });
}
