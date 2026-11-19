import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';

/// Karis Split-Sum GGX BRDF lookup table (`64x64`) + Kulla–Conty directional
/// albedo for physically-accurate specular Image-Based Lighting.
///
/// The `X` axis parameterizes `NdotV` in `[0, 1]` and the `Y` axis
/// parameterizes perceptual `roughness` in `[0, 1]`. Each texel stores:
/// - `R`: `scale` factor applied to `F0`
/// - `G`: Fresnel `bias` offset
/// - `B`: directional hemispherical albedo `scale + bias` (`E(mu)`) used for
///   Kulla–Conty multi-scattering energy compensation on rough metals.
abstract final class BrdfLut3D() {
  /// Default LUT width and height in texels.
  static const int resolution = 64;

  static Uint8List? _cachedPixels;
  static final Expando<Texture> _backendTextures = Expando('BrdfLut3D');

  /// Returns the shared `64x64` split-sum BRDF LUT [Texture] for [backend]
  /// (defaulting to [GpuBackend.instance]), lazily generated once.
  static Texture sharedTexture([GpuBackend? backend]) {
    final targetBackend = backend ?? GpuBackend.instance;
    return _backendTextures[targetBackend] ??= Texture(
      ByteData.sublistView(_pixels),
      width: resolution,
      height: resolution,
      sampler: TextureSampler.linear,
    );
  }

  static Uint8List get _pixels => _cachedPixels ??= generateRgba8();

  /// Generates an `RGBA8888` split-sum GGX LUT of `size x size` texels using
  /// [sampleCount] Hammersley quasi-Monte Carlo samples per texel.
  static Uint8List generateRgba8({int size = 64, int sampleCount = 64}) {
    final out = Uint8List(size * size * 4);
    for (var y = 0; y < size; y++) {
      final roughness = math.max(0.02, (y + 0.5) / size);
      for (var x = 0; x < size; x++) {
        final nDotV = math.max(1e-3, (x + 0.5) / size);
        final (scale, bias) = integrateBrdf(
          nDotV,
          roughness,
          sampleCount: sampleCount,
        );
        final energy = (scale + bias).clamp(0.0, 1.0);
        final idx = (y * size + x) * 4;
        out[idx] = (scale.clamp(0.0, 1.0) * 255.0).round();
        out[idx + 1] = (bias.clamp(0.0, 1.0) * 255.0).round();
        out[idx + 2] = (energy * 255.0).round();
        out[idx + 3] = 255;
      }
    }
    return out;
  }

  /// Evaluates the split-sum GGX BRDF integral `(scale, bias)` at `[nDotV]`
  /// and perceptual `[roughness]` using Hammersley importance sampling.
  static (double, double) integrateBrdf(
    double nDotV,
    double roughness, {
    int sampleCount = 64,
  }) {
    final clampedNdotV = nDotV.clamp(1e-4, 1.0);
    final r = roughness.clamp(0.02, 1.0);
    final a = r * r;
    final a2 = a * a;

    final vx = math.sqrt(math.max(0.0, 1.0 - clampedNdotV * clampedNdotV));
    const vy = 0.0;
    final vz = clampedNdotV;

    var sumScale = 0.0;
    var sumBias = 0.0;

    // IBL Smith correlated / Schlick-GGX k = a / 2 = r^2 / 2.
    final k = (r * r) * 0.5;
    double gSchlick(double cosTheta) => cosTheta / (cosTheta * (1.0 - k) + k);

    for (var i = 0; i < sampleCount; i++) {
      final xi1 = i / sampleCount;
      final xi2 = _radicalInverseVdC(i);

      final phi = 2.0 * math.pi * xi1;
      final cosTheta = math.sqrt((1.0 - xi2) / (1.0 + (a2 - 1.0) * xi2));
      final sinTheta = math.sqrt(math.max(0.0, 1.0 - cosTheta * cosTheta));

      final hx = math.cos(phi) * sinTheta;
      final hy = math.sin(phi) * sinTheta;
      final hz = cosTheta;

      final vDotH = math.max(0.0, vx * hx + vy * hy + vz * hz);
      final lz = 2.0 * vDotH * hz - vz;

      final nDotL = math.max(0.0, lz);
      final nDotH = math.max(1e-5, hz);

      if (nDotL > 0.0) {
        final g = gSchlick(clampedNdotV) * gSchlick(nDotL);
        final gVis = (g * vDotH) / (nDotH * clampedNdotV);
        final oneMinus = 1.0 - vDotH;
        final oneMinus2 = oneMinus * oneMinus;
        final fc = oneMinus2 * oneMinus2 * oneMinus;

        sumScale += (1.0 - fc) * gVis;
        sumBias += fc * gVis;
      }
    }

    return (sumScale / sampleCount, sumBias / sampleCount);
  }

  static double _radicalInverseVdC(int bitsArg) {
    var bits = bitsArg & 0xFFFFFFFF;
    bits = ((bits << 16) | (bits >> 16)) & 0xFFFFFFFF;
    bits =
        (((bits & 0x55555555) << 1) | ((bits & 0xAAAAAAAA) >> 1)) & 0xFFFFFFFF;
    bits =
        (((bits & 0x33333333) << 2) | ((bits & 0xCCCCCCCC) >> 2)) & 0xFFFFFFFF;
    bits =
        (((bits & 0x0F0F0F0F) << 4) | ((bits & 0xF0F0F0F0) >> 4)) & 0xFFFFFFFF;
    bits =
        (((bits & 0x00FF00FF) << 8) | ((bits & 0xFF00FF00) >> 8)) & 0xFFFFFFFF;
    return bits / 4294967296.0;
  }
}
