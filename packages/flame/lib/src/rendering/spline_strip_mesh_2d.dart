import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:vector_math/vector_math.dart';

/// Procedural Catmull-Rom 2D spline strip tessellator for roads, rivers,
/// laser beams, cables, and path previews.
class SplineStripMesh2D._({
  required final Float32List positions,
  required final Float32List uvs,
  required final Int32List colors,
  required final Uint16List indices,
  required final int sampleCount,
}) {
  /// Most spine samples one strip can hold: two vertices each under the
  /// 16-bit vertex indices of `Canvas.drawVertices`.
  static const int maxSamples = 32767;

  /// Builds a tessellated triangle strip along [controlPoints] with
  /// [subdivisionsPerSegment] samples per span. Fewer than two control points
  /// give an empty mesh that draws nothing.
  ///
  /// [tension] `0.5` is the standard Catmull-Rom spline; `1.0` gives straight
  /// segments and `0.0` doubles the tangents.
  ///
  /// Texture coordinates: `U` grows along the strip by one repeat every
  /// [uvRepeatLength] world units and `V` runs across it, both normalised
  /// (`0 .. 1` per repeat) and then multiplied by [textureWidth] and
  /// [textureHeight]. `Canvas.drawVertices` reads texture coordinates in the
  /// shader's own pixels, so pass the pixel size of the image behind the
  /// `ImageShader` given to [render] to map one repeat onto the whole image.
  /// With the defaults (`1.0`) the coordinates stay normalised, for a shader
  /// that carries its own scale matrix.
  ///
  /// A strip holds at most [maxSamples] spine samples. When
  /// `(controlPoints.length - 1) * subdivisionsPerSegment` exceeds that, the
  /// subdivisions are reduced to fit; more than [maxSamples] control points
  /// throw an [ArgumentError].
  factory SplineStripMesh2D.fromCatmullRom({
    required List<Vector2> controlPoints,
    int subdivisionsPerSegment = 8,
    double startWidth = 16.0,
    double? endWidth,
    Color startColor = const Color(0xFFFFFFFF),
    Color? endColor,
    double tension = 0.5,
    double uvRepeatLength = 64.0,
    double textureWidth = 1.0,
    double textureHeight = 1.0,
  }) {
    if (controlPoints.length < 2) {
      return SplineStripMesh2D._(
        positions: Float32List(0),
        uvs: Float32List(0),
        colors: Int32List(0),
        indices: Uint16List(0),
        sampleCount: 0,
      );
    }

    final spans = controlPoints.length - 1;
    if (spans + 1 > maxSamples) {
      throw ArgumentError.value(
        controlPoints.length,
        'controlPoints',
        'a strip holds at most $maxSamples control points',
      );
    }
    final subs = math.max(
      1,
      math.min(subdivisionsPerSegment, (maxSamples - 1) ~/ spans),
    );
    final totalSamples = spans * subs + 1;
    final finalEndWidth = endWidth ?? startWidth;
    final finalEndColor = endColor ?? startColor;

    final spineX = Float32List(totalSamples);
    final spineY = Float32List(totalSamples);

    var cursor = 0;
    for (var s = 0; s < spans; s++) {
      final p0 = controlPoints[math.max(0, s - 1)];
      final p1 = controlPoints[s];
      final p2 = controlPoints[s + 1];
      final p3 = controlPoints[math.min(controlPoints.length - 1, s + 2)];

      final m1x = (1.0 - tension) * (p2.x - p0.x);
      final m1y = (1.0 - tension) * (p2.y - p0.y);
      final m2x = (1.0 - tension) * (p3.x - p1.x);
      final m2y = (1.0 - tension) * (p3.y - p1.y);

      final limit = (s == spans - 1) ? subs : subs - 1;
      for (var k = 0; k <= limit; k++) {
        final t = k / subs;
        final t2 = t * t;
        final t3 = t2 * t;
        final h00 = 2.0 * t3 - 3.0 * t2 + 1.0;
        final h10 = t3 - 2.0 * t2 + t;
        final h01 = -2.0 * t3 + 3.0 * t2;
        final h11 = t3 - t2;

        spineX[cursor] = h00 * p1.x + h10 * m1x + h01 * p2.x + h11 * m2x;
        spineY[cursor] = h00 * p1.y + h10 * m1y + h01 * p2.y + h11 * m2y;
        cursor++;
      }
    }

    final positions = Float32List(totalSamples * 4);
    final uvs = Float32List(totalSamples * 4);
    final colors = Int32List(totalSamples * 2);
    final indices = Uint16List((totalSamples - 1) * 6);

    var arcDist = 0.0;
    var prevNx = 0.0;
    var prevNy = 1.0;
    final invLast = 1.0 / (totalSamples - 1);
    final invRepeat = uvRepeatLength > 1e-4 ? 1.0 / uvRepeatLength : 1.0;

    for (var i = 0; i < totalSamples; i++) {
      final px = spineX[i];
      final py = spineY[i];
      if (i > 0) {
        final dx = px - spineX[i - 1];
        final dy = py - spineY[i - 1];
        arcDist += math.sqrt(dx * dx + dy * dy);
      }

      final double tx;
      final double ty;
      if (i == 0) {
        tx = spineX[1] - px;
        ty = spineY[1] - py;
      } else if (i == totalSamples - 1) {
        tx = px - spineX[i - 1];
        ty = py - spineY[i - 1];
      } else {
        tx = spineX[i + 1] - spineX[i - 1];
        ty = spineY[i + 1] - spineY[i - 1];
      }

      final len = math.sqrt(tx * tx + ty * ty);
      final double nx;
      final double ny;
      if (len > 1e-5) {
        nx = -ty / len;
        ny = tx / len;
        prevNx = nx;
        prevNy = ny;
      } else {
        nx = prevNx;
        ny = prevNy;
      }

      final frac = i * invLast;
      final halfW = (startWidth + (finalEndWidth - startWidth) * frac) * 0.5;
      final ca = startColor.a + (finalEndColor.a - startColor.a) * frac;
      final cr = startColor.r + (finalEndColor.r - startColor.r) * frac;
      final cg = startColor.g + (finalEndColor.g - startColor.g) * frac;
      final cb = startColor.b + (finalEndColor.b - startColor.b) * frac;
      final argb =
          ((ca * 255.0).round().clamp(0, 255) << 24) |
          ((cr * 255.0).round().clamp(0, 255) << 16) |
          ((cg * 255.0).round().clamp(0, 255) << 8) |
          (cb * 255.0).round().clamp(0, 255);

      final vBase = i * 4;
      positions[vBase] = px + nx * halfW;
      positions[vBase + 1] = py + ny * halfW;
      positions[vBase + 2] = px - nx * halfW;
      positions[vBase + 3] = py - ny * halfW;

      final uCoord = arcDist * invRepeat * textureWidth;
      uvs[vBase] = uCoord;
      uvs[vBase + 1] = 0.0;
      uvs[vBase + 2] = uCoord;
      uvs[vBase + 3] = textureHeight;

      colors[i * 2] = argb;
      colors[i * 2 + 1] = argb;
    }

    var idxCursor = 0;
    for (var i = 0; i < totalSamples - 1; i++) {
      final b = i * 2;
      indices[idxCursor++] = b;
      indices[idxCursor++] = b + 1;
      indices[idxCursor++] = b + 2;
      indices[idxCursor++] = b + 1;
      indices[idxCursor++] = b + 3;
      indices[idxCursor++] = b + 2;
    }

    return SplineStripMesh2D._(
      positions: positions,
      uvs: uvs,
      colors: colors,
      indices: indices,
      sampleCount: totalSamples,
    );
  }

  static final Paint _sharedPaint = Paint()..isAntiAlias = true;

  /// Draws this strip onto [canvas] in 1 `Canvas.drawVertices` call.
  void render(
    Canvas canvas, {
    ui.Shader? shader,
    ui.BlendMode blendMode = ui.BlendMode.srcOver,
  }) {
    if (sampleCount < 2) {
      return;
    }
    _sharedPaint.shader = shader;
    final vertices = ui.Vertices.raw(
      ui.VertexMode.triangles,
      positions,
      textureCoordinates: shader != null ? uvs : null,
      colors: colors,
      indices: indices,
    );
    canvas.drawVertices(
      vertices,
      shader != null ? ui.BlendMode.modulate : blendMode,
      _sharedPaint,
    );
    vertices.dispose();
    _sharedPaint.shader = null;
  }
}
