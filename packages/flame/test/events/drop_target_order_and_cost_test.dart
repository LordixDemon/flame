import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flame/game.dart';
import 'package:flutter_test/flutter_test.dart';

class _Card({
  required super.position,
  required super.size,
}) extends PositionComponent with DragCallbacks {
  /// Set by the slot that accepts this card, read back in [onDragEnd].
  bool acceptedBySlot = false;
  bool? acceptedSeenInDragEnd;
  DragEndEvent? lastEnd;
  final List<String> log = <String>[];

  @override
  void onDragStart(DragStartEvent event) {
    super.onDragStart(event);
    acceptedBySlot = false;
  }

  @override
  void onDragEnd(DragEndEvent event) {
    super.onDragEnd(event);
    log.add('card.onDragEnd');
    acceptedSeenInDragEnd = acceptedBySlot;
    lastEnd = event;
  }

  @override
  void onDragCancel(DragCancelEvent event) {
    super.onDragCancel(event);
    log.add('card.onDragCancel');
  }
}

class _Slot({
  required super.position,
  required super.size,
  this.accepts = true,
}) extends PositionComponent with DropTargetCallbacks {
  final bool accepts;
  int enters = 0;
  int leaves = 0;
  int drops = 0;
  int cancels = 0;

  @override
  bool canAcceptDrop(Component dragged, DragDropEvent event) => accepts;

  @override
  void onDragTargetEnter(DragDropEvent event) => enters++;

  @override
  void onDragTargetLeave(DragDropEvent event) => leaves++;

  @override
  void onDrop(DragDropEvent event) {
    drops++;
    final dragged = event.draggedComponent;
    if (dragged is _Card) {
      dragged.log.add('slot.onDrop');
      dragged.acceptedBySlot = true;
    }
  }

  @override
  void onDragTargetCancel(DragDropEvent event) {
    cancels++;
    final dragged = event.draggedComponent;
    if (dragged is _Card) {
      dragged.log.add('slot.onDragTargetCancel');
    }
  }
}

class _PanSurface() extends PositionComponent with DragCallbacks {
  this : super(size: Vector2(800, 600));

  int updates = 0;

  @override
  void onDragUpdate(DragUpdateEvent event) => updates++;
}

/// Counts how often the tree is point-hit-tested through it.
class _Probe() extends PositionComponent {
  this : super(size: Vector2(800, 600));

  int hitTests = 0;

  @override
  bool containsLocalPoint(Vector2 point) {
    hitTests++;
    return super.containsLocalPoint(point);
  }
}

Future<FlameGame> _pumpGame(
  WidgetTester tester, {
  List<Component> hud = const [],
  List<Component> world = const [],
}) async {
  final game = FlameGame();
  game.world.addAll(world);
  game.camera.viewport.addAll(hud);
  await tester.pumpWidget(GameWidget(game: game));
  await tester.pump();
  await tester.pump();
  return game;
}

MultiDragScaleDispatcher _dispatcherOf(FlameGame game) =>
    game.findByKey(const MultiDragScaleDispatcherKey())!
        as MultiDragScaleDispatcher;

void main() {
  group('drop target resolution order', () {
    testWidgets('the target gets onDrop before the dragged component gets '
        'onDragEnd, which sees the outcome', (tester) async {
      final card = _Card(position: Vector2(180, 280), size: Vector2(40, 40));
      final slot = _Slot(position: Vector2(450, 250), size: Vector2(100, 100));
      await _pumpGame(tester, hud: [slot, card]);

      final gesture = await tester.startGesture(const Offset(200, 300));
      await tester.pump();
      await gesture.moveTo(const Offset(350, 300));
      await tester.pump();
      await gesture.moveTo(const Offset(500, 300));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(card.log, <String>['slot.onDrop', 'card.onDragEnd']);
      expect(card.acceptedSeenInDragEnd, isTrue);
      expect(card.lastEnd!.dropAccepted, isTrue);
      expect(card.lastEnd!.dropTarget, same(slot));
      expect(card.lastEnd!.dropEvent!.draggedComponent, same(card));
      expect(card.lastEnd!.wasCancelled, isFalse);
      expect(slot.enters, 1);
      expect(slot.drops, 1);
      expect(slot.leaves, 0);
      await tester.pump(const Duration(milliseconds: 500));
    });

    testWidgets('a release over nothing, or over a target that refuses, '
        'reports no drop', (tester) async {
      final card = _Card(position: Vector2(180, 280), size: Vector2(40, 40));
      final refusing = _Slot(
        position: Vector2(450, 250),
        size: Vector2(100, 100),
        accepts: false,
      );
      await _pumpGame(tester, hud: [refusing, card]);

      final gesture = await tester.startGesture(const Offset(200, 300));
      await tester.pump();
      await gesture.moveTo(const Offset(350, 300));
      await tester.pump();
      await gesture.moveTo(const Offset(500, 300));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(card.log, <String>['card.onDragEnd']);
      expect(card.lastEnd!.dropAccepted, isFalse);
      expect(card.lastEnd!.dropTarget, isNull);
      expect(card.lastEnd!.dropEvent, isNull);
      expect(refusing.enters, 0);
      expect(refusing.drops, 0);
      await tester.pump(const Duration(milliseconds: 500));
    });

    testWidgets('a cancelled drag drops nothing: the hovered target is told '
        'first, then the dragged component', (tester) async {
      final card = _Card(position: Vector2(180, 280), size: Vector2(40, 40));
      final slot = _Slot(position: Vector2(450, 250), size: Vector2(100, 100));
      await _pumpGame(tester, hud: [slot, card]);

      final gesture = await tester.startGesture(const Offset(200, 300));
      await tester.pump();
      await gesture.moveTo(const Offset(350, 300));
      await tester.pump();
      await gesture.moveTo(const Offset(500, 300));
      await tester.pump();
      expect(slot.enters, 1);

      await gesture.cancel();
      await tester.pump();

      expect(card.log, <String>[
        'slot.onDragTargetCancel',
        'card.onDragCancel',
      ]);
      expect(slot.drops, 0);
      expect(slot.cancels, 1);
      expect(card.acceptedBySlot, isFalse);
      await tester.pump(const Duration(milliseconds: 500));
    });

    test('a drag end converted from a cancellation carries no drop', () {
      final end = DragCancelEvent(7).toDragEnd();
      expect(end.pointerId, 7);
      expect(end.wasCancelled, isTrue);
      expect(end.dropAccepted, isFalse);
      expect(end.dropTarget, isNull);
      expect(end.velocity, Vector2.zero());
    });
  });

  group('drop target resolution cost', () {
    Future<int> hitTestsDuringTwentyUpdates(
      WidgetTester tester,
      _PanSurface surface,
      List<_Probe> probes,
    ) async {
      final gesture = await tester.startGesture(const Offset(200, 300));
      await tester.pump();
      await gesture.moveTo(const Offset(260, 300));
      await tester.pump();
      final updatesBefore = surface.updates;
      final hitTestsBefore = probes.fold<int>(0, (s, p) => s + p.hitTests);

      for (var i = 1; i <= 20; i++) {
        await gesture.moveTo(Offset(260.0 + i * 5, 300));
      }
      await tester.pump();
      expect(surface.updates - updatesBefore, 20);
      final hitTests =
          probes.fold<int>(0, (s, p) => s + p.hitTests) - hitTestsBefore;

      await gesture.up();
      await tester.pump(const Duration(milliseconds: 500));
      return hitTests;
    }

    testWidgets('drag updates do not point-hit-test the tree when the game '
        'has no drop target', (tester) async {
      final surface = _PanSurface();
      final probes = [for (var i = 0; i < 50; i++) _Probe()];
      final game = await _pumpGame(tester, hud: [surface], world: probes);
      expect(_dispatcherOf(game).mountedDropTargetCount, 0);

      expect(await hitTestsDuringTwentyUpdates(tester, surface, probes), 0);
    });

    testWidgets('a drag that is not a drop payload does not point-hit-test '
        'the tree even with drop targets mounted', (tester) async {
      final surface = _PanSurface()..isDropPayload = false;
      final probes = [for (var i = 0; i < 50; i++) _Probe()];
      final slot = _Slot(position: Vector2(250, 250), size: Vector2(300, 100));
      final game = await _pumpGame(
        tester,
        hud: [slot, surface],
        world: probes,
      );
      expect(_dispatcherOf(game).mountedDropTargetCount, 1);

      expect(await hitTestsDuringTwentyUpdates(tester, surface, probes), 0);
      expect(slot.enters, 0);
      expect(slot.drops, 0);
    });

    testWidgets('a payload drag still finds its drop target, and the count '
        'of mounted targets follows mounting and removal', (tester) async {
      final surface = _PanSurface();
      final probes = [for (var i = 0; i < 5; i++) _Probe()];
      final slot = _Slot(position: Vector2(250, 250), size: Vector2(300, 100));
      final game = await _pumpGame(
        tester,
        hud: [slot, surface],
        world: probes,
      );
      final dispatcher = _dispatcherOf(game);
      expect(dispatcher.mountedDropTargetCount, 1);

      await hitTestsDuringTwentyUpdates(tester, surface, probes);
      expect(slot.enters, 1);
      expect(slot.drops, 1);

      slot.removeFromParent();
      await tester.pump();
      expect(dispatcher.mountedDropTargetCount, 0);
      expect(await hitTestsDuringTwentyUpdates(tester, surface, probes), 0);

      game.camera.viewport.add(slot);
      await tester.pump();
      await tester.pump();
      expect(dispatcher.mountedDropTargetCount, 1);
    });
  });
}
