part of 'render_context_3d.dart';

/// The shadow pass of a [RenderContext3D]: finds the light that casts
/// shadows, fits its shadow map, renders the casters into it with depth-only
/// shaders, and gives the map to the shaders of the main pass.
///
/// The casters are the draws recorded during the pass, whatever their
/// material (as long as it casts shadows): they are drawn with
/// `shaders/shadow_caster.vert`, which reads the position of any vertex
/// layout (and `shadow_caster_skinned.vert` for layouts with joints and
/// joint weights), so draws of one surface batch into one instanced draw even
/// across materials.
class _ShadowPass(final RenderContext3D _context) {
  /// Whether the draws being recorded are those of a shadow map.
  bool recording = false;

  /// Whether the pass whose camera is set receives shadows.
  bool active = false;

  /// Incremented every time a shadow pass renders a map, see
  /// [RenderContext3D.shadowMapVersion].
  int version = 0;

  // The values of the Shadows block of the main pass.
  final Matrix4 _lightViewProjection = Matrix4.identity();
  final Vector4 _toLight = Vector4(0, 0, 0, -1);
  final Vector4 _color = Vector4.zero();
  final Vector4 _map = Vector4.zero();
  final Vector4 _bias = Vector4.zero();
  final Vector4 _decode = Vector4.zero();
  bool _packDepth = false;

  // The shadow map, as the texture bound to the receivers.
  GpuTextureTarget? _target;
  Texture? _texture;

  // The camera of the main pass, set back when the shadow pass ends.
  final Matrix4 _mainView = Matrix4.identity();
  final Matrix4 _mainProjection = Matrix4.identity();
  int _drawCallsBefore = 0;

  static final Vector3 _direction = Vector3.zero();
  static final Vector4 _noShadows = Vector4(0, 0, 0, -1);

  /// Decodes a texel of a packed map, see `packShadowDepth` in
  /// `shaders/flame_3d/shadow_caster_fragment.glsl`: 24 bits of depth in its
  /// red, green and blue channels, most significant first.
  static final Vector4 _packedDecode = Vector4(
    65536 * 255 / 16777215,
    256 * 255 / 16777215,
    255 / 16777215,
    0,
  );

  static const _bundle =
      'packages/flame_3d/assets/shaders/shadow_caster.shaderbundle';
  static const _skinnedBundle =
      'packages/flame_3d/assets/shaders/shadow_caster_skinned.shaderbundle';

  late final Shader _vertexShader = VertexShader.fromAsset(
    _bundle,
    slots: [RenderContext3D.cameraMatricesBlock],
  );
  late final Shader _skinnedVertexShader = VertexShader.fromAsset(
    _skinnedBundle,
    slots: [
      RenderContext3D.cameraMatricesBlock,
      RenderContext3D.jointMatricesBlock,
    ],
  );
  late final Shader _fragmentShader = FragmentShader.fromAsset(
    _bundle,
    slots: [RenderContext3D.shadowCasterBlock],
  );

  /// Casters write their depth, whatever their material's state: opaque,
  /// depth tested, both faces.
  static const _renderState = RenderState.opaque;

  final Map<VertexLayout, _CasterPipeline> _pipelines = Map.identity();

  bool begin(DirectionalShadowProjection projection, Aabb3? sceneBounds) {
    if (recording) {
      throw StateError('A shadow pass is already being recorded');
    }
    final context = _context;
    final device = context.device;
    active = false;
    if (sceneBounds == null || !device.backend.supportsTextureTargets) {
      return false;
    }

    // The first directional light with shadows, among the ones the
    // directional lights block holds.
    final lights = context.lights;
    Light? light;
    ShadowSettings? settings;
    var index = 0;
    for (var i = 0; i < lights.length; i++) {
      final source = lights[i].source;
      if (source is! DirectionalLight) {
        continue;
      }
      if (index == RenderContext3D.maxDirectionalLights) {
        break;
      }
      final shadows = source.shadows;
      if (shadows != null) {
        light = lights[i];
        settings = shadows;
        break;
      }
      index++;
    }
    if (light == null || settings == null) {
      return false;
    }

    final direction = light.direction(_direction);
    final resolution = settings.resolution;
    if (!projection.update(
      direction: direction,
      casters: sceneBounds,
      receivers: settings.bounds,
      cameraViewProjection: settings.fit == ShadowFit.view
          ? context._viewProjectionMatrix
          : null,
      cameraView: context._viewMatrix,
      maxDistance: settings.maxDistance,
      resolution: resolution,
      stabilize: settings.stabilize,
    )) {
      return false;
    }
    // From here on, the values of the last map are replaced.
    version++;

    final float = switch (settings.encoding) {
      ShadowMapEncoding.auto => device.backend.supportsFloatTextureTargets,
      ShadowMapEncoding.float32 => true,
      ShadowMapEncoding.rgba8 => false,
    };
    final target = device.textureTarget(
      resolution,
      resolution,
      float ? GpuPixelFormat.r32Float : GpuPixelFormat.rgba8888,
    );
    if (!identical(target, _target)) {
      _target = target;
      _texture = Texture(
        null,
        width: resolution,
        height: resolution,
        gpuTexture: target.texture,
      );
    }
    _packDepth = !float;
    if (float) {
      _decode.setValues(1, 0, 0, 0);
    } else {
      _decode.setFrom(_packedDecode);
    }
    _lightViewProjection.setFrom(projection.viewProjection);
    _toLight.setValues(
      -direction.x,
      -direction.y,
      -direction.z,
      index.toDouble(),
    );
    final color = settings.color;
    _color.setValues(
      color.r,
      color.g,
      color.b,
      settings.strength.clamp(0, 1).toDouble(),
    );
    final size = resolution.toDouble();
    _map.setValues(size, size, 1 / size, 1 / size);
    _bias.setValues(
      math.max(projection.texelWidth, projection.texelHeight),
      settings.depthBias,
      settings.normalBias,
      settings.softness.toDouble(),
    );

    _mainView.setFrom(context._viewMatrix);
    _mainProjection.setFrom(context._projectionMatrix);
    context.setCamera(projection.view, projection.projection);
    recording = true;
    _drawCallsBefore = device.stats.drawCalls;
    device.beginTexturePass(target, frontFace: context.frontFace);
    device.stats.shadowPasses++;
    return true;
  }

  /// Makes the pass whose camera is set receive the map of the last shadow
  /// pass, when it is still the map of [mapVersion].
  bool reuse(int mapVersion) {
    if (recording) {
      throw StateError('A shadow pass is being recorded');
    }
    if (mapVersion != version || _texture == null) {
      return false;
    }
    active = true;
    return true;
  }

  void end() {
    if (!recording) {
      throw StateError('No shadow pass is being recorded');
    }
    final context = _context;
    final device = context.device;
    try {
      flushCasters();
    } finally {
      device.endTexturePass();
      device.stats.shadowDrawCalls += device.stats.drawCalls - _drawCallsBefore;
      recording = false;
      context.setCamera(_mainView, _mainProjection);
      active = true;
    }
  }

  /// Draws the recorded draws whose material casts shadows into the shadow
  /// map: grouped by pipeline and surface, front to back from the light, and
  /// batched across materials.
  void flushCasters() {
    final context = _context;
    final count = context._count;
    final order = context._opaque;
    var casters = 0;
    for (var i = 0; i < count; i++) {
      if (!context._materials[i]!.castsShadows) {
        continue;
      }
      final surface = context._surfaces[i]!;
      final caster = _casterFor(surface.layout);
      if (caster == null) {
        continue;
      }
      final pipeline = caster.pipeline;
      context._pipelines[i] = pipeline;
      context._groupKeys[i] = pipeline.id.toDouble();
      // Skinned draws are never batched: keep them apart from the others.
      context._surfaceKeys[i] =
          surface.id * 2 + (context._joints[i] == null ? 0 : 1);
      order[casters++] = i;
    }
    context._sort(order, casters, context._opaqueComparator);

    context._boundMaterial = null;
    context._bindingEpoch = -1;
    var start = 0;
    while (start < casters) {
      final first = order[start];
      var end = start + 1;
      // Skinned draws and draws of instances the caller filled (particle
      // systems, `drawInstances`) are drawn on their own.
      if (context._joints[first] == null && context._external[first] == null) {
        while (end < casters && _batchesWith(first, order[end])) {
          end++;
        }
      }
      _submit(order, start, end - start);
      start = end;
    }

    // Release the references to what was drawn.
    for (var i = 0; i < count; i++) {
      context._surfaces[i] = null;
      context._materials[i] = null;
      context._pipelines[i] = null;
      context._joints[i] = null;
      context._external[i] = null;
    }
    context._jointTransforms = null;
    context._lastDrawCount = count;
    context._count = 0;
  }

  bool _batchesWith(int first, int other) {
    final context = _context;
    return identical(context._surfaces[first], context._surfaces[other]) &&
        identical(context._pipelines[first], context._pipelines[other]) &&
        context._joints[other] == null &&
        context._external[other] == null;
  }

  void _submit(Int32List order, int start, int count) {
    final context = _context;
    final device = context.device;
    final first = order[start];
    final surface = context._surfaces[first]!;
    final vertexShader = _pipelines[surface.layout]!.skinned
        ? _skinnedVertexShader
        : _vertexShader;

    device.bindPipeline(context._pipelines[first]!);
    if (device.bindingEpoch != context._bindingEpoch) {
      context
        .._bindingEpoch = device.bindingEpoch
        .._bindSlots(vertexShader, RenderContext3D._passScope)
        .._bindSlots(_fragmentShader, RenderContext3D._passScope);
    }
    device
      ..setRenderState(_renderState)
      ..setFrontFace(WindingOrder.counterClockwise);
    context._bindJoints(vertexShader, context._joints[first]);
    device.bindSurface(surface);
    final external = context._external[first];
    if (external != null) {
      final instanceCount = context._externalCounts[first];
      device
        ..bindInstances(external, instanceCount)
        ..drawSurface(surface, instanceCount: instanceCount);
      return;
    }
    context._gatherInstances(order, start, count);
    device
      ..bindInstances(context._batchInstances, count)
      ..drawSurface(surface, instanceCount: count);
  }

  /// The caster pipeline for surfaces laid out as [layout], or `null` when
  /// they have no position.
  _CasterPipeline? _casterFor(VertexLayout layout) {
    var caster = _pipelines[layout];
    if (caster == null) {
      final position = layout.attribute(VertexLayout.positionAttribute);
      final skinned =
          layout.attribute('vertexJoints')?.components == 4 &&
          layout.attribute('vertexWeights')?.components == 4;
      caster = _pipelines[layout] = _CasterPipeline(
        drawable: position != null && position.components == 3,
        skinned: skinned,
      );
    }
    if (!caster.drawable) {
      return null;
    }
    final vertexShader = caster.skinned ? _skinnedVertexShader : _vertexShader;
    final fragmentShader = _fragmentShader;
    // Resolve the resources first: recreating them bumps their generation.
    vertexShader.resource;
    fragmentShader.resource;
    if (caster._pipeline == null ||
        caster._vertexGeneration != vertexShader.generation ||
        caster._fragmentGeneration != fragmentShader.generation) {
      caster
        .._pipeline = _context.device.pipelineFor(
          vertexShader,
          fragmentShader,
          layout,
        )
        .._vertexGeneration = vertexShader.generation
        .._fragmentGeneration = fragmentShader.generation;
    }
    return caster;
  }

  void writeShadows(UniformBlock block) {
    if (!active) {
      block.setVector4('toLight', _noShadows);
      return;
    }
    block
      ..setMatrix4('lightViewProjection', _lightViewProjection)
      ..setVector4('toLight', _toLight)
      ..setVector4('color', _color)
      ..setVector4('map', _map)
      ..setVector4('bias', _bias)
      ..setVector4('decode', _decode);
  }

  /// Writes how the shaders that render shadow maps store depths.
  static void writeCasterUniforms(
    RenderContext3D context,
    UniformBlock block,
  ) {
    block.setFloat('packDepth', context._shadows._packDepth ? 1 : 0);
  }

  /// The shadow map of the pass, or a white texture without shadows.
  static Texture shadowMapTexture(RenderContext3D context) {
    final shadows = context._shadows;
    return shadows.active ? shadows._texture! : Texture.standard;
  }
}

/// The pipeline that renders the depth of surfaces of one vertex layout into
/// a shadow map.
class _CasterPipeline({
  /// Whether the layout has a position to draw.
  required final bool drawable,

  /// Whether the layout has joints and joint weights.
  required final bool skinned,
}) {
  DevicePipeline? _pipeline;
  int _vertexGeneration = -1;
  int _fragmentGeneration = -1;

  DevicePipeline get pipeline => _pipeline!;
}
