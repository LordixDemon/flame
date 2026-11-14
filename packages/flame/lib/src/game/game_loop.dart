import 'package:flutter/scheduler.dart';

/// Internal class that drives the game loop by calling the provided [callback]
/// function on Flutter animation frames, optionally pacing execution to a
/// minimum frame interval (`targetFps` / `idleFps`).
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
  final double? Function()? minFrameIntervalGetter,

  /// Optional provider returning an exact positive integer VSync divisor
  /// (`1` = native VSync, `2` = every 2nd VSync beat, `3` = every 3rd, etc.)
  /// to eliminate non-harmonic timestamp drift on high-refresh-rate displays.
  final int? Function()? vsyncDivisorGetter,
}) {
  this {
    _ticker = Ticker(_tick);
  }

  /// Total amount of time passed since the game loop was started.
  Duration _previous = Duration.zero;

  /// Accumulated delta time across skipped vsync frames when paced.
  double _accumulatedDt = 0.0;

  int _vsyncBeatCounter = 0;
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
      _accumulatedDt = 0.0;
      _vsyncBeatCounter = 0;
      _executedTicks++;
      callback(dt);
      return;
    }

    final minInterval = minFrameIntervalGetter?.call();
    if (minInterval != null && minInterval.isInfinite) {
      // Deep-idle mode (`idleFps == 0`): do not accumulate unbounded delta.
      _accumulatedDt = 0.0;
      _vsyncBeatCounter = 0;
      _skippedTicks++;
      return;
    }

    final divisor = vsyncDivisorGetter?.call();
    if (divisor != null && divisor >= 1) {
      if (divisor == 1) {
        final fireDt = _accumulatedDt > 0.0 ? _accumulatedDt + dt : dt;
        _accumulatedDt = 0.0;
        _vsyncBeatCounter = 0;
        _executedTicks++;
        callback(fireDt);
        return;
      }
      _accumulatedDt += dt;
      _vsyncBeatCounter++;
      if (_vsyncBeatCounter < divisor) {
        _skippedTicks++;
        return;
      }
      _vsyncBeatCounter = 0;
      final fireDt = _accumulatedDt;
      _accumulatedDt = 0.0;
      _executedTicks++;
      callback(fireDt);
      return;
    }

    if (minInterval == null || minInterval <= 0.0) {
      final fireDt = _accumulatedDt > 0.0 ? _accumulatedDt + dt : dt;
      _accumulatedDt = 0.0;
      _executedTicks++;
      callback(fireDt);
      return;
    }

    _accumulatedDt += dt;
    // Allow an 8% vsync phase tolerance so e.g. 60Hz pacing on a 120Hz display
    // (2 * 8.333ms = 16.666ms vs 16.667ms) never misses its harmonic beat.
    if (_accumulatedDt < minInterval * 0.92) {
      _skippedTicks++;
      return;
    }

    final fireDt = _accumulatedDt;
    _accumulatedDt = 0.0;
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
    _accumulatedDt = 0.0;
    _vsyncBeatCounter = 0;
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
