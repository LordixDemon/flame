import 'dart:ui';

import 'package:flame/components.dart'
    show Component, RectangleComponent, World;
import 'package:flame/game.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/particles.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/widgets.dart' show GlobalKey, RepaintBoundary;
import 'package:flutter_test/flutter_test.dart';

import 'gpu_test_helpers.dart';

const _red = Color(0xFFFF0000);

Scene3DProjection _isoProjection() => Scene3DProjection.affine(
  origin: Vector2(64, 64),
  xAxis: Vector2(24, 12),
  yAxis: Vector2(-24, 12),
  zAxis: Vector2(0, -28),
  towardsViewer: Vector3(1, 1, 1),
  near: -50,
  far: 50,
);

/// Runs [action] once in its update, after the components added before it
/// (game logic later in the frame than a particle system's update).
class _Later() extends Component {
  void Function()? action;

  @override
  void update(double dt) {
    final pending = action;
    action = null;
    pending?.call();
  }
}

/// A gray pillar standing at ([i], [j]).
MeshComponent _pillar(double i, double j) => MeshComponent(
  mesh: CuboidMesh(
    size: Vector3(0.6, 0.6, 2),
    material: opaqueUnlit(const Color(0xFF606060)),
  ),
  position: Vector3(i, j, 0),
);

/// A retained layer holding two gray pillars and, between them, a particle
/// system of solid red billboards that stand still and live long, with a
/// [_Later] after them. The particles spawned at the origin stay inside the
/// bounds of the pillars, so they do not change the part of the screen the
/// layer covers.
class _Scene() {
  this {
    layer.world.addAll([
      _pillar(1, -1),
      _pillar(-1, 1),
      system,
      later,
    ]);
    game = FlameGame(world: World(children: [ticker2D, layer]));
    game.camera.viewfinder.position = Vector2(64, 64);
  }

  final Scene3DComponent layer = Scene3DComponent(
    projection: _isoProjection(),
    cacheMode: Scene3DCacheMode.retained,
  );

  final ParticleSystem3D system = ParticleSystem3D(
    capacity: 64,
    material: ParticleMaterial(sprite: ParticleSprite.texture),
    emitters: [
      ParticleEmitter3D(
        lifespan: (100, 100),
        size: (0.8, 0.8),
        colors: const [_red],
      ),
    ],
  );

  final _Later later = _Later();

  // An animated 2D sibling, so that Flutter paints every pumped frame.
  final RectangleComponent ticker2D = RectangleComponent(
    size: Vector2.all(2),
    paint: Paint()..color = const Color(0xFF202020),
  );

  late final FlameGame game;
  GlobalKey? _key;

  Future<void> show(WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(128, 128)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = _key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: GameWidget(game: game),
      ),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }

  /// Pumps one frame and returns its pixels.
  Future<Pixels> frame(WidgetTester tester) async {
    ticker2D.position.x = ticker2D.position.x == 0 ? 2 : 0;
    await tester.pump(const Duration(milliseconds: 16));
    final boundary =
        _key!.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    return (await tester.runAsync(() async {
      final image = await boundary.toImage();
      final pixels = await readImage(image);
      image.dispose();
      return pixels;
    }))!;
  }
}

int _redPixels(Pixels pixels) =>
    pixels.count((r, g, b, a) => r > 200 && g < 60 && b < 60);

void main() {
  setUpGpu();

  group('A retained layer sees particles spawned outside update', () {
    testGpu('a burst later in the frame than the idle system', (
      tester,
    ) async {
      final scene = _Scene();
      await scene.show(tester);
      await scene.frame(tester);
      expect(scene.layer.renderStats.renderPasses, 0);
      expect(_redPixels(await scene.frame(tester)), 0);

      // The system, without particles, did not mark its world in its update;
      // the burst comes after it in the same frame.
      scene.later.action = () => scene.system.burst(1, at: Vector3.zero());
      final pixels = await scene.frame(tester);
      expect(scene.system.particleCount, 1);
      expect(scene.layer.renderStats.renderPasses, isNot(0));
      expect(_redPixels(pixels), greaterThan(50));
    });

    testGpu('particles spawned into a paused system', (tester) async {
      final scene = _Scene();
      scene.system.paused = true;
      await scene.show(tester);
      await scene.frame(tester);
      expect(scene.layer.renderStats.renderPasses, 0);

      scene.system.spawn(position: Vector3.zero(), size: 0.8, color: _red);
      final pixels = await scene.frame(tester);
      expect(scene.layer.renderStats.renderPasses, isNot(0));
      expect(_redPixels(pixels), greaterThan(50));

      // A paused system marks nothing more: the image is reused.
      await scene.frame(tester);
      expect(scene.layer.renderStats.renderPasses, 0);
    });

    testGpu('clearing the particles', (tester) async {
      final scene = _Scene();
      await scene.show(tester);
      scene.system.burst(1, at: Vector3.zero());
      expect(_redPixels(await scene.frame(tester)), greaterThan(50));

      // Cleared between two frames: the system's next update has nothing to
      // mark.
      scene.system.clear();
      final pixels = await scene.frame(tester);
      expect(scene.layer.renderStats.renderPasses, isNot(0));
      expect(_redPixels(pixels), 0);
      await scene.frame(tester);
      expect(scene.layer.renderStats.renderPasses, 0);
    });
  });
}
