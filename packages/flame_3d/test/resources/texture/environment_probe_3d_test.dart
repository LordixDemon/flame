import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../_fakes/fake_gpu_backend.dart';

/// A 2:1 panorama whose columns alternate between [a] and [b].
ByteData _stripes(int a, int b, {int width = 32, int height = 16}) {
  final bytes = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final v = x.isEven ? a : b;
      final o = (y * width + x) * 4;
      bytes
        ..[o] = v
        ..[o + 1] = v
        ..[o + 2] = v
        ..[o + 3] = 255;
    }
  }
  return ByteData.sublistView(bytes);
}

double _srgbToLinear(double c) =>
    c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();

void main() {
  group('EnvironmentProbe3D', () {
    test('an sRGB panorama is sampled as linear light, like its SH', () {
      FakeGpuBackend();
      final probe = EnvironmentProbe3D.fromEquirectangular(
        _stripes(128, 128),
        width: 32,
        height: 16,
      );
      final texture = probe.reflectionTexture.resource as FakeTexture;
      expect(texture.format, GpuPixelFormat.rgba8888Srgb);

      // The SH of a uniform panorama of 128 hold its linear value.
      final linear = _srgbToLinear(128 / 255);
      final e = probe.evaluateIrradiance(Vector3(0, 1, 0));
      expect(e.x / math.pi, closeTo(linear, 0.005));
    });

    test('a linear panorama is uploaded as it is', () {
      FakeGpuBackend();
      final probe = EnvironmentProbe3D.fromEquirectangular(
        _stripes(128, 128),
        width: 32,
        height: 16,
        srgb: false,
      );
      final texture = probe.reflectionTexture.resource as FakeTexture;
      expect(texture.format, GpuPixelFormat.rgba8888);
      final e = probe.evaluateIrradiance(Vector3(0, 1, 0));
      expect(e.x / math.pi, closeTo(128 / 255, 0.005));
    });

    test('rough mip levels average light, not encoded values', () {
      FakeGpuBackend();
      final probe = EnvironmentProbe3D.fromEquirectangular(
        _stripes(0, 255),
        width: 32,
        height: 16,
      );
      final texture = probe.reflectionTexture.resource as FakeTexture;
      final (level, bytes) = texture.writes.last;
      expect(level, greaterThan(0));
      // Black and white stripes blur to half the light: sRGB 188, not 128.
      final mid = bytes[(bytes.length ~/ 8) * 4];
      expect(mid, closeTo(188, 3));
    });

    test(
      'without sRGB textures, an sRGB panorama is linearized on the CPU',
      () {
        FakeGpuBackend(supportedFormats: {GpuPixelFormat.rgba8888});
        final probe = EnvironmentProbe3D.fromEquirectangular(
          _stripes(128, 128),
          width: 32,
          height: 16,
        );
        final texture = probe.reflectionTexture.resource as FakeTexture;
        expect(texture.format, GpuPixelFormat.rgba8888);
        final (_, bytes) = texture.writes.first;
        expect(bytes[0], closeTo(_srgbToLinear(128 / 255) * 255, 1));
      },
    );
  });
}
