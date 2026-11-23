part of 'render_context_3d.dart';

extension _RenderContext3DDraw on RenderContext3D {
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

  void _resolvePipeline(
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
        ((material.hasPassStableFragmentShader && _lastPipePass == _pass) ||
            identical(
              material.fragmentShaderFor(this, layout),
              _lastPipeFrag,
            ))) {
      return;
    }

    final vertexShader = material.vertexShaderFor(layout);
    final fragmentShader = material.fragmentShaderFor(this, layout);
    vertexShader.resource;
    fragmentShader.resource;
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

    _lastPipeMat = material;
    _lastPipeLayout = layout;
    _lastPipeMatVer = matVer;
    _lastPipeVert = vertexShader;
    _lastPipeFrag = fragmentShader;
    _lastPipeVertGen = vertexShader.generation;
    _lastPipeFragGen = fragmentShader.generation;
    _lastPipePass = _pass;
    _lastPipeDev = pipeline;
  }

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
    var quantized = 0.0;
    if (best >= 0) {
      if (bestWeight >= 1.0 - 1e-6) {
        quantized = 1.0;
      } else {
        final q = (bestWeight * 64.0).round();
        quantized = (q > 0 ? q : 1) / 64.0;
      }
      _anyProbeDraw = true;
    }
    _probeSlots[i] = best + 1;
    _probeWeights[i] = quantized;
  }

  int _prepareOpaqueSorted() {
    var opaqueCount = _cachedOpaqueCount;
    if (opaqueCount >= 0) {
      return opaqueCount;
    }
    final count = _count;
    opaqueCount = 0;
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
    _cachedOpaqueCount = opaqueCount;
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
    final count = _count;
    final groupKeys = _groupKeys;
    final surfaceKeys = _surfaceKeys;
    final sortDepths = _sortDepths;
    final int opaqueCount;
    var translucentCount = 0;
    if (_cachedOpaqueCount >= 0) {
      opaqueCount = _cachedOpaqueCount;
      if (_hasRecordedTranslucent) {
        for (var i = 0; i < count; i++) {
          final material = _materials[i]!;
          if (material.renderState.translucent) {
            _translucent[translucentCount++] = i;
            groupKeys[i] = material.translucentOrder.toDouble();
            surfaceKeys[i] = 0;
            sortDepths[i] = -_depths[i];
          }
        }
        _sortByProbe = false;
        _sort(_translucent, translucentCount);
      }
    } else {
      var oCount = 0;
      for (var i = 0; i < count; i++) {
        final material = _materials[i]!;
        if (material.renderState.translucent) {
          _translucent[translucentCount++] = i;
          groupKeys[i] = material.translucentOrder.toDouble();
          surfaceKeys[i] = 0;
          sortDepths[i] = -_depths[i];
        } else {
          _opaque[oCount++] = i;
          groupKeys[i] =
              _pipelines[i]!.id * 8589934592.0 +
              material.id * 2.0 +
              _mirrored[i];
          surfaceKeys[i] = _surfaces[i]!.id * 2 + (_joints[i] == null ? 0 : 1);
          sortDepths[i] = _depths[i];
        }
      }
      opaqueCount = oCount;
      _sortByProbe = _anyProbeDraw;
      _sort(_opaque, opaqueCount);
      _sortByProbe = false;
      if (translucentCount > 1) {
        _sort(_translucent, translucentCount);
      }
    }
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
    _hasRecordedRefractive = false;
    _hasRecordedTranslucent = false;
    _cachedOpaqueCount = -1;
    _oitGrab.resetSortCache();
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

  bool _batchesBasic(int first, int other) =>
      identical(_surfaces[first], _surfaces[other]) &&
      identical(_pipelines[first], _pipelines[other]) &&
      _joints[other] == null &&
      _external[other] == null;

  void _drawBatchGeometry(
    Surface surface,
    Int32List order,
    int start,
    int count,
  ) {
    final first = order[start];
    device.bindSurface(surface);
    final external = _external[first];
    if (external != null) {
      final instanceCount = _externalCounts[first];
      final ver = _externalVersions[first];
      final span = _externalCacheSpans[first];
      device
        ..bindInstances(
          external,
          instanceCount,
          startFloat: _externalOffsets[first],
          version: ver >= 0 ? ver : null,
          cacheSpanCount: span > 0 ? span : null,
        )
        ..drawSurface(surface, instanceCount: instanceCount);
      return;
    }
    device
      ..bindInstancesOf(_instances, order, start, count)
      ..drawSurface(surface, instanceCount: count);
  }

  bool _batchesWith(int first, int other) =>
      _batchesBasic(first, other) &&
      identical(_materials[first], _materials[other]) &&
      _mirrored[first] == _mirrored[other] &&
      _probeSlots[first] == _probeSlots[other] &&
      _probeWeights[first] == _probeWeights[other];

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
      final ver = _externalVersions[first];
      final span = _externalCacheSpans[first];
      device
        ..bindSurface(surface)
        ..bindInstances(
          external,
          instanceCount,
          startFloat: _externalOffsets[first],
          version: ver >= 0 ? ver : null,
          cacheSpanCount: span > 0 ? span : null,
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
    _externalVersions = Int32List(capacity)
      ..setRange(0, _externalVersions.length, _externalVersions);
    _externalCacheSpans = Int32List(capacity)
      ..setRange(0, _externalCacheSpans.length, _externalCacheSpans);
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

@pragma('vm:prefer-inline')
double _probeAxisWeight(double distance, double half, double fade) {
  final t = ((half + fade - distance) / fade).clamp(0.0, 1.0);
  return t * t * (3.0 - 2.0 * t);
}

int _capacityFor(int count) {
  var capacity = 64;
  while (capacity < count) {
    capacity *= 2;
  }
  return capacity;
}
