import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:flame_3d/core.dart';
import 'package:flame_3d/src/graphics/backend.dart';
import 'package:flame_3d/src/resources/texture/texture.dart';

/// Minimal read-only contract implemented by spatial reflection probe volumes
/// (such as `ReflectionProbeVolume3D`) so materials can bind local IBL probes
/// without depending on the `components` layer.
abstract interface class ReflectionProbeSource3D() {
  /// Baked environment probe supplied by this volume.
  EnvironmentProbe3D get probe;

  /// Whether reflections inside this volume use box-projected parallax.
  bool get boxProjection;

  /// Distance outside the probe bounds over which the blend weight fades to 0.
  double get blendDistance;

  /// Selection priority among overlapping probes (higher wins).
  int get priority;

  /// Current world-space center of this reflection probe volume.
  Vector3 get worldCenter;

  /// Current world-space AABB bounds of this reflection probe volume.
  Aabb3 get worldBounds;

  /// Smooth containment weight in `[0, 1]` for [worldPoint].
  double weightAt(Vector3 worldPoint);
}

/// {@template environment_probe_3d}
/// Pre-filtered Image-Based Lighting (IBL) probe storing 9-band (`L0..L2`)
/// Spherical Harmonics (`SH9`) diffuse irradiance coefficients alongside a
/// roughness-prefiltered mipmapped equirectangular specular reflection
/// [reflectionTexture].
///
/// Can be baked on the CPU from any RGBA8888 equirectangular panorama via
/// [EnvironmentProbe3D.fromEquirectangular] or synthesized procedurally from
/// sky/horizon/ground/sun parameters via [EnvironmentProbe3D.skyDome].
/// {@endtemplate}
class EnvironmentProbe3D({
  required final List<Vector3> shCoefficients,
  required final Texture reflectionTexture,
  var double intensity = 1.0,
}) {
  /// {@macro environment_probe_3d}
  this : assert(shCoefficients.length == 9, 'SH9 requires 9 coefficients');

  /// Evaluates diffuse irradiance (`RGB`, linear) for unit world [normal]
  /// using the Ramamoorthi & Hanrahan `L0..L2` cosine-lobe convolution.
  ///
  /// A Lambertian surface of albedo `a` reflects `a * E / π` of it, which is
  /// what `SpatialMaterial` adds to its ambient term (times [intensity]): a
  /// uniform panorama of value `v` gives `E = π v` and lights the surface as
  /// an ambient light of value `v`.
  Vector3 evaluateIrradiance(Vector3 normal, {Vector3? out}) {
    final res = out ?? Vector3.zero();
    final x = normal.x;
    final y = normal.y;
    final z = normal.z;

    const c0 = 0.282095 * math.pi;
    const c1 = 0.488603 * (2.0 * math.pi / 3.0);
    const c2 = 1.092548 * (math.pi / 4.0);
    const c3 = 0.315392 * (math.pi / 4.0);
    const c4 = 0.546274 * (math.pi / 4.0);

    const b0 = c0;
    final b1 = c1 * y;
    final b2 = c1 * z;
    final b3 = c1 * x;
    final b4 = c2 * x * y;
    final b5 = c2 * y * z;
    final b6 = c3 * (3.0 * z * z - 1.0);
    final b7 = c2 * x * z;
    final b8 = c4 * (x * x - y * y);

    final c = shCoefficients;
    final r =
        c[0].x * b0 +
        c[1].x * b1 +
        c[2].x * b2 +
        c[3].x * b3 +
        c[4].x * b4 +
        c[5].x * b5 +
        c[6].x * b6 +
        c[7].x * b7 +
        c[8].x * b8;
    final g =
        c[0].y * b0 +
        c[1].y * b1 +
        c[2].y * b2 +
        c[3].y * b3 +
        c[4].y * b4 +
        c[5].y * b5 +
        c[6].y * b6 +
        c[7].y * b7 +
        c[8].y * b8;
    final b =
        c[0].z * b0 +
        c[1].z * b1 +
        c[2].z * b2 +
        c[3].z * b3 +
        c[4].z * b4 +
        c[5].z * b5 +
        c[6].z * b6 +
        c[7].z * b7 +
        c[8].z * b8;

    return res..setValues(
      math.max(0.0, r * intensity),
      math.max(0.0, g * intensity),
      math.max(0.0, b * intensity),
    );
  }

  /// Projects an RGBA8888 `2:1` equirectangular [pixels] buffer onto `SH9`
  /// radiance coefficients and builds a roughness-prefiltered mipmapped
  /// specular reflection texture.
  ///
  /// With [srgb] (the default) the pixels are sRGB-encoded, like those of a
  /// Flutter image: the coefficients are projected from their linear values,
  /// and the reflection texture is uploaded as an sRGB texture that the GPU
  /// decodes to linear when sampling (or, on devices without sRGB textures,
  /// decoded on the CPU into a linear 8-bit texture), so reflections and
  /// diffuse light agree. Its blurred mip levels are computed in linear
  /// light. Without [srgb] the pixels are linear values and are used as
  /// they are.
  factory EnvironmentProbe3D.fromEquirectangular(
    ByteData pixels, {
    required int width,
    required int height,
    double intensity = 1.0,
    bool srgb = true,
  }) {
    final coeffs = List.generate(9, (_) => Vector3.zero());
    final raw = pixels.buffer.asUint8List(
      pixels.offsetInBytes,
      pixels.lengthInBytes,
    );
    final dPhi = 2.0 * math.pi / width;
    final dTheta = math.pi / height;

    for (var row = 0; row < height; row++) {
      final theta = (row + 0.5) / height * math.pi;
      final sinTheta = math.sin(theta);
      final cosTheta = math.cos(theta);
      final solidAngle = sinTheta * dTheta * dPhi;
      final y = cosTheta;

      for (var col = 0; col < width; col++) {
        final phi = ((col + 0.5) / width - 0.5) * 2.0 * math.pi;
        final x = sinTheta * math.cos(phi);
        final z = sinTheta * math.sin(phi);

        final idx = (row * width + col) * 4;
        final decode = srgb ? _srgbToLinear : _unormToLinear;
        final r = decode[raw[idx]];
        final g = decode[raw[idx + 1]];
        final b = decode[raw[idx + 2]];

        final y00 = 0.282095 * solidAngle;
        final y1m1 = 0.488603 * y * solidAngle;
        final y10 = 0.488603 * z * solidAngle;
        final y11 = 0.488603 * x * solidAngle;
        final y2m2 = 1.092548 * x * y * solidAngle;
        final y2m1 = 1.092548 * y * z * solidAngle;
        final y20 = 0.315392 * (3.0 * z * z - 1.0) * solidAngle;
        final y21 = 1.092548 * x * z * solidAngle;
        final y22 = 0.546274 * (x * x - y * y) * solidAngle;

        _accum(coeffs[0], r, g, b, y00);
        _accum(coeffs[1], r, g, b, y1m1);
        _accum(coeffs[2], r, g, b, y10);
        _accum(coeffs[3], r, g, b, y11);
        _accum(coeffs[4], r, g, b, y2m2);
        _accum(coeffs[5], r, g, b, y2m1);
        _accum(coeffs[6], r, g, b, y20);
        _accum(coeffs[7], r, g, b, y21);
        _accum(coeffs[8], r, g, b, y22);
      }
    }

    final tex = _PrefilteredEquirectTexture(
      pixels,
      width: width,
      height: height,
      srgb: srgb,
    );
    return EnvironmentProbe3D(
      shCoefficients: coeffs,
      reflectionTexture: tex,
      intensity: intensity,
    );
  }

  /// Synthesizes a procedural atmospheric sky dome panorama (`width x height`)
  /// and bakes its exact `SH9` diffuse probe + roughness-prefiltered mip chain.
  factory EnvironmentProbe3D.skyDome({
    int width = 128,
    int height = 64,
    Color zenithColor = const Color(0xFF0A2463),
    Color horizonColor = const Color(0xFF60A5FA),
    Color groundColor = const Color(0xFF334155),
    Vector3? upAxis,
    Vector3? sunDirection,
    Color sunColor = const Color(0xFFFFFBEB),
    double sunIntensity = 1.2,
    double intensity = 1.0,
  }) {
    final up = (upAxis?.clone() ?? Vector3(0, 1, 0))..normalize();
    final toSun = ((sunDirection?.clone() ?? Vector3(-0.4, -0.8, -0.3))
      ..scale(-1.0)
      ..normalize());
    final bytes = Uint8List(width * height * 4);
    final dir = Vector3.zero();

    for (var row = 0; row < height; row++) {
      final theta = (row + 0.5) / height * math.pi;
      final sinT = math.sin(theta);
      final cosT = math.cos(theta);
      for (var col = 0; col < width; col++) {
        final phi = ((col + 0.5) / width - 0.5) * 2.0 * math.pi;
        dir.setValues(sinT * math.cos(phi), cosT, sinT * math.sin(phi));
        final elev = dir.dot(up);
        double r;
        double g;
        double b;
        if (elev >= 0.0) {
          final t = math.pow(elev, 0.65).toDouble();
          r = _lerp(horizonColor.r, zenithColor.r, t);
          g = _lerp(horizonColor.g, zenithColor.g, t);
          b = _lerp(horizonColor.b, zenithColor.b, t);
        } else {
          final t = math.pow(-elev, 0.55).toDouble();
          r = _lerp(horizonColor.r, groundColor.r, t);
          g = _lerp(horizonColor.g, groundColor.g, t);
          b = _lerp(horizonColor.b, groundColor.b, t);
        }
        final sunCos = math.max(0.0, dir.dot(toSun));
        final glow = math.pow(sunCos, 16.0).toDouble() * 0.45 * sunIntensity;
        r = (r + sunColor.r * glow).clamp(0.0, 1.0);
        g = (g + sunColor.g * glow).clamp(0.0, 1.0);
        b = (b + sunColor.b * glow).clamp(0.0, 1.0);

        final i = (row * width + col) * 4;
        bytes
          ..[i] = (r * 255).round()
          ..[i + 1] = (g * 255).round()
          ..[i + 2] = (b * 255).round()
          ..[i + 3] = 255;
      }
    }

    return EnvironmentProbe3D.fromEquirectangular(
      ByteData.sublistView(bytes),
      width: width,
      height: height,
      intensity: intensity,
    );
  }

  static void _accum(Vector3 out, double r, double g, double b, double weight) {
    out.x += r * weight;
    out.y += g * weight;
    out.z += b * weight;
  }

  static double _lerp(double a, double b, double t) => a + (b - a) * t;

  /// The linear value of each 8-bit sRGB code (the exact sRGB curve, which
  /// the GPU uses for sRGB textures).
  static final Float32List _srgbToLinear = Float32List.fromList([
    for (var i = 0; i < 256; i++) _decodeSrgb(i / 255.0),
  ]);

  /// The value of each 8-bit linear code.
  static final Float32List _unormToLinear = Float32List.fromList([
    for (var i = 0; i < 256; i++) i / 255.0,
  ]);

  static double _decodeSrgb(double c) =>
      c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();

  static double _encodeSrgb(double l) => l <= 0.0031308
      ? l * 12.92
      : 1.055 * math.pow(l, 1.0 / 2.4).toDouble() - 0.055;
}

/// Equirectangular specular reflection texture whose mip chain is pre-convolved
/// with widening Gaussian lobes (wrapping horizontally across `u = 0..1` and
/// clamping at the poles) so `textureLod(..., roughness * maxMip)` produces
/// smooth blurred reflections at higher roughness values. The blur runs on
/// linear values; [srgb] pixels are stored in an sRGB texture when the device
/// has one, else decoded to a linear texture.
class _PrefilteredEquirectTexture(
  super.sourceData, {
  required super.width,
  required super.height,
  required final bool srgb,
}) extends Texture {
  this
    : super(
        mipmaps: true,
        colorSpace: srgb ? TextureColorSpace.srgb : TextureColorSpace.linear,
        sampler: const TextureSampler(
          minFilter: TextureFilter.linear,
          magFilter: TextureFilter.linear,
          mipFilter: TextureFilter.linear,
          wrapU: TextureWrap.repeat,
        ),
      );

  @override
  GpuTexture createResource() {
    final data = sourceData!;
    final backend = GpuBackend.instance;
    final levels = math.min(6, backend.maxMipLevelCount(width, height));
    final srgbStorage =
        srgb && backend.supportsPixelFormat(GpuPixelFormat.rgba8888Srgb);
    final gpuTex = backend.createTexture(
      storageMode: GpuStorageMode.hostVisible,
      width: width,
      height: height,
      format: srgbStorage
          ? GpuPixelFormat.rgba8888Srgb
          : GpuPixelFormat.rgba8888,
      mipLevelCount: levels,
    );

    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    final decode = srgb
        ? EnvironmentProbe3D._srgbToLinear
        : EnvironmentProbe3D._unormToLinear;
    var prev = Float32List(width * height * 4);
    for (var i = 0; i < prev.length; i++) {
      // Alpha is linear.
      prev[i] = (i & 3) == 3 ? bytes[i] / 255.0 : decode[bytes[i]];
    }
    if (srgbStorage || !srgb) {
      gpuTex.write(data);
    } else {
      gpuTex.write(ByteData.sublistView(_encode(prev, srgb: false)));
    }

    var prevW = width;
    var prevH = height;
    for (var level = 1; level < levels; level++) {
      final mipW = math.max(1, width >> level);
      final mipH = math.max(1, height >> level);
      final roughness = levels > 1 ? level / (levels - 1) : 0.0;
      final next = _convolveRoughnessMip(
        prev,
        prevW,
        prevH,
        mipW,
        mipH,
        roughness,
      );
      gpuTex.write(
        ByteData.sublistView(_encode(next, srgb: srgbStorage)),
        mipLevel: level,
      );
      prev = next;
      prevW = mipW;
      prevH = mipH;
    }
    return gpuTex;
  }

  static Uint8List _encode(Float32List linear, {required bool srgb}) {
    final out = Uint8List(linear.length);
    for (var i = 0; i < linear.length; i++) {
      final v = linear[i].clamp(0.0, 1.0);
      final encoded = srgb && (i & 3) != 3
          ? EnvironmentProbe3D._encodeSrgb(v)
          : v;
      out[i] = (encoded * 255.0).round();
    }
    return out;
  }

  /// Blurs [src] (`srcW x srcH` linear RGBA) into a `dstW x dstH` level with
  /// a Gaussian centered on each destination texel's footprint.
  static Float32List _convolveRoughnessMip(
    Float32List src,
    int srcW,
    int srcH,
    int dstW,
    int dstH,
    double roughness,
  ) {
    final dst = Float32List(dstW * dstH * 4);
    final radius = math.max(1, (roughness * 3.0).ceil());
    final sigma = math.max(0.65, roughness * 2.2);
    final inv2Sigma2 = 0.5 / (sigma * sigma);

    for (var y = 0; y < dstH; y++) {
      final fy = (y + 0.5) / dstH * srcH - 0.5;
      final y0 = fy.floor();
      for (var x = 0; x < dstW; x++) {
        final fx = (x + 0.5) / dstW * srcW - 0.5;
        final x0 = fx.floor();
        var sumR = 0.0;
        var sumG = 0.0;
        var sumB = 0.0;
        var sumA = 0.0;
        var sumW = 0.0;

        for (var sy = y0 - radius; sy <= y0 + 1 + radius; sy++) {
          final cy = sy.clamp(0, srcH - 1);
          final dy = sy - fy;
          for (var sx = x0 - radius; sx <= x0 + 1 + radius; sx++) {
            final cx = sx % srcW;
            final dx = sx - fx;
            final w = math.exp(-(dx * dx + dy * dy) * inv2Sigma2);
            final o = (cy * srcW + cx) * 4;
            sumR += src[o] * w;
            sumG += src[o + 1] * w;
            sumB += src[o + 2] * w;
            sumA += src[o + 3] * w;
            sumW += w;
          }
        }

        final invW = sumW > 0.0 ? 1.0 / sumW : 1.0;
        final outIdx = (y * dstW + x) * 4;
        dst[outIdx] = sumR * invW;
        dst[outIdx + 1] = sumG * invW;
        dst[outIdx + 2] = sumB * invW;
        dst[outIdx + 3] = sumA * invW;
      }
    }
    return dst;
  }
}
