import 'package:meta/meta.dart';

/// {@template light_grid_settings}
/// How the passes of a `World3D` shade more point and spot lights than the
/// light blocks hold (8 point and 4 spot lights): set as `World3D.lightGrid`.
///
/// ```dart
/// world.lightGrid = const LightGridSettings();
/// ```
///
/// When a pass has more point lights (or more spot lights) than its block
/// holds, every one of them that has a `range` and casts no shadows goes into
/// a grid of cubic cells in world space instead: each cell lists the lights
/// whose reach (their sphere, and for a spot light its cone) touches it, and
/// a fragment shades the lights of its own cell after those of the block. The
/// lights without a range and those that cast shadows stay in the blocks,
/// chosen among themselves as without a grid, so shadows do not change. The
/// work of a fragment follows the number of lights that reach its cell, not
/// the number of lights in the scene.
///
/// The grid covers the reach of its lights, cut to `World3D.sceneBounds`
/// (and to the view of the pass when it would need more than [maxCells]
/// cells). It is built on the CPU once per pass (in time proportional to the
/// lights and the cells they touch, without allocating once warm; a pass
/// whose lights did not change reuses it) and read by the fragment stage
/// from one `RGBA32F` texture, uploaded only when its contents change. A
/// pass whose lights fit the blocks uses no grid and renders exactly the
/// pixels it renders without one, unless [beyondLimitsOnly] is `false`.
/// {@endtemplate}
@immutable
class const LightGridSettings({
  /// The edge of a cell in world units, or `null` (the default) to choose it
  /// from the lights: the power of two nearest the geometric mean of the
  /// `range`s of the lights of the grid. Cells about as large as the lights'
  /// ranges keep the lists short; a fixed size keeps the grid from changing
  /// as lights come and go. It doubles while the grid would have more than
  /// [maxCells] cells, or more lists than its texture holds.
  final double? cellSize,

  /// The largest number of cells (`1` to `65536`), `4096` by default. The
  /// grid covers the reach of its lights; when that needs more cells, it is
  /// cut to what the camera of the pass can see, and its cells grow if it
  /// still needs more.
  final int maxCells = 4096,

  /// The largest number of lights in the grid (`1` to `16384`), `1024` by
  /// default. Beyond it, the lights of the least `intensity * range²` (times
  /// the brightness of their color) are left out of the pass.
  final int maxLights = 1024,

  /// The largest number of point lights a cell lists (`1` to
  /// [maxPointLightsPerCellLimit]), which bounds the work of a fragment.
  /// Beyond it, the lights that light the cell the least (at the point of
  /// the cell nearest them) are left out of that cell.
  final int maxPointLightsPerCell = maxPointLightsPerCellLimit,

  /// The largest number of spot lights a cell lists (`1` to
  /// [maxSpotLightsPerCellLimit]), chosen like [maxPointLightsPerCell].
  final int maxSpotLightsPerCell = maxSpotLightsPerCellLimit,

  /// Whether the grid is used only by passes with more point (or spot)
  /// lights than the blocks hold, `true` by default: a pass within the
  /// limits then renders the pixels it renders without a grid. With `false`,
  /// the lights with a range always go into the grid, so that each costs only
  /// the pixels it reaches, however few lights the pass has.
  final bool beyondLimitsOnly = true,
}) {
  /// {@macro light_grid_settings}
  this
    : assert(
        cellSize == null || cellSize > 0,
        'cellSize must be positive',
      ),
      assert(
        maxCells >= 1 && maxCells <= 65536,
        'maxCells must be in 1..65536',
      ),
      assert(
        maxLights >= 1 && maxLights <= 16384,
        'maxLights must be in 1..16384',
      ),
      assert(
        maxPointLightsPerCell >= 1 &&
            maxPointLightsPerCell <= maxPointLightsPerCellLimit,
        'maxPointLightsPerCell must be in 1..$maxPointLightsPerCellLimit',
      ),
      assert(
        maxSpotLightsPerCell >= 1 &&
            maxSpotLightsPerCell <= maxSpotLightsPerCellLimit,
        'maxSpotLightsPerCell must be in 1..$maxSpotLightsPerCellLimit',
      );

  /// The most point lights a cell can list: the bound of the loop of the
  /// fragment stages (`LIGHT_GRID_POINT_LIGHTS_PER_CELL` in
  /// `flame_3d/light_grid.glsl`).
  static const int maxPointLightsPerCellLimit = 32;

  /// The most spot lights a cell can list (`LIGHT_GRID_SPOT_LIGHTS_PER_CELL`
  /// in `flame_3d/light_grid.glsl`).
  static const int maxSpotLightsPerCellLimit = 16;

  @override
  bool operator ==(Object other) =>
      other is LightGridSettings &&
      other.cellSize == cellSize &&
      other.maxCells == maxCells &&
      other.maxLights == maxLights &&
      other.maxPointLightsPerCell == maxPointLightsPerCell &&
      other.maxSpotLightsPerCell == maxSpotLightsPerCell &&
      other.beyondLimitsOnly == beyondLimitsOnly;

  @override
  int get hashCode => Object.hash(
    cellSize,
    maxCells,
    maxLights,
    maxPointLightsPerCell,
    maxSpotLightsPerCell,
    beyondLimitsOnly,
  );

  @override
  String toString() =>
      'LightGridSettings(cellSize: $cellSize, maxCells: $maxCells, '
      'maxLights: $maxLights, maxPointLightsPerCell: $maxPointLightsPerCell, '
      'maxSpotLightsPerCell: $maxSpotLightsPerCell, '
      'beyondLimitsOnly: $beyondLimitsOnly)';
}
