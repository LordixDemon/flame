import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flame/src/tilemap/tile_passage_grid.dart';
import 'package:vector_math/vector_math.dart';

/// 8-directional character facing matching classic 4-row and extended 8-row
/// RPG sprite sheets.
///
/// Rows `0..3` follow the standard RPG Maker sheet convention:
/// `south(0)`, `west(1)`, `east(2)`, `north(3)`.
/// Rows `4..7` hold diagonal directions (`southWest`, `southEast`,
/// `northWest`, `northEast`) and automatically fall back to cardinal rows
/// when sampling a 4-row sheet.
enum CharacterFacing8(this.sheetRow8, this.fallbackRow4, this.dx, this.dy) {
  /// Facing down toward the camera (`+Y`, row `0`).
  south(0, 0, 0, 1),

  /// Facing left (`-X`, row `1`).
  west(1, 1, -1, 0),

  /// Facing right (`+X`, row `2`).
  east(2, 2, 1, 0),

  /// Facing up away from the camera (`-Y`, row `3`).
  north(3, 3, 0, -1),

  /// Facing down-left (`-X, +Y`, row `4`).
  southWest(4, 1, -1, 1),

  /// Facing down-right (`+X, +Y`, row `5`).
  southEast(5, 2, 1, 1),

  /// Facing up-left (`-X, -Y`, row `6`).
  northWest(6, 1, -1, -1),

  /// Facing up-right (`+X, -Y`, row `7`).
  northEast(7, 2, 1, -1);

  /// Row index in an 8-directional character sheet.
  final int sheetRow8;

  /// Fallback row index when sampling a 4-directional character sheet.
  final int fallbackRow4;

  /// Unit step sign along X (`-1`, `0`, `+1`).
  final int dx;

  /// Unit step sign along Y (`-1`, `0`, `+1`).
  final int dy;

  /// Converts a [GridCardinalDirection] into its [CharacterFacing8] value.
  static CharacterFacing8 fromCardinal(GridCardinalDirection cardinal) =>
      switch (cardinal) {
        GridCardinalDirection.south => CharacterFacing8.south,
        GridCardinalDirection.west => CharacterFacing8.west,
        GridCardinalDirection.east => CharacterFacing8.east,
        GridCardinalDirection.north => CharacterFacing8.north,
      };

  /// Resolves a facing direction from movement vector `(vx, vy)`.
  ///
  /// Returns [fallback] when `(vx, vy)` has near-zero magnitude.
  static CharacterFacing8 fromVelocity(
    double vx,
    double vy, {
    bool allowDiagonals = false,
    CharacterFacing8 fallback = CharacterFacing8.south,
  }) {
    if (vx.abs() <= 1e-5 && vy.abs() <= 1e-5) {
      return fallback;
    }
    if (!allowDiagonals) {
      if (vx.abs() >= vy.abs()) {
        return vx >= 0 ? CharacterFacing8.east : CharacterFacing8.west;
      }
      return vy >= 0 ? CharacterFacing8.south : CharacterFacing8.north;
    }
    final angle = math.atan2(vy, vx);
    final sector = ((angle / (math.pi / 4)).round() + 8) % 8;
    return switch (sector) {
      0 => CharacterFacing8.east,
      1 => CharacterFacing8.southEast,
      2 => CharacterFacing8.south,
      3 => CharacterFacing8.southWest,
      4 => CharacterFacing8.west,
      5 => CharacterFacing8.northWest,
      6 => CharacterFacing8.north,
      _ => CharacterFacing8.northEast,
    };
  }

  /// Resolves the sheet row index for a sheet with [directionalRows] (`4` or
  /// `8`).
  int rowForSheet(int directionalRows) =>
      directionalRows >= 8 ? sheetRow8 : fallbackRow4;

  /// Whether a held weapon should typically render behind the character torso
  /// for this facing direction.
  bool get weaponBehindBody =>
      this == CharacterFacing8.north ||
      this == CharacterFacing8.northWest ||
      this == CharacterFacing8.northEast;
}

/// Column animation cycle mode for [CharacterSpriteSheet].
enum StrideCycleMode() {
  /// Classic 3-column RPG Maker ping-pong cycle (`0 -> 1 -> 2 -> 1`) where
  /// column `1` is the neutral standing pose.
  pingPong3,

  /// Linear `N`-column cycle (`0 -> 1 -> ... -> columns - 1`) where column `0`
  /// is the default standing pose.
  linear,
}

/// 4/8-directional character sprite sheet layout with `0-1-2-1` ping-pong
/// stride stepping, multi-character block indexing, and per-frame weapon
/// attachment sockets.
class CharacterSpriteSheet({
  required this.frameWidth,
  required this.frameHeight,
  this.image,
  this.columns = 3,
  this.directionalRows = 4,
  this.strideMode = StrideCycleMode.pingPong3,
  int? idleColumn,
  this.characterBlockCol = 0,
  this.characterBlockRow = 0,
}) {
  this
    : assert(
        frameWidth > 0 && frameHeight > 0,
        'Frame size must be positive.',
      ),
      assert(columns >= 1, 'columns must be >= 1.'),
      assert(
        directionalRows == 4 || directionalRows == 8,
        'directionalRows must be 4 or 8.',
      );

  /// Optional backing GPU [ui.Image] for this character sheet.
  final ui.Image? image;

  /// Pixel width of a single animation frame cell.
  final int frameWidth;

  /// Pixel height of a single animation frame cell.
  final int frameHeight;

  /// Number of animation columns per character block (typically `3` or `4`).
  final int columns;

  /// Number of directional rows per character block (`4` or `8`).
  final int directionalRows;

  /// Stride frame stepping rule (`0-1-2-1` ping-pong vs linear).
  final StrideCycleMode strideMode;

  /// Column index used when the character is standing still.
  final int idleColumn =
      idleColumn ??
      (strideMode == StrideCycleMode.pingPong3 && columns >= 3 ? 1 : 0);

  /// Horizontal character block index on multi-character sheets (e.g. `0..3`
  /// on an 8-character RPG Maker sheet).
  final int characterBlockCol;

  /// Vertical character block index on multi-character sheets (e.g. `0..1`).
  final int characterBlockRow;

  final Map<int, Vector2> _weaponSockets = <int, Vector2>{};

  static const List<int> _pingPong3Sequence = <int>[0, 1, 2, 1];

  /// Pixel width of one complete character block (`columns * frameWidth`).
  int get blockPixelWidth => columns * frameWidth;

  /// Pixel height of one complete character block
  /// (`directionalRows * frameHeight`).
  int get blockPixelHeight => directionalRows * frameHeight;

  /// Resolves the animation column index for [stridePhase] (`[0.0, 1.0)`).
  int resolveColumn({
    required bool isMoving,
    required double stridePhase,
  }) {
    if (!isMoving || columns <= 1) {
      return idleColumn.clamp(0, columns - 1);
    }
    var wrapped = stridePhase % 1.0;
    if (wrapped < 0.0) {
      wrapped += 1.0;
    }
    if (strideMode == StrideCycleMode.pingPong3 && columns >= 3) {
      final step = (wrapped * 4.0).floor().clamp(0, 3);
      return _pingPong3Sequence[step];
    }
    return (wrapped * columns).floor().clamp(0, columns - 1);
  }

  /// Computes the exact pixel source [ui.Rect] for [facing], [isMoving], and
  /// [stridePhase].
  ui.Rect sourceRect({
    required CharacterFacing8 facing,
    required bool isMoving,
    required double stridePhase,
  }) {
    final col = resolveColumn(isMoving: isMoving, stridePhase: stridePhase);
    final row = facing.rowForSheet(directionalRows);
    final left = (characterBlockCol * blockPixelWidth + col * frameWidth)
        .toDouble();
    final top = (characterBlockRow * blockPixelHeight + row * frameHeight)
        .toDouble();
    return ui.Rect.fromLTWH(
      left,
      top,
      frameWidth.toDouble(),
      frameHeight.toDouble(),
    );
  }

  int _socketKey(CharacterFacing8 facing, int column) =>
      (facing.index << 8) | (column & 0xFF);

  /// Registers a local weapon/equipment anchor offset `(x, y)` relative to the
  /// frame top-left for `(facing, column)`.
  void setWeaponSocketOffset(
    CharacterFacing8 facing,
    int column,
    Vector2 offset,
  ) {
    _weaponSockets[_socketKey(facing, column)] = offset.clone();
  }

  /// Queries the configured weapon socket offset for `(facing, column)` into
  /// [out] without heap allocations.
  void getWeaponSocketOffset(
    CharacterFacing8 facing,
    int column,
    Vector2 out,
  ) {
    final hit = _weaponSockets[_socketKey(facing, column)];
    if (hit != null) {
      out.setFrom(hit);
    } else {
      out.setValues(frameWidth * 0.5, frameHeight * 0.65);
    }
  }

  /// Returns a copy of this sheet descriptor bound to [replacedImage].
  CharacterSpriteSheet withImage(
    ui.Image replacedImage, {
    int blockCol = 0,
    int blockRow = 0,
  }) {
    final copy = CharacterSpriteSheet(
      image: replacedImage,
      frameWidth: frameWidth,
      frameHeight: frameHeight,
      columns: columns,
      directionalRows: directionalRows,
      strideMode: strideMode,
      idleColumn: idleColumn,
      characterBlockCol: blockCol,
      characterBlockRow: blockRow,
    );
    copy._weaponSockets.addAll(_weaponSockets);
    return copy;
  }
}
