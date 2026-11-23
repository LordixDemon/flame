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
    final queue = context._queue;
    final count = queue.count;
    final order = queue.opaque;
    final ownOrder = queue.translucent;
    final groupKeysHi = queue.groupKeysHi;
    final groupKeysLo = queue.groupKeysLo;
    final surfaceKeys = queue.surfaceKeys;
    final sortDepths = queue.sortDepths;
    var opaqueCount = 0;
    var ownCount = 0;

    VertexLayout? lastLayout;
    _CasterPipeline? pipe;
    for (var i = 0; i < count; i++) {
      final mat = queue.materials[i]!;
      if (mat.renderState.translucent || !mat.renderState.depthWrite) {
        continue;
      }
      final surface = queue.surfaces[i]!;
      final depthNormalMat = mat.depthNormalMaterial;
      if (depthNormalMat != null) {
        groupKeysHi[i] = depthNormalMat.id;
        groupKeysLo[i] = 0;
        surfaceKeys[i] = surface.id * 2 + (queue.joints[i] == null ? 0 : 1);
        sortDepths[i] = queue.depths[i];
        ownOrder[ownCount++] = i;
        continue;
      }
      if (!mat.instancesHoldModelMatrices) {
        continue;
      }
      final layout = surface.layout;
      if (!identical(layout, lastLayout)) {
        lastLayout = layout;
        pipe = _pipelineFor(layout);
      }
      if (pipe == null) {
        continue;
      }
      final pipeline = pipe.pipeline;
      queue.pipelines[i] = pipeline;
      groupKeysHi[i] = pipeline.id;
      groupKeysLo[i] = 0;
      surfaceKeys[i] = surface.id * 2 + (queue.joints[i] == null ? 0 : 1);
      sortDepths[i] = queue.depths[i];
      order[opaqueCount++] = i;
    }

    queue.sort(order, opaqueCount);
    context
      .._boundMaterial = null
      .._bindingEpoch = -1;

    var start = 0;
    while (start < opaqueCount) {
      final first = order[start];
      var end = start + 1;
      if (queue.joints[first] == null && queue.external[first] == null) {
        while (end < opaqueCount && _batchesWith(first, order[end])) {
          end++;
        }
      }
      _submit(order, start, end - start);
      start = end;
    }
    if (ownCount > 0) {
      queue.sort(ownOrder, ownCount);
      var ownCursor = 0;
      while (ownCursor < ownCount) {
        final first = ownOrder[ownCursor];
        var ownEnd = ownCursor + 1;
        if (queue.joints[first] == null && queue.external[first] == null) {
          final firstMat = queue.materials[first]!.depthNormalMaterial!;
          final firstSurf = queue.surfaces[first]!;
          while (ownEnd < ownCount) {
            final other = ownOrder[ownEnd];
            if (queue.joints[other] != null ||
                queue.external[other] != null ||
                !identical(
                  queue.materials[other]!.depthNormalMaterial,
                  firstMat,
                ) ||
                !identical(queue.surfaces[other], firstSurf)) {
              break;
            }
            ownEnd++;
          }
        }
        _submitOwnBatch(ownOrder, ownCursor, ownEnd - ownCursor);
        ownCursor = ownEnd;
      }
    }

    queue.release(count, context._oitGrab);
    context._jointCache.activeTransforms = null;
    queue.lastDrawCount = count;
    queue.count = 0;
  }

  bool _batchesWith(int first, int other) =>
      _context._queue.batchesBasic(first, other);

  void _submit(Int32List order, int start, int count) {
    final context = _context;
    final queue = context._queue;
    final device = context.device;
    final first = order[start];
    final surface = queue.surfaces[first]!;
    final vertexShader = _pipelines[surface.layout]!.vertexShader!;

    final joints = queue.joints[first];
    device.bindPipeline(queue.pipelines[first]!);
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
    final queue = context._queue;
    final cache = context._pipelineCache;
    final device = context.device;
    final draw = order[position];
    final material = queue.materials[draw]!.depthNormalMaterial!;
    final surface = queue.surfaces[draw]!;
    cache.resolve(context, material, surface.layout);
    final pipeline = cache.lastDev!;
    if (!pipeline.instanced) {
      throw StateError(
        'A depthNormalMaterial needs a vertex shader that reads the instance '
        'inputs (the four instanceModel columns)',
      );
    }
    final vertexShader = cache.lastVert!;
    final fragmentShader = cache.lastFrag!;
    final joints = queue.joints[draw];
    device.bindPipeline(pipeline);
    context
      .._bindPassSlots(
        material,
        vertexShader,
        fragmentShader: fragmentShader,
        skipJoints: joints != null,
      )
      .._jointCache.activeTransforms = joints
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
