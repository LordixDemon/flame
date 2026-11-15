import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/src/components/mixins/has_visibility.dart';
import 'package:flame/src/components/position_component.dart';
import 'package:flame/src/game/game.dart';

/// Animated 2D/HD-2D water surface component featuring shoreline foam,
/// horizontal wave-displaced planar reflection strips (compatible with
/// `RenderTextureComponent.texture`), and animated specular glints.
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
  ui.Color deepColor;
  ui.Color shallowColor;
  ui.Color foamColor;
  ui.Color glintColor;
  double shoreFoamHeight;
  double waveSpeed;
  double waveAmplitudePx;
  double reflectionOpacity;
  int reflectionBands;

  /// Optional live planar reflection image (e.g. from a
  /// `RenderTextureComponent`).
  ui.Image? reflectionTexture;

  double _elapsed = 0.0;
  final ui.Paint _fillPaint = ui.Paint();
  final ui.Paint _foamPaint = ui.Paint();
  final ui.Paint _reflPaint = ui.Paint()
    ..filterQuality = ui.FilterQuality.medium;
  final Float32List _glintSegments = Float32List(32);

  double get elapsed => _elapsed;

  @override
  void update(double dt) {
    super.update(dt);
    if (dt > 0.0 && waveSpeed != 0.0) {
      _elapsed += dt;
      Game.notifyVisualMutation();
    }
  }

  @override
  void render(ui.Canvas canvas) {
    if (size.x <= 0.0 || size.y <= 0.0) {
      return;
    }
    final rect = ui.Rect.fromLTWH(0, 0, size.x, size.y);

    // 1. Depth gradient base:
    _fillPaint.shader = ui.Gradient.linear(
      ui.Offset.zero,
      ui.Offset(0, size.y),
      <ui.Color>[shallowColor, deepColor],
    );
    canvas.drawRect(rect, _fillPaint);

    // 2. Wave-rippled planar reflection bands:
    final refl = reflectionTexture;
    if (refl != null && reflectionOpacity > 1e-3 && reflectionBands > 0) {
      final bands = reflectionBands.clamp(1, 64);
      final bandDstH = size.y / bands;
      final bandSrcH = refl.height / bands;
      _reflPaint.color = ui.Color.fromARGB(
        (reflectionOpacity.clamp(0.0, 1.0) * 255).round(),
        255,
        255,
        255,
      );
      canvas.save();
      canvas.clipRect(rect);
      for (var b = 0; b < bands; b++) {
        final waveDx =
            math.sin(_elapsed * waveSpeed + b * 0.85) * waveAmplitudePx;
        // Vertically flip reflection bands (top of water reflects bottom of
        // shore scene!):
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
          size.x,
          bandDstH + 0.5,
        );
        canvas.drawImageRect(refl, src, dst, _reflPaint);
      }
      canvas.restore();
    }

    // 3. Undulating shoreline foam ribbon:
    if (shoreFoamHeight > 0.0) {
      final pulse = 1.0 + 0.22 * math.sin(_elapsed * waveSpeed * 1.4);
      final fh = (shoreFoamHeight * pulse).clamp(1.0, size.y);
      _foamPaint.shader = ui.Gradient.linear(
        ui.Offset.zero,
        ui.Offset(0, fh),
        <ui.Color>[foamColor, const ui.Color(0x00FFFFFF)],
      );
      canvas.drawRect(ui.Rect.fromLTWH(0, 0, size.x, fh), _foamPaint);
    }

    // 4. Animated specular sun/moon water glints:
    _foamPaint
      ..shader = null
      ..color = glintColor
      ..strokeWidth = 1.6
      ..strokeCap = ui.StrokeCap.round;
    var cursor = 0;
    for (var i = 0; i < 8; i++) {
      final shimmer = math.sin(_elapsed * waveSpeed * 1.8 + i * 1.7);
      if (shimmer <= 0.15) {
        continue;
      }
      final gx =
          ((i * 0.37 + 0.11) % 0.86 + 0.05) * size.x +
          math.cos(_elapsed + i) * 4.0;
      final gy = ((i * 0.29 + 0.18) % 0.75 + 0.15) * size.y;
      final halfLen = (4.0 + 8.0 * shimmer).clamp(2.0, size.x * 0.25);
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
