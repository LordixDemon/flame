import 'package:flame/cache.dart';
import 'package:flame/extensions.dart';
import 'package:flame/src/anchor.dart';
import 'package:flame/text.dart';
import 'package:flutter/rendering.dart';
import 'package:meta/meta.dart';

/// [TextPaint] applies a Flutter [TextStyle] to a string of
/// text, creating a [TextPainterTextElement].
///
/// ## Layout cache
///
/// Laying out a string is expensive, so the laid out [TextPainter] of the
/// last [cacheSize] distinct strings is kept in a least-recently-used cache
/// and shared by everything that formats the same string again. A string
/// that is measured or drawn counts as used, so the strings that are on
/// screen every frame are the last ones to leave the cache.
///
/// A painter is shared between the cache and the elements returned by
/// [format]. It is disposed (releasing the native paragraph) as soon as it
/// has left the cache **and** no element draws with it any more, never
/// earlier:
///
/// - Any number of components can share one [TextPaint], with any number of
///   distinct strings on screen at the same time; an element stays drawable
///   for as long as it is in use, however many other strings are formatted
///   and also after [dispose].
/// - An element gives up its painter with `TextElement.dispose`, which the
///   Flame text components call when their text changes and when they are
///   removed. An element that is never disposed keeps its painter alive until
///   both are garbage collected.
class TextPaint({
  TextStyle? style,
  final TextDirection textDirection = TextDirection.ltr,

  /// How many laid out strings are kept for reuse. With `0` nothing is cached
  /// and every call lays the string out again.
  final int cacheSize = 10,
}) extends TextRenderer {
  this : assert(cacheSize >= 0, 'cacheSize must be >= 0: $cacheSize');

  final TextStyle style = style ?? defaultTextStyle;
  int _layoutCount = 0;

  /// Number of [TextPainter.layout] runs executed on this [TextPaint] instance.
  @visibleForTesting
  int get layoutCount => _layoutCount;

  /// Number of cached [TextPainter] entries currently held in memory.
  int get cachedPainterCount => _textPainterCache.size;

  /// Lays out [text], or reuses its cached layout, and returns an element
  /// that draws it.
  ///
  /// The element shares its [TextPainter] with the cache and stays valid until
  /// its `dispose` method is called; see the class documentation.
  @override
  TextPainterTextElement format(String text) {
    final shared = _obtain(text);
    shared.holders++;
    return TextPainterTextElement(shared.painter, onDispose: shared.release);
  }

  @override
  LineMetrics getLineMetrics(String text) {
    // Measures on the cached painter directly, so that measuring many strings
    // (as line breaking does) leaves no element behind that would keep their
    // painters alive.
    final painter = _obtain(text).painter;
    return LineMetrics(
      ascent: painter.computeDistanceToActualBaseline(TextBaseline.alphabetic),
      width: painter.width,
      height: painter.height,
    );
  }

  @override
  void render(
    Canvas canvas,
    String text,
    Vector2 position, {
    Anchor anchor = Anchor.topLeft,
  }) {
    final element = format(text);
    try {
      element.render(canvas, position, anchor: anchor);
    } finally {
      element.dispose();
    }
  }

  late final MemoryCache<String, _SharedTextPainter> _textPainterCache =
      MemoryCache(
        cacheSize: cacheSize,
        onEvict: (_, shared) => shared.leaveCache(),
      );

  /// Empties the layout cache.
  ///
  /// The cached [TextPainter]s (and their native `ui.Paragraph`s) that no
  /// element draws with are disposed right away. The ones that are still in
  /// use stay valid and are disposed when the last element using them is
  /// disposed. The [TextPaint] itself can still be used afterwards.
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
  ///
  /// The returned painter is never disposed by this [TextPaint], since it can
  /// not know for how long the caller keeps it: it stays valid for as long as
  /// it is referenced and is reclaimed by the garbage collector. Use [format],
  /// [render] or [getLineMetrics] to let the cache release the native
  /// paragraph as soon as it is unused.
  TextPainter toTextPainter(String text) {
    final shared = _obtain(text);
    shared.hasEscaped = true;
    return shared.painter;
  }

  /// The laid out painter for [text], from the cache when it is there.
  _SharedTextPainter _obtain(String text) {
    final cached = _textPainterCache.getValue(text);
    if (cached != null) {
      return cached;
    }
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: textDirection,
    )..layout();
    _layoutCount++;
    final shared = _SharedTextPainter(painter);
    if (cacheSize > 0) {
      shared.isCached = true;
      _textPainterCache.setValue(text, shared);
    }
    return shared;
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
      cacheSize: cacheSize,
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

/// A laid out [TextPainter] that is shared by the layout cache of a
/// [TextPaint] and the elements that draw with it.
///
/// The painter is disposed once it is neither cached nor held by an element.
class _SharedTextPainter(final TextPainter painter) {
  /// The number of elements made by [TextPaint.format] that draw with
  /// [painter] and have not been disposed.
  int holders = 0;

  /// Whether [painter] is in the layout cache.
  bool isCached = false;

  /// Whether [painter] was handed out by [TextPaint.toTextPainter], after
  /// which only the garbage collector can tell when it is unused.
  bool hasEscaped = false;

  bool _isDisposed = false;

  /// Gives up the hold of one element. This is a field so that the elements
  /// of one painter share a single closure.
  late final void Function() release = _release;

  /// Called when the layout cache drops [painter].
  void leaveCache() {
    isCached = false;
    _disposeIfUnused();
  }

  void _release() {
    assert(holders > 0, 'A text painter was released more often than held');
    if (holders > 0) {
      holders--;
    }
    _disposeIfUnused();
  }

  void _disposeIfUnused() {
    if (isCached || holders > 0 || hasEscaped || _isDisposed) {
      return;
    }
    _isDisposed = true;
    painter.dispose();
  }
}
