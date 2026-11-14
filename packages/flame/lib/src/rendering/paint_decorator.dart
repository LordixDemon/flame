import 'dart:ui';

import 'package:flame/src/rendering/decorator.dart';
import 'package:meta/meta.dart';

/// [PaintDecorator] applies a paint filter to a group of drawing operations.
///
/// Specifically, the following filters are available:
/// - [PaintDecorator.blur] adds Gaussian blur to the image, as if your vision
///   became blurry and out of focus;
/// - [PaintDecorator.tint] tints the picture with the specified color, as if
///   looking through a colored glass;
/// - [PaintDecorator.grayscale] removes all color from the picture, as if it
///   was a black-and-white photo.
class PaintDecorator extends Decorator {
  PaintDecorator.blur(double amount, [double? amountY]) {
    addBlur(amount, amountY ?? amount);
  }

  PaintDecorator.tint(Color color) {
    _paint.colorFilter = ColorFilter.mode(color, BlendMode.srcATop);
  }

  PaintDecorator.grayscale({double opacity = 1.0}) {
    _paint.color = Color.fromARGB((255 * opacity).toInt(), 0, 0, 0);
    _paint.blendMode = BlendMode.luminosity;
  }

  final _paint = Paint();
  double _blurX = 0.0;
  double _blurY = 0.0;

  /// Whether [applyChain] bounds should be passed to [Canvas.saveLayer]
  /// (inflated by `3 * sigma` when blur is active) to avoid full-viewport GPU
  /// offscreen allocations.
  bool useBoundedSaveLayer = true;

  Rect? _lastInputBounds;
  double _lastCachedBlurX = -1.0;
  double _lastCachedBlurY = -1.0;
  Rect? _cachedLayerBounds;
  Rect? _lastSaveLayerBounds;

  /// Most recent bounds passed to [Canvas.saveLayer] (`null` when unbounded).
  @visibleForTesting
  Rect? get lastSaveLayerBounds => _lastSaveLayerBounds;

  void addBlur(double amount, [double? amountY]) {
    final sigmaX = amount;
    final sigmaY = amountY ?? amount;
    _blurX = sigmaX > 0 ? sigmaX : 0.0;
    _blurY = sigmaY > 0 ? sigmaY : 0.0;
    _paint.imageFilter = ImageFilter.blur(
      sigmaX: sigmaX,
      sigmaY: sigmaY,
    );
    _cachedLayerBounds = null;
  }

  Rect _resolveLayerBounds(Rect bounds) {
    final cached = _cachedLayerBounds;
    if (cached != null &&
        _lastInputBounds == bounds &&
        _lastCachedBlurX == _blurX &&
        _lastCachedBlurY == _blurY) {
      return cached;
    }
    final padX = _blurX > 0 ? 4.0 * _blurX + 4.0 : 2.0;
    final padY = _blurY > 0 ? 4.0 * _blurY + 4.0 : 2.0;
    final resolved = Rect.fromLTRB(
      bounds.left - padX,
      bounds.top - padY,
      bounds.right + padX,
      bounds.bottom + padY,
    );
    _lastInputBounds = bounds;
    _lastCachedBlurX = _blurX;
    _lastCachedBlurY = _blurY;
    _cachedLayerBounds = resolved;
    return resolved;
  }

  @override
  void apply(void Function(Canvas) draw, Canvas canvas) {
    _lastSaveLayerBounds = null;
    canvas.saveLayer(null, _paint);
    draw(canvas);
    canvas.restore();
  }

  @override
  void applyBounded(void Function(Canvas) draw, Canvas canvas, Rect? bounds) {
    if (!useBoundedSaveLayer || bounds == null || bounds.isEmpty) {
      apply(draw, canvas);
      return;
    }
    final layerBounds = _resolveLayerBounds(bounds);
    _lastSaveLayerBounds = layerBounds;
    canvas.saveLayer(layerBounds, _paint);
    draw(canvas);
    canvas.restore();
  }
}
