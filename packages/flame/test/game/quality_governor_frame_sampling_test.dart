import 'package:flame/game.dart';
import 'package:flutter_test/flutter_test.dart';

/// Reports to [game] that the platform measured a frame that took
/// [costMicros] from vsync to the end of rasterization.
void _reportFrameTiming(FlameGame game, int costMicros) {
  game.renderTelemetry.recordPlatformFrameTiming(
    buildMicros: 1000,
    rasterMicros: costMicros,
    totalSpanMicros: costMicros,
  );
}

/// One game loop tick as `GameRenderBox` runs it: pacing, update and, when the
/// game asks for it, a paint.
void _tick(FlameGame game, double dt) {
  game.advanceAdaptivePacing(dt);
  game.update(dt);
  if (game.shouldRenderThisTick(dt)) {
    game.onFrameRendered();
  }
}

void main() {
  group('DynamicQualityGovernor frame sampling', () {
    testWidgets('a game that does no work keeps the full render scale', (
      tester,
    ) async {
      final game = FlameGame();
      game.qualityGovernor.enabled = true;
      await tester.pumpWidget(GameWidget(game: game));
      await tester.pump();

      // Ten seconds of frames at vsync. The time between two frames equals
      // the frame budget, which says nothing about how long a frame takes.
      for (var i = 0; i < 600; i++) {
        await tester.pump(const Duration(microseconds: 16667));
      }

      expect(game.executedRenderFrames, greaterThan(500));
      expect(game.qualityGovernor.adjustmentCount, 0);
      expect(game.effectiveRenderScale, 1.0);
    });

    test('a constant scene settles on one render scale, whether the player '
        'is active or idle', () async {
      final game = FlameGame()
        ..targetFps = 120
        ..idleFps = 30
        ..idleTimeoutSeconds = 1.0
        ..overrideDisplayMetrics(refreshRate: 120)
        ..onGameResize(Vector2(800, 600));
      final governor = game.qualityGovernor..enabled = true;
      await game.start();

      // A fill-rate bound scene: 10 ms per frame at full resolution,
      // proportional to the number of pixels. The budget at 120 fps is
      // 8.3 ms.
      void frame(double dt) {
        final scale = governor.dynamicRenderScaleMultiplier;
        _reportFrameTiming(game, (10000.0 * scale * scale).round());
        _tick(game, dt);
      }

      void playerInteracts(double seconds) {
        for (var i = 0; i < (seconds * 120).round(); i++) {
          game.notifyActivity();
          frame(1 / 120);
        }
      }

      void playerWaits(double seconds) {
        for (var i = 0; i < 120; i++) {
          frame(1 / 120);
        }
        expect(game.isIdleThrottled, isTrue);
        for (var i = 0; i < ((seconds - 1) * 30).round(); i++) {
          frame(1 / 30);
        }
      }

      playerInteracts(8);
      // 0.8 * 0.8 * 10 ms = 6.4 ms fits the budget, 0.9 does not.
      expect(governor.dynamicRenderScaleMultiplier, closeTo(0.8, 1e-9));
      final settledAdjustments = governor.adjustmentCount;

      for (var cycle = 0; cycle < 5; cycle++) {
        // The idle throttle stretches the time between frames, but a frame
        // still costs 6.4 ms: that is no reason to raise the resolution.
        playerWaits(12);
        expect(governor.dynamicRenderScaleMultiplier, closeTo(0.8, 1e-9));
        playerInteracts(8);
      }

      expect(governor.adjustmentCount, settledAdjustments);
      expect(governor.dynamicRenderScaleMultiplier, closeTo(0.8, 1e-9));
    });

    test('the render scale recovers when the scene becomes cheaper', () async {
      final game = FlameGame()
        ..targetFps = 60
        ..overrideDisplayMetrics(refreshRate: 60)
        ..onGameResize(Vector2(800, 600));
      final governor = game.qualityGovernor..enabled = true;
      await game.start();

      // 20 ms per frame against a budget of 16.7 ms.
      for (var i = 0; i < 600; i++) {
        _reportFrameTiming(game, 20000);
        _tick(game, 1 / 60);
      }
      expect(governor.dynamicRenderScaleMultiplier, lessThan(1.0));

      // 5 ms per frame leaves plenty of headroom.
      for (var i = 0; i < 3000; i++) {
        _reportFrameTiming(game, 5000);
        _tick(game, 1 / 60);
      }
      expect(governor.dynamicRenderScaleMultiplier, 1.0);
    });

    test('no sample is taken while nothing is rendered', () async {
      final game = FlameGame()
        ..idleRenderMode = IdleRenderMode.onDemand
        ..overrideDisplayMetrics(refreshRate: 60)
        ..onGameResize(Vector2(800, 600));
      final governor = game.qualityGovernor..enabled = true;
      await game.start();

      // The last frame before the scene came to rest was far over budget.
      for (var i = 0; i < 4; i++) {
        game.markSceneDirty();
        _reportFrameTiming(game, 40000);
        _tick(game, 1 / 60);
      }
      final scaleAtRest = governor.dynamicRenderScaleMultiplier;
      final adjustmentsAtRest = governor.adjustmentCount;

      // A minute without a single paint: the stale measurement must not be
      // counted again on every update.
      final rendered = game.executedRenderFrames;
      for (var i = 0; i < 3600; i++) {
        _tick(game, 1 / 60);
      }
      expect(game.executedRenderFrames, rendered);
      expect(governor.dynamicRenderScaleMultiplier, scaleAtRest);
      expect(governor.adjustmentCount, adjustmentsAtRest);
    });

    test('the multiplier follows bounds that are changed later', () {
      final governor = DynamicQualityGovernor(enabled: true);
      expect(governor.dynamicRenderScaleMultiplier, 1.0);

      governor.maxRenderScale = 0.9;
      expect(governor.dynamicRenderScaleMultiplier, 0.9);

      governor
        ..maxRenderScale = 2.0
        ..minRenderScale = 1.2;
      expect(governor.dynamicRenderScaleMultiplier, 1.2);
    });

    test('switching the governor off repaints an on-demand scene', () async {
      final game = FlameGame()
        ..idleRenderMode = IdleRenderMode.onDemand
        ..overrideDisplayMetrics(refreshRate: 60)
        ..onGameResize(Vector2(800, 600));
      final governor = game.qualityGovernor..enabled = true;
      await game.start();

      for (var i = 0; i < 600; i++) {
        game.markSceneDirty();
        _reportFrameTiming(game, 40000);
        _tick(game, 1 / 60);
      }
      expect(game.effectiveRenderScale, lessThan(1.0));

      // Let the scene come to rest.
      for (var i = 0; i < 5; i++) {
        _tick(game, 1 / 60);
      }
      game.update(1 / 60);
      expect(game.shouldRenderThisTick(1 / 60), isFalse);

      // A plain field: nothing announces this change.
      governor.enabled = false;
      expect(game.effectiveRenderScale, 1.0);
      game.update(1 / 60);
      expect(game.shouldRenderThisTick(1 / 60), isTrue);
    });
  });
}
