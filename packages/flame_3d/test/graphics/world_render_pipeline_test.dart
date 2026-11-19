import 'dart:ui';

import 'package:flame_3d/camera.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_fakes/fake_gpu_backend.dart';

void main() {
  group('World3D render pipeline', () {
    late FakeGpuBackend backend;
    late GraphicsDevice device;
    late RenderContext3D context;

    setUp(() {
      backend = FakeGpuBackend(textureTargets: true);
      device = GraphicsDevice(backend: backend);
      context = RenderContext3D(device)
        ..setCamera(Matrix4.identity(), Matrix4.identity());
    });

    int fullSizeTargets(GpuPixelFormat format) => backend.textureTargetsCreated
        .where((t) => t == (64, 64, format))
        .length;

    void render(World3D world, {required Color clearValue, Mesh? mesh}) {
      device.begin();
      world
          .executeWorldRenderPipeline(
            device: device,
            renderContext: context,
            width: 64,
            height: 64,
            msaaSampleCount: 1,
            clearValue: clearValue,
            recordDraws: () {
              if (mesh != null) {
                context.drawMesh(mesh);
              }
            },
          )
          .dispose();
      device.end();
    }

    test('gives the grab pass and the scene target different targets', () {
      final world = World3D(
        grabSceneColorEnabled: true,
        postProcess: PostProcessSettings(exposure: 1.2),
      );
      render(world, clearValue: const Color(0xFF102030));

      expect(fullSizeTargets(GpuPixelFormat.rgba8888), 2);
    });

    test('gives every order-independent transparency pass its own target '
        'with HDR', () {
      final world = World3D(
        hdrEnabled: true,
        oitMode: OitMode3D.weightedBlended,
      );
      render(
        world,
        clearValue: const Color(0x00000000),
        mesh: CuboidMesh(
          size: Vector3.all(1),
          material: UnlitMaterial(albedoColor: const Color(0x80800000)),
        ),
      );

      // The opaque draws, the accumulation and the composited scene.
      expect(fullSizeTargets(GpuPixelFormat.rgbaFloat16), 3);
      // The revealage.
      expect(fullSizeTargets(GpuPixelFormat.rgba8888), 1);
    });

    test('sorts translucent draws without float targets', () {
      backend = FakeGpuBackend(
        textureTargets: true,
        floatTextureTargets: false,
      );
      device = GraphicsDevice(backend: backend);
      context = RenderContext3D(device)
        ..setCamera(Matrix4.identity(), Matrix4.identity());
      final world = World3D(oitMode: OitMode3D.weightedBlended);
      render(
        world,
        clearValue: const Color(0x00000000),
        mesh: CuboidMesh(
          size: Vector3.all(1),
          material: UnlitMaterial(albedoColor: const Color(0x80800000)),
        ),
      );

      expect(backend.textureTargetsCreated, isEmpty);
      expect(backend.countCommands('setBlendState wboit'), 0);
    });
  });
}
