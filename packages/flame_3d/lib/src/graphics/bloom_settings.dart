import 'package:flame_3d/resources.dart';

/// {@template bloom_settings}
/// Soft-knee GPU bloom post-processing for a `World3D` or `Scene3DComponent`.
///
/// Bright pixels above [threshold] (smoothed over [softKnee]) are extracted
/// at half resolution, blurred by [passes] 5-tap passes at that resolution
/// whose taps spread with [radius], and added back onto the rendered image at
/// [intensity] while preserving target alpha for transparent
/// `Scene3DComponent` layers.
///
/// Its setters report their changes ([version]), so that the retained
/// layers of the worlds that use it render again.
/// {@endtemplate}
class BloomSettings({
  var double _threshold = 0.8,
  var double _softKnee = 0.5,
  var double _intensity = 0.6,
  var double _radius = 1.0,
  var bool _dualKawase = false,

  /// Number of blur passes (`1` to `4`).
  int passes = 2,
}) with Versioned {
  /// {@macro bloom_settings}
  this {
    this.passes = passes;
  }

  /// Brightness threshold above which fragments contribute to bloom (`>= 0`).
  double get threshold => _threshold;
  set threshold(double value) => _threshold = noteChange(_threshold, value);

  /// Soft transition width around [threshold] in `[0, 1]`.
  double get softKnee => _softKnee;
  set softKnee(double value) => _softKnee = noteChange(_softKnee, value);

  /// Additive bloom strength (`0` disables bloom).
  double get intensity => _intensity;
  set intensity(double value) => _intensity = noteChange(_intensity, value);

  /// Filter spread multiplier in texels (`> 0`).
  double get radius => _radius;
  set radius(double value) => _radius = noteChange(_radius, value);

  /// Whether to blur using a progressive Dual Kawase downsample/upsample
  /// pyramid instead of fixed half-resolution Kawase passes.
  bool get dualKawase => _dualKawase;
  set dualKawase(bool value) => _dualKawase = noteChange(_dualKawase, value);

  /// Number of blur iterations (`1` to `4`).
  int get passes => _passes;
  int _passes = 2;
  set passes(int value) {
    if (value < 1 || value > 4) {
      throw ArgumentError.value(value, 'passes', 'Must be between 1 and 4');
    }
    _passes = noteChange(_passes, value);
  }
}
