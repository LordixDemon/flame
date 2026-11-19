import 'dart:collection' show UnmodifiableMapView;
import 'dart:ui' show Color;

import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';

/// Typed override parameters applied when instantiating a [Prefab3D].
class PrefabOverrides3D({
  final Vector3? position,
  final Quaternion? rotation,
  final Vector3? scale,
  final Color? color,
  final bool? visible,
  final int? cameraMask,
  final Set<String>? tags,
  final bool replaceTags = false,
  Map<String, Object?> customProps = const {},
}) {
  /// Custom blueprint parameters forwarded to [Prefab3D.builder].
  final Map<String, Object?> customProps = UnmodifiableMapView(
    Map<String, Object?>.of(customProps),
  );

  /// Reads a typed custom property under [key], returning `null` when absent or
  /// of a different type.
  T? prop<T>(String key) {
    final value = customProps[key];
    return value is T ? value : null;
  }

  /// Merges [defaults] beneath [customProps].
  PrefabOverrides3D withDefaults(Map<String, Object?> defaults) {
    if (defaults.isEmpty) {
      return this;
    }
    return PrefabOverrides3D(
      position: position,
      rotation: rotation,
      scale: scale,
      color: color,
      visible: visible,
      cameraMask: cameraMask,
      tags: tags,
      replaceTags: replaceTags,
      customProps: {...defaults, ...customProps},
    );
  }
}

/// Reusable named 3D component blueprint supporting typed
/// [PrefabOverrides3D] at instantiation time.
class Prefab3D({
  required final String id,
  required final Component3D Function(PrefabOverrides3D overrides) builder,
  Map<String, Object?> defaultProps = const {},
}) {
  /// Creates a [Prefab3D] that deep-clones [prototype] on every [instantiate].
  factory Prefab3D.fromPrototype(
    String id,
    Component3D prototype, {
    Map<String, Object?> defaultProps = const {},
  }) {
    final template = prototype.clone();
    return Prefab3D(
      id: id,
      defaultProps: defaultProps,
      builder: (_) => template.clone(),
    );
  }

  /// Default custom properties merged beneath caller [PrefabOverrides3D].
  final Map<String, Object?> defaultProps = UnmodifiableMapView(
    Map<String, Object?>.of(defaultProps),
  );

  /// Builds a fresh [Component3D] instance from this blueprint and applies
  /// [overrides].
  Component3D instantiate([PrefabOverrides3D? overrides]) {
    final effective = (overrides ?? PrefabOverrides3D()).withDefaults(
      defaultProps,
    );
    final instance = builder(effective)..prefabId = id;

    if (effective.position case final pos?) {
      instance.position.setFrom(pos);
    }
    if (effective.rotation case final rot?) {
      instance.rotation.setFrom(rot);
    }
    if (effective.scale case final scl?) {
      instance.scale.setFrom(scl);
    }
    if (effective.visible case final vis?) {
      instance.visible = vis;
    }
    if (effective.cameraMask case final mask?) {
      instance.cameraMask = mask;
    }
    if (effective.color case final tint?) {
      switch (instance) {
        case final MeshComponent meshComp:
          meshComp.color = tint;
        case final LodMeshComponent lodComp:
          lodComp.color = tint;
        case _:
          break;
      }
    }
    if (effective.tags case final extraTags?) {
      if (effective.replaceTags) {
        instance.clearTags3D();
      }
      for (final tag in extraTags) {
        instance.addTag3D(tag);
      }
    }
    return instance;
  }
}

/// Named catalog of [Prefab3D] blueprints for runtime instantiation and
/// `SceneSerializer3D` prefab round-tripping.
class PrefabRegistry3D() {
  final Map<String, Prefab3D> _prefabs = {};

  /// Number of registered [Prefab3D]s.
  int get length => _prefabs.length;

  /// Whether no prefabs are registered.
  bool get isEmpty => _prefabs.isEmpty;

  /// Whether at least one prefab is registered.
  bool get isNotEmpty => _prefabs.isNotEmpty;

  /// Registered prefab IDs.
  Iterable<String> get ids => _prefabs.keys;

  /// Whether a prefab with [id] is registered.
  bool contains(String id) => _prefabs.containsKey(id);

  /// Looks up the [Prefab3D] registered under [id], or `null` if missing.
  Prefab3D? lookup(String id) => _prefabs[id];

  /// Registers [prefab] in this registry.
  ///
  /// Throws a [StateError] when [Prefab3D.id] is already registered unless
  /// [overwrite] is `true`.
  void register(Prefab3D prefab, {bool overwrite = false}) {
    if (!overwrite && _prefabs.containsKey(prefab.id)) {
      throw StateError('Prefab3D "${prefab.id}" is already registered.');
    }
    _prefabs[prefab.id] = prefab;
  }

  /// Convenience helper registering a builder function directly under [id].
  Prefab3D registerBuilder(
    String id,
    Component3D Function(PrefabOverrides3D overrides) builder, {
    Map<String, Object?> defaultProps = const {},
    bool overwrite = false,
  }) {
    final prefab = Prefab3D(
      id: id,
      builder: builder,
      defaultProps: defaultProps,
    );
    register(prefab, overwrite: overwrite);
    return prefab;
  }

  /// Convenience helper registering a prototype [Component3D] under [id].
  Prefab3D registerPrototype(
    String id,
    Component3D prototype, {
    Map<String, Object?> defaultProps = const {},
    bool overwrite = false,
  }) {
    final prefab = Prefab3D.fromPrototype(
      id,
      prototype,
      defaultProps: defaultProps,
    );
    register(prefab, overwrite: overwrite);
    return prefab;
  }

  /// Removes the prefab registered under [id], returning `true` if removed.
  bool unregister(String id) => _prefabs.remove(id) != null;

  /// Clears all registered prefabs.
  void clear() => _prefabs.clear();

  /// Instantiates the prefab registered under [id] with optional [overrides].
  ///
  /// Throws a [StateError] if [id] is not registered.
  Component3D instantiate(String id, [PrefabOverrides3D? overrides]) {
    final prefab = _prefabs[id];
    if (prefab == null) {
      throw StateError('Unknown Prefab3D "$id".');
    }
    return prefab.instantiate(overrides);
  }
}
