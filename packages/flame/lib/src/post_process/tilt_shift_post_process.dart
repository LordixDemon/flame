import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flame/src/post_process/post_process.dart';
import 'package:flutter/painting.dart';
import 'package:vector_math/vector_math.dart';

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
  final Paint _basePaint = Paint()..filterQuality = FilterQuality.medium;
  final Paint _farBlurPaint = Paint()..filterQuality = FilterQuality.medium;
  final Paint _nearBlurPaint = Paint()..filterQuality = FilterQuality.medium;
  final Paint _maskPaint = Paint()..blendMode = BlendMode.dstIn;
  final Paint _layerPaint = Paint();

  double _cachedFarSigma = -1.0;
  double _cachedNearSigma = -1.0;

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
      releaseFrameResources();
      renderSubtree(canvas);
      return;
    }
    final sceneImage = rasterizeSubtree();
    holdFrameImage(sceneImage);
    renderFromImage(sceneImage, size, canvas);
  }
}
