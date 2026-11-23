part of 'msdf_text_batch_3d.dart';

/// Per-glyph atlas UV rectangle and typographic layout metrics (normalized to
/// `1.0` em line height).
class MsdfGlyphMetrics3D({
  required final int codeUnit,
  required final Rect uvRect,
  required final double advance,
  required final double bearingX,
  required final double bearingY,
  required final double width,
  required final double height,
});

/// Procedurally rasterized signed-distance glyph atlas of a built-in stroke
/// font (printable ASCII). The GPU texture holds a single distance value per
/// texel, in alpha; the three-channel distances stay on the CPU.
class MsdfFontAtlas3D._({
  required final int cellSize,
  required final int atlasWidth,
  required final int atlasHeight,
  required final double distanceRangePx,
  required final Texture texture,
  required final Uint8List msdfRgbBytes,
  required final Uint8List rgbaBytes,
  required final Map<int, MsdfGlyphMetrics3D> glyphs,
  required final Map<int, double> kerningPairs,
  required final MsdfGlyphMetrics3D fallbackGlyph,
}) {
  /// Generates the default printable ASCII (`0x20..0x7E`) + fallback symbol
  /// MSDF font atlas with [cellSize] pixels per glyph cell.
  factory MsdfFontAtlas3D.generateDefault({
    int cellSize = 32,
    double distanceRangePx = 4.0,
  }) {
    if (cellSize < 8) {
      throw ArgumentError.value(cellSize, 'cellSize', 'Must be >= 8');
    }
    const cols = 16;
    const rows =
        6; // 96 slots: 95 printable ASCII (32..126) + 1 fallback (127).
    final atlasW = cols * cellSize;
    final atlasH = rows * cellSize;
    final msdfRgb = Uint8List(atlasW * atlasH * 3);
    final rgba = Uint8List(atlasW * atlasH * 4);

    // Fill RGB with 255 in `rgba` so hardware tinting multiplies cleanly while
    // alpha carries the median signed-distance contour (`0.5` = glyph edge).
    for (var i = 0; i < atlasW * atlasH; i++) {
      final o4 = i * 4;
      rgba[o4] = 255;
      rgba[o4 + 1] = 255;
      rgba[o4 + 2] = 255;
      rgba[o4 + 3] = 0;
    }

    final glyphs = <int, MsdfGlyphMetrics3D>{};
    final invW = 1.0 / atlasW;
    final invH = 1.0 / atlasH;
    final padPx = math.min(2.0, cellSize * 0.125);
    final innerRatio = (cellSize - 2.0 * padPx) / cellSize;
    const strokeRadiusNorm = 0.078;
    final strokeRadiusPx = strokeRadiusNorm * (cellSize - 2.0 * padPx);
    final rangePx = math.max(1.0, distanceRangePx);

    MsdfGlyphMetrics3D buildSlot(int slotIndex, int codeUnit) {
      final col = slotIndex % cols;
      final row = slotIndex ~/ cols;
      final cellX = col * cellSize;
      final cellY = row * cellSize;

      final spec = _VectorGlyphTable.lookup(codeUnit);
      final segments = spec.segments;

      if (segments.isNotEmpty) {
        final segCount = segments.length ~/ 4;
        for (var py = 0; py < cellSize; py++) {
          // Normalized glyph coordinate `gy` in `[0..1]` (top=0, bottom=1).
          final gy = ((py + 0.5) - padPx) / (cellSize - 2.0 * padPx);
          for (var px = 0; px < cellSize; px++) {
            final gx = ((px + 0.5) - padPx) / (cellSize - 2.0 * padPx);

            var distR = double.infinity;
            var distG = double.infinity;
            var distB = double.infinity;
            var distAll = double.infinity;

            for (var s = 0; s < segCount; s++) {
              final b = s * 4;
              final dNorm = _pointToSegmentDistance(
                gx,
                gy,
                segments[b],
                segments[b + 1],
                segments[b + 2],
                segments[b + 3],
              );
              if (dNorm < distAll) {
                distAll = dNorm;
              }
              if (segCount == 1) {
                distR = dNorm;
                distG = dNorm;
                distB = dNorm;
              } else {
                // 3-color cyclic MSDF channel assignment (`RG`, `GB`, `RB`).
                final colorIdx = s % 3;
                if (colorIdx != 1 && dNorm < distR) {
                  distR = dNorm;
                }
                if (colorIdx != 2 && dNorm < distG) {
                  distG = dNorm;
                }
                if (colorIdx != 0 && dNorm < distB) {
                  distB = dNorm;
                }
              }
            }

            if (!distR.isFinite) {
              distR = distAll;
            }
            if (!distG.isFinite) {
              distG = distAll;
            }
            if (!distB.isFinite) {
              distB = distAll;
            }

            final scaleToPx = cellSize - 2.0 * padPx;
            final nR = (0.5 + (strokeRadiusPx - distR * scaleToPx) / rangePx)
                .clamp(0.0, 1.0);
            final nG = (0.5 + (strokeRadiusPx - distG * scaleToPx) / rangePx)
                .clamp(0.0, 1.0);
            final nB = (0.5 + (strokeRadiusPx - distB * scaleToPx) / rangePx)
                .clamp(0.0, 1.0);
            final nExact =
                (0.5 + (strokeRadiusPx - distAll * scaleToPx) / rangePx).clamp(
                  0.0,
                  1.0,
                );

            final texelIdx = (cellY + py) * atlasW + (cellX + px);
            final o3 = texelIdx * 3;
            msdfRgb[o3] = (nR * 255.0).round();
            msdfRgb[o3 + 1] = (nG * 255.0).round();
            msdfRgb[o3 + 2] = (nB * 255.0).round();

            // Combine multi-channel median with exact stroke contour so single
            // alpha-channel bilinear GPU sampling stays artifact-free at
            // stroke junctions while preserving sharp corners.
            final med = _median3(nR, nG, nB);
            final combined = math.max(med, nExact);
            rgba[texelIdx * 4 + 3] = (combined * 255.0).round();
          }
        }
      }

      final uvRect = Rect.fromLTWH(
        (cellX + padPx * 0.5) * invW,
        (cellY + padPx * 0.5) * invH,
        (cellSize - padPx) * invW,
        (cellSize - padPx) * invH,
      );

      return MsdfGlyphMetrics3D(
        codeUnit: codeUnit,
        uvRect: uvRect,
        advance: spec.advance,
        bearingX: 0.0,
        bearingY: 0.0,
        width: innerRatio > 0 ? spec.quadWidth : 0.75,
        height: 1.0,
      );
    }

    for (var code = 0x20; code <= 0x7E; code++) {
      glyphs[code] = buildSlot(code - 0x20, code);
    }
    final fallback = buildSlot(95, 0x7F);

    final tex = Texture(
      ByteData.sublistView(rgba),
      width: atlasW,
      height: atlasH,
      sampler: TextureSampler.linear,
    );

    return MsdfFontAtlas3D._(
      cellSize: cellSize,
      atlasWidth: atlasW,
      atlasHeight: atlasH,
      distanceRangePx: rangePx,
      texture: tex,
      msdfRgbBytes: msdfRgb,
      rgbaBytes: rgba,
      glyphs: Map<int, MsdfGlyphMetrics3D>.unmodifiable(glyphs),
      kerningPairs: _defaultKerningPairs,
      fallbackGlyph: fallback,
    );
  }

  late final List<MsdfGlyphMetrics3D> _asciiGlyphs =
      List<MsdfGlyphMetrics3D>.generate(
        95,
        (i) => glyphs[0x20 + i] ?? fallbackGlyph,
        growable: false,
      );
  late final Uint8List _hasKerningLeft = _buildKerningMask(kerningPairs);

  static Uint8List _buildKerningMask(Map<int, double> pairs) {
    final mask = Uint8List(128);
    for (final key in pairs.keys) {
      final left = key >> 16;
      if (left >= 0 && left < 128) {
        mask[left] = 1;
      }
    }
    return mask;
  }

  /// Resolves [MsdfGlyphMetrics3D] for [codeUnit] (falling back to
  /// [fallbackGlyph] for unknown symbols).
  MsdfGlyphMetrics3D metricsFor(int codeUnit) {
    if (codeUnit >= 0x20 && codeUnit <= 0x7E) {
      return _asciiGlyphs[codeUnit - 0x20];
    }
    return glyphs[codeUnit] ?? fallbackGlyph;
  }

  /// Returns horizontal kerning adjustment (in ems) between [leftCodeUnit] and
  /// [rightCodeUnit].
  double kerning(int leftCodeUnit, int rightCodeUnit) {
    if (leftCodeUnit >= 0 &&
        leftCodeUnit < 128 &&
        _hasKerningLeft[leftCodeUnit] == 0) {
      return 0.0;
    }
    return kerningPairs[(leftCodeUnit << 16) | (rightCodeUnit & 0xFFFF)] ?? 0.0;
  }

  /// Measures the layout width of a single line slice `text[start..end)` in
  /// world units at [fontSize].
  double measureLineRangeWidth(
    String text,
    int start,
    int end, {
    double fontSize = 1.0,
    double letterSpacing = 0.0,
  }) {
    if (start >= end) {
      return 0.0;
    }
    var emWidth = 0.0;
    var prev = -1;
    for (var i = start; i < end; i++) {
      final cu = text.codeUnitAt(i);
      if (cu == 0x0A) {
        break;
      }
      if (prev >= 0) {
        emWidth += kerning(prev, cu) + letterSpacing;
      }
      emWidth += metricsFor(cu).advance;
      prev = cu;
    }
    return emWidth * fontSize;
  }

  /// Measures the layout width of [text] in world units at [fontSize].
  double measureLineWidth(
    String text, {
    double fontSize = 1.0,
    double letterSpacing = 0.0,
  }) => measureLineRangeWidth(
    text,
    0,
    text.length,
    fontSize: fontSize,
    letterSpacing: letterSpacing,
  );

  /// Bilinearly samples the 3-channel MSDF median distance (`[0..1]`, `>= 0.5`
  /// inside a glyph stroke) at normalized atlas UV `(u, v)`.
  double sampleMedianDistance(double u, double v) {
    final fx = (u.clamp(0.0, 1.0) * atlasWidth - 0.5).clamp(
      0.0,
      atlasWidth - 1.0,
    );
    final fy = (v.clamp(0.0, 1.0) * atlasHeight - 0.5).clamp(
      0.0,
      atlasHeight - 1.0,
    );
    final x0 = fx.floor();
    final y0 = fy.floor();
    final x1 = math.min(atlasWidth - 1, x0 + 1);
    final y1 = math.min(atlasHeight - 1, y0 + 1);
    final tx = fx - x0;
    final ty = fy - y0;

    double chan(int x, int y, int c) =>
        msdfRgbBytes[(y * atlasWidth + x) * 3 + c] / 255.0;

    double bilerp(int c) {
      final top = chan(x0, y0, c) * (1.0 - tx) + chan(x1, y0, c) * tx;
      final bot = chan(x0, y1, c) * (1.0 - tx) + chan(x1, y1, c) * tx;
      return top * (1.0 - ty) + bot * ty;
    }

    return _median3(bilerp(0), bilerp(1), bilerp(2));
  }

  static double _median3(double a, double b, double c) =>
      math.max(math.min(a, b), math.min(math.max(a, b), c));

  static double _pointToSegmentDistance(
    double px,
    double py,
    double x0,
    double y0,
    double x1,
    double y1,
  ) {
    final dx = x1 - x0;
    final dy = y1 - y0;
    final len2 = dx * dx + dy * dy;
    if (len2 <= 1e-12) {
      final ex = px - x0;
      final ey = py - y0;
      return math.sqrt(ex * ex + ey * ey);
    }
    final t = (((px - x0) * dx + (py - y0) * dy) / len2).clamp(0.0, 1.0);
    final cx = x0 + dx * t;
    final cy = y0 + dy * t;
    final ex = px - cx;
    final ey = py - cy;
    return math.sqrt(ex * ex + ey * ey);
  }

  static final Map<int, double> _defaultKerningPairs = _buildDefaultKerning();

  static Map<int, double> _buildDefaultKerning() {
    int pair(String a, String b) =>
        (a.codeUnitAt(0) << 16) | (b.codeUnitAt(0) & 0xFFFF);
    return Map<int, double>.unmodifiable({
      pair('A', 'V'): -0.06,
      pair('V', 'A'): -0.06,
      pair('A', 'W'): -0.05,
      pair('W', 'A'): -0.05,
      pair('A', 'T'): -0.05,
      pair('T', 'A'): -0.05,
      pair('T', 'o'): -0.05,
      pair('T', 'a'): -0.05,
      pair('T', 'e'): -0.05,
      pair('L', 'T'): -0.05,
      pair('L', 'V'): -0.05,
      pair('F', '.'): -0.06,
      pair('P', '.'): -0.06,
    });
  }
}
