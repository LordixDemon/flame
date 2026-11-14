import 'package:flame/camera.dart';
import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flame/game.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

class _AccessibleHudButton({
  required String label,
  super.position,
  super.size,
}) extends PositionComponent with SemanticsComponent {
  int semanticTaps = 0;

  this {
    semanticsLabel = label;
    semanticsValue = 'Ready';
    isSemanticsButton = true;
    onSemanticsTap = () => semanticTaps++;
  }
}

class _AccessibleWorldTile({
  required String label,
  super.position,
  super.size,
}) extends PositionComponent with SemanticsComponent {
  int level = 1;

  this {
    semanticsLabel = label;
    isSemanticsSelected = true;
    onSemanticsIncrease = () {
      level++;
      semanticsValue = 'Level $level';
    };
  }
}

class _StylusCanvasComponent({
  super.size,
}) extends PositionComponent with TapCallbacks, DragCallbacks {
  TapDownEvent? lastTapDown;
  DragStartEvent? lastDragStart;
  DragUpdateEvent? lastDragUpdate;
  int tapCancelCount = 0;
  int dragCancelCount = 0;

  @override
  void onTapDown(TapDownEvent event) {
    lastTapDown = event;
  }

  @override
  void onTapCancel(TapCancelEvent event) {
    tapCancelCount++;
  }

  @override
  void onDragStart(DragStartEvent event) {
    super.onDragStart(event);
    lastDragStart = event;
  }

  @override
  void onDragUpdate(DragUpdateEvent event) {
    lastDragUpdate = event;
  }

  @override
  void onDragCancel(DragCancelEvent event) {
    super.onDragCancel(event);
    dragCancelCount++;
  }
}

void main() {
  group('Wave 7 — Subsystems 8–9: SemanticsComponent Accessibility Bridge & '
      'Pointer Hardware Telemetry / OS Blur Cancel', () {
    testWidgets(
      'Subsystem 8: SemanticsComponent projects HUD and World nodes into '
      'Flutter SemanticsNode tree, dispatches actions, and culls offscreen',
      (tester) async {
        final world = World();
        final camera = CameraComponent.withFixedResolution(
          width: 400,
          height: 300,
          world: world,
          viewfinder: Viewfinder()..anchor = Anchor.topLeft,
        );
        final game = FlameGame(world: world, camera: camera);

        final rollBtn = _AccessibleHudButton(
          label: 'Roll Dice',
          position: Vector2(20, 240),
          size: Vector2(120, 44),
        );
        final boardTile = _AccessibleWorldTile(
          label: 'Grand Plaza',
          position: Vector2(100, 80),
          size: Vector2(60, 60),
        );

        camera.viewport.add(rollBtn);
        world.add(boardTile);

        final semanticsHandle = tester.ensureSemantics();

        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox(
              width: 400,
              height: 300,
              child: GameWidget(game: game),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 16));

        expect(find.semantics.byLabel('Roll Dice'), findsOne);
        expect(find.semantics.byLabel('Grand Plaza'), findsOne);

        final btnNode = find.semantics.byLabel('Roll Dice').evaluate().single;
        expect(
          btnNode.getSemanticsData().flagsCollection.isButton,
          isTrue,
        );
        expect(btnNode.value, 'Ready');

        // Perform accessibility SemanticsAction.tap & SemanticsAction.increase!
        tester.semantics.tap(find.semantics.byLabel('Roll Dice'));
        expect(rollBtn.semanticTaps, 1);

        tester.semantics.performAction(
          find.semantics.byLabel('Grand Plaza'),
          SemanticsAction.increase,
        );
        await tester.pump();
        expect(boardTile.level, 2);
        expect(
          find.semantics.byLabel('Grand Plaza').evaluate().single.value,
          'Level 2',
        );

        // Pan camera far away -> offscreen world SemanticsComponent is culled,
        // while HUD button stays in the accessibility tree!
        camera.viewfinder.position = Vector2(5000, 5000);
        await tester.pump(const Duration(milliseconds: 16));
        expect(find.semantics.byLabel('Roll Dice'), findsOne);
        expect(find.semantics.byLabel('Grand Plaza'), findsNothing);

        semanticsHandle.dispose();
      },
    );

    testWidgets(
      'Subsystem 9: Stylus pressure/tilt/orientation/buttons propagate into '
      'TapDownEvent & DragUpdateEvent, and OS blur cancels active gestures',
      (tester) async {
        final game = FlameGame();
        final surface = _StylusCanvasComponent(size: Vector2(400, 300));
        game.add(surface);

        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox(
              width: 400,
              height: 300,
              child: GameWidget(game: game),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 16));
        await tester.pump(const Duration(milliseconds: 16));

        // 1. Stylus tap -> verifies pressure, tilt, orientation, deviceKind &
        // buttons on TapDownEvent!
        const stylusTapDown = PointerDownEvent(
          pointer: 10,
          kind: PointerDeviceKind.stylus,
          position: Offset(60, 70),
          pressure: 0.72,
          tilt: 0.41,
          orientation: -0.85,
        );
        const stylusTapUp = PointerUpEvent(
          pointer: 10,
          kind: PointerDeviceKind.stylus,
          position: Offset(60, 70),
        );
        tester.binding.handlePointerEvent(stylusTapDown);
        tester.binding.handlePointerEvent(stylusTapUp);
        await tester.pump(const Duration(milliseconds: 300));

        expect(surface.lastTapDown, isNotNull);
        expect(surface.lastTapDown!.deviceKind, PointerDeviceKind.stylus);
        expect(surface.lastTapDown!.isStylus, isTrue);
        expect(surface.lastTapDown!.pressure, closeTo(0.72, 1e-6));
        expect(surface.lastTapDown!.tilt, closeTo(0.41, 1e-6));
        expect(surface.lastTapDown!.orientation, closeTo(-0.85, 1e-6));
        expect(surface.lastTapDown!.buttons, kPrimaryButton);

        // 2. Stylus drag -> verifies live stroke pressure, tilt, orientation!
        const stylusDown = PointerDownEvent(
          pointer: 11,
          kind: PointerDeviceKind.stylus,
          position: Offset(60, 70),
          pressure: 0.65,
          tilt: 0.30,
          orientation: -0.85,
        );
        const stylusMove = PointerMoveEvent(
          pointer: 11,
          kind: PointerDeviceKind.stylus,
          position: Offset(120, 110),
          delta: Offset(60, 40),
          pressure: 0.88,
          tilt: 0.55,
          orientation: -0.60,
        );

        tester.binding.handlePointerEvent(stylusDown);
        await tester.pump(const Duration(milliseconds: 16));
        tester.binding.handlePointerEvent(stylusMove);
        await tester.pump(const Duration(milliseconds: 16));

        expect(surface.lastDragUpdate, isNotNull);
        expect(surface.lastDragUpdate!.deviceKind, PointerDeviceKind.stylus);
        expect(surface.lastDragUpdate!.isStylus, isTrue);
        expect(surface.lastDragUpdate!.pressure, closeTo(0.88, 1e-6));
        expect(surface.lastDragUpdate!.tilt, closeTo(0.55, 1e-6));
        expect(surface.lastDragUpdate!.orientation, closeTo(-0.60, 1e-6));
        expect(surface.lastDragUpdate!.buttons, kPrimaryButton);

        // 3. Simulate Alt-Tab / incoming call (AppLifecycleState.inactive)
        // while pointer 11 is held mid-drag -> deterministic drag cancel!
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        await tester.pump();
        expect(surface.dragCancelCount, 1);

        tester.binding.handlePointerEvent(
          const PointerUpEvent(
            pointer: 11,
            kind: PointerDeviceKind.stylus,
            position: Offset(120, 110),
          ),
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();

        // 4. Hold pointer past kPressTimeout so TapDown is active, then blur
        // (AppLifecycleState.hidden) -> deterministic tap cancel!
        tester.binding.handlePointerEvent(
          const PointerDownEvent(
            pointer: 12,
            position: Offset(50, 50),
          ),
        );
        await tester.pump(const Duration(milliseconds: 150));
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.hidden,
        );
        await tester.pump();
        expect(surface.tapCancelCount, greaterThanOrEqualTo(1));

        tester.binding.handlePointerEvent(
          const PointerUpEvent(
            pointer: 12,
            position: Offset(50, 50),
          ),
        );
      },
    );
  });
}
