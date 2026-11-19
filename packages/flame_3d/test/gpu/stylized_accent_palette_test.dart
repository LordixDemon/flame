import 'dart:ui';

import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter_test/flutter_test.dart';

import 'gpu_test_helpers.dart';

// The accent palette of StylizedMaterial with skinned, translucent and shadow
// pass draws, seen by the default camera (x and y in [-1, 1], looking down
// -z).

const _red = Color(0xFFFF1010);
const _blue = Color(0xFF1040FF);

StylizedMaterial _material({bool translucent = false}) => StylizedMaterial(
  accentPalette: const [_red, _blue],
  rimStrength: 0,
  specularStrength: 0,
  translucent: translucent,
);

/// A square of side `2 * half` facing +z, all accent, optionally skinned to
/// joint 0.
Surface _square(Material material, {double half = 0.3, bool skinned = false}) {
  return StylizedMaterial.buildSurface(
    positions: [-half, -half, 0, half, -half, 0, half, half, 0, -half, half, 0],
    normals: const [0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1],
    accent: const [1, 1, 1, 1],
    joints: skinned ? List.filled(16, 0) : null,
    weights: skinned
        ? const [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0]
        : null,
    indices: const [0, 1, 2, 0, 2, 3],
    material: material,
  );
}

Vector4 _accent(int index, {double fade = 0}) =>
    Vector4(0, 0, 0, StylizedMaterial.packAccentAndFade(index, fade: fade));

final List<Light> _ambient = [
  Light(position: Vector3.zero(), source: AmbientLight(intensity: 1)),
];

void main() {
  setUpGpu();

  group('StylizedMaterial accent palette', () {
    testGpuEngine('picks the accent of skinned draws per instance', () async {
      final material = _material();
      final surface = _square(material, skinned: true);
      expect(surface.layout, same(StylizedMaterial.skinnedVertexLayout));
      // The joint lifts both squares by 0.4.
      final joints = [Matrix4.translationValues(0, 0.4, 0)];
      final frame = await renderFrame(
        lights: _ambient,
        draw: (context) => context
          ..drawSurface(
            surface,
            transform: Matrix4.translationValues(-0.5, 0, -1),
            instanceData: _accent(0),
            jointTransforms: joints,
          )
          ..drawSurface(
            surface,
            transform: Matrix4.translationValues(0.5, 0, -1),
            instanceData: _accent(1),
            jointTransforms: joints,
          ),
      );
      final (lx, ly) = pixelAt(-0.5, 0.4);
      final (rx, ry) = pixelAt(0.5, 0.4);
      final (lr, _, lb, _) = frame.pixels.at(lx, ly);
      final (rr, _, rb, _) = frame.pixels.at(rx, ry);
      expect(lr, greaterThan(200));
      expect(lb, lessThan(40));
      expect(rb, greaterThan(200));
      expect(rr, lessThan(40));
      // Below the lifted squares: nothing.
      final (bx, by) = pixelAt(-0.5, -0.25);
      expect(frame.pixels.isClear(bx, by), isTrue);
    });

    testGpuEngine(
      'picks accent and fade of translucent draws in one batch',
      () async {
        final material = _material(translucent: true);
        final surface = _square(material);
        final frame = await renderFrame(
          lights: _ambient,
          draw: (context) => context
            ..drawSurface(
              surface,
              transform: Matrix4.translationValues(-0.5, 0, -1),
              instanceData: _accent(0, fade: 0.5),
            )
            ..drawSurface(
              surface,
              transform: Matrix4.translationValues(0.5, 0, -1),
              instanceData: _accent(1, fade: 0.5),
            ),
        );
        expect(frame.stats.drawCalls, 1);
        expect(frame.stats.instances, 2);
        final (lx, ly) = pixelAt(-0.5, 0);
        final (rx, ry) = pixelAt(0.5, 0);
        final (lr, _, lb, la) = frame.pixels.at(lx, ly);
        final (rr, _, rb, ra) = frame.pixels.at(rx, ry);
        // Half faded, premultiplied: half the accent over the clear color.
        expect(la, closeTo(128, 3));
        expect(ra, closeTo(128, 3));
        expect(lr, closeTo(128, 4));
        expect(lb, lessThan(20));
        expect(rb, closeTo(128, 4));
        expect(rr, lessThan(20));
      },
    );

    testGpuEngine('leaves the shadows of packed instances alone', () async {
      // A sun straight down the view: casters at z = -2 shadow a ground at
      // z = -5 right behind them.
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
      final ground = StylizedMaterial(rimStrength: 0, specularStrength: 0);
      final groundSurface = _square(ground, half: 1);
      final caster = _square(_material());

      Future<Pixels> render(Vector4? instanceData) async {
        final device = GraphicsDevice();
        final context = RenderContext3D(device);
        void draw(RenderContext3D context) => context
          ..drawSurface(
            groundSurface,
            transform: Matrix4.translationValues(0, 0, -5),
          )
          ..drawSurface(
            caster,
            transform: Matrix4.translationValues(-0.3, 0, -2),
            instanceData: instanceData,
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

      final plain = await render(null);
      final packed = await render(_accent(1));
      // The shadow (right of the caster) is there and is the same.
      final (sx, sy) = pixelAt(0.55, 0);
      final (gx, gy) = pixelAt(0.55, 0.8);
      expect(plain.at(sx, sy).$1, lessThan(plain.at(gx, gy).$1 - 30));
      final (px, py) = pixelAt(0.55, 0);
      expect(packed.at(px, py), plain.at(px, py));
      // Only the caster's own accent differs.
      expect(differingPixels(plain, packed), lessThan(400));
    });
  });
}
