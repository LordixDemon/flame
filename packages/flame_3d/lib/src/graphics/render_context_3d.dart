import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flame_3d/camera.dart';
import 'package:flame_3d/game.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/src/extensions/clip_space.dart';
import 'package:flame_3d/src/graphics/fullscreen_quad.dart';
import 'package:flame_3d/src/graphics/material_pipeline_cache.dart';
import 'package:flame_3d/src/graphics/material_tracker.dart';
import 'package:flame_3d/src/graphics/prefixed_uniform_block.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:meta/meta.dart';

part 'render_context_3d_depth_normal.dart';
part 'render_context_3d_oit_refraction.dart';
part 'render_context_3d_draw.dart';
part 'render_context_3d_plan.dart';
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

  /// The name of the block holding the ambient light `color` and `intensity`.
  static const String ambientLightBlock = 'AmbientLight';

  /// The name of the block holding the point lights.
  static const String lightsBlock = 'Lights';

  /// The name of the block holding the directional lights.
  static const String directionalLightsBlock = 'DirectionalLights';

  /// The name of the block holding cone spot lights.
  static const String spotLightsBlock = 'SpotLights';

  /// The name of the block holding the hemisphere light.
  static const String hemisphereLightBlock = 'HemisphereLight';

  /// The name of the block describing the light grid of the pass (see
  /// [lightGrid]): where its cells are, the size of its texture and how many
  /// of the lights of the [lightsBlock] and [spotLightsBlock] come before
  /// those the grid holds too. See `flame_3d/light_grid.glsl`.
  static const String lightGridBlock = 'LightGrid';

  /// The name of the sampler of the texture holding the light grid of the
  /// pass, see [lightGridBlock].
  static const String lightGridSampler = 'lightGridTexture';

  /// The name of the block holding the joint matrices of a skinned draw: the
  /// top three rows of each ([jointRowsMember]), or whole `mat4` matrices
  /// (`joints`) in shaders that declare them so.
  static const String jointMatricesBlock = 'JointMatrices';

  /// The member of [jointMatricesBlock] holding the top three rows of each
  /// joint matrix, `vec4 jointRows[192]` in `flame_3d/skinning.glsl`: row `r`
  /// of joint `j` is `jointRows[j * 3 + r]`. The bottom row of a joint matrix
  /// is taken to be `(0, 0, 0, 1)`, as it is for affine transforms.
  static const String jointRowsMember = 'jointRows';

  /// The name of the block describing the shadow map of the pass.
  static const String shadowsBlock = 'Shadows';

  /// The name of the block describing the unified multi-light `ShadowAtlas3D`.
  static const String shadowAtlasBlock = 'ShadowAtlas';

  /// The name of the sampler of the shadow map, see [shadowsBlock].
  static const String shadowMapSampler = 'shadowMap';

  /// The name of the block of the shaders that render shadow maps.
  static const String shadowCasterBlock = 'ShadowCaster';

  /// The name of the sampler holding the kept depths of the still casters
  /// that the moving casters are drawn over, in a shadow pass that keeps
  /// them (see [ShadowSettings.cacheStillCasters]): the texture of the view
  /// being recorded, or a white texture.
  static const String shadowStillCastersSampler = 'shadowStillCasters';

  /// The name of the block describing atmospheric fog (`FogSettings`).
  static const String fogBlock = 'Fog';

  /// The name of the block describing the body of water of the pass
  /// (`WaterVolumeSettings`), see `flame_3d/water_volume.glsl`.
  static const String waterVolumeBlock = 'WaterVolume';

  /// The name of the block describing the half-res scene depth-normal prepass.
  static const String depthNormalBlock = 'DepthNormal';

  /// The name of the sampler providing the half-res depth-normal texture.
  static const String depthNormalSampler = 'depthNormalTexture';

  /// The name of the block describing the opaque scene-color grab pass.
  static const String sceneColorBlock = 'SceneColor';

  /// The name of the sampler providing the opaque scene-color grab texture.
  static const String sceneColorSampler = 'sceneColorTexture';

  /// The name of the shared `64x64` split-sum GGX BRDF LUT sampler.
  static const String brdfLutSampler = 'brdfLutTexture';

  /// The name of the 3D `LightProbeGrid3D` volume strip sampler.
  static const String probeGridSampler = 'probeGridTexture';

  /// The name of the block carrying HDR, debug mode, local reflection probe box
  /// and 3D light-probe grid uniforms for `SpatialMaterial`.
  static const String passOptionsBlock = 'PassOptions';

  /// The name of the block in which `StylizedMaterial`'s fragment shader
  /// reads the camera, the lights, the shadows, the fog and the water volume
  /// of the pass.
  @internal
  static const String stylizedPassBlock = 'StylizedPass';

  /// The name of the consolidated pass block in which `SpatialMaterial`'s
  /// PBR fragment shaders read pass-level camera, options, lighting, light
  /// grid, shadows, and fog uniforms.
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

  /// The maximum number of point lights written to the [lightsBlock].
  static const int maxPointLights = 8;

  /// The maximum number of directional lights written to the
  /// [directionalLightsBlock].
  static const int maxDirectionalLights = 4;

  /// The maximum number of spot lights written to the [spotLightsBlock].
  static const int maxSpotLights = 4;

  /// The model matrix of the draw being submitted.
  Matrix4 get model => _modelMatrix;
  final Matrix4 _modelMatrix = Matrix4.identity();

  /// The camera's view matrix for the current pass.
  Matrix4 get view => _viewMatrix;
  final Matrix4 _viewMatrix = Matrix4.identity();

  /// The camera's projection matrix for the current pass.
  Matrix4 get projection => _projectionMatrix;
  final Matrix4 _projectionMatrix = Matrix4.identity();

  /// `projection * view` for the current pass.
  Matrix4 get viewProjection => _viewProjectionMatrix;
  final Matrix4 _viewProjectionMatrix = Matrix4.identity();

  /// Camera world-space position, computed from the view matrix by
  /// [setCamera].
  ///
  /// In a shadow pass this is the origin of the light's view, not a viewer:
  /// choose level of detail and distance culling from [viewerPosition].
  Vector3 get cameraPosition => _cameraPosition;
  final Vector3 _cameraPosition = Vector3.zero();

  /// The world-space position of the viewer that level of detail and
  /// distance culling choose detail from.
  ///
  /// The same as [cameraPosition] in a camera pass. While a shadow pass
  /// records ([isShadowPass]), it stays the position of the main camera that
  /// was set when the shadow pass began, so shadow casters draw the geometry
  /// the main pass shows instead of geometry chosen around the light's view
  /// origin.
  Vector3 get viewerPosition =>
      _shadows.recording ? _shadowViewerPosition : _cameraPosition;
  final Vector3 _shadowViewerPosition = Vector3.zero();

  /// The `projection * view` matrix of the viewer of [viewerPosition]: the
  /// same as [viewProjection] in a camera pass, the main camera's while a
  /// shadow pass records. Use it to measure the screen size of an object for
  /// level of detail.
  Matrix4 get viewerViewProjection =>
      _shadows.recording ? _shadowViewerViewProjection : _viewProjectionMatrix;
  final Matrix4 _shadowViewerViewProjection = Matrix4.identity();

  /// The view frustum of the current pass, in world space.
  Frustum get frustum => _frustum;
  final Frustum _frustum = Frustum();

  /// Whether the camera of the current pass mirrors the scene.
  bool get isMirrored => _isMirrored;
  bool _isMirrored = false;

  /// The front-face winding for the current pass.
  WindingOrder get frontFace =>
      _isMirrored ? WindingOrder.clockwise : WindingOrder.counterClockwise;

  /// Monotonically incremented whenever the main viewer camera changes
  /// outside shadow rendering, used by LODs and view-dependent caches.
  int get viewerEpoch => _viewerEpoch;
  int _viewerEpoch = 0;

  /// The joint matrices of the draw [Material.apply] runs for, or `null` when
  /// it is not skinned.
  List<Matrix4>? get jointTransforms => _jointTransforms;
  List<Matrix4>? _jointTransforms;

  /// The lights of the scene. Must be set before the draws are flushed.
  List<Light> get lights => _lights;
  set lights(List<Light> value) {
    _lights = value;
    _worldLightsVersion = null;
    _syncedLightRev = -1;
    _syncedOwner = null;
  }

  List<Light> _lights = const [];
  int? _worldLightsVersion;
  Object? _syncedOwner;

  /// World lights revision last supplied by [setWorldLights], or `null` when
  /// [lights] was assigned directly.
  @internal
  int? get worldLightsVersion => _worldLightsVersion;

  /// Owner that last synchronized options onto this context via
  /// [needsSyncOptions].
  @internal
  Object? get syncedOwner => _syncedOwner;

  /// Sets [lights] together with the enclosing [World3D.lightsVersion] so
  /// light-grid builds can skip unchanged passes in O(1).
  @internal
  void setWorldLights(List<Light> value, int lightsVersion) {
    _lights = value;
    _worldLightsVersion = lightsVersion;
  }

  /// How the passes shade more point and spot lights than the
  /// [lightsBlock] and [spotLightsBlock] hold, or `null` (the default) to
  /// leave the lights beyond those out, see [LightGridSettings].
  /// `World3D.lightGrid` sets it.
  LightGridSettings? lightGrid;

  /// What the light grid of the last pass that read one held, see
  /// [LightGridStats].
  LightGridStats get lightGridStats => _lightGrid.stats;

  /// The world bounds of everything the pass draws, or `null` (the default)
  /// when they are not known: the [lightGrid] covers only them.
  /// `World3D` sets its `sceneBounds`, unless it holds a component that may
  /// draw outside them.
  Aabb3? lightGridBounds;

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

  /// Active local box-projected `ReflectionProbeVolume3D`s of the scene.
  List<ReflectionProbeVolume3D> reflectionProbes = const [];

  /// 32-bit layer bitmask filtering `Object3D.cameraMask` and `Light.lightMask`
  /// for the current pass (`0xFFFFFFFF` renders all layers by default).
  int cameraMask = 0xFFFFFFFF;

  /// The number of draws recorded in the last flushed pass.
  int get drawCount => _lastDrawCount;
  int _lastDrawCount = 0;

  /// Notes the materials bound while a world renders, so that its version
  /// follows their changes; set by the world for its render.
  @internal
  MaterialTracker? materialTracker;

  final Float64List _depthRow = Float64List(4);

  final Map<String, PassUniformWriter> _passUniforms = {};
  final Map<String, PassTextureProvider> _passTextures = {};
  final Map<String, int> _customWriterKinds = {};
  int _passUniformsVersion = 0;
  int _pass = 0;
  int _cameraPass = 0;
  int _nextPassEpoch = 1;
  final Int32List _passKindEpochs = Int32List(_passKindCount)
    ..fillRange(0, _passKindCount, 1);

  @internal
  int get cameraPass => _cameraPass;

  Shader? _activeApplyVertexShader;

  /// Vertex shader variant for which `Material.apply` is currently running,
  /// or `null` outside `_applyMaterial`.
  @internal
  Shader? get activeApplyVertexShader => _activeApplyVertexShader;

  void _bumpAllPassKinds() {
    _pass++;
    final epoch = ++_nextPassEpoch;
    for (var k = 0; k < _passKindCount; k++) {
      _passKindEpochs[k] = epoch;
    }
  }

  void _bumpSceneColorUniforms() {
    final epoch = ++_nextPassEpoch;
    _passKindEpochs[_passKindSceneColor] = epoch;
    _passKindEpochs[_passKindPassOptions] = epoch;
    _passKindEpochs[_passKindSpatial] = epoch;
    _passKindEpochs[_passKindCustom] = epoch;
  }

  /// Bumps only `PassOptions`, `SpatialPass`, and custom pass blocks (without
  /// invalidating camera, light, fog, or stylized pass caches).
  @internal
  void bumpPassOptionsUniforms() {
    final epoch = ++_nextPassEpoch;
    _passKindEpochs[_passKindPassOptions] = epoch;
    _passKindEpochs[_passKindSpatial] = epoch;
    _passKindEpochs[_passKindCustom] = epoch;
  }

  /// Bumps the pass uniform epoch when per-pass state (such as `hdrEnabled`,
  /// `renderDebugMode`, `SceneColor`, or `lightProbeGrid`) changes after
  /// [setCamera] was called.
  void bumpPassUniforms() {
    _bumpAllPassKinds();
  }

  /// The uniform blocks filled once per render pass, by block name.
  Map<String, PassUniformWriter> get passUniforms =>
      Map.unmodifiable(_passUniforms);

  /// Registers [writer] to fill every uniform block named [name] once per
  /// render pass, for every shader that declares it.
  void registerPassUniform(String name, PassUniformWriter? writer) {
    if (writer == null) {
      _passUniforms.remove(name);
      _customWriterKinds.remove(name);
    } else {
      _passUniforms[name] = writer;
      final defaultKind = _defaultPassKindFor(name, writer);
      if (defaultKind > 0) {
        _customWriterKinds.remove(name);
      } else {
        _customWriterKinds[name] = 1;
      }
    }
    _passUniformsVersion++;
  }

  /// Registers [provider] to give the texture of every sampler named [name],
  /// once per render pass, for every shader that declares it.
  void registerPassTexture(String name, PassTextureProvider? provider) {
    if (provider == null) {
      _passTextures.remove(name);
    } else {
      _passTextures[name] = provider;
    }
    _passUniformsVersion++;
  }

  /// Set the camera matrices for the next pass.
  void setCamera(Matrix4 viewMatrix, Matrix4 projectionMatrix) {
    _bumpAllPassKinds();
    _cameraPass++;
    if (!_shadows.recording) {
      _viewerEpoch++;
    }
    _shadows
      ..active = false
      ..atlasActive = false;
    _viewMatrix.setFrom(viewMatrix);
    _projectionMatrix.setFrom(projectionMatrix);
    _viewProjectionMatrix
      ..setFrom(projectionMatrix)
      ..multiply(viewMatrix);
    _inverseView.copyInverse(viewMatrix);
    _cameraPosition.setValues(
      _inverseView.storage[12],
      _inverseView.storage[13],
      _inverseView.storage[14],
    );
    _frustum.setFromViewProjection(_viewProjectionMatrix);

    final m = _viewProjectionMatrix.storage;
    final perspective = m[3] * m[3] + m[7] * m[7] + m[11] * m[11] > 1e-12;
    final depthRow = perspective ? 3 : 2;
    for (var i = 0; i < 4; i++) {
      _depthRow[i] = m[i * 4 + depthRow];
    }
    _isMirrored = mirrors(_viewProjectionMatrix);
  }

  final Matrix4 _inverseView = Matrix4.identity();

  static bool mirrors(Matrix4 m) {
    final s = m.storage;
    final perspective = s[3] * s[3] + s[7] * s[7] + s[11] * s[11] > 1e-12;
    final r = perspective ? 3 : 2;
    final det =
        s[0] * (s[5] * s[8 + r] - s[9] * s[4 + r]) -
        s[4] * (s[1] * s[8 + r] - s[9] * s[r]) +
        s[8] * (s[1] * s[4 + r] - s[5] * s[r]);
    return det > 0;
  }

  int _activePrepassGroup = 0;
  int _nextPrepassGroupId = 1;

  // The prepass groups of Material.depthPrepassGroup keys in this pass: the
  // key, the group and the sort depth of each, the first [_sharedGroupCount]
  // entries in use (the lists are reused from pass to pass).
  final List<Object?> _sharedGroupKeys = [];
  final List<int> _sharedGroupIds = [];
  final List<double> _sharedGroupDepths = [];
  int _sharedGroupCount = 0;

  int _prepassGroupNesting = 0;
  double _prepassGroupDepth = double.nan;
  bool _depthPrepassOverride = false;

  /// Groups all translucent draws with [RenderState.depthPrepass] recorded
  /// before the matching [endDepthPrepassGroup] into a single cohesive depth
  /// prepass followed by a single `lessEqual` shaded pass.
  void beginDepthPrepassGroup() {
    if (_prepassGroupNesting++ == 0) {
      _activePrepassGroup = _nextPrepassGroupId++;
      _prepassGroupDepth = double.nan;
    }
  }

  /// Ends a group started by [beginDepthPrepassGroup].
  void endDepthPrepassGroup() {
    if (--_prepassGroupNesting <= 0) {
      _prepassGroupNesting = 0;
      _activePrepassGroup = 0;
      _prepassGroupDepth = double.nan;
    }
  }

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
    final i = _count;
    if (i == _capacity) {
      _grow();
    }
    _count++;

    _surfaces[i] = surface;
    _materials[i] = drawMaterial;
    _joints[i] = jointTransforms != null && jointTransforms.isNotEmpty
        ? jointTransforms
        : null;
    _external[i] = null;

    final m = (transform ?? _modelMatrix).storage;
    final base = i * VertexLayout.instanceStrideInFloats;
    final instances = _instances..setRange(base, base + 16, m);

    if (shadowPass) {
      _pipelines[i] = null;
      _vertexShaders[i] = null;
      _fragmentShaders[i] = null;
      _mirrored[i] = 0;
      _probeSlots[i] = 0;
      _probeWeights[i] = 0;
      _prepassGroups[i] = 0;
      _depths[i] = 0;
      RenderProfile.lap(RenderPhase.recording);
      return;
    }

    if (depthNormalPass) {
      if (hasDepthNormalMat) {
        _writeInstanceColorAndData(instances, base, color, instanceData);
      }
      _pipelines[i] = null;
      _vertexShaders[i] = null;
      _fragmentShaders[i] = null;
      _mirrored[i] = 0;
      _probeSlots[i] = 0;
      _probeWeights[i] = 0;
      _prepassGroups[i] = 0;
      final center = surface.aabbCenter;
      final cx = center.x;
      final cy = center.y;
      final cz = center.z;
      final wx = m[0] * cx + m[4] * cy + m[8] * cz + m[12];
      final wy = m[1] * cx + m[5] * cy + m[9] * cz + m[13];
      final wz = m[2] * cx + m[6] * cy + m[10] * cz + m[14];
      final d = _depthRow;
      _depths[i] = d[0] * wx + d[1] * wy + d[2] * wz + d[3];
      RenderProfile.lap(RenderPhase.recording);
      return;
    }

    if (_cachedOpaqueCount >= 0 || _oitGrab.hasSortCache) {
      _cachedOpaqueCount = -1;
      _oitGrab.resetSortCache();
    }
    if (drawMaterial.renderState.translucent) {
      _hasRecordedTranslucent = true;
    }
    if (!_hasRecordedRefractive &&
        drawMaterial is SpatialMaterial &&
        drawMaterial.transmission > 1e-4) {
      _hasRecordedRefractive = true;
    }

    _resolvePipeline(drawMaterial, surface.layout);
    _pipelines[i] = _lastPipeDev;
    _vertexShaders[i] = _lastPipeVert;
    _fragmentShaders[i] = _lastPipeFrag;

    if (mirrored != null) {
      _mirrored[i] = mirrored ? 1 : 0;
    } else {
      final determinant =
          m[0] * (m[5] * m[10] - m[6] * m[9]) -
          m[4] * (m[1] * m[10] - m[2] * m[9]) +
          m[8] * (m[1] * m[6] - m[2] * m[5]);
      _mirrored[i] = determinant < 0 ? 1 : 0;
    }

    _writeInstanceColorAndData(instances, base, color, instanceData);

    final center = surface.aabbCenter;
    final cx = center.x;
    final cy = center.y;
    final cz = center.z;
    final wx = m[0] * cx + m[4] * cy + m[8] * cz + m[12];
    final wy = m[1] * cx + m[5] * cy + m[9] * cz + m[13];
    final wz = m[2] * cx + m[6] * cy + m[10] * cz + m[14];
    if (reflectionProbes.isNotEmpty && drawMaterial.usesReflectionProbes) {
      _selectProbeFor(i, wx, wy, wz);
    } else {
      _probeSlots[i] = 0;
      _probeWeights[i] = 0;
    }
    final d = _depthRow;
    var depth = d[0] * wx + d[1] * wy + d[2] * wz + d[3];
    if (drawMaterial.renderState.translucent &&
        drawMaterial.renderState.depthPrepass) {
      if (drawMaterial.depthPrepassGroup case final key?) {
        depth = _joinSharedPrepassGroup(i, key, depth);
      } else if (_activePrepassGroup != 0) {
        if (_prepassGroupDepth.isNaN) {
          _prepassGroupDepth = depth;
        } else {
          depth = _prepassGroupDepth;
        }
        _prepassGroups[i] = _activePrepassGroup;
      } else {
        _prepassGroups[i] = _nextPrepassGroupId++;
      }
    } else {
      _prepassGroups[i] = 0;
    }
    _depths[i] = depth;
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
      _resolvePipeline(drawMaterial, surface.layout);
      pipeline = _lastPipeDev!;
      vertShader = _lastPipeVert!;
      fragShader = _lastPipeFrag!;
      if (!pipeline.instanced) {
        throw StateError(
          'drawInstances needs a material whose vertex shader reads the '
          'instance inputs (the four instanceModel columns)',
        );
      }
    }
    final i = _count;
    if (i == _capacity) {
      _grow();
    }
    _count++;

    _surfaces[i] = surface;
    _materials[i] = drawMaterial;
    _pipelines[i] = pipeline;
    _vertexShaders[i] = vertShader;
    _fragmentShaders[i] = fragShader;
    _joints[i] = jointTransforms != null && jointTransforms.isNotEmpty
        ? jointTransforms
        : null;
    _mirrored[i] = mirrored ? 1 : 0;
    _external[i] = instances;
    _externalCounts[i] = count;
    _externalOffsets[i] = instanceOffset * VertexLayout.instanceStrideInFloats;
    _externalVersions[i] = instanceVersion ?? -1;
    _externalCacheSpans[i] = instanceBufferCount ?? 0;

    if (shadowPass) {
      _probeSlots[i] = 0;
      _probeWeights[i] = 0;
      _prepassGroups[i] = 0;
      _depths[i] = 0;
      RenderProfile.lap(RenderPhase.recording);
      return;
    }

    final d = _depthRow;
    if (depthNormalPass) {
      _probeSlots[i] = 0;
      _probeWeights[i] = 0;
      _prepassGroups[i] = 0;
      _depths[i] = center == null
          ? d[3]
          : d[0] * center.x + d[1] * center.y + d[2] * center.z + d[3];
      RenderProfile.lap(RenderPhase.recording);
      return;
    }

    if (_cachedOpaqueCount >= 0 || _oitGrab.hasSortCache) {
      _cachedOpaqueCount = -1;
      _oitGrab.resetSortCache();
    }
    if (drawMaterial.renderState.translucent) {
      _hasRecordedTranslucent = true;
    }
    if (!_hasRecordedRefractive &&
        drawMaterial is SpatialMaterial &&
        drawMaterial.transmission > 1e-4) {
      _hasRecordedRefractive = true;
    }

    if (reflectionProbes.isNotEmpty && drawMaterial.usesReflectionProbes) {
      final at = center ?? _cameraPosition;
      _selectProbeFor(i, at.x, at.y, at.z);
    } else {
      _probeSlots[i] = 0;
      _probeWeights[i] = 0;
    }
    _depths[i] = center == null
        ? d[3]
        : d[0] * center.x + d[1] * center.y + d[2] * center.z + d[3];
    final prepass =
        drawMaterial.renderState.translucent &&
        drawMaterial.renderState.depthPrepass;
    if (prepass && drawMaterial.depthPrepassGroup != null) {
      _depths[i] = _joinSharedPrepassGroup(
        i,
        drawMaterial.depthPrepassGroup!,
        _depths[i],
      );
    } else {
      _prepassGroups[i] = prepass
          ? (_activePrepassGroup != 0
                ? _activePrepassGroup
                : _nextPrepassGroupId++)
          : 0;
    }
    RenderProfile.lap(RenderPhase.recording);
  }

  Material? _lastPipeMat;
  VertexLayout? _lastPipeLayout;
  Shader? _lastPipeVert;
  Shader? _lastPipeFrag;
  int _lastPipeMatVer = -1;
  int _lastPipeVertGen = -1;
  int _lastPipeFragGen = -1;
  int _lastPipePass = -1;
  DevicePipeline? _lastPipeDev;

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
    _shadowViewerPosition.setFrom(_cameraPosition);
    _shadowViewerViewProjection.setFrom(_viewProjectionMatrix);
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

  late final _DepthNormalPass _depthNormal = _DepthNormalPass(this);
  late final _OitAndGrabPass _oitGrab = _OitAndGrabPass(this);

  bool _hasRecordedRefractive = false;
  bool _hasRecordedTranslucent = false;
  int _cachedOpaqueCount = -1;

  /// Whether any currently recorded draw uses a refractive `SpatialMaterial`
  /// (`transmission > 0`).
  bool get hasRefractiveDraws => _hasRecordedRefractive;

  /// Whether any currently recorded draw is translucent.
  bool get hasTranslucentDraws => _hasRecordedTranslucent;

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
    _submitBatches(_opaque, opaqueCount);
    _boundMaterial = null;
    _jointTransforms = null;
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

  /// The [ReflectionProbeVolume3D] chosen for the draw [Material.apply] runs
  /// for, or `null` when its material does not use volumes (see
  /// [Material.usesReflectionProbes]) or no volume reaches it.
  ///
  /// The volume is chosen when the draw is recorded, as
  /// [selectReflectionProbe] chooses it, at the center of the drawn surface's
  /// bounds in world space (for [drawInstances], at its `center`, or the
  /// camera position without one). Draws that get different volumes, or
  /// different weights, are not batched together.
  ReflectionProbeVolume3D? get reflectionProbe {
    final slot = _drawProbeSlot;
    return slot > 0 && slot <= reflectionProbes.length
        ? reflectionProbes[slot - 1]
        : null;
  }

  /// The weight of [reflectionProbe] at the drawn object, in `(0, 1]`
  /// (`ReflectionProbeVolume3D.weightAt`), or `0` without one.
  double get reflectionProbeWeight =>
      reflectionProbe == null ? 0.0 : _drawProbeWeight;

  @internal
  int get activeProbeSlot => _drawProbeSlot;

  @internal
  double get activeProbeWeight => _drawProbeWeight;

  int _drawProbeSlot = 0;
  double _drawProbeWeight = 0;
  int _boundProbeSlot = 0;
  double _boundProbeWeight = 0;
  bool _anyProbeDraw = false;
  bool _sortByProbe = false;

  // Per pass: the center, half extents, blend distance and priority of each
  // volume, 8 doubles per volume.
  Float64List _probeBoxes = Float64List(0);
  int _probeBoxesPass = -1;
  List<ReflectionProbeVolume3D>? _probeBoxesOf;
  int _probeBoxesCount = 0;

  /// Selects the highest-priority / highest-weight `ReflectionProbeVolume3D`
  /// influencing [worldPoint], or `null` when none covers it.
  (ReflectionProbeVolume3D, double)? selectReflectionProbe(
    Vector3 worldPoint,
  ) {
    final probes = reflectionProbes;
    if (probes.isEmpty) {
      return null;
    }
    ReflectionProbeVolume3D? best;
    var bestWeight = 0.0;
    var bestPriority = -0x7FFFFFFF;
    for (var i = 0; i < probes.length; i++) {
      final p = probes[i];
      final w = p.weightAt(worldPoint);
      if (w <= 1e-4) {
        continue;
      }
      if (best == null ||
          p.priority > bestPriority ||
          (p.priority == bestPriority && w > bestWeight)) {
        best = p;
        bestWeight = w;
        bestPriority = p.priority;
      }
    }
    return best != null ? (best, bestWeight) : null;
  }

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

  late final _ShadowPass _shadows = _ShadowPass(this);

  /// Submit all queued draws.
  void flush() => _flushDraws();

  Material? _boundMaterial;
  int _bindingEpoch = -1;

  // The order-independent transparency pass draws are submitted for, see
  // `_OitAndGrabPass`.
  int _oitPass = _OitAndGrabPass.noPass;

  // The render states derived from material render states, created once.
  final Map<RenderState, RenderState> _depthOnlyStates = {};
  final Map<RenderState, RenderState> _prepassShadedStates = {};
  final Map<RenderState, RenderState> _wireframeStates = {};

  final Int32List _sharedPassEpochs = Int32List(_passKindCount)
    ..fillRange(0, _passKindCount, -1);
  final Int32List _sharedPassFrames = Int32List(_passKindCount)
    ..fillRange(0, _passKindCount, -1);
  final Int32List _sharedPassSigs = Int32List(_passKindCount);
  final List<GpuBuffer?> _sharedPassBuffers = List.filled(_passKindCount, null);
  final Int32List _sharedPassOffsets = Int32List(_passKindCount);
  final Int32List _sharedPassLengths = Int32List(_passKindCount);

  final Map<GpuUniformSlot, UniformBlock> _passBlocks = {};
  final Map<GpuUniformSlot, UniformBlock> _jointBlocks = {};

  final Map<UniformBlock, List<UniformBlock>> _stylizedPassViews = {};
  final Map<UniformBlock, List<UniformBlock>> _spatialPassViews = {};

  Float32List _jointPackScratch = Float32List(1024);
  late Uint8List _jointPackBytes = _jointPackScratch.buffer.asUint8List();
  int _jointPackDirtyStart = 0;
  int _jointPackDirtyEnd = 0;
  int _jointCacheFrame = -1;
  static const int _jointHashTableSize = 512;
  static const int _jointHashTableMask = _jointHashTableSize - 1;
  static const int _maxJointCacheEntries = 256;
  final List<_JointUploadEntry?> _jointHashTable = List.filled(
    _jointHashTableSize,
    null,
  );
  final Int32List _jointHashUsed = Int32List(_maxJointCacheEntries);
  int _jointHashCount = 0;
  final List<_JointUploadEntry> _jointCachePool = [];

  int _viewerPass = -1;
  double _viewerX = 0;
  double _viewerY = 0;
  double _viewerZ = 0;
  double _viewerW = 1;
  final Matrix4 _inverseViewProj = Matrix4.zero();

  /// Writes the viewer's world-space center of projection (`w = 1`) or
  /// parallel direction (`w = 0`) for the current camera pass, cached once per
  /// [_cameraPass].
  @internal
  void writeViewerTo(UniformBlock block, int offset) {
    if (_viewerPass != _cameraPass) {
      _viewerPass = _cameraPass;
      final inverse = _inverseViewProj..setFrom(_viewProjectionMatrix);
      final determinant = inverse.invert();
      final s = inverse.storage;
      final x = s[8];
      final y = s[9];
      final z = s[10];
      final w = s[11];
      final length = math.sqrt(x * x + y * y + z * z);
      if (determinant == 0 || !(length > 0)) {
        _viewerX = _cameraPosition.x;
        _viewerY = _cameraPosition.y;
        _viewerZ = _cameraPosition.z;
        _viewerW = 1;
      } else if (w.abs() > 1e-9 * length) {
        _viewerX = x / w;
        _viewerY = y / w;
        _viewerZ = z / w;
        _viewerW = 1;
      } else {
        _viewerX = -x / length;
        _viewerY = -y / length;
        _viewerZ = -z / length;
        _viewerW = 0;
      }
    }
    block.writeVec4ValuesAt(offset, _viewerX, _viewerY, _viewerZ, _viewerW);
  }

  static void writeCameraUniforms(
    RenderContext3D context,
    UniformBlock block,
  ) => _writeCameraUniforms(context, block);

  int _lightSelPass = -1;
  List<Light>? _lightSelList;
  int _lightSelLength = -1;
  int _lightSelMask = 0;
  AmbientLight? _selAmbient;
  bool _selHasHemisphere = false;
  HemisphereLight? _selHemisphere;
  final List<Light> _selDirectionals = [];

  int _selPointPass = -1;
  List<Light>? _selPointList;
  int _selPointLength = -1;
  int _selPointMask = 0;
  bool _selPointPrioritize = false;
  LightGridSettings? _selPointGrid;
  int _selPointCount = 0;
  final Int32List _selPointIndices = Int32List(maxPointLights);

  int _selSpotPass = -1;
  List<Light>? _selSpotList;
  int _selSpotLength = -1;
  int _selSpotMask = 0;
  LightGridSettings? _selSpotGrid;
  int _selSpotCount = 0;
  final Int32List _selSpotIndices = Int32List(maxSpotLights);

  static void writeAmbientLightUniforms(
    RenderContext3D context,
    UniformBlock block,
  ) => _writeAmbientLightUniforms(context, block);

  bool prioritizeNearestLights = false;

  // Which lights a selection picks among: all, those a light grid cannot
  // hold, or those it can (see LightGrid3D.binnable).

  final LightGrid3D _lightGrid = LightGrid3D();

  // The plan of the pass for its lights beyond the blocks: whether its point
  // (and spot) lights go into the light grid, and how many lights of the
  // blocks come before those the grid holds too. Made once per pass.
  int _gridPlanPass = -1;
  List<Light>? _gridPlanLights;
  int _gridPlanMask = 0;
  LightGridSettings? _gridPlanSettings;
  bool _gridPlanPrioritize = false;
  bool _gridPoints = false;
  bool _gridSpots = false;
  int _gridUniformPoints = maxPointLights;
  int _gridUniformSpots = maxSpotLights;
  int _gridBuiltPass = -1;

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

  int _syncedLightRev = -1;
  int _syncedFogVer = -1;
  int _syncedWaterVer = -1;
  double _syncedProbeIntensity = -1.0;

  @internal
  bool needsSyncOptions({
    required List<Light> lights,
    required int lightsVersion,
    required FogSettings? fog,
    required WaterVolumeSettings? waterVolume,
    required RenderDebugMode3D renderDebugMode,
    required LightProbeGrid3D? lightProbeGrid,
    required List<ReflectionProbeVolume3D> reflectionProbes,
    required bool prioritizeNearestLights,
    required LightGridSettings? lightGrid,
    required Aabb3? lightGridBounds,
    required bool hdrEnabled,
    Object? owner,
  }) {
    final fogVer = fog?.version ?? -1;
    final waterVer = waterVolume?.version ?? -1;
    final probeIntensity = lightProbeGrid?.intensity ?? -1.0;
    if (_syncedLightRev == lightsVersion &&
        identical(_syncedOwner, owner) &&
        identical(this.lights, lights) &&
        identical(this.fog, fog) &&
        _syncedFogVer == fogVer &&
        identical(this.waterVolume, waterVolume) &&
        _syncedWaterVer == waterVer &&
        this.renderDebugMode == renderDebugMode &&
        identical(this.lightProbeGrid, lightProbeGrid) &&
        _syncedProbeIntensity == probeIntensity &&
        identical(this.reflectionProbes, reflectionProbes) &&
        this.prioritizeNearestLights == prioritizeNearestLights &&
        identical(this.lightGrid, lightGrid) &&
        this.lightGridBounds == lightGridBounds &&
        this.hdrEnabled == hdrEnabled) {
      return false;
    }
    _syncedOwner = owner;
    _syncedLightRev = lightsVersion;
    _syncedFogVer = fogVer;
    _syncedWaterVer = waterVer;
    _syncedProbeIntensity = probeIntensity;
    return true;
  }

  int _count = 0;
  int _capacity = 0;
  List<Surface?> _surfaces = [];
  List<Material?> _materials = [];
  List<DevicePipeline?> _pipelines = [];
  List<Shader?> _vertexShaders = [];
  List<Shader?> _fragmentShaders = [];
  List<List<Matrix4>?> _joints = [];
  List<Float32List?> _external = [];
  Int32List _externalCounts = Int32List(0);
  Int32List _externalOffsets = Int32List(0);
  Int32List _externalVersions = Int32List(0);
  Int32List _externalCacheSpans = Int32List(0);
  Float32List _instances = Float32List(0);
  Float64List _depths = Float64List(0);
  Float64List _groupKeys = Float64List(0);
  Uint8List _mirrored = Uint8List(0);
  Int32List _surfaceKeys = Int32List(0);
  Int32List _prepassGroups = Int32List(0);
  Int32List _probeSlots = Int32List(0);
  Float64List _probeWeights = Float64List(0);
  Int32List _opaque = Int32List(0);
  Int32List _translucent = Int32List(0);
  Int32List _sortScratch = Int32List(0);
  Float64List _sortDepths = Float64List(0);
}
