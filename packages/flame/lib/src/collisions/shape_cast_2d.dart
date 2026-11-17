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

  /// How deep the shape was inside the obstacle before it moved, along
  /// [normal]. It is `0` unless the cast started in overlap (`toi == 0`), in
  /// which case moving the shape by `normal * penetration` separates the two.
  double penetration = 0.0;

  /// Optional obstacle tag/reference attached by the caller.
  Object? collider;
}

/// Continuous Collision Detection (`CCD`) swept shape-casting solvers
/// preventing fast projectiles, dice, or tokens from tunneling through thin
/// walls.
///
/// An impact is the moment the moving shape starts to overlap the obstacle.
/// Shapes that only touch do not overlap, so a shape that starts in contact
/// with an obstacle and moves away from it or slides along it is not
/// reported, while one that starts in contact and moves into the obstacle is
/// reported with `toi == 0` and the normal of the touched surface.
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
    out.penetration = 0.0;
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
        ..penetration = initialManifold.depth
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
    if (cornerT == null) {
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
    out.penetration = 0.0;
    final initialManifold = _scratchManifold;
    if (CollisionManifold2D.rectVsRect(
      rectA: movingRect,
      rectB: obstacleRect,
      out: initialManifold,
    )) {
      out
        ..toi = 0.0
        ..penetration = initialManifold.depth
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

  /// The time in `[0, 1]` at which the point `origin + delta * t` enters the
  /// interior of [box], with the normal of the side it enters through, or
  /// `null` when it never gets inside.
  ///
  /// The sides themselves are not part of the interior: a point that runs
  /// along a side, touches a corner, or starts on a side and moves outwards
  /// does not enter. A point that starts on a side and moves inwards enters at
  /// `t == 0`, and so does one that starts inside.
  static (double, double, double)? _rayVsAabb(
    Vector2 origin,
    Vector2 delta,
    Rect box,
  ) {
    // The point is inside the box for t in (tEnter, tExit).
    var tEnter = double.negativeInfinity;
    var tExit = double.infinity;
    var nx = 0.0;
    var ny = 0.0;

    if (delta.x.abs() < 1e-12) {
      if (origin.x <= box.left || origin.x >= box.right) {
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
      if (t1 > tEnter) {
        tEnter = t1;
        nx = nSign;
        ny = 0.0;
      }
      if (t2 < tExit) {
        tExit = t2;
      }
    }

    if (delta.y.abs() < 1e-12) {
      if (origin.y <= box.top || origin.y >= box.bottom) {
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
      if (t1 > tEnter) {
        tEnter = t1;
        nx = 0.0;
        ny = nSign;
      }
      if (t2 < tExit) {
        tExit = t2;
      }
    }

    final toi = math.max(tEnter, 0.0);
    // A positive comparison, so that a NaN is rejected.
    if (!(tExit > toi) || toi > 1.0) {
      return null;
    }
    return (toi, nx, ny);
  }

  /// The time in `[0, 1]` at which the point `(ox, oy) + (dx, dy) * t` enters
  /// the interior of the circle, or `null` when it never gets inside. A point
  /// that only touches the circle does not enter it.
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
    if (!(disc > 0.0) || a <= 1e-12) {
      return null;
    }
    final root = math.sqrt(disc);
    final tEnter = (-b - root) / (2.0 * a);
    final tExit = (-b + root) / (2.0 * a);
    final toi = math.max(tEnter, 0.0);
    return (tExit > toi && toi <= 1.0) ? toi : null;
  }
}
