import 'package:flutter/scheduler.dart';

/// Internal class that drives the game loop by calling the provided [callback]
/// function on Flutter animation frames, optionally pacing execution to a
/// minimum frame interval (`targetFps` / `idleFps`).
///
/// Pacing is measured in elapsed time, never in the number of ticker
/// callbacks, so a cap keeps its rate when frames arrive slower or faster than
/// the display refresh rate reported by the platform.
///
/// After creating a GameLoop, call `start()` in order to make it actually run.
/// When a GameLoop object is no longer needed, it must be `dispose()`d.
class GameLoop(
  /// Function to be called on every executed rendering frame.
  ///
  /// This function takes a single parameter `dt`, which is the amount of time
  /// passed since the previous invocation of this function. The time is
  /// measured in seconds, with microsecond precision. The argument will be
  /// equal to 0 on first invocation of the callback.
  var void Function(double dt) callback, {

  /// Optional provider returning the minimum interval (in seconds) between
  /// executed callbacks, `null` for uncapped vsync, or [double.infinity] to
  /// suspend ticks while idle until activity resumes.
  ///
  /// An interval that is not a whole number of display periods is honored on
  /// average: the time by which a frame overshoots the interval is carried
  /// over to the next one (a 60 Hz cap on a 90 Hz display executes two out of
  /// every three ticks).
  final double? Function()? minFrameIntervalGetter,

  /// Optional provider returning an exact positive integer VSync divisor
  /// (`1` = every display refresh, `2` = every 2nd, `3` = every 3rd, etc.).
  ///
  /// Together with [displayRefreshRateGetter] it snaps the pacing interval to
  /// `divisor / displayRefreshRate` seconds, so that a harmonic cap locks onto
  /// every Nth display refresh without drifting. The divisor is only used when
  /// that interval is within 8% of the one returned by
  /// [minFrameIntervalGetter] (or when no [minFrameIntervalGetter] was
  /// provided), and it is ignored without a [displayRefreshRateGetter].
  final int? Function()? vsyncDivisorGetter,

  /// Optional provider returning the refresh rate of the display in Hz, which
  /// gives [vsyncDivisorGetter] its unit of time.
  final double? Function()? displayRefreshRateGetter,
}) {
  this {
    _ticker = Ticker(_tick);
  }

  /// A frame is executed once this fraction of a non-harmonic interval has
  /// elapsed, so that timestamp jitter never pushes it to the next vsync.
  static const double _intervalTolerance = 0.92;

  /// How far the harmonic interval may be from the requested one for the
  /// divisor to be applied.
  static const double _harmonicSnapTolerance = 0.08;

  /// In harmonic mode a frame is executed once the interval minus this
  /// fraction of one display period has elapsed.
  static const double _harmonicBeatTolerance = 0.25;

  /// Total amount of time passed since the game loop was started.
  Duration _previous = Duration.zero;

  /// Time elapsed since the last executed callback; this is the `dt` that the
  /// next callback receives.
  double _pendingDt = 0.0;

  /// Time counted towards the next paced frame, including the overshoot that
  /// was carried over from the previous one.
  double _pacingCredit = 0.0;

  bool _hasTicked = false;
  int _executedTicks = 0;
  int _skippedTicks = 0;

  /// Number of callbacks executed since creation or [resetCounters].
  int get executedTicks => _executedTicks;

  /// Number of vsync ticks skipped due to frame pacing or idle throttling.
  int get skippedTicks => _skippedTicks;

  /// Resets [executedTicks] and [skippedTicks] counters.
  void resetCounters() {
    _executedTicks = 0;
    _skippedTicks = 0;
  }

  /// Internal object responsible for periodically calling [_tick].
  late final Ticker _ticker;

  /// This method is periodically invoked by the [_ticker].
  void _tick(Duration timestamp) {
    final durationDelta = timestamp - _previous;
    final dt = durationDelta.inMicroseconds / Duration.microsecondsPerSecond;
    _previous = timestamp;

    if (!_hasTicked) {
      _hasTicked = true;
      _pendingDt = 0.0;
      _pacingCredit = 0.0;
      _executedTicks++;
      callback(dt);
      return;
    }

    final minInterval = minFrameIntervalGetter?.call();
    if (minInterval != null && minInterval.isInfinite) {
      // Deep-idle mode (`idleFps == 0`): do not accumulate unbounded delta.
      _pendingDt = 0.0;
      _pacingCredit = 0.0;
      _skippedTicks++;
      return;
    }

    _pendingDt += dt;

    var interval = minInterval ?? 0.0;
    // The largest part of the interval that may still be missing when a frame
    // is executed.
    var slack = interval * (1.0 - _intervalTolerance);
    var isHarmonic = false;
    final divisor = vsyncDivisorGetter?.call();
    final displayHz = displayRefreshRateGetter?.call();
    if (divisor != null && divisor >= 1 && displayHz != null && displayHz > 0) {
      final displayPeriod = 1.0 / displayHz;
      final harmonicInterval = divisor * displayPeriod;
      final snaps =
          minFrameIntervalGetter == null ||
          (interval > 0.0 &&
              (harmonicInterval - interval).abs() <=
                  interval * _harmonicSnapTolerance);
      if (snaps) {
        interval = harmonicInterval;
        slack = displayPeriod * _harmonicBeatTolerance;
        isHarmonic = true;
      }
    }

    if (interval <= 0.0) {
      // Uncapped: every vsync executes.
      _pacingCredit = 0.0;
      _fire();
      return;
    }

    _pacingCredit += dt;
    if (_pacingCredit < interval - slack) {
      _skippedTicks++;
      return;
    }

    if (isHarmonic) {
      // Locked onto the display beat: nothing is carried over, so the phase
      // cannot drift.
      _pacingCredit = 0.0;
    } else {
      // Carry the overshoot over, so that the average rate matches the cap
      // even though single frames can only start on a vsync. The carry is
      // bounded by one interval so that a long stall is not replayed.
      final overshoot = _pacingCredit - interval;
      _pacingCredit = overshoot <= 0.0
          ? 0.0
          : (overshoot < interval ? overshoot : interval);
    }
    _fire();
  }

  void _fire() {
    final fireDt = _pendingDt;
    _pendingDt = 0.0;
    _executedTicks++;
    callback(fireDt);
  }

  /// Start running the game loop.
  void start() {
    if (!_ticker.isActive) {
      _ticker.start();
    }
  }

  /// Stop the game loop. While it is stopped, the time "freezes".
  void stop() {
    _ticker.stop();
    _previous = Duration.zero;
    _pendingDt = 0.0;
    _pacingCredit = 0.0;
    _hasTicked = false;
  }

  /// Steps the game loop by the given amount of time while the ticker is
  /// stopped.
  void step(double stepTime) {
    if (!_ticker.isActive) {
      _executedTicks++;
      callback(stepTime);
    }
  }

  /// Disposes the underlying [Ticker].
  void dispose() {
    _ticker.dispose();
  }
}
