import 'dart:math' as math;
import 'dart:typed_data';

/// Unit allegiance occupying a tactical grid cell during movement solving.
enum TacticalOccupant() {
  /// Unoccupied tile.
  none,

  /// Friendly unit: moving actor may traverse through this tile, but cannot
  /// end its move on it.
  ally,

  /// Hostile unit: blocks movement and exerts cardinal Zone of Control (ZOC)
  /// unless bypassed by a stealth/acrobat passive.
  enemy,
}

/// Zero-allocation Tactical RPG movement range, elevation, Zone-of-Control
/// (ZOC), ally pass-through, and threat-fringe solver (Fire Emblem / Tactics
/// Ogre / Triangle Strategy style).
class TacticalRangeSolver({
  required this.width,
  required this.height,
}) {
  this : assert(width > 0 && height > 0, 'Grid dimensions must be > 0.');

  /// Tactical grid column count.
  final int width;

  /// Tactical grid row count.
  final int height;

  final Float64List _bestCost = Float64List(width * height);
  final Int32List _parentIndex = Int32List(width * height);
  final Uint8List _flags = Uint8List(width * height);
  Int32List _heapCells = Int32List(width * height + 4);
  Float64List _heapCosts = Float64List(width * height + 4);
  int _heapSize = 0;

  static const int _flagVisited = 1 << 0;
  static const int _flagStandable = 1 << 1;
  static const int _flagAttackFringe = 1 << 2;

  static const List<int> _dirDx = <int>[0, 1, 0, -1];
  static const List<int> _dirDy = <int>[-1, 0, 1, 0];

  /// Packs `(col, row)` into `row * width + col`.
  int packCell(int col, int row) => row * width + col;

  /// Unpacks column from a packed cell index.
  int unpackCol(int packed) => packed % width;

  /// Unpacks row from a packed cell index.
  int unpackRow(int packed) => packed ~/ width;

  /// Returns `true` if `(col, row)` is inside `[0..width) x [0..height)`.
  bool inBounds(int col, int row) =>
      col >= 0 && col < width && row >= 0 && row < height;

  /// Solves reachable movement destinations and optional red attack-threat
  /// fringe around `(startCol, startRow)` within [moveBudget].
  ///
  /// - [stepCost]: terrain movement cost for entering `(col, row)`. Return
  ///   `double.infinity` (or `<= 0`) for impassable walls/chasms.
  /// - [elevationAt]: integer height level of `(col, row)` tested against
  ///   [maxClimb] (going up) and [maxDrop] (jumping down).
  /// - [occupantAt]: returns [TacticalOccupant.ally] (passable, non-standable)
  ///   or [TacticalOccupant.enemy] (impassable + cardinal ZOC).
  /// - [enableZoneOfControl]: when `true`, stepping onto a tile adjacent to any
  ///   enemy consumes all remaining [moveBudget], pinning the unit there.
  void solve({
    required int startCol,
    required int startRow,
    required double moveBudget,
    double Function(int col, int row)? stepCost,
    int Function(int col, int row)? elevationAt,
    TacticalOccupant Function(int col, int row)? occupantAt,
    bool Function(int fromCol, int fromRow, int dirIndex)? canStepEdge,
    int maxClimb = 999,
    int maxDrop = 999,
    bool enableZoneOfControl = true,
    bool ignoreEnemyBlock = false,
    int minAttackRange = 0,
    int maxAttackRange = 0,
  }) {
    final total = width * height;
    _bestCost.fillRange(0, total, double.infinity);
    _parentIndex.fillRange(0, total, -1);
    _flags.fillRange(0, total, 0);
    _heapSize = 0;

    if (!inBounds(startCol, startRow) || moveBudget < 0.0) {
      return;
    }

    final startIdx = packCell(startCol, startRow);
    _bestCost[startIdx] = 0.0;
    _flags[startIdx] = _flagVisited | _flagStandable;
    _heapPush(startIdx, 0.0);

    bool isInEnemyZoc(int col, int row) {
      if (!enableZoneOfControl || occupantAt == null) {
        return false;
      }
      for (var d = 0; d < 4; d++) {
        final nx = col + _dirDx[d];
        final ny = row + _dirDy[d];
        if (inBounds(nx, ny) && occupantAt(nx, ny) == TacticalOccupant.enemy) {
          return true;
        }
      }
      return false;
    }

    while (_heapSize > 0) {
      final curCost = _heapCosts[0];
      final curIdx = _heapCells[0];
      _heapPop();

      if (curCost > _bestCost[curIdx] + 1e-9) {
        continue;
      }
      if (curCost >= moveBudget - 1e-9) {
        continue;
      }

      final cx = curIdx % width;
      final cy = curIdx ~/ width;
      final curElev = elevationAt?.call(cx, cy) ?? 0;

      for (var d = 0; d < 4; d++) {
        if (canStepEdge != null && !canStepEdge(cx, cy, d)) {
          continue;
        }
        final nx = cx + _dirDx[d];
        final ny = cy + _dirDy[d];
        if (!inBounds(nx, ny)) {
          continue;
        }

        if (elevationAt != null) {
          final nextElev = elevationAt(nx, ny);
          final deltaElev = nextElev - curElev;
          if (deltaElev > maxClimb || -deltaElev > maxDrop) {
            continue;
          }
        }

        final occ = occupantAt?.call(nx, ny) ?? TacticalOccupant.none;
        if (occ == TacticalOccupant.enemy && !ignoreEnemyBlock) {
          continue;
        }

        final rawStep = stepCost?.call(nx, ny) ?? 1.0;
        if (rawStep <= 0.0 || rawStep.isInfinite || rawStep.isNaN) {
          continue;
        }

        var nextCost = curCost + rawStep;
        if (nextCost > moveBudget + 1e-9) {
          continue;
        }

        // Entering an enemy's cardinal Zone of Control consumes all remaining
        // movement budget so the unit cannot keep running past the defender!
        if (isInEnemyZoc(nx, ny) && nextCost < moveBudget) {
          nextCost = moveBudget;
        }

        final nextIdx = ny * width + nx;
        if (nextCost < _bestCost[nextIdx] - 1e-9) {
          _bestCost[nextIdx] = nextCost;
          _parentIndex[nextIdx] = curIdx;
          var cellFlags = _flagVisited;
          if (occ == TacticalOccupant.none) {
            cellFlags |= _flagStandable;
          }
          _flags[nextIdx] = cellFlags;
          _heapPush(nextIdx, nextCost);
        }
      }
    }

    // Compute attack threat fringe from all standable blue tiles!
    if (maxAttackRange > 0 && maxAttackRange >= minAttackRange) {
      final effMin = math.max(1, minAttackRange);
      for (var idx = 0; idx < total; idx++) {
        if ((_flags[idx] & _flagStandable) == 0) {
          continue;
        }
        final sx = idx % width;
        final sy = idx ~/ width;
        for (var dy = -maxAttackRange; dy <= maxAttackRange; dy++) {
          final ty = sy + dy;
          if (ty < 0 || ty >= height) {
            continue;
          }
          final rem = maxAttackRange - dy.abs();
          for (var dx = -rem; dx <= rem; dx++) {
            final dist = dx.abs() + dy.abs();
            if (dist < effMin) {
              continue;
            }
            final tx = sx + dx;
            if (tx >= 0 && tx < width) {
              _flags[ty * width + tx] |= _flagAttackFringe;
            }
          }
        }
      }
    }
  }

  /// Whether the unit can traverse through `(col, row)` (including ally tiles).
  bool canTraverse(int col, int row) =>
      inBounds(col, row) && (_flags[row * width + col] & _flagVisited) != 0;

  /// Whether the unit can legally end its move on `(col, row)` (blue move
  /// highlight; excludes ally-occupied tiles).
  bool canStandAt(int col, int row) =>
      inBounds(col, row) && (_flags[row * width + col] & _flagStandable) != 0;

  /// Whether `(col, row)` can be targeted by an attack from at least one
  /// standable destination tile.
  bool isInAttackRange(int col, int row) =>
      inBounds(col, row) &&
      (_flags[row * width + col] & _flagAttackFringe) != 0;

  /// Red border fringe: attackable tiles that are NOT themselves standable move
  /// tiles.
  bool isAttackFringeOnly(int col, int row) =>
      isInAttackRange(col, row) && !canStandAt(col, row);

  /// Minimum movement cost required to reach `(col, row)` (`double.infinity` if
  /// unreachable).
  double costTo(int col, int row) =>
      inBounds(col, row) ? _bestCost[row * width + col] : double.infinity;

  /// Reconstructs the shortest packed-cell path from `(startCol, startRow)` to
  /// standable destination `(destCol, destRow)` into [outPackedPath].
  ///
  /// Returns `true` if `(destCol, destRow)` is a valid standable destination.
  bool reconstructPath(int destCol, int destRow, List<int> outPackedPath) {
    outPackedPath.clear();
    if (!canStandAt(destCol, destRow)) {
      return false;
    }
    var cur = packCell(destCol, destRow);
    while (cur >= 0) {
      outPackedPath.add(cur);
      cur = _parentIndex[cur];
    }
    var left = 0;
    var right = outPackedPath.length - 1;
    while (left < right) {
      final tmp = outPackedPath[left];
      outPackedPath[left] = outPackedPath[right];
      outPackedPath[right] = tmp;
      left++;
      right--;
    }
    return true;
  }

  void _heapPush(int cellIdx, double cost) {
    if (_heapSize >= _heapCells.length) {
      final cap = _heapCells.length * 2;
      _heapCells = Int32List(cap)..setRange(0, _heapSize, _heapCells);
      _heapCosts = Float64List(cap)..setRange(0, _heapSize, _heapCosts);
    }
    var i = _heapSize++;
    while (i > 0) {
      final parent = (i - 1) >> 1;
      if (_heapCosts[parent] <= cost) {
        break;
      }
      _heapCells[i] = _heapCells[parent];
      _heapCosts[i] = _heapCosts[parent];
      i = parent;
    }
    _heapCells[i] = cellIdx;
    _heapCosts[i] = cost;
  }

  void _heapPop() {
    _heapSize--;
    if (_heapSize <= 0) {
      return;
    }
    final lastCell = _heapCells[_heapSize];
    final lastCost = _heapCosts[_heapSize];
    var i = 0;
    final half = _heapSize >> 1;
    while (i < half) {
      var child = (i << 1) + 1;
      final right = child + 1;
      if (right < _heapSize && _heapCosts[right] < _heapCosts[child]) {
        child = right;
      }
      if (lastCost <= _heapCosts[child]) {
        break;
      }
      _heapCells[i] = _heapCells[child];
      _heapCosts[i] = _heapCosts[child];
      i = child;
    }
    _heapCells[i] = lastCell;
    _heapCosts[i] = lastCost;
  }
}
