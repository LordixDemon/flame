import 'dart:ui';

import 'package:flame/effects.dart';

/// Change the MaskFilter on Paint of a component over time.
///
/// This effect applies incremental changes to the MaskFilter on Paint of a
/// component and requires that any other effect or update logic applied to the
/// same component also used incremental updates.
class GlowEffect(
  final double strength,
  super.controller, {
  final BlurStyle style = BlurStyle.outer,
  super.key,
}) extends Effect with EffectTarget<PaintProvider> {
  double _lastSigma = -1.0;

  @override
  void apply(double progress) {
    final sigma = strength * progress;
    if (sigma <= 0.0) {
      if (_lastSigma != 0.0) {
        _lastSigma = 0.0;
        target.paint.maskFilter = null;
      }
      return;
    }
    if ((sigma - _lastSigma).abs() < 1e-4) {
      return;
    }
    _lastSigma = sigma;
    target.paint.maskFilter = MaskFilter.blur(style, sigma);
  }

  @override
  void reset() {
    super.reset();
    _lastSigma = -1.0;
    target.paint.maskFilter = null;
  }
}
