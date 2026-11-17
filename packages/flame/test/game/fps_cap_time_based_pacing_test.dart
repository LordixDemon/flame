import 'package:flame/game.dart';
import 'package:flame/src/game/game_loop.dart';
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

/// Runs [game] in a `GameWidget` for one second on a display that reports
/// [reportedHz] and delivers frames at [actualHz], and returns the number of
/// updates the game received during that second.
Future<int> _updatesPerSecond(
  WidgetTester tester,
  _CountingGame game, {
  required double reportedHz,
  double? actualHz,
}) async {
  game.overrideDisplayMetrics(refreshRate: reportedHz);
  await tester.pumpWidget(GameWidget(game: game));
  await tester.pump();
  await tester.pump();

  final ticksPerSecond = (actualHz ?? reportedHz).round();
  final tick = Duration(microseconds: (1e6 / ticksPerSecond).round());
  final before = game.updates;
  final elapsedBefore = game.elapsed;
  for (var i = 0; i < ticksPerSecond; i++) {
    await tester.pump(tick);
  }
  // No time is lost or counted twice, whatever the pacing.
  expect(game.elapsed - elapsedBefore, closeTo(1.0, 0.02));
  return game.updates - before;
}

/// Starts a [GameLoop] that records every delta it delivers, lets [drive]
/// pump frames, and disposes the loop before the test ends.
Future<List<double>> _recordLoop(
  GameLoop Function(void Function(double dt) callback) create,
  Future<void> Function() drive,
) async {
  final dts = <double>[];
  final loop = create(dts.add)..start();
  try {
    await drive();
  } finally {
    loop.dispose();
  }
  return dts;
}

void main() {
  group('Framerate caps that divide the refresh rate', () {
    testWidgets('60 fps on a 120 Hz display runs every second refresh', (
      tester,
    ) async {
      final n = await _updatesPerSecond(
        tester,
        _CountingGame()..targetFps = 60,
        reportedHz: 120,
      );
      expect(n, inInclusiveRange(59, 61));
    });

    testWidgets('30 fps on a 120 Hz display runs every fourth refresh', (
      tester,
    ) async {
      final n = await _updatesPerSecond(
        tester,
        _CountingGame()..fpsPolicy = const FpsPolicy.powerSave30(),
        reportedHz: 120,
      );
      expect(n, inInclusiveRange(29, 31));
    });

    testWidgets('a cap at the refresh rate runs every refresh', (tester) async {
      final n = await _updatesPerSecond(
        tester,
        _CountingGame()..targetFps = 120,
        reportedHz: 120,
      );
      expect(n, inInclusiveRange(119, 121));
    });

    testWidgets('a cap above the refresh rate runs every refresh', (
      tester,
    ) async {
      final n = await _updatesPerSecond(
        tester,
        _CountingGame()..targetFps = 120,
        reportedHz: 60,
      );
      expect(n, inInclusiveRange(59, 61));
    });
  });

  group('Framerate caps that do not divide the refresh rate', () {
    testWidgets('60 fps on a 90 Hz display averages 60 updates per second', (
      tester,
    ) async {
      final n = await _updatesPerSecond(
        tester,
        _CountingGame()..targetFps = 60,
        reportedHz: 90,
      );
      expect(n, inInclusiveRange(58, 62));
    });

    testWidgets('120 fps on a 144 Hz display averages 120 updates per second', (
      tester,
    ) async {
      final n = await _updatesPerSecond(
        tester,
        _CountingGame()..targetFps = 120,
        reportedHz: 144,
      );
      expect(n, inInclusiveRange(117, 123));
    });

    testWidgets('60 fps on a 144 Hz display averages 60 updates per second', (
      tester,
    ) async {
      final n = await _updatesPerSecond(
        tester,
        _CountingGame()..fpsPolicy = const FpsPolicy.locked60(),
        reportedHz: 144,
      );
      expect(n, inInclusiveRange(58, 62));
    });
  });

  group('Caps are measured in time, not in ticker callbacks', () {
    testWidgets(
      '30 fps stays 30 fps when a display reported as 120 Hz delivers frames '
      'at 60 Hz',
      (tester) async {
        final n = await _updatesPerSecond(
          tester,
          _CountingGame()..fpsPolicy = const FpsPolicy.powerSave30(),
          reportedHz: 120,
          actualHz: 60,
        );
        expect(n, inInclusiveRange(29, 31));
      },
    );

    testWidgets(
      'the idle framerate stays 30 fps when a display reported as 120 Hz '
      'delivers frames at 60 Hz',
      (tester) async {
        final game = _CountingGame()
          ..targetFps = 120
          ..idleFps = 30
          ..idleTimeoutSeconds = 0.0;
        final n = await _updatesPerSecond(
          tester,
          game,
          reportedHz: 120,
          actualHz: 60,
        );
        expect(game.isIdleThrottled, isTrue);
        expect(n, inInclusiveRange(29, 31));
      },
    );

    testWidgets(
      '60 fps stays 60 fps when a display reported as 60 Hz delivers frames '
      'at 120 Hz',
      (tester) async {
        final n = await _updatesPerSecond(
          tester,
          _CountingGame()..targetFps = 60,
          reportedHz: 60,
          actualHz: 120,
        );
        expect(n, inInclusiveRange(59, 61));
      },
    );

    testWidgets(
      'a missed refresh does not delay the frames after it',
      (tester) async {
        // 30 fps on a 120 Hz display: four refreshes of 8.333 ms per frame.
        final dts = await _recordLoop(
          (callback) => GameLoop(
            callback,
            minFrameIntervalGetter: () => 1 / 30,
            vsyncDivisorGetter: () => 4,
            displayRefreshRateGetter: () => 120,
          ),
          () async {
            await tester.pump(const Duration(microseconds: 8333));
            // One refresh is skipped by the platform (a 16.667 ms gap), so
            // only three callbacks arrive during the next 33.3 ms.
            await tester.pump(const Duration(microseconds: 8333));
            await tester.pump(const Duration(microseconds: 16667));
            await tester.pump(const Duration(microseconds: 8333));
          },
        );

        expect(dts, hasLength(2));
        expect(dts.first, 0.0);
        expect(dts.last, closeTo(1 / 30, 1e-4));
      },
    );
  });

  group('GameLoop', () {
    testWidgets('a harmonic divisor keeps its phase under timestamp jitter', (
      tester,
    ) async {
      final dts = await _recordLoop(
        (callback) => GameLoop(
          callback,
          minFrameIntervalGetter: () => 1 / 60,
          vsyncDivisorGetter: () => 2,
          displayRefreshRateGetter: () => 120,
        ),
        () async {
          await tester.pump(const Duration(microseconds: 8333));
          // Refreshes whose timestamps are early or late, so that two of them
          // are between 14.9 ms and 18.5 ms apart instead of 16.7 ms.
          const jitter = [1500, -3300, 0, 1800];
          for (var i = 0; i < 40; i++) {
            await tester.pump(Duration(microseconds: 8333 + jitter[i % 4]));
          }
        },
      );

      // Every second refresh executes, never the first or the third.
      final paced = dts.skip(1).toList();
      expect(paced, hasLength(20));
      for (final dt in paced) {
        expect(dt, closeTo(1 / 60, 0.0021));
      }
    });

    testWidgets('a divisor without a display rate does not pace', (
      tester,
    ) async {
      final dts = await _recordLoop(
        (callback) => GameLoop(callback, vsyncDivisorGetter: () => 2),
        () async {
          for (var i = 0; i < 6; i++) {
            await tester.pump(const Duration(microseconds: 8333));
          }
        },
      );
      expect(dts, hasLength(6));
    });

    testWidgets('the divisor is ignored when it contradicts the interval', (
      tester,
    ) async {
      // A 120 fps cap on a display that is reported as 60 Hz: the divisor of
      // 1 would mean 16.7 ms, twice the requested interval.
      final dts = await _recordLoop(
        (callback) => GameLoop(
          callback,
          minFrameIntervalGetter: () => 1 / 120,
          vsyncDivisorGetter: () => 1,
          displayRefreshRateGetter: () => 60,
        ),
        () async {
          // The display really refreshes at 120 Hz.
          for (var i = 0; i < 13; i++) {
            await tester.pump(const Duration(microseconds: 8333));
          }
        },
      );
      expect(dts, hasLength(13));
    });

    testWidgets('an unpaced tick delivers the time of the skipped ones', (
      tester,
    ) async {
      double? interval = 1 / 30;
      final dts = await _recordLoop(
        (callback) => GameLoop(
          callback,
          minFrameIntervalGetter: () => interval,
        ),
        () async {
          // The first tick always executes, the second one is paced away.
          await tester.pump(const Duration(microseconds: 16667));
          await tester.pump(const Duration(microseconds: 16667));
          // The cap is lifted while 16.7 ms are still waiting to be delivered.
          interval = null;
          await tester.pump(const Duration(microseconds: 16667));
        },
      );
      expect(dts, hasLength(2));
      expect(dts.first, 0.0);
      expect(dts.last, closeTo(2 / 60, 1e-4));
    });
  });

  group('Game.renderTargetFps', () {
    test('a render rate that does not divide the update rate is met on '
        'average', () async {
      final game = FlameGame()
        ..renderTargetFps = 50
        ..onGameResize(Vector2(320, 240));
      await game.start();
      game.resetRenderSkipCounters();

      var renders = 0;
      for (var i = 0; i < 120; i++) {
        game.update(1 / 120);
        if (game.shouldRenderThisTick(1 / 120)) {
          renders++;
          game.onFrameRendered();
        }
      }
      expect(renders, inInclusiveRange(49, 51));
    });
  });

  group('FpsPolicy.harmonicDivisor', () {
    test('resolves whole divisors and rejects the rest', () {
      expect(FpsPolicy.harmonicDivisor(60, 120), 2);
      expect(FpsPolicy.harmonicDivisor(30, 120), 4);
      expect(FpsPolicy.harmonicDivisor(30, 90), 3);
      expect(FpsPolicy.harmonicDivisor(60, 59.94), 1);
      expect(FpsPolicy.harmonicDivisor(120, 60), 1);
      expect(FpsPolicy.harmonicDivisor(60, 90), isNull);
      expect(FpsPolicy.harmonicDivisor(120, 144), isNull);
      expect(FpsPolicy.harmonicDivisor(0, 60), isNull);
      // The same answers as the policy presets give.
      expect(const FpsPolicy.locked60().resolveVsyncDivisor(120), 2);
      expect(const FpsPolicy.custom(120).resolveVsyncDivisor(144), isNull);
    });
  });
}
