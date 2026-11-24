part of 'render_context_3d.dart';

class _PipelineResolutionCache() {
  Material? lastMat;
  VertexLayout? lastLayout;
  Shader? lastVert;
  Shader? lastFrag;
  int lastMatVer = -1;
  int lastVertGen = -1;
  int lastFragGen = -1;
  int lastPass = -1;
  DevicePipeline? lastDev;

  final Map<RenderState, RenderState> _depthOnlyStates = {};
  final Map<RenderState, RenderState> _prepassShadedStates = {};
  final Map<RenderState, RenderState> _wireframeStates = {};
  RenderState? _lastDepthOnlyIn;
  RenderState? _lastDepthOnlyOut;
  RenderState? _lastPrepassIn;
  RenderState? _lastPrepassOut;
  RenderState? _lastWireframeIn;
  RenderState? _lastWireframeOut;

  void resolve(
    RenderContext3D context,
    Material material,
    VertexLayout layout,
  ) {
    final matVer = material.version;
    if (identical(material, lastMat) &&
        identical(layout, lastLayout) &&
        matVer == lastMatVer &&
        lastDev != null &&
        lastVertGen == lastVert!.generation &&
        lastFragGen == lastFrag!.generation &&
        ((material.hasPassStableFragmentShader && lastPass == context._pass) ||
            identical(
              material.fragmentShaderFor(context, layout),
              lastFrag,
            ))) {
      return;
    }

    final vertexShader = material.vertexShaderFor(layout);
    final fragmentShader = material.fragmentShaderFor(context, layout);
    vertexShader.resource;
    fragmentShader.resource;
    final device = context.device;
    final cache = material.pipelineCache as MaterialPipelineCache?;
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

    lastMat = material;
    lastLayout = layout;
    lastMatVer = matVer;
    lastVert = vertexShader;
    lastFrag = fragmentShader;
    lastVertGen = vertexShader.generation;
    lastFragGen = fragmentShader.generation;
    lastPass = context._pass;
    lastDev = pipeline;
  }

  RenderState depthOnlyState(RenderState baseState) {
    if (identical(baseState, _lastDepthOnlyIn)) {
      return _lastDepthOnlyOut!;
    }
    final resolved = _depthOnlyStates[baseState] ??= RenderState(
      blend: BlendState.depthOnly,
      depthTest: baseState.depthTest,
      cullMode: baseState.cullMode,
      stencil: baseState.stencil,
    );
    _lastDepthOnlyIn = baseState;
    _lastDepthOnlyOut = resolved;
    return resolved;
  }

  RenderState prepassShadedState(RenderState baseState) {
    if (identical(baseState, _lastPrepassIn)) {
      return _lastPrepassOut!;
    }
    final resolved = _prepassShadedStates[baseState] ??= baseState.copyWith(
      depthCompare: CompareFunction.lessEqual,
      depthWrite: false,
    );
    _lastPrepassIn = baseState;
    _lastPrepassOut = resolved;
    return resolved;
  }

  RenderState wireframeState(RenderState effectiveState) {
    if (identical(effectiveState, _lastWireframeIn)) {
      return _lastWireframeOut!;
    }
    final resolved = _wireframeStates[effectiveState] ??= effectiveState
        .copyWith(polygonMode: PolygonFillMode.wireframe);
    _lastWireframeIn = effectiveState;
    _lastWireframeOut = resolved;
    return resolved;
  }
}

extension _RenderContext3DDraw on RenderContext3D {
  int _prepareOpaqueSorted() {
    final queue = _queue;
    var opaqueCount = queue.cachedOpaqueCount;
    if (opaqueCount >= 0) {
      return opaqueCount;
    }
    final count = queue.count;
    opaqueCount = 0;
    for (var i = 0; i < count; i++) {
      final material = queue.materials[i]!;
      if (!material.renderState.translucent) {
        queue.opaque[opaqueCount++] = i;
        queue.groupKeysHi[i] = queue.pipelines[i]!.id;
        queue.groupKeysLo[i] = (material.id << 1) | queue.mirrored[i];
        queue.surfaceKeys[i] =
            queue.surfaces[i]!.id * 2 + (queue.joints[i] == null ? 0 : 1);
        queue.sortDepths[i] = queue.depths[i];
      }
    }
    queue.sort(
      queue.opaque,
      opaqueCount,
      sortByProbe: _probeSelector.anyProbeDraw,
    );
    queue.cachedOpaqueCount = opaqueCount;
    _oitGrab.resetOpaqueDepthCache();
    return opaqueCount;
  }

  /// Sorts the draws recorded since the last flush and submits them to the
  /// device, which must be in a render pass.
  void _flushDraws() {
    RenderProfile.lap(RenderPhase.traversal);
    if (_shadows.recording) {
      _shadows.flushCasters();
      return;
    }
    final layers = depthLayers;
    if (layers != null && layers.isNotEmpty) {
      _flushDepthLayers(layers);
      return;
    }
    final queue = _queue;
    final count = queue.count;
    final groupKeysHi = queue.groupKeysHi;
    final groupKeysLo = queue.groupKeysLo;
    final surfaceKeys = queue.surfaceKeys;
    final sortDepths = queue.sortDepths;
    final int opaqueCount;
    var translucentCount = 0;
    if (queue.cachedOpaqueCount >= 0) {
      opaqueCount = queue.cachedOpaqueCount;
      if (queue.hasRecordedTranslucent) {
        for (var i = 0; i < count; i++) {
          final material = queue.materials[i]!;
          if (material.renderState.translucent) {
            queue.translucent[translucentCount++] = i;
            groupKeysHi[i] = material.translucentOrder;
            groupKeysLo[i] = 0;
            surfaceKeys[i] = 0;
            sortDepths[i] = -queue.depths[i];
          }
        }
        queue.sort(queue.translucent, translucentCount);
      }
    } else {
      var oCount = 0;
      for (var i = 0; i < count; i++) {
        final material = queue.materials[i]!;
        if (material.renderState.translucent) {
          queue.translucent[translucentCount++] = i;
          groupKeysHi[i] = material.translucentOrder;
          groupKeysLo[i] = 0;
          surfaceKeys[i] = 0;
          sortDepths[i] = -queue.depths[i];
        } else {
          queue.opaque[oCount++] = i;
          groupKeysHi[i] = queue.pipelines[i]!.id;
          groupKeysLo[i] = (material.id << 1) | queue.mirrored[i];
          surfaceKeys[i] =
              queue.surfaces[i]!.id * 2 + (queue.joints[i] == null ? 0 : 1);
          sortDepths[i] = queue.depths[i];
        }
      }
      opaqueCount = oCount;
      queue.sort(
        queue.opaque,
        opaqueCount,
        sortByProbe: _probeSelector.anyProbeDraw,
      );
      if (translucentCount > 1) {
        queue.sort(queue.translucent, translucentCount);
      }
    }
    RenderProfile.lap(RenderPhase.sort);

    _boundMaterial = null;
    _bindingEpoch = -1;
    _depthPrepassOverride = false;

    _submitBatches(queue.opaque, opaqueCount);
    _submitTranslucentBatches(queue.translucent, translucentCount);

    _probeSelector.resetPass();
    queue.release(count, _oitGrab);
    _boundMaterial = null;
    _jointCache.activeTransforms = null;
    queue.lastDrawCount = count;
    queue.count = 0;
    queue.resetPrepassGroups();
    RenderProfile.lap(RenderPhase.release);
  }

  void _flushDepthLayers(List<DepthLayer3D> layers) {
    final queue = _queue;
    final count = queue.count;
    if (count == 0) {
      _probeSelector.resetPass();
      queue.release(0, _oitGrab);
      _boundMaterial = null;
      _jointCache.activeTransforms = null;
      queue.lastDrawCount = 0;
      queue.count = 0;
      queue.resetPrepassGroups();
      RenderProfile.lap(RenderPhase.release);
      return;
    }
    final groupKeysHi = queue.groupKeysHi;
    final groupKeysLo = queue.groupKeysLo;
    final surfaceKeys = queue.surfaceKeys;
    final sortDepths = queue.sortDepths;
    final layerIds = queue.depthLayers;

    final savedWaterVolume = waterVolume;
    final targetW = device.renderTarget.width;
    final targetH = device.renderTarget.height;
    var restoredViewport = false;
    var anySubmitted = false;

    try {
      for (var l = 0; l < layers.length; l++) {
        final layer = layers[l];
        final layerIndex = layer.index;
        var oCount = 0;
        var tCount = 0;
        for (var i = 0; i < count; i++) {
          if (layerIds[i] != layerIndex) {
            continue;
          }
          final material = queue.materials[i]!;
          if (material.renderState.translucent) {
            queue.translucent[tCount++] = i;
            groupKeysHi[i] = material.translucentOrder;
            groupKeysLo[i] = 0;
            surfaceKeys[i] = 0;
            sortDepths[i] = -queue.depths[i];
          } else {
            queue.opaque[oCount++] = i;
            groupKeysHi[i] = queue.pipelines[i]!.id;
            groupKeysLo[i] = (material.id << 1) | queue.mirrored[i];
            surfaceKeys[i] =
                queue.surfaces[i]!.id * 2 + (queue.joints[i] == null ? 0 : 1);
            sortDepths[i] = queue.depths[i];
          }
        }
        if (oCount == 0 && tCount == 0) {
          continue;
        }
        if (oCount > 1) {
          queue.sort(
            queue.opaque,
            oCount,
            sortByProbe: _probeSelector.anyProbeDraw,
          );
        }
        if (tCount > 1) {
          queue.sort(queue.translucent, tCount);
        }
        RenderProfile.lap(RenderPhase.sort);

        device.setViewport(
          0,
          0,
          targetW,
          targetH,
          zNear: layer.zNear,
          zFar: layer.zFar,
        );
        if (layer.zNear != 0.0 || layer.zFar != 1.0) {
          restoredViewport = true;
        }

        final targetWater = layer.applyWaterVolume ? savedWaterVolume : null;
        final waterChanged = !identical(waterVolume, targetWater);
        if (waterChanged) {
          waterVolume = targetWater;
          _passRegistry.bumpWaterVolume(++_nextPassEpoch);
        }
        if (!anySubmitted || waterChanged) {
          _boundMaterial = null;
          _bindingEpoch = -1;
        }
        _depthPrepassOverride = false;
        anySubmitted = true;

        _submitBatches(queue.opaque, oCount);
        _submitTranslucentBatches(queue.translucent, tCount);
      }
    } finally {
      if (!identical(waterVolume, savedWaterVolume)) {
        waterVolume = savedWaterVolume;
        _passRegistry.bumpWaterVolume(++_nextPassEpoch);
      }
      if (restoredViewport) {
        device.setViewport(0, 0, targetW, targetH);
      }
    }

    _probeSelector.resetPass();
    queue.release(count, _oitGrab);
    _boundMaterial = null;
    _jointCache.activeTransforms = null;
    queue.lastDrawCount = count;
    queue.count = 0;
    queue.resetPrepassGroups();
    RenderProfile.lap(RenderPhase.release);
  }

  void _submitBatches(Int32List order, int count, {int offset = 0}) {
    final queue = _queue;
    var start = offset;
    final limit = offset + count;
    while (start < limit) {
      final first = order[start];
      var end = start + 1;
      if (queue.pipelines[first]!.instanced &&
          queue.joints[first] == null &&
          queue.external[first] == null &&
          queue.batches[first] == null) {
        while (end < limit && _batchesWith(first, order[end])) {
          end++;
        }
      }
      _submit(order, start, end - start);
      start = end;
    }
  }

  void _submitTranslucentBatches(Int32List order, int count) {
    final prepassGroups = _queue.prepassGroups;
    var cursor = 0;
    while (cursor < count) {
      final gid = prepassGroups[order[cursor]];
      if (gid == 0) {
        var nextGroup = cursor + 1;
        while (nextGroup < count && prepassGroups[order[nextGroup]] == 0) {
          nextGroup++;
        }
        _submitBatches(order, nextGroup - cursor, offset: cursor);
        cursor = nextGroup;
        continue;
      }

      var groupEnd = cursor + 1;
      while (groupEnd < count && prepassGroups[order[groupEnd]] == gid) {
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

  void _drawBatchGeometry(
    Surface surface,
    Int32List order,
    int start,
    int count,
  ) {
    final queue = _queue;
    final first = order[start];
    device.bindSurface(surface);
    final external = queue.external[first];
    if (external != null) {
      final instanceCount = queue.externalCounts[first];
      final ver = queue.externalVersions[first];
      final span = queue.externalCacheSpans[first];
      device
        ..bindInstances(
          external,
          instanceCount,
          startFloat: queue.externalOffsets[first],
          version: ver >= 0 ? ver : null,
          cacheSpanCount: span > 0 ? span : null,
        )
        ..drawSurface(surface, instanceCount: instanceCount);
      return;
    }
    device
      ..bindInstancesOf(queue.instances, order, start, count)
      ..drawSurface(surface, instanceCount: count);
  }

  bool _batchesWith(int first, int other) {
    final queue = _queue;
    return queue.batchesBasic(first, other) &&
        identical(queue.materials[first], queue.materials[other]) &&
        queue.mirrored[first] == queue.mirrored[other] &&
        queue.probeSlots[first] == queue.probeSlots[other] &&
        queue.probeWeights[first] == queue.probeWeights[other];
  }

  void _submit(Int32List order, int start, int count) {
    final queue = _queue;
    final first = order[start];
    final surface = queue.surfaces[first]!;
    final material = queue.materials[first]!;
    final pipeline = queue.pipelines[first]!;
    final vertexShader =
        queue.vertexShaders[first] ?? material.vertexShaderFor(surface.layout);
    final fragmentShader =
        queue.fragmentShaders[first] ??
        material.fragmentShaderFor(this, surface.layout);
    RenderProfile.lap(RenderPhase.batch);

    final joints = queue.joints[first];
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
        ? _pipelineCache.depthOnlyState(baseState)
        : (baseState.depthPrepass
              ? _pipelineCache.prepassShadedState(baseState)
              : baseState);
    if (!_depthPrepassOverride) {
      if (_oitPass != _OitAndGrabPass.noPass) {
        effectiveState = _OitAndGrabPass.stateFor(effectiveState, _oitPass);
      }
      if (renderDebugMode == RenderDebugMode3D.wireframe) {
        effectiveState = _pipelineCache.wireframeState(effectiveState);
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
        (queue.mirrored[first] == 1) == _camera.isMirrored
            ? WindingOrder.counterClockwise
            : WindingOrder.clockwise,
      );
    RenderProfile.lap(RenderPhase.state);

    final external = queue.external[first];
    if (external != null) {
      _probeSelector.drawProbeSlot = queue.probeSlots[first];
      _probeSelector.drawProbeWeight = queue.probeWeights[first];
      if (!identical(material, _boundMaterial) || _probeChanged) {
        _jointCache.activeTransforms = joints;
        _applyMaterial(material, vertexShader, fragmentShader);
      }
      _bindJoints(vertexShader, joints);
      final instanceCount = queue.externalCounts[first];
      final ver = queue.externalVersions[first];
      final span = queue.externalCacheSpans[first];
      device
        ..bindSurface(surface)
        ..bindInstances(
          external,
          instanceCount,
          startFloat: queue.externalOffsets[first],
          version: ver >= 0 ? ver : null,
          cacheSpanCount: span > 0 ? span : null,
        )
        ..drawSurface(surface, instanceCount: instanceCount);
      RenderProfile.lap(RenderPhase.draw);
      return;
    }

    final batch = queue.batches[first];
    if (batch != null) {
      _probeSelector.drawProbeSlot = queue.probeSlots[first];
      _probeSelector.drawProbeWeight = queue.probeWeights[first];
      if (!identical(material, _boundMaterial) || _probeChanged) {
        _jointCache.activeTransforms = joints;
        _applyMaterial(material, vertexShader, fragmentShader);
      }
      _bindJoints(vertexShader, joints);
      _bindBatchObjects(vertexShader, batch);
      device
        ..bindSurface(surface)
        ..drawSurface(surface);
      RenderProfile.lap(RenderPhase.draw);
      return;
    }

    if (!pipeline.instanced) {
      for (var i = start; i < start + count; i++) {
        final draw = order[i];
        _camera.modelMatrix.storage.setRange(
          0,
          16,
          queue.instances,
          draw * VertexLayout.instanceStrideInFloats,
        );
        _jointCache.activeTransforms = queue.joints[draw];
        _probeSelector.drawProbeSlot = queue.probeSlots[draw];
        _probeSelector.drawProbeWeight = queue.probeWeights[draw];
        _applyMaterial(material, vertexShader, fragmentShader);
        _bindJoints(vertexShader, queue.joints[draw]);
        device.bindSurface(surface);
        if (pipeline.usesInstanceData) {
          device.bindInstancesOf(queue.instances, order, i, 1);
        }
        device.drawSurface(surface);
        RenderProfile.lap(RenderPhase.draw);
      }
      return;
    }

    _probeSelector.drawProbeSlot = queue.probeSlots[first];
    _probeSelector.drawProbeWeight = queue.probeWeights[first];
    if (!identical(material, _boundMaterial) || _probeChanged) {
      _jointCache.activeTransforms = joints;
      _applyMaterial(material, vertexShader, fragmentShader);
    }
    _bindJoints(vertexShader, joints);
    device
      ..bindSurface(surface)
      ..bindInstancesOf(queue.instances, order, start, count)
      ..drawSurface(surface, instanceCount: count);
    RenderProfile.lap(RenderPhase.draw);
  }

  bool get _hasStaticDraws {
    final isStatic = _queue.isStatic;
    final count = _queue.count;
    for (var i = 0; i < count; i++) {
      if (isStatic[i] == 1) {
        return true;
      }
    }
    return false;
  }

  void _collectStaticMaterials(
    List<Material> outMaterials,
    List<int> outVersions,
  ) {
    outMaterials.clear();
    outVersions.clear();
    final queue = _queue;
    final count = queue.count;
    final isStatic = queue.isStatic;
    final materials = queue.materials;
    for (var i = 0; i < count; i++) {
      if (isStatic[i] != 1) {
        continue;
      }
      final mat = materials[i]!;
      var seen = false;
      for (var k = 0; k < outMaterials.length; k++) {
        if (identical(outMaterials[k], mat)) {
          seen = true;
          break;
        }
      }
      if (!seen) {
        outMaterials.add(mat);
        outVersions.add(mat.version - mat.animationVersion);
      }
    }
  }

  void _flushFiltered({
    required int staticFlag,
    required bool releaseAfter,
  }) {
    final queue = _queue;
    final count = queue.count;
    final isStatic = queue.isStatic;
    final groupKeysHi = queue.groupKeysHi;
    final groupKeysLo = queue.groupKeysLo;
    final surfaceKeys = queue.surfaceKeys;
    final sortDepths = queue.sortDepths;
    final layers = depthLayers;

    void submitFiltered({int? filterLayer}) {
      var oCount = 0;
      var tCount = 0;
      for (var i = 0; i < count; i++) {
        if (isStatic[i] != staticFlag) {
          continue;
        }
        if (filterLayer != null && queue.depthLayers[i] != filterLayer) {
          continue;
        }
        final material = queue.materials[i]!;
        if (material.renderState.translucent) {
          queue.translucent[tCount++] = i;
          groupKeysHi[i] = material.translucentOrder;
          groupKeysLo[i] = 0;
          surfaceKeys[i] = 0;
          sortDepths[i] = -queue.depths[i];
        } else {
          queue.opaque[oCount++] = i;
          groupKeysHi[i] = queue.pipelines[i]!.id;
          groupKeysLo[i] = (material.id << 1) | queue.mirrored[i];
          surfaceKeys[i] =
              queue.surfaces[i]!.id * 2 + (queue.joints[i] == null ? 0 : 1);
          sortDepths[i] = queue.depths[i];
        }
      }
      if (oCount == 0 && tCount == 0) {
        return;
      }
      if (oCount > 1) {
        queue.sort(
          queue.opaque,
          oCount,
          sortByProbe: _probeSelector.anyProbeDraw,
        );
      }
      if (tCount > 1) {
        queue.sort(queue.translucent, tCount);
      }
      _submitBatches(queue.opaque, oCount);
      _submitTranslucentBatches(queue.translucent, tCount);
    }

    _boundMaterial = null;
    _bindingEpoch = -1;
    _depthPrepassOverride = false;

    if (layers == null || layers.isEmpty) {
      submitFiltered();
    } else {
      final savedWaterVolume = waterVolume;
      final targetW = device.renderTarget.width;
      final targetH = device.renderTarget.height;
      var restoredViewport = false;
      var anySubmitted = false;
      try {
        for (var l = 0; l < layers.length; l++) {
          final layer = layers[l];
          final layerIndex = layer.index;
          if (staticFlag == 1 && layerIndex != 0) {
            continue;
          }
          var anyInLayer = false;
          for (var i = 0; i < count; i++) {
            if (isStatic[i] == staticFlag &&
                queue.depthLayers[i] == layerIndex) {
              anyInLayer = true;
              break;
            }
          }
          if (!anyInLayer) {
            continue;
          }
          device.setViewport(
            0,
            0,
            targetW,
            targetH,
            zNear: layer.zNear,
            zFar: layer.zFar,
          );
          if (layer.zNear != 0.0 || layer.zFar != 1.0) {
            restoredViewport = true;
          }
          final targetWater = layer.applyWaterVolume ? savedWaterVolume : null;
          final waterChanged = !identical(waterVolume, targetWater);
          if (waterChanged) {
            waterVolume = targetWater;
            _passRegistry.bumpWaterVolume(++_nextPassEpoch);
          }
          if (!anySubmitted || waterChanged) {
            _boundMaterial = null;
            _bindingEpoch = -1;
          }
          _depthPrepassOverride = false;
          anySubmitted = true;
          submitFiltered(filterLayer: layerIndex);
        }
      } finally {
        if (!identical(waterVolume, savedWaterVolume)) {
          waterVolume = savedWaterVolume;
          _passRegistry.bumpWaterVolume(++_nextPassEpoch);
        }
        if (restoredViewport) {
          device.setViewport(0, 0, targetW, targetH);
        }
      }
    }

    _boundMaterial = null;
    _jointCache.activeTransforms = null;
    if (releaseAfter) {
      _probeSelector.resetPass();
      queue.release(count, _oitGrab);
      queue.lastDrawCount = count;
      queue.count = 0;
      queue.resetPrepassGroups();
      RenderProfile.lap(RenderPhase.release);
    }
  }
}
