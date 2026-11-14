import 'dart:ui';

import 'package:flame/components.dart';
import 'package:flame/text.dart';
import 'package:flutter/painting.dart';
import 'package:meta/meta.dart';

class TextComponent<T extends TextRenderer>({
  String? text,
  T? textRenderer,
  super.position,
  super.size,
  super.scale,
  super.angle,
  super.anchor,
  super.children,
  super.priority,
  super.sortKey,
  super.key,
}) extends PositionComponent with HasPaint {
  this {
    updateBounds();
  }

  /// Whether pure opacity and color-filter animations (`setOpacity`,
  /// `OpacityEffect`, `ColorEffect`) on [TextPaint] renderers modulate at
  /// draw-time without recreating [TextPaint] or re-running HarfBuzz
  /// `TextPainter.layout()`.
  bool fastPaintModulation = true;

  bool _ownsRenderer = textRenderer == null;
  bool _usingRendererPaintCopy = false;
  bool _elementDisposed = false;
  Paint? _modulationPaint;

  String get text => _text;
  String _text = text ?? '';
  set text(String text) {
    if (_text != text) {
      _text = text;
      updateBounds();
    }
  }

  T get textRenderer => _textRenderer;
  T _textRenderer = textRenderer ?? TextRendererFactory.createDefault<T>();
  set textRenderer(T textRenderer) {
    if (_ownsRenderer &&
        !identical(_textRenderer, textRenderer) &&
        _textRenderer is TextPaint) {
      (_textRenderer as TextPaint).dispose();
    }
    _textRenderer = textRenderer;
    _ownsRenderer = false;
    _usingRendererPaintCopy = false;
    updateBounds();
  }

  late InlineTextElement _textElement;

  void _updateElement() {
    _elementDisposed = false;
    _textElement = _textRenderer.format(_text);
    _textElement.translate(0, _textElement.metrics.ascent);
  }

  @internal
  void updateBounds() {
    _updateElement();
    final measurements = _textElement.metrics;
    size.setValues(measurements.width, measurements.height);
  }

  bool _canFastModulatePaint() {
    if (!fastPaintModulation ||
        _usingRendererPaintCopy ||
        _textRenderer is! TextPaint) {
      return false;
    }
    final p = paint;
    return p.style == PaintingStyle.fill &&
        p.shader == null &&
        p.maskFilter == null &&
        (p.color.toARGB32() & 0x00FFFFFF) == 0x00FFFFFF;
  }

  @mustCallSuper
  @override
  void onMount() {
    super.onMount();
    if (_elementDisposed) {
      _updateElement();
    }
  }

  @mustCallSuper
  @override
  void onRemove() {
    if (_ownsRenderer && _textRenderer is TextPaint) {
      (_textRenderer as TextPaint).dispose();
      _elementDisposed = true;
    }
    super.onRemove();
  }

  @override
  void render(Canvas canvas) {
    if (_elementDisposed) {
      _updateElement();
    }
    if (_canFastModulatePaint()) {
      final p = paint;
      final alpha = p.color.a;
      if (alpha <= 0.0 && p.colorFilter == null) {
        return;
      }
      final needsLayer =
          alpha < 1.0 ||
          p.colorFilter != null ||
          p.imageFilter != null ||
          p.blendMode != BlendMode.srcOver;
      if (!needsLayer) {
        _textElement.draw(canvas);
        return;
      }
      final layerPaint = (_modulationPaint ??= Paint())
        ..color = Color.fromARGB(
          (alpha * 255.0).round().clamp(0, 255),
          255,
          255,
          255,
        )
        ..colorFilter = p.colorFilter
        ..imageFilter = p.imageFilter
        ..blendMode = p.blendMode;
      canvas.saveLayer(
        Rect.fromLTWH(-2.0, -2.0, size.x + 4.0, size.y + 4.0),
        layerPaint,
      );
      _textElement.draw(canvas);
      canvas.restore();
      return;
    }
    _textElement.draw(canvas);
  }

  @override
  void onChanged() {
    if (_canFastModulatePaint()) {
      return;
    }
    final previous = _textRenderer;
    _textRenderer = _textRenderer.copyWithPaint(paint) as T;
    if (_ownsRenderer &&
        !identical(previous, _textRenderer) &&
        previous is TextPaint) {
      previous.dispose();
    }
    _ownsRenderer = true;
    _usingRendererPaintCopy = true;
    _updateElement();
  }
}
