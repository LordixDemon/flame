import 'dart:ui' as ui;

import 'package:flame/components.dart';
import 'package:flame/post_process.dart';
import 'package:flutter/painting.dart';

/// Zero-asset GPU Contrast-Adaptive Sharpening (CAS) helper and [PostProcess].
///
/// Extracts signed high-frequency spatial detail `0.5 + a * (I - B)` without
/// clamping loss across `[0..1]` and composites it onto the base image via
/// `BlendMode.hardLight`, naturally boosting local edge contrast while
/// attenuating halos near pure black (`0.0`) and pure white (`1.0`).
abstract final class ContrastAdaptiveSharpenHelper._() {
  static final Paint _basePaint = Paint();
  static final Paint _layerPaint = Paint()..blendMode = BlendMode.hardLight;
  static final Paint _term1Paint = Paint();
  static final Paint _term2Paint = Paint()..blendMode = BlendMode.plus;

  static double _cachedStrength = -1.0;
  static double _cachedRadius = -1.0;
  static ColorFilter? _cachedTerm1Filter;
  static ColorFilter? _cachedTerm2Filter;
  static ui.ImageFilter? _cachedBlurFilter;

  static void _ensureFilters(double strength, double radiusPx) {
    if ((_cachedStrength - strength).abs() > 1e-4) {
      _cachedStrength = strength;
      final a = (0.5 * strength).clamp(0.0, 0.5);
      final bias1 = (0.5 - a) * 255.0;
      _cachedTerm1Filter = ColorFilter.matrix(<double>[
        a,
        0,
        0,
        0,
        bias1,
        0,
        a,
        0,
        0,
        bias1,
        0,
        0,
        a,
        0,
        bias1,
        0,
        0,
        0,
        1,
        0,
      ]);
      final bias2 = a * 255.0;
      _cachedTerm2Filter = ColorFilter.matrix(<double>[
        -a,
        0,
        0,
        0,
        bias2,
        0,
        -a,
        0,
        0,
        bias2,
        0,
        0,
        -a,
        0,
        bias2,
        0,
        0,
        0,
        1,
        0,
      ]);
    }
    if ((_cachedRadius - radiusPx).abs() > 1e-4) {
      _cachedRadius = radiusPx;
      _cachedBlurFilter = ui.ImageFilter.blur(
        sigmaX: radiusPx,
        sigmaY: radiusPx,
        tileMode: TileMode.clamp,
      );
    }
  }

  /// Draws [image] from [srcRect] into [dstRect] on [canvas] with
  /// contrast-adaptive sharpening of [strength] (`0.0 .. 1.0`).
  static void drawSharpenedImageRect(
    Canvas canvas,
    ui.Image image,
    Rect srcRect,
    Rect dstRect, {
    required double strength,
    FilterQuality filterQuality = FilterQuality.medium,
    double radiusLogicalPx = 0.85,
  }) {
    _basePaint.filterQuality = filterQuality;
    canvas.drawImageRect(image, srcRect, dstRect, _basePaint);

    final clamped = strength.clamp(0.0, 1.0);
    if (clamped <= 1e-3 || dstRect.isEmpty) {
      return;
    }

    final safeRadius = radiusLogicalPx.clamp(0.25, 3.0);
    _ensureFilters(clamped, safeRadius);

    _term1Paint
      ..filterQuality = filterQuality
      ..colorFilter = _cachedTerm1Filter;
    _term2Paint
      ..filterQuality = filterQuality
      ..colorFilter = _cachedTerm2Filter
      ..imageFilter = _cachedBlurFilter;

    canvas.saveLayer(dstRect, _layerPaint);
    canvas.drawImageRect(image, srcRect, dstRect, _term1Paint);
    canvas.drawImageRect(image, srcRect, dstRect, _term2Paint);
    canvas.restore();
  }
}

/// Post-processing stage that applies Contrast-Adaptive Sharpening (CAS) to
/// restore crisp micro-contrast after upscaling (`renderScale < 1.0`) or SSAA
/// supersampling (`renderScale > 1.0`).
class ContrastAdaptiveSharpenPostProcess({
  var double strength = 0.35,
  var double radiusPx = 0.85,
  var bool enabled = true,
  var FilterQuality filterQuality = FilterQuality.medium,
  super.pixelRatio,
}) extends PostProcess {
  ui.Image? _heldImage;

  void _replaceHeldImage(ui.Image? next) {
    if (!identical(_heldImage, next)) {
      _heldImage?.dispose();
      _heldImage = next;
    }
  }

  @override
  bool get isEffectivelyNoOp => !enabled || strength.clamp(0.0, 1.0) <= 1e-3;

  @override
  bool get supportsImageInput => true;

  @override
  bool renderFromImage(ui.Image inputImage, Vector2 size, Canvas canvas) {
    final srcRect = Rect.fromLTWH(
      0,
      0,
      inputImage.width.toDouble(),
      inputImage.height.toDouble(),
    );
    final dstRect = Rect.fromLTWH(0, 0, size.x, size.y);
    final clampedStrength = enabled ? strength.clamp(0.0, 1.0) : 0.0;
    ContrastAdaptiveSharpenHelper.drawSharpenedImageRect(
      canvas,
      inputImage,
      srcRect,
      dstRect,
      strength: clampedStrength,
      filterQuality: filterQuality,
      radiusLogicalPx: radiusPx,
    );
    return true;
  }

  @override
  void postProcess(Vector2 size, Canvas canvas) {
    final clampedStrength = strength.clamp(0.0, 1.0);
    if (!enabled || clampedStrength <= 1e-3 || size.x < 2 || size.y < 2) {
      renderSubtree(canvas);
      return;
    }

    final ui.Image frameImage;
    try {
      frameImage = rasterizeSubtree();
    } on Object {
      renderSubtree(canvas);
      return;
    }
    _replaceHeldImage(frameImage);
    renderFromImage(frameImage, size, canvas);
  }

  @override
  void onRemove() {
    _replaceHeldImage(null);
    super.onRemove();
  }
}
