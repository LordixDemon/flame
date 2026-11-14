import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flame/components.dart';
import 'package:flame/post_process.dart';
import 'package:flame/src/rendering/decorator.dart';
import 'package:flutter/painting.dart';

/// Built-in color grading presets for [ColorGradingPostProcess].
enum ColorGradingPreset() {
  /// Identity color response.
  neutral,

  /// Golden-hour warm amber highlights and soft magenta shadows.
  warmSunset,

  /// Crisp nocturnal cyan/indigo tint with subdued reds.
  coolMoonlight,

  /// Classic archival sepia tone.
  sepia,

  /// High-contrast monochrome film noir.
  noir,

  /// Punchy saturated arcade palette.
  vibrantPop,
}

/// Ready-to-use soft HDR-style bloom [PostProcess] requiring zero external
/// `.frag` shader asset files.
///
/// Extracts bright highlights above [threshold] (`0.0 .. 1.0`), blurs them by
/// [sigma] logical pixels, and additively composites (`BlendMode.plus`) them
/// back onto the scene with [intensity], deterministically disposing its
/// intermediate `ui.Image`.
class BloomPostProcess({
  var double threshold = 0.68,
  var double intensity = 0.55,
  var double sigma = 8.0,
  var bool enabled = true,
  super.pixelRatio,
}) extends PostProcess {
  ui.Image? _heldImage;
  final Paint _basePaint = Paint()..filterQuality = FilterQuality.medium;
  final Paint _bloomPaint = Paint()
    ..blendMode = BlendMode.plus
    ..filterQuality = FilterQuality.medium;

  double _cachedThreshold = -1.0;
  double _cachedIntensity = -1.0;
  double _cachedSigma = -1.0;

  void _replaceHeldImage(ui.Image? next) {
    if (!identical(_heldImage, next)) {
      _heldImage?.dispose();
      _heldImage = next;
    }
  }

  void _syncFilters(double t, double gain, double blurSigma) {
    if ((_cachedThreshold - t).abs() > 1e-4 ||
        (_cachedIntensity - gain).abs() > 1e-4) {
      _cachedThreshold = t;
      _cachedIntensity = gain;
      final invSpan = 1.0 / math.max(0.05, 1.0 - t);
      final scale = invSpan * gain;
      final bias = -t * scale * 255.0;
      _bloomPaint.colorFilter = ColorFilter.matrix(<double>[
        scale,
        0,
        0,
        0,
        bias,
        0,
        scale,
        0,
        0,
        bias,
        0,
        0,
        scale,
        0,
        bias,
        0,
        0,
        0,
        1,
        0,
      ]);
    }
    if ((_cachedSigma - blurSigma).abs() > 1e-4) {
      _cachedSigma = blurSigma;
      _bloomPaint.imageFilter = ui.ImageFilter.blur(
        sigmaX: blurSigma,
        sigmaY: blurSigma,
        tileMode: TileMode.decal,
      );
    }
  }

  @override
  void postProcess(Vector2 size, Canvas canvas) {
    final clampedGain = intensity.clamp(0.0, 3.0);
    if (!enabled || clampedGain <= 1e-3 || size.x < 2 || size.y < 2) {
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

    final src = Rect.fromLTWH(
      0,
      0,
      frameImage.width.toDouble(),
      frameImage.height.toDouble(),
    );
    final dst = Rect.fromLTWH(0, 0, size.x, size.y);
    _syncFilters(
      threshold.clamp(0.0, 0.95),
      clampedGain,
      sigma.clamp(0.5, 48.0),
    );

    canvas.drawImageRect(frameImage, src, dst, _basePaint);
    canvas.drawImageRect(frameImage, src, dst, _bloomPaint);
  }

  @override
  void onRemove() {
    _replaceHeldImage(null);
    super.onRemove();
  }
}

/// Zero-asset radial lens vignette [PostProcess] with cached gradient shader.
class VignettePostProcess({
  var double intensity = 0.42,
  var double innerRadius = 0.48,
  var double outerRadius = 1.0,
  var Color color = const Color(0xFF09070F),
  var bool enabled = true,
  super.pixelRatio,
}) extends PostProcess {
  final Paint _vignettePaint = Paint();
  Vector2 _cachedSize = Vector2.zero();
  double _cachedIntensity = -1.0;
  double _cachedInner = -1.0;
  double _cachedOuter = -1.0;
  int _cachedArgb = -1;

  @override
  void postProcess(Vector2 size, Canvas canvas) {
    renderSubtree(canvas);
    final clamped = intensity.clamp(0.0, 1.0);
    if (!enabled || clamped <= 1e-3 || size.x < 2 || size.y < 2) {
      return;
    }

    final argb = color.toARGB32();
    final inR = innerRadius.clamp(0.0, 0.98);
    final outR = math.max(inR + 0.02, outerRadius.clamp(0.05, 2.0));
    if (_cachedSize != size ||
        (_cachedIntensity - clamped).abs() > 1e-4 ||
        (_cachedInner - inR).abs() > 1e-4 ||
        (_cachedOuter - outR).abs() > 1e-4 ||
        _cachedArgb != argb) {
      _cachedSize = size.clone();
      _cachedIntensity = clamped;
      _cachedInner = inR;
      _cachedOuter = outR;
      _cachedArgb = argb;

      final halfDiag =
          math.sqrt(size.x * size.x + size.y * size.y) * 0.5 * outR;
      final edgeColor = color.withValues(
        alpha: (color.a * clamped).clamp(0, 1),
      );
      _vignettePaint.shader = ui.Gradient.radial(
        Offset(size.x * 0.5, size.y * 0.5),
        math.max(1.0, halfDiag),
        <Color>[const Color(0x00000000), edgeColor],
        <double>[(inR / outR).clamp(0.0, 0.99), 1.0],
      );
    }

    canvas.drawRect(Rect.fromLTWH(0, 0, size.x, size.y), _vignettePaint);
  }
}

/// Zero-asset RGB channel split [PostProcess] for impact shockwaves, damage
/// hits, speed boosts, and glitch transitions.
class ChromaticAberrationPostProcess({
  var double offsetPx = 2.5,
  var double angleRad = 0.0,
  var bool enabled = true,
  super.pixelRatio,
}) extends PostProcess {
  ui.Image? _heldImage;

  static final Paint _redPaint = Paint()
    ..filterQuality = FilterQuality.medium
    ..colorFilter = const ColorFilter.matrix(<double>[
      1, 0, 0, 0, 0, // R
      0, 0, 0, 0, 0,
      0, 0, 0, 0, 0,
      0, 0, 0, 1, 0,
    ]);

  static final Paint _greenPaint = Paint()
    ..blendMode = BlendMode.plus
    ..filterQuality = FilterQuality.medium
    ..colorFilter = const ColorFilter.matrix(<double>[
      0, 0, 0, 0, 0,
      0, 1, 0, 0, 0, // G
      0, 0, 0, 0, 0,
      0, 0, 0, 1, 0,
    ]);

  static final Paint _bluePaint = Paint()
    ..blendMode = BlendMode.plus
    ..filterQuality = FilterQuality.medium
    ..colorFilter = const ColorFilter.matrix(<double>[
      0, 0, 0, 0, 0,
      0, 0, 0, 0, 0,
      0, 0, 1, 0, 0, // B
      0, 0, 0, 1, 0,
    ]);

  static final Paint _layerPaint = Paint();

  void _replaceHeldImage(ui.Image? next) {
    if (!identical(_heldImage, next)) {
      _heldImage?.dispose();
      _heldImage = next;
    }
  }

  @override
  void postProcess(Vector2 size, Canvas canvas) {
    if (!enabled || offsetPx.abs() <= 1e-2 || size.x < 2 || size.y < 2) {
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

    final src = Rect.fromLTWH(
      0,
      0,
      frameImage.width.toDouble(),
      frameImage.height.toDouble(),
    );
    final dx = math.cos(angleRad) * offsetPx;
    final dy = math.sin(angleRad) * offsetPx;
    final bounds = Rect.fromLTWH(0, 0, size.x, size.y);

    canvas.saveLayer(bounds, _layerPaint);
    canvas.drawImageRect(
      frameImage,
      src,
      Rect.fromLTWH(-dx, -dy, size.x, size.y),
      _redPaint,
    );
    canvas.drawImageRect(frameImage, src, bounds, _greenPaint);
    canvas.drawImageRect(
      frameImage,
      src,
      Rect.fromLTWH(dx, dy, size.x, size.y),
      _bluePaint,
    );
    canvas.restore();
  }

  @override
  void onRemove() {
    _replaceHeldImage(null);
    super.onRemove();
  }
}

/// Zero-asset `4x5` color matrix grading [PostProcess] with artistic presets,
/// exposure, contrast, saturation, and temperature controls.
class ColorGradingPostProcess({
  var ColorGradingPreset preset = ColorGradingPreset.neutral,
  var double exposure = 0.0,
  var double contrast = 1.0,
  var double saturation = 1.0,
  var double temperature = 0.0,
  var bool enabled = true,
  super.pixelRatio,
}) extends PostProcess {
  final Paint _gradePaint = Paint();
  int _cachedHash = 0;

  /// Computes the 20-element Flutter `ColorFilter.matrix` for the current
  /// grading parameters.
  List<double> computeColorMatrix() {
    var rGain = 1.0;
    var gGain = 1.0;
    var bGain = 1.0;
    var sat = saturation;
    var con = contrast;

    switch (preset) {
      case ColorGradingPreset.neutral:
        break;
      case ColorGradingPreset.warmSunset:
        rGain = 1.10;
        gGain = 1.01;
        bGain = 0.88;
        sat *= 1.12;
        con *= 1.05;
      case ColorGradingPreset.coolMoonlight:
        rGain = 0.84;
        gGain = 0.96;
        bGain = 1.16;
        sat *= 0.82;
        con *= 1.06;
      case ColorGradingPreset.sepia:
        return <double>[
          0.393,
          0.769,
          0.189,
          0,
          0,
          0.349,
          0.686,
          0.168,
          0,
          0,
          0.272,
          0.534,
          0.131,
          0,
          0,
          0,
          0,
          0,
          1,
          0,
        ];
      case ColorGradingPreset.noir:
        sat = 0.0;
        con *= 1.32;
      case ColorGradingPreset.vibrantPop:
        sat *= 1.30;
        con *= 1.10;
    }

    final expFactor = math.pow(2.0, exposure.clamp(-4.0, 4.0)).toDouble();
    final temp = temperature.clamp(-1.0, 1.0);
    rGain *= (1.0 + temp * 0.14) * expFactor;
    bGain *= (1.0 - temp * 0.14) * expFactor;
    gGain *= expFactor;

    final s = sat.clamp(0.0, 3.0);
    const lumR = 0.2126;
    const lumG = 0.7152;
    const lumB = 0.0722;

    final sr = (1.0 - s) * lumR;
    final sg = (1.0 - s) * lumG;
    final sb = (1.0 - s) * lumB;

    final c = con.clamp(0.1, 3.0);
    final intercept = 128.0 * (1.0 - c);

    return <double>[
      (sr + s) * rGain * c,
      sg * rGain * c,
      sb * rGain * c,
      0,
      intercept,
      sr * gGain * c,
      (sg + s) * gGain * c,
      sb * gGain * c,
      0,
      intercept,
      sr * bGain * c,
      sg * bGain * c,
      (sb + s) * bGain * c,
      0,
      intercept,
      0,
      0,
      0,
      1,
      0,
    ];
  }

  void _syncPaint() {
    final hash = Object.hash(
      preset,
      (exposure * 1000).round(),
      (contrast * 1000).round(),
      (saturation * 1000).round(),
      (temperature * 1000).round(),
    );
    if (hash != _cachedHash) {
      _cachedHash = hash;
      _gradePaint.colorFilter = ColorFilter.matrix(computeColorMatrix());
    }
  }

  @override
  void postProcess(Vector2 size, Canvas canvas) {
    if (!enabled ||
        (preset == ColorGradingPreset.neutral &&
            exposure.abs() < 1e-4 &&
            (contrast - 1.0).abs() < 1e-4 &&
            (saturation - 1.0).abs() < 1e-4 &&
            temperature.abs() < 1e-4)) {
      renderSubtree(canvas);
      return;
    }
    _syncPaint();
    canvas.saveLayer(Rect.fromLTWH(0, 0, size.x, size.y), _gradePaint);
    renderSubtree(canvas);
    canvas.restore();
  }
}

/// Crisp silhouette selection/highlight outline [Decorator] for any 2D
/// component or sprite, requiring zero custom shaders.
class OutlineDecorator({
  Color color = const Color(0xFFFFD54F),
  var double thickness = 2.0,
  int directions = 8,
  this.enabled = true,
}) extends Decorator {
  Color _color = color;

  /// Outline stroke color.
  Color get color => _color;
  set color(Color value) {
    if (_color != value) {
      _color = value;
      _silhouettePaint = null;
    }
  }

  int _directions = directions;

  /// Number of angular silhouette taps (`4` for pixel-art cardinal, `8` for
  /// smooth).
  int get directions => _directions;
  set directions(int value) {
    _directions = value.clamp(4, 16);
  }

  /// Whether the outline is rendered.
  bool enabled;

  Paint? _silhouettePaint;

  Paint _ensurePaint() {
    return _silhouettePaint ??= Paint()
      ..colorFilter = ColorFilter.mode(_color, BlendMode.srcIn);
  }

  @override
  void apply(void Function(Canvas) draw, Canvas canvas) {
    applyBounded(draw, canvas, null);
  }

  @override
  void applyBounded(void Function(Canvas) draw, Canvas canvas, Rect? bounds) {
    if (!enabled || thickness <= 0.0 || _color.a <= 0.0) {
      draw(canvas);
      return;
    }

    final tapCount = _directions.clamp(4, 16);
    final paint = _ensurePaint();
    final stepAngle = (2.0 * math.pi) / tapCount;
    final expanded = (bounds != null && !bounds.isEmpty)
        ? bounds.inflate(thickness + 1.0)
        : null;

    canvas.saveLayer(expanded, paint);
    for (var i = 0; i < tapCount; i++) {
      final a = i * stepAngle;
      final dx = math.cos(a) * thickness;
      final dy = math.sin(a) * thickness;
      canvas.save();
      canvas.translate(dx, dy);
      draw(canvas);
      canvas.restore();
    }
    canvas.restore();

    draw(canvas);
  }
}
