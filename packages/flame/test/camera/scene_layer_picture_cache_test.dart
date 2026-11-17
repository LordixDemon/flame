import 'dart:ui';

import 'package:flame/camera.dart';
import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flutter_test/flutter_test.dart';

class _Probe({super.position, super.size}) extends PositionComponent {
  int renderCount = 0;

  @override
  void render(Canvas canvas) => renderCount++;
}

class _CullProbe({super.position, super.size})
    extends _Probe
    with CullWhenOffscreen;

void main() {
  Future<FlameGame> makeGame({
    bool spatialIndex = false,
    int? cameraMask,
  }) async {
    final world = World(spatialIndexEnabled: spatialIndex);
    final game = FlameGame(
      world: world,
      camera: CameraComponent(
        world: world,
        viewport: FixedSizeViewport(400, 300),
        cameraMask: cameraMask,
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

  group('SceneLayerComponent(cacheAsPicture: true)', () {
    for (final spatialIndex in [false, true]) {
      final mode = spatialIndex ? 'with' : 'without';
      test(
        'records children that are off screen at bake time '
        '($mode the spatial index)',
        () async {
          final game = await makeGame(spatialIndex: spatialIndex);
          final near = _Probe(position: Vector2(0, 0), size: Vector2(20, 20));
          final far = _Probe(position: Vector2(3000, 0), size: Vector2(20, 20));
          final farCullable = _CullProbe(
            position: Vector2(3000, 40),
            size: Vector2(20, 20),
          );
          final layer = SceneLayerComponent(
            cacheAsPicture: true,
            children: [near, far, farCullable],
          );
          game.world.add(layer);
          await game.ready();

          renderOnce(game);
          expect(near.renderCount, 1);
          expect(far.renderCount, 1);
          expect(farCullable.renderCount, 1);

          game.camera.viewfinder.position = Vector2(3000, 0);
          game.update(0);
          renderOnce(game);
          renderOnce(game);
          expect(layer.pictureBakeCount, 1);
          expect(far.renderCount, 1);
        },
      );
    }

    test('re-records after markLayerDirty', () async {
      final game = await makeGame(spatialIndex: true);
      final far = _Probe(position: Vector2(3000, 0), size: Vector2(20, 20));
      final layer = SceneLayerComponent(cacheAsPicture: true, children: [far]);
      game.world.add(layer);
      await game.ready();

      renderOnce(game);
      layer.markLayerDirty();
      renderOnce(game);
      expect(layer.pictureBakeCount, 2);
      expect(far.renderCount, 2);
    });

    test(
      'is not drawn, and not baked, by a camera its cameraMask excludes',
      () async {
        final game = await makeGame(cameraMask: 0x1);
        final child = _Probe(size: Vector2(20, 20));
        final layer = SceneLayerComponent(
          cacheAsPicture: true,
          children: [child],
        )..cameraMask = 0x2;
        game.world.add(layer);
        await game.ready();

        renderOnce(game);
        expect(layer.pictureBakeCount, 0);
        expect(child.renderCount, 0);

        layer.cameraMask = 0x1;
        renderOnce(game);
        expect(layer.pictureBakeCount, 1);
        expect(child.renderCount, 1);
      },
    );
  });
}
