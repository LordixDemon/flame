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
  ///
  /// A circle that only touches the rectangle from outside does not overlap
  /// it, like for [circleVsCircle] and [rectVsRect].
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

    // Center strictly outside the rectangle: push along (center - closest).
    if (distSq > 1e-10) {
      if (distSq >= radius * radius) {
        out.depth = 0.0;
        return false;
      }
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
  ///
  /// `normal * depth` is the minimum translation vector: the shortest move
  /// of [rectA] along one axis after which it no longer overlaps [rectB]. That
  /// also holds when one rectangle spans the other on an axis (a wide body
  /// over a thin wall, a small body deep inside a large one), where the
  /// shortest way out is longer than the width of the overlapping area.
  static bool rectVsRect({
    required Rect rectA,
    required Rect rectB,
    required CollisionManifold2D out,
  }) {
    // How far A has to move in each direction to clear B.
    final pushLeft = rectA.right - rectB.left;
    final pushRight = rectB.right - rectA.left;
    if (pushLeft <= 0.0 || pushRight <= 0.0) {
      out.depth = 0.0;
      return false;
    }
    final pushUp = rectA.bottom - rectB.top;
    final pushDown = rectB.bottom - rectA.top;
    if (pushUp <= 0.0 || pushDown <= 0.0) {
      out.depth = 0.0;
      return false;
    }

    final centerAx = (rectA.left + rectA.right) * 0.5;
    final centerAy = (rectA.top + rectA.bottom) * 0.5;

    // On each axis the nearer side wins, which is the side that the center of
    // A is on; with the centers aligned it is the positive direction.
    final depthX = math.min(pushLeft, pushRight);
    final depthY = math.min(pushUp, pushDown);

    if (depthX < depthY) {
      final sign = pushLeft < pushRight ? -1.0 : 1.0;
      out.normal.setValues(sign, 0.0);
      out.depth = depthX;
      out.contactPoint.setValues(
        sign < 0 ? rectB.left : rectB.right,
        centerAy.clamp(rectB.top, rectB.bottom),
      );
    } else {
      final sign = pushUp < pushDown ? -1.0 : 1.0;
      out.normal.setValues(0.0, sign);
      out.depth = depthY;
      out.contactPoint.setValues(
        centerAx.clamp(rectB.left, rectB.right),
        sign < 0 ? rectB.top : rectB.bottom,
      );
    }
    return true;
  }
}
