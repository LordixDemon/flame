import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/components.dart' show RectangleComponent, World;
import 'package:flame/game.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/debug.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/widgets.dart' show GlobalKey, RepaintBoundary;
import 'package:flutter_test/flutter_test.dart';

import 'gpu_test_helpers.dart';

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

/// Shows the [layer] over a gray 2D ground in a 160x120 view and returns the
/// pixels of the third frame.
Future<Pixels> _renderLayer(WidgetTester tester, Scene3DComponent layer) async {
  final game = FlameGame(
    world: World(
      children: [
        RectangleComponent(
          position: Vector2.all(-5000),
          size: Vector2.all(10000),
          paint: Paint()..color = _ground2D,
        ),
        layer,
      ],
    ),
  );
  game.camera.viewfinder
    ..position = layer.positionOf(layer.scenePointToLocal(Vector3(3, 2, 0.7)))
    ..zoom = 0.5;
  tester.view
    ..physicalSize = const Size(160, 120)
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

void main() {
  setUpGpu();

  group('DebugRenderer3D', () {
    /// A shadow catcher ground, a red cube floating above it and a sun
    /// casting shadows, with [extra] components added to the world.
    Future<Pixels> renderShadowScene(
      WidgetTester tester, {
      List<Component3D> extra = const [],
    }) {
      final layer = Scene3DComponent(projection: _boardProjection());
      layer.world.addAll([
        LightComponent.directional(
          direction: Vector3(1, 0, -1),
          shadows: ShadowSettings(),
        ),
        MeshComponent(
          mesh: PlaneMesh(
            size: Vector2.all(10),
            material: ShadowCatcherMaterial(),
          ),
          position: Vector3(2, 2, 0),
          rotation: Quaternion.axisAngle(Vector3(1, 0, 0), math.pi / 2),
        ),
        MeshComponent(
          mesh: CuboidMesh(
            size: Vector3.all(1),
            material: opaqueUnlit(const Color(0xFFFF0000)),
          ),
          position: Vector3(2, 2, 1.5),
        ),
        ...extra,
      ]);
      return _renderLayer(tester, layer);
    }

    int shadowPixels(Pixels pixels) =>
        pixels.count((r, g, b, a) => r < 0x70 && g < 0x70 && b < 0x70);

    testGpu('does not change the sun shadows it is added to', (tester) async {
      final plain = await renderShadowScene(tester);
      final shadowed = shadowPixels(plain);
      // The cube's shadow on the catcher: about 2 by 1 scene units.
      expect(shadowed, greaterThan(300));

      final withDebug = await renderShadowScene(
        tester,
        extra: [
          DebugRenderer3D(
            showObjectBounds: false,
            showSkeletons: false,
            showLightVolumes: false,
          ),
        ],
      );
      expect(shadowPixels(withDebug), shadowed);
      expect(differingPixels(plain, withDebug), 0);
    });
  });
}
