import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/src/graphics/backend/flutter_gpu/shader_bundle_reflection.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_fakes/fake_gpu_backend.dart';

void main() {
  group('StylizedMaterial 1-sampler MatCap atlas', () {
    test(
      'atlas shader bundles stay within GLES 3.0 limits with 1 fewer sampler',
      () {
        for (final (name, expectedSamplers) in const [
          ('stylized_material_atlas', 3),
          ('stylized_material_textured_atlas', 4),
        ]) {
          final bytes = File(
            'assets/shaders/$name.shaderbundle',
          ).readAsBytesSync();
          final stages = reflectShaderBundleGlesRequirements(
            ByteData.sublistView(bytes),
          )!;
          final frag = stages['TextureFragment']!;
          expect(frag.samplers, expectedSamplers, reason: name);
          expect(frag.uniformVectors, lessThanOrEqualTo(224), reason: name);
        }
      },
    );

    test('selects atlas fragment shader and binds matCapAtlasTexture', () {
      final backend = FakeGpuBackend();
      final device = GraphicsDevice(backend: backend);
      final context = RenderContext3D(device)
        ..setCamera(Matrix4.identity(), Matrix4.identity());

      final atlas = Texture(
        null,
        width: 4,
        height: 2,
        gpuTexture: FakeTexture(4, 2, 1, GpuPixelFormat.rgba8888),
      );
      final material = StylizedMaterial(matCapAtlasTexture: atlas);
      final surface = StylizedMaterial.buildSurface(
        positions: const [0, 0, 0, 1, 0, 0, 0, 1, 0],
        normals: const [0, 0, 1, 0, 0, 1, 0, 0, 1],
        indices: const [0, 1, 2],
        material: material,
      );

      device.begin();
      device.beginPass(const Size(32, 32));
      context.drawSurface(surface, material: material);
      context.flush();
      device.endPass().dispose();
      device.end();

      expect(device.lastFrameStats.drawCalls, 1);

      // Clearing matCapAtlasTexture switches back to the 2-sampler shader.
      material.matCapAtlasTexture = null;
      device.begin();
      device.beginPass(const Size(32, 32));
      context.drawSurface(surface, material: material);
      context.flush();
      device.endPass().dispose();
      device.end();

      expect(device.lastFrameStats.drawCalls, 1);
      atlas.dispose();
    });
  });
}
