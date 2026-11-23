import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show PixelFormat;

import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/src/graphics/light_culling_math.dart';
import 'package:meta/meta.dart';

part 'light_grid_3d_packing.dart';

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
  // Fields accessed by part file packing logic.
  Int32List _spotCounts = Int32List(64);
  Float64List _power = Float64List(64);
  Float64List _powerScratch = Float64List(64);
  final _LightGridTextureRing _textureRing = _LightGridTextureRing();

  /// Test hook exposing [coneIntersectsSphereFast] for equivalence tests.
  @visibleForTesting
  static bool coneReachesForTest(
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
    final outerEps = outer + 1e-3;
    final sinA = math.sin(outerEps);
    final cosA = math.cos(outerEps);
    return coneIntersectsSphereFast(
      x,
      y,
      z,
      ax,
      ay,
      az,
      outerEps,
      sinA,
      cosA,
      cosA * cosA,
      sinA * sinA,
      cx,
      cy,
      cz,
      radius,
    );
  }

  /// The texture holding [texels] for [backend], uploaded when its contents
  /// changed since it was last uploaded (or the GPU device was lost).
  Texture texture(GpuBackend backend) =>
      _textureRing.uploadIfChanged(backend, _texels, _contentVersion, stats);
}
