import 'package:flame/src/components/core/component.dart';
import 'package:flutter/foundation.dart'
    show Listenable, ValueListenable, VoidCallback;
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:meta/meta.dart';

class _ListenableBinding({
  required final Listenable source,
  required final VoidCallback deliver,
  required final bool fireImmediately,
  required final bool coalescePerFrame,
  required final bool notifyGameActivity,
}) {
  VoidCallback? _attachedListener;
  bool _dirtyThisFrame = false;

  void attach(HasListenableSubscriptions owner) {
    if (_attachedListener != null) {
      return;
    }
    void handleSignal() {
      if (notifyGameActivity) {
        owner.findGame()?.notifyActivity();
      }
      if (coalescePerFrame) {
        if (!_dirtyThisFrame) {
          _dirtyThisFrame = true;
          owner._enqueueCoalesced(this);
        }
      } else {
        deliver();
      }
    }

    _attachedListener = handleSignal;
    source.addListener(handleSignal);
    if (fireImmediately) {
      deliver();
    }
  }

  void detach() {
    final listener = _attachedListener;
    if (listener != null) {
      source.removeListener(listener);
      _attachedListener = null;
    }
    _dirtyThisFrame = false;
  }

  void flushIfDirty() {
    if (_dirtyThisFrame && _attachedListener != null) {
      _dirtyThisFrame = false;
      deliver();
    }
  }
}

/// Lifecycle-safe reactive subscription mixin for Flame [Component]s.
///
/// Automatically attaches registered [Listenable] / [ValueListenable]
/// listeners on [onMount] (or immediately if already mounted), detaches every
/// listener deterministically in [onRemove] so components can be mounted,
/// removed, and re-mounted without leaking callbacks, optionally coalesces
/// rapid multiple mutations within a frame into a single callback invocation,
/// and wakes adaptive game loops via `findGame()?.notifyActivity()`.
mixin HasListenableSubscriptions on Component {
  final List<_ListenableBinding> _bindings = <_ListenableBinding>[];
  final List<_ListenableBinding> _coalescedPending = <_ListenableBinding>[];
  bool _postFrameScheduled = false;

  /// Number of active listener subscriptions currently attached to their
  /// [Listenable] sources.
  @visibleForTesting
  int get activeSubscriptionCount {
    var count = 0;
    for (var i = 0; i < _bindings.length; i++) {
      if (_bindings[i]._attachedListener != null) {
        count++;
      }
    }
    return count;
  }

  /// Subscribes to [source], invoking [onChanged] with `source.value` whenever
  /// it notifies while this component is mounted.
  ///
  /// - [fireImmediately]: invokes [onChanged] with the current `source.value`
  ///   as soon as the component mounts (or immediately if already mounted).
  /// - [coalescePerFrame]: batches multiple notifications within the same frame
  ///   into a single [onChanged] call flushed via [flushCoalescedSubscriptions]
  ///   (and automatically on the next frame boundary).
  /// - [notifyGameActivity]: calls `findGame()?.notifyActivity()` so
  ///   idle-throttled adaptive game loops wake immediately on state changes.
  void listenTo<T>(
    ValueListenable<T> source,
    void Function(T value) onChanged, {
    bool fireImmediately = false,
    bool coalescePerFrame = false,
    bool notifyGameActivity = true,
  }) {
    final binding = _ListenableBinding(
      source: source,
      deliver: () => onChanged(source.value),
      fireImmediately: fireImmediately,
      coalescePerFrame: coalescePerFrame,
      notifyGameActivity: notifyGameActivity,
    );
    _bindings.add(binding);
    if (isMounted) {
      binding.attach(this);
    }
  }

  /// Subscribes to a general [Listenable] (such as `ChangeNotifier`), invoking
  /// [onChanged] while this component is mounted and auto-detaching in
  /// [onRemove].
  void listenToListenable(
    Listenable source,
    VoidCallback onChanged, {
    bool fireImmediately = false,
    bool coalescePerFrame = false,
    bool notifyGameActivity = true,
  }) {
    final binding = _ListenableBinding(
      source: source,
      deliver: onChanged,
      fireImmediately: fireImmediately,
      coalescePerFrame: coalescePerFrame,
      notifyGameActivity: notifyGameActivity,
    );
    _bindings.add(binding);
    if (isMounted) {
      binding.attach(this);
    }
  }

  void _enqueueCoalesced(_ListenableBinding binding) {
    _coalescedPending.add(binding);
    if (!_postFrameScheduled) {
      final scheduler = SchedulerBinding.instance;
      _postFrameScheduled = true;
      scheduler.addPostFrameCallback((_) {
        _postFrameScheduled = false;
        if (isMounted) {
          flushCoalescedSubscriptions();
        }
      });
    }
  }

  /// Immediately delivers any coalesced notifications queued since the last
  /// flush. Also invoked automatically during [update] and post-frame.
  void flushCoalescedSubscriptions() {
    if (_coalescedPending.isEmpty) {
      return;
    }
    final count = _coalescedPending.length;
    for (var i = 0; i < count; i++) {
      _coalescedPending[i].flushIfDirty();
    }
    _coalescedPending.removeRange(0, count);
  }

  /// Detaches and removes all registered subscriptions permanently.
  void clearSubscriptions() {
    for (var i = 0; i < _bindings.length; i++) {
      _bindings[i].detach();
    }
    _bindings.clear();
    _coalescedPending.clear();
  }

  @mustCallSuper
  @override
  void onMount() {
    super.onMount();
    for (var i = 0; i < _bindings.length; i++) {
      _bindings[i].attach(this);
    }
  }

  @mustCallSuper
  @override
  void update(double dt) {
    if (_coalescedPending.isNotEmpty) {
      flushCoalescedSubscriptions();
    }
    super.update(dt);
  }

  @mustCallSuper
  @override
  void onRemove() {
    for (var i = 0; i < _bindings.length; i++) {
      _bindings[i].detach();
    }
    _coalescedPending.clear();
    super.onRemove();
  }
}
