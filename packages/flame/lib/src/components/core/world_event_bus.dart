import 'package:flame/src/components/core/signal.dart';

class _QueuedEvent<T extends Object>(
  final WorldEventBus bus,
  final T payload,
) {
  void dispatch() => bus.emit<T>(payload);
}

/// Type-indexed synchronous and deferred end-of-frame event bus scoped to a
/// `World` or game session.
///
/// An event is delivered to the listeners that subscribed to its runtime
/// type, whatever the static type of the expression that was passed to
/// [emit] or [enqueue]: an event that travels through a variable, a list or a
/// parameter typed as a supertype still reaches `on<ConcreteEvent>`
/// listeners. When that static type differs from the runtime type, the
/// listeners of the static type receive the event as well, so
/// `emit<GameEvent>(CoinPicked())` reaches both `on<CoinPicked>` and
/// `on<GameEvent>`. Other supertypes of the event are not notified.
class WorldEventBus({final int maxFlushIterations = 8}) {
  final Map<Type, Object> _channels = <Type, Object>{};
  List<_QueuedEvent<Object>> _pending = <_QueuedEvent<Object>>[];
  List<_QueuedEvent<Object>> _draining = <_QueuedEvent<Object>>[];
  bool _flushing = false;

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

  /// Subscribes [listener] to events whose runtime type is exactly `T` (and
  /// to events that are emitted with `T` as their static type).
  SignalSubscription on<T extends Object>(void Function(T event) listener) =>
      _channelOf<T>().connect(listener);

  /// Subscribes [listener] to the next single event of type `T`.
  SignalSubscription once<T extends Object>(void Function(T event) listener) =>
      _channelOf<T>().connectOnce(listener);

  /// Immediately dispatches [event] to the `on` subscribers of its runtime
  /// type and, when that differs from it, of the static type `T`.
  void emit<T extends Object>(T event) {
    final runtimeType = event.runtimeType;
    final runtimeChannel = _channels[runtimeType];
    if (runtimeChannel != null) {
      // The channel is a `Signal<runtimeType>`, so the payload always passes
      // the covariance check of this call.
      (runtimeChannel as Signal<Object>).emit(event);
    }
    if (runtimeType != T) {
      final staticChannel = _channels[T];
      if (staticChannel is Signal<T>) {
        staticChannel.emit(event);
      }
    }
  }

  /// Queues [event] for deterministic delivery during the next [flushQueue]
  /// pass (for example at the end of `World.updateTree`). The listeners are
  /// chosen at delivery time, by the same rule as for [emit].
  void enqueue<T extends Object>(T event) {
    _pending.add(_QueuedEvent<T>(this, event));
  }

  /// Drains queued events in FIFO order, handling cascading [enqueue] calls up
  /// to [maxFlushIterations] rounds. Returns total dispatched events.
  ///
  /// A call made from inside a listener while a flush is running does nothing
  /// and returns `0`: the running flush delivers whatever is queued.
  int flushQueue() {
    if (_flushing || _pending.isEmpty) {
      return 0;
    }
    _flushing = true;
    var dispatched = 0;
    var iteration = 0;
    try {
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
    } finally {
      _flushing = false;
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
