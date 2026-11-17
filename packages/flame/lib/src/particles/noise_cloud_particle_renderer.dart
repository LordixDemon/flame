import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flame/src/math/simplex_noise_2d.dart';
import 'package:flame/src/particles/particle_buffer.dart';
import 'package:flame/src/particles/particle_renderer.dart';
import 'package:flame/src/particles/shared_particle_texture_cache.dart';

/// Renders each particle as one of 8 procedural multi-lobe turbulent cloud
/// puffs (`SimplexNoise2D` fBm), batched into a single [Canvas.drawRawAtlas]
/// (or [Canvas.drawVertices] when stretched) draw call.
///
/// The `4x2` (`256x128`) sprite sheet is rasterized synchronously on first load
/// and shared between instances with the same [seed] and [puffiness] through
/// a bounded GPU texture cache, giving organic billowing silhouettes for
/// smoke, steam, mist, fog, and fire tongues with zero external image assets
/// and zero first-frame flicker.
///
/// [puffiness] (`0..1`) pushes the outer lobes away from the core for a more
/// billowy outline. Every puff is fitted into its atlas cell, so it always
/// fades to full transparency before the edge of the region a particle
/// samples, whatever the puffiness.
///
/// The shared atlas is reference counted: it is never disposed while a loaded
/// renderer uses it, not even by [clearAtlasCache] or when the cache evicts
/// it. A renderer gives its atlas back in [dispose] (or when it is garbage
/// collected) and takes a fresh one on the next [onLoad].
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
  static const int _puffinessBuckets = 32;
  static const int _lobeCount = 15;

  /// Inset of the sampled region inside its cell, which prevents bilinear
  /// bleed across adjacent cloud variants.
  static const double _cellInset = 1.0;

  /// The largest distance from the cell center a puff may reach: one pixel
  /// short of the sampled region, so its border is fully transparent.
  static const double _fitRadius = _cellSize * 0.5 - _cellInset - 1.0;

  static final List<Rect> _cellRects = List<Rect>.generate(
    variantCount,
    (index) {
      final col = index % _cols;
      final row = index ~/ _cols;
      return Rect.fromLTWH(
        col * _cellSize + _cellInset,
        row * _cellSize + _cellInset,
        _cellSize - 2 * _cellInset,
        _cellSize - 2 * _cellInset,
      );
    },
    growable: false,
  );

  static final SharedParticleTextureCache<int> _sharedAtlasCache =
      SharedParticleTextureCache<int>(capacity: 16);

  /// Number of shared procedural cloud-puff GPU atlases currently cached.
  static int get cachedAtlasCount => _sharedAtlasCache.size;

  /// Empties the shared atlas cache.
  ///
  /// Atlases that no renderer uses are disposed immediately. An atlas that a
  /// loaded renderer still draws with stays valid and is disposed when its
  /// last renderer is disposed; renderers loaded afterwards get a new one.
  static void clearAtlasCache() => _sharedAtlasCache.clear();

  static int _bucketOf(double puffiness) =>
      (puffiness * _puffinessBuckets).round().clamp(0, _puffinessBuckets);

  static Image _rasterize(int seed, int puffinessBucket) {
    final qPuff = puffinessBucket / _puffinessBuckets;
    final recorder = PictureRecorder();
    final canvas = Canvas(recorder);
    final lobePaint = Paint();
    final lobeX = Float64List(_lobeCount);
    final lobeY = Float64List(_lobeCount);
    final lobeRadius = Float64List(_lobeCount);
    final lobeAlpha = Float64List(_lobeCount);

    for (var idx = 0; idx < variantCount; idx++) {
      final col = idx % _cols;
      final row = idx ~/ _cols;
      final cx = col * _cellSize + _cellSize * 0.5;
      final cy = row * _cellSize + _cellSize * 0.5;
      final noise = SimplexNoise2D(seed: seed + idx * 131);

      // Soft central core + 14 fBm-displaced turbulent perimeter lobes, laid
      // out relative to the cell center.
      var extent = 0.0;
      for (var l = 0; l < _lobeCount; l++) {
        if (l == 0) {
          lobeX[l] = 0;
          lobeY[l] = 0;
          lobeRadius[l] = _cellSize * 0.34;
          lobeAlpha[l] = 0.62;
        } else {
          final frac = (l - 1) / (_lobeCount - 1);
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
          lobeX[l] = math.cos(ang) * dist;
          lobeY[l] = math.sin(ang) * dist;
          lobeRadius[l] = _cellSize * (0.17 + 0.09 * (0.5 + 0.5 * nRadial));
          lobeAlpha[l] = (0.24 + 0.18 * (1.0 - frac * 0.35)).clamp(0.12, 0.45);
        }
        final reach =
            math.sqrt(lobeX[l] * lobeX[l] + lobeY[l] * lobeY[l]) +
            lobeRadius[l];
        if (reach > extent) {
          extent = reach;
        }
      }

      // Shrink the whole puff when its lobes would reach past the sampled
      // region; the clip is a guard against bleeding into neighbor cells.
      final fit = extent > _fitRadius ? _fitRadius / extent : 1.0;
      canvas.save();
      canvas.clipRect(_cellRects[idx]);
      for (var l = 0; l < _lobeCount; l++) {
        final center = Offset(cx + lobeX[l] * fit, cy + lobeY[l] * fit);
        final radius = lobeRadius[l] * fit;
        final aMid = (lobeAlpha[l] * 255).round().clamp(0, 255);
        final aSoft = (lobeAlpha[l] * 115).round().clamp(0, 255);
        lobePaint.shader = Gradient.radial(
          center,
          radius,
          <Color>[
            Color.fromARGB(aMid, 255, 255, 255),
            Color.fromARGB(aSoft, 255, 255, 255),
            const Color(0x00FFFFFF),
          ],
          const <double>[0.0, 0.52, 1.0],
        );
        canvas.drawCircle(center, radius, lobePaint);
      }
      canvas.restore();
    }

    final picture = recorder.endRecording();
    final image = picture.toImageSync(_atlasWidth, _atlasHeight);
    picture.dispose();
    return image;
  }

  SharedParticleTexture? _shared;

  @override
  Image? get texture => _shared?.image;

  @override
  Rect get srcRect => _cellRects[0];

  @override
  bool get hasPerParticleRects => true;

  @override
  Rect frameRectForParticle(ParticleBuffer particles, int index) =>
      _cellRects[particles.variant[index] & 7];

  @override
  FutureOr<void> onLoad() {
    final shared = _shared;
    if (shared == null || shared.isDisposed) {
      final bucket = _bucketOf(puffiness);
      // 64 slots per seed keep every (seed, puffiness) pair apart.
      _shared = _sharedAtlasCache.acquire(
        seed * 64 + bucket,
        this,
        () => _rasterize(seed, bucket),
      );
    }
  }

  @override
  void dispose() {
    final shared = _shared;
    if (shared != null) {
      _shared = null;
      _sharedAtlasCache.release(shared, this);
    }
    super.dispose();
  }
}
