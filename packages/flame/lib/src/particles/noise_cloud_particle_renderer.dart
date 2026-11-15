import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/src/cache/memory_cache.dart';
import 'package:flame/src/math/simplex_noise_2d.dart';
import 'package:flame/src/particles/particle_buffer.dart';
import 'package:flame/src/particles/particle_renderer.dart';

/// Renders each particle as one of 8 procedural multi-lobe turbulent cloud
/// puffs (`SimplexNoise2D` fBm), batched into a single [Canvas.drawRawAtlas]
/// (or [Canvas.drawVertices] when stretched) draw call.
///
/// The `4x2` (`256x128`) sprite sheet is rasterized synchronously on first load
/// and cached across instances via a bounded GPU [MemoryCache], giving organic
/// billowing silhouettes for smoke, steam, mist, fog, and fire tongues with
/// zero external image assets and zero first-frame flicker.
class NoiseCloudParticleRenderer({
  final int seed = 701,
  final double puffiness = 0.55,
  super.blendMode,
  super.paint,
}) extends TextureParticleRenderer {
  this
    : assert(
        puffiness >= 0.0 && puffiness <= 1.0,
        'puffiness must be between 0.0 and 1.0',
      );

  static const int _cols = 4;
  static const int _rows = 2;
  static const int variantCount = _cols * _rows;
  static const int _cellSize = 64;
  static const int _atlasWidth = _cols * _cellSize;
  static const int _atlasHeight = _rows * _cellSize;

  static final List<Rect> _cellRects = List<Rect>.generate(
    variantCount,
    (index) {
      final col = index % _cols;
      final row = index ~/ _cols;
      // 1px inset prevents bilinear bleed across adjacent cloud variants.
      return Rect.fromLTWH(
        col * _cellSize + 1.0,
        row * _cellSize + 1.0,
        _cellSize - 2.0,
        _cellSize - 2.0,
      );
    },
    growable: false,
  );

  static final MemoryCache<int, Image> _sharedAtlasCache =
      MemoryCache<int, Image>(
        cacheSize: 16,
        onEvict: (_, image) => image.dispose(),
      );

  /// Number of shared procedural cloud-puff GPU atlases currently cached.
  static int get cachedAtlasCount => _sharedAtlasCache.size;

  /// Disposes and clears all cached procedural cloud-puff GPU atlases.
  static void clearAtlasCache() => _sharedAtlasCache.clearCache();

  static Image _obtainSharedAtlas(int seed, double puffiness) {
    final pBucket = (puffiness * 32).round().clamp(0, 32);
    final key = ((seed & 0xffff) << 6) | pBucket;
    final existing = _sharedAtlasCache.getValue(key);
    if (existing != null) {
      return existing;
    }

    final qPuff = pBucket / 32.0;
    final recorder = PictureRecorder();
    final canvas = Canvas(recorder);
    final lobePaint = Paint();

    for (var idx = 0; idx < variantCount; idx++) {
      final col = idx % _cols;
      final row = idx ~/ _cols;
      final cx = col * _cellSize + _cellSize * 0.5;
      final cy = row * _cellSize + _cellSize * 0.5;
      final noise = SimplexNoise2D(seed: seed + idx * 131);

      // Soft central core + 14 fBm-displaced turbulent perimeter lobes.
      const lobeCount = 15;
      for (var l = 0; l < lobeCount; l++) {
        final double lx;
        final double ly;
        final double radius;
        final double coreAlpha;
        if (l == 0) {
          lx = cx;
          ly = cy;
          radius = _cellSize * 0.34;
          coreAlpha = 0.62;
        } else {
          final frac = (l - 1) / (lobeCount - 1);
          final baseAng = frac * math.pi * 2.0 + idx * 0.47;
          final nRadial = noise.fbm(
            math.cos(baseAng) * 1.4 + idx,
            math.sin(baseAng) * 1.4 - idx,
            octaves: 3,
          );
          final nTangential = noise.sample(l * 0.73, idx * 1.19);
          final ang = baseAng + nTangential * 0.32;
          final dist =
              _cellSize * (0.11 + 0.16 * qPuff + 0.08 * (nRadial * 0.5 + 0.5));
          lx = cx + math.cos(ang) * dist;
          ly = cy + math.sin(ang) * dist;
          radius = _cellSize * (0.17 + 0.09 * (0.5 + 0.5 * nRadial));
          coreAlpha = (0.24 + 0.18 * (1.0 - frac * 0.35)).clamp(0.12, 0.45);
        }

        final aMid = (coreAlpha * 255).round().clamp(0, 255);
        final aSoft = (coreAlpha * 115).round().clamp(0, 255);
        lobePaint.shader = Gradient.radial(
          Offset(lx, ly),
          radius,
          <Color>[
            Color.fromARGB(aMid, 255, 255, 255),
            Color.fromARGB(aSoft, 255, 255, 255),
            const Color(0x00FFFFFF),
          ],
          const <double>[0.0, 0.52, 1.0],
        );
        canvas.drawCircle(Offset(lx, ly), radius, lobePaint);
      }
    }

    final picture = recorder.endRecording();
    final image = picture.toImageSync(_atlasWidth, _atlasHeight);
    picture.dispose();
    _sharedAtlasCache.setValue(key, image);
    return image;
  }

  Image? _texture;

  @override
  Image? get texture => _texture;

  @override
  Rect get srcRect => _cellRects[0];

  @override
  bool get hasPerParticleRects => true;

  @override
  Rect frameRectForParticle(ParticleBuffer particles, int index) =>
      _cellRects[particles.variant[index] & 7];

  @override
  FutureOr<void> onLoad() {
    _texture ??= _obtainSharedAtlas(seed, puffiness);
  }
}
