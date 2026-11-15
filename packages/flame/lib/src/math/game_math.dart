import 'dart:math' as math;

import 'package:vector_math/vector_math.dart';

/// Mutable scalar velocity holder for zero-allocation [GameMath.smoothDamp]
/// and [GameMath.smoothDampAngle] calls.
class SmoothDampState({var double velocity = 0.0});

/// Fundamental game-mathematics utilities: critically damped springs
/// (`smoothDamp`), cubic splines, range remapping, and angle wrapping.
abstract final class GameMath._() {
  static const double _twoPi = math.pi * 2.0;

  /// Shortest signed angular difference in radians (`[-pi, +pi]`) from
  /// [currentRad] to [targetRad].
  static double deltaAngle(double currentRad, double targetRad) {
    var diff = (targetRad - currentRad) % _twoPi;
    if (diff > math.pi) {
      diff -= _twoPi;
    } else if (diff < -math.pi) {
      diff += _twoPi;
    }
    return diff;
  }

  /// Linearly maps [value] from `[a, b]` into `[0.0, 1.0]`.
  static double inverseLerp(double a, double b, double value) {
    final denom = b - a;
    if (denom.abs() <= 1e-12) {
      return 0.0;
    }
    return ((value - a) / denom).clamp(0.0, 1.0);
  }

  /// Remaps [value] from `[inMin, inMax]` to `[outMin, outMax]`, clamping when
  /// [clampResult] is `true`.
  static double remap(
    double value,
    double inMin,
    double inMax,
    double outMin,
    double outMax, {
    bool clampResult = false,
  }) {
    final denom = inMax - inMin;
    if (denom.abs() <= 1e-12) {
      return outMin;
    }
    var t = (value - inMin) / denom;
    if (clampResult) {
      t = t.clamp(0.0, 1.0);
    }
    return outMin + (outMax - outMin) * t;
  }

  /// Oscillates [t] smoothly back and forth within `[0, length]`.
  static double pingPong(double t, double length) {
    if (length <= 0.0) {
      return 0.0;
    }
    final wrapped = t % (length * 2.0);
    final positive = wrapped < 0.0 ? wrapped + length * 2.0 : wrapped;
    return length - (positive - length).abs();
  }

  /// Critically damped spring filter moving [current] toward [target] over
  /// approximately [smoothTime] seconds without overshoot, updating
  /// `state.velocity` in place.
  static double smoothDamp(
    double current,
    double target,
    SmoothDampState state,
    double smoothTime,
    double dt, {
    double maxSpeed = double.infinity,
  }) {
    if (dt <= 0.0) {
      return current;
    }
    final safeTime = math.max(0.0001, smoothTime);
    final omega = 2.0 / safeTime;
    final x = omega * dt;
    final exp = 1.0 / (1.0 + x + 0.48 * x * x + 0.235 * x * x * x);

    var change = current - target;
    final originalTo = target;

    final maxChange = maxSpeed * safeTime;
    if (maxChange.isFinite) {
      change = change.clamp(-maxChange, maxChange);
    }
    final clampedTarget = current - change;

    final temp = (state.velocity + omega * change) * dt;
    state.velocity = (state.velocity - omega * temp) * exp;
    var output = clampedTarget + (change + temp) * exp;

    if ((originalTo - current > 0.0) == (output > originalTo)) {
      output = originalTo;
      state.velocity = (output - originalTo) / dt;
    }
    return output;
  }

  /// Critically damped angular spring in radians handling `±pi` wrap-around.
  static double smoothDampAngle(
    double currentRad,
    double targetRad,
    SmoothDampState state,
    double smoothTime,
    double dt, {
    double maxSpeed = double.infinity,
  }) {
    final continuousTarget = currentRad + deltaAngle(currentRad, targetRad);
    return smoothDamp(
      currentRad,
      continuousTarget,
      state,
      smoothTime,
      dt,
      maxSpeed: maxSpeed,
    );
  }

  /// Zero-allocation 2D vector critically damped spring writing the updated
  /// position into [outPosition] and updating [inOutVelocity] in place.
  static void smoothDampVector2(
    Vector2 current,
    Vector2 target,
    Vector2 inOutVelocity,
    double smoothTime,
    double dt,
    Vector2 outPosition, {
    double maxSpeed = double.infinity,
  }) {
    if (dt <= 0.0) {
      outPosition.setFrom(current);
      return;
    }
    final safeTime = math.max(0.0001, smoothTime);
    final omega = 2.0 / safeTime;
    final x = omega * dt;
    final exp = 1.0 / (1.0 + x + 0.48 * x * x + 0.235 * x * x * x);

    var changeX = current.x - target.x;
    var changeY = current.y - target.y;
    final origTargetX = target.x;
    final origTargetY = target.y;

    final maxChange = maxSpeed * safeTime;
    if (maxChange.isFinite) {
      final sqDist = changeX * changeX + changeY * changeY;
      final maxChangeSq = maxChange * maxChange;
      if (sqDist > maxChangeSq && sqDist > 0.0) {
        final invDist = maxChange / math.sqrt(sqDist);
        changeX *= invDist;
        changeY *= invDist;
      }
    }

    final targetX = current.x - changeX;
    final targetY = current.y - changeY;

    final tempX = (inOutVelocity.x + omega * changeX) * dt;
    final tempY = (inOutVelocity.y + omega * changeY) * dt;

    inOutVelocity.setValues(
      (inOutVelocity.x - omega * tempX) * exp,
      (inOutVelocity.y - omega * tempY) * exp,
    );

    var outX = targetX + (changeX + tempX) * exp;
    var outY = targetY + (changeY + tempY) * exp;

    final origMinusCurrX = origTargetX - current.x;
    final origMinusCurrY = origTargetY - current.y;
    final outMinusOrigX = outX - origTargetX;
    final outMinusOrigY = outY - origTargetY;

    if (origMinusCurrX * outMinusOrigX + origMinusCurrY * outMinusOrigY > 0.0) {
      outX = origTargetX;
      outY = origTargetY;
      inOutVelocity.setZero();
    }
    outPosition.setValues(outX, outY);
  }

  /// Evaluates a 1D cubic Hermite spline at `t` in `[0, 1]`.
  static double hermite(
    double p0,
    double m0,
    double p1,
    double m1,
    double t,
  ) {
    final t2 = t * t;
    final t3 = t2 * t;
    final h00 = 2.0 * t3 - 3.0 * t2 + 1.0;
    final h10 = t3 - 2.0 * t2 + t;
    final h01 = -2.0 * t3 + 3.0 * t2;
    final h11 = t3 - t2;
    return h00 * p0 + h10 * m0 + h01 * p1 + h11 * m1;
  }

  /// Evaluates a 1D cubic Bézier curve at `t` in `[0, 1]`.
  static double cubicBezier(
    double p0,
    double p1,
    double p2,
    double p3,
    double t,
  ) {
    final u = 1.0 - t;
    final u2 = u * u;
    final t2 = t * t;
    return u2 * u * p0 + 3.0 * u2 * t * p1 + 3.0 * u * t2 * p2 + t2 * t * p3;
  }
}
