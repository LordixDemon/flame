import 'dart:ui';

import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter_test/flutter_test.dart';

import 'gpu_test_helpers.dart';

// StylizedMaterial.depthBias, seen by the default camera (x and y in [-1, 1],
// looking down -z, orthographic, depth 0 at z = 0 and 1 at z = -10).

final List<Light> _ambient = [
  Light(position: Vector3.zero(), source: AmbientLight(intensity: 1)),
];

/// A square of side `2 * half` facing +z, in the stylized layout (or with
/// [skinned], skinned to joint 0; with [standard], in the standard layout).
Surface _square(
  Material material, {
  double half = 0.4,
  bool skinned = false,
  bool standard = false,
}) {
  final positions = [
    -half, -half, 0.0, half, -half, 0.0, half, half, 0.0, -half, half, 0.0, //
  ];
  if (standard) {
    return PlaneMesh(
      size: Vector2.all(2 * half),
      material: material,
    ).surfaces.single;
  }
  return StylizedMaterial.buildSurface(
    positions: positions,
    normals: const [0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1],
    joints: skinned ? List.filled(16, 0) : null,
    weights: skinned
        ? const [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0]
        : null,
    indices: const [0, 1, 2, 0, 2, 3],
    material: material,
  );
}

void main() {
  setUpGpu();

  group('StylizedMaterial.depthBias', () {
    Future<Frame> overlap({
      required double bias,
      bool skinned = false,
      bool standard = false,
    }) {
      // A red square in front (z = -1) and a blue one 0.2 behind it, offset
      // to the right: without a bias the red one covers the blue one where
      // they overlap.
      final front = StylizedMaterial(
        albedoColor: const Color(0xFFFF0000),
        rimStrength: 0,
        specularStrength: 0,
      );
      final back = StylizedMaterial(
        albedoColor: const Color(0xFF0000FF),
        rimStrength: 0,
        specularStrength: 0,
        depthBias: bias,
      );
      final backSurface = _square(back, skinned: skinned, standard: standard);
      final backTransform = Matrix4.translationValues(0.3, 0, -1.2);
      if (standard) {
        // The plane mesh faces +y: turn it to face +z.
        backTransform.rotateX(1.5707963267948966);
      }
      return renderFrame(
        lights: _ambient,
        draw: (context) => context
          ..drawSurface(
            _square(front),
            transform: Matrix4.translationValues(-0.1, 0, -1),
          )
          ..drawSurface(
            backSurface,
            transform: backTransform,
            jointTransforms: skinned ? [Matrix4.identity()] : null,
          ),
      );
    }

    // Where the two squares overlap.
    final (ox, oy) = pixelAt(0.1, 0);

    testGpuEngine('draws an object in front of nearer neighbours', () async {
      final plain = await overlap(bias: 0);
      expect(plain.pixels.at(ox, oy).$1, greaterThan(200));
      // 0.2 behind is 0.02 of depth: a bias of 0.03 brings it in front.
      final biased = await overlap(bias: 0.03);
      final (r, _, b, _) = biased.pixels.at(ox, oy);
      expect(b, greaterThan(200));
      expect(r, lessThan(40));
      // The object does not move: it covers the same pixels.
      final (lx, ly) = pixelAt(-0.45, 0);
      final (rx, ry) = pixelAt(0.65, 0);
      expect(biased.pixels.at(lx, ly), plain.pixels.at(lx, ly));
      expect(biased.pixels.at(rx, ry), plain.pixels.at(rx, ry));
      final (gx, gy) = pixelAt(0.75, 0);
      expect(biased.pixels.isClear(gx, gy), isTrue);
    });

    testGpuEngine('biases skinned draws and the standard layout', () async {
      for (final (skinned, standard) in [(true, false), (false, true)]) {
        final plain = await overlap(
          bias: 0,
          skinned: skinned,
          standard: standard,
        );
        final biased = await overlap(
          bias: 0.03,
          skinned: skinned,
          standard: standard,
        );
        expect(plain.pixels.at(ox, oy).$1, greaterThan(200));
        expect(biased.pixels.at(ox, oy).$3, greaterThan(200));
      }
    });

    testGpuEngine('leaves the shadow where it was', () async {
      final lights = [
        Light(position: Vector3.zero(), source: AmbientLight(intensity: 0.3)),
        Light(
          position: Vector3.zero(),
          source: DirectionalLight(
            direction: Vector3(0.3, 0, -1),
            shadows: ShadowSettings(),
          ),
        ),
      ];
      final ground = _square(
        StylizedMaterial(rimStrength: 0, specularStrength: 0),
        half: 1,
      );

      Future<Pixels> render(double bias) async {
        final caster = _square(
          StylizedMaterial(
            rimStrength: 0,
            specularStrength: 0,
            depthBias: bias,
          ),
          half: 0.2,
        );
        final device = GraphicsDevice();
        final context = RenderContext3D(device);
        void draw(RenderContext3D context) => context
          ..drawSurface(ground, transform: Matrix4.translationValues(0, 0, -5))
          ..drawSurface(
            caster,
            transform: Matrix4.translationValues(-0.3, 0, -2),
          );
        device.begin();
        context
          ..lights = lights
          ..setCamera(defaultView, defaultProjection);
        if (context.beginShadowPass(
          projection: DirectionalShadowProjection(),
          sceneBounds: Aabb3.minMax(Vector3(-1, -1, -5), Vector3(1, 1, -2)),
        )) {
          draw(context);
          context.endShadowPass();
        }
        device.beginPass(const Size(64, 64), frontFace: context.frontFace);
        draw(context);
        context.flush();
        final image = device.endPass();
        device.end();
        final pixels = await readImage(image);
        image.dispose();
        return pixels;
      }

      final plain = await render(0);
      final biased = await render(0.05);
      final (sx, sy) = pixelAt(0.6, 0);
      final (gx, gy) = pixelAt(0.6, 0.8);
      expect(plain.at(sx, sy).$1, lessThan(plain.at(gx, gy).$1 - 30));
      expect(differingPixels(plain, biased), 0);
    });
  });
}
