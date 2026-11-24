import 'dart:collection' show UnmodifiableListView;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flame/components.dart' as flame;
import 'package:flame/game.dart' show Game;
import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/game.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/src/components/component_3d.dart'
    show ComponentBounds, ShadowCasterTracker;
import 'package:flame_3d/src/extensions/clip_space.dart';
import 'package:flame_3d/src/extensions/geometry_math.dart';
import 'package:flame_3d/src/graphics/embedded_renderer.dart';
import 'package:flame_3d/src/graphics/material_tracker.dart';
import 'package:meta/meta.dart';

part 'shadow_group.dart';
part 'world_3d_lighting.dart';
part 'world_3d_pipeline.dart';
part 'world_3d_queries.dart';

/// {@template world_3d}
/// The root component for all 3D world elements.
///
/// The primary feature of this component is that it allows [Component3D]s to
/// render directly to a [GraphicsDevice] instead of the regular rendering.
/// {@endtemplate}
class World3D({
  super.children,
  super.priority,
  double renderScale = 1.0,
  FogSettings? fog,
  WaterVolumeSettings? waterVolume,
  BloomSettings? bloom,
  PostProcessSettings? postProcess,
  LightProbeGrid3D? lightProbeGrid,
  bool hdrEnabled = false,
  OitMode3D oitMode = OitMode3D.none,
  bool grabSceneColorEnabled = false,
  RenderDebugMode3D renderDebugMode3D = RenderDebugMode3D.none,
  List<CustomRenderPass3D>? customPasses,
  var bool spatialIndex3DEnabled = false,
  bool prioritizeNearestLights = false,
  LightGridSettings? lightGrid,
  bool depthPrepassEnabled = false,
  SceneOcclusionCuller3D? occlusionCuller,
  List<DepthLayer3D>? depthLayers,
  StaticSceneCacheSettings? staticSceneCache,
}) extends flame.World {
  final _WorldLightRegistry _lighting = _WorldLightRegistry();
  final _WorldVersionState _versions = _WorldVersionState();
  final _WorldVisibilityCache _visibility = _WorldVisibilityCache();
  final _WorldShadowGroupState _shadowState = _WorldShadowGroupState();
  final _StaticSceneCacheState _staticCache = _StaticSceneCacheState();

  /// User-defined GPU [CustomRenderPass3D] hooks executed before or after the
  /// main scene pass.
  ///
  /// After changing the list or a pass, call [markSceneDirty] so retained
  /// layers render again.
  final List<CustomRenderPass3D> customPasses = customPasses != null
      ? List.of(customPasses)
      : [];

  /// Lazy flat AABB BVH accelerating AABB, frustum, and raycast queries when
  /// [spatialIndex3DEnabled] is `true` (or when queried directly).
  final SceneSpatialIndex3D spatialIndex3D = SceneSpatialIndex3D();

  int get _sceneVersion => componentsVersion + _valuesVersion;

  int get _valuesVersion =>
      _versions.settingsOffset +
      _settingsVersion +
      _versions.drawnMaterials.version +
      _versions.animationTicks +
      Material.assignmentRevision;

  int get _settingsVersion =>
      (_fog?.version ?? 0) +
      (_waterVolume?.version ?? 0) +
      (_bloom?.version ?? 0) +
      (_postProcess?.version ?? 0);

  int get _staticSettingsVersion =>
      (_fog?.version ?? 0) + (_waterVolume?.staticVersion ?? 0);

  /// Monotonically increasing version tracking everything that affects the
  /// cached static scene pass (`staticSceneCache`): geometry, transforms,
  /// lights, fog, static water-volume settings, and static materials.
  int get staticSceneVersion =>
      _versions.ownStaticVersion +
      _versions.staticSettingsOffset +
      _staticSettingsVersion +
      _versions.drawnMaterials.staticVersion +
      Material.castsShadowsRevision +
      Material.assignmentRevision +
      GpuBackend.renderEpoch +
      lightsVersion +
      (_lighting.lightsFrom?._lighting.lightsVersion ?? 0);

  /// The part of [sceneVersion] that follows the components of this world
  /// (and the lights and world settings it draws with), without the values
  /// that report their own changes (materials, fog, water, bloom and
  /// post-processing settings): what a spatial index of the components is
  /// built for.
  @internal
  int get componentsVersion =>
      _versions.ownSceneVersion +
      Material.castsShadowsRevision +
      GpuBackend.renderEpoch +
      (_lighting.lightsFrom?._lighting.lightsVersion ?? 0);

  int get _castersVersion =>
      _versions.ownCastersVersion +
      Material.castsShadowsRevision +
      GpuBackend.renderEpoch +
      (_lighting.lightsFrom?._lighting.lightsCastersVersion ?? 0);

  /// Monotonically increasing counter that increases whenever the rendered
  /// output of this world may change: `Scene3DCacheMode.retained` layers
  /// render again when it differs.
  int get sceneVersion => _sceneVersion;

  /// Monotonically increasing counter that increases whenever the shadow
  /// casters of this world may change, used by
  /// [ShadowSettings.cacheWhenStatic] to keep a static shadow map. Every
  /// change of [castersVersion] also changes [sceneVersion].
  int get castersVersion => _castersVersion;

  /// Marks this world's rendered output (and, unless [shadows] is `false`,
  /// its shadow casters) as changed: [sceneVersion] (and [castersVersion])
  /// increase, invalidating retained `Scene3DComponent` caches and a cached
  /// static shadow map, and idle-throttled game loops wake up.
  ///
  /// With [shadows], the kept layer of still casters
  /// ([ShadowSettings.cacheStillCasters]) is rendered again as well: report
  /// the change of one object with `Component3D.markDrawDirty` instead, so
  /// that only that object is drawn again.
  void markSceneDirty({bool shadows = true, bool staticCache = true}) {
    if (shadows) {
      _versions.shadowCasters.invalidate();
    }
    markComponentDirty(shadows: shadows, staticCache: staticCache);
  }

  /// Marks only the dynamic part of the scene dirty (waking retained caches
  /// without invalidating [staticSceneCache]).
  void markDynamicSceneDirty({bool shadows = false}) {
    markComponentDirty(shadows: shadows, staticCache: false);
  }

  /// Marks this world's rendered output (and, when [shadows], its shadow
  /// casters) as changed for a change a component reports itself, after
  /// telling [shadowCasters] which casters it reaches: like [markSceneDirty],
  /// without rendering the kept layer of still casters again.
  @internal
  void markComponentDirty({required bool shadows, bool staticCache = true}) {
    _versions.ownSceneVersion++;
    if (shadows) {
      _versions.ownCastersVersion++;
    }
    if (staticCache) {
      _versions.ownStaticVersion++;
    }
    Game.notifyVisualMutation();
  }

  /// The change tracking of this world's shadow casters, see
  /// [ShadowSettings.cacheStillCasters].
  @internal
  ShadowCasterTracker get shadowCasters => _versions.shadowCasters;

  int get _stillCastersVersion =>
      _versions.shadowCasters.version +
      Material.castsShadowsRevision +
      GpuBackend.renderEpoch +
      (_lighting.lightsFrom?._lighting.lightsCastersVersion ?? 0);

  int get _shadowKeyVersion => _versions.shadowCasters.alwaysMoving > 0
      ? -1 - _versions.shadowCasters.clock
      : _castersVersion;

  /// The settings of the first light of [lights] that casts shadows with
  /// [ShadowSettings.cacheStillCasters], or `null`.
  static ShadowSettings? _stillCasterSettings(List<Light> lights) {
    for (var i = 0; i < lights.length; i++) {
      final shadows = switch (lights[i].source) {
        final DirectionalLight light => light.shadows,
        final SpotLight light => light.shadows,
        final PointLight light => light.shadows,
        _ => null,
      };
      if (shadows != null && shadows.cacheStillCasters) {
        return shadows;
      }
    }
    return null;
  }

  Object? _prepareStillCasters(Object owner, List<Light> lights) {
    final settings = _stillCasterSettings(lights);
    if (settings == null) {
      return null;
    }
    _versions.shadowCasters.prepare(settings.stillCasterFrames);
    return _shadowCasterKey(owner, _stillCastersVersion, lights);
  }

  /// Marks this world's shadow casters as changed so a cached static shadow map
  /// ([ShadowSettings.cacheWhenStatic]) re-renders on the next pass.
  void markShadowsDirty() => markSceneDirty();

  /// Monotonically increasing counter that increases whenever a light of
  /// this world changes.
  int get lightsVersion => _lighting.lightsVersion;

  /// Marks the lights of this world as changed: [lightsVersion] and
  /// [sceneVersion] increase, and so does [castersVersion] unless [shadows]
  /// is `false`, here and in the worlds that borrow the lights.
  @internal
  void markLightsDirty({bool shadows = true}) {
    _lighting.markLightsDirty(shadows: shadows);
    markSceneDirty(shadows: shadows);
  }

  /// The world whose lights the passes of this world render with, before
  /// its own lights, or `null` (the default) for its own lights only.
  World3D? get lightsFrom => _lighting.lightsFrom;
  set lightsFrom(World3D? lender) {
    if (identical(lender, _lighting.lightsFrom)) {
      return;
    }
    if (lender != null) {
      if (identical(lender, this)) {
        throw ArgumentError.value(
          lender,
          'lightsFrom',
          'A world cannot borrow its own lights',
        );
      }
      if (lender._lighting.lightsFrom != null) {
        throw ArgumentError.value(
          lender,
          'lightsFrom',
          'This world borrows the lights of another world: borrow from that '
              'one',
        );
      }
      if (_lighting.borrowerCount > 0) {
        throw StateError(
          'A world that lends its lights to other worlds cannot borrow '
          'lights itself.',
        );
      }
    }
    final prevScene = _sceneVersion;
    final prevCasters = _castersVersion;
    _lighting.lightsFrom?._lighting.borrowerCount--;
    _lighting.lightsFrom = lender;
    lender?._lighting.borrowerCount++;
    _versions.ownSceneVersion += prevScene + 1 - _sceneVersion;
    _versions.ownCastersVersion += prevCasters + 1 - _castersVersion;
    Game.notifyVisualMutation();
  }

  /// The lights the passes of this world render with: those of [lightsFrom]
  /// (see there), followed by the lights of this world.
  List<Light> get lights => UnmodifiableListView(_passLights);

  List<Light> get _passLights => _lighting.passLights;

  /// Whether the half-resolution clip-depth + view-normal prepass renders
  /// every frame (soft particles, shoreline foam), see [renderDepthNormals].
  bool get depthPrepassEnabled => _depthPrepassEnabled;
  set depthPrepassEnabled(bool value) {
    if (value == _depthPrepassEnabled) {
      return;
    }
    _depthPrepassEnabled = value;
    markSceneDirty(shadows: false);
  }

  bool _depthPrepassEnabled = depthPrepassEnabled;

  /// Whether the lights nearest to the camera are chosen when the scene has
  /// more lights of a kind than a pass shades.
  bool get prioritizeNearestLights => _prioritizeNearestLights;
  set prioritizeNearestLights(bool value) {
    if (value == _prioritizeNearestLights) {
      return;
    }
    _prioritizeNearestLights = value;
    markSceneDirty();
  }

  bool _prioritizeNearestLights = prioritizeNearestLights;

  /// How the passes of this world shade more point and spot lights than the
  /// light blocks hold (8 point and 4 spot lights per pass), or `null`.
  LightGridSettings? get lightGrid => _lightGrid;
  set lightGrid(LightGridSettings? value) {
    if (value == _lightGrid) {
      return;
    }
    _lightGrid = value;
    markSceneDirty(shadows: false);
  }

  LightGridSettings? _lightGrid = lightGrid;

  /// Atmospheric distance/height fog applied to materials in this world (`null`
  /// disables fog).
  FogSettings? get fog => _fog;
  FogSettings? _fog = fog;
  set fog(FogSettings? value) {
    if (identical(value, _fog)) {
      return;
    }
    _replaceSetting(() => _fog = value);
    markSceneDirty(shadows: false);
  }

  /// The body of water of this world (`null`, the default, for none).
  WaterVolumeSettings? get waterVolume => _waterVolume;
  WaterVolumeSettings? _waterVolume = waterVolume;
  set waterVolume(WaterVolumeSettings? value) {
    if (identical(value, _waterVolume)) {
      return;
    }
    _replaceSetting(() => _waterVolume = value);
    markSceneDirty(shadows: false);
  }

  /// Optional GPU bloom post-processing applied to this world's rendered pass
  /// (`null` disables bloom).
  BloomSettings? get bloom => _bloom;
  BloomSettings? _bloom = bloom;
  set bloom(BloomSettings? value) {
    if (identical(value, _bloom)) {
      return;
    }
    _replaceSetting(() => _bloom = value);
    markSceneDirty(shadows: false);
  }

  /// Optional GPU tone-mapping, color-grading, 3D LUT, vignette, and FXAA
  /// settings fused into the final composite pass.
  PostProcessSettings? get postProcess => _postProcess;
  PostProcessSettings? _postProcess = postProcess;
  set postProcess(PostProcessSettings? value) {
    if (identical(value, _postProcess)) {
      return;
    }
    _replaceSetting(() => _postProcess = value);
    markSceneDirty(shadows: false);
  }

  /// Optional volumetric 3D `SH9` diffuse irradiance probe grid providing
  /// spatially varying indirect illumination across this world.
  LightProbeGrid3D? get lightProbeGrid => _lightProbeGrid;
  LightProbeGrid3D? _lightProbeGrid = lightProbeGrid;
  set lightProbeGrid(LightProbeGrid3D? value) {
    if (identical(value, _lightProbeGrid)) {
      return;
    }
    _lightProbeGrid = value;
    markSceneDirty(shadows: false);
  }

  /// Whether the main scene pass renders into a 16-bit floating-point
  /// (`rgbaFloat16`) target that keeps colors above 1.
  bool get hdrEnabled => _hdrEnabled;
  bool _hdrEnabled = hdrEnabled;
  set hdrEnabled(bool value) {
    if (value == _hdrEnabled) {
      return;
    }
    _hdrEnabled = value;
    markSceneDirty(shadows: false);
  }

  /// Order-independent transparency mode (`OitMode3D.none` or
  /// `OitMode3D.weightedBlended`).
  OitMode3D get oitMode => _oitMode;
  OitMode3D _oitMode = oitMode;
  set oitMode(OitMode3D value) {
    if (value == _oitMode) {
      return;
    }
    _oitMode = value;
    markSceneDirty(shadows: false);
  }

  /// Whether opaque geometry is captured into `sceneColorTexture` before
  /// translucent draws so refractive materials refract the scene behind them.
  bool get grabSceneColorEnabled => _grabSceneColorEnabled;
  bool _grabSceneColorEnabled = grabSceneColorEnabled;
  set grabSceneColorEnabled(bool value) {
    if (value == _grabSceneColorEnabled) {
      return;
    }
    _grabSceneColorEnabled = value;
    markSceneDirty(shadows: false);
  }

  /// Diagnostic buffer visualization mode.
  RenderDebugMode3D get renderDebugMode3D => _renderDebugMode3D;
  RenderDebugMode3D _renderDebugMode3D = renderDebugMode3D;
  set renderDebugMode3D(RenderDebugMode3D value) {
    if (value == _renderDebugMode3D) {
      return;
    }
    _renderDebugMode3D = value;
    markSceneDirty(shadows: false);
  }

  /// Optional [SceneOcclusionCuller3D] rasterized once per unique main
  /// camera view-projection before traversal to cull occluded [Object3D]s.
  SceneOcclusionCuller3D? get occlusionCuller => _occlusionCuller;
  SceneOcclusionCuller3D? _occlusionCuller = occlusionCuller;
  set occlusionCuller(SceneOcclusionCuller3D? value) {
    if (identical(value, _occlusionCuller)) {
      return;
    }
    _occlusionCuller = value;
    _visibility.invalidateOcclusion();
    markSceneDirty(shadows: false);
  }

  /// Optional depth layers rendered inside a single color pass by switching
  /// the viewport `[DepthLayer3D.zNear, DepthLayer3D.zFar]` range and optional
  /// `waterVolume` between layer batches.
  ///
  /// When `null` or empty (the default), all draws share `[0.0, 1.0]`.
  List<DepthLayer3D>? get depthLayers => _depthLayers;
  List<DepthLayer3D>? _depthLayers = _normalizeDepthLayers(depthLayers);
  set depthLayers(List<DepthLayer3D>? value) {
    final normalized = _normalizeDepthLayers(value);
    if (_depthLayersEqual(_depthLayers, normalized)) {
      return;
    }
    _depthLayers = normalized;
    markSceneDirty(shadows: false);
  }

  static List<DepthLayer3D>? _normalizeDepthLayers(List<DepthLayer3D>? layers) {
    if (layers == null || layers.isEmpty) {
      return layers == null ? null : const <DepthLayer3D>[];
    }
    final sorted = List<DepthLayer3D>.of(layers)
      ..sort((a, b) => a.index.compareTo(b.index));
    assert(() {
      for (var i = 1; i < sorted.length; i++) {
        if (sorted[i].index == sorted[i - 1].index) {
          throw ArgumentError.value(
            layers,
            'depthLayers',
            'Duplicate DepthLayer3D index ${sorted[i].index}',
          );
        }
      }
      return true;
    }());
    return UnmodifiableListView(sorted);
  }

  static bool _depthLayersEqual(
    List<DepthLayer3D>? a,
    List<DepthLayer3D>? b,
  ) {
    if (identical(a, b)) {
      return true;
    }
    if (a == null || b == null || a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }

  /// Optional static scene cache configuration (`null`, the default, disables
  /// static scene caching).
  StaticSceneCacheSettings? get staticSceneCache => _staticSceneCache;
  StaticSceneCacheSettings? _staticSceneCache = staticSceneCache;
  set staticSceneCache(StaticSceneCacheSettings? value) {
    if (identical(value, _staticSceneCache)) {
      return;
    }
    _staticSceneCache = value;
    _staticCache.invalidate();
    markSceneDirty(shadows: false);
  }

  /// Diagnostic string describing why the last frame missed or invalidated
  /// `staticSceneCache` (null when the last rendered frame hit).
  String? get staticSceneCacheMissReason => _staticCache.lastMissReason;

  /// Rasterizes registered occluders of [occlusionCuller] once per unique
  /// main-camera view-projection and frame before traversal.
  @internal
  void prepareOcclusionCuller(RenderContext3D ctx) =>
      _visibility.prepareOcclusionCuller(_occlusionCuller, ctx);

  /// Mounted local box-projected `ReflectionProbeVolume3D` components.
  List<ReflectionProbeVolume3D> get reflectionProbes =>
      _lighting.reflectionProbesView;

  /// The [Scene3DHost] this world renders with.
  Scene3DHost get host => _host ??= _findHost();
  Scene3DHost? _host;

  /// The render context that records the draws of this world.
  RenderContext3D get context => host.context;

  /// Whether this world is being rendered.
  bool get isRendering => _rendering;
  bool _rendering = false;

  /// Whether [World3D] is actively traversing its component tree via
  /// [renderScene] or [renderFromCamera].
  @internal
  bool get isTraversingTree => _traversingTree;
  bool _traversingTree = false;

  bool _allRootChildrenComponent3D() =>
      _visibility.allRootChildrenComponent3D(this);

  /// Lazily creates a fallback offscreen [Canvas] only if a non-[Component3D]
  /// or `debugMode` component is encountered during no-canvas rendering.
  @internal
  Canvas fallbackDummyCanvas() => _visibility.fallbackDummyCanvas();

  /// Disposes any lazily allocated fallback [PictureRecorder].
  @internal
  void disposeFallbackDummyCanvas() => _visibility.disposeFallbackDummyCanvas();

  @override
  void onMount() {
    _visibility.onMount();
    super.onMount();
  }

  @override
  void rebalanceChildren() {
    _visibility.onRebalance();
    super.rebalanceChildren();
  }

  /// The fraction of the device pixels the world is rendered at.
  double get renderScale => _renderScale;
  double _renderScale = _checkRenderScale(renderScale);
  set renderScale(double value) {
    final checked = _checkRenderScale(value);
    if (checked == _renderScale) {
      return;
    }
    _renderScale = checked;
    markSceneDirty(shadows: false);
  }

  /// The filter used to scale the rendered image to the viewport when
  /// [renderScale] is not `1`.
  FilterQuality scaledFilterQuality = FilterQuality.low;

  /// The union of the world-space bounds ([Component3D.aabb]) of the
  /// [Component3D]s of this world, or `null` when there are none.
  Aabb3? get sceneBounds => _versions.sceneBounds.value;

  /// Whether this world holds a component left out of [sceneBounds] (see
  /// [Component3D.includeInSceneBounds]), which may draw outside them.
  bool get hasUnboundedComponents => _versions.unboundedComponents.isNotEmpty;

  @override
  void onChildrenChanged(flame.Component child, flame.ChildrenChangeType type) {
    super.onChildrenChanged(child, type);
    switch (type) {
      case flame.ChildrenChangeType.added:
        _visibility.onChildAdded(child);
      case flame.ChildrenChangeType.removed:
        _visibility.onChildRemoved(child);
    }
    final isVolumeOrLight =
        child is LightComponent || child is ReflectionProbeVolume3D;
    final affectsStatic =
        !isVolumeOrLight &&
        !(child is Component3D && !child.affectsStaticSceneCache);
    markComponentDirty(shadows: !isVolumeOrLight, staticCache: affectsStatic);
    if (child is! Component3D || isVolumeOrLight) {
      return;
    }
    switch (type) {
      case flame.ChildrenChangeType.added:
        _versions.addToSceneBounds(child);
      case flame.ChildrenChangeType.removed:
        _versions.removeFromSceneBounds(child);
    }
  }

  /// Moves [child] in or out of [sceneBounds] after its
  /// [Component3D.includeInSceneBounds] changed.
  @internal
  void updateSceneBoundsMembership(Component3D child) {
    if (_versions.updateSceneBoundsMembership(child)) {
      markSceneDirty();
    }
  }

  /// Register a [light] with this world.
  @internal
  void addLight(Light light) {
    _lighting.addLight(light);
    markLightsDirty();
  }

  /// Unregister a [light] from this world.
  @internal
  void removeLight(Light light) {
    _lighting.removeLight(light);
    markLightsDirty();
  }

  /// Register a local [ReflectionProbeVolume3D] with this world.
  @internal
  void addReflectionProbe(ReflectionProbeVolume3D probe) {
    _lighting.addReflectionProbe(probe);
    markSceneDirty(shadows: false);
  }

  /// Unregister a local [ReflectionProbeVolume3D] from this world.
  @internal
  void removeReflectionProbe(ReflectionProbeVolume3D probe) {
    _lighting.removeReflectionProbe(probe);
    markSceneDirty(shadows: false);
  }

  @override
  void onRemove() {
    super.onRemove();
    _host = null;
    _cachedGame = null;
    _visibility.clearOnRemove();
    _staticCache.dispose();
  }

  Game? _cachedGame;
  final _SnapshotHost _snapshotHost = _SnapshotHost();

  /// Records [object] as visible during the current traversal when the world
  /// is collecting visible objects for reuse in the main scene pass.
  @internal
  void recordVisibleObject(Object3D object) =>
      _visibility.recordVisibleObject(object);

  @override
  void update(double dt) {
    super.update(dt);
    // A material marked animated changes on every frame: so does the scene
    // while the last render drew one.
    if (_versions.drawnMaterials.animatedCount > 0) {
      _versions.animationTicks++;
      Game.notifyVisualMutation();
    }
  }

  RenderContext3D? get _contextOrNull {
    if (!isMounted) {
      return null;
    }
    var host = _host;
    if (host == null) {
      for (final ancestor in ancestors()) {
        if (ancestor case final Scene3DHost found) {
          host = _host = found;
          break;
        }
      }
    }
    return host?.context;
  }

  /// The projection of the shadow map of this world.
  DirectionalShadowProjection get shadowProjection => _shadowState.projection;

  /// The group of worlds this world shares its shadow map with, or `null`.
  ShadowGroup? get shadowGroup => _shadowState.group;
  set shadowGroup(ShadowGroup? group) {
    if (identical(group, _shadowState.group)) {
      return;
    }
    _shadowState.group?._leave(this);
    _shadowState
      ..group = group
      ..groupRound = -1;
    group?._worlds.add(this);
    markSceneDirty();
  }

  /// Renders (or reuses) the shadow map / unified `ShadowAtlas3D` of this
  /// world, returning whether the upcoming main pass receives shadows.
  bool renderShadows(Canvas canvas, {RenderContext3D? overrideContext}) {
    try {
      return _renderShadows(canvas, overrideContext);
    } finally {
      _versions.shadowCasters.advance();
    }
  }

  /// Internal no-[Canvas] variant of [renderShadows].
  @internal
  bool renderShadowsNoCanvas({RenderContext3D? overrideContext}) {
    try {
      return _renderShadows(null, overrideContext);
    } finally {
      _versions.shadowCasters.advance();
    }
  }

  /// Record the depth and view-space normal buffer for this frame.
  bool renderDepthNormals(
    Canvas canvas,
    int width,
    int height, {
    RenderContext3D? overrideContext,
  }) => _renderDepthNormalsImpl(
    canvas,
    width,
    height,
    overrideContext: overrideContext,
  );

  static Object _shadowCasterKey(
    Object owner,
    int castersVersion,
    List<Light> lights,
  ) {
    for (var i = 0; i < lights.length; i++) {
      final source = lights[i].source;
      if (source is DirectionalLight && source.shadows != null) {
        final s = source.shadows!;
        final d = lights[i].direction(_keyDir);
        return Object.hash(
          owner,
          castersVersion,
          i,
          d.x,
          d.y,
          d.z,
          s.resolution,
          s.fit,
          s.maxDistance,
          s.stabilize,
          s.cascades,
        );
      }
    }
    return Object.hash(owner, castersVersion);
  }

  static final Vector3 _keyDir = Vector3.zero();

  static bool _passesCameraMaskHierarchy(Component3D node, int passMask) {
    flame.Component? cur = node;
    while (cur != null) {
      if (cur is Component3D) {
        if ((cur.cameraMask & passMask) == 0) {
          return false;
        }
      } else if (cur is World3D) {
        return true;
      }
      cur = cur.parent;
    }
    return true;
  }

  bool? _pipelineHdrOverride;

  /// Effective HDR setting of this world's scene render target when rendering
  /// with [device].
  @internal
  bool effectiveHdrEnabled(GraphicsDevice device) =>
      _hdrEnabled && needsPostCompositePass(device);

  /// Syncs world lighting, HDR, debug mode, `LightProbeGrid3D`, and
  /// `ReflectionProbeVolume3D` state onto [ctx].
  @internal
  void syncContextOptions(RenderContext3D ctx, {bool? hdrEnabled}) {
    final lights = _passLights;
    final resolvedHdr = hdrEnabled ?? _pipelineHdrOverride ?? false;
    final bounds = _lightGrid == null || hasUnboundedComponents
        ? null
        : sceneBounds;
    if (!ctx.needsSyncOptions(
      lights: lights,
      lightsVersion: lightsVersion,
      fog: _fog,
      waterVolume: _waterVolume,
      renderDebugMode: _renderDebugMode3D,
      lightProbeGrid: _lightProbeGrid,
      reflectionProbes: _lighting.reflectionProbes,
      prioritizeNearestLights: _prioritizeNearestLights,
      lightGrid: _lightGrid,
      lightGridBounds: bounds,
      hdrEnabled: resolvedHdr,
      depthLayers: _depthLayers,
      owner: this,
    )) {
      return;
    }
    ctx
      ..setWorldLights(lights, lightsVersion)
      ..fog = _fog
      ..waterVolume = _waterVolume
      ..hdrEnabled = resolvedHdr
      ..renderDebugMode = _renderDebugMode3D
      ..lightProbeGrid = _lightProbeGrid
      ..reflectionProbes = _lighting.reflectionProbes
      ..prioritizeNearestLights = _prioritizeNearestLights
      ..lightGrid = _lightGrid
      ..lightGridBounds = bounds
      ..depthLayers = _depthLayers
      ..bumpPassUniforms();
  }

  /// Records the draws of every component of this world into [context].
  void renderScene(Canvas canvas, {RenderContext3D? overrideContext}) =>
      _renderSceneImpl(canvas, overrideContext: overrideContext);

  /// Internal no-[Canvas] variant of [renderScene].
  @internal
  void renderSceneNoCanvas({RenderContext3D? overrideContext}) =>
      _renderSceneImpl(null, overrideContext: overrideContext);

  /// Whether this world requires rendering into an intermediate texture target
  /// followed by `BloomPass` / post-process / HDR / debug composition.
  @internal
  bool needsPostCompositePass(GraphicsDevice device) {
    if (!device.backend.supportsTextureTargets) {
      return false;
    }
    final bloomSettings = _bloom;
    final postSettings = _postProcess;
    final hasBloom =
        bloomSettings != null &&
        bloomSettings.intensity > 0 &&
        bloomSettings.radius > 0;
    final hasPost = postSettings != null && postSettings.isActive;
    final hasDebugPost =
        _renderDebugMode3D == RenderDebugMode3D.depth ||
        _renderDebugMode3D == RenderDebugMode3D.ssao;
    final hasAfterCustom = customPasses.any(
      (p) => p.enabled && p.stage == CustomRenderPassStage3D.afterScene,
    );
    return _hdrEnabled || hasBloom || hasPost || hasDebugPost || hasAfterCustom;
  }

  /// Executes the complete 3D scene pass pipeline.
  @internal
  Image executeWorldRenderPipeline({
    required GraphicsDevice device,
    required RenderContext3D renderContext,
    required int width,
    required int height,
    required int msaaSampleCount,
    required Color clearValue,
    required void Function() recordDraws,
    GpuRenderTarget? ownedOutputTarget,
    Rect? visibleFrame,
  }) {
    final tracker = _versions.drawnMaterials..begin();
    final previous = renderContext.materialTracker;
    renderContext.materialTracker = tracker;
    var completed = false;
    try {
      final image = _executeWorldRenderPipeline(
        device: device,
        renderContext: renderContext,
        width: width,
        height: height,
        msaaSampleCount: msaaSampleCount,
        clearValue: clearValue,
        recordDraws: recordDraws,
        ownedOutputTarget: ownedOutputTarget,
        visibleFrame: visibleFrame,
      );
      completed = true;
      return image;
    } finally {
      renderContext.materialTracker = previous;
      tracker.end(device.stats, completed: completed);
    }
  }

  /// Renders this world once at [size] physical pixels from [view] and
  /// [projection] into an independent [Image], which the caller disposes.
  Image renderToImage(
    Size size, {
    required Matrix4 view,
    required Matrix4 projection,
    Msaa msaa = Msaa.off,
    Color clearValue = const Color(0x00000000),
    GraphicsDevice? device,
    RenderContext3D? context,
  }) => renderToImageInto(
    size,
    view: view,
    projection: projection,
    msaa: msaa,
    clearValue: clearValue,
    device: device,
    context: context,
  );

  /// Render this world into an off-screen [Image] using an isolated host.
  @internal
  Image renderToImageInto(
    Size size, {
    required Matrix4 view,
    required Matrix4 projection,
    Msaa msaa = Msaa.off,
    Color clearValue = const Color(0x00000000),
    GraphicsDevice? device,
    RenderContext3D? context,
    GpuRenderTarget? target,
  }) => _renderToImageIntoImpl(
    size,
    view: view,
    projection: projection,
    msaa: msaa,
    clearValue: clearValue,
    device: device,
    context: context,
    target: target,
  );

  /// Render this world directly into [target], optionally preserving contents.
  @internal
  void renderChainedIntoTextureTarget({
    required Size size,
    required Matrix4 view,
    required Matrix4 projection,
    required GraphicsDevice device,
    required RenderContext3D context,
    required GpuTextureTarget target,
    required bool keepContents,
    Msaa msaa = Msaa.off,
  }) => _renderChainedIntoTextureTargetImpl(
    size: size,
    view: view,
    projection: projection,
    device: device,
    context: context,
    target: target,
    keepContents: keepContents,
    msaa: msaa,
  );

  /// Runs [body] with [device] and [context] as this world's host.
  @internal
  T renderWithHost<T>(
    GraphicsDevice device,
    RenderContext3D context,
    T Function() body, {
    Msaa msaa = Msaa.off,
  }) {
    final previousHost = _host;
    final snap = _snapshotHost;
    final prevDevice = snap._device;
    final prevContext = snap._context;
    final prevMsaa = snap.msaa;
    snap
      .._device = device
      .._context = context
      ..msaa = msaa;
    _host = snap;
    final gatherLights = !isMounted && _lighting.lights.isEmpty;
    if (gatherLights) {
      _lighting.gatherUnmountedLights(this);
    }
    final lender = _lighting.lightsFrom;
    final gatherLenderLights =
        lender != null && !lender.isMounted && lender._lighting.lights.isEmpty;
    if (gatherLenderLights) {
      lender._lighting.gatherUnmountedLights(lender);
    }
    try {
      return body();
    } finally {
      _host = previousHost;
      snap
        .._device = prevDevice
        .._context = prevContext
        ..msaa = prevMsaa;
      if (gatherLights) {
        _lighting.clearGatheredLights();
      }
      if (gatherLenderLights) {
        lender._lighting.clearGatheredLights();
      }
    }
  }

  /// Cast [ray] into this world and return the closest hit, or `null`.
  RayHit3D? raycast(
    Ray ray, {
    double maxDistance = double.infinity,
    CullMode? cullMode,
    bool Function(Object3D object)? filter,
    int cameraMask = 0xFFFFFFFF,
    bool includeHidden = false,
  }) => _raycastImpl(
    ray,
    maxDistance: maxDistance,
    cullMode: cullMode,
    filter: filter,
    cameraMask: cameraMask,
    includeHidden: includeHidden,
  );

  /// Cast [ray] into this world and return all hits sorted by distance.
  List<RayHit3D> raycastAll(
    Ray ray, {
    double maxDistance = double.infinity,
    CullMode? cullMode,
    bool Function(Object3D object)? filter,
    int cameraMask = 0xFFFFFFFF,
    bool includeHidden = false,
  }) => _raycastAllImpl(
    ray,
    maxDistance: maxDistance,
    cullMode: cullMode,
    filter: filter,
    cameraMask: cameraMask,
    includeHidden: includeHidden,
  );

  /// Whether a render pass with [cameraMask] draws [component] itself.
  static bool _drawnFor(Component3D component, int cameraMask) =>
      component.visible && (component.cameraMask & cameraMask) != 0;

  static final Ray _unitRay = Ray();

  /// Render this world from its active camera onto [canvas].
  @internal
  @override
  void renderFromCamera(Canvas canvas) {
    final camera = CameraComponent3D.currentCamera!;
    final Viewport(virtualSize: size) = camera.viewport;

    final host = this.host;
    final scale = host.pixelRatio * _renderScale;
    final renderSize = Size(size.x * scale, size.y * scale);

    final device = host.device;
    final context = host.context
      ..cameraMask = camera.cameraMask
      ..setCamera(camera.viewMatrix, camera.projectionMatrix);
    syncContextOptions(context, hdrEnabled: effectiveHdrEnabled(device));
    renderShadows(canvas);
    final wPx = math.max(1, renderSize.width.round());
    final hPx = math.max(1, renderSize.height.round());
    renderDepthNormals(canvas, wPx, hPx);

    final image = executeWorldRenderPipeline(
      device: device,
      renderContext: context,
      width: wPx,
      height: hPx,
      msaaSampleCount: host.msaaSampleCount,
      clearValue: device.clearValue,
      recordDraws: () {
        if (runtimeType == World3D &&
            !debugMode &&
            !spatialIndexEnabled &&
            decorator.isLastDecorator) {
          _renderSceneImpl(canvas, overrideContext: context);
        } else {
          _visibility.hasVisibleCache = false;
          _rendering = true;
          _traversingTree = _allRootChildrenComponent3D();
          try {
            super.renderFromCamera(canvas);
          } finally {
            _traversingTree = false;
            _rendering = false;
          }
        }
      },
    );

    _paint.filterQuality = _renderScale == 1.0
        ? FilterQuality.none
        : scaledFilterQuality;
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTWH(-size.x / 2, -size.y / 2, size.x, size.y),
      _paint,
    );
    image.dispose();
  }

  final Paint _paint = Paint();

  static double _checkRenderScale(double value) {
    if (!(value > 0) || value.isInfinite) {
      throw ArgumentError.value(value, 'renderScale', 'Must be above 0');
    }
    return value;
  }
}
