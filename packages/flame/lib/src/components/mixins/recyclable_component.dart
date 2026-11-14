import 'package:flame/src/components/component_pool.dart';
import 'package:flame/src/components/core/component.dart';

/// Optional lifecycle hooks invoked synchronously by [ComponentPool] when a
/// pooled component is acquired from or returned to its pool.
mixin RecyclableComponent on Component {
  /// Invoked synchronously inside [ComponentPool.acquire] before the component
  /// is returned to the caller.
  void onAcquire() {}

  /// Invoked synchronously when the component finishes detaching from the
  /// component tree (or when [ComponentPool.release] is called directly) and is
  /// returned to its [ComponentPool].
  void onRelease() {}
}
