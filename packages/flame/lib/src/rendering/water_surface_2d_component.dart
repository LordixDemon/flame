import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/src/components/mixins/has_visibility.dart';
import 'package:flame/src/components/position_component.dart';
import 'package:flame/src/game/game.dart';

/// Interactive 2D/HD-2D shallow-water surface component featuring:
/// - Zero-allocation 1D coupled spring-wave column physics ([splash],
///   [sampleSurfaceY], [sampleSlope]),
/// - Deformable `Vertices.raw(VertexMode.triangleStrip)` water body and
///   crest-reactive shoreline foam,
/// - Wave-displaced planar reflection strips (compatible with
///   `RenderTextureComponent.texture`),
/// - Subsurface caustic ribbons and animated specular glints.
class WaterSurface2DComponent({
  this.deepColor = const ui.Color(0xFF164A7A),
  this.shallowColor = const ui.Color(0xFF2C82B5),
  this.foamColor = const ui.Color(0xD8EEF9FF),
  this.glintColor = const ui.Color(0x99FFFBE0),
  this.shoreFoamHeight = 6.0,
  this.waveSpeed = 2.2,
  this.waveAmplitudePx = 3.5,
  this.reflectionOpacity = 0.38,
  this.reflectionBands = 12,
  this.reflectionTexture,
  int simulationColumns = 48,
  this.springStiffness = 145.0,
  this.waveDamping = 3.2,
  this.waveSpread = 0.26,
  this.enableCaustics = true,
  super.position,
  super.size,
  super.scale,
  super.angle,
  super.anchor,
  super.priority,
  super.sortKey,
  super.cameraMask,
  super.key,
}) extends PositionComponent with HasVisibility {
  this
    : assert(
        simulationColumns >= 4,
        'simulationColumns must be at least 4',
      ) {
    _columnCount = simulationColumns;
    _colHeight = Float32List(_columnCount);
    _colVel = Float32List(_columnCount);
    _leftDelta = Float32List(_columnCount);
    _rightDelta = Float32List(_columnCount);
    _stripPositions = Float32List(_columnCount * 4);
    _stripColors = Int32List(_columnCount * 2);
    _foamPositions = Float32List(_columnCount * 4);
    _foamColors = Int32List(_columnCount * 2);
  }

  ui.Color deepColor;
  ui.Color shallowColor;
  ui.Color foamColor;
  ui.Color glintColor;
  double shoreFoamHeight;
  double waveSpeed;
  double waveAmplitudePx;
  double reflectionOpacity;
  int reflectionBands;

  /// Hooke restoring spring stiffness for dynamic surface wave columns.
  double springStiffness;

  /// Velocity damping rate (`1/s`) applied to dynamic surface wave columns.
  double waveDamping;

  /// Neighbor-to-neighbor wave propagation coupling (`0.0 .. 0.45`).
  double waveSpread;

  /// Whether animated subsurface caustic shimmer lines are rendered.
  bool enableCaustics;

  /// Optional live planar reflection image (e.g. from a
  /// `RenderTextureComponent`).
  ui.Image? reflectionTexture;

  late final int _columnCount;
  late final Float32List _colHeight;
  late final Float32List _colVel;
  late final Float32List _leftDelta;
  late final Float32List _rightDelta;
  late final Float32List _stripPositions;
  late final Int32List _stripColors;
  late final Float32List _foamPositions;
  late final Int32List _foamColors;

  double _elapsed = 0.0;
  bool _hasActiveWaves = false;

  final ui.Paint _meshPaint = ui.Paint();
  final ui.Paint _foamPaint = ui.Paint();
  final ui.Paint _causticPaint = ui.Paint()..blendMode = ui.BlendMode.plus;
  final ui.Paint _reflPaint = ui.Paint()
    ..filterQuality = ui.FilterQuality.medium;
  final Float32List _glintSegments = Float32List(48);

  /// Elapsed animation time in seconds.
  double get elapsed => _elapsed;

  /// Number of simulated 1D surface wave columns.
  int get columnCount => _columnCount;

  /// Total mechanical energy (kinetic + spring potential) of dynamic ripples.
  double get waveMechanicalEnergy {
    var energy = 0.0;
    for (var i = 0; i < _columnCount; i++) {
      final h = _colHeight[i];
      final v = _colVel[i];
      energy += 0.5 * (v * v + springStiffness * h * h);
    }
    return energy;
  }

  /// Injects a vertical velocity [impulse] (positive = downward depression,
  /// negative = upward plume) centered at [localX] across [radius] pixels.
  void splash(double localX, double impulse, {double radius = 20.0}) {
    if (impulse == 0.0 || size.x <= 0.0) {
      return;
    }
    final width = size.x;
    final clampedX = localX.clamp(0.0, width);
    final sigma = math.max(2.0, radius);
    final invTwoSigmaSq = 0.5 / (sigma * sigma);
    final stepX = width / (_columnCount - 1);

    for (var i = 0; i < _columnCount; i++) {
      final cx = i * stepX;
      final dx = cx - clampedX;
      final w = math.exp(-dx * dx * invTwoSigmaSq);
      if (w > 1e-3) {
        _colVel[i] += impulse * w;
      }
    }
    _hasActiveWaves = true;
    Game.notifyVisualMutation();
  }

  /// Resets all dynamic wave column displacements and velocities to rest.
  void clearWaves() {
    _colHeight.fillRange(0, _columnCount, 0.0);
    _colVel.fillRange(0, _columnCount, 0.0);
    _hasActiveWaves = false;
  }

  /// Samples the pure dynamic splash wave displacement at [localX] in pixels.
  double sampleDynamicWaveHeight(double localX) {
    if (size.x <= 0.0) {
      return _colHeight[0];
    }
    final u = (localX / size.x).clamp(0.0, 1.0) * (_columnCount - 1);
    final i0 = u.floor().clamp(0, _columnCount - 1);
    final i1 = math.min(_columnCount - 1, i0 + 1);
    final frac = u - i0;
    return _colHeight[i0] + (_colHeight[i1] - _colHeight[i0]) * frac;
  }

  /// Samples the combined local surface Y coordinate (ambient swell + dynamic
  /// splash waves) at [localX], suitable for floating buoyant objects.
  double sampleSurfaceY(double localX) {
    final swell = waveSpeed == 0.0
        ? 0.0
        : math.sin(_elapsed * waveSpeed + localX * 0.035) *
              waveAmplitudePx *
              0.35;
    return swell + sampleDynamicWaveHeight(localX);
  }

  /// Samples the surface tangent slope `dy / dx` at [localX] for pitching
  /// floating boats or debris.
  double sampleSlope(double localX) {
    const eps = 2.0;
    final yL = sampleSurfaceY(localX - eps);
    final yR = sampleSurfaceY(localX + eps);
    return (yR - yL) / (2.0 * eps);
  }

  @override
  void update(double dt) {
    super.update(dt);
    if (dt <= 0.0) {
      return;
    }
    var mutated = false;
    if (waveSpeed != 0.0) {
      _elapsed += dt;
      mutated = true;
    }
    if (_hasActiveWaves) {
      _stepWaveColumns(dt.clamp(0.0, 0.05));
      mutated = true;
    }
    if (mutated) {
      Game.notifyVisualMutation();
    }
  }

  void _stepWaveColumns(double dt) {
    // Sub-step at <= 1/120s so stiff Hooke waves remain unconditionally stable.
    final steps = math.max(1, (dt * 120.0).ceil());
    final subDt = dt / steps;
    final spread = waveSpread.clamp(0.0, 0.45);
    final dampFactor = math.max(0.0, 1.0 - waveDamping * subDt);
    final n = _columnCount;

    for (var s = 0; s < steps; s++) {
      for (var i = 0; i < n; i++) {
        final acc = -springStiffness * _colHeight[i];
        _colVel[i] = (_colVel[i] + acc * subDt) * dampFactor;
        _colHeight[i] += _colVel[i] * subDt;
      }
      for (var pass = 0; pass < 2; pass++) {
        for (var i = 0; i < n; i++) {
          if (i > 0) {
            final dL = spread * (_colHeight[i] - _colHeight[i - 1]);
            _leftDelta[i] = dL;
            _colVel[i - 1] += dL * 18.0 * subDt;
          }
          if (i < n - 1) {
            final dR = spread * (_colHeight[i] - _colHeight[i + 1]);
            _rightDelta[i] = dR;
            _colVel[i + 1] += dR * 18.0 * subDt;
          }
        }
        for (var i = 0; i < n; i++) {
          if (i > 0) {
            _colHeight[i - 1] += _leftDelta[i] * 0.5;
          }
          if (i < n - 1) {
            _colHeight[i + 1] += _rightDelta[i] * 0.5;
          }
        }
      }
    }

    var maxAbs = 0.0;
    for (var i = 0; i < n; i++) {
      final a = _colHeight[i].abs() + _colVel[i].abs();
      if (a > maxAbs) {
        maxAbs = a;
      }
    }
    if (maxAbs < 1e-4) {
      clearWaves();
    }
  }

  @override
  void render(ui.Canvas canvas) {
    if (size.x <= 0.0 || size.y <= 0.0) {
      return;
    }
    final width = size.x;
    final height = size.y;
    final n = _columnCount;
    final stepX = width / (n - 1);
    final shallowArgb = shallowColor.toARGB32();
    final deepArgb = deepColor.toARGB32();

    // 1. Deformable shallow-to-deep water body triangle strip:
    for (var i = 0; i < n; i++) {
      final x = i * stepX;
      final swell = waveSpeed == 0.0
          ? 0.0
          : math.sin(_elapsed * waveSpeed + x * 0.035) * waveAmplitudePx * 0.35;
      final surfY = (swell + _colHeight[i]).clamp(-height * 0.45, height * 0.6);
      final p = i * 4;
      _stripPositions[p] = x;
      _stripPositions[p + 1] = surfY;
      _stripPositions[p + 2] = x;
      _stripPositions[p + 3] = height;
      _stripColors[i * 2] = shallowArgb;
      _stripColors[i * 2 + 1] = deepArgb;
    }

    final bodyVerts = ui.Vertices.raw(
      ui.VertexMode.triangleStrip,
      _stripPositions,
      colors: _stripColors,
    );
    canvas.drawVertices(bodyVerts, ui.BlendMode.dst, _meshPaint);
    bodyVerts.dispose();

    final clipBounds = ui.Rect.fromLTWH(
      0,
      -height * 0.45,
      width,
      height * 1.45,
    );

    // 2. Wave-rippled planar reflection bands:
    final refl = reflectionTexture;
    if (refl != null && reflectionOpacity > 1e-3 && reflectionBands > 0) {
      final bands = reflectionBands.clamp(1, 64);
      final bandDstH = height / bands;
      final bandSrcH = refl.height / bands;
      _reflPaint.color = ui.Color.fromARGB(
        (reflectionOpacity.clamp(0.0, 1.0) * 255).round(),
        255,
        255,
        255,
      );
      canvas.save();
      canvas.clipRect(clipBounds);
      for (var b = 0; b < bands; b++) {
        final waveDx =
            math.sin(_elapsed * waveSpeed + b * 0.85) * waveAmplitudePx +
            sampleDynamicWaveHeight(width * 0.5) * 0.35;
        final srcRow = bands - 1 - b;
        final src = ui.Rect.fromLTWH(
          0,
          srcRow * bandSrcH,
          refl.width.toDouble(),
          bandSrcH,
        );
        final dst = ui.Rect.fromLTWH(
          waveDx,
          b * bandDstH,
          width,
          bandDstH + 0.5,
        );
        canvas.drawImageRect(refl, src, dst, _reflPaint);
      }
      canvas.restore();
    }

    // 3. Crest-reactive undulating shoreline foam strip:
    if (shoreFoamHeight > 0.0) {
      final pulse = 1.0 + 0.22 * math.sin(_elapsed * waveSpeed * 1.4);
      final baseFoamH = (shoreFoamHeight * pulse).clamp(1.0, height);
      final foamBaseA = (foamColor.a * 255).round();
      final foamRgb = foamColor.toARGB32() & 0x00FFFFFF;

      for (var i = 0; i < n; i++) {
        final p = i * 4;
        final x = _stripPositions[p];
        final surfY = _stripPositions[p + 1];
        final crestBoost = (-_colHeight[i] * 0.35).clamp(0.0, baseFoamH * 1.6);
        final fh = baseFoamH + crestBoost;
        final aTop = (foamBaseA * (1.0 + crestBoost * 0.08)).round().clamp(
          0,
          255,
        );
        _foamPositions[p] = x;
        _foamPositions[p + 1] = surfY;
        _foamPositions[p + 2] = x;
        _foamPositions[p + 3] = math.min(height, surfY + fh);
        _foamColors[i * 2] = (aTop << 24) | foamRgb;
        _foamColors[i * 2 + 1] = foamRgb; // alpha = 0
      }

      final foamVerts = ui.Vertices.raw(
        ui.VertexMode.triangleStrip,
        _foamPositions,
        colors: _foamColors,
      );
      canvas.drawVertices(foamVerts, ui.BlendMode.dst, _meshPaint);
      foamVerts.dispose();
    }

    // 4. Subsurface caustic shimmer + specular sun/moon water glints:
    var cursor = 0;
    if (enableCaustics) {
      _causticPaint
        ..color = const ui.Color(0x2890E0FF)
        ..strokeWidth = 2.2
        ..strokeCap = ui.StrokeCap.round;
      for (var c = 0; c < 6; c++) {
        final cx = ((c * 0.19 + 0.09 + _elapsed * 0.03) % 0.88 + 0.06) * width;
        final cy =
            ((c * 0.23 + 0.28) % 0.62 + 0.22) * height +
            math.sin(_elapsed * 1.7 + c) * 2.5;
        final len = 10.0 + 6.0 * math.sin(_elapsed * 2.1 + c * 1.3).abs();
        _glintSegments[cursor++] = cx - len;
        _glintSegments[cursor++] = cy;
        _glintSegments[cursor++] = cx + len;
        _glintSegments[cursor++] = cy + 1.5;
      }
      if (cursor > 0) {
        canvas.drawRawPoints(
          ui.PointMode.lines,
          Float32List.sublistView(_glintSegments, 0, cursor),
          _causticPaint,
        );
      }
    }

    _foamPaint
      ..shader = null
      ..color = glintColor
      ..strokeWidth = 1.6
      ..strokeCap = ui.StrokeCap.round;
    cursor = 0;
    for (var i = 0; i < 8; i++) {
      final shimmer = math.sin(_elapsed * waveSpeed * 1.8 + i * 1.7);
      if (shimmer <= 0.15) {
        continue;
      }
      final gx =
          ((i * 0.37 + 0.11) % 0.86 + 0.05) * width +
          math.cos(_elapsed + i) * 4.0;
      final gy = ((i * 0.29 + 0.18) % 0.75 + 0.15) * height;
      final halfLen = (4.0 + 8.0 * shimmer).clamp(2.0, width * 0.25);
      _glintSegments[cursor++] = gx - halfLen;
      _glintSegments[cursor++] = gy;
      _glintSegments[cursor++] = gx + halfLen;
      _glintSegments[cursor++] = gy;
    }
    if (cursor > 0) {
      canvas.drawRawPoints(
        ui.PointMode.lines,
        Float32List.sublistView(_glintSegments, 0, cursor),
        _foamPaint,
      );
    }
  }
}
