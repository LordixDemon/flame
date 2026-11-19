import 'dart:ui';

import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter_test/flutter_test.dart';

import 'gpu_test_helpers.dart';

/// A mesh drawing [surface] at the origin.
MeshComponent _show(Surface surface) =>
    MeshComponent(mesh: Mesh()..addSurface(surface));

void main() {
  setUpGpu();

  testGpuEngine(
    'RenderTexture3D.texture given to a material at setup shows the render',
    () async {
      final device = GraphicsDevice();
      final context = RenderContext3D(device);
      final portal = RenderTexture3D(
        width: 32,
        height: 32,
        clearValue: const Color(0xFF2040E0),
      );
      addTearDown(portal.dispose);

      // The material gets the texture before anything was rendered.
      final screen = World3D(
        children: [
          _show(
            quad(
              UnlitMaterial(albedoTexture: portal.texture)
                ..renderState = RenderState.opaque,
              halfSize: 1,
            ),
          ),
        ],
      );
      // A red square on the left half of the portal's view.
      final source = World3D(
        children: [
          _show(quad(opaqueUnlit(const Color(0xFFE02020))))..position.x = -0.5,
        ],
      );

      device.begin();
      expect(
        portal.renderWorld(
          source,
          view: defaultView,
          projection: defaultProjection,
          device: device,
          context: context,
        ),
        isTrue,
      );
      device.end();

      device.begin();
      final image = screen.renderToImage(
        const Size(32, 32),
        view: defaultView,
        projection: defaultProjection,
        device: device,
        context: context,
      );
      device.end();
      final pixels = await readImage(image);
      image.dispose();

      bool red(int r, int g, int b, int a) => r > 180 && g < 80 && b < 80;
      bool blue(int r, int g, int b, int a) => b > 180 && r < 80;
      expect(pixels.count(red), greaterThan(100));
      expect(pixels.count(blue), greaterThan(100));
      expect(pixels.count((r, g, b, a) => r > 240 && g > 240 && b > 240), 0);
    },
  );

  testGpuEngine('World3D.renderToImage lights an unmounted world', () async {
    Future<int> centerBrightness({required bool withLights}) async {
      final world = World3D(
        children: [
          _show(
            quad(
              SpatialMaterial(),
              halfSize: 1,
            ),
          ),
          if (withLights) ...[
            LightComponent.directional(
              direction: Vector3(0, 0, -1),
              intensity: 3,
            ),
            LightComponent.ambient(intensity: 0.05),
          ] else
            LightComponent.ambient(intensity: 0.05),
        ],
      );
      final device = GraphicsDevice()..begin();
      final image = world.renderToImage(
        const Size(16, 16),
        view: defaultView,
        projection: defaultProjection,
        device: device,
        context: RenderContext3D(device),
      );
      device.end();
      final pixels = await readImage(image);
      image.dispose();
      expect(world.isMounted, isFalse);
      return pixels.at(8, 8).$1;
    }

    final dark = await centerBrightness(withLights: false);
    final lit = await centerBrightness(withLights: true);
    expect(lit, greaterThan(dark + 60));
  });
}
