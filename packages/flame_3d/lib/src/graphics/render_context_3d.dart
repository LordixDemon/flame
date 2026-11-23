import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flame_3d/camera.dart';
import 'package:flame_3d/game.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/src/extensions/clip_space.dart';
import 'package:flame_3d/src/graphics/material_pipeline_cache.dart';
import 'package:flame_3d/src/graphics/material_tracker.dart';
import 'package:flame_3d/src/graphics/prefixed_uniform_block.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:meta/meta.dart';

part 'render_context_3d_depth_normal.dart';
part 'render_context_3d_oit_refraction.dart';
part 'render_context_3d_shadows.dart';

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
  }

  List<Light> _lights = const [];
  int? _worldLightsVersion;

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

  @internal
  int get cameraPass => _cameraPass;

  /// Bumps the pass uniform epoch when per-pass state (such as `hdrEnabled`,
  /// `renderDebugMode`, `SceneColor`, or `lightProbeGrid`) changes after
  /// [setCamera] was called.
  void bumpPassUniforms() {
    _pass++;
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
    _pass++;
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

  void _saveCameraSnapshot(_CameraSnapshot out) {
    out.view.setFrom(_viewMatrix);
    out.projection.setFrom(_projectionMatrix);
    out.viewProjection.setFrom(_viewProjectionMatrix);
    out.cameraPosition.setFrom(_cameraPosition);
    out.depthRow.setAll(0, _depthRow);
    out.isMirrored = _isMirrored;
    _copyFrustum(out.frustum, _frustum);
  }

  void _restoreCameraSnapshot(
    _CameraSnapshot snap, {
    required bool active,
    required bool atlasActive,
  }) {
    _pass++;
    _cameraPass++;
    _shadows
      ..active = active
      ..atlasActive = atlasActive;
    _viewMatrix.setFrom(snap.view);
    _projectionMatrix.setFrom(snap.projection);
    _viewProjectionMatrix.setFrom(snap.viewProjection);
    _cameraPosition.setFrom(snap.cameraPosition);
    _depthRow.setAll(0, snap.depthRow);
    _isMirrored = snap.isMirrored;
    _copyFrustum(_frustum, snap.frustum);
  }

  static void _copyFrustum(Frustum dst, Frustum src) {
    dst.plane0
      ..normal.setFrom(src.plane0.normal)
      ..constant = src.plane0.constant;
    dst.plane1
      ..normal.setFrom(src.plane1.normal)
      ..constant = src.plane1.constant;
    dst.plane2
      ..normal.setFrom(src.plane2.normal)
      ..constant = src.plane2.constant;
    dst.plane3
      ..normal.setFrom(src.plane3.normal)
      ..constant = src.plane3.constant;
    dst.plane4
      ..normal.setFrom(src.plane4.normal)
      ..constant = src.plane4.constant;
    dst.plane5
      ..normal.setFrom(src.plane5.normal)
      ..constant = src.plane5.constant;
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

  /// Puts draw [i] in the prepass group of [key] (made at its first draw in
  /// the pass) and returns the sort depth the group's draws share, that of
  /// its first draw ([depth] for it).
  double _joinSharedPrepassGroup(int i, Object key, double depth) {
    for (var k = 0; k < _sharedGroupCount; k++) {
      if (identical(_sharedGroupKeys[k], key)) {
        _prepassGroups[i] = _sharedGroupIds[k];
        return _sharedGroupDepths[k];
      }
    }
    final id = _nextPrepassGroupId++;
    if (_sharedGroupCount == _sharedGroupKeys.length) {
      _sharedGroupKeys.add(key);
      _sharedGroupIds.add(id);
      _sharedGroupDepths.add(depth);
    } else {
      _sharedGroupKeys[_sharedGroupCount] = key;
      _sharedGroupIds[_sharedGroupCount] = id;
      _sharedGroupDepths[_sharedGroupCount] = depth;
    }
    _sharedGroupCount++;
    _prepassGroups[i] = id;
    return depth;
  }

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
      _mirrored[i] = 0;
      _probeSlots[i] = 0;
      _probeWeights[i] = 0;
      _prepassGroups[i] = 0;
      _depths[i] = 0;
      RenderProfile.lap(RenderPhase.recording);
      return;
    }

    final (pipeline, vertShader, fragShader) = _pipelineTripleFor(
      drawMaterial,
      surface.layout,
    );
    _pipelines[i] = pipeline;
    _vertexShaders[i] = vertShader;
    _fragmentShaders[i] = fragShader;

    if (mirrored != null) {
      _mirrored[i] = mirrored ? 1 : 0;
    } else {
      final determinant =
          m[0] * (m[5] * m[10] - m[6] * m[9]) -
          m[4] * (m[1] * m[10] - m[2] * m[9]) +
          m[8] * (m[1] * m[6] - m[2] * m[5]);
      _mirrored[i] = determinant < 0 ? 1 : 0;
    }

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
    if (_shadows.recording) {
      drawMaterial.wasRecorded = true;
    }
    if (_shadows.recording &&
        (!drawMaterial.castsShadows ||
            !drawMaterial.instancesHoldModelMatrices)) {
      return;
    }
    final (pipeline, vertShader, fragShader) = _pipelineTripleFor(
      drawMaterial,
      surface.layout,
    );
    if (!pipeline.instanced) {
      throw StateError(
        'drawInstances needs a material whose vertex shader reads the '
        'instance inputs (the four instanceModel columns)',
      );
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

    if (!_shadows.recording &&
        reflectionProbes.isNotEmpty &&
        drawMaterial.usesReflectionProbes) {
      final at = center ?? _cameraPosition;
      _selectProbeFor(i, at.x, at.y, at.z);
    } else {
      _probeSlots[i] = 0;
      _probeWeights[i] = 0;
    }
    final d = _depthRow;
    _depths[i] = center == null
        ? d[3]
        : d[0] * center.x + d[1] * center.y + d[2] * center.z + d[3];
    final prepass =
        !_shadows.recording &&
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
  DevicePipeline? _lastPipeDev;

  DevicePipeline _pipelineFor(Material material, VertexLayout layout) =>
      _pipelineTripleFor(material, layout).$1;

  (DevicePipeline, Shader, Shader) _pipelineTripleFor(
    Material material,
    VertexLayout layout,
  ) {
    final matVer = material.version;
    if (identical(material, _lastPipeMat) &&
        identical(layout, _lastPipeLayout) &&
        matVer == _lastPipeMatVer &&
        _lastPipeDev != null &&
        _lastPipeVertGen == _lastPipeVert!.generation &&
        _lastPipeFragGen == _lastPipeFrag!.generation &&
        identical(material.fragmentShaderFor(this, layout), _lastPipeFrag)) {
      return (_lastPipeDev!, _lastPipeVert!, _lastPipeFrag!);
    }

    final vertexShader = material.vertexShaderFor(layout);
    final fragmentShader = material.fragmentShaderFor(this, layout);
    vertexShader.resource;
    fragmentShader.resource;
    final cache = material.pipelineCache;
    DevicePipeline pipeline;
    if (cache != null &&
        identical(cache.device, device) &&
        identical(cache.layout, layout) &&
        cache.vertexGeneration == vertexShader.generation &&
        cache.fragmentGeneration == fragmentShader.generation &&
        identical(cache.vertexShader, vertexShader) &&
        identical(cache.fragmentShader, fragmentShader)) {
      pipeline = cache.pipeline;
    } else {
      pipeline = device.pipelineFor(vertexShader, fragmentShader, layout);
      material.wasRecorded = true;
      material.pipelineCache = MaterialPipelineCache(
        device: device,
        layout: layout,
        vertexShader: vertexShader,
        fragmentShader: fragmentShader,
        vertexGeneration: vertexShader.generation,
        fragmentGeneration: fragmentShader.generation,
        pipeline: pipeline,
      );
    }

    _lastPipeMat = material;
    _lastPipeLayout = layout;
    _lastPipeMatVer = matVer;
    _lastPipeVert = vertexShader;
    _lastPipeFrag = fragmentShader;
    _lastPipeVertGen = vertexShader.generation;
    _lastPipeFragGen = fragmentShader.generation;
    _lastPipeDev = pipeline;
    return (pipeline, vertexShader, fragmentShader);
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

  /// Whether any currently recorded draw uses a refractive `SpatialMaterial`
  /// (`transmission > 0`).
  bool get hasRefractiveDraws {
    for (var i = 0; i < _count; i++) {
      final m = _materials[i];
      if (m is SpatialMaterial && m.transmission > 1e-4) {
        return true;
      }
    }
    return false;
  }

  /// Whether any currently recorded draw is translucent.
  bool get hasTranslucentDraws {
    for (var i = 0; i < _count; i++) {
      if (_materials[i]!.renderState.translucent) {
        return true;
      }
    }
    return false;
  }

  /// Binds [grabTarget] as the active `sceneColorTexture` for upcoming passes
  /// (`null` clears it).
  void setActiveSceneColorTarget(GpuTextureTarget? grabTarget) {
    _oitGrab.setGrabTarget(grabTarget);
    _pass++;
  }

  /// Clears any active `sceneColorTexture` binding.
  void clearActiveSceneColorTarget() {
    if (_oitGrab.grabActive) {
      _oitGrab.clearGrab();
      _pass++;
    }
  }

  /// Flushes only the currently recorded opaque draws into the active render
  /// pass while keeping all recorded draws in memory for the subsequent
  /// translucent/WBOIT pass.
  void flushOpaquePreview() {
    final count = _count;
    var opaqueCount = 0;
    for (var i = 0; i < count; i++) {
      final material = _materials[i]!;
      if (!material.renderState.translucent) {
        _opaque[opaqueCount++] = i;
        _groupKeys[i] =
            _pipelines[i]!.id * 8589934592.0 + material.id * 2.0 + _mirrored[i];
        _surfaceKeys[i] = _surfaces[i]!.id * 2 + (_joints[i] == null ? 0 : 1);
        _sortDepths[i] = _depths[i];
      }
    }
    _sortByProbe = _anyProbeDraw;
    _sort(_opaque, opaqueCount);
    _sortByProbe = false;
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

  void _ensureProbeBoxes() {
    final probes = reflectionProbes;
    if (_probeBoxesPass == _pass &&
        identical(_probeBoxesOf, probes) &&
        _probeBoxesCount == probes.length) {
      return;
    }
    if (_probeBoxes.length < probes.length * 8) {
      _probeBoxes = Float64List(probes.length * 8);
    }
    final boxes = _probeBoxes;
    for (var k = 0; k < probes.length; k++) {
      final p = probes[k];
      final box = p.worldBounds;
      final o = k * 8;
      boxes
        ..[o] = (box.min.x + box.max.x) * 0.5
        ..[o + 1] = (box.min.y + box.max.y) * 0.5
        ..[o + 2] = (box.min.z + box.max.z) * 0.5
        ..[o + 3] = (box.max.x - box.min.x) * 0.5
        ..[o + 4] = (box.max.y - box.min.y) * 0.5
        ..[o + 5] = (box.max.z - box.min.z) * 0.5
        ..[o + 6] = math.max(0.0, p.blendDistance)
        ..[o + 7] = p.priority.toDouble();
    }
    _probeBoxesPass = _pass;
    _probeBoxesOf = probes;
    _probeBoxesCount = probes.length;
  }

  @pragma('vm:prefer-inline')
  static double _probeAxisWeight(double distance, double half, double fade) {
    final t = ((half + fade - distance) / fade).clamp(0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
  }

  /// Chooses the volume of draw [i] at ([x], [y], [z]), like
  /// [selectReflectionProbe], without allocating.
  void _selectProbeFor(int i, double x, double y, double z) {
    _ensureProbeBoxes();
    final boxes = _probeBoxes;
    var best = -1;
    var bestWeight = 0.0;
    var bestPriority = 0.0;
    for (var k = 0; k < _probeBoxesCount; k++) {
      final o = k * 8;
      final fade = boxes[o + 6];
      final dx = (x - boxes[o]).abs();
      final dy = (y - boxes[o + 1]).abs();
      final dz = (z - boxes[o + 2]).abs();
      final hx = boxes[o + 3];
      final hy = boxes[o + 4];
      final hz = boxes[o + 5];
      if (dx > hx + fade || dy > hy + fade || dz > hz + fade) {
        continue;
      }
      final w = fade <= 1e-5
          ? 1.0
          : _probeAxisWeight(dx, hx, fade) *
                _probeAxisWeight(dy, hy, fade) *
                _probeAxisWeight(dz, hz, fade);
      if (w <= 1e-4) {
        continue;
      }
      final priority = boxes[o + 7];
      if (best < 0 ||
          priority > bestPriority ||
          (priority == bestPriority && w > bestWeight)) {
        best = k;
        bestWeight = w;
        bestPriority = priority;
      }
    }
    _probeSlots[i] = best + 1;
    _probeWeights[i] = best < 0 ? 0.0 : bestWeight;
    if (best >= 0) {
      _anyProbeDraw = true;
    }
  }

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

  /// Sorts the draws recorded since the last flush and submits them to the
  /// device, which must be in a render pass.
  void flush() {
    RenderProfile.lap(RenderPhase.traversal);
    if (_shadows.recording) {
      _shadows.flushCasters();
      return;
    }
    final count = _count;
    var opaqueCount = 0;
    var translucentCount = 0;
    final groupKeys = _groupKeys;
    final surfaceKeys = _surfaceKeys;
    final sortDepths = _sortDepths;
    for (var i = 0; i < count; i++) {
      final material = _materials[i]!;
      if (material.renderState.translucent) {
        _translucent[translucentCount++] = i;
        groupKeys[i] = material.translucentOrder.toDouble();
        surfaceKeys[i] = 0;
        sortDepths[i] = -_depths[i];
      } else {
        _opaque[opaqueCount++] = i;
        groupKeys[i] =
            _pipelines[i]!.id * 8589934592.0 + material.id * 2.0 + _mirrored[i];
        surfaceKeys[i] = _surfaces[i]!.id * 2 + (_joints[i] == null ? 0 : 1);
        sortDepths[i] = _depths[i];
      }
    }
    _sortByProbe = _anyProbeDraw;
    _sort(_opaque, opaqueCount);
    _sortByProbe = false;
    _sort(_translucent, translucentCount);
    RenderProfile.lap(RenderPhase.sort);

    _boundMaterial = null;
    _bindingEpoch = -1;
    _depthPrepassOverride = false;

    _submitBatches(_opaque, opaqueCount);
    _submitTranslucentBatches(_translucent, translucentCount);

    _releaseDraws(count);
    _boundMaterial = null;
    _jointTransforms = null;
    _lastDrawCount = count;
    _count = 0;
    _nextPrepassGroupId = 1;
    _activePrepassGroup = 0;
    _prepassGroupNesting = 0;
    _sharedGroupKeys.fillRange(0, _sharedGroupCount, null);
    _sharedGroupCount = 0;
    RenderProfile.lap(RenderPhase.release);
  }

  void _releaseDraws(int count) {
    _anyProbeDraw = false;
    _surfaces.fillRange(0, count, null);
    _materials.fillRange(0, count, null);
    _pipelines.fillRange(0, count, null);
    _vertexShaders.fillRange(0, count, null);
    _fragmentShaders.fillRange(0, count, null);
    _joints.fillRange(0, count, null);
    _external.fillRange(0, count, null);
  }

  void _submitBatches(Int32List order, int count, {int offset = 0}) {
    var start = offset;
    final limit = offset + count;
    while (start < limit) {
      final first = order[start];
      var end = start + 1;
      if (_pipelines[first]!.instanced &&
          _joints[first] == null &&
          _external[first] == null) {
        while (end < limit && _batchesWith(first, order[end])) {
          end++;
        }
      }
      _submit(order, start, end - start);
      start = end;
    }
  }

  void _submitTranslucentBatches(Int32List order, int count) {
    var cursor = 0;
    while (cursor < count) {
      final gid = _prepassGroups[order[cursor]];
      if (gid == 0) {
        var nextGroup = cursor + 1;
        while (nextGroup < count && _prepassGroups[order[nextGroup]] == 0) {
          nextGroup++;
        }
        _submitBatches(order, nextGroup - cursor, offset: cursor);
        cursor = nextGroup;
        continue;
      }

      var groupEnd = cursor + 1;
      while (groupEnd < count && _prepassGroups[order[groupEnd]] == gid) {
        groupEnd++;
      }
      final span = groupEnd - cursor;
      _depthPrepassOverride = true;
      _submitBatches(order, span, offset: cursor);
      _depthPrepassOverride = false;
      _submitBatches(order, span, offset: cursor);
      cursor = groupEnd;
    }
  }

  bool _batchesWith(int first, int other) {
    return identical(_surfaces[first], _surfaces[other]) &&
        identical(_materials[first], _materials[other]) &&
        identical(_pipelines[first], _pipelines[other]) &&
        _mirrored[first] == _mirrored[other] &&
        _probeSlots[first] == _probeSlots[other] &&
        _probeWeights[first] == _probeWeights[other] &&
        _joints[other] == null &&
        _external[other] == null;
  }

  void _submit(Int32List order, int start, int count) {
    final first = order[start];
    final surface = _surfaces[first]!;
    final material = _materials[first]!;
    final pipeline = _pipelines[first]!;
    final vertexShader =
        _vertexShaders[first] ?? material.vertexShaderFor(surface.layout);
    final fragmentShader =
        _fragmentShaders[first] ??
        material.fragmentShaderFor(this, surface.layout);
    RenderProfile.lap(RenderPhase.batch);

    final joints = _joints[first];
    device.bindPipeline(pipeline);
    if (device.bindingEpoch != _bindingEpoch) {
      _bindingEpoch = device.bindingEpoch;
      _boundMaterial = null;
      _bindPassSlots(
        material,
        vertexShader,
        fragmentShader: fragmentShader,
        skipJoints: pipeline.instanced && joints != null,
      );
    }
    final baseState = material.renderState;
    var effectiveState = _depthPrepassOverride
        ? _depthOnlyStates[baseState] ??= RenderState(
            blend: BlendState.depthOnly,
            depthTest: baseState.depthTest,
            cullMode: baseState.cullMode,
            stencil: baseState.stencil,
          )
        : (baseState.depthPrepass
              ? _prepassShadedStates[baseState] ??= baseState.copyWith(
                  depthCompare: CompareFunction.lessEqual,
                  depthWrite: false,
                )
              : baseState);
    if (!_depthPrepassOverride) {
      if (_oitPass != _OitAndGrabPass.noPass) {
        effectiveState = _OitAndGrabPass.stateFor(effectiveState, _oitPass);
      }
      if (renderDebugMode == RenderDebugMode3D.wireframe) {
        effectiveState = _wireframeStates[effectiveState] ??= effectiveState
            .copyWith(polygonMode: PolygonFillMode.wireframe);
      } else if (renderDebugMode == RenderDebugMode3D.overdraw) {
        effectiveState = const RenderState(
          blend: BlendState.additive,
          depthTest: false,
          depthWrite: false,
        );
      }
    }
    device
      ..setRenderState(effectiveState)
      ..setFrontFace(
        (_mirrored[first] == 1) == _isMirrored
            ? WindingOrder.counterClockwise
            : WindingOrder.clockwise,
      );
    RenderProfile.lap(RenderPhase.state);

    final external = _external[first];
    if (external != null) {
      _drawProbeSlot = _probeSlots[first];
      _drawProbeWeight = _probeWeights[first];
      if (!identical(material, _boundMaterial) || _probeChanged) {
        _jointTransforms = joints;
        _applyMaterial(material, vertexShader, fragmentShader);
      }
      _bindJoints(vertexShader, joints);
      final instanceCount = _externalCounts[first];
      device
        ..bindSurface(surface)
        ..bindInstances(
          external,
          instanceCount,
          startFloat: _externalOffsets[first],
        )
        ..drawSurface(surface, instanceCount: instanceCount);
      RenderProfile.lap(RenderPhase.draw);
      return;
    }

    if (!pipeline.instanced) {
      for (var i = start; i < start + count; i++) {
        final draw = order[i];
        _modelMatrix.storage.setRange(
          0,
          16,
          _instances,
          draw * VertexLayout.instanceStrideInFloats,
        );
        _jointTransforms = _joints[draw];
        _drawProbeSlot = _probeSlots[draw];
        _drawProbeWeight = _probeWeights[draw];
        _applyMaterial(material, vertexShader, fragmentShader);
        _bindJoints(vertexShader, _joints[draw]);
        device.bindSurface(surface);
        if (pipeline.usesInstanceData) {
          device.bindInstancesOf(_instances, order, i, 1);
        }
        device.drawSurface(surface);
        RenderProfile.lap(RenderPhase.draw);
      }
      return;
    }

    _drawProbeSlot = _probeSlots[first];
    _drawProbeWeight = _probeWeights[first];
    if (!identical(material, _boundMaterial) || _probeChanged) {
      _jointTransforms = joints;
      _applyMaterial(material, vertexShader, fragmentShader);
    }
    _bindJoints(vertexShader, joints);
    device
      ..bindSurface(surface)
      ..bindInstancesOf(_instances, order, start, count)
      ..drawSurface(surface, instanceCount: count);
    RenderProfile.lap(RenderPhase.draw);
  }

  Material? _boundMaterial;
  int _bindingEpoch = -1;

  // The order-independent transparency pass draws are submitted for, see
  // `_OitAndGrabPass`.
  int _oitPass = _OitAndGrabPass.noPass;

  // The render states derived from material render states, created once.
  final Map<RenderState, RenderState> _depthOnlyStates = {};
  final Map<RenderState, RenderState> _prepassShadedStates = {};
  final Map<RenderState, RenderState> _wireframeStates = {};

  bool get _probeChanged =>
      _drawProbeSlot != _boundProbeSlot ||
      _drawProbeWeight != _boundProbeWeight;

  void _applyMaterial(
    Material material,
    Shader vertexShader,
    Shader fragmentShader,
  ) {
    RenderProfile.lap(RenderPhase.binding);
    _boundProbeSlot = _drawProbeSlot;
    _boundProbeWeight = _drawProbeWeight;
    materialTracker?.note(material);
    if (!material.cachesApply ||
        !material.isApplyCacheValid(this, vertexShader, fragmentShader)) {
      material.apply(this);
      if (material.cachesApply) {
        material.recordApplyCache(this, vertexShader, fragmentShader);
      }
    }
    RenderProfile.lap(RenderPhase.materialApply);
    _bindMaterialPlan(_planFor(vertexShader), vertexShader);
    _bindMaterialPlan(_planFor(fragmentShader), fragmentShader);
    if (!identical(material, _boundMaterial)) {
      device.stats.materialChanges++;
      _boundMaterial = material;
    }
  }

  void _bindPassSlots(
    Material material,
    Shader vertexShader, {
    Shader? fragmentShader,
    bool skipJoints = false,
  }) {
    _bindPassPlan(_planFor(vertexShader), skipJoints: skipJoints);
    _bindPassPlan(
      _planFor(fragmentShader ?? material.fragmentShader),
      skipJoints: true,
    );
  }

  void _bindJoints(Shader vertexShader, List<Matrix4>? joints) {
    if (joints == null) {
      return;
    }
    final js = _planFor(vertexShader).jointsSlot;
    if (js == null) {
      return;
    }
    _writeAndBindJoints(js, joints);
  }

  void _bindMaterialPlan(_ShaderPlan plan, Shader shader) {
    final blocks = plan.materialBlocks;
    for (var i = 0; i < blocks.length; i++) {
      device.bindUniformBlock(shader.blockAt(blocks[i].blockIndex));
    }
    final samplers = plan.materialSamplers;
    for (var i = 0; i < samplers.length; i++) {
      final s = samplers[i];
      device.bindTexture(
        s.slot,
        shader.textureAt(s.samplerIndex) ?? Texture.standard,
      );
    }
  }

  void _bindPassPlan(_ShaderPlan plan, {bool skipJoints = false}) {
    final blocks = plan.passBlocks;
    for (var i = 0; i < blocks.length; i++) {
      _bindPassBlockEntry(blocks[i]);
    }
    final samplers = plan.passSamplers;
    for (var i = 0; i < samplers.length; i++) {
      final s = samplers[i];
      device.bindTexture(s.slot, s.provider(this));
    }
    final js = plan.jointsSlot;
    if (js != null && !skipJoints) {
      _bindDefaultJoints(js);
    }
  }

  void _bindDefaultJoints(_JointsEntry js) {
    final pass = _pass;
    if (_sharedPassEpochs[_passKindJointsIdentity] == pass &&
        _sharedPassSigs[_passKindJointsIdentity] == js.layoutSignature) {
      final buf = _sharedPassBuffers[_passKindJointsIdentity];
      if (buf != null) {
        device.bindUniformSlice(
          js.slot,
          buf,
          offsetInBytes: _sharedPassOffsets[_passKindJointsIdentity],
          lengthInBytes: _sharedPassLengths[_passKindJointsIdentity],
        );
        return;
      }
    }
    device.bindUniformBlock(js.defaultBlock);
    if (!device.isSuspended && js.defaultBlock.uploadBuffer != null) {
      _sharedPassEpochs[_passKindJointsIdentity] = pass;
      _sharedPassSigs[_passKindJointsIdentity] = js.layoutSignature;
      _sharedPassBuffers[_passKindJointsIdentity] =
          js.defaultBlock.uploadBuffer;
      _sharedPassOffsets[_passKindJointsIdentity] =
          js.defaultBlock.uploadOffset;
      _sharedPassLengths[_passKindJointsIdentity] =
          js.defaultBlock.bytes.lengthInBytes;
    }
  }

  void _bindPassBlockEntry(_PassBlockEntry entry) {
    final kind = entry.passKind;
    final pass = _pass;
    if (kind > 0 &&
        _sharedPassEpochs[kind] == pass &&
        _sharedPassSigs[kind] == entry.layoutSignature) {
      final buf = _sharedPassBuffers[kind];
      if (buf != null) {
        device.bindUniformSlice(
          entry.slot,
          buf,
          offsetInBytes: _sharedPassOffsets[kind],
          lengthInBytes: _sharedPassLengths[kind],
        );
        return;
      }
    }
    if (entry.writtenPass != pass) {
      entry.writtenPass = pass;
      RenderProfile.lap(RenderPhase.binding);
      entry.writer(this, entry.block);
      RenderProfile.lap(RenderPhase.uniformWrite);
    }
    device.bindUniformBlock(entry.block);
    if (kind > 0 && !device.isSuspended && entry.block.uploadBuffer != null) {
      _sharedPassEpochs[kind] = pass;
      _sharedPassSigs[kind] = entry.layoutSignature;
      _sharedPassBuffers[kind] = entry.block.uploadBuffer;
      _sharedPassOffsets[kind] = entry.block.uploadOffset;
      _sharedPassLengths[kind] = entry.block.bytes.lengthInBytes;
    }
  }

  _ShaderPlan _planFor(Shader shader) {
    shader.resource;
    final cached = shader.renderCache;
    if (cached is _ShaderPlan &&
        identical(cached.context, this) &&
        cached.version == _passUniformsVersion &&
        cached.generation == shader.generation) {
      return cached;
    }
    final passBlocks = <_PassBlockEntry>[];
    final passSamplers = <_PassSamplerEntry>[];
    final materialBlocks = <_MatBlockEntry>[];
    final materialSamplers = <_MatSamplerEntry>[];
    _JointsEntry? jointsSlot;

    final shaderSlots = shader.slots;
    final resolvedSlots = shader.resolvedSlots;
    for (var i = 0; i < shaderSlots.length; i++) {
      final name = shaderSlots[i];
      final slot = resolvedSlots[i];
      if (slot.sizeInBytes == null) {
        final provider = _passTextures[name];
        if (provider != null) {
          passSamplers.add(_PassSamplerEntry(slot, provider));
        } else {
          materialSamplers.add(
            _MatSamplerEntry(slot, shader.samplerIndexOf(name)),
          );
        }
        continue;
      }
      final writer =
          _passUniforms[name] ??
          (name == stylizedPassBlock
              ? _writeStylizedPass
              : (name == spatialPassBlock ? _writeSpatialPass : null));
      if (writer != null) {
        final block = _passBlocks[slot] ??= UniformBlock(slot);
        final kind = _resolvedPassKind(name, writer);
        final sig = kind > 0 ? _passLayoutSignature(kind, block) : 0;
        passBlocks.add(_PassBlockEntry(slot, block, writer, kind, sig));
      } else if (name == jointMatricesBlock) {
        final defaultBlock = _jointBlocks[slot] ??= UniformBlock(slot);
        final rows = defaultBlock.resolveOffset(jointRowsMember);
        final joints = rows >= 0
            ? UniformBlock.missingOffset
            : (defaultBlock.memberOffset('joints') ?? 0);
        final capacity = rows >= 0
            ? (defaultBlock.data.length - rows) ~/ 12
            : (defaultBlock.data.length - joints) ~/ 16;
        final sig = Object.hash(slot.sizeInBytes ?? 0, rows, joints);
        jointsSlot = _JointsEntry(
          slot,
          defaultBlock,
          rows,
          joints,
          capacity,
          sig,
        );
      } else {
        materialBlocks.add(
          _MatBlockEntry(slot, shader.blockIndexOf(name)),
        );
      }
    }

    final plan = _ShaderPlan(
      context: this,
      version: _passUniformsVersion,
      generation: shader.generation,
      passBlocks: passBlocks,
      passSamplers: passSamplers,
      materialBlocks: materialBlocks,
      materialSamplers: materialSamplers,
      jointsSlot: jointsSlot,
    );
    shader.renderCache = plan;
    return plan;
  }

  static const int _passKindCustom = 0;
  static const int _passKindCameraMatrices = 1;
  static const int _passKindCamera = 2;
  static const int _passKindAmbient = 3;
  static const int _passKindLights = 4;
  static const int _passKindDirLights = 5;
  static const int _passKindSpotLights = 6;
  static const int _passKindHemi = 7;
  static const int _passKindLightGrid = 8;
  static const int _passKindShadows = 9;
  static const int _passKindShadowAtlas = 10;
  static const int _passKindFog = 11;
  static const int _passKindWaterVolume = 12;
  static const int _passKindDepthNormal = 13;
  static const int _passKindSceneColor = 14;
  static const int _passKindPassOptions = 15;
  static const int _passKindShadowCaster = 16;
  static const int _passKindStylized = 17;
  static const int _passKindSpatial = 18;
  static const int _passKindJointsIdentity = 19;
  static const int _passKindCount = 20;

  final Int32List _sharedPassEpochs = Int32List(_passKindCount)
    ..fillRange(0, _passKindCount, -1);
  final Int32List _sharedPassSigs = Int32List(_passKindCount);
  final List<GpuBuffer?> _sharedPassBuffers = List.filled(_passKindCount, null);
  final Int32List _sharedPassOffsets = Int32List(_passKindCount);
  final Int32List _sharedPassLengths = Int32List(_passKindCount);

  static int _defaultPassKindFor(String name, PassUniformWriter writer) {
    if (name == cameraMatricesBlock && identical(writer, writeCameraUniforms)) {
      return _passKindCameraMatrices;
    }
    if (name == cameraBlock && identical(writer, writeCameraUniforms)) {
      return _passKindCamera;
    }
    if (name == ambientLightBlock &&
        identical(writer, writeAmbientLightUniforms)) {
      return _passKindAmbient;
    }
    if (name == lightsBlock && identical(writer, writeLightsUniforms)) {
      return _passKindLights;
    }
    if (name == directionalLightsBlock &&
        identical(writer, writeDirectionalLightsUniforms)) {
      return _passKindDirLights;
    }
    if (name == spotLightsBlock && identical(writer, writeSpotLightsUniforms)) {
      return _passKindSpotLights;
    }
    if (name == hemisphereLightBlock &&
        identical(writer, writeHemisphereLightUniforms)) {
      return _passKindHemi;
    }
    if (name == lightGridBlock && identical(writer, writeLightGridUniforms)) {
      return _passKindLightGrid;
    }
    if (name == shadowsBlock && identical(writer, writeShadowsUniforms)) {
      return _passKindShadows;
    }
    if (name == shadowAtlasBlock &&
        identical(writer, _ShadowPass.writeAtlasUniforms)) {
      return _passKindShadowAtlas;
    }
    if (name == fogBlock && identical(writer, writeFogUniforms)) {
      return _passKindFog;
    }
    if (name == waterVolumeBlock &&
        identical(writer, writeWaterVolumeUniforms)) {
      return _passKindWaterVolume;
    }
    if (name == depthNormalBlock &&
        identical(writer, _DepthNormalPass.writeUniforms)) {
      return _passKindDepthNormal;
    }
    if (name == sceneColorBlock &&
        identical(writer, _OitAndGrabPass.writeSceneColorUniforms)) {
      return _passKindSceneColor;
    }
    if (name == passOptionsBlock &&
        identical(writer, writePassOptionsUniforms)) {
      return _passKindPassOptions;
    }
    if (name == shadowCasterBlock &&
        identical(writer, _ShadowPass.writeCasterUniforms)) {
      return _passKindShadowCaster;
    }
    return _passKindCustom;
  }

  int _resolvedPassKind(String name, PassUniformWriter writer) {
    if (name == stylizedPassBlock && identical(writer, _writeStylizedPass)) {
      return _allDefaultPassParts(_stylizedPassParts)
          ? _passKindStylized
          : _passKindCustom;
    }
    if (name == spatialPassBlock && identical(writer, _writeSpatialPass)) {
      return _allDefaultPassParts(_spatialPassParts)
          ? _passKindSpatial
          : _passKindCustom;
    }
    if (_customWriterKinds.containsKey(name)) {
      return _passKindCustom;
    }
    return _defaultPassKindFor(name, writer);
  }

  bool _allDefaultPassParts(List<String> parts) {
    for (var i = 0; i < parts.length; i++) {
      if (_customWriterKinds.containsKey(parts[i])) {
        return false;
      }
    }
    return true;
  }

  static int _passLayoutSignature(int kind, UniformBlock block) {
    final len = block.bytes.lengthInBytes;
    if (kind == _passKindSpatial) {
      return Object.hash(
        len,
        block.resolveOffset('PassOptions_flags'),
        block.resolveOffset('Lights_numLights'),
        block.resolveOffset('Shadows_atlas'),
        block.resolveOffset('LightGrid_counts'),
      );
    }
    if (kind == _passKindStylized) {
      return Object.hash(
        len,
        block.resolveOffset('Camera_view'),
        block.resolveOffset('Lights_numLights'),
        block.resolveOffset('WaterVolume_plane'),
      );
    }
    return len;
  }

  final Map<GpuUniformSlot, UniformBlock> _passBlocks = {};
  final Map<GpuUniformSlot, UniformBlock> _jointBlocks = {};

  final Map<UniformBlock, List<UniformBlock>> _stylizedPassViews = {};
  final Map<UniformBlock, List<UniformBlock>> _spatialPassViews = {};

  static void _writePrefixedPass(
    RenderContext3D context,
    UniformBlock block,
    List<String> parts,
    Map<UniformBlock, List<UniformBlock>> viewsMap,
  ) {
    final views = viewsMap[block] ??= [
      for (final part in parts) PrefixedUniformBlock(block, '${part}_'),
    ];
    for (var i = 0; i < views.length; i++) {
      context._passUniforms[parts[i]]?.call(context, views[i]);
    }
  }

  static void _writeStylizedPass(RenderContext3D context, UniformBlock block) {
    _writePrefixedPass(
      context,
      block,
      _stylizedPassParts,
      context._stylizedPassViews,
    );
  }

  static void _writeSpatialPass(RenderContext3D context, UniformBlock block) {
    _writePrefixedPass(
      context,
      block,
      _spatialPassParts,
      context._spatialPassViews,
    );
  }

  Float32List _jointPackScratch = Float32List(1024);
  int _jointCacheFrame = -1;
  final List<_JointUploadEntry> _jointCacheActive = [];
  final List<_JointUploadEntry> _jointCachePool = [];

  void _writeAndBindJoints(_JointsEntry js, List<Matrix4> joints) {
    final count = joints.length;
    if (count > js.capacity) {
      throw StateError(
        'At most ${js.capacity} joints per surface are supported; '
        'found $count',
      );
    }
    final isRow = js.isRowMode;
    final stride = isRow ? 12 : 16;
    final base = isRow ? js.rowsOffset : js.jointsOffset;
    final floatLen = js.defaultBlock.data.length;
    final byteLen = floatLen * 4;
    if (_jointPackScratch.length < floatLen) {
      _jointPackScratch = Float32List(floatLen);
    }
    final scratch = _jointPackScratch;
    if (base > 0) {
      scratch.fillRange(0, base, 0.0);
    }
    final writtenEnd = base + count * stride;
    if (isRow) {
      for (var i = 0; i < count; i++) {
        final m = joints[i].storage;
        final o = base + i * 12;
        scratch
          ..[o] = m[0]
          ..[o + 1] = m[4]
          ..[o + 2] = m[8]
          ..[o + 3] = m[12]
          ..[o + 4] = m[1]
          ..[o + 5] = m[5]
          ..[o + 6] = m[9]
          ..[o + 7] = m[13]
          ..[o + 8] = m[2]
          ..[o + 9] = m[6]
          ..[o + 10] = m[10]
          ..[o + 11] = m[14];
      }
    } else {
      for (var i = 0; i < count; i++) {
        scratch.setRange(base + i * 16, base + (i + 1) * 16, joints[i].storage);
      }
    }
    if (writtenEnd < floatLen) {
      scratch.fillRange(writtenEnd, floatLen, 0.0);
    }

    final frame = device.frame;
    if (_jointCacheFrame != frame) {
      _jointCacheFrame = frame;
      _jointCachePool.addAll(_jointCacheActive);
      _jointCacheActive.clear();
    }

    final writtenCount = count * stride;
    RenderProfile.lap(RenderPhase.uniformWrite);
    for (var i = 0; i < _jointCacheActive.length; i++) {
      final e = _jointCacheActive[i];
      if (e.isRow == isRow &&
          e.floatLen == floatLen &&
          e.jointCount == count &&
          e.base == base &&
          _floatsEqual(e.snapshot, scratch, base, writtenCount)) {
        device.bindUniformSlice(
          js.slot,
          e.buffer,
          offsetInBytes: e.offset,
          lengthInBytes: byteLen,
        );
        return;
      }
    }

    final uploaded = device.uploadUniformBytes(
      scratch.buffer.asUint8List(0, byteLen),
    );
    if (uploaded == null) {
      return;
    }
    final (buf, off) = uploaded;
    device.bindUniformSlice(
      js.slot,
      buf,
      offsetInBytes: off,
      lengthInBytes: byteLen,
    );
    if (_jointCacheActive.length >= 64) {
      return;
    }
    final entry = _jointCachePool.isNotEmpty
        ? _jointCachePool.removeLast()
        : _JointUploadEntry();
    entry.store(
      isRow: isRow,
      floatLen: floatLen,
      jointCount: count,
      base: base,
      scratch: scratch,
      written: writtenCount,
      buffer: buf,
      offset: off,
    );
    _jointCacheActive.add(entry);
  }

  static bool _floatsEqual(
    Float32List snapshot,
    Float32List scratch,
    int base,
    int count,
  ) {
    if (count > 0 &&
        (snapshot[0] != scratch[base] ||
            snapshot[count - 1] != scratch[base + count - 1])) {
      return false;
    }
    for (var i = 0; i < count; i++) {
      if (snapshot[i] != scratch[base + i]) {
        return false;
      }
    }
    return true;
  }

  static void writeCameraUniforms(
    RenderContext3D context,
    UniformBlock block,
  ) {
    final off =
        (block.cachedWriterOffsets as _CameraOffsets?) ??
        (block.cachedWriterOffsets = _CameraOffsets(block));
    if (off.view >= 0) {
      block.writeMatrix4At(off.view, context.view);
    }
    if (off.projection >= 0) {
      block.writeMatrix4At(off.projection, context.projection);
    }
    if (off.viewProjection >= 0) {
      block.writeMatrix4At(off.viewProjection, context.viewProjection);
    }
    if (off.position >= 0) {
      final p = context.cameraPosition;
      block.writeVec3ValuesAt(off.position, p.x, p.y, p.z);
    }
  }

  int _lightSelPass = -1;
  List<Light>? _lightSelList;
  int _lightSelLength = -1;
  int _lightSelMask = 0;
  AmbientLight? _selAmbient;
  bool _selHasHemisphere = false;
  HemisphereLight? _selHemisphere;
  final List<Light> _selDirectionals = [];

  void _ensureLightSelection() {
    final list = lights;
    if (_lightSelPass == _pass &&
        identical(_lightSelList, list) &&
        _lightSelLength == list.length &&
        _lightSelMask == cameraMask) {
      return;
    }
    _lightSelPass = _pass;
    _lightSelList = list;
    _lightSelLength = list.length;
    _lightSelMask = cameraMask;
    _selAmbient = null;
    _selHasHemisphere = false;
    _selHemisphere = null;
    _selDirectionals.clear();
    for (var i = 0; i < list.length; i++) {
      final l = list[i];
      if ((l.lightMask & cameraMask) == 0) {
        continue;
      }
      final source = l.source;
      if (source is AmbientLight) {
        _selAmbient ??= source;
      } else if (source is HemisphereLight) {
        _selHasHemisphere = true;
        _selHemisphere ??= source;
      } else if (source is DirectionalLight &&
          _selDirectionals.length < maxDirectionalLights) {
        _selDirectionals.add(l);
      }
    }
  }

  static void writeAmbientLightUniforms(
    RenderContext3D context,
    UniformBlock block,
  ) {
    context._ensureLightSelection();
    final off =
        (block.cachedWriterOffsets as _AmbientOffsets?) ??
        (block.cachedWriterOffsets = _AmbientOffsets(block));
    final ambient = context._selAmbient;
    if (ambient == null && context._selHasHemisphere) {
      if (off.color >= 0) {
        block.writeVec4ValuesAt(off.color, 0, 0, 0, 0);
      }
      if (off.intensity >= 0) {
        block.writeFloatAt(off.intensity, 0);
      }
      return;
    }
    final resolved = ambient ?? _defaultAmbientLight;
    if (off.color >= 0) {
      block.writeColorAt(off.color, resolved.color);
    }
    if (off.intensity >= 0) {
      block.writeFloatAt(off.intensity, resolved.intensity);
    }
  }

  bool prioritizeNearestLights = false;

  static final Int32List _topLightIndices = Int32List(maxPointLights);
  static final Float64List _topLightScores = Float64List(maxPointLights);

  static double _lightPriorityScore(
    RenderContext3D context,
    Vector3 pos,
    double intensity,
  ) {
    final proj = context.projection.storage;
    if (proj[15].abs() < 0.5) {
      final cam = context.cameraPosition;
      final dx = pos.x - cam.x;
      final dy = pos.y - cam.y;
      final dz = pos.z - cam.z;
      return intensity / (1.0 + dx * dx + dy * dy + dz * dz);
    }
    final vp = context.viewProjection.storage;
    final cx = vp[0] * pos.x + vp[4] * pos.y + vp[8] * pos.z + vp[12];
    final cy = vp[1] * pos.x + vp[5] * pos.y + vp[9] * pos.z + vp[13];
    final cw = vp[3] * pos.x + vp[7] * pos.y + vp[11] * pos.z + vp[15];
    final invW = cw.abs() > 1e-6 ? 1.0 / cw : 1.0;
    final nx = cx * invW;
    final ny = cy * invW;
    return intensity / (1.0 + nx * nx + ny * ny);
  }

  /// Fills [out] with the indices, in [lights], of the point lights the
  /// [lightsBlock] holds, in the order it holds them, and returns how many:
  /// those of the pass's `lightMask` and of non-zero intensity among the
  /// first [maxPointLights], or, with [prioritizeNearestLights] and more of
  /// them, the [maxPointLights] of the highest priority.
  ///
  /// When the [lightGrid] holds the point lights of the pass, the block
  /// holds first those the grid cannot hold (chosen among themselves as
  /// above), then as many of the others as fit, which shaders that read the
  /// grid skip (see [lightGridBlock]).
  ///
  /// The shadow pass matches its lights to the block with it.
  static int _selectPointLights(RenderContext3D context, Int32List out) {
    context._planLightGrid();
    if (!context._gridPoints) {
      return _pickPointLights(context, out, 0, maxPointLights, _pickAll);
    }
    final fixed = _pickPointLights(
      context,
      out,
      0,
      maxPointLights,
      _pickFixed,
    );
    return fixed +
        _pickPointLights(
          context,
          out,
          fixed,
          maxPointLights - fixed,
          _pickBinnable,
        );
  }

  // Which lights a selection picks among: all, those a light grid cannot
  // hold, or those it can (see LightGrid3D.binnable).
  static const int _pickAll = 0;
  static const int _pickFixed = 1;
  static const int _pickBinnable = 2;

  @pragma('vm:prefer-inline')
  static bool _picks(Light light, int pick) =>
      pick == _pickAll ||
      LightGrid3D.binnable(light) == (pick == _pickBinnable);

  /// Writes into [out] from [offset] the indices of at most [capacity]
  /// point lights among those [pick] says, as [_selectPointLights] chooses
  /// them, and returns how many.
  static int _pickPointLights(
    RenderContext3D context,
    Int32List out,
    int offset,
    int capacity,
    int pick,
  ) {
    final lights = context.lights;
    var totalPointLights = 0;
    for (var i = 0; i < lights.length; i++) {
      if ((lights[i].lightMask & context.cameraMask) != 0 &&
          lights[i].source is PointLight &&
          _picks(lights[i], pick)) {
        totalPointLights++;
      }
    }

    var count = 0;
    if (!context.prioritizeNearestLights || totalPointLights <= capacity) {
      var slots = 0;
      for (var i = 0; i < lights.length && slots < capacity; i++) {
        final light = lights[i];
        if ((light.lightMask & context.cameraMask) == 0) {
          continue;
        }
        final source = light.source;
        if (source is! PointLight || !_picks(light, pick)) {
          continue;
        }
        // Beside a light grid, a light of zero intensity takes no place.
        if (source.intensity == 0 && pick != _pickAll) {
          continue;
        }
        slots++;
        if (source.intensity == 0) {
          continue;
        }
        out[offset + count++] = i;
      }
      return count;
    }
    for (var i = 0; i < lights.length; i++) {
      final light = lights[i];
      if ((light.lightMask & context.cameraMask) == 0) {
        continue;
      }
      final source = light.source;
      if (source is! PointLight ||
          source.intensity <= 0 ||
          !_picks(light, pick)) {
        continue;
      }
      count = _insertByScore(
        out,
        count,
        capacity,
        i,
        _lightPriorityScore(context, light.position, source.intensity),
        offset: offset,
      );
    }
    return count;
  }

  /// Fills [out] with the indices, in [lights], of the spot lights the
  /// [spotLightsBlock] holds, in the order it holds them, and returns how
  /// many: those of the pass's `lightMask` and of non-zero intensity, the
  /// first [maxSpotLights] when there are no more spot lights than that, the
  /// [maxSpotLights] of the highest priority otherwise.
  ///
  /// When the [lightGrid] holds the spot lights of the pass, the block holds
  /// first those the grid cannot hold, then as many of the others as fit
  /// (see [_selectPointLights]).
  ///
  /// The shadow pass matches its lights to the block with it.
  static int _selectSpotLights(RenderContext3D context, Int32List out) {
    context._planLightGrid();
    if (!context._gridSpots) {
      return _pickSpotLights(context, out, 0, maxSpotLights, _pickAll);
    }
    final fixed = _pickSpotLights(context, out, 0, maxSpotLights, _pickFixed);
    return fixed +
        _pickSpotLights(
          context,
          out,
          fixed,
          maxSpotLights - fixed,
          _pickBinnable,
        );
  }

  /// Writes into [out] from [offset] the indices of at most [capacity] spot
  /// lights among those [pick] says, as [_selectSpotLights] chooses them,
  /// and returns how many.
  static int _pickSpotLights(
    RenderContext3D context,
    Int32List out,
    int offset,
    int capacity,
    int pick,
  ) {
    final lights = context.lights;
    var totalSpot = 0;
    for (var i = 0; i < lights.length; i++) {
      if ((lights[i].lightMask & context.cameraMask) != 0 &&
          lights[i].source is SpotLight &&
          _picks(lights[i], pick)) {
        totalSpot++;
      }
    }

    var count = 0;
    if (totalSpot <= capacity) {
      for (var i = 0; i < lights.length && count < capacity; i++) {
        if ((lights[i].lightMask & context.cameraMask) == 0) {
          continue;
        }
        final source = lights[i].source;
        if (source is SpotLight &&
            source.intensity > 0 &&
            _picks(lights[i], pick)) {
          out[offset + count++] = i;
        }
      }
      return count;
    }
    for (var i = 0; i < lights.length; i++) {
      if ((lights[i].lightMask & context.cameraMask) == 0) {
        continue;
      }
      final source = lights[i].source;
      if (source is! SpotLight ||
          source.intensity <= 0 ||
          !_picks(lights[i], pick)) {
        continue;
      }
      count = _insertByScore(
        out,
        count,
        capacity,
        i,
        _lightPriorityScore(context, lights[i].position, source.intensity),
        offset: offset,
      );
    }
    return count;
  }

  /// Inserts light [index] of [score] into the [count] first entries of
  /// [out] from [offset], kept by decreasing score in [_topLightScores], at
  /// most [capacity] of them; returns the new count.
  static int _insertByScore(
    Int32List out,
    int count,
    int capacity,
    int index,
    double score, {
    int offset = 0,
  }) {
    if (capacity <= 0) {
      return count;
    }
    int pos;
    if (count < capacity) {
      pos = count++;
    } else if (score > _topLightScores[capacity - 1]) {
      pos = capacity - 1;
    } else {
      return count;
    }
    while (pos > 0 && _topLightScores[pos - 1] < score) {
      _topLightScores[pos] = _topLightScores[pos - 1];
      out[offset + pos] = out[offset + pos - 1];
      pos--;
    }
    _topLightScores[pos] = score;
    out[offset + pos] = index;
    return count;
  }

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
  static final Int32List _gridScratch = Int32List(maxPointLights);

  void _planLightGrid() {
    if (_gridPlanPass == _pass &&
        identical(_gridPlanLights, lights) &&
        _gridPlanMask == cameraMask &&
        identical(_gridPlanSettings, lightGrid) &&
        _gridPlanPrioritize == prioritizeNearestLights) {
      return;
    }
    _gridPlanPass = _pass;
    _gridPlanLights = lights;
    _gridPlanMask = cameraMask;
    _gridPlanSettings = lightGrid;
    _gridPlanPrioritize = prioritizeNearestLights;
    _gridPoints = false;
    _gridSpots = false;
    _gridUniformPoints = maxPointLights;
    _gridUniformSpots = maxSpotLights;
    final settings = lightGrid;
    if (settings == null) {
      return;
    }
    var points = 0;
    var spots = 0;
    var binnablePoints = 0;
    var binnableSpots = 0;
    for (var i = 0; i < lights.length; i++) {
      final light = lights[i];
      if ((light.lightMask & cameraMask) == 0) {
        continue;
      }
      final source = light.source;
      if (source is PointLight) {
        points++;
        if (LightGrid3D.binnable(light)) {
          binnablePoints++;
        }
      } else if (source is SpotLight) {
        spots++;
        if (LightGrid3D.binnable(light)) {
          binnableSpots++;
        }
      }
    }
    final always = !settings.beyondLimitsOnly;
    _gridPoints = binnablePoints > 0 && (always || points > maxPointLights);
    _gridSpots = binnableSpots > 0 && (always || spots > maxSpotLights);
    if (_gridPoints) {
      _gridUniformPoints = _pickPointLights(
        this,
        _gridScratch,
        0,
        maxPointLights,
        _pickFixed,
      );
    }
    if (_gridSpots) {
      _gridUniformSpots = _pickSpotLights(
        this,
        _gridScratch,
        0,
        maxSpotLights,
        _pickFixed,
      );
    }
  }

  /// Builds the light grid of the pass, once per pass, when its lights need
  /// one; returns whether it holds any light.
  bool _buildLightGrid() {
    _planLightGrid();
    if (!_gridPoints && !_gridSpots) {
      _lightGrid.stats.active = false;
      return false;
    }
    if (_gridBuiltPass != _pass) {
      _gridBuiltPass = _pass;
      _lightGrid.build(
        lights: lights,
        cameraMask: cameraMask,
        settings: lightGrid!,
        points: _gridPoints,
        spots: _gridSpots,
        bounds: lightGridBounds,
        viewProjection: _viewProjectionMatrix,
        lightsVersion: _worldLightsVersion,
      );
    }
    return _lightGrid.hasLights;
  }

  static Texture _lightGridTexture(RenderContext3D context) =>
      context._buildLightGrid()
      ? context._lightGrid.texture(context.device.backend)
      : Texture.standard;

  /// Writes the [lightGridBlock] of the pass: where the cells of its grid
  /// are (`origin`: the corner of cell `(0, 0, 0)` and `1 / cell size`;
  /// `cells`: the number of cells along x, y and z, and `x * y`), its
  /// texture (`data`: width, `1 / width`, `1 / height`, and `1` when the
  /// grid holds lights, else `0`), and how many lights of the
  /// [lightsBlock] and [spotLightsBlock] a shader that reads the grid shades
  /// from the blocks (`counts.xy`): all of them without a grid, else those
  /// that come before the lights the grid holds too.
  static void writeLightGridUniforms(
    RenderContext3D context,
    UniformBlock block,
  ) {
    final off =
        (block.cachedWriterOffsets as _LightGridOffsets?) ??
        (block.cachedWriterOffsets = _LightGridOffsets(block));
    if (context._buildLightGrid()) {
      final grid = context._lightGrid;
      final s = grid.stats;
      if (off.origin >= 0) {
        block.writeVec4ValuesAt(
          off.origin,
          grid.origin.x,
          grid.origin.y,
          grid.origin.z,
          1 / s.cellSize,
        );
      }
      if (off.cells >= 0) {
        block.writeVec4ValuesAt(
          off.cells,
          s.cellsX.toDouble(),
          s.cellsY.toDouble(),
          s.cellsZ.toDouble(),
          (s.cellsX * s.cellsY).toDouble(),
        );
      }
      if (off.data >= 0) {
        block.writeVec4ValuesAt(
          off.data,
          LightGrid3D.textureWidth.toDouble(),
          1 / LightGrid3D.textureWidth,
          1 / s.textureHeight,
          1,
        );
      }
    } else {
      if (off.origin >= 0) {
        block.writeVec4ValuesAt(off.origin, 0, 0, 0, 0);
      }
      if (off.cells >= 0) {
        block.writeVec4ValuesAt(off.cells, 0, 0, 0, 0);
      }
      if (off.data >= 0) {
        block.writeVec4ValuesAt(off.data, 0, 0, 0, 0);
      }
    }
    if (off.counts >= 0) {
      block.writeVec4ValuesAt(
        off.counts,
        context._gridUniformPoints.toDouble(),
        context._gridUniformSpots.toDouble(),
        0,
        0,
      );
    }
  }

  static void writeLightsUniforms(RenderContext3D context, UniformBlock block) {
    final off =
        (block.cachedWriterOffsets as _LightsOffsets?) ??
        (block.cachedWriterOffsets = _LightsOffsets(block));
    final lights = context.lights;
    final count = _selectPointLights(context, _topLightIndices);
    final dataLen = block.data.length;
    for (var k = 0; k < count; k++) {
      final light = lights[_topLightIndices[k]];
      final source = light.source as PointLight;
      final range = source.range;
      final p = light.position;
      if (off.positions >= 0 && off.positions + k * 4 + 3 <= dataLen) {
        block.writeVec3ValuesAt(off.positions + k * 4, p.x, p.y, p.z);
      }
      if (off.colors >= 0 && off.colors + k * 4 + 4 <= dataLen) {
        block.writeColorAt(off.colors + k * 4, source.color);
      }
      if (off.intensities >= 0 && off.intensities + k * 4 < dataLen) {
        block.writeFloatAt(off.intensities + k * 4, source.intensity);
      }
      if (off.ranges >= 0 && off.ranges + k * 4 < dataLen) {
        block.writeFloatAt(
          off.ranges + k * 4,
          range != null && range > 0 ? range : 0,
        );
      }
    }
    if (off.numLights >= 0) {
      block.writeFloatAt(off.numLights, count.toDouble());
    }
  }

  static void writeSpotLightsUniforms(
    RenderContext3D context,
    UniformBlock block,
  ) {
    final off =
        (block.cachedWriterOffsets as _SpotLightsOffsets?) ??
        (block.cachedWriterOffsets = _SpotLightsOffsets(block));
    final lights = context.lights;
    final count = _selectSpotLights(context, _topLightIndices);
    final dataLen = block.data.length;

    final dir = _scratchDirection;
    for (var k = 0; k < count; k++) {
      final light = lights[_topLightIndices[k]];
      final source = light.source as SpotLight;
      light.direction(dir);
      final outer = source.outerConeAngle.clamp(0.001, math.pi * 0.999);
      final inner = source.innerConeAngle.clamp(0.0, outer - 1e-4);
      final cosOuter = math.cos(outer);
      final invSpan = 1.0 / math.max(math.cos(inner) - cosOuter, 1e-4);
      final range = source.range;
      final c = source.color;
      final p = light.position;
      if (off.positions >= 0 && off.positions + k * 4 + 3 <= dataLen) {
        block.writeVec3ValuesAt(off.positions + k * 4, p.x, p.y, p.z);
      }
      if (off.directions >= 0 && off.directions + k * 4 + 4 <= dataLen) {
        block.writeVec4ValuesAt(
          off.directions + k * 4,
          -dir.x,
          -dir.y,
          -dir.z,
          source.specular,
        );
      }
      if (off.colors >= 0 && off.colors + k * 4 + 4 <= dataLen) {
        block.writeVec4ValuesAt(
          off.colors + k * 4,
          c.r,
          c.g,
          c.b,
          source.intensity,
        );
      }
      if (off.cones >= 0 && off.cones + k * 4 + 4 <= dataLen) {
        block.writeVec4ValuesAt(
          off.cones + k * 4,
          cosOuter,
          invSpan,
          range != null && range > 0 ? range : 0,
          0,
        );
      }
    }
    if (off.numLights >= 0) {
      block.writeFloatAt(off.numLights, count.toDouble());
    }
  }

  static void writeDirectionalLightsUniforms(
    RenderContext3D context,
    UniformBlock block,
  ) {
    context._ensureLightSelection();
    final off =
        (block.cachedWriterOffsets as _DirLightsOffsets?) ??
        (block.cachedWriterOffsets = _DirLightsOffsets(block));
    final dirs = context._selDirectionals;
    final count = dirs.length;
    final direction = _scratchDirection;
    final dataLen = block.data.length;
    for (var k = 0; k < count; k++) {
      final light = dirs[k];
      final source = light.source as DirectionalLight;
      light.direction(direction);
      final color = source.color;
      if (off.directions >= 0 && off.directions + k * 4 + 4 <= dataLen) {
        block.writeVec4ValuesAt(
          off.directions + k * 4,
          -direction.x,
          -direction.y,
          -direction.z,
          source.specular,
        );
      }
      if (off.colors >= 0 && off.colors + k * 4 + 4 <= dataLen) {
        block.writeVec4ValuesAt(
          off.colors + k * 4,
          color.r,
          color.g,
          color.b,
          source.intensity,
        );
      }
    }
    if (off.numLights >= 0) {
      block.writeFloatAt(off.numLights, count.toDouble());
    }
  }

  static void writeHemisphereLightUniforms(
    RenderContext3D context,
    UniformBlock block,
  ) {
    context._ensureLightSelection();
    final off =
        (block.cachedWriterOffsets as _HemiOffsets?) ??
        (block.cachedWriterOffsets = _HemiOffsets(block));
    final hemisphere = context._selHemisphere;
    final up = _scratchDirection;
    if (hemisphere == null) {
      if (off.skyColor >= 0) {
        block.writeVec4ValuesAt(off.skyColor, 0, 0, 0, 0);
      }
      if (off.groundColor >= 0) {
        block.writeVec4ValuesAt(off.groundColor, 0, 0, 0, 0);
      }
      if (off.up >= 0) {
        block.writeVec3ValuesAt(off.up, 0, 1, 0);
      }
      if (off.intensity >= 0) {
        block.writeFloatAt(off.intensity, 0);
      }
      return;
    }
    up.setFrom(hemisphere.up);
    if (up.length2 > 0) {
      up.normalize();
    } else {
      up.setValues(0, 1, 0);
    }
    if (off.skyColor >= 0) {
      block.writeColorAt(off.skyColor, hemisphere.skyColor);
    }
    if (off.groundColor >= 0) {
      block.writeColorAt(off.groundColor, hemisphere.groundColor);
    }
    if (off.up >= 0) {
      block.writeVec3ValuesAt(off.up, up.x, up.y, up.z);
    }
    if (off.intensity >= 0) {
      block.writeFloatAt(off.intensity, hemisphere.intensity);
    }
  }

  static void writeFogUniforms(RenderContext3D context, UniformBlock block) {
    final off =
        (block.cachedWriterOffsets as _FogOffsets?) ??
        (block.cachedWriterOffsets = _FogOffsets(block));
    final fog = context.fog;
    if (fog == null || fog.maxOpacity <= 0) {
      if (off.color >= 0) {
        block.writeVec4ValuesAt(off.color, 0, 0, 0, 0);
      }
      if (off.params >= 0) {
        block.writeVec4ValuesAt(off.params, 0, 0, 0, 0);
      }
      if (off.height >= 0) {
        block.writeVec4ValuesAt(off.height, 0, 1, 0, 0);
      }
      return;
    }
    final up = _scratchDirection..setFrom(fog.up);
    if (up.length2 > 0) {
      up.normalize();
    } else {
      up.setValues(0, 1, 0);
    }
    final span = math.max(fog.end - fog.start, 1e-4);
    final c = fog.color;
    if (off.color >= 0) {
      block.writeVec4ValuesAt(
        off.color,
        c.r,
        c.g,
        c.b,
        c.a * fog.maxOpacity.clamp(0.0, 1.0),
      );
    }
    if (off.params >= 0) {
      block.writeVec4ValuesAt(
        off.params,
        math.max(0.0, fog.start),
        1.0 / span,
        math.max(0.0, fog.density),
        math.max(0.0, fog.heightFalloff),
      );
    }
    if (off.height >= 0) {
      block.writeVec4ValuesAt(
        off.height,
        up.x,
        up.y,
        up.z,
        fog.baseHeight,
      );
    }
  }

  /// Fills the [waterVolumeBlock] from [waterVolume], see
  /// `flame_3d/water_volume.glsl`.
  static void writeWaterVolumeUniforms(
    RenderContext3D context,
    UniformBlock block,
  ) {
    final off =
        (block.cachedWriterOffsets as _WaterVolOffsets?) ??
        (block.cachedWriterOffsets = _WaterVolOffsets(block));
    final water = context.waterVolume;
    if (water == null || !water.isActive) {
      if (off.plane >= 0) {
        block.writeVec4ValuesAt(off.plane, 0, 1, 0, 0);
      }
      if (off.deep >= 0) {
        block.writeVec4ValuesAt(off.deep, 0, 0, 0, 0);
      }
      if (off.caustics >= 0) {
        block.writeVec4ValuesAt(off.caustics, 0, 0, 0, 0);
      }
      if (off.boundsMin >= 0) {
        block.writeVec4ValuesAt(off.boundsMin, 0, 0, 0, 0);
      }
      return;
    }
    final up = _scratchDirection..setFrom(water.up);
    if (up.length2 > 0) {
      up.normalize();
    } else {
      up.setValues(0, 1, 0);
    }
    final shallow = water.shallowColor;
    final deep = water.deepColor;
    final caustic = water.causticColor;
    final line = water.waterlineColor;
    final scale = water.causticScale;
    if (off.plane >= 0) {
      block.writeVec4ValuesAt(off.plane, up.x, up.y, up.z, water.level);
    }
    if (off.shallow >= 0) {
      block.writeVec4ValuesAt(
        off.shallow,
        shallow.r,
        shallow.g,
        shallow.b,
        math.max(0.0, water.absorption),
      );
    }
    if (off.deep >= 0) {
      block.writeVec4ValuesAt(off.deep, deep.r, deep.g, deep.b, 1);
    }
    if (off.caustics >= 0) {
      block.writeVec4ValuesAt(
        off.caustics,
        math.max(0.0, water.causticStrength),
        scale > 0 ? 1 / scale : 0,
        water.phase,
        math.max(0.0, water.waterlineWidth),
      );
    }
    if (off.causticColor >= 0) {
      block.writeVec4ValuesAt(
        off.causticColor,
        caustic.r,
        caustic.g,
        caustic.b,
        water.waterlineLightTint.clamp(0.0, 1.0),
      );
    }
    if (off.waterline >= 0) {
      block.writeVec4ValuesAt(
        off.waterline,
        line.r,
        line.g,
        line.b,
        line.a,
      );
    }
    if (off.waterlineFoam >= 0) {
      block.writeVec4ValuesAt(
        off.waterlineFoam,
        water.waterlinePhase,
        water.waterlineLightFloor > 0 ? water.waterlineLightFloor : 0,
        0,
        0,
      );
    }
    final bounds = water.bounds;
    if (bounds == null) {
      if (off.boundsMin >= 0) {
        block.writeVec4ValuesAt(off.boundsMin, 0, 0, 0, 0);
      }
    } else {
      final lo = bounds.min;
      final hi = bounds.max;
      if (off.boundsMin >= 0) {
        block.writeVec4ValuesAt(off.boundsMin, lo.x, lo.y, lo.z, 1);
      }
      if (off.boundsMax >= 0) {
        block.writeVec4ValuesAt(off.boundsMax, hi.x, hi.y, hi.z, 0);
      }
    }
  }

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
  }) {
    final fogVer = fog?.version ?? -1;
    final waterVer = waterVolume?.version ?? -1;
    final probeIntensity = lightProbeGrid?.intensity ?? -1.0;
    if (_syncedLightRev == lightsVersion &&
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
    _syncedLightRev = lightsVersion;
    _syncedFogVer = fogVer;
    _syncedWaterVer = waterVer;
    _syncedProbeIntensity = probeIntensity;
    return true;
  }

  static final _scratchDirection = Vector3.zero();

  static final _defaultAmbientLight = AmbientLight();

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

  void _grow() {
    final capacity = _capacityFor(_capacity + 1);
    List<T?> grow<T>(List<T?> list) => [
      ...list,
      ...List<T?>.filled(capacity - list.length, null),
    ];
    _surfaces = grow(_surfaces);
    _materials = grow(_materials);
    _pipelines = grow(_pipelines);
    _vertexShaders = grow(_vertexShaders);
    _fragmentShaders = grow(_fragmentShaders);
    _joints = grow(_joints);
    _external = grow(_external);
    _externalCounts = Int32List(capacity)
      ..setRange(0, _externalCounts.length, _externalCounts);
    _externalOffsets = Int32List(capacity)
      ..setRange(0, _externalOffsets.length, _externalOffsets);
    _instances = Float32List(capacity * VertexLayout.instanceStrideInFloats)
      ..setRange(0, _instances.length, _instances);
    _depths = Float64List(capacity)..setRange(0, _depths.length, _depths);
    _mirrored = Uint8List(capacity)..setRange(0, _mirrored.length, _mirrored);
    _groupKeys = Float64List(capacity);
    _surfaceKeys = Int32List(capacity);
    _prepassGroups = Int32List(capacity)
      ..setRange(0, _prepassGroups.length, _prepassGroups);
    _probeSlots = Int32List(capacity)
      ..setRange(0, _probeSlots.length, _probeSlots);
    _probeWeights = Float64List(capacity)
      ..setRange(0, _probeWeights.length, _probeWeights);
    _sortDepths = Float64List(capacity);
    _opaque = Int32List(capacity);
    _translucent = Int32List(capacity);
    _sortScratch = Int32List(capacity);
    _capacity = capacity;
  }

  static int _capacityFor(int count) {
    var capacity = 64;
    while (capacity < count) {
      capacity *= 2;
    }
    return capacity;
  }

  @pragma('vm:prefer-inline')
  @pragma('dart2js:prefer-inline')
  int _compareDraws(int a, int b) {
    final groupA = _groupKeys[a];
    final groupB = _groupKeys[b];
    if (groupA != groupB) {
      return groupA < groupB ? -1 : 1;
    }
    final surfaceA = _surfaceKeys[a];
    final surfaceB = _surfaceKeys[b];
    if (surfaceA != surfaceB) {
      return surfaceA < surfaceB ? -1 : 1;
    }
    if (_sortByProbe) {
      final probeA = _probeSlots[a];
      final probeB = _probeSlots[b];
      if (probeA != probeB) {
        return probeA < probeB ? -1 : 1;
      }
      final weightA = _probeWeights[a];
      final weightB = _probeWeights[b];
      if (weightA != weightB) {
        return weightA < weightB ? -1 : 1;
      }
    }
    final depthA = _sortDepths[a];
    final depthB = _sortDepths[b];
    if (depthA != depthB) {
      return depthA < depthB ? -1 : 1;
    }
    return a - b;
  }

  void _sort(Int32List list, int length) {
    if (length < 2) {
      return;
    }
    const run = 8;
    for (var start = 0; start < length; start += run) {
      final end = start + run < length ? start + run : length;
      for (var i = start + 1; i < end; i++) {
        final value = list[i];
        var j = i - 1;
        while (j >= start && _compareDraws(list[j], value) > 0) {
          list[j + 1] = list[j];
          j--;
        }
        list[j + 1] = value;
      }
    }
    var source = list;
    var target = _sortScratch;
    for (var width = run; width < length; width *= 2) {
      for (var left = 0; left < length; left += 2 * width) {
        final middle = left + width < length ? left + width : length;
        final right = left + 2 * width < length ? left + 2 * width : length;
        var i = left;
        var j = middle;
        var k = left;
        while (i < middle && j < right) {
          if (_compareDraws(source[j], source[i]) < 0) {
            target[k++] = source[j++];
          } else {
            target[k++] = source[i++];
          }
        }
        while (i < middle) {
          target[k++] = source[i++];
        }
        while (j < right) {
          target[k++] = source[j++];
        }
      }
      final swap = source;
      source = target;
      target = swap;
    }
    if (!identical(source, list)) {
      list.setRange(0, length, source);
    }
  }
}

class _PassBlockEntry(
  final GpuUniformSlot slot,
  final UniformBlock block,
  final PassUniformWriter writer,
  final int passKind,
  final int layoutSignature,
) {
  int writtenPass = -1;
}

class _PassSamplerEntry(
  final GpuUniformSlot slot,
  final PassTextureProvider provider,
);

class _MatBlockEntry(
  final GpuUniformSlot slot,
  final int blockIndex,
);

class _MatSamplerEntry(
  final GpuUniformSlot slot,
  final int samplerIndex,
);

class _JointsEntry(
  final GpuUniformSlot slot,
  final UniformBlock defaultBlock,
  final int rowsOffset,
  final int jointsOffset,
  final int capacity,
  final int layoutSignature,
) {
  bool get isRowMode => rowsOffset >= 0;
}

class _ShaderPlan({
  required final RenderContext3D context,
  required final int version,
  required final int generation,
  required final List<_PassBlockEntry> passBlocks,
  required final List<_PassSamplerEntry> passSamplers,
  required final List<_MatBlockEntry> materialBlocks,
  required final List<_MatSamplerEntry> materialSamplers,
  required final _JointsEntry? jointsSlot,
});

class _JointUploadEntry() {
  bool isRow = false;
  int floatLen = 0;
  int jointCount = 0;
  int base = 0;
  Float32List snapshot = Float32List(0);
  late GpuBuffer buffer;
  int offset = 0;

  void store({
    required bool isRow,
    required int floatLen,
    required int jointCount,
    required int base,
    required Float32List scratch,
    required int written,
    required GpuBuffer buffer,
    required int offset,
  }) {
    this.isRow = isRow;
    this.floatLen = floatLen;
    this.jointCount = jointCount;
    this.base = base;
    this.buffer = buffer;
    this.offset = offset;
    if (snapshot.length < written) {
      snapshot = Float32List(written);
    }
    snapshot.setRange(0, written, scratch, base);
  }
}

class _CameraOffsets(final UniformBlock _b) {
  late final int view = _b.resolveOffset('view');
  late final int projection = _b.resolveOffset('projection');
  late final int viewProjection = _b.resolveOffset('viewProjection');
  late final int position = _b.resolveOffset('position');
}

class _AmbientOffsets(final UniformBlock _b) {
  late final int color = _b.resolveOffset('color');
  late final int intensity = _b.resolveOffset('intensity');
}

class _LightsOffsets(final UniformBlock _b) {
  late final int positions = _b.resolveOffset('positions');
  late final int colors = _b.resolveOffset('colors');
  late final int intensities = _b.resolveOffset('intensities');
  late final int ranges = _b.resolveOffset('ranges');
  late final int numLights = _b.resolveOffset('numLights');
}

class _SpotLightsOffsets(final UniformBlock _b) {
  late final int positions = _b.resolveOffset('positions');
  late final int directions = _b.resolveOffset('directions');
  late final int colors = _b.resolveOffset('colors');
  late final int cones = _b.resolveOffset('cones');
  late final int numLights = _b.resolveOffset('numLights');
}

class _DirLightsOffsets(final UniformBlock _b) {
  late final int directions = _b.resolveOffset('directions');
  late final int colors = _b.resolveOffset('colors');
  late final int numLights = _b.resolveOffset('numLights');
}

class _HemiOffsets(final UniformBlock _b) {
  late final int skyColor = _b.resolveOffset('skyColor');
  late final int groundColor = _b.resolveOffset('groundColor');
  late final int up = _b.resolveOffset('up');
  late final int intensity = _b.resolveOffset('intensity');
}

class _LightGridOffsets(final UniformBlock _b) {
  late final int origin = _b.resolveOffset('origin');
  late final int cells = _b.resolveOffset('cells');
  late final int data = _b.resolveOffset('data');
  late final int counts = _b.resolveOffset('counts');
}

class _FogOffsets(final UniformBlock _b) {
  late final int color = _b.resolveOffset('color');
  late final int params = _b.resolveOffset('params');
  late final int height = _b.resolveOffset('height');
}

class _WaterVolOffsets(final UniformBlock _b) {
  late final int plane = _b.resolveOffset('plane');
  late final int shallow = _b.resolveOffset('shallow');
  late final int deep = _b.resolveOffset('deep');
  late final int caustics = _b.resolveOffset('caustics');
  late final int causticColor = _b.resolveOffset('causticColor');
  late final int waterline = _b.resolveOffset('waterline');
  late final int waterlineFoam = _b.resolveOffset('waterlineFoam');
  late final int boundsMin = _b.resolveOffset('boundsMin');
  late final int boundsMax = _b.resolveOffset('boundsMax');
}

class _PassOptionsOffsets(final UniformBlock _b) {
  late final int flags = _b.resolveOffset('flags');
  late final int gridBoundsMin = _b.resolveOffset('gridBoundsMin');
  late final int gridInvSpan = _b.resolveOffset('gridInvSpan');
  late final int gridRes = _b.resolveOffset('gridRes');
}

class _CameraSnapshot() {
  final Matrix4 view = Matrix4.identity();
  final Matrix4 projection = Matrix4.identity();
  final Matrix4 viewProjection = Matrix4.identity();
  final Vector3 cameraPosition = Vector3.zero();
  final Float64List depthRow = Float64List(4);
  final Frustum frustum = Frustum();
  bool isMirrored = false;
}
