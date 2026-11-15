import 'dart:math' as math;
import 'dart:typed_data';

/// Allocation-free 3D quaternion and `3x3` rotation matrix math utilities for
/// gimbal-lock-free `canvas3d` orientation, SLERP blending, and skeletal
/// skinning.
abstract final class Quaternion3D._() {
  /// Identity unit quaternion `(0, 0, 0, 1)`.
  static const (double, double, double, double) identity = (0.0, 0.0, 0.0, 1.0);

  /// Normalizes `(qx, qy, qz, qw)` onto the unit 3-sphere.
  static (double, double, double, double) normalize(
    double qx,
    double qy,
    double qz,
    double qw,
  ) {
    final len = math.sqrt(qx * qx + qy * qy + qz * qz + qw * qw);
    if (len <= 1e-9) {
      return identity;
    }
    final inv = 1.0 / len;
    return (qx * inv, qy * inv, qz * inv, qw * inv);
  }

  /// Creates a unit quaternion rotating by [angleRad] around `(ax, ay, az)`.
  static (double, double, double, double) fromAxisAngle(
    double ax,
    double ay,
    double az,
    double angleRad,
  ) {
    final len = math.sqrt(ax * ax + ay * ay + az * az);
    if (len <= 1e-9) {
      return identity;
    }
    final half = angleRad * 0.5;
    final s = math.sin(half) / len;
    return (ax * s, ay * s, az * s, math.cos(half));
  }

  /// Creates a unit quaternion matching `canvas3d`'s intrinsic Euler convention
  /// `R = Rz(yaw) * Ry(pitch) * Rx(roll)`.
  static (double, double, double, double) fromEuler({
    double yawRad = 0.0,
    double pitchRad = 0.0,
    double rollRad = 0.0,
  }) {
    final cy = math.cos(yawRad * 0.5);
    final sy = math.sin(yawRad * 0.5);
    final cp = math.cos(pitchRad * 0.5);
    final sp = math.sin(pitchRad * 0.5);
    final cr = math.cos(rollRad * 0.5);
    final sr = math.sin(rollRad * 0.5);

    return (
      sr * cp * cy - cr * sp * sy,
      cr * sp * cy + sr * cp * sy,
      cr * cp * sy - sr * sp * cy,
      cr * cp * cy + sr * sp * sy,
    );
  }

  /// Hamilton product `a * b` (applying rotation `b` in local space followed by
  /// `a`).
  static (double, double, double, double) multiply(
    (double, double, double, double) a,
    (double, double, double, double) b,
  ) {
    final (ax, ay, az, aw) = a;
    final (bx, by, bz, bw) = b;
    return (
      aw * bx + ax * bw + ay * bz - az * by,
      aw * by - ax * bz + ay * bw + az * bx,
      aw * bz + ax * by - ay * bx + az * bw,
      aw * bw - ax * bx - ay * by - az * bz,
    );
  }

  /// Shortest-arc spherical linear interpolation between unit quaternions [a]
  /// and [b] at `t` (`0.0 .. 1.0`).
  static (double, double, double, double) slerp(
    (double, double, double, double) a,
    (double, double, double, double) b,
    double t,
  ) {
    final u = t.clamp(0.0, 1.0);
    final (ax, ay, az, aw) = a;
    var (bx, by, bz, bw) = b;
    var dot = ax * bx + ay * by + az * bz + aw * bw;
    if (dot < 0.0) {
      dot = -dot;
      bx = -bx;
      by = -by;
      bz = -bz;
      bw = -bw;
    }
    if (dot > 0.9995) {
      return normalize(
        ax + (bx - ax) * u,
        ay + (by - ay) * u,
        az + (bz - az) * u,
        aw + (bw - aw) * u,
      );
    }
    final theta0 = math.acos(dot.clamp(-1.0, 1.0));
    final theta = theta0 * u;
    final sinTheta = math.sin(theta);
    final sinTheta0 = math.sin(theta0);
    final s0 = math.cos(theta) - dot * sinTheta / sinTheta0;
    final s1 = sinTheta / sinTheta0;
    return (
      s0 * ax + s1 * bx,
      s0 * ay + s1 * by,
      s0 * az + s1 * bz,
      s0 * aw + s1 * bw,
    );
  }

  /// Writes the row-major `3x3` rotation matrix for `(qx, qy, qz, qw)` into
  /// [out] at [offset] (requires `out.length >= offset + 9`).
  static void writeMatrix3(
    double qx,
    double qy,
    double qz,
    double qw,
    Float32List out, [
    int offset = 0,
  ]) {
    final (x, y, z, w) = normalize(qx, qy, qz, qw);
    final xx = x * x;
    final yy = y * y;
    final zz = z * z;
    final xy = x * y;
    final xz = x * z;
    final yz = y * z;
    final wx = w * x;
    final wy = w * y;
    final wz = w * z;

    out[offset] = 1.0 - 2.0 * (yy + zz);
    out[offset + 1] = 2.0 * (xy - wz);
    out[offset + 2] = 2.0 * (xz + wy);
    out[offset + 3] = 2.0 * (xy + wz);
    out[offset + 4] = 1.0 - 2.0 * (xx + zz);
    out[offset + 5] = 2.0 * (yz - wx);
    out[offset + 6] = 2.0 * (xz - wy);
    out[offset + 7] = 2.0 * (yz + wx);
    out[offset + 8] = 1.0 - 2.0 * (xx + yy);
  }

  /// Writes `R = Rz(yaw) * Ry(pitch) * Rx(roll)` into [out] at [offset].
  static void writeEulerMatrix3({
    required double yawRad,
    required double pitchRad,
    required double rollRad,
    required Float32List out,
    int offset = 0,
  }) {
    final cy = math.cos(yawRad);
    final sy = math.sin(yawRad);
    final cp = math.cos(pitchRad);
    final sp = math.sin(pitchRad);
    final cr = math.cos(rollRad);
    final sr = math.sin(rollRad);

    out[offset] = cy * cp;
    out[offset + 1] = cy * sp * sr - sy * cr;
    out[offset + 2] = cy * sp * cr + sy * sr;
    out[offset + 3] = sy * cp;
    out[offset + 4] = sy * sp * sr + cy * cr;
    out[offset + 5] = sy * sp * cr - cy * sr;
    out[offset + 6] = -sp;
    out[offset + 7] = cp * sr;
    out[offset + 8] = cp * cr;
  }

  /// Multiplies two row-major `3x3` matrices `out = a * b`.
  static void multiplyMatrix3(
    Float32List a,
    int aOff,
    Float32List b,
    int bOff,
    Float32List out,
    int outOff,
  ) {
    final a00 = a[aOff];
    final a01 = a[aOff + 1];
    final a02 = a[aOff + 2];
    final a10 = a[aOff + 3];
    final a11 = a[aOff + 4];
    final a12 = a[aOff + 5];
    final a20 = a[aOff + 6];
    final a21 = a[aOff + 7];
    final a22 = a[aOff + 8];

    final b00 = b[bOff];
    final b01 = b[bOff + 1];
    final b02 = b[bOff + 2];
    final b10 = b[bOff + 3];
    final b11 = b[bOff + 4];
    final b12 = b[bOff + 5];
    final b20 = b[bOff + 6];
    final b21 = b[bOff + 7];
    final b22 = b[bOff + 8];

    out[outOff] = a00 * b00 + a01 * b10 + a02 * b20;
    out[outOff + 1] = a00 * b01 + a01 * b11 + a02 * b21;
    out[outOff + 2] = a00 * b02 + a01 * b12 + a02 * b22;
    out[outOff + 3] = a10 * b00 + a11 * b10 + a12 * b20;
    out[outOff + 4] = a10 * b01 + a11 * b11 + a12 * b21;
    out[outOff + 5] = a10 * b02 + a11 * b12 + a12 * b22;
    out[outOff + 6] = a20 * b00 + a21 * b10 + a22 * b20;
    out[outOff + 7] = a20 * b01 + a21 * b11 + a22 * b21;
    out[outOff + 8] = a20 * b02 + a21 * b12 + a22 * b22;
  }
}
