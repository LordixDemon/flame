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

  /// Whether the binding was registered while its owner was mounting (from
  /// `onMount`): such a binding lasts until the owner is removed and is
  /// registered anew by the next `onMount`.
  required final bool mountScoped,
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
/// listeners on [onMount] (or immediately if the component is mounted or in
/// the middle of mounting, so `listenTo` may be called from `onMount` as
/// well), detaches every listener deterministically in [onRemove] so
/// components can be mounted, removed, and re-mounted without leaking
/// callbacks, optionally coalesces rapid multiple mutations within a frame
/// into a single callback invocation, and wakes adaptive game loops via
/// `findGame()?.notifyActivity()`.
///
/// A subscription that is registered from the constructor, from `onLoad` or
/// while the component is mounted lives as long as the component: it is
/// re-attached on every mount. A subscription that is registered from
/// `onMount` lasts until the component is removed, and is registered again by
/// the next `onMount`.
mixin HasListenableSubscriptions on Component {
  final List<_ListenableBinding> _bindings = <_ListenableBinding>[];
  List<_ListenableBinding> _coalescedPending = <_ListenableBinding>[];
  List<_ListenableBinding> _coalescedFlushing = <_ListenableBinding>[];
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
  ///   (and automatically on the next frame boundary). Off by default: every
  ///   notification then invokes [onChanged] synchronously.
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
      mountScoped: isMounting,
    );
    _bindings.add(binding);
    // `isMounting` covers a registration made from `onMount`: the mounted
    // state is only set after `onMount` has returned.
    if (isMounted || isMounting) {
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
      mountScoped: isMounting,
    );
    _bindings.add(binding);
    // `isMounting` covers a registration made from `onMount`: the mounted
    // state is only set after `onMount` has returned.
    if (isMounted || isMounting) {
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
    // The batch is swapped out before it is delivered: a callback may notify
    // again (queued for the next flush), clear the subscriptions or get this
    // component removed without disturbing the loop.
    final batch = _coalescedPending;
    _coalescedPending = _coalescedFlushing;
    _coalescedFlushing = batch;
    for (var i = 0; i < batch.length; i++) {
      batch[i].flushIfDirty();
    }
    batch.clear();
  }

  /// Detaches and removes all registered subscriptions permanently.
  void clearSubscriptions() {
    for (var i = 0; i < _bindings.length; i++) {
      _bindings[i].detach();
    }
    _bindings.clear();
    _coalescedPending.clear();
    _coalescedFlushing.clear();
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
    var kept = 0;
    for (var i = 0; i < _bindings.length; i++) {
      final binding = _bindings[i]..detach();
      if (!binding.mountScoped) {
        _bindings[kept++] = binding;
      }
    }
    _bindings.length = kept;
    _coalescedPending.clear();
    super.onRemove();
  }
}
