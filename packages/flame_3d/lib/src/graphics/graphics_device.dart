import 'dart:typed_data';
import 'dart:ui';

import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/src/graphics/bloom_pass.dart';
import 'package:meta/meta.dart';

/// {@template graphics_device}
/// The [GraphicsDevice] provides a way for developers to interact with the GPU
/// by binding different resources to it.
///
/// A frame starts with [begin] and ends with [end]. Within a frame, one or more
/// render passes can be created with [beginPass]/[endPass], each producing an
/// [Image].
///
/// The device remembers what is bound: binding the pipeline, render state,
/// surface or uniform data that is already bound costs nothing, so callers can
/// bind everything a draw needs without tracking it themselves.
///
/// Uniform and instance data is staged in CPU memory and uploaded to GPU
/// buffers once per render pass. Those buffers are recycled once the GPU has
/// finished the frames that read them.
///
/// While the GPU device is lost or recovering (see
/// [GpuBackend.isDeviceReady]), passes record nothing: binds and draws are
/// ignored, no resource is uploaded and [endPass] returns a transparent
/// image, so nothing draws with a handle of the lost device.
/// {@endtemplate}
class GraphicsDevice({
  /// The clear value, used to clear out the screen.
  final Color clearValue = const Color(0x00000000),
  GpuBackend? backend,
}) {
  /// The GPU backend this device records its rendering commands through.
  final GpuBackend backend = backend ?? GpuBackend.instance;

  /// The counters of the frame being recorded.
  ///
  /// They are reset by [begin]; read [lastFrameStats] for a complete frame.
  final RenderStats stats = RenderStats();

  /// The counters of the last frame that ended.
  final RenderStats lastFrameStats = RenderStats();

  /// A number identifying the current frame, incremented by every [begin].
  int get frame => _frame;
  int _frame = 0;

  GpuFrame? _gpuFrame;
  GpuRenderPass? _renderPass;
  late GpuRenderTarget _renderTarget;

  /// The render target of the current (or last) render pass.
  GpuRenderTarget get renderTarget => _renderTarget;

  late final _TransientArena _arena = _TransientArena(backend);

  // Render target pool: keyed by (width, height, MSAA sample count), each
  // bucket holds targets and its usage counters for this frame.
  final _pool = <(int, int, int), _PoolBucket>{};
  final List<(int, int, int)> _evictPoolKeys = [];

  /// The number of frames a render target size that is no longer used stays
  /// pooled, so that a scene whose size changes back and forth, or that skips
  /// a few frames, keeps its targets instead of creating new ones.
  static const int targetRetainFrames = 30;

  // Pipelines, keyed by vertex shader, fragment shader and surface layout.
  final _pipelines = <(GpuShader, GpuShader, VertexLayout), DevicePipeline>{};

  // What is currently bound to the render pass.
  GpuPipeline? _pipeline;
  Surface? _surface;
  int _bindingEpoch = 0;
  BlendState _blend = BlendState.opaque;
  CompareFunction _depthCompare = CompareFunction.less;
  bool _depthWrite = true;
  CullMode _cullMode = CullMode.none;
  WindingOrder _frontFace = WindingOrder.counterClockwise;
  StencilState? _stencil;
  PolygonFillMode _polygonMode = PolygonFillMode.fill;
  PrimitiveTopology _topology = PrimitiveTopology.triangles;

  // Per-pass/pipeline descriptor deduplication (reset in `_startPass`,
  // `clearBindings`, and when switching pipelines).
  final List<GpuUniformSlot?> _boundUniformSlots = List.filled(
    16,
    null,
    growable: true,
  );
  final List<GpuBuffer?> _boundUniformBuffers = List.filled(
    16,
    null,
    growable: true,
  );
  Int32List _boundUniformOffsets = Int32List(16);
  Int32List _boundUniformLengths = Int32List(16);
  int _boundUniformCount = 0;

  final List<GpuUniformSlot?> _boundTexSlots = List.filled(
    16,
    null,
    growable: true,
  );
  final List<GpuTexture?> _boundTexHandles = List.filled(
    16,
    null,
    growable: true,
  );
  Int32List _boundTexSamplerKeys = Int32List(16);
  int _boundTexCount = 0;

  bool _hasViewport = false;
  int _vpX = 0;
  int _vpY = 0;
  int _vpW = 0;
  int _vpH = 0;
  double _vpZNear = 0.0;
  double _vpZFar = 1.0;

  bool _hasScissor = false;
  int _scX = 0;
  int _scY = 0;
  int _scW = 0;
  int _scH = 0;

  /// Incremented whenever the pass's bindings are cleared (by [clearBindings]
  /// or by binding a different pipeline), after which every resource of the
  /// next draw must be bound again.
  int get bindingEpoch => _bindingEpoch;

  /// The winding order of front faces for the following draws.
  WindingOrder get frontFace => _frontFace;

  /// Whether a render pass is being recorded.
  bool get isInPass => _renderPass != null;

  /// Whether the current pass records nothing because the GPU device is not
  /// ready (see [GpuBackend.isDeviceReady]).
  bool get isSuspended => _suspended;
  bool _suspended = false;

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

  /// Begin a new frame.
  ///
  /// Starts the frame whose transient storage is shared across all render
  /// passes. Call [end] when the frame is complete.
  void begin() {
    _frame++;
    stats.reset();
    for (final bucket in _pool.values) {
      bucket.used = 0;
    }
    _gpuFrame = backend.beginFrame();
  }

  /// End the frame.
  void end() {
    _gpuFrame?.end();
    _gpuFrame = null;
    _arena.endFrame();
    lastFrameStats.setFrom(stats);

    // Release the targets of sizes unused for a while, and the targets of a
    // size beyond how many were used in this frame.
    if (_pool.isNotEmpty) {
      _evictPoolKeys.clear();
      for (final entry in _pool.entries) {
        final bucket = entry.value;
        final used = bucket.used;
        if (used == 0) {
          if (_frame - bucket.lastUsedFrame >= targetRetainFrames) {
            _evictPoolKeys.add(entry.key);
          }
        } else {
          bucket.lastUsedFrame = _frame;
          final targets = bucket.targets;
          if (used < targets.length) {
            targets.removeRange(used, targets.length);
          }
        }
      }
      for (var i = 0; i < _evictPoolKeys.length; i++) {
        _pool.remove(_evictPoolKeys[i]);
      }
    }
    if (_textureTargets.isNotEmpty) {
      _evictTextureKeys.clear();
      for (final entry in _textureTargets.entries) {
        if (_frame - entry.value.lastUsedFrame >= targetRetainFrames) {
          _evictTextureKeys.add(entry.key);
        }
      }
      for (var i = 0; i < _evictTextureKeys.length; i++) {
        _textureTargets.remove(_evictTextureKeys[i]);
      }
    }
  }

  /// Begin a render pass at the given [size], in physical pixels.
  void beginPass(
    Size size, {
    int msaaSampleCount = 1,
    WindingOrder frontFace = WindingOrder.counterClockwise,
  }) {
    final frame = _gpuFrame;
    if (frame == null) {
      throw StateError('beginPass must be called between begin and end');
    }
    RenderProfile.lap(RenderPhase.setup);
    _renderTarget = _acquireRenderTarget(size, msaaSampleCount);
    _startPass(_beginGpuPass(frame, _renderTarget), frontFace);
    RenderProfile.lap(RenderPhase.passBegin);
  }

  /// Begins a render pass into a caller-owned [target] (created with
  /// [GpuBackend.createRenderTarget]) instead of the shared rotating pool.
  void beginOwnedPass(
    GpuRenderTarget target, {
    WindingOrder frontFace = WindingOrder.counterClockwise,
  }) {
    final frame = _gpuFrame;
    if (frame == null) {
      throw StateError('beginOwnedPass must be called between begin and end');
    }
    RenderProfile.lap(RenderPhase.setup);
    _renderTarget = target;
    _startPass(_beginGpuPass(frame, target), frontFace);
    RenderProfile.lap(RenderPhase.passBegin);
  }

  late final BloomPass _bloom = BloomPass(this);

  /// Applies GPU [BloomSettings] (and optional [PostProcessSettings]) to
  /// [sceneTarget] inside the active frame and returns the composited [Image].
  ///
  /// [visibleFrame] is the part of the target that is seen, in its pixels
  /// (it may reach outside the target): the vignette of [postProcess] is
  /// centered on it. It is the whole target when `null`.
  Image applyBloomFromTarget(
    GpuTextureTarget sceneTarget,
    BloomSettings? settings, {
    PostProcessSettings? postProcess,
    Texture? depthNormalTexture,
    GpuRenderTarget? outputTarget,
    bool hdrEnabled = false,
    RenderDebugMode3D renderDebugMode = RenderDebugMode3D.none,
    Rect? visibleFrame,
  }) {
    return _bloom.applyFromTarget(
      sceneTarget,
      settings,
      postProcess: postProcess,
      depthNormalTexture: depthNormalTexture,
      outputTarget: outputTarget,
      hdrEnabled: hdrEnabled,
      debugMode: renderDebugMode,
      visibleFrame: visibleFrame,
    );
  }

  /// Number of compiled [DevicePipeline] instances cached on this device.
  int get cachedPipelineCount => _pipelines.length;

  /// Estimated GPU render-target memory (color + depth attachments, in bytes)
  /// currently pooled by this device.
  int get estimatedTargetVramBytes {
    var total = 0;
    for (final entry in _pool.entries) {
      final (w, h, samples) = entry.key;
      // Triple-buffered color + depth-stencil estimate.
      final perTarget = w * h * 4 * (3 + samples);
      total += perTarget * entry.value.targets.length;
    }
    for (final entry in _textureTargets.values) {
      total += entry.estimatedBytes;
    }
    return total;
  }

  /// Pre-compiles and caches the GPU [DevicePipeline] for [material] and
  /// [layout] (`VertexLayout.standard` by default) so its first draw in
  /// gameplay incurs zero shader-compilation stutter.
  DevicePipeline warmupMaterial(
    Material material, {
    VertexLayout? layout,
  }) {
    final resolvedLayout = layout ?? VertexLayout.standard;
    final vert = material.vertexShaderFor(resolvedLayout);
    return pipelineFor(vert, material.fragmentShader, resolvedLayout);
  }

  void _clearPassBindings() {
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

  /// Submit the render pass to the GPU and return the rendered [Image].
  ///
  /// While the device is not ready, the image is transparent.
  Image endPass() {
    final renderPass = _pass;
    if (_suspended) {
      _renderPass = null;
      _suspended = false;
      return _SuspendedRenderPass.blankImage();
    }
    RenderProfile.lap(RenderPhase.release);
    _arena.flush();
    RenderProfile.lap(RenderPhase.upload);
    _renderPass = null;
    final image = renderPass.submit(onCompleted: _arena.passCompletion());
    RenderProfile.lap(RenderPhase.passEnd);
    return image;
  }

  /// The render target of [width]x[height] pixels that renders into a
  /// texture of [format] for later passes to sample, cleared to [clearValue]
  /// at the start of each pass.
  ///
  /// Every call with the same size, format, clear value and [role] returns
  /// the same target, created on first use and released
  /// [targetRetainFrames] frames after its last use. Give targets that are
  /// used in the same frame for different purposes different [role]s (any
  /// object with value equality, such as an enum value or a string), so that
  /// a pass never samples the texture it renders into.
  ///
  /// With a [msaaSampleCount] above 1 its passes render with that many
  /// samples per pixel, resolved into the texture later passes sample (see
  /// [GpuBackend.createTextureTarget]).
  GpuTextureTarget textureTarget(
    int width,
    int height,
    GpuPixelFormat format, {
    Color clearValue = const Color(0xFFFFFFFF),
    Object? role,
    int msaaSampleCount = 1,
  }) {
    final key = (width, height, format, clearValue, role, msaaSampleCount);
    var entry = _textureTargets[key];
    if (entry == null) {
      final target = backend.createTextureTarget(
        width: width,
        height: height,
        format: format,
        clearValue: clearValue,
        msaaSampleCount: msaaSampleCount,
      );
      final estimatedBytes =
          width *
          height *
          (format.bytesPerBlock *
                  (msaaSampleCount > 1 ? 1 + msaaSampleCount : 1) +
              4 * msaaSampleCount);
      entry = _textureTargets[key] = _TextureTargetEntry(
        target,
        _frame,
        estimatedBytes,
      );
    } else {
      entry.lastUsedFrame = _frame;
    }
    return entry.target;
  }

  final _textureTargets =
      <(int, int, GpuPixelFormat, Color, Object?, int), _TextureTargetEntry>{};
  final List<(int, int, GpuPixelFormat, Color, Object?, int)>
  _evictTextureKeys = [];

  /// Marks [target] as used in the current frame so [targetRetainFrames] does
  /// not evict a cached texture target (such as a static shadow map).
  @internal
  void touchTextureTarget(GpuTextureTarget target) {
    for (final entry in _textureTargets.values) {
      if (identical(entry.target, target)) {
        entry.lastUsedFrame = _frame;
        return;
      }
    }
  }

  /// Begin a render pass into [target], whose texture later passes sample.
  ///
  /// The pass clears the target's color, or, when [keepContents] is `true`,
  /// starts from the color it holds, to draw over a picture an earlier pass
  /// rendered (the scene, in an `afterScene` custom pass). The depth buffer
  /// is cleared either way.
  ///
  /// Keeping the contents costs two full-size copy passes and a scratch
  /// target of the same size and format: render passes cannot load what a
  /// texture target holds on every backend (Flutter GPU starts a pass that
  /// should load its target from undefined contents), so the picture is
  /// copied out and back in at the start of the pass.
  void beginTexturePass(
    GpuTextureTarget target, {
    WindingOrder frontFace = WindingOrder.counterClockwise,
    bool keepContents = false,
  }) {
    final frame = _gpuFrame;
    if (frame == null) {
      throw StateError('beginTexturePass must be called between begin and end');
    }
    if (keepContents && backend.supportsNativeKeepContents(target)) {
      _renderTarget = target;
      _startPass(_beginGpuPass(frame, target, keepContents: true), frontFace);
      return;
    }
    if (keepContents && backend.isDeviceReady) {
      final scratch = textureTarget(
        target.width,
        target.height,
        target.format,
        role: _scratchRole,
      );
      _renderTarget = scratch;
      _startPass(_beginGpuPass(frame, scratch), WindingOrder.counterClockwise);
      _copyTexture(0, target);
      endTexturePass();
      _renderTarget = target;
      _startPass(_beginGpuPass(frame, target), WindingOrder.counterClockwise);
      _copyTexture(1, scratch);
      setFrontFace(frontFace);
      return;
    }
    _renderTarget = target;
    _startPass(_beginGpuPass(frame, target), frontFace);
  }

  static const Object _scratchRole = #flame3dKeepContents;
  static const String _copyBundle =
      'packages/flame_3d/assets/shaders/texture_copy.shaderbundle';
  late final Shader _copyVertex = VertexShader.fromAsset(_copyBundle);
  late final Shader _copyFragment = FragmentShader.fromAsset(
    _copyBundle,
    slots: const ['sourceTexture'],
  );
  static final Surface _copyQuad = Surface.fromBuffers(
    vertices: Float32List.fromList(const [
      -1.0, -1.0, 0.0, //
      1.0, -1.0, 0.0, //
      1.0, 1.0, 0.0, //
      -1.0, 1.0, 0.0, //
    ]),
    indices: Uint16List.fromList(const [0, 1, 2, 0, 2, 3]),
    layout: VertexLayout(const [
      VertexAttribute(VertexLayout.positionAttribute, 3),
    ]),
  );
  static const RenderState _copyState = RenderState(
    depthTest: false,
    depthWrite: false,
  );
  final List<GpuTextureTarget?> _copySources = List.filled(2, null);
  final List<Texture> _copyTextures = List.filled(2, Texture.standard);

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

  /// Draws [texture] over the viewport of the open pass, without testing or
  /// writing depth: texel for texel when it has the size of the viewport and
  /// is sampled with the nearest texel. One draw call of two triangles.
  @internal
  void drawTextureCopy(Texture texture) {
    _copyFragment.setTexture('sourceTexture', texture);
    bindPipeline(pipelineFor(_copyVertex, _copyFragment, _copyQuad.layout));
    setRenderState(_copyState);
    bindTexture(_copyFragment.slot('sourceTexture'), texture);
    bindSurface(_copyQuad);
    drawSurface(_copyQuad);
  }

  /// Submit the pass begun by [beginTexturePass] to the GPU.
  void endTexturePass() {
    final renderPass = _pass;
    if (_suspended) {
      _renderPass = null;
      _suspended = false;
      return;
    }
    RenderProfile.lap(RenderPhase.release);
    _arena.flush();
    RenderProfile.lap(RenderPhase.upload);
    _renderPass = null;
    renderPass.commit(onCompleted: _arena.passCompletion());
  }

  GpuRenderPass get _pass {
    return _renderPass ??
        (throw StateError('No render pass, call beginPass first'));
  }

  /// The [DevicePipeline] that draws surfaces with [layout] using
  /// [vertexShader] and [fragmentShader], created on first use.
  DevicePipeline pipelineFor(
    Shader vertexShader,
    Shader fragmentShader,
    VertexLayout layout,
  ) {
    final vertex = vertexShader.resource;
    final fragment = fragmentShader.resource;
    return _pipelines[(vertex, fragment, layout)] ??= DevicePipeline._create(
      backend,
      vertex,
      fragment,
      layout,
      _pipelines.length,
    );
  }

  /// Bind [pipeline].
  bool bindPipeline(DevicePipeline pipeline) {
    final gpuPipeline = pipeline.pipeline;
    if (identical(gpuPipeline, _pipeline)) {
      return false;
    }
    final renderPass = _pass;
    if (_pipeline != null) {
      renderPass.clearBindings();
      _clearPassBindings();
    }
    renderPass.bindPipeline(gpuPipeline);
    _pipeline = gpuPipeline;
    _surface = null;
    _bindingEpoch++;
    stats.pipelineChanges++;
    return true;
  }

  /// Apply the blending, depth, stencil, polygon mode and culling of [state]
  /// to the following draws.
  void setRenderState(RenderState state) {
    final renderPass = _pass;
    if (state.blend != _blend) {
      renderPass.setBlendState(state.blend);
      _blend = state.blend;
      stats.stateChanges++;
    }
    final compare = state.effectiveDepthCompare;
    if (compare != _depthCompare || state.depthWrite != _depthWrite) {
      renderPass.setDepthState(
        compare: compare,
        writeEnabled: state.depthWrite,
      );
      _depthCompare = compare;
      _depthWrite = state.depthWrite;
      stats.stateChanges++;
    }
    if (state.cullMode != _cullMode) {
      renderPass.setCullMode(state.cullMode);
      _cullMode = state.cullMode;
      stats.stateChanges++;
    }
    if (state.stencil != _stencil) {
      renderPass.setStencil(state.stencil);
      _stencil = state.stencil;
      stats.stateChanges++;
    }
    if (state.polygonMode != _polygonMode) {
      renderPass.setPolygonMode(state.polygonMode);
      _polygonMode = state.polygonMode;
      stats.stateChanges++;
    }
  }

  /// Sets the viewport rectangle and depth range `[zNear, zFar]` inside the
  /// current render pass.
  void setViewport(
    int x,
    int y,
    int width,
    int height, {
    double zNear = 0.0,
    double zFar = 1.0,
  }) {
    if (_hasViewport &&
        _vpX == x &&
        _vpY == y &&
        _vpW == width &&
        _vpH == height &&
        _vpZNear == zNear &&
        _vpZFar == zFar) {
      return;
    }
    _hasViewport = true;
    _vpX = x;
    _vpY = y;
    _vpW = width;
    _vpH = height;
    _vpZNear = zNear;
    _vpZFar = zFar;
    _pass.setViewport(x, y, width, height, zNear: zNear, zFar: zFar);
    stats.stateChanges++;
  }

  /// Sets the pixel scissor clip rectangle inside the current render pass.
  void setScissor(int x, int y, int width, int height) {
    if (_hasScissor &&
        _scX == x &&
        _scY == y &&
        _scW == width &&
        _scH == height) {
      return;
    }
    _hasScissor = true;
    _scX = x;
    _scY = y;
    _scW = width;
    _scH = height;
    _pass.setScissor(x, y, width, height);
    stats.stateChanges++;
  }

  /// Sets the stencil state (`null` disables stencil testing and writes) in the
  /// current render pass.
  void setStencil(StencilState? stencil) {
    if (stencil != _stencil) {
      _pass.setStencil(stencil);
      _stencil = stencil;
      stats.stateChanges++;
    }
  }

  /// Sets polygon fill or wireframe rasterization mode in the current pass.
  void setPolygonMode(PolygonFillMode mode) {
    if (mode != _polygonMode) {
      _pass.setPolygonMode(mode);
      _polygonMode = mode;
      stats.stateChanges++;
    }
  }

  /// Sets primitive assembly topology in the current pass.
  void setPrimitiveTopology(PrimitiveTopology topology) {
    if (topology != _topology) {
      _pass.setPrimitiveTopology(topology);
      _topology = topology;
      stats.stateChanges++;
    }
  }

  /// Set the winding order of front faces for the following draws.
  void setFrontFace(WindingOrder frontFace) {
    if (frontFace != _frontFace) {
      _pass.setWindingOrder(frontFace);
      _frontFace = frontFace;
      stats.stateChanges++;
    }
  }

  /// Clear all resources bound to the current render pass.
  void clearBindings() {
    _pass.clearBindings();
    _surface = null;
    _clearPassBindings();
    _bindingEpoch++;
  }

  /// Bind the vertex and index buffers of [surface].
  void bindSurface(Surface surface) {
    if (identical(surface, _surface) || _suspended) {
      return;
    }
    final buffer = surface.resource;
    _pass
      ..bindVertexBuffer(
        buffer,
        offsetInBytes: 0,
        lengthInBytes: surface.verticesBytes,
      )
      ..bindIndexBuffer(
        buffer,
        offsetInBytes: surface.indicesOffsetInBytes,
        lengthInBytes: surface.indicesBytes,
        indexType: surface.indexType,
      );
    _surface = surface;
    RenderProfile.lap(RenderPhase.binding);
  }

  /// Upload [count] instances from [instances] starting at [startFloat] floats
  /// and bind them as the instance buffer.
  void bindInstances(
    Float32List instances,
    int count, {
    int startFloat = 0,
  }) {
    if (_suspended) {
      return;
    }
    final floats = count * VertexLayout.instanceStrideInFloats;
    final block = _arena.allocate(floats * 4, _instanceAlignment);
    final offset = block.lastOffset;
    block.floats.setRange(
      offset ~/ 4,
      offset ~/ 4 + floats,
      instances,
      startFloat,
    );
    stats.uploadedBytes += floats * 4;
    RenderProfile.lap(RenderPhase.upload);
    _pass.bindVertexBuffer(
      block.buffer,
      offsetInBytes: offset,
      lengthInBytes: floats * 4,
      slot: 1,
    );
    RenderProfile.lap(RenderPhase.binding);
  }

  /// Upload the instances `order[start]` to `order[start + count - 1]` of
  /// [instances], in that order, and bind them as the instance buffer.
  @internal
  void bindInstancesOf(
    Float32List instances,
    Int32List order,
    int start,
    int count,
  ) {
    if (_suspended) {
      return;
    }
    const stride = VertexLayout.instanceStrideInFloats;
    final floats = count * stride;
    final block = _arena.allocate(floats * 4, _instanceAlignment);
    final offset = block.lastOffset;
    final target = block.floats;
    var at = offset ~/ 4;
    for (var i = start; i < start + count; i++) {
      final source = order[i] * stride;
      target.setRange(at, at + stride, instances, source);
      at += stride;
    }
    stats.uploadedBytes += floats * 4;
    RenderProfile.lap(RenderPhase.gather);
    _pass.bindVertexBuffer(
      block.buffer,
      offsetInBytes: offset,
      lengthInBytes: floats * 4,
      slot: 1,
    );
    RenderProfile.lap(RenderPhase.binding);
  }

  /// Draw the bound [surface] [instanceCount] times.
  void drawSurface(Surface surface, {int instanceCount = 1}) {
    setPrimitiveTopology(surface.topology);
    _pass.drawIndexed(surface.indexCount, instanceCount: instanceCount);
    final trisPerInstance = switch (surface.topology) {
      PrimitiveTopology.triangles => surface.indexCount ~/ 3,
      PrimitiveTopology.triangleStrip =>
        surface.indexCount >= 3 ? surface.indexCount - 2 : 0,
      PrimitiveTopology.lines ||
      PrimitiveTopology.lineStrip ||
      PrimitiveTopology.points => 0,
    };
    stats
      ..drawCalls += 1
      ..instances += instanceCount
      ..triangles += trisPerInstance * instanceCount;
  }

  /// Bind a [surface]'s geometry (vertex/index buffers) and draw it once.
  void bindGeometry(Surface surface) {
    bindSurface(surface);
    drawSurface(surface);
  }

  /// Upload [data] and bind it to the uniform block [slot].
  void bindUniform(GpuUniformSlot slot, ByteData data) {
    if (_suspended) {
      return;
    }
    final block = _uploadUniform(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
    _bindUniformResolved(
      slot,
      block.buffer,
      block.lastOffset,
      data.lengthInBytes,
    );
  }

  /// Uploads [data] into this frame's transient arena without binding a slot,
  /// returning `(buffer, offsetInBytes)` so several shaders with matching block
  /// layouts can share one upload via [bindUniformSlice].
  @internal
  (GpuBuffer, int)? uploadUniformBytes(Uint8List data) {
    if (_suspended) {
      return null;
    }
    final block = _uploadUniform(data);
    return (block.buffer, block.lastOffset);
  }

  /// Binds a previously uploaded uniform buffer slice to [slot].
  @internal
  void bindUniformSlice(
    GpuUniformSlot slot,
    GpuBuffer buffer, {
    required int offsetInBytes,
    required int lengthInBytes,
  }) {
    if (_suspended) {
      return;
    }
    _bindUniformResolved(slot, buffer, offsetInBytes, lengthInBytes);
  }

  /// Bind [block] to its slot, uploading it first unless its current contents
  /// were already uploaded during this frame.
  void bindUniformBlock(UniformBlock block) {
    if (_suspended) {
      return;
    }
    RenderProfile.lap(RenderPhase.binding);
    if (block.isDirty || block.uploadFrame != _frame) {
      final upload = _uploadUniform(block.byteList);
      block.markUploaded(_frame, upload.buffer, upload.lastOffset);
      RenderProfile.lap(RenderPhase.upload);
    }
    _bindUniformResolved(
      block.slot,
      block.uploadBuffer!,
      block.uploadOffset,
      block.bytes.lengthInBytes,
    );
    RenderProfile.lap(RenderPhase.binding);
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

  /// Bind a uniform [slot] to the [texture], sampled with its
  /// [Texture.sampler].
  void bindTexture(GpuUniformSlot slot, Texture texture) {
    if (_suspended) {
      return;
    }
    final gpuTex = texture.resource;
    final sampler = texture.sampler;
    final samplerKey = sampler.key;
    for (var i = 0; i < _boundTexCount; i++) {
      if (identical(_boundTexSlots[i], slot)) {
        if (identical(_boundTexHandles[i], gpuTex) &&
            _boundTexSamplerKeys[i] == samplerKey) {
          return;
        }
        _boundTexHandles[i] = gpuTex;
        _boundTexSamplerKeys[i] = samplerKey;
        _pass.bindTexture(slot, gpuTex, sampler: sampler);
        RenderProfile.lap(RenderPhase.binding);
        return;
      }
    }
    final idx = _boundTexCount++;
    if (idx == _boundTexSlots.length) {
      _boundTexSlots.add(slot);
      _boundTexHandles.add(gpuTex);
      _boundTexSamplerKeys = Int32List(_boundTexSamplerKeys.length * 2)
        ..setRange(0, _boundTexSamplerKeys.length, _boundTexSamplerKeys);
    } else {
      _boundTexSlots[idx] = slot;
      _boundTexHandles[idx] = gpuTex;
    }
    _boundTexSamplerKeys[idx] = samplerKey;
    _pass.bindTexture(slot, gpuTex, sampler: sampler);
    RenderProfile.lap(RenderPhase.binding);
  }

  _TransientBlock _uploadUniform(Uint8List data) {
    final length = data.length;
    final block = _arena.allocate(length, backend.uniformAlignment);
    block.staging.setRange(block.lastOffset, block.lastOffset + length, data);
    stats
      ..uniformUploads += 1
      ..uploadedBytes += length;
    return block;
  }

  /// Acquire a render target from the pool, creating one if needed.
  GpuRenderTarget _acquireRenderTarget(Size size, int msaaSampleCount) {
    final key = (
      _pixels(size.width),
      _pixels(size.height),
      msaaSampleCount,
    );
    final bucket = _pool[key] ??= _PoolBucket(_frame);
    final index = bucket.used;
    final targets = bucket.targets;
    if (index < targets.length) {
      bucket.used = index + 1;
      return targets[index];
    }

    final target = backend.createRenderTarget(
      width: key.$1,
      height: key.$2,
      clearValue: clearValue,
      msaaSampleCount: key.$3,
    );

    targets.add(target);
    bucket.used = index + 1;
    return target;
  }

  static int _pixels(double size) {
    final pixels = size.round();
    return pixels < 1 ? 1 : pixels;
  }

  static const _instanceAlignment = 16;
}

class _PoolBucket(this.lastUsedFrame) {
  final List<GpuRenderTarget> targets = [];
  int used = 0;
  int lastUsedFrame;
}

class _TextureTargetEntry(
  final GpuTextureTarget target,
  var int lastUsedFrame,
  final int estimatedBytes,
);

/// {@template device_pipeline}
/// A render pipeline built by a [GraphicsDevice] for one vertex shader,
/// fragment shader and surface [VertexLayout], with what the device learned
/// about how it reads its inputs.
/// {@endtemplate}
class DevicePipeline._(
  /// The backend pipeline.
  final GpuPipeline pipeline, {

  /// The backend vertex shader linked into this pipeline.
  required final GpuShader vertexShader,

  /// The backend fragment shader linked into this pipeline.
  required final GpuShader fragmentShader,

  /// A number identifying this pipeline within its device, usable to sort
  /// draws by pipeline.
  required final int id,

  /// Whether the vertex shader reads per-instance data, so an instance buffer
  /// must be bound for every draw.
  required final bool usesInstanceData,

  /// Whether the vertex shader reads its model matrix from the instance data,
  /// so draws of the same surface and material can be batched into one
  /// instanced draw.
  required final bool instanced,
}) {
  factory DevicePipeline._create(
    GpuBackend backend,
    GpuShader vertexShader,
    GpuShader fragmentShader,
    VertexLayout layout,
    int id,
  ) {
    final vertexAttributes = <GpuVertexAttribute>[];
    final instanceAttributes = <GpuVertexAttribute>[];
    final inputs = vertexShader.inputs;

    void addInstanceAttribute(int index, String name, int location) {
      instanceAttributes.add(
        GpuVertexAttribute(
          name: name,
          location: location,
          components: VertexLayout.instanceAttributes[index].components,
          offsetInBytes: index * 16,
        ),
      );
    }

    if (inputs == null) {
      for (final (index, attribute) in layout.attributes.indexed) {
        vertexAttributes.add(
          GpuVertexAttribute(
            name: attribute.name,
            location: index,
            components: attribute.components,
            offsetInBytes: layout.offsetOf(attribute.name)! * 4,
          ),
        );
      }
      for (final (index, attribute)
          in VertexLayout.instanceAttributes.indexed) {
        addInstanceAttribute(
          index,
          attribute.name,
          layout.attributes.length + index,
        );
      }
    } else {
      for (final input in inputs) {
        final attribute = layout.attribute(input.name);
        if (attribute != null) {
          vertexAttributes.add(
            GpuVertexAttribute(
              name: input.name,
              location: input.location,
              components: attribute.components,
              offsetInBytes: layout.offsetOf(input.name)! * 4,
            ),
          );
          continue;
        }
        final instanceIndex = VertexLayout.instanceAttributes.indexWhere(
          (a) => a.name == input.name,
        );
        if (instanceIndex < 0) {
          final instanceInputs = VertexLayout.instanceAttributes
              .map((a) => a.name)
              .join(', ');
          throw StateError(
            'The vertex shader input "${input.name}" is not provided by the '
            'surface vertex layout $layout, nor is it an instance input '
            '($instanceInputs)',
          );
        }
        addInstanceAttribute(instanceIndex, input.name, input.location);
      }
    }

    final modelColumns = instanceAttributes
        .where((a) => a.name.startsWith('instanceModel'))
        .length;
    if (modelColumns != 0 && modelColumns != 4) {
      throw StateError(
        'A vertex shader must declare all four instanceModel columns or none',
      );
    }

    final pipeline = backend.createPipeline(
      vertexShader: vertexShader,
      fragmentShader: fragmentShader,
      vertexLayout: GpuVertexLayout([
        GpuVertexBufferLayout(
          strideInBytes: layout.strideInBytes,
          attributes: vertexAttributes,
        ),
        if (instanceAttributes.isNotEmpty)
          GpuVertexBufferLayout(
            strideInBytes: VertexLayout.instanceStrideInFloats * 4,
            attributes: instanceAttributes,
            perInstance: true,
          ),
      ]),
    );
    return DevicePipeline._(
      pipeline,
      vertexShader: vertexShader,
      fragmentShader: fragmentShader,
      id: id,
      usesInstanceData: instanceAttributes.isNotEmpty,
      instanced: modelColumns == 4,
    );
  }
}

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
      final offset = _align(block.used, alignment);
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

  static int _align(int value, int alignment) {
    final remainder = value % alignment;
    return remainder == 0 ? value : value + alignment - remainder;
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
