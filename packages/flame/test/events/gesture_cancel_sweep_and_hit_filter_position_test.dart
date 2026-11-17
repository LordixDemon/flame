import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flame/game.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

class _Pressable({
  required super.position,
  required super.size,
}) extends PositionComponent
    with TapCallbacks, DragCallbacks, LongPressCallbacks, DoubleTapCallbacks {
  int tapDowns = 0;
  int tapCancels = 0;
  int dragStarts = 0;
  int dragCancels = 0;
  int dragEnds = 0;
  int doubleTapDowns = 0;
  int doubleTapCancels = 0;
  int doubleTapUps = 0;

  @override
  void onTapDown(TapDownEvent event) => tapDowns++;

  @override
  void onTapCancel(TapCancelEvent event) => tapCancels++;

  @override
  void onDragStart(DragStartEvent event) {
    super.onDragStart(event);
    dragStarts++;
  }

  @override
  void onDragCancel(DragCancelEvent event) {
    super.onDragCancel(event);
    dragCancels++;
  }

  @override
  void onDragEnd(DragEndEvent event) {
    super.onDragEnd(event);
    dragEnds++;
  }

  @override
  void onDoubleTapDown(DoubleTapDownEvent event) => doubleTapDowns++;

  @override
  void onDoubleTapCancel(DoubleTapCancelEvent event) => doubleTapCancels++;

  @override
  void onDoubleTapUp(DoubleTapEvent event) => doubleTapUps++;
}

class _Draggable({
  required super.position,
  required super.size,
}) extends PositionComponent with DragCallbacks {
  int updates = 0;

  @override
  void onDragUpdate(DragUpdateEvent event) => updates++;
}

Future<FlameGame> _pumpGame(WidgetTester tester, Component hud) async {
  final game = FlameGame();
  game.camera.viewport.add(hud);
  await tester.pumpWidget(GameWidget(game: game));
  await tester.pump();
  await tester.pump();
  return game;
}

void main() {
  group('cancelActivePointerGestures', () {
    testWidgets('cancels the tap and the drag of a component that was removed '
        'while it held them', (tester) async {
      final button = _Pressable(
        position: Vector2(100, 100),
        size: Vector2(200, 200),
      );
      final game = await _pumpGame(tester, button);

      final gesture = await tester.startGesture(const Offset(200, 200));
      await tester.pump();
      expect(button.tapDowns, 1);
      await gesture.moveTo(const Offset(260, 200));
      await tester.pump();
      expect(button.dragStarts, 1);
      expect(button.isDragged, isTrue);

      // A second press that stays a tap.
      final tap = await tester.startGesture(
        const Offset(150, 150),
        pointer: 77,
      );
      await tester.pump();
      expect(button.tapDowns, 2);
      final tapCancelsBefore = button.tapCancels;

      // The component leaves the tree mid-gesture, then the app loses focus
      // before the pointers move again.
      button.removeFromParent();
      await tester.pump();
      expect(button.isMounted, isFalse);

      game.cancelActivePointerGestures();
      expect(button.dragCancels, 1);
      expect(button.isDragged, isFalse);
      expect(button.tapCancels, tapCancelsBefore + 1);

      // The pointers are still down; lifting them delivers nothing further.
      await gesture.up();
      await tap.up();
      await tester.pump(const Duration(milliseconds: 500));
      expect(button.dragCancels, 1);
      expect(button.dragEnds, 0);
      expect(button.tapCancels, tapCancelsBefore + 1);
    });

    testWidgets('cancels a double tap that is pressed but not released', (
      tester,
    ) async {
      final button = _Pressable(
        position: Vector2(100, 100),
        size: Vector2(200, 200),
      );
      final game = await _pumpGame(tester, button);

      await tester.tapAt(const Offset(200, 200));
      await tester.pump(kDoubleTapMinTime);
      final second = await tester.startGesture(const Offset(200, 200));
      await tester.pump();
      expect(button.doubleTapDowns, 1);

      game.cancelActivePointerGestures();
      expect(button.doubleTapCancels, 1);

      await second.up();
      await tester.pump(const Duration(milliseconds: 500));
      expect(button.doubleTapCancels, 1);
      expect(button.doubleTapUps, 0);
    });
  });

  group('InputHitFilter position', () {
    testWidgets('drag updates report where the pointer is, not where it '
        'would be one more delta ahead', (tester) async {
      final card = _Draggable(
        position: Vector2(100, 100),
        size: Vector2(600, 400),
      );
      final game = await _pumpGame(tester, card);

      final seen = <Vector2>[];
      bool filter(Component candidate, Vector2? canvasPosition) {
        if (identical(candidate, card) && canvasPosition != null) {
          seen.add(canvasPosition.clone());
        }
        return true;
      }

      final gesture = await tester.startGesture(const Offset(200, 300));
      await tester.pump();
      game.pushInputHitFilter(filter);

      // The first update carries the movement accumulated up to the slop.
      await gesture.moveTo(const Offset(260, 300));
      await tester.pump();
      await gesture.moveTo(const Offset(300, 300));
      await tester.pump();
      await gesture.moveTo(const Offset(380, 320));
      await tester.pump();

      expect(card.updates, greaterThanOrEqualTo(3));
      expect(seen, isNotEmpty);
      expect(seen.last.x, closeTo(380, 1e-6));
      expect(seen.last.y, closeTo(320, 1e-6));
      // Every reported position is one the pointer actually visited.
      const visited = <double>[200, 260, 300, 380];
      for (final position in seen) {
        expect(visited, contains(position.x));
      }

      expect(game.popInputHitFilter(filter), same(filter));
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 500));
    });
  });
}
