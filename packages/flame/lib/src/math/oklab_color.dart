import 'dart:math' as math;
import 'dart:ui' show Color;

import 'package:flame/src/math/game_math.dart';

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
