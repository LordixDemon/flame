import 'dart:ui';

import 'package:flame/game.dart' show GameWidget;
import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/game.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/particles.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter/widgets.dart' show ObjectKey;
import 'package:flutter_test/flutter_test.dart';

import 'gpu_test_helpers.dart';

// The default camera looks down -z with an orthographic projection: world x
// and y from -1 to 1 fill the 64 by 64 image, and a point at z = -5 has the
// depth 0.5.

const _size = 64;

/// Renders [world] (mounted in a game) from the default camera.
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
      const Size(_size + 0.0, _size + 0.0),
      view: defaultView,
      projection: defaultProjection,
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

/// A system holding one still particle of [size] at [position], drawn with
/// [material].
ParticleSystem3D _particle(
  ParticleMaterial material,
  Vector3 position, {
  double size = 0.8,
  Color color = const Color(0xFFFFFFFF),
}) {
  return ParticleSystem3D(capacity: 1, material: material)..spawn(
    position: position,
    size: size,
    lifespan: 100,
    gravityScale: 0,
    color: color,
  );
}

/// The number of pixels of the `depth` debug view in the rectangle from
/// ([x0], [y0]) to ([x1], [y1]) that show geometry at a depth of 0.5.
int _atHalfDepth(Pixels pixels, int x0, int y0, int x1, int y1) {
  var count = 0;
  for (var y = y0; y < y1; y++) {
    for (var x = x0; x < x1; x++) {
      if ((pixels.at(x, y).$1 - 128).abs() < 8) {
        count++;
      }
    }
  }
  return count;
}

void main() {
  setUpGpu();

  group('ParticleMaterial in the depth-normal prepass', () {
    testGpu('holds opaque billboards, cut out as drawn', (tester) async {
      // A square on the left, a soft-circle particle of the same size on
      // the right, both at depth 0.5.
      final pixels = await _render(
        tester,
        World3D(
          renderDebugMode3D: RenderDebugMode3D.depth,
          children: [
            MeshComponent(
              mesh: CuboidMesh(
                size: Vector3(0.8, 0.8, 0.01),
                material: opaqueUnlit(const Color(0xFFFFFFFF)),
              ),
              position: Vector3(-0.5, 0, -5),
            ),
            _particle(
              ParticleMaterial(
                alphaCutoff: 0.5,
                renderState: RenderState.opaque,
              ),
              Vector3(0.5, 0, -5),
            ),
          ],
        ),
      );
      final square = _atHalfDepth(pixels, 0, 16, 32, 48);
      final disc = _atHalfDepth(pixels, 32, 16, 64, 48);
      expect(square, greaterThan(400));
      // The disc covers less than the square it is cut from: the area of a
      // circle of 3 / 4 of its half side, about 44 % of it.
      expect(disc, greaterThan(square * 0.3));
      expect(disc, lessThan(square * 0.6));
      // Its center is at the depth of the square, its corners are empty.
      expect(pixels.at(48, 32).$1, closeTo(pixels.at(16, 32).$1, 2));
      expect(pixels.at(58, 22).$1, lessThan(8));
    });

    testGpu('leaves out translucent billboards and soft opaque ones', (
      tester,
    ) async {
      final pixels = await _render(
        tester,
        World3D(
          renderDebugMode3D: RenderDebugMode3D.depth,
          children: [
            _particle(ParticleMaterial(), Vector3(-0.5, 0, -5)),
            _particle(
              ParticleMaterial(
                alphaCutoff: 0.5,
                softDepthFade: 0.2,
                renderState: RenderState.opaque,
              ),
              Vector3(0.5, 0, -5),
            ),
          ],
        ),
      );
      expect(_atHalfDepth(pixels, 0, 0, _size, _size), 0);
    });

    testGpu('an opaque billboard with a soft fade does not fade itself', (
      tester,
    ) async {
      ParticleSystem3D soft() => _particle(
        ParticleMaterial(
          alphaCutoff: 0.5,
          softDepthFade: 0.2,
          renderState: RenderState.opaque,
        ),
        Vector3(0, 0, -5),
        color: const Color(0xFF40C0FF),
      );
      final withPrepass = await _render(
        tester,
        World3D(depthPrepassEnabled: true, children: [soft()]),
      );
      final without = await _render(tester, World3D(children: [soft()]));
      expect(withPrepass.at(32, 32), without.at(32, 32));
      expect(withPrepass.at(32, 32).$3, greaterThan(200));
    });

    testGpu('soft particles fade against the opaque particles behind', (
      tester,
    ) async {
      // A white soft particle just in front of a big red opaque one: the
      // soft one reads the red one's depth and fades out.
      final pixels = await _render(
        tester,
        World3D(
          depthPrepassEnabled: true,
          children: [
            _particle(
              ParticleMaterial(
                sprite: ParticleSprite.texture,
                alphaCutoff: 0.5,
                renderState: RenderState.opaque,
              ),
              Vector3(0, 0, -5),
              size: 1.6,
              color: const Color(0xFFFF0000),
            ),
            _particle(
              ParticleMaterial(softDepthFade: 0.2),
              Vector3(0, 0, -4.98),
            ),
          ],
        ),
      );
      final (r, g, b, _) = pixels.at(32, 32);
      expect(r, greaterThan(240));
      expect(g, lessThan(20));
      expect(b, lessThan(20));
    });
  });
}
