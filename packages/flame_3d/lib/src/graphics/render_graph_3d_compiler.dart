part of 'render_graph_3d.dart';

class _RenderGraphPoolEntry(this.desc, this.backend, this.deviceGeneration) {
  final RenderGraphTextureDesc3D desc;
  final GpuBackend backend;
  final int deviceGeneration;
  final List<GpuTextureTarget> targets = [];
  int used = 0;
  int lastUsed = 0;
}

class _RenderGraphTargetPool() {
  final List<_RenderGraphPoolEntry> _pool = [];
  final List<GpuTextureTarget> slotTargets = [];
  int _executions = 0;

  _RenderGraphPoolEntry _poolEntryFor(
    RenderGraphTextureDesc3D desc,
    GpuBackend backend,
    int deviceGeneration,
  ) {
    for (var i = 0; i < _pool.length; i++) {
      final entry = _pool[i];
      if (entry.desc == desc &&
          identical(entry.backend, backend) &&
          entry.deviceGeneration == deviceGeneration) {
        return entry;
      }
    }
    final created = _RenderGraphPoolEntry(desc, backend, deviceGeneration);
    _pool.add(created);
    return created;
  }

  void acquireForPlan(
    CompiledRenderGraph3D plan,
    GpuBackend backend,
    int deviceGeneration,
  ) {
    final execution = ++_executions;
    for (var i = _pool.length - 1; i >= 0; i--) {
      final entry = _pool[i];
      if (!identical(entry.backend, backend) ||
          entry.deviceGeneration != deviceGeneration) {
        _pool.removeAt(i);
      } else {
        entry.used = 0;
      }
    }
    slotTargets.clear();
    final descs = plan.physicalSlotDescriptors;
    for (var i = 0; i < descs.length; i++) {
      final desc = descs[i];
      final entry = _poolEntryFor(desc, backend, deviceGeneration);
      final idx = entry.used++;
      entry.lastUsed = execution;
      final list = entry.targets;
      if (idx < list.length) {
        slotTargets.add(list[idx]);
      } else {
        final created = backend.createTextureTarget(
          width: desc.width,
          height: desc.height,
          format: desc.format,
          clearValue: desc.clearValue,
        );
        list.add(created);
        slotTargets.add(created);
      }
    }
    for (var i = _pool.length - 1; i >= 0; i--) {
      final entry = _pool[i];
      if (entry.used > 0) {
        if (entry.used < entry.targets.length) {
          entry.targets.removeRange(entry.used, entry.targets.length);
        }
      } else if (execution - entry.lastUsed >=
          RenderGraph3D.targetRetainExecutions) {
        _pool.removeAt(i);
      }
    }
  }
}

CompiledRenderGraph3D _compileRenderGraph(
  List<RenderGraphPass3D> passes,
  List<RenderGraphResourceHandle3D> resources,
  Set<int> outputs,
) {
  final n = passes.length;
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

  final writersOf = <int, List<int>>{};
  for (var i = 0; i < n; i++) {
    for (final w in passes[i].writes) {
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
    final writtenHere = {for (final w in passes[i].writes) w.id};
    for (final r in passes[i].reads) {
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
    final p = passes[i];
    final writesOutput = p.writes.any((w) => outputs.contains(w.id));
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

  final culledPasses = <RenderGraphPass3D>[
    for (var i = 0; i < n; i++)
      if (!live[i]) passes[i],
  ];
  final executionOrder = <RenderGraphPass3D>[
    for (final idx in topoAll)
      if (live[idx]) passes[idx],
  ];

  // Compute live `[firstUse, lastUse]` pass intervals for transient textures.
  final firstUse = <int, int>{};
  final lastUse = <int, int>{};
  for (var step = 0; step < executionOrder.length; step++) {
    final pass = executionOrder[step];
    for (final h in pass.writes) {
      if (!h.imported) {
        firstUse.putIfAbsent(h.id, () => step);
        lastUse[h.id] = outputs.contains(h.id) ? executionOrder.length : step;
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
    final res = resources[resId];
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
    culledPasses: List.unmodifiable(culledPasses),
    virtualTextureCount: transientIds.length,
    physicalTargetCount: slotDescs.length,
    resourceToPhysicalSlot: Map.unmodifiable(resourceToSlot),
    physicalSlotDescriptors: List.unmodifiable(slotDescs),
  );
}
