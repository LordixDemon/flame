import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:vector_math/vector_math.dart';

/// Mutable scalar velocity holder for zero-allocation [GameMath.smoothDamp]
/// and [GameMath.smoothDampAngle] calls.
class SmoothDampState({var double velocity = 0.0});

/// Fundamental game-mathematics utilities: critically damped springs
/// (`smoothDamp`), perceptual color interpolation ([OklabColor]), cubic
/// splines, angle wrapping, and seeded zero-allocation [SimplexNoise2D].
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

  /// Linearly maps [value] from `[inMin, inMax]` into `[outMin, outMax]`.
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

/// Perceptually uniform OKLab / OKLCH color representation preventing muddy
/// mid-tones when interpolating saturated game colors.
class const OklabColor(
  this.l,
  this.a,
  this.b, [
  this.alpha = 1.0,
]) {
  /// Perceptual lightness (`0.0` black .. `1.0` white).
  final double l;

  /// Green–red opponent axis.
  final double a;

  /// Blue–yellow opponent axis.
  final double b;

  /// Opacity in `[0.0, 1.0]`.
  final double alpha;

  /// Converts an sRGB [Color] into [OklabColor].
  factory OklabColor.fromColor(Color color) {
    final r = _srgbToLinear(color.r);
    final g = _srgbToLinear(color.g);
    final bl = _srgbToLinear(color.b);

    final lLin = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * bl;
    final mLin = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * bl;
    final sLin = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * bl;

    final lRoot = _cbrt(lLin);
    final mRoot = _cbrt(mLin);
    final sRoot = _cbrt(sLin);

    return OklabColor(
      0.2104542553 * lRoot + 0.7936177850 * mRoot - 0.0040720468 * sRoot,
      1.9779984951 * lRoot - 2.4285922050 * mRoot + 0.4505937099 * sRoot,
      0.0259040371 * lRoot + 0.7827717662 * mRoot - 0.8086757660 * sRoot,
      color.a,
    );
  }

  /// Converts this OKLab color back into a clamped sRGB [Color].
  Color toColor() {
    final lRoot = l + 0.3963377774 * a + 0.2158037573 * b;
    final mRoot = l - 0.1055613458 * a - 0.0638541728 * b;
    final sRoot = l - 0.0894841775 * a - 1.2914855480 * b;

    final lLin = lRoot * lRoot * lRoot;
    final mLin = mRoot * mRoot * mRoot;
    final sLin = sRoot * sRoot * sRoot;

    final r = 4.0767416621 * lLin - 3.3077115913 * mLin + 0.2309699292 * sLin;
    final g = -1.2684380046 * lLin + 2.6097574011 * mLin - 0.3413193965 * sLin;
    final bl = -0.0041960863 * lLin - 0.7034186147 * mLin + 1.7076147010 * sLin;

    return Color.from(
      alpha: alpha.clamp(0.0, 1.0),
      red: _linearToSrgb(r),
      green: _linearToSrgb(g),
      blue: _linearToSrgb(bl),
    );
  }

  /// Perceptually uniform linear interpolation between [start] and [end] in
  /// OKLab space.
  static Color lerp(Color start, Color end, double t) {
    final c0 = OklabColor.fromColor(start);
    final c1 = OklabColor.fromColor(end);
    return OklabColor(
      c0.l + (c1.l - c0.l) * t,
      c0.a + (c1.a - c0.a) * t,
      c0.b + (c1.b - c0.b) * t,
      c0.alpha + (c1.alpha - c0.alpha) * t,
    ).toColor();
  }

  /// Polar OKLCH interpolation preserving chroma vibrancy across hue sweeps.
  static Color lerpOklch(Color start, Color end, double t) {
    final c0 = OklabColor.fromColor(start);
    final c1 = OklabColor.fromColor(end);
    final ch0 = math.sqrt(c0.a * c0.a + c0.b * c0.b);
    final ch1 = math.sqrt(c1.a * c1.a + c1.b * c1.b);
    if (ch0 < 1e-5 || ch1 < 1e-5) {
      return lerp(start, end, t);
    }
    final h0 = math.atan2(c0.b, c0.a);
    final h1 = math.atan2(c1.b, c1.a);
    final h = h0 + GameMath.deltaAngle(h0, h1) * t;
    final ch = ch0 + (ch1 - ch0) * t;
    final lVal = c0.l + (c1.l - c0.l) * t;
    final alphaVal = c0.alpha + (c1.alpha - c0.alpha) * t;
    return OklabColor(
      lVal,
      ch * math.cos(h),
      ch * math.sin(h),
      alphaVal,
    ).toColor();
  }

  static double _cbrt(double x) {
    if (x == 0.0) {
      return 0.0;
    }
    return x > 0.0
        ? math.pow(x, 1.0 / 3.0).toDouble()
        : -math.pow(-x, 1.0 / 3.0).toDouble();
  }

  static double _srgbToLinear(double c) {
    final clamped = c.clamp(0.0, 1.0);
    return clamped <= 0.04045
        ? clamped / 12.92
        : math.pow((clamped + 0.055) / 1.055, 2.4).toDouble();
  }

  static double _linearToSrgb(double c) {
    final clamped = c.clamp(0.0, 1.0);
    return clamped <= 0.0031308
        ? clamped * 12.92
        : 1.055 * math.pow(clamped, 1.0 / 2.4).toDouble() - 0.055;
  }
}

/// Seeded, zero-allocation 2D Simplex noise generator with fractal Brownian
/// motion (`fbm`) support.
class SimplexNoise2D({int seed = 1337}) {
  this {
    final perm = Uint8List(256);
    for (var i = 0; i < 256; i++) {
      perm[i] = i;
    }
    var state = (seed ^ 0x9E3779B9) & 0xFFFFFFFF;
    for (var i = 255; i > 0; i--) {
      state = (state + 0x6D2B79F5) & 0xFFFFFFFF;
      var z = state;
      z = ((z ^ (z >>> 15)) * (z | 1)) & 0xFFFFFFFF;
      z ^= (z + (((z ^ (z >>> 7)) * (z | 61)) & 0xFFFFFFFF)) & 0xFFFFFFFF;
      final rand = (z ^ (z >>> 14)) & 0xFFFFFFFF;
      final j = rand % (i + 1);
      final tmp = perm[i];
      perm[i] = perm[j];
      perm[j] = tmp;
    }
    for (var i = 0; i < 512; i++) {
      final p = perm[i & 255];
      _perm[i] = p;
      _permMod12[i] = p % 12;
    }
  }

  static const double _f2 = 0.3660254037844386; // 0.5 * (sqrt(3) - 1)
  static const double _g2 = 0.21132486540518713; // (3 - sqrt(3)) / 6

  static const List<double> _grad2 = <double>[
    1, 1, -1, 1, 1, -1, -1, -1, //
    1, 0, -1, 0, 1, 0, -1, 0, //
    0, 1, 0, -1, 0, 1, 0, -1, //
  ];

  final Uint8List _perm = Uint8List(512);
  final Uint8List _permMod12 = Uint8List(512);

  /// Evaluates single-octave 2D Simplex noise at `(x, y)` in `[-1.0, 1.0]`.
  double sample(double x, double y) {
    final s = (x + y) * _f2;
    final i = (x + s).floor();
    final j = (y + s).floor();
    final t = (i + j) * _g2;
    final x0 = x - (i - t);
    final y0 = y - (j - t);

    final int i1;
    final int j1;
    if (x0 > y0) {
      i1 = 1;
      j1 = 0;
    } else {
      i1 = 0;
      j1 = 1;
    }

    final x1 = x0 - i1 + _g2;
    final y1 = y0 - j1 + _g2;
    final x2 = x0 - 1.0 + 2.0 * _g2;
    final y2 = y0 - 1.0 + 2.0 * _g2;

    final ii = i & 255;
    final jj = j & 255;

    var n0 = 0.0;
    var t0 = 0.5 - x0 * x0 - y0 * y0;
    if (t0 > 0.0) {
      final gi0 = _permMod12[ii + _perm[jj]] * 2;
      t0 *= t0;
      n0 = t0 * t0 * (_grad2[gi0] * x0 + _grad2[gi0 + 1] * y0);
    }

    var n1 = 0.0;
    var t1 = 0.5 - x1 * x1 - y1 * y1;
    if (t1 > 0.0) {
      final gi1 = _permMod12[ii + i1 + _perm[jj + j1]] * 2;
      t1 *= t1;
      n1 = t1 * t1 * (_grad2[gi1] * x1 + _grad2[gi1 + 1] * y1);
    }

    var n2 = 0.0;
    var t2 = 0.5 - x2 * x2 - y2 * y2;
    if (t2 > 0.0) {
      final gi2 = _permMod12[ii + 1 + _perm[jj + 1]] * 2;
      t2 *= t2;
      n2 = t2 * t2 * (_grad2[gi2] * x2 + _grad2[gi2 + 1] * y2);
    }

    return (70.0 * (n0 + n1 + n2)).clamp(-1.0, 1.0);
  }

  /// Evaluates normalized multi-octave fractal Brownian motion (`[-1, 1]`).
  double fbm(
    double x,
    double y, {
    int octaves = 4,
    double lacunarity = 2.0,
    double gain = 0.5,
  }) {
    var sum = 0.0;
    var amplitude = 1.0;
    var frequency = 1.0;
    var norm = 0.0;
    for (var o = 0; o < octaves; o++) {
      sum += sample(x * frequency, y * frequency) * amplitude;
      norm += amplitude;
      amplitude *= gain;
      frequency *= lacunarity;
    }
    return norm > 0.0 ? (sum / norm).clamp(-1.0, 1.0) : 0.0;
  }
}
