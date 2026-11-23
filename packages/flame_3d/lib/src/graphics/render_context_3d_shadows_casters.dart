part of 'render_context_3d.dart';

extension _ShadowPassCasters on _ShadowPass {
  void flushCasters() {
    final context = _context;
    final queue = context._queue;
    final count = queue.count;
    final order = queue.opaque;
    final groupKeysHi = queue.groupKeysHi;
    final groupKeysLo = queue.groupKeysLo;
    final surfaceKeys = queue.surfaceKeys;
    final sortDepths = queue.sortDepths;
    var casters = 0;
    VertexLayout? lastLayout;
    _CasterPipeline? caster;
    for (var i = 0; i < count; i++) {
      // The caster shaders read every instance as a model matrix: draws
      // whose instances hold something else (billboards, ribbons) cannot
      // cast where they are, so they cast nothing.
      final material = queue.materials[i]!;
      if (!material.castsShadows || !material.instancesHoldModelMatrices) {
        continue;
      }
      final surface = queue.surfaces[i]!;
      final layout = surface.layout;
      if (!identical(layout, lastLayout)) {
        lastLayout = layout;
        caster = _activeCasterFor(layout);
      }
      if (caster == null) {
        continue;
      }
      final pipeline = caster.pipeline;
      queue.pipelines[i] = pipeline;
      groupKeysHi[i] = pipeline.id;
      groupKeysLo[i] = 0;
      surfaceKeys[i] = surface.id * 2 + (queue.joints[i] == null ? 0 : 1);
      sortDepths[i] = queue.depths[i];
      order[casters++] = i;
    }
    queue.sort(order, casters);
    RenderProfile.lap(RenderPhase.sort);

    context
      .._boundMaterial = null
      .._bindingEpoch = -1;
    var start = 0;
    while (start < casters) {
      final first = order[start];
      var end = start + 1;
      if (queue.joints[first] == null && queue.external[first] == null) {
        while (end < casters && _batchesWith(first, order[end])) {
          end++;
        }
      }
      _submit(order, start, end - start);
      start = end;
    }

    queue.release(count, context._oitGrab);
    context._jointCache.activeTransforms = null;
    queue.lastDrawCount = count;
    queue.count = 0;
    RenderProfile.lap(RenderPhase.release);
  }

  bool _batchesWith(int first, int other) =>
      _context._queue.batchesBasic(first, other);

  void _submit(Int32List order, int start, int count) {
    final context = _context;
    final queue = context._queue;
    final device = context.device;
    final first = order[start];
    final surface = queue.surfaces[first]!;
    final caster = _activeCasters[surface.layout]!;
    final vertexShader = caster.vertexShader!;
    final fragmentShader = caster.fragmentShader!;
    UniformBlock? paraboloidBlock;
    if (_recordingParaboloidTile) {
      final pb = paraboloidBlock = vertexShader.block('ParaboloidLight');
      final pOff =
          (pb.cachedWriterOffsets as _ParaboloidOffsets?) ??
          (pb.cachedWriterOffsets = _ParaboloidOffsets(pb));
      if (pOff.tileEpoch != _paraboloidTileEpoch) {
        pOff.tileEpoch = _paraboloidTileEpoch;
        if (pOff.posInvRange >= 0) {
          pb.writeVec4ValuesAt(
            pOff.posInvRange,
            _paraboloidPosInvRange.x,
            _paraboloidPosInvRange.y,
            _paraboloidPosInvRange.z,
            _paraboloidPosInvRange.w,
          );
        }
        if (pOff.params >= 0) {
          pb.writeVec4ValuesAt(
            pOff.params,
            _paraboloidParams.x,
            _paraboloidParams.y,
            _paraboloidParams.z,
            _paraboloidParams.w,
          );
        }
      }
    }
    RenderProfile.lap(RenderPhase.batch);

    final joints = queue.joints[first];
    device.bindPipeline(queue.pipelines[first]!);
    if (device.bindingEpoch != context._bindingEpoch) {
      context
        .._bindingEpoch = device.bindingEpoch
        .._bindPassPlan(
          context._planFor(vertexShader),
          skipJoints: joints != null,
        )
        .._bindPassPlan(context._planFor(fragmentShader), skipJoints: true);
    }
    if (paraboloidBlock != null) {
      device.bindUniformBlock(paraboloidBlock);
    }
    device
      ..setRenderState(_ShadowPass._renderState)
      ..setFrontFace(WindingOrder.counterClockwise);
    RenderProfile.lap(RenderPhase.state);
    context._bindJoints(vertexShader, joints);
    context._drawBatchGeometry(surface, order, start, count);
    RenderProfile.lap(RenderPhase.draw);
  }

  /// The pipelines of the casters being recorded: of a paraboloid tile or
  /// not, of moving casters (over the kept layer of the still ones) or not.
  Map<VertexLayout, _CasterPipeline> get _activeCasters => _recordingMovers
      ? (_recordingParaboloidTile
            ? _paraboloidMovingPipelines
            : _movingPipelines)
      : (_recordingParaboloidTile ? _paraboloidPipelines : _pipelines);

  /// The pipeline that draws the casters of [layout] being recorded, see
  /// [_activeCasters], or `null` when they cannot be drawn.
  _CasterPipeline? _activeCasterFor(VertexLayout layout) {
    if (_recordingMovers) {
      return _recordingParaboloidTile
          ? _casterIn(
              _paraboloidMovingPipelines,
              layout,
              _paraboloidMovingVertexShader,
              _paraboloidMovingSkinnedVertexShader,
              _paraboloidMovingFragmentShader,
            )
          : _casterIn(
              _movingPipelines,
              layout,
              _movingVertexShader,
              _movingSkinnedVertexShader,
              _movingFragmentShader,
            );
    }
    return _recordingParaboloidTile
        ? _casterIn(
            _paraboloidPipelines,
            layout,
            _paraboloidVertexShader,
            _paraboloidSkinnedVertexShader,
            _paraboloidFragmentShader,
          )
        : _casterIn(
            _pipelines,
            layout,
            _vertexShader,
            _skinnedVertexShader,
            _fragmentShader,
          );
  }

  _CasterPipeline? _casterIn(
    Map<VertexLayout, _CasterPipeline> pipelines,
    VertexLayout layout,
    Shader vertex,
    Shader skinnedVertex,
    Shader fragment,
  ) => _CasterPipeline.resolve(
    _context.device,
    pipelines,
    layout,
    vertex,
    skinnedVertex,
    fragment,
  );
}

class _CasterPipeline({
  required final bool drawable,
  required final bool skinned,
}) {
  DevicePipeline? _pipeline;
  int _vertexGeneration = -1;
  int _fragmentGeneration = -1;

  // The shaders of [pipeline].
  Shader? vertexShader;
  Shader? fragmentShader;

  DevicePipeline get pipeline => _pipeline!;

  /// Finds or builds a cached caster pipeline for [layout], or `null` when
  /// [layout] has no 3-component position attribute.
  static _CasterPipeline? resolve(
    GraphicsDevice device,
    Map<VertexLayout, _CasterPipeline> pipelines,
    VertexLayout layout,
    Shader vertex,
    Shader skinnedVertex,
    Shader fragment,
  ) {
    var caster = pipelines[layout];
    if (caster == null) {
      final position = layout.attribute(VertexLayout.positionAttribute);
      final skinned =
          layout.attribute('vertexJoints')?.components == 4 &&
          layout.attribute('vertexWeights')?.components == 4;
      caster = pipelines[layout] = _CasterPipeline(
        drawable: position != null && position.components == 3,
        skinned: skinned,
      );
    }
    if (!caster.drawable) {
      return null;
    }
    final vertexShader = caster.skinned ? skinnedVertex : vertex;
    final fragmentShader = fragment;
    vertexShader.resource;
    fragmentShader.resource;
    if (caster._pipeline == null ||
        caster._vertexGeneration != vertexShader.generation ||
        caster._fragmentGeneration != fragmentShader.generation) {
      caster
        .._pipeline = device.pipelineFor(
          vertexShader,
          fragmentShader,
          layout,
        )
        .._vertexGeneration = vertexShader.generation
        .._fragmentGeneration = fragmentShader.generation
        ..vertexShader = vertexShader
        ..fragmentShader = fragmentShader;
    }
    return caster;
  }
}

/// The kept layers of still casters of one projection
/// ([ShadowSettings.cacheStillCasters]): one per view (the single map, or
/// each tile of the atlas), and the map the receivers sample, kept to be
/// reused whole while nothing changes.
