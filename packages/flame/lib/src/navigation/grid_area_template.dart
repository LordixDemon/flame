import 'dart:math' as math;

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
