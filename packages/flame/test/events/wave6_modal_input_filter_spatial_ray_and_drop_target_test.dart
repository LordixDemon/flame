import 'package:flame/canvas3d.dart';
import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flame/game.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

class _InteractiveButton({
  required super.position,
  required super.size,
}) extends PositionComponent with TapCallbacks, HoverCallbacks, DragCallbacks {
  int tapDownCount = 0;
  int tapUpCount = 0;
  int hoverEnterCount = 0;
  int dragStartCount = 0;

  @override
  void onTapDown(TapDownEvent event) => tapDownCount++;

  @override
  void onTapUp(TapUpEvent event) => tapUpCount++;

  @override
  void onHoverEnter() => hoverEnterCount++;

  @override
  void onDragStart(DragStartEvent event) {
    super.onDragStart(event);
    dragStartCount++;
  }
}

class _PassthroughFlameGame({
  super.children,
}) extends FlameGame with DeferHitTestToComponents {
  @override
  Color backgroundColor() => const Color(0x00000000);
}

class _SpatialBoardTile3D({
  required this.centerX,
  required this.topZ,
  this.halfSize = 1.5,
  this.sphereRadius = 2.6,
  this.acceptDrops = true,
}) extends Component with SpatialHitbox3D, TapCallbacks, DropTargetCallbacks {
  final double centerX;
  final double topZ;
  final double halfSize;
  final double sphereRadius;
  final bool acceptDrops;

  int narrowphaseCalls = 0;
  int tapDownCount = 0;
  int tapUpCount = 0;
  int enterCount = 0;
  int moveCount = 0;
  int leaveCount = 0;
  int dropCount = 0;
  int cancelCount = 0;
  DragDropEvent? lastDropEvent;

  @override
  (double, double, double, double)? get boundingSphere3D =>
      (centerX, 0.0, topZ - 0.5, sphereRadius);

  @override
  double? intersectRay3D(Ray3D ray) {
    narrowphaseCalls++;
    return intersectWorldAabb3D(
      ray,
      minX: centerX - halfSize,
      minY: -halfSize,
      minZ: topZ - 1.0,
      maxX: centerX + halfSize,
      maxY: halfSize,
      maxZ: topZ,
    );
  }

  @override
  void onTapDown(TapDownEvent event) => tapDownCount++;

  @override
  void onTapUp(TapUpEvent event) => tapUpCount++;

  @override
  bool canAcceptDrop(Component dragged, DragDropEvent event) => acceptDrops;

  @override
  void onDragTargetEnter(DragDropEvent event) {
    enterCount++;
    lastDropEvent = event;
  }

  @override
  void onDragTargetMove(DragDropEvent event) {
    moveCount++;
    lastDropEvent = event;
  }

  @override
  void onDragTargetLeave(DragDropEvent event) {
    leaveCount++;
  }

  @override
  void onDrop(DragDropEvent event) {
    dropCount++;
    lastDropEvent = event;
  }

  @override
  void onDragTargetCancel(DragDropEvent event) {
    cancelCount++;
  }
}

class _DraggableHudCard({
  required super.position,
  required super.size,
}) extends PositionComponent with DragCallbacks, DropTargetCallbacks {
  int selfDropEnterCount = 0;
  int selfDropCount = 0;

  @override
  void onDragUpdate(DragUpdateEvent event) {
    position.add(event.localDelta);
  }

  @override
  void onDragTargetEnter(DragDropEvent event) => selfDropEnterCount++;

  @override
  void onDrop(DragDropEvent event) => selfDropCount++;
}

void main() {
  group('Wave 6 — Modal InputHitFilter Stack, O(k) SpatialHitbox3D Ray '
      'Broadphase & Cross-Layer DropTargetCallbacks', () {
    testWidgets(
      'Unlock #6a: Modal pushInputHitFilter / popInputHitFilter stack gates '
      'taps, hovers, drags, and DeferHitTestToComponents passthrough',
      (tester) async {
        var backgroundWidgetTaps = 0;
        final spotlightBtn = _InteractiveButton(
          position: Vector2(40, 40),
          size: Vector2(100, 100),
        );
        final blockedBtn = _InteractiveButton(
          position: Vector2(240, 40),
          size: Vector2(100, 100),
        );
        final game = _PassthroughFlameGame(
          children: [spotlightBtn, blockedBtn],
        );

        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => backgroundWidgetTaps++,
                    child: const SizedBox.expand(),
                  ),
                ),
                Positioned.fill(
                  child: GameWidget(
                    game: game,
                    behavior: HitTestBehavior.deferToChild,
                  ),
                ),
              ],
            ),
          ),
        );
        await tester.pump();
        await tester.pump();

        // Push modal filter 1: spotlight ONLY spotlightBtn!
        bool allowOnlySpotlight(Component c, Vector2? _) =>
            identical(c, spotlightBtn);
        game.pushInputHitFilter(allowOnlySpotlight);
        expect(game.inputHitFilterStackDepth, 1);
        expect(game.containsEventHandlerAt(Vector2(90, 90)), isTrue);
        expect(game.containsEventHandlerAt(Vector2(290, 90)), isFalse);

        // Hover + tap + drag over blockedBtn (290, 90): blocked in Flame AND
        // tap passes through DeferHitTestToComponents to background widget!
        final mouse = TestPointer(7, PointerDeviceKind.mouse);
        await tester.sendEventToBinding(mouse.hover(const Offset(290, 90)));
        expect(blockedBtn.hoverEnterCount, 0);

        await tester.tapAt(const Offset(290, 90));
        await tester.pump();
        expect(blockedBtn.tapDownCount, 0);
        expect(backgroundWidgetTaps, 1);

        await tester.dragFrom(const Offset(290, 90), const Offset(40, 0));
        await tester.pump();
        expect(blockedBtn.dragStartCount, 0);

        // Hover + tap + drag over spotlightBtn (90, 90): permitted!
        await tester.sendEventToBinding(mouse.hover(const Offset(90, 90)));
        expect(spotlightBtn.hoverEnterCount, 1);

        await tester.tapAt(const Offset(90, 90));
        await tester.pump();
        expect(spotlightBtn.tapDownCount, 1);
        expect(spotlightBtn.tapUpCount, 1);
        expect(backgroundWidgetTaps, 1);

        await tester.dragFrom(const Offset(90, 90), const Offset(40, 0));
        await tester.pump();
        expect(spotlightBtn.dragStartCount, 1);
        expect(spotlightBtn.tapDownCount, 2); // initial down before drag slop
        expect(spotlightBtn.tapUpCount, 1); // cancelled on drag, no tapUp!

        // Push nested modal filter 2: swap spotlight to blockedBtn!
        game.pushInputHitFilter((c, _) => identical(c, blockedBtn));
        expect(game.inputHitFilterStackDepth, 2);

        await tester.tapAt(const Offset(90, 90));
        await tester.pump();
        expect(spotlightBtn.tapDownCount, 2); // blocked by top filter!
        expect(spotlightBtn.tapUpCount, 1);
        expect(backgroundWidgetTaps, 2);

        await tester.tapAt(const Offset(290, 90));
        await tester.pump();
        expect(blockedBtn.tapDownCount, 1); // allowed by top filter!
        expect(blockedBtn.tapUpCount, 1);

        // Pop filter 2 -> restores filter 1!
        game.popInputHitFilter();
        expect(game.inputHitFilterStackDepth, 1);
        await tester.tapAt(const Offset(90, 90));
        await tester.pump();
        expect(spotlightBtn.tapDownCount, 3);
        expect(spotlightBtn.tapUpCount, 2);

        // Clear all filters -> both buttons interactive!
        game.clearInputHitFilters();
        expect(game.inputHitFilterStackDepth, 0);
        await tester.tapAt(const Offset(290, 90));
        await tester.pump();
        expect(blockedBtn.tapDownCount, 2);
        expect(blockedBtn.tapUpCount, 2);
        await tester.pump(const Duration(milliseconds: 500));
      },
    );

    testWidgets(
      'Unlock #6b: O(k) World.spatialHitboxes3D registry & boundingSphere3D '
      'broadphase prune 500 non-3D props and non-intersecting 3D meshes',
      (tester) async {
        final world = World();
        for (var i = 0; i < 500; i++) {
          world.add(
            PositionComponent(
              position: Vector2((i % 25) * 10.0, (i ~/ 25) * 10.0),
              size: Vector2.all(8),
            ),
          );
        }

        final tileFarLeft = _SpatialBoardTile3D(centerX: -12.0, topZ: 1.0);
        final tileHitCenter = _SpatialBoardTile3D(centerX: 0.0, topZ: 1.0);
        final tileFarRight1 = _SpatialBoardTile3D(centerX: 12.0, topZ: 1.0);
        final tileFarRight2 = _SpatialBoardTile3D(centerX: 24.0, topZ: 1.0);
        world.addAll([
          tileFarLeft,
          tileHitCenter,
          tileFarRight1,
          tileFarRight2,
        ]);

        // Map viewport X (0..800, center 400 -> worldX 0) at 20px per 3D unit
        // into a vertical downward 3D ray!
        final camera = CameraComponent(world: world)
          ..rayProjector3D = (viewportPt, _) {
            final wx = (viewportPt.x - 400.0) / 20.0;
            final wy = (viewportPt.y - 300.0) / 20.0;
            return Ray3D(
              ox: wx,
              oy: wy,
              oz: 10.0,
              dx: 0.0,
              dy: 0.0,
              dz: -1.0,
            );
          };

        final game = FlameGame(world: world, camera: camera);
        await tester.pumpWidget(GameWidget(game: game));
        await tester.pump();
        await tester.pump();

        expect(world.registeredSpatialHitbox3DCount, 4);

        // Tap at viewport center (400, 300) -> ray at (0, 0, 10) straight down!
        await tester.tapAt(const Offset(400, 300));
        await tester.pump();

        // O(k): tested ONLY the 4 registered 3D hitboxes (NOT 504 world
        // children!), and boundingSphere3D pruned 3 of the 4 so narrowphase
        // ran ONCE per pointer event (1 on TapDown + 1 on TapUp = 2 total)!
        expect(camera.lastSpatialRayCandidatesTested, 4);
        expect(camera.lastSpatialRayNarrowphaseTests, 1);
        expect(tileHitCenter.narrowphaseCalls, 2);
        expect(tileFarLeft.narrowphaseCalls, 0);
        expect(tileFarRight1.narrowphaseCalls, 0);
        expect(tileFarRight2.narrowphaseCalls, 0);
        expect(tileHitCenter.tapDownCount, 1);
        expect(tileHitCenter.tapUpCount, 1);
        expect(tileHitCenter.lastHitPoint3D!.$3, closeTo(1.0, 1e-5));

        // Unmounting 2 3D tiles updates World.registeredSpatialHitbox3DCount!
        tileFarRight1.removeFromParent();
        tileFarRight2.removeFromParent();
        await tester.pump();
        expect(world.registeredSpatialHitbox3DCount, 2);
        await tester.pump(const Duration(milliseconds: 500));
      },
    );

    testWidgets(
      'Unlock #6c: Cross-layer DropTargetCallbacks delivers enter, move, '
      'leave, drop & cancel from HUD DragCallbacks onto 3D SpatialHitbox3D '
      'board tiles with self-exclusion and canAcceptDrop passthrough',
      (tester) async {
        final tileLeft = _SpatialBoardTile3D(
          centerX: -4.0,
          topZ: 0.0,
          halfSize: 2.0,
          sphereRadius: 4.0,
        );
        // Upper locked shield at X = +4, Z = 2.0 rejects drops -> must pass
        // through to tileRightAccept underneath at Z = 0.0!
        final tileRightLockedUpper = _SpatialBoardTile3D(
          centerX: 4.0,
          topZ: 2.0,
          halfSize: 2.0,
          sphereRadius: 4.0,
          acceptDrops: false,
        );
        final tileRightAccept = _SpatialBoardTile3D(
          centerX: 4.0,
          topZ: 0.0,
          halfSize: 2.0,
          sphereRadius: 4.0,
        );

        final world = World(
          children: [tileLeft, tileRightLockedUpper, tileRightAccept],
        );
        final camera = CameraComponent(world: world)
          ..rayProjector3D = (viewportPt, _) {
            final wx = (viewportPt.x - 400.0) / 25.0;
            final wy = (viewportPt.y - 300.0) / 25.0;
            return Ray3D(
              ox: wx,
              oy: wy,
              oz: 10.0,
              dx: 0.0,
              dy: 0.0,
              dz: -1.0,
            );
          };

        // HUD card starts at viewport (180, 280), size 40x40 (center 200, 300:
        // wx = -8.0, outside both tiles). It also mixes DropTargetCallbacks to
        // verify it never intercepts drops onto itself while dragged!
        final hudCard = _DraggableHudCard(
          position: Vector2(180, 280),
          size: Vector2(40, 40),
        );
        camera.viewport.add(hudCard);

        final game = FlameGame(world: world, camera: camera);
        await tester.pumpWidget(GameWidget(game: game));
        await tester.pump();
        await tester.pump();

        // 1. Start drag on HUD card at (200, 300), drag onto tileLeft at
        //    (300, 300 -> wx = -4.0), nudge on tileLeft, then drag onto
        //    (500, 300 -> wx = +4.0) and release!
        final gesture = await tester.startGesture(const Offset(200, 300));
        await tester.pump();

        // Move across slop onto tileLeft (wx = -4.0 -> screen X = 300)
        await gesture.moveTo(const Offset(295, 300));
        await tester.pump();
        await gesture.moveTo(const Offset(305, 300));
        await tester.pump();

        expect(tileLeft.enterCount, 1);
        expect(tileLeft.moveCount, greaterThanOrEqualTo(1));
        expect(hudCard.selfDropEnterCount, 0);

        // Move across to X = 500 (wx = +4.0): leaves tileLeft, skips locked
        // upper shield (canAcceptDrop == false), enters tileRightAccept!
        await gesture.moveTo(const Offset(500, 300));
        await tester.pump();

        expect(tileLeft.leaveCount, 1);
        expect(tileRightLockedUpper.enterCount, 0);
        expect(tileRightAccept.enterCount, 1);
        expect(
          tileRightAccept.lastDropEvent!.hitPoint3D!.$1,
          closeTo(4.0, 1e-4),
        );
        expect(
          tileRightAccept.lastDropEvent!.hitPoint3D!.$3,
          closeTo(0.0, 1e-4),
        );
        expect(
          tileRightAccept.lastDropEvent!.hitDistance3D,
          closeTo(10.0, 1e-4),
        );

        // Release -> fires onDrop on tileRightAccept!
        await gesture.up();
        await tester.pump();

        expect(tileRightAccept.dropCount, 1);
        expect(tileRightAccept.lastDropEvent!.draggedComponent, same(hudCard));
        expect(hudCard.selfDropCount, 0);

        // 2. Drag hudCard (currently centered near (500, 300)) back over
        //    tileLeft (300, 300) and cancel -> fires onDragTargetCancel!
        final cancelGesture = await tester.startGesture(const Offset(500, 300));
        await tester.pump();
        await cancelGesture.moveTo(const Offset(300, 300));
        await tester.pump();
        expect(tileLeft.enterCount, 2);

        await cancelGesture.cancel();
        await tester.pump();
        expect(tileLeft.cancelCount, 1);
        expect(tileLeft.dropCount, 0);
        await tester.pump(const Duration(milliseconds: 500));
      },
    );

    testWidgets(
      'Combined stress: modal InputHitFilter gates DropTargetCallbacks, '
      'mid-drag dropTargetEnabled toggle fires leave, and mid-drag source '
      'unmount fires onDragTargetCancel cleanly',
      (tester) async {
        final blockedTile = _SpatialBoardTile3D(
          centerX: -4.0,
          topZ: 0.0,
          halfSize: 2.0,
          sphereRadius: 4.0,
        );
        final allowedTile = _SpatialBoardTile3D(
          centerX: 4.0,
          topZ: 0.0,
          halfSize: 2.0,
          sphereRadius: 4.0,
        );
        final world = World(children: [blockedTile, allowedTile]);
        final camera = CameraComponent(world: world)
          ..rayProjector3D = (viewportPt, _) {
            final wx = (viewportPt.x - 400.0) / 25.0;
            final wy = (viewportPt.y - 300.0) / 25.0;
            return Ray3D(
              ox: wx,
              oy: wy,
              oz: 10.0,
              dx: 0.0,
              dy: 0.0,
              dz: -1.0,
            );
          };

        final hudCard = _DraggableHudCard(
          position: Vector2(180, 280),
          size: Vector2(40, 40),
        );
        camera.viewport.add(hudCard);

        final game = FlameGame(world: world, camera: camera);
        await tester.pumpWidget(GameWidget(game: game));
        await tester.pump();
        await tester.pump();

        // Modal filter allows hudCard + allowedTile ONLY (blocks blockedTile)!
        game.pushInputHitFilter(
          (c, _) => identical(c, hudCard) || identical(c, allowedTile),
        );

        final g1 = await tester.startGesture(const Offset(200, 300));
        await tester.pump();

        // Drag over blockedTile (300, 300 -> wx = -4.0): blocked by modal
        // InputHitFilter!
        await g1.moveTo(const Offset(300, 300));
        await tester.pump();
        expect(blockedTile.enterCount, 0);

        // Drag over allowedTile (500, 300 -> wx = +4.0): permitted!
        await g1.moveTo(const Offset(500, 300));
        await tester.pump();
        expect(allowedTile.enterCount, 1);

        // Disable dropTargetEnabled mid-drag and nudge -> fires leave!
        allowedTile.dropTargetEnabled = false;
        await g1.moveTo(const Offset(505, 300));
        await tester.pump();
        expect(allowedTile.leaveCount, 1);

        // Re-enable dropTargetEnabled and nudge -> re-enters allowedTile!
        allowedTile.dropTargetEnabled = true;
        await g1.moveTo(const Offset(500, 300));
        await tester.pump();
        expect(allowedTile.enterCount, 2);

        // Unmount dragged hudCard mid-drag and move pointer -> stale record
        // cleanup fires onDragTargetCancel on allowedTile with 0 crashes!
        hudCard.removeFromParent();
        await tester.pump();
        await g1.moveTo(const Offset(495, 300));
        await tester.pump();
        expect(allowedTile.cancelCount, 1);
        expect(allowedTile.dropCount, 0);

        await g1.up();
        await tester.pump(const Duration(milliseconds: 500));
      },
    );
  });
}
