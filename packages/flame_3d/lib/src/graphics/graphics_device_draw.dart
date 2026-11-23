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

  void _clearPassBindings() {
    _boundInstBuffer = null;
    _boundInstOffset = -1;
    _boundInstLength = -1;
    if (_boundUniformCount > 0) {
      _boundUniformSlots.fillRange(0, _boundUniformCount, null);
      _boundUniformBuffers.fillRange(0, _boundUniformCount, null);
      _boundUniformCount = 0;
    }
    if (_boundTexCount > 0) {
      _boundTexSlots.fillRange(0, _boundTexCount, null);
      _boundTexHandles.fillRange(0, _boundTexCount, null);
      _boundTexCount = 0;
    }
  }

  void _bindInstanceSlice(
    GpuBuffer buffer,
    int offsetInBytes,
    int lengthInBytes,
  ) {
    if (identical(_boundInstBuffer, buffer) &&
        _boundInstOffset == offsetInBytes &&
        _boundInstLength == lengthInBytes) {
      return;
    }
    _boundInstBuffer = buffer;
    _boundInstOffset = offsetInBytes;
    _boundInstLength = lengthInBytes;
    _pass.bindVertexBuffer(
      buffer,
      offsetInBytes: offsetInBytes,
      lengthInBytes: lengthInBytes,
      slot: 1,
    );
  }

  void _startPass(GpuRenderPass renderPass, WindingOrder frontFace) {
    _renderPass = renderPass;
    stats.renderPasses++;

    // The state every pass starts with, see `GpuFrame.beginRenderPass`.
    _pipeline = null;
    _surface = null;
    _clearPassBindings();
    _hasViewport = false;
    _hasScissor = false;
    _bindingEpoch++;
    _blend = BlendState.opaque;
    _depthCompare = CompareFunction.less;
    _depthWrite = true;
    _cullMode = CullMode.none;
    _frontFace = WindingOrder.counterClockwise;
    _stencil = null;
    _polygonMode = PolygonFillMode.fill;
    _topology = PrimitiveTopology.triangles;
    if (frontFace != _frontFace) {
      renderPass.setWindingOrder(frontFace);
      _frontFace = frontFace;
      stats.stateChanges++;
    }
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

  void _bindUniformResolved(
    GpuUniformSlot slot,
    GpuBuffer buffer,
    int offsetInBytes,
    int lengthInBytes,
  ) {
    for (var i = 0; i < _boundUniformCount; i++) {
      if (identical(_boundUniformSlots[i], slot)) {
        if (identical(_boundUniformBuffers[i], buffer) &&
            _boundUniformOffsets[i] == offsetInBytes &&
            _boundUniformLengths[i] == lengthInBytes) {
          return;
        }
        _boundUniformBuffers[i] = buffer;
        _boundUniformOffsets[i] = offsetInBytes;
        _boundUniformLengths[i] = lengthInBytes;
        _pass.bindUniform(
          slot,
          buffer,
          offsetInBytes: offsetInBytes,
          lengthInBytes: lengthInBytes,
        );
        return;
      }
    }
    final idx = _boundUniformCount++;
    if (idx == _boundUniformSlots.length) {
      _boundUniformSlots.add(slot);
      _boundUniformBuffers.add(buffer);
      _boundUniformOffsets = Int32List(_boundUniformOffsets.length * 2)
        ..setRange(0, _boundUniformOffsets.length, _boundUniformOffsets);
      _boundUniformLengths = Int32List(_boundUniformLengths.length * 2)
        ..setRange(0, _boundUniformLengths.length, _boundUniformLengths);
    } else {
      _boundUniformSlots[idx] = slot;
      _boundUniformBuffers[idx] = buffer;
    }
    _boundUniformOffsets[idx] = offsetInBytes;
    _boundUniformLengths[idx] = lengthInBytes;
    _pass.bindUniform(
      slot,
      buffer,
      offsetInBytes: offsetInBytes,
      lengthInBytes: lengthInBytes,
    );
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
