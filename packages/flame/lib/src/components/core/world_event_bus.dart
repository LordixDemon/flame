import 'package:flame/src/components/core/signal.dart';

class _QueuedEvent<T>(final Signal<T> channel, final T payload) {
  void dispatch() => channel.emit(payload);
}

/// Type-indexed synchronous and deferred end-of-frame event bus scoped to a
/// `World` or game session.
class WorldEventBus({final int maxFlushIterations = 8}) {
  final Map<Type, Object> _channels = <Type, Object>{};
  List<_QueuedEvent<dynamic>> _pending = <_QueuedEvent<dynamic>>[];
  List<_QueuedEvent<dynamic>> _draining = <_QueuedEvent<dynamic>>[];

  /// Number of deferred events currently awaiting [flushQueue].
  int get pendingCount => _pending.length;

  Signal<T> _channelOf<T extends Object>() {
    final existing = _channels[T];
    if (existing is Signal<T>) {
      return existing;
    }
    final created = Signal<T>();
    _channels[T] = created;
    return created;
  }

  /// Subscribes [listener] to events of exact runtime type `T`.
  SignalSubscription on<T extends Object>(void Function(T event) listener) =>
      _channelOf<T>().connect(listener);

  /// Subscribes [listener] to the next single event of type `T`.
  SignalSubscription once<T extends Object>(void Function(T event) listener) =>
      _channelOf<T>().connectOnce(listener);

  /// Immediately dispatches [event] to all active `on<T>` subscribers.
  void emit<T extends Object>(T event) {
    final existing = _channels[T];
    if (existing is Signal<T>) {
      existing.emit(event);
    }
  }

  /// Queues [event] for deterministic delivery during the next [flushQueue]
  /// pass (for example at the end of `World.updateTree`).
  void enqueue<T extends Object>(T event) {
    _pending.add(_QueuedEvent<T>(_channelOf<T>(), event));
  }

  /// Drains queued events in FIFO order, handling cascading [enqueue] calls up
  /// to [maxFlushIterations] rounds. Returns total dispatched events.
  int flushQueue() {
    if (_pending.isEmpty) {
      return 0;
    }
    var dispatched = 0;
    var iteration = 0;
    while (_pending.isNotEmpty && iteration < maxFlushIterations) {
      iteration++;
      final batch = _pending;
      _pending = _draining..clear();
      _draining = batch;
      for (var i = 0; i < batch.length; i++) {
        batch[i].dispatch();
        dispatched++;
      }
      batch.clear();
    }
    return dispatched;
  }

  /// Clears all listeners and queued events.
  void clear() {
    for (final channel in _channels.values) {
      if (channel is Signal) {
        channel.clear();
      }
    }
    _channels.clear();
    _pending.clear();
    _draining.clear();
  }
}
