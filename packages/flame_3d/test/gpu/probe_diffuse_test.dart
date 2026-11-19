import 'dart:typed_data';
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

/// A white, fully diffuse sphere at the origin.
MeshComponent _sphere({EnvironmentProbe3D? probe}) => MeshComponent(
  mesh: SphereMesh(
    radius: 0.9,
    material: SpatialMaterial(
      metallic: 0,
      roughness: 1,
      environmentProbe: probe,
      // Diffuse light only.
      environmentIntensity: 0,
    ),
  ),
);

/// Expects the sphere (about x, y = 35..93) to look the same in [a] and [b]:
/// at its top, middle and bottom.
void _expectSameSphere(Pixels a, Pixels b) {
  for (final y in [44, 64, 84]) {
    final (ar, ag, ab, _) = a.at(64, y);
    final (br, bg, bb, _) = b.at(64, y);
    expect(ar, closeTo(br, 4), reason: 'red at y = $y');
    expect(ag, closeTo(bg, 4), reason: 'green at y = $y');
    expect(ab, closeTo(bb, 4), reason: 'blue at y = $y');
  }
}

void main() {
  setUpGpu();

  group('Probe diffuse light', () {
    testGpu('a uniform environment probe lights like a hemisphere light of its '
        'color', (tester) async {
      const w = 32;
      const h = 16;
      final bytes = Uint8List(w * h * 4);
      for (var i = 0; i < w * h; i++) {
        bytes
          ..[i * 4] = 128
          ..[i * 4 + 1] = 128
          ..[i * 4 + 2] = 128
          ..[i * 4 + 3] = 255;
      }
      final probe = EnvironmentProbe3D.fromEquirectangular(
        ByteData.sublistView(bytes),
        width: w,
        height: h,
        // Linear panorama: 128 is 0.502, the value of 0xFF808080.
        srgb: false,
      );

      final withProbe = await _render(
        tester,
        World3D(
          children: [
            LightComponent.ambient(intensity: 0),
            _sphere(probe: probe),
          ],
        ),
      );
      final withHemisphere = await _render(
        tester,
        World3D(
          children: [
            LightComponent.hemisphere(
              skyColor: const Color(0xFF808080),
              intensity: 1,
            ),
            _sphere(),
          ],
        ),
      );
      expect(withHemisphere.at(64, 64).$1, greaterThan(60));
      _expectSameSphere(withProbe, withHemisphere);
    });

    testGpu('a grid baked from ambient light lights like that ambient light', (
      tester,
    ) async {
      final grid = LightProbeGrid3D.bakeFromLights(
        bounds: Aabb3.minMax(Vector3.all(-2), Vector3.all(2)),
        lights: const [],
        ambientIntensity: 0.5,
      );
      final withGrid = await _render(
        tester,
        World3D(
          lightProbeGrid: grid,
          children: [LightComponent.ambient(intensity: 0), _sphere()],
        ),
      );
      final withAmbient = await _render(
        tester,
        World3D(
          children: [LightComponent.ambient(intensity: 0.5), _sphere()],
        ),
      );
      expect(withAmbient.at(64, 64).$1, greaterThan(60));
      _expectSameSphere(withGrid, withAmbient);
    });

    testGpu('a grid baked from a hemisphere light lights like that light', (
      tester,
    ) async {
      Light hemisphere() => Light(
        position: Vector3.zero(),
        source: HemisphereLight(
          skyColor: const Color(0xFFE04020),
          groundColor: const Color(0xFF2040A0),
        ),
      );
      final grid = LightProbeGrid3D.bakeFromLights(
        bounds: Aabb3.minMax(Vector3.all(-2), Vector3.all(2)),
        lights: [hemisphere()],
        ambientIntensity: 0,
      );
      final withGrid = await _render(
        tester,
        World3D(
          lightProbeGrid: grid,
          children: [LightComponent.ambient(intensity: 0), _sphere()],
        ),
      );
      final withLight = await _render(
        tester,
        World3D(
          children: [
            LightComponent.hemisphere(
              skyColor: const Color(0xFFE04020),
              groundColor: const Color(0xFF2040A0),
            ),
            _sphere(),
          ],
        ),
      );
      expect(withLight.at(64, 44).$1, greaterThan(withLight.at(64, 84).$1));
      _expectSameSphere(withGrid, withLight);
    });
  });
}
