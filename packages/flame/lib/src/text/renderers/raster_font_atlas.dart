import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/src/anchor.dart';
import 'package:flutter/painting.dart';

/// Metrics for a single baked glyph inside a [RasterFontAtlas].
class const RasterGlyphMetrics({
  required final ui.Rect atlasRect,
  required final double advance,
  required final double drawOffsetX,
  required final double drawOffsetY,
  required final double logicalWidth,
  required final double logicalHeight,
});

/// Pre-rasterized GPU glyph atlas (`ui.Image`) enabling arbitrary numbers of
/// dynamic labels, damage/coin popups, price tags, and multipliers to render in
/// a single `Canvas.drawRawAtlas` call with zero per-frame `Paragraph` layouts.
class RasterFontAtlas._(
  final Map<int, RasterGlyphMetrics> _glyphs, {
  required final ui.Image image,
  required final double pixelRatio,
  required final double lineHeight,
  required final double baseline,
  required final double spaceAdvance,
}) {
  static const String _asciiPartA = ' !"#\$%&\'()*+,-./0123456789:;<=>?@';
  static const String _asciiPartB = r'ABCDEFGHIJKLMNOPQRSTUVWXYZ[\]^_`';
  static const String _asciiPartC =
      'abcdefghijklmnopqrstuvwxyz{|}~×÷±€£¥₽₩★☆▲▼◆•—–…';

  /// Default printable ASCII + common game symbols (`×`, `÷`, `±`, currencies,
  /// stars, arrows).
  static const String defaultCharset = '$_asciiPartA$_asciiPartB$_asciiPartC';

  static const String _cyrUpper = 'АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ';
  static const String _cyrLower = 'абвгдеёжзийклмнопрстуфхцчшщъыьэюя';

  /// Cyrillic uppercase and lowercase alphabet for localized labels.
  static const String cyrillicCharset = '$_cyrUpper$_cyrLower';

  /// Synchronous shelf-packer that rasterizes every unique rune in [charset]
  /// into a single GPU [ui.Image] texture.
  ///
  /// By default ([bakeWhiteForTinting] = `true`), glyph fills are baked in pure
  /// white (`0xFFFFFFFF`) while optional [outlineWidth] / [outlineColor] or
  /// `style.shadows` bake dark borders directly into the glyph cells, allowing
  /// `BlendMode.modulate` to tint fills to any runtime [Color] in one shared
  /// `drawRawAtlas` batch while keeping outlines dark and crisp.
  factory RasterFontAtlas.bake({
    required TextStyle style,
    String charset = defaultCharset,
    bool includeCyrillic = false,
    double pixelRatio = 2.0,
    double padding = 2.0,
    double outlineWidth = 0.0,
    ui.Color outlineColor = const ui.Color(0xE6000000),
    bool bakeWhiteForTinting = true,
  }) {
    assert(pixelRatio > 0, 'pixelRatio must be positive: $pixelRatio');
    assert(padding >= 0, 'padding must be non-negative: $padding');

    final fullChars = includeCyrillic ? '$charset$cyrillicCharset' : charset;
    final uniqueRunes = <int>{...fullChars.runes, 0x20, 0x3F}; // ' ' and '?'

    final fillStyle = bakeWhiteForTinting
        ? style.copyWith(color: const ui.Color(0xFFFFFFFF))
        : style;
    final strokeStyle = outlineWidth > 0
        ? style.copyWith(
            foreground: Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = outlineWidth
              ..strokeJoin = StrokeJoin.round
              ..color = outlineColor,
          )
        : null;

    var shadowPad = 0.0;
    final shadows = fillStyle.shadows;
    if (shadows != null) {
      for (final s in shadows) {
        final reach =
            math.max(s.offset.dx.abs(), s.offset.dy.abs()) + s.blurRadius * 2.0;
        if (reach > shadowPad) {
          shadowPad = reach;
        }
      }
    }
    final extraLogicalMargin = outlineWidth * 0.6 + shadowPad + padding;

    final measured =
        <
          ({
            int rune,
            String charStr,
            double advance,
            double cellLogicalW,
            double cellLogicalH,
            int cellPxW,
            int cellPxH,
            double padLogical,
            double baseline,
          })
        >[];

    var maxLineHeight = 0.0;
    var maxBaseline = 0.0;
    var spaceAdv = (fillStyle.fontSize ?? 14.0) * 0.32;
    var totalAreaPx = 0;

    final painter = TextPainter(textDirection: TextDirection.ltr);
    for (final rune in uniqueRunes) {
      final s = String.fromCharCode(rune);
      painter
        ..text = TextSpan(text: s, style: fillStyle)
        ..layout();
      final w = painter.width;
      final h = painter.height;
      final base = painter.computeDistanceToActualBaseline(
        TextBaseline.alphabetic,
      );
      if (h > maxLineHeight) {
        maxLineHeight = h;
      }
      if (base > maxBaseline) {
        maxBaseline = base;
      }
      if (rune == 0x20) {
        spaceAdv = w > 0 ? w : spaceAdv;
      }
      final cellLogW = w + extraLogicalMargin * 2;
      final cellLogH = h + extraLogicalMargin * 2;
      final pxW = math.max(2, (cellLogW * pixelRatio).ceil() + 2);
      final pxH = math.max(2, (cellLogH * pixelRatio).ceil() + 2);
      totalAreaPx += pxW * pxH;
      measured.add((
        rune: rune,
        charStr: s,
        advance: w,
        cellLogicalW: pxW / pixelRatio,
        cellLogicalH: pxH / pixelRatio,
        cellPxW: pxW,
        cellPxH: pxH,
        padLogical: extraLogicalMargin,
        baseline: base,
      ));
    }

    // Choose power-of-two-ish atlas width capable of holding all shelf rows.
    var atlasWidthPx = 128;
    while (atlasWidthPx < 2048 &&
        atlasWidthPx * atlasWidthPx < totalAreaPx * 1.45) {
      atlasWidthPx *= 2;
    }
    for (final m in measured) {
      if (m.cellPxW + 2 > atlasWidthPx) {
        atlasWidthPx = m.cellPxW + 2;
      }
    }

    final placements = <({int index, int pxX, int pxY})>[];
    var cursorX = 1;
    var cursorY = 1;
    var rowHeight = 0;
    for (var i = 0; i < measured.length; i++) {
      final m = measured[i];
      if (cursorX + m.cellPxW + 1 > atlasWidthPx) {
        cursorX = 1;
        cursorY += rowHeight + 1;
        rowHeight = 0;
      }
      placements.add((index: i, pxX: cursorX, pxY: cursorY));
      cursorX += m.cellPxW + 1;
      if (m.cellPxH > rowHeight) {
        rowHeight = m.cellPxH;
      }
    }
    final atlasHeightPx = math.max(16, cursorY + rowHeight + 2);

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(
      recorder,
      ui.Rect.fromLTWH(0, 0, atlasWidthPx.toDouble(), atlasHeightPx.toDouble()),
    );
    canvas.scale(pixelRatio, pixelRatio);

    final strokePainter = strokeStyle != null
        ? TextPainter(textDirection: TextDirection.ltr)
        : null;
    final glyphMap = <int, RasterGlyphMetrics>{};

    for (final p in placements) {
      final m = measured[p.index];
      final logX = p.pxX / pixelRatio;
      final logY = p.pxY / pixelRatio;
      final drawPos = ui.Offset(logX + m.padLogical, logY + m.padLogical);

      if (m.rune != 0x20) {
        if (strokePainter != null) {
          strokePainter
            ..text = TextSpan(text: m.charStr, style: strokeStyle)
            ..layout()
            ..paint(canvas, drawPos);
        }
        painter
          ..text = TextSpan(text: m.charStr, style: fillStyle)
          ..layout()
          ..paint(canvas, drawPos);
      }

      glyphMap[m.rune] = RasterGlyphMetrics(
        atlasRect: ui.Rect.fromLTWH(
          p.pxX.toDouble(),
          p.pxY.toDouble(),
          m.cellPxW.toDouble(),
          m.cellPxH.toDouble(),
        ),
        advance: m.advance,
        drawOffsetX: -m.padLogical,
        drawOffsetY: -m.padLogical,
        logicalWidth: m.cellLogicalW,
        logicalHeight: m.cellLogicalH,
      );
    }

    painter.dispose();
    strokePainter?.dispose();

    final picture = recorder.endRecording();
    final atlasImage = picture.toImageSync(atlasWidthPx, atlasHeightPx);
    picture.dispose();

    return RasterFontAtlas._(
      glyphMap,
      image: atlasImage,
      pixelRatio: pixelRatio,
      lineHeight: maxLineHeight > 0
          ? maxLineHeight
          : (fillStyle.fontSize ?? 14.0),
      baseline: maxBaseline,
      spaceAdvance: spaceAdv,
    );
  }

  bool _disposed = false;

  /// Whether [dispose] has been called on this atlas.
  bool get isDisposed => _disposed;

  /// Number of distinct Unicode runes baked into this atlas.
  int get glyphCount => _glyphs.length;

  /// Looks up metrics for [rune], falling back to `'?'` (`0x3F`) if absent.
  RasterGlyphMetrics? metricsForRune(int rune) =>
      _glyphs[rune] ?? _glyphs[0x3F];

  /// Measures the logical width of [text] with zero allocations.
  ///
  /// A line feed (`\n`) starts a new line, as it does in
  /// [GlyphBatchRenderer.addText]; the result is the width of the widest line.
  double measureWidth(String text, {double letterSpacing = 0.0}) {
    if (text.isEmpty) {
      return 0.0;
    }
    var widest = 0.0;
    var lineStart = 0;
    while (true) {
      final lineEnd = _lineEnd(text, lineStart);
      final width = _measureRange(text, lineStart, lineEnd, letterSpacing);
      if (width > widest) {
        widest = width;
      }
      if (lineEnd >= text.length) {
        return widest;
      }
      lineStart = lineEnd + 1;
    }
  }

  /// Number of lines [text] occupies: one more than its line feeds.
  int lineCountOf(String text) {
    var lines = 1;
    for (var i = 0; i < text.length; i++) {
      if (text.codeUnitAt(i) == 0x0A) {
        lines++;
      }
    }
    return lines;
  }

  /// Index of the line feed that ends the line starting at [start], or the
  /// length of [text] for its last line.
  static int _lineEnd(String text, int start) {
    final lf = text.indexOf('\n', start);
    return lf < 0 ? text.length : lf;
  }

  /// Reads the Unicode code point at code unit [index] of [text], joining a
  /// surrogate pair into one rune.
  static int _runeAt(String text, int index, int end) {
    final cu = text.codeUnitAt(index);
    if (cu >= 0xD800 && cu <= 0xDBFF && index + 1 < end) {
      final next = text.codeUnitAt(index + 1);
      if (next >= 0xDC00 && next <= 0xDFFF) {
        return 0x10000 + ((cu - 0xD800) << 10) + (next - 0xDC00);
      }
    }
    return cu;
  }

  /// Width of the single line made of the code units `[start, end)` of
  /// [text]. Carriage returns take no space.
  double _measureRange(String text, int start, int end, double letterSpacing) {
    var width = 0.0;
    var count = 0;
    for (var i = start; i < end; i++) {
      final rune = _runeAt(text, i, end);
      if (rune > 0xFFFF) {
        i++;
      }
      if (rune == 0x0D) {
        continue;
      }
      final m = metricsForRune(rune);
      width += m?.advance ?? spaceAdvance;
      count++;
    }
    if (count > 1 && letterSpacing != 0.0) {
      width += (count - 1) * letterSpacing;
    }
    return width;
  }

  /// Disposes the underlying GPU [image].
  void dispose() {
    if (!_disposed) {
      _disposed = true;
      image.dispose();
    }
  }
}

/// Zero-allocation Struct-of-Arrays glyph batch accumulator submitting hundreds
/// of dynamic strings sharing a [RasterFontAtlas] in a single
/// [ui.Canvas.drawRawAtlas] call.
class GlyphBatchRenderer({
  int initialGlyphCapacity = 256,
}) {
  Float32List _transforms = Float32List(
    math.max(32, initialGlyphCapacity) * 4,
  );
  Float32List _rects = Float32List(math.max(32, initialGlyphCapacity) * 4);
  Int32List _colors = Int32List(math.max(32, initialGlyphCapacity));
  final ui.Paint _paint = ui.Paint()..filterQuality = ui.FilterQuality.low;

  int _glyphCount = 0;
  int _lastFlushedGlyphs = 0;
  int _lastFlushDrawCalls = 0;

  /// Number of glyphs currently buffered since [begin].
  int get bufferedGlyphCount => _glyphCount;

  /// Number of glyphs drawn in the most recent [flush].
  int get lastFlushedGlyphs => _lastFlushedGlyphs;

  /// Number of `Canvas.drawRawAtlas` calls issued in the most recent [flush].
  int get lastFlushDrawCalls => _lastFlushDrawCalls;

  void _ensureCapacity(int needed) {
    if (_colors.length >= needed) {
      return;
    }
    var cap = _colors.length * 2;
    while (cap < needed) {
      cap *= 2;
    }
    _transforms = Float32List(cap * 4)
      ..setRange(0, _glyphCount * 4, _transforms);
    _rects = Float32List(cap * 4)..setRange(0, _glyphCount * 4, _rects);
    _colors = Int32List(cap)..setRange(0, _glyphCount, _colors);
  }

  /// Resets the glyph buffer for a new batch pass.
  void begin() {
    _glyphCount = 0;
  }

  /// Appends [text] using [atlas] anchored at `(x, y)` with optional [anchor],
  /// uniform [scale], [rotation] (radians), [color] tint, and [letterSpacing].
  ///
  /// A line feed (`\n`) starts a new line one [RasterFontAtlas.lineHeight]
  /// below; a carriage return is ignored. [anchor] positions the whole block
  /// vertically and each line horizontally by its own width, so
  /// `Anchor.center` centres every line.
  void addText(
    RasterFontAtlas atlas,
    String text, {
    required double x,
    required double y,
    Anchor anchor = Anchor.topLeft,
    double scale = 1.0,
    double rotation = 0.0,
    ui.Color color = const ui.Color(0xFFFFFFFF),
    double letterSpacing = 0.0,
  }) {
    if (text.isEmpty || scale <= 0.0 || color.a <= 0.0) {
      return;
    }
    _ensureCapacity(_glyphCount + text.length);

    final lineHeight = atlas.lineHeight;
    final totalH = lineHeight * atlas.lineCountOf(text);
    final startLocalY = -anchor.y * totalH;

    final invPixelRatio = 1.0 / atlas.pixelRatio;
    final effScale = scale * invPixelRatio;
    final cosA = rotation == 0.0 ? 1.0 : math.cos(rotation);
    final sinA = rotation == 0.0 ? 0.0 : math.sin(rotation);
    final scos = effScale * cosA;
    final ssin = effScale * sinA;
    final argb = color.toARGB32();

    var lineStart = 0;
    var lineIndex = 0;
    while (true) {
      final lineEnd = RasterFontAtlas._lineEnd(text, lineStart);
      final lineW = (anchor.x == 0.0)
          ? 0.0
          : atlas._measureRange(text, lineStart, lineEnd, letterSpacing);
      final lineLocalY = startLocalY + lineIndex * lineHeight;

      var penX = -anchor.x * lineW;
      for (var i = lineStart; i < lineEnd; i++) {
        final rune = RasterFontAtlas._runeAt(text, i, lineEnd);
        if (rune > 0xFFFF) {
          i++;
        }
        if (rune == 0x0D) {
          continue;
        }
        if (rune == 0x20) {
          penX += atlas.spaceAdvance + letterSpacing;
          continue;
        }
        final m = atlas.metricsForRune(rune);
        if (m == null) {
          penX += atlas.spaceAdvance + letterSpacing;
          continue;
        }
        final gx = (penX + m.drawOffsetX) * scale;
        final gy = (lineLocalY + m.drawOffsetY) * scale;
        final tx = x + gx * cosA - gy * sinA;
        final ty = y + gx * sinA + gy * cosA;

        final slot = _glyphCount++;
        _ensureCapacity(_glyphCount + 1);
        final t4 = slot * 4;
        _transforms[t4] = scos;
        _transforms[t4 + 1] = ssin;
        _transforms[t4 + 2] = tx;
        _transforms[t4 + 3] = ty;

        final r = m.atlasRect;
        _rects[t4] = r.left;
        _rects[t4 + 1] = r.top;
        _rects[t4 + 2] = r.right;
        _rects[t4 + 3] = r.bottom;
        _colors[slot] = argb;

        penX += m.advance + letterSpacing;
      }

      if (lineEnd >= text.length) {
        break;
      }
      lineStart = lineEnd + 1;
      lineIndex++;
    }
  }

  /// Appends a single baked glyph [metrics] from [atlas] at `(x, y)` with
  /// uniform [scale], [rotation], and [color] into the active batch.
  void addGlyph(
    RasterFontAtlas atlas,
    RasterGlyphMetrics metrics, {
    required double x,
    required double y,
    double scale = 1.0,
    double rotation = 0.0,
    ui.Color color = const ui.Color(0xFFFFFFFF),
  }) {
    if (scale <= 0.0 || color.a <= 0.0) {
      return;
    }
    final slot = _glyphCount++;
    _ensureCapacity(_glyphCount + 1);
    final effScale = scale / atlas.pixelRatio;
    final cosA = rotation == 0.0 ? 1.0 : math.cos(rotation);
    final sinA = rotation == 0.0 ? 0.0 : math.sin(rotation);
    final gx = metrics.drawOffsetX * scale;
    final gy = metrics.drawOffsetY * scale;

    final t4 = slot * 4;
    _transforms[t4] = effScale * cosA;
    _transforms[t4 + 1] = effScale * sinA;
    _transforms[t4 + 2] = x + gx * cosA - gy * sinA;
    _transforms[t4 + 3] = y + gx * sinA + gy * cosA;

    final r = metrics.atlasRect;
    _rects[t4] = r.left;
    _rects[t4 + 1] = r.top;
    _rects[t4 + 2] = r.right;
    _rects[t4 + 3] = r.bottom;
    _colors[slot] = color.toARGB32();
  }

  /// Flushes all buffered glyphs for [atlas] onto [canvas] in a single
  /// `Canvas.drawRawAtlas` call.
  void flush(
    ui.Canvas canvas,
    RasterFontAtlas atlas, {
    ui.BlendMode blendMode = ui.BlendMode.modulate,
    ui.FilterQuality filterQuality = ui.FilterQuality.low,
  }) {
    _lastFlushedGlyphs = _glyphCount;
    if (_glyphCount == 0 || atlas.isDisposed) {
      _lastFlushDrawCalls = 0;
      _glyphCount = 0;
      return;
    }
    _paint.filterQuality = filterQuality;
    canvas.drawRawAtlas(
      atlas.image,
      Float32List.sublistView(_transforms, 0, _glyphCount * 4),
      Float32List.sublistView(_rects, 0, _glyphCount * 4),
      Int32List.sublistView(_colors, 0, _glyphCount),
      blendMode,
      null,
      _paint,
    );
    _lastFlushDrawCalls = 1;
    _glyphCount = 0;
  }
}
