import 'dart:ui';

import 'package:flame/src/particles/particle_buffer.dart';
import 'package:flame/src/particles/particle_renderer.dart';

/// Renders particles using a sprite-sheet flipbook (`columns × rows`) batched
/// into a single [Canvas.drawRawAtlas] call.
///
/// When [fps] is null (default), frames advance from `0` to `frameCount - 1`
/// across each particle's normalized lifetime `progressAt(i)`. When [fps] is
/// set, frames advance at [fps] frames per second (wrapping around when [loop]
/// is `true`), offset by each particle's deterministic `variant` seed when
/// [randomizeStartFrame] is `true`.
class FlipbookParticleRenderer({
  required final Image image,
  required final int columns,
  required final int rows,
  int? frameCount,
  final double? fps,
  final bool loop = true,
  final bool randomizeStartFrame = false,
  Rect? sheetRegion,
  super.blendMode,
  super.paint,
}) extends TextureParticleRenderer {
  this
    : assert(columns > 0, 'columns must be positive'),
      assert(rows > 0, 'rows must be positive') {
    assert(
      _totalFrames > 0 && _totalFrames <= columns * rows,
      'frameCount ($_totalFrames) must be within 1..${columns * rows}',
    );
    final region =
        sheetRegion ??
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
    final cellW = region.width / columns;
    final cellH = region.height / rows;
    _frames = List<Rect>.generate(_totalFrames, (index) {
      final col = index % columns;
      final row = index ~/ columns;
      return Rect.fromLTWH(
        region.left + col * cellW,
        region.top + row * cellH,
        cellW,
        cellH,
      );
    }, growable: false);
  }

  final int _totalFrames = frameCount ?? (columns * rows);
  late final List<Rect> _frames;

  /// Precomputed source rectangles for each frame in the flipbook.
  List<Rect> get frames => _frames;

  @override
  Image get texture => image;

  @override
  Rect get srcRect => _frames[0];

  @override
  bool get hasPerParticleRects => _totalFrames > 1;

  @override
  Rect frameRectForParticle(ParticleBuffer particles, int index) {
    final startOffset = randomizeStartFrame
        ? (particles.variant[index] % _totalFrames)
        : 0;
    final rate = fps;
    int frame;
    if (rate != null && rate > 0) {
      final raw = startOffset + (particles.age[index] * rate).floor();
      frame = loop ? (raw % _totalFrames) : raw.clamp(0, _totalFrames - 1);
    } else {
      final p = particles.progressAt(index).clamp(0.0, 0.999999);
      final raw = startOffset + (p * _totalFrames).floor();
      frame = randomizeStartFrame
          ? (raw % _totalFrames)
          : raw.clamp(0, _totalFrames - 1);
    }
    return _frames[frame];
  }
}

/// Renders each particle using a deterministic random region from [sourceRects]
/// on a shared [image] atlas, batched into a single [Canvas.drawRawAtlas] call.
///
/// Ideal for debris shards, petals, snowflakes, leaves, runes, or sparkles
/// packed into one atlas texture.
class VariantSpriteParticleRenderer({
  required final Image image,
  required final List<Rect> sourceRects,
  super.blendMode,
  super.paint,
}) extends TextureParticleRenderer {
  this : assert(sourceRects.isNotEmpty, 'sourceRects must not be empty');

  @override
  Image get texture => image;

  @override
  Rect get srcRect => sourceRects[0];

  @override
  bool get hasPerParticleRects => sourceRects.length > 1;

  @override
  Rect frameRectForParticle(ParticleBuffer particles, int index) {
    return sourceRects[particles.variant[index] % sourceRects.length];
  }
}
