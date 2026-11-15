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
  hail,
  ash,
}

/// Zero-allocation, camera-torus-wrapped precipitation renderer (`rain`,
/// `snow`, `embers`, `hail`, `ash`) with multi-layer depth parallax, dynamic
/// wind gusts, and deterministic ground/water splash impact callbacks.
///
/// Wraps particle positions modulo the active camera bounds in
/// `O(particleCount)` with `0` heap allocations — so panning or teleporting the
/// camera `+50,000px` never leaves empty sky or spawns GC.
class WeatherPrecipitationLayer({
  this.kind = WeatherKind.rain,
  int particleCount = 128,
  this.intensity = 1.0,
  this.windVelocityX = -65.0,
  this.fallSpeedY = 460.0,
  int depthLayers = 3,
  this.gustStrength = 0.0,
  this.gustFrequency = 1.1,
  this.splashRate = 28.0,
  this.onDropImpact,
  this.fallbackBounds = const Rect.fromLTWH(0, 0, 800, 600),
  super.priority = 9000,
  super.cameraMask,
  super.key,
}) extends Component with HasVisibility {
  this {
    _depthLayerCount = depthLayers.clamp(1, 3);
    final n = math.max(1, particleCount);
    _seedX = Float32List(n);
    _seedY = Float32List(n);
    _speedScale = Float32List(n);
    _phase = Float32List(n);
    _layerBand = Uint8List(n);
    _linePoints = Float32List(n * 4);

    // Deterministic Halton-like low-discrepancy distribution across depth
    // parallax bands (`0` = far, `1` = mid, `2` = near foreground):
    for (var i = 0; i < n; i++) {
      final band = i % _depthLayerCount;
      _layerBand[i] = band;
      _seedX[i] = ((i * 0.61803398875) % 1.0) * 4096.0;
      _seedY[i] = ((i * 0.38196601125 + 0.17) % 1.0) * 4096.0;
      final parallaxMul = _depthLayerCount == 1
          ? 1.0
          : (0.66 + (band / (_depthLayerCount - 1)) * 0.68);
      _speedScale[i] = (0.76 + (i % 7) * 0.06) * parallaxMul;
      _phase[i] = i * 0.91;
    }
  }

  WeatherKind kind;
  double intensity;
  double windVelocityX;
  double fallSpeedY;

  /// Amplitude of coherent storm wind gusts added to [windVelocityX].
  double gustStrength;

  /// Oscillation rate in rad/s for storm wind gusts.
  double gustFrequency;

  /// Impacts per second (at `intensity == 1.0`) emitted via [onDropImpact] when
  /// `kind` is `rain` or `hail`.
  double splashRate;

  /// Optional callback invoked at deterministic camera-visible impact points so
  /// rainfall/hail excites `WaterRipplePoolComponent` or
  /// `WaterSurface2DComponent` with zero allocations.
  void Function(double worldX, double worldY)? onDropImpact;

  Rect fallbackBounds;

  late final int _depthLayerCount;
  late final Float32List _seedX;
  late final Float32List _seedY;
  late final Float32List _speedScale;
  late final Float32List _phase;
  late final Uint8List _layerBand;
  late final Float32List _linePoints;

  double _elapsed = 0.0;
  double _gustOffset = 0.0;
  double _splashDebt = 0.0;
  int _splashSeq = 0;
  int _lastActiveDropCount = 0;

  final Paint _paint = Paint()
    ..strokeCap = StrokeCap.round
    ..isAntiAlias = true;

  /// Number of precipitation drops rendered in the last [render] pass.
  int get lastActiveDropCount => _lastActiveDropCount;

  /// Current effective horizontal wind velocity including active gusts.
  double get currentWindVelocityX =>
      windVelocityX +
      (gustStrength == 0.0
          ? 0.0
          : math.sin(_elapsed * gustFrequency) * gustStrength);

  /// Depth parallax band (`0 .. depthLayers - 1`) assigned to drop [index].
  int depthBandOf(int index) => _layerBand[index];

  /// Speed multiplier assigned to drop [index] (monotonically larger for nearer
  /// parallax bands at matching `(index % 7)`).
  double speedScaleOf(int index) => _speedScale[index];

  /// Samples the camera-wrapped world position of drop [index] inside [bounds]
  /// (exposed for deterministic verification).
  Offset sampleDropPosition(int index, Rect bounds) {
    final w = math.max(1.0, bounds.width);
    final h = math.max(1.0, bounds.height);
    final sp = _speedScale[index];
    final sway = switch (kind) {
      WeatherKind.snow => math.sin(_elapsed * 2.4 + _phase[index]) * 18.0,
      WeatherKind.embers => math.sin(_elapsed * 3.1 + _phase[index]) * 24.0,
      WeatherKind.ash => math.sin(_elapsed * 1.8 + _phase[index]) * 30.0,
      _ => 0.0,
    };
    final vy = switch (kind) {
      WeatherKind.embers => -fallSpeedY * 0.35,
      WeatherKind.ash => fallSpeedY * 0.22,
      WeatherKind.hail => fallSpeedY * 1.28,
      _ => fallSpeedY,
    };
    final rawX =
        _seedX[index] + (_elapsed * windVelocityX + _gustOffset) * sp + sway;
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
    final clampedInt = intensity.clamp(0.0, 1.0);
    if (kind == WeatherKind.clear || clampedInt <= 1e-3 || dt <= 0.0) {
      return;
    }
    _elapsed += dt;
    if (gustStrength != 0.0) {
      _gustOffset += math.sin(_elapsed * gustFrequency) * gustStrength * dt;
    }

    final impactCb = onDropImpact;
    if (impactCb != null &&
        splashRate > 0.0 &&
        (kind == WeatherKind.rain || kind == WeatherKind.hail)) {
      _splashDebt += splashRate * clampedInt * dt;
      final count = _splashDebt.floor();
      if (count > 0) {
        _splashDebt -= count;
        final bounds = fallbackBounds;
        for (var k = 0; k < count; k++) {
          _splashSeq = (_splashSeq + 1) & 0x7fffffff;
          final u = (_splashSeq * 0.61803398875) % 1.0;
          final v = (_splashSeq * 0.32471795724 + 0.19) % 1.0;
          impactCb(
            bounds.left + u * bounds.width,
            bounds.top + (0.35 + 0.65 * v) * bounds.height,
          );
        }
      }
    }
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

    final effWindX = currentWindVelocityX;
    var renderedTotal = 0;

    for (var band = 0; band < _depthLayerCount; band++) {
      final bandFrac = _depthLayerCount == 1
          ? 1.0
          : band / (_depthLayerCount - 1);
      final bandAlphaScale = 0.52 + 0.48 * bandFrac;
      final bandWidthScale = 0.72 + 0.52 * bandFrac;
      final bandStreakScale = 0.75 + 0.50 * bandFrac;

      final baseAlpha =
          (clampedInt * bandAlphaScale * (kind == WeatherKind.rain ? 165 : 215))
              .round()
              .clamp(0, 255);
      if (baseAlpha <= 2) {
        continue;
      }

      switch (kind) {
        case WeatherKind.clear:
          return;
        case WeatherKind.rain:
          _paint
            ..color = Color.fromARGB(baseAlpha, 185, 218, 255)
            ..strokeWidth = 1.35 * bandWidthScale;
        case WeatherKind.hail:
          _paint
            ..color = Color.fromARGB(baseAlpha, 228, 245, 255)
            ..strokeWidth = 2.4 * bandWidthScale;
        case WeatherKind.snow:
          _paint
            ..color = Color.fromARGB(baseAlpha, 245, 250, 255)
            ..strokeWidth = 3.2 * bandWidthScale;
        case WeatherKind.embers:
          _paint
            ..color = Color.fromARGB(baseAlpha, 255, 148, 66)
            ..strokeWidth = 2.6 * bandWidthScale;
        case WeatherKind.ash:
          _paint
            ..color = Color.fromARGB(baseAlpha, 168, 166, 174)
            ..strokeWidth = 2.5 * bandWidthScale;
      }

      final streakDx = switch (kind) {
        WeatherKind.rain => effWindX * 0.032 * bandStreakScale,
        WeatherKind.hail => effWindX * 0.016 * bandStreakScale,
        _ => 0.0,
      };
      final streakDy = switch (kind) {
        WeatherKind.rain => fallSpeedY * 0.032 * bandStreakScale,
        WeatherKind.hail => fallSpeedY * 0.020 * bandStreakScale,
        WeatherKind.embers => -3.0 * bandStreakScale,
        WeatherKind.ash => 1.2 * bandStreakScale,
        _ => 0.5,
      };

      var cursor = 0;
      for (var i = 0; i < total; i++) {
        if (_layerBand[i] != band) {
          continue;
        }
        final p = sampleDropPosition(i, bounds);
        _linePoints[cursor++] = p.dx;
        _linePoints[cursor++] = p.dy;
        _linePoints[cursor++] = p.dx + streakDx;
        _linePoints[cursor++] = p.dy + streakDy;
        renderedTotal++;
      }

      if (cursor > 0) {
        final slice = cursor == _linePoints.length
            ? _linePoints
            : Float32List.sublistView(_linePoints, 0, cursor);
        canvas.drawRawPoints(ui.PointMode.lines, slice, _paint);
      }
    }
    _lastActiveDropCount = renderedTotal;
  }
}
