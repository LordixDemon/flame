import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame/src/grid/grid_topology.dart';

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

  /// The lowest weight of any cell, which scales the heuristic so that it
  /// never overestimates the cost of the cheapest possible step.
  double _minWeight = 1.0;
  bool _minWeightDirty = false;

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
  ///
  /// Paths stay shortest for any mix of weights. The search is guided by the
  /// lowest weight on the grid, so a grid with a few very cheap cells explores
  /// more cells per search than one with uniform weights.
  void setCellWeight(int col, int row, double weight) {
    if (inBounds(col, row) && weight > 0.0) {
      _weights[row * width + col] = weight;
      _minWeightDirty = true;
    }
  }

  /// Clears all obstacles and resets cell weights to `1.0`.
  void resetGrid() {
    _blocked.fillRange(0, _blocked.length, 0);
    _weights.fillRange(0, _weights.length, 1.0);
    _minWeight = 1.0;
    _minWeightDirty = false;
  }

  void _refreshMinWeight() {
    if (!_minWeightDirty) {
      return;
    }
    var lowest = double.infinity;
    for (var i = 0; i < _weights.length; i++) {
      final weight = _weights[i];
      if (weight < lowest) {
        lowest = weight;
      }
    }
    _minWeight = lowest.isFinite ? lowest : 1.0;
    _minWeightDirty = false;
  }

  /// Computes a shortest path from [start] to [goal] (including both endpoints)
  /// into [outPath] with **zero** internal heap allocations, returning `true`
  /// when a path exists.
  ///
  /// When [allowBlockedStart] is `false` (default), a blocked [start] cell
  /// returns `false`; set [allowBlockedStart] to `true` when an agent needs to
  /// step off a cell that just became blocked.
  bool findPath(
    GridCell start,
    GridCell goal,
    List<GridCell> outPath, {
    bool allowBlockedStart = false,
  }) {
    outPath.clear();
    if (!inBounds(start.col, start.row) || !inBounds(goal.col, goal.row)) {
      return false;
    }
    if (isBlocked(goal.col, goal.row)) {
      return false;
    }
    if (!allowBlockedStart && isBlocked(start.col, start.row)) {
      return false;
    }
    if (start.col == goal.col && start.row == goal.row) {
      outPath.add(start);
      return true;
    }

    _refreshMinWeight();

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

  /// A lower bound of the cost from `(x0, y0)` to `(x1, y1)`: the number of
  /// steps on an empty grid, each at the lowest weight there is. Being a lower
  /// bound (and consistent) is what makes the first path found the shortest.
  double _heuristic(int x0, int y0, int x1, int y1) {
    final dx = (x0 - x1).abs().toDouble();
    final dy = (y0 - y1).abs().toDouble();
    if (!allowDiagonal) {
      return (dx + dy) * _minWeight;
    }
    // Octile heuristic.
    return ((dx + dy) + (_sqrt2 - 2.0) * math.min(dx, dy)) * _minWeight;
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
