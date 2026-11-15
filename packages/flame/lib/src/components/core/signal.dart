/// Handle returned when subscribing to a [Signal] or `WorldEventBus` channel.
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
