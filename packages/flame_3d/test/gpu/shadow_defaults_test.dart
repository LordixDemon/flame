import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
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

// The shadows of the default settings, pixel for pixel: the goldens were
// rendered before ShadowSettings.cacheStillCasters existed, and must not
// change while it is off. The environment variable UPDATE_SHADOW_GOLDENS=1
// writes them again.

const _width = 160.0;
const _height = 120.0;

final _update = Platform.environment['UPDATE_SHADOW_GOLDENS'] == '1';

/// The scenes the goldens hold.
enum _Case() {
  sun,
  packedSun,
  cascadesAndSpot,
  sunAndPoint,
  cachedSun,
  group,
}

ShadowSettings _settings(_Case scene, {bool cascades = false}) =>
    ShadowSettings(
      resolution: 256,
      fit: ShadowFit.scene,
      encoding: scene == _Case.packedSun
          ? ShadowMapEncoding.rgba8
          : ShadowMapEncoding.auto,
      cascades: cascades ? 2 : 1,
      cacheWhenStatic: scene == _Case.cachedSun,
    );

Scene3DComponent _layer() => Scene3DComponent(
  projection: Scene3DProjection.affine(
    origin: Vector2(80, 40),
    xAxis: Vector2(12, 6),
    yAxis: Vector2(-12, 6),
    zAxis: Vector2(0, -14),
    towardsViewer: Vector3(1, 1, 1.2),
    near: -60,
    far: 60,
  ),
);

/// Builds [scene] into [layer] (and [second] for a group), returning the
/// caster the frames move.
MeshComponent _build(_Case scene, Scene3DComponent layer, World3D? second) {
  final world = layer.world;
  world.addAll([
    LightComponent.ambient(intensity: 0.35),
    LightComponent.directional(
      direction: Vector3(0.45, -0.3, -1),
      intensity: 0.8,
      shadows: _settings(scene, cascades: scene == _Case.cascadesAndSpot),
    ),
    if (scene == _Case.cascadesAndSpot)
      LightComponent.spot(
        position: Vector3(-2, -2, 6),
        direction: Vector3(0.3, 0.3, -1),
        intensity: 3,
        range: 14,
        outerConeAngle: 0.9,
        shadows: _settings(scene),
      ),
    if (scene == _Case.sunAndPoint)
      LightComponent.point(
        position: Vector3(0.5, 0.5, 2.6),
        intensity: 4,
        range: 8,
        shadows: _settings(scene),
      ),
    MeshComponent(
      mesh: PlaneMesh(
        size: Vector2.all(12),
        material: StylizedMaterial(albedoColor: const Color(0xFFD8D0C0)),
      ),
      rotation: Quaternion.axisAngle(Vector3(1, 0, 0), math.pi / 2),
    ),
  ]);
  if (second != null) {
    final shadows = ShadowGroup();
    world.shadowGroup = shadows;
    second
      ..shadowGroup = shadows
      ..lightsFrom = world;
  }
  final materials = [
    for (final color in const [
      Color(0xFFC05040),
      Color(0xFF4070C0),
      Color(0xFF50A050),
    ])
      StylizedMaterial(albedoColor: color),
  ];
  for (var i = 0; i < 4; i++) {
    for (var j = 0; j < 4; j++) {
      final height = 0.4 + ((i * 7 + j * 3) % 5) * 0.25;
      final cylinder = (i + j).isOdd;
      ((second != null && j.isOdd) ? second : world).add(
        MeshComponent(
          mesh: cylinder
              ? CylinderMesh(
                  radius: 0.3,
                  height: height,
                  material: materials[(i * j) % 3],
                )
              : CuboidMesh(
                  size: Vector3(0.6, 0.6, height),
                  material: materials[(i + j) % 3],
                ),
          position: Vector3(-4 + i * 2.5, -4 + j * 2.5, height / 2),
          rotation: cylinder
              ? Quaternion.axisAngle(Vector3(1, 0, 0), math.pi / 2)
              : null,
        ),
      );
    }
  }
  final mover = MeshComponent(
    mesh: CuboidMesh(
      size: Vector3(0.5, 0.5, 1.2),
      material: StylizedMaterial(albedoColor: const Color(0xFFE0B030)),
    ),
    position: Vector3(-3, -1, 0.6),
  );
  (second ?? world).add(mover);
  return mover;
}

void main() {
  setUpGpu();

  group('Default shadows', () {
    for (final scene in _Case.values) {
      testGpu('${scene.name}: the same pixels as before still casters could '
          'be kept', (tester) async {
        final layer = _layer();
        final second = scene == _Case.group ? _layer() : null;
        final mover = _build(scene, layer, second?.world);
        final game = FlameGame(
          world: World(
            children: [
              RectangleComponent(
                size: Vector2(_width, _height),
                paint: Paint()..color = const Color(0xFF203040),
              ),
              layer,
              ?second,
            ],
          ),
        );
        game.camera.viewfinder.position = Vector2(_width / 2, _height / 2);
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
        // A few frames with the caster moving, then still (a cached map is
        // reused in the last one).
        for (var frame = 0; frame < 5; frame++) {
          if (frame < 3) {
            mover.position.x = -3 + frame * 0.6;
          }
          await tester.pump(const Duration(milliseconds: 16));
        }
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final path = 'test/gpu/goldens/shadows_default_${scene.name}.png';
        final pixels = (await tester.runAsync(() async {
          final image = await boundary.toImage();
          if (_update) {
            final png = await image.toByteData(format: ui.ImageByteFormat.png);
            File(path).writeAsBytesSync(png!.buffer.asUint8List());
          }
          final out = await readImage(image);
          image.dispose();
          return out;
        }))!;
        final golden = await loadPng(tester, path);
        expect(differingPixels(pixels, golden, tolerance: 0), 0);
        // The shadows show: pixels of the ground in the shadow of the sun.
        expect(
          pixels.count(
            (r, g, b, a) =>
                r >= 70 &&
                r <= 170 &&
                (r - g).abs() < 16 &&
                r > b &&
                r - b < 30,
          ),
          greaterThan(300),
        );
      });
    }
  });
}
