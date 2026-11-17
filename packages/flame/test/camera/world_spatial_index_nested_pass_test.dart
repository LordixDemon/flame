import 'dart:ui';

import 'package:flame/camera.dart';
import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flutter_test/flutter_test.dart';

class _Probe({super.position, super.size, super.priority})
    extends PositionComponent {
  int renderCount = 0;

  @override
  void render(Canvas canvas) => renderCount++;
}

void main() {
  Future<FlameGame> makeGame({required bool spatialIndex}) async {
    final world = World(spatialIndexEnabled: spatialIndex);
    final game = FlameGame(
      world: world,
      camera: CameraComponent(
        world: world,
        viewport: FixedSizeViewport(400, 300),
      ),
    )..onGameResize(Vector2(400, 300));
    await game.start();
    await game.ready();
    return game;
  }

  void renderOnce(FlameGame game) {
    final rec = PictureRecorder();
    game.camera.renderTree(Canvas(rec, const Rect.fromLTWH(0, 0, 400, 300)));
    rec.endRecording().dispose();
  }

  /// An in-world "monitor": a camera inside the world that looks at a far
  /// away part of the same world.
  CameraComponent monitorCamera(World world) => CameraComponent(
    world: world,
    viewport: FixedSizeViewport(40, 30),
  )..viewfinder.position = Vector2(5000, 5000);

  group('WorldSpatialIndex with a pass nested in a pass of the same world', () {
    for (final spatialIndex in [false, true]) {
      final mode = spatialIndex ? 'with' : 'without';
      test(
        'world children after an in-world camera are still drawn '
        '($mode the index)',
        () async {
          final game = await makeGame(spatialIndex: spatialIndex);
          final monitor = Component(
            priority: 0,
            children: [monitorCamera(game.world)],
          );
          final later = _Probe(
            position: Vector2(-10, -10),
            size: Vector2(20, 20),
            priority: 5,
          );
          game.world.addAll([monitor, later]);
          await game.ready();

          renderOnce(game);
          expect(later.renderCount, greaterThanOrEqualTo(1));
        },
      );
    }

    test('each pass draws exactly what its own camera sees', () async {
      final game = await makeGame(spatialIndex: true);
      final world = game.world;

      final before = _Probe(
        position: Vector2(-50, 0),
        size: Vector2(20, 20),
        priority: -5,
      );
      final after = _Probe(
        position: Vector2(50, 0),
        size: Vector2(20, 20),
        priority: 5,
      );
      // Only in front of the monitor camera.
      final farAway = _Probe(
        position: Vector2(5000, 5000),
        size: Vector2(20, 20),
        priority: 5,
      );
      // Siblings of the monitor inside one container, on both sides of it.
      final siblingBefore = _Probe(
        position: Vector2(0, -60),
        size: Vector2(20, 20),
        priority: -1,
      );
      final siblingAfter = _Probe(
        position: Vector2(0, 60),
        size: Vector2(20, 20),
        priority: 0x7fffffff,
      );
      final monitor = monitorCamera(world);
      // Keep the nesting to a single level for exact counts.
      final previousDepth = CameraComponent.maxCamerasDepth;
      CameraComponent.maxCamerasDepth = 2;
      addTearDown(() => CameraComponent.maxCamerasDepth = previousDepth);

      world.addAll([
        before,
        Component(
          priority: 0,
          children: [siblingBefore, monitor, siblingAfter],
        ),
        after,
        farAway,
      ]);
      await game.ready();
      // The camera sorts last among its siblings by default.
      monitor.priority = 0;
      game.update(0);

      renderOnce(game);

      // The main camera sees the four central components once each ...
      expect(before.renderCount, 1);
      expect(after.renderCount, 1);
      expect(siblingBefore.renderCount, 1);
      expect(siblingAfter.renderCount, 1);
      // ... and the monitor sees only the far one.
      expect(farAway.renderCount, 1);
      expect(world.spatialIndex.openRenderPassCount, 0);

      // The next frame is the same.
      renderOnce(game);
      expect(before.renderCount, 2);
      expect(after.renderCount, 2);
      expect(siblingBefore.renderCount, 2);
      expect(siblingAfter.renderCount, 2);
      expect(farAway.renderCount, 2);
    });

    test(
      'a RenderTextureComponent in the world that shows the same world does '
      'not disturb the main pass',
      () async {
        final game = await makeGame(spatialIndex: true);
        final world = game.world;
        final source = CameraComponent(
          world: world,
          viewport: FixedSizeViewport(64, 64),
        )..viewfinder.position = Vector2(5000, 5000);
        game.add(source);

        final screen = RenderTextureComponent(
          sourceCamera: source,
          position: Vector2(-100, -100),
          size: Vector2(64, 64),
          priority: 0,
        );
        final after = _Probe(
          position: Vector2(50, 0),
          size: Vector2(20, 20),
          priority: 5,
        );
        final farAway = _Probe(
          position: Vector2(5000, 5000),
          size: Vector2(20, 20),
        );
        world.addAll([screen, after, farAway]);
        await game.ready();
        game.update(0);

        renderOnce(game);

        expect(screen.captureCount, 1);
        expect(after.renderCount, 1);
        expect(farAway.renderCount, 1);
      },
    );
  });
}
