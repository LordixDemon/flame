import 'dart:math' as math;

import 'package:flame_3d/core.dart';
import 'package:flame_3d/src/parser/gltf/gltf_node.dart';

/// Interpolation algorithm.
enum AnimationInterpolation(final String value) {
  /// The animated values are linearly interpolated between keyframes.
  /// When targeting a rotation, spherical linear interpolation (slerp)
  /// **SHOULD** be used to interpolate quaternions.
  /// The number of output elements **MUST** equal the number of input elements.
  linear('LINEAR'),

  /// The animated values remain constant to the output of the first keyframe,
  /// until the next keyframe.
  /// The number of output elements **MUST** equal the number of input elements.
  step('STEP'),

  /// The animation's interpolation is computed using a cubic spline with
  /// specified tangents.
  cubicSpline('CUBICSPLINE'); // cSpell:ignore CUBICSPLINE

  static AnimationInterpolation valueOf(String value) {
    return values.firstWhere((e) => e.value == value);
  }

  static AnimationInterpolation? parse(Map<String, Object?> map, String key) {
    return Parser.stringEnum(map, key, valueOf);
  }

  Vector3 lerp(Vector3 a, Vector3 b, double t) {
    final out = Vector3.zero();
    lerpInto(a, b, t, out);
    return out;
  }

  /// Writes the interpolated vector between [a] and [b] at [t] into [out]
  /// without allocating.
  void lerpInto(Vector3 a, Vector3 b, double t, Vector3 out) {
    switch (this) {
      case linear:
        out.setValues(
          a.x + (b.x - a.x) * t,
          a.y + (b.y - a.y) * t,
          a.z + (b.z - a.z) * t,
        );
      case step:
        out.setFrom(a);
      case cubicSpline:
        throw UnimplementedError();
    }
  }

  Quaternion slerp(Quaternion a, Quaternion b, double t) {
    final out = Quaternion.identity();
    slerpInto(a, b, t, out);
    return out;
  }

  /// Writes the shortest-arc spherical linear interpolation between [a] and [b]
  /// at [t] into [out] without allocating.
  void slerpInto(Quaternion a, Quaternion b, double t, Quaternion out) {
    switch (this) {
      case linear:
        slerpQuaternionsInto(a, b, t, out);
      case step:
        out.setFrom(a);
      case cubicSpline:
        throw UnimplementedError();
    }
  }

  /// Allocation-free shortest-arc quaternion SLERP into [out].
  static void slerpQuaternionsInto(
    Quaternion a,
    Quaternion b,
    double t,
    Quaternion out,
  ) {
    final ax = a.x;
    final ay = a.y;
    final az = a.z;
    final aw = a.w;
    var bx = b.x;
    var by = b.y;
    var bz = b.z;
    var bw = b.w;

    var cosHalfTheta = ax * bx + ay * by + az * bz + aw * bw;
    if (cosHalfTheta < 0.0) {
      cosHalfTheta = -cosHalfTheta;
      bx = -bx;
      by = -by;
      bz = -bz;
      bw = -bw;
    }

    double s0;
    double s1;
    if (1.0 - cosHalfTheta > 1e-5) {
      final halfTheta = math.acos(cosHalfTheta.clamp(-1.0, 1.0));
      final invSin = 1.0 / math.sin(halfTheta);
      s0 = math.sin((1.0 - t) * halfTheta) * invSin;
      s1 = math.sin(t * halfTheta) * invSin;
    } else {
      s0 = 1.0 - t;
      s1 = t;
    }

    var rx = s0 * ax + s1 * bx;
    var ry = s0 * ay + s1 * by;
    var rz = s0 * az + s1 * bz;
    var rw = s0 * aw + s1 * bw;
    final len = math.sqrt(rx * rx + ry * ry + rz * rz + rw * rw);
    if (len > 1e-12) {
      final inv = 1.0 / len;
      rx *= inv;
      ry *= inv;
      rz *= inv;
      rw *= inv;
    }
    out.setValues(rx, ry, rz, rw);
  }
}
