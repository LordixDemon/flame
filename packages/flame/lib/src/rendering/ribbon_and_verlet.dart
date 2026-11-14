import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/components.dart';
import 'package:flutter/painting.dart';

/// Zero-allocation Struct-of-Arrays 2D ribbon trail component rendered in a
/// single `Canvas.drawVertices` call.
///
/// Ideal for sword slashes, projectile streaks, vehicle skidmarks, magic
/// ribbons, and board token motion trails.
class RibbonTrailComponent({
  final int maxPoints = 32,
  var double lifetime = 0.35,
  var double startWidth = 14.0,
  var double endWidth = 0.0,
  var Color startColor = const Color(0xFFFFFFFF),
  var Color endColor = const Color(0x00FFFFFF),
  var double minPointDistance = 3.0,
  var ui.BlendMode blendMode = ui.BlendMode.srcOver,
  var Vector2 Function()? targetProvider,
  super.priority,
  super.key,
}) extends Component {
  this
    : assert(maxPoints >= 2, 'maxPoints must be at least 2'),
      assert(lifetime > 0, 'lifetime must be positive');

  /// Optional shader (such as an `ImageShader`) mapped across ribbon UVs.
  ui.Shader? shader;

  /// Texture pixel width used to scale normalized `U` (`0..1`) coordinates.
  double textureWidth = 1.0;

  /// Texture pixel height used to scale normalized `V` (`0..1`) coordinates.
  double textureHeight = 1.0;

  final Float32List _ptX = Float32List(maxPoints);
  final Float32List _ptY = Float32List(maxPoints);
  final Float32List _ptAge = Float32List(maxPoints);
  final Float32List _vertPositions = Float32List(maxPoints * 4);
  final Float32List _vertUvs = Float32List(maxPoints * 4);
  final Int32List _vertColors = Int32List(maxPoints * 2);
  final Uint16List _indices = _buildStripIndices(maxPoints);
  final Paint _paint = Paint()..isAntiAlias = true;

  int _head = 0; // oldest index
  int _count = 0;

  /// Number of active points currently in the trail.
  int get pointCount => _count;

  static Uint16List _buildStripIndices(int maxPts) {
    final segs = maxPts - 1;
    final out = Uint16List(segs * 6);
    var k = 0;
    for (var i = 0; i < segs; i++) {
      final b = i * 2;
      out[k++] = b;
      out[k++] = b + 1;
      out[k++] = b + 2;
      out[k++] = b + 1;
      out[k++] = b + 3;
      out[k++] = b + 2;
    }
    return out;
  }

  /// Clears all active points immediately.
  void clear() {
    _head = 0;
    _count = 0;
  }

  /// Appends `(x, y)` to the trail head if farther than [minPointDistance]
  /// (unless [force] is `true`).
  void addPointXY(double x, double y, {bool force = false}) {
    if (_count > 0 && !force) {
      final newestIdx = (_head + _count - 1) % maxPoints;
      final dx = x - _ptX[newestIdx];
      final dy = y - _ptY[newestIdx];
      if (dx * dx + dy * dy < minPointDistance * minPointDistance) {
        return;
      }
    }
    if (_count == maxPoints) {
      // Overwrite oldest slot and advance head.
      _ptX[_head] = x;
      _ptY[_head] = y;
      _ptAge[_head] = 0.0;
      _head = (_head + 1) % maxPoints;
    } else {
      final slot = (_head + _count) % maxPoints;
      _ptX[slot] = x;
      _ptY[slot] = y;
      _ptAge[slot] = 0.0;
      _count++;
    }
  }

  /// Convenience wrapper for [addPointXY].
  void addPoint(Vector2 position, {bool force = false}) =>
      addPointXY(position.x, position.y, force: force);

  @override
  void update(double dt) {
    for (var i = 0; i < _count; i++) {
      final idx = (_head + i) % maxPoints;
      _ptAge[idx] += dt;
    }
    while (_count > 0 && _ptAge[_head] >= lifetime) {
      _head = (_head + 1) % maxPoints;
      _count--;
    }

    final provider = targetProvider;
    if (provider != null) {
      final p = provider();
      addPointXY(p.x, p.y);
    }
  }

  @override
  void render(Canvas canvas) {
    if (_count < 2) {
      return;
    }

    final n = _count;
    final invLast = 1.0 / (n - 1);
    final sA = startColor.a;
    final sR = startColor.r;
    final sG = startColor.g;
    final sB = startColor.b;
    final eA = endColor.a;
    final eR = endColor.r;
    final eG = endColor.g;
    final eB = endColor.b;

    var prevNx = 0.0;
    var prevNy = 1.0;

    // Iterate from newest (i = 0 => newest) to oldest (i = n - 1 => tail).
    for (var i = 0; i < n; i++) {
      final ringIdx = (_head + (n - 1 - i)) % maxPoints;
      final px = _ptX[ringIdx];
      final py = _ptY[ringIdx];
      final ageRatio = (_ptAge[ringIdx] / lifetime).clamp(0.0, 1.0);
      final along = i * invLast;
      final t = math.max(ageRatio, along);

      double tx;
      double ty;
      if (i == 0) {
        final nextIdx = (_head + (n - 2)) % maxPoints;
        tx = px - _ptX[nextIdx];
        ty = py - _ptY[nextIdx];
      } else if (i == n - 1) {
        final prevIdx = (_head + 1) % maxPoints;
        tx = _ptX[prevIdx] - px;
        ty = _ptY[prevIdx] - py;
      } else {
        final prevIdx = (_head + (n - i)) % maxPoints;
        final nextIdx = (_head + (n - 2 - i)) % maxPoints;
        tx = _ptX[prevIdx] - _ptX[nextIdx];
        ty = _ptY[prevIdx] - _ptY[nextIdx];
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

      final halfW = (startWidth + (endWidth - startWidth) * t) * 0.5;
      final cr = sR + (eR - sR) * t;
      final cg = sG + (eG - sG) * t;
      final cb = sB + (eB - sB) * t;
      final ca = sA + (eA - sA) * t;
      final argb =
          ((ca * 255.0).round().clamp(0, 255) << 24) |
          ((cr * 255.0).round().clamp(0, 255) << 16) |
          ((cg * 255.0).round().clamp(0, 255) << 8) |
          (cb * 255.0).round().clamp(0, 255);

      final vBase = i * 4;
      _vertPositions[vBase] = px + nx * halfW;
      _vertPositions[vBase + 1] = py + ny * halfW;
      _vertPositions[vBase + 2] = px - nx * halfW;
      _vertPositions[vBase + 3] = py - ny * halfW;

      _vertUvs[vBase] = along * textureWidth;
      _vertUvs[vBase + 1] = 0.0;
      _vertUvs[vBase + 2] = along * textureWidth;
      _vertUvs[vBase + 3] = textureHeight;

      final cBase = i * 2;
      _vertColors[cBase] = argb;
      _vertColors[cBase + 1] = argb;
    }

    final useShader = shader != null;
    _paint.shader = shader;

    final vertCount = n * 2;
    final idxCount = (n - 1) * 6;
    final vertices = ui.Vertices.raw(
      ui.VertexMode.triangles,
      Float32List.sublistView(_vertPositions, 0, vertCount * 2),
      textureCoordinates: useShader
          ? Float32List.sublistView(_vertUvs, 0, vertCount * 2)
          : null,
      colors: Int32List.sublistView(_vertColors, 0, vertCount),
      indices: Uint16List.sublistView(_indices, 0, idxCount),
    );
    canvas.drawVertices(
      vertices,
      useShader ? ui.BlendMode.modulate : blendMode,
      _paint,
    );
    vertices.dispose();
    _paint.shader = null;
  }
}

/// Procedural Catmull-Rom 2D spline strip tessellator for roads, rivers,
/// laser beams, cables, and path previews.
class SplineStripMesh2D._({
  required final Float32List positions,
  required final Float32List uvs,
  required final Int32List colors,
  required final Uint16List indices,
  required final int sampleCount,
}) {
  /// Builds a tessellated triangle strip along [controlPoints] with
  /// [subdivisionsPerSegment] samples per span.
  factory SplineStripMesh2D.fromCatmullRom({
    required List<Vector2> controlPoints,
    int subdivisionsPerSegment = 8,
    double startWidth = 16.0,
    double? endWidth,
    Color startColor = const Color(0xFFFFFFFF),
    Color? endColor,
    double tension = 0.5,
    double uvRepeatLength = 64.0,
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

    final subs = math.max(1, subdivisionsPerSegment);
    final spans = controlPoints.length - 1;
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

      final uCoord = arcDist * invRepeat;
      uvs[vBase] = uCoord;
      uvs[vBase + 1] = 0.0;
      uvs[vBase + 2] = uCoord;
      uvs[vBase + 3] = 1.0;

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

/// Zero-allocation Struct-of-Arrays 2D Verlet rope, chain, banner, or tether
/// simulation with iterative distance constraints.
class VerletRope2D({
  required final int nodeCount,
  required Vector2 start,
  Vector2? end,
  var double segmentLength = 12.0,
  var double gravityX = 0.0,
  var double gravityY = 680.0,
  var double damping = 0.985,
  var int constraintIterations = 8,
  bool pinStart = true,
  bool pinEnd = false,
}) {
  this : assert(nodeCount >= 2, 'nodeCount must be at least 2') {
    final targetEnd =
        end ?? Vector2(start.x, start.y + segmentLength * (nodeCount - 1));
    for (var i = 0; i < nodeCount; i++) {
      final t = i / (nodeCount - 1);
      final x = start.x + (targetEnd.x - start.x) * t;
      final y = start.y + (targetEnd.y - start.y) * t;
      posX[i] = x;
      posY[i] = y;
      prevX[i] = x;
      prevY[i] = y;
    }
    if (pinStart) {
      pinned[0] = 1;
    }
    if (pinEnd) {
      pinned[nodeCount - 1] = 1;
    }
  }

  /// Current X positions of each rope node.
  final Float32List posX = Float32List(nodeCount);

  /// Current Y positions of each rope node.
  final Float32List posY = Float32List(nodeCount);

  /// Previous X positions used for Verlet integration.
  final Float32List prevX = Float32List(nodeCount);

  /// Previous Y positions used for Verlet integration.
  final Float32List prevY = Float32List(nodeCount);

  /// Per-node pin mask (`1` = pinned/kinematic, `0` = dynamic).
  final Uint8List pinned = Uint8List(nodeCount);

  /// Pins [index] at `(x, y)` with zero velocity.
  void setNodePin(int index, double x, double y, {bool isPinned = true}) {
    posX[index] = x;
    posY[index] = y;
    prevX[index] = x;
    prevY[index] = y;
    pinned[index] = isPinned ? 1 : 0;
  }

  /// Advances Verlet integration and distance constraints by [dt] seconds.
  void step(double dt) {
    if (dt <= 0.0) {
      return;
    }
    final clampedDt = math.min(dt, 1.0 / 20.0);
    final dt2 = clampedDt * clampedDt;
    final damp = damping.clamp(0.0, 1.0);

    for (var i = 0; i < nodeCount; i++) {
      if (pinned[i] != 0) {
        continue;
      }
      final cx = posX[i];
      final cy = posY[i];
      final vx = (cx - prevX[i]) * damp;
      final vy = (cy - prevY[i]) * damp;
      prevX[i] = cx;
      prevY[i] = cy;
      posX[i] = cx + vx + gravityX * dt2;
      posY[i] = cy + vy + gravityY * dt2;
    }

    final iters = math.max(1, constraintIterations);
    for (var k = 0; k < iters; k++) {
      for (var i = 0; i < nodeCount - 1; i++) {
        final dx = posX[i + 1] - posX[i];
        final dy = posY[i + 1] - posY[i];
        final dist = math.sqrt(dx * dx + dy * dy);
        if (dist <= 1e-6) {
          continue;
        }
        final diff = (dist - segmentLength) / dist;
        final pA = pinned[i] != 0;
        final pB = pinned[i + 1] != 0;
        if (pA && pB) {
          continue;
        } else if (pA) {
          posX[i + 1] -= dx * diff;
          posY[i + 1] -= dy * diff;
        } else if (pB) {
          posX[i] += dx * diff;
          posY[i] += dy * diff;
        } else {
          final ox = dx * diff * 0.5;
          final oy = dy * diff * 0.5;
          posX[i] += ox;
          posY[i] += oy;
          posX[i + 1] -= ox;
          posY[i + 1] -= oy;
        }
      }
    }
  }
}
