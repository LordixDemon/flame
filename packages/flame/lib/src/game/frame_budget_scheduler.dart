import 'dart:async';
import 'dart:math' as math;

/// Amortizes mid-gameplay scene preparation work (static 3D chunk bakes,
/// procedural mesh generation, snapshot pre-warming) across frames so single
/// frames never breach the VSync deadline.
class FrameBudgetScheduler({
  var double budgetFraction = 0.65,
  var int maxTasksPerFrame = 8,
  var int maxStarvationFrames = 12,
}) {
  final List<_ScheduledFrameTask<dynamic>> _queue =
      <_ScheduledFrameTask<dynamic>>[];
  final Stopwatch _taskStopwatch = Stopwatch();

  int _sequence = 0;
  int _starvedFrames = 0;
  int _completedTaskCount = 0;
  int _lastFrameExecutedTasks = 0;
  int _lastFrameTaskMicros = 0;

  /// Number of deferred tasks currently waiting in the queue.
  int get pendingTaskCount => _queue.length;

  /// Whether at least one deferred task is queued.
  bool get hasPendingTasks => _queue.isNotEmpty;

  /// Total number of scheduled tasks executed since creation.
  int get completedTaskCount => _completedTaskCount;

  /// Number of tasks executed during the most recent [drainWithinBudget] call.
  int get lastFrameExecutedTasks => _lastFrameExecutedTasks;

  /// Microseconds spent executing deferred tasks during the most recent frame.
  int get lastFrameTaskMicros => _lastFrameTaskMicros;

  /// Enqueues [task] ordered by descending [priority] (higher runs first; FIFO
  /// among equal priorities) and returns a [Future] resolving with its result.
  Future<T> schedule<T>(T Function() task, {int priority = 0}) {
    final completer = Completer<T>();
    _insertTask(
      _ScheduledFrameTask<T>(
        priority: priority,
        sequence: _sequence++,
        run: task,
        completer: completer,
      ),
    );
    return completer.future;
  }

  /// Enqueues a fire-and-forget synchronous [task] without allocating a
  /// [Completer].
  void scheduleSync(void Function() task, {int priority = 0}) {
    _insertTask(
      _ScheduledFrameTask<void>(
        priority: priority,
        sequence: _sequence++,
        run: task,
      ),
    );
  }

  void _insertTask(_ScheduledFrameTask<dynamic> entry) {
    var idx = _queue.length;
    while (idx > 0) {
      final prev = _queue[idx - 1];
      if (prev.priority > entry.priority ||
          (prev.priority == entry.priority && prev.sequence < entry.sequence)) {
        break;
      }
      idx--;
    }
    _queue.insert(idx, entry);
  }

  /// Executes queued tasks while `elapsedUpdateMicros + taskMicros` stays below
  /// `frameBudgetMicros * budgetFraction` (or executes `1` anti-starvation task
  /// if the queue has waited [maxStarvationFrames] consecutive busy frames).
  int drainWithinBudget({
    required int elapsedUpdateMicros,
    required int frameBudgetMicros,
  }) {
    _lastFrameExecutedTasks = 0;
    _lastFrameTaskMicros = 0;
    if (_queue.isEmpty) {
      _starvedFrames = 0;
      return 0;
    }

    final allowedTotalMicros = math.max(
      0,
      (frameBudgetMicros * budgetFraction.clamp(0.05, 1.0)).round(),
    );
    final forceOneForStarvation =
        maxStarvationFrames > 0 && _starvedFrames >= maxStarvationFrames;

    if (elapsedUpdateMicros >= allowedTotalMicros && !forceOneForStarvation) {
      _starvedFrames++;
      return 0;
    }

    _taskStopwatch
      ..reset()
      ..start();
    var executed = 0;
    try {
      while (_queue.isNotEmpty && executed < maxTasksPerFrame) {
        final spent = elapsedUpdateMicros + _taskStopwatch.elapsedMicroseconds;
        if (executed > 0 && spent >= allowedTotalMicros) {
          break;
        }
        if (executed == 0 &&
            spent >= allowedTotalMicros &&
            !forceOneForStarvation) {
          break;
        }
        final next = _queue.removeAt(0);
        next.execute();
        executed++;
        _completedTaskCount++;
        if (forceOneForStarvation && spent >= allowedTotalMicros) {
          break;
        }
      }
    } finally {
      _taskStopwatch.stop();
      _lastFrameTaskMicros = _taskStopwatch.elapsedMicroseconds;
      _lastFrameExecutedTasks = executed;
      if (executed > 0) {
        _starvedFrames = 0;
      } else {
        _starvedFrames++;
      }
    }
    return executed;
  }

  /// Synchronously executes all remaining queued tasks immediately.
  void flushAllSync() {
    while (_queue.isNotEmpty) {
      _queue.removeAt(0).execute();
      _completedTaskCount++;
    }
    _starvedFrames = 0;
  }

  /// Cancels and removes all pending tasks without executing them.
  void clear() {
    _queue.clear();
    _starvedFrames = 0;
  }
}

class _ScheduledFrameTask<T>({
  required final int priority,
  required final int sequence,
  required final T Function() run,
  final Completer<T>? completer,
}) {
  void execute() {
    final c = completer;
    if (c == null) {
      run();
      return;
    }
    try {
      c.complete(run());
    } on Object catch (error, stackTrace) {
      c.completeError(error, stackTrace);
    }
  }
}
