import 'package:flame/components.dart';
import 'package:flame/effects.dart';
import 'package:flame/game.dart';
import 'package:flame/src/game/game_loop.dart';
import 'package:flutter_test/flutter_test.dart';

class _TelemetryProbeGame() extends FlameGame with HasFrameTelemetry;

void main() {
  group('FpsPolicy, decoupled renderTargetFps, dirty render & FrameBudget', () {
    test(
      'FpsPolicy resolves exact harmonic VSync divisors across 60/120/144/240 '
      'Hz (#11)',
      () {
        const locked60 = FpsPolicy.locked60();
        expect(locked60.resolveVsyncDivisor(60.0), 1);
        expect(locked60.resolveVsyncDivisor(120.0), 2);
        expect(locked60.resolveVsyncDivisor(240.0), 4);
        // 60 FPS on 144 Hz is non-harmonic (2.4) -> falls back to accumulator.
        expect(locked60.resolveVsyncDivisor(144.0), isNull);

        // harmonicHalf gives 72 FPS (divisor 2) on 144 Hz, and stays 60 FPS
        // (divisor 1) on 60 Hz!
        const half = FpsPolicy.harmonicHalf();
        expect(half.resolveTargetFps(144.0), closeTo(72.0, 1e-5));
        expect(half.resolveVsyncDivisor(144.0), 2);
        expect(half.resolveTargetFps(60.0), closeTo(60.0, 1e-5));
        expect(half.resolveVsyncDivisor(60.0), 1);

        const save30 = FpsPolicy.powerSave30();
        expect(save30.resolveVsyncDivisor(120.0), 4);
      },
    );

    testWidgets(
      'GameLoop integer VSync divisor fires exact 1/2 beats on 120 Hz (#11)',
      (tester) async {
        final dts = <double>[];
        final loop = GameLoop(
          dts.add,
          vsyncDivisorGetter: () => 2,
        )..start();
        try {
          const tick120 = Duration(microseconds: 8333);
          for (var i = 1; i <= 10; i++) {
            await tester.pump(tick120);
          }
          // First pump fires initial dt=0 tick; next 9 beats divide by 2 -> 4
          // exact ~16.666ms updates with zero drift!
          expect(dts.first, 0.0);
          final paced = dts.skip(1).toList();
          expect(paced.length, 4);
          for (final dt in paced) {
            expect(dt, closeTo(0.016666, 1e-3));
          }
        } finally {
          loop.dispose();
        }
      },
    );

    test(
      'Decoupled renderTargetFps & fixedTimeStep renderInterpolationAlpha '
      '(#12)',
      () async {
        final game = FlameGame()
          ..fixedTimeStep = 0.01
          ..renderTargetFps = 30.0
          ..onGameResize(Vector2(320, 240));
        await game.start();
        game.resetRenderSkipCounters();

        // Simulate 6 update ticks at 60 Hz (dt = 1/60 = 0.01667s):
        // 30 Hz render cap allows ~3 renders and skips ~3 renders!
        var rendersScheduled = 0;
        for (var i = 0; i < 6; i++) {
          game.updateTree(1.0 / 60.0);
          if (game.shouldRenderThisTick(1.0 / 60.0)) {
            rendersScheduled++;
            game.onFrameRendered();
          }
        }
        expect(game.executedUpdateTicks, 6);
        expect(rendersScheduled, 3);
        expect(game.skippedRenderFrames, 3);
        expect(game.executedRenderFrames, 3);
        expect(game.renderInterpolationAlpha, inInclusiveRange(0.0, 1.0));
      },
    );

    test(
      'IdleRenderMode.onDemand skips clean paints and wakes on scene mutations '
      '(#13)',
      () async {
        final game = FlameGame()
          ..idleRenderMode = IdleRenderMode.onDemand
          ..onGameResize(Vector2(320, 240));
        final actor = PositionComponent(
          position: Vector2(10, 20),
          size: Vector2(16, 16),
        );
        game.world.add(actor);
        await game.start();
        game.resetRenderSkipCounters();

        // Frame 1: initial dirty state renders once.
        expect(game.shouldRenderThisTick(0.016), isTrue);
        game.onFrameRendered();
        expect(game.isSceneDirty, isFalse);

        // Stationary frames 2..4: update runs, but paint is skipped!
        for (var i = 0; i < 3; i++) {
          game.update(0.016);
          expect(game.shouldRenderThisTick(0.016), isFalse);
        }
        expect(game.skippedCleanPaints, 3);

        // Moving a component mutates Transform2D -> automatically wakes paint!
        actor.position.x += 5.0;
        game.update(0.016);
        expect(game.shouldRenderThisTick(0.016), isTrue);
        game.onFrameRendered();

        // Adding and ticking an Effect also marks scene dirty automatically.
        actor.add(
          MoveByEffect(Vector2(20, 0), EffectController(duration: 0.2)),
        );
        game.update(0.05);
        expect(game.shouldRenderThisTick(0.05), isTrue);
        game.onFrameRendered();
      },
    );

    test(
      'Hardware FrameTiming ring-buffer percentiles, jank & isGpuBound (#14)',
      () {
        final game = _TelemetryProbeGame()..onGameResize(Vector2(320, 240));
        for (var i = 0; i < 19; i++) {
          game.renderTelemetry.recordPlatformFrameTiming(
            buildMicros: 2500,
            rasterMicros: 9500,
            totalSpanMicros: 12000,
          );
        }
        // Inject 1 heavy GPU jank frame (32 ms > 1.5 * 16.67 ms = 25 ms).
        game.renderTelemetry.recordPlatformFrameTiming(
          buildMicros: 3000,
          rasterMicros: 29000,
          totalSpanMicros: 32000,
        );

        expect(game.renderTelemetry.platformTimingSampleCount, 20);
        expect(game.jankFrameCount, 1);
        expect(game.isGpuBound, isTrue);
        expect(game.smoothedRasterMs, greaterThan(game.smoothedBuildMs));
        expect(game.p99FrameMs, closeTo(32.0, 1e-2));
        expect(game.p95FrameMs, greaterThanOrEqualTo(12.0));
      },
    );

    test(
      'FrameBudgetScheduler orders by priority and enforces anti-starvation '
      '(#15)',
      () async {
        final order = <String>[];
        final scheduler = FrameBudgetScheduler(
          budgetFraction: 0.5,
          maxTasksPerFrame: 2,
          maxStarvationFrames: 3,
        );

        final fLow = scheduler.schedule(() {
          order.add('low');
          return 1;
        }, priority: 1);
        final fHigh = scheduler.schedule(() {
          order.add('high');
          return 2;
        }, priority: 10);
        scheduler.scheduleSync(() => order.add('mid'), priority: 5);

        // Busy frames where update already exceeded 50% of 16ms (8000us):
        // first 3 busy frames defer work; 4th triggers anti-starvation!
        expect(
          scheduler.drainWithinBudget(
            elapsedUpdateMicros: 9500,
            frameBudgetMicros: 16000,
          ),
          0,
        );
        expect(
          scheduler.drainWithinBudget(
            elapsedUpdateMicros: 9500,
            frameBudgetMicros: 16000,
          ),
          0,
        );
        expect(
          scheduler.drainWithinBudget(
            elapsedUpdateMicros: 9500,
            frameBudgetMicros: 16000,
          ),
          0,
        );
        expect(
          scheduler.drainWithinBudget(
            elapsedUpdateMicros: 9500,
            frameBudgetMicros: 16000,
          ),
          1,
        );
        expect(order, ['high']);
        expect(await fHigh, 2);

        // Light frame drains remaining tasks up to maxTasksPerFrame (2).
        expect(
          scheduler.drainWithinBudget(
            elapsedUpdateMicros: 1000,
            frameBudgetMicros: 16000,
          ),
          2,
        );
        expect(order, ['high', 'mid', 'low']);
        expect(await fLow, 1);
        expect(scheduler.pendingTaskCount, 0);
      },
    );
  });
}
