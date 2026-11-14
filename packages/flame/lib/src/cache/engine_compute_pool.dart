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
  void onCancel(void Function() listener) {
    if (_cancelled) {
      listener();
      return;
    }
    (_listeners ??= <void Function()>[]).add(listener);
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
class EngineComputePool({
  final int workerCount = 2,
}) {
  this : assert(workerCount >= 0, 'workerCount must be >= 0: $workerCount');

  final Queue<_ComputeTaskEntry> _highQueue = Queue<_ComputeTaskEntry>();
  final Queue<_ComputeTaskEntry> _normalQueue = Queue<_ComputeTaskEntry>();
  final Queue<_ComputeTaskEntry> _lowQueue = Queue<_ComputeTaskEntry>();

  final List<_IsolateWorkerSlot> _workers = <_IsolateWorkerSlot>[];
  final Map<int, _ComputeTaskEntry> _inFlight = <int, _ComputeTaskEntry>{};

  Future<void>? _warmUpFuture;
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
  Future<void> warmUp() {
    if (_disposed) {
      return Future<void>.error(StateError('EngineComputePool is disposed.'));
    }
    if (workerCount == 0) {
      return Future<void>.value();
    }
    return _warmUpFuture ??= _spawnWorkers();
  }

  Future<void> _spawnWorkers() async {
    final futures = <Future<_IsolateWorkerSlot>>[];
    for (var i = 0; i < workerCount; i++) {
      futures.add(_spawnSingleWorker(i));
    }
    final spawned = await Future.wait(futures);
    if (_disposed) {
      for (final slot in spawned) {
        slot.dispose();
      }
      return;
    }
    _workers.addAll(spawned);
    _pumpQueue();
  }

  Future<_IsolateWorkerSlot> _spawnSingleWorker(int index) async {
    final slot = _IsolateWorkerSlot(index: index, onReply: _handleWorkerReply);
    await slot.start();
    return slot;
  }

  /// Schedules [callback] with [payload] onto the pool at [priority].
  ///
  /// Higher-priority queued tasks (`high` > `normal` > `low`) overtake lower
  /// priority queued tasks whenever a worker becomes free. If [cancelToken] is
  /// cancelled before execution completes, the returned [Future] fails
  /// immediately with [ComputeCancelledException].
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
      cancelToken.onCancel(() {
        if (task.cancelled || task.completer.isCompleted) {
          return;
        }
        task.cancelled = true;
        _removeFromQueues(task);
        task.completer.completeError(const ComputeCancelledException());
      });
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
    } else if (_workers.length == workerCount) {
      _pumpQueue();
    } else {
      unawaited(warmUp().catchError(task.failIfPending));
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

  void _pumpInline() {
    if (_inlineBusy || _disposed) {
      return;
    }
    final next = _dequeueNextValid();
    if (next == null) {
      return;
    }
    _inlineBusy = true;
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
      if (worker.busy) {
        continue;
      }
      final next = _dequeueNextValid();
      if (next == null) {
        return;
      }
      worker.busy = true;
      _inFlight[next.id] = next;
      try {
        next.sendTo(worker.sendPort);
      } on Object catch (error, stackTrace) {
        worker.busy = false;
        _inFlight.remove(next.id);
        next.failIfPending(error, stackTrace);
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
    final task = _inFlight.remove(taskId);
    if (task != null && !task.cancelled && !task.isCompleted) {
      if (ok) {
        _completedTaskCount++;
        task.completeValue(valueOrError);
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

  /// Terminates all background isolates immediately, closes communication
  /// ports, and fails any pending/in-flight tasks with
  /// [ComputeCancelledException].
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

    for (final t in _inFlight.values) {
      t.cancelWithError(err);
    }
    _inFlight.clear();

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
  }

  @override
  void failIfPending(Object error, [StackTrace? stackTrace]) {
    if (!cancelled && !completer.isCompleted) {
      completer.completeError(error, stackTrace);
    }
  }

  @override
  void cancelWithError(Object error) {
    cancelled = true;
    if (!completer.isCompleted) {
      completer.completeError(error);
    }
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
}) {
  late final RawReceivePort _rawPort = RawReceivePort(
    null,
    'EngineComputePool-$index',
  );
  Isolate? _isolate;
  late final SendPort sendPort;
  bool busy = false;

  Future<void> start() async {
    final handshake = Completer<SendPort>();
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

    _isolate = await Isolate.spawn<SendPort>(
      _computePoolWorkerEntryPoint,
      _rawPort.sendPort,
      debugName: 'FlameComputeWorker-$index',
    );
    sendPort = await handshake.future;
  }

  void dispose() {
    _rawPort.close();
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
