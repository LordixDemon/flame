part of 'gpu_backend.dart';

/// A texture handle that is created again after a device loss (see
/// [base.GpuBackend.deviceGeneration]): by [_create] (empty: its owner
/// uploads its pixels again), or, for a texture that wraps a `dart:ui`
/// image, not at all: it is then [isLost] and bound as a transparent texture.
class _FlutterGpuTexture implements GpuTexture {
  _FlutterGpuTexture(gpu.Texture Function() this._create)
    : _backend = null,
      _raw = null;

  _FlutterGpuTexture.wrapping(GpuBackend this._backend, gpu.Texture raw)
    : _create = null,
      _raw = raw,
      _generation = base.GpuBackend.deviceGeneration;

  final gpu.Texture Function()? _create;
  final GpuBackend? _backend;
  gpu.Texture? _raw;
  int _generation = -1;
  bool _lost = false;

  /// The texture of the current device.
  gpu.Texture get raw {
    final raw = _raw;
    if (raw != null && _generation == base.GpuBackend.deviceGeneration) {
      return raw;
    }
    _generation = base.GpuBackend.deviceGeneration;
    final create = _create;
    if (create != null) {
      return _raw = create();
    }
    _lost = true;
    return raw!;
  }

  /// Whether this texture wrapped an image of a device that was lost since.
  bool get isLost {
    raw;
    return _lost;
  }

  /// The texture to bind: [raw], or a transparent texture once [isLost].
  gpu.Texture get bindable {
    final texture = raw;
    return _lost ? _backend!._lostImageTexture : texture;
  }

  /// Replaces the texture, for its texture target.
  void replace(gpu.Texture raw) {
    _raw = raw;
    _generation = base.GpuBackend.deviceGeneration;
  }

  @override
  int get mipLevelCount => raw.mipLevelCount;

  @override
  void write(ByteData data, {int mipLevel = 0}) {
    raw.overwrite(data, mipLevel: mipLevel);
  }

  @override
  Image asImage() => bindable.asImage();
}

/// A buffer handle that is created again (empty) after a device loss; its
/// owners write their data again (surfaces upload their vertices in a buffer
/// of their own, the transient blocks of a device are rewritten every frame).
class _FlutterGpuBuffer(
  @override final int sizeInBytes,
  final gpu.DeviceBuffer Function() _create, {
  bool deferred = false,
}) implements GpuBuffer {
  this {
    if (!deferred) {
      raw;
    }
  }

  gpu.DeviceBuffer? _raw;
  int _generation = -1;

  /// The buffer of the current device.
  gpu.DeviceBuffer get raw {
    final raw = _raw;
    if (raw != null && _generation == base.GpuBackend.deviceGeneration) {
      return raw;
    }
    _generation = base.GpuBackend.deviceGeneration;
    _views.clear();
    _view0 = null;
    _view1 = null;
    _viewOffset0 = -1;
    _viewOffset1 = -1;
    return _raw = _create();
  }

  @override
  void write(ByteData data, {int destinationOffsetInBytes = 0}) {
    raw.overwrite(data, destinationOffsetInBytes: destinationOffsetInBytes);
  }

  // `flutter_gpu` takes buffer ranges as `BufferView` objects. Static geometry
  // buffers hit the two-entry fast path (vertex + index slice) without
  // touching the hash map; transient buffers reuse offsets in `_views`.
  gpu.BufferView? _view0;
  int _viewOffset0 = -1;
  int _viewLength0 = 0;
  gpu.BufferView? _view1;
  int _viewOffset1 = -1;
  int _viewLength1 = 0;
  final Map<int, gpu.BufferView> _views = {};

  gpu.BufferView view(int offsetInBytes, int lengthInBytes) {
    final buffer = raw;
    if (_viewOffset0 == offsetInBytes &&
        _viewLength0 == lengthInBytes &&
        _view0 != null) {
      return _view0!;
    }
    if (_viewOffset1 == offsetInBytes &&
        _viewLength1 == lengthInBytes &&
        _view1 != null) {
      return _view1!;
    }
    var view = _views[offsetInBytes];
    if (view == null || view.lengthInBytes != lengthInBytes) {
      if (_views.length >= _maxViews) {
        _views.clear();
      }
      view = _views[offsetInBytes] = gpu.BufferView(
        buffer,
        offsetInBytes: offsetInBytes,
        lengthInBytes: lengthInBytes,
      );
    }
    if (_view0 == null) {
      _view0 = view;
      _viewOffset0 = offsetInBytes;
      _viewLength0 = lengthInBytes;
    } else if (_view1 == null) {
      _view1 = view;
      _viewOffset1 = offsetInBytes;
      _viewLength1 = lengthInBytes;
    }
    return view;
  }

  static const _maxViews = 4096;
}

class _FlutterGpuShaderLibrary(
  final gpu.ShaderLibrary raw,
  final String _assetName,
  final Map<String, List<GpuShaderInput>>? _inputs,
) implements GpuShaderLibrary {
  final Map<String, _FlutterGpuShader> _shaders = {};

  @override
  GpuShader operator [](String entryPoint) {
    return _shaders.putIfAbsent(entryPoint, () {
      final shader = raw[entryPoint];
      if (shader == null) {
        throw StateError(
          'Shader "$entryPoint" not found in library "$_assetName"',
        );
      }
      return _FlutterGpuShader(shader, _inputs?[entryPoint]);
    });
  }
}

class _FlutterGpuShader(
  final gpu.Shader raw,
  @override final List<GpuShaderInput>? inputs,
) implements GpuShader {
  final Map<String, _FlutterGpuUniformSlot> _slots = {};

  @override
  GpuUniformSlot getUniformSlot(String slot) {
    return _slots.putIfAbsent(
      slot,
      () => _FlutterGpuUniformSlot(raw.getUniformSlot(slot)),
    );
  }
}

class _FlutterGpuUniformSlot(final gpu.UniformSlot raw)
    implements GpuUniformSlot {
  @override
  String get name => raw.uniformName;

  @override
  late final int? sizeInBytes = raw.sizeInBytes;

  final Map<String, int?> _offsets = {};

  @override
  int? getMemberOffsetInBytes(String member) {
    return _offsets.putIfAbsent(
      member,
      () => raw.getMemberOffsetInBytes(member),
    );
  }
}

/// A pipeline handle that is created again after a device loss, from the
/// same shaders (whose libraries were loaded again in place) and layout.
class _FlutterGpuPipeline(
  final gpu.RenderPipeline Function() _create, {
  bool deferred = false,
}) implements GpuPipeline {
  this {
    if (!deferred) {
      raw;
    }
  }

  gpu.RenderPipeline? _raw;
  int _generation = -1;

  /// The pipeline of the current device.
  gpu.RenderPipeline get raw {
    final raw = _raw;
    if (raw != null && _generation == base.GpuBackend.deviceGeneration) {
      return raw;
    }
    _generation = base.GpuBackend.deviceGeneration;
    return _raw = _create();
  }
}
