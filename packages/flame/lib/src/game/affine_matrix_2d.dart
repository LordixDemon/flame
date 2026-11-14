import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/src/game/transform2d.dart';
import 'package:vector_math/vector_math.dart';

/// Compact, zero-allocation 2D affine transformation matrix
/// (`[m00, m10, tx; m01, m11, ty; 0, 0, 1]`) used to cache hierarchical world
/// transforms on `PositionComponent`s without heap allocations or repeated
/// ancestor tree walks.
///
/// Column-major naming matches `Matrix4.storage`:
/// - `x' = m00 * x + m10 * y + tx` (`storage[0]`, `storage[4]`, `storage[12]`)
/// - `y' = m01 * x + m11 * y + ty` (`storage[1]`, `storage[5]`, `storage[13]`)
class AffineMatrix2D() {
  /// X-axis X component (`storage[0]`).
  double m00 = 1.0;

  /// X-axis Y component (`storage[1]`).
  double m01 = 0.0;

  /// Y-axis X component (`storage[4]`).
  double m10 = 0.0;

  /// Y-axis Y component (`storage[5]`).
  double m11 = 1.0;

  /// Translation X (`storage[12]`).
  double tx = 0.0;

  /// Translation Y (`storage[13]`).
  double ty = 0.0;

  /// Resets this matrix to the 2D identity transform.
  void setIdentity() {
    m00 = 1.0;
    m01 = 0.0;
    m10 = 0.0;
    m11 = 1.0;
    tx = 0.0;
    ty = 0.0;
  }

  /// Copies all 6 affine coefficients from [other].
  void setFrom(AffineMatrix2D other) {
    m00 = other.m00;
    m01 = other.m01;
    m10 = other.m10;
    m11 = other.m11;
    tx = other.tx;
    ty = other.ty;
  }

  /// Loads the 2D affine entries directly from [transform].
  void setFromTransform2D(Transform2D transform) {
    final s = transform.transformMatrix.storage;
    m00 = s[0];
    m01 = s[1];
    m10 = s[4];
    m11 = s[5];
    tx = s[12];
    ty = s[13];
  }

  /// Sets `this = parent * local` (safe even when `parent` is `this`).
  void setMultiplyTransform2D(AffineMatrix2D parent, Transform2D local) {
    final ls = local.transformMatrix.storage;
    final l00 = ls[0];
    final l01 = ls[1];
    final l10 = ls[4];
    final l11 = ls[5];
    final ltx = ls[12];
    final lty = ls[13];

    final p00 = parent.m00;
    final p01 = parent.m01;
    final p10 = parent.m10;
    final p11 = parent.m11;
    final ptx = parent.tx;
    final pty = parent.ty;

    m00 = p00 * l00 + p10 * l01;
    m01 = p01 * l00 + p11 * l01;
    m10 = p00 * l10 + p10 * l11;
    m11 = p01 * l10 + p11 * l11;
    tx = p00 * ltx + p10 * lty + ptx;
    ty = p01 * ltx + p11 * lty + pty;
  }

  /// Determinant `m00 * m11 - m01 * m10`.
  double get determinant => m00 * m11 - m01 * m10;

  /// Transforms local `(x, y)` into world X.
  @pragma('vm:prefer-inline')
  double transformX(double x, double y) => m00 * x + m10 * y + tx;

  /// Transforms local `(x, y)` into world Y.
  @pragma('vm:prefer-inline')
  double transformY(double x, double y) => m01 * x + m11 * y + ty;

  /// Transforms local `(x, y)` into a world `(wx, wy)` record with zero heap
  /// allocations.
  @pragma('vm:prefer-inline')
  (double x, double y) transformXY(double x, double y) =>
      (m00 * x + m10 * y + tx, m01 * x + m11 * y + ty);

  /// Transforms local [point] into world coordinates, writing into [output]
  /// when provided to avoid heap allocation.
  Vector2 transformPoint(Vector2 point, {Vector2? output}) {
    final px = point.x;
    final py = point.y;
    final wx = m00 * px + m10 * py + tx;
    final wy = m01 * px + m11 * py + ty;
    return (output?..setValues(wx, wy)) ?? Vector2(wx, wy);
  }

  /// Transforms world [point] into local coordinates via analytical `2x2`
  /// inversion (returns `(0, 0)` when degenerate `determinant == 0`).
  Vector2 inverseTransformPoint(Vector2 point, {Vector2? output}) {
    final det = m00 * m11 - m01 * m10;
    if (det.abs() <= 1e-15) {
      return (output?..setZero()) ?? Vector2.zero();
    }
    final invDet = 1.0 / det;
    final dx = point.x - tx;
    final dy = point.y - ty;
    final lx = (dx * m11 - dy * m10) * invDet;
    final ly = (dy * m00 - dx * m01) * invDet;
    return (output?..setValues(lx, ly)) ?? Vector2(lx, ly);
  }

  /// Projects a local rectangle `[0..width] × [0..height]` into its tightest
  /// world-space axis-aligned [Rect] with zero intermediate `Vector2` or `List`
  /// allocations.
  Rect transformSizeToAabb(double width, double height) {
    final x0 = tx;
    final y0 = ty;
    final x1 = m00 * width + tx;
    final y1 = m01 * width + ty;
    final x2 = m10 * height + tx;
    final y2 = m11 * height + ty;
    final x3 = x1 + m10 * height;
    final y3 = y1 + m11 * height;

    final minX = math.min(math.min(x0, x1), math.min(x2, x3));
    final maxX = math.max(math.max(x0, x1), math.max(x2, x3));
    final minY = math.min(math.min(y0, y1), math.min(y2, y3));
    final maxY = math.max(math.max(y0, y1), math.max(y2, y3));
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }
}
