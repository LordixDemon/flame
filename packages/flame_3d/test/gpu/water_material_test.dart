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

/// Maps a `+Y`-up scene to a `+Z`-up one: (x, y, z) -> (z, x, y).
Vector3 _toZUp(Vector3 v) => Vector3(v.z, v.x, v.y);

final Quaternion _zUpRotation = Quaternion.fromRotation(
  Matrix3.columns(Vector3(0, 1, 0), Vector3(0, 0, 1), Vector3(1, 0, 0)),
);

Future<Pixels> _render(
  WidgetTester tester,
  World3D world, {
  required Vector3 eye,
  required Vector3 up,
}) async {
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
      view: Matrix4.identity()..setAsViewMatrix(eye, Vector3.zero(), up),
      projection: Matrix4.identity()..setAsPerspective(50, 1, 0.5, 40),
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

TerrainMesh3D _water(WaterMaterial material) => TerrainMesh3D(
  columns: 32,
  rows: 32,
  width: 6,
  depth: 6,
  heights: Float32List(32 * 32),
  material: material,
);

void main() {
  setUpGpu();

  group('WaterMaterial', () {
    testGpu('is lit by spot lights', (tester) async {
      Future<Pixels> render({required bool withSpot}) => _render(
        tester,
        World3D(
          children: [
            LightComponent.ambient(intensity: 0),
            if (withSpot)
              LightComponent.spot(
                position: Vector3(0, 3, 0),
                direction: Vector3(0, -1, 0),
                intensity: 6,
                outerConeAngle: 0.7,
              ),
            MeshComponent(mesh: _water(WaterMaterial(opacity: 1))),
          ],
        ),
        eye: Vector3(0, 5, 3),
        up: Vector3(0, 1, 0),
      );
      final dark = await render(withSpot: false);
      final lit = await render(withSpot: true);
      final (dr, dg, db, _) = dark.at(64, 64);
      final (lr, lg, lb, _) = lit.at(64, 64);
      expect(lr + lg + lb, greaterThan(dr + dg + db + 60));
    });

    testGpu('ripples follow its upAxis, not the hemisphere light', (
      tester,
    ) async {
      // The same scene with +Y up and turned to +Z up, without a hemisphere
      // light: the two pictures must be the same.
      final sunY = Vector3(-0.3, -1, -0.2);
      Future<Pixels> render({required bool zUp}) => _render(
        tester,
        World3D(
          children: [
            LightComponent.directional(
              direction: zUp ? _toZUp(sunY) : sunY,
              intensity: 2,
            ),
            MeshComponent(
              rotation: zUp ? _zUpRotation : null,
              mesh: _water(
                WaterMaterial(
                  opacity: 1,
                  time: 0.7,
                  rippleStrength: 0.35,
                  upAxis: zUp ? Vector3(0, 0, 1) : Vector3(0, 1, 0),
                ),
              ),
            ),
          ],
        ),
        eye: zUp ? _toZUp(Vector3(1, 4, 3)) : Vector3(1, 4, 3),
        up: zUp ? Vector3(0, 0, 1) : Vector3(0, 1, 0),
      );
      final yUp = await render(zUp: false);
      final zUp = await render(zUp: true);
      expect(yUp.count((r, g, b, a) => r + g + b > 30), greaterThan(4000));
      expect(differingPixels(yUp, zUp, tolerance: 3), lessThan(40));
    });

    test('follows opacity changes in its render state', () {
      final water = WaterMaterial(opacity: 1);
      expect(water.renderState.translucent, isFalse);
      water.opacity = 0.5;
      expect(water.renderState.translucent, isTrue);
      expect(water.renderState.cullMode, CullMode.backFace);
      water.opacity = 1;
      expect(water.renderState.translucent, isFalse);

      // A render state set by hand is kept.
      water.renderState = RenderState.additive;
      water.opacity = 0.3;
      expect(water.renderState, same(RenderState.additive));
    });
  });
}
