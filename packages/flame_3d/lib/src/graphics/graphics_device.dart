import 'dart:typed_data';
import 'dart:ui';

import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/src/graphics/bloom_pass.dart';
import 'package:flame_3d/src/graphics/fullscreen_quad.dart';
import 'package:meta/meta.dart';

part 'device_pipeline.dart';
part 'gpu_transient_arena.dart';
part 'graphics_device_draw.dart';
part 'graphics_device_pool.dart';

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
    _evictUnusedTargets();
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
  final List<GpuTextureTarget?> _copySources = List.filled(2, null);
  final List<Texture> _copyTextures = List.filled(2, Texture.standard);

  /// Draws [texture] over the viewport of the open pass, without testing or
  /// writing depth: texel for texel when it has the size of the viewport and
  /// is sampled with the nearest texel. One draw call of two triangles.
  @internal
  void drawTextureCopy(Texture texture) {
    _copyFragment.setTexture('sourceTexture', texture);
    bindPipeline(
      pipelineFor(_copyVertex, _copyFragment, fullscreenQuadSurface.layout),
    );
    setRenderState(fullscreenQuadState);
    bindTexture(_copyFragment.slot('sourceTexture'), texture);
    bindSurface(fullscreenQuadSurface);
    drawSurface(fullscreenQuadSurface);
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

  static const _instanceAlignment = 16;
}
