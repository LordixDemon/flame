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
import 'package:flame_3d/src/embedding/embedded_renderer.dart';
import 'package:flame_3d/src/extensions/clip_space.dart';
import 'package:flame_3d/src/extensions/geometry_math.dart';
import 'package:flame_3d/src/graphics/material_tracker.dart';
import 'package:flame_3d/src/world_scale/occlusion_culler_3d.dart';
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
  OcclusionCuller3D? occlusionCuller,
}) extends flame.World {
  final List<Light> _lights = [];
  // Increases when a light joins or leaves [_lights], see [_passLights].
  int _lightListRevision = 0;
  final List<ReflectionProbeVolume3D> _reflectionProbes = [];

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

  int _ownSceneVersion = 0;
  int _ownCastersVersion = 0;

  // The changes of this world's own lights, which the worlds that borrow them
  // ([lightsFrom]) add to their versions.
  int _lightsVersion = 0;
  int _lightsCastersVersion = 0;

  // Material.castsShadows is shared by every world that draws the material,
  // so its changes are counted globally and added here, as are the changes of
  // the lights this world borrows and the losses and recoveries of the GPU
  // device (what was cached before is gone).
  int get _sceneVersion => componentsVersion + _valuesVersion;

  // The versions of the values this world draws with, which report their
  // own changes: its settings, and the materials of its last render (see
  // [MaterialTracker]), plus one per update while one of those is marked
  // `Material.animated`, and the materials given to surfaces (shared by
  // every world, as Material.castsShadows).
  int get _valuesVersion =>
      _settingsOffset +
      _settingsVersion +
      _drawnMaterials.version +
      _animationTicks +
      Material.assignmentRevision;

  int get _settingsVersion =>
      (_fog?.version ?? 0) +
      (_waterVolume?.version ?? 0) +
      (_bloom?.version ?? 0) +
      (_postProcess?.version ?? 0);

  // Keeps [_valuesVersion] from going back when a setting is replaced by one
  // of a lower version.
  int _settingsOffset = 0;
  int _animationTicks = 0;
  final MaterialTracker _drawnMaterials = MaterialTracker();

  /// The part of [sceneVersion] that follows the components of this world
  /// (and the lights and world settings it draws with), without the values
  /// that report their own changes (materials, fog, water, bloom and
  /// post-processing settings): what a spatial index of the components is
  /// built for.
  @internal
  int get componentsVersion =>
      _ownSceneVersion +
      Material.castsShadowsRevision +
      GpuBackend.renderEpoch +
      (_lightsFrom?._lightsVersion ?? 0);

  int get _castersVersion =>
      _ownCastersVersion +
      Material.castsShadowsRevision +
      GpuBackend.renderEpoch +
      (_lightsFrom?._lightsCastersVersion ?? 0);

  /// Monotonically increasing counter that increases whenever the rendered
  /// output of this world may change: `Scene3DCacheMode.retained` layers
  /// render again when it differs.
  ///
  /// It increases when a component is added, removed, moved, shown, hidden or
  /// gets another `cameraMask`; when a property of a component that changes
  /// its draws is assigned (`Object3D.castsShadows`, `MeshComponent.color`,
  /// `instanceData` and `jointTransforms`, the same on `ModelComponent` and
  /// `LodMeshComponent`, the instances of an `InstancedGroup3D`); when a
  /// field of a light source is assigned, a light is added or removed, or
  /// its `lightMask` changes; when an animation or active particles advance,
  /// or particles are spawned or cleared (`ParticleSystem3D.burst`, `spawn`,
  /// `clear`);
  /// when a `Material.castsShadows` changes; when a setting of this world is
  /// assigned ([fog], [waterVolume], [bloom], [postProcess], [hdrEnabled],
  /// [depthPrepassEnabled], ...); and when the lights it borrows change (see
  /// [lightsFrom] and [lightsVersion]).
  ///
  /// It also increases when a value this world draws with changes, as those
  /// values report their own changes ([Versioned]): a field of [fog], of
  /// [waterVolume], of [bloom] or of [postProcess], a field of one of the
  /// materials its last render drew (`Material.version`), of their palettes
  /// or of the state they read (`WaterRipples`, `WaterFoamSources`), and a
  /// `Surface` given another material. A material this world did not draw
  /// in its last render (one hidden, culled, or drawn in another world
  /// only) does not change it; neither does writing the value a field
  /// already holds. While the last render drew a material marked
  /// `Material.animated`, it increases on every update. None of these
  /// changes [castersVersion]: a material moves no shadow, besides its
  /// `Material.castsShadows` (and the `Material.renderState` it follows).
  ///
  /// The engine cannot see changes made in place: a field of a light's
  /// `ShadowSettings`, a vector of a light source, joint matrices written
  /// into an existing list, the buffers of a custom `Object3D.draw`,
  /// [customPasses], the contents of a texture rendered again, an object a
  /// material or a setting holds changed in place (an `Aabb3`, an
  /// `EnvironmentProbe3D`), and the [lightProbeGrid] changed in place. Report
  /// them with `Component3D.markDrawDirty`, `LightSource.markChanged`,
  /// `Material.markChanged` (or [Versioned.markChanged] of the setting) or
  /// [markSceneDirty].
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
  void markSceneDirty({bool shadows = true}) {
    if (shadows) {
      _shadowCasters.invalidate();
    }
    markComponentDirty(shadows: shadows);
  }

  /// Marks this world's rendered output (and, when [shadows], its shadow
  /// casters) as changed for a change a component reports itself, after
  /// telling [shadowCasters] which casters it reaches: like [markSceneDirty],
  /// without rendering the kept layer of still casters again.
  @internal
  void markComponentDirty({required bool shadows}) {
    _ownSceneVersion++;
    if (shadows) {
      _ownCastersVersion++;
    }
    Game.notifyVisualMutation();
  }

  /// The change tracking of this world's shadow casters, see
  /// [ShadowSettings.cacheStillCasters].
  @internal
  ShadowCasterTracker get shadowCasters => _shadowCasters;
  final ShadowCasterTracker _shadowCasters = ShadowCasterTracker();

  // The version of the still casters: that of [shadowCasters], and the
  // changes it does not see, as [_castersVersion] counts them.
  int get _stillCastersVersion =>
      _shadowCasters.version +
      Material.castsShadowsRevision +
      (_lightsFrom?._lightsCastersVersion ?? 0);

  // The version of the casters a cached shadow map is keyed with: while a
  // caster whose changes the engine cannot see is in the world (see
  // ShadowCasterMotion.moving), one that never repeats.
  int get _shadowKeyVersion => _shadowCasters.alwaysMoving > 0
      ? -1 - _shadowCasters.clock
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

  /// Prepares the still casters of this world for a render of the shadows
  /// whose lights are [lights], returning the key of the still casters, or
  /// `null` when no light keeps them.
  Object? _prepareStillCasters(Object owner, List<Light> lights) {
    final settings = _stillCasterSettings(lights);
    if (settings == null) {
      return null;
    }
    _shadowCasters.prepare(settings.stillCasterFrames);
    return _shadowCasterKey(owner, _stillCastersVersion, lights);
  }

  /// Marks this world's shadow casters as changed so a cached static shadow map
  /// ([ShadowSettings.cacheWhenStatic]) re-renders on the next pass.
  void markShadowsDirty() => markSceneDirty();

  /// Monotonically increasing counter that increases whenever a light of
  /// this world changes: a `LightComponent` is mounted or removed, moves
  /// (also when one of its ancestors moves), gets another `lightMask`, or a
  /// field of its source is assigned (or reported with
  /// `LightSource.markChanged`).
  ///
  /// The worlds that borrow this world's lights ([lightsFrom]) add it to
  /// their [sceneVersion], and add the part of it that can move shadows to
  /// their [castersVersion], so their retained layers and cached shadow maps
  /// follow the lights they borrow. Every change of [lightsVersion] also
  /// changes this world's [sceneVersion].
  int get lightsVersion => _lightsVersion;

  /// Marks the lights of this world as changed: [lightsVersion] and
  /// [sceneVersion] increase, and so does [castersVersion] unless [shadows]
  /// is `false`, here and in the worlds that borrow the lights.
  @internal
  void markLightsDirty({bool shadows = true}) {
    _lightsVersion++;
    if (shadows) {
      _lightsCastersVersion++;
    }
    markSceneDirty(shadows: shadows);
  }

  /// The world whose lights the passes of this world render with, before
  /// its own lights, or `null` (the default) for its own lights only.
  ///
  /// Layers that show one scene, such as the `Scene3DComponent`s of a
  /// `ShadowGroup`, can keep their lights in one world and let the others
  /// borrow them, instead of holding a copy of every light per layer:
  ///
  /// ```dart
  /// characters.world.lightsFrom = buildings.world;
  /// ```
  ///
  /// - The passes of this world use the lights of the lender, in the
  ///   lender's order, followed by the lights of this world. The positions
  ///   and directions of the lights are those in the lender's world space.
  /// - A borrowed light reaches a pass of this world when its `lightMask`
  ///   shares a bit with the pass's camera mask (the `cameraMask` of the
  ///   `Scene3DComponent`, or of the camera), as in its own world: give the
  ///   layers different `cameraMask` bits to keep a light out of some of
  ///   them.
  /// - Every change of a lent light (see [lightsVersion]) changes the
  ///   [sceneVersion] of this world, and of its [castersVersion] when it can
  ///   move shadows: its retained layers render again, its cached static
  ///   shadow maps follow, and a game whose `idleRenderMode` skips unchanged
  ///   frames wakes up. The other changes of the lender do not.
  /// - The lights are those the lender has registered, which a light does
  ///   when it is mounted. While the lender is not mounted (not added to a
  ///   game yet, or removed from it), this world renders with its own lights
  ///   only, and with the lender's again once it is mounted. The link stays
  ///   until [lightsFrom] is set to `null`.
  ///
  /// A world cannot borrow its own lights, nor those of a world that borrows
  /// lights itself, and a world that lends its lights cannot borrow: these
  /// throw. Assigning another lender increases [sceneVersion] and
  /// [castersVersion].
  World3D? get lightsFrom => _lightsFrom;
  set lightsFrom(World3D? lender) {
    if (identical(lender, _lightsFrom)) {
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
      if (lender._lightsFrom != null) {
        throw ArgumentError.value(
          lender,
          'lightsFrom',
          'This world borrows the lights of another world: borrow from that '
              'one',
        );
      }
      if (_borrowerCount > 0) {
        throw StateError(
          'A world that lends its lights to other worlds cannot borrow '
          'lights itself.',
        );
      }
    }
    final sceneVersion = _sceneVersion;
    final castersVersion = _castersVersion;
    _lightsFrom?._borrowerCount--;
    _lightsFrom = lender;
    lender?._borrowerCount++;
    // The versions keep increasing, whatever those of the old and the new
    // lender.
    _ownSceneVersion += sceneVersion + 1 - _sceneVersion;
    _ownCastersVersion += castersVersion + 1 - _castersVersion;
    Game.notifyVisualMutation();
  }

  World3D? _lightsFrom;
  // The number of worlds that borrow this world's lights.
  int _borrowerCount = 0;

  /// The lights the passes of this world render with: those of [lightsFrom]
  /// (see there), followed by the lights of this world.
  ///
  /// The list is a view that cannot be modified; it follows the lights as
  /// they are mounted and removed.
  List<Light> get lights => UnmodifiableListView(_passLights);

  /// The lights the passes of this world render with, see [lights].
  List<Light> get _passLights {
    final lender = _lightsFrom;
    if (lender == null || lender._lights.isEmpty) {
      return _lights;
    }
    if (_lights.isEmpty) {
      return lender._lights;
    }
    if (!identical(_mergedLender, lender) ||
        _mergedLenderRevision != lender._lightListRevision ||
        _mergedOwnRevision != _lightListRevision) {
      _mergedLender = lender;
      _mergedLenderRevision = lender._lightListRevision;
      _mergedOwnRevision = _lightListRevision;
      _mergedLights
        ..clear()
        ..addAll(lender._lights)
        ..addAll(_lights);
    }
    return _mergedLights;
  }

  // The borrowed lights followed by the own ones, rebuilt when a light joins
  // or leaves either list.
  final List<Light> _mergedLights = [];
  World3D? _mergedLender;
  int _mergedLenderRevision = -1;
  int _mergedOwnRevision = -1;

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
  /// light blocks hold (8 point and 4 spot lights per pass), or `null` (the
  /// default) to leave the lights beyond those out (see
  /// [prioritizeNearestLights] for which stay).
  ///
  /// With settings, the point (or spot) lights of a pass that has more of
  /// them than the block holds go into a grid of cells in world space, when
  /// they have a `range` and cast no shadows, and every material that reads
  /// the grid (`StylizedMaterial`, `SpatialMaterial`, `WaterMaterial`,
  /// `BillboardMaterial3D`, and custom shaders through
  /// `flame_3d/light_grid.glsl`) shades on each pixel the lights that reach
  /// its cell. See [LightGridSettings].
  ///
  /// Assigning other settings increases [sceneVersion].
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

  /// The body of water of this world: the surfaces of `StylizedMaterial`s
  /// below its level look submerged (tinted and darkened with their depth,
  /// with caustics), and foam where they cross it (`null`, the default, for
  /// none). See [WaterVolumeSettings].
  ///
  /// Assigning another object marks the scene changed, and so does changing
  /// the fields of the current one (its `time`, for instance), see
  /// [sceneVersion].
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
  /// (`rgbaFloat16`) target that keeps colors above 1, decoded to linear light
  /// for [bloom] and the tone mapping of [postProcess].
  ///
  /// Every material writes that target sRGB-encoded with an extended range:
  /// `SpatialMaterial` encodes its un-tonemapped radiance (instead of its
  /// built-in Reinhard curve), the other materials write their usual colors.
  /// Blending therefore happens in the same space as without HDR, and with
  /// [ToneMapMode.none] and an exposure of 1 those materials look exactly as
  /// without HDR. When [postProcess] is `null`, [ToneMapMode.acesFilmic] is
  /// applied.
  ///
  /// Backends without floating-point render targets (OpenGL ES) render into
  /// an 8-bit target instead: the picture is the same, but colors above 1
  /// clip before bloom and tone mapping. On the web the composite shaders
  /// have no WebGPU build: the first frame throws an [UnsupportedError], as
  /// with [bloom], [postProcess], [oitMode] and [depthPrepassEnabled].
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
  ///
  /// With `OitMode3D.weightedBlended`, alpha-blended translucent draws are
  /// drawn with their own materials into an accumulation and a revealage
  /// target and composited as a weighted average, whatever their order;
  /// other translucent draws are sorted. Backends without floating-point
  /// render targets (OpenGL ES) sort all translucent draws instead.
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
  /// translucent draws so `WaterMaterial` and transmissive `SpatialMaterial`
  /// refract the real scene behind them.
  bool get grabSceneColorEnabled => _grabSceneColorEnabled;
  bool _grabSceneColorEnabled = grabSceneColorEnabled;
  set grabSceneColorEnabled(bool value) {
    if (value == _grabSceneColorEnabled) {
      return;
    }
    _grabSceneColorEnabled = value;
    markSceneDirty(shadows: false);
  }

  /// Diagnostic buffer visualization mode (`none`, `normals`, `depth`, `ssao`,
  /// `cascadeSplits`, `wireframe`, `overdraw`, `roughnessMetallic`, `albedo`).
  RenderDebugMode3D get renderDebugMode3D => _renderDebugMode3D;
  RenderDebugMode3D _renderDebugMode3D = renderDebugMode3D;
  set renderDebugMode3D(RenderDebugMode3D value) {
    if (value == _renderDebugMode3D) {
      return;
    }
    _renderDebugMode3D = value;
    markSceneDirty(shadows: false);
  }

  /// Optional CPU Hi-Z [OcclusionCuller3D] rasterized once per unique main
  /// camera view-projection before traversal to cull occluded [Object3D]s.
  OcclusionCuller3D? get occlusionCuller => _occlusionCuller;
  OcclusionCuller3D? _occlusionCuller = occlusionCuller;
  set occlusionCuller(OcclusionCuller3D? value) {
    if (identical(value, _occlusionCuller)) {
      return;
    }
    _occlusionCuller = value;
    _lastRasterizedCuller = null;
    markSceneDirty(shadows: false);
  }

  OcclusionCuller3D? _lastRasterizedCuller;
  int _occFrame = -1;
  final Float32List _occVp = Float32List(16);

  /// Rasterizes registered occluders of [occlusionCuller] once per unique
  /// main-camera view-projection and frame before traversal.
  @internal
  void prepareOcclusionCuller(RenderContext3D ctx) {
    final culler = _occlusionCuller;
    if (culler == null || ctx.isShadowPass || !culler.hasOccluders) {
      return;
    }
    final frame = ctx.device.frame;
    final vp = ctx.viewProjection.storage;
    if (identical(_lastRasterizedCuller, culler) &&
        _occFrame == frame &&
        sameMatrix16(vp, _occVp)) {
      return;
    }
    _lastRasterizedCuller = culler;
    _occFrame = frame;
    for (var i = 0; i < 16; i++) {
      _occVp[i] = vp[i];
    }
    culler.rasterizeOccluders(ctx.viewProjection);
  }

  late final List<ReflectionProbeVolume3D> _reflectionProbesView =
      UnmodifiableListView(_reflectionProbes);

  /// Mounted local box-projected `ReflectionProbeVolume3D` components.
  List<ReflectionProbeVolume3D> get reflectionProbes => _reflectionProbesView;

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

  List<Component3D>? _rootComponents3D;
  int _nonComponent3DRootCount = 0;
  bool _rootHasPrioritizedChild = false;

  bool _allRootChildrenComponent3D() {
    if (isMounted) {
      return _nonComponent3DRootCount == 0;
    }
    for (final child in children) {
      if (child is! Component3D) {
        return false;
      }
    }
    return true;
  }

  PictureRecorder? _fallbackRecorder;
  Canvas? _fallbackCanvas;

  /// Lazily creates a fallback offscreen [Canvas] only if a non-[Component3D]
  /// or `debugMode` component is encountered during no-canvas rendering.
  @internal
  Canvas fallbackDummyCanvas() =>
      _fallbackCanvas ??= Canvas(_fallbackRecorder = PictureRecorder());

  /// Disposes any lazily allocated fallback [PictureRecorder].
  @internal
  void disposeFallbackDummyCanvas() {
    final recorder = _fallbackRecorder;
    if (recorder != null) {
      _fallbackRecorder = null;
      _fallbackCanvas = null;
      recorder.endRecording().dispose();
    }
  }

  @override
  void onMount() {
    _rootComponents3D?.clear();
    _nonComponent3DRootCount = 0;
    _rootHasPrioritizedChild = false;
    super.onMount();
  }

  @override
  void rebalanceChildren() {
    _rootHasPrioritizedChild = true;
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
  ///
  /// Lights, reflection probe volumes and the components that set
  /// [Component3D.includeInSceneBounds] to `false` are left out. The sun's
  /// shadow map is fitted to these bounds, and a `Scene3DComponent` renders
  /// only the part of its area they cover unless [hasUnboundedComponents].
  Aabb3? get sceneBounds => _sceneBounds.value;
  final ComponentBounds _sceneBounds = ComponentBounds();
  final Set<Component3D> _unboundedComponents = Set.identity();

  /// Whether this world holds a component left out of [sceneBounds] (see
  /// [Component3D.includeInSceneBounds]), which may draw outside them.
  bool get hasUnboundedComponents => _unboundedComponents.isNotEmpty;

  @override
  void onChildrenChanged(flame.Component child, flame.ChildrenChangeType type) {
    super.onChildrenChanged(child, type);
    if (child is Component3D) {
      switch (type) {
        case flame.ChildrenChangeType.added:
          (_rootComponents3D ??= <Component3D>[]).add(child);
          if (child.priority != 0) {
            _rootHasPrioritizedChild = true;
          }
        case flame.ChildrenChangeType.removed:
          _rootComponents3D?.remove(child);
      }
    } else {
      switch (type) {
        case flame.ChildrenChangeType.added:
          _nonComponent3DRootCount++;
        case flame.ChildrenChangeType.removed:
          if (_nonComponent3DRootCount > 0) {
            _nonComponent3DRootCount--;
          }
      }
    }
    final isVolumeOrLight =
        child is LightComponent || child is ReflectionProbeVolume3D;
    // The casters tell the change tracking themselves when they are mounted
    // or removed (see Component3D.onMount).
    markComponentDirty(shadows: !isVolumeOrLight);
    if (child is! Component3D || isVolumeOrLight) {
      return;
    }
    switch (type) {
      case flame.ChildrenChangeType.added:
        _addToSceneBounds(child);
      case flame.ChildrenChangeType.removed:
        _sceneBounds.remove(child);
        _unboundedComponents.remove(child);
    }
  }

  /// Moves [child] in or out of [sceneBounds] after its
  /// [Component3D.includeInSceneBounds] changed.
  @internal
  void updateSceneBoundsMembership(Component3D child) {
    final wasBounded = _sceneBounds.contains(child);
    if (!wasBounded && !_unboundedComponents.remove(child)) {
      return;
    }
    if (wasBounded) {
      _sceneBounds.remove(child);
    }
    _addToSceneBounds(child);
    markSceneDirty();
  }

  /// Register a [light] with this world.
  @internal
  void addLight(Light light) {
    _lights.add(light);
    _lightListRevision++;
    markLightsDirty();
  }

  /// Unregister a [light] from this world.
  @internal
  void removeLight(Light light) {
    _lights.remove(light);
    _lightListRevision++;
    markLightsDirty();
  }

  /// Register a local [ReflectionProbeVolume3D] with this world.
  @internal
  void addReflectionProbe(ReflectionProbeVolume3D probe) {
    _reflectionProbes.add(probe);
    markSceneDirty(shadows: false);
  }

  /// Unregister a local [ReflectionProbeVolume3D] from this world.
  @internal
  void removeReflectionProbe(ReflectionProbeVolume3D probe) {
    _reflectionProbes.remove(probe);
    markSceneDirty(shadows: false);
  }

  @override
  void onRemove() {
    super.onRemove();
    _host = null;
    _cachedGame = null;
    _visibleObjects.clear();
    _hasVisibleCache = false;
    disposeFallbackDummyCanvas();
  }

  Game? _cachedGame;
  final _SnapshotHost _snapshotHost = _SnapshotHost();
  final List<Object3D> _visibleObjects = [];
  bool _collectingVisible = false;
  bool _hasVisibleCache = false;
  RenderContext3D? _visibleCtx;
  int _visibleCameraMask = 0;
  int _visibleSceneVersion = -1;
  final Float32List _visibleVp = Float32List(16);

  /// Records [object] as visible during the current traversal when the world
  /// is collecting visible objects for reuse in the main scene pass.
  @internal
  void recordVisibleObject(Object3D object) {
    if (_collectingVisible) {
      _visibleObjects.add(object);
    }
  }

  @override
  void update(double dt) {
    super.update(dt);
    // A material marked animated changes on every frame: so does the scene
    // while the last render drew one.
    if (_drawnMaterials.animatedCount > 0) {
      _animationTicks++;
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
  DirectionalShadowProjection get shadowProjection => _shadowProjection;
  final DirectionalShadowProjection _shadowProjection =
      DirectionalShadowProjection();

  /// The group of worlds this world shares its shadow map with, or `null`.
  ShadowGroup? get shadowGroup => _shadowGroup;
  set shadowGroup(ShadowGroup? group) {
    if (identical(group, _shadowGroup)) {
      return;
    }
    _shadowGroup?._leave(this);
    _shadowGroup = group;
    _groupRound = -1;
    group?._worlds.add(this);
    markSceneDirty();
  }

  ShadowGroup? _shadowGroup;

  // The camera this world was last shown with in its shadow group, and the
  // round of the group it was shown in, see [ShadowGroup.noteView].
  final Matrix4 _groupView = Matrix4.zero();
  final Matrix4 _groupProjection = Matrix4.zero();
  final Matrix4 _groupViewProjection = Matrix4.zero();
  int _groupRound = -1;
  bool _groupNotedByHost = false;

  /// Renders (or reuses) the shadow map / unified `ShadowAtlas3D` of this
  /// world, returning whether the upcoming main pass receives shadows.
  bool renderShadows(Canvas canvas, {RenderContext3D? overrideContext}) {
    try {
      return _renderShadows(canvas, overrideContext);
    } finally {
      _shadowCasters.advance();
    }
  }

  /// Internal no-[Canvas] variant of [renderShadows], allocating a dummy
  /// [PictureRecorder] lazily only if a non-[Component3D] child is met.
  @internal
  bool renderShadowsNoCanvas({RenderContext3D? overrideContext}) {
    try {
      return _renderShadows(null, overrideContext);
    } finally {
      _shadowCasters.advance();
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
      reflectionProbes: _reflectionProbes,
      prioritizeNearestLights: _prioritizeNearestLights,
      lightGrid: _lightGrid,
      lightGridBounds: bounds,
      hdrEnabled: resolvedHdr,
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
      ..reflectionProbes = _reflectionProbes
      ..prioritizeNearestLights = _prioritizeNearestLights
      ..lightGrid = _lightGrid
      ..lightGridBounds = bounds
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

  /// Executes the complete 3D scene pass pipeline (Grab-Pass refraction,
  /// Weighted Blended OIT, CustomRenderPass3D hooks, HDR float16 target, and
  /// Bloom/PostProcess/ColorLut3D/Debug composite) once shadows & depth-normal
  /// prepasses have completed, returning the final [Image].
  ///
  /// [visibleFrame], in the pixels of the target, is the part of it that is
  /// seen, which the vignette is centered on (the whole target by default).
  ///
  /// The materials the render binds are kept with their versions, so that
  /// [sceneVersion] follows their changes; the materials of the previous
  /// render that changed since are counted in [RenderStats.updatedMaterials]
  /// and [RenderStats.animatedMaterials] of the device.
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
    final tracker = _drawnMaterials..begin();
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
  ///
  /// The world need not be mounted: the lights of an unmounted world are
  /// gathered from its tree for the render. Each call renders into a render
  /// target of its own, so the image stays valid however long it is kept.
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

  /// Runs [body] with [device] and [context] as this world's host, so that
  /// its components record their draws into [context] whatever host the
  /// world is mounted under (or without one).
  ///
  /// For an unmounted world, whose lights are not registered (they register
  /// when mounted), the lights of its tree are gathered for the duration of
  /// [body], and so are those of an unmounted [lightsFrom].
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
    final gatherLights = !isMounted && _lights.isEmpty;
    if (gatherLights) {
      _gatherLights(this);
    }
    final lender = _lightsFrom;
    final gatherLenderLights =
        lender != null && !lender.isMounted && lender._lights.isEmpty;
    if (gatherLenderLights) {
      lender._gatherLights(lender);
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
        _lights.clear();
        _lightListRevision++;
      }
      if (gatherLenderLights) {
        lender._lights.clear();
        lender._lightListRevision++;
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

  /// Whether a render pass with [cameraMask] draws [component] itself (its
  /// ancestors aside).
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
          _hasVisibleCache = false;
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
