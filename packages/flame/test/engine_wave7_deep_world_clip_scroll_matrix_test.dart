import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flame/camera.dart';
import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flame/game.dart';
import 'package:flame/layout.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

class _NestedTileComponent({
  required this.tileId,
  super.position,
  super.size,
}) extends PositionComponent with HasTags, TapCallbacks {
  final int tileId;
  int renderCount = 0;

  @override
  void render(ui.Canvas canvas) {
    renderCount++;
  }
}

class _TappableItemComponent({
  required this.index,
  super.position,
  super.size,
}) extends PositionComponent with TapCallbacks {
  final int index;
  int taps = 0;
  int renders = 0;

  @override
  void render(ui.Canvas canvas) {
    renders++;
  }

  @override
  void onTapDown(TapDownEvent event) {
    taps++;
  }
}

void main() {
  group('Wave 7 — Subsystems 5–7: Deep WorldSpatialIndex & WorldQuery, '
      'Clipped Hit-Testing / ScrollContainerComponent & AffineMatrix2D', () {
    test(
      'Subsystem 5: Deep World(spatialIndexEnabled: true) indexes nested '
      'SceneLayerComponent subtrees in O(visible) and updates deep WorldQuery',
      () async {
        final world = World(spatialIndexEnabled: true, spatialCellSize: 128);
        final camera = CameraComponent.withFixedResolution(
          width: 300,
          height: 200,
          world: world,
          viewfinder: Viewfinder()..anchor = Anchor.topLeft,
        );
        final game = FlameGame(world: world, camera: camera);
        game.onGameResize(Vector2(300, 200));
        await game.start();
        addTearDown(game.onRemove);

        final activeHazardQuery = world.registerQuery(
          WorldQuery<_NestedTileComponent>(withTags: const ['hazard']),
        );

        final groundLayer = SceneLayerComponent(name: 'ground');
        final propGroup = PositionComponent(position: Vector2(0, 0));
        groundLayer.add(propGroup);
        world.add(groundLayer);

        // Populate 400 nested tiles across a 4000x4000 world (20x20 grid, 200px
        // spacing). Only the top-left ~2x2 tiles overlap the 300x200 camera!
        final tiles = <_NestedTileComponent>[];
        for (var gy = 0; gy < 20; gy++) {
          for (var gx = 0; gx < 20; gx++) {
            final id = gy * 20 + gx;
            final tile = _NestedTileComponent(
              tileId: id,
              position: Vector2(gx * 200.0 + 10, gy * 200.0 + 10),
              size: Vector2(48, 48),
            );
            if (id % 50 == 0) {
              tile.addTag('hazard');
            }
            tiles.add(tile);
          }
        }
        propGroup.addAll(tiles);
        await game.ready();
        game.update(1 / 60);

        // Deep WorldQuery matched all 8 grandchildren tagged 'hazard'!
        expect(activeHazardQuery.length, 8);

        // Live tag mutation on a deeply nested grandchild updates WorldQuery!
        tiles[1].addTag('hazard');
        expect(activeHazardQuery.length, 9);
        tiles[0].removeTag('hazard');
        expect(activeHazardQuery.length, 8);

        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(
          recorder,
          const ui.Rect.fromLTWH(0, 0, 300, 200),
        );
        game.render(canvas);
        recorder.endRecording().dispose();

        // Spatial index lazily syncs and tracks all 400 nested leaf tiles!
        expect(world.spatialIndex.indexedCount, 400);

        final renderedTiles = tiles.where((t) => t.renderCount > 0).length;
        expect(renderedTiles, greaterThan(0));
        expect(renderedTiles, lessThan(20)); // O(visible) << 400!

        // Spatial point hit-testing hits nested grandchild at (25, 25)!
        final hit = game
            .componentsAtPoint(Vector2(25, 25))
            .whereType<_NestedTileComponent>()
            .toList();
        expect(hit.map((t) => t.tileId), [0]);
      },
    );

    test(
      'Subsystem 6: ClipComponent clips pointer hit-testing and '
      'ScrollContainerComponent handles wheel, inertia, clamping & culling',
      () async {
        final world = World();
        final camera = CameraComponent.withFixedResolution(
          width: 400,
          height: 300,
          world: world,
          viewfinder: Viewfinder()..anchor = Anchor.topLeft,
        );
        final game = FlameGame(world: world, camera: camera);
        game.onGameResize(Vector2(400, 300));
        await game.start();
        addTearDown(game.onRemove);

        final clip = ClipComponent.rectangle(
          position: Vector2(10, 10),
          size: Vector2(80, 50),
        );
        final overflowingButton = _TappableItemComponent(
          index: -1,
          position: Vector2.zero(),
          size: Vector2(160, 50),
        );
        clip.add(overflowingButton);
        world.add(clip);

        final items = <_TappableItemComponent>[
          for (var i = 0; i < 20; i++)
            _TappableItemComponent(
              index: i,
              position: Vector2(0, i * 40.0),
              size: Vector2(150, 36),
            ),
        ];
        final scroll = ScrollContainerComponent(
          position: Vector2(200, 20),
          size: Vector2(150, 120),
          contentChildren: items,
          showScrollbar: true,
        );
        world.add(scroll);
        await game.ready();
        game.update(1 / 60);

        // Inside clip (x=50, y=30) -> hits overflowingButton!
        expect(
          game.componentsAtPoint(Vector2(50, 30)).contains(overflowingButton),
          isTrue,
        );
        // Outside clip (x=120, y=30) -> clipped out, does NOT hit!
        expect(
          game.componentsAtPoint(Vector2(120, 30)).contains(overflowingButton),
          isFalse,
        );

        void renderPass() {
          final rec = ui.PictureRecorder();
          game.render(ui.Canvas(rec, const ui.Rect.fromLTWH(0, 0, 400, 300)));
          rec.endRecording().dispose();
        }

        renderPass();
        expect(scroll.lastVisibleChildCount, lessThanOrEqualTo(4));
        expect(scroll.lastCulledChildCount, greaterThanOrEqualTo(16));

        expect(
          game.componentsAtPoint(Vector2(220, 30)).contains(items[0]),
          isTrue,
        );
        expect(
          game.componentsAtPoint(Vector2(220, 230)).contains(items[5]),
          isFalse,
        );

        scroll.scrollTo(y: 99999);
        expect(scroll.scrollOffset.y, closeTo(scroll.maxScrollY, 1e-5));
        scroll.scrollTo(y: -500);
        expect(scroll.scrollOffset.y, 0.0);

        scroll.onScroll(
          ScrollEvent(
            game,
            const PointerScrollEvent(
              position: ui.Offset(250, 60),
              scrollDelta: ui.Offset(0, 80),
            ),
          ),
        );
        expect(scroll.scrollOffset.y, closeTo(80.0, 1e-5));

        scroll.ensureRectVisible(items[15].toRect());
        expect(
          scroll.scrollOffset.y + scroll.size.y,
          greaterThanOrEqualTo(636.0 - 1e-5),
        );

        scroll.scrollTo(y: 100);
        scroll.onDragStart(
          DragStartEvent(
            1,
            game,
            DragStartDetails(
              globalPosition: const ui.Offset(250, 100),
              localPosition: const ui.Offset(250, 100),
            ),
          ),
        );
        scroll.onDragUpdate(
          DragUpdateEvent(
            1,
            game,
            DragUpdateDetails(
              globalPosition: const ui.Offset(250, 60),
              localPosition: const ui.Offset(250, 60),
              delta: const ui.Offset(0, -40),
            ),
          ),
        );
        scroll.onDragEnd(
          DragEndEvent(
            1,
            DragEndDetails(
              velocity: const Velocity(pixelsPerSecond: ui.Offset(0, -600)),
            ),
          ),
        );
        final afterDragY = scroll.scrollOffset.y;
        expect(afterDragY, closeTo(140.0, 1e-5));
        game.update(0.1);
        expect(scroll.scrollOffset.y, greaterThan(afterDragY));
      },
    );

    test(
      'Subsystem 7: AffineMatrix2D and versioned PositionComponent '
      'worldTransformMatrix cache across 5-level hierarchy',
      () async {
        final game = FlameGame();
        game.onGameResize(Vector2(400, 300));
        await game.start();
        addTearDown(game.onRemove);

        final n1 = PositionComponent(
          position: Vector2(20, 30),
          angle: 0.35,
          scale: Vector2(1.5, 0.8),
        );
        final n2 = PositionComponent(
          position: Vector2(-12, 40),
          angle: -0.6,
          scale: Vector2(0.9, 1.25),
        );
        final n3 = PositionComponent(
          position: Vector2(50, -15),
          angle: 1.1,
          scale: Vector2(2.0, 2.0),
        );
        final n4 = PositionComponent(
          position: Vector2(8, 16),
          angle: -0.25,
          anchor: Anchor.center,
          size: Vector2(30, 20),
        );
        final leaf = PositionComponent(
          position: Vector2(15, 10),
          angle: 0.45,
          scale: Vector2(1.2, 0.7),
          size: Vector2(24, 12),
        );

        n4.add(leaf);
        n3.add(n4);
        n2.add(n3);
        n1.add(n2);
        game.world.add(n1);
        await game.ready();

        final localPt = Vector2(7.5, -3.25);
        final worldPt = leaf.absolutePositionOf(localPt);
        final recalcAfterFirst = leaf.worldTransformRecalcCount;
        expect(recalcAfterFirst, 1);

        for (var i = 0; i < 100; i++) {
          final p = leaf.absolutePositionOf(localPt);
          expect(p.x, closeTo(worldPt.x, 1e-9));
          expect(p.y, closeTo(worldPt.y, 1e-9));
        }
        expect(leaf.worldTransformRecalcCount, recalcAfterFirst);

        // Verify exact 64-bit double precision on AffineMatrix2D directly, and
        // 32-bit float precision on Vector2 roundtrips!
        final m = leaf.worldTransformMatrix;
        final (wx64, wy64) = m.transformXY(7.5, -3.25);
        expect(wx64, closeTo(worldPt.x, 1e-4));
        expect(wy64, closeTo(worldPt.y, 1e-4));
        final invVec = m.inverseTransformPoint(worldPt);
        expect(invVec.x, closeTo(7.5, 1e-5));
        expect(invVec.y, closeTo(-3.25, 1e-5));

        final roundtrip = leaf.absoluteToLocal(worldPt);
        expect(roundtrip.x, closeTo(localPt.x, 1e-5));
        expect(roundtrip.y, closeTo(localPt.y, 1e-5));

        n1.angle += math.pi / 5;
        n1.position.add(Vector2(100, -50));
        final movedWorldPt = leaf.absolutePositionOf(localPt);
        expect(leaf.worldTransformRecalcCount, recalcAfterFirst + 1);
        expect((movedWorldPt - worldPt).length, greaterThan(50.0));
        final movedRoundtrip = leaf.absoluteToLocal(movedWorldPt);
        expect(movedRoundtrip.x, closeTo(localPt.x, 1e-5));
        expect(movedRoundtrip.y, closeTo(localPt.y, 1e-5));
      },
    );
  });
}
