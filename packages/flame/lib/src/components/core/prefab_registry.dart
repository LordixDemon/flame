import 'package:flame/src/components/core/component.dart';

/// Reusable factory entry inside a [PrefabRegistry].
typedef PrefabFactory<T extends Component> = T Function(
  Map<String, Object?> params,
);

/// Declarative registry of reusable, parameterized [Component] prefabs.
class PrefabRegistry() {
  final Map<String, PrefabFactory<Component>> _factories =
      <String, PrefabFactory<Component>>{};
  final Map<String, Map<String, Object?>> _defaults =
      <String, Map<String, Object?>>{};

  /// Whether a prefab with [id] is registered.
  bool contains(String id) => _factories.containsKey(id);

  /// Registered prefab identifiers.
  Iterable<String> get ids => _factories.keys;

  /// Registers prefab [id] with [factory] and optional [defaultParams] merged
  /// beneath caller overrides on [instantiate].
  void register<T extends Component>(
    String id,
    PrefabFactory<T> factory, {
    Map<String, Object?> defaultParams = const <String, Object?>{},
  }) {
    _factories[id] = factory;
    _defaults[id] = Map<String, Object?>.unmodifiable(defaultParams);
  }

  /// Removes prefab [id] if registered.
  bool unregister(String id) {
    _defaults.remove(id);
    return _factories.remove(id) != null;
  }

  /// Instantiates prefab [id], merging [overrides] onto its `defaultParams`.
  T instantiate<T extends Component>(
    String id, [
    Map<String, Object?> overrides = const <String, Object?>{},
  ]) {
    final factory = _factories[id];
    if (factory == null) {
      throw StateError('Unknown prefab "$id"');
    }
    final defaults = _defaults[id]!;
    final merged = overrides.isEmpty
        ? defaults
        : (defaults.isEmpty
              ? overrides
              : <String, Object?>{...defaults, ...overrides});
    final created = factory(merged);
    if (created is! T) {
      throw StateError(
        'Prefab "$id" produced ${created.runtimeType}, expected $T',
      );
    }
    return created;
  }
}
