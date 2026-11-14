import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame/src/grid/grid_topology.dart';
import 'package:vector_math/vector_math.dart';

/// Zero-allocation A* grid pathfinder over pre-allocated `Float32List` /
/// `Int32List` / `Uint8List` buffers with stamp-invalidated search state,
/// weighted terrain costs, and optional anti-corner-cutting 8-way diagonals.
class AStarGridPathfinder({
  required final int width,
  required final int height,
  var bool allowDiagonal = false,
  var bool preventCornerCutting = true,
}) {
  final Uint8List _blocked = Uint8List(width * height);
  final Float32List _weights = Float32List(width * height)
    ..fillRange(0, width * height, 1.0);
  final Float32List _gScore = Float32List(width * height);
  final Float32List _fScore = Float32List(width * height);
  final Int32List _parent = Int32List(width * height);
  final Int32List _stateStamp = Int32List(width * height);
  final Int32List _heapNodes = Int32List(width * height);
  final Int32List _heapIndex = Int32List(width * height);

  int _currentStamp = 0;
  int _heapSize = 0;

  static const double _sqrt2 = 1.4142135623730951;

  /// Whether `(col, row)` lies inside `[0, width) * [0, height)`.
  bool inBounds(int col, int row) =>
      col >= 0 && col < width && row >= 0 && row < height;

  /// Marks `(col, row)` as impassable (`blocked = true`) or passable (`false`).
  void setBlocked(int col, int row, {required bool blocked}) {
    if (inBounds(col, row)) {
      _blocked[row * width + col] = blocked ? 1 : 0;
    }
  }

  /// Returns `true` if `(col, row)` is out-of-bounds or marked blocked.
  bool isBlocked(int col, int row) =>
      !inBounds(col, row) || _blocked[row * width + col] != 0;

  /// Sets positive traversal cost multiplier (`>= 1.0` for mud/forest, `< 1.0`
  /// for roads) at `(col, row)`.
  void setCellWeight(int col, int row, double weight) {
    if (inBounds(col, row) && weight > 0.0) {
      _weights[row * width + col] = weight;
    }
  }

  /// Clears all obstacles and resets cell weights to `1.0`.
  void resetGrid() {
    _blocked.fillRange(0, _blocked.length, 0);
    _weights.fillRange(0, _weights.length, 1.0);
  }

  /// Computes a shortest path from [start] to [goal] (including both endpoints)
  /// into [outPath] with **zero** internal heap allocations, returning `true`
  /// when a path exists.
  bool findPath(GridCell start, GridCell goal, List<GridCell> outPath) {
    outPath.clear();
    if (!inBounds(start.col, start.row) || !inBounds(goal.col, goal.row)) {
      return false;
    }
    if (isBlocked(goal.col, goal.row)) {
      return false;
    }
    if (start.col == goal.col && start.row == goal.row) {
      outPath.add(start);
      return true;
    }

    // Advance stamp by 2: `stamp + 1` = open, `stamp + 2` = closed.
    _currentStamp += 2;
    if (_currentStamp >= 0x7FFFFFF0) {
      _stateStamp.fillRange(0, _stateStamp.length, 0);
      _currentStamp = 2;
    }
    final openTag = _currentStamp;
    final closedTag = _currentStamp + 1;

    _heapSize = 0;
    final startIdx = start.row * width + start.col;
    final goalIdx = goal.row * width + goal.col;

    _gScore[startIdx] = 0.0;
    _fScore[startIdx] = _heuristic(start.col, start.row, goal.col, goal.row);
    _parent[startIdx] = -1;
    _stateStamp[startIdx] = openTag;
    _heapPush(startIdx);

    while (_heapSize > 0) {
      final curr = _heapPop();
      if (curr == goalIdx) {
        _reconstructPath(curr, start.elevation, outPath);
        return true;
      }
      _stateStamp[curr] = closedTag;

      final cx = curr % width;
      final cy = curr ~/ width;
      final baseG = _gScore[curr];

      // 4 cardinal neighbors.
      _relaxNeighbor(cx + 1, cy, curr, baseG, 1.0, goal, openTag, closedTag);
      _relaxNeighbor(cx - 1, cy, curr, baseG, 1.0, goal, openTag, closedTag);
      _relaxNeighbor(cx, cy + 1, curr, baseG, 1.0, goal, openTag, closedTag);
      _relaxNeighbor(cx, cy - 1, curr, baseG, 1.0, goal, openTag, closedTag);

      if (allowDiagonal) {
        final nOpen = !isBlocked(cx, cy - 1);
        final sOpen = !isBlocked(cx, cy + 1);
        final eOpen = !isBlocked(cx + 1, cy);
        final wOpen = !isBlocked(cx - 1, cy);

        if (!preventCornerCutting || (nOpen && eOpen)) {
          _relaxNeighbor(
            cx + 1,
            cy - 1,
            curr,
            baseG,
            _sqrt2,
            goal,
            openTag,
            closedTag,
          );
        }
        if (!preventCornerCutting || (sOpen && eOpen)) {
          _relaxNeighbor(
            cx + 1,
            cy + 1,
            curr,
            baseG,
            _sqrt2,
            goal,
            openTag,
            closedTag,
          );
        }
        if (!preventCornerCutting || (sOpen && wOpen)) {
          _relaxNeighbor(
            cx - 1,
            cy + 1,
            curr,
            baseG,
            _sqrt2,
            goal,
            openTag,
            closedTag,
          );
        }
        if (!preventCornerCutting || (nOpen && wOpen)) {
          _relaxNeighbor(
            cx - 1,
            cy - 1,
            curr,
            baseG,
            _sqrt2,
            goal,
            openTag,
            closedTag,
          );
        }
      }
    }
    return false;
  }

  void _relaxNeighbor(
    int nx,
    int ny,
    int currIdx,
    double baseG,
    double stepDist,
    GridCell goal,
    int openTag,
    int closedTag,
  ) {
    if (isBlocked(nx, ny)) {
      return;
    }
    final nIdx = ny * width + nx;
    final state = _stateStamp[nIdx];
    if (state == closedTag) {
      return;
    }
    final tentativeG = baseG + stepDist * _weights[nIdx];
    if (state != openTag || tentativeG < _gScore[nIdx]) {
      _parent[nIdx] = currIdx;
      _gScore[nIdx] = tentativeG;
      _fScore[nIdx] = tentativeG + _heuristic(nx, ny, goal.col, goal.row);
      if (state == openTag) {
        _siftUp(_heapIndex[nIdx]);
      } else {
        _stateStamp[nIdx] = openTag;
        _heapPush(nIdx);
      }
    }
  }

  double _heuristic(int x0, int y0, int x1, int y1) {
    final dx = (x0 - x1).abs().toDouble();
    final dy = (y0 - y1).abs().toDouble();
    if (!allowDiagonal) {
      return dx + dy;
    }
    // Octile heuristic.
    return (dx + dy) + (_sqrt2 - 2.0) * math.min(dx, dy);
  }

  void _reconstructPath(int goalIdx, int elevation, List<GridCell> out) {
    var cursor = goalIdx;
    while (cursor >= 0) {
      out.add(GridCell(cursor % width, cursor ~/ width, elevation));
      cursor = _parent[cursor];
    }
    // Reverse in place.
    for (var l = 0, r = out.length - 1; l < r; l++, r--) {
      final tmp = out[l];
      out[l] = out[r];
      out[r] = tmp;
    }
  }

  void _heapPush(int node) {
    final pos = _heapSize++;
    _heapNodes[pos] = node;
    _heapIndex[node] = pos;
    _siftUp(pos);
  }

  int _heapPop() {
    final top = _heapNodes[0];
    _heapSize--;
    if (_heapSize > 0) {
      final moved = _heapNodes[_heapSize];
      _heapNodes[0] = moved;
      _heapIndex[moved] = 0;
      _siftDown(0);
    }
    return top;
  }

  void _siftUp(int pos) {
    var idx = pos;
    final node = _heapNodes[idx];
    final score = _fScore[node];
    while (idx > 0) {
      final parentPos = (idx - 1) >> 1;
      final parentNode = _heapNodes[parentPos];
      if (score >= _fScore[parentNode]) {
        break;
      }
      _heapNodes[idx] = parentNode;
      _heapIndex[parentNode] = idx;
      idx = parentPos;
    }
    _heapNodes[idx] = node;
    _heapIndex[node] = idx;
  }

  void _siftDown(int pos) {
    var idx = pos;
    final node = _heapNodes[idx];
    final score = _fScore[node];
    final half = _heapSize >> 1;
    while (idx < half) {
      var child = (idx << 1) + 1;
      final right = child + 1;
      if (right < _heapSize &&
          _fScore[_heapNodes[right]] < _fScore[_heapNodes[child]]) {
        child = right;
      }
      final childNode = _heapNodes[child];
      if (score <= _fScore[childNode]) {
        break;
      }
      _heapNodes[idx] = childNode;
      _heapIndex[childNode] = idx;
      idx = child;
    }
    _heapNodes[idx] = node;
    _heapIndex[node] = idx;
  }
}

class const _GraphEdge<N>(final N to, final double cost);

/// Generic directed/undirected weighted graph pathfinder & exact-step reachability
/// solver (ideal for branching board-game tracks, portals, shortcuts, and
/// waypoint networks).
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

/// Zero-allocation 2D Dijkstra integration & normalized vector flow field
/// enabling hundreds of agents to steer around walls toward one or more goals
/// via `O(1)` cell lookups.
class FlowField2D({required final int width, required final int height}) {
  final Uint8List _blocked = Uint8List(width * height);
  final Float32List _integration = Float32List(width * height);
  final Float32List _dirX = Float32List(width * height);
  final Float32List _dirY = Float32List(width * height);
  final Int32List _queue = Int32List(width * height);

  /// Marks `(col, row)` as blocked or passable.
  void setBlocked(int col, int row, {required bool blocked}) {
    if (col >= 0 && col < width && row >= 0 && row < height) {
      _blocked[row * width + col] = blocked ? 1 : 0;
    }
  }

  /// Bakes the integration cost field and normalized flow vectors toward
  /// [goals].
  void bake(Iterable<GridCell> goals) {
    final len = width * height;
    _integration.fillRange(0, len, double.infinity);
    _dirX.fillRange(0, len, 0.0);
    _dirY.fillRange(0, len, 0.0);

    var head = 0;
    var tail = 0;
    for (final g in goals) {
      if (g.col >= 0 && g.col < width && g.row >= 0 && g.row < height) {
        final idx = g.row * width + g.col;
        if (_blocked[idx] == 0 && _integration[idx].isInfinite) {
          _integration[idx] = 0.0;
          _queue[tail++] = idx;
        }
      }
    }

    // 4-way BFS wave propagation.
    while (head < tail) {
      final curr = _queue[head++];
      final cx = curr % width;
      final cy = curr ~/ width;
      final nextCost = _integration[curr] + 1.0;

      void tryEnqueue(int nx, int ny) {
        if (nx < 0 || nx >= width || ny < 0 || ny >= height) {
          return;
        }
        final nIdx = ny * width + nx;
        if (_blocked[nIdx] != 0 || nextCost >= _integration[nIdx]) {
          return;
        }
        _integration[nIdx] = nextCost;
        _queue[tail++] = nIdx;
      }

      tryEnqueue(cx + 1, cy);
      tryEnqueue(cx - 1, cy);
      tryEnqueue(cx, cy + 1);
      tryEnqueue(cx, cy - 1);
    }

    // Compute steepest-descent unit vector across 8 neighbors.
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final idx = y * width + x;
        final selfCost = _integration[idx];
        if (!selfCost.isFinite || selfCost == 0.0) {
          continue;
        }
        var bestCost = selfCost;
        var vx = 0.0;
        var vy = 0.0;

        for (var dy = -1; dy <= 1; dy++) {
          for (var dx = -1; dx <= 1; dx++) {
            if (dx == 0 && dy == 0) {
              continue;
            }
            final nx = x + dx;
            final ny = y + dy;
            if (nx < 0 || nx >= width || ny < 0 || ny >= height) {
              continue;
            }
            // Guard diagonal corner-cutting around wall corners.
            if (dx != 0 && dy != 0) {
              if (_blocked[y * width + nx] != 0 ||
                  _blocked[ny * width + x] != 0) {
                continue;
              }
            }
            final c = _integration[ny * width + nx];
            if (c < bestCost) {
              bestCost = c;
              vx = dx.toDouble();
              vy = dy.toDouble();
            }
          }
        }
        final mag = math.sqrt(vx * vx + vy * vy);
        if (mag > 0.0) {
          _dirX[idx] = vx / mag;
          _dirY[idx] = vy / mag;
        }
      }
    }
  }

  /// Returns the integration distance at `(col, row)` (`double.infinity` if
  /// unreachable).
  double costAt(int col, int row) =>
      (col >= 0 && col < width && row >= 0 && row < height)
      ? _integration[row * width + col]
      : double.infinity;

  /// Writes the unit steering vector at `(col, row)` into [out].
  void sampleDirection(int col, int row, Vector2 out) {
    if (col < 0 || col >= width || row < 0 || row >= height) {
      out.setZero();
      return;
    }
    final idx = row * width + col;
    out.setValues(_dirX[idx], _dirY[idx]);
  }
}
