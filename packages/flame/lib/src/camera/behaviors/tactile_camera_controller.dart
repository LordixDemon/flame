import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/camera.dart';

/// Reusable tactile pan & zoom controller for a camera [Viewfinder], providing
/// soft-bounded manual world panning, multiplicative zoom clamping, and smooth
/// exponential spring snap-back to the canonical camera framing.
class TactileCameraController({
  this.maxPanX = 240.0,
  this.maxPanY = 155.0,
  this.minZoomFactor = 0.76,
  this.maxZoomFactor = 1.85,
  this.returnSpringRate = 7.0,
}) {
  /// Maximum horizontal manual pan offset in world units.
  final double maxPanX;

  /// Maximum vertical manual pan offset in world units.
  final double maxPanY;

  /// Minimum multiplicative manual zoom factor.
  final double minZoomFactor;

  /// Maximum multiplicative manual zoom factor.
  final double maxZoomFactor;

  /// Exponential spring speed (`1/s`) when returning to canonical framing.
  final double returnSpringRate;

  double _panX = 0.0;
  double _panY = 0.0;
  double _zoomFactor = 1.0;
  bool _gestureActive = false;
  bool _returning = false;

  /// Current manual X pan offset in world units.
  double get panX => _panX;

  /// Current manual Y pan offset in world units.
  double get panY => _panY;

  /// Current manual pan offset as an [Offset].
  Offset get panOffset => Offset(_panX, _panY);

  /// Current multiplicative manual zoom factor (`1.0` = neutral).
  double get zoomFactor => _zoomFactor;

  /// Whether a touch/drag gesture is currently active.
  bool get isGestureActive => _gestureActive;

  /// Whether the camera currently deviates from neutral framing.
  bool get hasManualOverride =>
      (_panX * _panX + _panY * _panY) > 0.25 ||
      (_zoomFactor - 1.0).abs() > 0.005;

  /// Marks the start of a manual pan/pinch gesture.
  void beginGesture() {
    _gestureActive = true;
    _returning = false;
  }

  /// Marks the end of a manual pan/pinch gesture.
  void endGesture() {
    _gestureActive = false;
  }

  /// Pans manually in world coordinates within `[-maxPanX..maxPanX]` and
  /// `[-maxPanY..maxPanY]`.
  void panByWorld(double dx, double dy) {
    _returning = false;
    _panX = (_panX + dx).clamp(-maxPanX, maxPanX);
    _panY = (_panY + dy).clamp(-maxPanY, maxPanY);
  }

  /// Multiplies manual zoom within `[minZoomFactor..maxZoomFactor]`.
  void zoomByFactor(double factor) {
    _returning = false;
    _zoomFactor = (_zoomFactor * factor).clamp(minZoomFactor, maxZoomFactor);
  }

  /// Multiplies manual zoom by [factor] while shifting manual pan so that the
  /// focal point at `(viewportDeltaX, viewportDeltaY)` from the viewport center
  /// (at `baseZoom` before manual zoom) remains stationary on screen.
  void zoomByFactorAnchored(
    double factor, {
    required double viewportDeltaX,
    required double viewportDeltaY,
    double baseZoom = 1.0,
  }) {
    _returning = false;
    final prevFactor = _zoomFactor;
    final nextFactor = (prevFactor * factor).clamp(
      minZoomFactor,
      maxZoomFactor,
    );
    if ((nextFactor - prevFactor).abs() < 1e-9 || baseZoom <= 1e-6) {
      return;
    }
    final prevTotalZoom = baseZoom * prevFactor;
    final nextTotalZoom = baseZoom * nextFactor;
    final shiftWorldX =
        viewportDeltaX * (1.0 / prevTotalZoom - 1.0 / nextTotalZoom);
    final shiftWorldY =
        viewportDeltaY * (1.0 / prevTotalZoom - 1.0 / nextTotalZoom);
    _zoomFactor = nextFactor;
    _panX = (_panX + shiftWorldX).clamp(-maxPanX, maxPanX);
    _panY = (_panY + shiftWorldY).clamp(-maxPanY, maxPanY);
  }

  /// Springs (or snaps when [instant] is true) manual pan & zoom back to
  /// neutral framing.
  void reset({bool instant = false}) {
    if (instant) {
      _panX = 0.0;
      _panY = 0.0;
      _zoomFactor = 1.0;
      _returning = false;
      return;
    }
    _returning = true;
  }

  /// Advances spring snap-back by [dt] seconds when [reset] has been requested
  /// and no gesture is active.
  ///
  /// Pan and zoom decay towards neutral as `exp(-returnSpringRate * t)`,
  /// independently of how the elapsed time is split into frames.
  void update(double dt) {
    if (!_returning || _gestureActive || dt <= 0.0) {
      return;
    }
    // Exact exponential decay: the same curve at any frame rate, and a long
    // frame never overshoots or teleports the camera home.
    final k = 1.0 - math.exp(-dt * returnSpringRate);
    _panX += (0.0 - _panX) * k;
    _panY += (0.0 - _panY) * k;
    _zoomFactor += (1.0 - _zoomFactor) * k;
    if (_panX.abs() < 0.25 &&
        _panY.abs() < 0.25 &&
        (_zoomFactor - 1.0).abs() < 0.002) {
      _panX = 0.0;
      _panY = 0.0;
      _zoomFactor = 1.0;
      _returning = false;
    }
  }
}
