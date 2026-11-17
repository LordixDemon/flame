import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flame/components.dart';
import 'package:flame/src/effects/component_effect.dart';
import 'package:flame/src/effects/effect.dart';
import 'package:flame/src/effects/effect_target.dart';
import 'package:flame/src/effects/transform2d_effect.dart';
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
///
/// [target] is handed to the effect, and to the effects nested inside a
/// `SequenceEffect` or `CombinedEffect`, in place of the lookup in the
/// component tree that mounting an effect performs.
class TimelineEffectStep(
  final Object target,
  final Effect effect,
) extends TimelineStep;

/// Asynchronous beat receiving an `isCancelled()` predicate so suspended logic
/// can abort cleanly when [TimelineComponent.cancel] or `onRemove` occurs.
///
/// The beat ends when the future returned by [task] settles. A [task] that
/// throws, or whose future completes with an error, ends the beat as well;
/// the error is reported to the current [Zone]. [onSkip] is called instead of
/// (for a beat that has not started) or in addition to (for a beat that is
/// running) [task] when the timeline is skipped to its end.
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
          // The step is consumed before its callback runs, so an action that
          // throws, cancels or skips the timeline is never replayed.
          _index++;
          _stepElapsed = 0;
          _runCallback(step.action);
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
            _index++;
            _stepElapsed = 0;
            _runTween(step, 1.0);
            continue;
          }
          final needed = step.duration - _stepElapsed;
          if (remaining >= needed) {
            remaining -= math.max(0.0, needed);
            _index++;
            _stepElapsed = 0;
            _runTween(step, 1.0);
          } else {
            _stepElapsed += remaining;
            _runTween(step, (_stepElapsed / step.duration).clamp(0.0, 1.0));
            return 0;
          }
        case TimelineEffectStep():
          var finished = false;
          var leftover = remaining;
          try {
            if (!_effectBound) {
              _bindEffect(step.effect, step.target);
              _effectBound = true;
            }
            leftover = step.effect.advance(remaining);
            finished = step.effect.controller.completed;
          } on Object catch (error, stackTrace) {
            // An effect that cannot be driven is dropped instead of being
            // retried (and failing again) on every following tick.
            _reportStepError(error, stackTrace);
            finished = true;
            leftover = remaining;
          }
          if (finished) {
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
            _startBeat(step);
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

  /// Starts the async [step]. The beat counts as finished as soon as its
  /// future settles, whether it completes normally or with an error, and also
  /// when the task throws before it returns a future.
  void _startBeat(TimelineAsyncStep step) {
    final gen = generation;
    void settle() {
      if (owner._generation == gen) {
        _asyncDone = true;
        owner.findGame()?.notifyActivity();
      }
    }

    final Future<void> future;
    try {
      future = step.task(() => owner._generation != gen || owner.isRemoved);
    } on Object catch (error, stackTrace) {
      _reportStepError(error, stackTrace);
      _asyncDone = true;
      return;
    }
    unawaited(
      future.then<void>(
        (_) => settle(),
        onError: (Object error, StackTrace stackTrace) {
          _reportStepError(error, stackTrace);
          settle();
        },
      ),
    );
  }

  /// Fast-forwards every remaining step. Steps that have not started yet are
  /// never started: an async beat only receives its `onSkip` callback.
  void skipToEnd() {
    while (_index < steps.length) {
      if (owner._generation != generation) {
        return;
      }
      final step = steps[_index];
      // Consumed first, for the same reason as in [advance].
      _index++;
      _stepElapsed = 0;
      switch (step) {
        case TimelineActionStep():
          _runCallback(step.action);
        case TimelineWaitStep():
          _runCallback(step.onSkip);
        case TimelineTweenStep():
          _runTween(step, 1.0);
        case TimelineEffectStep():
          try {
            if (!_effectBound) {
              _bindEffect(step.effect, step.target);
            }
            final dur = step.effect.controller.duration;
            step.effect.advance(
              (dur != null && dur.isFinite) ? dur + 1.0 : 1e6,
            );
          } on Object catch (error, stackTrace) {
            _reportStepError(error, stackTrace);
          }
          _effectBound = false;
        case TimelineAsyncStep():
          _asyncStarted = false;
          _asyncDone = false;
          _runCallback(step.onSkip);
        case TimelineParallelStep():
          final runners =
              _parallelRunners ??
              step.branches
                  .map((b) => _TimelineRunner(b, owner, generation))
                  .toList(growable: false);
          _parallelRunners = null;
          for (final r in runners) {
            r.skipToEnd();
          }
      }
    }
  }

  static void _runCallback(VoidCallback? callback) {
    if (callback == null) {
      return;
    }
    try {
      callback();
    } on Object catch (error, stackTrace) {
      _reportStepError(error, stackTrace);
    }
  }

  static void _runTween(TimelineTweenStep step, double rawProgress) {
    try {
      step.onUpdate(step.curve.transform(rawProgress));
    } on Object catch (error, stackTrace) {
      _reportStepError(error, stackTrace);
    }
  }

  /// A failing step must not take the whole choreography down with it: the
  /// error is handed to the current [Zone] (the same way an unawaited
  /// future's error would be) and the timeline carries on with the next step.
  static void _reportStepError(Object error, StackTrace stackTrace) {
    Zone.current.handleUncaughtError(error, stackTrace);
  }

  /// Gives [effect] (and the effects nested inside a sequence or a combined
  /// effect) the target it would otherwise look up in the component tree when
  /// it is mounted.
  static void _bindEffect(Effect effect, Object target) {
    if (effect is EffectTarget) {
      effect.bindTargetIfUnset(target);
    } else if (effect is ComponentEffect<Component>) {
      if (target is! Component) {
        throw UnsupportedError(
          'This effect can only be applied to a Component',
        );
      }
      // Checked at runtime against the target type of the effect.
      effect.target = target;
      if (effect is Transform2DEffect) {
        effect.transform = effect.target.transform;
      }
    }
    if (effect.hasChildren) {
      for (final child in effect.children) {
        if (child is Effect) {
          _bindEffect(child, target);
        }
      }
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
///
/// A step that fails does not stall the timeline: when a `doSync` action, a
/// tween callback, an `onSkip` callback or the task of an async beat throws,
/// when the future of an async beat completes with an error, or when an
/// effect cannot be driven, the error is reported once to the current [Zone]
/// as an uncaught error and the timeline moves on to the next step.
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
  bool _skipping = false;

  /// Current cancellation generation token.
  int get generation => _generation;

  /// Whether a block is executing or queued. The timeline's own bookkeeping
  /// relies on this instead of on [isBusy], which subclasses may widen.
  bool get _hasBlocks => _activeRunner != null || _queue.isNotEmpty;

  /// True while a timeline block is executing or queued.
  ///
  /// A subclass that drives additional work from its own `update` may
  /// override this to report that work as well: the timeline keeps ticking
  /// for as long as this getter returns `true`. [onIdle] is still reported
  /// when the last block finishes.
  bool get isBusy => _hasBlocks;

  /// Number of blocks waiting behind the currently executing block.
  int get queuedBlockCount => _queue.length;

  void _sleepIfIdle() {
    if (!isBusy) {
      ticksEnabled = false;
    }
  }

  /// Builds and appends a choreography block to the FIFO queue, starting
  /// immediately if the timeline is currently idle.
  ///
  /// The returned future completes when the block has run to its end, was
  /// skipped by [skipToEnd] or was dropped by [cancel].
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
    // A block that is enqueued by a callback of a block that is being skipped
    // is picked up (and skipped as well) by the running [skipToEnd].
    if (_activeRunner == null && !_skipping) {
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
  ///
  /// Nothing new is started on the way: an async beat that has not begun yet
  /// (in the active block or in a queued one) only receives its `onSkip`
  /// callback, its task is never called. [onIdle] is reported once, after the
  /// last block has been skipped.
  void skipToEnd() {
    if (_skipping || !_hasBlocks) {
      return;
    }
    _skipping = true;
    final generationAtStart = _generation;
    try {
      while (_generation == generationAtStart && _hasBlocks) {
        if (_activeRunner == null) {
          final next = _queue.removeFirst();
          _activeBlock = next;
          _activeRunner = _TimelineRunner(next.steps, this, _generation);
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
    } finally {
      _skipping = false;
    }
    if (_generation == generationAtStart) {
      _generation++;
    }
    if (_hasBlocks) {
      // Only reachable when a skipped callback cancelled the timeline and
      // then enqueued a new block: that block runs normally.
      if (_activeRunner == null) {
        _startNextBlock();
      }
      return;
    }
    _sleepIfIdle();
    onIdle?.call();
  }

  /// Immediately aborts the active block and clears all queued blocks,
  /// incrementing [generation] so suspended async tasks exit safely.
  void cancel() {
    final wasBusy = _hasBlocks;
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
    _sleepIfIdle();
    // While a skip is in progress it reports the idle state itself.
    if (wasBusy && !_skipping) {
      onIdle?.call();
    }
  }

  void _startNextBlock() {
    if (_queue.isEmpty) {
      _activeBlock = null;
      _activeRunner = null;
      _sleepIfIdle();
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
        _sleepIfIdle();
        onIdle?.call();
      }
    }
  }

  @override
  void update(double dt) {
    if (!_hasBlocks) {
      _sleepIfIdle();
      return;
    }
    var remaining = dt * _playbackRate;
    while (remaining >= 0) {
      if (_activeRunner == null) {
        if (_queue.isEmpty) {
          _sleepIfIdle();
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
          _sleepIfIdle();
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
