import 'dart:math' as math;
import 'dart:ui' show Color;

import 'package:flame/src/canvas3d/primitives_3d.dart';
import 'package:flame/src/game/game.dart';
import 'package:flame/src/math/oklab_color.dart';
import 'package:flame/src/rendering/light_2d_layer.dart';

/// Keyframe snapshot at [hour] (`0.0 .. 24.0`) inside a
/// [DayNightWeatherController].
class const DayNightKeyframe({
  required this.hour,
  required this.sunDirX,
  required this.sunDirY,
  required this.sunDirZ,
  required this.sunColor,
  required this.skyColor,
  required this.groundColor,
  required this.ambient2DColor,
  this.ambientIntensity = 0.44,
  this.diffuseIntensity = 0.66,
  this.nightLampFactor = 0.0,
}) {
  final double hour;
  final double sunDirX;
  final double sunDirY;
  final double sunDirZ;
  final Color sunColor;
  final Color skyColor;
  final Color groundColor;
  final Color ambient2DColor;
  final double ambientIntensity;
  final double diffuseIntensity;

  /// Factor `[0..1]` indicating window / streetlamp / torch auto-ignition
  /// (`0.0` in daylight, `1.0` at night).
  final double nightLampFactor;
}

/// Synchronized 24-hour RPG / HD-2D environment clock driving:
/// - 3D sun trajectory, hemisphere colors, and cast shadow angles on
///   [DirectionalLight3D],
/// - 2D ambient darkness tint on [Light2DLayer],
/// - Perceptual Oklab color transitions across midnight (`23:59 -> 00:00`),
/// - Smooth [nightLampFactor] (`0..1`) for town windows and streetlamps.
class DayNightWeatherController({
  double initialHour = 12.0,
  this.hoursPerRealSecond = 0.0,
  List<DayNightKeyframe>? keyframes,
}) {
  this {
    _keyframes = (keyframes == null || keyframes.isEmpty)
        ? List<DayNightKeyframe>.of(defaultCycle)
        : (List<DayNightKeyframe>.of(keyframes)
            ..sort((a, b) => a.hour.compareTo(b.hour)));
    _evaluate(_wrapHour(initialHour));
  }

  /// Canonical 4-phase JRPG / HD-2D cycle (Midnight, Dawn, Noon, Sunset).
  static const List<DayNightKeyframe> defaultCycle = <DayNightKeyframe>[
    DayNightKeyframe(
      hour: 0.0,
      sunDirX: 0.25,
      sunDirY: 0.35,
      sunDirZ: 0.90,
      sunColor: Color(0xFF6B8CFF),
      skyColor: Color(0xFF1F2B4D),
      groundColor: Color(0xFF141828),
      ambient2DColor: Color(0xFF28345A),
      ambientIntensity: 0.26,
      diffuseIntensity: 0.30,
      nightLampFactor: 1.0,
    ),
    DayNightKeyframe(
      hour: 6.0,
      sunDirX: -0.78,
      sunDirY: -0.22,
      sunDirZ: 0.42,
      sunColor: Color(0xFFFFB27E),
      skyColor: Color(0xFFFFD6C2),
      groundColor: Color(0xFF5A4644),
      ambient2DColor: Color(0xFFD9B2A3),
      ambientIntensity: 0.38,
      diffuseIntensity: 0.56,
      nightLampFactor: 0.35,
    ),
    DayNightKeyframe(
      hour: 12.0,
      sunDirX: -0.25,
      sunDirY: -0.30,
      sunDirZ: 0.92,
      sunColor: Color(0xFFFFF8E8),
      skyColor: Color(0xFFD8EEFF),
      groundColor: Color(0xFF6E5E53),
      ambient2DColor: Color(0xFFFFFFFF),
      ambientIntensity: 0.48,
      diffuseIntensity: 0.72,
    ),
    DayNightKeyframe(
      hour: 18.5,
      sunDirX: 0.80,
      sunDirY: -0.25,
      sunDirZ: 0.38,
      sunColor: Color(0xFFFF8854),
      skyColor: Color(0xFFF3A68E),
      groundColor: Color(0xFF4F383C),
      ambient2DColor: Color(0xFFE09478),
      ambientIntensity: 0.35,
      diffuseIntensity: 0.58,
      nightLampFactor: 0.55,
    ),
  ];

  late final List<DayNightKeyframe> _keyframes;

  /// Rate at which game hours advance per real-time second (`0.0` = manual).
  double hoursPerRealSecond;

  double _hour = 12.0;

  /// The hour the lighting values were last computed for. The clock itself
  /// ([_hour]) is kept exact, and the lighting is only recomputed once it has
  /// moved away from this by a noticeable amount.
  double _evaluatedHour = 12.0;
  double _sunDirX = -0.25;
  double _sunDirY = -0.30;
  double _sunDirZ = 0.92;
  Color _sunColor = const Color(0xFFFFF8E8);
  Color _skyColor = const Color(0xFFD8EEFF);
  Color _groundColor = const Color(0xFF6E5E53);
  Color _ambient2DColor = const Color(0xFFFFFFFF);
  double _ambientIntensity = 0.48;
  double _diffuseIntensity = 0.72;
  double _nightLampFactor = 0.0;
  int _version = 0;

  double get hour => _hour;
  int get version => _version;
  double get sunDirX => _sunDirX;
  double get sunDirY => _sunDirY;
  double get sunDirZ => _sunDirZ;
  Color get sunColor => _sunColor;
  Color get skyColor => _skyColor;
  Color get groundColor => _groundColor;
  Color get ambient2DColor => _ambient2DColor;
  double get ambientIntensity => _ambientIntensity;
  double get diffuseIntensity => _diffuseIntensity;
  double get nightLampFactor => _nightLampFactor;

  /// Whether night-time streetlamps / windows should currently glow.
  bool get areNightLampsLit => _nightLampFactor >= 0.5;

  /// Sets exact time of day in hours (wrapping modulo `24.0` cleanly even for
  /// negative values).
  ///
  /// [hour] always takes the new value. The lighting values, [version] and
  /// the visual-mutation notification follow once the clock has moved more
  /// than a millionth of an hour away from the time they were last computed
  /// for, so arbitrarily small steps add up instead of being lost.
  void setHour(double nextHour) {
    _hour = _wrapHour(nextHour);
    var moved = (_hour - _evaluatedHour).abs();
    if (moved > 12.0) {
      moved = 24.0 - moved;
    }
    if (moved > 1e-6) {
      _evaluate(_hour);
      _version++;
      Game.notifyVisualMutation();
    }
  }

  /// Advances the clock by `dt * hoursPerRealSecond` and optionally pushes
  /// updated lighting onto [light3D] and [light2D].
  ///
  /// The clock advances by exactly that amount on every call, however small
  /// the step is.
  void update(
    double dt, {
    DirectionalLight3D? light3D,
    Light2DLayer? light2D,
  }) {
    if (hoursPerRealSecond != 0.0 && dt > 0.0) {
      setHour(_hour + dt * hoursPerRealSecond);
    }
    if (light3D != null) {
      applyToLight3D(light3D);
    }
    if (light2D != null) {
      light2D.ambientColor = _ambient2DColor;
    }
  }

  /// Applies current interpolated sun direction, colors, and intensities to
  /// [target].
  void applyToLight3D(DirectionalLight3D target) {
    target
      ..setDirection(_sunDirX, _sunDirY, _sunDirZ)
      ..sunColor = _sunColor
      ..skyColor = _skyColor
      ..groundColor = _groundColor
      ..ambientIntensity = _ambientIntensity
      ..diffuseIntensity = _diffuseIntensity;
  }

  static double _wrapHour(double h) {
    final m = h % 24.0;
    return m < 0.0 ? m + 24.0 : m;
  }

  void _evaluate(double h) {
    _hour = h;
    _evaluatedHour = h;
    final n = _keyframes.length;
    if (n == 1) {
      final k = _keyframes[0];
      _sunDirX = k.sunDirX;
      _sunDirY = k.sunDirY;
      _sunDirZ = k.sunDirZ;
      _sunColor = k.sunColor;
      _skyColor = k.skyColor;
      _groundColor = k.groundColor;
      _ambient2DColor = k.ambient2DColor;
      _ambientIntensity = k.ambientIntensity;
      _diffuseIntensity = k.diffuseIntensity;
      _nightLampFactor = k.nightLampFactor;
      return;
    }

    var idxA = n - 1;
    var idxB = 0;
    for (var i = 0; i < n; i++) {
      if (_keyframes[i].hour <= h) {
        idxA = i;
        idxB = (i + 1) % n;
      } else {
        break;
      }
    }

    final a = _keyframes[idxA];
    final b = _keyframes[idxB];
    var span = b.hour - a.hour;
    if (span <= 0.0) {
      span += 24.0;
    }
    var rel = h - a.hour;
    if (rel < 0.0) {
      rel += 24.0;
    }
    final t = span <= 1e-6 ? 0.0 : (rel / span).clamp(0.0, 1.0);

    final dx = a.sunDirX + (b.sunDirX - a.sunDirX) * t;
    final dy = a.sunDirY + (b.sunDirY - a.sunDirY) * t;
    final dz = a.sunDirZ + (b.sunDirZ - a.sunDirZ) * t;
    final len = math.sqrt(dx * dx + dy * dy + dz * dz);
    if (len > 1e-6) {
      _sunDirX = dx / len;
      _sunDirY = dy / len;
      _sunDirZ = dz / len;
    }

    _sunColor = OklabColor.lerp(a.sunColor, b.sunColor, t);
    _skyColor = OklabColor.lerp(a.skyColor, b.skyColor, t);
    _groundColor = OklabColor.lerp(a.groundColor, b.groundColor, t);
    _ambient2DColor = OklabColor.lerp(a.ambient2DColor, b.ambient2DColor, t);
    _ambientIntensity =
        a.ambientIntensity + (b.ambientIntensity - a.ambientIntensity) * t;
    _diffuseIntensity =
        a.diffuseIntensity + (b.diffuseIntensity - a.diffuseIntensity) * t;
    _nightLampFactor =
        a.nightLampFactor + (b.nightLampFactor - a.nightLampFactor) * t;
  }
}
