import 'package:flame/cache.dart';
import 'package:flame/text.dart';
import 'package:flutter/rendering.dart';
import 'package:meta/meta.dart';

/// [TextPaint] applies a Flutter [TextStyle] to a string of
/// text, creating a [TextPainterTextElement].
class TextPaint({
  TextStyle? style,
  final TextDirection textDirection = TextDirection.ltr,
  final int cacheSize = 10,
}) extends TextRenderer {
  final TextStyle style = style ?? defaultTextStyle;
  int _layoutCount = 0;

  /// Number of [TextPainter.layout] runs executed on this [TextPaint] instance.
  @visibleForTesting
  int get layoutCount => _layoutCount;

  /// Number of cached [TextPainter] entries currently held in memory.
  int get cachedPainterCount => _textPainterCache.size;

  @override
  TextPainterTextElement format(String text) {
    final tp = toTextPainter(text);
    return TextPainterTextElement(tp);
  }

  late final MemoryCache<String, TextPainter> _textPainterCache = MemoryCache(
    cacheSize: cacheSize,
    onEvict: (_, tp) => tp.dispose(),
  );

  /// Disposes all cached [TextPainter] (and native `ui.Paragraph`) instances.
  void dispose() {
    _textPainterCache.clearCache();
  }

  static const TextStyle defaultTextStyle = TextStyle(
    color: Color(0xFFFFFFFF),
    fontFamily: 'Arial',
    fontSize: 24,
  );

  /// Returns a [TextPainter] that allows for text rendering and size
  /// measuring.
  ///
  /// A [TextPainter] has three important properties: paint, width and
  /// height (or size).
  ///
  /// Example usage:
  ///
  ///   const config = TextPaint(fontSize: 48.0, fontFamily: 'Arial');
  ///   final tp = config.toTextPainter('Score: $score');
  ///   tp.paint(canvas, const Offset(10, 10));
  ///
  /// However, you probably want to use the [render] method which already
  /// takes the anchor into consideration.
  /// That way, you don't need to perform the math for that yourself.
  TextPainter toTextPainter(String text) {
    if (!_textPainterCache.containsKey(text)) {
      final tp = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: textDirection,
      );
      tp.layout();
      _layoutCount++;
      _textPainterCache.setValue(text, tp);
    }
    return _textPainterCache.getValue(text)!;
  }

  @override
  TextPaint copyWithPaint(Paint paint) {
    return TextPaint(
      textDirection: textDirection,
      cacheSize: cacheSize,
      style: TextStyle(
        inherit: style.inherit,
        backgroundColor: style.backgroundColor,
        fontSize: style.fontSize,
        fontWeight: style.fontWeight,
        fontStyle: style.fontStyle,
        letterSpacing: style.letterSpacing,
        wordSpacing: style.wordSpacing,
        textBaseline: style.textBaseline,
        height: style.height,
        leadingDistribution: style.leadingDistribution,
        locale: style.locale,
        foreground: paint,
        background: style.background,
        shadows: style.shadows,
        fontFeatures: style.fontFeatures,
        fontVariations: style.fontVariations,
        decoration: style.decoration,
        decorationColor: style.decorationColor,
        decorationStyle: style.decorationStyle,
        decorationThickness: style.decorationThickness,
        debugLabel: style.debugLabel,
        fontFamily: style.fontFamily,
        fontFamilyFallback: style.fontFamilyFallback,
        overflow: style.overflow,
      ),
    );
  }

  TextPaint copyWith(
    TextStyle Function(TextStyle) transform, {
    TextDirection? textDirection,
  }) {
    return TextPaint(
      style: transform(style),
      textDirection: textDirection ?? this.textDirection,
    );
  }

  InlineTextStyle asInlineTextStyle() {
    return InlineTextStyle(
      color: style.color,
      fontFamily: style.fontFamily,
      fontSize: style.fontSize,
      fontWeight: style.fontWeight,
      fontStyle: style.fontStyle,
      letterSpacing: style.letterSpacing,
      wordSpacing: style.wordSpacing,
      height: style.height,
      leadingDistribution: style.leadingDistribution,
      shadows: style.shadows,
      fontFeatures: style.fontFeatures,
      fontVariations: style.fontVariations,
      decoration: style.decoration,
      decorationColor: style.decorationColor,
      decorationStyle: style.decorationStyle,
      decorationThickness: style.decorationThickness,
      background: _extractBackground(style),
      foreground: style.foreground,
    );
  }

  Paint? _extractBackground(TextStyle style) {
    if (style.background != null) {
      return style.background;
    }
    if (style.backgroundColor != null) {
      return Paint()..color = style.backgroundColor!;
    }
    return null;
  }
}
