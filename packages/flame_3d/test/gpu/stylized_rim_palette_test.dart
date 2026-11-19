import 'dart:ui';

import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter_test/flutter_test.dart';

import 'gpu_test_helpers.dart';

// The rim palette of StylizedMaterial: objects that differ only in their rim
// highlight (hovered, selected, owner colored) keep one material and one
// instanced draw. Seen by the default camera (x and y in [-1, 1], looking
// down -z, orthographic).

const _orange = Color(0xFFFF8000);
const _cyan = Color(0xFF00E0FF);

StylizedMaterial _material() => StylizedMaterial(
  albedoColor: const Color(0xFF404040),
  rimStrength: 0,
  specularStrength: 0,
  rimPalette: const [_orange, _cyan],
);

final List<Light> _ambient = [
  Light(position: Vector3.zero(), source: AmbientLight(intensity: 1)),
];

Vector4 _rim(int? index, {int? accent, double fade = 0}) => Vector4(
  0,
  0,
  0,
  StylizedMaterial.packPaletteAndFade(accent: accent, rim: index, fade: fade),
);

/// The pixel near the left edge of the sphere of radius 0.3 at ([x], 0).
(int, int) _edge(double x) => pixelAt(x - 0.28, 0, width: 128, height: 128);

(int, int) _middle(double x) => pixelAt(x, 0, width: 128, height: 128);

void main() {
  setUpGpu();

  group('StylizedMaterial rim palette', () {
    test('packs the rim with the accent and the fade', () {
      // Without a rim, the packing of packAccentAndFade.
      expect(
        StylizedMaterial.packPaletteAndFade(accent: 3, fade: 0.25),
        StylizedMaterial.packAccentAndFade(3, fade: 0.25),
      );
      expect(StylizedMaterial.packPaletteAndFade(fade: 0.4), 0.4);
      final w = StylizedMaterial.packPaletteAndFade(
        accent: 15,
        rim: StylizedMaterial.maxRimPaletteSize - 1,
        fade: 0.75,
      );
      final slot = (w / 4).floor();
      expect(w - slot * 4, closeTo(0.75, 1e-6));
      expect(slot % 17, 16);
      expect(slot ~/ 17, StylizedMaterial.maxRimPaletteSize);
      expect(
        () => StylizedMaterial.packPaletteAndFade(
          rim: StylizedMaterial.maxRimPaletteSize,
        ),
        throwsRangeError,
      );
    });

    testGpuEngine('adds each instance its own rim in one draw call', () async {
      final material = _material();
      final sphere = SphereMesh(radius: 0.3, material: material);
      final frame = await renderFrame(
        width: 128,
        height: 128,
        lights: _ambient,
        draw: (context) {
          for (final (x, rim) in [(-0.6, 0), (0.0, 1), (0.6, null)]) {
            context.drawMesh(
              sphere,
              transform: Matrix4.translationValues(x, 0, -2),
              instanceData: _rim(rim),
            );
          }
        },
      );
      expect(frame.stats.drawCalls, 1);
      expect(frame.stats.instances, 3);

      final (ox, oy) = _edge(-0.6);
      final (cx, cy) = _edge(0);
      final (nx, ny) = _edge(0.6);
      final orange = frame.pixels.at(ox, oy);
      final cyan = frame.pixels.at(cx, cy);
      final none = frame.pixels.at(nx, ny);
      // The edges glow in the instance's rim color...
      expect(orange.$1, greaterThan(none.$1 + 60));
      expect(orange.$3, lessThan(orange.$1 - 60));
      expect(cyan.$3, greaterThan(none.$3 + 60));
      expect(cyan.$1, lessThan(cyan.$3 - 60));
      // ...the middles, facing the viewer, do not.
      for (final x in [-0.6, 0.0, 0.6]) {
        final (mx, my) = _middle(x);
        final (r, g, b, _) = frame.pixels.at(mx, my);
        expect(r, closeTo(64, 4));
        expect(b, closeTo(64, 4));
        expect(g, closeTo(64, 4));
      }
    });

    testGpuEngine('works with skinned draws and an accent at once', () async {
      final material = StylizedMaterial(
        rimStrength: 0,
        specularStrength: 0,
        accentPalette: const [Color(0xFF20FF20)],
        rimPalette: const [_orange],
      );
      final surface = StylizedMaterial.buildSurface(
        positions: const [
          -0.3,
          -0.3,
          0,
          0.3,
          -0.3,
          0,
          0.3,
          0.3,
          0,
          -0.3,
          0.3,
          0,
        ],
        // Normals leaning away from the viewer: all rim.
        normals: const [-1, 0, 0.2, -1, 0, 0.2, -1, 0, 0.2, -1, 0, 0.2],
        accent: const [1, 1, 1, 1],
        joints: List.filled(16, 0),
        weights: const [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0],
        indices: const [0, 1, 2, 0, 2, 3],
        material: material,
      );
      final joints = [Matrix4.identity()];
      final frame = await renderFrame(
        width: 128,
        height: 128,
        lights: _ambient,
        draw: (context) => context
          ..drawSurface(
            surface,
            transform: Matrix4.translationValues(-0.5, 0, -1),
            instanceData: _rim(null, accent: 0),
            jointTransforms: joints,
          )
          ..drawSurface(
            surface,
            transform: Matrix4.translationValues(0.5, 0, -1),
            instanceData: _rim(0, accent: 0),
            jointTransforms: joints,
          ),
      );
      final (lx, ly) = _middle(-0.5);
      final (rx, ry) = _middle(0.5);
      final plain = frame.pixels.at(lx, ly);
      final rimmed = frame.pixels.at(rx, ry);
      // Green accent on both; the rimmed one also gets orange.
      expect(plain.$2, greaterThan(200));
      expect(plain.$1, lessThan(80));
      expect(rimmed.$2, greaterThan(200));
      expect(rimmed.$1, greaterThan(plain.$1 + 60));
    });

    testGpuEngine('leaves the shadow pass alone', () async {
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
      final ground = StylizedMaterial.buildSurface(
        positions: const [-1, -1, 0, 1, -1, 0, 1, 1, 0, -1, 1, 0],
        normals: const [0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1],
        indices: const [0, 1, 2, 0, 2, 3],
        material: StylizedMaterial(rimStrength: 0, specularStrength: 0),
      );
      final caster = SphereMesh(radius: 0.3, material: _material());

      Future<Pixels> render(Vector4? instanceData) async {
        final device = GraphicsDevice();
        final context = RenderContext3D(device);
        void draw(RenderContext3D context) => context
          ..drawSurface(ground, transform: Matrix4.translationValues(0, 0, -5))
          ..drawMesh(
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
          sceneBounds: Aabb3.minMax(Vector3(-1, -1, -5), Vector3(1, 1, -1.7)),
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
      final rimmed = await render(_rim(1));
      final (sx, sy) = pixelAt(0.6, 0);
      final (gx, gy) = pixelAt(0.6, 0.85);
      expect(plain.at(sx, sy).$1, lessThan(plain.at(gx, gy).$1 - 30));
      expect(rimmed.at(sx, sy), plain.at(sx, sy));
      expect(differingPixels(plain, rimmed), lessThan(300));
    });
  });
}
