import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// Visibility state of a grid tile in [ShadowcastFogOfWar].
enum FogCellState(this.code) {
  /// Never seen by any friendly observer (black shroud).
  unexplored(0),

  /// Previously seen in an earlier turn/step, currently out of sight (dimmed
  /// terrain memory).
  exploredShroud(1),

  /// Currently within active line-of-sight of at least one observer.
  visible(2);

  /// Compact byte encoding stored in [ShadowcastFogOfWar.rawStates].
  final int code;

  /// Decodes a [FogCellState] from its byte [code].
  static FogCellState fromCode(int code) => switch (code) {
    2 => FogCellState.visible,
    1 => FogCellState.exploredShroud,
    _ => FogCellState.unexplored,
  };
}

/// Zero-allocation, bit-exact symmetric shadowcasting Fog-of-War solver.
///
/// Implements Albert Ford's 4-quadrant diamond-bevel shadowcasting using exact
/// integer rational slopes (`num / den`) on a pre-allocated iterative stack:
/// - **Strict Symmetry (`sees(A, B) == sees(B, A)`)**: Guaranteed across all
///   non-opaque tile pairs without floating-point rounding drift.
/// - **Zero Heap Allocations**: `revealFrom` runs entirely inside flat
///   `Int32List` work stacks.
/// - **3-State Memory**: Tracks `unexplored`, `exploredShroud`, and `visible`
///   with GPU mask generation via [bakeMaskImageSync].
class ShadowcastFogOfWar({
  required this.width,
  required this.height,
  this.opaquePredicate,
  int initialStackCapacity = 128,
}) {
  this : assert(width > 0 && height > 0, 'Grid dimensions must be > 0.');

  /// Grid column count.
  final int width;

  /// Grid row count.
  final int height;

  /// Optional external wall/sight-blocker callback; if omitted, uses the
  /// internal bit-packed wall flag set via [setOpaque].
  final bool Function(int col, int row)? opaquePredicate;

  final Uint8List _states = Uint8List(width * height);
  final Uint8List _opaqueBits = Uint8List((width * height + 7) >> 3);

  Int32List _stackDepth = Int32List(math.max(32, initialStackCapacity));
  Int32List _stackStartNum = Int32List(math.max(32, initialStackCapacity));
  Int32List _stackStartDen = Int32List(math.max(32, initialStackCapacity));
  Int32List _stackEndNum = Int32List(math.max(32, initialStackCapacity));
  Int32List _stackEndDen = Int32List(math.max(32, initialStackCapacity));

  int _version = 0;

  /// Monotonically incremented whenever visibility or shroud state mutates.
  int get version => _version;

  /// Read-only view of raw cell codes (`0 = unexplored`, `1 = shroud`,
  /// `2 = visible`).
  List<int> get rawStates => List<int>.unmodifiable(_states);

  /// Returns `true` if `(col, row)` lies inside `[0..width) x [0..height)`.
  bool inBounds(int col, int row) =>
      col >= 0 && col < width && row >= 0 && row < height;

  /// Marks `(col, row)` as sight-blocking or transparent in the built-in
  /// opacity bitmap.
  void setOpaque(int col, int row, {required bool opaque}) {
    if (!inBounds(col, row)) {
      return;
    }
    final idx = row * width + col;
    final byteIdx = idx >> 3;
    final mask = 1 << (idx & 7);
    if (opaque) {
      _opaqueBits[byteIdx] |= mask;
    } else {
      _opaqueBits[byteIdx] &= ~mask;
    }
  }

  /// Whether `(col, row)` blocks line-of-sight rays. Out-of-bounds cells are
  /// treated as opaque.
  bool isOpaque(int col, int row) {
    if (!inBounds(col, row)) {
      return true;
    }
    final custom = opaquePredicate;
    if (custom != null) {
      return custom(col, row);
    }
    final idx = row * width + col;
    return (_opaqueBits[idx >> 3] & (1 << (idx & 7))) != 0;
  }

  /// Queries the [FogCellState] at `(col, row)`.
  FogCellState stateAt(int col, int row) {
    if (!inBounds(col, row)) {
      return FogCellState.unexplored;
    }
    return FogCellState.fromCode(_states[row * width + col]);
  }

  /// Returns `true` when `(col, row)` is currently [FogCellState.visible].
  bool isVisible(int col, int row) =>
      inBounds(col, row) &&
      _states[row * width + col] == FogCellState.visible.code;

  /// Returns `true` when `(col, row)` is either [FogCellState.exploredShroud]
  /// or [FogCellState.visible].
  bool isExplored(int col, int row) =>
      inBounds(col, row) &&
      _states[row * width + col] >= FogCellState.exploredShroud.code;

  /// Resets the entire map back to [FogCellState.unexplored].
  void resetAll() {
    _states.fillRange(0, _states.length, FogCellState.unexplored.code);
    _version++;
  }

  /// Reveals every cell on the map to [FogCellState.visible].
  void revealAll() {
    _states.fillRange(0, _states.length, FogCellState.visible.code);
    _version++;
  }

  /// Demotes all currently [FogCellState.visible] cells to
  /// [FogCellState.exploredShroud] before recomputing active observer sight.
  void clearVisibleToShroud() {
    var changed = false;
    final visCode = FogCellState.visible.code;
    final shroudCode = FogCellState.exploredShroud.code;
    for (var i = 0; i < _states.length; i++) {
      if (_states[i] == visCode) {
        _states[i] = shroudCode;
        changed = true;
      }
    }
    if (changed) {
      _version++;
    }
  }

  void _markVisible(int col, int row) {
    final idx = row * width + col;
    final visCode = FogCellState.visible.code;
    if (_states[idx] != visCode) {
      _states[idx] = visCode;
      _version++;
    }
  }

  void _ensureStackCapacity(int needed) {
    if (_stackDepth.length >= needed) {
      return;
    }
    var cap = _stackDepth.length * 2;
    while (cap < needed) {
      cap *= 2;
    }
    _stackDepth = Int32List(cap)..setRange(0, _stackDepth.length, _stackDepth);
    _stackStartNum = Int32List(cap)
      ..setRange(0, _stackStartNum.length, _stackStartNum);
    _stackStartDen = Int32List(cap)
      ..setRange(0, _stackStartDen.length, _stackStartDen);
    _stackEndNum = Int32List(cap)
      ..setRange(0, _stackEndNum.length, _stackEndNum);
    _stackEndDen = Int32List(cap)
      ..setRange(0, _stackEndDen.length, _stackEndDen);
  }

  /// Exact integer `ceil(num / den)` for `den > 0` across negative, zero, and
  /// positive numerators.
  static int _ceilDiv(int num, int den) {
    final q = num ~/ den;
    final r = num.remainder(den);
    return r > 0 ? q + 1 : q;
  }

  /// Exact integer `floor(num / den)` for `den > 0` across negative, zero, and
  /// positive numerators.
  static int _floorDiv(int num, int den) {
    final q = num ~/ den;
    final r = num.remainder(den);
    return r < 0 ? q - 1 : q;
  }

  /// Computes symmetric shadowcast visibility from `(originCol, originRow)` out
  /// to Euclidean [radius] (in tile units), promoting seen tiles to
  /// [FogCellState.visible].
  ///
  /// Multiple party members or torches can call [revealFrom] sequentially after
  /// a single [clearVisibleToShroud] pass to union their sight cones.
  void revealFrom(
    int originCol,
    int originRow, {
    required double radius,
  }) {
    if (!inBounds(originCol, originRow) || radius < 0.0) {
      return;
    }
    _markVisible(originCol, originRow);
    final maxDepth = radius.floor();
    if (maxDepth <= 0) {
      return;
    }
    final radiusSq = radius * radius + 1e-9;

    // Scan all 4 cardinal quadrants:
    // 0: North (ox + col, oy - depth)
    // 1: South (ox + col, oy + depth)
    // 2: East  (ox + depth, oy + col)
    // 3: West  (ox - depth, oy + col)
    for (var quadrant = 0; quadrant < 4; quadrant++) {
      var sp = 0;
      _stackDepth[0] = 1;
      _stackStartNum[0] = -1;
      _stackStartDen[0] = 1;
      _stackEndNum[0] = 1;
      _stackEndDen[0] = 1;
      sp = 1;

      while (sp > 0) {
        sp--;
        var depth = _stackDepth[sp];
        var sNum = _stackStartNum[sp];
        var sDen = _stackStartDen[sp];
        final eNum = _stackEndNum[sp];
        final eDen = _stackEndDen[sp];

        while (depth <= maxDepth && sNum * eDen <= eNum * sDen) {
          // Exact rational equivalent of Ford's round_ties_up(depth * start)
          // and round_ties_down(depth * end):
          // (2*col + 1)/(2*depth) > sNum/sDen  <=> 2*col*sDen >= 2*depth*sNum - sDen + 1
          // (2*col - 1)/(2*depth) < eNum/eDen  <=> 2*col*eDen <= 2*depth*eNum + eDen - 1
          final minCol = _ceilDiv(2 * depth * sNum - sDen + 1, 2 * sDen);
          final maxCol = _floorDiv(2 * depth * eNum + eDen - 1, 2 * eDen);

          var prevWasWall = false;
          var anyFloorScanned = false;

          for (var col = minCol; col <= maxCol; col++) {
            final int wx;
            final int wy;
            switch (quadrant) {
              case 0:
                wx = originCol + col;
                wy = originRow - depth;
              case 1:
                wx = originCol + col;
                wy = originRow + depth;
              case 2:
                wx = originCol + depth;
                wy = originRow + col;
              default:
                wx = originCol - depth;
                wy = originRow + col;
            }

            final cellInBounds = inBounds(wx, wy);
            final cellWall = !cellInBounds || isOpaque(wx, wy);

            if (cellInBounds) {
              final distSq = (depth * depth + col * col).toDouble();
              if (distSq <= radiusSq) {
                // Symmetric floor-center rule:
                // Floor tile is visible iff its center slope col/depth lies in
                // [sNum/sDen, eNum/eDen]. Walls on the bevel boundary are also
                // revealed so cavern walls surrounding a room light up cleanly.
                final centerSymmetric =
                    col * sDen >= depth * sNum && col * eDen <= depth * eNum;
                if (cellWall || centerSymmetric) {
                  _markVisible(wx, wy);
                }
              }
            }

            if (cellWall) {
              if (anyFloorScanned && !prevWasWall && depth < maxDepth) {
                // Narrow child scan before this wall to endSlope =
                // (2*col - 1) / (2*depth).
                final childENum = 2 * col - 1;
                final childEDen = 2 * depth;
                if (sNum * childEDen <= childENum * sDen) {
                  _ensureStackCapacity(sp + 1);
                  _stackDepth[sp] = depth + 1;
                  _stackStartNum[sp] = sNum;
                  _stackStartDen[sp] = sDen;
                  _stackEndNum[sp] = childENum;
                  _stackEndDen[sp] = childEDen;
                  sp++;
                }
              }
              prevWasWall = true;
            } else {
              if (prevWasWall) {
                // Advance current startSlope past previous wall's upper bevel:
                // previous col = col - 1 => (2*(col - 1) + 1)/(2*depth) =
                // (2*col - 1)/(2*depth).
                sNum = 2 * col - 1;
                sDen = 2 * depth;
              }
              prevWasWall = false;
              anyFloorScanned = true;
            }
          }

          if (!anyFloorScanned || prevWasWall) {
            break;
          }
          depth++;
        }
      }
    }
  }

  /// Synchronously returns `true` if a direct symmetric sightline exists
  /// between `(colA, rowA)` and `(colB, rowB)` within [radius] without mutating
  /// stored shroud states.
  bool hasLineOfSight(
    int colA,
    int rowA,
    int colB,
    int rowB, {
    required double radius,
  }) {
    if (!inBounds(colA, rowA) || !inBounds(colB, rowB)) {
      return false;
    }
    final dx = colB - colA;
    final dy = rowB - rowA;
    if (dx * dx + dy * dy > radius * radius + 1e-9) {
      return false;
    }
    if (dx == 0 && dy == 0) {
      return true;
    }
    final snapshot = Uint8List.fromList(_states);
    final savedVersion = _version;
    _states.fillRange(0, _states.length, FogCellState.unexplored.code);
    revealFrom(colA, rowA, radius: radius);
    final result = isVisible(colB, rowB);
    _states.setRange(0, _states.length, snapshot);
    _version = savedVersion;
    return result;
  }

  /// Bakes the current 3-state fog grid into a GPU [ui.Image] mask suitable
  /// for rendering over a 2D tilemap or HD-2D ground plane.
  ui.Image bakeMaskImageSync({
    int pixelsPerTile = 4,
    double featherSigma = 0.0,
    ui.Color unexploredColor = const ui.Color(0xF005070D),
    ui.Color shroudColor = const ui.Color(0x960A0E1A),
    ui.Color visibleColor = const ui.Color(0x00000000),
  }) {
    final ppt = math.max(1, pixelsPerTile);
    final imgW = width * ppt;
    final imgH = height * ppt;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(
      recorder,
      ui.Rect.fromLTWH(0, 0, imgW.toDouble(), imgH.toDouble()),
    );

    if (featherSigma > 0.0) {
      canvas.saveLayer(
        ui.Rect.fromLTWH(0, 0, imgW.toDouble(), imgH.toDouble()),
        ui.Paint()
          ..imageFilter = ui.ImageFilter.blur(
            sigmaX: featherSigma,
            sigmaY: featherSigma,
            tileMode: ui.TileMode.clamp,
          ),
      );
    }

    final unexploredPaint = ui.Paint()..color = unexploredColor;
    final shroudPaint = ui.Paint()..color = shroudColor;
    final visiblePaint = ui.Paint()..color = visibleColor;

    final tilePx = ppt.toDouble();
    for (var r = 0; r < height; r++) {
      final rowOff = r * width;
      final top = r * tilePx;
      var c = 0;
      while (c < width) {
        final code = _states[rowOff + c];
        var runEnd = c + 1;
        while (runEnd < width && _states[rowOff + runEnd] == code) {
          runEnd++;
        }
        final paint = switch (code) {
          2 => visiblePaint,
          1 => shroudPaint,
          _ => unexploredPaint,
        };
        if (paint.color.a > 0.0) {
          canvas.drawRect(
            ui.Rect.fromLTWH(
              c * tilePx,
              top,
              (runEnd - c) * tilePx,
              tilePx,
            ),
            paint,
          );
        }
        c = runEnd;
      }
    }

    if (featherSigma > 0.0) {
      canvas.restore();
    }

    final picture = recorder.endRecording();
    final image = picture.toImageSync(imgW, imgH);
    picture.dispose();
    return image;
  }
}
