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

/// A probe whose panorama is [r], [g], [b] in every direction.
EnvironmentProbe3D _uniformProbe(int r, int g, int b, {bool srgb = true}) {
  const w = 32;
  const h = 16;
  final bytes = Uint8List(w * h * 4);
  for (var i = 0; i < w * h; i++) {
    bytes
      ..[i * 4] = r
      ..[i * 4 + 1] = g
      ..[i * 4 + 2] = b
      ..[i * 4 + 3] = 255;
  }
  return EnvironmentProbe3D.fromEquirectangular(
    ByteData.sublistView(bytes),
    width: w,
    height: h,
    srgb: srgb,
  );
}

SpatialMaterial _mirror({EnvironmentProbe3D? probe}) => SpatialMaterial(
  metallic: 1,
  roughness: 0.05,
  environmentProbe: probe,
);

final Matrix4 _view = Matrix4.identity()
  ..setAsViewMatrix(Vector3(0, 0, 6), Vector3.zero(), Vector3(0, 1, 0));
final Matrix4 _projection = Matrix4.identity()
  ..setAsPerspective(50, 1, 0.5, 30);

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

/// Two volumes side by side: a red one around x = -1.5 and a blue one around
/// x = 1.5, which do not overlap.
List<ReflectionProbeVolume3D> _redAndBlueVolumes() => [
  ReflectionProbeVolume3D(
    probe: _uniformProbe(255, 0, 0),
    position: Vector3(-1.5, 0, 0),
    extents: Vector3(1.4, 2, 2),
    blendDistance: 0,
  ),
  ReflectionProbeVolume3D(
    probe: _uniformProbe(0, 0, 255),
    position: Vector3(1.5, 0, 0),
    extents: Vector3(1.4, 2, 2),
    blendDistance: 0,
  ),
];

void main() {
  setUpGpu();

  group('ReflectionProbeVolume3D', () {
    testGpu('instanced objects of one material reflect their own volume', (
      tester,
    ) async {
      // One mesh and one material: the two spheres are one instanced draw.
      final mesh = SphereMesh(radius: 0.6, material: _mirror());
      final pixels = await _render(
        tester,
        World3D(
          children: [
            ..._redAndBlueVolumes(),
            MeshComponent(position: Vector3(-1.5, 0, 0), mesh: mesh),
            MeshComponent(position: Vector3(1.5, 0, 0), mesh: mesh),
          ],
        ),
      );

      final (lr, _, lb, _) = pixels.at(35, 64);
      final (rr, _, rb, _) = pixels.at(92, 64);
      expect(lr, greaterThan(100), reason: 'left sphere reflects red');
      expect(lb, lessThan(30));
      expect(rb, greaterThan(100), reason: 'right sphere reflects blue');
      expect(rr, lessThan(30));
    });

    testGpu('separate surfaces of one material reflect their own volume', (
      tester,
    ) async {
      final material = _mirror();
      final pixels = await _render(
        tester,
        World3D(
          children: [
            ..._redAndBlueVolumes(),
            MeshComponent(
              position: Vector3(-1.5, 0, 0),
              mesh: SphereMesh(radius: 0.6, material: material),
            ),
            MeshComponent(
              position: Vector3(1.5, 0, 0),
              mesh: SphereMesh(radius: 0.6, material: material),
            ),
          ],
        ),
      );

      final (lr, _, lb, _) = pixels.at(35, 64);
      final (rr, _, rb, _) = pixels.at(92, 64);
      expect(lr, greaterThan(100));
      expect(lb, lessThan(30));
      expect(rb, greaterThan(100));
      expect(rr, lessThan(30));
    });

    testGpu('an object outside every volume reflects none of them', (
      tester,
    ) async {
      final pixels = await _render(
        tester,
        World3D(
          children: [
            ReflectionProbeVolume3D(
              probe: _uniformProbe(255, 0, 0),
              position: Vector3(-1.5, 0, 0),
              extents: Vector3(1.4, 2, 2),
              blendDistance: 0,
            ),
            MeshComponent(
              position: Vector3(1.5, 0, 0),
              mesh: SphereMesh(radius: 0.6, material: _mirror()),
            ),
          ],
        ),
      );

      final (r, g, b, _) = pixels.at(92, 64);
      expect(r, lessThan(30));
      expect(g, lessThan(30));
      expect(b, lessThan(30));
    });

    testGpu("a volume leaves a material's own environment probe alone", (
      tester,
    ) async {
      final probe = _uniformProbe(40, 200, 90);
      World3D world({required bool withVolume}) => World3D(
        children: [
          if (withVolume)
            // Far from the sphere; the camera is in its blend band.
            ReflectionProbeVolume3D(
              probe: _uniformProbe(255, 0, 0),
              position: Vector3(0, 0, 8.5),
              extents: Vector3.all(1),
              blendDistance: 2,
            ),
          MeshComponent(
            position: Vector3(1.2, 0.3, 0),
            mesh: SphereMesh(radius: 0.8, material: _mirror(probe: probe)),
          ),
        ],
      );

      final without = await _render(tester, world(withVolume: false));
      final withVolume = await _render(tester, world(withVolume: true));
      expect(
        without.count((r, g, b, a) => g > 60),
        greaterThan(400),
        reason: 'the sphere reflects its own probe',
      );
      expect(differingPixels(without, withVolume), 0);
    });
  });

  group('EnvironmentProbe3D', () {
    testGpu('reflects an sRGB panorama in linear light', (tester) async {
      Future<Pixels> mirror(EnvironmentProbe3D probe) => _render(
        tester,
        World3D(
          children: [
            MeshComponent(
              mesh: SphereMesh(radius: 0.9, material: _mirror(probe: probe)),
            ),
          ],
        ),
      );
      // sRGB 128 is linear 0.216, which is 55 of 255 in a linear panorama.
      final encoded = await mirror(_uniformProbe(128, 128, 128));
      final linear = await mirror(_uniformProbe(55, 55, 55, srgb: false));
      final (er, _, _, _) = encoded.at(64, 64);
      final (lr, _, _, _) = linear.at(64, 64);
      expect(lr, greaterThan(40));
      expect(er, closeTo(lr, 3));
    });
  });
}
