// ignore_for_file: avoid_redundant_argument_values

part of 'gpu_backend.dart';

/// The number of color textures [target] (a render target of the Flutter
/// GPU backend) has created, for tests.
@visibleForTesting
int debugColorTextureCount(GpuRenderTarget target) {
  return (target as _FlutterGpuRenderTarget)._buffers.length;
}

/// A render target: a depth texture, a multisample color texture with MSAA,
/// and the color textures its passes render into and whose images Flutter
/// draws. Its textures are created again after a device loss.
class _FlutterGpuRenderTarget(
  final GpuBackend _backend,
  @override final int width,
  @override final int height,
  final int _sampleCount,
  final Vector4 _clearValue,
) implements GpuRenderTarget {
  static const _maxColorTextures = 3;

  final List<_ColorBuffer> _buffers = [];
  gpu.Texture? _multisampleColorTexture;
  late gpu.Texture _depthTexture;
  int _generation = -1;

  /// Creates the textures of the current device unless they exist.
  void ensureCurrent() {
    if (_generation == base.GpuBackend.deviceGeneration) {
      return;
    }
    _generation = base.GpuBackend.deviceGeneration;
    final context = _backend._context;
    _buffers.clear();
    _lastPresented = null;
    _multisampleColorTexture = _sampleCount > 1
        ? context.createTexture(
            gpu.StorageMode.deviceTransient,
            width,
            height,
            format: GpuBackend._colorFormat,
            sampleCount: _sampleCount,
            enableShaderReadUsage: false,
          )
        : null;
    _depthTexture = context.createTexture(
      gpu.StorageMode.deviceTransient,
      width,
      height,
      format: _backend._depthStencilFormat,
      sampleCount: _sampleCount,
      enableShaderReadUsage: _sampleCount == 1,
    );
  }

  /// The color buffer for a new pass.
  _ColorBuffer acquire() {
    ensureCurrent();
    final drawnFrames = GpuBackend._drawnFrames;
    _ColorBuffer? oldest;
    for (final buffer in _buffers) {
      final presented = buffer.presentedFrame;
      if (presented == null || drawnFrames >= presented + 2) {
        return buffer;
      }
      if (oldest == null || buffer.presentedSerial < oldest.presentedSerial) {
        oldest = buffer;
      }
    }
    if (oldest != null && _buffers.length >= _maxColorTextures) {
      return oldest;
    }
    final texture = _backend._context.createTexture(
      gpu.StorageMode.devicePrivate,
      width,
      height,
      format: GpuBackend._colorFormat,
    );
    final multisample = _multisampleColorTexture;
    final buffer = _ColorBuffer(
      texture,
      gpu.RenderTarget.singleColor(
        gpu.ColorAttachment(
          texture: multisample ?? texture,
          resolveTexture: multisample == null ? null : texture,
          storeAction: multisample == null
              ? gpu.StoreAction.store
              : gpu.StoreAction.multisampleResolve,
          clearValue: _clearValue,
        ),
        depthStencilAttachment: gpu.DepthStencilAttachment(
          texture: _depthTexture,
          depthClearValue: 1.0,
        ),
      ),
    );
    _buffers.add(buffer);
    return buffer;
  }

  /// Records that the image of [buffer] was handed out.
  void present(_ColorBuffer buffer) {
    buffer
      ..presentedFrame = GpuBackend._drawnFrames
      ..presentedSerial = _presentations++;
    _lastPresented = buffer;
  }

  /// Records that the image last handed out is drawn again in this frame.
  void representLast() {
    _lastPresented?.presentedFrame = GpuBackend._drawnFrames;
  }

  _ColorBuffer? _lastPresented;

  int _presentations = 0;
}

/// A color texture of a [_FlutterGpuRenderTarget] and the render target that
/// renders into it.
class _ColorBuffer(
  final gpu.Texture texture,
  final gpu.RenderTarget renderTarget,
) {
  /// The number of frames Flutter had drawn when the image of this texture
  /// was last handed out, or `null` if it never was.
  int? presentedFrame;

  /// Orders the presentations of the buffers of a render target.
  int presentedSerial = 0;
}

/// A [GpuTextureTarget] of the Flutter GPU backend: one color texture, which
/// later passes sample, and a transient depth texture, created once, and
/// again after a device loss.
class _FlutterGpuTextureTarget(
  final GpuBackend _backend,
  @override final int width,
  @override final int height,
  @override final GpuPixelFormat format,
  final int _sampleCount,
  final Vector4 _clearValue,
) implements GpuTextureTarget {
  @override
  late final _FlutterGpuTexture texture = _FlutterGpuTexture(() {
    ensureCurrent();
    return _color;
  });

  late gpu.Texture _color;
  late gpu.RenderTarget _renderTarget;
  int _generation = -1;

  /// The render target of the current device, creating it when stale.
  gpu.RenderTarget get renderTarget {
    ensureCurrent();
    return _renderTarget;
  }

  /// Creates the textures of the current device unless they exist.
  void ensureCurrent() {
    if (_generation == base.GpuBackend.deviceGeneration) {
      return;
    }
    _generation = base.GpuBackend.deviceGeneration;
    final context = _backend._context;
    final pixelFormat = _backend._pixelFormat(format);
    final color = _color = context.createTexture(
      gpu.StorageMode.devicePrivate,
      width,
      height,
      format: pixelFormat,
    );
    // Multisampled passes render into a transient texture resolved into the
    // sampled one.
    final multisampleTexture = _sampleCount > 1
        ? context.createTexture(
            gpu.StorageMode.deviceTransient,
            width,
            height,
            format: pixelFormat,
            sampleCount: _sampleCount,
            enableShaderReadUsage: false,
          )
        : null;
    final depthTexture = context.createTexture(
      gpu.StorageMode.deviceTransient,
      width,
      height,
      format: _backend._depthStencilFormat,
      sampleCount: _sampleCount,
      enableShaderReadUsage: false,
    );
    _renderTarget = gpu.RenderTarget.singleColor(
      multisampleTexture == null
          ? gpu.ColorAttachment(texture: color, clearValue: _clearValue)
          : gpu.ColorAttachment(
              texture: multisampleTexture,
              resolveTexture: color,
              storeAction: gpu.StoreAction.multisampleResolve,
              clearValue: _clearValue,
            ),
      depthStencilAttachment: gpu.DepthStencilAttachment(
        texture: depthTexture,
        depthClearValue: 1.0,
      ),
    );
    texture.replace(color);
  }
}

class const _FlutterGpuFrame(final GpuBackend _backend)
    implements base.GpuFrame {
  @override
  base.GpuRenderPass beginRenderPass(
    GpuRenderTarget target, {
    bool keepContents = false,
  }) {
    final commandBuffer = _backend._context.createCommandBuffer();
    if (target is _FlutterGpuTextureTarget) {
      return _FlutterGpuRenderPass(
        _backend,
        null,
        null,
        commandBuffer,
        _begin(
          commandBuffer,
          target.renderTarget,
        ),
      );
    }
    final renderTarget = target as _FlutterGpuRenderTarget;
    final buffer = renderTarget.acquire();
    return _FlutterGpuRenderPass(
      _backend,
      renderTarget,
      buffer,
      commandBuffer,
      _begin(commandBuffer, buffer.renderTarget),
    );
  }

  static gpu.RenderPass _begin(
    gpu.CommandBuffer commandBuffer,
    gpu.RenderTarget renderTarget,
  ) {
    return commandBuffer.createRenderPass(renderTarget)
      // The default state documented on `GpuFrame.beginRenderPass`.
      ..setWindingOrder(gpu.WindingOrder.counterClockwise)
      ..setCullMode(gpu.CullMode.none)
      ..setColorBlendEnable(false)
      ..setDepthWriteEnable(true)
      ..setDepthCompareOperation(gpu.CompareFunction.less);
  }

  @override
  void end() {}
}
