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
