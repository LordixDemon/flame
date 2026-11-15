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

    // Measure canonical line height & space advance from 'Mg' and ' ':
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
    // Group pending draws by target page index so each modified page only calls
    // `toImageSync` once!
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

/// CLDR-aligned grammatical plural categories.
enum PluralCategory() {
  zero,
  one,
  two,
  few,
  many,
  other,
}

/// Function mapping an integer quantity `n` (`>= 0`) to a [PluralCategory].
typedef PluralRuleResolver = PluralCategory Function(int n);

/// Multi-locale string table with built-in CLDR pluralization (including full
/// Slavic `ru`/`uk`/`pl` `one/few/many` rules), gender agreement tags,
/// parameter interpolation, fallback locale resolution, and live hot-swap
/// version tracking.
///
/// Supported inline directives:
/// - `{name}` -> parameter value
/// - `{plural:count|one=# монета|few=# монеты|many=# монет|other=# монеты}`
/// - `{gender:heroSex|m=Готов|f=Готова|other=Готово}`
class LocalizationTable({
  String initialLocale = 'en',
  this.fallbackLocale = 'en',
}) {
  String _locale = initialLocale;
  final String fallbackLocale;

  final Map<String, Map<String, String>> _bundles =
      <String, Map<String, String>>{};
  final Map<String, PluralRuleResolver> _pluralResolvers =
      <String, PluralRuleResolver>{};
  final Set<void Function()> _listeners = <void Function()>{};
  int _version = 0;

  String get locale => _locale;
  int get version => _version;

  set locale(String next) {
    if (_locale != next) {
      _locale = next;
      _version++;
      final copy = List<void Function()>.of(_listeners, growable: false);
      for (var i = 0; i < copy.length; i++) {
        copy[i]();
      }
    }
  }

  void addListener(void Function() listener) => _listeners.add(listener);
  void removeListener(void Function() listener) => _listeners.remove(listener);

  /// Registers or merges key-value translations for [localeCode].
  void registerTranslations(String localeCode, Map<String, String> entries) {
    final target = _bundles.putIfAbsent(localeCode, () => <String, String>{});
    target.addAll(entries);
    _version++;
  }

  /// Registers a custom [PluralRuleResolver] for [languagePrefix] (e.g.
  /// `'ar'`).
  void registerPluralResolver(
    String languagePrefix,
    PluralRuleResolver resolver,
  ) {
    _pluralResolvers[languagePrefix.toLowerCase()] = resolver;
  }

  /// Resolves the [PluralCategory] for integer [count] under [localeCode].
  PluralCategory resolvePluralCategory(int count, [String? localeCode]) {
    final n = count.abs();
    final lang = (localeCode ?? _locale)
        .split(RegExp('[-_]'))
        .first
        .toLowerCase();

    final custom = _pluralResolvers[lang];
    if (custom != null) {
      return custom(n);
    }

    switch (lang) {
      case 'ru':
      case 'uk':
      case 'be':
      case 'sr':
      case 'hr':
        final mod10 = n % 10;
        final mod100 = n % 100;
        if (mod10 == 1 && mod100 != 11) {
          return PluralCategory.one;
        }
        if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) {
          return PluralCategory.few;
        }
        return PluralCategory.many;
      case 'pl':
        if (n == 1) {
          return PluralCategory.one;
        }
        final mod10 = n % 10;
        final mod100 = n % 100;
        if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) {
          return PluralCategory.few;
        }
        return PluralCategory.many;
      case 'fr':
        return (n == 0 || n == 1) ? PluralCategory.one : PluralCategory.other;
      case 'ja':
      case 'zh':
      case 'ko':
        return PluralCategory.other;
      default:
        return n == 1 ? PluralCategory.one : PluralCategory.other;
    }
  }

  /// Formats translation [key] using [params] under the active [locale]
  /// (falling back to [fallbackLocale], or returning `key` if missing).
  String tr(
    String key, [
    Map<String, Object?> params = const <String, Object?>{},
  ]) {
    final template =
        _bundles[_locale]?[key] ?? _bundles[fallbackLocale]?[key] ?? key;
    return formatTemplate(template, params, localeCode: _locale);
  }

  /// Formats an arbitrary template string against [params].
  String formatTemplate(
    String template,
    Map<String, Object?> params, {
    String? localeCode,
  }) {
    if (!template.contains('{')) {
      return template;
    }

    final sb = StringBuffer();
    var i = 0;
    while (i < template.length) {
      final open = template.indexOf('{', i);
      if (open < 0) {
        sb.write(template.substring(i));
        break;
      }
      sb.write(template.substring(i, open));
      final close = template.indexOf('}', open + 1);
      if (close < 0) {
        sb.write(template.substring(open));
        break;
      }

      final expr = template.substring(open + 1, close);
      if (expr.startsWith('plural:')) {
        sb.write(_evalPlural(expr.substring(7), params, localeCode));
      } else if (expr.startsWith('gender:')) {
        sb.write(_evalGender(expr.substring(7), params));
      } else {
        final v = params[expr];
        sb.write(v?.toString() ?? '{$expr}');
      }
      i = close + 1;
    }
    return sb.toString();
  }

  String _evalPlural(
    String body,
    Map<String, Object?> params,
    String? localeCode,
  ) {
    final parts = body.split('|');
    if (parts.isEmpty) {
      return '';
    }
    final varName = parts[0].trim();
    final rawVal = params[varName];
    final count = rawVal is num
        ? rawVal.round()
        : (int.tryParse(rawVal?.toString() ?? '') ?? 0);
    final cat = resolvePluralCategory(count, localeCode);

    String? matched;
    String? otherFallback;
    for (var i = 1; i < parts.length; i++) {
      final eq = parts[i].indexOf('=');
      if (eq <= 0) {
        continue;
      }
      final k = parts[i].substring(0, eq).trim();
      final v = parts[i].substring(eq + 1);
      if (k == cat.name) {
        matched = v;
        break;
      }
      if (k == 'other') {
        otherFallback = v;
      }
    }
    final chosen = matched ?? otherFallback ?? '';
    return chosen.replaceAll('#', count.toString());
  }

  String _evalGender(String body, Map<String, Object?> params) {
    final parts = body.split('|');
    if (parts.isEmpty) {
      return '';
    }
    final varName = parts[0].trim();
    final genderVal = (params[varName]?.toString() ?? 'other').toLowerCase();

    String? matched;
    String? otherFallback;
    for (var i = 1; i < parts.length; i++) {
      final eq = parts[i].indexOf('=');
      if (eq <= 0) {
        continue;
      }
      final k = parts[i].substring(0, eq).trim().toLowerCase();
      final v = parts[i].substring(eq + 1);
      if (k == genderVal) {
        matched = v;
        break;
      }
      if (k == 'other') {
        otherFallback = v;
      }
    }
    return matched ?? otherFallback ?? '';
  }
}
