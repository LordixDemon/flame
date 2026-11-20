import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:ui' show Color, Size;

import 'package:flame_3d/game.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/src/graphics/backend/flutter_gpu/gpu_backend.dart'
    as flutter_gpu;
import 'package:flutter_test/flutter_test.dart';

import 'gpu_test_helpers.dart';

/// A 2x2 texture of four colors.
Texture _checker() {
  return Texture(
    ByteData.sublistView(
      Uint8List.fromList(const [
        255, 0, 0, 255, 0, 255, 0, 255, //
        0, 0, 255, 255, 255, 255, 0, 255, //
      ]),
    ),
    width: 2,
    height: 2,
  );
}

void main() {
  setUpGpu();

  tearDown(GpuBackend.debugResetDeviceState);

  flutter_gpu.GpuBackend backend() =>
      GpuBackend.instance as flutter_gpu.GpuBackend;

  group('device check', () {
    testGpuEngine('passes on a working device', () async {
      final losses = backend().deviceLossCount;
      expect(await backend().checkDevice(), isTrue);
      expect(backend().deviceLossCount, losses);
      expect(backend().isDeviceReady, isTrue);
    });
  });

  group('a simulated device loss', () {
    testGpuEngine(
      'creates every GPU object again and renders the same pixels',
      () async {
        final device = GraphicsDevice();
        final context = RenderContext3D(device);
        final checker = _checker();
        final textured = quad(
          UnlitMaterial(albedoTexture: checker)
            ..renderState = RenderState.opaque,
          halfSize: 0.4,
        );
        final solid = quad(opaqueUnlit(const Color(0xFF30A060)), halfSize: 0.2);
        final targetMaterial = UnlitMaterial()
          ..renderState = RenderState.opaque;
        final sampled = quad(targetMaterial, halfSize: 0.3);

        Future<Pixels> render() async {
          device.begin();
          // A pass into a texture target, sampled by the next pass.
          final target = device.textureTarget(
            16,
            16,
            GpuPixelFormat.rgba8888,
            clearValue: const Color(0xFFE0A020),
          );
          context.setCamera(defaultView, defaultProjection);
          device.beginTexturePass(target, frontFace: context.frontFace);
          context
            ..drawSurface(solid)
            ..flush();
          device.endTexturePass();
          targetMaterial.albedoTexture = Texture(
            null,
            width: 16,
            height: 16,
            gpuTexture: target.texture,
          );
          device.beginPass(
            const Size(64, 64),
            msaaSampleCount: 4,
            frontFace: context.frontFace,
          );
          context
            ..drawSurface(
              textured,
              transform: Matrix4.translationValues(-0.4, 0, -1),
            )
            ..drawSurface(
              sampled,
              transform: Matrix4.translationValues(0.5, 0.4, -2),
            )
            ..flush();
          final image = device.endPass();
          device.end();
          final pixels = await readImage(image);
          image.dispose();
          return pixels;
        }

        final before = await render();
        final generation = GpuBackend.deviceGeneration;

        expect(await backend().debugSimulateDeviceLoss(), isTrue);

        expect(GpuBackend.deviceGeneration, generation + 1);
        expect(backend().isDeviceReady, isTrue);
        expect(checker.hasResource, isFalse);
        final after = await render();
        expect(checker.hasResource, isTrue);
        expect(differingPixels(before, after, tolerance: 0), 0);
        // The frame is not empty: the checker and the sampled target show,
        // the target's clear color and its green square included.
        expect(before.count((r, g, b, a) => a > 0), greaterThan(500));
        expect(
          before.count((r, g, b, a) => r > 200 && g > 130 && b < 60),
          greaterThan(20),
        );
        expect(
          before.count((r, g, b, a) => r < 70 && g > 140 && b < 120),
          greaterThan(5),
        );
      },
    );

    testGpuEngine('renders nothing while the device is lost', () async {
      final solid = quad(opaqueUnlit(const Color(0xFF30A060)));
      backend().reportDeviceLost('test');
      final lost = await renderFrame(draw: (c) => c.drawSurface(solid));
      expect(lost.pixels.width, 1);
      expect(lost.pixels.at(0, 0), (0, 0, 0, 0));
      expect(await backend().recoverDevice(), isTrue);
      final back = await renderFrame(draw: (c) => c.drawSurface(solid));
      expect(back.pixels.at(32, 32), (0x30, 0xA0, 0x60, 0xFF));
    });

    testGpuEngine(
      'binds a texture that wrapped an image of the lost device as '
      'transparent',
      () async {
        final recorder = ui.PictureRecorder();
        ui.Canvas(recorder).drawColor(
          const Color(0xFF2050E0),
          ui.BlendMode.src,
        );
        final picture = recorder.endRecording();
        final image = await picture.toImage(4, 4);
        picture.dispose();
        final wrapped = backend().createTextureFromImage(image)!;
        image.dispose();
        final material = UnlitMaterial(
          albedoTexture: Texture(
            null,
            width: 4,
            height: 4,
            gpuTexture: wrapped,
          ),
        )..renderState = RenderState.opaque;
        final surface = quad(material);

        final before = await renderFrame(draw: (c) => c.drawSurface(surface));
        expect(before.pixels.at(32, 32), (0x20, 0x50, 0xE0, 0xFF));

        expect(await backend().debugSimulateDeviceLoss(), isTrue);
        final after = await renderFrame(draw: (c) => c.drawSurface(surface));
        expect(after.pixels.at(32, 32), (0, 0, 0, 0));
      },
    );
  });

  group('capabilities', () {
    testGpuEngine('are what the API guarantees off OpenGL ES', () async {
      final caps = backend().capabilities;
      expect(caps.api, isNot(GpuGraphicsApi.openGLES));
      expect(caps.floatTextureTargets, isTrue);
      expect(caps.halfFloatTextureTargets, isTrue);
      expect(caps.floatTargetDetection, 'api');
      expect(backend().supportsFloatTextureTargets, isTrue);
      expect(
        backend().shaderRequirements(
          'packages/flame_3d/assets/shaders/water_material.shaderbundle',
          'TextureFragment',
        ),
        isNull,
      );
    });

    testGpuEngine('the float target probe tells float from 8-bit targets', () {
      return Future(() async {
        final b = backend();
        expect(await b.debugProbeFloatTarget(GpuPixelFormat.rgbaFloat16), true);
        expect(await b.debugProbeFloatTarget(GpuPixelFormat.r32Float), true);
        // An 8-bit target clamps the value above 1 that the probe renders.
        expect(
          await b.debugProbeFloatTarget(
            GpuPixelFormat.rgba8888,
            checkRange: true,
          ),
          isFalse,
        );
      });
    });
  });
}
