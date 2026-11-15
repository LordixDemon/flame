import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/src/camera/camera_component.dart';
import 'package:flame/src/components/core/component.dart';
import 'package:flame/src/components/mixins/has_visibility.dart';
import 'package:flame/src/game/game.dart';
import 'package:flutter/painting.dart';

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
