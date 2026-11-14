import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flame/components.dart';
import 'package:flame/src/effects/effect.dart';
import 'package:flame/src/effects/effect_target.dart';
import 'package:flutter/animation.dart' show Curve, Curves;
import 'package:flutter/foundation.dart' show VoidCallback;

/// Declarative step executed inside a [TimelineComponent].
sealed class const TimelineStep();

/// Immediate synchronous action step (`0` duration).
class TimelineActionStep(final VoidCallback action) extends TimelineStep;

/// Frame-accurate delay step lasting [duration] seconds (scaled by
/// [TimelineComponent.playbackRate]) without allocating a `TimerComponent`.
class TimelineWaitStep(
  final double duration, {
  final VoidCallback? onSkip,
}) extends TimelineStep {
  this : assert(duration >= 0, 'duration must be non-negative: $duration');
}

/// Frame-driven normalized `[0..1]` interpolation step lasting [duration]
/// seconds.
class TimelineTweenStep(
  final double duration,
  final void Function(double progress) onUpdate, {
  final Curve curve = Curves.linear,
}) extends TimelineStep {
  this : assert(duration >= 0, 'duration must be non-negative: $duration');
}

/// Advances [effect] bound to [target] directly inside the timeline without
/// mounting/removing child components, propagating exact leftover `dt` to
/// subsequent steps.
class TimelineEffectStep(
  final Object target,
  final Effect effect,
) extends TimelineStep;

/// Asynchronous beat receiving an `isCancelled()` predicate so suspended logic
/// can abort cleanly when [TimelineComponent.cancel] or `onRemove` occurs.
class TimelineAsyncStep(
  final Future<void> Function(bool Function() isCancelled) task, {
  final VoidCallback? onSkip,
}) extends TimelineStep;

/// Runs multiple timeline branches concurrently until every branch finishes.
class TimelineParallelStep(
  final List<List<TimelineStep>> branches,
) extends TimelineStep;

/// Fluent builder constructing a sequence of [TimelineStep]s for
/// [TimelineComponent].
class TimelineBuilder() {
  final List<TimelineStep> _steps = <TimelineStep>[];

  /// Appends an immediate synchronous [action].
  void doSync(VoidCallback action) {
    _steps.add(TimelineActionStep(action));
  }

  /// Appends a frame-accurate wait of [seconds] (zero `TimerComponent`
  /// allocations).
  void wait(double seconds, {VoidCallback? onSkip}) {
    if (seconds > 0) {
      _steps.add(TimelineWaitStep(seconds, onSkip: onSkip));
    }
  }

  /// Appends a frame-accurate curved `[0..1]` interpolation over [seconds].
  void tween(
    double seconds,
    void Function(double progress) onUpdate, {
    Curve curve = Curves.linear,
  }) {
    _steps.add(TimelineTweenStep(seconds, onUpdate, curve: curve));
  }

  /// Appends an [Effect] bound to [target], scaled automatically by
  /// [TimelineComponent.playbackRate] and fast-forwarded by `skipToEnd()`.
  void animate(Object target, Effect effect) {
    _steps.add(TimelineEffectStep(target, effect));
  }

  /// Appends an async [task] beat guarded by a generation token
  /// (`isCancelled`).
  void runBeat(
    Future<void> Function(bool Function() isCancelled) task, {
    VoidCallback? onSkip,
  }) {
    _steps.add(TimelineAsyncStep(task, onSkip: onSkip));
  }

  /// Appends multiple concurrent timeline branches that run in parallel until
  /// all branches finish.
  void parallel(Iterable<void Function(TimelineBuilder branch)> branches) {
    final compiled = <List<TimelineStep>>[];
    for (final buildBranch in branches) {
      final sub = TimelineBuilder();
      buildBranch(sub);
      if (sub._steps.isNotEmpty) {
        compiled.add(sub._steps);
      }
    }
    if (compiled.isNotEmpty) {
      _steps.add(TimelineParallelStep(compiled));
    }
  }

  /// Launches staggered branches across [items] separated by [intervalSeconds].
  void stagger<T>(
    Iterable<T> items,
    double intervalSeconds,
    void Function(TimelineBuilder branch, T item, int index) buildItem,
  ) {
    assert(intervalSeconds >= 0, 'intervalSeconds must be non-negative');
    final compiled = <List<TimelineStep>>[];
    var index = 0;
    for (final item in items) {
      final sub = TimelineBuilder();
      final delay = index * intervalSeconds;
      if (delay > 0) {
        sub.wait(delay);
      }
      buildItem(sub, item, index);
      if (sub._steps.isNotEmpty) {
        compiled.add(sub._steps);
      }
      index++;
    }
    if (compiled.isNotEmpty) {
      _steps.add(TimelineParallelStep(compiled));
    }
  }
}

class _TimelineRunner(
  final List<TimelineStep> steps,
  final TimelineComponent owner,
  final int generation,
) {
  int _index = 0;
  double _stepElapsed = 0;
  bool _effectBound = false;
  bool _asyncStarted = false;
  bool _asyncDone = false;
  List<_TimelineRunner>? _parallelRunners;

  bool get isDone => _index >= steps.length;

  /// Advances the runner by [dt], returning unconsumed leftover time (`>= 0`)
  /// when the entire runner finishes within this tick.
  double advance(double dt) {
    var remaining = dt;
    while (_index < steps.length) {
      if (owner._generation != generation) {
        return 0;
      }
      final step = steps[_index];
      switch (step) {
        case TimelineActionStep():
          step.action();
          _index++;
          _stepElapsed = 0;
        case TimelineWaitStep():
          final needed = step.duration - _stepElapsed;
          if (remaining >= needed) {
            remaining -= math.max(0.0, needed);
            _index++;
            _stepElapsed = 0;
          } else {
            _stepElapsed += remaining;
            return 0;
          }
        case TimelineTweenStep():
          if (step.duration <= 0) {
            step.onUpdate(step.curve.transform(1.0));
            _index++;
            _stepElapsed = 0;
            continue;
          }
          final needed = step.duration - _stepElapsed;
          if (remaining >= needed) {
            remaining -= math.max(0.0, needed);
            step.onUpdate(step.curve.transform(1.0));
            _index++;
            _stepElapsed = 0;
          } else {
            _stepElapsed += remaining;
            final rawT = (_stepElapsed / step.duration).clamp(0.0, 1.0);
            step.onUpdate(step.curve.transform(rawT));
            return 0;
          }
        case TimelineEffectStep():
          if (!_effectBound) {
            _bindEffect(step);
            _effectBound = true;
          }
          final leftover = step.effect.advance(remaining);
          if (step.effect.controller.completed) {
            remaining = leftover;
            _effectBound = false;
            _index++;
            _stepElapsed = 0;
          } else {
            return 0;
          }
        case TimelineAsyncStep():
          if (!_asyncStarted) {
            _asyncStarted = true;
            _asyncDone = false;
            final gen = generation;
            unawaited(
              step.task(() => owner._generation != gen || owner.isRemoved).then(
                (_) {
                  if (owner._generation == gen) {
                    _asyncDone = true;
                    owner.findGame()?.notifyActivity();
                  }
                },
              ),
            );
          }
          if (_asyncDone) {
            _asyncStarted = false;
            _asyncDone = false;
            _index++;
            _stepElapsed = 0;
            remaining = 0;
          } else {
            return 0;
          }
        case TimelineParallelStep():
          final runners = _parallelRunners ??= step.branches
              .map((b) => _TimelineRunner(b, owner, generation))
              .toList(growable: false);
          var allDone = true;
          var minLeftover = remaining;
          for (var i = 0; i < runners.length; i++) {
            final r = runners[i];
            if (!r.isDone) {
              final left = r.advance(remaining);
              if (!r.isDone) {
                allDone = false;
              } else if (left < minLeftover) {
                minLeftover = left;
              }
            }
          }
          if (allDone) {
            _parallelRunners = null;
            _index++;
            _stepElapsed = 0;
            remaining = minLeftover;
          } else {
            return 0;
          }
      }
    }
    return remaining;
  }

  void skipToEnd() {
    while (_index < steps.length) {
      if (owner._generation != generation) {
        return;
      }
      final step = steps[_index];
      switch (step) {
        case TimelineActionStep():
          step.action();
        case TimelineWaitStep():
          step.onSkip?.call();
        case TimelineTweenStep():
          step.onUpdate(step.curve.transform(1.0));
        case TimelineEffectStep():
          if (!_effectBound) {
            _bindEffect(step);
          }
          final dur = step.effect.controller.duration;
          step.effect.advance(
            (dur != null && dur.isFinite) ? dur + 1.0 : 1e6,
          );
          _effectBound = false;
        case TimelineAsyncStep():
          step.onSkip?.call();
        case TimelineParallelStep():
          final runners =
              _parallelRunners ??
              step.branches
                  .map((b) => _TimelineRunner(b, owner, generation))
                  .toList(growable: false);
          for (final r in runners) {
            r.skipToEnd();
          }
          _parallelRunners = null;
      }
      _index++;
      _stepElapsed = 0;
    }
  }

  static void _bindEffect(TimelineEffectStep step) {
    final eff = step.effect;
    if (eff is EffectTarget) {
      eff.bindTargetIfUnset(step.target);
    }
  }
}

class _QueuedBlock(
  final List<TimelineStep> steps,
  final Completer<void> completer,
);

/// Zero-`TimerComponent`-allocation scene choreography and cutscene sequencer.
///
/// Supports sequential steps (`doSync`, `wait`, `tween`, `animate`, `runBeat`),
/// concurrent branches (`parallel`, `stagger`), live [playbackRate] scaling
/// (e.g. `1x` / `2x` fast-forward), deterministic [skipToEnd], and generation-
/// guarded [cancel]. Automatically suspends its `update` tick via
/// [PassiveComponent] whenever idle.
class TimelineComponent({
  double playbackRate = 1.0,
  var VoidCallback? onIdle,
  super.priority,
  super.key,
}) extends Component with PassiveComponent {
  this
    : assert(playbackRate > 0, 'playbackRate must be positive: $playbackRate') {
    ticksEnabled = false;
  }

  double _playbackRate = playbackRate;

  /// Multiplier applied to `dt` when advancing waits, tweens, and timeline
  /// effects (e.g. `2.0` runs choreography twice as fast).
  double get playbackRate => _playbackRate;
  set playbackRate(double value) {
    assert(value > 0, 'playbackRate must be positive: $value');
    _playbackRate = value;
  }

  final Queue<_QueuedBlock> _queue = Queue<_QueuedBlock>();
  _QueuedBlock? _activeBlock;
  _TimelineRunner? _activeRunner;
  int _generation = 0;

  /// Current cancellation generation token.
  int get generation => _generation;

  /// True while a timeline block is executing or queued.
  bool get isBusy => _activeRunner != null || _queue.isNotEmpty;

  /// Number of blocks waiting behind the currently executing block.
  int get queuedBlockCount => _queue.length;

  /// Builds and appends a choreography block to the FIFO queue, starting
  /// immediately if the timeline is currently idle.
  Future<void> enqueue(void Function(TimelineBuilder builder) buildBlock) {
    final builder = TimelineBuilder();
    buildBlock(builder);
    if (builder._steps.isEmpty) {
      return Future<void>.value();
    }
    final completer = Completer<void>();
    _queue.addLast(_QueuedBlock(builder._steps, completer));
    ticksEnabled = true;
    findGame()?.notifyActivity();
    if (_activeRunner == null) {
      _startNextBlock();
    }
    return completer.future;
  }

  /// Plays [buildBlock], optionally cancelling any running/queued blocks first
  /// when [interrupt] is `true`.
  Future<void> play(
    void Function(TimelineBuilder builder) buildBlock, {
    bool interrupt = false,
  }) {
    if (interrupt) {
      cancel();
    }
    return enqueue(buildBlock);
  }

  /// Fast-forwards all active and queued synchronous steps, tweens, and finite
  /// effects to their end states, invalidates any suspended async tasks, and
  /// transitions cleanly to idle.
  void skipToEnd() {
    if (!isBusy) {
      return;
    }
    while (_activeRunner != null || _queue.isNotEmpty) {
      if (_activeRunner == null) {
        _startNextBlock();
      }
      final runner = _activeRunner;
      final block = _activeBlock;
      _activeRunner = null;
      _activeBlock = null;
      runner?.skipToEnd();
      if (block != null && !block.completer.isCompleted) {
        block.completer.complete();
      }
    }
    _generation++;
    ticksEnabled = false;
    onIdle?.call();
  }

  /// Immediately aborts the active block and clears all queued blocks,
  /// incrementing [generation] so suspended async tasks exit safely.
  void cancel() {
    final wasBusy = isBusy;
    _generation++;
    final active = _activeBlock;
    _activeBlock = null;
    _activeRunner = null;
    if (active != null && !active.completer.isCompleted) {
      active.completer.complete();
    }
    while (_queue.isNotEmpty) {
      final pending = _queue.removeFirst();
      if (!pending.completer.isCompleted) {
        pending.completer.complete();
      }
    }
    ticksEnabled = false;
    if (wasBusy) {
      onIdle?.call();
    }
  }

  void _startNextBlock() {
    if (_queue.isEmpty) {
      _activeBlock = null;
      _activeRunner = null;
      ticksEnabled = false;
      return;
    }
    final next = _queue.removeFirst();
    _activeBlock = next;
    _activeRunner = _TimelineRunner(next.steps, this, _generation);
    final genBefore = _generation;
    _activeRunner!.advance(0);
    if (_generation != genBefore) {
      return;
    }
    if (_activeRunner != null && _activeRunner!.isDone) {
      final finished = _activeBlock;
      _activeBlock = null;
      _activeRunner = null;
      if (finished != null && !finished.completer.isCompleted) {
        finished.completer.complete();
      }
      if (_queue.isNotEmpty) {
        _startNextBlock();
      } else {
        ticksEnabled = false;
        onIdle?.call();
      }
    }
  }

  @override
  void update(double dt) {
    if (!isBusy) {
      ticksEnabled = false;
      return;
    }
    var remaining = dt * _playbackRate;
    while (remaining >= 0) {
      if (_activeRunner == null) {
        if (_queue.isEmpty) {
          ticksEnabled = false;
          onIdle?.call();
          return;
        }
        _startNextBlock();
        if (_activeRunner == null) {
          return;
        }
      }
      final genBefore = _generation;
      final leftover = _activeRunner!.advance(remaining);
      if (_generation != genBefore) {
        return;
      }
      if (_activeRunner != null && _activeRunner!.isDone) {
        final finished = _activeBlock;
        _activeBlock = null;
        _activeRunner = null;
        if (finished != null && !finished.completer.isCompleted) {
          finished.completer.complete();
        }
        if (_queue.isEmpty) {
          ticksEnabled = false;
          onIdle?.call();
          return;
        }
        remaining = leftover;
      } else {
        break;
      }
    }
  }

  @override
  void onRemove() {
    cancel();
    super.onRemove();
  }
}
