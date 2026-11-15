import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/src/components/core/component.dart';
import 'package:flame/src/game/game.dart';
import 'package:flutter/painting.dart';
import 'package:vector_math/vector_math.dart';

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
    if (_count > 0) {
      Game.notifyVisualMutation();
    }
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
    Game.notifyVisualMutation();
  }

  /// Convenience wrapper for [addPointXY].
  void addPoint(Vector2 position, {bool force = false}) =>
      addPointXY(position.x, position.y, force: force);

  @override
  void update(double dt) {
    final hadPoints = _count > 0;
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
    if (hadPoints && dt > 0.0) {
      Game.notifyVisualMutation();
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
