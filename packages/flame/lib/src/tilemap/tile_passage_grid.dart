import 'dart:typed_data';

import 'package:flame/src/grid/grid_topology.dart';

/// Cardinal step direction on a 2D RPG grid.
enum GridCardinalDirection(
  this.dx,
  this.dy,
  this.exitBit,
  this.oppositeEntryBit,
) {
  north(0, -1, TilePassageFlags.passNorth, TilePassageFlags.passSouth),
  east(1, 0, TilePassageFlags.passEast, TilePassageFlags.passWest),
  south(0, 1, TilePassageFlags.passSouth, TilePassageFlags.passNorth),
  west(-1, 0, TilePassageFlags.passWest, TilePassageFlags.passEast);

  final int dx;
  final int dy;
  final int exitBit;
  final int oppositeEntryBit;

  /// Opposite `180°` direction.
  GridCardinalDirection get opposite => switch (this) {
    GridCardinalDirection.north => GridCardinalDirection.south,
    GridCardinalDirection.east => GridCardinalDirection.west,
    GridCardinalDirection.south => GridCardinalDirection.north,
    GridCardinalDirection.west => GridCardinalDirection.east,
  };
}

/// Bit-packed RPG Maker-style per-tile passage, bridge, bush, counter, terrain
/// tag (`0..15`), and region ID (`0..255`) metadata.
///
/// Layout (28-bit safe across VM and Web JS):
/// - Bits `0..3`: Directional edge exit passability (`N, E, S, W`).
/// - Bit `4`: `starOverhead` (`☆` tile rendered above ground actors).
/// - Bit `5`: `bridgeOverpass` (supports walking *under* at `elevation == 0`
///   and *over* at `elevation == 1`).
/// - Bit `6`: `counter` (interaction ray reaches `1` extra cell across desks).
/// - Bit `7`: `bush` (immerses lower quarter of standing sprites).
/// - Bit `8`: `ladder` (locks facing North while climbing).
/// - Bit `9`: `damageFloor` (triggers floor hazard tick on step).
/// - Bits `12..15`: 4-bit `terrainTag` (`0..15`).
/// - Bits `16..23`: 8-bit `regionId` (`0..255`).
abstract final class TilePassageFlags._() {
  static const int passNorth = 1 << 0;
  static const int passEast = 1 << 1;
  static const int passSouth = 1 << 2;
  static const int passWest = 1 << 3;
  static const int passAll4 = passNorth | passEast | passSouth | passWest;
  static const int impassable = 0;

  static const int starOverhead = 1 << 4;
  static const int bridgeOverpass = 1 << 5;
  static const int counter = 1 << 6;
  static const int bush = 1 << 7;
  static const int ladder = 1 << 8;
  static const int damageFloor = 1 << 9;

  static const int _terrainShift = 12;
  static const int _terrainMask = 0xF << _terrainShift;
  static const int _regionShift = 16;
  static const int _regionMask = 0xFF << _regionShift;

  /// Packs directional passability, RPG flags, [terrainTag] (`0..15`), and
  /// [regionId] (`0..255`) into a single 32-bit integer.
  static int pack({
    int passMask = passAll4,
    bool starOverhead = false,
    bool bridgeOverpass = false,
    bool counter = false,
    bool bush = false,
    bool ladder = false,
    bool damageFloor = false,
    int terrainTag = 0,
    int regionId = 0,
  }) {
    var bits = passMask & passAll4;
    if (starOverhead) {
      bits |= TilePassageFlags.starOverhead;
    }
    if (bridgeOverpass) {
      bits |= TilePassageFlags.bridgeOverpass;
    }
    if (counter) {
      bits |= TilePassageFlags.counter;
    }
    if (bush) {
      bits |= TilePassageFlags.bush;
    }
    if (ladder) {
      bits |= TilePassageFlags.ladder;
    }
    if (damageFloor) {
      bits |= TilePassageFlags.damageFloor;
    }
    bits |= (terrainTag.clamp(0, 15)) << _terrainShift;
    bits |= (regionId.clamp(0, 255)) << _regionShift;
    return bits;
  }

  /// Extracts the 4-bit terrain tag (`0..15`).
  static int terrainTagOf(int flags) =>
      (flags & _terrainMask) >>> _terrainShift;

  /// Extracts the 8-bit region ID (`0..255`).
  static int regionIdOf(int flags) => (flags & _regionMask) >>> _regionShift;
}

/// Multi-elevation RPG tile passage grid supporting 4-edge directional cliffs,
/// RPG Maker `☆` overhead tiles, dual-level `bridgeOverpass` crossings (`z=0`
/// underpass vs `z=1` bridge deck), and `counter` desk reach-through probes.
class TilePassageGrid({
  required this.width,
  required this.height,
  int defaultGroundFlags = TilePassageFlags.passAll4,
}) {
  final int width;
  final int height;

  /// Ground-level (`elevation == 0`) passage flags per cell.
  final Uint32List _groundFlags = Uint32List(width * height)
    ..fillRange(0, width * height, defaultGroundFlags);

  /// Bridge/upper-deck (`elevation == 1`) passage flags per cell (`0` when no
  /// upper deck exists on that cell).
  final Uint32List _upperFlags = Uint32List(width * height);

  /// Whether `(col, row)` lies inside `[0, width) * [0, height)`.
  bool inBounds(int col, int row) =>
      col >= 0 && col < width && row >= 0 && row < height;

  /// Reads raw packed flags at `(col, row)` on [elevation] (`0` or `1`).
  int flagsAt(int col, int row, {int elevation = 0}) {
    if (!inBounds(col, row)) {
      return TilePassageFlags.impassable;
    }
    final idx = row * width + col;
    return elevation > 0 ? _upperFlags[idx] : _groundFlags[idx];
  }

  /// Writes packed [flags] at `(col, row)` on [elevation] (`0` or `1`).
  void setFlags(int col, int row, int flags, {int elevation = 0}) {
    if (!inBounds(col, row)) {
      return;
    }
    final idx = row * width + col;
    if (elevation > 0) {
      _upperFlags[idx] = flags;
    } else {
      _groundFlags[idx] = flags;
    }
  }

  /// Configures an overpass bridge deck at `(col, row)` (`elevation == 1`)
  /// while keeping underpass ground flags intact on `elevation == 0`.
  void setBridgeDeck(
    int col,
    int row, {
    int deckPassMask = TilePassageFlags.passAll4,
  }) {
    if (!inBounds(col, row)) {
      return;
    }
    final idx = row * width + col;
    _upperFlags[idx] = TilePassageFlags.pack(
      passMask: deckPassMask,
      bridgeOverpass: true,
    );
  }

  /// Evaluates whether an actor at [from] (including `from.elevation`) can
  /// step one cell in [dir], returning the resulting [GridCell] (with automatic
  /// ramp/bridge elevation preservation) or `null` if blocked.
  GridCell? tryStep(
    GridCell from,
    GridCardinalDirection dir, {
    bool allowOneWayJump = false,
  }) {
    final toCol = from.col + dir.dx;
    final toRow = from.row + dir.dy;
    if (!inBounds(from.col, from.row) || !inBounds(toCol, toRow)) {
      return null;
    }

    final fromIdx = from.row * width + from.col;
    final toIdx = toRow * width + toCol;

    final curElev = from.elevation > 0 ? 1 : 0;
    final srcFlags = curElev == 1
        ? _upperFlags[fromIdx]
        : _groundFlags[fromIdx];
    if ((srcFlags & dir.exitBit) == 0) {
      return null;
    }

    if (curElev == 1) {
      final dstUpper = _upperFlags[toIdx];
      if ((dstUpper & TilePassageFlags.bridgeOverpass) != 0 &&
          ((dstUpper & dir.oppositeEntryBit) != 0 || allowOneWayJump)) {
        return GridCell(toCol, toRow, 1);
      }
      final dstGround = _groundFlags[toIdx];
      if ((dstGround & dir.oppositeEntryBit) != 0 || allowOneWayJump) {
        return GridCell(toCol, toRow);
      }
      return null;
    } else {
      final dstGround = _groundFlags[toIdx];
      if ((dstGround & dir.oppositeEntryBit) != 0 ||
          (allowOneWayJump && (dstGround & TilePassageFlags.passAll4) != 0)) {
        return GridCell(toCol, toRow);
      }
      final dstUpper = _upperFlags[toIdx];
      if ((dstUpper & TilePassageFlags.bridgeOverpass) != 0 &&
          (dstUpper & dir.oppositeEntryBit) != 0) {
        return GridCell(toCol, toRow, 1);
      }
      return null;
    }
  }

  /// Resolves the target interaction cell(s) in front of [actorCell] facing
  /// [facing].
  void resolveInteractionProbe(
    GridCell actorCell,
    GridCardinalDirection facing,
    List<GridCell> outCells,
  ) {
    outCells.clear();
    final c1 = actorCell.col + facing.dx;
    final r1 = actorCell.row + facing.dy;
    if (!inBounds(c1, r1)) {
      return;
    }
    outCells.add(GridCell(c1, r1, actorCell.elevation));
    final f1 = flagsAt(c1, r1, elevation: actorCell.elevation);
    if ((f1 & TilePassageFlags.counter) != 0) {
      final c2 = c1 + facing.dx;
      final r2 = r1 + facing.dy;
      if (inBounds(c2, r2)) {
        outCells.add(GridCell(c2, r2, actorCell.elevation));
      }
    }
  }

  /// Whether `(col, row)` immerses the lower quarter of standing sprites
  /// (tall grass / shallow water).
  bool isBush(int col, int row, {int elevation = 0}) =>
      (flagsAt(col, row, elevation: elevation) & TilePassageFlags.bush) != 0;

  /// Whether `(col, row)` inflicts floor hazard damage on entry.
  bool isDamageFloor(int col, int row, {int elevation = 0}) =>
      (flagsAt(col, row, elevation: elevation) &
          TilePassageFlags.damageFloor) !=
      0;

  /// Whether `(col, row)` renders above ground-level characters (`☆` flag).
  bool isStarOverhead(int col, int row) =>
      (flagsAt(col, row) & TilePassageFlags.starOverhead) != 0;

  /// Reads the 4-bit terrain tag (`0..15`) at `(col, row)`.
  int terrainTag(int col, int row, {int elevation = 0}) =>
      TilePassageFlags.terrainTagOf(flagsAt(col, row, elevation: elevation));

  /// Reads the 8-bit region ID (`0..255`) at `(col, row)`.
  int regionId(int col, int row, {int elevation = 0}) =>
      TilePassageFlags.regionIdOf(flagsAt(col, row, elevation: elevation));
}
