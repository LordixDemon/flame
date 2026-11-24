// ignore_for_file: avoid_redundant_argument_values

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flame_3d/core.dart';
import 'package:flame_3d/src/graphics/backend/flutter_gpu/gles_driver_probe.dart';
import 'package:flame_3d/src/graphics/backend/flutter_gpu/shader_bundle_reflection.dart';
import 'package:flame_3d/src/graphics/backend/gpu_backend.dart' as base;
import 'package:flame_3d/src/graphics/backend/gpu_device.dart';
import 'package:flame_3d/src/graphics/backend/gpu_enums.dart';
import 'package:flame_3d/src/graphics/backend/gpu_handles.dart';
import 'package:flame_3d/src/graphics/backend/texture_sampler.dart';
import 'package:flame_3d/src/graphics/render_state.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding;
import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:meta/meta.dart';

part 'gpu_backend_probe.dart';
part 'gpu_backend_render_pass.dart';
part 'gpu_backend_resources.dart';
part 'gpu_backend_targets.dart';

/// A [base.GpuBackend] implemented on top of `flutter_gpu`.
///
/// Creates a backend wrapping `gpuContext`, defaulting to the global
/// `flutter_gpu` context.
base class GpuBackend({gpu.GpuContext? gpuContext}) extends base.GpuBackend {
  static Future<void> initialize() async {
    final backend = create();
    if (backend == null) {
      return;
    }
    await backend._preloadShaderLibraries();
    await backend._detectCapabilities();
  }

  static GpuBackend? create() => GpuBackend();

  /// Whether Flutter GPU can be used: it needs Impeller and the Flutter GPU
  /// flag (`--enable-flutter-gpu` or `FLTEnableFlutterGPU`).
  static bool get isAvailable {
    try {
      return gpu.gpuContext.minimumUniformByteAlignment > 0;
      // Flutter GPU reports a missing Impeller backend with a plain Exception.
      // ignore: avoid_catches_without_on_clauses
    } catch (_) {
      return false;
    }
  }

  final gpu.GpuContext _context = gpuContext ?? gpu.gpuContext;

  late final _FlutterGpuFrame _frame = _FlutterGpuFrame(this);

  @override
  late final int uniformAlignment = _context.minimumUniformByteAlignment;

  @override
  late final int maxSamplerAnisotropy = math.max(
    1,
    math.min(16, _context.maxSamplerAnisotropy),
  );

  late final gpu.PixelFormat _depthStencilFormat = () {
    final ds = _context.defaultDepthStencilFormat;
    return ds != gpu.PixelFormat.unknown ? ds : _context.defaultStencilFormat;
  }();

  @override
  bool supportsPixelFormat(GpuPixelFormat format) {
    if (format == GpuPixelFormat.depthStencil) {
      return _depthStencilFormat != gpu.PixelFormat.unknown;
    }
    final pf = _pixelFormat(format);
    if (format == GpuPixelFormat.rgbaFloat16) {
      return capabilities.halfFloatTextureTargets &&
          _context.supportsTextureFormat(pf);
    }
    if (format == GpuPixelFormat.rgbaFloat32 ||
        format == GpuPixelFormat.r32Float) {
      return capabilities.floatTextureTargets &&
          _context.supportsTextureFormat(pf);
    }
    return _context.supportsTextureFormat(pf);
  }

  /// The graphics API Flutter GPU renders with.
  ///
  /// Flutter GPU does not say: on Android, rendering into mip levels is
  /// documented as supported on Vulkan and not on OpenGL ES, which tells
  /// them apart (Windows renders with OpenGL ES through ANGLE, without
  /// rendering into mip levels); iOS and macOS apps render with Metal; the
  /// renderer of `flutter test` is not known.
  late final GpuGraphicsApi api = () {
    final renderMipmaps = _context.doesSupportFramebufferRenderMipmap;
    if (Platform.isAndroid) {
      return renderMipmaps ? GpuGraphicsApi.vulkan : GpuGraphicsApi.openGLES;
    }
    if (!renderMipmaps) {
      return GpuGraphicsApi.openGLES;
    }
    if (Platform.isIOS ||
        (Platform.isMacOS &&
            !Platform.environment.containsKey('FLUTTER_TEST'))) {
      return GpuGraphicsApi.metal;
    }
    return GpuGraphicsApi.unknown;
  }();

  GpuDeviceCapabilities? _capabilities;

  @override
  GpuDeviceCapabilities get capabilities =>
      _capabilities ??= _assumedCapabilities();

  /// What is known without asking the device: Metal and Vulkan devices
  /// render into 16/32-bit float textures (Vulkan requires it of every
  /// device), OpenGL ES devices only with extensions, assumed absent until
  /// [_detectCapabilities] checks.
  GpuDeviceCapabilities _assumedCapabilities() {
    final gles = api == GpuGraphicsApi.openGLES;
    return GpuDeviceCapabilities(
      api: api,
      floatTextureTargets: !gles,
      halfFloatTextureTargets: !gles,
      floatTargetDetection: gles ? 'none' : 'api',
      offscreenMsaa: _context.doesSupportOffscreenMSAA,
      manualMipmaps: _context.doesSupportManuallyMippedTextures,
    );
  }

  /// Asks an OpenGL ES device for its limits and extensions, and, when
  /// [base.GpuBackend.probeFloatTargets] allows it, starts checking by
  /// rendering whether it can render into float textures.
  ///
  /// Impeller's OpenGL ES backend runs submitted commands only when it
  /// renders a frame, so the float target check waits for the first frame
  /// of the app: until it completes (see [capabilitiesSettled]) float
  /// targets are assumed absent, as they are without the check.
  Future<void> _detectCapabilities() async {
    final assumed = _assumedCapabilities();
    if (api != GpuGraphicsApi.openGLES) {
      _capabilities = assumed;
      _settled.complete();
      return;
    }
    final driver = probeGlesDriver(
      shaderExtensions: {
        for (final bundle in _requirements.values)
          for (final shader in bundle.values) ...shader.extensions,
      },
    );
    GpuDeviceCapabilities detected({
      bool full = false,
      bool half = false,
      String detection = 'pending',
      Map<String, String> notes = const {},
    }) {
      return GpuDeviceCapabilities(
        api: api,
        renderer: driver?.renderer,
        vendor: driver?.vendor,
        version: driver?.version,
        shadingLanguageVersion: driver?.shadingLanguageVersion,
        extensions: driver?.extensions ?? const {},
        extensionsKnown: driver != null,
        shaderExtensions: driver?.shaderExtensions ?? const {},
        shaderExtensionsKnown: driver != null,
        maxVertexUniformVectors: driver?.maxVertexUniformVectors,
        maxFragmentUniformVectors: driver?.maxFragmentUniformVectors,
        maxVertexSamplers: driver?.maxVertexSamplers,
        maxFragmentSamplers: driver?.maxFragmentSamplers,
        maxTextureSize: driver?.maxTextureSize,
        floatTextureTargets: full,
        halfFloatTextureTargets: half,
        floatTargetDetection: detection,
        offscreenMsaa: assumed.offscreenMsaa,
        manualMipmaps: assumed.manualMipmaps,
        notes: notes,
      );
    }

    final skip = _floatProbeSkipReason(driver);
    if (skip != null) {
      _capabilities = detected(
        detection: 'none',
        notes: {'floatTargets': skip},
      );
      _settled.complete();
      return;
    }
    _capabilities = detected();
    unawaited(
      _probeFloatTargets()
          .then((result) {
            final (full, half, notes) = result;
            _capabilities = detected(
              full: full,
              half: half,
              detection: notes.containsKey('deviceCheck') ? 'probe' : 'none',
              notes: notes,
            );
          })
          .whenComplete(_settled.complete),
    );
  }

  /// Why the float targets of an OpenGL ES device are not checked by
  /// rendering, or `null` when they are.
  static String? _floatProbeSkipReason(GlesDriverInfo? driver) {
    if (!base.GpuBackend.probeFloatTargets) {
      return 'not checked: GpuBackend.probeFloatTargets is off';
    }
    if (driver == null) {
      return 'not checked: the driver could not be queried';
    }
    if (driver.renderer.contains('Android Emulator')) {
      // Rendering into a float texture there stopped the emulator's GPU.
      return 'not checked on the Android emulator';
    }
    final extensions = driver.extensions;
    if (!extensions.contains('GL_EXT_color_buffer_float') &&
        !extensions.contains('GL_EXT_color_buffer_half_float')) {
      return 'absent: the driver lists neither GL_EXT_color_buffer_float '
          'nor GL_EXT_color_buffer_half_float';
    }
    return null;
  }

  /// Renders into float textures once the app renders frames, see
  /// [_detectCapabilities].
  Future<(bool, bool, Map<String, String>)> _probeFloatTargets() async {
    try {
      await WidgetsBinding.instance.waitUntilFirstFrameRasterized;
      // Without a binding there are no frames to wait for.
      // ignore: avoid_catches_without_on_clauses
    } catch (_) {}
    final probe = _DeviceProbe.create(this);
    if (probe == null) {
      return (false, false, const <String, String>{});
    }
    final check = await probe.checkRenders();
    final half = await probe.checkFloatTexture(GpuPixelFormat.rgbaFloat16);
    final full = await probe.checkFloatTexture(GpuPixelFormat.r32Float);
    return (
      // Without a working check, a float target cannot be trusted either.
      check == null && full == null,
      check == null && half == null,
      {
        'deviceCheck': check ?? 'ok',
        'rgbaFloat16': half ?? 'ok',
        'r32Float': full ?? 'ok',
      },
    );
  }

  final Completer<void> _settled = Completer<void>();

  @override
  Future<void> get capabilitiesSettled => _settled.future;

  /// Checks by rendering, as [initialize] does on OpenGL ES, whether a
  /// texture target can render into [format] (a float format) and later
  /// passes sample it, keeping values above 1 for
  /// [GpuPixelFormat.rgbaFloat16].
  ///
  /// With [checkRange] the range check runs whatever the format (an 8-bit
  /// format then fails it), for tests.
  @visibleForTesting
  Future<bool> debugProbeFloatTarget(
    GpuPixelFormat format, {
    bool? checkRange,
  }) async {
    final probe = _DeviceProbe.create(this);
    return probe != null &&
        await probe.rendersIntoFloatTexture(format, checkRange: checkRange);
  }

  /// Sets the detected capabilities, for tests.
  @visibleForTesting
  set debugCapabilities(GpuDeviceCapabilities? capabilities) {
    _capabilities = capabilities;
  }

  // The sampler options of every distinct sampler, by key, created once per
  // backend instance so `maxSamplerAnisotropy` clamps to `_context`.
  final List<gpu.SamplerOptions?> _samplers = List<gpu.SamplerOptions?>.filled(
    TextureSampler.keyCount,
    null,
  );

  gpu.SamplerOptions _samplerFor(TextureSampler sampler) {
    return _samplers[sampler.key] ??= () {
      final aniso = sampler.maxAnisotropy.clamp(1, maxSamplerAnisotropy);
      // `flutter_gpu` requires minFilter, magFilter, and mipFilter to all be
      // linear whenever `maxAnisotropy > 1`.
      final forceLinear = aniso > 1;
      return gpu.SamplerOptions(
        minFilter: forceLinear
            ? gpu.MinMagFilter.linear
            : _filter(sampler.minFilter),
        magFilter: forceLinear
            ? gpu.MinMagFilter.linear
            : _filter(sampler.magFilter),
        mipFilter: forceLinear
            ? gpu.MipFilter.linear
            : switch (sampler.mipFilter) {
                TextureFilter.nearest => gpu.MipFilter.nearest,
                TextureFilter.linear => gpu.MipFilter.linear,
              },
        widthAddressMode: _addressMode(sampler.wrapU),
        heightAddressMode: _addressMode(sampler.wrapV),
        maxAnisotropy: aniso,
      );
    }();
  }

  static gpu.MinMagFilter _filter(TextureFilter filter) {
    return switch (filter) {
      TextureFilter.nearest => gpu.MinMagFilter.nearest,
      TextureFilter.linear => gpu.MinMagFilter.linear,
    };
  }

  static gpu.SamplerAddressMode _addressMode(TextureWrap wrap) {
    return switch (wrap) {
      TextureWrap.clamp => gpu.SamplerAddressMode.clampToEdge,
      TextureWrap.repeat => gpu.SamplerAddressMode.repeat,
      TextureWrap.mirror => gpu.SamplerAddressMode.mirror,
    };
  }

  @override
  GpuTexture createTexture({
    required GpuStorageMode storageMode,
    required int width,
    required int height,
    required GpuPixelFormat format,
    int mipLevelCount = 1,
  }) {
    final pf = _pixelFormat(format);
    final mode = _storageMode(storageMode);
    // After a device loss the texture is created again, empty: its owner
    // (a `Texture` resource) uploads its pixels again in a texture of its own.
    return _FlutterGpuTexture(
      () => _context.createTexture(
        mode,
        width,
        height,
        format: pf,
        enableRenderTargetUsage: !format.isCompressed,
        mipLevelCount: mipLevelCount,
      ),
    );
  }

  @override
  int maxMipLevelCount(int width, int height) {
    // Mip levels uploaded by hand sample as black on some OpenGL ES devices.
    if (!_supportsManualMipmaps) {
      return 1;
    }
    return gpu.Texture.fullMipCount(width, height);
  }

  late final bool _supportsManualMipmaps =
      _context.doesSupportManuallyMippedTextures;

  @override
  GpuTexture? createTextureFromImage(Image image) {
    try {
      return _FlutterGpuTexture.wrapping(
        this,
        gpu.Texture.fromImage(_context, image),
      );
      // Flutter GPU reports images without a compatible texture with a plain
      // Exception.
    } on Exception {
      return null;
    }
  }

  @override
  bool get supportsTexturesFromImages => true;

  /// A transparent texture bound instead of a texture that wraps an image of
  /// a lost device, which cannot be created again.
  gpu.Texture get _lostImageTexture {
    final generation = base.GpuBackend.deviceGeneration;
    final cached = _lostImage;
    if (cached != null && _lostImageGeneration == generation) {
      return cached;
    }
    _lostImageGeneration = generation;
    return _lostImage = _context.createTexture(
      gpu.StorageMode.hostVisible,
      1,
      1,
      format: _colorFormat,
    )..overwrite(ByteData(4));
  }

  gpu.Texture? _lostImage;
  int _lostImageGeneration = -1;

  @override
  GpuBuffer createBuffer({
    required GpuStorageMode storageMode,
    required int sizeInBytes,
  }) {
    final mode = _storageMode(storageMode);
    return _FlutterGpuBuffer(
      sizeInBytes,
      () => _context.createDeviceBuffer(mode, sizeInBytes),
      deferred: !isDeviceReady,
    );
  }

  final Map<String, _FlutterGpuShaderLibrary> _shaderLibraries = {};

  // What the shaders of each bundle need from an OpenGL ES device, read only
  // when rendering with OpenGL ES.
  final Map<String, Map<String, GpuShaderRequirements>> _requirements = {};

  // The bytes of the libraries registered at run time, to load them again
  // after a device loss.
  final Map<String, ByteData> _registeredBytes = {};

  /// Loads every `.shaderbundle` shader asset declared by the app.
  ///
  /// Bundles are discovered through [AssetManifest], so a game's own custom
  /// shaders are picked up automatically alongside flame_3d's built-ins.
  /// Loading is done up front because `flutter_gpu` can only load shader
  /// bundles asynchronously, while [loadShaderLibrary] is synchronous.
  Future<void> _preloadShaderLibraries() async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    for (final assetName in manifest.listAssets()) {
      if (assetName.endsWith('.shaderbundle')) {
        final library = await gpu.ShaderLibrary.fromAsset(assetName);
        if (library != null) {
          final bytes = await rootBundle.load(assetName);
          _shaderLibraries[assetName] = _FlutterGpuShaderLibrary(
            library,
            assetName,
            reflectShaderBundleInputs(bytes),
          );
          _readRequirements(assetName, bytes);
        }
      }
    }
  }

  void _readRequirements(String assetName, ByteData bytes) {
    if (api != GpuGraphicsApi.openGLES) {
      return;
    }
    final requirements = reflectShaderBundleGlesRequirements(bytes);
    if (requirements != null) {
      _requirements[assetName] = requirements;
    }
  }

  @override
  GpuShaderRequirements? shaderRequirements(
    String assetName,
    String entryPoint,
  ) {
    final bundle =
        _requirements[assetName] ??
        _requirements[base.GpuBackend.stripPackagePrefix(assetName)];
    return bundle?[entryPoint];
  }

  @override
  Future<void> registerShaderLibrary(String assetName, ByteData bytes) async {
    final library = await gpu.ShaderLibrary.fromBytes(bytes);
    if (library == null) {
      throw StateError('"$assetName" is not a valid shader bundle.');
    }
    _shaderLibraries[assetName] = _FlutterGpuShaderLibrary(
      library,
      assetName,
      reflectShaderBundleInputs(bytes),
    );
    _registeredBytes[assetName] = bytes;
    _readRequirements(assetName, bytes);
  }

  /// Loads every shader library again in place, keeping the identity of the
  /// libraries and shaders handed out: their pipelines are created again
  /// (see [base.GpuBackend.deviceGeneration]).
  @override
  Future<void> rebuildDeviceObjects() async {
    for (final MapEntry(key: assetName, value: library)
        in _shaderLibraries.entries) {
      final bytes = _registeredBytes[assetName];
      if (bytes != null) {
        final error = library.raw.reinitializeFromBytes(bytes);
        if (error != null) {
          throw StateError('Could not reload "$assetName": $error');
        }
      } else {
        gpu.ShaderLibrary.reinitialize(assetName);
      }
    }
  }

  /// Renders a small pass with a draw and reads it back.
  @override
  Future<bool> verifyDevice() async {
    final probe = _DeviceProbe.create(this);
    return probe != null && await probe.renders();
  }

  @override
  GpuShaderLibrary loadShaderLibrary(String assetName) {
    final library =
        _shaderLibraries[assetName] ??
        _shaderLibraries[base.GpuBackend.stripPackagePrefix(assetName)];
    if (library == null) {
      throw StateError(
        'Shader library "$assetName" has not been loaded. Make sure to '
        '`await GpuBackend.initialize()` at the start of your main, and that '
        'the asset is declared in pubspec.yaml.',
      );
    }
    return library;
  }

  @override
  GpuPipeline createPipeline({
    required GpuShader vertexShader,
    required GpuShader fragmentShader,
    GpuVertexLayout? vertexLayout,
  }) {
    final vertex = (vertexShader as _FlutterGpuShader).raw;
    final fragment = (fragmentShader as _FlutterGpuShader).raw;
    final layout = vertexLayout == null ? null : _vertexLayout(vertexLayout);
    return _FlutterGpuPipeline(
      () => _context.createRenderPipeline(
        vertex,
        fragment,
        vertexLayout: layout,
      ),
      deferred: !isDeviceReady,
    );
  }

  @override
  GpuRenderTarget createRenderTarget({
    required int width,
    required int height,
    required Color clearValue,
    int msaaSampleCount = 1,
  }) {
    // Silently ignore the request for MSAA if the device does not support it.
    final sampleCount = msaaSampleCount > 1 && _context.doesSupportOffscreenMSAA
        ? msaaSampleCount
        : 1;
    final target = _FlutterGpuRenderTarget(
      this,
      width,
      height,
      sampleCount,
      Vector4Utils.fromColor(clearValue),
    );
    if (isDeviceReady) {
      target.ensureCurrent();
    }
    return target;
  }

  @override
  void representLastImage(GpuRenderTarget target) {
    if (target is _FlutterGpuRenderTarget) {
      target.representLast();
    }
  }

  @override
  bool get supportsTextureTargets => true;

  // Flutter GPU has no query for the formats a texture can be rendered into:
  // see [capabilities], detected by rendering on OpenGL ES.
  @override
  bool get supportsFloatTextureTargets => capabilities.floatTextureTargets;

  @override
  bool supportsNativeKeepContents(GpuTextureTarget target) => false;

  @override
  bool get supportsFragDepth =>
      api != GpuGraphicsApi.openGLES || capabilities.supportsOpenGlEs3;

  @override
  GpuTextureTarget createTextureTarget({
    required int width,
    required int height,
    required GpuPixelFormat format,
    required Color clearValue,
    int msaaSampleCount = 1,
  }) {
    final sampleCount = msaaSampleCount > 1 && _context.doesSupportOffscreenMSAA
        ? msaaSampleCount
        : 1;
    final target = _FlutterGpuTextureTarget(
      this,
      width,
      height,
      format,
      sampleCount,
      Vector4Utils.fromColor(clearValue),
    );
    if (isDeviceReady) {
      target.ensureCurrent();
    }
    return target;
  }

  /// The number of frames Flutter has drawn since the backend started
  /// counting them, see [_FlutterGpuRenderTarget].
  static int get _drawnFrames {
    if (!_countingFrames) {
      try {
        // Persistent callbacks run after every frame's layout and paint, and
        // do not schedule frames.
        SchedulerBinding.instance.addPersistentFrameCallback(
          (_) => _frameCount++,
        );
        _countingFrames = true;
        // Without a binding, frames are not counted.
        // ignore: avoid_catches_without_on_clauses
      } catch (_) {}
    }
    return _frameCount;
  }

  static bool _countingFrames = false;
  static int _frameCount = 0;

  @override
  base.GpuFrame beginFrame() => _frame;

  gpu.PixelFormat _pixelFormat(GpuPixelFormat format) {
    return switch (format) {
      GpuPixelFormat.rgba8888 => gpu.PixelFormat.r8g8b8a8UNormInt,
      GpuPixelFormat.bgra8888 => gpu.PixelFormat.b8g8r8a8UNormInt,
      GpuPixelFormat.rgba8888Srgb => gpu.PixelFormat.r8g8b8a8UNormIntSRGB,
      GpuPixelFormat.bgra8888Srgb => gpu.PixelFormat.b8g8r8a8UNormIntSRGB,
      GpuPixelFormat.rgbaFloat16 => gpu.PixelFormat.r16g16b16a16Float,
      GpuPixelFormat.rgbaFloat32 => gpu.PixelFormat.r32g32b32a32Float,
      GpuPixelFormat.r32Float => gpu.PixelFormat.r32Float,
      GpuPixelFormat.depthStencil => _depthStencilFormat,
      GpuPixelFormat.bc1Rgba => gpu.PixelFormat.bc1RGBAUNormInt,
      GpuPixelFormat.bc3Rgba => gpu.PixelFormat.bc3RGBAUNormInt,
      GpuPixelFormat.bc7Rgba => gpu.PixelFormat.bc7RGBAUNormInt,
      GpuPixelFormat.etc2Rgb8 => gpu.PixelFormat.etc2RGB8UNormInt,
      GpuPixelFormat.etc2Rgba8 => gpu.PixelFormat.etc2RGBA8UNormInt,
      GpuPixelFormat.astc4x4 => gpu.PixelFormat.astc4x4LDR,
      GpuPixelFormat.astc8x8 => gpu.PixelFormat.astc8x8LDR,
      GpuPixelFormat.bc1RgbaSrgb => gpu.PixelFormat.bc1RGBAUNormIntSRGB,
      GpuPixelFormat.bc3RgbaSrgb => gpu.PixelFormat.bc3RGBAUNormIntSRGB,
      GpuPixelFormat.bc7RgbaSrgb => gpu.PixelFormat.bc7RGBAUNormIntSRGB,
      GpuPixelFormat.etc2Rgb8Srgb => gpu.PixelFormat.etc2RGB8UNormIntSRGB,
      GpuPixelFormat.etc2Rgba8Srgb => gpu.PixelFormat.etc2RGBA8UNormIntSRGB,
      GpuPixelFormat.astc4x4Srgb => gpu.PixelFormat.astc4x4LDRSRGB,
      GpuPixelFormat.astc8x8Srgb => gpu.PixelFormat.astc8x8LDRSRGB,
    };
  }

  static const _colorFormat = gpu.PixelFormat.r8g8b8a8UNormInt;

  static gpu.StorageMode _storageMode(GpuStorageMode mode) {
    return switch (mode) {
      GpuStorageMode.hostVisible => gpu.StorageMode.hostVisible,
      GpuStorageMode.devicePrivate => gpu.StorageMode.devicePrivate,
      GpuStorageMode.deviceTransient => gpu.StorageMode.deviceTransient,
    };
  }

  static gpu.VertexLayout _vertexLayout(GpuVertexLayout layout) {
    return gpu.VertexLayout(
      buffers: [
        for (final buffer in layout.buffers)
          gpu.VertexBuffer(
            strideInBytes: buffer.strideInBytes,
            stepMode: buffer.perInstance
                ? gpu.VertexStepMode.instance
                : gpu.VertexStepMode.vertex,
            attributes: [
              for (final attribute in buffer.attributes)
                gpu.VertexAttribute(
                  name: attribute.name,
                  offsetInBytes: attribute.offsetInBytes,
                  format: switch (attribute.components) {
                    1 => gpu.VertexFormat.float32,
                    2 => gpu.VertexFormat.float32x2,
                    3 => gpu.VertexFormat.float32x3,
                    4 => gpu.VertexFormat.float32x4,
                    final components => throw ArgumentError.value(
                      components,
                      'components',
                      'Vertex attribute "${attribute.name}" must have 1 to 4 '
                          'components',
                    ),
                  },
                ),
            ],
          ),
      ],
    );
  }
}
