import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flutter/painting.dart';

/// Metrics for a single signed-distance-field glyph inside an [SdfFontAtlas].
class const SdfGlyphMetrics({
  required final ui.Rect atlasRect,
  required final double advance,
  required final double drawOffsetX,
  required final double drawOffsetY,
  required final double logicalWidth,
  required final double logicalHeight,
});

/// Visual styling parameters for [SdfTextComponent].
class const SdfTextStyle({
  final ui.Color color = const ui.Color(0xFFFFFFFF),
  final double fontScale = 1.0,
  final double letterSpacing = 0.0,
  final double lineHeightMultiplier = 1.15,
  final double outlineWidth = 0.0,
  final ui.Color outlineColor = const ui.Color(0xFF000000),
  final double glowRadius = 0.0,
  final ui.Color glowColor = const ui.Color(0x88FFFFFF),
  final ui.Offset shadowOffset = ui.Offset.zero,
  final ui.Color shadowColor = const ui.Color(0x00000000),
  final double shadowSoftness = 0.12,
  final double antiAliasSoftness = 0.06,
}) {
  SdfTextStyle copyWith({
    ui.Color? color,
    double? fontScale,
    double? letterSpacing,
    double? lineHeightMultiplier,
    double? outlineWidth,
    ui.Color? outlineColor,
    double? glowRadius,
    ui.Color? glowColor,
    ui.Offset? shadowOffset,
    ui.Color? shadowColor,
    double? shadowSoftness,
    double? antiAliasSoftness,
  }) {
    return SdfTextStyle(
      color: color ?? this.color,
      fontScale: fontScale ?? this.fontScale,
      letterSpacing: letterSpacing ?? this.letterSpacing,
      lineHeightMultiplier: lineHeightMultiplier ?? this.lineHeightMultiplier,
      outlineWidth: outlineWidth ?? this.outlineWidth,
      outlineColor: outlineColor ?? this.outlineColor,
      glowRadius: glowRadius ?? this.glowRadius,
      glowColor: glowColor ?? this.glowColor,
      shadowOffset: shadowOffset ?? this.shadowOffset,
      shadowColor: shadowColor ?? this.shadowColor,
      shadowSoftness: shadowSoftness ?? this.shadowSoftness,
      antiAliasSoftness: antiAliasSoftness ?? this.antiAliasSoftness,
    );
  }
}

/// Resolution-independent Signed Distance Field (SDF) font atlas baked via an
/// exact linear-time `O(W * H)` Felzenszwalb–Huttenlocher 2D Euclidean Distance
/// Transform.
///
/// Each texel in [image] encodes the normalized signed distance `d in [0..1]`
/// (`0.5` = exact glyph contour, `> 0.5` = inside glyph, `< 0.5` = outside
/// glyph) across `R = G = B = sdfByte` with `A = 255` so GPU bilinear texture
/// filtering reconstructs razor-sharp contours, outlines, glows, and shadows at
/// arbitrary camera zoom levels (`0.25x` to `32x`) without re-rasterizing
/// `Paragraph` layouts.
class SdfFontAtlas._(
  final Map<int, SdfGlyphMetrics> _glyphs, {
  required final ui.Image image,
  required final double bakeFontSize,
  required final double pixelRatio,
  required final double spreadPx,
  required final double lineHeight,
  required final double baseline,
  required final double spaceAdvance,
}) {
  static const String _asciiPartA = ' !"#\$%&\'()*+,-./0123456789:;<=>?@';
  static const String _asciiPartB = r'ABCDEFGHIJKLMNOPQRSTUVWXYZ[\]^_`';
  static const String _asciiPartC =
      'abcdefghijklmnopqrstuvwxyz{|}~×÷±€£¥₽₩★☆▲▼◆•—–…';

  /// Default printable ASCII + common game symbols.
  static const String defaultCharset = '$_asciiPartA$_asciiPartB$_asciiPartC';

  static const String _cyrUpper = 'АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ';
  static const String _cyrLower = 'абвгдеёжзийклмнопрстуфхцчшщъыьэюя';

  /// Cyrillic uppercase and lowercase alphabet.
  static const String cyrillicCharset = '$_cyrUpper$_cyrLower';

  /// Asynchronously rasterizes [charset] and computes an exact 2D Euclidean
  /// Signed Distance Field atlas stored in a single GPU [ui.Image].
  static Future<SdfFontAtlas> bake({
    required TextStyle style,
    String charset = defaultCharset,
    bool includeCyrillic = false,
    double pixelRatio = 2.0,
    double spreadPx = 8.0,
  }) async {
    assert(pixelRatio > 0, 'pixelRatio must be positive: $pixelRatio');
    assert(spreadPx >= 1.0, 'spreadPx must be >= 1.0: $spreadPx');

    final fullChars = includeCyrillic ? '$charset$cyrillicCharset' : charset;
    final uniqueRunes = <int>{...fullChars.runes, 0x20, 0x3F};

    final baseFontSize = style.fontSize ?? 32.0;
    final cleanStyle = TextStyle(
      fontFamily: style.fontFamily,
      fontFamilyFallback: style.fontFamilyFallback,
      fontSize: baseFontSize,
      fontWeight: style.fontWeight,
      fontStyle: style.fontStyle,
      letterSpacing: style.letterSpacing,
      height: style.height,
      color: const ui.Color(0xFFFFFFFF),
    );

    final padLogical = (spreadPx / pixelRatio) + 2.0;
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
            double baseline,
          })
        >[];

    var maxLineHeight = 0.0;
    var maxBaseline = 0.0;
    var spaceAdv = baseFontSize * 0.32;
    var totalAreaPx = 0;

    final painter = TextPainter(textDirection: TextDirection.ltr);
    for (final rune in uniqueRunes) {
      final s = String.fromCharCode(rune);
      painter
        ..text = TextSpan(text: s, style: cleanStyle)
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
      final cellLogW = w + padLogical * 2;
      final cellLogH = h + padLogical * 2;
      final pxW = math.max(4, (cellLogW * pixelRatio).ceil() + 2);
      final pxH = math.max(4, (cellLogH * pixelRatio).ceil() + 2);
      totalAreaPx += pxW * pxH;
      measured.add((
        rune: rune,
        charStr: s,
        advance: w,
        cellLogicalW: pxW / pixelRatio,
        cellLogicalH: pxH / pixelRatio,
        cellPxW: pxW,
        cellPxH: pxH,
        baseline: base,
      ));
    }

    var atlasWidthPx = 128;
    while (atlasWidthPx < 2048 &&
        atlasWidthPx * atlasWidthPx < totalAreaPx * 1.45) {
      atlasWidthPx *= 2;
    }
    for (final m in measured) {
      if (m.cellPxW + 4 > atlasWidthPx) {
        atlasWidthPx = m.cellPxW + 4;
      }
    }

    final placements = <({int index, int pxX, int pxY})>[];
    var cursorX = 2;
    var cursorY = 2;
    var rowHeight = 0;
    for (var i = 0; i < measured.length; i++) {
      final m = measured[i];
      if (cursorX + m.cellPxW + 2 > atlasWidthPx) {
        cursorX = 2;
        cursorY += rowHeight + 2;
        rowHeight = 0;
      }
      placements.add((index: i, pxX: cursorX, pxY: cursorY));
      cursorX += m.cellPxW + 2;
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

    final glyphMap = <int, SdfGlyphMetrics>{};
    for (final p in placements) {
      final m = measured[p.index];
      final logX = p.pxX / pixelRatio;
      final logY = p.pxY / pixelRatio;
      final drawPos = ui.Offset(logX + padLogical, logY + padLogical);
      if (m.rune != 0x20) {
        painter
          ..text = TextSpan(text: m.charStr, style: cleanStyle)
          ..layout()
          ..paint(canvas, drawPos);
      }
      glyphMap[m.rune] = SdfGlyphMetrics(
        atlasRect: ui.Rect.fromLTWH(
          p.pxX.toDouble(),
          p.pxY.toDouble(),
          m.cellPxW.toDouble(),
          m.cellPxH.toDouble(),
        ),
        advance: m.advance,
        drawOffsetX: -padLogical,
        drawOffsetY: -padLogical,
        logicalWidth: m.cellLogicalW,
        logicalHeight: m.cellLogicalH,
      );
    }
    painter.dispose();

    final picture = recorder.endRecording();
    final maskImage = picture.toImageSync(atlasWidthPx, atlasHeightPx);
    picture.dispose();

    final byteData = await maskImage.toByteData();
    maskImage.dispose();

    final rgbaOut = Uint8List(atlasWidthPx * atlasHeightPx * 4);
    // Initialize atlas background to SDF = 0 (outside), A = 255.
    for (var i = 3; i < rgbaOut.length; i += 4) {
      rgbaOut[i] = 255;
    }

    if (byteData != null) {
      final srcRgba = byteData.buffer.asUint8List();
      // Compute exact per-cell 2D EDT so neighboring glyphs in the atlas never
      // influence each other's distance fields.
      for (final p in placements) {
        final m = measured[p.index];
        if (m.rune == 0x20) {
          continue;
        }
        final cw = m.cellPxW;
        final ch = m.cellPxH;
        final cellAlpha = Uint8List(cw * ch);
        for (var y = 0; y < ch; y++) {
          final srcRow = ((p.pxY + y) * atlasWidthPx + p.pxX) * 4;
          final dstRow = y * cw;
          for (var x = 0; x < cw; x++) {
            cellAlpha[dstRow + x] = srcRgba[srcRow + x * 4 + 3];
          }
        }
        final cellSdf = computeSignedDistanceField(
          cellAlpha,
          cw,
          ch,
          spreadPx: spreadPx,
        );
        for (var y = 0; y < ch; y++) {
          final dstRow = ((p.pxY + y) * atlasWidthPx + p.pxX) * 4;
          final sdfRow = y * cw;
          for (var x = 0; x < cw; x++) {
            final d = cellSdf[sdfRow + x];
            final idx = dstRow + x * 4;
            rgbaOut[idx] = d;
            rgbaOut[idx + 1] = d;
            rgbaOut[idx + 2] = d;
            rgbaOut[idx + 3] = 255;
          }
        }
      }
    }

    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      rgbaOut,
      atlasWidthPx,
      atlasHeightPx,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    final sdfImage = await completer.future;

    return SdfFontAtlas._(
      glyphMap,
      image: sdfImage,
      bakeFontSize: baseFontSize,
      pixelRatio: pixelRatio,
      spreadPx: spreadPx,
      lineHeight: maxLineHeight > 0 ? maxLineHeight : baseFontSize,
      baseline: maxBaseline,
      spaceAdvance: spaceAdv,
    );
  }

  /// Computes an 8-bit normalized Signed Distance Field (`0..255`, where `128`
  /// corresponds to distance `0.0` on the contour, `> 128` is inside, and
  /// `< 128` is outside) from an 8-bit coverage mask [alphaMask] of dimensions
  /// `[width] x [height]` in exact `O(width * height)` time via the separable
  /// Felzenszwalb–Huttenlocher 2D Euclidean Distance Transform.
  static Uint8List computeSignedDistanceField(
    Uint8List alphaMask,
    int width,
    int height, {
    double spreadPx = 8.0,
  }) {
    final total = width * height;
    assert(alphaMask.length >= total, 'alphaMask is smaller than width*height');
    final out = Uint8List(total);
    if (total == 0) {
      return out;
    }

    const inf = 1e20;
    final outsideGrid = Float64List(total);
    final insideGrid = Float64List(total);

    var anyInside = false;
    var anyOutside = false;
    for (var i = 0; i < total; i++) {
      final a = alphaMask[i];
      if (a >= 128) {
        anyInside = true;
        outsideGrid[i] = 0.0;
        insideGrid[i] = inf;
      } else {
        anyOutside = true;
        outsideGrid[i] = inf;
        insideGrid[i] = 0.0;
      }
    }

    if (!anyInside) {
      return out; // All 0.
    }
    if (!anyOutside) {
      out.fillRange(0, total, 255);
      return out;
    }

    final maxDim = math.max(width, height);
    final f = Float64List(maxDim);
    final d = Float64List(maxDim);
    final v = Int32List(maxDim);
    final z = Float64List(maxDim + 1);

    _edt2d(outsideGrid, width, height, f, d, v, z);
    _edt2d(insideGrid, width, height, f, d, v, z);

    final invTwoSpread = 1.0 / (2.0 * math.max(1e-6, spreadPx));
    for (var i = 0; i < total; i++) {
      final a = alphaMask[i];
      final double signedPx;
      if (a > 0 && a < 255) {
        signedPx = (a / 255.0) - 0.5;
      } else if (a >= 128) {
        signedPx = math.sqrt(insideGrid[i]) - 0.5;
      } else {
        signedPx = -(math.sqrt(outsideGrid[i]) - 0.5);
      }
      final normalized = (0.5 + signedPx * invTwoSpread).clamp(0.0, 1.0);
      out[i] = (normalized * 255.0 + 0.5).floor().clamp(0, 255);
    }
    return out;
  }

  static void _edt2d(
    Float64List grid,
    int width,
    int height,
    Float64List f,
    Float64List d,
    Int32List v,
    Float64List z,
  ) {
    // 1D squared EDT along rows.
    for (var y = 0; y < height; y++) {
      final rowOffset = y * width;
      for (var x = 0; x < width; x++) {
        f[x] = grid[rowOffset + x];
      }
      _edt1d(f, d, v, z, width);
      for (var x = 0; x < width; x++) {
        grid[rowOffset + x] = d[x];
      }
    }

    // 1D squared EDT along columns.
    for (var x = 0; x < width; x++) {
      for (var y = 0; y < height; y++) {
        f[y] = grid[y * width + x];
      }
      _edt1d(f, d, v, z, height);
      for (var y = 0; y < height; y++) {
        grid[y * width + x] = d[y];
      }
    }
  }

  static void _edt1d(
    Float64List f,
    Float64List d,
    Int32List v,
    Float64List z,
    int n,
  ) {
    if (n == 0) {
      return;
    }
    v[0] = 0;
    z[0] = -double.infinity;
    z[1] = double.infinity;
    var k = 0;

    for (var q = 1; q < n; q++) {
      final fq = f[q] + q * q;
      var s = _parabolaIntersection(f, q, fq, v[k]);
      while (s <= z[k]) {
        k--;
        s = _parabolaIntersection(f, q, fq, v[k]);
      }
      k++;
      v[k] = q;
      z[k] = s;
      z[k + 1] = double.infinity;
    }

    k = 0;
    for (var q = 0; q < n; q++) {
      while (z[k + 1] < q) {
        k++;
      }
      final vk = v[k];
      final dx = q - vk;
      d[q] = dx * dx + f[vk];
    }
  }

  @pragma('vm:prefer-inline')
  static double _parabolaIntersection(
    Float64List f,
    int q,
    double fqPlusQ2,
    int vk,
  ) {
    return (fqPlusQ2 - (f[vk] + vk * vk)) / (2.0 * (q - vk));
  }

  bool _disposed = false;

  /// Whether [dispose] has been called on this atlas.
  bool get isDisposed => _disposed;

  /// Number of distinct Unicode runes baked into this atlas.
  int get glyphCount => _glyphs.length;

  /// Looks up metrics for [rune], falling back to `'?'` (`0x3F`) if absent.
  SdfGlyphMetrics? metricsForRune(int rune) => _glyphs[rune] ?? _glyphs[0x3F];

  /// Measures the logical single-line width of [text] at [fontScale].
  double measureLineWidth(
    String text, {
    double fontScale = 1.0,
    double letterSpacing = 0.0,
  }) {
    if (text.isEmpty || fontScale <= 0.0) {
      return 0.0;
    }
    var width = 0.0;
    var count = 0;
    for (final rune in text.runes) {
      if (rune == 0x0A) {
        break;
      }
      if (rune == 0x20) {
        width += spaceAdvance * fontScale;
      } else {
        final m = metricsForRune(rune);
        width += (m?.advance ?? spaceAdvance) * fontScale;
      }
      count++;
    }
    if (count > 1 && letterSpacing != 0.0) {
      width += (count - 1) * letterSpacing * fontScale;
    }
    return width;
  }

  /// Builds a GPU-evaluated `ColorFilter` that thresholds this SDF texture at
  /// normalized distance [edge] (`0.5` = glyph contour, `< 0.5` = dilated
  /// outline/glow) with smooth anti-aliasing ramp [softness] and output tint
  /// [color].
  static ui.ColorFilter buildSdfColorFilter(
    ui.Color color, {
    double edge = 0.5,
    double softness = 0.06,
  }) {
    final w = softness.clamp(0.005, 0.45);
    final low = math.max(0.02, edge - w);
    final high = math.min(0.99, low + 2.0 * w);
    final span = math.max(0.005, high - low);
    final slope = 1.0 / span;
    final bias = -low * slope * 255.0;

    final r255 = color.r * 255.0;
    final g255 = color.g * 255.0;
    final b255 = color.b * 255.0;

    return ui.ColorFilter.matrix(<double>[
      0, 0, 0, 0, r255, // R' = color.r
      0, 0, 0, 0, g255, // G' = color.g
      0, 0, 0, 0, b255, // B' = color.b
      slope, 0, 0, 0, bias, // A' = clamp((R_sdf - low) / span, 0, 1)
    ]);
  }

  /// Disposes the underlying GPU [image].
  void dispose() {
    if (!_disposed) {
      _disposed = true;
      image.dispose();
    }
  }
}

/// Resolution-independent SDF text component that renders multiline text with
/// crisp anti-aliased contours, outlines, glows, and drop shadows at arbitrary
/// camera zoom levels using `Canvas.drawRawAtlas` and GPU SDF thresholding (or
/// an optional custom [customShader]).
class SdfTextComponent({
  required SdfFontAtlas atlas,
  String text = '',
  SdfTextStyle style = const SdfTextStyle(),
  TextAlign textAlign = TextAlign.left,
  bool autoResize = true,
  ui.FragmentShader? customShader,
  super.position,
  super.size,
  super.scale,
  super.angle,
  super.anchor,
  super.children,
  super.priority,
  super.key,
}) extends PositionComponent with HasVisibility {
  SdfFontAtlas _atlas = atlas;
  String _text = text;
  SdfTextStyle _style = style;
  TextAlign _textAlign = textAlign;
  bool _autoResize = autoResize;
  ui.FragmentShader? _customShader = customShader;

  Float32List _transforms = Float32List(64);
  Float32List _shadowTransforms = Float32List(64);
  Float32List _rects = Float32List(64);
  int _glyphCount = 0;
  bool _layoutDirty = true;

  final ui.Paint _fillPaint = ui.Paint()..filterQuality = ui.FilterQuality.low;
  final ui.Paint _outlinePaint = ui.Paint()
    ..filterQuality = ui.FilterQuality.low;
  final ui.Paint _glowPaint = ui.Paint()..filterQuality = ui.FilterQuality.low;
  final ui.Paint _shadowPaint = ui.Paint()
    ..filterQuality = ui.FilterQuality.low;

  int _lastDrawCalls = 0;

  this {
    _rebuildLayoutIfNeeded();
  }

  /// Number of `Canvas` draw calls issued during the most recent [render].
  int get lastDrawCalls => _lastDrawCalls;

  SdfFontAtlas get atlas => _atlas;
  set atlas(SdfFontAtlas value) {
    if (!identical(_atlas, value)) {
      _atlas = value;
      _markLayoutAndVisualDirty();
    }
  }

  String get text => _text;
  set text(String value) {
    if (_text != value) {
      _text = value;
      _markLayoutAndVisualDirty();
    }
  }

  SdfTextStyle get style => _style;
  set style(SdfTextStyle value) {
    if (_style != value) {
      _style = value;
      _markLayoutAndVisualDirty();
    }
  }

  TextAlign get textAlign => _textAlign;
  set textAlign(TextAlign value) {
    if (_textAlign != value) {
      _textAlign = value;
      _markLayoutAndVisualDirty();
    }
  }

  bool get autoResize => _autoResize;
  set autoResize(bool value) {
    if (_autoResize != value) {
      _autoResize = value;
      _markLayoutAndVisualDirty();
    }
  }

  ui.FragmentShader? get customShader => _customShader;
  set customShader(ui.FragmentShader? value) {
    if (!identical(_customShader, value)) {
      _customShader = value;
      markSubtreeDirty();
      Game.notifyVisualMutation();
    }
  }

  void _markLayoutAndVisualDirty() {
    _layoutDirty = true;
    _rebuildLayoutIfNeeded();
    markSubtreeDirty();
    Game.notifyVisualMutation();
  }

  void _ensureCapacity(int needed) {
    if (_rects.length >= needed * 4) {
      return;
    }
    var cap = _rects.length ~/ 4;
    if (cap < 16) {
      cap = 16;
    }
    while (cap < needed) {
      cap *= 2;
    }
    _transforms = Float32List(cap * 4);
    _shadowTransforms = Float32List(cap * 4);
    _rects = Float32List(cap * 4);
  }

  void _rebuildLayoutIfNeeded() {
    if (!_layoutDirty) {
      return;
    }
    _layoutDirty = false;
    _glyphCount = 0;

    if (_text.isEmpty || _style.fontScale <= 0.0 || _atlas.isDisposed) {
      if (_autoResize) {
        size.setZero();
      }
      return;
    }

    final lines = _text.split('\n');
    final fontScale = _style.fontScale;
    final letterSpacing = _style.letterSpacing;
    final lineStep =
        _atlas.lineHeight * fontScale * _style.lineHeightMultiplier;
    final lineWidths = Float64List(lines.length);
    var maxWidth = 0.0;
    var totalRunes = 0;

    for (var i = 0; i < lines.length; i++) {
      final lw = _atlas.measureLineWidth(
        lines[i],
        fontScale: fontScale,
        letterSpacing: letterSpacing,
      );
      lineWidths[i] = lw;
      if (lw > maxWidth) {
        maxWidth = lw;
      }
      totalRunes += lines[i].length;
    }

    final totalHeight = lines.length == 1
        ? _atlas.lineHeight * fontScale
        : (lines.length - 1) * lineStep + _atlas.lineHeight * fontScale;

    if (_autoResize) {
      size.setValues(maxWidth, totalHeight);
    }

    final containerWidth = _autoResize ? maxWidth : size.x;
    _ensureCapacity(math.max(1, totalRunes));

    final effScale = fontScale / _atlas.pixelRatio;
    final sx = _style.shadowOffset.dx;
    final sy = _style.shadowOffset.dy;

    for (var lineIdx = 0; lineIdx < lines.length; lineIdx++) {
      final line = lines[lineIdx];
      final lw = lineWidths[lineIdx];
      final startX = switch (_textAlign) {
        TextAlign.center => (containerWidth - lw) * 0.5,
        TextAlign.right || TextAlign.end => containerWidth - lw,
        _ => 0.0,
      };
      final startY = lineIdx * lineStep;

      var penX = startX;
      for (final rune in line.runes) {
        if (rune == 0x20) {
          penX += (_atlas.spaceAdvance + letterSpacing) * fontScale;
          continue;
        }
        final m = _atlas.metricsForRune(rune);
        if (m == null) {
          penX += (_atlas.spaceAdvance + letterSpacing) * fontScale;
          continue;
        }
        final slot = _glyphCount++;
        _ensureCapacity(_glyphCount);
        final t4 = slot * 4;
        final tx = penX + m.drawOffsetX * fontScale;
        final ty = startY + m.drawOffsetY * fontScale;

        _transforms[t4] = effScale;
        _transforms[t4 + 1] = 0.0;
        _transforms[t4 + 2] = tx;
        _transforms[t4 + 3] = ty;

        _shadowTransforms[t4] = effScale;
        _shadowTransforms[t4 + 1] = 0.0;
        _shadowTransforms[t4 + 2] = tx + sx;
        _shadowTransforms[t4 + 3] = ty + sy;

        final r = m.atlasRect;
        _rects[t4] = r.left;
        _rects[t4 + 1] = r.top;
        _rects[t4 + 2] = r.right;
        _rects[t4 + 3] = r.bottom;

        penX += (m.advance + letterSpacing) * fontScale;
      }
    }
  }

  @override
  void onLoad() {
    super.onLoad();
    _rebuildLayoutIfNeeded();
  }

  @override
  void render(ui.Canvas canvas) {
    _lastDrawCalls = 0;
    if (!isVisible || _atlas.isDisposed) {
      return;
    }
    _rebuildLayoutIfNeeded();
    if (_glyphCount == 0) {
      return;
    }

    final shader = _customShader;
    if (shader != null) {
      shader
        ..setImageSampler(0, _atlas.image)
        ..setFloat(0, _style.color.r)
        ..setFloat(1, _style.color.g)
        ..setFloat(2, _style.color.b)
        ..setFloat(3, _style.color.a);
      _fillPaint
        ..colorFilter = null
        ..shader = shader;
      canvas.drawRect(
        ui.Rect.fromLTWH(0, 0, size.x, size.y),
        _fillPaint,
      );
      _fillPaint.shader = null;
      _lastDrawCalls = 1;
      return;
    }

    // Estimate canvas zoom/scale from CTM so the anti-aliasing ramp stays ~1
    // screen pixel crisp across arbitrary camera zoom levels!
    final ctm = canvas.getTransform();
    final ctmScale = math.sqrt(ctm[0] * ctm[0] + ctm[1] * ctm[1]);
    final texelToScreen = math.max(
      0.05,
      ctmScale * (_style.fontScale / _atlas.pixelRatio),
    );
    final autoAa = (0.65 / (texelToScreen * 2.0 * _atlas.spreadPx)).clamp(
      0.015,
      0.22,
    );
    final aa = math.max(_style.antiAliasSoftness * 0.5, autoAa);

    final transformsView = Float32List.sublistView(
      _transforms,
      0,
      _glyphCount * 4,
    );
    final rectsView = Float32List.sublistView(_rects, 0, _glyphCount * 4);

    // 1. Optional drop shadow pass.
    if (_style.shadowColor.a > 0.001) {
      final shadowTransformsView = Float32List.sublistView(
        _shadowTransforms,
        0,
        _glyphCount * 4,
      );
      _shadowPaint
        ..color = ui.Color.fromRGBO(
          255,
          255,
          255,
          _style.shadowColor.a.clamp(0.0, 1.0),
        )
        ..colorFilter = SdfFontAtlas.buildSdfColorFilter(
          _style.shadowColor,
          softness: math.max(aa, _style.shadowSoftness),
        );
      canvas.drawRawAtlas(
        _atlas.image,
        shadowTransformsView,
        rectsView,
        null,
        null,
        null,
        _shadowPaint,
      );
      _lastDrawCalls++;
    }

    // 2. Optional outer glow pass.
    if (_style.glowRadius > 0.0 && _style.glowColor.a > 0.001) {
      final glowNorm =
          (_style.glowRadius * _atlas.pixelRatio / (2.0 * _atlas.spreadPx))
              .clamp(0.02, 0.42);
      _glowPaint
        ..color = ui.Color.fromRGBO(
          255,
          255,
          255,
          _style.glowColor.a.clamp(0.0, 1.0),
        )
        ..colorFilter = SdfFontAtlas.buildSdfColorFilter(
          _style.glowColor,
          edge: (0.5 - glowNorm * 0.5).clamp(0.08, 0.49),
          softness: glowNorm,
        );
      canvas.drawRawAtlas(
        _atlas.image,
        transformsView,
        rectsView,
        null,
        null,
        null,
        _glowPaint,
      );
      _lastDrawCalls++;
    }

    // 3. Optional crisp outline pass.
    if (_style.outlineWidth > 0.0 && _style.outlineColor.a > 0.001) {
      final outlineNorm =
          (_style.outlineWidth * _atlas.pixelRatio / (2.0 * _atlas.spreadPx))
              .clamp(0.01, 0.42);
      _outlinePaint
        ..color = ui.Color.fromRGBO(
          255,
          255,
          255,
          _style.outlineColor.a.clamp(0.0, 1.0),
        )
        ..colorFilter = SdfFontAtlas.buildSdfColorFilter(
          _style.outlineColor,
          edge: (0.5 - outlineNorm).clamp(0.05, 0.49),
          softness: aa,
        );
      canvas.drawRawAtlas(
        _atlas.image,
        transformsView,
        rectsView,
        null,
        null,
        null,
        _outlinePaint,
      );
      _lastDrawCalls++;
    }

    // 4. Crisp main glyph fill pass.
    if (_style.color.a > 0.001) {
      _fillPaint
        ..color = ui.Color.fromRGBO(
          255,
          255,
          255,
          _style.color.a.clamp(0.0, 1.0),
        )
        ..colorFilter = SdfFontAtlas.buildSdfColorFilter(
          _style.color,
          softness: aa,
        );
      canvas.drawRawAtlas(
        _atlas.image,
        transformsView,
        rectsView,
        null,
        null,
        null,
        _fillPaint,
      );
      _lastDrawCalls++;
    }
  }
}
