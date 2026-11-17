import 'dart:async';
import 'dart:isolate';

import 'package:flame/cache.dart';
import 'package:flutter_test/flutter_test.dart';

int _double(int v) => v * 2;

int _one(Object? _) => 1;

int _exitIsolate(int v) {
  Isolate.exit();
}

int _failLater(int v) {
  // An error outside of the awaited computation is uncaught, and fatal for
  // the isolate.
  Timer.run(() => throw StateError('uncaught in worker'));
  return v;
}

Future<int> _slowDouble(int v) async {
  await Future<void>.delayed(const Duration(milliseconds: 50));
  return v * 2;
}

/// The outcome of [future]: its value, its error, or [_neverCompleted].
Future<Object?> _settle(Future<Object?> future) async {
  try {
    return await future.timeout(const Duration(seconds: 5));
  } on TimeoutException {
    return _neverCompleted;
  } on Object catch (error) {
    return error;
  }
}

const _neverCompleted = 'NEVER COMPLETED';

void main() {
  group('EngineComputePool settles every scheduled task', () {
    test('inline pool: a task scheduled right before dispose() is '
        'cancelled', () async {
      final pool = EngineComputePool(workerCount: 0);
      final future = pool.schedule<int, int>(_double, 21);
      unawaited(pool.dispose());

      expect(await _settle(future), isA<ComputeCancelledException>());
      expect(pool.activeWorkerCount, 0);
    });

    test('inline pool: dispose() cancels the running task and the queued '
        'ones', () async {
      final pool = EngineComputePool(workerCount: 0);
      final running = _settle(pool.schedule<int, int>(_slowDouble, 1));
      final queued = _settle(pool.schedule<int, int>(_double, 2));
      // Lets the first task start.
      await Future<void>.delayed(Duration.zero);
      expect(pool.activeWorkerCount, 1);
      unawaited(pool.dispose());

      expect(await running, isA<ComputeCancelledException>());
      expect(await queued, isA<ComputeCancelledException>());
      // The result that arrives afterwards is dropped quietly.
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(pool.completedTaskCount, 0);
    });

    test('a task that can not be sent fails and does not strand the tasks '
        'behind it', () async {
      final pool = EngineComputePool(workerCount: 1);
      addTearDown(pool.dispose);
      final port = ReceivePort();
      addTearDown(port.close);

      // A ReceivePort can not be sent to another isolate.
      final unsendable = _settle(pool.schedule<Object?, int>(_one, port));
      final alsoUnsendable = _settle(pool.schedule<Object?, int>(_one, port));
      final good = _settle(pool.schedule<int, int>(_double, 21));

      expect(await unsendable, isA<ArgumentError>());
      expect(await alsoUnsendable, isA<ArgumentError>());
      expect(await good, 42);
      expect(pool.pendingTaskCount, 0);
      expect(pool.activeWorkerCount, 0);
    });

    test('a worker isolate that exits fails its task, and the pool goes '
        'on with a new worker', () async {
      final pool = EngineComputePool(workerCount: 1);
      addTearDown(pool.dispose);

      final dying = _settle(pool.schedule<int, int>(_exitIsolate, 1));
      final next = _settle(pool.schedule<int, int>(_double, 21));

      expect(await dying, isA<RemoteError>());
      expect(await next, 42);
      expect(await _settle(pool.schedule<int, int>(_double, 4)), 8);
      expect(pool.activeWorkerCount, 0);
    });

    test('a worker isolate that dies of an uncaught error does not swallow '
        'the tasks sent to it afterwards', () async {
      final pool = EngineComputePool(workerCount: 1);
      addTearDown(pool.dispose);

      // The task itself completes; the isolate dies right after.
      expect(await _settle(pool.schedule<int, int>(_failLater, 7)), 7);
      for (var i = 0; i < 20; i++) {
        final outcome = await _settle(pool.schedule<int, int>(_double, i));
        expect(
          outcome,
          anyOf(i * 2, isA<RemoteError>()),
          reason: 'task $i neither completed nor failed',
        );
      }
      // The replacement worker is up by now.
      await pool.warmUp();
      expect(await _settle(pool.schedule<int, int>(_double, 50)), 100);
    });

    test('warmUp() fails on a disposed pool', () async {
      final pool = EngineComputePool(workerCount: 1);
      await pool.dispose();
      expect(pool.warmUp(), throwsStateError);
      expect(pool.schedule<int, int>(_double, 1), throwsStateError);
    });
  });

  group('ComputeCancellationToken', () {
    test('a listener can be taken off again', () {
      final token = ComputeCancellationToken();
      var calls = 0;
      void listener() => calls++;
      token.onCancel(listener);
      token.removeOnCancel(listener);
      token.removeOnCancel(listener);
      token.cancel();
      expect(calls, 0);
    });

    test('a long-lived token does not keep the tasks that are done', () async {
      final pool = EngineComputePool(workerCount: 0);
      addTearDown(pool.dispose);
      final token = _CountingToken();

      for (var i = 0; i < 50; i++) {
        final future = pool.schedule<int, int>(
          _double,
          i,
          cancelToken: token,
        );
        expect(token.registered, 1);
        expect(await future, i * 2);
        expect(token.registered, 0);
      }

      // A failed task lets go of the token as well.
      final failing = _settle(
        pool.schedule<int, int>(_throws, 1, cancelToken: token),
      );
      expect(await failing, isA<StateError>());
      expect(token.registered, 0);

      // Cancelling reaches the task that is still pending.
      final pending = _settle(
        pool.schedule<int, int>(_slowDouble, 1, cancelToken: token),
      );
      expect(token.registered, 1);
      token.cancel();
      expect(await pending, isA<ComputeCancelledException>());
      expect(
        await _settle(pool.schedule<int, int>(_double, 1, cancelToken: token)),
        isA<ComputeCancelledException>(),
      );
    });
  });
}

int _throws(int v) => throw StateError('task failed');

/// Counts the listeners that are registered and not taken off again.
class _CountingToken() extends ComputeCancellationToken {
  int registered = 0;

  @override
  void onCancel(void Function() listener) {
    registered++;
    super.onCancel(listener);
  }

  @override
  void removeOnCancel(void Function() listener) {
    registered--;
    super.removeOnCancel(listener);
  }
}
