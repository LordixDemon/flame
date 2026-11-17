import 'package:flame/src/components/core/component.dart';
import 'package:flame/src/components/core/signal.dart';
import 'package:flame/src/components/core/world_event_bus.dart';

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
///
/// A subscription that is requested before the component mounts (from its
/// constructor or from `onLoad`) is attached on every mount. One that is
/// requested while the component is mounting or mounted (from `onMount` or
/// later) is attached at once and lasts until the component is removed.
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
  ///
  /// Without a [bus], a component that is not inside a `World` when the
  /// subscription is attached has no bus to listen to, and nothing is
  /// subscribed.
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

  WorldEventBus? _resolveEnclosingBus() =>
      enclosingWorld(includeSelf: true)?.eventBus;

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
