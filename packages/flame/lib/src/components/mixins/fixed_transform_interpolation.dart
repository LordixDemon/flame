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

  /// The number of the fixed-step pass in which this component last ran its
  /// `fixedUpdate` (`-1` before the first one).
  int _steppedPass = -1;
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
  /// immediately before `fixedUpdate(fixedDt)`, which passes the number of
  /// the running pass as [fixedPass].
  @internal
  void capturePreFixedState([int? fixedPass]) {
    _prevX = transform.x;
    _prevY = transform.y;
    _prevAngle = transform.angle;
    _prevScaleX = transform.scale.x;
    _prevScaleY = transform.scale.y;
    _hasCapturedState = true;
    if (fixedPass != null) {
      _steppedPass = fixedPass;
    }
  }

  /// Whether this component ran its `fixedUpdate` in the fixed-step pass
  /// number [fixedPass].
  ///
  /// The previous/current pair only describes motion that is in progress
  /// when the component took part in the most recent pass. A component whose
  /// step is skipped (a paused `HasTimeScale` ancestor, `sleepUpdates()`, a
  /// graphics tier gate) keeps the pair of its last step, and must be drawn
  /// at its logical transform instead of sliding between the two with the
  /// interpolation alpha of every frame.
  @internal
  bool wasSteppedInFixedPass(int fixedPass) => _steppedPass == fixedPass;

  /// Snaps the interpolation history to the current logical transform so an
  /// instant teleport, spawn, or wrap-around does not streak across the screen
  /// for one frame.
  void teleportFixedState() {
    capturePreFixedState();
  }

  /// Whether this component currently has a non-zero transform delta between
  /// its previous and current fixed-timestep states.
  bool get hasPendingFixedInterpolationDelta {
    if (!fixedInterpolationEnabled || !_hasCapturedState) {
      return false;
    }
    return (_prevX - transform.x).abs() > 1e-6 ||
        (_prevY - transform.y).abs() > 1e-6 ||
        (_prevAngle - transform.angle).abs() > 1e-6 ||
        (_prevScaleX - transform.scale.x).abs() > 1e-6 ||
        (_prevScaleY - transform.scale.y).abs() > 1e-6;
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
    if (game == null ||
        game.fixedTimeStep == null ||
        !wasSteppedInFixedPass(game.fixedUpdatePassCount)) {
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

    // The logical transform, which the regular render chain applies.
    final current = transform.transformMatrix.storage;
    final a = current[0];
    final b = current[1];
    final c = current[4];
    final d = current[5];
    final tx = current[12];
    final ty = current[13];
    final det = a * d - b * c;
    if (det.abs() <= 1e-12) {
      super.renderTree(canvas);
      return;
    }

    // The interpolated transform that should end up on the canvas.
    final (ix, iy, ia, isx, isy) = sampleInterpolatedTransform(alpha);
    final cosA = math.cos(ia);
    final sinA = math.sin(ia);
    final offX = transform.offset.x;
    final offY = transform.offset.y;
    final i00 = cosA * isx;
    final i01 = sinA * isx;
    final i10 = -sinA * isy;
    final i11 = cosA * isy;
    final itx = ix + i00 * offX + i10 * offY;
    final ity = iy + i01 * offX + i11 * offY;

    // Inverse of the logical transform.
    final n00 = d / det;
    final n01 = -b / det;
    final n10 = -c / det;
    final n11 = a / det;
    final ntx = -(n00 * tx + n10 * ty);
    final nty = -(n01 * tx + n11 * ty);

    // correction = interpolated * logical^-1. With it in front, the regular
    // chain (visibility, culling and every other `renderTree` override, the
    // decorators with their bounds) runs unchanged and still lands on the
    // interpolated transform.
    _interpMatrix64[0] = i00 * n00 + i10 * n01;
    _interpMatrix64[1] = i01 * n00 + i11 * n01;
    _interpMatrix64[4] = i00 * n10 + i10 * n11;
    _interpMatrix64[5] = i01 * n10 + i11 * n11;
    _interpMatrix64[12] = i00 * ntx + i10 * nty + itx;
    _interpMatrix64[13] = i01 * ntx + i11 * nty + ity;

    canvas.save();
    canvas.transform(_interpMatrix64);
    super.renderTree(canvas);
    canvas.restore();
  }
}
