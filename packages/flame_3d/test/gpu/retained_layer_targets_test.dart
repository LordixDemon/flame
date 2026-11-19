import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/components.dart' show RectangleComponent, World;
import 'package:flame/game.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/src/graphics/backend/flutter_gpu/gpu_backend.dart'
    show debugColorTextureCount;
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/widgets.dart' show GlobalKey, RepaintBoundary;
import 'package:flutter_test/flutter_test.dart';

import 'gpu_test_helpers.dart';

Scene3DProjection _isoProjection() => Scene3DProjection.affine(
  origin: Vector2(64, 64),
  xAxis: Vector2(24, 12),
  yAxis: Vector2(-24, 12),
  zAxis: Vector2(0, -28),
  towardsViewer: Vector3(1, 1, 1),
  near: -50,
  far: 50,
);

/// A game showing [layer] over a 2D background that is repainted on every
/// [_Stage.frame], so that Flutter paints every pumped frame.
class _Stage(final Scene3DComponent layer) {
  final RectangleComponent background = RectangleComponent(
    size: Vector2.all(128),
    paint: Paint()..color = const Color(0xFF406040),
  );
  late final FlameGame game = FlameGame(
    world: World(children: [background, layer]),
  )..camera.viewfinder.position = Vector2(64, 64);
  final GlobalKey _key = GlobalKey();
  var _shade = 0;

  Future<void> start(WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(128, 128)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      RepaintBoundary(
        key: _key,
        child: GameWidget(game: game),
      ),
    );
    await frame(tester);
  }

  Future<void> frame(WidgetTester tester) async {
    // A different shade of green in the low bits keeps the 2D picture
    // changing without moving anything.
    _shade = (_shade + 1) % 2;
    background.paint.color = Color(0xFF406040 + _shade);
    await tester.pump(const Duration(milliseconds: 16));
  }

  Future<Pixels> pixels(WidgetTester tester) async {
    final boundary =
        _key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    return (await tester.runAsync(() async {
      final image = await boundary.toImage();
      final data = await image.toByteData();
      final out = Pixels(image.width, image.height, data!.buffer.asUint8List());
      image.dispose();
      return out;
    }))!;
  }
}

bool _red(int r, int g, int b, int a) => r > 180 && g < 90 && b < 90;
bool _green(int r, int g, int b, int a) => g > 180 && r < 90 && b < 90;

MeshComponent _cube(Color color, {double size = 1.2}) => MeshComponent(
  mesh: CuboidMesh(
    size: Vector3.all(size),
    material: UnlitMaterial(albedoColor: color),
  ),
);

void main() {
  setUpGpu();

  group('Scene3DCacheMode.retained', () {
    testGpu('keeps a target per path when post-processing toggles across a '
        'size change', (tester) async {
      final layer = Scene3DComponent(
        projection: _isoProjection(),
        cacheMode: Scene3DCacheMode.retained,
      );
      layer.world.add(_cube(const Color(0xFFE02020)));
      final stage = _Stage(layer);
      await stage.start(tester);
      await stage.frame(tester);

      // Bloom that adds nothing visible, at twice the zoom: the layer covers
      // a larger part of the screen and renders into the bloom target.
      layer.bloom = BloomSettings(threshold: 100);
      stage.game.camera.viewfinder.zoom = 2;
      await stage.frame(tester);
      expect(layer.renderStats.renderPasses, greaterThan(0));

      // Without bloom again the scene target must follow the new size.
      layer.bloom = null;
      await stage.frame(tester);
      await stage.frame(tester);
      final retained = (await stage.pixels(tester)).count(_red);

      layer.cacheMode = Scene3DCacheMode.none;
      await stage.frame(tester);
      await stage.frame(tester);
      final reference = (await stage.pixels(tester)).count(_red);

      expect(reference, greaterThan(1000));
      expect(retained, reference);
    });

    testGpu('does not render into the texture of the image it reused', (
      tester,
    ) async {
      final cube = _cube(const Color(0xFFE02020));
      final layer = Scene3DComponent(
        projection: _isoProjection(),
        cacheMode: Scene3DCacheMode.retained,
      );
      layer.world.add(cube);
      final stage = _Stage(layer);
      await stage.start(tester);
      for (var i = 0; i < 4; i++) {
        await stage.frame(tester);
      }
      expect(layer.cacheHitCount, greaterThanOrEqualTo(3));
      final target = layer.debugRetainedTarget!;
      expect(debugColorTextureCount(target), 1);

      // The previous frame drew the reused image: the new render takes
      // another color texture instead of the one Flutter may still draw.
      cube.position.x = 0.5;
      await stage.frame(tester);
      expect(layer.renderStats.renderPasses, 1);
      expect(layer.debugRetainedTarget, same(target));
      expect(debugColorTextureCount(target), 2);
    });

    testGpu('renders again after changes made through setters', (
      tester,
    ) async {
      final cube = MeshComponent(
        mesh: CuboidMesh(
          size: Vector3.all(1.2),
          material: UnlitMaterial(),
        ),
        color: const Color(0xFFE02020),
      );
      final layer = Scene3DComponent(
        projection: _isoProjection(),
        cacheMode: Scene3DCacheMode.retained,
      );
      layer.world.add(cube);
      final stage = _Stage(layer);
      await stage.start(tester);
      await stage.frame(tester);
      await stage.frame(tester);
      expect(layer.renderStats.renderPasses, 0);
      expect((await stage.pixels(tester)).count(_red), greaterThan(500));

      cube.color = const Color(0xFF20E020);
      await stage.frame(tester);
      expect(layer.renderStats.renderPasses, 1);
      await stage.frame(tester);
      final pixels = await stage.pixels(tester);
      expect(pixels.count(_red), 0);
      expect(pixels.count(_green), greaterThan(500));

      // Writing the same values again keeps the image.
      cube
        ..color = const Color(0xFF20E020)
        ..position.setZero();
      await stage.frame(tester);
      expect(layer.renderStats.renderPasses, 0);

      // The layer's own camera mask, which no setter of the world sees.
      cube.cameraMask = 0x01;
      await stage.frame(tester);
      await stage.frame(tester);
      expect((await stage.pixels(tester)).count(_green), greaterThan(500));
      layer.cameraMask = 0x02;
      await stage.frame(tester);
      expect(layer.renderStats.renderPasses, 1);
      await stage.frame(tester);
      expect((await stage.pixels(tester)).count(_green), 0);
    });

    testGpu('and the static shadow cache follow castsShadows and lights', (
      tester,
    ) async {
      final casterMaterial = StylizedMaterial(
        albedoColor: const Color(0xFFE0C080),
      );
      final caster = MeshComponent(
        mesh: CuboidMesh(size: Vector3.all(1.0), material: casterMaterial),
        position: Vector3(0, 0, 0.5),
      );
      final ground = MeshComponent(
        mesh: PlaneMesh(
          size: Vector2.all(8),
          material: ShadowCatcherMaterial(color: const Color(0xC0000000)),
        ),
        rotation: Quaternion.axisAngle(Vector3(1, 0, 0), math.pi / 2),
      );
      final sun = DirectionalLight(
        direction: Vector3(0.5, -0.5, -1.0),
        shadows: ShadowSettings(cacheWhenStatic: true),
      );
      final layer = Scene3DComponent(
        projection: _isoProjection(),
        cacheMode: Scene3DCacheMode.retained,
      );
      layer.world.addAll([
        LightComponent.ambient(intensity: 0.4),
        LightComponent(source: sun),
        ground,
        caster,
      ]);
      final stage = _Stage(layer);
      await stage.start(tester);
      await stage.frame(tester);
      await stage.frame(tester);
      expect(layer.renderStats.renderPasses, 0);

      bool shadowed(int r, int g, int b, int a) => g < 40 && r < 40;
      final withShadow = (await stage.pixels(tester)).count(shadowed);
      expect(withShadow, greaterThan(60));

      caster.castsShadows = false;
      await stage.frame(tester);
      expect(layer.renderStats.shadowPasses, 1);
      await stage.frame(tester);
      expect((await stage.pixels(tester)).count(shadowed), lessThan(10));

      caster.castsShadows = true;
      await stage.frame(tester);
      await stage.frame(tester);
      expect((await stage.pixels(tester)).count(shadowed), withShadow);

      casterMaterial.castsShadows = false;
      await stage.frame(tester);
      await stage.frame(tester);
      expect((await stage.pixels(tester)).count(shadowed), lessThan(10));
      casterMaterial.castsShadows = null;

      // Turning the sun moves the shadow.
      await stage.frame(tester);
      final before = await stage.pixels(tester);
      sun.direction = Vector3(-0.5, -0.5, -1.0);
      await stage.frame(tester);
      expect(layer.renderStats.shadowPasses, 1);
      await stage.frame(tester);
      final after = await stage.pixels(tester);
      var moved = 0;
      for (var y = 0; y < 128; y++) {
        for (var x = 0; x < 128; x++) {
          if (shadowed(
                before.at(x, y).$1,
                before.at(x, y).$2,
                before.at(x, y).$3,
                0,
              ) !=
              shadowed(
                after.at(x, y).$1,
                after.at(x, y).$2,
                after.at(x, y).$3,
                0,
              )) {
            moved++;
          }
        }
      }
      expect(moved, greaterThan(20));
    });
  });
}
