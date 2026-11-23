import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame_3d/core.dart';
import 'package:flame_3d/src/graphics/backend.dart';
import 'package:flame_3d/src/resources/texture/texture.dart';

/// 3D color-grading lookup table (`size x size x size`, `16x16x16` by default)
/// unpacked horizontally as a `(size * size) x size` (`256x16`) 2D strip
/// [Texture] for single-pass trilinear GPU color grading in
/// `PostProcessSettings`.
class ColorLut3D.fromStripBytes(
  final Uint8List _stripBytes, {
  final int size = 16,
}) {
  this
    : assert(
        size >= 2 && _stripBytes.length == size * size * size * 4,
        'stripBytes must contain size^3 * 4 RGBA8888 bytes',
      );

  /// Synthesizes a `size x size x size` 3D LUT by evaluating [transform] on
  /// normalized `(r, g, b)` coordinates in `[0, 1]`.
  factory ColorLut3D.fromFunction(
    Vector3 Function(double r, double g, double b) transform, {
    int size = 16,
  }) {
    if (size < 2 || size > 64) {
      throw ArgumentError.value(size, 'size', 'Must be between 2 and 64');
    }
    final width = size * size;
    final bytes = Uint8List(width * size * 4);
    final denom = (size - 1).toDouble();

    for (var bIdx = 0; bIdx < size; bIdx++) {
      final b = bIdx / denom;
      for (var gIdx = 0; gIdx < size; gIdx++) {
        final g = gIdx / denom;
        for (var rIdx = 0; rIdx < size; rIdx++) {
          final r = rIdx / denom;
          final mapped = transform(r, g, b);
          final x = bIdx * size + rIdx;
          final o = (gIdx * width + x) * 4;
          bytes[o] = (mapped.x.clamp(0.0, 1.0) * 255.0).round();
          bytes[o + 1] = (mapped.y.clamp(0.0, 1.0) * 255.0).round();
          bytes[o + 2] = (mapped.z.clamp(0.0, 1.0) * 255.0).round();
          bytes[o + 3] = 255;
        }
      }
    }
    return ColorLut3D.fromStripBytes(bytes, size: size);
  }

  /// Neutral identity 3D LUT (`(r, g, b) -> (r, g, b)`).
  factory ColorLut3D.identity({int size = 16}) {
    final out = Vector3.zero();
    return ColorLut3D.fromFunction(
      (r, g, b) => out..setValues(r, g, b),
      size: size,
    );
  }

  /// Warm cinematic film LUT with golden highlights and subtle teal shadows.
  factory ColorLut3D.warmCinematic({int size = 16}) {
    final out = Vector3.zero();
    return ColorLut3D.fromFunction(
      (r, g, b) {
        final lum = 0.299 * r + 0.587 * g + 0.114 * b;
        final shadowW = math.pow(1.0 - lum, 1.6).toDouble();
        final highW = math.pow(lum, 1.3).toDouble();
        var nr = r + highW * 0.12 - shadowW * 0.04;
        var ng = g + highW * 0.05 + shadowW * 0.02;
        var nb = b - highW * 0.08 + shadowW * 0.09;
        nr = _smoothSCurve(nr.clamp(0.0, 1.0));
        ng = _smoothSCurve(ng.clamp(0.0, 1.0));
        nb = _smoothSCurve(nb.clamp(0.0, 1.0));
        return out..setValues(nr, ng, nb);
      },
      size: size,
    );
  }

  /// Cool nocturnal moonlight LUT with crisp cyan-indigo tonal balance.
  factory ColorLut3D.coolNight({int size = 16}) {
    final out = Vector3.zero();
    return ColorLut3D.fromFunction(
      (r, g, b) {
        final lum = 0.299 * r + 0.587 * g + 0.114 * b;
        final desatR = lum + (r - lum) * 0.72;
        final desatG = lum + (g - lum) * 0.82;
        final desatB = lum + (b - lum) * 0.92;
        return out..setValues(
          (desatR * 0.78).clamp(0.0, 1.0),
          (desatG * 0.9 + 0.03).clamp(0.0, 1.0),
          (desatB * 1.16 + 0.07).clamp(0.0, 1.0),
        );
      },
      size: size,
    );
  }

  /// Classic warm vintage sepia tone LUT.
  factory ColorLut3D.sepia({int size = 16}) {
    final out = Vector3.zero();
    return ColorLut3D.fromFunction(
      (r, g, b) => out
        ..setValues(
          (r * 0.393 + g * 0.769 + b * 0.189).clamp(0.0, 1.0),
          (r * 0.349 + g * 0.686 + b * 0.168).clamp(0.0, 1.0),
          (r * 0.272 + g * 0.534 + b * 0.131).clamp(0.0, 1.0),
        ),
      size: size,
    );
  }

  final Expando<Texture> _textures = Expando('ColorLut3DTexture');

  /// Raw `RGBA8888` `(size * size) x size` strip bytes.
  Uint8List get stripBytes => _stripBytes;

  /// Width of the unpacked 2D strip texture (`size * size`).
  int get stripWidth => size * size;

  /// Height of the unpacked 2D strip texture (`size`).
  int get stripHeight => size;

  /// Returns the GPU [Texture] for [backend] (defaulting to
  /// [GpuBackend.instance]).
  Texture textureFor([GpuBackend? backend]) {
    final b = backend ?? GpuBackend.instance;
    return _textures[b] ??= Texture(
      ByteData.sublistView(_stripBytes),
      width: stripWidth,
      height: stripHeight,
      sampler: TextureSampler.linear,
    );
  }

  /// Evaluates trilinear interpolation on CPU at normalized `(r, g, b)`.
  Vector3 sample(double r, double g, double b, {Vector3? out}) {
    final res = out ?? Vector3.zero();
    final maxIdx = size - 1;
    final cr = r.clamp(0.0, 1.0) * maxIdx;
    final cg = g.clamp(0.0, 1.0) * maxIdx;
    final cb = b.clamp(0.0, 1.0) * maxIdx;

    final r0 = cr.floor().clamp(0, maxIdx);
    final g0 = cg.floor().clamp(0, maxIdx);
    final b0 = cb.floor().clamp(0, maxIdx);
    final r1 = math.min(r0 + 1, maxIdx);
    final g1 = math.min(g0 + 1, maxIdx);
    final b1 = math.min(b0 + 1, maxIdx);

    final fr = cr - r0;
    final fg = cg - g0;
    final fb = cb - b0;

    final width = size * size;
    double chan(int ri, int gi, int bi, int c) {
      final x = bi * size + ri;
      return _stripBytes[(gi * width + x) * 4 + c] / 255.0;
    }

    double tri(int c) {
      final c000 = chan(r0, g0, b0, c);
      final c100 = chan(r1, g0, b0, c);
      final c010 = chan(r0, g1, b0, c);
      final c110 = chan(r1, g1, b0, c);
      final c001 = chan(r0, g0, b1, c);
      final c101 = chan(r1, g0, b1, c);
      final c011 = chan(r0, g1, b1, c);
      final c111 = chan(r1, g1, b1, c);

      final c00 = c000 + (c100 - c000) * fr;
      final c10 = c010 + (c110 - c010) * fr;
      final c01 = c001 + (c101 - c001) * fr;
      final c11 = c011 + (c111 - c011) * fr;

      final c0 = c00 + (c10 - c00) * fg;
      final c1 = c01 + (c11 - c01) * fg;
      return c0 + (c1 - c0) * fb;
    }

    return res..setValues(tri(0), tri(1), tri(2));
  }

  static double _smoothSCurve(double x) {
    return (x * x * (3.0 - 2.0 * x)) * 0.25 + x * 0.75;
  }
}
