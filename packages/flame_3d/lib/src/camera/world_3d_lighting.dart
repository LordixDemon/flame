part of 'world_3d.dart';

class _WorldLightRegistry() {
  final List<Light> lights = [];
  // Increases when a light joins or leaves [lights].
  int lightListRevision = 0;

  // The changes of this world's own lights, which borrowing worlds add to
  // their versions.
  int lightsVersion = 0;
  int lightsCastersVersion = 0;

  World3D? lightsFrom;
  int borrowerCount = 0;

  final List<Light> _mergedLights = [];
  World3D? _mergedLender;
  int _mergedLenderRevision = -1;
  int _mergedOwnRevision = -1;

  final List<ReflectionProbeVolume3D> reflectionProbes = [];
  late final List<ReflectionProbeVolume3D> reflectionProbesView =
      UnmodifiableListView(reflectionProbes);

  List<Light> get passLights {
    final lender = lightsFrom;
    if (lender == null || lender._lighting.lights.isEmpty) {
      return lights;
    }
    if (lights.isEmpty) {
      return lender._lighting.lights;
    }
    final lenderReg = lender._lighting;
    if (!identical(_mergedLender, lender) ||
        _mergedLenderRevision != lenderReg.lightListRevision ||
        _mergedOwnRevision != lightListRevision) {
      _mergedLender = lender;
      _mergedLenderRevision = lenderReg.lightListRevision;
      _mergedOwnRevision = lightListRevision;
      _mergedLights
        ..clear()
        ..addAll(lenderReg.lights)
        ..addAll(lights);
    }
    return _mergedLights;
  }

  void addLight(Light light) {
    lights.add(light);
    lightListRevision++;
  }

  void removeLight(Light light) {
    lights.remove(light);
    lightListRevision++;
  }

  void markLightsDirty({required bool shadows}) {
    lightsVersion++;
    if (shadows) {
      lightsCastersVersion++;
    }
  }

  void addReflectionProbe(ReflectionProbeVolume3D probe) {
    reflectionProbes.add(probe);
  }

  void removeReflectionProbe(ReflectionProbeVolume3D probe) {
    reflectionProbes.remove(probe);
  }

  void gatherUnmountedLights(flame.Component node) {
    for (final child in node.children) {
      if (child is LightComponent) {
        // The light reads its position and direction from this matrix,
        // which a mounted light refreshes in its update.
        child.worldTransformMatrix;
        lights.add(child.light);
        lightListRevision++;
      }
      gatherUnmountedLights(child);
    }
  }

  void clearGatheredLights() {
    lights.clear();
    lightListRevision++;
  }
}

class _WorldVersionState() {
  int ownSceneVersion = 0;
  int ownCastersVersion = 0;
  int settingsOffset = 0;
  int animationTicks = 0;

  final MaterialTracker drawnMaterials = MaterialTracker();
  final ShadowCasterTracker shadowCasters = ShadowCasterTracker();
  final ComponentBounds sceneBounds = ComponentBounds();
  final Set<Component3D> unboundedComponents = Set.identity();

  void addToSceneBounds(Component3D child) {
    if (child.includeInSceneBounds) {
      sceneBounds.add(child);
    } else {
      unboundedComponents.add(child);
    }
  }

  void removeFromSceneBounds(Component3D child) {
    sceneBounds.remove(child);
    unboundedComponents.remove(child);
  }

  bool updateSceneBoundsMembership(Component3D child) {
    final wasBounded = sceneBounds.contains(child);
    if (!wasBounded && !unboundedComponents.remove(child)) {
      return false;
    }
    if (wasBounded) {
      sceneBounds.remove(child);
    }
    addToSceneBounds(child);
    return true;
  }
}

extension _World3DLighting on World3D {
  /// Replaces a setting by [assign], keeping [_valuesVersion] as it was:
  /// the setter marks the scene dirty.
  void _replaceSetting(void Function() assign) {
    final before = _settingsVersion;
    assign();
    _versions.settingsOffset += before - _settingsVersion;
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
}
