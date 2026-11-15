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

/// Geometric shape family for [GridAreaTemplate] spell/skill AoE targeting.
enum AoEShapeKind() {
  /// Filled or hollow Manhattan diamond (`|dx| + |dy| in [minRadius..radius]`).
  diamond,

  /// Hollow Manhattan ring (`minRadius <= |dx| + |dy| <= radius`).
  ring,

  /// Orthogonal `+` cross centered on target (arms optionally blocked by
  /// walls).
  cross,

  /// Chebyshev square (`max(|dx|, |dy|) in [minRadius..radius]`).
  square,

  /// Directional widening breath cone from `(originCol, originRow)` toward
  /// `(targetCol, targetRow)`.
  cone,

  /// Piercing line ray from `(originCol, originRow)` through
  /// `(targetCol, targetRow)` out to `radius`, stopping immediately at the
  /// first wall blocker.
  rayLine,

  /// Axial `(q, r)` hexagonal radius (`(|dq| + |dr| + |dq + dr|) / 2 <= r`).
  hexRadius,
}

/// Evaluates tactical spell, breath, spear, and grenade Area-of-Effect (AoE)
/// footprints with optional wall/pillar line occlusion.
class const GridAreaTemplate({
  required this.kind,
  required this.radius,
  this.minRadius = 0,
  this.stopsAtWalls = false,
}) {
  this
    : assert(radius >= 0, 'radius must be >= 0.'),
      assert(minRadius >= 0, 'minRadius must be >= 0.');

  /// AoE geometric template type.
  final AoEShapeKind kind;

  /// Outer extent in grid tiles.
  final int radius;

  /// Inner dead-zone exclusion radius (e.g. mortar `minRadius: 2`).
  final int minRadius;

  /// Whether wall blockers (`isWallBlocked`) stop `rayLine` / `cross` / `cone`
  /// propagation.
  final bool stopsAtWalls;

  /// Populates [outCells] with affected `(col, row)` records clipped to
  /// `[0..gridWidth) x [0..gridHeight)`.
  void collectCells({
    required int originCol,
    required int originRow,
    required int targetCol,
    required int targetRow,
    required int gridWidth,
    required int gridHeight,
    required List<({int col, int row})> outCells,
    bool Function(int col, int row)? isWallBlocked,
  }) {
    outCells.clear();
    bool inBounds(int c, int r) =>
        c >= 0 && c < gridWidth && r >= 0 && r < gridHeight;

    switch (kind) {
      case AoEShapeKind.diamond:
      case AoEShapeKind.ring:
        final effMin = kind == AoEShapeKind.ring
            ? math.max(1, minRadius)
            : minRadius;
        for (var dy = -radius; dy <= radius; dy++) {
          final r = targetRow + dy;
          if (r < 0 || r >= gridHeight) {
            continue;
          }
          final rem = radius - dy.abs();
          for (var dx = -rem; dx <= rem; dx++) {
            final d = dx.abs() + dy.abs();
            if (d < effMin) {
              continue;
            }
            final c = targetCol + dx;
            if (c >= 0 && c < gridWidth) {
              if (stopsAtWalls && (isWallBlocked?.call(c, r) ?? false)) {
                continue;
              }
              outCells.add((col: c, row: r));
            }
          }
        }

      case AoEShapeKind.square:
        for (var dy = -radius; dy <= radius; dy++) {
          for (var dx = -radius; dx <= radius; dx++) {
            final cheb = math.max(dx.abs(), dy.abs());
            if (cheb < minRadius) {
              continue;
            }
            final c = targetCol + dx;
            final r = targetRow + dy;
            if (inBounds(c, r)) {
              if (stopsAtWalls && (isWallBlocked?.call(c, r) ?? false)) {
                continue;
              }
              outCells.add((col: c, row: r));
            }
          }
        }

      case AoEShapeKind.cross:
        if (minRadius == 0 && inBounds(targetCol, targetRow)) {
          if (!stopsAtWalls ||
              !(isWallBlocked?.call(targetCol, targetRow) ?? false)) {
            outCells.add((col: targetCol, row: targetRow));
          }
        }
        const dirs = <({int dx, int dy})>[
          (dx: 0, dy: -1),
          (dx: 1, dy: 0),
          (dx: 0, dy: 1),
          (dx: -1, dy: 0),
        ];
        for (final dir in dirs) {
          for (var step = 1; step <= radius; step++) {
            final c = targetCol + dir.dx * step;
            final r = targetRow + dir.dy * step;
            if (!inBounds(c, r)) {
              break;
            }
            if (stopsAtWalls && (isWallBlocked?.call(c, r) ?? false)) {
              break;
            }
            if (step >= minRadius) {
              outCells.add((col: c, row: r));
            }
          }
        }

      case AoEShapeKind.cone:
        final vx = targetCol - originCol;
        final vy = targetRow - originRow;
        final int dirX;
        final int dirY;
        if (vx.abs() >= vy.abs()) {
          dirX = vx >= 0 ? 1 : -1;
          dirY = 0;
        } else {
          dirX = 0;
          dirY = vy >= 0 ? 1 : -1;
        }
        final perpX = -dirY;
        final perpY = dirX;
        for (var depth = math.max(1, minRadius); depth <= radius; depth++) {
          final spread = depth - 1;
          for (var lat = -spread; lat <= spread; lat++) {
            final c = originCol + dirX * depth + perpX * lat;
            final r = originRow + dirY * depth + perpY * lat;
            if (!inBounds(c, r)) {
              continue;
            }
            if (stopsAtWalls && (isWallBlocked?.call(c, r) ?? false)) {
              continue;
            }
            outCells.add((col: c, row: r));
          }
        }

      case AoEShapeKind.rayLine:
        final dx = targetCol - originCol;
        final dy = targetRow - originRow;
        if (dx == 0 && dy == 0) {
          if (minRadius == 0 && inBounds(originCol, originRow)) {
            outCells.add((col: originCol, row: originRow));
          }
          return;
        }
        final len = math.sqrt(dx * dx + dy * dy);
        final ux = dx / len;
        final uy = dy / len;
        var prevC = originCol;
        var prevR = originRow;
        // Sample along the ray in 0.5-tile increments up to `radius` tiles,
        // deduplicating integer cells and halting immediately on wall impact.
        final maxSteps = math.max(1, radius * 4);
        for (var s = 1; s <= maxSteps; s++) {
          final dist = (s * radius) / maxSteps;
          final c = (originCol + ux * dist).round();
          final r = (originRow + uy * dist).round();
          if (c == prevC && r == prevR) {
            continue;
          }
          prevC = c;
          prevR = r;
          if (!inBounds(c, r)) {
            break;
          }
          if (stopsAtWalls && (isWallBlocked?.call(c, r) ?? false)) {
            break;
          }
          final manhattanOrCheb = math.max(
            (c - originCol).abs(),
            (r - originRow).abs(),
          );
          if (manhattanOrCheb >= minRadius) {
            final exists = outCells.any((e) => e.col == c && e.row == r);
            if (!exists) {
              outCells.add((col: c, row: r));
            }
          }
        }

      case AoEShapeKind.hexRadius:
        for (var dq = -radius; dq <= radius; dq++) {
          final minDr = math.max(-radius, -dq - radius);
          final maxDr = math.min(radius, -dq + radius);
          for (var dr = minDr; dr <= maxDr; dr++) {
            final cubeDist = (dq.abs() + dr.abs() + (dq + dr).abs()) ~/ 2;
            if (cubeDist < minRadius) {
              continue;
            }
            final q = targetCol + dq;
            final r = targetRow + dr;
            if (inBounds(q, r)) {
              if (stopsAtWalls && (isWallBlocked?.call(q, r) ?? false)) {
                continue;
              }
              outCells.add((col: q, row: r));
            }
          }
        }
    }
  }
}
