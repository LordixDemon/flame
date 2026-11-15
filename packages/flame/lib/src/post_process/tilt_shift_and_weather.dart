import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/components.dart';
import 'package:flame/post_process.dart';
import 'package:flame/src/canvas3d/batch_mesh_renderer_3d.dart';
import 'package:flame/src/game/game.dart';
import 'package:flame/src/math/game_math.dart';
import 'package:flame/src/rendering/light_2d_layer.dart';
import 'package:flutter/painting.dart';

/// HD-2D / tabletop diorama miniature depth-of-field [PostProcess] requiring
/// zero external `.frag` shader assets.
///
/// Keeps a crisp horizontal focus band centered at normalized screen height
/// [focusCenterY] (`0.0` = top, `1.0` = bottom) with half-height
/// [focusBandHalfHeight], while smoothly feathering into [farSigma] blur toward
/// the top horizon and [nearSigma] blur toward the foreground bottom edge.
class TiltShiftPostProcess({
  var double focusCenterY = 0.52,
  var double focusBandHalfHeight = 0.14,
  var double featherFalloff = 0.22,
  var double farSigma = 4.5,
  var double nearSigma = 5.5,
  var double strength = 1.0,
  var bool enabled = true,
  super.pixelRatio,
}) extends PostProcess {
  ui.Image? _heldImage;

  final Paint _basePaint = Paint()..filterQuality = FilterQuality.medium;
  final Paint _farBlurPaint = Paint()..filterQuality = FilterQuality.medium;
  final Paint _nearBlurPaint = Paint()..filterQuality = FilterQuality.medium;
  final Paint _maskPaint = Paint()..blendMode = BlendMode.dstIn;
  final Paint _layerPaint = Paint();

  double _cachedFarSigma = -1.0;
  double _cachedNearSigma = -1.0;

  void _replaceHeldImage(ui.Image? next) {
    if (!identical(_heldImage, next)) {
      _heldImage?.dispose();
      _heldImage = next;
    }
  }

  void _syncBlurFilters(double effFar, double effNear) {
    if ((_cachedFarSigma - effFar).abs() > 1e-4) {
      _cachedFarSigma = effFar;
      _farBlurPaint.imageFilter = effFar > 0.05
          ? ui.ImageFilter.blur(
              sigmaX: effFar,
              sigmaY: effFar,
              tileMode: TileMode.clamp,
            )
          : null;
    }
    if ((_cachedNearSigma - effNear).abs() > 1e-4) {
      _cachedNearSigma = effNear;
      _nearBlurPaint.imageFilter = effNear > 0.05
          ? ui.ImageFilter.blur(
              sigmaX: effNear,
              sigmaY: effNear,
              tileMode: TileMode.clamp,
            )
          : null;
    }
  }

  @override
  bool get isEffectivelyNoOp {
    if (!enabled) {
      return true;
    }
    final s = strength.clamp(0.0, 1.0);
    if (s <= 1e-3) {
      return true;
    }
    return farSigma * s <= 0.05 && nearSigma * s <= 0.05;
  }

  @override
  bool get supportsImageInput => true;

  @override
  bool renderFromImage(ui.Image inputImage, Vector2 size, Canvas canvas) {
    final dst = Rect.fromLTWH(0, 0, size.x, size.y);
    final src = Rect.fromLTWH(
      0,
      0,
      inputImage.width.toDouble(),
      inputImage.height.toDouble(),
    );
    final s = strength.clamp(0.0, 1.0);
    final effFar = math.max(0.0, farSigma) * s;
    final effNear = math.max(0.0, nearSigma) * s;

    canvas.drawImageRect(inputImage, src, dst, _basePaint);
    if (!enabled ||
        s <= 1e-3 ||
        (effFar <= 0.05 && effNear <= 0.05) ||
        size.x < 2 ||
        size.y < 2) {
      return true;
    }

    _syncBlurFilters(effFar, effNear);

    final center = focusCenterY.clamp(0.0, 1.0) * size.y;
    final halfBand = focusBandHalfHeight.clamp(0.0, 0.5) * size.y;
    final feather = math.max(1.0, featherFalloff.clamp(0.01, 1.0) * size.y);

    // 1. Far horizon (top) blur region:
    final farEnd = (center - halfBand).clamp(0.0, size.y);
    if (effFar > 0.05 && farEnd > 0.5) {
      final farFadeStart = math.max(0.0, farEnd - feather);
      final topRect = Rect.fromLTWH(0, 0, size.x, farEnd);
      _layerPaint.color = Color.fromARGB(
        (s * 255).round().clamp(0, 255),
        255,
        255,
        255,
      );
      canvas.saveLayer(topRect, _layerPaint);
      canvas.drawImageRect(inputImage, src, dst, _farBlurPaint);
      _maskPaint.shader = ui.Gradient.linear(
        Offset(0, farFadeStart),
        Offset(0, farEnd),
        const <Color>[Color(0xFFFFFFFF), Color(0x00FFFFFF)],
      );
      canvas.drawRect(topRect, _maskPaint);
      canvas.restore();
    }

    // 2. Near foreground (bottom) blur region:
    final nearStart = (center + halfBand).clamp(0.0, size.y);
    if (effNear > 0.05 && nearStart < size.y - 0.5) {
      final nearFadeEnd = math.min(size.y, nearStart + feather);
      final botRect = Rect.fromLTWH(0, nearStart, size.x, size.y - nearStart);
      _layerPaint.color = Color.fromARGB(
        (s * 255).round().clamp(0, 255),
        255,
        255,
        255,
      );
      canvas.saveLayer(botRect, _layerPaint);
      canvas.drawImageRect(inputImage, src, dst, _nearBlurPaint);
      _maskPaint.shader = ui.Gradient.linear(
        Offset(0, nearStart),
        Offset(0, nearFadeEnd),
        const <Color>[Color(0x00FFFFFF), Color(0xFFFFFFFF)],
      );
      canvas.drawRect(botRect, _maskPaint);
      canvas.restore();
    }

    return true;
  }

  @override
  void postProcess(Vector2 size, Canvas canvas) {
    if (isEffectivelyNoOp || size.x < 2 || size.y < 2) {
      renderSubtree(canvas);
      return;
    }
    final sceneImage = rasterizeSubtree();
    _replaceHeldImage(sceneImage);
    renderFromImage(sceneImage, size, canvas);
  }

  @override
  void onRemove() {
    _replaceHeldImage(null);
    super.onRemove();
  }
}

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
  void setHour(double nextHour) {
    final wrapped = _wrapHour(nextHour);
    if ((_hour - wrapped).abs() > 1e-6) {
      _evaluate(wrapped);
      _version++;
      Game.notifyVisualMutation();
    }
  }

  /// Advances the clock by `dt * hoursPerRealSecond` and optionally pushes
  /// updated lighting onto [light3D] and [light2D].
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

/// Weather preset kind for [WeatherPrecipitationLayer].
enum WeatherKind() {
  clear,
  rain,
  snow,
  embers,
}

/// Zero-allocation, camera-torus-wrapped precipitation renderer (`rain`,
/// `snow`, `embers`) that wraps particle positions modulo the active camera
/// bounds in `O(particleCount)` with `0` heap allocations — so panning or
/// teleporting the camera `+50,000px` never leaves empty sky or spawns GC.
class WeatherPrecipitationLayer({
  this.kind = WeatherKind.rain,
  int particleCount = 128,
  this.intensity = 1.0,
  this.windVelocityX = -65.0,
  this.fallSpeedY = 460.0,
  this.fallbackBounds = const Rect.fromLTWH(0, 0, 800, 600),
  super.priority = 9000,
  super.cameraMask,
  super.key,
}) extends Component with HasVisibility {
  this {
    final n = math.max(1, particleCount);
    _seedX = Float32List(n);
    _seedY = Float32List(n);
    _speedScale = Float32List(n);
    _phase = Float32List(n);
    _linePoints = Float32List(n * 4);

    // Deterministic Halton-like low-discrepancy distribution:
    for (var i = 0; i < n; i++) {
      _seedX[i] = ((i * 0.61803398875) % 1.0) * 4096.0;
      _seedY[i] = ((i * 0.38196601125 + 0.17) % 1.0) * 4096.0;
      _speedScale[i] = 0.72 + (i % 7) * 0.08;
      _phase[i] = i * 0.91;
    }
  }

  WeatherKind kind;
  double intensity;
  double windVelocityX;
  double fallSpeedY;
  Rect fallbackBounds;

  late final Float32List _seedX;
  late final Float32List _seedY;
  late final Float32List _speedScale;
  late final Float32List _phase;
  late final Float32List _linePoints;

  double _elapsed = 0.0;
  int _lastActiveDropCount = 0;

  final Paint _paint = Paint()
    ..strokeCap = StrokeCap.round
    ..isAntiAlias = true;

  /// Number of precipitation drops rendered in the last [render] pass.
  int get lastActiveDropCount => _lastActiveDropCount;

  /// Samples the camera-wrapped world position of drop [index] inside [bounds]
  /// (exposed for deterministic verification).
  Offset sampleDropPosition(int index, Rect bounds) {
    final w = math.max(1.0, bounds.width);
    final h = math.max(1.0, bounds.height);
    final sp = _speedScale[index];
    final sway = kind == WeatherKind.snow
        ? math.sin(_elapsed * 2.4 + _phase[index]) * 18.0
        : (kind == WeatherKind.embers
              ? math.sin(_elapsed * 3.1 + _phase[index]) * 24.0
              : 0.0);
    final vy = kind == WeatherKind.embers ? -fallSpeedY * 0.35 : fallSpeedY;
    final rawX = _seedX[index] + _elapsed * windVelocityX * sp + sway;
    final rawY = _seedY[index] + _elapsed * vy * sp;

    final wx = _posMod(rawX - bounds.left, w) + bounds.left;
    final wy = _posMod(rawY - bounds.top, h) + bounds.top;
    return Offset(wx, wy);
  }

  static double _posMod(double value, double mod) {
    final r = value % mod;
    return r < 0.0 ? r + mod : r;
  }

  @override
  void update(double dt) {
    super.update(dt);
    if (kind == WeatherKind.clear || intensity <= 1e-3 || dt <= 0.0) {
      return;
    }
    _elapsed += dt;
    Game.notifyVisualMutation();
  }

  @override
  void render(Canvas canvas) {
    _lastActiveDropCount = 0;
    final clampedInt = intensity.clamp(0.0, 1.0);
    if (kind == WeatherKind.clear || clampedInt <= 1e-3) {
      return;
    }

    final bounds =
        CameraComponent.currentCamera?.visibleWorldRect ?? fallbackBounds;
    final total = (_seedX.length * clampedInt).round().clamp(0, _seedX.length);
    if (total == 0) {
      return;
    }

    final alpha = (clampedInt * (kind == WeatherKind.rain ? 155 : 210))
        .round()
        .clamp(0, 255);
    switch (kind) {
      case WeatherKind.clear:
        return;
      case WeatherKind.rain:
        _paint
          ..color = Color.fromARGB(alpha, 185, 215, 255)
          ..strokeWidth = 1.35;
      case WeatherKind.snow:
        _paint
          ..color = Color.fromARGB(alpha, 245, 250, 255)
          ..strokeWidth = 3.2;
      case WeatherKind.embers:
        _paint
          ..color = Color.fromARGB(alpha, 255, 148, 66)
          ..strokeWidth = 2.6;
    }

    final streakDx = kind == WeatherKind.rain ? windVelocityX * 0.032 : 0.0;
    final streakDy = kind == WeatherKind.rain
        ? fallSpeedY * 0.032
        : (kind == WeatherKind.embers ? -3.0 : 0.5);

    var cursor = 0;
    for (var i = 0; i < total; i++) {
      final p = sampleDropPosition(i, bounds);
      _linePoints[cursor++] = p.dx;
      _linePoints[cursor++] = p.dy;
      _linePoints[cursor++] = p.dx + streakDx;
      _linePoints[cursor++] = p.dy + streakDy;
    }

    final slice = cursor == _linePoints.length
        ? _linePoints
        : Float32List.sublistView(_linePoints, 0, cursor);
    canvas.drawRawPoints(ui.PointMode.lines, slice, _paint);
    _lastActiveDropCount = total;
  }
}
