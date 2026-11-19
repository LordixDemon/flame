import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/components.dart' show RectangleComponent, World;
import 'package:flame/game.dart';
import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/widgets.dart' show GlobalKey, RepaintBoundary;
import 'package:flutter_test/flutter_test.dart';

import 'gpu_test_helpers.dart';

const _width = 160.0;
const _height = 120.0;
const _ground2D = Color(0xFF808080);

/// The projection of dimetric 2D art: scene points (i, j, z), z up.
Scene3DProjection _boardProjection() {
  return Scene3DProjection.affine(
    origin: Vector2(0, -18),
    xAxis: Vector2(44, 22),
    yAxis: Vector2(-44, 22),
    zAxis: Vector2(0, -53.889),
    towardsViewer: Vector3(0.6124, 0.6124, 0.5),
    near: -100,
    far: 100,
  );
}

/// A shadow catcher of 10 by 10 in the z = 0 plane, centered on (2, 2, 0).
MeshComponent _catcher() {
  return MeshComponent(
    mesh: PlaneMesh(
      size: Vector2.all(10),
      material: ShadowCatcherMaterial(),
    ),
    position: Vector3(2, 2, 0),
    // The plane faces +y: turned to face +z.
    rotation: Quaternion.axisAngle(Vector3(1, 0, 0), math.pi / 2),
  );
}

/// A red cube floating 1 to 2 above the ground at (2, 2): with the sun along
/// (1, 0, -1), its shadow spans x 2.5 to 4.5 and y 1.5 to 2.5 on the ground.
MeshComponent _cube() {
  return MeshComponent(
    mesh: CuboidMesh(
      size: Vector3.all(1),
      material: opaqueUnlit(const Color(0xFFFF0000)),
    ),
    position: Vector3(2, 2, 1.5),
  );
}

LightComponent _sun({ShadowFit fit = ShadowFit.view, int cascades = 1}) {
  return LightComponent.directional(
    direction: Vector3(1, 0, -1),
    shadows: ShadowSettings(fit: fit, cascades: cascades),
  );
}

/// A lit gray cube resting on the ground at ([i], [j]).
MeshComponent _litCube(double i, double j) {
  return MeshComponent(
    mesh: CuboidMesh(
      size: Vector3.all(1),
      material: SpatialMaterial(
        albedoColor: const Color(0xFFB0B0B0),
        metallic: 0,
        roughness: 0.8,
      ),
    ),
    position: Vector3(i, j, 0.5),
  );
}

/// A spot light with shadows far above the scene, shining away from it: it
/// lights nothing, but puts the frame on the shadow atlas.
LightComponent _farSpot() {
  return LightComponent.spot(
    position: Vector3(2, 2, 50),
    direction: Vector3(0, 0, 1),
    intensity: 0.5,
    range: 2,
    shadows: ShadowSettings(resolution: 256),
  );
}

/// A 2D gray ground under two layers, the lower one (priority 1) and the
/// upper one (priority 2), whose worlds hold `lower` and `upper`.
class _TwoLayers({
  required List<Component3D> lower,
  required List<Component3D> upper,
}) {
  this {
    lowerLayer.world.addAll(lower);
    upperLayer.world.addAll(upper);
    game = FlameGame(
      world: World(
        children: [
          RectangleComponent(
            position: Vector2.all(-5000),
            size: Vector2.all(10000),
            paint: Paint()..color = _ground2D,
          ),
          lowerLayer,
          upperLayer,
        ],
      ),
    );
    game.camera.viewfinder
      ..position = lowerLayer.positionOf(
        lowerLayer.scenePointToLocal(Vector3(3, 2, 0.7)),
      )
      ..zoom = 0.5;
  }

  final Scene3DComponent lowerLayer = Scene3DComponent(
    projection: _boardProjection(),
    priority: 1,
  );
  final Scene3DComponent upperLayer = Scene3DComponent(
    projection: _boardProjection(),
    priority: 2,
  );

  /// Pumps one more frame after [render], and returns its pixels.
  Future<Pixels> renderAgain(WidgetTester tester) async {
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

  GlobalKey? _key;
  late final FlameGame game;

  /// Puts both worlds in [group].
  void share(ShadowGroup group) {
    lowerLayer.world.shadowGroup = group;
    upperLayer.world.shadowGroup = group;
  }

  /// Shows the game, and returns its pixels after a few frames.
  Future<Pixels> render(WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(_width, _height)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = _key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: GameWidget(game: game),
      ),
    );
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    return (await tester.runAsync(() async {
      final image = await boundary.toImage();
      final pixels = await readImage(image);
      image.dispose();
      return pixels;
    }))!;
  }

  /// The red channel of the pixel where the ground point [scenePoint] is.
  int redAt(Pixels pixels, Vector3 scenePoint) {
    final at = game.camera.localToGlobal(
      lowerLayer.positionOf(lowerLayer.scenePointToLocal(scenePoint)),
    );
    return pixels.at(at.x.floor(), at.y.floor()).$1;
  }
}

void main() {
  setUpGpu();

  // Half opaque black over the gray, the catcher's default color.
  final darkened = (0x80 * (1 - 128 / 255)).round();
  final inShadow = [Vector3(3.5, 2, 0), Vector3(4.2, 2.3, 0)];
  final lit = [Vector3(3.5, 3, 0), Vector3(5, 2, 0)];

  group('ShadowGroup', () {
    testGpu('without a group, a layer casts no shadow on another', (
      tester,
    ) async {
      final layers = _TwoLayers(
        lower: [_sun(), _catcher()],
        upper: [_sun(), _cube()],
      );
      final pixels = await layers.render(tester);
      for (final point in [...inShadow, ...lit]) {
        expect(layers.redAt(pixels, point), 0x80, reason: 'at $point');
      }
      expect(layers.upperLayer.renderStats.shadowPasses, 1);
      expect(layers.lowerLayer.renderStats.shadowPasses, 1);
    });

    testGpu('the upper layer casts onto the lower one', (tester) async {
      final layers = _TwoLayers(
        lower: [_sun(), _catcher()],
        upper: [_sun(), _cube()],
      )..share(ShadowGroup());
      final pixels = await layers.render(tester);
      for (final point in inShadow) {
        expect(
          layers.redAt(pixels, point),
          closeTo(darkened, 2),
          reason: 'at $point',
        );
      }
      for (final point in lit) {
        expect(layers.redAt(pixels, point), 0x80, reason: 'at $point');
      }
      // The lower layer, rendered first, renders the map; the upper one
      // reuses it.
      expect(layers.lowerLayer.renderStats.shadowPasses, 1);
      expect(layers.upperLayer.renderStats.shadowPasses, 0);
      expect(layers.upperLayer.renderStats.renderPasses, 1);
    });

    for (final fit in ShadowFit.values) {
      testGpu('the lower layer casts onto the upper one with its map, '
          'fitted to the ${fit.name}', (tester) async {
        // The lower layer, rendered first, only shows the cube: the map,
        // fitted to the whole scene or to what both layers show, covers the
        // ground the upper layer shows.
        final layers = _TwoLayers(
          lower: [
            _sun(fit: fit),
            _cube(),
          ],
          upper: [
            _sun(fit: fit),
            _catcher(),
          ],
        )..share(ShadowGroup());
        final pixels = await layers.render(tester);
        for (final point in inShadow) {
          expect(
            layers.redAt(pixels, point),
            closeTo(darkened, 2),
            reason: 'at $point',
          );
        }
        for (final point in lit) {
          expect(layers.redAt(pixels, point), 0x80, reason: 'at $point');
        }
        expect(layers.lowerLayer.renderStats.shadowPasses, 1);
        expect(layers.upperLayer.renderStats.shadowPasses, 0);
      });
    }

    testGpu('a world that leaves the group no longer casts into its map', (
      tester,
    ) async {
      final group = ShadowGroup();
      final layers = _TwoLayers(
        lower: [_sun(), _catcher()],
        upper: [_sun(), _cube()],
      )..share(group);
      layers.upperLayer.world.shadowGroup = null;
      expect(group.worlds, [layers.lowerLayer.world]);
      final pixels = await layers.render(tester);
      for (final point in inShadow) {
        expect(layers.redAt(pixels, point), 0x80, reason: 'at $point');
      }
    });

    for (final (name, lights) in [
      ('2 cascades', () => [_sun(cascades: 2)]),
      ('4 cascades', () => [_sun(cascades: 4)]),
      ('a second shadow-casting light', () => [_sun(), _farSpot()]),
    ]) {
      testGpu('the upper layer casts onto the lower one with $name', (
        tester,
      ) async {
        final layers = _TwoLayers(
          lower: [...lights(), _catcher()],
          upper: [...lights(), _cube()],
        )..share(ShadowGroup());
        final pixels = await layers.render(tester);
        for (final point in inShadow) {
          expect(
            layers.redAt(pixels, point),
            closeTo(darkened, 2),
            reason: 'at $point',
          );
        }
        for (final point in lit) {
          expect(layers.redAt(pixels, point), 0x80, reason: 'at $point');
        }
        // One atlas pass, reused by the upper layer.
        expect(layers.lowerLayer.renderStats.shadowPasses, 1);
        expect(layers.upperLayer.renderStats.shadowPasses, 0);
        expect(layers.lowerLayer.context.hasShadowAtlas, isTrue);
      });
    }

    testGpu('a spot light casts across the group from its atlas tile', (
      tester,
    ) async {
      // The spot light's tile comes after the sun's in the atlas: the
      // cube's shadow from it falls around y 2 to 5.
      LightComponent spot() => LightComponent.spot(
        position: Vector3(2, 0, 4),
        direction: Vector3(0, 3, -4),
        range: 12,
        outerConeAngle: 0.8,
        shadows: ShadowSettings(resolution: 512),
      );
      final layers = _TwoLayers(
        lower: [_sun(), spot(), _catcher()],
        upper: [_sun(), spot(), _cube()],
      )..share(ShadowGroup());
      final pixels = await layers.render(tester);
      for (final point in [...inShadow, Vector3(2, 4, 0)]) {
        expect(
          layers.redAt(pixels, point),
          closeTo(darkened, 2),
          reason: 'at $point',
        );
      }
      expect(layers.redAt(pixels, Vector3(5, 2, 0)), 0x80);
    });
  });

  group('lights shared through lightsFrom', () {
    testGpu('the upper layer casts with the lights of the lower world', (
      tester,
    ) async {
      final layers = _TwoLayers(
        lower: [_sun(), _catcher()],
        upper: [_cube()],
      )..share(ShadowGroup());
      layers.upperLayer.world.lightsFrom = layers.lowerLayer.world;
      final pixels = await layers.render(tester);
      for (final point in inShadow) {
        expect(
          layers.redAt(pixels, point),
          closeTo(darkened, 2),
          reason: 'at $point',
        );
      }
      for (final point in lit) {
        expect(layers.redAt(pixels, point), 0x80, reason: 'at $point');
      }
      expect(layers.lowerLayer.renderStats.shadowPasses, 1);
      expect(layers.upperLayer.renderStats.shadowPasses, 0);
    });

    testGpu('the lower layer casts with the lights of the upper world', (
      tester,
    ) async {
      // The lower layer renders first, with the borrowed sun, and renders the
      // group's map; the upper one, which holds the sun, reuses it.
      final layers = _TwoLayers(
        lower: [_cube()],
        upper: [
          _sun(fit: ShadowFit.scene),
          _catcher(),
        ],
      )..share(ShadowGroup());
      layers.lowerLayer.world.lightsFrom = layers.upperLayer.world;
      final pixels = await layers.render(tester);
      for (final point in inShadow) {
        expect(
          layers.redAt(pixels, point),
          closeTo(darkened, 2),
          reason: 'at $point',
        );
      }
      for (final point in lit) {
        expect(layers.redAt(pixels, point), 0x80, reason: 'at $point');
      }
      expect(layers.lowerLayer.renderStats.shadowPasses, 1);
      expect(layers.upperLayer.renderStats.shadowPasses, 0);
    });

    testGpu('borrowed lights render exactly as copies of the lights', (
      tester,
    ) async {
      // Two layers that shadow each other: the upper cube's shadow falls on
      // the lower ground, the lower cube's on the upper cube, lit by a sun,
      // a point light and an ambient light.
      List<Component3D> lights() => [
        LightComponent.ambient(intensity: 0.3),
        _sun(fit: ShadowFit.scene),
        LightComponent.point(
          position: Vector3(1, 4, 3),
          intensity: 20,
          color: const Color(0xFFFFC080),
        ),
      ];
      _TwoLayers scene({required bool borrow}) {
        final layers = _TwoLayers(
          lower: [...lights(), _catcher(), _litCube(1, 2)],
          upper: [if (!borrow) ...lights(), _litCube(2.6, 2), _cube()],
        )..share(ShadowGroup());
        if (borrow) {
          layers.upperLayer.world.lightsFrom = layers.lowerLayer.world;
        }
        return layers;
      }

      final copied = await scene(borrow: false).render(tester);
      final borrowed = await scene(borrow: true).render(tester);
      expect(differingPixels(copied, borrowed, tolerance: 0), 0);

      // Without the lights, the upper cubes look different.
      final unlit = _TwoLayers(
        lower: [...lights(), _catcher(), _litCube(1, 2)],
        upper: [_litCube(2.6, 2), _cube()],
      )..share(ShadowGroup());
      expect(
        differingPixels(copied, await unlit.render(tester)),
        greaterThan(100),
      );
    });

    testGpu('a borrowed light keeps out of a layer through its lightMask', (
      tester,
    ) async {
      // The red light reaches the passes of mask 0x2 only; the upper layer
      // renders with mask 0x1.
      _TwoLayers scene({required bool redLight}) {
        final layers = _TwoLayers(
          lower: [
            LightComponent.ambient(intensity: 0.5),
            if (redLight)
              LightComponent.directional(
                direction: Vector3(-1, -1, -1),
                color: const Color(0xFFFF0000),
                intensity: 3,
                lightMask: 0x2,
              ),
          ],
          upper: [_litCube(2, 2)],
        );
        layers.upperLayer
          ..cameraMask = 0x1
          ..world.lightsFrom = layers.lowerLayer.world;
        return layers;
      }

      final withRed = await scene(redLight: true).render(tester);
      final withoutRed = await scene(redLight: false).render(tester);
      expect(differingPixels(withRed, withoutRed, tolerance: 0), 0);
    });

    testGpu('a retained borrower renders again when a lent light changes', (
      tester,
    ) async {
      final sun = _sun(fit: ShadowFit.scene);
      final litCube = _litCube(4, 0);
      final layers = _TwoLayers(
        lower: [_cube(), litCube],
        upper: [sun, _catcher()],
      )..share(ShadowGroup());
      layers.lowerLayer
        ..cacheMode = Scene3DCacheMode.retained
        ..world.lightsFrom = layers.upperLayer.world;
      final before = await layers.render(tester);
      expect(
        layers.redAt(before, inShadow.first),
        closeTo(darkened, 2),
      );
      final hits = layers.lowerLayer.cacheHitCount;
      await layers.renderAgain(tester);
      expect(layers.lowerLayer.cacheHitCount, hits + 1);

      // A change of the lender that is not a light leaves the borrower's
      // image alone.
      layers.upperLayer.world.fog = FogSettings();
      await layers.renderAgain(tester);
      expect(layers.lowerLayer.cacheHitCount, hits + 2);

      // Dimming the lent sun, which moves no shadow, renders the borrower
      // again: its lit cube darkens.
      sun.source.intensity = 0.25;
      final dimmed = await layers.renderAgain(tester);
      expect(layers.lowerLayer.cacheHitCount, hits + 2);
      expect(differingPixels(before, dimmed), greaterThan(50));

      // Turning the lent sun renders the borrower again, and the shadow
      // moves (the sun now travels along -x).
      (sun.source as DirectionalLight)
        ..intensity = 1
        ..direction = Vector3(-1, 0, -1);
      final after = await layers.renderAgain(tester);
      expect(layers.lowerLayer.cacheHitCount, hits + 2);
      expect(layers.redAt(after, inShadow.first), 0x80);
      expect(layers.redAt(after, Vector3(0, 2, 0)), closeTo(darkened, 2));
    });
  });
}
