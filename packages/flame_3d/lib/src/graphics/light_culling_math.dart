import 'dart:math' as math;

import 'package:meta/meta.dart';

/// Algebraic spotlight cone vs sphere intersection test equivalent to
/// `outer + asin(r/d) + 1e-3`, avoiding per-cell `sqrt`, `asin`, and `cos`.
@internal
@pragma('vm:prefer-inline')
bool coneIntersectsSphereFast(
  double x,
  double y,
  double z,
  double ax,
  double ay,
  double az,
  double outerEps,
  double sinA,
  double cosA,
  double cosA2,
  double sinA2,
  double cx,
  double cy,
  double cz,
  double radius,
) {
  final vx = cx - x;
  final vy = cy - y;
  final vz = cz - z;
  final d2 = vx * vx + vy * vy + vz * vz;
  final r2 = radius * radius;
  if (d2 <= r2 || outerEps >= math.pi) {
    return true;
  }
  final axisDot = vx * ax + vy * ay + vz * az;
  final rhs = axisDot + radius * sinA;
  if (cosA >= 0) {
    return rhs >= 0 && rhs * rhs >= cosA2 * (d2 - r2);
  }
  if (r2 >= d2 * sinA2 || rhs >= 0) {
    return true;
  }
  return rhs * rhs <= cosA2 * (d2 - r2);
}

/// Tests whether a sphere centered at `([x], [y], [z])` with squared radius
/// [rSq] intersects `[minX..maxX] x [minY..maxY] x [minZ..maxZ]`.
@internal
@pragma('vm:prefer-inline')
bool sphereIntersectsAabb(
  double x,
  double y,
  double z,
  double rSq,
  double minX,
  double minY,
  double minZ,
  double maxX,
  double maxY,
  double maxZ,
) {
  final qx = x < minX ? minX - x : (x > maxX ? x - maxX : 0.0);
  final qy = y < minY ? minY - y : (y > maxY ? y - maxY : 0.0);
  final qz = z < minZ ? minZ - z : (z > maxZ ? z - maxZ : 0.0);
  return qx * qx + qy * qy + qz * qz <= rSq;
}
