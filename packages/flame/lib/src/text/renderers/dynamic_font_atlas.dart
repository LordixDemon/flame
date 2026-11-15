import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// Metrics and page binding for a single glyph baked inside a
/// [DynamicFontAtlas].
class const DynamicGlyphEntry({
  required this.pageIndex,
  required this.atlasRect,
  required this.advance,
  required this.drawOffsetX,
  required this.drawOffsetY,
  required this.logicalWidth,
  required this.logicalHeight,
}) {
  final int pageIndex;
  final ui.Rect atlasRect;
  final double advance;
  final double drawOffsetX;
  final double drawOffsetY;
  final double logicalWidth;
  final double logicalHeight;
}

class _DynamicAtlasPage(this.sizePx) {
  final int sizePx;
  ui.Image? image;
  int cursorX = 1;
  int cursorY = 1;
  int shelfHeight = 0;

  void dispose() {
    image?.dispose();
    image = null;
  }
}

/// Multi-page shelf-packed GPU font atlas (`ui.Image` pages) that lazily
/// rasterizes unseen Unicode codepoints (Latin, Cyrillic, CJK, symbols, emoji,
/// multiplayer nicknames) **on demand** without invalidating or moving the
/// `(pageIndex, atlasRect)` of any previously baked glyph.
class DynamicFontAtlas({
  required this.style,
  this.pageSizePx = 512,
  this.pixelRatio = 2.0,
  this.paddingLogical = 2.0,
  this.outlineWidth = 0.0,
  this.outlineColor = const ui.Color(0xE6000000),
  this.bakeWhiteForTinting = true,
  String preloadCharset = ' ?',
}) {
  this
    : assert(pageSizePx >= 64, 'pageSizePx must be >= 64: $pageSizePx'),
      assert(pixelRatio > 0.0, 'pixelRatio must be > 0: $pixelRatio') {
    _fillStyle = bakeWhiteForTinting
        ? style.copyWith(color: const ui.Color(0xFFFFFFFF))
        : style;
    _strokeStyle = outlineWidth > 0.0
        ? style.copyWith(
            foreground: Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = outlineWidth
              ..strokeJoin = StrokeJoin.round
              ..color = outlineColor,
          )
        : null;

    _painter
      ..text = TextSpan(text: 'Mg', style: _fillStyle)
      ..layout();
    _lineHeight = math.max(1.0, _painter.height);
    _baseline = _painter.computeDistanceToActualBaseline(
      TextBaseline.alphabetic,
    );

    _painter
      ..text = TextSpan(text: ' ', style: _fillStyle)
      ..layout();
    _spaceAdvance = _painter.width > 0.0
        ? _painter.width
        : ((_fillStyle.fontSize ?? 14.0) * 0.32);

    if (preloadCharset.isNotEmpty) {
      ensureGlyphsForText(preloadCharset);
    }
  }

  final TextStyle style;
  final int pageSizePx;
  final double pixelRatio;
  final double paddingLogical;
  final double outlineWidth;
  final ui.Color outlineColor;
  final bool bakeWhiteForTinting;

  late final TextStyle _fillStyle;
  late final TextStyle? _strokeStyle;
  late final double _lineHeight;
  late final double _baseline;
  late final double _spaceAdvance;

  final TextPainter _painter = TextPainter(textDirection: TextDirection.ltr);
  final Map<int, DynamicGlyphEntry> _glyphs = <int, DynamicGlyphEntry>{};
  final List<_DynamicAtlasPage> _pages = <_DynamicAtlasPage>[];
  final ui.Paint _copyPaint = ui.Paint()
    ..blendMode = ui.BlendMode.src
    ..filterQuality = ui.FilterQuality.none;
  final ui.Paint _batchPaint = ui.Paint()
    ..filterQuality = ui.FilterQuality.medium;

  int _totalBakedGlyphs = 0;
  int _pageBakeCount = 0;

  double get lineHeight => _lineHeight;
  double get baseline => _baseline;
  double get spaceAdvance => _spaceAdvance;
  int get pageCount => _pages.length;
  int get glyphCount => _glyphs.length;
  int get pageBakeCount => _pageBakeCount;
  int get totalBakedGlyphs => _totalBakedGlyphs;

  /// Returns the GPU texture for [pageIndex].
  ui.Image pageImage(int pageIndex) => _pages[pageIndex].image!;

  /// Looks up or lazily bakes [rune], returning its immutable
  /// [DynamicGlyphEntry].
  DynamicGlyphEntry ensureGlyph(int rune) {
    final existing = _glyphs[rune];
    if (existing != null) {
      return existing;
    }
    ensureGlyphs(<int>[rune]);
    return _glyphs[rune]!;
  }

  /// Ensures every Unicode rune in [text] is baked into the atlas, batching all
  /// newly discovered runes onto page updates in a single pass.
  void ensureGlyphsForText(String text) {
    List<int>? missing;
    for (final rune in text.runes) {
      if (!_glyphs.containsKey(rune)) {
        missing ??= <int>[];
        missing.add(rune);
      }
    }
    if (missing != null) {
      ensureGlyphs(missing);
    }
  }

  /// Batch-bakes any unseen runes in [runes]. Previously baked runes keep their
  /// exact `(pageIndex, atlasRect)` untouched.
  void ensureGlyphs(Iterable<int> runes) {
    final uniqueMissing = <int>{};
    for (final r in runes) {
      if (!_glyphs.containsKey(r)) {
        uniqueMissing.add(r);
      }
    }
    if (uniqueMissing.isEmpty) {
      return;
    }

    final padLogical = outlineWidth * 0.6 + paddingLogical;
    final pendingByPage =
        <int, List<({int rune, String str, int pxX, int pxY, double padPx})>>{};

    for (final rune in uniqueMissing) {
      final s = String.fromCharCode(rune);
      _painter
        ..text = TextSpan(text: s, style: _fillStyle)
        ..layout();
      final w = _painter.width;
      final h = _painter.height;
      final glyphBase = _painter.computeDistanceToActualBaseline(
        TextBaseline.alphabetic,
      );

      final cellLogW = w + padLogical * 2.0;
      final cellLogH = h + padLogical * 2.0;
      final cellPxW = math.min(
        pageSizePx - 2,
        math.max(2, (cellLogW * pixelRatio).ceil()),
      );
      final cellPxH = math.min(
        pageSizePx - 2,
        math.max(2, (cellLogH * pixelRatio).ceil()),
      );

      final (pageIdx, allocX, allocY) = _allocateRect(cellPxW, cellPxH);
      final rect = ui.Rect.fromLTWH(
        allocX.toDouble(),
        allocY.toDouble(),
        cellPxW.toDouble(),
        cellPxH.toDouble(),
      );

      _glyphs[rune] = DynamicGlyphEntry(
        pageIndex: pageIdx,
        atlasRect: rect,
        advance: rune == 0x20 && w <= 0.0 ? _spaceAdvance : w,
        drawOffsetX: -padLogical,
        drawOffsetY: (_baseline - glyphBase) - padLogical,
        logicalWidth: cellPxW / pixelRatio,
        logicalHeight: cellPxH / pixelRatio,
      );
      _totalBakedGlyphs++;

      pendingByPage
          .putIfAbsent(
            pageIdx,
            () => <({int rune, String str, int pxX, int pxY, double padPx})>[],
          )
          .add((
            rune: rune,
            str: s,
            pxX: allocX,
            pxY: allocY,
            padPx: padLogical * pixelRatio,
          ));
    }

    pendingByPage.forEach((pageIdx, items) {
      final page = _pages[pageIdx];
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);

      if (page.image != null) {
        canvas.drawImage(page.image!, ui.Offset.zero, _copyPaint);
      }

      for (var i = 0; i < items.length; i++) {
        final it = items[i];
        canvas.save();
        canvas.translate(it.pxX + it.padPx, it.pxY + it.padPx);
        canvas.scale(pixelRatio, pixelRatio);

        if (_strokeStyle != null) {
          _painter
            ..text = TextSpan(text: it.str, style: _strokeStyle)
            ..layout()
            ..paint(canvas, ui.Offset.zero);
        }
        _painter
          ..text = TextSpan(text: it.str, style: _fillStyle)
          ..layout()
          ..paint(canvas, ui.Offset.zero);
        canvas.restore();
      }

      final picture = recorder.endRecording();
      final nextImg = picture.toImageSync(page.sizePx, page.sizePx);
      picture.dispose();
      page.image?.dispose();
      page.image = nextImg;
      _pageBakeCount++;
    });
  }

  (int pageIndex, int pxX, int pxY) _allocateRect(int wPx, int hPx) {
    const gap = 1;
    if (_pages.isEmpty) {
      _pages.add(_DynamicAtlasPage(pageSizePx));
    }

    var pageIdx = _pages.length - 1;
    var page = _pages[pageIdx];

    if (page.cursorX + wPx + gap > page.sizePx) {
      page.cursorX = 1;
      page.cursorY += page.shelfHeight + gap;
      page.shelfHeight = 0;
    }

    if (page.cursorY + hPx + gap > page.sizePx) {
      page = _DynamicAtlasPage(pageSizePx);
      _pages.add(page);
      pageIdx = _pages.length - 1;
    }

    final x = page.cursorX;
    final y = page.cursorY;
    page.cursorX += wPx + gap;
    if (hPx > page.shelfHeight) {
      page.shelfHeight = hPx;
    }
    return (pageIdx, x, y);
  }

  /// Renders single-line [text] at `(x, y)` using minimal per-page
  /// `Canvas.drawRawAtlas` calls (automatically baking any unseen runes).
  int drawText(
    ui.Canvas canvas,
    String text, {
    required double x,
    required double y,
    ui.Color color = const ui.Color(0xFFFFFFFF),
    double scale = 1.0,
    double letterSpacing = 0.0,
  }) {
    if (text.isEmpty) {
      return 0;
    }
    ensureGlyphsForText(text);

    final invScale = scale / pixelRatio;
    final txByPage = <int, List<double>>{};
    final rxByPage = <int, List<double>>{};
    final colByPage = <int, List<int>>{};
    final argb = color.toARGB32();

    var cursorX = x;
    for (final rune in text.runes) {
      if (rune == 0x20) {
        cursorX += (_spaceAdvance + letterSpacing) * scale;
        continue;
      }
      final g = _glyphs[rune]!;
      final tx = txByPage.putIfAbsent(g.pageIndex, () => <double>[]);
      final rx = rxByPage.putIfAbsent(g.pageIndex, () => <double>[]);
      final cl = colByPage.putIfAbsent(g.pageIndex, () => <int>[]);

      tx.addAll(<double>[
        invScale,
        0.0,
        cursorX + g.drawOffsetX * scale,
        y + g.drawOffsetY * scale,
      ]);
      rx.addAll(<double>[
        g.atlasRect.left,
        g.atlasRect.top,
        g.atlasRect.right,
        g.atlasRect.bottom,
      ]);
      cl.add(argb);
      cursorX += (g.advance + letterSpacing) * scale;
    }

    var draws = 0;
    txByPage.forEach((pIdx, txList) {
      canvas.drawRawAtlas(
        _pages[pIdx].image!,
        Float32List.fromList(txList),
        Float32List.fromList(rxByPage[pIdx]!),
        Int32List.fromList(colByPage[pIdx]!),
        ui.BlendMode.modulate,
        null,
        _batchPaint,
      );
      draws++;
    });
    return draws;
  }

  /// Disposes all GPU page images.
  void dispose() {
    for (var i = 0; i < _pages.length; i++) {
      _pages[i].dispose();
    }
    _pages.clear();
    _glyphs.clear();
  }
}
