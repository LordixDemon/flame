import 'dart:ui';

import 'package:flame/camera.dart';
import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flutter_test/flutter_test.dart';

class _Probe({super.position, super.size}) extends PositionComponent {
  int renderCount = 0;
  Offset? screenTopLeft;

  @override
  void render(Canvas canvas) {
    renderCount++;
    final m = canvas.getTransform();
    screenTopLeft = Offset(m[12], m[13]);
  }
}

class _Cloud({super.position, super.size})
    extends _Probe
    with CullWhenOffscreen;

void main() {
  Future<FlameGame> makeGame({bool spatialIndex = false}) async {
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

  group('parallax SceneLayerComponent and culling', () {
    test('a CullWhenOffscreen child is culled where it is drawn', () async {
      final game = await makeGame();
      // A distant background that moves at half the camera speed.
      final onScreen = _Cloud(
        position: Vector2(1000, 0),
        size: Vector2(40, 20),
      );
      final offScreen = _Cloud(
        position: Vector2(2000, 0),
        size: Vector2(40, 20),
      );
      game.world.add(
        SceneLayerComponent(
          parallaxFactor: Vector2(0.5, 1.0),
          children: [onScreen, offScreen],
        ),
      );
      await game.ready();

      // Camera at x = 2000: the layer is shifted by +1000. The first cloud
      // (layer x = 1000) is drawn at the centre of the screen, the second one
      // (layer x = 2000), which sits inside visibleWorldRect when read as a
      // plain world position, is drawn 1000 px to the right of it.
      game.camera.viewfinder.position = Vector2(2000, 0);
      game.update(0);
      renderOnce(game);

      expect(onScreen.renderCount, 1);
      expect(onScreen.screenTopLeft!.dx, closeTo(200, 1e-3));
      expect(offScreen.renderCount, 0);
    });

    test('nested parallax layers add up', () async {
      final game = await makeGame();
      final cloud = _Cloud(position: Vector2(500, 0), size: Vector2(40, 20));
      game.world.add(
        SceneLayerComponent(
          parallaxFactor: Vector2(0.5, 1.0),
          children: [
            SceneLayerComponent(
              parallaxFactor: Vector2(0.75, 1.0),
              children: [cloud],
            ),
          ],
        ),
      );
      await game.ready();

      // Shift = 2000 * 0.5 + 2000 * 0.25 = 1500: drawn at world x = 2000.
      game.camera.viewfinder.position = Vector2(2000, 0);
      game.update(0);
      renderOnce(game);

      expect(cloud.renderCount, 1);
      expect(cloud.screenTopLeft!.dx, closeTo(200, 1e-3));
    });

    test('a SpatialCullGroup is culled where it is drawn', () async {
      final game = await makeGame();
      final onScreen = _Probe(
        position: Vector2(1000, 0),
        size: Vector2(40, 20),
      );
      final offScreen = _Probe(
        position: Vector2(2000, 0),
        size: Vector2(40, 20),
      );
      final near = SpatialCullGroup(children: [onScreen]);
      final far = SpatialCullGroup(children: [offScreen]);
      game.world.add(
        SceneLayerComponent(
          parallaxFactor: Vector2(0.5, 1.0),
          children: [near, far],
        ),
      );
      await game.ready();

      game.camera.viewfinder.position = Vector2(2000, 0);
      game.update(0);
      renderOnce(game);

      expect(onScreen.renderCount, 1);
      expect(near.wasGroupCulledLastFrame, isFalse);
      expect(offScreen.renderCount, 0);
      expect(far.wasGroupCulledLastFrame, isTrue);
    });

    test('a unit-parallax layer culls exactly like the plain world', () async {
      final game = await makeGame();
      final visible = _Cloud(position: Vector2(2000, 0), size: Vector2(40, 20));
      final hidden = _Cloud(position: Vector2(1000, 0), size: Vector2(40, 20));
      game.world.add(SceneLayerComponent(children: [visible, hidden]));
      await game.ready();

      game.camera.viewfinder.position = Vector2(2000, 0);
      game.update(0);
      renderOnce(game);

      expect(visible.renderCount, 1);
      expect(hidden.renderCount, 0);
    });

    test(
      'changing parallaxFactor at runtime takes the layer out of the spatial '
      'index',
      () async {
        final game = await makeGame(spatialIndex: true);
        final leaf = _Probe(position: Vector2(1000, 0), size: Vector2(40, 20));
        final layer = SceneLayerComponent(children: [leaf]);
        game.world.add(layer);
        await game.ready();

        game.camera.viewfinder.position = Vector2(2000, 0);
        game.update(0);
        renderOnce(game);
        // Indexed by its plain world box, which is off screen.
        expect(game.world.spatialIndex.containsIndexed(leaf), isTrue);
        expect(leaf.renderCount, 0);

        layer.parallaxFactor.setValues(0.5, 1.0);
        renderOnce(game);
        expect(game.world.spatialIndex.containsIndexed(leaf), isFalse);
        expect(leaf.renderCount, 1);
        expect(leaf.screenTopLeft!.dx, closeTo(200, 1e-3));
      },
    );
  });
}
