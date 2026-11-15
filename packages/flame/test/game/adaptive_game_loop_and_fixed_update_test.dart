import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flame/src/game/game_loop.dart';
import 'package:flutter_test/flutter_test.dart';

class _SpringBodyComponent() extends Component with HasFixedUpdate {
  double position = 0.0;
  double velocity = 12.0;
  int fixedSteps = 0;
  int variableSteps = 0;

  @override
  void fixedUpdate(double fixedDt) {
    fixedSteps++;
    const stiffness = 80.0;
    const damping = 6.0;
    final accel = -stiffness * (position - 1.0) - damping * velocity;
    velocity += accel * fixedDt;
    position += velocity * fixedDt;
  }

  @override
  void update(double dt) {
    variableSteps++;
  }
}

class _TimeScaledFixedGame() extends FlameGame with HasTimeScale;

void main() {
  group('Adaptive Frame Pacing', () {
    testWidgets(
      'GameLoop throttles ticks according to minFrameIntervalGetter',
      (tester) async {
        final dts = <double>[];
        final loop = GameLoop(
          dts.add,
          minFrameIntervalGetter: () => 1.0 / 30.0,
        )..start();

        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(microseconds: 16667));
        }
        loop.dispose();

        expect(loop.executedTicks, inInclusiveRange(4, 6));
        expect(loop.skippedTicks, greaterThanOrEqualTo(4));
        for (final dt in dts.skip(1)) {
          expect(dt, greaterThanOrEqualTo((1.0 / 30.0) * 0.92));
        }
      },
    );

    test(
      'Game transitions between targetFps, idleFps, and notifyActivity boost',
      () {
        final game = FlameGame()
          ..targetFps = 120
          ..idleFps = 30
          ..idleTimeoutSeconds = 2.0;

        expect(game.isIdleThrottled, isFalse);
        expect(game.effectiveTargetFps, equals(120));
        expect(game.minFrameIntervalSeconds, closeTo(1.0 / 120.0, 1e-6));

        game.advanceAdaptivePacing(1.5);
        expect(game.isIdleThrottled, isFalse);
        expect(game.effectiveTargetFps, equals(120));

        game.advanceAdaptivePacing(0.6);
        expect(game.isIdleThrottled, isTrue);
        expect(game.effectiveTargetFps, equals(30));
        expect(game.minFrameIntervalSeconds, closeTo(1.0 / 30.0, 1e-6));

        game.notifyActivity(boostSeconds: 3.0);
        expect(game.isIdleThrottled, isFalse);
        expect(game.effectiveTargetFps, equals(120));

        game.advanceAdaptivePacing(2.5);
        expect(game.isIdleThrottled, isFalse);

        game.advanceAdaptivePacing(0.6);
        game.advanceAdaptivePacing(2.1);
        expect(game.isIdleThrottled, isTrue);

        game.idleFps = 0;
        expect(game.effectiveTargetFps, equals(0));
        expect(game.minFrameIntervalSeconds, equals(double.infinity));
      },
    );

    testWidgets(
      'pointer hover/down on GameWidget automatically wakes idle game',
      (tester) async {
        final game = FlameGame()
          ..targetFps = 120
          ..idleFps = 20
          ..idleTimeoutSeconds = 1.0;

        await tester.pumpWidget(GameWidget(game: game));
        await tester.pump();

        game.advanceAdaptivePacing(2.0);
        expect(game.isIdleThrottled, isTrue);

        await tester.tapAt(const Offset(50, 50));
        await tester.pump();
        expect(game.isIdleThrottled, isFalse);
      },
    );
  });

  group('Deterministic Fixed-Substep Simulation', () {
    test(
      '60Hz and 120Hz frame rates produce identical fixedUpdate physics state',
      () async {
        Future<_SpringBodyComponent> runSim(
          int frames,
          double frameDt,
        ) async {
          final game = FlameGame()
            ..fixedTimeStep = 1.0 / 120.0
            ..onGameResize(Vector2(800, 600));
          final body = _SpringBodyComponent();
          game.add(body);
          await game.start();
          game.resetFixedUpdateAccumulator();
          body
            ..position = 0.0
            ..velocity = 12.0
            ..fixedSteps = 0
            ..variableSteps = 0;

          for (var i = 0; i < frames; i++) {
            game.update(frameDt);
          }
          return body;
        }

        final body60 = await runSim(60, 1.0 / 60.0);
        final body120 = await runSim(120, 1.0 / 120.0);

        expect(body60.fixedSteps, equals(120));
        expect(body120.fixedSteps, equals(120));
        expect(body60.variableSteps, equals(60));
        expect(body120.variableSteps, equals(120));
        expect(body60.position, closeTo(body120.position, 1e-12));
        expect(body60.velocity, closeTo(body120.velocity, 1e-12));
      },
    );

    test(
      'exposes renderInterpolationAlpha for fractional remainders and caps '
      'maxFixedSubSteps',
      () async {
        final game = FlameGame()
          ..fixedTimeStep = 0.01
          ..maxFixedSubSteps = 4
          ..onGameResize(Vector2(400, 300));
        final body = _SpringBodyComponent();
        game.add(body);
        await game.start();
        game.resetFixedUpdateAccumulator();
        body.fixedSteps = 0;

        game.update(0.015);
        expect(game.lastFrameFixedSteps, equals(1));
        expect(body.fixedSteps, equals(1));
        expect(game.renderInterpolationAlpha, closeTo(0.5, 1e-6));

        game.update(0.20);
        expect(game.lastFrameFixedSteps, equals(4));
        expect(body.fixedSteps, equals(5));
      },
    );

    test('HasTimeScale = 0 pauses HasFixedUpdate simulation', () async {
      final game = _TimeScaledFixedGame()
        ..fixedTimeStep = 1.0 / 120.0
        ..onGameResize(Vector2(400, 300));
      final body = _SpringBodyComponent();
      game.add(body);
      await game.start();
      body.fixedSteps = 0;

      game.timeScale = 0.0;
      game.update(1.0 / 60.0);
      expect(body.fixedSteps, equals(0));

      game.timeScale = 1.0;
      game.update(1.0 / 60.0);
      expect(body.fixedSteps, greaterThan(0));
    });
  });
}
