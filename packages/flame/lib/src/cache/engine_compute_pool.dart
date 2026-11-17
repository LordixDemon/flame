import 'dart:async';
import 'dart:collection';
import 'dart:isolate';
import 'dart:typed_data';

/// Priority tier for tasks scheduled onto an [EngineComputePool].
enum ComputePriority() {
  low,
  normal,
  high,
}

/// Exception thrown when a queued or in-flight [EngineComputePool] task is
/// cancelled via a [ComputeCancellationToken] or [EngineComputePool.dispose].
class const ComputeCancelledException([
  final String message = 'Compute task was cancelled.',
]) implements Exception {
  @override
  String toString() => 'ComputeCancelledException: $message';
}

/// Cooperative cancellation token for [EngineComputePool.schedule].
class ComputeCancellationToken() {
  bool _cancelled = false;
  List<void Function()>? _listeners;

  /// Whether [cancel] has been invoked.
  bool get isCancelled => _cancelled;

  /// Marks this token cancelled and notifies registered listeners once.
  void cancel() {
    if (_cancelled) {
      return;
    }
    _cancelled = true;
    final listeners = _listeners;
    _listeners = null;
    if (listeners != null) {
      for (var i = 0; i < listeners.length; i++) {
        listeners[i]();
      }
    }
  }

  /// Registers [listener] to run when [cancel] is called (or immediately if
  /// already cancelled).
  ///
  /// The token keeps the listener, and everything it captures, until it is
  /// cancelled or the listener is taken off again with [removeOnCancel].
  void onCancel(void Function() listener) {
    if (_cancelled) {
      listener();
      return;
    }
    (_listeners ??= <void Function()>[]).add(listener);
  }

  /// Unregisters a [listener] that was registered with [onCancel], so that a
  /// long-lived token does not keep finished work alive. Does nothing when the
  /// listener is not registered.
  void removeOnCancel(void Function() listener) {
    _listeners?.remove(listener);
  }
}

/// Signature of an isolate-safe compute callback executed by
/// [EngineComputePool].
///
/// Must be a top-level function, `static` method, or pure closure that does not
/// capture unsendable host objects (such as `ui.Image`, `Canvas`, or
/// `ReceivePort`).
typedef ComputeTaskCallback<P, R> = FutureOr<R> Function(P payload);

/// Persistent multi-worker background [Isolate] pool with priority scheduling,
/// instant queued-task cancellation, single-threaded inline fallback
/// (`workerCount: 0`), and zero-copy [TransferableTypedData] typed-array
/// helpers.
///
/// Every future returned by [schedule] settles: with the task's result, with
/// the error the task threw, with [ComputeCancelledException] when it is
/// cancelled or the pool is disposed, or with a [RemoteError] when the worker
/// isolate that ran it terminated. A worker that terminates is replaced, so
/// the pool keeps [workerCount] workers.
class EngineComputePool({
  final int workerCount = 2,
}) {
  this : assert(workerCount >= 0, 'workerCount must be >= 0: $workerCount');

  final Queue<_ComputeTaskEntry> _highQueue = Queue<_ComputeTaskEntry>();
  final Queue<_ComputeTaskEntry> _normalQueue = Queue<_ComputeTaskEntry>();
  final Queue<_ComputeTaskEntry> _lowQueue = Queue<_ComputeTaskEntry>();

  final List<_IsolateWorkerSlot> _workers = <_IsolateWorkerSlot>[];
  final Map<int, _ComputeTaskEntry> _inFlight = <int, _ComputeTaskEntry>{};

  /// The number of worker isolates that are being spawned right now.
  int _spawning = 0;
  Completer<void>? _spawnsSettled;
  Object? _spawnError;
  StackTrace? _spawnStackTrace;
  int _nextWorkerIndex = 0;

  bool _disposed = false;
  bool _inlineBusy = false;
  int _nextTaskId = 1;
  int _completedTaskCount = 0;

  /// Whether [dispose] has been called on this pool.
  bool get isDisposed => _disposed;

  /// Number of tasks waiting in the priority queues (`high` + `normal` +
  /// `low`).
  int get pendingTaskCount =>
      _highQueue.length + _normalQueue.length + _lowQueue.length;

  /// Number of workers currently executing a task.
  int get activeWorkerCount =>
      workerCount == 0 ? (_inlineBusy ? 1 : 0) : _inFlight.length;

  /// Total number of tasks that completed successfully since pool creation.
  int get completedTaskCount => _completedTaskCount;

  /// Eagerly spawns all [workerCount] background isolates and awaits their
  /// initial port handshakes. Safe to call multiple times; [schedule] also
  /// invokes this automatically on demand.
  ///
  /// The returned future fails when the pool is disposed, or when a worker
  /// could not be spawned.
  Future<void> warmUp() async {
    if (_disposed) {
      throw StateError('EngineComputePool is disposed.');
    }
    if (workerCount == 0) {
      return;
    }
    _ensureWorkers();
    while (_spawning > 0) {
      await (_spawnsSettled ??= Completer<void>()).future;
    }
    final error = _spawnError;
    if (!_disposed && _workers.length < workerCount && error != null) {
      Error.throwWithStackTrace(error, _spawnStackTrace ?? StackTrace.current);
    }
  }

  /// Starts spawning as many workers as are missing to reach [workerCount].
  void _ensureWorkers() {
    if (_disposed) {
      return;
    }
    while (_workers.length + _spawning < workerCount) {
      _spawning++;
      unawaited(_spawnWorker());
    }
  }

  /// Spawns one worker. Never completes with an error: a failed spawn is
  /// recorded in [_spawnError], and fails the queued tasks when it leaves the
  /// pool without any worker that could run them.
  Future<void> _spawnWorker() async {
    final slot = _IsolateWorkerSlot(
      index: _nextWorkerIndex++,
      onReply: _handleWorkerReply,
      onExit: _handleWorkerExit,
    );
    Object? error;
    StackTrace? stackTrace;
    try {
      await slot.start();
    } on Object catch (e, s) {
      error = e;
      stackTrace = s;
    }
    _spawning--;
    if (error != null) {
      slot.dispose();
      _spawnError = error;
      _spawnStackTrace = stackTrace;
      if (!_disposed && _workers.isEmpty && _spawning == 0) {
        _failQueued(error, stackTrace);
      }
    } else if (_disposed) {
      slot.dispose();
    } else {
      _spawnError = null;
      _spawnStackTrace = null;
      _workers.add(slot);
      _pumpQueue();
    }
    if (_spawning == 0) {
      final settled = _spawnsSettled;
      _spawnsSettled = null;
      settled?.complete();
    }
  }

  /// Schedules [callback] with [payload] onto the pool at [priority].
  ///
  /// Higher-priority queued tasks (`high` > `normal` > `low`) overtake lower
  /// priority queued tasks whenever a worker becomes free. If [cancelToken] is
  /// cancelled before execution completes, the returned [Future] fails
  /// immediately with [ComputeCancelledException].
  ///
  /// The returned future always settles, see the class documentation. A
  /// [callback] or [payload] that can not be sent to a worker isolate fails
  /// the future with the error of the failed send.
  Future<R> schedule<P, R>(
    ComputeTaskCallback<P, R> callback,
    P payload, {
    ComputePriority priority = ComputePriority.normal,
    ComputeCancellationToken? cancelToken,
  }) {
    if (_disposed) {
      return Future<R>.error(StateError('EngineComputePool is disposed.'));
    }
    if (cancelToken?.isCancelled ?? false) {
      return Future<R>.error(const ComputeCancelledException());
    }

    final task = _QueuedComputeTask<P, R>(
      id: _nextTaskId++,
      callback: callback,
      payload: payload,
      priority: priority,
    );

    if (cancelToken != null) {
      void cancelTask() {
        if (task.cancelled || task.isCompleted) {
          return;
        }
        _removeFromQueues(task);
        task.cancelWithError(const ComputeCancelledException());
      }

      cancelToken.onCancel(cancelTask);
      // A token usually outlives its tasks: do not let it keep them.
      task.onSettled = () => cancelToken.removeOnCancel(cancelTask);
    }

    switch (priority) {
      case ComputePriority.high:
        _highQueue.addLast(task);
      case ComputePriority.normal:
        _normalQueue.addLast(task);
      case ComputePriority.low:
        _lowQueue.addLast(task);
    }

    if (workerCount == 0) {
      _pumpInline();
    } else {
      _ensureWorkers();
      _pumpQueue();
    }

    return task.completer.future;
  }

  void _removeFromQueues(_ComputeTaskEntry task) {
    switch (task.priority) {
      case ComputePriority.high:
        _highQueue.remove(task);
      case ComputePriority.normal:
        _normalQueue.remove(task);
      case ComputePriority.low:
        _lowQueue.remove(task);
    }
  }

  _ComputeTaskEntry? _dequeueNextValid() {
    while (_highQueue.isNotEmpty) {
      final t = _highQueue.removeFirst();
      if (!t.cancelled && !t.isCompleted) {
        return t;
      }
    }
    while (_normalQueue.isNotEmpty) {
      final t = _normalQueue.removeFirst();
      if (!t.cancelled && !t.isCompleted) {
        return t;
      }
    }
    while (_lowQueue.isNotEmpty) {
      final t = _lowQueue.removeFirst();
      if (!t.cancelled && !t.isCompleted) {
        return t;
      }
    }
    return null;
  }

  /// Fails every queued task with [error], for when nothing can run them.
  void _failQueued(Object error, StackTrace? stackTrace) {
    for (
      var task = _dequeueNextValid();
      task != null;
      task = _dequeueNextValid()
    ) {
      task.failIfPending(error, stackTrace);
    }
  }

  void _pumpInline() {
    if (_inlineBusy || _disposed) {
      return;
    }
    final next = _dequeueNextValid();
    if (next == null) {
      return;
    }
    _inlineBusy = true;
    // Tracked like a task on a worker, so that [dispose] fails it too.
    _inFlight[next.id] = next;
    scheduleMicrotask(() async {
      try {
        if (!next.cancelled && !_disposed) {
          final result = await next.runInline();
          if (!next.cancelled && !next.isCompleted) {
            _completedTaskCount++;
            next.completeValue(result);
          }
        }
      } on Object catch (error, stackTrace) {
        next.failIfPending(error, stackTrace);
      } finally {
        _inFlight.remove(next.id);
        _inlineBusy = false;
        if (!_disposed) {
          _pumpInline();
        }
      }
    });
  }

  void _pumpQueue() {
    if (_disposed || _workers.isEmpty) {
      return;
    }
    for (var i = 0; i < _workers.length; i++) {
      final worker = _workers[i];
      // A task that can not be sent leaves the worker free for the next one.
      while (!worker.busy) {
        final next = _dequeueNextValid();
        if (next == null) {
          return;
        }
        try {
          next.sendTo(worker.sendPort);
        } on Object catch (error, stackTrace) {
          next.failIfPending(error, stackTrace);
          continue;
        }
        worker.busy = true;
        worker.currentTaskId = next.id;
        _inFlight[next.id] = next;
      }
    }
  }

  void _handleWorkerReply(
    _IsolateWorkerSlot worker,
    int taskId,
    Object? valueOrError,
    String? stackStr, {
    required bool ok,
  }) {
    worker.busy = false;
    worker.currentTaskId = null;
    final task = _inFlight.remove(taskId);
    if (task != null && !task.cancelled && !task.isCompleted) {
      if (ok) {
        try {
          task.completeValue(valueOrError);
          _completedTaskCount++;
        } on Object catch (error, stackTrace) {
          task.failIfPending(error, stackTrace);
        }
      } else {
        task.failIfPending(
          RemoteError(
            valueOrError?.toString() ?? 'Unknown isolate compute error',
            stackStr ?? '',
          ),
        );
      }
    }
    if (!_disposed) {
      _pumpQueue();
    }
  }

  /// Called when the isolate of [worker] terminated on its own: it exited, was
  /// killed, or hit an uncaught error.
  void _handleWorkerExit(_IsolateWorkerSlot worker) {
    final wasLive = _workers.remove(worker);
    worker.dispose();
    if (_disposed || !wasLive) {
      return;
    }
    final taskId = worker.currentTaskId;
    if (taskId != null) {
      _inFlight
          .remove(taskId)
          ?.failIfPending(
            RemoteError(
              worker.lastError ??
                  'The compute worker isolate terminated before the task '
                      'completed.',
              worker.lastErrorStackTrace ?? '',
            ),
          );
    }
    _ensureWorkers();
    _pumpQueue();
  }

  /// Terminates all background isolates immediately, closes communication
  /// ports, and fails any pending/in-flight tasks with
  /// [ComputeCancelledException]. That includes the task that the inline mode
  /// (`workerCount: 0`) has taken off the queue but not finished.
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    const err = ComputeCancelledException('EngineComputePool disposed.');

    void cancelQueue(Queue<_ComputeTaskEntry> q) {
      while (q.isNotEmpty) {
        final t = q.removeFirst();
        t.cancelWithError(err);
      }
    }

    cancelQueue(_highQueue);
    cancelQueue(_normalQueue);
    cancelQueue(_lowQueue);

    final inFlight = _inFlight.values.toList(growable: false);
    _inFlight.clear();
    for (final t in inFlight) {
      t.cancelWithError(err);
    }

    for (final worker in _workers) {
      worker.dispose();
    }
    _workers.clear();
  }

  /// Packs a [Float32List] view into zero-copy [TransferableTypedData] for
  /// O(1) cross-isolate transfer.
  static TransferableTypedData packFloat32(Float32List data) =>
      TransferableTypedData.fromList(<TypedData>[data]);

  /// Materializes a [Float32List] from [TransferableTypedData] in the receiving
  /// isolate.
  static Float32List unpackFloat32(TransferableTypedData data) =>
      data.materialize().asFloat32List();

  /// Packs a [Uint8List] view into zero-copy [TransferableTypedData] for
  /// O(1) cross-isolate transfer.
  static TransferableTypedData packUint8(Uint8List data) =>
      TransferableTypedData.fromList(<TypedData>[data]);

  /// Materializes a [Uint8List] from [TransferableTypedData] in the receiving
  /// isolate.
  static Uint8List unpackUint8(TransferableTypedData data) =>
      data.materialize().asUint8List();

  /// Packs an [Int32List] view into zero-copy [TransferableTypedData] for
  /// O(1) cross-isolate transfer.
  static TransferableTypedData packInt32(Int32List data) =>
      TransferableTypedData.fromList(<TypedData>[data]);

  /// Materializes an [Int32List] from [TransferableTypedData] in the receiving
  /// isolate.
  static Int32List unpackInt32(TransferableTypedData data) =>
      data.materialize().asInt32List();
}

sealed class _ComputeTaskEntry({
  required final int id,
  required final ComputePriority priority,
}) {
  bool cancelled = false;

  bool get isCompleted;

  FutureOr<Object?> runInline();

  void sendTo(SendPort port);

  void completeValue(Object? rawValue);

  void failIfPending(Object error, [StackTrace? stackTrace]);

  void cancelWithError(Object error);
}

final class _QueuedComputeTask<P, R>({
  required super.id,
  required final ComputeTaskCallback<P, R> callback,
  required final P payload,
  required super.priority,
}) extends _ComputeTaskEntry {
  final Completer<R> completer = Completer<R>();

  /// Invoked once, when [completer] has been completed in any way.
  void Function()? onSettled;

  @override
  bool get isCompleted => completer.isCompleted;

  @override
  FutureOr<Object?> runInline() => callback(payload);

  @override
  void sendTo(SendPort port) {
    port.send(<Object?>[id, callback, payload]);
  }

  @override
  void completeValue(Object? rawValue) {
    completer.complete(rawValue as R);
    _settled();
  }

  @override
  void failIfPending(Object error, [StackTrace? stackTrace]) {
    if (!cancelled && !completer.isCompleted) {
      completer.completeError(error, stackTrace);
      _settled();
    }
  }

  @override
  void cancelWithError(Object error) {
    cancelled = true;
    if (!completer.isCompleted) {
      completer.completeError(error);
      _settled();
    }
  }

  void _settled() {
    final onSettled = this.onSettled;
    this.onSettled = null;
    onSettled?.call();
  }
}

class _IsolateWorkerSlot({
  required final int index,
  required final void Function(
    _IsolateWorkerSlot worker,
    int taskId,
    Object? valueOrError,
    String? stackStr, {
    required bool ok,
  })
  onReply,
  required final void Function(_IsolateWorkerSlot worker) onExit,
}) {
  late final RawReceivePort _rawPort = RawReceivePort(
    null,
    'EngineComputePool-$index',
  );

  /// Receives the uncaught errors and the exit notification of the isolate.
  late final RawReceivePort _lifecyclePort = RawReceivePort(
    null,
    'EngineComputePool-$index-lifecycle',
  );
  Isolate? _isolate;
  late final SendPort sendPort;
  bool busy = false;
  bool _disposed = false;

  /// The task that was sent to the isolate and has not been answered.
  int? currentTaskId;

  /// The uncaught error that the isolate reported before it terminated.
  String? lastError;
  String? lastErrorStackTrace;

  Future<void> start() async {
    final handshake = Completer<SendPort>();
    // The failure of a start-up is delivered through the await below.
    handshake.future.ignore();
    _rawPort.handler = (Object? message) {
      if (!handshake.isCompleted) {
        if (message is SendPort) {
          handshake.complete(message);
        }
        return;
      }
      if (message is List<Object?> && message.length == 4) {
        final taskId = message[0]! as int;
        final ok = message[1]! as bool;
        final valueOrError = message[2];
        final stackStr = message[3] as String?;
        onReply(this, taskId, valueOrError, stackStr, ok: ok);
      }
    };
    _lifecyclePort.handler = (Object? message) {
      if (_disposed) {
        return;
      }
      if (message is List<Object?> && message.length == 2) {
        // An uncaught error, which is fatal: the exit notification follows.
        lastError = message[0]?.toString();
        lastErrorStackTrace = message[1]?.toString();
        return;
      }
      if (!handshake.isCompleted) {
        handshake.completeError(
          StateError(
            lastError ?? 'The compute worker isolate exited during start-up.',
          ),
        );
        return;
      }
      onExit(this);
    };

    _isolate = await Isolate.spawn<SendPort>(
      _computePoolWorkerEntryPoint,
      _rawPort.sendPort,
      debugName: 'FlameComputeWorker-$index',
      onExit: _lifecyclePort.sendPort,
      onError: _lifecyclePort.sendPort,
    );
    sendPort = await handshake.future;
  }

  void dispose() {
    _disposed = true;
    _rawPort.close();
    _lifecyclePort.close();
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
  }
}

void _computePoolWorkerEntryPoint(SendPort hostSendPort) {
  final workerRawPort = RawReceivePort();
  workerRawPort.handler = (Object? message) async {
    if (message is! List<Object?> || message.length != 3) {
      return;
    }
    final taskId = message[0]! as int;
    final fn = message[1]! as Function;
    final payload = message[2];
    try {
      final dynamic rawResult = Function.apply(fn, <Object?>[payload]);
      final resolved = rawResult is Future ? await rawResult : rawResult;
      hostSendPort.send(<Object?>[taskId, true, resolved, null]);
    } on Object catch (error, stackTrace) {
      hostSendPort.send(
        <Object?>[taskId, false, error.toString(), stackTrace.toString()],
      );
    }
  };
  hostSendPort.send(workerRawPort.sendPort);
}
