import 'dart:ui' show PointerDeviceKind;

import 'package:flame/events.dart';
import 'package:flame/game.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

class _CountingGame() extends FlameGame {
  int updates = 0;

  @override
  void update(double dt) {
    super.update(dt);
    updates++;
  }
}

class _IdleFromOnLoadGame() extends _CountingGame {
  @override
  Future<void> onLoad() async {
    await super.onLoad();
    idleFps = 10;
    idleTimeoutSeconds = 1.0;
  }
}

class _KeyGame() extends FlameGame with KeyboardEvents {
  int keyEvents = 0;

  @override
  KeyEventResult onKeyEvent(
    KeyEvent event,
    Set<LogicalKeyboardKey> keysPressed,
  ) {
    keyEvents++;
    return KeyEventResult.handled;
  }
}

Future<void> _runSeconds(WidgetTester tester, double seconds) async {
  final frames = (seconds * 60).round();
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(microseconds: 16667));
  }
}

void main() {
  group('User input that keeps a game out of the idle throttle', () {
    testWidgets('a touch, when idleFps was set before the widget was built', (
      tester,
    ) async {
      final game = _CountingGame()
        ..idleFps = 10
        ..idleTimeoutSeconds = 1.0;
      await tester.pumpWidget(GameWidget(game: game));
      await tester.pump();
      await _runSeconds(tester, 2);
      expect(game.isIdleThrottled, isTrue);

      await tester.tapAt(const Offset(50, 50));
      await tester.pump(const Duration(microseconds: 16667));
      expect(game.isIdleThrottled, isFalse);
    });

    testWidgets('a touch, when idleFps was set in onLoad', (tester) async {
      final game = _IdleFromOnLoadGame();
      await tester.pumpWidget(GameWidget(game: game));
      await tester.pump();
      await _runSeconds(tester, 2);
      expect(game.isIdleThrottled, isTrue);

      await tester.tapAt(const Offset(50, 50));
      await tester.pump(const Duration(microseconds: 16667));
      expect(game.isIdleThrottled, isFalse);
    });

    testWidgets(
      'a touch resumes a game that was suspended with idleFps = 0 long after '
      'the widget was built',
      (tester) async {
        final game = _CountingGame();
        await tester.pumpWidget(GameWidget(game: game));
        await tester.pump();
        await _runSeconds(tester, 1);

        // For example a battery saver setting that is switched on later.
        game
          ..idleFps = 0
          ..idleTimeoutSeconds = 0.5;
        await _runSeconds(tester, 1);
        expect(game.isIdleThrottled, isTrue);
        final suspendedAt = game.updates;
        await _runSeconds(tester, 1);
        expect(game.updates, suspendedAt, reason: 'the loop is suspended');

        await tester.tapAt(const Offset(50, 50));
        await _runSeconds(tester, 0.25);
        expect(game.isIdleThrottled, isFalse);
        expect(game.updates, greaterThan(suspendedAt + 10));
      },
    );

    testWidgets('a moving finger', (tester) async {
      final game = _CountingGame()
        ..idleFps = 10
        ..idleTimeoutSeconds = 1.0;
      await tester.pumpWidget(GameWidget(game: game));
      await tester.pump();

      final gesture = await tester.startGesture(const Offset(50, 50));
      for (var i = 0; i < 180; i++) {
        await gesture.moveBy(const Offset(1, 0));
        await tester.pump(const Duration(microseconds: 16667));
      }
      expect(game.isIdleThrottled, isFalse);
      await gesture.up();
    });

    testWidgets('a hovering mouse', (tester) async {
      final game = _CountingGame()
        ..idleFps = 10
        ..idleTimeoutSeconds = 1.0;
      await tester.pumpWidget(GameWidget(game: game));
      await tester.pump();
      await _runSeconds(tester, 2);
      expect(game.isIdleThrottled, isTrue);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(40, 40));
      addTearDown(mouse.removePointer);
      await mouse.moveTo(const Offset(60, 60));
      await tester.pump(const Duration(microseconds: 16667));
      expect(game.isIdleThrottled, isFalse);
    });

    testWidgets('a key press', (tester) async {
      final game = _KeyGame()
        ..idleFps = 10
        ..idleTimeoutSeconds = 1.0;
      await tester.pumpWidget(GameWidget(game: game));
      await tester.pump();
      await _runSeconds(tester, 2);
      expect(game.isIdleThrottled, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.pump(const Duration(microseconds: 16667));
      expect(game.keyEvents, greaterThan(0));
      expect(game.isIdleThrottled, isFalse);
    });

    testWidgets('a touch on an overlay does not count', (tester) async {
      final game = _CountingGame()
        ..idleFps = 10
        ..idleTimeoutSeconds = 1.0;
      game.overlays
        ..addEntry(
          'panel',
          (context, game) => const Positioned(
            left: 0,
            top: 0,
            width: 100,
            height: 100,
            child: AbsorbPointer(child: SizedBox.expand()),
          ),
        )
        ..add('panel');
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: GameWidget(game: game),
        ),
      );
      await tester.pump();
      await _runSeconds(tester, 2);
      expect(game.isIdleThrottled, isTrue);

      // Consumed by the overlay: the game does not see it.
      await tester.tapAt(const Offset(50, 50));
      await tester.pump(const Duration(microseconds: 16667));
      expect(game.isIdleThrottled, isTrue);

      // Outside the overlay the game is hit.
      await tester.tapAt(const Offset(300, 300));
      await tester.pump(const Duration(microseconds: 16667));
      expect(game.isIdleThrottled, isFalse);
    });
  });
}
