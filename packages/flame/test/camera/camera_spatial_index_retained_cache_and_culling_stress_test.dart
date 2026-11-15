import 'dart:ui' as ui;

import 'package:flame/camera.dart';
import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flame/math.dart';
import 'package:flutter_test/flutter_test.dart';

class _SpatialProbeTile({
  required this.id,
  required super.position,
  required super.size,
  super.priority,
}) extends PositionComponent with CullWhenOffscreen {
  final int id;
  int renderCount = 0;

  @override
  void render(ui.Canvas canvas) {
    renderCount++;
    canvas.drawRect(size.toRect(), ui.Paint());
  }

  @override
  bool containsLocalPoint(Vector2 point) {
    return point.x >= 0 &&
        point.y >= 0 &&
        point.x <= size.x &&
        point.y <= size.y;
  }
}

class _CountingHudBox({
  super.position,
  super.size,
}) extends PositionComponent {
  int renders = 0;

  @override
  void render(ui.Canvas canvas) {
    renders++;
    canvas.drawRect(size.toRect(), ui.Paint());
  }
}

void _renderOnce(FlameGame game, double w, double h) {
  final rec = ui.PictureRecorder();
  game.render(ui.Canvas(rec, ui.Rect.fromLTWH(0, 0, w, h)));
  game.onFrameRendered();
  rec.endRecording().dispose();
}

void main() {
  group('10k-entity WorldSpatialIndex culling & hit-test oracle stress', () {
    test(
      '10,000 entities in World(spatialIndexEnabled: true) cull offscreen '
      'renders in O(visible) and match non-indexed hit-test order identically',
      () async {
        final worldIndexed = World(spatialIndexEnabled: true);
        final worldLinear = World();

        final camIndexed = CameraComponent.withFixedResolution(
          width: 320,
          height: 240,
          world: worldIndexed,
        );
        final camLinear = CameraComponent.withFixedResolution(
          width: 320,
          height: 240,
          world: worldLinear,
        );

        final gameIndexed = FlameGame(world: worldIndexed, camera: camIndexed)
          ..onGameResize(Vector2(320, 240));
        final gameLinear = FlameGame(world: worldLinear, camera: camLinear)
          ..onGameResize(Vector2(320, 240));

        await gameIndexed.start();
        await gameLinear.start();
        addTearDown(gameIndexed.onRemove);
        addTearDown(gameLinear.onRemove);

        final rng = SeededRng(0x10000ECA);
        final tilesIndexed = <_SpatialProbeTile>[];
        final tilesLinear = <_SpatialProbeTile>[];

        // Spawn 10,000 entities spread across a 16,000 x 16,000 world!
        for (var i = 0; i < 10000; i++) {
          final x = (rng.nextDouble() - 0.5) * 16000.0;
          final y = (rng.nextDouble() - 0.5) * 16000.0;
          final w = 24.0 + rng.nextInt(40);
          final h = 24.0 + rng.nextInt(40);
          final prio = rng.nextInt(12);

          tilesIndexed.add(
            _SpatialProbeTile(
              id: i,
              position: Vector2(x, y),
              size: Vector2(w, h),
              priority: prio,
            ),
          );
          tilesLinear.add(
            _SpatialProbeTile(
              id: i,
              position: Vector2(x, y),
              size: Vector2(w, h),
              priority: prio,
            ),
          );
        }

        worldIndexed.addAll(tilesIndexed);
        worldLinear.addAll(tilesLinear);
        await gameIndexed.ready();
        await gameLinear.ready();

        // Sweep camera across 25 random locations, mutating 40 entities each
        // frame (position + priority churn) and verifying both O(visible)
        // render culling AND bit-exact hit-test ordering parity!
        for (var step = 0; step < 25; step++) {
          final cx = (rng.nextDouble() - 0.5) * 12000.0;
          final cy = (rng.nextDouble() - 0.5) * 12000.0;
          final zoom = 0.75 + rng.nextDouble() * 1.25;
          camIndexed.viewfinder
            ..position = Vector2(cx, cy)
            ..zoom = zoom;
          camLinear.viewfinder
            ..position = Vector2(cx, cy)
            ..zoom = zoom;

          for (var m = 0; m < 40; m++) {
            final idx = rng.nextInt(10000);
            final nx = cx + (rng.nextDouble() - 0.5) * 260.0;
            final ny = cy + (rng.nextDouble() - 0.5) * 200.0;
            final np = rng.nextInt(16);
            tilesIndexed[idx]
              ..position.setValues(nx, ny)
              ..priority = np;
            tilesLinear[idx]
              ..position.setValues(nx, ny)
              ..priority = np;
          }

          for (var i = 0; i < 10000; i++) {
            tilesIndexed[i].renderCount = 0;
          }

          gameIndexed.update(1 / 60);
          gameLinear.update(1 / 60);
          _renderOnce(gameIndexed, 320, 240);

          var renderedThisFrame = 0;
          for (var i = 0; i < 10000; i++) {
            renderedThisFrame += tilesIndexed[i].renderCount;
          }
          // Only entities near the 320x240 viewport render (<< 10,000)!
          expect(renderedThisFrame, lessThan(450));

          // Probe 8 random screen points per step and verify exact ID order!
          for (var p = 0; p < 8; p++) {
            final pt = Vector2(
              20.0 + rng.nextDouble() * 280.0,
              20.0 + rng.nextDouble() * 200.0,
            );
            final idsIndexed = gameIndexed
                .componentsAtPoint(pt)
                .whereType<_SpatialProbeTile>()
                .map((t) => t.id)
                .toList();
            final idsLinear = gameLinear
                .componentsAtPoint(pt)
                .whereType<_SpatialProbeTile>()
                .map((t) => t.id)
                .toList();
            expect(
              idsIndexed,
              idsLinear,
              reason: 'Hit-test mismatch at step $step point $pt',
            );
          }
        }
      },
    );
  });

  group('Retained cache, self-capture guard & transition interrupts', () {
    test(
      'survives 200 frames of splitRetained invalidation + resize + trauma, '
      'guards RenderTextureComponent self-capture recursion, and interrupts '
      'mid-flight SceneTransitions cleanly',
      () async {
        final world = World();
        final camera = CameraComponent.withFixedResolution(
          width: 400,
          height: 300,
          world: world,
          layerCacheMode: CameraLayerCacheMode.splitRetained,
        );
        final game = FlameGame(world: world, camera: camera)
          ..onGameResize(Vector2(400, 300));
        await game.start();
        addTearDown(game.onRemove);

        final bgBox = _CountingHudBox(size: Vector2(400, 300));
        final worldBox = _CountingHudBox(
          position: Vector2(-25, -25),
          size: Vector2(50, 50),
        );
        final hudBox = _CountingHudBox(
          position: Vector2(12, 12),
          size: Vector2(80, 24),
        );
        // Self-referencing RenderTextureComponent (sourceCamera == camera) MUST
        // guard against infinite render recursion!
        final selfMirror = RenderTextureComponent(
          sourceCamera: camera,
          position: Vector2(280, 12),
          size: Vector2(96, 72),
          refreshFps: 30,
        );

        camera.backdrop.add(bgBox);
        world.add(worldBox);
        camera.viewport.addAll(<Component>[hudBox, selfMirror]);
        await game.ready();

        var curW = 400.0;
        var curH = 300.0;
        for (var frame = 0; frame < 200; frame++) {
          if (frame % 17 == 0) {
            hudBox.position.x = 12.0 + (frame % 40);
          }
          if (frame % 23 == 0) {
            worldBox.position.y = -25.0 + (frame % 30);
          }
          if (frame % 41 == 0) {
            camera.viewfinder.addTrauma(0.45);
          }
          if (frame % 53 == 0) {
            curW = curW == 400.0 ? 480.0 : 400.0;
            curH = curH == 300.0 ? 360.0 : 300.0;
            game.onGameResize(Vector2(curW, curH));
          }
          game.update(1 / 60);
          _renderOnce(game, curW, curH);
        }

        expect(camera.worldCacheHitCount, greaterThan(40));
        expect(camera.backdropCacheHitCount, greaterThan(150));

        selfMirror.removeFromParent();
        await game.ready();
        expect(selfMirror.texture, isNull);

        // Rapidly interrupt 6 consecutive SceneTransitions mid-flight!
        final worlds = List<World>.generate(
          6,
          (i) => World(
            children: <Component>[
              _CountingHudBox(
                position: Vector2(i * 5.0, 0),
                size: Vector2(30, 30),
              ),
            ],
          ),
        );
        final futures = <Future<void>>[];
        for (var i = 0; i < worlds.length; i++) {
          futures.add(
            camera.transitionToWorld(
              worlds[i],
              transition: i.isEven
                  ? const CrossFadeSceneTransition(duration: 0.25)
                  : CircularRevealSceneTransition(duration: 0.25),
            ),
          );
          game
            ..processLifecycleEvents()
            ..update(0.05);
          _renderOnce(game, curW, curH);
        }

        // Advance past final transition duration -> all futures resolve and
        // camera settles cleanly on worlds.last!
        for (var step = 0; step < 20; step++) {
          game.update(0.03);
          _renderOnce(game, curW, curH);
        }
        await Future.wait(futures);
        expect(camera.hasActiveSceneTransition, isFalse);
        expect(camera.world, same(worlds.last));
      },
    );
  });
}
