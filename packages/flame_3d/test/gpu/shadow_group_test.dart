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
    final key = GlobalKey();
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

    testGpu('the lower layer casts onto the upper one with its map', (
      tester,
    ) async {
      // The lower layer only shows the cube: a map fitted to the whole scene
      // covers the ground the upper layer shows.
      final layers = _TwoLayers(
        lower: [
          _sun(fit: ShadowFit.scene),
          _cube(),
        ],
        upper: [
          _sun(fit: ShadowFit.scene),
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
}
