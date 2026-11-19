import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Color, Rect;

import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';

/// Camera-alignment mode for 3D text strings in an [MsdfTextBatch3D].
enum TextBillboardMode3D() {
  /// Faces the camera plane on both axes.
  spherical,

  /// Rotates horizontally around world `+Y` to face the camera while staying
  /// upright.
  cylindrical,

  /// Fixed 3D world orientation controlled by an explicit `Quaternion`.
  fixed,
}

/// Horizontal line alignment for 3D text strings in an [MsdfTextBatch3D].
enum TextAlign3D() {
  /// Left-aligned starting at `position`.
  left,

  /// Horizontally centered around `position`.
  center,

  /// Right-aligned ending at `position`.
  right,
}

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

/// Procedurally rasterized multi-channel signed-distance glyph atlas for crisp,
/// resolution-independent 3D text rendering.
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

  /// Resolves [MsdfGlyphMetrics3D] for [codeUnit] (falling back to
  /// [fallbackGlyph] for unknown symbols).
  MsdfGlyphMetrics3D metricsFor(int codeUnit) =>
      glyphs[codeUnit] ?? fallbackGlyph;

  /// Returns horizontal kerning adjustment (in ems) between [leftCodeUnit] and
  /// [rightCodeUnit].
  double kerning(int leftCodeUnit, int rightCodeUnit) =>
      kerningPairs[(leftCodeUnit << 16) | (rightCodeUnit & 0xFFFF)] ?? 0.0;

  /// Measures the layout width of [text] in world units at [fontSize].
  double measureLineWidth(
    String text, {
    double fontSize = 1.0,
    double letterSpacing = 0.0,
  }) {
    if (text.isEmpty) {
      return 0.0;
    }
    var emWidth = 0.0;
    int? prev;
    for (var i = 0; i < text.length; i++) {
      final cu = text.codeUnitAt(i);
      if (cu == 0x0A) {
        break;
      }
      if (prev != null) {
        emWidth += kerning(prev, cu) + letterSpacing;
      }
      emWidth += metricsFor(cu).advance;
      prev = cu;
    }
    return emWidth * fontSize;
  }

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

class _TextEntry3D({
  required final String text,
  required final Vector3 position,
  required final double fontSize,
  required final Color color,
  required final TextBillboardMode3D mode,
  required final Quaternion? rotation,
  required final TextAlign3D align,
  required final double letterSpacing,
  required final double lineHeight,
});

/// Batched 3D world-space text renderer with a signed-distance glyph atlas.
///
/// Packs hundreds of world-space strings, camera-facing
/// ([TextBillboardMode3D.spherical], [TextBillboardMode3D.cylindrical]) and
/// fixed ([TextBillboardMode3D.fixed] plaques) alike, into **1 instanced
/// [BillboardBatch3D] draw call** per pass, with `alphaCutoff`
/// signed-distance edges and hardware depth occlusion. The text is unlit: it
/// keeps its color whatever the lights.
///
/// Batches without an [atlas] share one atlas made by
/// [MsdfFontAtlas3D.generateDefault]. The atlas holds printable ASCII only;
/// other characters draw its fallback glyph.
class MsdfTextBatch3D({
  MsdfFontAtlas3D? atlas,

  /// The distance below which atlas texels are discarded (`0.5` is the
  /// glyph edge). Values below `1 / 255` are drawn as `1 / 255`: glyph quads
  /// are opaque, so without a cutoff they would draw as solid boxes.
  var double alphaCutoff = 0.5,
  int initialCapacity = 128,
  super.position,
  super.rotation,
  super.scale,
  super.children,
  super.cameraMask,
}) extends Object3D {
  this : super(castsShadows: false) {
    _billboardMaterial = BillboardMaterial3D(
      albedoTexture: this.atlas.texture,
      alphaCutoff: alphaCutoff,
      shadeWeight: 0.0,
      // The atlas is white with the distance in alpha: straight alpha.
      premultipliedTexture: false,
    );
    _billboardBatch = BillboardBatch3D(
      material: _billboardMaterial,
      initialCapacity: math.max(16, initialCapacity),
    );
  }

  static MsdfFontAtlas3D? _sharedDefaultAtlas;

  /// Backing [MsdfFontAtlas3D] shared across all batched strings.
  final MsdfFontAtlas3D atlas =
      atlas ?? (_sharedDefaultAtlas ??= MsdfFontAtlas3D.generateDefault());

  late final BillboardMaterial3D _billboardMaterial;
  late final BillboardBatch3D _billboardBatch;

  final List<_TextEntry3D> _entries = [];
  bool _geometryDirty = false;
  int _glyphQuadCount = 0;
  final Aabb3 _localAabb = Aabb3();
  bool _hasBounds = false;

  /// Number of text strings currently queued in this batch.
  int get textCount => _entries.length;

  /// Total number of non-whitespace glyph quads generated across all strings.
  int get glyphCount {
    _ensureRebuilt();
    return _glyphQuadCount;
  }

  /// Underlying [BillboardMaterial3D] the glyphs are drawn with.
  BillboardMaterial3D get billboardMaterial => _billboardMaterial;

  /// Clears all strings from this batch without releasing GPU buffers.
  void clear() {
    if (_entries.isEmpty) {
      return;
    }
    _entries.clear();
    _billboardBatch.clear();
    _glyphQuadCount = 0;
    _hasBounds = false;
    _geometryDirty = false;
    markAabbDirty();
    worldOrNull?.markSceneDirty(shadows: false);
  }

  /// Appends [text] to this batch and returns its string slot index.
  int addText(
    String text, {
    required Vector3 position,
    double fontSize = 0.5,
    Color color = const Color(0xFFFFFFFF),
    TextBillboardMode3D mode = TextBillboardMode3D.spherical,
    Quaternion? rotation,
    TextAlign3D align = TextAlign3D.left,
    double letterSpacing = 0.0,
    double lineHeight = 1.2,
  }) {
    final idx = _entries.length;
    _entries.add(
      _TextEntry3D(
        text: text,
        position: position.clone(),
        fontSize: math.max(1e-4, fontSize),
        color: color,
        mode: mode,
        rotation: rotation?.clone(),
        align: align,
        letterSpacing: letterSpacing,
        lineHeight: lineHeight,
      ),
    );
    _geometryDirty = true;
    markAabbDirty();
    worldOrNull?.markSceneDirty(shadows: false);
    return idx;
  }

  /// Replaces the string at [index] in place; the options left out keep
  /// their values.
  void setText(
    int index,
    String text, {
    Vector3? position,
    double? fontSize,
    Color? color,
    TextBillboardMode3D? mode,
    Quaternion? rotation,
    TextAlign3D? align,
    double? letterSpacing,
    double? lineHeight,
  }) {
    RangeError.checkValidIndex(index, this, 'index', _entries.length);
    final prev = _entries[index];
    _entries[index] = _TextEntry3D(
      text: text,
      position: position?.clone() ?? prev.position,
      fontSize: fontSize ?? prev.fontSize,
      color: color ?? prev.color,
      mode: mode ?? prev.mode,
      rotation: rotation?.clone() ?? prev.rotation,
      align: align ?? prev.align,
      letterSpacing: letterSpacing ?? prev.letterSpacing,
      lineHeight: lineHeight ?? prev.lineHeight,
    );
    _geometryDirty = true;
    markAabbDirty();
    worldOrNull?.markSceneDirty(shadows: false);
  }

  @override
  Aabb3? computeLocalAabb() {
    _ensureRebuilt();
    return _hasBounds ? _localAabb : null;
  }

  @override
  void draw(covariant RenderContext3D context) {
    if (_entries.isEmpty || context.isShadowPass) {
      return;
    }
    _ensureRebuilt();
    _billboardMaterial.alphaCutoff = math.max(alphaCutoff, 1 / 255);
    if (!_billboardBatch.isEmpty) {
      _billboardBatch.drawTransformed(context, worldTransformMatrix);
    }
  }

  void _ensureRebuilt() {
    if (!_geometryDirty) {
      return;
    }
    _geometryDirty = false;
    _billboardBatch.clear();
    _glyphQuadCount = 0;

    var minX = double.infinity;
    var minY = double.infinity;
    var minZ = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    var maxZ = double.negativeInfinity;

    void expandBounds(double x, double y, double z, double r) {
      if (x - r < minX) {
        minX = x - r;
      }
      if (y - r < minY) {
        minY = y - r;
      }
      if (z - r < minZ) {
        minZ = z - r;
      }
      if (x + r > maxX) {
        maxX = x + r;
      }
      if (y + r > maxY) {
        maxY = y + r;
      }
      if (z + r > maxZ) {
        maxZ = z + r;
      }
    }

    final rightVec = Vector3.zero();
    final upVec = Vector3.zero();

    for (var eIdx = 0; eIdx < _entries.length; eIdx++) {
      final entry = _entries[eIdx];
      if (entry.text.isEmpty) {
        continue;
      }
      final lines = entry.text.split('\n');
      final size = entry.fontSize;

      // The plane of fixed text, and the roll and tilt that a rotation adds
      // to camera-facing text.
      final rot = entry.rotation;
      var rollRad = 0.0;
      var tiltRad = 0.0;
      rightVec.setValues(1.0, 0.0, 0.0);
      upVec.setValues(0.0, 1.0, 0.0);
      if (rot != null) {
        _rotateByQuat(rot, rightVec);
        _rotateByQuat(rot, upVec);
        rollRad = math.atan2(rightVec.y, rightVec.x);
        tiltRad = math.asin((-upVec.z).clamp(-1.0, 1.0));
      }
      final fixed = entry.mode == TextBillboardMode3D.fixed;
      final orientation = switch (entry.mode) {
        TextBillboardMode3D.spherical => BillboardOrientation3D.spherical,
        TextBillboardMode3D.cylindrical => BillboardOrientation3D.cylindrical,
        TextBillboardMode3D.fixed => BillboardOrientation3D.fixed,
      };

      for (var lineIdx = 0; lineIdx < lines.length; lineIdx++) {
        final line = lines[lineIdx];
        if (line.isEmpty) {
          continue;
        }
        final lineW = atlas.measureLineWidth(
          line,
          fontSize: size,
          letterSpacing: entry.letterSpacing,
        );
        var cursorX = switch (entry.align) {
          TextAlign3D.left => 0.0,
          TextAlign3D.center => -0.5 * lineW,
          TextAlign3D.right => -lineW,
        };
        final cursorY = -lineIdx * entry.lineHeight * size;

        int? prevCu;
        for (var cIdx = 0; cIdx < line.length; cIdx++) {
          final cu = line.codeUnitAt(cIdx);
          if (prevCu != null) {
            cursorX += (atlas.kerning(prevCu, cu) + entry.letterSpacing) * size;
          }
          final m = atlas.metricsFor(cu);
          final gw = m.width * size;
          final gh = m.height * size;
          final adv = m.advance * size;

          if (cu != 0x20 && cu != 0x09) {
            final localOffsetX = cursorX + 0.5 * adv;
            final localOffsetY = cursorY;

            // Every glyph of a string sits at the string's position and is
            // moved to its place in the string by its anchors, which the
            // shader applies along the sprite's right and up: the camera's
            // (or the cylinder's) for camera-facing text, so that a string
            // keeps its width seen from any side, the plane's for fixed text.
            final anchorX = -localOffsetX / gw;
            final anchorY = -localOffsetY / gh;
            final rx = (anchorX.abs() + 0.5) * gw;
            final ry = (anchorY.abs() + 0.5) * gh;
            final p = entry.position;
            expandBounds(p.x, p.y, p.z, math.sqrt(rx * rx + ry * ry));

            _billboardBatch.addBillboard(
              position: p,
              width: gw,
              height: gh,
              orientation: orientation,
              upAxis: fixed ? upVec : null,
              rightAxis: fixed ? rightVec : null,
              anchorY: anchorY,
              anchorX: anchorX,
              tiltRadians: fixed ? 0.0 : tiltRad,
              rollRadians: fixed ? 0.0 : rollRad,
              uvRect: m.uvRect,
              color: entry.color,
              unlit: 1.0,
            );
            _glyphQuadCount++;
          }

          cursorX += adv;
          prevCu = cu;
        }
      }
    }

    if (minX.isFinite) {
      _localAabb
        ..min.setValues(minX, minY, minZ)
        ..max.setValues(maxX, maxY, maxZ);
      _hasBounds = true;
    } else {
      _hasBounds = false;
    }
  }

  static void _rotateByQuat(Quaternion q, Vector3 v) {
    final qx = q.x;
    final qy = q.y;
    final qz = q.z;
    final qw = q.w;
    final tx = 2.0 * (qy * v.z - qz * v.y);
    final ty = 2.0 * (qz * v.x - qx * v.z);
    final tz = 2.0 * (qx * v.y - qy * v.x);
    v.setValues(
      v.x + qw * tx + (qy * tz - qz * ty),
      v.y + qw * ty + (qz * tx - qx * tz),
      v.z + qw * tz + (qx * ty - qy * tx),
    );
  }
}

// =============================================================================
// Procedural Vector Stroke Glyph Table (Printable ASCII 0x20..0x7E)
// =============================================================================

class _GlyphStrokeSpec({
  required final List<double> segments,
  final double advance = 0.62,
  final double quadWidth = 0.62,
});

abstract final class _VectorGlyphTable._() {
  // Normalized `[0..1] x [0..1]` cell coordinates (`y = 0` top, `y = 1` bottom,
  // cap-top `0.15`, midline `0.5`, baseline `0.85`, descender `0.96`).
  static const double _l = 0.2;
  static const double _c = 0.5;
  static const double _r = 0.8;
  static const double _t = 0.15;
  static const double _m = 0.5;
  static const double _xh = 0.36;
  static const double _b = 0.85;
  static const double _d = 0.96;

  static _GlyphStrokeSpec lookup(int codeUnit) =>
      _specs[codeUnit] ?? _fallbackBox;

  static final _GlyphStrokeSpec _fallbackBox = _GlyphStrokeSpec(
    segments: const [
      _l, _t, _r, _t, //
      _r, _t, _r, _b, //
      _r, _b, _l, _b, //
      _l, _b, _l, _t, //
      _l, _t, _r, _b, //
    ],
  );

  static final Map<int, _GlyphStrokeSpec> _specs = _buildTable();

  static Map<int, _GlyphStrokeSpec> _buildTable() {
    final map = <int, _GlyphStrokeSpec>{};
    void def(
      String ch,
      List<double> segs, {
      double advance = 0.62,
    }) {
      map[ch.codeUnitAt(0)] = _GlyphStrokeSpec(
        segments: segs,
        advance: advance,
        quadWidth: math.max(0.45, advance),
      );
    }

    // Space
    def(' ', const [], advance: 0.34);

    // Digits 0..9
    def('0', const [
      _l, _t, _r, _t, _r, _t, _r, _b, _r, _b, _l, _b, _l, _b, _l, _t, //
      _l, _b, _r, _t,
    ]);
    def(
      '1',
      const [
        _l + 0.1,
        _t + 0.12,
        _c,
        _t,
        _c,
        _t,
        _c,
        _b,
        _l + 0.1,
        _b,
        _r - 0.1,
        _b,
      ],
      advance: 0.5,
    );
    def('2', const [
      _l,
      _t,
      _r,
      _t,
      _r,
      _t,
      _r,
      _m,
      _r,
      _m,
      _l,
      _m,
      _l,
      _m,
      _l,
      _b,
      _l,
      _b,
      _r,
      _b,
    ]);
    def('3', const [
      _l,
      _t,
      _r,
      _t,
      _r,
      _t,
      _r,
      _b,
      _r,
      _b,
      _l,
      _b,
      _l + 0.1,
      _m,
      _r,
      _m,
    ]);
    def('4', const [
      _l,
      _t,
      _l,
      _m,
      _l,
      _m,
      _r,
      _m,
      _r - 0.08,
      _t,
      _r - 0.08,
      _b,
    ]);
    def('5', const [
      _r,
      _t,
      _l,
      _t,
      _l,
      _t,
      _l,
      _m,
      _l,
      _m,
      _r,
      _m,
      _r,
      _m,
      _r,
      _b,
      _r,
      _b,
      _l,
      _b,
    ]);
    def('6', const [
      _r,
      _t,
      _l,
      _t,
      _l,
      _t,
      _l,
      _b,
      _l,
      _b,
      _r,
      _b,
      _r,
      _b,
      _r,
      _m,
      _r,
      _m,
      _l,
      _m,
    ]);
    def('7', const [_l, _t, _r, _t, _r, _t, _l + 0.15, _b]);
    def('8', const [
      _l,
      _t,
      _r,
      _t,
      _r,
      _t,
      _r,
      _b,
      _r,
      _b,
      _l,
      _b,
      _l,
      _b,
      _l,
      _t,
      _l,
      _m,
      _r,
      _m,
    ]);
    def('9', const [
      _l,
      _m,
      _l,
      _t,
      _l,
      _t,
      _r,
      _t,
      _r,
      _t,
      _r,
      _b,
      _r,
      _b,
      _l,
      _b,
      _l,
      _m,
      _r,
      _m,
    ]);

    // Uppercase A..Z
    def('A', const [
      _l,
      _b,
      _c,
      _t,
      _c,
      _t,
      _r,
      _b,
      _l + 0.12,
      _m + 0.08,
      _r - 0.12,
      _m + 0.08,
    ]);
    def('B', const [
      _l,
      _t,
      _l,
      _b,
      _l,
      _t,
      _r - 0.08,
      _t,
      _r - 0.08,
      _t,
      _r,
      _t + 0.16,
      _r,
      _t + 0.16,
      _r - 0.08,
      _m,
      _l,
      _m,
      _r - 0.05,
      _m,
      _r - 0.05,
      _m,
      _r,
      _b - 0.12,
      _r,
      _b - 0.12,
      _r - 0.08,
      _b,
      _r - 0.08,
      _b,
      _l,
      _b,
    ]);
    def('C', const [_r, _t, _l, _t, _l, _t, _l, _b, _l, _b, _r, _b]);
    def('D', const [
      _l,
      _t,
      _l,
      _b,
      _l,
      _t,
      _r - 0.12,
      _t,
      _r - 0.12,
      _t,
      _r,
      _m,
      _r,
      _m,
      _r - 0.12,
      _b,
      _r - 0.12,
      _b,
      _l,
      _b,
    ]);
    def('E', const [
      _r,
      _t,
      _l,
      _t,
      _l,
      _t,
      _l,
      _b,
      _l,
      _b,
      _r,
      _b,
      _l,
      _m,
      _r - 0.1,
      _m,
    ]);
    def('F', const [_r, _t, _l, _t, _l, _t, _l, _b, _l, _m, _r - 0.1, _m]);
    def('G', const [
      _r,
      _t,
      _l,
      _t,
      _l,
      _t,
      _l,
      _b,
      _l,
      _b,
      _r,
      _b,
      _r,
      _b,
      _r,
      _m,
      _c,
      _m,
      _r,
      _m,
    ]);
    def('H', const [_l, _t, _l, _b, _r, _t, _r, _b, _l, _m, _r, _m]);
    def('I', const [
      _l + 0.1,
      _t,
      _r - 0.1,
      _t,
      _c,
      _t,
      _c,
      _b,
      _l + 0.1,
      _b,
      _r - 0.1,
      _b,
    ], advance: 0.44);
    def('J', const [
      _l + 0.1,
      _t,
      _r,
      _t,
      _r - 0.1,
      _t,
      _r - 0.1,
      _b,
      _r - 0.1,
      _b,
      _l,
      _b,
      _l,
      _b,
      _l,
      _b - 0.18,
    ]);
    def('K', const [_l, _t, _l, _b, _r, _t, _l, _m, _l, _m, _r, _b]);
    def('L', const [_l, _t, _l, _b, _l, _b, _r, _b]);
    def('M', const [
      _l,
      _b,
      _l,
      _t,
      _l,
      _t,
      _c,
      _m + 0.08,
      _c,
      _m + 0.08,
      _r,
      _t,
      _r,
      _t,
      _r,
      _b,
    ], advance: 0.72);
    def('N', const [_l, _b, _l, _t, _l, _t, _r, _b, _r, _b, _r, _t]);
    def('O', const [
      _l,
      _t,
      _r,
      _t,
      _r,
      _t,
      _r,
      _b,
      _r,
      _b,
      _l,
      _b,
      _l,
      _b,
      _l,
      _t,
    ]);
    def('P', const [
      _l,
      _b,
      _l,
      _t,
      _l,
      _t,
      _r,
      _t,
      _r,
      _t,
      _r,
      _m,
      _r,
      _m,
      _l,
      _m,
    ]);
    def('Q', const [
      _l,
      _t,
      _r,
      _t,
      _r,
      _t,
      _r,
      _b,
      _r,
      _b,
      _l,
      _b,
      _l,
      _b,
      _l,
      _t,
      _c,
      _m + 0.1,
      _r + 0.06,
      _b + 0.06,
    ]);
    def('R', const [
      _l,
      _b,
      _l,
      _t,
      _l,
      _t,
      _r,
      _t,
      _r,
      _t,
      _r,
      _m,
      _r,
      _m,
      _l,
      _m,
      _c,
      _m,
      _r,
      _b,
    ]);
    def('S', const [
      _r,
      _t,
      _l,
      _t,
      _l,
      _t,
      _l,
      _m,
      _l,
      _m,
      _r,
      _m,
      _r,
      _m,
      _r,
      _b,
      _r,
      _b,
      _l,
      _b,
    ]);
    def('T', const [_l, _t, _r, _t, _c, _t, _c, _b]);
    def('U', const [_l, _t, _l, _b, _l, _b, _r, _b, _r, _b, _r, _t]);
    def('V', const [_l, _t, _c, _b, _c, _b, _r, _t]);
    def('W', const [
      _l,
      _t,
      _l + 0.14,
      _b,
      _l + 0.14,
      _b,
      _c,
      _m,
      _c,
      _m,
      _r - 0.14,
      _b,
      _r - 0.14,
      _b,
      _r,
      _t,
    ], advance: 0.74);
    def('X', const [_l, _t, _r, _b, _r, _t, _l, _b]);
    def('Y', const [_l, _t, _c, _m, _r, _t, _c, _m, _c, _m, _c, _b]);
    def('Z', const [_l, _t, _r, _t, _r, _t, _l, _b, _l, _b, _r, _b]);

    // Lowercase a..z (distinct x-height `_xh` + ascenders/descenders)
    def('a', const [
      _l + 0.05,
      _xh,
      _r - 0.05,
      _xh,
      _r - 0.05,
      _xh,
      _r - 0.05,
      _b,
      _r - 0.05,
      _m + 0.08,
      _l,
      _m + 0.08,
      _l,
      _m + 0.08,
      _l,
      _b,
      _l,
      _b,
      _r - 0.05,
      _b,
    ], advance: 0.56);
    def('b', const [
      _l,
      _t,
      _l,
      _b,
      _l,
      _xh,
      _r,
      _xh,
      _r,
      _xh,
      _r,
      _b,
      _r,
      _b,
      _l,
      _b,
    ], advance: 0.56);
    def('c', const [
      _r,
      _xh,
      _l,
      _xh,
      _l,
      _xh,
      _l,
      _b,
      _l,
      _b,
      _r,
      _b,
    ], advance: 0.52);
    def('d', const [
      _r,
      _t,
      _r,
      _b,
      _r,
      _xh,
      _l,
      _xh,
      _l,
      _xh,
      _l,
      _b,
      _l,
      _b,
      _r,
      _b,
    ], advance: 0.56);
    def('e', const [
      _l,
      _m + 0.08,
      _r,
      _m + 0.08,
      _r,
      _m + 0.08,
      _r,
      _xh,
      _r,
      _xh,
      _l,
      _xh,
      _l,
      _xh,
      _l,
      _b,
      _l,
      _b,
      _r,
      _b,
    ], advance: 0.56);
    def('f', const [
      _r - 0.1,
      _t,
      _c - 0.05,
      _t,
      _c - 0.05,
      _t,
      _c - 0.05,
      _b,
      _l + 0.08,
      _xh,
      _r - 0.12,
      _xh,
    ], advance: 0.42);
    def('g', const [
      _r,
      _xh,
      _l,
      _xh,
      _l,
      _xh,
      _l,
      _b,
      _l,
      _b,
      _r,
      _b,
      _r,
      _xh,
      _r,
      _d,
      _r,
      _d,
      _l,
      _d,
    ], advance: 0.56);
    def('h', const [
      _l,
      _t,
      _l,
      _b,
      _l,
      _xh,
      _r,
      _xh,
      _r,
      _xh,
      _r,
      _b,
    ], advance: 0.56);
    def('i', const [
      _c,
      _xh,
      _c,
      _b,
      _c,
      _t + 0.05,
      _c,
      _t + 0.1,
    ], advance: 0.34);
    def('j', const [
      _c + 0.08,
      _xh,
      _c + 0.08,
      _d,
      _c + 0.08,
      _d,
      _l + 0.05,
      _d,
      _c + 0.08,
      _t + 0.05,
      _c + 0.08,
      _t + 0.1,
    ], advance: 0.38);
    def('k', const [
      _l,
      _t,
      _l,
      _b,
      _r - 0.06,
      _xh,
      _l,
      _m + 0.12,
      _l,
      _m + 0.12,
      _r - 0.04,
      _b,
    ], advance: 0.54);
    def('l', const [_c, _t, _c, _b, _c, _b, _c + 0.12, _b], advance: 0.34);
    def('m', const [
      _l,
      _b,
      _l,
      _xh,
      _l,
      _xh,
      _r,
      _xh,
      _c,
      _xh,
      _c,
      _b,
      _r,
      _xh,
      _r,
      _b,
    ], advance: 0.7);
    def('n', const [
      _l,
      _b,
      _l,
      _xh,
      _l,
      _xh,
      _r,
      _xh,
      _r,
      _xh,
      _r,
      _b,
    ], advance: 0.56);
    def('o', const [
      _l,
      _xh,
      _r,
      _xh,
      _r,
      _xh,
      _r,
      _b,
      _r,
      _b,
      _l,
      _b,
      _l,
      _b,
      _l,
      _xh,
    ], advance: 0.56);
    def('p', const [
      _l,
      _xh,
      _l,
      _d,
      _l,
      _xh,
      _r,
      _xh,
      _r,
      _xh,
      _r,
      _b,
      _r,
      _b,
      _l,
      _b,
    ], advance: 0.56);
    def('q', const [
      _r,
      _xh,
      _r,
      _d,
      _r,
      _xh,
      _l,
      _xh,
      _l,
      _xh,
      _l,
      _b,
      _l,
      _b,
      _r,
      _b,
    ], advance: 0.56);
    def('r', const [
      _l + 0.08,
      _b,
      _l + 0.08,
      _xh,
      _l + 0.08,
      _xh,
      _r - 0.08,
      _xh,
    ], advance: 0.44);
    def('s', const [
      _r,
      _xh,
      _l,
      _xh,
      _l,
      _xh,
      _l,
      _m + 0.1,
      _l,
      _m + 0.1,
      _r,
      _m + 0.1,
      _r,
      _m + 0.1,
      _r,
      _b,
      _r,
      _b,
      _l,
      _b,
    ], advance: 0.52);
    def('t', const [
      _c,
      _t + 0.08,
      _c,
      _b,
      _c,
      _b,
      _r - 0.1,
      _b,
      _l + 0.1,
      _xh,
      _r - 0.1,
      _xh,
    ], advance: 0.44);
    def('u', const [
      _l,
      _xh,
      _l,
      _b,
      _l,
      _b,
      _r,
      _b,
      _r,
      _b,
      _r,
      _xh,
    ], advance: 0.56);
    def('v', const [_l, _xh, _c, _b, _c, _b, _r, _xh], advance: 0.54);
    def('w', const [
      _l,
      _xh,
      _l + 0.14,
      _b,
      _l + 0.14,
      _b,
      _c,
      _m + 0.08,
      _c,
      _m + 0.08,
      _r - 0.14,
      _b,
      _r - 0.14,
      _b,
      _r,
      _xh,
    ], advance: 0.68);
    def('x', const [_l, _xh, _r, _b, _r, _xh, _l, _b], advance: 0.54);
    def('y', const [_l, _xh, _c, _b, _r, _xh, _l + 0.08, _d], advance: 0.54);
    def('z', const [
      _l,
      _xh,
      _r,
      _xh,
      _r,
      _xh,
      _l,
      _b,
      _l,
      _b,
      _r,
      _b,
    ], advance: 0.52);

    // Punctuation & math/programming symbols
    def('.', const [_c, _b - 0.04, _c, _b], advance: 0.32);
    def(',', const [_c, _b - 0.04, _c - 0.08, _d], advance: 0.32);
    def(':', const [
      _c,
      _xh + 0.06,
      _c,
      _xh + 0.1,
      _c,
      _b - 0.05,
      _c,
      _b,
    ], advance: 0.32);
    def(';', const [
      _c,
      _xh + 0.06,
      _c,
      _xh + 0.1,
      _c,
      _b - 0.04,
      _c - 0.08,
      _d,
    ], advance: 0.32);
    def('!', const [
      _c,
      _t,
      _c,
      _b - 0.18,
      _c,
      _b - 0.04,
      _c,
      _b,
    ], advance: 0.34);
    def('?', const [
      _l,
      _t,
      _r,
      _t,
      _r,
      _t,
      _r,
      _m,
      _r,
      _m,
      _c,
      _m,
      _c,
      _m,
      _c,
      _b - 0.18,
      _c,
      _b - 0.04,
      _c,
      _b,
    ]);
    def('-', const [_l + 0.06, _m, _r - 0.06, _m], advance: 0.48);
    def('_', const [_l, _b + 0.05, _r, _b + 0.05]);
    def('+', const [
      _c,
      _t + 0.15,
      _c,
      _b - 0.15,
      _l + 0.05,
      _m,
      _r - 0.05,
      _m,
    ]);
    def('=', const [
      _l + 0.05,
      _m - 0.1,
      _r - 0.05,
      _m - 0.1,
      _l + 0.05,
      _m + 0.1,
      _r - 0.05,
      _m + 0.1,
    ]);
    def('*', const [
      _c,
      _t + 0.15,
      _c,
      _m + 0.15,
      _l + 0.08,
      _t + 0.22,
      _r - 0.08,
      _m + 0.08,
      _r - 0.08,
      _t + 0.22,
      _l + 0.08,
      _m + 0.08,
    ]);
    def('/', const [_l + 0.05, _b, _r - 0.05, _t], advance: 0.48);
    def(r'\', const [_l + 0.05, _t, _r - 0.05, _b], advance: 0.48);
    def('|', const [_c, _t, _c, _d], advance: 0.32);
    def('(', const [
      _r - 0.15,
      _t,
      _l + 0.15,
      _m,
      _l + 0.15,
      _m,
      _r - 0.15,
      _d,
    ], advance: 0.4);
    def(')', const [
      _l + 0.15,
      _t,
      _r - 0.15,
      _m,
      _r - 0.15,
      _m,
      _l + 0.15,
      _d,
    ], advance: 0.4);
    def('[', const [
      _r - 0.12,
      _t,
      _l + 0.15,
      _t,
      _l + 0.15,
      _t,
      _l + 0.15,
      _d,
      _l + 0.15,
      _d,
      _r - 0.12,
      _d,
    ], advance: 0.4);
    def(']', const [
      _l + 0.12,
      _t,
      _r - 0.15,
      _t,
      _r - 0.15,
      _t,
      _r - 0.15,
      _d,
      _r - 0.15,
      _d,
      _l + 0.12,
      _d,
    ], advance: 0.4);
    def('{', const [
      _r - 0.12,
      _t,
      _c,
      _t,
      _c,
      _t,
      _c,
      _m - 0.06,
      _c,
      _m - 0.06,
      _l + 0.12,
      _m,
      _l + 0.12,
      _m,
      _c,
      _m + 0.06,
      _c,
      _m + 0.06,
      _c,
      _d,
      _c,
      _d,
      _r - 0.12,
      _d,
    ], advance: 0.44);
    def('}', const [
      _l + 0.12,
      _t,
      _c,
      _t,
      _c,
      _t,
      _c,
      _m - 0.06,
      _c,
      _m - 0.06,
      _r - 0.12,
      _m,
      _r - 0.12,
      _m,
      _c,
      _m + 0.06,
      _c,
      _m + 0.06,
      _c,
      _d,
      _c,
      _d,
      _l + 0.12,
      _d,
    ], advance: 0.44);
    def('<', const [
      _r - 0.08,
      _t + 0.12,
      _l + 0.08,
      _m,
      _l + 0.08,
      _m,
      _r - 0.08,
      _b - 0.12,
    ]);
    def('>', const [
      _l + 0.08,
      _t + 0.12,
      _r - 0.08,
      _m,
      _r - 0.08,
      _m,
      _l + 0.08,
      _b - 0.12,
    ]);
    def("'", const [_c, _t, _c, _t + 0.2], advance: 0.28);
    def('"', const [
      _c - 0.1,
      _t,
      _c - 0.1,
      _t + 0.2,
      _c + 0.1,
      _t,
      _c + 0.1,
      _t + 0.2,
    ], advance: 0.42);
    def('`', const [_c - 0.06, _t, _c + 0.06, _t + 0.14], advance: 0.34);
    def('^', const [
      _l + 0.1,
      _t + 0.22,
      _c,
      _t,
      _c,
      _t,
      _r - 0.1,
      _t + 0.22,
    ], advance: 0.5);
    def('~', const [
      _l,
      _m + 0.04,
      _l + 0.2,
      _m - 0.08,
      _l + 0.2,
      _m - 0.08,
      _r - 0.2,
      _m + 0.08,
      _r - 0.2,
      _m + 0.08,
      _r,
      _m - 0.04,
    ]);
    def('#', const [
      _l + 0.14,
      _t,
      _l + 0.1,
      _b,
      _r - 0.1,
      _t,
      _r - 0.14,
      _b,
      _l,
      _m - 0.12,
      _r,
      _m - 0.12,
      _l,
      _m + 0.12,
      _r,
      _m + 0.12,
    ]);
    def(r'$', const [
      _r,
      _t + 0.06,
      _l,
      _t + 0.06,
      _l,
      _t + 0.06,
      _l,
      _m,
      _l,
      _m,
      _r,
      _m,
      _r,
      _m,
      _r,
      _b - 0.06,
      _r,
      _b - 0.06,
      _l,
      _b - 0.06,
      _c,
      _t - 0.05,
      _c,
      _d,
    ]);
    def('%', const [
      _l + 0.06,
      _b,
      _r - 0.06,
      _t,
      _l,
      _t,
      _l + 0.18,
      _t,
      _l + 0.18,
      _t,
      _l + 0.18,
      _t + 0.18,
      _l + 0.18,
      _t + 0.18,
      _l,
      _t + 0.18,
      _l,
      _t + 0.18,
      _l,
      _t,
      _r - 0.18,
      _b - 0.18,
      _r,
      _b - 0.18,
      _r,
      _b - 0.18,
      _r,
      _b,
      _r,
      _b,
      _r - 0.18,
      _b,
      _r - 0.18,
      _b,
      _r - 0.18,
      _b - 0.18,
    ], advance: 0.68);
    def('&', const [
      _r,
      _b,
      _l + 0.06,
      _t + 0.16,
      _l + 0.06,
      _t + 0.16,
      _c,
      _t,
      _c,
      _t,
      _r - 0.1,
      _t + 0.16,
      _r - 0.1,
      _t + 0.16,
      _l,
      _m + 0.12,
      _l,
      _m + 0.12,
      _c,
      _b,
      _c,
      _b,
      _r,
      _m + 0.1,
    ]);
    def('@', const [
      _r,
      _b - 0.12,
      _r,
      _t,
      _r,
      _t,
      _l,
      _t,
      _l,
      _t,
      _l,
      _b,
      _l,
      _b,
      _r - 0.1,
      _b,
      _c - 0.08,
      _xh,
      _c + 0.12,
      _xh,
      _c + 0.12,
      _xh,
      _c + 0.12,
      _m + 0.16,
      _c + 0.12,
      _m + 0.16,
      _c - 0.08,
      _m + 0.16,
      _c - 0.08,
      _m + 0.16,
      _c - 0.08,
      _xh,
    ], advance: 0.72);

    return map;
  }
}
