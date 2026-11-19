import 'dart:ui';

import 'package:flame/game.dart' show GameWidget;
import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/game.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter/widgets.dart' show ObjectKey;
import 'package:flutter_test/flutter_test.dart';

import 'gpu_test_helpers.dart';

final Matrix4 _view = Matrix4.identity()
  ..setAsViewMatrix(Vector3(0, 0, 6), Vector3.zero(), Vector3(0, 1, 0));
final Matrix4 _projection = Matrix4.identity()
  ..setAsPerspective(30, 1, 0.5, 30);

Future<Pixels> _render(WidgetTester tester, World3D world) async {
  final game = FlameGame3D(world: world);
  await tester.pumpWidget(GameWidget(key: ObjectKey(game), game: game));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
  return (await tester.runAsync(() async {
    final device = GraphicsDevice();
    final context = RenderContext3D(device);
    device.begin();
    final image = world.renderToImage(
      const Size(128, 128),
      view: _view,
      projection: _projection,
      clearValue: const Color(0xFF000000),
      device: device,
      context: context,
    );
    device.end();
    final pixels = await readImage(image);
    image.dispose();
    return pixels;
  }))!;
}

/// The mean of the red channel over a 5x5 square around ([x], [y]).
double _meanRed(Pixels pixels, int x, int y) {
  var sum = 0;
  for (var dy = -2; dy <= 2; dy++) {
    for (var dx = -2; dx <= 2; dx++) {
      sum += pixels.at(x + dx, y + dy).$1;
    }
  }
  return sum / 25;
}

void main() {
  setUpGpu();

  group('LightProbeGrid3D', () {
    testGpu('lights the side of a surface that faces the baked light', (
      tester,
    ) async {
      // A directional light travelling towards -X: every probe is the same,
      // so only the normal tells the two sides apart.
      final grid = LightProbeGrid3D.bakeFromLights(
        bounds: Aabb3.minMax(Vector3.all(-2), Vector3.all(2)),
        resolutionX: 3,
        resolutionY: 3,
        resolutionZ: 3,
        ambientIntensity: 0,
        lights: [
          Light(
            position: Vector3.zero(),
            source: DirectionalLight(
              intensity: 3,
              direction: Vector3(-1, 0, 0),
            ),
          ),
        ],
      );
      final towards = grid.sampleIrradiance(Vector3.zero(), Vector3(1, 0, 0));
      final away = grid.sampleIrradiance(Vector3.zero(), Vector3(-1, 0, 0));
      expect(towards.x, greaterThan(away.x * 4));

      final pixels = await _render(
        tester,
        World3D(
          lightProbeGrid: grid,
          children: [
            LightComponent.ambient(intensity: 0),
            MeshComponent(
              mesh: SphereMesh(
                radius: 0.9,
                material: SpatialMaterial(metallic: 0, roughness: 1),
              ),
            ),
          ],
        ),
      );

      // The sphere spans about x = 35..93 at y = 64.
      final lit = _meanRed(pixels, 88, 64);
      final unlit = _meanRed(pixels, 40, 64);
      expect(lit, greaterThan(60));
      expect(lit, greaterThan(unlit + 40));
    });
  });
}
