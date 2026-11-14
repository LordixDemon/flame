import 'dart:async';
import 'dart:ui';

import 'package:flame/src/cache/memory_cache.dart';
import 'package:flame/src/particles/particle_renderer.dart';

/// Renders each particle as a circle, batched into a single draw call.
///
/// Procedural circle textures are rasterized synchronously on first load and
/// shared across all [CircleParticleRenderer] instances via a bounded GPU
/// texture cache keyed by quantized [softness], eliminating first-frame async
/// flicker and preventing per-emitter GPU texture leaks.
class CircleParticleRenderer({
  /// How much the circle fades out towards its edge, from 0 (crisp) to 1
  /// (fully soft).
  final double softness = 0,
  super.blendMode,
  super.paint,
}) extends TextureParticleRenderer {
  /// Creates a circle renderer.
  ///
  /// [softness] goes from 0 (a crisp edge) to 1 (fully faded from the
  /// center), which suits smoke and glow, especially combined with
  /// `blendMode: BlendMode.plus`.
  this
    : assert(
        softness >= 0 && softness <= 1,
        'softness must be between 0 and 1',
      );

  static const int _textureSize = 64;
  static const int _softnessBuckets = 64;

  static final MemoryCache<int, Image> _sharedTextureCache =
      MemoryCache<int, Image>(
        cacheSize: 24,
        onEvict: (_, image) => image.dispose(),
      );

  /// Number of shared procedural circle GPU textures currently cached.
  static int get cachedTextureCount => _sharedTextureCache.size;

  /// Disposes and clears all cached procedural circle GPU textures.
  static void clearTextureCache() => _sharedTextureCache.clearCache();

  static Image _obtainSharedTexture(double softness) {
    final bucket = (softness * _softnessBuckets).round().clamp(
      0,
      _softnessBuckets,
    );
    final existing = _sharedTextureCache.getValue(bucket);
    if (existing != null) {
      return existing;
    }
    final quantized = bucket / _softnessBuckets;
    const white = Color(0xffffffff);
    const transparent = Color(0x00ffffff);
    const radius = _textureSize / 2;
    const center = Offset(radius, radius);
    final paint = Paint();
    if (quantized > 0) {
      paint.shader = Gradient.radial(
        center,
        radius,
        const [white, white, transparent],
        [0, (1 - quantized).clamp(0.0, 0.99), 1],
      );
    } else {
      paint.color = white;
    }
    final recorder = PictureRecorder();
    Canvas(recorder).drawCircle(center, radius, paint);
    final picture = recorder.endRecording();
    final image = picture.toImageSync(_textureSize, _textureSize);
    picture.dispose();
    _sharedTextureCache.setValue(bucket, image);
    return image;
  }

  Image? _texture;

  @override
  Image? get texture => _texture;

  @override
  Rect get srcRect =>
      const Rect.fromLTWH(0, 0, _textureSize * 1.0, _textureSize * 1.0);

  @override
  FutureOr<void> onLoad() {
    _texture ??= _obtainSharedTexture(softness);
  }
}
