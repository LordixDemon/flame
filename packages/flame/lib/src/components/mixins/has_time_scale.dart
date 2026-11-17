import 'package:flame/src/components/core/component.dart';

/// This mixin allows components to control their speed as compared to the
/// normal speed. Only framerate independent logic will benefit from [timeScale]
/// changes.
///
/// Note: Modified [timeScale] will be applied to all children as well (both
/// variable [Component.update] and deterministic `HasFixedUpdate.fixedUpdate`).
/// A [timeScale] of 0 stops the update pass for the component and its whole
/// subtree: [Component.update] is not called on any of them until the time
/// scale is raised again.
mixin HasTimeScale on CustomTraversal {
  /// The ratio of components tick speed and normal tick speed.
  /// It defaults to 1.0, which means the component moves normally.
  /// A value of 0.5 means the component moves half the normal speed
  /// and a value of 2.0 means the component moves twice as fast.
  double _timeScale = 1.0;

  bool _pulseActive = false;
  double _pulseBaselineScale = 1.0;
  double _pulseTargetScale = 1.0;
  double _pulseHoldDuration = 0.0;
  double _pulseRampDuration = 0.0;
  double _pulseElapsed = 0.0;

  /// Whether [updateSubtree] is currently running the subtree.
  bool _updatingSubtree = false;

  /// Set when a pulse is applied from inside the subtree update: the frame in
  /// which that happens was not slowed down yet, so it does not count.
  bool _pulseStartsNextFrame = false;

  /// Returns the current time scale.
  double get timeScale => _timeScale;

  /// Whether a transient [applyTimePulse] hit-stop / slow-mo pulse is active.
  bool get isTimePulseActive => _pulseActive;

  /// Sets the time scale to given value if it is non-negative and cancels any
  /// active [applyTimePulse].
  /// Note: Too high values will result in inconsistent gameplay
  /// and tunneling in physics.
  set timeScale(double value) {
    if (value.isNegative) {
      return;
    }
    _pulseActive = false;
    _timeScale = value;
  }

  /// Applies a transient hit-stop / slow-motion pulse that holds [timeScale] at
  /// [scale] (`>= 0`, including `0.0` for pure freeze-frame hit-stop) for
  /// [realDuration] **unscaled** real seconds, then smoothly ramps back to the
  /// pre-pulse baseline scale over [rampBackDuration] real seconds.
  ///
  /// Because the pulse timer advances using unscaled real `dt`, even a `0.0`
  /// freeze-frame hit-stop automatically unfreezes itself without external
  /// timers.
  ///
  /// With a [realDuration] of zero the pulse starts at [scale] and ramps back
  /// right away. A pulse that is applied by a component of this subtree during
  /// its update starts to count with the next frame, the first one that it
  /// slows down.
  void applyTimePulse({
    required double scale,
    required double realDuration,
    double rampBackDuration = 0.08,
  }) {
    assert(scale >= 0, 'scale must be non-negative: $scale');
    assert(
      realDuration >= 0,
      'realDuration must be non-negative: $realDuration',
    );
    assert(
      rampBackDuration >= 0,
      'rampBackDuration must be non-negative: $rampBackDuration',
    );
    if (!_pulseActive) {
      _pulseBaselineScale = _timeScale;
    }
    if (realDuration <= 0.0 && rampBackDuration <= 0.0) {
      _pulseActive = false;
      _timeScale = _pulseBaselineScale;
      return;
    }
    _pulseTargetScale = scale;
    _pulseHoldDuration = realDuration;
    _pulseRampDuration = rampBackDuration;
    _pulseElapsed = 0.0;
    _pulseActive = true;
    _pulseStartsNextFrame = _updatingSubtree;
    _timeScale = scale;
  }

  /// Cancels any active [applyTimePulse] and restores the pre-pulse baseline
  /// [timeScale].
  void clearTimePulse() {
    if (_pulseActive) {
      _pulseActive = false;
      _timeScale = _pulseBaselineScale;
    }
  }

  void _advancePulse(double realDt) {
    _pulseElapsed += realDt;
    final total = _pulseHoldDuration + _pulseRampDuration;
    if (_pulseElapsed >= total) {
      _pulseActive = false;
      _timeScale = _pulseBaselineScale;
      return;
    }
    if (_pulseElapsed < _pulseHoldDuration) {
      _timeScale = _pulseTargetScale;
      return;
    }
    if (_pulseRampDuration <= 0.0) {
      _pulseActive = false;
      _timeScale = _pulseBaselineScale;
      return;
    }
    final t = ((_pulseElapsed - _pulseHoldDuration) / _pulseRampDuration).clamp(
      0.0,
      1.0,
    );
    // Smoothstep ease-out back to baseline.
    final eased = t * t * (3.0 - 2.0 * t);
    _timeScale =
        _pulseTargetScale + (_pulseBaselineScale - _pulseTargetScale) * eased;
  }

  @override
  void updateSubtree(double dt) {
    final activeScale = _timeScale;
    if (activeScale > 0.0) {
      _updatingSubtree = true;
      try {
        super.updateSubtree(dt * activeScale);
      } finally {
        _updatingSubtree = false;
      }
    }
    if (_pulseStartsNextFrame) {
      _pulseStartsNextFrame = false;
    } else if (_pulseActive && dt > 0.0) {
      _advancePulse(dt);
    }
  }

  /// Pauses the component and its subtree by setting the time scale to 0.0.
  void pause() {
    timeScale = 0.0;
  }

  /// Resumes the component by setting the time scale to 1.0 or to the given
  /// value.
  void resume({double? newTimeScale}) {
    if (timeScale == 0.0) {
      timeScale = newTimeScale ?? 1.0;
    }
  }
}
