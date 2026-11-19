import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flame_3d/camera.dart';
import 'package:flame_3d/game.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/src/extensions/clip_space.dart';
import 'package:flame_3d/src/graphics/material_pipeline_cache.dart';
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
    registerPassUniform(shadowsBlock, writeShadowsUniforms);
    registerPassUniform(shadowAtlasBlock, _ShadowPass.writeAtlasUniforms);
    registerPassUniform(fogBlock, writeFogUniforms);
    registerPassUniform(depthNormalBlock, _DepthNormalPass.writeUniforms);
    registerPassUniform(
      sceneColorBlock,
      _OitAndGrabPass.writeSceneColorUniforms,
    );
    registerPassUniform(passOptionsBlock, writePassOptionsUniforms);
    registerPassUniform(shadowCasterBlock, _ShadowPass.writeCasterUniforms);
    registerPassTexture(shadowMapSampler, _ShadowPass.shadowMapTexture);
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

  /// The name of the block holding the joint matrices (`joints`) of a skinned
  /// draw.
  static const String jointMatricesBlock = 'JointMatrices';

  /// The name of the block describing the shadow map of the pass.
  static const String shadowsBlock = 'Shadows';

  /// The name of the block describing the unified multi-light `ShadowAtlas3D`.
  static const String shadowAtlasBlock = 'ShadowAtlas';

  /// The name of the sampler of the shadow map, see [shadowsBlock].
  static const String shadowMapSampler = 'shadowMap';

  /// The name of the block of the shaders that render shadow maps.
  static const String shadowCasterBlock = 'ShadowCaster';

  /// The name of the block describing atmospheric fog (`FogSettings`).
  static const String fogBlock = 'Fog';

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
  /// reads the camera, the lights, the shadows and the fog of the pass.
  @internal
  static const String stylizedPassBlock = 'StylizedPass';

  static const List<String> _stylizedPassParts = [
    cameraBlock,
    ambientLightBlock,
    lightsBlock,
    directionalLightsBlock,
    spotLightsBlock,
    hemisphereLightBlock,
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

  /// The joint matrices of the draw [Material.apply] runs for, or `null` when
  /// it is not skinned.
  List<Matrix4>? get jointTransforms => _jointTransforms;
  List<Matrix4>? _jointTransforms;

  /// The lights of the scene. Must be set before the draws are flushed.
  List<Light> lights = const [];

  /// Atmospheric fog of the current pass (`null` disables fog).
  FogSettings? fog;

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

  final Float64List _depthRow = Float64List(4);

  final Map<String, PassUniformWriter> _passUniforms = {};
  final Map<String, PassTextureProvider> _passTextures = {};
  int _passUniformsVersion = 0;
  int _pass = 0;

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
    } else {
      _passUniforms[name] = writer;
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
  }) {
    final drawMaterial = material ?? surface.material;
    final shadowPass = _shadows.recording;
    if (shadowPass &&
        (!drawMaterial.castsShadows ||
            !drawMaterial.instancesHoldModelMatrices)) {
      return;
    }
    final i = _count;
    if (i == _capacity) {
      _grow();
    }
    _count++;

    _surfaces[i] = surface;
    _materials[i] = drawMaterial;
    _pipelines[i] = shadowPass
        ? null
        : _pipelineFor(drawMaterial, surface.layout);
    _joints[i] = jointTransforms != null && jointTransforms.isNotEmpty
        ? jointTransforms
        : null;

    final m = (transform ?? _modelMatrix).storage;
    final determinant =
        m[0] * (m[5] * m[10] - m[6] * m[9]) -
        m[4] * (m[1] * m[10] - m[2] * m[9]) +
        m[8] * (m[1] * m[6] - m[2] * m[5]);
    _mirrored[i] = determinant < 0 ? 1 : 0;

    final base = i * VertexLayout.instanceStrideInFloats;
    final instances = _instances..setRange(base, base + 16, m);
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

    final aabb = surface.aabb;
    final cx = (aabb.min.x + aabb.max.x) * 0.5;
    final cy = (aabb.min.y + aabb.max.y) * 0.5;
    final cz = (aabb.min.z + aabb.max.z) * 0.5;
    final wx = m[0] * cx + m[4] * cy + m[8] * cz + m[12];
    final wy = m[1] * cx + m[5] * cy + m[9] * cz + m[13];
    final wz = m[2] * cx + m[6] * cy + m[10] * cz + m[14];
    if (!shadowPass &&
        reflectionProbes.isNotEmpty &&
        drawMaterial.usesReflectionProbes) {
      _selectProbeFor(i, wx, wy, wz);
    } else {
      _probeSlots[i] = 0;
      _probeWeights[i] = 0;
    }
    final d = _depthRow;
    var depth = d[0] * wx + d[1] * wy + d[2] * wz + d[3];
    if (!shadowPass &&
        drawMaterial.renderState.translucent &&
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
    _external[i] = null;
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
    Material? material,
    Vector3? center,
    bool mirrored = false,
  }) {
    if (count <= 0) {
      return;
    }
    assert(
      instances.length >= count * VertexLayout.instanceStrideInFloats,
      'instances holds fewer than $count instances',
    );
    final drawMaterial = material ?? surface.material;
    if (_shadows.recording &&
        (!drawMaterial.castsShadows ||
            !drawMaterial.instancesHoldModelMatrices)) {
      return;
    }
    final pipeline = _pipelineFor(drawMaterial, surface.layout);
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
    _joints[i] = null;
    _mirrored[i] = mirrored ? 1 : 0;
    _external[i] = instances;
    _externalCounts[i] = count;

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

  DevicePipeline _pipelineFor(Material material, VertexLayout layout) {
    final vertexShader = material.vertexShaderFor(layout);
    final fragmentShader = material.fragmentShader;
    vertexShader.resource;
    fragmentShader.resource;
    final cache = material.pipelineCache;
    if (cache != null &&
        identical(cache.device, device) &&
        identical(cache.layout, layout) &&
        cache.vertexGeneration == vertexShader.generation &&
        cache.fragmentGeneration == fragmentShader.generation &&
        identical(cache.vertexShader, vertexShader) &&
        identical(cache.fragmentShader, fragmentShader)) {
      return cache.pipeline;
    }
    final pipeline = device.pipelineFor(vertexShader, fragmentShader, layout);
    material.pipelineCache = MaterialPipelineCache(
      device: device,
      layout: layout,
      vertexShader: vertexShader,
      fragmentShader: fragmentShader,
      vertexGeneration: vertexShader.generation,
      fragmentGeneration: fragmentShader.generation,
      pipeline: pipeline,
    );
    return pipeline;
  }

  /// Whether the draws being recorded are those of a shadow map.
  bool get isShadowPass => _shadows.recording;

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
  bool beginShadowPass({
    required DirectionalShadowProjection projection,
    required Aabb3? sceneBounds,
    Object? castersKey,
  }) {
    _shadowViewerPosition.setFrom(_cameraPosition);
    _shadowViewerViewProjection.setFrom(_viewProjectionMatrix);
    return _shadows.begin(projection, sceneBounds, castersKey: castersKey);
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
    final v = _scratchVector4;
    block.setVector4(
      'flags',
      v..setValues(
        context.hdrEnabled ? 1.0 : 0.0,
        context.renderDebugMode.index.toDouble(),
        context._oitGrab.grabActive ? 1.0 : 0.0,
        0.0,
      ),
    );

    final grid = context.lightProbeGrid;
    if (grid != null && grid.intensity > 0) {
      final b = grid.bounds;
      final sx = math.max(1e-5, b.max.x - b.min.x);
      final sy = math.max(1e-5, b.max.y - b.min.y);
      final sz = math.max(1e-5, b.max.z - b.min.z);
      block
        ..setVector4(
          'gridBoundsMin',
          v..setValues(b.min.x, b.min.y, b.min.z, grid.intensity),
        )
        ..setVector4(
          'gridInvSpan',
          // The grid holds irradiance: the diffuse light is E * kD * base / pi.
          v..setValues(
            1.0 / sx,
            1.0 / sy,
            1.0 / sz,
            grid.volumeTextureRange / math.pi,
          ),
        )
        ..setVector4(
          'gridRes',
          v..setValues(
            grid.resolutionX.toDouble(),
            grid.resolutionY.toDouble(),
            grid.resolutionZ.toDouble(),
            0.0,
          ),
        );
    } else {
      block
        ..setVector4('gridBoundsMin', v..setZero())
        ..setVector4('gridInvSpan', v)
        ..setVector4('gridRes', v..setValues(1, 1, 1, 0));
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
        groupKeys[i] = 0;
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
    final vertexShader = material.vertexShaderFor(surface.layout);
    RenderProfile.lap(RenderPhase.batch);

    device.bindPipeline(pipeline);
    if (device.bindingEpoch != _bindingEpoch) {
      _bindingEpoch = device.bindingEpoch;
      _boundMaterial = null;
      _bindPassSlots(material, vertexShader);
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
        _jointTransforms = null;
        _applyMaterial(material, vertexShader);
      }
      final instanceCount = _externalCounts[first];
      device
        ..bindSurface(surface)
        ..bindInstances(external, instanceCount)
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
        _applyMaterial(material, vertexShader);
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

    final joints = _joints[first];
    _drawProbeSlot = _probeSlots[first];
    _drawProbeWeight = _probeWeights[first];
    if (!identical(material, _boundMaterial) || _probeChanged) {
      _jointTransforms = joints;
      _applyMaterial(material, vertexShader);
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

  void _applyMaterial(Material material, Shader vertexShader) {
    RenderProfile.lap(RenderPhase.binding);
    _boundProbeSlot = _drawProbeSlot;
    _boundProbeWeight = _drawProbeWeight;
    material.apply(this);
    RenderProfile.lap(RenderPhase.materialApply);
    _bindSlots(vertexShader, _materialScope);
    _bindSlots(material.fragmentShader, _materialScope);
    if (!identical(material, _boundMaterial)) {
      device.stats.materialChanges++;
      _boundMaterial = material;
    }
  }

  void _bindPassSlots(Material material, Shader vertexShader) {
    _bindSlots(vertexShader, _passScope);
    _bindSlots(material.fragmentShader, _passScope);
  }

  void _bindJoints(Shader vertexShader, List<Matrix4>? joints) {
    if (joints == null) {
      return;
    }
    _bindSlots(vertexShader, _jointsScope, joints);
  }

  void _bindSlots(Shader shader, int scope, [List<Matrix4>? joints]) {
    final plan = _planFor(shader);
    final slots = plan.slots;
    final kinds = plan.kinds;
    for (var i = 0; i < slots.length; i++) {
      final kind = kinds[i];
      final slot = slots[i];
      switch (kind) {
        case _sampler when scope == _materialScope:
          device.bindTexture(
            slot,
            shader.texture(plan.names[i]) ?? Texture.standard,
          );
        case _passSampler when scope == _passScope:
          device.bindTexture(slot, _passTextures[plan.names[i]]!(this));
        case _material when scope == _materialScope:
          device.bindUniformBlock(shader.block(plan.names[i]));
        case _passBlock when scope == _passScope:
          device.bindUniformBlock(_passBlockFor(slot, plan.writers[i]!));
        case _jointsBlock when scope == _passScope:
          device.bindUniformBlock(_jointsBlockFor(slot));
        case _jointsBlock when scope == _jointsScope:
          final block = _jointsBlockFor(slot);
          RenderProfile.lap(RenderPhase.binding);
          _writeJoints(block, joints!);
          RenderProfile.lap(RenderPhase.uniformWrite);
          device.bindUniformBlock(block);
      }
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
    final names = <String>[];
    final slots = <GpuUniformSlot>[];
    final kinds = <int>[];
    final writers = <PassUniformWriter?>[];
    for (final name in shader.slots) {
      final slot = shader.slot(name);
      final writer =
          _passUniforms[name] ??
          (name == stylizedPassBlock ? _writeStylizedPass : null);
      names.add(name);
      slots.add(slot);
      writers.add(writer);
      kinds.add(switch (slot.sizeInBytes) {
        null when _passTextures.containsKey(name) => _passSampler,
        null => _sampler,
        _ when writer != null => _passBlock,
        _ when name == jointMatricesBlock => _jointsBlock,
        _ => _material,
      });
    }
    final plan = _ShaderPlan(
      context: this,
      version: _passUniformsVersion,
      generation: shader.generation,
      names: names,
      slots: slots,
      kinds: kinds,
      writers: writers,
    );
    shader.renderCache = plan;
    return plan;
  }

  final Map<GpuUniformSlot, UniformBlock> _passBlocks = {};
  final Map<GpuUniformSlot, int> _passBlockPasses = {};
  final Map<GpuUniformSlot, UniformBlock> _jointBlocks = {};

  UniformBlock _passBlockFor(GpuUniformSlot slot, PassUniformWriter writer) {
    final block = _passBlocks[slot] ??= UniformBlock(slot);
    if (_passBlockPasses[slot] != _pass) {
      _passBlockPasses[slot] = _pass;
      RenderProfile.lap(RenderPhase.binding);
      writer(this, block);
      RenderProfile.lap(RenderPhase.uniformWrite);
    }
    return block;
  }

  final Map<UniformBlock, List<UniformBlock>> _stylizedPassViews = {};

  static void _writeStylizedPass(RenderContext3D context, UniformBlock block) {
    final views = context._stylizedPassViews[block] ??= [
      for (final part in _stylizedPassParts)
        PrefixedUniformBlock(block, '${part}_'),
    ];
    for (var i = 0; i < views.length; i++) {
      context._passUniforms[_stylizedPassParts[i]]?.call(context, views[i]);
    }
  }

  UniformBlock _jointsBlockFor(GpuUniformSlot slot) {
    return _jointBlocks[slot] ??= UniformBlock(slot);
  }

  static void _writeJoints(UniformBlock block, List<Matrix4> joints) {
    final base = block.memberOffset('joints') ?? 0;
    final capacity = (block.data.length - base) ~/ 16;
    if (joints.length > capacity) {
      throw StateError(
        'At most $capacity joints per surface are supported;'
        ' found ${joints.length}',
      );
    }
    for (var i = 0; i < joints.length; i++) {
      block.writeAt(base + i * 16, joints[i].storage);
    }
  }

  static void writeCameraUniforms(
    RenderContext3D context,
    UniformBlock block,
  ) {
    block
      ..setMatrix4('view', context.view)
      ..setMatrix4('projection', context.projection)
      ..setMatrix4('viewProjection', context.viewProjection)
      ..setVector3('position', context.cameraPosition);
  }

  static void writeAmbientLightUniforms(
    RenderContext3D context,
    UniformBlock block,
  ) {
    final lights = context.lights;
    AmbientLight? ambient;
    var hasHemisphere = false;
    for (var i = 0; i < lights.length && ambient == null; i++) {
      if ((lights[i].lightMask & context.cameraMask) == 0) {
        continue;
      }
      final source = lights[i].source;
      if (source is AmbientLight) {
        ambient = source;
      } else if (source is HemisphereLight) {
        hasHemisphere = true;
      }
    }
    if (ambient == null && hasHemisphere) {
      block
        ..setColor('color', const Color(0x00000000))
        ..setFloat('intensity', 0);
      return;
    }
    ambient ??= _defaultAmbientLight;
    block
      ..setColor('color', ambient.color)
      ..setFloat('intensity', ambient.intensity);
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
  /// The shadow pass matches its lights to the block with it.
  static int _selectPointLights(RenderContext3D context, Int32List out) {
    final lights = context.lights;
    var totalPointLights = 0;
    for (var i = 0; i < lights.length; i++) {
      if ((lights[i].lightMask & context.cameraMask) != 0 &&
          lights[i].source is PointLight) {
        totalPointLights++;
      }
    }

    var count = 0;
    if (!context.prioritizeNearestLights ||
        totalPointLights <= maxPointLights) {
      var slots = 0;
      for (var i = 0; i < lights.length && slots < maxPointLights; i++) {
        final light = lights[i];
        if ((light.lightMask & context.cameraMask) == 0) {
          continue;
        }
        final source = light.source;
        if (source is! PointLight) {
          continue;
        }
        slots++;
        if (source.intensity == 0) {
          continue;
        }
        out[count++] = i;
      }
      return count;
    }
    for (var i = 0; i < lights.length; i++) {
      final light = lights[i];
      if ((light.lightMask & context.cameraMask) == 0) {
        continue;
      }
      final source = light.source;
      if (source is! PointLight || source.intensity <= 0) {
        continue;
      }
      count = _insertByScore(
        out,
        count,
        maxPointLights,
        i,
        _lightPriorityScore(context, light.position, source.intensity),
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
  /// The shadow pass matches its lights to the block with it.
  static int _selectSpotLights(RenderContext3D context, Int32List out) {
    final lights = context.lights;
    var totalSpot = 0;
    for (var i = 0; i < lights.length; i++) {
      if ((lights[i].lightMask & context.cameraMask) != 0 &&
          lights[i].source is SpotLight) {
        totalSpot++;
      }
    }

    var count = 0;
    if (totalSpot <= maxSpotLights) {
      for (var i = 0; i < lights.length && count < maxSpotLights; i++) {
        if ((lights[i].lightMask & context.cameraMask) == 0) {
          continue;
        }
        final source = lights[i].source;
        if (source is SpotLight && source.intensity > 0) {
          out[count++] = i;
        }
      }
      return count;
    }
    for (var i = 0; i < lights.length; i++) {
      if ((lights[i].lightMask & context.cameraMask) == 0) {
        continue;
      }
      final source = lights[i].source;
      if (source is! SpotLight || source.intensity <= 0) {
        continue;
      }
      count = _insertByScore(
        out,
        count,
        maxSpotLights,
        i,
        _lightPriorityScore(context, lights[i].position, source.intensity),
      );
    }
    return count;
  }

  /// Inserts light [index] of [score] into the [count] first entries of
  /// [out], kept by decreasing score in [_topLightScores], at most
  /// [capacity] of them; returns the new count.
  static int _insertByScore(
    Int32List out,
    int count,
    int capacity,
    int index,
    double score,
  ) {
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
      out[pos] = out[pos - 1];
      pos--;
    }
    _topLightScores[pos] = score;
    out[pos] = index;
    return count;
  }

  static void writeLightsUniforms(RenderContext3D context, UniformBlock block) {
    final lights = context.lights;
    final count = _selectPointLights(context, _topLightIndices);
    for (var k = 0; k < count; k++) {
      final light = lights[_topLightIndices[k]];
      final source = light.source as PointLight;
      final range = source.range;
      block
        ..setVector3('positions', light.position, index: k)
        ..setColor('colors', source.color, index: k)
        ..setFloat('intensities', source.intensity, index: k)
        ..setFloat(
          'ranges',
          range != null && range > 0 ? range : 0,
          index: k,
        );
    }
    block.setFloat('numLights', count.toDouble());
  }

  static void writeSpotLightsUniforms(
    RenderContext3D context,
    UniformBlock block,
  ) {
    final lights = context.lights;
    final count = _selectSpotLights(context, _topLightIndices);

    final dir = _scratchDirection;
    final val = _scratchVector4;
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
      block
        ..setVector3('positions', light.position, index: k)
        ..setVector4(
          'directions',
          val..setValues(-dir.x, -dir.y, -dir.z, source.specular),
          index: k,
        )
        ..setVector4(
          'colors',
          val..setValues(c.r, c.g, c.b, source.intensity),
          index: k,
        )
        ..setVector4(
          'cones',
          val..setValues(
            cosOuter,
            invSpan,
            range != null && range > 0 ? range : 0,
            0,
          ),
          index: k,
        );
    }
    block.setFloat('numLights', count.toDouble());
  }

  static void writeDirectionalLightsUniforms(
    RenderContext3D context,
    UniformBlock block,
  ) {
    final lights = context.lights;
    final direction = _scratchDirection;
    final value = _scratchVector4;
    var count = 0;
    for (var i = 0; i < lights.length && count < maxDirectionalLights; i++) {
      final light = lights[i];
      if ((light.lightMask & context.cameraMask) == 0) {
        continue;
      }
      final source = light.source;
      if (source is! DirectionalLight) {
        continue;
      }
      light.direction(direction);
      final color = source.color;
      block
        ..setVector4(
          'directions',
          value..setValues(
            -direction.x,
            -direction.y,
            -direction.z,
            source.specular,
          ),
          index: count,
        )
        ..setVector4(
          'colors',
          value..setValues(color.r, color.g, color.b, source.intensity),
          index: count,
        );
      count++;
    }
    block.setFloat('numLights', count.toDouble());
  }

  static void writeHemisphereLightUniforms(
    RenderContext3D context,
    UniformBlock block,
  ) {
    final lights = context.lights;
    HemisphereLight? hemisphere;
    for (var i = 0; i < lights.length && hemisphere == null; i++) {
      if ((lights[i].lightMask & context.cameraMask) == 0) {
        continue;
      }
      final source = lights[i].source;
      if (source is HemisphereLight) {
        hemisphere = source;
      }
    }
    final up = _scratchDirection;
    if (hemisphere == null) {
      block
        ..setColor('skyColor', const Color(0x00000000))
        ..setColor('groundColor', const Color(0x00000000))
        ..setVector3('up', up..setValues(0, 1, 0))
        ..setFloat('intensity', 0);
      return;
    }
    up.setFrom(hemisphere.up);
    if (up.length2 > 0) {
      up.normalize();
    } else {
      up.setValues(0, 1, 0);
    }
    block
      ..setColor('skyColor', hemisphere.skyColor)
      ..setColor('groundColor', hemisphere.groundColor)
      ..setVector3('up', up)
      ..setFloat('intensity', hemisphere.intensity);
  }

  static void writeFogUniforms(RenderContext3D context, UniformBlock block) {
    final fog = context.fog;
    final v = _scratchVector4;
    if (fog == null || fog.maxOpacity <= 0) {
      block
        ..setVector4('color', v..setZero())
        ..setVector4('params', v)
        ..setVector4('height', v..setValues(0, 1, 0, 0));
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
    block
      ..setVector4(
        'color',
        v..setValues(c.r, c.g, c.b, c.a * fog.maxOpacity.clamp(0.0, 1.0)),
      )
      ..setVector4(
        'params',
        v..setValues(
          math.max(0.0, fog.start),
          1.0 / span,
          math.max(0.0, fog.density),
          math.max(0.0, fog.heightFalloff),
        ),
      )
      ..setVector4(
        'height',
        v..setValues(up.x, up.y, up.z, fog.baseHeight),
      );
  }

  static final _scratchDirection = Vector3.zero();
  static final _scratchVector4 = Vector4.zero();

  static final _defaultAmbientLight = AmbientLight();

  int _count = 0;
  int _capacity = 0;
  List<Surface?> _surfaces = [];
  List<Material?> _materials = [];
  List<DevicePipeline?> _pipelines = [];
  List<List<Matrix4>?> _joints = [];
  List<Float32List?> _external = [];
  Int32List _externalCounts = Int32List(0);
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
    _joints = grow(_joints);
    _external = grow(_external);
    _externalCounts = Int32List(capacity)
      ..setRange(0, _externalCounts.length, _externalCounts);
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

  static const _sampler = 0;
  static const _material = 1;
  static const _passBlock = 2;
  static const _passSampler = 3;
  static const _jointsBlock = 4;

  static const _passScope = 0;
  static const _materialScope = 1;
  static const _jointsScope = 2;
}

class _ShaderPlan({
  required final RenderContext3D context,
  required final int version,
  required final int generation,
  required final List<String> names,
  required final List<GpuUniformSlot> slots,
  required final List<int> kinds,
  required final List<PassUniformWriter?> writers,
});
