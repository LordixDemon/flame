import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show PixelFormat;

import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';

/// {@template light_grid_stats}
/// What the light grid of the last camera pass of a `RenderContext3D` held,
/// see [LightGridSettings] and `RenderContext3D.lightGridStats`.
///
/// The values are those of the last pass that read the grid (a pass whose
/// shaders read no grid leaves them as they were); [active] is `false` when
/// that pass used no grid.
/// {@endtemplate}
class LightGridStats() {
  /// Whether the last pass shaded lights from a grid.
  bool active = false;

  /// The edge of a cell, in world units.
  double cellSize = 0;

  /// The number of cells along x.
  int cellsX = 0;

  /// The number of cells along y.
  int cellsY = 0;

  /// The number of cells along z.
  int cellsZ = 0;

  /// The number of point lights in the grid.
  int pointLights = 0;

  /// The number of spot lights in the grid.
  int spotLights = 0;

  /// The number of lights the cells list, summed over the cells.
  int entries = 0;

  /// The number of cells that list at least one light.
  int occupiedCells = 0;

  /// The most point lights a cell lists.
  int maxPointLightsInCell = 0;

  /// The most spot lights a cell lists.
  int maxSpotLightsInCell = 0;

  /// The number of times a light that reaches a cell was left out of it
  /// because the cell was full (`LightGridSettings.maxPointLightsPerCell`
  /// and `maxSpotLightsPerCell`), summed over the cells.
  int droppedEntries = 0;

  /// The number of lights left out of the pass because the grid was full
  /// (`LightGridSettings.maxLights`).
  int droppedLights = 0;

  /// Whether the grid was cut to what the camera of the pass sees, because
  /// the reach of its lights needed more than `LightGridSettings.maxCells`
  /// cells.
  bool clippedToView = false;

  /// The width of the texture the shaders read, in texels.
  int textureWidth = 0;

  /// The height of the texture the shaders read, in texels.
  int textureHeight = 0;

  /// The number of texels the grid uses (cells and lights).
  int usedTexels = 0;

  /// How many times the grid was built, since the context was created: a
  /// pass whose lights did not change reuses the grid of before.
  int builds = 0;

  /// How many times the texture was uploaded, since the context was
  /// created: only when its contents change.
  int uploads = 0;

  /// The number of cells.
  int get cells => cellsX * cellsY * cellsZ;

  /// The average number of lights listed by the cells that list any.
  double get averageLightsPerOccupiedCell =>
      occupiedCells == 0 ? 0 : entries / occupiedCells;

  void _clearGrid() {
    active = false;
    cellSize = 0;
    cellsX = cellsY = cellsZ = 0;
    pointLights = spotLights = 0;
    entries = occupiedCells = 0;
    maxPointLightsInCell = maxSpotLightsInCell = 0;
    droppedEntries = droppedLights = 0;
    clippedToView = false;
    usedTexels = 0;
  }

  @override
  String toString() =>
      'LightGridStats(active: $active, cellSize: $cellSize, '
      'cells: ${cellsX}x${cellsY}x$cellsZ, pointLights: $pointLights, '
      'spotLights: $spotLights, entries: $entries, occupiedCells: '
      '$occupiedCells, maxPointLightsInCell: $maxPointLightsInCell, '
      'maxSpotLightsInCell: $maxSpotLightsInCell, droppedEntries: '
      '$droppedEntries, droppedLights: $droppedLights, clippedToView: '
      '$clippedToView, texture: ${textureWidth}x$textureHeight, '
      'usedTexels: $usedTexels, builds: $builds, uploads: $uploads)';
}

/// {@template light_grid_3d}
/// Bins the point and spot lights of a render pass into a grid of cubic
/// cells in world space, for the fragment stages to shade only the lights
/// that reach their cell (see [LightGridSettings]).
///
/// `RenderContext3D` owns one and builds it once per pass that needs it;
/// [build] can also be used on its own, to inspect a grid.
///
/// The grid is one `RGBA32F` texture of [textureWidth] texels per row, read
/// with nearest filtering at texel centers (`flame_3d/light_grid.glsl`):
///
/// - texel `c` of the first [LightGridStats.cells] texels is the header of
///   cell `c = x + cellsX * (y + cellsY * z)`: `(first point light texel,
///   point light count, first spot light texel, spot light count)`;
/// - a point light of a cell takes two texels, `(position, range)` and
///   `(color, intensity)`; a spot light four, `(position, range)`,
///   `(color, intensity)`, `(direction towards the light, specular)` and
///   `(cos outer, 1 / (cos inner - cos outer), 0, 0)`: the values the
///   `Lights` and `SpotLights` blocks hold for them;
/// - each cell's lights follow one another in the order of the lights of the
///   pass, so a fragment adds them up in the order a block would.
/// {@endtemplate}
class LightGrid3D() {
  /// The width of the texture, in texels.
  static const int textureWidth = 256;

  /// The most texels the texture holds (a 256 x 512 texture): beyond, the
  /// cells grow until the grid fits.
  static const int maxTexels = textureWidth * 512;

  /// What the last [build] held.
  final LightGridStats stats = LightGridStats();

  /// The world position of the corner of cell `(0, 0, 0)`.
  final Vector3 origin = Vector3.zero();

  /// Whether the last [build] put any light in the grid.
  bool get hasLights => _texelCount > 0 && stats.entries > 0;

  /// The texels of the grid, 4 floats each, [textureWidth] per row: the
  /// first [LightGridStats.usedTexels] are in use, the rest of the last row
  /// up to [LightGridStats.textureHeight] rows are zero.
  Float32List get texels => _texels;

  /// Increases every time a [build] changes the contents of [texels].
  int get contentVersion => _contentVersion;

  // The lights of the grid, in the order of the lights of the pass: their
  // index in that list, kind (0 point, 1 spot) and values, see _stride.
  static const int _stride = 16;
  Int32List _lightIndex = Int32List(64);
  Uint8List _lightKind = Uint8List(64);
  Float64List _light = Float64List(64 * _stride);
  int _lightCount = 0;

  // The inputs of the last build, to tell when a build would give the same
  // grid: the values of its lights, and the settings and view.
  Float64List _lastLight = Float64List(0);
  Int32List _lastIndex = Int32List(0);
  Uint8List _lastKind = Uint8List(0);
  int _lastCount = -1;
  LightGridSettings? _lastSettings;
  final Float64List _lastView = Float64List(16);
  bool _lastViewUsed = false;

  // Candidate (cell, light) pairs, per kind, and the cells' runs.
  Int32List _pointCells = Int32List(256);
  Int32List _pointLights = Int32List(256);
  int _pointPairs = 0;
  Int32List _spotCells = Int32List(256);
  Int32List _spotLights = Int32List(256);
  int _spotPairs = 0;
  Int32List _cellCounts = Int32List(64);
  Int32List _cellStarts = Int32List(64);
  Int32List _ordered = Int32List(256);

  // The lights chosen for a full cell.
  final Int32List _chosen = Int32List(
    LightGridSettings.maxPointLightsPerCellLimit,
  );
  final Float64List _chosenScores = Float64List(
    LightGridSettings.maxPointLightsPerCellLimit,
  );

  Float32List _texels = Float32List(textureWidth * 4);
  int _texelCount = 0;
  int _contentVersion = 0;

  final Matrix4 _inverse = Matrix4.zero();
  final Vector4 _corner = Vector4.zero();

  int _lastRawCount = -1;
  List<Light>? _lastLightsRef;
  int? _lastLightsVersion;
  int _lastCameraMask = 0;
  bool _lastPoints = false;
  bool _lastSpots = false;

  /// Builds the grid of the point lights (with [points]) and spot lights
  /// (with [spots]) of [lights] that a pass of [cameraMask] shades and that
  /// can go into a grid: those with a `range` above zero that cast no
  /// shadows and have an intensity (see [binnable]).
  ///
  /// [bounds], when given, holds everything the pass draws: the grid covers
  /// only the part of it the lights reach. [viewProjection] is the
  /// `projection * view` of the camera of the pass: the grid is cut to what
  /// it sees when it would need more than `settings.maxCells` cells.
  ///
  /// Passing [lightsVersion] (such as `World3D.lightsVersion`) lets consecutive
  /// builds skip light gathering in O(1) when the light list, mask, flags,
  /// settings, bounds, and view have not changed.
  ///
  /// Returns whether the contents of [texels] changed. A build whose lights,
  /// settings, bounds and view are those of the previous one changes
  /// nothing.
  bool build({
    required List<Light> lights,
    required int cameraMask,
    required LightGridSettings settings,
    required bool points,
    required bool spots,
    Aabb3? bounds,
    Matrix4? viewProjection,
    int? lightsVersion,
  }) {
    if (bounds == null) {
      _bounds.setAll(0, _noBounds);
    } else {
      final min = bounds.min;
      final max = bounds.max;
      _bounds
        ..[0] = min.x
        ..[1] = min.y
        ..[2] = min.z
        ..[3] = max.x
        ..[4] = max.y
        ..[5] = max.z;
    }
    if (lightsVersion != null &&
        lightsVersion == _lastLightsVersion &&
        identical(lights, _lastLightsRef) &&
        lights.length == _lastRawCount &&
        cameraMask == _lastCameraMask &&
        points == _lastPoints &&
        spots == _lastSpots &&
        _sameGridEnvelope(settings, viewProjection)) {
      return false;
    }
    _gather(lights, cameraMask, points: points, spots: spots);
    if (_sameInputs(settings, viewProjection)) {
      _lastLightsVersion = lightsVersion;
      _lastLightsRef = lights;
      _lastRawCount = lights.length;
      _lastCameraMask = cameraMask;
      _lastPoints = points;
      _lastSpots = spots;
      return false;
    }
    _lastLightsVersion = lightsVersion;
    _lastLightsRef = lights;
    _lastRawCount = lights.length;
    _lastCameraMask = cameraMask;
    _lastPoints = points;
    _lastSpots = spots;
    _keepInputs(settings, viewProjection);
    stats.builds++;
    _bin(settings, viewProjection);
    _contentVersion++;
    return true;
  }

  /// Whether [light] can go into a grid: a point light whose intensity is
  /// not zero, or a spot light whose intensity is above zero, with a
  /// `range` above zero and without `shadows`.
  static bool binnable(Light light) {
    final source = light.source;
    if (source is PointLight) {
      final range = source.range;
      return source.shadows == null &&
          range != null &&
          range > 0 &&
          source.intensity != 0;
    }
    if (source is SpotLight) {
      final range = source.range;
      return source.shadows == null &&
          range != null &&
          range > 0 &&
          source.intensity > 0;
    }
    return false;
  }

  void _gather(
    List<Light> lights,
    int cameraMask, {
    required bool points,
    required bool spots,
  }) {
    var count = 0;
    for (var i = 0; i < lights.length; i++) {
      final light = lights[i];
      if ((light.lightMask & cameraMask) == 0 || !binnable(light)) {
        continue;
      }
      final source = light.source;
      final isSpot = source is SpotLight;
      if (isSpot ? !spots : !points) {
        continue;
      }
      if (count == _lightIndex.length) {
        _growLights(count * 2);
      }
      final o = count * _stride;
      final data = _light;
      final position = light.position;
      final color = source.color;
      data
        ..[o] = position.x
        ..[o + 1] = position.y
        ..[o + 2] = position.z
        ..[o + 4] = color.r
        ..[o + 5] = color.g
        ..[o + 6] = color.b
        ..[o + 7] = source.intensity;
      if (source is SpotLight) {
        // The values RenderContext3D.writeSpotLightsUniforms writes.
        final dir = light.direction(_direction);
        final outer = source.outerConeAngle.clamp(0.001, math.pi * 0.999);
        final inner = source.innerConeAngle.clamp(0.0, outer - 1e-4);
        final cosOuter = math.cos(outer);
        data
          ..[o + 3] = source.range!
          ..[o + 8] = -dir.x
          ..[o + 9] = -dir.y
          ..[o + 10] = -dir.z
          ..[o + 11] = source.specular
          ..[o + 12] = cosOuter
          ..[o + 13] = 1.0 / math.max(math.cos(inner) - cosOuter, 1e-4)
          ..[o + 14] = outer;
      } else {
        data
          ..[o + 3] = (source as PointLight).range!
          ..[o + 8] = 0
          ..[o + 9] = 0
          ..[o + 10] = 0
          ..[o + 11] = 0
          ..[o + 12] = 0
          ..[o + 13] = 0
          ..[o + 14] = 0;
      }
      data[o + 15] = 0;
      _lightIndex[count] = i;
      _lightKind[count] = isSpot ? 1 : 0;
      count++;
    }
    _lightCount = count;
  }

  static final Vector3 _direction = Vector3.zero();

  void _growLights(int capacity) {
    _lightIndex = Int32List(capacity)
      ..setRange(0, _lightIndex.length, _lightIndex);
    _lightKind = Uint8List(capacity)
      ..setRange(0, _lightKind.length, _lightKind);
    _light = Float64List(capacity * _stride)
      ..setRange(0, _light.length, _light);
  }

  // The bounds of the build (min, max), infinite without.
  final Float64List _bounds = Float64List(6);
  final Float64List _lastBounds = Float64List(6);
  static final Float64List _noBounds = Float64List.fromList([
    -double.infinity,
    -double.infinity,
    -double.infinity,
    double.infinity,
    double.infinity,
    double.infinity,
  ]);

  bool _sameGridEnvelope(LightGridSettings settings, Matrix4? viewProjection) {
    if (_lastCount < 0 || _lastSettings != settings) {
      return false;
    }
    for (var i = 0; i < 6; i++) {
      if (_bounds[i] != _lastBounds[i]) {
        return false;
      }
    }
    if (_lastViewUsed) {
      if (viewProjection == null) {
        return false;
      }
      final m = viewProjection.storage;
      for (var i = 0; i < 16; i++) {
        if (m[i] != _lastView[i]) {
          return false;
        }
      }
    }
    return true;
  }

  bool _sameInputs(LightGridSettings settings, Matrix4? viewProjection) {
    if (_lastCount != _lightCount ||
        !_sameGridEnvelope(settings, viewProjection)) {
      return false;
    }
    for (var i = 0; i < _lightCount; i++) {
      if (_lastIndex[i] != _lightIndex[i] || _lastKind[i] != _lightKind[i]) {
        return false;
      }
    }
    final n = _lightCount * _stride;
    for (var i = 0; i < n; i++) {
      if (_lastLight[i] != _light[i]) {
        return false;
      }
    }
    return true;
  }

  void _keepInputs(LightGridSettings settings, Matrix4? viewProjection) {
    if (_lastIndex.length < _lightCount) {
      _lastIndex = Int32List(_lightIndex.length);
      _lastKind = Uint8List(_lightIndex.length);
      _lastLight = Float64List(_light.length);
    }
    _lastIndex.setRange(0, _lightCount, _lightIndex);
    _lastKind.setRange(0, _lightCount, _lightKind);
    _lastLight.setRange(0, _lightCount * _stride, _light);
    _lastCount = _lightCount;
    _lastSettings = settings;
    _lastBounds.setAll(0, _bounds);
    if (viewProjection != null) {
      final m = viewProjection.storage;
      for (var i = 0; i < 16; i++) {
        _lastView[i] = m[i];
      }
    }
    // Set by _bin when the grid is cut to the view.
    _lastViewUsed = false;
  }

  // The margin added to the reach of every light, so that a fragment whose
  // cell the shader finds with float32 arithmetic is in a cell that lists
  // every light reaching it: a light that does not reach a fragment adds
  // exactly nothing to it, so a cell may list more lights than reach it,
  // never fewer.
  static double _margin(double cellSize, double x, double y, double z) =>
      cellSize * 1e-3 + (x.abs() + y.abs() + z.abs()) * 1e-5 + 1e-6;

  void _bin(LightGridSettings settings, Matrix4? viewProjection) {
    final s = stats.._clearGrid();
    s.textureWidth = textureWidth;
    _texelCount = 0;
    final count = _lightCount;
    if (count == 0) {
      _finishTexels(0);
      return;
    }

    // The cell size: given, or the power of two nearest the geometric mean
    // of the ranges.
    var cell = settings.cellSize ?? 0;
    if (cell <= 0) {
      var logSum = 0.0;
      for (var k = 0; k < count; k++) {
        logSum += math.log(_light[k * _stride + 3]);
      }
      final mean = logSum / count / math.ln2;
      cell = math.pow(2.0, mean.roundToDouble()).toDouble();
    }

    // The box the lights reach.
    var minX = double.infinity;
    var minY = double.infinity;
    var minZ = double.infinity;
    var maxX = -double.infinity;
    var maxY = -double.infinity;
    var maxZ = -double.infinity;
    for (var k = 0; k < count; k++) {
      final o = k * _stride;
      final x = _light[o];
      final y = _light[o + 1];
      final z = _light[o + 2];
      final r = _light[o + 3] + _margin(cell, x, y, z);
      minX = math.min(minX, x - r);
      minY = math.min(minY, y - r);
      minZ = math.min(minZ, z - r);
      maxX = math.max(maxX, x + r);
      maxY = math.max(maxY, y + r);
      maxZ = math.max(maxZ, z + r);
    }

    // Cut it to what the pass draws (grown by the margin).
    final grow = _margin(cell, 0, 0, 0);
    minX = math.max(minX, _bounds[0] - grow);
    minY = math.max(minY, _bounds[1] - grow);
    minZ = math.max(minZ, _bounds[2] - grow);
    maxX = math.min(maxX, _bounds[3] + grow);
    maxY = math.min(maxY, _bounds[4] + grow);
    maxZ = math.min(maxZ, _bounds[5] + grow);
    if (minX >= maxX || minY >= maxY || minZ >= maxZ) {
      _finishTexels(0);
      return;
    }

    if (_cells(minX, minY, minZ, maxX, maxY, maxZ, cell) > settings.maxCells &&
        viewProjection != null) {
      // Cut the box to what the camera sees (one cell more on every side).
      if (_viewBounds(viewProjection, cell)) {
        minX = math.max(minX, _viewMin.x);
        minY = math.max(minY, _viewMin.y);
        minZ = math.max(minZ, _viewMin.z);
        maxX = math.min(maxX, _viewMax.x);
        maxY = math.min(maxY, _viewMax.y);
        maxZ = math.min(maxZ, _viewMax.z);
        s.clippedToView = true;
        _lastViewUsed = true;
        if (minX >= maxX || minY >= maxY || minZ >= maxZ) {
          _finishTexels(0);
          return;
        }
      }
    }
    while (_cells(minX, minY, minZ, maxX, maxY, maxZ, cell) >
        settings.maxCells) {
      cell *= 2;
    }

    // Lay out the grid; if its lists do not fit the texture, grow the
    // cells.
    for (;;) {
      final x0 = (minX / cell).floorToDouble();
      final y0 = (minY / cell).floorToDouble();
      final z0 = (minZ / cell).floorToDouble();
      final nx = _span(minX, maxX, cell).toInt();
      final ny = _span(minY, maxY, cell).toInt();
      final nz = _span(minZ, maxZ, cell).toInt();
      origin.setValues(x0 * cell, y0 * cell, z0 * cell);
      s
        ..cellSize = cell
        ..cellsX = nx
        ..cellsY = ny
        ..cellsZ = nz;
      final texels = _layOut(settings, minX, minY, minZ, maxX, maxY, maxZ);
      if (texels <= maxTexels) {
        break;
      }
      cell *= 2;
    }
  }

  // The number of cells of edge [size] of the snapped grid over the box.
  static double _cells(
    double minX,
    double minY,
    double minZ,
    double maxX,
    double maxY,
    double maxZ,
    double size,
  ) =>
      _span(minX, maxX, size) *
      _span(minY, maxY, size) *
      _span(minZ, maxZ, size);

  // The number of cells of edge [size] that the snapped grid needs from
  // [min] to [max].
  static double _span(double min, double max, double size) {
    final first = (min / size).floorToDouble();
    final last = (max / size).floorToDouble();
    return math.max(1.0, last - first + 1);
  }

  final Vector3 _viewMin = Vector3.zero();
  final Vector3 _viewMax = Vector3.zero();

  // The world box of the corners of the view of [viewProjection], grown by
  // [grow]; false when the matrix cannot be inverted.
  bool _viewBounds(Matrix4 viewProjection, double grow) {
    final inverse = _inverse..setFrom(viewProjection);
    if (inverse.invert() == 0) {
      return false;
    }
    _viewMin.setValues(double.infinity, double.infinity, double.infinity);
    _viewMax.setValues(
      -double.infinity,
      -double.infinity,
      -double.infinity,
    );
    for (var c = 0; c < 8; c++) {
      _corner.setValues(
        (c & 1) == 0 ? -1 : 1,
        (c & 2) == 0 ? -1 : 1,
        (c & 4) == 0 ? 0 : 1,
        1,
      );
      inverse.transform(_corner);
      final w = _corner.w;
      if (w.abs() < 1e-12) {
        return false;
      }
      final x = _corner.x / w;
      final y = _corner.y / w;
      final z = _corner.z / w;
      _viewMin.setValues(
        math.min(_viewMin.x, x),
        math.min(_viewMin.y, y),
        math.min(_viewMin.z, z),
      );
      _viewMax.setValues(
        math.max(_viewMax.x, x),
        math.max(_viewMax.y, y),
        math.max(_viewMax.z, z),
      );
    }
    _viewMin.setValues(
      _viewMin.x - grow,
      _viewMin.y - grow,
      _viewMin.z - grow,
    );
    _viewMax.setValues(
      _viewMax.x + grow,
      _viewMax.y + grow,
      _viewMax.z + grow,
    );
    return _viewMin.x.isFinite && _viewMax.x.isFinite;
  }

  // Bins the lights into the cells of the grid in [stats] and writes the
  // texels; returns the number of texels needed (the texels are written
  // only when it fits [maxTexels]).
  int _layOut(
    LightGridSettings settings,
    double minX,
    double minY,
    double minZ,
    double maxX,
    double maxY,
    double maxZ,
  ) {
    final s = stats;
    final cell = s.cellSize;
    final nx = s.cellsX;
    final ny = s.cellsY;
    final nz = s.cellsZ;
    final cells = nx * ny * nz;
    final ox = origin.x;
    final oy = origin.y;
    final oz = origin.z;

    // The lights that reach the box, and among them the maxLights of the
    // most power.
    var kept = 0;
    for (var k = 0; k < _lightCount; k++) {
      final o = k * _stride;
      final x = _light[o];
      final y = _light[o + 1];
      final z = _light[o + 2];
      final r = _light[o + 3] + _margin(cell, x, y, z);
      final reaches =
          x + r >= minX &&
          x - r <= maxX &&
          y + r >= minY &&
          y - r <= maxY &&
          z + r >= minZ &&
          z - r <= maxZ;
      _light[o + 15] = reaches ? 1 : 0;
      if (reaches) {
        kept++;
      }
    }
    var dropped = 0;
    if (kept > settings.maxLights) {
      dropped = _keepStrongest(settings.maxLights);
    }

    _pointPairs = 0;
    _spotPairs = 0;
    var points = 0;
    var spots = 0;
    for (var k = 0; k < _lightCount; k++) {
      final o = k * _stride;
      if (_light[o + 15] == 0) {
        continue;
      }
      final x = _light[o];
      final y = _light[o + 1];
      final z = _light[o + 2];
      final range = _light[o + 3];
      final r = range + _margin(cell, x, y, z);
      final isSpot = _lightKind[k] == 1;
      if (isSpot) {
        spots++;
      } else {
        points++;
      }
      final cx0 = math.max(0, ((x - r - ox) / cell).floor());
      final cy0 = math.max(0, ((y - r - oy) / cell).floor());
      final cz0 = math.max(0, ((z - r - oz) / cell).floor());
      final cx1 = math.min(nx - 1, ((x + r - ox) / cell).floor());
      final cy1 = math.min(ny - 1, ((y + r - oy) / cell).floor());
      final cz1 = math.min(nz - 1, ((z + r - oz) / cell).floor());
      final r2 = r * r;
      // The cone of a spot light, against the sphere around a cell.
      final cellRadius = cell * 0.8660254037844386;
      final ax = -_light[o + 8];
      final ay = -_light[o + 9];
      final az = -_light[o + 10];
      final outer = _light[o + 14];
      for (var cz = cz0; cz <= cz1; cz++) {
        final bz0 = oz + cz * cell;
        final dz = z < bz0 ? bz0 - z : (z > bz0 + cell ? z - bz0 - cell : 0.0);
        for (var cy = cy0; cy <= cy1; cy++) {
          final by0 = oy + cy * cell;
          final dy = y < by0
              ? by0 - y
              : (y > by0 + cell ? y - by0 - cell : 0.0);
          for (var cx = cx0; cx <= cx1; cx++) {
            final bx0 = ox + cx * cell;
            final dx = x < bx0
                ? bx0 - x
                : (x > bx0 + cell ? x - bx0 - cell : 0.0);
            if (dx * dx + dy * dy + dz * dz > r2) {
              continue;
            }
            if (isSpot &&
                !_coneReaches(
                  x,
                  y,
                  z,
                  ax,
                  ay,
                  az,
                  outer,
                  bx0 + cell * 0.5,
                  by0 + cell * 0.5,
                  bz0 + cell * 0.5,
                  cellRadius + _margin(cell, x, y, z),
                )) {
              continue;
            }
            final index = cx + nx * (cy + ny * cz);
            if (isSpot) {
              _addSpotPair(index, k);
            } else {
              _addPointPair(index, k);
            }
          }
        }
      }
    }
    s
      ..pointLights = points
      ..spotLights = spots
      ..droppedLights = dropped;

    // The texels: the headers, then each cell's point and spot lights.
    if (_cellCounts.length < cells) {
      _cellCounts = Int32List(cells);
      _cellStarts = Int32List(cells);
    }
    final pointCap = settings.maxPointLightsPerCell;
    final spotCap = settings.maxSpotLightsPerCell;
    var needed = cells;
    // Count first, to know the size.
    final pointsPerCell = _countPairs(_pointCells, _pointPairs, cells);
    for (var c = 0; c < cells; c++) {
      needed += 2 * math.min(pointsPerCell[c], pointCap);
    }
    final spotsPerCell = _countSpotPairs(cells);
    for (var c = 0; c < cells; c++) {
      needed += 4 * math.min(spotsPerCell[c], spotCap);
    }
    if (needed > maxTexels) {
      return needed;
    }
    _ensureTexels(needed);
    final t = _texels..fillRange(0, cells * 4, 0);
    var next = cells;
    var entries = 0;
    var occupied = 0;
    var dropped2 = 0;
    var maxPoints = 0;
    var maxSpots = 0;

    // Point lights.
    _sortPairs(_pointCells, _pointLights, _pointPairs, pointsPerCell, cells);
    for (var c = 0; c < cells; c++) {
      final n = pointsPerCell[c];
      if (n == 0) {
        continue;
      }
      final start = _cellStarts[c];
      final chosen = _choose(c, start, n, pointCap);
      dropped2 += n - chosen;
      maxPoints = math.max(maxPoints, chosen);
      t
        ..[c * 4] = next.toDouble()
        ..[c * 4 + 1] = chosen.toDouble();
      for (var j = 0; j < chosen; j++) {
        final k = n > pointCap ? _chosen[j] : _ordered[start + j];
        final o = k * _stride;
        final at = next * 4;
        t
          ..[at] = _light[o]
          ..[at + 1] = _light[o + 1]
          ..[at + 2] = _light[o + 2]
          ..[at + 3] = _light[o + 3]
          ..[at + 4] = _light[o + 4]
          ..[at + 5] = _light[o + 5]
          ..[at + 6] = _light[o + 6]
          ..[at + 7] = _light[o + 7];
        next += 2;
      }
      entries += chosen;
    }

    // Spot lights.
    _sortPairs(_spotCells, _spotLights, _spotPairs, spotsPerCell, cells);
    for (var c = 0; c < cells; c++) {
      final n = spotsPerCell[c];
      if (n == 0) {
        continue;
      }
      final start = _cellStarts[c];
      final chosen = _choose(c, start, n, spotCap);
      dropped2 += n - chosen;
      maxSpots = math.max(maxSpots, chosen);
      t
        ..[c * 4 + 2] = next.toDouble()
        ..[c * 4 + 3] = chosen.toDouble();
      for (var j = 0; j < chosen; j++) {
        final k = n > spotCap ? _chosen[j] : _ordered[start + j];
        final o = k * _stride;
        final at = next * 4;
        for (var i = 0; i < 8; i++) {
          t[at + i] = _light[o + i];
        }
        t
          ..[at + 8] = _light[o + 8]
          ..[at + 9] = _light[o + 9]
          ..[at + 10] = _light[o + 10]
          ..[at + 11] = _light[o + 11]
          ..[at + 12] = _light[o + 12]
          ..[at + 13] = _light[o + 13]
          ..[at + 14] = 0
          ..[at + 15] = 0;
        next += 4;
      }
      entries += chosen;
    }
    for (var c = 0; c < cells; c++) {
      if (t[c * 4 + 1] > 0 || t[c * 4 + 3] > 0) {
        occupied++;
      }
    }
    s
      ..entries = entries
      ..occupiedCells = occupied
      ..droppedEntries = dropped2
      ..maxPointLightsInCell = maxPoints
      ..maxSpotLightsInCell = maxSpots
      ..active = entries > 0;
    _finishTexels(next);
    return next;
  }

  // Whether the cone of half-angle [outer] along the unit axis (ax, ay, az)
  // from (x, y, z) reaches the sphere of [radius] around (cx, cy, cz).
  static bool _coneReaches(
    double x,
    double y,
    double z,
    double ax,
    double ay,
    double az,
    double outer,
    double cx,
    double cy,
    double cz,
    double radius,
  ) {
    final vx = cx - x;
    final vy = cy - y;
    final vz = cz - z;
    final distance = math.sqrt(vx * vx + vy * vy + vz * vz);
    if (distance <= radius) {
      return true;
    }
    final spread = outer + math.asin(radius / distance) + 1e-3;
    if (spread >= math.pi) {
      return true;
    }
    return (vx * ax + vy * ay + vz * az) >= distance * math.cos(spread);
  }

  void _addPointPair(int cell, int light) {
    if (_pointPairs == _pointCells.length) {
      _pointCells = _grown(_pointCells, _pointPairs * 2);
      _pointLights = _grown(_pointLights, _pointPairs * 2);
    }
    _pointCells[_pointPairs] = cell;
    _pointLights[_pointPairs++] = light;
  }

  void _addSpotPair(int cell, int light) {
    if (_spotPairs == _spotCells.length) {
      _spotCells = _grown(_spotCells, _spotPairs * 2);
      _spotLights = _grown(_spotLights, _spotPairs * 2);
    }
    _spotCells[_spotPairs] = cell;
    _spotLights[_spotPairs++] = light;
  }

  static Int32List _grown(Int32List list, int capacity) =>
      Int32List(capacity)..setRange(0, list.length, list);

  // The number of pairs of each cell, in _cellCounts (points) or
  // _spotCounts.
  Int32List _countPairs(Int32List pairCells, int pairs, int cells) {
    final counts = _cellCounts..fillRange(0, cells, 0);
    for (var i = 0; i < pairs; i++) {
      counts[pairCells[i]]++;
    }
    return counts;
  }

  Int32List _spotCounts = Int32List(64);

  Int32List _countSpotPairs(int cells) {
    if (_spotCounts.length < cells) {
      _spotCounts = Int32List(cells);
    }
    final counts = _spotCounts..fillRange(0, cells, 0);
    for (var i = 0; i < _spotPairs; i++) {
      counts[_spotCells[i]]++;
    }
    return counts;
  }

  // Orders the pairs by cell (stably, so each cell's lights keep their
  // order) into _ordered, each cell's run starting at _cellStarts.
  void _sortPairs(
    Int32List pairCells,
    Int32List pairLights,
    int pairs,
    Int32List counts,
    int cells,
  ) {
    var at = 0;
    for (var c = 0; c < cells; c++) {
      _cellStarts[c] = at;
      at += counts[c];
    }
    if (_ordered.length < pairs) {
      _ordered = Int32List(math.max(pairs, _ordered.length * 2));
    }
    // _cellStarts is used as the cursor, then restored.
    for (var i = 0; i < pairs; i++) {
      final c = pairCells[i];
      _ordered[_cellStarts[c]++] = pairLights[i];
    }
    for (var c = 0; c < cells; c++) {
      _cellStarts[c] -= counts[c];
    }
  }

  // Chooses, among the [n] lights of cell [c] from _ordered[start], the
  // [cap] that light it the most (at its point nearest them), into _chosen
  // in their order; returns how many lights the cell keeps.
  int _choose(int c, int start, int n, int cap) {
    if (n <= cap) {
      return n;
    }
    final s = stats;
    final cell = s.cellSize;
    final nx = s.cellsX;
    final ny = s.cellsY;
    final cx = c % nx;
    final cy = (c ~/ nx) % ny;
    final cz = c ~/ (nx * ny);
    final bx0 = origin.x + cx * cell;
    final by0 = origin.y + cy * cell;
    final bz0 = origin.z + cz * cell;
    var count = 0;
    for (var j = 0; j < n; j++) {
      final k = _ordered[start + j];
      final o = k * _stride;
      final x = _light[o];
      final y = _light[o + 1];
      final z = _light[o + 2];
      final dx = x < bx0 ? bx0 - x : (x > bx0 + cell ? x - bx0 - cell : 0.0);
      final dy = y < by0 ? by0 - y : (y > by0 + cell ? y - by0 - cell : 0.0);
      final dz = z < bz0 ? bz0 - z : (z > bz0 + cell ? z - bz0 - cell : 0.0);
      final fade = math.max(
        0.0,
        1 - math.sqrt(dx * dx + dy * dy + dz * dz) / _light[o + 3],
      );
      final score = _brightness(o) * fade * fade;
      // Keep the cap highest scores; on a tie, the light that comes first.
      int pos;
      if (count < cap) {
        pos = count++;
      } else if (score > _chosenScores[cap - 1]) {
        pos = cap - 1;
      } else {
        continue;
      }
      while (pos > 0 && _chosenScores[pos - 1] < score) {
        _chosenScores[pos] = _chosenScores[pos - 1];
        _chosen[pos] = _chosen[pos - 1];
        pos--;
      }
      _chosenScores[pos] = score;
      _chosen[pos] = k;
    }
    // Back into the order of the lights.
    for (var i = 1; i < count; i++) {
      final k = _chosen[i];
      var j = i - 1;
      while (j >= 0 && _chosen[j] > k) {
        _chosen[j + 1] = _chosen[j];
        j--;
      }
      _chosen[j + 1] = k;
    }
    return count;
  }

  // The intensity of the light at [o] times the brightness of its color.
  double _brightness(int o) =>
      _light[o + 7].abs() *
      (0.2126 * _light[o + 4] +
          0.7152 * _light[o + 5] +
          0.0722 * _light[o + 6]);

  // Leaves out of the grid all but the [max] lights of the most
  // `intensity * range²` among those that reach it (on a tie, those that
  // come first); returns how many it left out.
  int _keepStrongest(int max) {
    if (_power.length < _lightIndex.length) {
      _power = Float64List(_lightIndex.length);
      _powerScratch = Float64List(_lightIndex.length);
    }
    var n = 0;
    for (var k = 0; k < _lightCount; k++) {
      final o = k * _stride;
      if (_light[o + 15] != 0) {
        final range = _light[o + 3];
        final power = _brightness(o) * range * range;
        _power[k] = power;
        _powerScratch[n++] = power;
      } else {
        _power[k] = -1;
      }
    }
    // The power of the max-th strongest light: those above it stay, and
    // as many of those of that power as fit, in their order.
    final threshold = _select(_powerScratch, n, max - 1);
    var above = 0;
    for (var k = 0; k < _lightCount; k++) {
      if (_power[k] > threshold) {
        above++;
      }
    }
    var ties = max - above;
    for (var k = 0; k < _lightCount; k++) {
      final o = k * _stride;
      if (_light[o + 15] == 0) {
        continue;
      }
      final power = _power[k];
      if (power > threshold) {
        continue;
      }
      if (power == threshold && ties > 0) {
        ties--;
        continue;
      }
      _light[o + 15] = 0;
    }
    return n - max;
  }

  Float64List _power = Float64List(64);
  Float64List _powerScratch = Float64List(64);

  // The value that would be at [rank] if the first [n] values of [values]
  // were sorted from the largest down (quickselect; reorders [values]).
  static double _select(Float64List values, int n, int rank) {
    var lo = 0;
    var hi = n - 1;
    while (lo < hi) {
      final pivot = values[(lo + hi) >> 1];
      var i = lo;
      var j = hi;
      while (i <= j) {
        while (values[i] > pivot) {
          i++;
        }
        while (values[j] < pivot) {
          j--;
        }
        if (i <= j) {
          final t = values[i];
          values[i] = values[j];
          values[j] = t;
          i++;
          j--;
        }
      }
      if (rank <= j) {
        hi = j;
      } else if (rank >= i) {
        lo = i;
      } else {
        return values[rank];
      }
    }
    return values[rank];
  }

  void _ensureTexels(int texels) {
    final rows = (texels + textureWidth - 1) ~/ textureWidth;
    var height = 1;
    while (height < rows) {
      height *= 2;
    }
    final floats = height * textureWidth * 4;
    if (_texels.length < floats) {
      _texels = Float32List(floats);
    }
  }

  void _finishTexels(int texels) {
    _ensureTexels(math.max(texels, 1));
    final rows = (math.max(texels, 1) + textureWidth - 1) ~/ textureWidth;
    var height = 1;
    while (height < rows) {
      height *= 2;
    }
    _texels.fillRange(texels * 4, height * textureWidth * 4, 0);
    _texelCount = texels;
    stats
      ..usedTexels = texels
      ..textureHeight = height;
  }

  // The textures holding the grid, written in turn so that a texture a
  // frame in flight may still read is not written: the version of the
  // contents each holds, and the device generation it was written for.
  final List<Texture?> _ring = List.filled(3, null);
  final List<GpuTexture?> _ringGpu = List.filled(3, null);
  final Int32List _ringVersion = Int32List(3)..fillRange(0, 3, -1);
  final Int32List _ringGeneration = Int32List(3)..fillRange(0, 3, -1);
  final List<GpuBackend?> _ringBackend = List.filled(3, null);
  int _ringNext = 0;

  /// The texture holding [texels] for [backend], uploaded when its contents
  /// changed since it was last uploaded (or the GPU device was lost).
  Texture texture(GpuBackend backend) {
    final generation = GpuBackend.deviceGeneration;
    for (var i = 0; i < 3; i++) {
      if (_ringVersion[i] == _contentVersion &&
          _ringGeneration[i] == generation &&
          identical(_ringBackend[i], backend)) {
        return _ring[i]!;
      }
    }
    final slot = _ringNext;
    _ringNext = (_ringNext + 1) % 3;
    final height = stats.textureHeight;
    var texture = _ring[slot];
    var gpuTexture = _ringGpu[slot];
    if (texture == null ||
        gpuTexture == null ||
        texture.height != height ||
        !identical(_ringBackend[slot], backend)) {
      gpuTexture = backend.createTexture(
        storageMode: GpuStorageMode.hostVisible,
        width: textureWidth,
        height: height,
        format: GpuPixelFormat.rgbaFloat32,
      );
      texture = Texture(
        null,
        width: textureWidth,
        height: height,
        format: PixelFormat.rgbaFloat32,
        gpuTexture: gpuTexture,
      );
      _ring[slot] = texture;
      _ringGpu[slot] = gpuTexture;
      _ringBackend[slot] = backend;
    }
    gpuTexture.write(
      ByteData.sublistView(_texels, 0, height * textureWidth * 4),
    );
    _ringVersion[slot] = _contentVersion;
    _ringGeneration[slot] = generation;
    stats.uploads++;
    return texture;
  }
}
