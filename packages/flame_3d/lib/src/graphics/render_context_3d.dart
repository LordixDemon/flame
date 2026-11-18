import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flame_3d/camera.dart';
import 'package:flame_3d/game.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/src/graphics/material_pipeline_cache.dart';

part 'render_context_3d_shadows.dart';

/// Fills a uniform block that the [RenderContext3D] uploads once per render
/// pass, see [RenderContext3D.registerPassUniform].
///
/// [block] belongs to one shader; writers should only write the members they
/// know, [UniformBlock] ignores members the shader does not declare.
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
///
/// Components record draws with [drawMesh], [drawSurface] and
/// [drawInstances] while the world is traversed; nothing reaches the GPU until
/// [flush]. Then:
///
/// - opaque draws (see [RenderState.translucent]) are grouped by pipeline,
///   material and surface, and roughly ordered front to back within a group;
///   consecutive opaque draws of the same [Surface] and [Material] become a
///   single instanced draw when the material's vertex shader reads its model
///   matrix from the instance data (see `shaders/flame_3d/instancing.glsl`);
/// - translucent draws follow, back to front; consecutive translucent draws
///   of the same [Surface] and [Material] become one instanced draw, whose
///   instances are drawn in that order.
///
/// Front faces are counter-clockwise on screen. The winding flips when the
/// camera mirrors the scene (see [isMirrored]) and for objects whose model
/// matrix mirrors them (a negative determinant, from an odd number of negative
/// scales), so back-face culling keeps culling the faces that point away.
///
/// Skinned draws are never batched. A material's [Material.apply] runs when
/// the bound material changes (and before every draw of a material whose
/// shader reads its model matrix from uniforms), so materials must not change
/// their values between draws of one frame to vary objects: use the
/// per-instance color and data, or distinct materials.
///
/// Uniform blocks registered with [registerPassUniform] (the camera matrices
/// and the ambient, point, directional and hemisphere lights by default) are
/// written and uploaded once per pass for each shader that declares them.
///
/// When a directional light of the scene casts shadows (see
/// [ShadowSettings]), the host renders its shadow map before the main pass,
/// between [beginShadowPass] and [endShadowPass], and the [shadowsBlock] and
/// the [shadowMapSampler] give it to the shaders that receive shadows.
/// {@endtemplate}
class RenderContext3D(super.device) extends RenderContext {
  /// {@macro render_context_3d}
  this {
    registerPassUniform(cameraMatricesBlock, writeCameraUniforms);
    registerPassUniform(cameraBlock, writeCameraUniforms);
    registerPassUniform(ambientLightBlock, writeAmbientLightUniforms);
    registerPassUniform(lightsBlock, writeLightsUniforms);
    registerPassUniform(directionalLightsBlock, writeDirectionalLightsUniforms);
    registerPassUniform(hemisphereLightBlock, writeHemisphereLightUniforms);
    registerPassUniform(shadowsBlock, writeShadowsUniforms);
    registerPassUniform(shadowCasterBlock, _ShadowPass.writeCasterUniforms);
    registerPassTexture(shadowMapSampler, _ShadowPass.shadowMapTexture);
  }

  /// The name of the vertex stage block holding the camera matrices
  /// (`view`, `projection` and `viewProjection`).
  static const String cameraMatricesBlock = 'CameraMatrices';

  /// The name of the block holding the camera `position` (and any of the
  /// members of [cameraMatricesBlock]).
  static const String cameraBlock = 'Camera';

  /// The name of the block holding the ambient light `color` and `intensity`.
  static const String ambientLightBlock = 'AmbientLight';

  /// The name of the block holding the point lights: `numLights`, and the
  /// `positions`, `colors`, `intensities` (in `x`) and `ranges` (in `x`, `0`
  /// for an inverse-square falloff) arrays.
  static const String lightsBlock = 'Lights';

  /// The name of the block holding the directional lights: `numLights`, the
  /// `directions` array (in `xyz` the unit vector from a surface towards the
  /// light, in `w` its specular factor) and the `colors` array (in `rgb` the
  /// color, in `a` the intensity).
  static const String directionalLightsBlock = 'DirectionalLights';

  /// The name of the block holding the hemisphere light: `skyColor`,
  /// `groundColor`, the unit `up` vector and `intensity` (`0` when the scene
  /// has none).
  static const String hemisphereLightBlock = 'HemisphereLight';

  /// The name of the block holding the joint matrices (`joints`) of a skinned
  /// draw, see `shaders/flame_3d/skinning.glsl`. The context fills it for
  /// every skinned draw.
  static const String jointMatricesBlock = 'JointMatrices';

  /// The name of the block describing the shadow map of the pass, see
  /// `shaders/flame_3d/shadows.glsl`: the light's view-projection, its
  /// direction and index, the color and strength of the shadows, the size of
  /// the map, the biases and how its texels decode to depths. Without
  /// shadows, the `w` of its `toLight` member is `-1`.
  static const String shadowsBlock = 'Shadows';

  /// The name of the sampler of the shadow map, see [shadowsBlock].
  static const String shadowMapSampler = 'shadowMap';

  /// The name of the block of the shaders that render shadow maps, telling
  /// them how to store depths.
  static const String shadowCasterBlock = 'ShadowCaster';

  /// The maximum number of point lights written to the [lightsBlock].
  static const int maxPointLights = 8;

  /// The maximum number of directional lights written to the
  /// [directionalLightsBlock].
  static const int maxDirectionalLights = 4;

  /// The model matrix of the draw being submitted.
  ///
  /// [drawMesh] and [drawSurface] use it when no transform is given. While
  /// [Material.apply] runs for a material that is not drawn instanced, it holds
  /// the model matrix of the draw the material is applied for.
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
  Vector3 get cameraPosition => _cameraPosition;
  final Vector3 _cameraPosition = Vector3.zero();

  /// The view frustum of the current pass, in world space.
  Frustum get frustum => _frustum;
  final Frustum _frustum = Frustum();

  /// Whether the camera of the current pass mirrors the scene, in which case
  /// front faces are clockwise on screen (see [frontFace]).
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

  /// The number of draws recorded in the last flushed pass.
  int get drawCount => _lastDrawCount;
  int _lastDrawCount = 0;

  // Depth of a world position: `dot(row, (x, y, z, 1))` grows away from the
  // camera (clip w for perspective cameras, clip z for orthographic ones).
  final Float64List _depthRow = Float64List(4);

  final Map<String, PassUniformWriter> _passUniforms = {};
  final Map<String, PassTextureProvider> _passTextures = {};
  int _passUniformsVersion = 0;
  int _pass = 0;

  /// The uniform blocks filled once per render pass, by block name.
  Map<String, PassUniformWriter> get passUniforms =>
      Map.unmodifiable(_passUniforms);

  /// Registers [writer] to fill every uniform block named [name] once per
  /// render pass, for every shader that declares it.
  ///
  /// Use this for data shared by every draw of a pass (camera, lights,
  /// environment, time). Pass `null` to stop filling the block.
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
  ///
  /// Use this for textures shared by every draw of a pass, such as the
  /// shadow map. Pass `null` to stop providing it.
  void registerPassTexture(String name, PassTextureProvider? provider) {
    if (provider == null) {
      _passTextures.remove(name);
    } else {
      _passTextures[name] = provider;
    }
    _passUniformsVersion++;
  }

  /// Set the camera matrices for the next pass.
  ///
  /// Everything derived from them (the view-projection matrix, camera
  /// position, frustum and mirroring) is computed here once per pass. The
  /// pass has no shadows until [endShadowPass] says otherwise.
  void setCamera(Matrix4 viewMatrix, Matrix4 projectionMatrix) {
    _pass++;
    _shadows.active = false;
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
    // Planes for Impeller's clip space, where depth runs from 0 at the near
    // plane to 1 at the far plane.
    _frustum.setFromViewProjection(_viewProjectionMatrix);

    final m = _viewProjectionMatrix.storage;
    // Row 3 (clip w) depends on the position for perspective projections.
    final perspective = m[3] * m[3] + m[7] * m[7] + m[11] * m[11] > 1e-12;
    final depthRow = perspective ? 3 : 2;
    for (var i = 0; i < 4; i++) {
      _depthRow[i] = m[i * 4 + depthRow];
    }
    _isMirrored = mirrors(_viewProjectionMatrix);
  }

  final Matrix4 _inverseView = Matrix4.identity();

  /// Whether the view-projection matrix [m] mirrors the scene compared to a
  /// standard camera, which flips the on-screen winding of every triangle.
  ///
  /// The orientation of a projected triangle is the sign of the determinant of
  /// the x, y and w rows (over x, y and z) of [m], which is negative for a
  /// standard right-handed camera whatever its depth mapping. For an
  /// orthographic projection the w row is constant, and the depth row (z) is
  /// used instead, assuming depth grows away from the camera.
  static bool mirrors(Matrix4 m) {
    final s = m.storage;
    final perspective = s[3] * s[3] + s[7] * s[7] + s[11] * s[11] > 1e-12;
    final r = perspective ? 3 : 2;
    // Element (row, column) is at `column * 4 + row`.
    final det =
        s[0] * (s[5] * s[8 + r] - s[9] * s[4 + r]) -
        s[4] * (s[1] * s[8 + r] - s[9] * s[r]) +
        s[8] * (s[1] * s[4 + r] - s[5] * s[r]);
    return det > 0;
  }

  /// Records a draw of every surface of [mesh] with the model matrix
  /// [transform] (defaults to [model]), the per-instance [color] and the
  /// per-instance [instanceData] (zero when `null`).
  ///
  /// [jointTransforms] holds, by surface index, the joint matrices of skinned
  /// surfaces.
  void drawMesh(
    Mesh mesh, {
    Matrix4? transform,
    Color color = const Color(0xFFFFFFFF),
    Vector4? instanceData,
    Map<int, List<Matrix4>>? jointTransforms,
  }) {
    mesh.draw(
      this,
      transform: transform,
      color: color,
      instanceData: instanceData,
      jointTransforms: jointTransforms,
    );
  }

  /// Records a draw of [surface] with its material (or [material]), the model
  /// matrix [transform] (defaults to [model]), the per-instance [color] and
  /// the per-instance [instanceData] (zero when `null`).
  ///
  /// The color and the instance data reach the material's vertex shader as
  /// `instanceColor` and `instanceData` (see
  /// `shaders/flame_3d/instancing.glsl`); what the instance data means is up
  /// to the material. Both are copied when the draw is recorded, so draws
  /// that differ only in them still batch.
  ///
  /// [jointTransforms] are the joint matrices of a skinned surface.
  void drawSurface(
    Surface surface, {
    Matrix4? transform,
    Color color = const Color(0xFFFFFFFF),
    Vector4? instanceData,
    List<Matrix4>? jointTransforms,
    Material? material,
  }) {
    final drawMaterial = material ?? surface.material;
    final i = _count;
    if (i == _capacity) {
      _grow();
    }
    _count++;

    _surfaces[i] = surface;
    _materials[i] = drawMaterial;
    _pipelines[i] = _pipelineFor(drawMaterial, surface.layout);
    _joints[i] = jointTransforms != null && jointTransforms.isNotEmpty
        ? jointTransforms
        : null;

    final m = (transform ?? _modelMatrix).storage;
    // A model matrix with a negative determinant (an odd number of negative
    // scales) mirrors the object, which flips the winding of its triangles.
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

    // Depth of the center of the surface's bounds.
    final aabb = surface.aabb;
    final cx = (aabb.min.x + aabb.max.x) * 0.5;
    final cy = (aabb.min.y + aabb.max.y) * 0.5;
    final cz = (aabb.min.z + aabb.max.z) * 0.5;
    final wx = m[0] * cx + m[4] * cy + m[8] * cz + m[12];
    final wy = m[1] * cx + m[5] * cy + m[9] * cz + m[13];
    final wz = m[2] * cx + m[6] * cy + m[10] * cz + m[14];
    final d = _depthRow;
    _depths[i] = d[0] * wx + d[1] * wy + d[2] * wz + d[3];
    _external[i] = null;
  }

  /// Records one instanced draw of [surface] with its material (or
  /// [material]) whose [count] instances are read from [instances], each
  /// [VertexLayout.instanceStrideInFloats] floats laid out as the per-instance
  /// inputs (see `shaders/flame_3d/instancing.glsl`).
  ///
  /// This is for objects that build their own instance data, such as particle
  /// systems: the draw costs one draw call however many instances it has. It
  /// is never batched with other draws, and the material's vertex shader must
  /// read the instance inputs (declare the four `instanceModel` columns); what
  /// the columns mean is up to the material.
  ///
  /// [instances] is read when the draws are flushed, not copied when the draw
  /// is recorded: keep its first [count] instances unchanged until then.
  /// [center] is the world-space point whose depth orders the draw among the
  /// other draws (back to front for translucent materials), the origin when
  /// `null`. The instances are drawn with the winding of objects that do not
  /// mirror. Nothing is recorded when [count] is zero.
  void drawInstances(
    Surface surface, {
    required Float32List instances,
    required int count,
    Material? material,
    Vector3? center,
  }) {
    if (count <= 0) {
      return;
    }
    assert(
      instances.length >= count * VertexLayout.instanceStrideInFloats,
      'instances holds fewer than $count instances',
    );
    final drawMaterial = material ?? surface.material;
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
    _mirrored[i] = 0;
    _external[i] = instances;
    _externalCounts[i] = count;

    final d = _depthRow;
    _depths[i] = center == null
        ? d[3]
        : d[0] * center.x + d[1] * center.y + d[2] * center.z + d[3];
  }

  DevicePipeline _pipelineFor(Material material, VertexLayout layout) {
    final vertexShader = material.vertexShaderFor(layout);
    final fragmentShader = material.fragmentShader;
    // Resolve the resources first: recreating them bumps their generation.
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

  /// Whether the draws being recorded are those of a shadow map: between
  /// [beginShadowPass] and [endShadowPass], when the camera is the view of
  /// the light that casts shadows.
  bool get isShadowPass => _shadows.recording;

  /// Starts the shadow pass of the scene whose [lights] are set, when its
  /// first directional light with [DirectionalLight.shadows] casts shadows,
  /// and returns whether it did.
  ///
  /// Call it once the camera of the main pass is set with [setCamera] and
  /// before the main pass begins. It fits [projection] (one per scene, see
  /// [DirectionalShadowProjection]) to what [sceneBounds] (the bounds of
  /// every caster, see `World3D.sceneBounds`) and the camera call for, makes
  /// the light's view the camera, and begins a pass into the shadow map.
  /// Record the draws of the scene as for the main pass, then call
  /// [endShadowPass].
  ///
  /// It returns `false`, and the main pass has no shadows, when no light
  /// casts shadows, when the camera sees nothing that receives them, or when
  /// the GPU backend cannot render into textures (on the web).
  bool beginShadowPass({
    required DirectionalShadowProjection projection,
    required Aabb3? sceneBounds,
  }) {
    return _shadows.begin(projection, sceneBounds);
  }

  /// Renders the draws recorded since [beginShadowPass] into the shadow map,
  /// ends the shadow pass, and sets the camera of the main pass back, whose
  /// draws then receive the shadows.
  void endShadowPass() => _shadows.end();

  /// A number that changes every time a shadow pass renders a shadow map
  /// (between [beginShadowPass] and [endShadowPass]): while it stays the
  /// same, the map of the last shadow pass is still the one this context
  /// binds, see [reuseShadowMap].
  int get shadowMapVersion => _shadows.version;

  /// Makes the current pass receive the shadow map of the last shadow pass
  /// again, without rendering it, when no shadow pass rendered another map
  /// since: when [version] is still [shadowMapVersion]. Returns whether it
  /// did; the pass has no shadows otherwise.
  ///
  /// Call it instead of [beginShadowPass], once the camera of the main pass is
  /// set with [setCamera] and before the main pass begins. Scenes that share
  /// a shadow map (see `ShadowGroup`) render it once, in the first of their
  /// passes, and the others reuse it. The map's shadows are those of the
  /// light that cast them, among the [lights] of the scene that rendered it:
  /// the shaders tell that light from the others by its index among the
  /// directional lights, so the scenes that reuse a map give the same index to
  /// a light in the same direction.
  bool reuseShadowMap(int version) => _shadows.reuse(version);

  /// Writes the shadow map of the current pass into [block], see
  /// [shadowsBlock].
  static void writeShadowsUniforms(
    RenderContext3D context,
    UniformBlock block,
  ) {
    context._shadows.writeShadows(block);
  }

  late final _ShadowPass _shadows = _ShadowPass(this);

  /// Sorts the draws recorded since the last flush and submits them to the
  /// device, which must be in a render pass.
  void flush() {
    if (_shadows.recording) {
      _shadows.flushCasters();
      return;
    }
    final count = _count;
    var opaqueCount = 0;
    var translucentCount = 0;
    for (var i = 0; i < count; i++) {
      final material = _materials[i]!;
      if (material.renderState.translucent) {
        _translucent[translucentCount++] = i;
      } else {
        _opaque[opaqueCount++] = i;
        _groupKeys[i] =
            _pipelines[i]!.id * 8589934592.0 + material.id * 2.0 + _mirrored[i];
        // Skinned draws are never batched: keep them apart from the others.
        _surfaceKeys[i] = _surfaces[i]!.id * 2 + (_joints[i] == null ? 0 : 1);
      }
    }
    _sort(_opaque, opaqueCount, _opaqueComparator);
    _sort(_translucent, translucentCount, _translucentComparator);

    _boundMaterial = null;
    _bindingEpoch = -1;

    _submitBatches(_opaque, opaqueCount);
    // Back to front: only draws that are consecutive in that order batch, and
    // the instances of a batch are drawn in that order.
    _submitBatches(_translucent, translucentCount);

    // Release the references to what was drawn.
    for (var i = 0; i < count; i++) {
      _surfaces[i] = null;
      _materials[i] = null;
      _pipelines[i] = null;
      _joints[i] = null;
      _external[i] = null;
    }
    _boundMaterial = null;
    _jointTransforms = null;
    _lastDrawCount = count;
    _count = 0;
  }

  /// Submits the first [count] draws of [order], merging consecutive draws
  /// that batch into instanced draws.
  void _submitBatches(Int32List order, int count) {
    var start = 0;
    while (start < count) {
      final first = order[start];
      var end = start + 1;
      if (_pipelines[first]!.instanced &&
          _joints[first] == null &&
          _external[first] == null) {
        while (end < count && _batchesWith(first, order[end])) {
          end++;
        }
      }
      _submit(order, start, end - start);
      start = end;
    }
  }

  bool _batchesWith(int first, int other) {
    return identical(_surfaces[first], _surfaces[other]) &&
        identical(_materials[first], _materials[other]) &&
        identical(_pipelines[first], _pipelines[other]) &&
        _mirrored[first] == _mirrored[other] &&
        _joints[other] == null &&
        _external[other] == null;
  }

  /// Submits the [count] draws starting at [start] in [order], which share
  /// their surface, material and pipeline.
  void _submit(Int32List order, int start, int count) {
    final first = order[start];
    final surface = _surfaces[first]!;
    final material = _materials[first]!;
    final pipeline = _pipelines[first]!;
    final vertexShader = material.vertexShaderFor(surface.layout);

    device.bindPipeline(pipeline);
    if (device.bindingEpoch != _bindingEpoch) {
      _bindingEpoch = device.bindingEpoch;
      _boundMaterial = null;
      _bindPassSlots(material, vertexShader);
    }
    device
      ..setRenderState(material.renderState)
      ..setFrontFace(
        (_mirrored[first] == 1) == _isMirrored
            ? WindingOrder.counterClockwise
            : WindingOrder.clockwise,
      );

    final external = _external[first];
    if (external != null) {
      if (!identical(material, _boundMaterial)) {
        _jointTransforms = null;
        _applyMaterial(material, vertexShader);
      }
      final instanceCount = _externalCounts[first];
      device
        ..bindSurface(surface)
        ..bindInstances(external, instanceCount)
        ..drawSurface(surface, instanceCount: instanceCount);
      return;
    }

    if (!pipeline.instanced) {
      // The model matrix comes from uniforms: one draw per object, applying
      // the material for each of them.
      for (var i = start; i < start + count; i++) {
        final draw = order[i];
        _modelMatrix.storage.setRange(
          0,
          16,
          _instances,
          draw * VertexLayout.instanceStrideInFloats,
        );
        _jointTransforms = _joints[draw];
        _applyMaterial(material, vertexShader);
        _bindJoints(vertexShader, _joints[draw]);
        device.bindSurface(surface);
        if (pipeline.usesInstanceData) {
          _gatherInstances(order, i, 1);
          device.bindInstances(_batchInstances, 1);
        }
        device.drawSurface(surface);
      }
      return;
    }

    final joints = _joints[first];
    if (!identical(material, _boundMaterial)) {
      _jointTransforms = joints;
      _applyMaterial(material, vertexShader);
    }
    _bindJoints(vertexShader, joints);
    device.bindSurface(surface);
    _gatherInstances(order, start, count);
    device.bindInstances(_batchInstances, count);
    device.drawSurface(surface, instanceCount: count);
  }

  Material? _boundMaterial;
  int _bindingEpoch = -1;

  void _applyMaterial(Material material, Shader vertexShader) {
    material.apply(this);
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

  /// Binds the slots of [shader] of the given [scope].
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
          // Bound for every draw: vertices without joint weights ignore it.
          device.bindUniformBlock(_jointsBlockFor(slot));
        case _jointsBlock when scope == _jointsScope:
          final block = _jointsBlockFor(slot);
          _writeJoints(block, joints!);
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
      final writer = _passUniforms[name];
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
      writer(this, block);
    }
    return block;
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

  void _gatherInstances(Int32List order, int start, int count) {
    const stride = VertexLayout.instanceStrideInFloats;
    if (_batchInstances.length < count * stride) {
      _batchInstances = Float32List(_capacityFor(count) * stride);
    }
    final batch = _batchInstances;
    for (var i = 0; i < count; i++) {
      final source = order[start + i] * stride;
      batch.setRange(i * stride, i * stride + stride, _instances, source);
    }
  }

  /// Writes the camera matrices and position into [block].
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

  /// Writes the first ambient light of [RenderContext3D.lights] into [block].
  ///
  /// A scene without ambient light gets a default one (white, intensity
  /// `0.2`), unless it has a [HemisphereLight], which then lights it alone.
  static void writeAmbientLightUniforms(
    RenderContext3D context,
    UniformBlock block,
  ) {
    final lights = context.lights;
    AmbientLight? ambient;
    var hasHemisphere = false;
    for (var i = 0; i < lights.length && ambient == null; i++) {
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

  /// Writes the point lights of [RenderContext3D.lights] (at most
  /// [maxPointLights]) into [block].
  static void writeLightsUniforms(RenderContext3D context, UniformBlock block) {
    final lights = context.lights;
    var count = 0;
    for (var i = 0; i < lights.length && count < maxPointLights; i++) {
      final light = lights[i];
      final source = light.source;
      if (source is! PointLight) {
        continue;
      }
      final range = source.range;
      block
        ..setVector3('positions', light.position, index: count)
        ..setColor('colors', source.color, index: count)
        ..setFloat('intensities', source.intensity, index: count)
        ..setFloat(
          'ranges',
          range != null && range > 0 ? range : 0,
          index: count,
        );
      count++;
    }
    // NOTE: using floats because Android GLES does not support integer uniforms
    // Refer to https://github.com/flutter/engine/pull/55329
    block.setFloat('numLights', count.toDouble());
  }

  /// Writes the directional lights of [RenderContext3D.lights] (at most
  /// [maxDirectionalLights]) into [block], see [directionalLightsBlock].
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

  /// Writes the first hemisphere light of [RenderContext3D.lights] into
  /// [block], see [hemisphereLightBlock].
  static void writeHemisphereLightUniforms(
    RenderContext3D context,
    UniformBlock block,
  ) {
    final lights = context.lights;
    HemisphereLight? hemisphere;
    for (var i = 0; i < lights.length && hemisphere == null; i++) {
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

  static final _scratchDirection = Vector3.zero();
  static final _scratchVector4 = Vector4.zero();

  static final _defaultAmbientLight = AmbientLight();

  // Recorded draws, in recording order (structure of arrays).
  int _count = 0;
  int _capacity = 0;
  List<Surface?> _surfaces = [];
  List<Material?> _materials = [];
  List<DevicePipeline?> _pipelines = [];
  List<List<Matrix4>?> _joints = [];
  // The instance buffers of draws recorded with drawInstances, and their
  // instance counts.
  List<Float32List?> _external = [];
  Int32List _externalCounts = Int32List(0);
  Float32List _instances = Float32List(0);
  Float64List _depths = Float64List(0);
  Float64List _groupKeys = Float64List(0);
  Uint8List _mirrored = Uint8List(0);
  Int32List _surfaceKeys = Int32List(0);
  Int32List _opaque = Int32List(0);
  Int32List _translucent = Int32List(0);
  Int32List _sortScratch = Int32List(0);
  Float32List _batchInstances = Float32List(0);

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

  // Tear-offs are kept so that sorting does not allocate them every frame.
  late final _opaqueComparator = _compareOpaque;
  late final _translucentComparator = _compareTranslucent;

  /// Opaque order: pipeline, material, mirroring, surface, skinning, then
  /// front to back.
  int _compareOpaque(int a, int b) {
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
    final depthA = _depths[a];
    final depthB = _depths[b];
    if (depthA != depthB) {
      return depthA < depthB ? -1 : 1;
    }
    return a - b;
  }

  /// Translucent order: back to front.
  int _compareTranslucent(int a, int b) {
    final depthA = _depths[a];
    final depthB = _depths[b];
    if (depthA != depthB) {
      return depthA > depthB ? -1 : 1;
    }
    return a - b;
  }

  /// Sorts the first [length] entries of [list] with a bottom-up merge sort:
  /// stable, O(n log n), and allocation free.
  void _sort(Int32List list, int length, int Function(int, int) compare) {
    if (length < 2) {
      return;
    }
    // Sort short runs with insertion sort first.
    const run = 8;
    for (var start = 0; start < length; start += run) {
      final end = start + run < length ? start + run : length;
      for (var i = start + 1; i < end; i++) {
        final value = list[i];
        var j = i - 1;
        while (j >= start && compare(list[j], value) > 0) {
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
          if (compare(source[j], source[i]) < 0) {
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
  static const _jointsBlock = 3;
  static const _passSampler = 4;

  static const _materialScope = 0;
  static const _passScope = 1;
  static const _jointsScope = 2;
}

/// The slots of a shader, classified once for a [RenderContext3D].
class _ShaderPlan({
  required final RenderContext3D context,
  required final int version,
  required final int generation,
  required final List<String> names,
  required final List<GpuUniformSlot> slots,
  required final List<int> kinds,
  required final List<PassUniformWriter?> writers,
});
