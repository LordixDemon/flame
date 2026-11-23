part of 'render_context_3d.dart';

/// Half-resolution clip-depth + view-space normal prepass enabling mobile SSAO,
/// 3D Depth of Field, Soft Particles (`ParticleMaterial.softDepthFade`), and
/// shoreline intersection foam (`WaterMaterial.shoreFoamDepth`) on every
/// Flutter GPU backend without sampling depth-stencil attachments.
class _DepthNormalPass(final RenderContext3D _context) {
  bool recording = false;
  bool active = false;

  GpuTextureTarget? _target;
  Texture? _texture;
  int _width = 1;
  int _height = 1;

  static const _bundle =
      'packages/flame_3d/assets/shaders/depth_normal_prepass.shaderbundle';
  static const _skinnedBundle =
      'packages/flame_3d/assets/shaders/'
      'depth_normal_prepass_skinned.shaderbundle';

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
  late final Shader _fragmentShader = FragmentShader.fromAsset(_bundle);

  static const _renderState = RenderState.opaque;
  final Map<VertexLayout, _CasterPipeline> _pipelines = Map.identity();

  bool begin(int sceneWidth, int sceneHeight) {
    if (recording) {
      throw StateError('A depth-normal prepass is already being recorded');
    }
    final context = _context;
    final device = context.device;
    active = false;
    if (!device.backend.supportsTextureTargets) {
      return false;
    }

    _width = math.max(1, sceneWidth >> 1);
    _height = math.max(1, sceneHeight >> 1);
    final target = device.textureTarget(
      _width,
      _height,
      GpuPixelFormat.rgba8888,
      clearValue: const Color(0xFFFF8080),
      role: _DepthNormalPass,
    );
    if (!identical(target, _target)) {
      _target = target;
      _texture = Texture(
        null,
        width: _width,
        height: _height,
        sampler: TextureSampler.linear,
        gpuTexture: target.texture,
      );
    }

    recording = true;
    device.beginTexturePass(target, frontFace: context.frontFace);
    return true;
  }

  void end() {
    if (!recording) {
      throw StateError('No depth-normal prepass is being recorded');
    }
    final context = _context;
    final device = context.device;
    try {
      _flushOpaqueDepthNormals();
    } finally {
      device.endTexturePass();
      recording = false;
      active = true;
    }
  }

  void clear() {
    active = false;
  }

  void _flushOpaqueDepthNormals() {
    final context = _context;
    final count = context._count;
    final order = context._opaque;
    final groupKeys = context._groupKeys;
    final surfaceKeys = context._surfaceKeys;
    final sortDepths = context._sortDepths;
    var opaqueCount = 0;
    // Draws whose material has a depthNormalMaterial, from the end of
    // `order` backwards.
    var ownCount = 0;

    VertexLayout? lastLayout;
    _CasterPipeline? pipe;
    for (var i = 0; i < count; i++) {
      final mat = context._materials[i]!;
      if (mat.renderState.translucent || !mat.renderState.depthWrite) {
        continue;
      }
      if (mat.depthNormalMaterial != null) {
        order[count - 1 - ownCount++] = i;
        continue;
      }
      if (!mat.instancesHoldModelMatrices) {
        continue;
      }
      final surface = context._surfaces[i]!;
      final layout = surface.layout;
      if (!identical(layout, lastLayout)) {
        lastLayout = layout;
        pipe = _pipelineFor(layout);
      }
      if (pipe == null) {
        continue;
      }
      final pipeline = pipe.pipeline;
      context._pipelines[i] = pipeline;
      groupKeys[i] = pipeline.id.toDouble();
      surfaceKeys[i] = surface.id * 2 + (context._joints[i] == null ? 0 : 1);
      sortDepths[i] = context._depths[i];
      order[opaqueCount++] = i;
    }

    context._sort(order, opaqueCount);
    context._boundMaterial = null;
    context._bindingEpoch = -1;

    var start = 0;
    while (start < opaqueCount) {
      final first = order[start];
      var end = start + 1;
      if (context._joints[first] == null && context._external[first] == null) {
        while (end < opaqueCount && _batchesWith(first, order[end])) {
          end++;
        }
      }
      _submit(order, start, end - start);
      start = end;
    }
    if (ownCount > 0) {
      final ownStart = count - ownCount;
      if (ownCount > 1) {
        for (var i = ownStart + 1; i < count; i++) {
          final key = order[i];
          final keyMat = context._materials[key]!.depthNormalMaterial!.id;
          final keySurf = context._surfaces[key]!.id;
          var j = i - 1;
          while (j >= ownStart) {
            final cur = order[j];
            final curMat = context._materials[cur]!.depthNormalMaterial!.id;
            final curSurf = context._surfaces[cur]!.id;
            if (curMat < keyMat || (curMat == keyMat && curSurf <= keySurf)) {
              break;
            }
            order[j + 1] = cur;
            j--;
          }
          order[j + 1] = key;
        }
      }
      var ownCursor = ownStart;
      while (ownCursor < count) {
        final first = order[ownCursor];
        var ownEnd = ownCursor + 1;
        if (context._joints[first] == null &&
            context._external[first] == null) {
          final firstMat = context._materials[first]!.depthNormalMaterial!;
          final firstSurf = context._surfaces[first]!;
          while (ownEnd < count) {
            final other = order[ownEnd];
            if (context._joints[other] != null ||
                context._external[other] != null ||
                !identical(
                  context._materials[other]!.depthNormalMaterial,
                  firstMat,
                ) ||
                !identical(context._surfaces[other], firstSurf)) {
              break;
            }
            ownEnd++;
          }
        }
        _submitOwnBatch(order, ownCursor, ownEnd - ownCursor);
        ownCursor = ownEnd;
      }
    }

    context
      .._releaseDraws(count)
      .._jointTransforms = null;
    context._lastDrawCount = count;
    context._count = 0;
  }

  bool _batchesWith(int first, int other) =>
      _context._batchesBasic(first, other);

  void _submit(Int32List order, int start, int count) {
    final context = _context;
    final device = context.device;
    final first = order[start];
    final surface = context._surfaces[first]!;
    final vertexShader = _pipelines[surface.layout]!.vertexShader!;

    final joints = context._joints[first];
    device.bindPipeline(context._pipelines[first]!);
    if (device.bindingEpoch != context._bindingEpoch) {
      context
        .._bindingEpoch = device.bindingEpoch
        .._bindPassPlan(
          context._planFor(vertexShader),
          skipJoints: joints != null,
        );
    }
    device
      ..setRenderState(_renderState)
      ..setFrontFace(context.frontFace);
    context._bindJoints(vertexShader, joints);
    context._drawBatchGeometry(surface, order, start, count);
  }

  /// Submits [batchCount] matching draws starting at [position] in [order] with
  /// their custom [Material.depthNormalMaterial].
  void _submitOwnBatch(Int32List order, int position, int batchCount) {
    final context = _context;
    final device = context.device;
    final draw = order[position];
    final material = context._materials[draw]!.depthNormalMaterial!;
    final surface = context._surfaces[draw]!;
    final pipeline = context._pipelineFor(material, surface.layout);
    if (!pipeline.instanced) {
      throw StateError(
        'A depthNormalMaterial needs a vertex shader that reads the instance '
        'inputs (the four instanceModel columns)',
      );
    }
    final vertexShader = material.vertexShaderFor(surface.layout);
    final fragmentShader = material.fragmentShaderFor(context, surface.layout);
    final joints = context._joints[draw];
    device.bindPipeline(pipeline);
    context
      .._bindPassSlots(
        material,
        vertexShader,
        fragmentShader: fragmentShader,
        skipJoints: joints != null,
      )
      .._jointTransforms = joints
      .._applyMaterial(material, vertexShader, fragmentShader)
      .._bindJoints(vertexShader, joints)
      // The next draw binds its own slots again.
      .._bindingEpoch = -1
      .._boundMaterial = null;
    device
      ..setRenderState(_renderState)
      ..setFrontFace(context.frontFace);
    context._drawBatchGeometry(surface, order, position, batchCount);
  }

  _CasterPipeline? _pipelineFor(VertexLayout layout) => _CasterPipeline.resolve(
    _context.device,
    _pipelines,
    layout,
    _vertexShader,
    _skinnedVertexShader,
    _fragmentShader,
  );

  static void writeUniforms(RenderContext3D context, UniformBlock block) {
    final dn = context._depthNormal;
    final off =
        (block.cachedWriterOffsets as int?) ??
        (block.cachedWriterOffsets = block.resolveOffset('params'));
    if (off >= 0) {
      block.writeVec4ValuesAt(
        off,
        dn.active ? 1.0 : 0.0,
        1.0 / dn._width,
        1.0 / dn._height,
        0.0,
      );
    }
  }

  static Texture passTexture(RenderContext3D context) {
    final dn = context._depthNormal;
    return dn.active ? dn._texture! : Texture.standard;
  }
}
