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
}) implements ShaderBindTarget {
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

  // Render-target and binding state trackers.
  final _RenderTargetPool _targetPool = _RenderTargetPool();
  final _PassBindingState _bindings = _PassBindingState();

  /// The number of frames a render target size that is no longer used stays
  /// pooled, so that a scene whose size changes back and forth, or that skips
  /// a few frames, keeps its targets instead of creating new ones.
  static const int targetRetainFrames = 30;

  // Pipelines, keyed by vertex shader -> fragment shader -> surface layout.
  final Map<GpuShader, Map<GpuShader, Map<VertexLayout, DevicePipeline>>>
  _pipelines = Map.identity();
  int _pipelineCount = 0;
  GpuShader? _lastPipeVert;
  GpuShader? _lastPipeFrag;
  VertexLayout? _lastPipeLayout;
  DevicePipeline? _lastPipeResult;

  final Expando<_InstanceUploadCache> _instanceCache = Expando();

  /// Incremented whenever the pass's bindings are cleared (by [clearBindings]
  /// or by binding a different pipeline), after which every resource of the
  /// next draw must be bound again.
  int get bindingEpoch => _bindings.bindingEpoch;

  /// The winding order of front faces for the following draws.
  WindingOrder get frontFace => _bindings.frontFace;

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
    _targetPool.beginFrame();
    _gpuFrame = backend.beginFrame();
  }

  /// End the frame.
  void end() {
    _gpuFrame?.end();
    _gpuFrame = null;
    _arena.endFrame();
    lastFrameStats.setFrom(stats);
    _targetPool.evictUnused(_frame);
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
    _renderTarget = _targetPool.acquireRenderTarget(
      backend,
      clearValue,
      _frame,
      size,
      msaaSampleCount,
    );
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
  int get cachedPipelineCount => _pipelineCount;

  /// Estimated GPU render-target memory (color + depth attachments, in bytes)
  /// currently pooled by this device.
  int get estimatedTargetVramBytes => _targetPool.estimatedVramBytes;

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
  }) => _targetPool.acquireTextureTarget(
    backend,
    _frame,
    width,
    height,
    format,
    clearValue: clearValue,
    role: role,
    msaaSampleCount: msaaSampleCount,
  );

  /// Marks [target] as used in the current frame so [targetRetainFrames] does
  /// not evict a cached texture target (such as a static shadow map).
  @internal
  void touchTextureTarget(GpuTextureTarget target) =>
      _targetPool.touchTextureTarget(target, _frame);

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
  DevicePipeline? _copyPipeline;
  int _copyVertGen = -1;
  int _copyFragGen = -1;
  GpuUniformSlot? _copySourceSlot;

  /// Draws [texture] over the viewport of the open pass, without testing or
  /// writing depth: texel for texel when it has the size of the viewport and
  /// is sampled with the nearest texel. One draw call of two triangles.
  @internal
  void drawTextureCopy(Texture texture) {
    _copyVertex.resource;
    _copyFragment.resource;
    var pipeline = _copyPipeline;
    if (pipeline == null ||
        _copyVertGen != _copyVertex.generation ||
        _copyFragGen != _copyFragment.generation) {
      pipeline = _copyPipeline = pipelineFor(
        _copyVertex,
        _copyFragment,
        fullscreenQuadSurface.layout,
      );
      _copyVertGen = _copyVertex.generation;
      _copyFragGen = _copyFragment.generation;
      _copySourceSlot = _copyFragment.slot('sourceTexture');
    }
    bindPipeline(pipeline);
    setRenderState(fullscreenQuadState);
    bindTexture(_copySourceSlot!, texture);
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
    final last = _lastPipeResult;
    if (last != null &&
        identical(vertex, _lastPipeVert) &&
        identical(fragment, _lastPipeFrag) &&
        (identical(layout, _lastPipeLayout) || _lastPipeLayout == layout)) {
      return last;
    }
    var fragMap = _pipelines[vertex];
    if (fragMap == null) {
      fragMap = Map.identity();
      _pipelines[vertex] = fragMap;
    }
    var layoutMap = fragMap[fragment];
    if (layoutMap == null) {
      layoutMap = {};
      fragMap[fragment] = layoutMap;
    }
    final pipeline = layoutMap[layout] ??= DevicePipeline._create(
      backend,
      vertex,
      fragment,
      layout,
      _pipelineCount++,
    );
    _lastPipeVert = vertex;
    _lastPipeFrag = fragment;
    _lastPipeLayout = layout;
    _lastPipeResult = pipeline;
    return pipeline;
  }

  /// Bind [pipeline].
  bool bindPipeline(DevicePipeline pipeline) {
    final gpuPipeline = pipeline.pipeline;
    final b = _bindings;
    if (identical(gpuPipeline, b.pipeline)) {
      return false;
    }
    final renderPass = _pass;
    if (b.pipeline != null) {
      renderPass.clearBindings();
      b.clearBindings();
    }
    renderPass.bindPipeline(gpuPipeline);
    b
      ..pipeline = gpuPipeline
      ..surface = null;
    b.bindingEpoch++;
    stats.pipelineChanges++;
    return true;
  }

  /// Apply the blending, depth, stencil, polygon mode and culling of [state]
  /// to the following draws.
  void setRenderState(RenderState state) {
    final renderPass = _pass;
    final b = _bindings;
    if (state.blend != b.blend) {
      renderPass.setBlendState(state.blend);
      b.blend = state.blend;
      stats.stateChanges++;
    }
    final compare = state.effectiveDepthCompare;
    if (compare != b.depthCompare || state.depthWrite != b.depthWrite) {
      renderPass.setDepthState(
        compare: compare,
        writeEnabled: state.depthWrite,
      );
      b
        ..depthCompare = compare
        ..depthWrite = state.depthWrite;
      stats.stateChanges++;
    }
    if (state.cullMode != b.cullMode) {
      renderPass.setCullMode(state.cullMode);
      b.cullMode = state.cullMode;
      stats.stateChanges++;
    }
    if (state.stencil != b.stencil) {
      renderPass.setStencil(state.stencil);
      b.stencil = state.stencil;
      stats.stateChanges++;
    }
    if (state.polygonMode != b.polygonMode) {
      renderPass.setPolygonMode(state.polygonMode);
      b.polygonMode = state.polygonMode;
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
    final b = _bindings;
    if (b.hasViewport &&
        b.vpX == x &&
        b.vpY == y &&
        b.vpW == width &&
        b.vpH == height &&
        b.vpZNear == zNear &&
        b.vpZFar == zFar) {
      return;
    }
    b
      ..hasViewport = true
      ..vpX = x
      ..vpY = y
      ..vpW = width
      ..vpH = height
      ..vpZNear = zNear
      ..vpZFar = zFar;
    _pass.setViewport(x, y, width, height, zNear: zNear, zFar: zFar);
    stats.stateChanges++;
  }

  /// Sets the pixel scissor clip rectangle inside the current render pass.
  void setScissor(int x, int y, int width, int height) {
    final b = _bindings;
    if (b.hasScissor &&
        b.scX == x &&
        b.scY == y &&
        b.scW == width &&
        b.scH == height) {
      return;
    }
    b
      ..hasScissor = true
      ..scX = x
      ..scY = y
      ..scW = width
      ..scH = height;
    _pass.setScissor(x, y, width, height);
    stats.stateChanges++;
  }

  /// Sets the stencil state (`null` disables stencil testing and writes) in the
  /// current render pass.
  void setStencil(StencilState? stencil) {
    final b = _bindings;
    if (stencil != b.stencil) {
      _pass.setStencil(stencil);
      b.stencil = stencil;
      stats.stateChanges++;
    }
  }

  /// Sets polygon fill or wireframe rasterization mode in the current pass.
  void setPolygonMode(PolygonFillMode mode) {
    final b = _bindings;
    if (mode != b.polygonMode) {
      _pass.setPolygonMode(mode);
      b.polygonMode = mode;
      stats.stateChanges++;
    }
  }

  /// Sets primitive assembly topology in the current pass.
  void setPrimitiveTopology(PrimitiveTopology topology) {
    final b = _bindings;
    if (topology != b.topology) {
      _pass.setPrimitiveTopology(topology);
      b.topology = topology;
      stats.stateChanges++;
    }
  }

  /// Set the winding order of front faces for the following draws.
  void setFrontFace(WindingOrder frontFace) {
    final b = _bindings;
    if (frontFace != b.frontFace) {
      _pass.setWindingOrder(frontFace);
      b.frontFace = frontFace;
      stats.stateChanges++;
    }
  }

  /// Clear all resources bound to the current render pass.
  void clearBindings() {
    _pass.clearBindings();
    _bindings
      ..surface = null
      ..clearBindings();
    _bindings.bindingEpoch++;
  }

  /// Bind the vertex and index buffers of [surface].
  void bindSurface(Surface surface) {
    final b = _bindings;
    if (identical(surface, b.surface) || _suspended) {
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
    b.surface = surface;
    RenderProfile.lap(RenderPhase.binding);
  }

  /// Upload [count] instances from [instances] starting at [startFloat] floats
  /// and bind them as the instance buffer.
  ///
  /// When [version] is non-null and [instances] preserves its contents as long
  /// as [version] is unchanged, consecutive frames promote the buffer (or the
  /// first [cacheSpanCount] instances starting at float `0` when
  /// [cacheSpanCount] is set) to a retained [GpuBuffer], avoiding per-frame
  /// re-uploads.
  void bindInstances(
    Float32List instances,
    int count, {
    int startFloat = 0,
    int? version,
    int? cacheSpanCount,
  }) {
    if (_suspended || count <= 0) {
      return;
    }
    const stride = VertexLayout.instanceStrideInFloats;
    final floats = count * stride;
    final bytes = floats * 4;
    if (version == null) {
      final block = _arena.allocate(bytes, _instanceAlignment);
      final offset = block.lastOffset;
      block.floats.setRange(
        offset ~/ 4,
        offset ~/ 4 + floats,
        instances,
        startFloat,
      );
      stats.uploadedBytes += bytes;
      RenderProfile.lap(RenderPhase.upload);
      _bindings.bindInstanceSlice(_pass, block.buffer, offset, bytes);
      RenderProfile.lap(RenderPhase.binding);
      return;
    }

    var entry = _instanceCache[instances];
    if (entry == null) {
      entry = _InstanceUploadCache();
      _instanceCache[instances] = entry;
    }
    final spanCount = cacheSpanCount ?? count;
    final spanStartFloat = cacheSpanCount != null ? 0 : startFloat;
    final spanFloats = spanCount * stride;
    final spanBytes = spanFloats * 4;
    final subOffsetBytes = (startFloat - spanStartFloat) * 4;
    final gen = GpuBackend.deviceGeneration;

    final gpuBuf = entry.gpuBuffer;
    if (gpuBuf != null &&
        entry.deviceGeneration == gen &&
        entry.version == version &&
        entry.spanStartFloat == spanStartFloat &&
        entry.spanFloats == spanFloats) {
      _bindings.bindInstanceSlice(_pass, gpuBuf, subOffsetBytes, bytes);
      RenderProfile.lap(RenderPhase.binding);
      return;
    }

    final arenaBuf = entry.arenaBuffer;
    if (arenaBuf != null &&
        entry.frame == _frame &&
        entry.deviceGeneration == gen &&
        entry.version == version &&
        entry.spanStartFloat == spanStartFloat &&
        entry.spanFloats == spanFloats) {
      _bindings.bindInstanceSlice(
        _pass,
        arenaBuf,
        entry.arenaOffset + subOffsetBytes,
        bytes,
      );
      RenderProfile.lap(RenderPhase.binding);
      return;
    }

    if (entry.frame >= 0 &&
        entry.frame != _frame &&
        entry.deviceGeneration == gen &&
        entry.version == version &&
        entry.spanStartFloat == spanStartFloat &&
        entry.spanFloats == spanFloats) {
      final persistent = backend.createBuffer(
        storageMode: GpuStorageMode.hostVisible,
        sizeInBytes: spanBytes,
      );
      persistent.write(
        instances.buffer.asByteData(
          instances.offsetInBytes + spanStartFloat * 4,
          spanBytes,
        ),
      );
      entry
        ..gpuBuffer = persistent
        ..arenaBuffer = null;
      stats.uploadedBytes += spanBytes;
      RenderProfile.lap(RenderPhase.upload);
      _bindings.bindInstanceSlice(_pass, persistent, subOffsetBytes, bytes);
      RenderProfile.lap(RenderPhase.binding);
      return;
    }

    final block = _arena.allocate(spanBytes, _instanceAlignment);
    final offset = block.lastOffset;
    block.floats.setRange(
      offset ~/ 4,
      offset ~/ 4 + spanFloats,
      instances,
      spanStartFloat,
    );
    entry
      ..gpuBuffer = null
      ..arenaBuffer = block.buffer
      ..arenaOffset = offset
      ..frame = _frame
      ..deviceGeneration = gen
      ..version = version
      ..spanStartFloat = spanStartFloat
      ..spanFloats = spanFloats;
    stats.uploadedBytes += spanBytes;
    RenderProfile.lap(RenderPhase.upload);
    _bindings.bindInstanceSlice(
      _pass,
      block.buffer,
      offset + subOffsetBytes,
      bytes,
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
    _bindings.bindInstanceSlice(_pass, block.buffer, offset, floats * 4);
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
    final block = _uploadUniformByteData(data);
    _bindings.bindUniformResolved(
      _pass,
      slot,
      block.buffer,
      block.lastOffset,
      data.lengthInBytes,
    );
  }

  int _lastUploadedOffset = 0;

  /// Buffer byte offset of the last slice uploaded via [uploadUniformRange].
  @internal
  int get lastUploadedOffset => _lastUploadedOffset;

  /// Uploads the first [length] bytes of [data] into this frame's transient
  /// arena without creating view objects or Record wrappers; the slice offset
  /// is stored in [lastUploadedOffset].
  @internal
  GpuBuffer? uploadUniformRange(Uint8List data, int length) {
    if (_suspended) {
      return null;
    }
    final block = _uploadUniformRange(data, length);
    _lastUploadedOffset = block.lastOffset;
    return block.buffer;
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
    _bindings.bindUniformResolved(
      _pass,
      slot,
      buffer,
      offsetInBytes,
      lengthInBytes,
    );
  }

  /// Bind [block] to its slot, uploading it first unless its current contents
  /// were already uploaded during this frame.
  @override
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
    _bindings.bindUniformResolved(
      _pass,
      block.slot,
      block.uploadBuffer!,
      block.uploadOffset,
      block.bytes.lengthInBytes,
    );
    RenderProfile.lap(RenderPhase.binding);
  }

  /// Bind a uniform [slot] to the [texture], sampled with its
  /// [Texture.sampler].
  @override
  void bindTexture(GpuUniformSlot slot, Texture texture) {
    if (_suspended) {
      return;
    }
    _bindings.bindTextureResolved(
      _pass,
      slot,
      texture.resource,
      texture.sampler,
    );
  }

  static const _instanceAlignment = 16;
}
