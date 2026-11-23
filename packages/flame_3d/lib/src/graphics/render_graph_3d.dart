import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:meta/meta.dart';

part 'render_graph_3d_compiler.dart';

/// Descriptor of a transient GPU texture managed by a [RenderGraph3D].
@immutable
class const RenderGraphTextureDesc3D({
  required final int width,
  required final int height,
  final GpuPixelFormat format = GpuPixelFormat.rgba8888,
  final Color clearValue = const Color(0x00000000),
}) {
  @override
  bool operator ==(Object other) {
    return other is RenderGraphTextureDesc3D &&
        other.width == width &&
        other.height == height &&
        other.format == format &&
        other.clearValue == clearValue;
  }

  @override
  int get hashCode => Object.hash(width, height, format, clearValue);
}

/// Handle to a virtual or imported texture resource in a [RenderGraph3D].
@immutable
class const RenderGraphResourceHandle3D._({
  required final int id,
  required final String name,
  required final RenderGraphTextureDesc3D descriptor,
  required final bool imported,
});

/// Execution context supplied to each live [RenderGraphPass3D].
class RenderGraphPassContext3D({
  required GraphicsDevice device,
  required RenderContext3D renderContext,
  required Map<int, GpuTextureTarget> resolvedTargets,
}) {
  /// The active [GraphicsDevice] for the executing graph.
  GraphicsDevice get device => _device;
  GraphicsDevice _device = device;

  /// The active [RenderContext3D] for the executing graph.
  RenderContext3D get renderContext => _renderContext;
  RenderContext3D _renderContext = renderContext;

  final Map<int, GpuTextureTarget> _resolvedTargets = resolvedTargets;

  static final Expando<Texture> _linearTextures = Expando<Texture>(
    'RenderGraphLinearTextures',
  );
  static final Expando<Map<TextureSampler, Texture>> _samplerTextures =
      Expando<Map<TextureSampler, Texture>>('RenderGraphSamplerTextures');

  /// Returns the physical [GpuTextureTarget] backing [handle].
  GpuTextureTarget targetOf(RenderGraphResourceHandle3D handle) {
    final target = _resolvedTargets[handle.id];
    if (target == null) {
      throw StateError(
        'Resource "${handle.name}" (#${handle.id}) was not allocated for this '
        'pass (check that the pass declares it in reads or writes).',
      );
    }
    return target;
  }

  /// Wraps the physical [GpuTextureTarget] backing [handle] as a [Texture]
  /// sampled with [sampler].
  Texture textureOf(
    RenderGraphResourceHandle3D handle, {
    TextureSampler sampler = TextureSampler.linear,
  }) {
    final t = targetOf(handle);
    if (sampler == TextureSampler.linear) {
      final cached = _linearTextures[t];
      if (cached != null && identical(cached.gpuTexture, t.texture)) {
        return cached;
      }
      return _linearTextures[t] = Texture(
        null,
        width: t.width,
        height: t.height,
        sampler: sampler,
        gpuTexture: t.texture,
      );
    }
    final map = _samplerTextures[t] ??= <TextureSampler, Texture>{};
    final cached = map[sampler];
    if (cached != null && identical(cached.gpuTexture, t.texture)) {
      return cached;
    }
    return map[sampler] = Texture(
      null,
      width: t.width,
      height: t.height,
      sampler: sampler,
      gpuTexture: t.texture,
    );
  }
}

/// A single node in a [RenderGraph3D] Directed Acyclic Graph.
class RenderGraphPass3D({
  required final String name,
  required final void Function(RenderGraphPassContext3D context) execute,
  final List<RenderGraphResourceHandle3D> reads = const [],
  final List<RenderGraphResourceHandle3D> writes = const [],
  final bool hasSideEffects = false,
});

/// Compiled execution plan of a [RenderGraph3D], including topologically sorted
/// live passes, eliminated dead passes, and transient texture lifetime aliasing
/// assignments.
class CompiledRenderGraph3D({
  required final List<RenderGraphPass3D> executionOrder,
  required final List<RenderGraphPass3D> culledPasses,
  required final int virtualTextureCount,
  required final int physicalTargetCount,
  required final Map<int, int> resourceToPhysicalSlot,
  required final List<RenderGraphTextureDesc3D> physicalSlotDescriptors,
}) {
  late final Int32List _resourceIds;
  late final Int32List _resourceSlots;
  bool _resourceArraysBuilt = false;

  void _ensureResourceArrays() {
    if (_resourceArraysBuilt) {
      return;
    }
    _resourceArraysBuilt = true;
    final len = resourceToPhysicalSlot.length;
    final ids = _resourceIds = Int32List(len);
    final slots = _resourceSlots = Int32List(len);
    var i = 0;
    for (final entry in resourceToPhysicalSlot.entries) {
      ids[i] = entry.key;
      slots[i] = entry.value;
      i++;
    }
  }
}

/// Declarative frame-graph / render-graph DAG scheduler with topological pass
/// ordering, backward-reachability dead-pass culling, and greedy lifetime
/// interval aliasing/pooling of transient [GpuTextureTarget]s.
class RenderGraph3D() {
  final List<RenderGraphResourceHandle3D> _resources = [];
  final Map<int, GpuTextureTarget> _importedTargets = {};
  final Set<int> _outputs = {};
  final List<RenderGraphPass3D> _passes = [];

  final _RenderGraphTargetPool _targetPool = _RenderGraphTargetPool();

  CompiledRenderGraph3D? _cachedPlan;
  int _compileCount = 0;

  // Scratch collections reused across `execute()` calls.
  final Map<int, GpuTextureTarget> _resolvedTargets = {};
  RenderGraphPassContext3D? _reusableContext;

  /// Number of times [compile] has actually recomputed a plan rather than
  /// returning a cached [CompiledRenderGraph3D].
  int get compileCount => _compileCount;

  /// The number of [execute] calls a pooled target of a descriptor no graph
  /// used is kept for before it is released (a graph rebuilt at a new size
  /// does not keep the targets of the old size for ever).
  static const int targetRetainExecutions = 30;

  /// Clears declared passes and virtual resources while retaining pooled GPU
  /// targets for reuse on the next frame.
  void clear() {
    _resources.clear();
    _importedTargets.clear();
    _outputs.clear();
    _passes.clear();
    _cachedPlan = null;
  }

  /// Declares a transient virtual texture with [descriptor].
  RenderGraphResourceHandle3D createTexture(
    String name,
    RenderGraphTextureDesc3D descriptor,
  ) {
    _cachedPlan = null;
    final handle = RenderGraphResourceHandle3D._(
      id: _resources.length,
      name: name,
      descriptor: descriptor,
      imported: false,
    );
    _resources.add(handle);
    return handle;
  }

  /// Imports an external caller-owned [GpuTextureTarget] into the graph.
  ///
  /// Passes that write to an imported target are treated as live roots and are
  /// never culled.
  RenderGraphResourceHandle3D importTextureTarget(
    String name,
    GpuTextureTarget target,
  ) {
    _cachedPlan = null;
    final handle = RenderGraphResourceHandle3D._(
      id: _resources.length,
      name: name,
      descriptor: RenderGraphTextureDesc3D(
        width: target.width,
        height: target.height,
        format: target.format,
      ),
      imported: true,
    );
    _resources.add(handle);
    _importedTargets[handle.id] = target;
    _outputs.add(handle.id);
    return handle;
  }

  /// Marks [handle] as a graph output so passes producing it are preserved by
  /// dead-pass elimination.
  void markOutput(RenderGraphResourceHandle3D handle) {
    if (_outputs.add(handle.id)) {
      _cachedPlan = null;
    }
  }

  /// Appends [pass] to this render graph.
  void addPass(RenderGraphPass3D pass) {
    _cachedPlan = null;
    _passes.add(pass);
  }

  /// Convenience builder that creates and appends a [RenderGraphPass3D].
  RenderGraphPass3D addRenderPass({
    required String name,
    required void Function(RenderGraphPassContext3D context) execute,
    List<RenderGraphResourceHandle3D> reads = const [],
    List<RenderGraphResourceHandle3D> writes = const [],
    bool hasSideEffects = false,
  }) {
    _cachedPlan = null;
    final pass = RenderGraphPass3D(
      name: name,
      reads: reads,
      writes: writes,
      hasSideEffects: hasSideEffects,
      execute: execute,
    );
    _passes.add(pass);
    return pass;
  }

  /// Compiles the DAG: builds producer->consumer edges, detects cycles,
  /// eliminates unreferenced dead passes, and aliases non-overlapping transient
  /// textures with identical [RenderGraphTextureDesc3D]s into minimal physical
  /// slots.
  CompiledRenderGraph3D compile() {
    final cached = _cachedPlan;
    if (cached != null) {
      return cached;
    }
    _compileCount++;
    return _cachedPlan = _compileRenderGraph(_passes, _resources, _outputs);
  }

  /// Compiles and executes all live passes on [device] and [renderContext],
  /// allocating (and pooling) only [CompiledRenderGraph3D.physicalTargetCount]
  /// transient GPU texture targets.
  CompiledRenderGraph3D execute(
    GraphicsDevice device,
    RenderContext3D renderContext,
  ) {
    final plan = compile();
    if (plan.executionOrder.isEmpty) {
      return plan;
    }

    _targetPool.acquireForPlan(
      plan,
      device.backend,
      GpuBackend.deviceGeneration,
    );
    final slotTargets = _targetPool.slotTargets;

    plan._ensureResourceArrays();
    final resolved = _resolvedTargets..clear();
    if (_importedTargets.isNotEmpty) {
      resolved.addAll(_importedTargets);
    }
    final resIds = plan._resourceIds;
    final resSlots = plan._resourceSlots;
    for (var i = 0; i < resIds.length; i++) {
      resolved[resIds[i]] = slotTargets[resSlots[i]];
    }

    final ctx = _reusableContext;
    final RenderGraphPassContext3D activeCtx;
    if (ctx == null) {
      activeCtx = _reusableContext = RenderGraphPassContext3D(
        device: device,
        renderContext: renderContext,
        resolvedTargets: resolved,
      );
    } else {
      ctx
        .._device = device
        .._renderContext = renderContext;
      activeCtx = ctx;
    }
    for (var i = 0; i < plan.executionOrder.length; i++) {
      plan.executionOrder[i].execute(activeCtx);
    }
    return plan;
  }
}
