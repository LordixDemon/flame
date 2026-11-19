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

const _size = 64;

Future<Pixels> _snapshot(
  WidgetTester tester,
  World3D world, {
  required Matrix4 view,
  required Matrix4 projection,
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
      const Size(_size + 0.0, _size + 0.0),
      view: view,
      projection: projection,
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

void main() {
  setUpGpu();

  group('depth-normal prepass', () {
    testGpu('stores the per-pixel depth of large triangles under a '
        'perspective camera', (tester) async {
      final view = Matrix4.identity()
        ..setAsViewMatrix(
          Vector3(0, 2, 0),
          Vector3(0, 0, -10),
          Vector3(0, 1, 0),
        );
      final projection = Matrix4.identity()..setAsPerspective(60, 1, 0.5, 60);
      final material = opaqueUnlit(const Color(0xFF808080));

      // One 40 x 40 quad, reaching behind the camera...
      final coarse = World3D(
        renderDebugMode3D: RenderDebugMode3D.depth,
        children: [
          MeshComponent(
            mesh: PlaneMesh(size: Vector2(40, 40), material: material),
          ),
        ],
      );
      // ... and the same floor made of 2 x 2 tiles.
      final tiles = PlaneMesh(size: Vector2(2, 2), material: material);
      final fine = World3D(
        renderDebugMode3D: RenderDebugMode3D.depth,
        children: [
          for (var x = -19; x < 20; x += 2)
            for (var z = -19; z < 20; z += 2)
              MeshComponent(
                position: Vector3(x.toDouble(), 0, z.toDouble()),
                mesh: tiles,
              ),
        ],
      );

      final coarsePx = await _snapshot(
        tester,
        coarse,
        view: view,
        projection: projection,
      );
      final finePx = await _snapshot(
        tester,
        fine,
        view: view,
        projection: projection,
      );

      for (final y in [36, 44, 52, 60]) {
        final (fr, _, _, _) = finePx.at(_size ~/ 2, y);
        final (cr, _, _, _) = coarsePx.at(_size ~/ 2, y);
        expect(fr, inExclusiveRange(10, 250), reason: 'row $y');
        expect(cr, closeTo(fr, 3), reason: 'row $y');
      }
    });
  });
}
