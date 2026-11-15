import 'dart:math' as math;

import 'package:flame/src/grid/grid_topology.dart';
import 'package:flame/src/tilemap/tile_passage_grid.dart';
import 'package:vector_math/vector_math.dart';

/// Locomotion physics mode for [GridCharacterMotor].
enum GridLocomotionMode() {
  /// Classic RPG Maker / Pokemon / Octopath tile-committed steps (`1` full cell
  /// per move) with seamless stride-phase continuity across consecutive tiles.
  tileLocked,

  /// Sub-tile free movement (Chrono Trigger / Sea of Stars / Zelda) with
  /// automatic doorway corner-sliding (`cornerSlideTolerance`).
  freeSubTile,
}

enum MoveRouteCommandKind() {
  stepCardinal,
  turnCardinal,
  turnTowardPoint,
  turnAwayFromPoint,
  jumpOffset,
  waitSeconds,
  setThrough,
}

/// Single scripted step inside a [MoveRoute].
class const MoveRouteCommand._({
  required this.kind,
  this.direction = GridCardinalDirection.south,
  this.dx = 0,
  this.dy = 0,
  this.targetX = 0.0,
  this.targetY = 0.0,
  this.arcHeightPx = 16.0,
  this.duration = 0.35,
  this.flag = false,
}) {
  factory MoveRouteCommand.step(GridCardinalDirection dir) =>
      MoveRouteCommand._(
        kind: MoveRouteCommandKind.stepCardinal,
        direction: dir,
      );

  factory MoveRouteCommand.turn(GridCardinalDirection dir) =>
      MoveRouteCommand._(
        kind: MoveRouteCommandKind.turnCardinal,
        direction: dir,
      );

  factory MoveRouteCommand.turnToward(double worldX, double worldY) =>
      MoveRouteCommand._(
        kind: MoveRouteCommandKind.turnTowardPoint,
        targetX: worldX,
        targetY: worldY,
      );

  factory MoveRouteCommand.turnAwayFrom(double worldX, double worldY) =>
      MoveRouteCommand._(
        kind: MoveRouteCommandKind.turnAwayFromPoint,
        targetX: worldX,
        targetY: worldY,
      );

  factory MoveRouteCommand.jump({
    required int dCol,
    required int dRow,
    double arcHeightPx = 20.0,
    double duration = 0.36,
  }) => MoveRouteCommand._(
    kind: MoveRouteCommandKind.jumpOffset,
    dx: dCol,
    dy: dRow,
    arcHeightPx: arcHeightPx,
    duration: duration,
  );

  factory MoveRouteCommand.wait(double seconds) => MoveRouteCommand._(
    kind: MoveRouteCommandKind.waitSeconds,
    duration: seconds,
  );

  factory MoveRouteCommand.setThrough({required bool through}) =>
      MoveRouteCommand._(kind: MoveRouteCommandKind.setThrough, flag: through);

  final MoveRouteCommandKind kind;
  final GridCardinalDirection direction;
  final int dx;
  final int dy;
  final double targetX;
  final double targetY;
  final double arcHeightPx;
  final double duration;
  final bool flag;
}

/// Scripted movement sequence for NPCs, cutscenes, and pushed boulders.
class const MoveRoute({
  required this.commands,
  this.repeat = false,
  this.skipIfBlocked = true,
}) {
  final List<MoveRouteCommand> commands;
  final bool repeat;
  final bool skipIfBlocked;
}

/// RPG character movement motor supporting both **tile-locked steps** (with
/// continuous walk-cycle phase across back-to-back tiles) and **sub-tile free
/// movement with doorway corner-sliding**, plus parabolic jump arcs, `through`
/// noclip mode, and scripted [MoveRoute] execution.
class GridCharacterMotor({
  required this.passageGrid,
  this.tileWidth = 32.0,
  this.tileHeight = 32.0,
  this.mode = GridLocomotionMode.tileLocked,
  this.speedPixelsPerSecond = 128.0,
  this.strideCyclesPerTile = 1.0,
  this.hitboxHalfWidth = 11.0,
  this.hitboxHalfHeight = 10.0,
  this.cornerSlideTolerance = 10.0,
  GridCell initialCell = const GridCell(0, 0),
  this.facing = GridCardinalDirection.south,
  this.through = false,
}) {
  this {
    _logicalCell = initialCell;
    _worldPos.setValues(
      (initialCell.col + 0.5) * tileWidth,
      (initialCell.row + 0.5) * tileHeight,
    );
  }

  final TilePassageGrid passageGrid;
  final double tileWidth;
  final double tileHeight;
  GridLocomotionMode mode;
  double speedPixelsPerSecond;
  double strideCyclesPerTile;
  double hitboxHalfWidth;
  double hitboxHalfHeight;

  /// Maximum perpendicular overlap in pixels (`>= 0`) where pressing into the
  /// corner of a wall smoothly slides the actor into an adjacent open doorway.
  double cornerSlideTolerance;

  GridCardinalDirection facing;
  bool through;

  /// Optional dynamic occupancy callback returning `true` if another solid NPC
  /// occupies `(col, row, elevation)`.
  bool Function(int col, int row, int elevation)? isCellOccupied;

  late GridCell _logicalCell;
  final Vector2 _worldPos = Vector2.zero();
  final Vector2 _stepStartPos = Vector2.zero();
  final Vector2 _stepTargetPos = Vector2.zero();

  bool _isSteppingTile = false;
  double _stepProgress = 0.0;
  double _stridePhase = 0.0;
  bool _isMovingVisual = false;

  bool _isJumping = false;
  double _jumpDuration = 0.35;
  double _jumpElapsed = 0.0;
  double _jumpArcHeightPx = 0.0;
  double _jumpElevationPx = 0.0;

  MoveRoute? _activeRoute;
  int _routeCursor = 0;
  double _routeWaitTimer = 0.0;

  GridCell get cell => _logicalCell;
  Vector2 get worldPosition => _worldPos;
  double get jumpElevationPx => _jumpElevationPx;
  double get stridePhase => _stridePhase;
  bool get isMoving => _isMovingVisual || _isSteppingTile || _isJumping;
  bool get isJumping => _isJumping;
  bool get hasActiveMoveRoute => _activeRoute != null;

  /// Teleports the character cleanly to [targetCell].
  void setCellPosition(GridCell targetCell) {
    _logicalCell = targetCell;
    _worldPos.setValues(
      (targetCell.col + 0.5) * tileWidth,
      (targetCell.row + 0.5) * tileHeight,
    );
    _isSteppingTile = false;
    _isJumping = false;
    _jumpElevationPx = 0.0;
    _stepProgress = 0.0;
  }

  /// Assigns a scripted [route] (pass `null` to cancel).
  void startMoveRoute(MoveRoute? route) {
    _activeRoute = route;
    _routeCursor = 0;
    _routeWaitTimer = 0.0;
  }

  /// Queries interactable target cell(s) in front of the actor (including `1`
  /// cell across RPG Maker `counter` desks!).
  void queryInteractionCells(List<GridCell> outCells) {
    passageGrid.resolveInteractionProbe(_logicalCell, facing, outCells);
  }

  /// Advances locomotion for [dt] seconds given normalized player directional
  /// input `(inputX, inputY)` (ignored while a scripted [MoveRoute] is active).
  void update(
    double dt, {
    double inputX = 0.0,
    double inputY = 0.0,
  }) {
    if (dt <= 0.0) {
      return;
    }

    if (_isJumping) {
      _jumpElapsed += dt;
      final t = (_jumpElapsed / _jumpDuration).clamp(0.0, 1.0);
      _worldPos.setValues(
        _stepStartPos.x + (_stepTargetPos.x - _stepStartPos.x) * t,
        _stepStartPos.y + (_stepTargetPos.y - _stepStartPos.y) * t,
      );
      _jumpElevationPx = 4.0 * _jumpArcHeightPx * t * (1.0 - t);
      _stridePhase = (_stridePhase + dt * 2.0) % 1.0;
      if (t >= 1.0 - 1e-6) {
        _isJumping = false;
        _jumpElevationPx = 0.0;
        _worldPos.setFrom(_stepTargetPos);
      }
      return;
    }

    if (_isSteppingTile) {
      _advanceSteppingTile(dt, inputX, inputY);
      return;
    }

    if (_activeRoute != null) {
      _advanceMoveRoute(dt);
      return;
    }

    if (mode == GridLocomotionMode.tileLocked) {
      final started = _tryStartTileStepFromInput(inputX, inputY);
      if (started) {
        _advanceSteppingTile(dt, inputX, inputY);
      } else {
        _isMovingVisual = false;
        _stridePhase = 0.0;
      }
    } else {
      _updateFreeSubTile(dt, inputX, inputY);
    }
  }

  void _advanceSteppingTile(double dt, double inputX, double inputY) {
    final dist = math.max(
      1.0,
      (_stepTargetPos - _stepStartPos).length,
    );
    final stepDelta = (speedPixelsPerSecond * dt) / dist;
    _stepProgress += stepDelta;
    _stridePhase = (_stridePhase + stepDelta * strideCyclesPerTile) % 1.0;

    if (_stepProgress >= 1.0 - 1e-6) {
      final leftoverRatio = _stepProgress - 1.0;
      _isSteppingTile = false;
      _stepProgress = 0.0;
      _worldPos.setFrom(_stepTargetPos);

      if (_activeRoute != null) {
        _advanceMoveRoute(leftoverRatio * (dist / speedPixelsPerSecond));
      } else {
        final chained = _tryStartTileStepFromInput(inputX, inputY);
        if (!chained) {
          _isMovingVisual = false;
          _stridePhase = 0.0;
        } else if (leftoverRatio > 1e-5) {
          final nextDist = math.max(
            1.0,
            (_stepTargetPos - _stepStartPos).length,
          );
          final carry = (leftoverRatio * dist) / nextDist;
          _stepProgress = carry.clamp(0.0, 0.99);
          _worldPos.setValues(
            _stepStartPos.x +
                (_stepTargetPos.x - _stepStartPos.x) * _stepProgress,
            _stepStartPos.y +
                (_stepTargetPos.y - _stepStartPos.y) * _stepProgress,
          );
        }
      }
    } else {
      _worldPos.setValues(
        _stepStartPos.x + (_stepTargetPos.x - _stepStartPos.x) * _stepProgress,
        _stepStartPos.y + (_stepTargetPos.y - _stepStartPos.y) * _stepProgress,
      );
    }
  }

  bool _tryStartTileStepFromInput(double ix, double iy) {
    if (ix.abs() <= 1e-4 && iy.abs() <= 1e-4) {
      return false;
    }
    final dir = _dominantCardinal(ix, iy);
    return tryBeginStep(dir);
  }

  /// Attempts to commit a `1`-tile step in [dir]. Updates [facing] even if the
  /// destination tile is blocked (unless climbing a `ladder`, which locks
  /// facing North per RPG Maker rules).
  bool tryBeginStep(GridCardinalDirection dir) {
    final onLadder =
        (passageGrid.flagsAt(
              _logicalCell.col,
              _logicalCell.row,
              elevation: _logicalCell.elevation,
            ) &
            TilePassageFlags.ladder) !=
        0;
    facing = onLadder ? GridCardinalDirection.north : dir;

    final GridCell? dest;
    if (through) {
      final nc = _logicalCell.col + dir.dx;
      final nr = _logicalCell.row + dir.dy;
      dest = passageGrid.inBounds(nc, nr)
          ? GridCell(nc, nr, _logicalCell.elevation)
          : null;
    } else {
      dest = passageGrid.tryStep(_logicalCell, dir);
    }

    if (dest == null) {
      return false;
    }
    if (!through &&
        isCellOccupied != null &&
        isCellOccupied!(dest.col, dest.row, dest.elevation)) {
      return false;
    }

    _stepStartPos.setFrom(_worldPos);
    _stepTargetPos.setValues(
      (dest.col + 0.5) * tileWidth,
      (dest.row + 0.5) * tileHeight,
    );
    _logicalCell = dest;
    _isSteppingTile = true;
    _isMovingVisual = true;
    _stepProgress = 0.0;
    return true;
  }

  void _updateFreeSubTile(double dt, double ix, double iy) {
    final len = math.sqrt(ix * ix + iy * iy);
    if (len <= 1e-4) {
      _isMovingVisual = false;
      _stridePhase = 0.0;
      return;
    }
    final nx = ix / len;
    final ny = iy / len;
    facing = _dominantCardinal(nx, ny);

    final moveDist = speedPixelsPerSecond * dt;
    final dx = nx * moveDist;
    final dy = ny * moveDist;

    final startX = _worldPos.x;
    final startY = _worldPos.y;

    if (through) {
      _worldPos.setValues(
        (startX + dx).clamp(
          hitboxHalfWidth,
          passageGrid.width * tileWidth - hitboxHalfWidth,
        ),
        (startY + dy).clamp(
          hitboxHalfHeight,
          passageGrid.height * tileHeight - hitboxHalfHeight,
        ),
      );
    } else {
      if (dx.abs() > 1e-6) {
        if (_canOccupyWorldBox(startX + dx, startY)) {
          _worldPos.x = startX + dx;
        } else if (dy.abs() <= 1e-4 && cornerSlideTolerance > 0.0) {
          final slideY = _probePerpendicularCornerSlide(
            targetX: startX + dx.sign * 2.0,
            currentY: startY,
            horizontalMove: true,
          );
          if (slideY != 0.0) {
            final nudge = math.min(moveDist, slideY.abs()) * slideY.sign;
            if (_canOccupyWorldBox(startX, startY + nudge)) {
              _worldPos.y = startY + nudge;
            }
          }
        }
      }

      if (dy.abs() > 1e-6) {
        if (_canOccupyWorldBox(_worldPos.x, _worldPos.y + dy)) {
          _worldPos.y += dy;
        } else if (dx.abs() <= 1e-4 && cornerSlideTolerance > 0.0) {
          final slideX = _probePerpendicularCornerSlide(
            targetX: _worldPos.x,
            currentY: _worldPos.y + dy.sign * 2.0,
            horizontalMove: false,
          );
          if (slideX != 0.0) {
            final nudge = math.min(moveDist, slideX.abs()) * slideX.sign;
            if (_canOccupyWorldBox(_worldPos.x + nudge, _worldPos.y)) {
              _worldPos.x += nudge;
            }
          }
        }
      }
    }

    final moved = math.sqrt(
      (_worldPos.x - startX) * (_worldPos.x - startX) +
          (_worldPos.y - startY) * (_worldPos.y - startY),
    );
    _isMovingVisual = moved > 1e-4;
    if (_isMovingVisual) {
      _stridePhase =
          (_stridePhase + (moved / tileWidth) * strideCyclesPerTile) % 1.0;
      _logicalCell = GridCell(
        (_worldPos.x / tileWidth).floor().clamp(0, passageGrid.width - 1),
        (_worldPos.y / tileHeight).floor().clamp(0, passageGrid.height - 1),
        _logicalCell.elevation,
      );
    } else {
      _stridePhase = 0.0;
    }
  }

  double _probePerpendicularCornerSlide({
    required double targetX,
    required double currentY,
    required bool horizontalMove,
  }) {
    const samples = 4;
    for (var s = 1; s <= samples; s++) {
      final offset = (cornerSlideTolerance * s) / samples;
      if (horizontalMove) {
        final negOpen = _canOccupyWorldBox(targetX, currentY - offset);
        final posOpen = _canOccupyWorldBox(targetX, currentY + offset);
        if (negOpen && !posOpen) {
          return -offset;
        }
        if (posOpen && !negOpen) {
          return offset;
        }
      } else {
        final negOpen = _canOccupyWorldBox(targetX - offset, currentY);
        final posOpen = _canOccupyWorldBox(targetX + offset, currentY);
        if (negOpen && !posOpen) {
          return -offset;
        }
        if (posOpen && !negOpen) {
          return offset;
        }
      }
    }
    return 0.0;
  }

  bool _canOccupyWorldBox(double cx, double cy) {
    final left = cx - hitboxHalfWidth;
    final right = cx + hitboxHalfWidth - 1e-4;
    final top = cy - hitboxHalfHeight;
    final bottom = cy + hitboxHalfHeight - 1e-4;

    if (left < 0.0 ||
        top < 0.0 ||
        right >= passageGrid.width * tileWidth ||
        bottom >= passageGrid.height * tileHeight) {
      return false;
    }

    final minCol = (left / tileWidth).floor();
    final maxCol = (right / tileWidth).floor();
    final minRow = (top / tileHeight).floor();
    final maxRow = (bottom / tileHeight).floor();

    for (var r = minRow; r <= maxRow; r++) {
      for (var c = minCol; c <= maxCol; c++) {
        final fl = passageGrid.flagsAt(c, r, elevation: _logicalCell.elevation);
        if ((fl & TilePassageFlags.passAll4) == 0) {
          return false;
        }
        if (isCellOccupied != null &&
            isCellOccupied!(c, r, _logicalCell.elevation) &&
            (c != _logicalCell.col || r != _logicalCell.row)) {
          return false;
        }
      }
    }
    return true;
  }

  void _advanceMoveRoute(double dt) {
    final route = _activeRoute;
    if (route == null || route.commands.isEmpty) {
      _activeRoute = null;
      _isMovingVisual = false;
      return;
    }

    if (_routeWaitTimer > 0.0) {
      _routeWaitTimer -= dt;
      if (_routeWaitTimer > 1e-7) {
        return;
      }
      _routeWaitTimer = 0.0;
    }

    var guard = 0;
    while (_activeRoute != null &&
        !_isSteppingTile &&
        !_isJumping &&
        _routeWaitTimer <= 0.0 &&
        guard < 32) {
      guard++;
      if (_routeCursor >= route.commands.length) {
        if (route.repeat) {
          _routeCursor = 0;
        } else {
          _activeRoute = null;
          _isMovingVisual = false;
          _stridePhase = 0.0;
          return;
        }
      }

      final cmd = route.commands[_routeCursor];
      switch (cmd.kind) {
        case MoveRouteCommandKind.stepCardinal:
          if (tryBeginStep(cmd.direction)) {
            _routeCursor++;
            return;
          } else if (route.skipIfBlocked) {
            _routeCursor++;
          } else {
            _isMovingVisual = false;
            return;
          }
        case MoveRouteCommandKind.turnCardinal:
          facing = cmd.direction;
          _routeCursor++;
        case MoveRouteCommandKind.turnTowardPoint:
          facing = _dominantCardinal(
            cmd.targetX - _worldPos.x,
            cmd.targetY - _worldPos.y,
          );
          _routeCursor++;
        case MoveRouteCommandKind.turnAwayFromPoint:
          facing = _dominantCardinal(
            _worldPos.x - cmd.targetX,
            _worldPos.y - cmd.targetY,
          );
          _routeCursor++;
        case MoveRouteCommandKind.jumpOffset:
          _routeCursor++;
          final dstCol = (_logicalCell.col + cmd.dx).clamp(
            0,
            passageGrid.width - 1,
          );
          final dstRow = (_logicalCell.row + cmd.dy).clamp(
            0,
            passageGrid.height - 1,
          );
          if (cmd.dx != 0 || cmd.dy != 0) {
            facing = _dominantCardinal(cmd.dx.toDouble(), cmd.dy.toDouble());
          }
          _stepStartPos.setFrom(_worldPos);
          _stepTargetPos.setValues(
            (dstCol + 0.5) * tileWidth,
            (dstRow + 0.5) * tileHeight,
          );
          _logicalCell = GridCell(dstCol, dstRow, _logicalCell.elevation);
          _jumpArcHeightPx = cmd.arcHeightPx;
          _jumpDuration = math.max(0.05, cmd.duration);
          _jumpElapsed = 0.0;
          _isJumping = true;
          _isMovingVisual = true;
          return;
        case MoveRouteCommandKind.waitSeconds:
          _routeCursor++;
          _routeWaitTimer = math.max(0.0, cmd.duration);
          _isMovingVisual = false;
          if (_routeWaitTimer > 0.0) {
            return;
          }
        case MoveRouteCommandKind.setThrough:
          through = cmd.flag;
          _routeCursor++;
      }
    }
  }

  static GridCardinalDirection _dominantCardinal(double dx, double dy) {
    if (dx.abs() >= dy.abs()) {
      return dx >= 0 ? GridCardinalDirection.east : GridCardinalDirection.west;
    }
    return dy >= 0 ? GridCardinalDirection.south : GridCardinalDirection.north;
  }
}
