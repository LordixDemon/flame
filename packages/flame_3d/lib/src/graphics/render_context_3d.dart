import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flame_3d/camera.dart' show DepthLayer3D;
import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/src/extensions/clip_space.dart';
import 'package:flame_3d/src/graphics/fullscreen_quad.dart';
import 'package:flame_3d/src/graphics/material_pipeline_cache.dart';
import 'package:flame_3d/src/graphics/material_tracker.dart';
import 'package:flame_3d/src/graphics/prefixed_uniform_block.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:meta/meta.dart';

part 'render_context_3d_camera_state.dart';
part 'render_context_3d_depth_normal.dart';
part 'render_context_3d_draw.dart';
part 'render_context_3d_draw_queue.dart';
part 'render_context_3d_joints.dart';
part 'render_context_3d_oit_refraction.dart';
part 'render_context_3d_plan.dart';
part 'render_context_3d_probes.dart';
part 'render_context_3d_shadows.dart';
part 'render_context_3d_shadows_atlas.dart';
part 'render_context_3d_shadows_cascades.dart';
part 'render_context_3d_shadows_casters.dart';
part 'render_context_3d_uniforms.dart';

/// Fills a uniform block that the [RenderContext3D] uploads once per render
/// pass, see [RenderContext3D.registerPassUniform].
typedef PassUniformWriter = void Function(
  RenderContext3D context,
  UniformBlock block,
);

/// The texture a sampler gets for a whole render pass, see
/// [RenderContext3D.registerPassTexture].
typedef PassTextureProvider = Texture Function(RenderContext3D context);

/// {@template render_context_3d}
/// Records the draws of a render pass and submits them to the
/// [GraphicsDevice] in an order that is cheap for the GPU.
/// {@endtemplate}
class RenderContext3D(super.device) extends RenderContext {
  /// {@macro render_context_3d}
  this {
    registerPassUniform(cameraMatricesBlock, writeCameraUniforms);
    registerPassUniform(cameraBlock, writeCameraUniforms);
    registerPassUniform(ambientLightBlock, writeAmbientLightUniforms);
    registerPassUniform(lightsBlock, writeLightsUniforms);
    registerPassUniform(directionalLightsBlock, writeDirectionalLightsUniforms);
    registerPassUniform(spotLightsBlock, writeSpotLightsUniforms);
    registerPassUniform(hemisphereLightBlock, writeHemisphereLightUniforms);
    registerPassUniform(lightGridBlock, writeLightGridUniforms);
    registerPassUniform(shadowsBlock, writeShadowsUniforms);
    registerPassUniform(shadowAtlasBlock, _ShadowPass.writeAtlasUniforms);
    registerPassUniform(fogBlock, writeFogUniforms);
    registerPassUniform(waterVolumeBlock, writeWaterVolumeUniforms);
    registerPassUniform(depthNormalBlock, _DepthNormalPass.writeUniforms);
    registerPassUniform(
      sceneColorBlock,
      _OitAndGrabPass.writeSceneColorUniforms,
    );
    registerPassUniform(passOptionsBlock, writePassOptionsUniforms);
    registerPassUniform(shadowCasterBlock, _ShadowPass.writeCasterUniforms);
    registerPassTexture(shadowMapSampler, _ShadowPass.shadowMapTexture);
    registerPassTexture(
      shadowStillCastersSampler,
      _ShadowPass.stillCastersTexture,
    );
    registerPassTexture(lightGridSampler, _lightGridTexture);
    registerPassTexture(depthNormalSampler, _DepthNormalPass.passTexture);
    registerPassTexture(
      sceneColorSampler,
      _OitAndGrabPass.sceneColorPassTexture,
    );
    registerPassTexture(
      brdfLutSampler,
      (ctx) => BrdfLut3D.sharedTexture(ctx.device.backend),
    );
    registerPassTexture(
      probeGridSampler,
      (ctx) =>
          ctx.lightProbeGrid?.volumeTextureFor(ctx.device.backend) ??
          Texture.standard,
    );
  }

  /// The name of the vertex stage block holding the camera matrices
  /// (`view`, `projection` and `viewProjection`).
  static const String cameraMatricesBlock = 'CameraMatrices';

  /// The name of the block holding the camera `position` (and any of the
  /// members of [cameraMatricesBlock]).
  static const String cameraBlock = 'Camera';

  /// The name of the ambient light uniform block.
  static const String ambientLightBlock = 'AmbientLight';

  /// The name of the point lights uniform block.
  static const String lightsBlock = 'Lights';

  /// The name of the directional lights uniform block.
  static const String directionalLightsBlock = 'DirectionalLights';

  /// The name of the spot lights uniform block.
  static const String spotLightsBlock = 'SpotLights';

  /// The name of the hemisphere light uniform block.
  static const String hemisphereLightBlock = 'HemisphereLight';

  /// The name of the uniform block describing the light grid of the pass, see
  /// `flame_3d/light_grid.glsl` (`LightGrid.origin`, `cells`, `data`,
  /// `counts`, the unbinned light counts at the head of [lightsBlock] and
  /// [spotLightsBlock]).
  static const String lightGridBlock = 'LightGrid';

  /// The name of the sampler holding the packed cell lists of the light grid
  /// (`RGBA32F` of width [LightGrid3D.textureWidth]).
  static const String lightGridSampler = 'lightGridTexture';

  /// The name of the skeletal skinning joint-matrices uniform block.
  ///
  /// The block holds at most 32 transposed `3x4` joint matrices (`vec4` rows,
  /// [jointRowsMember]).
  static const String jointMatricesBlock = 'JointMatrices';

  /// The vector member holding the `3x4` transposed joint matrices inside
  /// [jointMatricesBlock].
  static const String jointRowsMember = 'jointRows';

  /// The name of the rigid multi-mesh batch uniform block (`BatchObjects`),
  /// see `flame_3d/rigid_batch.glsl`.
  static const String batchObjectsBlock = 'BatchObjects';

  /// The name of the directional shadow mapping uniform block.
  static const String shadowsBlock = 'Shadows';

  /// The name of the multi-tile `ShadowAtlas3D` uniform block (`tiles`, `res`).
  static const String shadowAtlasBlock = 'ShadowAtlas';

  /// The name of the directional shadow map sampler.
  static const String shadowMapSampler = 'shadowMap';

  /// The name of the uniform block giving the view-projection matrix (`vp`)
  /// for the shadow-caster pass.
  static const String shadowCasterBlock = 'ShadowCaster';

  /// The name of the sampler giving a shadow caster view the depth of its
  /// still casters while it records the moving ones over them.
  static const String shadowStillCastersSampler = 'shadowStillCasters';

  /// The name of the atmospheric fog uniform block.
  static const String fogBlock = 'Fog';

  /// The name of the volumetric water uniform block (`WaterVolume`, read
  /// through `StylizedPass` by `StylizedMaterial`).
  static const String waterVolumeBlock = 'WaterVolume';

  /// The name of the half-res depth-normal pass uniform block (`DepthNormal`).
  static const String depthNormalBlock = 'DepthNormal';

  /// The name of the half-res depth-normal texture sampler.
  static const String depthNormalSampler = 'depthNormalTexture';

  /// The name of the scene-color grab-pass uniform block (`SceneColor`).
  static const String sceneColorBlock = 'SceneColor';

  /// The name of the scene-color grab-pass texture sampler
  /// (`sceneColorTexture`).
  static const String sceneColorSampler = 'sceneColorTexture';

  /// The name of the shared Karis split-sum GGX BRDF lookup sampler.
  static const String brdfLutSampler = 'brdfLutTexture';

  /// The name of the volumetric `SH9` diffuse irradiance probe grid sampler.
  static const String probeGridSampler = 'probeGridTexture';

  /// The name of the per-pass options uniform block (`PassOptions`: HDR
  /// encoding flag, diagnostic `RenderDebugMode3D`, and `LightProbeGrid3D`).
  static const String passOptionsBlock = 'PassOptions';

  /// The single uniform block packing every pass block a `StylizedMaterial`
  /// reads. Its fields match those of the sub-blocks prefixed with `<Block>_`.
  @internal
  static const String stylizedPassBlock = 'StylizedPass';

  /// The single uniform block packing every pass block a `SpatialMaterial`
  /// reads. Its fields match those of the sub-blocks prefixed with `<Block>_`.
  @internal
  static const String spatialPassBlock = 'SpatialPass';

  static const List<String> _stylizedPassParts = [
    cameraBlock,
    ambientLightBlock,
    lightsBlock,
    directionalLightsBlock,
    spotLightsBlock,
    hemisphereLightBlock,
    shadowsBlock,
    fogBlock,
    waterVolumeBlock,
    lightGridBlock,
  ];

  static const List<String> _spatialPassParts = [
    cameraBlock,
    passOptionsBlock,
    ambientLightBlock,
    lightsBlock,
    directionalLightsBlock,
    spotLightsBlock,
    hemisphereLightBlock,
    lightGridBlock,
    shadowsBlock,
    fogBlock,
  ];

  /// Maximum point lights supported per render pass.
  static const int maxPointLights = 8;

  /// Maximum directional lights supported per render pass (`DirectionalLights`
  /// UBO holds `4` entries `[0..3]`).
  static const int maxDirectionalLights = 4;

  /// Maximum spot lights supported per render pass.
  static const int maxSpotLights = 4;

  final _CameraPassState _camera = _CameraPassState();
  final _DrawQueue _queue = _DrawQueue();
  final _JointUploadCache _jointCache = _JointUploadCache();
  final _ReflectionProbeSelector _probeSelector = _ReflectionProbeSelector();
  final _PipelineResolutionCache _pipelineCache = _PipelineResolutionCache();
  final _PassUniformRegistry _passRegistry = _PassUniformRegistry();
  final _LightPassState _lightState = _LightPassState();

  late final _ShadowPass _shadows = _ShadowPass(this);
  late final _DepthNormalPass _depthNormal = _DepthNormalPass(this);
  late final _OitAndGrabPass _oitGrab = _OitAndGrabPass(this);

  /// The model matrix of the draw being submitted.
  Matrix4 get model => _camera.modelMatrix;

  /// The camera's view matrix for the current pass.
  Matrix4 get view => _camera.viewMatrix;

  /// The camera's projection matrix for the current pass.
  Matrix4 get projection => _camera.projectionMatrix;

  /// `projection * view` for the current pass.
  Matrix4 get viewProjection => _camera.viewProjectionMatrix;

  /// Camera world-space position, computed from the view matrix by
  /// [setCamera].
  ///
  /// In a shadow pass this is the origin of the light's view, not a viewer:
  /// choose level of detail and distance culling from [viewerPosition].
  Vector3 get cameraPosition => _camera.cameraPosition;

  /// The world-space position of the viewer that level of detail and
  /// distance culling choose detail from.
  ///
  /// The same as [cameraPosition] in a camera pass. While a shadow pass
  /// records ([isShadowPass]), it stays the position of the main camera that
  /// was set when the shadow pass began, so shadow casters draw the geometry
  /// the main pass shows instead of geometry chosen around the light's view
  /// origin.
  Vector3 get viewerPosition => _shadows.recording
      ? _camera.shadowViewerPosition
      : _camera.cameraPosition;

  /// The `projection * view` matrix of the viewer of [viewerPosition]: the
  /// same as [viewProjection] in a camera pass, the main camera's while a
  /// shadow pass records. Use it to measure the screen size of an object for
  /// level of detail.
  Matrix4 get viewerViewProjection => _shadows.recording
      ? _camera.shadowViewerViewProjection
      : _camera.viewProjectionMatrix;

  /// The view frustum of the current pass, in world space.
  Frustum get frustum => _camera.frustum;

  /// Whether the camera of the current pass mirrors the scene.
  bool get isMirrored => _camera.isMirrored;

  /// The front-face winding for the current pass.
  WindingOrder get frontFace => _camera.isMirrored
      ? WindingOrder.clockwise
      : WindingOrder.counterClockwise;

  /// Monotonically incremented whenever the main viewer camera changes
  /// outside shadow rendering, used by LODs and view-dependent caches.
  int get viewerEpoch => _camera.viewerEpoch;

  /// The joint matrices of the draw [Material.apply] runs for, or `null` when
  /// it is not skinned.
  List<Matrix4>? get jointTransforms => _jointCache.activeTransforms;

  /// The lights of the scene. Must be set before the draws are flushed.
  List<Light> get lights => _lightState.lights;
  set lights(List<Light> value) {
    _lightState
      ..lights = value
      ..worldLightsVersion = null
      .._syncedLightRev = -1
      ..syncedOwner = null;
  }

  /// World lights revision last supplied by [setWorldLights], or `null` when
  /// [lights] was assigned directly.
  @internal
  int? get worldLightsVersion => _lightState.worldLightsVersion;

  /// Owner that last synchronized options onto this context via
  /// [needsSyncOptions].
  @internal
  Object? get syncedOwner => _lightState.syncedOwner;

  /// Sets [lights] together with the enclosing `World3D.lightsVersion` so
  /// light-grid builds can skip unchanged passes in O(1).
  @internal
  void setWorldLights(List<Light> value, int lightsVersion) {
    _lightState
      ..lights = value
      ..worldLightsVersion = lightsVersion;
  }

  /// How the passes shade more point and spot lights than the
  /// [lightsBlock] and [spotLightsBlock] hold, or `null` (the default) to
  /// leave the lights beyond those out, see [LightGridSettings].
  /// `World3D.lightGrid` sets it.
  LightGridSettings? get lightGrid => _lightState.lightGrid;
  set lightGrid(LightGridSettings? value) => _lightState.lightGrid = value;

  /// What the light grid of the last pass that read one held, see
  /// [LightGridStats].
  LightGridStats get lightGridStats => _lightState.lightGridBuilder.stats;

  /// The world bounds of everything the pass draws, or `null` (the default)
  /// when they are not known: the [lightGrid] covers only them.
  /// `World3D` sets its `sceneBounds`, unless it holds a component that may
  /// draw outside them.
  Aabb3? get lightGridBounds => _lightState.lightGridBounds;
  set lightGridBounds(Aabb3? value) => _lightState.lightGridBounds = value;

  /// Whether exceeding [maxPointLights] / [maxSpotLights] ranks lights by
  /// proximity + intensity instead of keeping list order.
  bool get prioritizeNearestLights => _lightState.prioritizeNearestLights;
  set prioritizeNearestLights(bool value) =>
      _lightState.prioritizeNearestLights = value;

  /// Atmospheric fog of the current pass (`null` disables fog).
  FogSettings? fog;

  /// The body of water of the current pass, whose submerged surfaces
  /// `StylizedMaterial` tints (`null`, the default, for none).
  WaterVolumeSettings? waterVolume;

  /// Whether the current pass renders into the HDR scene target of a
  /// `World3D` with `hdrEnabled`, which the composite decodes.
  ///
  /// Materials write that target sRGB-encoded with an extended range (values
  /// above 1 are kept): `SpatialMaterial` encodes its un-tonemapped radiance
  /// when this is `true` (read from `PassOptions.flags.x`), the other
  /// materials write their usual display colors either way.
  bool hdrEnabled = false;

  /// Active diagnostic buffer visualization mode for the current pass.
  RenderDebugMode3D renderDebugMode = RenderDebugMode3D.none;

  /// Optional volumetric 3D `SH9` diffuse irradiance probe grid of the scene.
  LightProbeGrid3D? lightProbeGrid;

  /// Active local box-projected [ReflectionProbeSource3D]s of the scene.
  List<ReflectionProbeSource3D> get reflectionProbes => _probeSelector.probes;
  set reflectionProbes(List<ReflectionProbeSource3D> value) =>
      _probeSelector.probes = value;

  /// Optional depth layers rendered in a single pass with per-layer viewport
  /// `[DepthLayer3D.zNear, DepthLayer3D.zFar]` and water-volume toggles.
  List<DepthLayer3D>? depthLayers;

  /// Active [DepthLayer3D.index] recorded onto newly enqueued draws.
  @internal
  int activeDepthLayer = 0;

  /// 32-bit layer bitmask filtering `Object3D.cameraMask` and `Light.lightMask`
  /// for the current pass (`0xFFFFFFFF` renders all layers by default).
  int cameraMask = 0xFFFFFFFF;

  /// The number of draws recorded in the last flushed pass.
  int get drawCount => _queue.lastDrawCount;

  /// Notes the materials bound while a world renders, so that its version
  /// follows their changes; set by the world for its render.
  @internal
  MaterialTracker? materialTracker;

  int _pass = 0;
  int _cameraPass = 0;
  int _nextPassEpoch = 1;

  /// Incremented whenever the active camera matrices change.
  @internal
  int get cameraPass => _cameraPass;

  Shader? _activeApplyVertexShader;

  /// Vertex shader variant for which `Material.apply` is currently running,
  /// or `null` outside `_applyMaterial`.
  @internal
  Shader? get activeApplyVertexShader => _activeApplyVertexShader;

  Material? _boundMaterial;
  int _bindingEpoch = -1;
  int _oitPass = _OitAndGrabPass.noPass;
  bool _depthPrepassOverride = false;

  void _bumpAllPassKinds() {
    _pass++;
    _passRegistry.bumpAll(++_nextPassEpoch);
  }

  void _bumpSceneColorUniforms() {
    _passRegistry.bumpSceneColor(++_nextPassEpoch);
  }

  /// Bumps only `PassOptions`, `SpatialPass`, and custom pass blocks (without
  /// invalidating camera, light, fog, or stylized pass caches).
  @internal
  void bumpPassOptionsUniforms() {
    _passRegistry.bumpPassOptions(++_nextPassEpoch);
  }

  /// Bumps the pass uniform epoch when per-pass state (such as `hdrEnabled`,
  /// `renderDebugMode`, `SceneColor`, or `lightProbeGrid`) changes after
  /// [setCamera] was called.
  void bumpPassUniforms() {
    _bumpAllPassKinds();
  }

  /// The uniform blocks filled once per render pass, by block name.
  Map<String, PassUniformWriter> get passUniforms =>
      Map.unmodifiable(_passRegistry.writers);

  /// Registers [writer] to fill every uniform block named [name] once per
  /// render pass, for every shader that declares it.
  void registerPassUniform(String name, PassUniformWriter? writer) =>
      _passRegistry.registerUniform(name, writer);

  /// Registers [provider] to give the texture of every sampler named [name],
  /// once per render pass, for every shader that declares it.
  void registerPassTexture(String name, PassTextureProvider? provider) =>
      _passRegistry.registerTexture(name, provider);

  /// Set the camera matrices for the next pass.
  void setCamera(Matrix4 viewMatrix, Matrix4 projectionMatrix) {
    _bumpAllPassKinds();
    _cameraPass++;
    _shadows
      ..active = false
      ..atlasActive = false;
    _camera.setCamera(
      viewMatrix,
      projectionMatrix,
      isRecordingShadow: _shadows.recording,
    );
  }

  static bool mirrors(Matrix4 m) => _CameraPassState.mirrors(m);

  /// Groups all translucent draws with [RenderState.depthPrepass] recorded
  /// before the matching [endDepthPrepassGroup] into a single cohesive depth
  /// prepass followed by a single `lessEqual` shaded pass.
  void beginDepthPrepassGroup() => _queue.beginDepthPrepassGroup();

  /// Ends a group started by [beginDepthPrepassGroup].
  void endDepthPrepassGroup() => _queue.endDepthPrepassGroup();

  /// Records a draw of every surface of [mesh].
  void drawMesh(
    Mesh mesh, {
    Matrix4? transform,
    Color color = const Color(0xFFFFFFFF),
    Vector4? instanceData,
    Map<int, List<Matrix4>>? jointTransforms,
    bool? mirrored,
  }) {
    final multiSurface = mesh.surfaces.length > 1;
    if (multiSurface) {
      beginDepthPrepassGroup();
    }
    try {
      mesh.draw(
        this,
        transform: transform,
        color: color,
        instanceData: instanceData,
        jointTransforms: jointTransforms,
        mirrored: mirrored,
      );
    } finally {
      if (multiSurface) {
        endDepthPrepassGroup();
      }
    }
  }

  /// Records a draw of [surface] with its material (or [material]).
  void drawSurface(
    Surface surface, {
    Matrix4? transform,
    Color color = const Color(0xFFFFFFFF),
    Vector4? instanceData,
    List<Matrix4>? jointTransforms,
    Material? material,
    bool? mirrored,
  }) {
    final drawMaterial = material ?? surface.material;
    final shadowPass = _shadows.recording;
    if (shadowPass) {
      drawMaterial.wasRecorded = true;
      if (!drawMaterial.castsShadows ||
          !drawMaterial.instancesHoldModelMatrices) {
        return;
      }
    }
    final depthNormalPass = _depthNormal.recording;
    final hasDepthNormalMat = drawMaterial.depthNormalMaterial != null;
    if (depthNormalPass) {
      final rs = drawMaterial.renderState;
      if (rs.translucent ||
          !rs.depthWrite ||
          (!hasDepthNormalMat && !drawMaterial.instancesHoldModelMatrices)) {
        return;
      }
    }
    final queue = _queue;
    final i = queue.count;
    if (i == queue.capacity) {
      queue.grow();
    }
    queue.count++;

    queue.surfaces[i] = surface;
    queue.materials[i] = drawMaterial;
    queue.depthLayers[i] = activeDepthLayer;
    queue.joints[i] = jointTransforms != null && jointTransforms.isNotEmpty
        ? jointTransforms
        : null;
    queue.external[i] = null;

    final m = (transform ?? _camera.modelMatrix).storage;
    final base = i * VertexLayout.instanceStrideInFloats;
    final instances = queue.instances..setRange(base, base + 16, m);

    if (shadowPass) {
      queue.pipelines[i] = null;
      queue.vertexShaders[i] = null;
      queue.fragmentShaders[i] = null;
      queue.mirrored[i] = 0;
      queue.probeSlots[i] = 0;
      queue.probeWeights[i] = 0;
      queue.prepassGroups[i] = 0;
      queue.depths[i] = 0;
      RenderProfile.lap(RenderPhase.recording);
      return;
    }

    if (depthNormalPass) {
      if (hasDepthNormalMat) {
        _writeInstanceColorAndData(instances, base, color, instanceData);
      }
      queue.pipelines[i] = null;
      queue.vertexShaders[i] = null;
      queue.fragmentShaders[i] = null;
      queue.mirrored[i] = 0;
      queue.probeSlots[i] = 0;
      queue.probeWeights[i] = 0;
      queue.prepassGroups[i] = 0;
      final center = surface.aabbCenter;
      final cx = center.x;
      final cy = center.y;
      final cz = center.z;
      final wx = m[0] * cx + m[4] * cy + m[8] * cz + m[12];
      final wy = m[1] * cx + m[5] * cy + m[9] * cz + m[13];
      final wz = m[2] * cx + m[6] * cy + m[10] * cz + m[14];
      final d = _camera.depthRow;
      queue.depths[i] = d[0] * wx + d[1] * wy + d[2] * wz + d[3];
      RenderProfile.lap(RenderPhase.recording);
      return;
    }

    if (queue.cachedOpaqueCount >= 0 || _oitGrab.hasSortCache) {
      queue.cachedOpaqueCount = -1;
      _oitGrab.resetSortCache();
    }
    if (drawMaterial.renderState.translucent) {
      queue.hasRecordedTranslucent = true;
    }
    if (!queue.hasRecordedRefractive &&
        drawMaterial is SpatialMaterial &&
        drawMaterial.transmission > 1e-4) {
      queue.hasRecordedRefractive = true;
    }

    _pipelineCache.resolve(this, drawMaterial, surface.layout);
    queue.pipelines[i] = _pipelineCache.lastDev;
    queue.vertexShaders[i] = _pipelineCache.lastVert;
    queue.fragmentShaders[i] = _pipelineCache.lastFrag;

    if (mirrored != null) {
      queue.mirrored[i] = mirrored ? 1 : 0;
    } else {
      final determinant =
          m[0] * (m[5] * m[10] - m[6] * m[9]) -
          m[4] * (m[1] * m[10] - m[2] * m[9]) +
          m[8] * (m[1] * m[6] - m[2] * m[5]);
      queue.mirrored[i] = determinant < 0 ? 1 : 0;
    }

    _writeInstanceColorAndData(instances, base, color, instanceData);

    final center = surface.aabbCenter;
    final cx = center.x;
    final cy = center.y;
    final cz = center.z;
    final wx = m[0] * cx + m[4] * cy + m[8] * cz + m[12];
    final wy = m[1] * cx + m[5] * cy + m[9] * cz + m[13];
    final wz = m[2] * cx + m[6] * cy + m[10] * cz + m[14];
    if (_probeSelector.probes.isNotEmpty && drawMaterial.usesReflectionProbes) {
      _probeSelector.selectForDraw(queue, i, _pass, wx, wy, wz);
    } else {
      queue.probeSlots[i] = 0;
      queue.probeWeights[i] = 0;
    }
    final d = _camera.depthRow;
    var depth = d[0] * wx + d[1] * wy + d[2] * wz + d[3];
    if (drawMaterial.renderState.translucent &&
        drawMaterial.renderState.depthPrepass) {
      if (drawMaterial.depthPrepassGroup case final key?) {
        depth = queue.joinSharedPrepassGroup(i, key, depth);
      } else if (queue.activePrepassGroup != 0) {
        if (queue.prepassGroupDepth.isNaN) {
          queue.prepassGroupDepth = depth;
        } else {
          depth = queue.prepassGroupDepth;
        }
        queue.prepassGroups[i] = queue.activePrepassGroup;
      } else {
        queue.prepassGroups[i] = queue.nextPrepassGroupId++;
      }
    } else {
      queue.prepassGroups[i] = 0;
    }
    queue.depths[i] = depth;
    RenderProfile.lap(RenderPhase.recording);
  }

  static void _writeInstanceColorAndData(
    Float32List instances,
    int base,
    Color color,
    Vector4? instanceData,
  ) {
    instances[base + 16] = color.r;
    instances[base + 17] = color.g;
    instances[base + 18] = color.b;
    instances[base + 19] = color.a;
    if (instanceData == null) {
      instances
        ..[base + 20] = 0
        ..[base + 21] = 0
        ..[base + 22] = 0
        ..[base + 23] = 0;
    } else {
      final data = instanceData.storage;
      instances
        ..[base + 20] = data[0]
        ..[base + 21] = data[1]
        ..[base + 22] = data[2]
        ..[base + 23] = data[3];
    }
  }

  /// Records one instanced draw of [surface] with its material (or
  /// [material]).
  ///
  /// [instances] holds [count] instances of
  /// [VertexLayout.instanceStrideInFloats] floats. Set [mirrored] when their
  /// model matrices mirror the surface (an odd number of negative scales), so
  /// that its front faces stay front faces; the instances of one draw must
  /// all mirror or all not. [center] is the world-space point the draw is
  /// sorted by when translucent.
  void drawInstances(
    Surface surface, {
    required Float32List instances,
    required int count,
    int instanceOffset = 0,
    List<Matrix4>? jointTransforms,
    Material? material,
    Vector3? center,
    bool mirrored = false,
    int? instanceVersion,
    int? instanceBufferCount,
  }) {
    if (count <= 0) {
      return;
    }
    assert(instanceOffset >= 0, 'instanceOffset must be non-negative');
    assert(
      instances.length >=
          (instanceOffset + count) * VertexLayout.instanceStrideInFloats,
      'instances holds fewer than ${instanceOffset + count} instances',
    );
    final drawMaterial = material ?? surface.material;
    final shadowPass = _shadows.recording;
    if (shadowPass) {
      drawMaterial.wasRecorded = true;
      if (!drawMaterial.castsShadows ||
          !drawMaterial.instancesHoldModelMatrices) {
        return;
      }
    }
    final depthNormalPass = _depthNormal.recording;
    if (depthNormalPass) {
      final rs = drawMaterial.renderState;
      if (rs.translucent ||
          !rs.depthWrite ||
          (drawMaterial.depthNormalMaterial == null &&
              !drawMaterial.instancesHoldModelMatrices)) {
        return;
      }
    }
    DevicePipeline? pipeline;
    Shader? vertShader;
    Shader? fragShader;
    if (!shadowPass && !depthNormalPass) {
      _pipelineCache.resolve(this, drawMaterial, surface.layout);
      pipeline = _pipelineCache.lastDev!;
      vertShader = _pipelineCache.lastVert!;
      fragShader = _pipelineCache.lastFrag!;
      if (!pipeline.instanced) {
        throw StateError(
          'drawInstances needs a material whose vertex shader reads the '
          'instance inputs (the four instanceModel columns)',
        );
      }
    }
    final queue = _queue;
    final i = queue.count;
    if (i == queue.capacity) {
      queue.grow();
    }
    queue.count++;

    queue.surfaces[i] = surface;
    queue.materials[i] = drawMaterial;
    queue.depthLayers[i] = activeDepthLayer;
    queue.pipelines[i] = pipeline;
    queue.vertexShaders[i] = vertShader;
    queue.fragmentShaders[i] = fragShader;
    queue.joints[i] = jointTransforms != null && jointTransforms.isNotEmpty
        ? jointTransforms
        : null;
    queue.mirrored[i] = mirrored ? 1 : 0;
    queue.external[i] = instances;
    queue.externalCounts[i] = count;
    queue.externalOffsets[i] =
        instanceOffset * VertexLayout.instanceStrideInFloats;
    queue.externalVersions[i] = instanceVersion ?? -1;
    queue.externalCacheSpans[i] = instanceBufferCount ?? 0;

    if (shadowPass) {
      queue.probeSlots[i] = 0;
      queue.probeWeights[i] = 0;
      queue.prepassGroups[i] = 0;
      queue.depths[i] = 0;
      RenderProfile.lap(RenderPhase.recording);
      return;
    }

    final d = _camera.depthRow;
    if (depthNormalPass) {
      queue.probeSlots[i] = 0;
      queue.probeWeights[i] = 0;
      queue.prepassGroups[i] = 0;
      queue.depths[i] = center == null
          ? d[3]
          : d[0] * center.x + d[1] * center.y + d[2] * center.z + d[3];
      RenderProfile.lap(RenderPhase.recording);
      return;
    }

    if (queue.cachedOpaqueCount >= 0 || _oitGrab.hasSortCache) {
      queue.cachedOpaqueCount = -1;
      _oitGrab.resetSortCache();
    }
    if (drawMaterial.renderState.translucent) {
      queue.hasRecordedTranslucent = true;
    }
    if (!queue.hasRecordedRefractive &&
        drawMaterial is SpatialMaterial &&
        drawMaterial.transmission > 1e-4) {
      queue.hasRecordedRefractive = true;
    }

    if (_probeSelector.probes.isNotEmpty && drawMaterial.usesReflectionProbes) {
      final at = center ?? _camera.cameraPosition;
      _probeSelector.selectForDraw(queue, i, _pass, at.x, at.y, at.z);
    } else {
      queue.probeSlots[i] = 0;
      queue.probeWeights[i] = 0;
    }
    queue.depths[i] = center == null
        ? d[3]
        : d[0] * center.x + d[1] * center.y + d[2] * center.z + d[3];
    final prepass =
        drawMaterial.renderState.translucent &&
        drawMaterial.renderState.depthPrepass;
    if (prepass && drawMaterial.depthPrepassGroup != null) {
      queue.depths[i] = queue.joinSharedPrepassGroup(
        i,
        drawMaterial.depthPrepassGroup!,
        queue.depths[i],
      );
    } else {
      queue.prepassGroups[i] = prepass
          ? (queue.activePrepassGroup != 0
                ? queue.activePrepassGroup
                : queue.nextPrepassGroupId++)
          : 0;
    }
    RenderProfile.lap(RenderPhase.recording);
  }

  /// Records a single multi-mesh rigid batch draw of [surface] using per-object
  /// transforms, colors, and instance data packed in [batch].
  void drawRigidBatch(
    Surface surface, {
    required RigidBatchBuffer batch,
    List<Matrix4>? jointTransforms,
    Material? material,
    Vector3? center,
    bool mirrored = false,
  }) {
    assert(
      batch.capacity ==
          (surface.layout.offsetOf(StylizedMaterial.jointsAttribute) != null
              ? RigidBatchBuffer.maxSkinnedObjects
              : RigidBatchBuffer.maxObjects),
      'RigidBatchBuffer capacity (${batch.capacity}) must match surface '
      'layout (maxSkinnedObjects=${RigidBatchBuffer.maxSkinnedObjects}, '
      'maxObjects=${RigidBatchBuffer.maxObjects})',
    );
    final drawMaterial = material ?? surface.material;
    final shadowPass = _shadows.recording;
    if (shadowPass) {
      drawMaterial.wasRecorded = true;
      if (!drawMaterial.castsShadows ||
          !drawMaterial.instancesHoldModelMatrices) {
        return;
      }
    }
    if (_depthNormal.recording) {
      return;
    }
    DevicePipeline? pipeline;
    Shader? vertShader;
    Shader? fragShader;
    if (!shadowPass) {
      _pipelineCache.resolve(this, drawMaterial, surface.layout);
      pipeline = _pipelineCache.lastDev!;
      vertShader = _pipelineCache.lastVert!;
      fragShader = _pipelineCache.lastFrag!;
    }
    final queue = _queue;
    final i = queue.count;
    if (i == queue.capacity) {
      queue.grow();
    }
    queue.count++;

    queue.surfaces[i] = surface;
    queue.materials[i] = drawMaterial;
    queue.depthLayers[i] = activeDepthLayer;
    queue.pipelines[i] = pipeline;
    queue.vertexShaders[i] = vertShader;
    queue.fragmentShaders[i] = fragShader;
    queue.joints[i] = jointTransforms != null && jointTransforms.isNotEmpty
        ? jointTransforms
        : null;
    queue.external[i] = null;
    queue.batches[i] = batch;
    queue.mirrored[i] = mirrored ? 1 : 0;

    if (shadowPass) {
      queue.probeSlots[i] = 0;
      queue.probeWeights[i] = 0;
      queue.prepassGroups[i] = 0;
      queue.depths[i] = 0;
      RenderProfile.lap(RenderPhase.recording);
      return;
    }

    if (queue.cachedOpaqueCount >= 0 || _oitGrab.hasSortCache) {
      queue.cachedOpaqueCount = -1;
      _oitGrab.resetSortCache();
    }
    if (drawMaterial.renderState.translucent) {
      queue.hasRecordedTranslucent = true;
    }
    if (!queue.hasRecordedRefractive &&
        drawMaterial is SpatialMaterial &&
        drawMaterial.transmission > 1e-4) {
      queue.hasRecordedRefractive = true;
    }

    if (_probeSelector.probes.isNotEmpty && drawMaterial.usesReflectionProbes) {
      final at = center ?? _camera.cameraPosition;
      _probeSelector.selectForDraw(queue, i, _pass, at.x, at.y, at.z);
    } else {
      queue.probeSlots[i] = 0;
      queue.probeWeights[i] = 0;
    }
    final d = _camera.depthRow;
    queue.depths[i] = center == null
        ? d[3]
        : d[0] * center.x + d[1] * center.y + d[2] * center.z + d[3];
    final prepass =
        drawMaterial.renderState.translucent &&
        drawMaterial.renderState.depthPrepass;
    if (prepass && drawMaterial.depthPrepassGroup != null) {
      queue.depths[i] = queue.joinSharedPrepassGroup(
        i,
        drawMaterial.depthPrepassGroup!,
        queue.depths[i],
      );
    } else {
      queue.prepassGroups[i] = prepass
          ? (queue.activePrepassGroup != 0
                ? queue.activePrepassGroup
                : queue.nextPrepassGroupId++)
          : 0;
    }
    RenderProfile.lap(RenderPhase.recording);
  }

  /// Whether the draws being recorded are those of a shadow map.
  bool get isShadowPass => _shadows.recording;

  /// The casters the shadow pass being recorded draws: all of them, or, in
  /// a pass that keeps the depths of the still casters
  /// ([ShadowSettings.cacheStillCasters]), the still ones (into their kept
  /// layer) or the moving ones (over a copy of it). [ShadowCasterLayer.all]
  /// outside a shadow pass.
  ///
  /// `Object3D.bind` records the draws of an object only in the recordings
  /// of its layer (see `Object3D.shadowMotion`); a renderer that records
  /// draws itself in such a pass records those of the layer.
  ShadowCasterLayer get shadowCasterLayer =>
      _shadows.recording ? _shadows.layer : ShadowCasterLayer.all;

  /// Whether the current main pass receives a shadow map.
  bool get hasActiveShadows => _shadows.active;

  /// Whether the unified multi-tile `ShadowAtlas3D` is active for this pass.
  bool get hasShadowAtlas => _shadows.active && _shadows.atlasActive;

  /// Active `ShadowAtlas3D` tile packer of this context.
  ShadowAtlas3D get shadowAtlas => _shadows.atlas;

  /// Starts the shadow pass of the scene whose [lights] are set, with the
  /// camera of the main pass set: returns whether draws are to be recorded.
  ///
  /// The draws of every caster are recorded once per view of the lights:
  ///
  /// ```dart
  /// if (context.beginShadowPass(projection: p, sceneBounds: bounds)) {
  ///   recordCasters();
  ///   while (context.advanceShadowAtlasTile()) {
  ///     recordCasters();
  ///   }
  ///   context.endShadowPass();
  /// }
  /// ```
  ///
  /// A lone light (a directional light with one cascade, or a spot light)
  /// has one map; cascades, a point light and several lights share the tiles
  /// of the [shadowAtlas], each tile a view of its own. When it returns
  /// `false`, the main pass still receives shadows if [hasActiveShadows]
  /// (a map kept by [ShadowSettings.cacheWhenStatic]).
  ///
  /// With [ShadowFit.view], the map of a directional light (and its
  /// cascades) is fitted to what the camera of the pass sees, or, given
  /// [fitViewProjections] and the [fitViews] that go with them, to what any
  /// of these cameras sees: the map of several passes that share it.
  ///
  /// With a [stillCastersKey], an object that compares equal while the still
  /// casters do not change, and lights that set
  /// [ShadowSettings.cacheStillCasters], the depths of the still casters are
  /// kept per [projection] from frame to frame, one layer per map or atlas
  /// tile: a frame renders the layers that changed (one pass each), then the
  /// map, each view a copy of its layer with the moving casters drawn over
  /// it. Each recording then holds the casters of [shadowCasterLayer] only,
  /// which `Object3D` does itself, and there are more recordings than views:
  /// keep calling [advanceShadowAtlasTile] until it returns `false`. A view
  /// whose projection changed since the previous frame is rendered whole,
  /// and its layer is rendered again once its projection holds still.
  bool beginShadowPass({
    required DirectionalShadowProjection projection,
    required Aabb3? sceneBounds,
    Object? castersKey,
    Object? stillCastersKey,
    List<Matrix4>? fitViewProjections,
    List<Matrix4>? fitViews,
  }) {
    _camera.shadowViewerPosition.setFrom(_camera.cameraPosition);
    _camera.shadowViewerViewProjection.setFrom(_camera.viewProjectionMatrix);
    _shadows
      .._fitViewProjections = fitViewProjections
      .._fitViews = fitViews;
    try {
      return _shadows.begin(
        projection,
        sceneBounds,
        castersKey: castersKey,
        stillCastersKey: stillCastersKey,
      );
    } finally {
      _shadows
        .._fitViewProjections = null
        .._fitViews = null;
    }
  }

  /// Flushes casters recorded for the current `ShadowAtlas3D` tile and
  /// advances to the next tile inside the same render pass, returning `false`
  /// when all tiles have been recorded.
  bool advanceShadowAtlasTile() => _shadows.advanceAtlasTile();

  /// Renders the draws recorded since [beginShadowPass] into the shadow map
  /// and restores the main camera.
  void endShadowPass() => _shadows.end();

  /// Always `false`: two cascades are tiles of the [shadowAtlas], recorded
  /// through [advanceShadowAtlasTile].
  @Deprecated('Two cascades are atlas tiles; use advanceShadowAtlasTile')
  bool get needsShadowCascade1 => false;

  /// Does nothing: two cascades are tiles of the [shadowAtlas].
  @Deprecated('Two cascades are atlas tiles; use advanceShadowAtlasTile')
  void beginShadowCascade1() {}

  /// Does nothing: two cascades are tiles of the [shadowAtlas].
  @Deprecated('Two cascades are atlas tiles; use advanceShadowAtlasTile')
  void endShadowCascade1() {}

  /// Whether the draws being recorded belong to the half-res depth-normal
  /// prepass.
  bool get isDepthNormalPass => _depthNormal.recording;

  /// The active half-res depth-normal texture of the current pass, or `null`.
  Texture? get activeDepthNormalTexture =>
      _depthNormal.active ? _depthNormal._texture : null;

  /// Begins the half-res depth-normal prepass for a scene of [width]x[height].
  bool beginDepthNormalPass(int width, int height) =>
      _depthNormal.begin(width, height);

  /// Flushes opaque geometry into the half-res depth-normal target.
  void endDepthNormalPass() => _depthNormal.end();

  /// Marks the depth-normal prepass inactive when skipped for a pass.
  void clearDepthNormalPass() => _depthNormal.clear();

  /// Whether any currently recorded draw uses a refractive `SpatialMaterial`
  /// (`transmission > 0`).
  bool get hasRefractiveDraws => _queue.hasRecordedRefractive;

  /// Whether any currently recorded draw is translucent.
  bool get hasTranslucentDraws => _queue.hasRecordedTranslucent;

  /// Binds [grabTarget] as the active `sceneColorTexture` for upcoming passes
  /// (`null` clears it).
  void setActiveSceneColorTarget(GpuTextureTarget? grabTarget) {
    _oitGrab.setGrabTarget(grabTarget);
    _bumpSceneColorUniforms();
  }

  /// Clears any active `sceneColorTexture` binding.
  void clearActiveSceneColorTarget() {
    if (_oitGrab.grabActive) {
      _oitGrab.clearGrab();
      _bumpSceneColorUniforms();
    }
  }

  /// Flushes only the currently recorded opaque draws into the active render
  /// pass while keeping all recorded draws in memory for the subsequent
  /// translucent/WBOIT pass.
  void flushOpaquePreview() {
    final opaqueCount = _prepareOpaqueSorted();
    _boundMaterial = null;
    _bindingEpoch = -1;
    _depthPrepassOverride = false;
    _submitBatches(_queue.opaque, opaqueCount);
    _boundMaterial = null;
    _jointCache.activeTransforms = null;
  }

  /// Executes a Weighted Blended OIT accumulation (`revealPass == false`) or
  /// revealage (`revealPass == true`) subpass on the currently recorded draws.
  void flushWboitSubpass({
    required bool revealPass,
    required bool releaseAfter,
  }) => _oitGrab.flushWboitSubpass(
    revealPass: revealPass,
    releaseAfter: releaseAfter,
  );

  /// Composites WBOIT `opaqueTarget`, `accumTarget`, and `revealTarget` into
  /// the currently open render pass.
  void drawWboitComposite({
    required GpuTextureTarget opaqueTarget,
    required GpuTextureTarget accumTarget,
    required GpuTextureTarget revealTarget,
  }) => _oitGrab.drawCompositeQuad(
    opaqueTarget: opaqueTarget,
    accumTarget: accumTarget,
    revealTarget: revealTarget,
  );

  /// The [ReflectionProbeSource3D] chosen for the draw `Material.apply` runs
  /// for, or `null` when its material does not use volumes (see
  /// [Material.usesReflectionProbes]) or no volume reaches it.
  ///
  /// The volume is chosen when the draw is recorded, as
  /// [selectReflectionProbe] chooses it, at the center of the drawn surface's
  /// bounds in world space (for [drawInstances], at its `center`, or the
  /// camera position without one). Draws that get different volumes, or
  /// different weights, are not batched together.
  ReflectionProbeSource3D? get reflectionProbe => _probeSelector.activeProbe;

  /// The weight of [reflectionProbe] at the drawn object, in `(0, 1]`
  /// ([ReflectionProbeSource3D.weightAt]), or `0` without one.
  double get reflectionProbeWeight => _probeSelector.activeWeight;

  @internal
  int get activeProbeSlot => _probeSelector.drawProbeSlot;

  @internal
  double get activeProbeWeight => _probeSelector.drawProbeWeight;

  /// Selects the highest-priority / highest-weight [ReflectionProbeSource3D]
  /// influencing [worldPoint], or `null` when none covers it.
  (ReflectionProbeSource3D, double)? selectReflectionProbe(
    Vector3 worldPoint,
  ) => _probeSelector.select(worldPoint);

  int get shadowMapVersion => _shadows.version;

  /// Whether the shadow map of the last [beginShadowPass] depends on the
  /// cameras it was fitted to: a directional light with [ShadowFit.view]
  /// casts in it. A map that does not (spot and point lights,
  /// [ShadowFit.scene], [ShadowFit.fixed]) is the same whichever cameras are
  /// given, so a `ShadowGroup` reuses it in a frame whose cameras moved.
  @internal
  bool get shadowMapFollowsViews => _shadows.followsViews;

  bool reuseShadowMap(int version) => _shadows.reuse(version);

  static void writeShadowsUniforms(
    RenderContext3D context,
    UniformBlock block,
  ) {
    context._shadows.writeShadows(block);
  }

  /// Writes `PassOptions` (HDR linear output flag, `RenderDebugMode3D`,
  /// `SceneColor` Grab-Pass state and `LightProbeGrid3D` bounds) once per
  /// pass. The reflection probe volume of a draw is not a pass value: see
  /// [reflectionProbe].
  static void writePassOptionsUniforms(
    RenderContext3D context,
    UniformBlock block,
  ) {
    final off =
        (block.cachedWriterOffsets as _PassOptionsOffsets?) ??
        (block.cachedWriterOffsets = _PassOptionsOffsets(block));
    if (off.flags >= 0) {
      block.writeVec4ValuesAt(
        off.flags,
        context.hdrEnabled ? 1.0 : 0.0,
        context.renderDebugMode.index.toDouble(),
        context._oitGrab.grabActive ? 1.0 : 0.0,
        0.0,
      );
    }

    final grid = context.lightProbeGrid;
    if (grid != null && grid.intensity > 0) {
      final b = grid.bounds;
      final sx = math.max(1e-5, b.max.x - b.min.x);
      final sy = math.max(1e-5, b.max.y - b.min.y);
      final sz = math.max(1e-5, b.max.z - b.min.z);
      if (off.gridBoundsMin >= 0) {
        block.writeVec4ValuesAt(
          off.gridBoundsMin,
          b.min.x,
          b.min.y,
          b.min.z,
          grid.intensity,
        );
      }
      if (off.gridInvSpan >= 0) {
        // The grid holds irradiance: the diffuse light is E * kD * base / pi.
        block.writeVec4ValuesAt(
          off.gridInvSpan,
          1.0 / sx,
          1.0 / sy,
          1.0 / sz,
          grid.volumeTextureRange / math.pi,
        );
      }
      if (off.gridRes >= 0) {
        block.writeVec4ValuesAt(
          off.gridRes,
          grid.resolutionX.toDouble(),
          grid.resolutionY.toDouble(),
          grid.resolutionZ.toDouble(),
          0.0,
        );
      }
    } else {
      if (off.gridBoundsMin >= 0) {
        block.writeVec4ValuesAt(off.gridBoundsMin, 0, 0, 0, 0);
      }
      if (off.gridInvSpan >= 0) {
        block.writeVec4ValuesAt(off.gridInvSpan, 0, 0, 0, 0);
      }
      if (off.gridRes >= 0) {
        block.writeVec4ValuesAt(off.gridRes, 1, 1, 1, 0);
      }
    }
  }

  /// Submit all queued draws.
  void flush() => _flushDraws();

  /// Writes the viewer's world-space center of projection (`w = 1`) or
  /// parallel direction (`w = 0`) for the current camera pass, cached once per
  /// [_cameraPass].
  @internal
  void writeViewerTo(UniformBlock block, int offset) =>
      _camera.writeViewerTo(_cameraPass, block, offset);

  static void writeCameraUniforms(
    RenderContext3D context,
    UniformBlock block,
  ) => _writeCameraUniforms(context, block);

  static void writeAmbientLightUniforms(
    RenderContext3D context,
    UniformBlock block,
  ) => _writeAmbientLightUniforms(context, block);

  static void writeLightGridUniforms(
    RenderContext3D context,
    UniformBlock block,
  ) => _writeLightGridUniforms(context, block);

  static void writeLightsUniforms(
    RenderContext3D context,
    UniformBlock block,
  ) => _writeLightsUniforms(context, block);

  static void writeSpotLightsUniforms(
    RenderContext3D context,
    UniformBlock block,
  ) => _writeSpotLightsUniforms(context, block);

  static void writeDirectionalLightsUniforms(
    RenderContext3D context,
    UniformBlock block,
  ) => _writeDirectionalLightsUniforms(context, block);

  static void writeHemisphereLightUniforms(
    RenderContext3D context,
    UniformBlock block,
  ) => _writeHemisphereLightUniforms(context, block);

  static void writeFogUniforms(
    RenderContext3D context,
    UniformBlock block,
  ) => _writeFogUniforms(context, block);

  static void writeWaterVolumeUniforms(
    RenderContext3D context,
    UniformBlock block,
  ) => _writeWaterVolumeUniforms(context, block);

  @internal
  bool needsSyncOptions({
    required List<Light> lights,
    required int lightsVersion,
    required FogSettings? fog,
    required WaterVolumeSettings? waterVolume,
    required RenderDebugMode3D renderDebugMode,
    required LightProbeGrid3D? lightProbeGrid,
    required List<ReflectionProbeSource3D> reflectionProbes,
    required bool prioritizeNearestLights,
    required LightGridSettings? lightGrid,
    required Aabb3? lightGridBounds,
    required bool hdrEnabled,
    List<DepthLayer3D>? depthLayers,
    Object? owner,
  }) => _lightState.needsSyncOptions(
    context: this,
    lights: lights,
    lightsVersion: lightsVersion,
    fog: fog,
    waterVolume: waterVolume,
    renderDebugMode: renderDebugMode,
    lightProbeGrid: lightProbeGrid,
    reflectionProbes: reflectionProbes,
    prioritizeNearestLights: prioritizeNearestLights,
    lightGrid: lightGrid,
    lightGridBounds: lightGridBounds,
    hdrEnabled: hdrEnabled,
    depthLayers: depthLayers,
    owner: owner,
  );
}
