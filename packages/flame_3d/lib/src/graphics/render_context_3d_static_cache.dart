part of 'render_context_3d.dart';

/// Captures cached static layer-0 clip-depth + direct-sun share and restores
/// cached static color/depth with optional moving-shadow projection on hit
/// frames (`World3D.staticSceneCache`).
class _StaticCachePass(final RenderContext3D _context) {
  static const _depthBundle =
      'packages/flame_3d/assets/shaders/static_depth.shaderbundle';
  static const _depthBatchedBundle =
      'packages/flame_3d/assets/shaders/static_depth_batched.shaderbundle';
  static const _restoreBundle =
      'packages/flame_3d/assets/shaders/static_restore.shaderbundle';

  static const String _paramsBlock = 'StaticDepthParams';
  static const String _restoreBlock = 'StaticRestore';

  late final Shader _depthVert = VertexShader.fromAsset(
    _depthBundle,
    slots: [RenderContext3D.cameraMatricesBlock],
  );
  late final Shader _depthBatchedVert = VertexShader.fromAsset(
    _depthBatchedBundle,
    slots: [
      RenderContext3D.cameraMatricesBlock,
      RenderContext3D.batchObjectsBlock,
    ],
  );
  late final Shader _depthFrag = FragmentShader.fromAsset(
    _depthBundle,
    slots: const [_paramsBlock],
  );

  late final Shader _restoreVert = VertexShader.fromAsset(_restoreBundle);
  late final Shader _restoreFrag = FragmentShader.fromAsset(
    _restoreBundle,
    slots: [
      _restoreBlock,
      'staticColorTexture',
      'staticDepthTexture',
      RenderContext3D.shadowMapSampler,
      'stillShadowMap',
    ],
  );

  bool? _shadersLoad;
  bool get shadersAvailable {
    final known = _shadersLoad;
    if (known != null) {
      return known;
    }
    try {
      _depthVert.resource;
      _depthBatchedVert.resource;
      _depthFrag.resource;
      _restoreVert.resource;
      _restoreFrag.resource;
      return _shadersLoad = true;
    } on UnsupportedError {
      return _shadersLoad = false;
    } on StateError {
      return _shadersLoad = false;
    }
  }

  final Map<VertexLayout, _StaticDepthPipeline> _depthPipelines =
      Map.identity();

  DevicePipeline? _restorePipeline;
  int _restoreVertGen = -1;
  int _restoreFragGen = -1;
  GpuUniformSlot? _staticColorSlot;
  GpuUniformSlot? _staticDepthSlot;
  GpuUniformSlot? _shadowMapSlot;
  GpuUniformSlot? _stillShadowSlot;
  _StaticRestoreOffsets? _restoreOffsets;
  _StaticDepthParamOffsets? _depthParamOffsets;

  final Matrix4 _invVp = Matrix4.identity();
  final Vector3 _sunDirScratch = Vector3.zero();
  final Vector3 _hemiUpScratch = Vector3(0, 1, 0);

  static const RenderState _restoreRenderState = RenderState(
    depthCompare: CompareFunction.always,
  );

  final Map<CullMode, RenderState> _depthStates = {};

  void flushStaticDepthOnly() {
    final context = _context;
    final queue = context._queue;
    final device = context.device;
    final count = queue.count;
    final order = queue.opaque;
    final isStatic = queue.isStatic;
    final groupKeysHi = queue.groupKeysHi;
    final groupKeysLo = queue.groupKeysLo;
    final surfaceKeys = queue.surfaceKeys;
    final sortDepths = queue.sortDepths;

    var depthCount = 0;
    VertexLayout? lastLayout;
    _StaticDepthPipeline? pipe;
    for (var i = 0; i < count; i++) {
      if (isStatic[i] != 1) {
        continue;
      }
      final surface = queue.surfaces[i]!;
      final layout = surface.layout;
      if (!identical(layout, lastLayout)) {
        lastLayout = layout;
        pipe = _StaticDepthPipeline.resolve(
          device,
          _depthPipelines,
          layout,
          _depthVert,
          _depthBatchedVert,
          _depthFrag,
        );
      }
      if (pipe == null) {
        continue;
      }
      final material = queue.materials[i]!;
      final pipeline = pipe.pipeline;
      queue.pipelines[i] = pipeline;
      groupKeysHi[i] = pipeline.id;
      groupKeysLo[i] =
          (material.renderState.cullMode.index << 1) | queue.mirrored[i];
      surfaceKeys[i] = surface.id;
      sortDepths[i] = queue.depths[i];
      order[depthCount++] = i;
    }

    if (depthCount == 0) {
      return;
    }
    if (depthCount > 1) {
      queue.sort(order, depthCount);
    }

    _writeStaticDepthParams(order, depthCount);

    context
      .._boundMaterial = null
      .._bindingEpoch = -1;

    var start = 0;
    while (start < depthCount) {
      final first = order[start];
      var end = start + 1;
      if (queue.joints[first] == null &&
          queue.external[first] == null &&
          queue.batches[first] == null) {
        while (end < depthCount && _batchesStaticDepth(first, order[end])) {
          end++;
        }
      }
      _submitDepthBatch(order, start, end - start);
      start = end;
    }
  }

  bool _batchesStaticDepth(int first, int other) {
    final queue = _context._queue;
    return queue.batchesBasic(first, other) &&
        queue.materials[first]!.renderState.cullMode ==
            queue.materials[other]!.renderState.cullMode &&
        queue.mirrored[first] == queue.mirrored[other];
  }

  void _writeStaticDepthParams(Int32List order, int depthCount) {
    _depthFrag.resource;
    final block = _depthFrag.block(_paramsBlock);
    final off = _depthParamOffsets ??= _StaticDepthParamOffsets(block);
    final context = _context;
    final lightState = context._lightState
      ..ensureLightSelection(context._pass, context.cameraMask);

    double luma(Color c) => 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;

    StylizedMaterial? stylized;
    final materials = context._queue.materials;
    for (var i = 0; i < depthCount; i++) {
      final mat = materials[order[i]];
      if (mat is StylizedMaterial) {
        stylized = mat;
        break;
      }
    }
    final ambientBaseFactor = stylized != null
        ? luma(stylized.ambientBase)
        : 0.65;
    final skyFillFactor = stylized?.skyFill ?? 0.35;
    final groundBounceFactor = stylized?.groundBounce ?? 0.10;

    final ambient = lightState.selAmbient;
    var ambBase = ambient != null
        ? luma(ambient.color) * ambient.intensity
        : 0.0;
    var skyLuma = 0.0;
    var groundLuma = 0.0;
    final hemi = lightState.selHemisphere;
    if (hemi != null) {
      ambBase += hemi.intensity * ambientBaseFactor;
      skyLuma = hemi.intensity * luma(hemi.skyColor) * skyFillFactor;
      groundLuma = hemi.intensity * luma(hemi.groundColor) * groundBounceFactor;
      _hemiUpScratch.setFrom(hemi.up);
      if (_hemiUpScratch.length2 > 0) {
        _hemiUpScratch.normalize();
      } else {
        _hemiUpScratch.setValues(0, 1, 0);
      }
    } else {
      _hemiUpScratch.setValues(0, 1, 0);
    }

    final shadows = context._shadows;
    final dirIndex = shadows._toLight.w.round();
    var hasSun = false;
    var sunLuma = 0.0;
    if (shadows.active &&
        !shadows.atlasActive &&
        dirIndex >= 0 &&
        dirIndex < lightState.selDirectionals.length) {
      final sun = lightState.selDirectionals[dirIndex];
      final sunSrc = sun.source as DirectionalLight;
      hasSun = true;
      sunLuma = luma(sunSrc.color) * sunSrc.intensity;
      _sunDirScratch.setValues(
        shadows._toLight.x,
        shadows._toLight.y,
        shadows._toLight.z,
      );
      if (_sunDirScratch.length2 > 0) {
        _sunDirScratch.normalize();
      }
    } else {
      _sunDirScratch.setValues(0, 1, 0);
    }

    if (off.sunDirIntensity >= 0) {
      block.writeVec4ValuesAt(
        off.sunDirIntensity,
        _sunDirScratch.x,
        _sunDirScratch.y,
        _sunDirScratch.z,
        sunLuma,
      );
    }
    if (off.ambientLuma >= 0) {
      block.writeVec4ValuesAt(
        off.ambientLuma,
        ambBase,
        skyLuma,
        groundLuma,
        hasSun ? 1.0 : 0.0,
      );
    }
    if (off.hemiUp >= 0) {
      block.writeVec4ValuesAt(
        off.hemiUp,
        _hemiUpScratch.x,
        _hemiUpScratch.y,
        _hemiUpScratch.z,
        0.0,
      );
    }
  }

  void _submitDepthBatch(Int32List order, int start, int count) {
    final context = _context;
    final queue = context._queue;
    final device = context.device;
    final first = order[start];
    final surface = queue.surfaces[first]!;
    final pipe = _depthPipelines[surface.layout]!;
    final vertexShader = pipe.vertexShader!;
    final fragmentShader = _depthFrag;

    device.bindPipeline(pipe.pipeline);
    if (device.bindingEpoch != context._bindingEpoch) {
      context
        .._bindingEpoch = device.bindingEpoch
        .._bindPassPlan(context._planFor(vertexShader), skipJoints: true);
      device.bindUniformBlock(fragmentShader.block(_paramsBlock));
    }

    final cull = queue.materials[first]!.renderState.cullMode;
    final depthState = _depthStates[cull] ??= RenderState.opaque.copyWith(
      cullMode: cull,
    );
    device
      ..setRenderState(depthState)
      ..setFrontFace(
        (queue.mirrored[first] == 1) == context._camera.isMirrored
            ? WindingOrder.counterClockwise
            : WindingOrder.clockwise,
      );

    final batch = queue.batches[first];
    if (batch != null) {
      context._bindBatchObjects(vertexShader, batch);
      device
        ..bindSurface(surface)
        ..drawSurface(surface);
    } else {
      context._drawBatchGeometry(surface, order, start, count);
    }
  }

  void drawStaticRestore({
    required Texture staticColor,
    required Texture staticDepth,
    required double zNear,
    required double zFar,
    required bool projectMovingShadows,
    required List<Vector4> movingBounds,
    int movingBoundsCount = 1,
  }) {
    final context = _context;
    final device = context.device;
    _restoreVert.resource;
    _restoreFrag.resource;
    var pipeline = _restorePipeline;
    if (pipeline == null ||
        _restoreVertGen != _restoreVert.generation ||
        _restoreFragGen != _restoreFrag.generation) {
      pipeline = _restorePipeline = device.pipelineFor(
        _restoreVert,
        _restoreFrag,
        fullscreenQuadSurface.layout,
      );
      _restoreVertGen = _restoreVert.generation;
      _restoreFragGen = _restoreFrag.generation;
      _staticColorSlot = _restoreFrag.slot('staticColorTexture');
      _staticDepthSlot = _restoreFrag.slot('staticDepthTexture');
      _shadowMapSlot = _restoreFrag.slot(RenderContext3D.shadowMapSampler);
      _stillShadowSlot = _restoreFrag.slot('stillShadowMap');
      _restoreOffsets = null;
    }

    final block = _restoreFrag.block(_restoreBlock);
    final off = _restoreOffsets ??= _StaticRestoreOffsets(block);

    _invVp.setFrom(context.viewProjection);
    if (_invVp.invert() == 0.0) {
      _invVp.setIdentity();
    }

    final shadows = context._shadows;
    if (off.invViewProjection >= 0) {
      block.writeMatrix4At(off.invViewProjection, _invVp);
    }
    if (off.lightViewProjection >= 0) {
      block.writeMatrix4At(
        off.lightViewProjection,
        shadows._lightViewProjection,
      );
    }
    if (off.depthRange >= 0) {
      block.writeVec4ValuesAt(
        off.depthRange,
        zNear,
        zFar,
        projectMovingShadows ? 1.0 : 0.0,
        movingBoundsCount.toDouble(),
      );
    }
    if (off.shadowToLight >= 0) {
      block.writeVec4ValuesAt(
        off.shadowToLight,
        shadows._toLight.x,
        shadows._toLight.y,
        shadows._toLight.z,
        shadows._toLight.w,
      );
    }
    if (off.shadowColor >= 0) {
      block.writeVec4ValuesAt(
        off.shadowColor,
        shadows._color.x,
        shadows._color.y,
        shadows._color.z,
        shadows._color.w,
      );
    }
    if (off.shadowMapSize >= 0) {
      block.writeVec4ValuesAt(
        off.shadowMapSize,
        shadows._map.x,
        shadows._map.y,
        shadows._map.z,
        shadows._map.w,
      );
    }
    if (off.shadowBias >= 0) {
      block.writeVec4ValuesAt(
        off.shadowBias,
        shadows._bias.x,
        shadows._bias.y,
        shadows._bias.z,
        shadows._bias.w,
      );
    }
    if (off.shadowDecode >= 0) {
      block.writeVec4ValuesAt(
        off.shadowDecode,
        shadows._decode.x,
        shadows._decode.y,
        shadows._decode.z,
        shadows._decode.w,
      );
    }
    if (off.movingBounds >= 0) {
      final dataLen = block.data.length;
      final activeCount = movingBoundsCount.clamp(0, 4);
      for (var i = 0; i < 4; i++) {
        final floatOffset = off.movingBounds + i * 4;
        if (floatOffset + 4 > dataLen) {
          break;
        }
        if (i < activeCount && i < movingBounds.length) {
          final b = movingBounds[i];
          block.writeVec4ValuesAt(floatOffset, b.x, b.y, b.z, b.w);
        } else {
          block.writeVec4ValuesAt(floatOffset, 2.0, 2.0, -1.0, -1.0);
        }
      }
    }

    final liveShadow = _ShadowPass.shadowMapTexture(context);
    final stillShadow = shadows.activeStillTexture ?? Texture.standard;
    device
      ..bindPipeline(pipeline)
      ..setRenderState(_restoreRenderState)
      ..setFrontFace(WindingOrder.counterClockwise)
      ..bindUniformBlock(block)
      ..bindTexture(_staticColorSlot!, staticColor)
      ..bindTexture(_staticDepthSlot!, staticDepth)
      ..bindTexture(_shadowMapSlot!, liveShadow)
      ..bindTexture(_stillShadowSlot!, stillShadow)
      ..bindSurface(fullscreenQuadSurface)
      ..drawSurface(fullscreenQuadSurface);
  }
}

class _StaticDepthPipeline({
  required final bool drawable,
  required final bool batched,
}) {
  DevicePipeline? _pipeline;
  int _vertexGeneration = -1;
  int _fragmentGeneration = -1;
  Shader? vertexShader;

  DevicePipeline get pipeline => _pipeline!;

  static _StaticDepthPipeline? resolve(
    GraphicsDevice device,
    Map<VertexLayout, _StaticDepthPipeline> pipelines,
    VertexLayout layout,
    Shader vertex,
    Shader batchedVertex,
    Shader fragment,
  ) {
    var entry = pipelines[layout];
    if (entry == null) {
      final pos = layout.attribute(VertexLayout.positionAttribute);
      final normal = layout.attribute('vertexNormal');
      final batched =
          layout.attribute(VertexLayout.objectIdAttribute)?.components == 1;
      entry = pipelines[layout] = _StaticDepthPipeline(
        drawable:
            pos != null &&
            pos.components == 3 &&
            normal != null &&
            normal.components == 3,
        batched: batched,
      );
    }
    if (!entry.drawable) {
      return null;
    }
    final vs = entry.batched ? batchedVertex : vertex;
    vs.resource;
    fragment.resource;
    if (entry._pipeline == null ||
        entry._vertexGeneration != vs.generation ||
        entry._fragmentGeneration != fragment.generation) {
      entry
        .._pipeline = device.pipelineFor(vs, fragment, layout)
        .._vertexGeneration = vs.generation
        .._fragmentGeneration = fragment.generation
        ..vertexShader = vs;
    }
    return entry;
  }
}

class _StaticDepthParamOffsets(final UniformBlock _b) {
  late final int sunDirIntensity = _b.resolveOffset('sunDirIntensity');
  late final int ambientLuma = _b.resolveOffset('ambientLuma');
  late final int hemiUp = _b.resolveOffset('hemiUp');
}

class _StaticRestoreOffsets(final UniformBlock _b) {
  late final int invViewProjection = _b.resolveOffset('invViewProjection');
  late final int lightViewProjection = _b.resolveOffset('lightViewProjection');
  late final int depthRange = _b.resolveOffset('depthRange');
  late final int shadowToLight = _b.resolveOffset('shadowToLight');
  late final int shadowColor = _b.resolveOffset('shadowColor');
  late final int shadowMapSize = _b.resolveOffset('shadowMapSize');
  late final int shadowBias = _b.resolveOffset('shadowBias');
  late final int shadowDecode = _b.resolveOffset('shadowDecode');
  late final int movingBounds = _b.resolveOffset('movingBounds');
}
