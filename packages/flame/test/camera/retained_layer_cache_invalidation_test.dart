import 'dart:ui';

import 'package:flame/camera.dart';
import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flutter_test/flutter_test.dart';

class _RenderCounter() extends Component {
  int renderCount = 0;

  @override
  void render(Canvas canvas) => renderCount++;
}

void main() {
  late FlameGame game;
  late World world;

  Future<void> boot({List<Component>? hud}) async {
    world = World();
    game = FlameGame(
      world: world,
      camera: CameraComponent(
        world: world,
        viewport: FixedSizeViewport(400, 300),
        hudComponents: hud,
        layerCacheMode: CameraLayerCacheMode.splitRetained,
      ),
    )..onGameResize(Vector2(400, 300));
    await game.start();
    await game.ready();
  }

  void frame(double dt) {
    game.update(dt);
    final rec = PictureRecorder();
    game.camera.renderTree(Canvas(rec, const Rect.fromLTWH(0, 0, 400, 300)));
    rec.endRecording().dispose();
  }

  group('CameraLayerCacheMode.splitRetained', () {
    test('replacing camera.backdrop shows the new backdrop', () async {
      await boot();
      frame(0);
      frame(0);
      expect(game.camera.backdropCacheHitCount, greaterThan(0));

      // A fresh leaf has the same subtreeVersion (0) as the backdrop that was
      // recorded before it.
      final sky = _RenderCounter();
      game.camera.backdrop = sky;
      await game.ready();
      frame(0);
      expect(sky.renderCount, 1);

      // ... and is retained from then on.
      frame(0);
      frame(0);
      expect(sky.renderCount, 1);
    });

    test('replacing camera.viewport shows the new HUD', () async {
      final oldHud = _RenderCounter();
      await boot(hud: [oldHud]);
      frame(0);
      frame(0);
      expect(oldHud.renderCount, 1);
      expect(game.camera.viewportCacheHitCount, greaterThan(0));

      // Same size, same number of children, same subtreeVersion.
      final newHud = _RenderCounter();
      game.camera.viewport = FixedSizeViewport(400, 300)..add(newHud);
      await game.ready();
      frame(0);
      frame(0);

      expect(newHud.renderCount, 1);
      expect(oldHud.renderCount, 1);
    });

    test('replacing camera.viewfinder re-records the world', () async {
      await boot();
      final prop = _RenderCounter();
      world.add(prop);
      await game.ready();
      frame(0);
      frame(0);
      expect(prop.renderCount, 1);

      game.camera.viewfinder = Viewfinder();
      await game.ready();
      frame(0);
      expect(prop.renderCount, 2);
      frame(0);
      expect(prop.renderCount, 2);
    });

    test('changing renderPasses re-records the world', () async {
      await boot();
      final prop = _RenderCounter();
      world.add(prop);
      await game.ready();
      frame(0);
      frame(0);
      final rebuilds = game.camera.worldCacheRebuildCount;

      game.camera.renderPasses = const [RenderPass.opaque];
      frame(0);
      expect(game.camera.worldCacheRebuildCount, rebuilds + 1);
      frame(0);
      expect(game.camera.worldCacheRebuildCount, rebuilds + 1);
    });

    test(
      'a throttled RenderTextureComponent in the HUD keeps refreshing',
      () async {
        final sourceWorld = World();
        final sourceCamera = CameraComponent(
          world: sourceWorld,
          viewport: FixedSizeViewport(64, 64),
        );
        final minimap = RenderTextureComponent(
          sourceCamera: sourceCamera,
          size: Vector2.all(64),
          refreshFps: 30,
        );
        await boot(hud: [minimap]);
        game.addAll([sourceWorld, sourceCamera]);
        await game.ready();

        frame(1 / 60);
        final capturesAtStart = minimap.captureCount;
        final hitsAtStart = game.camera.viewportCacheHitCount;
        expect(capturesAtStart, 1);

        // One second at 60 fps: a 30 Hz texture is captured about 30 times,
        // and the HUD layer is replayed on the frames in between.
        for (var i = 0; i < 60; i++) {
          frame(1 / 60);
        }
        final captures = minimap.captureCount - capturesAtStart;
        expect(captures, inInclusiveRange(29, 31));
        expect(
          game.camera.viewportCacheHitCount - hitsAtStart,
          inInclusiveRange(28, 32),
        );
      },
    );

    test(
      'an unthrottled RenderTextureComponent refreshes on every frame',
      () async {
        final sourceWorld = World();
        final sourceCamera = CameraComponent(
          world: sourceWorld,
          viewport: FixedSizeViewport(64, 64),
        );
        final minimap = RenderTextureComponent(
          sourceCamera: sourceCamera,
          size: Vector2.all(64),
        );
        await boot(hud: [minimap]);
        game.addAll([sourceWorld, sourceCamera]);
        await game.ready();

        frame(1 / 60);
        final capturesAtStart = minimap.captureCount;
        for (var i = 0; i < 10; i++) {
          frame(1 / 60);
        }
        expect(minimap.captureCount, capturesAtStart + 10);
      },
    );

    test('refreshNow outside of render re-records the HUD layer', () async {
      final sourceWorld = World();
      final sourceCamera = CameraComponent(
        world: sourceWorld,
        viewport: FixedSizeViewport(64, 64),
      );
      final minimap = RenderTextureComponent(
        sourceCamera: sourceCamera,
        size: Vector2.all(64),
        autoRefresh: false,
      );
      await boot(hud: [minimap]);
      game.addAll([sourceWorld, sourceCamera]);
      await game.ready();

      frame(0);
      frame(0);
      frame(0);
      final rebuilds = game.camera.viewportCacheRebuildCount;
      final captures = minimap.captureCount;

      minimap.refreshNow();
      expect(minimap.captureCount, captures + 1);
      frame(0);
      expect(game.camera.viewportCacheRebuildCount, rebuilds + 1);
      frame(0);
      expect(game.camera.viewportCacheRebuildCount, rebuilds + 1);
      expect(minimap.captureCount, captures + 1);
    });
  });
}
