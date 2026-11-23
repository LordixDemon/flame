// ignore_for_file: avoid_redundant_argument_values

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flame_3d/game.dart';
import 'package:flame_3d/src/graphics/backend/flutter_gpu/gles_driver_probe.dart';
import 'package:flame_3d/src/graphics/backend/flutter_gpu/shader_bundle_reflection.dart';
import 'package:flame_3d/src/graphics/backend/gpu_backend.dart' as base;
import 'package:flame_3d/src/graphics/backend/gpu_device.dart';
import 'package:flame_3d/src/graphics/backend/gpu_enums.dart';
import 'package:flame_3d/src/graphics/backend/gpu_handles.dart';
import 'package:flame_3d/src/graphics/render_state.dart';
import 'package:flame_3d/src/resources/texture/texture_sampler.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding;
import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:meta/meta.dart';

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
        _requirements[_withoutPackagePrefix(assetName)];
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
        _shaderLibraries[_withoutPackagePrefix(assetName)];
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

  /// When an app (or a package's own tests) is the root package, its assets
  /// are listed without the `packages/<name>/` prefix other packages use to
  /// refer to them.
  static String _withoutPackagePrefix(String assetName) {
    if (!assetName.startsWith('packages/')) {
      return assetName;
    }
    final packageEnd = assetName.indexOf('/', 'packages/'.length);
    return packageEnd < 0 ? assetName : assetName.substring(packageEnd + 1);
  }
}

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
