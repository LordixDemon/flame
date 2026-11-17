// The 3D-ray hit flag must not outlive the hit test that set it: a drag
// target resolved through the lazy hit list stops iterating at the target, so
// a later drop event reached through the target's 2D rectangle must not carry
// the 3D hit of an earlier pointer position.
import 'package:flame/canvas3d.dart';
import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flame/game.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// 2D footprint 100x100 around the world origin, 3D volume only the central
/// 20x20 column (top at z = 10).
class _Tower({super.position, super.size})
    extends PositionComponent
    with TapCallbacks, DropTargetCallbacks, SpatialHitbox3D {
  int taps = 0;
  final List<DragDropEvent> dropEvents = <DragDropEvent>[];

  @override
  double? intersectRay3D(Ray3D ray) => intersectWorldAabb3D(
    ray,
    minX: -10,
    minY: -10,
    minZ: 0,
    maxX: 10,
    maxY: 10,
    maxZ: 10,
  );

  @override
  void onTapDown(TapDownEvent event) => taps++;

  @override
  void onDragTargetEnter(DragDropEvent event) => dropEvents.add(event);

  @override
  void onDragTargetMove(DragDropEvent event) => dropEvents.add(event);
}

class _HudCard({super.position, super.size})
    extends PositionComponent
    with DragCallbacks {
  @override
  void onDragUpdate(DragUpdateEvent event) => position.add(event.localDelta);
}

Ray3D _straightDown(Vector2 _, Vector2 worldPt) =>
    Ray3D(ox: worldPt.x, oy: worldPt.y, oz: 100, dx: 0, dy: 0, dz: -1);

void main() {
  testWidgets('complete tap clears the 3D-ray flag (passes)', (tester) async {
    final game = FlameGame()..camera.rayProjector3D = _straightDown;
    final tower = _Tower(
      position: Vector2(-50, -50),
      size: Vector2(100, 100),
    );
    await tester.pumpWidget(
      SizedBox(width: 800, height: 600, child: GameWidget(game: game)),
    );
    await tester.pump();
    game.world.add(tower);
    await game.ready();
    await tester.pump();

    await tester.tapAt(const Offset(400, 300));
    await tester.pump(const Duration(seconds: 1));
    expect(tower.taps, 1);
    expect(tower.isActiveSpatialRayHit, isFalse);
  });

  testWidgets('drop target reached through its 2D rectangle must not report '
      'the 3D hit of an earlier pointer position', (tester) async {
    final game = FlameGame()..camera.rayProjector3D = _straightDown;
    final tower = _Tower(
      position: Vector2(-50, -50),
      size: Vector2(100, 100),
    );
    final card = _HudCard(
      position: Vector2(180, 280),
      size: Vector2(40, 40),
    );
    await tester.pumpWidget(
      SizedBox(width: 800, height: 600, child: GameWidget(game: game)),
    );
    await tester.pump();
    game.world.add(tower);
    game.camera.viewport.add(card);
    await game.ready();
    await tester.pump();

    final gesture = await tester.startGesture(const Offset(200, 300));
    await tester.pump();
    // Onto the 3D column (world (-2, 0) then (0, 0)).
    await gesture.moveTo(const Offset(398, 300));
    await tester.pump();
    await gesture.moveTo(const Offset(400, 300));
    await tester.pump();
    expect(tower.dropEvents, isNotEmpty);
    expect(tower.dropEvents.last.hitPoint3D, isNotNull);
    expect(tower.dropEvents.last.hitPoint3D!.$1, closeTo(0.0, 1e-6));
    final flagBetweenEvents = tower.isActiveSpatialRayHit;

    // World (30, 0): outside the 3D column, inside the 2D footprint.
    final before = tower.dropEvents.length;
    await gesture.moveTo(const Offset(430, 300));
    await tester.pump();
    expect(tower.dropEvents.length, greaterThan(before));
    final ev = tower.dropEvents.last;
    expect(
      ev.hitPoint3D,
      isNull,
      reason:
          'ray at world x=30 misses the 3D column [-10, 10]; event still '
          'carries hitPoint3D=${ev.hitPoint3D}, '
          'hitDistance3D=${ev.hitDistance3D} '
          '(isActiveSpatialRayHit between events: $flagBetweenEvents)',
    );
    await gesture.up();
    await tester.pump(const Duration(seconds: 1));
  });
}
