part of 'graphics_device.dart';

class _InstanceUploadCache() {
  GpuBuffer? gpuBuffer;
  GpuBuffer? arenaBuffer;
  int arenaOffset = 0;
  int frame = -1;
  int deviceGeneration = -1;
  int version = -1;
  int spanStartFloat = -1;
  int spanFloats = -1;
}

class _PassBindingState() {
  GpuPipeline? pipeline;
  Surface? surface;
  int bindingEpoch = 0;
  BlendState blend = BlendState.opaque;
  CompareFunction depthCompare = CompareFunction.less;
  bool depthWrite = true;
  CullMode cullMode = CullMode.none;
  WindingOrder frontFace = WindingOrder.counterClockwise;
  StencilState? stencil;
  PolygonFillMode polygonMode = PolygonFillMode.fill;
  PrimitiveTopology topology = PrimitiveTopology.triangles;

  GpuBuffer? boundInstBuffer;
  int boundInstOffset = -1;
  int boundInstLength = -1;

  final List<GpuUniformSlot?> boundUniformSlots = List.filled(
    16,
    null,
    growable: true,
  );
  final List<GpuBuffer?> boundUniformBuffers = List.filled(
    16,
    null,
    growable: true,
  );
  Int32List boundUniformOffsets = Int32List(16);
  Int32List boundUniformLengths = Int32List(16);
  int boundUniformCount = 0;

  final List<GpuUniformSlot?> boundTexSlots = List.filled(
    16,
    null,
    growable: true,
  );
  final List<GpuTexture?> boundTexHandles = List.filled(
    16,
    null,
    growable: true,
  );
  Int32List boundTexSamplerKeys = Int32List(16);
  int boundTexCount = 0;

  bool hasViewport = false;
  int vpX = 0;
  int vpY = 0;
  int vpW = 0;
  int vpH = 0;
  double vpZNear = 0.0;
  double vpZFar = 1.0;

  bool hasScissor = false;
  int scX = 0;
  int scY = 0;
  int scW = 0;
  int scH = 0;

  void clearBindings() {
    boundInstBuffer = null;
    boundInstOffset = -1;
    boundInstLength = -1;
    if (boundUniformCount > 0) {
      boundUniformSlots.fillRange(0, boundUniformCount, null);
      boundUniformBuffers.fillRange(0, boundUniformCount, null);
      boundUniformCount = 0;
    }
    if (boundTexCount > 0) {
      boundTexSlots.fillRange(0, boundTexCount, null);
      boundTexHandles.fillRange(0, boundTexCount, null);
      boundTexCount = 0;
    }
  }

  void resetForPass(
    GpuRenderPass renderPass,
    WindingOrder initialFrontFace,
    RenderStats stats,
  ) {
    pipeline = null;
    surface = null;
    clearBindings();
    hasViewport = false;
    hasScissor = false;
    bindingEpoch++;
    blend = BlendState.opaque;
    depthCompare = CompareFunction.less;
    depthWrite = true;
    cullMode = CullMode.none;
    frontFace = WindingOrder.counterClockwise;
    stencil = null;
    polygonMode = PolygonFillMode.fill;
    topology = PrimitiveTopology.triangles;
    if (initialFrontFace != frontFace) {
      renderPass.setWindingOrder(initialFrontFace);
      frontFace = initialFrontFace;
      stats.stateChanges++;
    }
  }

  void bindInstanceSlice(
    GpuRenderPass pass,
    GpuBuffer buffer,
    int offsetInBytes,
    int lengthInBytes,
  ) {
    if (identical(boundInstBuffer, buffer) &&
        boundInstOffset == offsetInBytes &&
        boundInstLength == lengthInBytes) {
      return;
    }
    boundInstBuffer = buffer;
    boundInstOffset = offsetInBytes;
    boundInstLength = lengthInBytes;
    pass.bindVertexBuffer(
      buffer,
      offsetInBytes: offsetInBytes,
      lengthInBytes: lengthInBytes,
      slot: 1,
    );
  }

  void bindUniformResolved(
    GpuRenderPass pass,
    GpuUniformSlot slot,
    GpuBuffer buffer,
    int offsetInBytes,
    int lengthInBytes,
  ) {
    for (var i = 0; i < boundUniformCount; i++) {
      if (identical(boundUniformSlots[i], slot)) {
        if (identical(boundUniformBuffers[i], buffer) &&
            boundUniformOffsets[i] == offsetInBytes &&
            boundUniformLengths[i] == lengthInBytes) {
          return;
        }
        boundUniformBuffers[i] = buffer;
        boundUniformOffsets[i] = offsetInBytes;
        boundUniformLengths[i] = lengthInBytes;
        pass.bindUniform(
          slot,
          buffer,
          offsetInBytes: offsetInBytes,
          lengthInBytes: lengthInBytes,
        );
        return;
      }
    }
    final idx = boundUniformCount++;
    if (idx == boundUniformSlots.length) {
      boundUniformSlots.add(slot);
      boundUniformBuffers.add(buffer);
    } else {
      boundUniformSlots[idx] = slot;
      boundUniformBuffers[idx] = buffer;
    }
    if (idx >= boundUniformOffsets.length) {
      boundUniformOffsets = Int32List(boundUniformOffsets.length * 2)
        ..setRange(0, boundUniformOffsets.length, boundUniformOffsets);
      boundUniformLengths = Int32List(boundUniformLengths.length * 2)
        ..setRange(0, boundUniformLengths.length, boundUniformLengths);
    }
    boundUniformOffsets[idx] = offsetInBytes;
    boundUniformLengths[idx] = lengthInBytes;
    pass.bindUniform(
      slot,
      buffer,
      offsetInBytes: offsetInBytes,
      lengthInBytes: lengthInBytes,
    );
  }

  void bindTextureResolved(
    GpuRenderPass pass,
    GpuUniformSlot slot,
    GpuTexture gpuTex,
    TextureSampler sampler,
  ) {
    final samplerKey = sampler.key;
    for (var i = 0; i < boundTexCount; i++) {
      if (identical(boundTexSlots[i], slot)) {
        if (identical(boundTexHandles[i], gpuTex) &&
            boundTexSamplerKeys[i] == samplerKey) {
          return;
        }
        boundTexHandles[i] = gpuTex;
        boundTexSamplerKeys[i] = samplerKey;
        pass.bindTexture(slot, gpuTex, sampler: sampler);
        RenderProfile.lap(RenderPhase.binding);
        return;
      }
    }
    final idx = boundTexCount++;
    if (idx == boundTexSlots.length) {
      boundTexSlots.add(slot);
      boundTexHandles.add(gpuTex);
    } else {
      boundTexSlots[idx] = slot;
      boundTexHandles[idx] = gpuTex;
    }
    if (idx >= boundTexSamplerKeys.length) {
      boundTexSamplerKeys = Int32List(boundTexSamplerKeys.length * 2)
        ..setRange(0, boundTexSamplerKeys.length, boundTexSamplerKeys);
    }
    boundTexSamplerKeys[idx] = samplerKey;
    pass.bindTexture(slot, gpuTex, sampler: sampler);
    RenderProfile.lap(RenderPhase.binding);
  }
}

extension _GraphicsDeviceDraw on GraphicsDevice {
  /// Starts recording a pass into [target], or into nothing while the
  /// device is not ready.
  GpuRenderPass _beginGpuPass(
    GpuFrame frame,
    GpuRenderTarget target, {
    bool keepContents = false,
  }) {
    _suspended = !backend.isDeviceReady;
    return _suspended
        ? _SuspendedRenderPass.instance
        : frame.beginRenderPass(target, keepContents: keepContents);
  }

  void _startPass(GpuRenderPass renderPass, WindingOrder frontFace) {
    _renderPass = renderPass;
    stats.renderPasses++;
    // The state every pass starts with, see `GpuFrame.beginRenderPass`.
    _bindings.resetForPass(renderPass, frontFace, stats);
  }

  /// Draws [source] over the whole open pass.
  void _copyTexture(int slot, GpuTextureTarget source) {
    if (!identical(_copySources[slot], source)) {
      _copySources[slot] = source;
      _copyTextures[slot] = Texture(
        null,
        width: source.width,
        height: source.height,
        gpuTexture: source.texture,
      );
    }
    drawTextureCopy(_copyTextures[slot]);
  }

  _TransientBlock _uploadUniform(Uint8List data) =>
      _uploadUniformRange(data, data.length);

  _TransientBlock _uploadUniformRange(Uint8List data, int length) {
    final block = _arena.allocate(length, backend.uniformAlignment);
    block.staging.setRange(block.lastOffset, block.lastOffset + length, data);
    stats
      ..uniformUploads += 1
      ..uploadedBytes += length;
    return block;
  }

  _TransientBlock _uploadUniformByteData(ByteData data) {
    final length = data.lengthInBytes;
    final block = _arena.allocate(length, backend.uniformAlignment);
    final base = block.lastOffset;
    final dst = block.byteData;
    final aligned = length & ~3;
    for (var i = 0; i < aligned; i += 4) {
      dst.setUint32(base + i, data.getUint32(i, Endian.host), Endian.host);
    }
    for (var i = aligned; i < length; i++) {
      dst.setUint8(base + i, data.getUint8(i));
    }
    stats
      ..uniformUploads += 1
      ..uploadedBytes += length;
    return block;
  }
}
