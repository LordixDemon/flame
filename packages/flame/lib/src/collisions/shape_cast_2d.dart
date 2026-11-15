import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'package:flame/src/collisions/collision_manifold_2d.dart';
import 'package:vector_math/vector_math.dart';

/// Result of a continuous collision detection (`CCD`) swept shape cast.
class ShapeCastHit2D() {
  /// Normalized Time of Impact (`0.0 .. 1.0`) along the motion delta vector.
  double toi = 1.0;

  /// Outward surface normal at impact.
  final Vector2 normal = Vector2.zero();

  /// Contact point on the obstacle surface.
  final Vector2 point = Vector2.zero();

  /// Optional obstacle tag/reference attached by the caller.
  Object? collider;
}

/// Continuous Collision Detection (`CCD`) swept shape-casting solvers
/// preventing fast projectiles, dice, or tokens from tunneling through thin
/// walls.
abstract final class ShapeCast2D._() {
  /// Sweeps a circle (`startCenter`, `radius`) along `delta` against static
  /// axis-aligned [obstacleRect] via exact Minkowski-expanded rounded-box ray
  /// intersection, writing into [out] and returning `true` on impact within
  /// `t in [0, 1]`.
  static bool sweepCircleVsRect({
    required Vector2 startCenter,
    required double radius,
    required Vector2 delta,
    required Rect obstacleRect,
    required ShapeCastHit2D out,
    Object? collider,
  }) {
    // Handle initial overlap at t = 0.
    final initialManifold = _scratchManifold;
    if (CollisionManifold2D.circleVsRect(
      circleCenter: startCenter,
      radius: radius,
      rectB: obstacleRect,
      out: initialManifold,
    )) {
      out
        ..toi = 0.0
        ..collider = collider;
      out.normal.setFrom(initialManifold.normal);
      out.point.setFrom(initialManifold.contactPoint);
      return true;
    }

    if (delta.x == 0.0 && delta.y == 0.0) {
      return false;
    }

    // Broadphase slab test against Minkowski-expanded AABB.
    final expanded = obstacleRect.inflate(radius);
    final slabHit = _rayVsAabb(startCenter, delta, expanded);
    if (slabHit == null) {
      return false;
    }
    final (slabT, slabNx, slabNy) = slabHit;
    final hitX = startCenter.x + delta.x * slabT;
    final hitY = startCenter.y + delta.y * slabT;

    // Within flat Voronoi face (not rounded corner), slabT is exact.
    final inHorizSpan = hitX >= obstacleRect.left && hitX <= obstacleRect.right;
    final inVertSpan = hitY >= obstacleRect.top && hitY <= obstacleRect.bottom;
    if (inHorizSpan || inVertSpan) {
      out
        ..toi = slabT
        ..collider = collider;
      out.normal.setValues(slabNx, slabNy);
      out.point.setValues(
        hitX - slabNx * radius,
        hitY - slabNy * radius,
      );
      return true;
    }

    // Otherwise intersect ray against the nearest corner circle of radius `R`.
    final cornerX = hitX < obstacleRect.left
        ? obstacleRect.left
        : obstacleRect.right;
    final cornerY = hitY < obstacleRect.top
        ? obstacleRect.top
        : obstacleRect.bottom;
    final cornerT = _rayVsCircle(
      startCenter.x,
      startCenter.y,
      delta.x,
      delta.y,
      cornerX,
      cornerY,
      radius,
    );
    if (cornerT == null || cornerT < 0.0 || cornerT > 1.0) {
      return false;
    }
    final cxAtHit = startCenter.x + delta.x * cornerT;
    final cyAtHit = startCenter.y + delta.y * cornerT;
    var nx = cxAtHit - cornerX;
    var ny = cyAtHit - cornerY;
    final nLen = math.sqrt(nx * nx + ny * ny);
    if (nLen > 1e-8) {
      nx /= nLen;
      ny /= nLen;
    } else {
      nx = slabNx;
      ny = slabNy;
    }
    out
      ..toi = cornerT
      ..collider = collider;
    out.normal.setValues(nx, ny);
    out.point.setValues(cornerX, cornerY);
    return true;
  }

  /// Sweeps a moving axis-aligned box (`movingRect`) along `delta` against
  /// static `obstacleRect` using exact Minkowski-sum ray-slab intersection.
  static bool sweepRectVsRect({
    required Rect movingRect,
    required Vector2 delta,
    required Rect obstacleRect,
    required ShapeCastHit2D out,
    Object? collider,
  }) {
    final initialManifold = _scratchManifold;
    if (CollisionManifold2D.rectVsRect(
      rectA: movingRect,
      rectB: obstacleRect,
      out: initialManifold,
    )) {
      out
        ..toi = 0.0
        ..collider = collider;
      out.normal.setFrom(initialManifold.normal);
      out.point.setFrom(initialManifold.contactPoint);
      return true;
    }

    if (delta.x == 0.0 && delta.y == 0.0) {
      return false;
    }

    final halfW = movingRect.width * 0.5;
    final halfH = movingRect.height * 0.5;
    final origin = _scratchOrigin
      ..setValues(
        movingRect.left + halfW,
        movingRect.top + halfH,
      );
    final minkowski = Rect.fromLTRB(
      obstacleRect.left - halfW,
      obstacleRect.top - halfH,
      obstacleRect.right + halfW,
      obstacleRect.bottom + halfH,
    );
    final slab = _rayVsAabb(origin, delta, minkowski);
    if (slab == null) {
      return false;
    }
    final (t, nx, ny) = slab;
    out
      ..toi = t
      ..collider = collider;
    out.normal.setValues(nx, ny);
    out.point.setValues(
      (origin.x + delta.x * t - nx * halfW).clamp(
        obstacleRect.left,
        obstacleRect.right,
      ),
      (origin.y + delta.y * t - ny * halfH).clamp(
        obstacleRect.top,
        obstacleRect.bottom,
      ),
    );
    return true;
  }

  static final CollisionManifold2D _scratchManifold = CollisionManifold2D();
  static final Vector2 _scratchOrigin = Vector2.zero();

  static (double, double, double)? _rayVsAabb(
    Vector2 origin,
    Vector2 delta,
    Rect box,
  ) {
    var tMin = 0.0;
    var tMax = 1.0;
    var nx = 0.0;
    var ny = 0.0;

    if (delta.x.abs() < 1e-12) {
      if (origin.x < box.left || origin.x > box.right) {
        return null;
      }
    } else {
      final invX = 1.0 / delta.x;
      var t1 = (box.left - origin.x) * invX;
      var t2 = (box.right - origin.x) * invX;
      var nSign = -1.0;
      if (t1 > t2) {
        final tmp = t1;
        t1 = t2;
        t2 = tmp;
        nSign = 1.0;
      }
      if (t1 > tMin) {
        tMin = t1;
        nx = nSign;
        ny = 0.0;
      }
      if (t2 < tMax) {
        tMax = t2;
      }
      if (tMin > tMax) {
        return null;
      }
    }

    if (delta.y.abs() < 1e-12) {
      if (origin.y < box.top || origin.y > box.bottom) {
        return null;
      }
    } else {
      final invY = 1.0 / delta.y;
      var t1 = (box.top - origin.y) * invY;
      var t2 = (box.bottom - origin.y) * invY;
      var nSign = -1.0;
      if (t1 > t2) {
        final tmp = t1;
        t1 = t2;
        t2 = tmp;
        nSign = 1.0;
      }
      if (t1 > tMin) {
        tMin = t1;
        nx = 0.0;
        ny = nSign;
      }
      if (t2 < tMax) {
        tMax = t2;
      }
      if (tMin > tMax) {
        return null;
      }
    }

    if (tMin < 0.0 || tMin > 1.0) {
      return null;
    }
    return (tMin, nx, ny);
  }

  static double? _rayVsCircle(
    double ox,
    double oy,
    double dx,
    double dy,
    double cx,
    double cy,
    double r,
  ) {
    final fx = ox - cx;
    final fy = oy - cy;
    final a = dx * dx + dy * dy;
    final b = 2.0 * (fx * dx + fy * dy);
    final c = fx * fx + fy * fy - r * r;
    final disc = b * b - 4.0 * a * c;
    if (disc < 0.0 || a <= 1e-12) {
      return null;
    }
    final t = (-b - math.sqrt(disc)) / (2.0 * a);
    return (t >= 0.0 && t <= 1.0) ? t : null;
  }
}
