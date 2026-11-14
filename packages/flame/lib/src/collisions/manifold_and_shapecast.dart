import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'package:vector_math/vector_math.dart';

/// Mutable zero-allocation penetration manifold holding the Minimum Translation
/// Vector (`normal * depth`) pushing shape A out of shape B, plus the world
/// `contactPoint`.
class CollisionManifold2D() {
  /// Unit push-out normal pointing from obstacle B toward moving shape A.
  final Vector2 normal = Vector2.zero();

  /// Non-negative penetration depth along [normal].
  double depth = 0.0;

  /// Representative contact point in world space.
  final Vector2 contactPoint = Vector2.zero();

  /// Writes `normal * depth` into [out].
  void writeMtv(Vector2 out) {
    out.setValues(normal.x * depth, normal.y * depth);
  }

  /// Analytical circle-vs-circle penetration manifold (`true` on overlap).
  static bool circleVsCircle({
    required Vector2 centerA,
    required double radiusA,
    required Vector2 centerB,
    required double radiusB,
    required CollisionManifold2D out,
  }) {
    final dx = centerA.x - centerB.x;
    final dy = centerA.y - centerB.y;
    final rSum = radiusA + radiusB;
    final distSq = dx * dx + dy * dy;
    if (distSq >= rSum * rSum) {
      out.depth = 0.0;
      return false;
    }
    final dist = math.sqrt(distSq);
    if (dist > 1e-8) {
      out.normal.setValues(dx / dist, dy / dist);
      out.depth = rSum - dist;
    } else {
      out.normal.setValues(0.0, -1.0);
      out.depth = rSum;
    }
    out.contactPoint.setValues(
      centerB.x + out.normal.x * radiusB,
      centerB.y + out.normal.y * radiusB,
    );
    return true;
  }

  /// Analytical circle-vs-AABB ([Rect]) penetration manifold (`true` when
  /// overlapping, including full circle-center containment inside [rectB]).
  static bool circleVsRect({
    required Vector2 circleCenter,
    required double radius,
    required Rect rectB,
    required CollisionManifold2D out,
  }) {
    final cx = circleCenter.x;
    final cy = circleCenter.y;
    final closestX = cx.clamp(rectB.left, rectB.right);
    final closestY = cy.clamp(rectB.top, rectB.bottom);

    final dx = cx - closestX;
    final dy = cy - closestY;
    final distSq = dx * dx + dy * dy;

    if (distSq > radius * radius) {
      out.depth = 0.0;
      return false;
    }

    // Center strictly outside the rectangle: push along (center - closest).
    if (distSq > 1e-10) {
      final dist = math.sqrt(distSq);
      out.normal.setValues(dx / dist, dy / dist);
      out.depth = radius - dist;
      out.contactPoint.setValues(closestX, closestY);
      return true;
    }

    // Circle center is inside or right on the edge of rectB: find nearest face.
    final dLeft = cx - rectB.left;
    final dRight = rectB.right - cx;
    final dTop = cy - rectB.top;
    final dBottom = rectB.bottom - cy;

    var minPen = dLeft;
    out.normal.setValues(-1.0, 0.0);
    out.contactPoint.setValues(rectB.left, cy);

    if (dRight < minPen) {
      minPen = dRight;
      out.normal.setValues(1.0, 0.0);
      out.contactPoint.setValues(rectB.right, cy);
    }
    if (dTop < minPen) {
      minPen = dTop;
      out.normal.setValues(0.0, -1.0);
      out.contactPoint.setValues(cx, rectB.top);
    }
    if (dBottom < minPen) {
      minPen = dBottom;
      out.normal.setValues(0.0, 1.0);
      out.contactPoint.setValues(cx, rectB.bottom);
    }

    out.depth = radius + minPen;
    return true;
  }

  /// Analytical AABB-vs-AABB penetration manifold (`true` when overlapping).
  static bool rectVsRect({
    required Rect rectA,
    required Rect rectB,
    required CollisionManifold2D out,
  }) {
    final overlapX =
        math.min(rectA.right, rectB.right) - math.max(rectA.left, rectB.left);
    if (overlapX <= 0.0) {
      out.depth = 0.0;
      return false;
    }
    final overlapY =
        math.min(rectA.bottom, rectB.bottom) - math.max(rectA.top, rectB.top);
    if (overlapY <= 0.0) {
      out.depth = 0.0;
      return false;
    }

    final centerAx = (rectA.left + rectA.right) * 0.5;
    final centerAy = (rectA.top + rectA.bottom) * 0.5;
    final centerBx = (rectB.left + rectB.right) * 0.5;
    final centerBy = (rectB.top + rectB.bottom) * 0.5;

    if (overlapX < overlapY) {
      final sign = centerAx < centerBx ? -1.0 : 1.0;
      out.normal.setValues(sign, 0.0);
      out.depth = overlapX;
      out.contactPoint.setValues(
        sign < 0 ? rectB.left : rectB.right,
        centerAy.clamp(rectB.top, rectB.bottom),
      );
    } else {
      final sign = centerAy < centerBy ? -1.0 : 1.0;
      out.normal.setValues(0.0, sign);
      out.depth = overlapY;
      out.contactPoint.setValues(
        centerAx.clamp(rectB.left, rectB.right),
        sign < 0 ? rectB.top : rectB.bottom,
      );
    }
    return true;
  }
}

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
