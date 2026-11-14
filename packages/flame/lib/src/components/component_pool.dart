import 'dart:math' as math;

import 'package:flame/components.dart';

/// A zero-allocation pool for managing reusable [Component]s.
///
/// Components acquired via [acquire] are automatically returned to the pool in
/// `O(1)` time without allocating `Future` or `Completer` closures when they
/// finish detaching from their parent (or when cancelled before mounting).
/// Components mixing in [RecyclableComponent] also receive synchronous
/// [RecyclableComponent.onAcquire] and [RecyclableComponent.onRelease]
/// callbacks.
///
/// Example usage:
/// ```dart
/// final bulletPool = ComponentPool<MyBullet>(
///   factory: () => MyBullet(),
///   maxSize: 50,
///   initialSize: 10,
/// );
///
/// final bullet = bulletPool.acquire();
/// bullet.position = Vector2(10, 20);
/// game.add(bullet);
///
/// // Later, when the bullet should be recycled:
/// bullet.removeFromParent(); // Automatically returns to pool
/// ```
class ComponentPool<T extends Component>({
  required final T Function() _factory,

  /// The maximum number of idle components that can be stored in the pool. If
  /// the pool reaches this limit, additional released components are discarded.
  final int maxSize = 100,
  int initialSize = 0,
}) {
  final List<T> _available = [];
  int _inUseCount = 0;

  /// Creates a new component pool with the specified factory, maximum size, and
  /// initial size.
  this {
    if (initialSize > 0) {
      prewarm(initialSize);
    }
  }

  /// Number of idle components currently available in the pool.
  int get availableCount => _available.length;

  /// Number of components currently checked out via [acquire] that have not yet
  /// been returned to the pool.
  int get inUseCount => _inUseCount;

  /// Pre-allocates up to [count] additional idle components (capped so
  /// [availableCount] never exceeds [maxSize]).
  void prewarm(int count) {
    if (count <= 0 || _available.length >= maxSize) {
      return;
    }
    final targetAdd = math.min(count, maxSize - _available.length);
    for (var i = 0; i < targetAdd; i++) {
      final component = _factory()
        ..isInComponentPool = true
        ..poolReturnHook = _releaseFromTree;
      _available.add(component);
    }
  }

  /// Acquires a component from the pool (or constructs a new one via the
  /// factory when empty) with zero `Future` or closure allocations.
  ///
  /// Simply call [Component.removeFromParent] when done with the component (or
  /// [release] if it was never added to a parent).
  T acquire() {
    final T component;
    if (_available.isEmpty) {
      component = _factory();
    } else {
      component = _available.removeLast()..isInComponentPool = false;
    }
    component.poolReturnHook = _releaseFromTree;
    _inUseCount++;
    if (component is RecyclableComponent) {
      component.onAcquire();
    }
    return component;
  }

  /// Explicitly returns [component] to the pool.
  ///
  /// Useful when an acquired component is discarded before ever being added to
  /// a parent; if [component] currently belongs to a parent, this delegates to
  /// [Component.removeFromParent].
  void release(T component) {
    if (component.parent != null) {
      component.removeFromParent();
      return;
    }
    _releaseFromTree(component);
  }

  void _releaseFromTree(Component raw) {
    if (raw.isInComponentPool) {
      return;
    }
    final component = raw as T;
    if (_inUseCount > 0) {
      _inUseCount--;
    }
    if (component is RecyclableComponent) {
      component.onRelease();
    }
    if (_available.length < maxSize) {
      component.isInComponentPool = true;
      _available.add(component);
    }
  }

  /// Clears all idle components currently parked in the pool without affecting
  /// components that are currently in use.
  void clear() {
    for (final item in _available) {
      item.isInComponentPool = false;
    }
    _available.clear();
  }
}
