import 'dart:async';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flame_3d/src/graphics/backend/flutter_gpu/gpu_backend.dart'
    if (dart.library.js_interop) 'package:flame_3d/src/graphics/backend/web_gpu/gpu_backend.dart'
    as backend;
import 'package:flame_3d/src/graphics/backend/gpu_device.dart';
import 'package:flame_3d/src/graphics/backend/gpu_enums.dart';
import 'package:flame_3d/src/graphics/backend/gpu_handles.dart';
import 'package:flame_3d/src/graphics/render_state.dart';
import 'package:flame_3d/src/resources/texture/texture_sampler.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/widgets.dart'
    show AppLifecycleState, WidgetsBinding, WidgetsBindingObserver;
import 'package:meta/meta.dart';

/// {@template gpu_backend}
/// A rendering backend: the abstraction over a concrete low-level GPU API.
///
/// `flame_3d` talks to the GPU exclusively through this interface, so the same
/// rendering code can run on different platforms.
///
/// Exactly one backend is active at a time, reachable via [instance]. Each
/// [GpuBackend] implementation sets the [instance] at construction time through
/// it's super constructor.
/// {@endtemplate}
abstract base class GpuBackend() {
  this {
    _instance = this;
    _LifecycleWatch.ensure();
  }

  static GpuBackend? _instance;

  /// The active backend, or `null` when none was created yet.
  ///
  /// Unlike [instance], it never creates one, so it can be read where no GPU
  /// may be available (a plain `flutter test`).
  static GpuBackend? get activeOrNull => _instance;

  /// The active backend.
  ///
  /// Calls [backend.GpuBackend.create] if no instance was set. Certain backends
  /// require async initialization so you are required to call
  /// [GpuBackend.initialize] at the start of your main.dart.
  static GpuBackend get instance {
    return _instance ??=
        backend.GpuBackend.create() ??
        (throw StateError(
          'No GpuBackend has been registered. Call '
          '`await GpuBackend.initialize()` before constructing a '
          'GraphicsDevice.',
        ));
  }

  /// Initialize the [GpuBackend].
  static Future<void> initialize() => backend.GpuBackend.initialize();

  /// Whether the platform's GPU backend can be used in this process.
  ///
  /// It is `false` when Flutter GPU (on native platforms) or WebGPU (on the
  /// web) is unavailable, for example when Impeller is disabled.
  static bool get isAvailable => backend.GpuBackend.isAvailable;

  /// The alignment, in bytes, that the offset of a uniform block binding must
  /// have within a [GpuBuffer].
  int get uniformAlignment => 256;

  /// Maximum anisotropic filtering clamp supported by samplers on this device
  /// (`1` when anisotropic filtering is unsupported, up to `16` on capable
  /// GPUs).
  int get maxSamplerAnisotropy => 1;

  /// Whether this backend and GPU hardware support allocating and sampling
  /// textures in [format].
  bool supportsPixelFormat(GpuPixelFormat format) => !format.isCompressed;

  /// Creates a [GpuTexture] with [mipLevelCount] mip levels (at most
  /// [maxMipLevelCount]).
  GpuTexture createTexture({
    required GpuStorageMode storageMode,
    required int width,
    required int height,
    required GpuPixelFormat format,
    int mipLevelCount = 1,
  });

  /// The largest number of mip levels a [width]x[height] texture can have,
  /// or `1` when this backend cannot sample mip levels uploaded by hand.
  int maxMipLevelCount(int width, int height) {
    final largest = width > height ? width : height;
    return largest < 1 ? 1 : largest.bitLength;
  }

  /// A [GpuTexture] that shares the GPU memory of [image] without copying it,
  /// or `null` when this backend cannot wrap it.
  ///
  /// On a backend that [supportsTexturesFromImages], `null` means the image
  /// has no GPU texture yet: an image from `Picture.toImageSync` is
  /// rasterized later, on devices; one from `Picture.toImage` has one.
  GpuTexture? createTextureFromImage(Image image) => null;

  /// Whether [createTextureFromImage] can wrap images (Flutter GPU) or never
  /// does (WebGPU).
  bool get supportsTexturesFromImages => false;

  /// Creates a [GpuBuffer] of [sizeInBytes] bytes.
  ///
  /// The buffer can be bound as vertex, index and uniform data.
  GpuBuffer createBuffer({
    required GpuStorageMode storageMode,
    required int sizeInBytes,
  });

  /// Loads a [GpuShaderLibrary] from the asset at [assetName].
  GpuShaderLibrary loadShaderLibrary(String assetName);

  /// Registers the shader library [bytes] (the contents of a shader bundle
  /// asset in this backend's format) under [assetName], so that
  /// [loadShaderLibrary] can return it.
  ///
  /// This allows shaders that are not declared as assets, for example ones
  /// downloaded or compiled at run time.
  Future<void> registerShaderLibrary(String assetName, ByteData bytes) {
    throw UnsupportedError(
      '$runtimeType cannot register shader libraries at run time.',
    );
  }

  /// Links [vertexShader] and [fragmentShader] into a [GpuPipeline] that reads
  /// its vertex inputs as described by [vertexLayout].
  ///
  /// When [vertexLayout] is `null` the backend's default layout for the
  /// vertex shader is used.
  GpuPipeline createPipeline({
    required GpuShader vertexShader,
    required GpuShader fragmentShader,
    GpuVertexLayout? vertexLayout,
  });

  /// Creates a [GpuRenderTarget] of [width]x[height], cleared to [clearValue]
  /// at the start of each pass.
  GpuRenderTarget createRenderTarget({
    required int width,
    required int height,
    required Color clearValue,
    int msaaSampleCount = 1,
  });

  /// Records that the image the last pass into [target] returned is drawn
  /// again in the current frame, so that [target] does not render into its
  /// color texture while Flutter may still be drawing it (for the next two
  /// frames, as after the pass itself).
  ///
  /// A caller that keeps an image and draws it on later frames without
  /// rendering again calls this on each of them. Backends whose images do
  /// not share the memory of the render target ignore it.
  void representLastImage(GpuRenderTarget target) {}

  /// Whether this backend can create [GpuTextureTarget]s, see
  /// [createTextureTarget].
  bool get supportsTextureTargets => false;

  /// Whether a [GpuTextureTarget] can render into a
  /// [GpuPixelFormat.r32Float] or [GpuPixelFormat.rgbaFloat16] texture. When it
  /// cannot, a depth stored in a texture is packed into the 8-bit channels of a
  /// [GpuPixelFormat.rgba8888] texture instead.
  bool get supportsFloatTextureTargets => false;

  /// Whether [beginFrame]'s `beginRenderPass(target, keepContents: true)` can
  /// natively preserve [target]'s color pixels without an external copy pass.
  bool supportsNativeKeepContents(GpuTextureTarget target) => false;

  /// Creates a [GpuTextureTarget] of [width]x[height] whose passes render
  /// into a texture of [format] that later passes sample, cleared to
  /// [clearValue] (and its depth to the far plane) at the start of each pass.
  ///
  /// With a [msaaSampleCount] above 1, passes render with that many samples
  /// per pixel into a transient multisampled texture, resolved into the
  /// sampled texture at the end of each pass. A backend without multisampled
  /// texture targets (WebGPU here, OpenGL ES devices without offscreen MSAA)
  /// uses one sample.
  ///
  /// Throws an [UnsupportedError] when [supportsTextureTargets] is `false`.
  GpuTextureTarget createTextureTarget({
    required int width,
    required int height,
    required GpuPixelFormat format,
    required Color clearValue,
    int msaaSampleCount = 1,
  }) {
    throw UnsupportedError('$runtimeType cannot render into textures.');
  }

  /// Begins a new frame.
  GpuFrame beginFrame();

  /// What this backend's GPU device offers, as far as it was detected.
  ///
  /// [initialize] detects it: before, and on backends that detect nothing,
  /// it is [GpuDeviceCapabilities.unknown] or what the backend knows without
  /// asking the device.
  GpuDeviceCapabilities get capabilities => GpuDeviceCapabilities.unknown;

  /// Completes once [capabilities] are final: checks that need the app to
  /// render frames (the float targets on OpenGL ES) finish after
  /// [initialize] returned.
  Future<void> get capabilitiesSettled => Future.value();

  /// Whether [initialize] checks by rendering, on OpenGL ES, whether the
  /// device renders into float textures (16-bit for HDR, 32-bit for shadow
  /// maps). `false` by default: float targets are then not used on OpenGL
  /// ES. Set it before [initialize].
  ///
  /// The check runs once the app renders its first frame, only when the
  /// driver lists `GL_EXT_color_buffer_half_float` or
  /// `GL_EXT_color_buffer_float`, and never on the Android emulator, whose
  /// GPU it stopped (the driver lists both extensions there). See
  /// [capabilities] and [capabilitiesSettled].
  static bool probeFloatTargets = false;

  /// What the shader [entryPoint] of the shader bundle [assetName] needs
  /// from the device, or `null` when this backend does not read it.
  ///
  /// The Flutter GPU backend reads it from the bundle's OpenGL ES build when
  /// it renders with OpenGL ES; other backends and APIs return `null`.
  GpuShaderRequirements? shaderRequirements(
    String assetName,
    String entryPoint,
  ) => null;

  /// Whether the shader [entryPoint] of the shader bundle [assetName] can
  /// run on this device, or `null` when that is not known (and the shader is
  /// assumed to run).
  ///
  /// It compares [shaderRequirements] with [capabilities]: the extensions
  /// the shader requires, its uniform vectors and its textures per stage.
  GpuShaderSupport? shaderSupport(String assetName, String entryPoint) {
    final requirements = shaderRequirements(assetName, entryPoint);
    if (requirements == null) {
      return null;
    }
    final caps = capabilities;
    final vertex = requirements.stage == GpuShaderStage.vertex;
    return GpuShaderSupport(
      requirements: requirements,
      missingExtensions: caps.shaderExtensionsKnown
          ? [
              for (final extension in requirements.extensions)
                if (!caps.shaderExtensions.contains(extension)) extension,
            ]
          : const [],
      uniformVectorLimit: vertex
          ? caps.maxVertexUniformVectors
          : caps.maxFragmentUniformVectors,
      samplerLimit: vertex ? caps.maxVertexSamplers : caps.maxFragmentSamplers,
    );
  }

  // ---------------------------------------------------------------------
  // Device loss.

  static int _deviceGeneration = 0;
  static int _renderEpoch = 0;
  static final List<GpuDeviceListener> _deviceListeners = [];

  /// Incremented every time the backend starts to rebuild its GPU objects
  /// after a device loss.
  ///
  /// Every GPU handle created before (buffers, textures, render targets,
  /// pipelines of this backend, and the `Resource`s of flame_3d) is created
  /// again before its next use, so nothing draws with a handle of the lost
  /// device.
  static int get deviceGeneration => _deviceGeneration;

  /// Incremented when the device is lost and again when it renders again.
  ///
  /// The versions of every `World3D` add it, so retained layers and cached
  /// shadow maps render again after a recovery instead of keeping what was
  /// (not) rendered while the device was lost.
  static int get renderEpoch => _renderEpoch;

  /// Registers [listener] for the losses and recoveries of the device.
  static void addDeviceListener(GpuDeviceListener listener) {
    _deviceListeners.add(listener);
  }

  /// Unregisters [listener], returning whether it was registered.
  static bool removeDeviceListener(GpuDeviceListener listener) {
    return _deviceListeners.remove(listener);
  }

  /// Whether a resumed app checks that the device still renders (with
  /// [checkDevice]) and recovers it when it does not. `true` by default.
  ///
  /// The check renders a 4 by 4 pixel pass and reads it back, once per
  /// return to the foreground.
  static bool checkDeviceOnResume = true;

  GpuDeviceState _deviceState = GpuDeviceState.ready;
  Object? _lastDeviceLossReason;
  int _deviceLossCount = 0;
  int _recoveryCount = 0;
  Future<bool>? _recovery;
  int _failedRecoveries = 0;
  Timer? _retry;

  /// The delays after which a failed recovery is tried again by itself.
  static const List<Duration> _retryDelays = [
    Duration(milliseconds: 500),
    Duration(seconds: 1),
    Duration(seconds: 2),
  ];

  /// The state of the device: [GpuDeviceState.ready] while it renders.
  GpuDeviceState get deviceState => _deviceState;

  /// Whether the device renders. While it does not, `GraphicsDevice`
  /// records nothing and its passes return a transparent image.
  bool get isDeviceReady => _deviceState == GpuDeviceState.ready;

  /// The reason given for the last device loss, or `null` if there was none.
  Object? get lastDeviceLossReason => _lastDeviceLossReason;

  /// The number of device losses reported since the backend was created.
  int get deviceLossCount => _deviceLossCount;

  /// The number of successful recoveries since the backend was created.
  int get deviceRecoveryCount => _recoveryCount;

  /// Reports that the device was lost, for [reason].
  ///
  /// The backend calls it when a command buffer fails on the GPU, when
  /// submitting one throws, and when [checkDevice] fails; an app that knows
  /// better may call it too. Drawing stops at once (see [isDeviceReady]),
  /// the listeners' `onLost` is called, and [recoverDevice] runs right after
  /// the current task. A report while a loss is already being handled is
  /// ignored.
  void reportDeviceLost(Object reason) {
    if (_deviceState == GpuDeviceState.lost ||
        _deviceState == GpuDeviceState.recovering) {
      return;
    }
    _deviceState = GpuDeviceState.lost;
    _lastDeviceLossReason = reason;
    _deviceLossCount++;
    _renderEpoch++;
    debugPrint('flame_3d: GPU device lost ($reason), recovering.');
    for (final listener in List.of(_deviceListeners)) {
      listener.onLost?.call(reason);
    }
    // Not within the frame or callback that found the loss.
    Timer.run(() {
      if (_deviceState == GpuDeviceState.lost) {
        unawaited(recoverDevice());
      }
    });
  }

  /// Rebuilds what the backend owns after a device loss and checks that the
  /// device renders, returning whether it does.
  ///
  /// It increments [deviceGeneration] (every handle is created again before
  /// its next use), lets the backend rebuild its own objects (the Flutter GPU
  /// backend reloads its shader bundles) and runs the same check as
  /// [checkDevice]. On success the device is [GpuDeviceState.ready] again and
  /// the listeners' `onRecovered` is called; otherwise it is
  /// [GpuDeviceState.failed], `onRecoveryFailed` is called, and recovery is
  /// tried again by itself after 0.5, 1 and 2 seconds, then at the next
  /// resume of the app (or call). Calls while a recovery runs share it; a
  /// call while the device is ready returns `true`.
  Future<bool> recoverDevice() {
    if (_deviceState == GpuDeviceState.ready) {
      return Future.value(true);
    }
    return _recovery ??= _recover().whenComplete(() => _recovery = null);
  }

  Future<bool> _recover() async {
    _deviceState = GpuDeviceState.recovering;
    _deviceGeneration++;
    try {
      await rebuildDeviceObjects();
      if (!await verifyDevice()) {
        throw StateError('The GPU device does not render after recovery.');
      }
    } on Object catch (error) {
      _deviceState = GpuDeviceState.failed;
      debugPrint('flame_3d: GPU device recovery failed: $error');
      for (final listener in List.of(_deviceListeners)) {
        listener.onRecoveryFailed?.call(error);
      }
      if (_failedRecoveries < _retryDelays.length) {
        _retry?.cancel();
        _retry = Timer(_retryDelays[_failedRecoveries++], () {
          if (_deviceState == GpuDeviceState.failed) {
            unawaited(recoverDevice());
          }
        });
      }
      return false;
    }
    _deviceState = GpuDeviceState.ready;
    _failedRecoveries = 0;
    _retry?.cancel();
    _recoveryCount++;
    _renderEpoch++;
    debugPrint('flame_3d: GPU device recovered.');
    for (final listener in List.of(_deviceListeners)) {
      listener.onRecovered?.call(_deviceGeneration);
    }
    return true;
  }

  /// Checks that the device still renders: renders a small pass and reads it
  /// back. When it does not, the device is reported lost (see
  /// [reportDeviceLost]). Returns whether it renders; `false` without a
  /// check while the device is not ready.
  Future<bool> checkDevice() async {
    if (_deviceState != GpuDeviceState.ready) {
      if (_deviceState == GpuDeviceState.failed) {
        return await recoverDevice();
      }
      return false;
    }
    Object? error;
    var ok = false;
    try {
      ok = await verifyDevice();
    } on Object catch (e) {
      error = e;
    }
    if (!ok) {
      reportDeviceLost(error ?? 'the device check rendered a wrong picture');
    }
    return ok;
  }

  /// Rebuilds what only the backend can rebuild after a device loss, such as
  /// its shader libraries. Called by [recoverDevice].
  @protected
  Future<void> rebuildDeviceObjects() async {}

  /// Renders on the device and reads the result back, returning whether it
  /// is right. Called by [checkDevice] and [recoverDevice]; `true` on
  /// backends that cannot check.
  @protected
  Future<bool> verifyDevice() async => true;

  /// Simulates a device loss: reports it and waits for the recovery,
  /// returning whether it succeeded.
  ///
  /// Every handle is created again, as after a real loss, though the old
  /// ones still work: tests use it to check that rendering comes back.
  @visibleForTesting
  Future<bool> debugSimulateDeviceLoss() async {
    reportDeviceLost('simulated device loss');
    return await recoverDevice();
  }

  /// Forgets the device-loss state shared by all backends (generation,
  /// listeners, resume checks), for tests.
  @visibleForTesting
  static void debugResetDeviceState() {
    _deviceListeners.clear();
    checkDeviceOnResume = true;
    _instance?._retry?.cancel();
  }
}

/// Checks the device when the app returns to the foreground, see
/// [GpuBackend.checkDeviceOnResume].
class _LifecycleWatch() with WidgetsBindingObserver {
  static _LifecycleWatch? _watch;

  bool _wasAway = false;

  static void ensure() {
    if (_watch != null) {
      return;
    }
    try {
      final watch = _LifecycleWatch();
      WidgetsBinding.instance.addObserver(watch);
      _watch = watch;
      // Without a binding (pure Dart tests) nothing is watched.
      // ignore: avoid_catches_without_on_clauses
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _wasAway = true;
      case AppLifecycleState.resumed:
        if (_wasAway && GpuBackend.checkDeviceOnResume) {
          final backend = GpuBackend._instance;
          if (backend != null) {
            unawaited(backend.checkDevice());
          }
        }
        _wasAway = false;
      case AppLifecycleState.inactive:
        break;
    }
  }
}

/// A single frame of rendering.
///
/// Obtain one via [GpuBackend.beginFrame] and finalize it with [end].
abstract interface class GpuFrame() {
  /// Begins a render pass that draws into [target].
  ///
  /// When [keepContents] is `true` and the backend supports native preservation
  /// (`supportsNativeKeepContents(target)`), existing color contents of
  /// [target] are loaded instead of cleared; the depth buffer is still
  /// cleared to `1.0`.
  ///
  /// Every pass starts with the default render state: no blending, depth test
  /// with [CompareFunction.less], depth writes on, no culling and
  /// [WindingOrder.counterClockwise] front faces.
  GpuRenderPass beginRenderPass(
    GpuRenderTarget target, {
    bool keepContents = false,
  });

  /// Finalizes the frame.
  void end();
}

/// Records the bind, state and draw commands of a single render pass.
///
/// Bindings persist from one draw to the next until [clearBindings] is called
/// or a different pipeline is bound with [bindPipeline], so unchanged resources
/// need not be bound again.
///
/// Obtain one via [GpuFrame.beginRenderPass] and submit it with [submit].
abstract interface class GpuRenderPass() {
  /// Binds the render [pipeline].
  ///
  /// Callers must call [clearBindings] before binding a pipeline whose shaders
  /// differ from the current one, and bind its resources again.
  void bindPipeline(GpuPipeline pipeline);

  /// Sets how the color output of the following draws is blended.
  void setBlendState(BlendState blend);

  /// Sets the depth test of the following draws: [compare] is
  /// [CompareFunction.always] to disable the test.
  void setDepthState({
    required CompareFunction compare,
    required bool writeEnabled,
  });

  /// Sets which faces the following draws cull.
  void setCullMode(CullMode cullMode);

  /// Sets which winding order is front-facing for the following draws.
  void setWindingOrder(WindingOrder windingOrder);

  /// Sets the viewport rectangle and normalized depth range `[zNear, zFar]`
  /// inside the active render target.
  void setViewport(
    int x,
    int y,
    int width,
    int height, {
    double zNear = 0.0,
    double zFar = 1.0,
  });

  /// Sets the pixel scissor clip rectangle inside the active render target.
  void setScissor(int x, int y, int width, int height);

  /// Configures stencil testing and stencil buffer updates (`null` disables
  /// stencil test and writes).
  void setStencil(StencilState? stencil);

  /// Sets polygon fill or wireframe rasterization mode.
  void setPolygonMode(PolygonFillMode mode);

  /// Sets primitive assembly topology for subsequent draws.
  void setPrimitiveTopology(PrimitiveTopology topology);

  /// Binds [lengthInBytes] bytes of [buffer] starting at [offsetInBytes] to
  /// the vertex buffer [slot].
  void bindVertexBuffer(
    GpuBuffer buffer, {
    required int offsetInBytes,
    required int lengthInBytes,
    int slot = 0,
  });

  /// Binds [lengthInBytes] bytes of [buffer] starting at [offsetInBytes] as
  /// the index buffer, holding indices of [indexType].
  void bindIndexBuffer(
    GpuBuffer buffer, {
    required int offsetInBytes,
    required int lengthInBytes,
    required GpuIndexType indexType,
  });

  /// Binds [lengthInBytes] bytes of [buffer] starting at [offsetInBytes] to
  /// the uniform block [slot].
  ///
  /// [offsetInBytes] must be a multiple of [GpuBackend.uniformAlignment].
  void bindUniform(
    GpuUniformSlot slot,
    GpuBuffer buffer, {
    required int offsetInBytes,
    required int lengthInBytes,
  });

  /// Binds [texture] to the sampler [slot], sampled as [sampler] says.
  ///
  /// Backends create one sampler object per distinct [sampler] value (see
  /// [TextureSampler.key]) and reuse it.
  void bindTexture(
    GpuUniformSlot slot,
    GpuTexture texture, {
    TextureSampler sampler = TextureSampler.nearest,
  });

  /// Clears all resources bound to this pass.
  void clearBindings();

  /// Draws [vertexCount] vertices of the bound vertex buffers, [instanceCount]
  /// times.
  void draw(int vertexCount, {int instanceCount = 1});

  /// Draws [indexCount] indices of the bound index buffer, [instanceCount]
  /// times.
  void drawIndexed(int indexCount, {int instanceCount = 1});

  /// Finalizes the pass, submits its commands to the GPU and returns the
  /// rendered color as an [Image].
  ///
  /// [onCompleted] is called once the GPU no longer reads any buffer bound
  /// during the pass, after which their contents may be overwritten.
  ///
  /// Passes into a [GpuTextureTarget] end with [commit] instead.
  Image submit({void Function()? onCompleted});

  /// Finalizes the pass and submits its commands to the GPU without
  /// returning an image, as passes into a [GpuTextureTarget] end.
  ///
  /// [onCompleted] is called as for [submit].
  void commit({void Function()? onCompleted});
}
