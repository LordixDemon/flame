import 'dart:ui';

import 'package:flame/src/grid/grid_topology.dart';
import 'package:meta/meta.dart';

/// Bit-packed 28-bit tile cell descriptor (safe across 64-bit native VM and
/// 32-bit Web/JS bitwise operations) encoding a 24-bit [tileId] (`0` = empty),
/// horizontal/vertical flip flags, and `90°` clockwise quarter-turn rotation.
extension type const TileGid(int raw) {
  /// Empty (transparent) tile slot.
  static const TileGid empty = TileGid(0);

  static const int _idMask = 0x00FFFFFF;
  static const int _flipHBit = 1 << 24;
  static const int _flipVBit = 1 << 25;
  static const int _rotShift = 26;
  static const int _rotMask = 0x3 << _rotShift;

  /// Packs [tileId] (`0 .. 0x00FFFFFF`) with optional [flipH], [flipV], and
  /// [quarterTurns] (`0 .. 3`, clockwise `90°` steps).
  factory TileGid.pack(
    int tileId, {
    bool flipH = false,
    bool flipV = false,
    int quarterTurns = 0,
  }) {
    assert(
      tileId >= 0 && tileId <= _idMask,
      'tileId out of 24-bit range: $tileId',
    );
    var bits = tileId & _idMask;
    if (flipH) {
      bits |= _flipHBit;
    }
    if (flipV) {
      bits |= _flipVBit;
    }
    bits |= (quarterTurns & 0x3) << _rotShift;
    return TileGid(bits);
  }

  /// Base 1-based tileset identifier (`0` means empty cell).
  int get tileId => raw & _idMask;

  /// Whether this cell is empty (`tileId == 0`).
  bool get isEmpty => (raw & _idMask) == 0;

  /// Whether this cell contains a non-empty tile (`tileId > 0`).
  bool get isNotEmpty => (raw & _idMask) != 0;

  /// Horizontal mirror flag.
  bool get flipH => (raw & _flipHBit) != 0;

  /// Vertical mirror flag.
  bool get flipV => (raw & _flipVBit) != 0;

  /// Clockwise `90°` rotation steps (`0`, `1`, `2`, or `3`).
  int get quarterTurns => (raw & _rotMask) >>> _rotShift;

  /// Returns a copy with updated transform flags.
  TileGid copyWith({
    int? tileId,
    bool? flipH,
    bool? flipV,
    int? quarterTurns,
  }) {
    return TileGid.pack(
      tileId ?? this.tileId,
      flipH: flipH ?? this.flipH,
      flipV: flipV ?? this.flipV,
      quarterTurns: quarterTurns ?? this.quarterTurns,
    );
  }
}

/// RPG Maker-style autotile sheet layout family.
enum AutotileKind() {
  /// Animated ground/water/lava blob (`2x3` tiles per frame × `frameCount`
  /// horizontal blocks, ping-pong `0-1-2-1` or linear cycle).
  animatedBlobA1,

  /// Static ground/road/carpet 47-state blob (`2x3` full tiles = `4x6`
  /// half-tile sub-cells).
  groundBlobA2,

  /// Building roof or rectangular facade (`2x2` full tiles = `4x4` half-tile
  /// sub-cells, 16 cardinal states without inner corners).
  facadeRectA3,

  /// Vertical cliff/wall face (`2x2` full tiles = `4x4` half-tiles) joining
  /// seamlessly beneath a wall-top `groundBlobA2` layer.
  cliffWallA4,

  /// Animated vertical waterfall strip (`2x3` half-tile column scrolling
  /// vertically across frames, left/center/right shore edges).
  waterfallA1,
}

/// Resolved 4 quarter-subtile offsets (in half-tile grid units relative to an
/// autotile block's top-left pixel origin) for `[topLeft, topRight,
/// bottomLeft, bottomRight]`.
@immutable
class const AutotileSubtileQuad({
  required this.tlQx,
  required this.tlQy,
  required this.trQx,
  required this.trQy,
  required this.blQx,
  required this.blQy,
  required this.brQx,
  required this.brQy,
}) {
  final int tlQx;
  final int tlQy;
  final int trQx;
  final int trQy;
  final int blQx;
  final int blQy;
  final int brQx;
  final int brQy;

  /// Writes the 4 source atlas rectangles `(TL, TR, BL, BR)` in pixels given
  /// the autotile block's pixel origin `(originPxX, originPxY)` and
  /// `halfTilePxW` / `halfTilePxH`.
  void writeSourceRects({
    required double originPxX,
    required double originPxY,
    required double halfTilePxW,
    required double halfTilePxH,
    required List<Rect> out4,
  }) {
    out4
      ..clear()
      ..add(
        Rect.fromLTWH(
          originPxX + tlQx * halfTilePxW,
          originPxY + tlQy * halfTilePxH,
          halfTilePxW,
          halfTilePxH,
        ),
      )
      ..add(
        Rect.fromLTWH(
          originPxX + trQx * halfTilePxW,
          originPxY + trQy * halfTilePxH,
          halfTilePxW,
          halfTilePxH,
        ),
      )
      ..add(
        Rect.fromLTWH(
          originPxX + blQx * halfTilePxW,
          originPxY + blQy * halfTilePxH,
          halfTilePxW,
          halfTilePxH,
        ),
      )
      ..add(
        Rect.fromLTWH(
          originPxX + brQx * halfTilePxW,
          originPxY + brQy * halfTilePxH,
          halfTilePxW,
          halfTilePxH,
        ),
      );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AutotileSubtileQuad &&
          tlQx == other.tlQx &&
          tlQy == other.tlQy &&
          trQx == other.trQx &&
          trQy == other.trQy &&
          blQx == other.blQx &&
          blQy == other.blQy &&
          brQx == other.brQx &&
          brQy == other.brQy;

  @override
  int get hashCode => Object.hash(
    tlQx,
    tlQy,
    trQx,
    trQy,
    blQx,
    blQy,
    brQx,
    brQy,
  );
}

/// Descriptor binding a logical `tileId` to an RPG Maker-style `A1–A4`
/// quarter-subtile autotile block inside an atlas image.
class const AutotileDefinition({
  required this.tileId,
  required this.kind,
  required this.blockOriginPxX,
  required this.blockOriginPxY,
  this.frameCount = 1,
  this.frameStridePxX = 0.0,
  this.frameStridePxY = 0.0,
  this.pingPongAnimation = true,
  this.connectGroupId,
}) {
  /// Logical non-zero `TileGid.tileId` triggers this autotile rule.
  final int tileId;

  /// Layout family (`A1`, `A2`, `A3`, `A4`, `waterfallA1`).
  final AutotileKind kind;

  /// Top-left X pixel coordinate of frame `0` in the tileset atlas.
  final double blockOriginPxX;

  /// Top-left Y pixel coordinate of frame `0` in the tileset atlas.
  final double blockOriginPxY;

  /// Number of distinct animation frames (`1` for static `A2`/`A3`/`A4`,
  /// typically `3` for `A1` water with `0-1-2-1` ping-pong stride).
  final int frameCount;

  /// Horizontal pixel stride between consecutive animation blocks in the sheet.
  final double frameStridePxX;

  /// Vertical pixel stride between consecutive animation blocks in the sheet.
  final double frameStridePxY;

  /// When `true` and `frameCount == 3`, steps follow the RPG Maker `0-1-2-1`
  /// 4-phase cycle (`cycleLength == 2 * frameCount - 2`).
  final bool pingPongAnimation;

  /// Optional compatibility group ID allowing e.g. deep water and shallow water
  /// to weld borders seamlessly when sharing the same `connectGroupId`.
  final int? connectGroupId;

  /// Total animation phase count (`4` for 3-frame ping-pong, `frameCount`
  /// otherwise).
  int get phaseCount {
    if (frameCount <= 1) {
      return 1;
    }
    return pingPongAnimation ? (frameCount * 2 - 2) : frameCount;
  }

  /// Maps monotonic animation tick [step] (`>= 0`) to a concrete atlas frame
  /// index in `[0 .. frameCount - 1]`.
  int resolveAtlasFrame(int step) {
    if (frameCount <= 1) {
      return 0;
    }
    final phases = phaseCount;
    final p = ((step % phases) + phases) % phases;
    if (!pingPongAnimation || p < frameCount) {
      return p;
    }
    return phases - p;
  }
}

/// Quarter-subtile (`TL, TR, BL, BR`) composer for RPG Maker `A1`, `A2`, `A3`,
/// `A4`, and waterfall autotiles.
///
/// Composes all 47 canonical 8-bit blob states (`A1`/`A2`), all 16 4-bit
/// rectangular roof/wall states (`A3`/`A4`), and horizontal shore-gated
/// waterfall strips from compact half-tile source sheets with zero heap
/// allocations on lookup.
abstract final class AutotileComposer._() {
  /// Resolves the 4 quarter-subtiles for an 8-bit corner-gated blob mask
  /// ([AutoTileBitmask.compute8BitBlob]) on a standard `2x3`-tile (`4x6`
  /// half-tile) `A1`/`A2` block.
  static AutotileSubtileQuad composeBlobA2FromMask(int mask8Bit) {
    final n = (mask8Bit & AutoTileBitmask.north) != 0;
    final e = (mask8Bit & AutoTileBitmask.east) != 0;
    final s = (mask8Bit & AutoTileBitmask.south) != 0;
    final w = (mask8Bit & AutoTileBitmask.west) != 0;
    final ne = (mask8Bit & AutoTileBitmask.northEast) != 0;
    final se = (mask8Bit & AutoTileBitmask.southEast) != 0;
    final sw = (mask8Bit & AutoTileBitmask.southWest) != 0;
    final nw = (mask8Bit & AutoTileBitmask.northWest) != 0;

    // Top-Left quadrant (qx, qy) in 4x6 half-tile grid:
    final int tlX;
    final int tlY;
    if (!n && !w) {
      tlX = 0;
      tlY = 2;
    } else if (!n && w) {
      tlX = 2;
      tlY = 2;
    } else if (n && !w) {
      tlX = 0;
      tlY = 4;
    } else if (!nw) {
      tlX = 2;
      tlY = 0;
    } else {
      tlX = 2;
      tlY = 4;
    }

    // Top-Right quadrant:
    final int trX;
    final int trY;
    if (!n && !e) {
      trX = 3;
      trY = 2;
    } else if (!n && e) {
      trX = 1;
      trY = 2;
    } else if (n && !e) {
      trX = 3;
      trY = 4;
    } else if (!ne) {
      trX = 3;
      trY = 0;
    } else {
      trX = 1;
      trY = 4;
    }

    // Bottom-Left quadrant:
    final int blX;
    final int blY;
    if (!s && !w) {
      blX = 0;
      blY = 5;
    } else if (!s && w) {
      blX = 2;
      blY = 5;
    } else if (s && !w) {
      blX = 0;
      blY = 3;
    } else if (!sw) {
      blX = 2;
      blY = 1;
    } else {
      blX = 2;
      blY = 3;
    }

    // Bottom-Right quadrant:
    final int brX;
    final int brY;
    if (!s && !e) {
      brX = 3;
      brY = 5;
    } else if (!s && e) {
      brX = 1;
      brY = 5;
    } else if (s && !e) {
      brX = 3;
      brY = 3;
    } else if (!se) {
      brX = 3;
      brY = 1;
    } else {
      brX = 1;
      brY = 3;
    }

    return AutotileSubtileQuad(
      tlQx: tlX,
      tlQy: tlY,
      trQx: trX,
      trQy: trY,
      blQx: blX,
      blQy: blY,
      brQx: brX,
      brQy: brY,
    );
  }

  /// Resolves the 4 quarter-subtiles for a 4-bit cardinal mask
  /// ([AutoTileBitmask.compute4Bit]) on a `2x2`-tile (`4x4` half-tile) `A3`
  /// roof/facade or `A4` vertical cliff-wall block.
  static AutotileSubtileQuad composeRectA3FromMask(int mask4Bit) {
    final n = (mask4Bit & AutoTileBitmask.north) != 0;
    final e = (mask4Bit & AutoTileBitmask.east) != 0;
    final s = (mask4Bit & AutoTileBitmask.south) != 0;
    final w = (mask4Bit & AutoTileBitmask.west) != 0;

    return AutotileSubtileQuad(
      tlQx: w ? 2 : 0,
      tlQy: n ? 2 : 0,
      trQx: e ? 1 : 3,
      trQy: n ? 2 : 0,
      blQx: w ? 2 : 0,
      blQy: s ? 1 : 3,
      brQx: e ? 1 : 3,
      brQy: s ? 1 : 3,
    );
  }

  /// Resolves a waterfall (`2x1` tile = `4x2` half-tile per vertical frame row)
  /// subtile quad based on whether matching waterfall tiles sit immediately
  /// [westMatches] and [eastMatches].
  static AutotileSubtileQuad composeWaterfall({
    required bool westMatches,
    required bool eastMatches,
  }) {
    final leftQx = westMatches ? 2 : 0;
    final rightQx = eastMatches ? 1 : 3;
    return AutotileSubtileQuad(
      tlQx: leftQx,
      tlQy: 0,
      trQx: rightQx,
      trQy: 0,
      blQx: leftQx,
      blQy: 1,
      brQx: rightQx,
      brQy: 1,
    );
  }

  /// Resolves the appropriate [AutotileSubtileQuad] for [kind] at `(col, row)`
  /// using [matchesNeighbor].
  static AutotileSubtileQuad composeForCell({
    required AutotileKind kind,
    required int col,
    required int row,
    required bool Function(int col, int row) matchesNeighbor,
  }) {
    switch (kind) {
      case AutotileKind.animatedBlobA1:
      case AutotileKind.groundBlobA2:
        final mask8 = AutoTileBitmask.compute8BitBlob(
          col,
          row,
          matchesNeighbor,
        );
        return composeBlobA2FromMask(mask8);
      case AutotileKind.facadeRectA3:
      case AutotileKind.cliffWallA4:
        final mask4 = AutoTileBitmask.compute4Bit(col, row, matchesNeighbor);
        return composeRectA3FromMask(mask4);
      case AutotileKind.waterfallA1:
        return composeWaterfall(
          westMatches: matchesNeighbor(col - 1, row),
          eastMatches: matchesNeighbor(col + 1, row),
        );
    }
  }
}
