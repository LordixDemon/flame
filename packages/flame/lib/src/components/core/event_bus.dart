import 'package:flame/src/camera/world.dart';
import 'package:flame/src/components/core/component.dart';

/// Handle returned when subscribing to a [Signal] or [WorldEventBus] channel.
class SignalSubscription(final void Function() _onCancel) {
  bool _isCancelled = false;

  /// Whether this subscription has already been cancelled.
  bool get isCancelled => _isCancelled;

  /// Detaches the listener idempotently.
  void cancel() {
    if (_isCancelled) {
      return;
    }
    _isCancelled = true;
    _onCancel();
  }
}

/// Lightweight, re-entrancy-safe typed signal supporting zero-allocation
/// synchronous dispatch when listener membership does not mutate mid-emit.
class Signal<T>() {
  final List<void Function(T payload)> _listeners =
      <void Function(T payload)>[];
  int _dispatchDepth = 0;
  bool _needsCompaction = false;
  final List<bool> _activeFlags = <bool>[];

  /// Number of currently active listeners.
  int get listenerCount {
    var count = 0;
    for (var i = 0; i < _activeFlags.length; i++) {
      if (_activeFlags[i]) {
        count++;
      }
    }
    return count;
  }

  /// Registers [listener] and returns a [SignalSubscription] handle.
  SignalSubscription connect(void Function(T payload) listener) {
    _listeners.add(listener);
    _activeFlags.add(true);
    return SignalSubscription(() => disconnect(listener));
  }

  /// Registers a one-shot [listener] that automatically disconnects after its
  /// first invocation.
  SignalSubscription connectOnce(void Function(T payload) listener) {
    late final SignalSubscription sub;
    return sub = connect((payload) {
      sub.cancel();
      listener(payload);
    });
  }

  /// Removes [listener] from this signal.
  void disconnect(void Function(T payload) listener) {
    for (var i = _listeners.length - 1; i >= 0; i--) {
      if (_activeFlags[i] && _listeners[i] == listener) {
        if (_dispatchDepth > 0) {
          _activeFlags[i] = false;
          _needsCompaction = true;
        } else {
          _listeners.removeAt(i);
          _activeFlags.removeAt(i);
        }
        return;
      }
    }
  }

  /// Removes all listeners immediately.
  void clear() {
    if (_dispatchDepth > 0) {
      for (var i = 0; i < _activeFlags.length; i++) {
        _activeFlags[i] = false;
      }
      _needsCompaction = true;
    } else {
      _listeners.clear();
      _activeFlags.clear();
    }
  }

  /// Synchronously invokes all active listeners registered at the start of
  /// [emit].
  void emit(T payload) {
    final len = _listeners.length;
    if (len == 0) {
      return;
    }
    _dispatchDepth++;
    try {
      for (var i = 0; i < len; i++) {
        if (_activeFlags[i]) {
          _listeners[i](payload);
        }
      }
    } finally {
      _dispatchDepth--;
      if (_dispatchDepth == 0 && _needsCompaction) {
        _compact();
      }
    }
  }

  void _compact() {
    _needsCompaction = false;
    var write = 0;
    for (var read = 0; read < _listeners.length; read++) {
      if (_activeFlags[read]) {
        if (write != read) {
          _listeners[write] = _listeners[read];
          _activeFlags[write] = true;
        }
        write++;
      }
    }
    _listeners.length = write;
    _activeFlags.length = write;
  }
}

class _QueuedEvent<T>(final Signal<T> channel, final T payload) {
  void dispatch() => channel.emit(payload);
}

/// Type-indexed synchronous and deferred end-of-frame event bus scoped to a
/// [World] or game session.
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

class _DeferredBusBinding<T extends Object>(
  final WorldEventBus? explicitBus,
  final void Function(T event) listener, {
  final bool once = false,
}) {
  SignalSubscription attach(WorldEventBus resolved) =>
      once ? resolved.once<T>(listener) : resolved.on<T>(listener);
}

/// Lifecycle-safe mixin attaching [Signal] and [WorldEventBus] listeners in
/// [onMount] and automatically cancelling them in [onRemove].
mixin HasEventBusSubscriptions on Component {
  final List<SignalSubscription> _activeSubs = <SignalSubscription>[];
  final List<_DeferredBusBinding<dynamic>> _deferredBindings =
      <_DeferredBusBinding<dynamic>>[];

  /// Tracks an arbitrary [SignalSubscription] and cancels it automatically when
  /// this component is removed from the tree.
  SignalSubscription autoCancelSignal(SignalSubscription subscription) {
    _activeSubs.add(subscription);
    return subscription;
  }

  /// Subscribes to `T` on [bus] (or the enclosing `World.eventBus` when [bus]
  /// is omitted). Safe to call in constructors, `onLoad`, or `onMount`.
  void listenEvent<T extends Object>(
    void Function(T event) listener, {
    WorldEventBus? bus,
  }) {
    final binding = _DeferredBusBinding<T>(bus, listener);
    if (isMounted || isMounting) {
      final resolved = bus ?? _resolveEnclosingBus();
      if (resolved != null) {
        _activeSubs.add(binding.attach(resolved));
      }
    } else {
      _deferredBindings.add(binding);
    }
  }

  /// Subscribes to the next single event of `T` on [bus] (or the enclosing
  /// `World.eventBus`), automatically detaching on delivery or `onRemove`.
  void listenEventOnce<T extends Object>(
    void Function(T event) listener, {
    WorldEventBus? bus,
  }) {
    final binding = _DeferredBusBinding<T>(bus, listener, once: true);
    if (isMounted || isMounting) {
      final resolved = bus ?? _resolveEnclosingBus();
      if (resolved != null) {
        _activeSubs.add(binding.attach(resolved));
      }
    } else {
      _deferredBindings.add(binding);
    }
  }

  WorldEventBus? _resolveEnclosingBus() {
    final world = findParent<World>(includeSelf: true);
    return world?.eventBus;
  }

  @override
  void onMount() {
    super.onMount();
    if (_deferredBindings.isNotEmpty) {
      final worldBus = _resolveEnclosingBus();
      for (var i = 0; i < _deferredBindings.length; i++) {
        final b = _deferredBindings[i];
        final resolved = b.explicitBus ?? worldBus;
        if (resolved != null) {
          _activeSubs.add(b.attach(resolved));
        }
      }
    }
  }

  @override
  void onRemove() {
    for (var i = 0; i < _activeSubs.length; i++) {
      _activeSubs[i].cancel();
    }
    _activeSubs.clear();
    super.onRemove();
  }
}
