class const _GraphEdge<N>(final N to, final double cost);

/// Generic directed/undirected weighted graph pathfinder & exact-step
/// reachability solver (ideal for branching board-game tracks, portals,
/// shortcuts, and waypoint networks).
class GraphPathfinder<N>() {
  final Map<N, List<_GraphEdge<N>>> _adj = <N, List<_GraphEdge<N>>>{};

  /// Registers [node] if absent.
  void addNode(N node) {
    _adj.putIfAbsent(node, () => <_GraphEdge<N>>[]);
  }

  /// Adds a one-way directed edge `from -> to` with traversal [cost].
  void addDirectedEdge(N from, N to, {double cost = 1.0}) {
    addNode(from);
    addNode(to);
    _adj[from]!.add(_GraphEdge<N>(to, cost));
  }

  /// Adds a two-way bidirectional edge `a <-> b` with traversal [cost].
  void addBidirectionalEdge(N a, N b, {double cost = 1.0}) {
    addDirectedEdge(a, b, cost: cost);
    addDirectedEdge(b, a, cost: cost);
  }

  /// Outgoing neighbor nodes directly reachable in 1 step from [node].
  Iterable<N> outgoingOf(N node) sync* {
    final edges = _adj[node];
    if (edges != null) {
      for (var i = 0; i < edges.length; i++) {
        yield edges[i].to;
      }
    }
  }

  /// Computes all distinct destination nodes reachable in **exact** [steps]
  /// hops from [start] along directed edges (useful for branching dice-movement
  /// previews!).
  Set<N> reachableInExactSteps(N start, int steps) {
    if (steps <= 0) {
      return <N>{start};
    }
    var frontier = <N>{start};
    for (var s = 0; s < steps; s++) {
      final next = <N>{};
      for (final node in frontier) {
        final edges = _adj[node];
        if (edges != null) {
          for (var i = 0; i < edges.length; i++) {
            next.add(edges[i].to);
          }
        }
      }
      frontier = next;
      if (frontier.isEmpty) {
        break;
      }
    }
    return frontier;
  }

  /// Finds the minimum-cost path from [start] to [goal] via Dijkstra / A*,
  /// writing nodes into [outPath] and returning `true` if reachable.
  bool findShortestPath(
    N start,
    N goal,
    List<N> outPath, {
    double Function(N a, N b)? heuristic,
  }) {
    outPath.clear();
    if (!_adj.containsKey(start) || !_adj.containsKey(goal)) {
      return false;
    }
    if (start == goal) {
      outPath.add(start);
      return true;
    }

    final gScore = <N, double>{start: 0.0};
    final fScore = <N, double>{
      start: heuristic != null ? heuristic(start, goal) : 0.0,
    };
    final parent = <N, N>{};
    final open = <N>[start];
    final closed = <N>{};

    while (open.isNotEmpty) {
      var bestIdx = 0;
      var bestF = fScore[open[0]] ?? double.infinity;
      for (var i = 1; i < open.length; i++) {
        final f = fScore[open[i]] ?? double.infinity;
        if (f < bestF) {
          bestF = f;
          bestIdx = i;
        }
      }
      final curr = open.removeAt(bestIdx);
      if (curr == goal) {
        var cursor = goal;
        while (true) {
          outPath.add(cursor);
          final prev = parent[cursor];
          if (prev == null) {
            break;
          }
          cursor = prev;
        }
        for (var l = 0, r = outPath.length - 1; l < r; l++, r--) {
          final tmp = outPath[l];
          outPath[l] = outPath[r];
          outPath[r] = tmp;
        }
        return true;
      }
      closed.add(curr);

      final edges = _adj[curr];
      if (edges == null) {
        continue;
      }
      final currG = gScore[curr]!;
      for (var i = 0; i < edges.length; i++) {
        final edge = edges[i];
        if (closed.contains(edge.to)) {
          continue;
        }
        final tentative = currG + edge.cost;
        final prevG = gScore[edge.to];
        if (prevG == null || tentative < prevG) {
          parent[edge.to] = curr;
          gScore[edge.to] = tentative;
          fScore[edge.to] =
              tentative + (heuristic != null ? heuristic(edge.to, goal) : 0.0);
          if (!open.contains(edge.to)) {
            open.add(edge.to);
          }
        }
      }
    }
    return false;
  }
}
