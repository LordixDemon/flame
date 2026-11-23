import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Color, Rect;

import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/src/extensions/geometry_math.dart';

part 'msdf_font_atlas_3d.dart';
part 'msdf_vector_glyph_table.dart';

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

class _TextEntry3D({
  required var String text,
  required final Vector3 position,
  required var double fontSize,
  required var Color color,
  required var TextBillboardMode3D mode,
  required var TextAlign3D align,
  required var double letterSpacing,
  required var double lineHeight,
  var Quaternion? rotation,
}) {
  int quadStart = 0;
  int quadCount = 0;
  double minX = 0.0;
  double minY = 0.0;
  double minZ = 0.0;
  double maxX = 0.0;
  double maxY = 0.0;
  double maxZ = 0.0;
  bool hasBounds = false;
}

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
  bool _aabbDirty = false;
  int _glyphQuadCount = 0;
  final Aabb3 _localAabb = Aabb3();
  bool _hasBounds = false;
  final Vector3 _rightScratch = Vector3.zero();
  final Vector3 _upScratch = Vector3.zero();

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
    _aabbDirty = false;
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
    _aabbDirty = true;
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
    final entry = _entries[index]..text = text;
    if (position != null) {
      entry.position.setFrom(position);
    }
    if (fontSize != null) {
      entry.fontSize = math.max(1e-4, fontSize);
    }
    if (color != null) {
      entry.color = color;
    }
    if (mode != null) {
      entry.mode = mode;
    }
    if (rotation != null) {
      final existing = entry.rotation;
      if (existing != null) {
        existing.setFrom(rotation);
      } else {
        entry.rotation = rotation.clone();
      }
    }
    if (align != null) {
      entry.align = align;
    }
    if (letterSpacing != null) {
      entry.letterSpacing = letterSpacing;
    }
    if (lineHeight != null) {
      entry.lineHeight = lineHeight;
    }

    if (!_geometryDirty && _countVisibleGlyphs(text) == entry.quadCount) {
      _emitEntryGlyphs(entry, inPlace: true);
    } else {
      _geometryDirty = true;
    }
    _aabbDirty = true;
    markAabbDirty();
    worldOrNull?.markSceneDirty(shadows: false);
  }

  @override
  bool get usesDefaultFrustumVisibility => runtimeType == MsdfTextBatch3D;

  @override
  Aabb3? computeLocalAabb() {
    _ensureRebuilt();
    if (_aabbDirty) {
      _recomputeAabbFromEntries();
    }
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
      _billboardBatch.drawTransformed(
        context,
        worldTransformMatrix,
        transformVersion: worldTransformVersion,
      );
    }
  }

  static int _countVisibleGlyphs(String text) {
    var count = 0;
    for (var i = 0; i < text.length; i++) {
      final cu = text.codeUnitAt(i);
      if (cu != 0x0A && cu != 0x20 && cu != 0x09) {
        count++;
      }
    }
    return count;
  }

  void _ensureRebuilt() {
    if (!_geometryDirty) {
      return;
    }
    _geometryDirty = false;
    _billboardBatch.clear();
    _glyphQuadCount = 0;

    for (var eIdx = 0; eIdx < _entries.length; eIdx++) {
      final entry = _entries[eIdx];
      entry.quadStart = _glyphQuadCount;
      _emitEntryGlyphs(entry, inPlace: false);
      _glyphQuadCount += entry.quadCount;
    }

    _recomputeAabbFromEntries();
  }

  void _recomputeAabbFromEntries() {
    _aabbDirty = false;
    var minX = double.infinity;
    var minY = double.infinity;
    var minZ = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    var maxZ = double.negativeInfinity;
    var any = false;
    for (var i = 0; i < _entries.length; i++) {
      final e = _entries[i];
      if (!e.hasBounds) {
        continue;
      }
      any = true;
      if (e.minX < minX) {
        minX = e.minX;
      }
      if (e.minY < minY) {
        minY = e.minY;
      }
      if (e.minZ < minZ) {
        minZ = e.minZ;
      }
      if (e.maxX > maxX) {
        maxX = e.maxX;
      }
      if (e.maxY > maxY) {
        maxY = e.maxY;
      }
      if (e.maxZ > maxZ) {
        maxZ = e.maxZ;
      }
    }
    if (any) {
      _localAabb
        ..min.setValues(minX, minY, minZ)
        ..max.setValues(maxX, maxY, maxZ);
      _hasBounds = true;
    } else {
      _hasBounds = false;
    }
  }

  void _emitEntryGlyphs(_TextEntry3D entry, {required bool inPlace}) {
    final text = entry.text;
    if (text.isEmpty) {
      entry
        ..quadCount = 0
        ..hasBounds = false;
      return;
    }

    final size = entry.fontSize;
    final rot = entry.rotation;
    var rollRad = 0.0;
    var tiltRad = 0.0;
    final rightVec = _rightScratch..setValues(1.0, 0.0, 0.0);
    final upVec = _upScratch..setValues(0.0, 1.0, 0.0);
    if (rot != null) {
      rotateVectorByQuat(rot, rightVec, rightVec);
      rotateVectorByQuat(rot, upVec, upVec);
      rollRad = math.atan2(rightVec.y, rightVec.x);
      tiltRad = math.asin((-upVec.z).clamp(-1.0, 1.0));
    }
    final fixed = entry.mode == TextBillboardMode3D.fixed;
    final orientation = switch (entry.mode) {
      TextBillboardMode3D.spherical => BillboardOrientation3D.spherical,
      TextBillboardMode3D.cylindrical => BillboardOrientation3D.cylindrical,
      TextBillboardMode3D.fixed => BillboardOrientation3D.fixed,
    };

    var minX = double.infinity;
    var minY = double.infinity;
    var minZ = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    var maxZ = double.negativeInfinity;
    var quads = 0;

    final p = entry.position;
    final px = p.x;
    final py = p.y;
    final pz = p.z;

    var lineStart = 0;
    var lineIdx = 0;
    while (lineStart <= text.length) {
      final nl = text.indexOf('\n', lineStart);
      final lineEnd = nl < 0 ? text.length : nl;
      if (lineEnd > lineStart) {
        final lineW = atlas.measureLineRangeWidth(
          text,
          lineStart,
          lineEnd,
          fontSize: size,
          letterSpacing: entry.letterSpacing,
        );
        var cursorX = switch (entry.align) {
          TextAlign3D.left => 0.0,
          TextAlign3D.center => -0.5 * lineW,
          TextAlign3D.right => -lineW,
        };
        final cursorY = -lineIdx * entry.lineHeight * size;

        var prevCu = -1;
        for (var cIdx = lineStart; cIdx < lineEnd; cIdx++) {
          final cu = text.codeUnitAt(cIdx);
          if (prevCu >= 0) {
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
            final r = math.sqrt(rx * rx + ry * ry);
            if (px - r < minX) {
              minX = px - r;
            }
            if (py - r < minY) {
              minY = py - r;
            }
            if (pz - r < minZ) {
              minZ = pz - r;
            }
            if (px + r > maxX) {
              maxX = px + r;
            }
            if (py + r > maxY) {
              maxY = py + r;
            }
            if (pz + r > maxZ) {
              maxZ = pz + r;
            }

            if (inPlace) {
              _billboardBatch.setBillboard(
                entry.quadStart + quads,
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
            } else {
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
            }
            quads++;
          }

          cursorX += adv;
          prevCu = cu;
        }
      }
      if (nl < 0) {
        break;
      }
      lineStart = nl + 1;
      lineIdx++;
    }

    entry
      ..quadCount = quads
      ..minX = minX
      ..minY = minY
      ..minZ = minZ
      ..maxX = maxX
      ..maxY = maxY
      ..maxZ = maxZ
      ..hasBounds = quads > 0;
  }
}
