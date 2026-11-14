import 'dart:math' as math;

import 'package:meta/meta.dart';
import 'package:vector_math/vector_math.dart';

/// Discrete integer cell coordinate `(col, row)` with optional vertical
/// [elevation] layer.
@immutable
class const GridCell(
  this.col,
  this.row, [
  this.elevation = 0,
]) {
  /// Column (`x` / axial `q`) coordinate.
  final int col;

  /// Row (`y` / axial `r`) coordinate.
  final int row;

  /// Optional height / floor layer.
  final int elevation;

  /// Component-wise cell offset addition.
  GridCell operator +(GridCell other) => GridCell(
    col + other.col,
    row + other.row,
    elevation + other.elevation,
  );

  /// Component-wise cell offset subtraction.
  GridCell operator -(GridCell other) => GridCell(
    col - other.col,
    row - other.row,
    elevation - other.elevation,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GridCell &&
          col == other.col &&
          row == other.row &&
          elevation == other.elevation;

  @override
  int get hashCode => Object.hash(col, row, elevation);

  @override
  String toString() => elevation == 0
      ? 'GridCell($col, $row)'
      : 'GridCell($col, $row, z:$elevation)';
}

/// Orthogonal rectangular grid math (`world <-> cell`, distances, rings, and
/// Bresenham line-of-sight).
class SquareGridTopology({
  this.cellWidth = 64.0,
  this.cellHeight = 64.0,
  Vector2? origin,
}) {
  final double cellWidth;
  final double cellHeight;
  final Vector2 origin = origin?.clone() ?? Vector2.zero();

  static const List<(int, int)> _dirs4 = <(int, int)>[
    (1, 0),
    (0, 1),
    (-1, 0),
    (0, -1),
  ];

  static const List<(int, int)> _dirs8 = <(int, int)>[
    (1, 0),
    (1, 1),
    (0, 1),
    (-1, 1),
    (-1, 0),
    (-1, -1),
    (0, -1),
    (1, -1),
  ];

  /// Writes the world-space center of [cell] into [out].
  void cellToWorldCenter(GridCell cell, Vector2 out) {
    out.setValues(
      origin.x + (cell.col + 0.5) * cellWidth,
      origin.y + (cell.row + 0.5) * cellHeight,
    );
  }

  /// Maps a world-space point `(worldX, worldY)` to its containing [GridCell].
  GridCell worldToCell(double worldX, double worldY, {int elevation = 0}) {
    final col = ((worldX - origin.x) / cellWidth).floor();
    final row = ((worldY - origin.y) / cellHeight).floor();
    return GridCell(col, row, elevation);
  }

  /// 4-way Manhattan distance `|dc| + |dr|`.
  static int manhattanDistance(GridCell a, GridCell b) =>
      (a.col - b.col).abs() + (a.row - b.row).abs();

  /// 8-way Chebyshev distance `max(|dc|, |dr|)`.
  static int chebyshevDistance(GridCell a, GridCell b) =>
      math.max((a.col - b.col).abs(), (a.row - b.row).abs());

  /// Appends the 4 cardinal neighbors of [cell] into [out].
  void neighbors4(GridCell cell, List<GridCell> out) {
    out.clear();
    for (var i = 0; i < _dirs4.length; i++) {
      final (dc, dr) = _dirs4[i];
      out.add(GridCell(cell.col + dc, cell.row + dr, cell.elevation));
    }
  }

  /// Appends all 8 cardinal + diagonal neighbors of [cell] into [out].
  void neighbors8(GridCell cell, List<GridCell> out) {
    out.clear();
    for (var i = 0; i < _dirs8.length; i++) {
      final (dc, dr) = _dirs8[i];
      out.add(GridCell(cell.col + dc, cell.row + dr, cell.elevation));
    }
  }

  /// Traces a discrete Bresenham line from [start] to [end], writing visited
  /// cells into [out] and returning `false` if [isBlocked] rejects any
  /// intermediate or target cell.
  static bool traceLineOfSight(
    GridCell start,
    GridCell end,
    List<GridCell> out, {
    bool Function(GridCell cell)? isBlocked,
  }) {
    out.clear();
    var x0 = start.col;
    var y0 = start.row;
    final x1 = end.col;
    final y1 = end.row;

    final dx = (x1 - x0).abs();
    final sx = x0 < x1 ? 1 : -1;
    final dy = -(y1 - y0).abs();
    final sy = y0 < y1 ? 1 : -1;
    var err = dx + dy;

    while (true) {
      final current = GridCell(x0, y0, start.elevation);
      out.add(current);
      if (current != start && isBlocked != null && isBlocked(current)) {
        return false;
      }
      if (x0 == x1 && y0 == y1) {
        return true;
      }
      final e2 = 2 * err;
      if (e2 >= dy) {
        err += dy;
        x0 += sx;
      }
      if (e2 <= dx) {
        err += dx;
        y0 += sy;
      }
    }
  }
}

/// Diamond axonometric / isometric grid topology supporting vertical
/// [elevationStep] offsets and exact `world <-> cell` projection.
class IsometricGridTopology({
  this.tileWidth = 128.0,
  this.tileHeight = 64.0,
  this.elevationStep = 24.0,
  Vector2? origin,
}) {
  /// Full horizontal width of one diamond tile.
  final double tileWidth;

  /// Full vertical height of one diamond tile.
  final double tileHeight;

  /// Upward screen-Y displacement per integer `GridCell.elevation` unit.
  final double elevationStep;

  /// World coordinates of the center of `GridCell(0, 0, 0)`.
  final Vector2 origin = origin?.clone() ?? Vector2.zero();

  /// Projects [cell] to its world-space diamond center in [out].
  void cellToWorldCenter(GridCell cell, Vector2 out) {
    final halfW = tileWidth * 0.5;
    final halfH = tileHeight * 0.5;
    out.setValues(
      origin.x + (cell.col - cell.row) * halfW,
      origin.y + (cell.col + cell.row) * halfH - cell.elevation * elevationStep,
    );
  }

  /// Unprojects a world-space point `(worldX, worldY)` at a known [elevation]
  /// back to its containing isometric [GridCell].
  GridCell worldToCell(double worldX, double worldY, {int elevation = 0}) {
    final halfW = tileWidth * 0.5;
    final halfH = tileHeight * 0.5;
    final dx = worldX - origin.x;
    final dy = (worldY - origin.y) + elevation * elevationStep;
    final fracCol = 0.5 * (dx / halfW + dy / halfH);
    final fracRow = 0.5 * (dy / halfH - dx / halfW);
    return GridCell(fracCol.round(), fracRow.round(), elevation);
  }
}

/// Orientation of hexagonal cells in [HexGridTopology].
enum HexOrientation() {
  pointyTop,
  flatTop,
}

/// Axial/cube hexagonal grid topology (`col = q`, `row = r`, `s = -q - r`)
/// supporting exact cube rounding, hex distances, 6-neighbors, rings, and
/// spirals.
class HexGridTopology({
  this.hexRadius = 40.0,
  this.orientation = HexOrientation.pointyTop,
  Vector2? origin,
}) {
  /// Outer radius (center to corner) of each regular hexagon.
  final double hexRadius;
  final HexOrientation orientation;
  final Vector2 origin = origin?.clone() ?? Vector2.zero();

  static const double _sqrt3 = 1.7320508075688772;

  static const List<(int, int)> _axialDirs = <(int, int)>[
    (1, 0),
    (1, -1),
    (0, -1),
    (-1, 0),
    (-1, 1),
    (0, 1),
  ];

  /// Projects axial hex [cell] (`col = q`, `row = r`) to world center [out].
  void cellToWorldCenter(GridCell cell, Vector2 out) {
    final q = cell.col.toDouble();
    final r = cell.row.toDouble();
    if (orientation == HexOrientation.pointyTop) {
      out.setValues(
        origin.x + hexRadius * (_sqrt3 * q + (_sqrt3 * 0.5) * r),
        origin.y + hexRadius * (1.5 * r),
      );
    } else {
      out.setValues(
        origin.x + hexRadius * (1.5 * q),
        origin.y + hexRadius * ((_sqrt3 * 0.5) * q + _sqrt3 * r),
      );
    }
  }

  /// Unprojects `(worldX, worldY)` into the nearest axial [GridCell] via exact
  /// cube-coordinate rounding.
  GridCell worldToCell(double worldX, double worldY, {int elevation = 0}) {
    final px = (worldX - origin.x) / hexRadius;
    final py = (worldY - origin.y) / hexRadius;
    final double fq;
    final double fr;
    if (orientation == HexOrientation.pointyTop) {
      fq = (_sqrt3 / 3.0) * px - (1.0 / 3.0) * py;
      fr = (2.0 / 3.0) * py;
    } else {
      fq = (2.0 / 3.0) * px;
      fr = (-1.0 / 3.0) * px + (_sqrt3 / 3.0) * py;
    }
    return _cubeRound(fq, fr, elevation);
  }

  /// Exact step distance between two axial hex cells.
  static int hexDistance(GridCell a, GridCell b) {
    final dq = (a.col - b.col).abs();
    final dr = (a.row - b.row).abs();
    final ds = ((-a.col - a.row) - (-b.col - b.row)).abs();
    return (dq + dr + ds) ~/ 2;
  }

  /// Appends all 6 adjacent hex cells around [center] into [out].
  void neighbors6(GridCell center, List<GridCell> out) {
    out.clear();
    for (var i = 0; i < 6; i++) {
      final (dq, dr) = _axialDirs[i];
      out.add(GridCell(center.col + dq, center.row + dr, center.elevation));
    }
  }

  /// Appends the `6 * radius` hex cells at exact step [radius] around [center].
  void hexRing(GridCell center, int radius, List<GridCell> out) {
    out.clear();
    if (radius <= 0) {
      out.add(center);
      return;
    }
    // Start at direction 4 (-1, +1) * radius, then walk 6 sides.
    var q = center.col + _axialDirs[4].$1 * radius;
    var r = center.row + _axialDirs[4].$2 * radius;
    for (var side = 0; side < 6; side++) {
      final (dq, dr) = _axialDirs[side];
      for (var step = 0; step < radius; step++) {
        out.add(GridCell(q, r, center.elevation));
        q += dq;
        r += dr;
      }
    }
  }

  static GridCell _cubeRound(double fq, double fr, int elevation) {
    final fs = -fq - fr;
    var rq = fq.round();
    var rr = fr.round();
    final rs = fs.round();

    final qDiff = (rq - fq).abs();
    final rDiff = (rr - fr).abs();
    final sDiff = (rs - fs).abs();

    if (qDiff > rDiff && qDiff > sDiff) {
      rq = -rr - rs;
    } else if (rDiff > sDiff) {
      rr = -rq - rs;
    }
    return GridCell(rq, rr, elevation);
  }
}

/// 4-bit (16-tile cardinal) and 8-bit corner-gated (47-tile blob) auto-tiling
/// bitmask resolvers for procedural terrain, roads, walls, and water borders.
abstract final class AutoTileBitmask._() {
  static const int north = 1 << 0;
  static const int east = 1 << 1;
  static const int south = 1 << 2;
  static const int west = 1 << 3;
  static const int northEast = 1 << 4;
  static const int southEast = 1 << 5;
  static const int southWest = 1 << 6;
  static const int northWest = 1 << 7;

  /// Computes the 4-bit cardinal mask (`0 .. 15`) around `(col, row)`.
  static int compute4Bit(
    int col,
    int row,
    bool Function(int col, int row) matchesTerrain,
  ) {
    var mask = 0;
    if (matchesTerrain(col, row - 1)) {
      mask |= north;
    }
    if (matchesTerrain(col + 1, row)) {
      mask |= east;
    }
    if (matchesTerrain(col, row + 1)) {
      mask |= south;
    }
    if (matchesTerrain(col - 1, row)) {
      mask |= west;
    }
    return mask;
  }

  /// Computes the corner-gated 8-bit Wang/Blob mask (producing one of the 47
  /// canonical blob tile combinations) where diagonal bits are set **only** if
  /// both adjacent cardinal neighbors also match!
  static int compute8BitBlob(
    int col,
    int row,
    bool Function(int col, int row) matchesTerrain,
  ) {
    final n = matchesTerrain(col, row - 1);
    final e = matchesTerrain(col + 1, row);
    final s = matchesTerrain(col, row + 1);
    final w = matchesTerrain(col - 1, row);

    var mask = 0;
    if (n) {
      mask |= north;
    }
    if (e) {
      mask |= east;
    }
    if (s) {
      mask |= south;
    }
    if (w) {
      mask |= west;
    }
    if (n && e && matchesTerrain(col + 1, row - 1)) {
      mask |= northEast;
    }
    if (s && e && matchesTerrain(col + 1, row + 1)) {
      mask |= southEast;
    }
    if (s && w && matchesTerrain(col - 1, row + 1)) {
      mask |= southWest;
    }
    if (n && w && matchesTerrain(col - 1, row - 1)) {
      mask |= northWest;
    }
    return mask;
  }
}
