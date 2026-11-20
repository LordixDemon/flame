import 'dart:ui' show Color;

import 'package:flame_3d/resources.dart';

/// Tone-mapping operator applied during final scene composition in
/// [PostProcessSettings].
enum ToneMapMode() {
  /// Linear clamp with no tone-mapping curve.
  none,

  /// Simple Reinhard curve `c / (1 + c)`.
  reinhard,

  /// Narkowicz ACES Filmic approximation with rich highlight roll-off.
  acesFilmic,

  /// Punchy AgX-inspired log-sigmoid filmic curve preserving hue in highlights.
  agx,
}

/// {@template post_process_settings}
/// GPU color-grading, tone-mapping, 3D color LUT, vignette, SSAO, 3D DoF, and
/// fast anti-aliasing configuration for a `World3D` or `Scene3DComponent`.
///
/// When paired with `BloomSettings`, all post-processing operations execute
/// inside the final bloom composite shader with **zero extra GPU render
/// passes**.
///
/// Its setters report their changes ([version]), so that the retained
/// layers of the worlds that use it render again.
/// {@endtemplate}
class PostProcessSettings({
  var ToneMapMode _toneMap = ToneMapMode.none,
  var double _exposure = 1.0,
  var double _contrast = 1.0,
  var double _saturation = 1.0,
  var double _vignetteIntensity = 0.0,
  var double _vignetteSmoothness = 0.5,
  var Color _tint = const Color(0xFFFFFFFF),
  var bool _fxaa = false,
  var ColorLut3D? _colorLut,
  var double _colorLutIntensity = 1.0,
  var double _ssaoIntensity = 0.0,
  var double _ssaoRadius = 1.5,
  var double _dofFocusDepth = 0.5,
  var double _dofFocusRange = 0.15,
  var double _dofBlurStrength = 0.0,
}) with Versioned {
  ToneMapMode get toneMap => _toneMap;
  set toneMap(ToneMapMode value) => _toneMap = noteChange(_toneMap, value);

  double get exposure => _exposure;
  set exposure(double value) => _exposure = noteChange(_exposure, value);

  double get contrast => _contrast;
  set contrast(double value) => _contrast = noteChange(_contrast, value);

  double get saturation => _saturation;
  set saturation(double value) => _saturation = noteChange(_saturation, value);

  double get vignetteIntensity => _vignetteIntensity;
  set vignetteIntensity(double value) =>
      _vignetteIntensity = noteChange(_vignetteIntensity, value);

  double get vignetteSmoothness => _vignetteSmoothness;
  set vignetteSmoothness(double value) =>
      _vignetteSmoothness = noteChange(_vignetteSmoothness, value);

  Color get tint => _tint;
  set tint(Color value) => _tint = noteChange(_tint, value);

  bool get fxaa => _fxaa;
  set fxaa(bool value) => _fxaa = noteChange(_fxaa, value);

  /// Optional `16x16x16` (`256x16` 2D strip) trilinear 3D color-grading LUT.
  ColorLut3D? get colorLut => _colorLut;
  set colorLut(ColorLut3D? value) => _colorLut = noteChange(_colorLut, value);

  /// Blend factor `[0..1]` for [colorLut].
  double get colorLutIntensity => _colorLutIntensity;
  set colorLutIntensity(double value) =>
      _colorLutIntensity = noteChange(_colorLutIntensity, value);

  /// Screen-space ambient occlusion strength (`0` disables SSAO).
  double get ssaoIntensity => _ssaoIntensity;
  set ssaoIntensity(double value) =>
      _ssaoIntensity = noteChange(_ssaoIntensity, value);

  /// Screen-space sampling radius multiplier for SSAO.
  double get ssaoRadius => _ssaoRadius;
  set ssaoRadius(double value) => _ssaoRadius = noteChange(_ssaoRadius, value);

  /// Normalized `[0..1]` clip-space focal depth for 3D Depth of Field.
  double get dofFocusDepth => _dofFocusDepth;
  set dofFocusDepth(double value) =>
      _dofFocusDepth = noteChange(_dofFocusDepth, value);

  /// Clear-focus half-range around [dofFocusDepth] in normalized clip depth.
  double get dofFocusRange => _dofFocusRange;
  set dofFocusRange(double value) =>
      _dofFocusRange = noteChange(_dofFocusRange, value);

  /// Bokeh blur strength outside [dofFocusRange] (`0` disables 3D DoF).
  double get dofBlurStrength => _dofBlurStrength;
  set dofBlurStrength(double value) =>
      _dofBlurStrength = noteChange(_dofBlurStrength, value);

  /// Whether SSAO or 3D Depth of Field requires the half-res depth-normal pass.
  bool get needsDepthNormal => ssaoIntensity > 1e-4 || dofBlurStrength > 1e-4;

  /// Whether any non-identity post-process stage is enabled.
  bool get isActive =>
      toneMap != ToneMapMode.none ||
      (exposure - 1.0).abs() > 1e-4 ||
      (contrast - 1.0).abs() > 1e-4 ||
      (saturation - 1.0).abs() > 1e-4 ||
      vignetteIntensity > 1e-4 ||
      tint != const Color(0xFFFFFFFF) ||
      fxaa ||
      (colorLut != null && colorLutIntensity > 1e-4) ||
      needsDepthNormal;
}
