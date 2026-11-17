import 'dart:async';
import 'dart:ui';

import 'package:flame/src/particles/particle_renderer.dart';
import 'package:flame/src/particles/shared_particle_texture_cache.dart';

/// Renders each particle as a circle, batched into a single draw call.
///
/// Procedural circle textures are rasterized synchronously on first load and
/// shared across all [CircleParticleRenderer] instances via a bounded GPU
/// texture cache keyed by quantized [softness], eliminating first-frame async
/// flicker and preventing per-emitter GPU texture leaks.
///
/// The shared texture is reference counted: it is never disposed while a
/// loaded renderer uses it, not even by [clearTextureCache] or when the
/// cache evicts it. A renderer gives its texture back in [dispose] (or when
/// it is garbage collected) and takes a fresh one on the next [onLoad].
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

  static final SharedParticleTextureCache<int> _sharedTextureCache =
      SharedParticleTextureCache<int>(capacity: 24);

  /// Number of shared procedural circle GPU textures currently cached.
  static int get cachedTextureCount => _sharedTextureCache.size;

  /// Empties the shared texture cache.
  ///
  /// Textures that no renderer uses are disposed immediately. A texture that
  /// a loaded renderer still draws with stays valid and is disposed when its
  /// last renderer is disposed; renderers loaded afterwards get a new one.
  static void clearTextureCache() => _sharedTextureCache.clear();

  static int _bucketOf(double softness) =>
      (softness * _softnessBuckets).round().clamp(0, _softnessBuckets);

  static Image _rasterize(int bucket) {
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
    return image;
  }

  SharedParticleTexture? _shared;

  @override
  Image? get texture => _shared?.image;

  @override
  Rect get srcRect =>
      const Rect.fromLTWH(0, 0, _textureSize * 1.0, _textureSize * 1.0);

  @override
  FutureOr<void> onLoad() {
    final shared = _shared;
    if (shared == null || shared.isDisposed) {
      final bucket = _bucketOf(softness);
      _shared = _sharedTextureCache.acquire(
        bucket,
        this,
        () => _rasterize(bucket),
      );
    }
  }

  @override
  void dispose() {
    final shared = _shared;
    if (shared != null) {
      _shared = null;
      _sharedTextureCache.release(shared, this);
    }
    super.dispose();
  }
}
