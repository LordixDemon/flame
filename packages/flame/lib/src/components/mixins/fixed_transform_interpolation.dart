import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flame/src/components/mixins/has_fixed_update.dart';
import 'package:flame/src/components/position_component.dart';
import 'package:flame/src/rendering/transform2d_decorator.dart';
import 'package:meta/meta.dart';

/// Mixin for [PositionComponent]s driven by [HasFixedUpdate] that automatically
/// interpolates the rendered 2D transform (`position`, shortest-arc `angle`,
/// and `scale`) between the previous and current fixed-timestep states using
/// `FlameGame.renderInterpolationAlpha`.
///
/// This eliminates beat-frequency visual micro-stutter on `90Hz` / `120Hz` /
/// `144Hz` displays when `fixedTimeStep` runs at e.g. `60Hz`, without mutating
/// logical simulation `position`, `angle`, or `scale` and with `0` per-frame
/// heap allocations.
mixin FixedTransformInterpolation on PositionComponent, HasFixedUpdate {
  /// Whether visual transform interpolation is active during [renderTree].
  bool fixedInterpolationEnabled = true;

  bool _hasCapturedState = false;
  double _prevX = 0.0;
  double _prevY = 0.0;
  double _prevAngle = 0.0;
  double _prevScaleX = 1.0;
  double _prevScaleY = 1.0;

  static final Float64List _interpMatrix64 = Float64List(16)
    ..[10] = 1.0
    ..[15] = 1.0;

  /// Snapshots the current logical transform as the "previous fixed tick"
  /// baseline. Invoked automatically by `ComponentTreeRoot.runFixedUpdatePass`
  /// immediately before `fixedUpdate(fixedDt)`.
  @internal
  void capturePreFixedState() {
    _prevX = transform.x;
    _prevY = transform.y;
    _prevAngle = transform.angle;
    _prevScaleX = transform.scale.x;
    _prevScaleY = transform.scale.y;
    _hasCapturedState = true;
  }

  /// Snaps the interpolation history to the current logical transform so an
  /// instant teleport, spawn, or wrap-around does not streak across the screen
  /// for one frame.
  void teleportFixedState() {
    capturePreFixedState();
  }

  @override
  void onMount() {
    super.onMount();
    capturePreFixedState();
  }

  /// Evaluates the interpolated `(x, y, angle, scaleX, scaleY)` for [alpha] in
  /// `[0..1]`.
  (double x, double y, double angle, double scaleX, double scaleY)
  sampleInterpolatedTransform(double alpha) {
    if (!_hasCapturedState || alpha >= 0.999999) {
      return (
        transform.x,
        transform.y,
        transform.angle,
        transform.scale.x,
        transform.scale.y,
      );
    }
    final t = alpha.clamp(0.0, 1.0);
    final ix = _prevX + (transform.x - _prevX) * t;
    final iy = _prevY + (transform.y - _prevY) * t;
    final isx = _prevScaleX + (transform.scale.x - _prevScaleX) * t;
    final isy = _prevScaleY + (transform.scale.y - _prevScaleY) * t;

    const twoPi = math.pi * 2.0;
    var deltaA = (transform.angle - _prevAngle) % twoPi;
    if (deltaA > math.pi) {
      deltaA -= twoPi;
    } else if (deltaA < -math.pi) {
      deltaA += twoPi;
    }
    final ia = _prevAngle + deltaA * t;
    return (ix, iy, ia, isx, isy);
  }

  @override
  void renderTree(Canvas canvas) {
    if (!fixedInterpolationEnabled || !_hasCapturedState) {
      super.renderTree(canvas);
      return;
    }
    final game = findGame();
    if (game == null || game.fixedTimeStep == null) {
      super.renderTree(canvas);
      return;
    }
    final alpha = game.renderInterpolationAlpha;
    if (alpha >= 0.9999 ||
        ((_prevX - transform.x).abs() <= 1e-6 &&
            (_prevY - transform.y).abs() <= 1e-6 &&
            (_prevAngle - transform.angle).abs() <= 1e-6 &&
            (_prevScaleX - transform.scale.x).abs() <= 1e-6 &&
            (_prevScaleY - transform.scale.y).abs() <= 1e-6) ||
        decorator is! Transform2DDecorator) {
      super.renderTree(canvas);
      return;
    }

    final (ix, iy, ia, isx, isy) = sampleInterpolatedTransform(alpha);
    final cosA = math.cos(ia);
    final sinA = math.sin(ia);
    final offX = transform.offset.x;
    final offY = transform.offset.y;

    final m00 = cosA * isx;
    final m01 = sinA * isx;
    final m10 = -sinA * isy;
    final m11 = cosA * isy;
    _interpMatrix64[0] = m00;
    _interpMatrix64[1] = m01;
    _interpMatrix64[4] = m10;
    _interpMatrix64[5] = m11;
    _interpMatrix64[12] = ix + m00 * offX + m10 * offY;
    _interpMatrix64[13] = iy + m01 * offX + m11 * offY;

    canvas.save();
    canvas.transform(_interpMatrix64);
    final nextDecorator = (decorator as Transform2DDecorator).nextDecorator;
    if (nextDecorator == null) {
      renderTreeWithoutDecorator(canvas);
    } else {
      nextDecorator.applyChain(
        renderTreeWithoutDecorator,
        canvas,
        bounds: decoratorBounds,
      );
    }
    canvas.restore();
  }
}
