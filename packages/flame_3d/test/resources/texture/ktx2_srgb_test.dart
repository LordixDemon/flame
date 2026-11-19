import 'dart:typed_data';

import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../_fakes/fake_gpu_backend.dart';

Uint8List _grey(int value, {int size = 4}) {
  final rgba = Uint8List(size * size * 4);
  for (var i = 0; i < size * size; i++) {
    rgba
      ..[i * 4] = value
      ..[i * 4 + 1] = value
      ..[i * 4 + 2] = value
      ..[i * 4 + 3] = 255;
  }
  return rgba;
}

void main() {
  group('Ktx2TextureLoader sRGB block formats', () {
    test('sRGB vkFormats map to sRGB pixel formats', () {
      const k = Ktx2TextureLoader.mapVkFormat;
      expect(
        k(Ktx2TextureLoader.vkFormatBc1RgbaSrgbBlock),
        (GpuPixelFormat.bc1RgbaSrgb, true),
      );
      expect(
        k(Ktx2TextureLoader.vkFormatBc1RgbSrgbBlock),
        (GpuPixelFormat.bc1RgbaSrgb, true),
      );
      expect(
        k(Ktx2TextureLoader.vkFormatBc3SrgbBlock),
        (GpuPixelFormat.bc3RgbaSrgb, true),
      );
      expect(
        k(Ktx2TextureLoader.vkFormatBc7SrgbBlock),
        (GpuPixelFormat.bc7RgbaSrgb, true),
      );
      expect(
        k(Ktx2TextureLoader.vkFormatEtc2R8G8B8SrgbBlock),
        (GpuPixelFormat.etc2Rgb8Srgb, true),
      );
      expect(
        k(Ktx2TextureLoader.vkFormatEtc2R8G8B8A8SrgbBlock),
        (GpuPixelFormat.etc2Rgba8Srgb, true),
      );
      expect(
        k(Ktx2TextureLoader.vkFormatAstc4x4SrgbBlock),
        (GpuPixelFormat.astc4x4Srgb, true),
      );
      expect(
        k(Ktx2TextureLoader.vkFormatAstc8x8SrgbBlock),
        (GpuPixelFormat.astc8x8Srgb, true),
      );
      expect(
        k(Ktx2TextureLoader.vkFormatBc1RgbaUnormBlock),
        (GpuPixelFormat.bc1Rgba, false),
      );
    });

    test('sRGB block formats keep their block geometry', () {
      for (final (srgb, unorm) in [
        (GpuPixelFormat.bc1RgbaSrgb, GpuPixelFormat.bc1Rgba),
        (GpuPixelFormat.bc3RgbaSrgb, GpuPixelFormat.bc3Rgba),
        (GpuPixelFormat.bc7RgbaSrgb, GpuPixelFormat.bc7Rgba),
        (GpuPixelFormat.etc2Rgb8Srgb, GpuPixelFormat.etc2Rgb8),
        (GpuPixelFormat.etc2Rgba8Srgb, GpuPixelFormat.etc2Rgba8),
        (GpuPixelFormat.astc4x4Srgb, GpuPixelFormat.astc4x4),
        (GpuPixelFormat.astc8x8Srgb, GpuPixelFormat.astc8x8),
      ]) {
        expect(srgb.isCompressed, isTrue);
        expect(srgb.blockWidth, unorm.blockWidth);
        expect(srgb.bytesPerBlock, unorm.bytesPerBlock);
      }
    });

    test('an sRGB BC1 file is uploaded as sRGB, directly or decoded', () {
      final ktx = Ktx2TextureLoader.encodeBc1(
        _grey(128),
        width: 4,
        height: 4,
        srgb: true,
      );

      final direct = Ktx2TextureLoader.load(
        ktx,
        backend: FakeGpuBackend(
          supportedFormats: {
            GpuPixelFormat.bc1RgbaSrgb,
            GpuPixelFormat.rgba8888Srgb,
          },
        ),
      );
      expect(
        (direct.resource as FakeTexture).format,
        GpuPixelFormat.bc1RgbaSrgb,
      );

      final decoded = Ktx2TextureLoader.load(
        ktx,
        backend: FakeGpuBackend(
          supportedFormats: {GpuPixelFormat.rgba8888Srgb},
        ),
      );
      expect(
        (decoded.resource as FakeTexture).format,
        GpuPixelFormat.rgba8888Srgb,
      );
    });
  });
}
