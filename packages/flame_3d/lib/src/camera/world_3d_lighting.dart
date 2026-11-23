part of 'world_3d.dart';

extension _World3DLighting on World3D {
  /// Replaces a setting by [assign], keeping [_valuesVersion] as it was:
  /// the setter marks the scene dirty.
  void _replaceSetting(void Function() assign) {
    final before = _settingsVersion;
    assign();
    _settingsOffset += before - _settingsVersion;
  }

  void _addToSceneBounds(Component3D child) {
    if (child.includeInSceneBounds) {
      _sceneBounds.add(child);
    } else {
      _unboundedComponents.add(child);
    }
  }

  Game? _resolveGame() {
    if (!isMounted) {
      _cachedGame = null;
      return findGame();
    }
    final cached = _cachedGame;
    if (cached != null) {
      return cached;
    }
    return _cachedGame = findGame();
  }

  Scene3DHost _findHost() {
    for (final ancestor in ancestors()) {
      if (ancestor case final Scene3DHost host) {
        return host;
      }
    }
    throw StateError(
      'A World3D needs a Scene3DHost ancestor: a Scene3DComponent, or a '
      'Game3D game such as FlameGame3D.',
    );
  }

  void _gatherLights(flame.Component node) {
    for (final child in node.children) {
      if (child is LightComponent) {
        // The light reads its position and direction from this matrix,
        // which a mounted light refreshes in its update.
        child.worldTransformMatrix;
        _lights.add(child.light);
        _lightListRevision++;
      }
      _gatherLights(child);
    }
  }
}
