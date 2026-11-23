// ignore_for_file: avoid_redundant_argument_values

part of 'gpu_backend.dart';

/// Renders small passes and reads them back: the check that the device
/// renders (after a loss, on resume) and, on OpenGL ES, the check whether it
/// renders into float textures.
///
/// It draws with the texture copy shader of flame_3d, into 4 by 4 targets,
/// and creates its objects anew on every use.
class _DeviceProbe._(
  final GpuBackend _backend,
  final gpu.Shader _vertex,
  final gpu.Shader _fragment,
  final gpu.UniformSlot _source,
) {
  static const _copyBundle =
      'packages/flame_3d/assets/shaders/texture_copy.shaderbundle';
  static const _size = 4;

  /// A probe, or `null` when the copy shader is not loaded.
  static _DeviceProbe? create(GpuBackend backend) {
    try {
      final library = backend.loadShaderLibrary(_copyBundle);
      final vertex = (library['TextureVertex'] as _FlutterGpuShader).raw;
      final fragment = (library['TextureFragment'] as _FlutterGpuShader).raw;
      return _DeviceProbe._(
        backend,
        vertex,
        fragment,
        fragment.getUniformSlot('sourceTexture'),
      );
      // Without the shader there is nothing to probe with.
      // ignore: avoid_catches_without_on_clauses
    } catch (_) {
      return null;
    }
  }

  gpu.GpuContext get _context => _backend._context;

  /// Whether a draw renders and reads back the right color.
  Future<bool> renders() async => await checkRenders() == null;

  /// `null` when a draw renders and reads back the right color, otherwise
  /// what went wrong.
  Future<String?> checkRenders() async {
    try {
      const color = [51, 102, 204, 255];
      final (texture, target) = _target(
        GpuBackend._colorFormat,
        Vector4(1, 0, 0, 1),
      );
      final commands = _context.createCommandBuffer();
      _draw(commands, target, [(_solid(color), null)]);
      if (!await _submit(commands)) {
        return 'the command buffer failed';
      }
      return _compare(await _read(texture), color, 3);
      // Any failure means the device does not render.
      // ignore: avoid_catches_without_on_clauses
    } catch (error) {
      return '$error';
    }
  }

  /// Whether a texture target of [format] renders and is sampled by a later
  /// pass, see [checkFloatTexture].
  Future<bool> rendersIntoFloatTexture(
    GpuPixelFormat format, {
    bool? checkRange,
  }) async {
    return await checkFloatTexture(format, checkRange: checkRange) == null;
  }

  /// `null` when a texture target of [format] renders and is sampled by a
  /// later pass, keeping values above 1 for [GpuPixelFormat.rgbaFloat16]
  /// (or whenever [checkRange] is `true`), otherwise what went wrong.
  ///
  /// The range check clears the target to 0.75, adds 0.75 (1.5, which an
  /// 8-bit or clamped target keeps at 1) and subtracts 0.75 again (0.75, or
  /// 0.25 when clamped), then copies it into an 8-bit target: 191 or 64.
  /// Otherwise the target is cleared to 0.5 and copied into an 8-bit target,
  /// red only (128).
  Future<String?> checkFloatTexture(
    GpuPixelFormat format, {
    bool? checkRange,
  }) async {
    try {
      final range = checkRange ?? format == GpuPixelFormat.rgbaFloat16;
      final (floatTexture, floatTarget) = _target(
        _backend._pixelFormat(format),
        range ? Vector4(0.75, 0.75, 0.75, 1) : Vector4(0.5, 0.5, 0.5, 1),
      );
      final first = _context.createCommandBuffer();
      final quarter = _solid(const [191, 191, 191, 255]);
      _draw(
        first,
        floatTarget,
        range ? [(quarter, _add), (quarter, _subtract)] : [(quarter, _keep)],
      );
      final (texture, target) = _target(
        GpuBackend._colorFormat,
        Vector4(0, 0, 0, 1),
      );
      final second = _context.createCommandBuffer();
      _draw(second, target, [(floatTexture, null)]);
      final firstDone = _submit(first);
      if (!await _submit(second) || !await firstDone) {
        return 'a command buffer failed';
      }
      return _compare(
        await _read(texture),
        range ? const [191, 191, 191, 255] : const [128, 0, 0, 255],
        10,
      );
      // A format the device cannot render into fails somewhere on the way.
      // ignore: avoid_catches_without_on_clauses
    } catch (error) {
      return '$error';
    }
  }

  /// `null` when [pixel] is within [tolerance] of [expected], otherwise a
  /// description of the difference.
  static String? _compare(
    List<int>? pixel,
    List<int> expected,
    int tolerance,
  ) {
    if (pixel == null) {
      return 'the pixels could not be read back';
    }
    return _near(pixel, expected, tolerance)
        ? null
        : 'read back $pixel instead of $expected';
  }

  (gpu.Texture, gpu.RenderTarget) _target(
    gpu.PixelFormat format,
    Vector4 clear,
  ) {
    final texture = _context.createTexture(
      gpu.StorageMode.devicePrivate,
      _size,
      _size,
      format: format,
    );
    final depth = _context.createTexture(
      gpu.StorageMode.deviceTransient,
      _size,
      _size,
      format: _backend._depthStencilFormat,
      enableShaderReadUsage: false,
    );
    return (
      texture,
      gpu.RenderTarget.singleColor(
        gpu.ColorAttachment(texture: texture, clearValue: clear),
        depthStencilAttachment: gpu.DepthStencilAttachment(
          texture: depth,
          depthClearValue: 1.0,
        ),
      ),
    );
  }

  gpu.Texture _solid(List<int> rgba) {
    return _context.createTexture(
      gpu.StorageMode.hostVisible,
      1,
      1,
      format: GpuBackend._colorFormat,
    )..overwrite(ByteData.sublistView(Uint8List.fromList(rgba)));
  }

  /// Draws each source over the whole [target], blended with its equation
  /// (none when `null`).
  void _draw(
    gpu.CommandBuffer commands,
    gpu.RenderTarget target,
    List<(gpu.Texture, gpu.ColorBlendEquation?)> draws,
  ) {
    final quad = _context.createDeviceBufferWithCopy(
      ByteData.sublistView(
        Float32List.fromList(const [
          -1, -1, 0, 1, -1, 0, 1, 1, 0, //
          -1, -1, 0, 1, 1, 0, -1, 1, 0, //
        ]),
      ),
    );
    final pipeline = _context.createRenderPipeline(
      _vertex,
      _fragment,
      vertexLayout: const gpu.VertexLayout(
        buffers: [
          gpu.VertexBuffer(
            strideInBytes: 12,
            attributes: [
              gpu.VertexAttribute(
                name: 'vertexPosition',
                offsetInBytes: 0,
                format: gpu.VertexFormat.float32x3,
              ),
            ],
          ),
        ],
      ),
    );
    final pass = commands.createRenderPass(target)
      ..setWindingOrder(gpu.WindingOrder.counterClockwise)
      ..setCullMode(gpu.CullMode.none)
      ..setDepthWriteEnable(false)
      ..setDepthCompareOperation(gpu.CompareFunction.always);
    for (final (source, blend) in draws) {
      pass
        ..bindPipeline(pipeline)
        ..bindVertexBuffer(
          gpu.BufferView(quad, offsetInBytes: 0, lengthInBytes: 72),
        )
        ..bindTexture(_source, source, sampler: gpu.SamplerOptions())
        ..setColorBlendEnable(blend != null);
      if (blend != null) {
        pass.setColorBlendEquation(blend);
      }
      pass.draw(6);
    }
  }

  static Future<bool> _submit(gpu.CommandBuffer commands) {
    final done = Completer<bool>();
    commands.submit(completionCallback: done.complete);
    return done.future.timeout(
      const Duration(seconds: 3),
      onTimeout: () => false,
    );
  }

  /// The pixel at the center of [texture], once the GPU rendered it.
  ///
  /// Every probe target ends opaque. On OpenGL ES, Impeller runs the
  /// commands of a submitted command buffer later (when it renders a frame),
  /// and reports it complete before: until then the texture reads back
  /// transparent, so it is read again, frame after frame, for at most two
  /// seconds.
  static Future<List<int>?> _read(gpu.Texture texture) async {
    final image = texture.asImage();
    final waited = Stopwatch()..start();
    try {
      while (true) {
        final data = await image.toByteData();
        if (data == null) {
          return null;
        }
        final i = ((image.height ~/ 2) * image.width + image.width ~/ 2) * 4;
        final pixel = [
          data.getUint8(i),
          data.getUint8(i + 1),
          data.getUint8(i + 2),
          data.getUint8(i + 3),
        ];
        if (pixel[3] != 0 || waited.elapsed > const Duration(seconds: 2)) {
          return pixel;
        }
        try {
          SchedulerBinding.instance.scheduleFrame();
          // Without a binding, waiting is all there is to do.
          // ignore: avoid_catches_without_on_clauses
        } catch (_) {}
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }
    } finally {
      image.dispose();
    }
  }

  static bool _near(List<int> pixel, List<int> expected, int tolerance) {
    for (var i = 0; i < 4; i++) {
      if ((pixel[i] - expected[i]).abs() > tolerance) {
        return false;
      }
    }
    return true;
  }

  static final _add = gpu.ColorBlendEquation(
    sourceColorBlendFactor: gpu.BlendFactor.one,
    destinationColorBlendFactor: gpu.BlendFactor.one,
    sourceAlphaBlendFactor: gpu.BlendFactor.zero,
    destinationAlphaBlendFactor: gpu.BlendFactor.one,
  );

  static final _keep = gpu.ColorBlendEquation(
    sourceColorBlendFactor: gpu.BlendFactor.zero,
    destinationColorBlendFactor: gpu.BlendFactor.one,
    sourceAlphaBlendFactor: gpu.BlendFactor.zero,
    destinationAlphaBlendFactor: gpu.BlendFactor.one,
  );

  static final _subtract = gpu.ColorBlendEquation(
    colorBlendOperation: gpu.BlendOperation.reverseSubtract,
    sourceColorBlendFactor: gpu.BlendFactor.one,
    destinationColorBlendFactor: gpu.BlendFactor.one,
    sourceAlphaBlendFactor: gpu.BlendFactor.zero,
    destinationAlphaBlendFactor: gpu.BlendFactor.one,
  );
}
