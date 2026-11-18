import 'package:flame/game.dart';
import 'package:flame/src/game/game_loop.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

class _CountingGame() extends FlameGame {
  int updates = 0;
  double elapsed = 0;

  @override
  void update(double dt) {
    super.update(dt);
    updates++;
    elapsed += dt;
  }
}

/// Counts the frames Flutter draws (each runs the persistent frame callbacks).
class _FrameCounter(WidgetTester tester) {
  this {
    tester.binding.addPersistentFrameCallback((_) => frames++);
  }

  int frames = 0;
}

Future<void> _runSeconds(WidgetTester tester, double seconds) async {
  final frames = (seconds * 60).round();
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(microseconds: 16667));
  }
}

void main() {
  group('Timer pacing while idle', () {
    testWidgets('an idle game whose scene does not change draws no frames', (
      tester,
    ) async {
      final game = _CountingGame()
        ..idleFps = 30
        ..idleTimeoutSeconds = 0.5
        ..idleRenderMode = IdleRenderMode.onDemandWhenIdle;
      final counter = _FrameCounter(tester);
      await tester.pumpWidget(GameWidget(game: game));
      await tester.pump();
      await _runSeconds(tester, 1);
      expect(game.isIdleThrottled, isTrue);

      final framesBefore = counter.frames;
      final updatesBefore = game.updates;
      await _runSeconds(tester, 1);
      // The simulation keeps its idle rate, but nothing is drawn.
      expect(game.updates - updatesBefore, inInclusiveRange(29, 31));
      expect(counter.frames - framesBefore, 0);
      expect(game.renderBox.gameLoop!.isTimerPaced, isTrue);
    });

    testWidgets('a dirty idle scene draws only the frames it paints', (
      tester,
    ) async {
      final game = _CountingGame()
        ..idleFps = 30
        ..idleTimeoutSeconds = 0.5
        ..idleRenderMode = IdleRenderMode.onDemandWhenIdle;
      var version = 0;
      game.registerDirtyVersionSource(() => version);
      final counter = _FrameCounter(tester);
      await tester.pumpWidget(GameWidget(game: game));
      await tester.pump();
      await _runSeconds(tester, 1);
      expect(game.isIdleThrottled, isTrue);

      final framesBefore = counter.frames;
      for (var i = 0; i < 60; i++) {
        version++;
        await tester.pump(const Duration(microseconds: 16667));
      }
      // About 30 paints in one second, not 60 display refreshes.
      expect(counter.frames - framesBefore, inInclusiveRange(28, 32));
    });

    testWidgets('without timer pacing every display refresh is drawn', (
      tester,
    ) async {
      final game = _CountingGame()
        ..idleFps = 30
        ..idleTimeoutSeconds = 0.5
        ..idleTimerPacing = false
        ..idleRenderMode = IdleRenderMode.onDemandWhenIdle;
      final counter = _FrameCounter(tester);
      await tester.pumpWidget(GameWidget(game: game));
      await tester.pump();
      await _runSeconds(tester, 1);
      expect(game.isIdleThrottled, isTrue);

      final framesBefore = counter.frames;
      await _runSeconds(tester, 1);
      expect(counter.frames - framesBefore, inInclusiveRange(59, 61));
      expect(game.renderBox.gameLoop!.isTimerPaced, isFalse);
    });

    testWidgets('a touch brings the loop back to display frames at once', (
      tester,
    ) async {
      final game = _CountingGame()
        ..targetFps = 60
        ..idleFps = 10
        ..idleTimeoutSeconds = 0.5;
      await tester.pumpWidget(GameWidget(game: game));
      await tester.pump();
      await _runSeconds(tester, 1);
      expect(game.renderBox.gameLoop!.isTimerPaced, isTrue);

      await tester.tapAt(const Offset(40, 40));
      expect(game.renderBox.gameLoop!.isTimerPaced, isFalse);
      expect(SchedulerBinding.instance.hasScheduledFrame, isTrue);
      final updatesBefore = game.updates;
      await _runSeconds(tester, 0.25);
      expect(game.isIdleThrottled, isFalse);
      expect(game.updates - updatesBefore, inInclusiveRange(14, 16));
    });

    testWidgets('notifyActivity brings the loop back to display frames', (
      tester,
    ) async {
      final game = _CountingGame()
        ..idleFps = 10
        ..idleTimeoutSeconds = 0.5;
      await tester.pumpWidget(GameWidget(game: game));
      await tester.pump();
      await _runSeconds(tester, 1);
      expect(game.renderBox.gameLoop!.isTimerPaced, isTrue);

      game.notifyActivity();
      expect(game.renderBox.gameLoop!.isTimerPaced, isFalse);
      expect(SchedulerBinding.instance.hasScheduledFrame, isTrue);
    });

    testWidgets('the time delivered matches the time passed across modes', (
      tester,
    ) async {
      final game = _CountingGame()
        ..idleFps = 30
        ..idleTimeoutSeconds = 0.5;
      await tester.pumpWidget(GameWidget(game: game));
      await tester.pump();
      final start = game.elapsed;
      await _runSeconds(tester, 1.5);
      game.notifyActivity();
      await _runSeconds(tester, 0.5);
      await _runSeconds(tester, 1.0);
      // Up to one interval may still be waiting to be delivered.
      expect(game.elapsed - start, closeTo(3.0, 1 / 30 + 0.02));
    });

    testWidgets('a game suspended with idleFps = 0 draws and updates nothing', (
      tester,
    ) async {
      final game = _CountingGame()
        ..idleFps = 0
        ..idleTimeoutSeconds = 0.5;
      final counter = _FrameCounter(tester);
      await tester.pumpWidget(GameWidget(game: game));
      await tester.pump();
      await _runSeconds(tester, 1);
      expect(game.isIdleThrottled, isTrue);

      final framesBefore = counter.frames;
      final updatesBefore = game.updates;
      await _runSeconds(tester, 2);
      expect(counter.frames - framesBefore, 0);
      expect(game.updates, updatesBefore);

      await tester.tapAt(const Offset(40, 40));
      await _runSeconds(tester, 0.25);
      expect(game.updates, greaterThan(updatesBefore + 10));
    });

    testWidgets('pausing the engine cancels the pacing timer', (tester) async {
      final game = _CountingGame()
        ..idleFps = 30
        ..idleTimeoutSeconds = 0.5;
      await tester.pumpWidget(GameWidget(game: game));
      await tester.pump();
      await _runSeconds(tester, 1);
      expect(game.renderBox.gameLoop!.isTimerPaced, isTrue);

      game.pauseEngine();
      expect(game.renderBox.gameLoop!.isTimerPaced, isFalse);
      final updates = game.updates;
      await _runSeconds(tester, 1);
      expect(game.updates, updates);

      game.resumeEngine();
      await _runSeconds(tester, 1);
      expect(game.updates, greaterThan(updates));
    });
  });

  group('GameLoop timer pacing', () {
    testWidgets('stays on display frames for an interval of one period', (
      tester,
    ) async {
      var ticks = 0;
      final loop = GameLoop(
        (_) => ticks++,
        minFrameIntervalGetter: () => 1 / 60,
        displayRefreshRateGetter: () => 60,
        timerPacingGetter: () => true,
      )..start();
      await _runSeconds(tester, 0.5);
      expect(loop.isTimerPaced, isFalse);
      expect(ticks, inInclusiveRange(29, 31));
      loop.dispose();
    });

    testWidgets('paces a long interval with a timer and requests no frame', (
      tester,
    ) async {
      var ticks = 0;
      final loop = GameLoop(
        (_) => ticks++,
        minFrameIntervalGetter: () => 1 / 20,
        displayRefreshRateGetter: () => 60,
        timerPacingGetter: () => true,
      )..start();
      await tester.pump(const Duration(microseconds: 16667));
      await tester.pump(const Duration(microseconds: 16667));
      expect(loop.isTimerPaced, isFalse);
      // The next executed tick hands over to the timer.
      await _runSeconds(tester, 0.1);
      expect(loop.isTimerPaced, isTrue);
      expect(SchedulerBinding.instance.hasScheduledFrame, isFalse);
      final before = ticks;
      await _runSeconds(tester, 1);
      expect(ticks - before, inInclusiveRange(19, 21));
      loop.stop();
      expect(loop.isTimerPaced, isFalse);
      loop.dispose();
    });
  });
}
