// ignore_for_file: avoid_redundant_argument_values

part of 'gpu_backend.dart';

/// A render pass; [_target] and [_buffer] are those of a pass whose image is
/// returned by [submit], and `null` for a pass into a texture target.
class _FlutterGpuRenderPass(
  final GpuBackend _backend,
  final _FlutterGpuRenderTarget? _target,
  final _ColorBuffer? _buffer,
  final gpu.CommandBuffer _commandBuffer,
  final gpu.RenderPass _renderPass,
) implements base.GpuRenderPass {
  @override
  void bindPipeline(GpuPipeline pipeline) {
    _renderPass.bindPipeline((pipeline as _FlutterGpuPipeline).raw);
  }

  @override
  void setBlendState(BlendState blend) {
    if (blend == BlendState.opaque) {
      // Disabling blending alone keeps the effect of an equation that keeps
      // the target (a depth-only draw): the color of the next draw would be
      // lost.
      _renderPass
        ..setColorBlendEquation(_replace)
        ..setColorBlendEnable(false);
      return;
    }
    _renderPass
      ..setColorBlendEnable(true)
      ..setColorBlendEquation(switch (blend) {
        BlendState.opaque || BlendState.premultipliedAlpha => _premultiplied,
        BlendState.alpha => _straightAlpha,
        BlendState.additive => _additive,
        BlendState.depthOnly => _keepTarget,
        BlendState.wboitAccum => _wboitAccum,
        BlendState.wboitReveal => _wboitReveal,
        BlendState.wboitAccumStraight => _wboitAccumStraight,
      });
  }

  @override
  void setDepthState({
    required CompareFunction compare,
    required bool writeEnabled,
  }) {
    _renderPass
      ..setDepthCompareOperation(_compareFunction(compare))
      ..setDepthWriteEnable(writeEnabled);
  }

  static gpu.CompareFunction _compareFunction(CompareFunction compare) {
    return switch (compare) {
      CompareFunction.never => gpu.CompareFunction.never,
      CompareFunction.less => gpu.CompareFunction.less,
      CompareFunction.equal => gpu.CompareFunction.equal,
      CompareFunction.lessEqual => gpu.CompareFunction.lessEqual,
      CompareFunction.greater => gpu.CompareFunction.greater,
      CompareFunction.notEqual => gpu.CompareFunction.notEqual,
      CompareFunction.greaterEqual => gpu.CompareFunction.greaterEqual,
      CompareFunction.always => gpu.CompareFunction.always,
    };
  }

  static gpu.StencilOperation _stencilOp(StencilOp op) {
    return switch (op) {
      StencilOp.keep => gpu.StencilOperation.keep,
      StencilOp.zero => gpu.StencilOperation.zero,
      StencilOp.replace => gpu.StencilOperation.setToReferenceValue,
      StencilOp.incrementClamp => gpu.StencilOperation.incrementClamp,
      StencilOp.decrementClamp => gpu.StencilOperation.decrementClamp,
      StencilOp.invert => gpu.StencilOperation.invert,
      StencilOp.incrementWrap => gpu.StencilOperation.incrementWrap,
      StencilOp.decrementWrap => gpu.StencilOperation.decrementWrap,
    };
  }

  @override
  void setCullMode(CullMode cullMode) {
    _renderPass.setCullMode(switch (cullMode) {
      CullMode.none => gpu.CullMode.none,
      CullMode.frontFace => gpu.CullMode.frontFace,
      CullMode.backFace => gpu.CullMode.backFace,
    });
  }

  @override
  void setWindingOrder(WindingOrder windingOrder) {
    _renderPass.setWindingOrder(switch (windingOrder) {
      WindingOrder.clockwise => gpu.WindingOrder.clockwise,
      WindingOrder.counterClockwise => gpu.WindingOrder.counterClockwise,
    });
  }

  @override
  void setViewport(
    int x,
    int y,
    int width,
    int height, {
    double zNear = 0.0,
    double zFar = 1.0,
  }) {
    _renderPass.setViewport(
      gpu.Viewport(
        x: x,
        y: y,
        width: width,
        height: height,
        depthRange: gpu.DepthRange(zNear: zNear, zFar: zFar),
      ),
    );
  }

  @override
  void setScissor(int x, int y, int width, int height) {
    _renderPass.setScissor(
      gpu.Scissor(x: x, y: y, width: width, height: height),
    );
  }

  static final Map<StencilState, gpu.StencilConfig> _stencilConfigs = {};

  @override
  void setStencil(StencilState? stencil) {
    if (stencil == null) {
      _renderPass
        ..setStencilReference(0)
        ..setStencilConfig(_disabledStencil);
      return;
    }
    final config = _stencilConfigs.length >= 64
        ? _createStencilConfig(stencil)
        : (_stencilConfigs[stencil] ??= _createStencilConfig(stencil));
    _renderPass
      ..setStencilReference(stencil.referenceValue & 0xFF)
      ..setStencilConfig(config);
  }

  static gpu.StencilConfig _createStencilConfig(StencilState stencil) =>
      gpu.StencilConfig(
        compareFunction: _compareFunction(stencil.compare),
        stencilFailureOperation: _stencilOp(stencil.stencilFail),
        depthFailureOperation: _stencilOp(stencil.depthFail),
        depthStencilPassOperation: _stencilOp(stencil.pass),
        readMask: stencil.readMask & 0xFF,
        writeMask: stencil.writeMask & 0xFF,
      );

  @override
  void setPolygonMode(PolygonFillMode mode) {
    _renderPass.setPolygonMode(switch (mode) {
      PolygonFillMode.fill => gpu.PolygonMode.fill,
      PolygonFillMode.wireframe => gpu.PolygonMode.line,
    });
  }

  @override
  void setPrimitiveTopology(PrimitiveTopology topology) {
    _renderPass.setPrimitiveType(switch (topology) {
      PrimitiveTopology.triangles => gpu.PrimitiveType.triangle,
      PrimitiveTopology.triangleStrip => gpu.PrimitiveType.triangleStrip,
      PrimitiveTopology.lines => gpu.PrimitiveType.line,
      PrimitiveTopology.lineStrip => gpu.PrimitiveType.lineStrip,
      PrimitiveTopology.points => gpu.PrimitiveType.point,
    });
  }

  @override
  void bindVertexBuffer(
    GpuBuffer buffer, {
    required int offsetInBytes,
    required int lengthInBytes,
    int slot = 0,
  }) {
    _renderPass.bindVertexBuffer(
      (buffer as _FlutterGpuBuffer).view(offsetInBytes, lengthInBytes),
      slot: slot,
    );
  }

  @override
  void bindIndexBuffer(
    GpuBuffer buffer, {
    required int offsetInBytes,
    required int lengthInBytes,
    required GpuIndexType indexType,
  }) {
    _renderPass.bindIndexBuffer(
      (buffer as _FlutterGpuBuffer).view(offsetInBytes, lengthInBytes),
      switch (indexType) {
        GpuIndexType.uint16 => gpu.IndexType.int16,
        GpuIndexType.uint32 => gpu.IndexType.int32,
      },
    );
  }

  @override
  void bindUniform(
    GpuUniformSlot slot,
    GpuBuffer buffer, {
    required int offsetInBytes,
    required int lengthInBytes,
  }) {
    _renderPass.bindUniform(
      (slot as _FlutterGpuUniformSlot).raw,
      (buffer as _FlutterGpuBuffer).view(offsetInBytes, lengthInBytes),
    );
  }

  @override
  void bindTexture(
    GpuUniformSlot slot,
    GpuTexture texture, {
    TextureSampler sampler = TextureSampler.nearest,
  }) {
    _renderPass.bindTexture(
      (slot as _FlutterGpuUniformSlot).raw,
      (texture as _FlutterGpuTexture).bindable,
      // Passed explicitly: `flutter_gpu` allocates default options otherwise.
      sampler: _backend._samplerFor(sampler),
    );
  }

  @override
  void clearBindings() => _renderPass.clearBindings();

  @override
  void draw(int vertexCount, {int instanceCount = 1}) {
    _renderPass.draw(vertexCount, instanceCount: instanceCount);
  }

  @override
  void drawIndexed(int indexCount, {int instanceCount = 1}) {
    _renderPass.drawIndexed(indexCount, instanceCount: instanceCount);
  }

  @override
  Image submit({void Function()? onCompleted}) {
    final target = _target;
    final buffer = _buffer;
    if (target == null || buffer == null) {
      throw StateError('A pass into a texture target ends with commit');
    }
    commit(onCompleted: onCompleted);
    target.present(buffer);
    return buffer.texture.asImage();
  }

  @override
  void commit({void Function()? onCompleted}) {
    final backend = _backend;
    try {
      _commandBuffer.submit(
        completionCallback: (success) {
          if (!success) {
            backend.reportDeviceLost(
              'a command buffer failed on the GPU',
            );
          }
          onCompleted?.call();
        },
      );
      // Flutter GPU reports a failed submission with a plain Exception.
    } on Exception catch (error) {
      backend.reportDeviceLost('submitting a command buffer failed: $error');
      onCompleted?.call();
    }
  }

  static final _disabledStencil = gpu.StencilConfig(
    readMask: 0xFF,
    writeMask: 0,
  );

  static final _replace = gpu.ColorBlendEquation(
    sourceColorBlendFactor: gpu.BlendFactor.one,
    destinationColorBlendFactor: gpu.BlendFactor.zero,
    sourceAlphaBlendFactor: gpu.BlendFactor.one,
    destinationAlphaBlendFactor: gpu.BlendFactor.zero,
  );

  static final _premultiplied = gpu.ColorBlendEquation(
    sourceColorBlendFactor: gpu.BlendFactor.one,
    destinationColorBlendFactor: gpu.BlendFactor.oneMinusSourceAlpha,
    sourceAlphaBlendFactor: gpu.BlendFactor.one,
    destinationAlphaBlendFactor: gpu.BlendFactor.oneMinusSourceAlpha,
  );

  static final _straightAlpha = gpu.ColorBlendEquation(
    sourceColorBlendFactor: gpu.BlendFactor.sourceAlpha,
    destinationColorBlendFactor: gpu.BlendFactor.oneMinusSourceAlpha,
    sourceAlphaBlendFactor: gpu.BlendFactor.one,
    destinationAlphaBlendFactor: gpu.BlendFactor.oneMinusSourceAlpha,
  );

  // Added light covers nothing: the alpha of the target is kept.
  static final _additive = gpu.ColorBlendEquation(
    sourceColorBlendFactor: gpu.BlendFactor.one,
    destinationColorBlendFactor: gpu.BlendFactor.one,
    sourceAlphaBlendFactor: gpu.BlendFactor.zero,
    destinationAlphaBlendFactor: gpu.BlendFactor.one,
  );

  // Depth only: the target keeps its color and alpha.
  static final _keepTarget = gpu.ColorBlendEquation(
    sourceColorBlendFactor: gpu.BlendFactor.zero,
    destinationColorBlendFactor: gpu.BlendFactor.one,
    sourceAlphaBlendFactor: gpu.BlendFactor.zero,
    destinationAlphaBlendFactor: gpu.BlendFactor.one,
  );

  static final _wboitAccum = gpu.ColorBlendEquation(
    sourceColorBlendFactor: gpu.BlendFactor.one,
    destinationColorBlendFactor: gpu.BlendFactor.one,
    sourceAlphaBlendFactor: gpu.BlendFactor.one,
    destinationAlphaBlendFactor: gpu.BlendFactor.one,
  );

  static final _wboitAccumStraight = gpu.ColorBlendEquation(
    sourceColorBlendFactor: gpu.BlendFactor.sourceAlpha,
    destinationColorBlendFactor: gpu.BlendFactor.one,
    sourceAlphaBlendFactor: gpu.BlendFactor.one,
    destinationAlphaBlendFactor: gpu.BlendFactor.one,
  );

  static final _wboitReveal = gpu.ColorBlendEquation(
    sourceColorBlendFactor: gpu.BlendFactor.zero,
    destinationColorBlendFactor: gpu.BlendFactor.oneMinusSourceAlpha,
    sourceAlphaBlendFactor: gpu.BlendFactor.zero,
    destinationAlphaBlendFactor: gpu.BlendFactor.oneMinusSourceAlpha,
  );
}
