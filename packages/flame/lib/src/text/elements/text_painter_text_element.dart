import 'dart:ui';

import 'package:flame/text.dart';
import 'package:flutter/rendering.dart' as flutter;
import 'package:meta/meta.dart';

/// A single line of text that is drawn with a laid out Flutter
/// [flutter.TextPainter].
///
/// The painter can be shared with whoever made the element, as `TextPaint`
/// does with its layout cache. In that case `onDispose` is how the element
/// tells its maker that it no longer draws with the painter; it is invoked
/// once, by [dispose].
class TextPainterTextElement(
  final flutter.TextPainter _textPainter, {
  void Function()? onDispose,
}) extends InlineTextElement {
  void Function()? _onDispose = onDispose;

  final LineMetrics _box = LineMetrics(
    ascent: _textPainter.computeDistanceToActualBaseline(
      flutter.TextBaseline.alphabetic,
    ),
    width: _textPainter.width,
    height: _textPainter.height,
  );

  @visibleForTesting
  flutter.TextPainter get textPainter => _textPainter;

  @override
  LineMetrics get metrics => _box;

  @override
  void translate(double dx, double dy) => _box.translate(dx, dy);

  @override
  void draw(Canvas canvas) {
    _textPainter.paint(canvas, Offset(_box.left, _box.top));
  }

  /// Gives up the text painter of this element, which lets a shared painter
  /// be disposed as soon as nothing else uses it.
  ///
  /// The element must not be drawn afterwards. Calling this more than once is
  /// harmless.
  @override
  void dispose() {
    final onDispose = _onDispose;
    _onDispose = null;
    onDispose?.call();
  }

  @override
  String toString() {
    return 'TextPainterTextElement(text: ${_textPainter.text?.toPlainText()})';
  }
}
