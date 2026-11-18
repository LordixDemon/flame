import 'dart:async';

import 'package:clock/clock.dart';
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

  /// Optional provider telling whether the loop may currently pace its ticks
  /// with a [Timer] instead of display frames.
  ///
  /// Every display frame that is requested is also drawn: Flutter composites
  /// and rasterizes the whole layer tree once per frame, whether anything was
  /// painted or not. A loop that skips most frames (an idle framerate of 30
  /// fps on a 60 or 120 Hz display) would otherwise still have every display
  /// refresh drawn. When this returns `true` and the minimum frame interval
  /// spans more than one and a half display periods (or is infinite), the loop
  /// stops requesting frames after a tick and runs the next one from a timer,
  /// outside of any frame. A frame is then only drawn when the callback asks
  /// for one (for example by marking a render object as needing paint), so a
  /// throttled game whose picture does not change draws no frames at all.
  ///
  /// The loop goes back to display frames as soon as this returns `false` or
  /// the interval gets shorter (checked on every timer tick), or right away
  /// when [wake] is called.
  final bool Function()? timerPacingGetter,
}) {
  this {
    _ticker = Ticker(_tick);
  }

  /// The interval, in display periods, above which [timerPacingGetter] lets the
  /// loop pace its ticks with a timer.
  static const double _timerPacingMinPeriods = 1.5;

  /// How often a loop suspended by an infinite interval checks whether it may
  /// run again (it runs no tick then; [wake] resumes it at once).
  static const Duration _suspendedPollInterval = Duration(milliseconds: 250);

  /// Display rate assumed when no [displayRefreshRateGetter] tells it.
  static const double _defaultDisplayHz = 60.0;

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

  /// Monotonic clock of the timer pacing ([timerPacingGetter]), from
  /// `package:clock` so that a faked clock drives it in tests;
  /// [_lastTickMicros] is the time of the last tick, executed or skipped.
  final Stopwatch _clock = clock.stopwatch();
  int _lastTickMicros = 0;

  /// Whether the loop runs (between [start] and [stop]).
  bool _running = false;

  /// The pending timer tick while the loop paces with a timer.
  Timer? _timer;

  /// Whether the next ticker callback follows timer pacing: its timestamp
  /// restarted at zero, so its `dt` comes from [_clock].
  bool _resumedFromTimer = false;

  /// Whether the loop currently paces its ticks with a timer
  /// ([timerPacingGetter]) and requests no display frames.
  bool get isTimerPaced => _timer != null;

  double _secondsSinceLastTick() {
    final now = _clock.elapsedMicroseconds;
    final dt = (now - _lastTickMicros) / Duration.microsecondsPerSecond;
    _lastTickMicros = now;
    return dt < 0.0 ? 0.0 : dt;
  }

  /// This method is periodically invoked by the [_ticker].
  void _tick(Duration timestamp) {
    final durationDelta = timestamp - _previous;
    var dt = durationDelta.inMicroseconds / Duration.microsecondsPerSecond;
    _previous = timestamp;
    if (_resumedFromTimer) {
      _resumedFromTimer = false;
      dt = _secondsSinceLastTick();
    } else {
      _lastTickMicros = _clock.elapsedMicroseconds;
    }

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
      _maybePaceWithTimer();
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
    _maybePaceWithTimer();
  }

  /// The interval the timer pacing would wait between ticks, or `null` when the
  /// loop must run on display frames.
  double? _timerPacingInterval() {
    if (!_running || timerPacingGetter?.call() != true) {
      return null;
    }
    final interval = minFrameIntervalGetter?.call();
    if (interval == null) {
      return null;
    }
    if (interval.isInfinite) {
      return interval;
    }
    final displayHz = displayRefreshRateGetter?.call();
    final period =
        1.0 /
        (displayHz != null && displayHz > 0 ? displayHz : _defaultDisplayHz);
    return interval > period * _timerPacingMinPeriods ? interval : null;
  }

  /// After a tick on a display frame: switches to timer pacing when allowed.
  void _maybePaceWithTimer() {
    final interval = _timerPacingInterval();
    if (interval == null) {
      return;
    }
    _ticker.stop();
    _previous = Duration.zero;
    _pendingDt = 0.0;
    _pacingCredit = 0.0;
    _armTimer(interval, sinceLastTick: true);
  }

  void _armTimer(double interval, {required bool sinceLastTick}) {
    _timer?.cancel();
    if (interval.isInfinite) {
      _timer = Timer(_suspendedPollInterval, _onTimer);
      return;
    }
    var waitMicros = (interval * Duration.microsecondsPerSecond).round();
    if (sinceLastTick) {
      waitMicros -= _clock.elapsedMicroseconds - _lastTickMicros;
    }
    _timer = Timer(
      Duration(microseconds: waitMicros < 0 ? 0 : waitMicros),
      _onTimer,
    );
  }

  void _onTimer() {
    _timer = null;
    if (!_running) {
      return;
    }
    final interval = _timerPacingInterval();
    if (interval == null) {
      _resumeTicker();
      return;
    }
    if (interval.isInfinite) {
      // Still suspended: no tick, and the time does not pile up.
      _lastTickMicros = _clock.elapsedMicroseconds;
      _skippedTicks++;
      _armTimer(interval, sinceLastTick: false);
      return;
    }
    final dt = _secondsSinceLastTick();
    _hasTicked = true;
    _executedTicks++;
    callback(dt);
    if (!_running || _ticker.isActive) {
      return;
    }
    final next = _timerPacingInterval();
    if (next == null) {
      _resumeTicker();
    } else if (_timer == null) {
      _armTimer(next, sinceLastTick: true);
    }
  }

  void _resumeTicker() {
    _timer?.cancel();
    _timer = null;
    if (!_running || _ticker.isActive) {
      return;
    }
    _previous = Duration.zero;
    _pendingDt = 0.0;
    _pacingCredit = 0.0;
    _resumedFromTimer = _hasTicked;
    _ticker.start();
  }

  /// Goes back to display frames right away when the loop paces its ticks with
  /// a timer ([timerPacingGetter]), for example on user input; the next tick
  /// then runs on the next frame. Does nothing otherwise.
  void wake() {
    if (_timer != null) {
      _resumeTicker();
    }
  }

  /// Start running the game loop.
  void start() {
    if (_running) {
      return;
    }
    _running = true;
    _clock.start();
    if (!_ticker.isActive) {
      _ticker.start();
    }
  }

  /// Stop the game loop. While it is stopped, the time "freezes".
  void stop() {
    _running = false;
    _timer?.cancel();
    _timer = null;
    _resumedFromTimer = false;
    _ticker.stop();
    _previous = Duration.zero;
    _pendingDt = 0.0;
    _pacingCredit = 0.0;
    _hasTicked = false;
  }

  /// Steps the game loop by the given amount of time while the ticker is
  /// stopped.
  void step(double stepTime) {
    if (!_running && !_ticker.isActive) {
      _executedTicks++;
      callback(stepTime);
    }
  }

  /// Disposes the underlying [Ticker].
  void dispose() {
    _running = false;
    _timer?.cancel();
    _timer = null;
    _ticker.dispose();
  }
}
