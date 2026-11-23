part of 'graphics_device.dart';

/// A host-visible GPU buffer and its CPU staging copy.
class _TransientBlock(final GpuBuffer buffer, final int capacity) {
  late final Uint8List staging = Uint8List(capacity);
  late final Float32List floats = staging.buffer.asFloat32List();

  int used = 0;
  int flushed = 0;
  int lastOffset = 0;

  void flush() {
    if (used > flushed) {
      buffer.write(
        ByteData.sublistView(staging, flushed, used),
        destinationOffsetInBytes: flushed,
      );
      flushed = used;
    }
  }
}

/// The transient blocks used by one frame, pooled across completed frames so
/// pass completion callbacks allocate zero closures per pass or frame.
class _FrameUploads(final _TransientArena _arena) {
  final List<_TransientBlock> blocks = [];
  int pendingPasses = 0;
  bool ended = false;

  late final void Function() completionCallback = _onCompleted;

  void _onCompleted() {
    pendingPasses--;
    if (ended && pendingPasses == 0) {
      _arena._release(this);
    }
  }
}

/// Sub-allocates the uniform and instance data of a frame from a pool of
/// [_TransientBlock]s, uploads it once per pass and recycles the blocks once
/// the GPU completed every pass of the frame that used them.
class _TransientArena(final GpuBackend _backend) {
  static const _blockSize = 256 * 1024;
  static const _maxFreeBlocks = 8;
  static const _maxFreeFrames = 8;

  final List<_TransientBlock> _free = [];
  final List<_FrameUploads> _freeFrames = [];
  late _FrameUploads _frame = _FrameUploads(this);
  _TransientBlock? _current;

  _TransientBlock allocate(int size, int alignment) {
    var block = _current;
    if (block != null) {
      final offset = GpuBackend.alignUp(block.used, alignment);
      if (offset + size <= block.capacity) {
        block
          ..lastOffset = offset
          ..used = offset + size;
        return block;
      }
    }
    block = _current = _takeBlock(size);
    _frame.blocks.add(block);
    return block
      ..lastOffset = 0
      ..used = size;
  }

  _TransientBlock _takeBlock(int size) {
    for (var i = 0; i < _free.length; i++) {
      final block = _free[i];
      if (block.capacity >= size) {
        _free.removeAt(i);
        return block
          ..used = 0
          ..flushed = 0;
      }
    }
    var capacity = _blockSize;
    while (capacity < size) {
      capacity *= 2;
    }
    return _TransientBlock(
      _backend.createBuffer(
        storageMode: GpuStorageMode.hostVisible,
        sizeInBytes: capacity,
      ),
      capacity,
    );
  }

  void flush() {
    for (var i = 0; i < _frame.blocks.length; i++) {
      _frame.blocks[i].flush();
    }
  }

  void Function() passCompletion() {
    _frame.pendingPasses++;
    return _frame.completionCallback;
  }

  void endFrame() {
    final frame = _frame..ended = true;
    if (frame.pendingPasses == 0) {
      _release(frame);
    }
    _frame = _freeFrames.isNotEmpty
        ? _freeFrames.removeLast()
        : _FrameUploads(this);
    _current = null;
  }

  void _release(_FrameUploads frame) {
    for (var i = 0; i < frame.blocks.length; i++) {
      if (_free.length < _maxFreeBlocks) {
        _free.add(frame.blocks[i]);
      }
    }
    frame
      ..blocks.clear()
      ..pendingPasses = 0
      ..ended = false;
    if (_freeFrames.length < _maxFreeFrames) {
      _freeFrames.add(frame);
    }
  }
}

/// The pass recorded while the GPU device is not ready: it records nothing.
class _SuspendedRenderPass() implements GpuRenderPass {
  static final _SuspendedRenderPass instance = _SuspendedRenderPass();

  static Image? _blank;

  /// A new handle to a transparent 1 by 1 image (a clone, so that callers
  /// may dispose it).
  static Image blankImage() {
    final blank = _blank ??= () {
      final recorder = PictureRecorder();
      Canvas(recorder);
      final picture = recorder.endRecording();
      final image = picture.toImageSync(1, 1);
      picture.dispose();
      return image;
    }();
    return blank.clone();
  }

  @override
  void bindPipeline(GpuPipeline pipeline) {}

  @override
  void setBlendState(BlendState blend) {}

  @override
  void setDepthState({
    required CompareFunction compare,
    required bool writeEnabled,
  }) {}

  @override
  void setCullMode(CullMode cullMode) {}

  @override
  void setWindingOrder(WindingOrder windingOrder) {}

  @override
  void setViewport(
    int x,
    int y,
    int width,
    int height, {
    double zNear = 0.0,
    double zFar = 1.0,
  }) {}

  @override
  void setScissor(int x, int y, int width, int height) {}

  @override
  void setStencil(StencilState? stencil) {}

  @override
  void setPolygonMode(PolygonFillMode mode) {}

  @override
  void setPrimitiveTopology(PrimitiveTopology topology) {}

  @override
  void bindVertexBuffer(
    GpuBuffer buffer, {
    required int offsetInBytes,
    required int lengthInBytes,
    int slot = 0,
  }) {}

  @override
  void bindIndexBuffer(
    GpuBuffer buffer, {
    required int offsetInBytes,
    required int lengthInBytes,
    required GpuIndexType indexType,
  }) {}

  @override
  void bindUniform(
    GpuUniformSlot slot,
    GpuBuffer buffer, {
    required int offsetInBytes,
    required int lengthInBytes,
  }) {}

  @override
  void bindTexture(
    GpuUniformSlot slot,
    GpuTexture texture, {
    TextureSampler sampler = TextureSampler.nearest,
  }) {}

  @override
  void clearBindings() {}

  @override
  void draw(int vertexCount, {int instanceCount = 1}) {}

  @override
  void drawIndexed(int indexCount, {int instanceCount = 1}) {}

  @override
  Image submit({void Function()? onCompleted}) {
    onCompleted?.call();
    return blankImage();
  }

  @override
  void commit({void Function()? onCompleted}) {
    onCompleted?.call();
  }
}
