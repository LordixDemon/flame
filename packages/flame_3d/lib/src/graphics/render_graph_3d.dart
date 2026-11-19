import 'dart:ui' show Color;

import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:meta/meta.dart';

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
  required final GraphicsDevice device,
  required final RenderContext3D renderContext,
  required Map<int, GpuTextureTarget> resolvedTargets,
}) {
  final Map<int, GpuTextureTarget> _resolvedTargets = resolvedTargets;

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
    return Texture(
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
});

/// Declarative frame-graph / render-graph DAG scheduler with topological pass
/// ordering, backward-reachability dead-pass culling, and greedy lifetime
/// interval aliasing/pooling of transient [GpuTextureTarget]s.
class RenderGraph3D() {
  final List<RenderGraphResourceHandle3D> _resources = [];
  final Map<int, GpuTextureTarget> _importedTargets = {};
  final Set<int> _outputs = {};
  final List<RenderGraphPass3D> _passes = [];

  // Reusable pool of physical texture targets across `execute()` calls, keyed
  // by physical slot descriptor so aliased non-overlapping resources genuinely
  // share the exact same GPU memory allocation.
  final Map<RenderGraphTextureDesc3D, List<GpuTextureTarget>> _targetPool = {};
  final Map<RenderGraphTextureDesc3D, int> _targetLastUsed = {};
  int _executions = 0;

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
  }

  /// Declares a transient virtual texture with [descriptor].
  RenderGraphResourceHandle3D createTexture(
    String name,
    RenderGraphTextureDesc3D descriptor,
  ) {
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
    _outputs.add(handle.id);
  }

  /// Appends [pass] to this render graph.
  void addPass(RenderGraphPass3D pass) {
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
    final n = _passes.length;
    if (n == 0) {
      return CompiledRenderGraph3D(
        executionOrder: const [],
        culledPasses: const [],
        virtualTextureCount: 0,
        physicalTargetCount: 0,
        resourceToPhysicalSlot: const {},
        physicalSlotDescriptors: const [],
      );
    }

    // Build dependency edges: if pass P writes R and pass C reads R, P -> C.
    // Also if pass P1 writes R and later pass P2 writes R, P1 -> P2.
    final adj = List<Set<int>>.generate(n, (_) => <int>{});
    final revAdj = List<Set<int>>.generate(n, (_) => <int>{});
    final lastWriter = <int, int>{};

    // First scan writers in declaration order, then link readers to all writers
    // or support arbitrary declaration order: if a pass declares `reads: [R]`
    // before the pass that declares `writes: [R]`, find producers of R across
    // all passes!
    final writersOf = <int, List<int>>{};
    for (var i = 0; i < n; i++) {
      for (final w in _passes[i].writes) {
        final prev = lastWriter[w.id];
        if (prev != null && prev != i) {
          adj[prev].add(i);
          revAdj[i].add(prev);
        }
        lastWriter[w.id] = i;
        (writersOf[w.id] ??= <int>[]).add(i);
      }
    }

    for (var i = 0; i < n; i++) {
      final writtenHere = {for (final w in _passes[i].writes) w.id};
      for (final r in _passes[i].reads) {
        if (writtenHere.contains(r.id)) {
          continue;
        }
        final producers = writersOf[r.id];
        if (producers == null) {
          continue;
        }
        for (final prod in producers) {
          if (prod != i) {
            adj[prod].add(i);
            revAdj[i].add(prod);
          }
        }
      }
    }

    // Kahn's topological sort over all passes to detect cycles first.
    final inDegree = List<int>.generate(n, (i) => revAdj[i].length);
    final ready = <int>[
      for (var i = 0; i < n; i++)
        if (inDegree[i] == 0) i,
    ];
    final topoAll = <int>[];
    var head = 0;
    while (head < ready.length) {
      // Pick lowest declaration index among ready nodes for deterministic
      // ordering.
      var bestPos = head;
      for (var j = head + 1; j < ready.length; j++) {
        if (ready[j] < ready[bestPos]) {
          bestPos = j;
        }
      }
      final tmp = ready[head];
      ready[head] = ready[bestPos];
      ready[bestPos] = tmp;

      final u = ready[head++];
      topoAll.add(u);
      for (final v in adj[u]) {
        inDegree[v]--;
        if (inDegree[v] == 0) {
          ready.add(v);
        }
      }
    }

    if (topoAll.length != n) {
      throw StateError('RenderGraph3D contains a cyclic pass dependency');
    }

    // Backward reachability dead-pass culling from side-effect passes and
    // passes writing to graph outputs / imported targets.
    final live = List<bool>.filled(n, false);
    final stack = <int>[];
    for (var i = 0; i < n; i++) {
      final p = _passes[i];
      final writesOutput = p.writes.any((w) => _outputs.contains(w.id));
      if (p.hasSideEffects || writesOutput) {
        live[i] = true;
        stack.add(i);
      }
    }
    while (stack.isNotEmpty) {
      final curr = stack.removeLast();
      for (final pred in revAdj[curr]) {
        if (!live[pred]) {
          live[pred] = true;
          stack.add(pred);
        }
      }
    }

    final executionOrder = <RenderGraphPass3D>[];
    final culledPasses = <RenderGraphPass3D>[];
    for (final idx in topoAll) {
      if (live[idx]) {
        executionOrder.add(_passes[idx]);
      } else {
        culledPasses.add(_passes[idx]);
      }
    }

    for (var i = 0; i < n; i++) {
      if (!live[i]) {
        // Keep culledPasses in declaration order for predictable inspection.
      }
    }

    // Compute live `[firstUse, lastUse]` pass intervals for transient textures.
    final firstUse = <int, int>{};
    final lastUse = <int, int>{};
    for (var step = 0; step < executionOrder.length; step++) {
      final pass = executionOrder[step];
      for (final h in pass.writes) {
        if (!h.imported) {
          firstUse.putIfAbsent(h.id, () => step);
          lastUse[h.id] = _outputs.contains(h.id)
              ? executionOrder.length
              : step;
        }
      }
      for (final h in pass.reads) {
        if (!h.imported) {
          firstUse.putIfAbsent(h.id, () => step);
          final prev = lastUse[h.id] ?? step;
          if (step > prev) {
            lastUse[h.id] = step;
          }
        }
      }
    }

    // Greedy interval coloring / lifetime aliasing per descriptor.
    final transientIds = firstUse.keys.toList()
      ..sort((a, b) => firstUse[a]!.compareTo(firstUse[b]!));

    final slotDescs = <RenderGraphTextureDesc3D>[];
    final slotLastUse = <int>[];
    final resourceToSlot = <int, int>{};

    for (final resId in transientIds) {
      final res = _resources[resId];
      final start = firstUse[resId]!;
      final end = lastUse[resId]!;

      var reusedSlot = -1;
      for (var s = 0; s < slotDescs.length; s++) {
        if (slotDescs[s] == res.descriptor && slotLastUse[s] < start) {
          reusedSlot = s;
          break;
        }
      }
      if (reusedSlot >= 0) {
        slotLastUse[reusedSlot] = end;
        resourceToSlot[resId] = reusedSlot;
      } else {
        final newSlot = slotDescs.length;
        slotDescs.add(res.descriptor);
        slotLastUse.add(end);
        resourceToSlot[resId] = newSlot;
      }
    }

    return CompiledRenderGraph3D(
      executionOrder: List.unmodifiable(executionOrder),
      culledPasses: List.unmodifiable([
        for (var i = 0; i < n; i++)
          if (!live[i]) _passes[i],
      ]),
      virtualTextureCount: transientIds.length,
      physicalTargetCount: slotDescs.length,
      resourceToPhysicalSlot: Map.unmodifiable(resourceToSlot),
      physicalSlotDescriptors: List.unmodifiable(slotDescs),
    );
  }

  void _releaseUnusedTargets(Map<RenderGraphTextureDesc3D, int> used) {
    final execution = ++_executions;
    _targetPool.removeWhere((desc, targets) {
      final count = used[desc];
      if (count != null) {
        _targetLastUsed[desc] = execution;
        if (count < targets.length) {
          targets.removeRange(count, targets.length);
        }
        return false;
      }
      final lastUsed = _targetLastUsed[desc] ?? execution;
      if (execution - lastUsed < targetRetainExecutions) {
        return false;
      }
      _targetLastUsed.remove(desc);
      return true;
    });
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

    final usedPerDesc = <RenderGraphTextureDesc3D, int>{};
    final slotTargets = <GpuTextureTarget>[];
    for (final desc in plan.physicalSlotDescriptors) {
      final list = _targetPool.putIfAbsent(desc, () => <GpuTextureTarget>[]);
      final idx = usedPerDesc[desc] ?? 0;
      if (idx < list.length) {
        slotTargets.add(list[idx]);
      } else {
        final created = device.backend.createTextureTarget(
          width: desc.width,
          height: desc.height,
          format: desc.format,
          clearValue: desc.clearValue,
        );
        list.add(created);
        slotTargets.add(created);
      }
      usedPerDesc[desc] = idx + 1;
    }
    _releaseUnusedTargets(usedPerDesc);

    final resolved = <int, GpuTextureTarget>{
      ..._importedTargets,
      for (final MapEntry(:key, :value) in plan.resourceToPhysicalSlot.entries)
        key: slotTargets[value],
    };

    final ctx = RenderGraphPassContext3D(
      device: device,
      renderContext: renderContext,
      resolvedTargets: resolved,
    );
    for (final pass in plan.executionOrder) {
      pass.execute(ctx);
    }
    return plan;
  }
}

/// Injection stage for a user-supplied [CustomRenderPass3D] on `World3D`.
enum CustomRenderPassStage3D() {
  /// Runs after shadow & depth-normal prepasses, right before the main scene
  /// pass begins.
  beforeScene,

  /// Runs after the main 3D scene pass has finished, before the
  /// post-processing composite: [CustomRenderPassContext3D.sceneTarget] holds
  /// the scene, which a pass reads, or draws over with
  /// `device.beginTexturePass(sceneTarget, keepContents: true)`.
  afterScene,
}

/// Context passed to a [CustomRenderPass3D] registered in
/// `World3D.customPasses`.
class CustomRenderPassContext3D({
  required final GraphicsDevice device,
  required final RenderContext3D renderContext,
  required final int width,
  required final int height,

  /// The scene's texture target, for [CustomRenderPassStage3D.afterScene]
  /// passes. Begin a pass on it with `keepContents: true` to draw over the
  /// scene: without it the pass clears the scene.
  final GpuTextureTarget? sceneTarget,
  final Texture? depthNormalTexture,
});

/// User-defined GPU render pass hook executed by `World3D` during frame
/// rendering.
class CustomRenderPass3D({
  required final String name,
  required final void Function(CustomRenderPassContext3D context) execute,
  final CustomRenderPassStage3D stage = CustomRenderPassStage3D.afterScene,
  var bool enabled = true,
});
