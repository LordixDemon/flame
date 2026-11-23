import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/src/extensions/clip_space.dart';
import 'package:flame_3d/src/world_scale/chunked_terrain_3d.dart';

/// Spherical agent/player/creature volume that pushes nearby [FoliageSystem3D]
/// blades outward and flattens them smoothly.
class FoliageInteractor3D({
  required Vector3 position,

  /// Influence radius in world units.
  var double radius = 1.5,

  /// Bend/crush intensity in `[0, 1]`.
  var double strength = 1.0,
}) {
  /// Creates a spherical foliage trample interactor at `position` with
  /// `radius` and `strength` (`[0..1]`).
  this : assert(radius > 0, 'radius must be positive');

  /// World-space center of the trample sphere.
  final Vector3 position = position.clone();
}

/// Optional density callback returning `[0..1]` spawn probability at
/// `(x, y, z)` with surface [normal].
typedef FoliageDensityCallback3D = double Function(
  double x,
  double y,
  double z,
  Vector3 normal,
);

class _FoliageDrawCache() {
  bool valid = false;
  int stateVer = -1;
  int worldVer = -1;
  double camX = 0;
  double camY = 0;
  double camZ = 0;
  double maxDist = -1;
  double fadeStart = -1;
  double windStrength = -1;
  double windFreq = -1;
  double maxBend = -1;
  double windDirX = 0;
  double windDirY = 0;
  final Float32List vp = Float32List(16);
  int visibleCellCount = 0;
  int visibleInstanceCount = 0;
  int bufferVersion = 0;

  bool matches(
    int stateVer,
    int worldVer,
    Vector3 camPos,
    double maxDist,
    double fadeStart,
    double windStrength,
    double windFreq,
    double maxBend,
    Vector2 windDir,
    Float32List currentVp,
  ) =>
      valid &&
      this.stateVer == stateVer &&
      this.worldVer == worldVer &&
      camX == camPos.x &&
      camY == camPos.y &&
      camZ == camPos.z &&
      this.maxDist == maxDist &&
      this.fadeStart == fadeStart &&
      this.windStrength == windStrength &&
      this.windFreq == windFreq &&
      this.maxBend == maxBend &&
      windDirX == windDir.x &&
      windDirY == windDir.y &&
      sameMatrix16(currentVp, vp);

  void store(
    int stateVer,
    int worldVer,
    Vector3 camPos,
    double maxDist,
    double fadeStart,
    double windStrength,
    double windFreq,
    double maxBend,
    Vector2 windDir,
    Float32List currentVp,
    int cellCount,
    int instanceCount,
  ) {
    valid = true;
    this.stateVer = stateVer;
    this.worldVer = worldVer;
    camX = camPos.x;
    camY = camPos.y;
    camZ = camPos.z;
    this.maxDist = maxDist;
    this.fadeStart = fadeStart;
    this.windStrength = windStrength;
    this.windFreq = windFreq;
    this.maxBend = maxBend;
    windDirX = windDir.x;
    windDirY = windDir.y;
    for (var k = 0; k < 16; k++) {
      vp[k] = currentVp[k];
    }
    visibleCellCount = cellCount;
    visibleInstanceCount = instanceCount;
    bufferVersion++;
  }
}

/// High-density GPU-instanced vegetation scatter [Object3D] (`capacity` up to
/// `32,768+` blades/tufts/shrubs).
///
/// Partitions instances into spatial grid cells for `O(visible_cells)` frustum
/// and distance culling, applies per-blade smooth scale-down and deterministic
/// distance density thinning (`0` visual popping), animates wind sway as a
/// CPU shear of each blade's matrix (`instanceData` carries the wind phase,
/// strength, crush and tilt for custom shaders), and deforms blades
/// interactively around [FoliageInteractor3D] spheres with smooth spring
/// recovery.
class FoliageSystem3D({
  Mesh? mesh,
  Material? material,

  /// Maximum number of foliage instances stored in pre-allocated SoA buffers.
  final int capacity = 32768,

  /// Horizontal spatial cell edge length in local units.
  final double cellSize = 16.0,

  /// Maximum camera distance beyond which all foliage is culled.
  var double maxDrawDistance = 96.0,

  /// Fraction of [maxDrawDistance] where smooth density thinning and scale-down
  /// begin.
  var double fadeStartFraction = 0.65,

  /// Wind tip-sway amplitude in local units.
  var double windStrength = 0.14,

  /// Wind angular frequency in radians per second.
  var double windFrequency = 2.2,
  Vector2? windDirection,

  /// Maximum lean of a fully trampled blade (`crush == 1`), applied as a
  /// shear: the tip moves sideways by about `maxBendAngle` times the blade's
  /// height (`1.05` leans it by roughly 45 degrees). Despite the name, it is
  /// not an angle.
  var double maxBendAngle = 1.05,

  /// Exponential attack rate (`s^-1`) when an interactor steps onto blades.
  var double trampleAttackRate = 28.0,

  /// Exponential spring recovery rate (`s^-1`) after an interactor leaves.
  var double trampleSpringRate = 6.5,
  List<FoliageInteractor3D>? interactors,
  super.position,
  super.scale,
  super.rotation,
  super.children,
  super.castsShadows = false,
  super.cameraMask,
}) extends Object3D {
  /// Creates a GPU-instanced foliage scatter system.
  this
    : assert(capacity >= 1, 'capacity must be at least 1'),
      assert(cellSize > 0, 'cellSize must be positive'),
      assert(maxDrawDistance > 0, 'maxDrawDistance must be positive'),
      assert(
        fadeStartFraction >= 0 && fadeStartFraction < 1,
        'fadeStartFraction must be in [0, 1)',
      ) {
    final wLen = this.windDirection.length;
    if (wLen > 1e-8) {
      this.windDirection.scale(1.0 / wLen);
    } else {
      this.windDirection.setValues(1, 0);
    }
    final resolvedMat =
        material ??
        (SpatialMaterial(
          metallic: 0,
          roughness: 0.85,
          doubleSided: true,
        )..renderState = RenderState.opaque);
    this.material = resolvedMat;
    this.mesh = mesh ?? _buildDefaultGrassTuftMesh(resolvedMat);
    _ownsDefaultMesh = mesh == null;
  }

  /// Instanced tuft/blade/shrub [Mesh] (anchored at `y = 0` at its base).
  late final Mesh mesh;

  /// Material shared across all drawn instances.
  late final Material material;

  bool _ownsDefaultMesh = false;

  /// Normalized horizontal `(x, z)` wind travel direction.
  final Vector2 windDirection = windDirection?.clone() ?? Vector2(1.0, 0.35);

  /// Dynamic spherical interactors (player, mounts, rolling boulders) bending
  /// nearby foliage.
  final List<FoliageInteractor3D> interactors = interactors != null
      ? List<FoliageInteractor3D>.of(interactors)
      : <FoliageInteractor3D>[];

  late final Float32List _posX = Float32List(capacity);
  late final Float32List _posY = Float32List(capacity);
  late final Float32List _posZ = Float32List(capacity);
  late final Float32List _yaw = Float32List(capacity);
  late final Float32List _cosYaw = Float32List(capacity);
  late final Float32List _sinYaw = Float32List(capacity);
  late final Float32List _scaleX = Float32List(capacity);
  late final Float32List _scaleY = Float32List(capacity);
  late final Float32List _scaleZ = Float32List(capacity);
  late final Float32List _colorR = Float32List(capacity);
  late final Float32List _colorG = Float32List(capacity);
  late final Float32List _colorB = Float32List(capacity);
  late final Float32List _colorA = Float32List(capacity);
  late final Float32List _windPhase = Float32List(capacity);
  late final Float32List _cosPhase = Float32List(capacity);
  late final Float32List _sinPhase = Float32List(capacity);
  late final Float32List _densityRank = Float32List(capacity);
  late final Float32List _bendX = Float32List(capacity);
  late final Float32List _bendZ = Float32List(capacity);
  late final Float32List _crush = Float32List(capacity);

  late final Float32List _instanceBuffer = Float32List(
    capacity * VertexLayout.instanceStrideInFloats,
  );
  Float32List? _shadowInstanceBuffer;

  int _bladeCount = 0;
  double _windTime = 0;
  bool _cellsDirty = true;
  int _stateVersion = 0;
  bool _anyCellBent = false;

  // Separate draw-cache snapshots for main and shadow passes so shadow passes
  // never thrash the main camera cache (and vice versa).
  final _FoliageDrawCache _mainCache = _FoliageDrawCache();
  final _FoliageDrawCache _shadowCache = _FoliageDrawCache();

  // Active interactor scratch buffers reused across `_updateInteractors`.
  Float64List _activeIx = Float64List(0);
  Float64List _activeIy = Float64List(0);
  Float64List _activeIz = Float64List(0);
  Float64List _activeIr = Float64List(0);
  Float64List _activeIrSq = Float64List(0);
  Float64List _activeIStrength = Float64List(0);
  Int32List _cellInteractors = Int32List(0);

  // Spatial cell CSR structure:
  Int32List _cellOffsets = Int32List(0);
  Int32List _cellCounts = Int32List(0);
  Int32List _cellBladeIndices = Int32List(0);
  Float32List _cellBounds = Float32List(0);
  Uint8List _cellHasBend = Uint8List(0);
  int _cellCount = 0;

  final Aabb3 _localAabb = Aabb3();
  final Aabb3 _cellBoxScratch = Aabb3();
  final Matrix4 _invWorldScratch = Matrix4.identity();
  final Vector3 _localCamScratch = Vector3.zero();

  int _lastVisibleCellCount = 0;
  int _lastVisibleInstanceCount = 0;

  /// Number of scattered/added foliage instances (`<= capacity`).
  int get bladeCount => _bladeCount;

  /// Number of populated spatial cells.
  int get cellCount {
    _ensureSpatialCells();
    return _cellCount;
  }

  /// Number of spatial cells that passed frustum and distance culling in the
  /// most recent visibility build / draw.
  int get lastVisibleCellCount => _lastVisibleCellCount;

  /// Number of individual foliage instances packed in the most recent
  /// visibility build / draw.
  int get lastVisibleInstanceCount => _lastVisibleInstanceCount;

  /// Current accumulated wind time in seconds.
  double get windTime => _windTime;

  /// Removes all scattered blades without deallocating capacity.
  void clear() {
    _bladeCount = 0;
    _cellCount = 0;
    _cellsDirty = true;
    _anyCellBent = false;
    _stateVersion++;
    _mainCache.valid = false;
    _shadowCache.valid = false;
    markAabbDirty();
    markDrawDirty(shadows: castsShadows);
  }

  /// Appends a single blade/tuft instance and returns its index (`-1` if
  /// [capacity] is full).
  int addBlade({
    required Vector3 position,
    double yaw = 0,
    Vector3? bladeScale,
    Color color = const Color(0xFF569E3E),
    double? windPhase,
    double? densityRank,
  }) => _addBladeRaw(
    position.x,
    position.y,
    position.z,
    yaw,
    bladeScale?.x ?? 1.0,
    bladeScale?.y ?? 1.0,
    bladeScale?.z ?? 1.0,
    color.r,
    color.g,
    color.b,
    color.a,
    windPhase,
    densityRank,
    notify: true,
  );

  int _addBladeRaw(
    double px,
    double py,
    double pz,
    double yaw,
    double sx,
    double sy,
    double sz,
    double r,
    double g,
    double b,
    double a,
    double? windPhase,
    double? densityRank, {
    required bool notify,
  }) {
    if (_bladeCount >= capacity) {
      return -1;
    }
    final i = _bladeCount++;
    _posX[i] = px;
    _posY[i] = py;
    _posZ[i] = pz;
    _yaw[i] = yaw;
    _cosYaw[i] = math.cos(yaw);
    _sinYaw[i] = math.sin(yaw);
    _scaleX[i] = sx;
    _scaleY[i] = sy;
    _scaleZ[i] = sz;
    _colorR[i] = r;
    _colorG[i] = g;
    _colorB[i] = b;
    _colorA[i] = a;
    final resolvedPhase =
        windPhase ?? (_hashFloat01(i * 747796405 + 2891336453) * math.pi * 2.0);
    _windPhase[i] = resolvedPhase;
    _cosPhase[i] = math.cos(resolvedPhase);
    _sinPhase[i] = math.sin(resolvedPhase);
    _densityRank[i] = (densityRank ?? _hashFloat01(i * 1597334677 + 3812015801))
        .clamp(0.0, 1.0);
    _bendX[i] = 0;
    _bendZ[i] = 0;
    _crush[i] = 0;
    _cellsDirty = true;
    if (notify) {
      _stateVersion++;
      markAabbDirty();
      markDrawDirty(shadows: castsShadows);
    }
    return i;
  }

  /// Deterministically scatters up to [count] jittered Poisson-like foliage
  /// instances across [terrain], filtering by slope
  /// (`normal.y >= minSlopeCos`), elevation `[minHeight .. maxHeight]`, and
  /// optional [densityCallback].
  ///
  /// Returns the number of newly placed instances.
  int scatterOnTerrain(
    ChunkedTerrain3D terrain, {
    int count = 4096,
    double minSlopeCos = 0.72,
    double minHeight = -double.infinity,
    double maxHeight = double.infinity,
    int seed = 1337,
    double minScale = 0.75,
    double maxScale = 1.35,
    Color baseColor = const Color(0xFF4B8F38),
    Color variationColor = const Color(0xFF79B846),
    FoliageDensityCallback3D? densityCallback,
  }) {
    clear();
    final targetCount = math.min(count, capacity);
    if (targetCount <= 0) {
      return 0;
    }

    // Stratified jittered grid with oversampling when slope/height filters
    // reject candidates, guaranteeing even spacing without clumping.
    var rngState = (seed ^ 0x5DEECE66) & 0x7FFFFFFF;
    if (rngState == 0) {
      rngState = 1337;
    }
    double next01() {
      rngState = (rngState * 48271) % 2147483647;
      return (rngState & 0x7FFFFFFF) / 2147483647.0;
    }

    final normalScratch = Vector3.zero();
    final aspect = math.sqrt(terrain.worldWidth / terrain.worldDepth);
    final gridCols = math.max(1, (math.sqrt(targetCount) * aspect).ceil());
    final gridRows = math.max(1, (targetCount / gridCols).ceil());
    final cellW = terrain.worldWidth / gridCols;
    final cellD = terrain.worldDepth / gridRows;
    final halfW = terrain.worldWidth * 0.5;
    final halfD = terrain.worldDepth * 0.5;

    var placed = 0;
    // Pass 1: stratified jittered cells.
    for (var gr = 0; gr < gridRows && placed < targetCount; gr++) {
      for (var gc = 0; gc < gridCols && placed < targetCount; gc++) {
        final jx = 0.12 + 0.76 * next01();
        final jz = 0.12 + 0.76 * next01();
        final x = -halfW + (gc + jx) * cellW;
        final z = -halfD + (gr + jz) * cellD;
        if (_tryPlaceOnTerrain(
          terrain,
          x,
          z,
          minSlopeCos,
          minHeight,
          maxHeight,
          minScale,
          maxScale,
          baseColor,
          variationColor,
          densityCallback,
          next01,
          normalScratch,
        )) {
          placed++;
        }
      }
    }

    // Pass 2: top up remaining quota if slope/height masks rejected some cells.
    final maxAttempts = targetCount * 6;
    var attempts = 0;
    while (placed < targetCount && attempts < maxAttempts) {
      attempts++;
      final x = (next01() - 0.5) * terrain.worldWidth;
      final z = (next01() - 0.5) * terrain.worldDepth;
      if (_tryPlaceOnTerrain(
        terrain,
        x,
        z,
        minSlopeCos,
        minHeight,
        maxHeight,
        minScale,
        maxScale,
        baseColor,
        variationColor,
        densityCallback,
        next01,
        normalScratch,
      )) {
        placed++;
      }
    }

    _ensureSpatialCells();
    if (placed > 0) {
      _stateVersion++;
    }
    markAabbDirty();
    markDrawDirty(shadows: castsShadows);
    return placed;
  }

  /// Reads the rest local position of blade [index].
  Vector3 bladePosition(int index, {Vector3? out}) {
    RangeError.checkValidIndex(index, _posX, 'index', _bladeCount);
    final res = out ?? Vector3.zero();
    res.setValues(_posX[index], _posY[index], _posZ[index]);
    return res;
  }

  /// Current horizontal bend angle magnitude (in radians) of blade [index].
  double bladeBendMagnitude(int index) {
    RangeError.checkValidIndex(index, _bendX, 'index', _bladeCount);
    final bx = _bendX[index];
    final bz = _bendZ[index];
    return math.sqrt(bx * bx + bz * bz);
  }

  /// Current horizontal bend vector `(bendX, bendZ)` of blade [index].
  Vector2 bladeBendVector(int index, {Vector2? out}) {
    RangeError.checkValidIndex(index, _bendX, 'index', _bladeCount);
    final res = out ?? Vector2.zero();
    res.setValues(_bendX[index], _bendZ[index]);
    return res;
  }

  /// Current vertical crush factor `[0..1]` (`0` = upright, `1` = fully
  /// flattened) of blade [index].
  double bladeCrush(int index) {
    RangeError.checkValidIndex(index, _crush, 'index', _bladeCount);
    return _crush[index];
  }

  @override
  void update(double dt) {
    super.update(dt);
    if (dt <= 0 || _bladeCount == 0) {
      return;
    }
    _windTime += dt;
    if (windStrength != 0) {
      _stateVersion++;
    }
    _updateInteractors(dt);
  }

  /// Evaluates spatial-cell frustum & distance culling and packs visible
  /// instances into the contiguous GPU instance buffer (`24` floats/instance),
  /// returning the number of visible instances.
  int buildVisibleInstances({
    required Vector3 cameraPosition,
    Frustum? frustum,
  }) {
    _mainCache.valid = false;
    _shadowCache.valid = false;
    final count = _packVisibleInstances(
      cameraPosition: cameraPosition,
      frustum: frustum,
      outBuffer: _instanceBuffer,
    );
    _mainCache.bufferVersion++;
    return count;
  }

  int _packVisibleInstances({
    required Vector3 cameraPosition,
    required Float32List outBuffer,
    Frustum? frustum,
  }) {
    _lastVisibleCellCount = 0;
    _lastVisibleInstanceCount = 0;
    if (_bladeCount == 0) {
      return 0;
    }
    _ensureSpatialCells();

    final worldMat = worldTransformMatrix;
    final isIdentity = worldMat.isIdentity();
    if (isIdentity) {
      _localCamScratch.setFrom(cameraPosition);
    } else {
      _invWorldScratch.setFrom(worldMat);
      if (_invWorldScratch.invert().abs() > 1e-15) {
        final m = _invWorldScratch.storage;
        _localCamScratch.setValues(
          m[0] * cameraPosition.x +
              m[4] * cameraPosition.y +
              m[8] * cameraPosition.z +
              m[12],
          m[1] * cameraPosition.x +
              m[5] * cameraPosition.y +
              m[9] * cameraPosition.z +
              m[13],
          m[2] * cameraPosition.x +
              m[6] * cameraPosition.y +
              m[10] * cameraPosition.z +
              m[14],
        );
      } else {
        _localCamScratch.setFrom(cameraPosition);
      }
    }

    final camX = _localCamScratch.x;
    final camY = _localCamScratch.y;
    final camZ = _localCamScratch.z;
    final maxDist = maxDrawDistance;
    final maxDistSq = maxDist * maxDist;
    final fadeStart = maxDist * fadeStartFraction;
    final fadeStartSq64 = fadeStart * fadeStart * 0.64;
    final fadeSpan = math.max(1e-4, maxDist - fadeStart);

    final wStorage = worldMat.storage;
    final windDirX = windDirection.x;
    final windDirZ = windDirection.y;
    final windAmp = windStrength;
    final hasWind = windAmp != 0.0;
    final windDirLen = hasWind
        ? math.sqrt(windDirX * windDirX + windDirZ * windDirZ)
        : 0.0;
    final windOmega = _windTime * windFrequency;
    final cosW = hasWind ? math.cos(windOmega) : 1.0;
    final sinW = hasWind ? math.sin(windOmega) : 0.0;

    var outInstances = 0;
    const stride = VertexLayout.instanceStrideInFloats;

    for (var cell = 0; cell < _cellCount; cell++) {
      final cb = cell * 6;
      final cMinX = _cellBounds[cb];
      final cMinY = _cellBounds[cb + 1];
      final cMinZ = _cellBounds[cb + 2];
      final cMaxX = _cellBounds[cb + 3];
      final cMaxY = _cellBounds[cb + 4];
      final cMaxZ = _cellBounds[cb + 5];

      final qx = camX < cMinX
          ? cMinX - camX
          : (camX > cMaxX ? camX - cMaxX : 0);
      final qy = camY < cMinY
          ? cMinY - camY
          : (camY > cMaxY ? camY - cMaxY : 0);
      final qz = camZ < cMinZ
          ? cMinZ - camZ
          : (camZ > cMaxZ ? camZ - cMaxZ : 0);
      if (qx * qx + qy * qy + qz * qz > maxDistSq) {
        continue;
      }

      if (frustum != null) {
        _cellBoxScratch
          ..min.setValues(cMinX, cMinY, cMinZ)
          ..max.setValues(cMaxX, cMaxY, cMaxZ);
        if (!isIdentity) {
          _cellBoxScratch.transform(worldMat);
        }
        if (_cellBoxScratch.frustumCullTest(frustum) == CullResult.outside) {
          continue;
        }
      }

      _lastVisibleCellCount++;
      final cellBent = _cellHasBend[cell] != 0;
      final start = _cellOffsets[cell];
      final end = start + _cellCounts[cell];

      for (var k = start; k < end; k++) {
        final i = _cellBladeIndices[k];
        final px = _posX[i];
        final py = _posY[i];
        final pz = _posZ[i];

        final dx = px - camX;
        final dy = py - camY;
        final dz = pz - camZ;
        final distSq = dx * dx + dy * dy + dz * dz;
        if (distSq >= maxDistSq) {
          continue;
        }

        // Per-blade deterministic cutoff distance produces continuous density
        // thinning AND smooth zero-pop scale-down to 0 right at cutoff!
        var distScale = 1.0;
        if (distSq > fadeStartSq64) {
          final dist = math.sqrt(distSq);
          final bladeCutoff = fadeStart + _densityRank[i] * fadeSpan;
          if (dist >= bladeCutoff) {
            continue;
          }
          final rampStart = bladeCutoff * 0.8;
          if (dist > rampStart) {
            final t =
                ((bladeCutoff - dist) / math.max(1e-4, bladeCutoff - rampStart))
                    .clamp(0.0, 1.0);
            distScale = t * t * (3.0 - 2.0 * t);
          }
        }
        if (distScale <= 1e-3) {
          continue;
        }

        final crush = cellBent ? _crush[i] : 0.0;
        final sx = _scaleX[i] * distScale;
        final sy = cellBent
            ? _scaleY[i] * distScale * (1.0 - 0.65 * crush)
            : _scaleY[i] * distScale;
        final sz = _scaleZ[i] * distScale;

        final cy = _cosYaw[i];
        final syaw = _sinYaw[i];

        final double tiltX;
        final double tiltZ;
        final double m11;
        final double tiltMag;
        if (!cellBent && !hasWind) {
          tiltX = 0.0;
          tiltZ = 0.0;
          m11 = sy;
          tiltMag = 0.0;
        } else if (!cellBent) {
          final sinTotal = sinW * _cosPhase[i] + cosW * _sinPhase[i];
          final sway = windAmp * sinTotal;
          tiltX = windDirX * sway;
          tiltZ = windDirZ * sway;
          tiltMag = sway.abs() * windDirLen;
          final tiltSq = tiltMag * tiltMag;
          m11 = tiltSq == 0.0 ? sy : sy / math.sqrt(1.0 + tiltSq);
        } else {
          final double sway;
          if (hasWind) {
            final sinTotal = sinW * _cosPhase[i] + cosW * _sinPhase[i];
            sway = windAmp * sinTotal * (1.0 - 0.5 * crush);
          } else {
            sway = 0.0;
          }
          tiltX = _bendX[i] + windDirX * sway;
          tiltZ = _bendZ[i] + windDirZ * sway;
          final tiltSq = tiltX * tiltX + tiltZ * tiltZ;
          if (tiltSq == 0.0) {
            m11 = sy;
            tiltMag = 0.0;
          } else {
            m11 = sy / math.sqrt(1.0 + tiltSq);
            tiltMag = math.sqrt(tiltSq);
          }
        }

        // Local columns: X and Z rotated by `yaw`, Y tilted outward by trample
        // + wind while anchoring `y = 0` in the ground!
        final m00 = cy * sx;
        const m01 = 0.0;
        final m02 = -syaw * sx;

        final m10 = tiltX * sy;
        final m12 = tiltZ * sy;

        final m20 = syaw * sz;
        const m21 = 0.0;
        final m22 = cy * sz;

        final base = outInstances * stride;
        if (isIdentity) {
          outBuffer
            ..[base] = m00
            ..[base + 1] = m01
            ..[base + 2] = m02
            ..[base + 3] = 0
            ..[base + 4] = m10
            ..[base + 5] = m11
            ..[base + 6] = m12
            ..[base + 7] = 0
            ..[base + 8] = m20
            ..[base + 9] = m21
            ..[base + 10] = m22
            ..[base + 11] = 0
            ..[base + 12] = px
            ..[base + 13] = py
            ..[base + 14] = pz
            ..[base + 15] = 1;
        } else {
          _writeWorldMul(
            wStorage,
            m00,
            m01,
            m02,
            m10,
            m11,
            m12,
            m20,
            m21,
            m22,
            px,
            py,
            pz,
            outBuffer,
            base,
          );
        }

        outBuffer
          ..[base + 16] = _colorR[i]
          ..[base + 17] = _colorG[i]
          ..[base + 18] = _colorB[i]
          ..[base + 19] = _colorA[i]
          ..[base + 20] = _windPhase[i]
          ..[base + 21] = windAmp
          ..[base + 22] = crush
          ..[base + 23] = tiltMag;
        outInstances++;
      }
    }

    _lastVisibleInstanceCount = outInstances;
    return outInstances;
  }

  @override
  bool get usesDefaultFrustumVisibility => runtimeType == FoliageSystem3D;

  @override
  Aabb3? computeLocalAabb() {
    if (_bladeCount == 0) {
      return null;
    }
    _ensureSpatialCells();
    return _localAabb;
  }

  @override
  void onRemove() {
    if (_ownsDefaultMesh) {
      for (final s in mesh.surfaces) {
        s.dispose();
      }
    }
    super.onRemove();
  }

  @override
  void draw(covariant RenderContext3D context) {
    if (_bladeCount == 0) {
      return;
    }
    final isShadow = context.isShadowPass;
    final cache = isShadow ? _shadowCache : _mainCache;
    final outBuffer = isShadow
        ? (_shadowInstanceBuffer ??= Float32List(
            capacity * VertexLayout.instanceStrideInFloats,
          ))
        : _instanceBuffer;
    final camPos = context.viewerPosition;
    final vp = context.viewProjection.storage;
    final worldVer = worldTransformVersion;
    final hitCache = cache.matches(
      _stateVersion,
      worldVer,
      camPos,
      maxDrawDistance,
      fadeStartFraction,
      windStrength,
      windFrequency,
      maxBendAngle,
      windDirection,
      vp,
    );
    final int count;
    if (hitCache) {
      count = cache.visibleInstanceCount;
      _lastVisibleInstanceCount = count;
      _lastVisibleCellCount = cache.visibleCellCount;
    } else {
      // Distance thinning follows the viewer, also in shadow passes (where the
      // camera is the light's view, centered on the world origin): the blades
      // that cast shadows are the ones the main pass shows.
      count = _packVisibleInstances(
        cameraPosition: camPos,
        frustum: context.frustum,
        outBuffer: outBuffer,
      );
      cache.store(
        _stateVersion,
        worldVer,
        camPos,
        maxDrawDistance,
        fadeStartFraction,
        windStrength,
        windFrequency,
        maxBendAngle,
        windDirection,
        vp,
        _lastVisibleCellCount,
        count,
      );
    }
    if (count <= 0) {
      return;
    }
    for (final surface in mesh.surfaces) {
      context.drawInstances(
        surface,
        instances: outBuffer,
        count: count,
        material: material,
        instanceVersion: cache.bufferVersion,
      );
    }
  }

  void _ensureInteractorScratch(int count) {
    if (_activeIx.length >= count) {
      return;
    }
    var cap = math.max(16, _activeIx.length);
    while (cap < count) {
      cap *= 2;
    }
    _activeIx = Float64List(cap);
    _activeIy = Float64List(cap);
    _activeIz = Float64List(cap);
    _activeIr = Float64List(cap);
    _activeIrSq = Float64List(cap);
    _activeIStrength = Float64List(cap);
    _cellInteractors = Int32List(cap);
  }

  void _updateInteractors(double dt) {
    _ensureSpatialCells();
    if (_cellCount == 0) {
      return;
    }

    var activeCount = 0;
    if (interactors.isNotEmpty) {
      _ensureInteractorScratch(interactors.length);
      final worldMat = worldTransformMatrix;
      final isIdentity = worldMat.isIdentity();
      Float32List? invM;
      if (!isIdentity) {
        _invWorldScratch.setFrom(worldMat);
        _invWorldScratch.invert();
        invM = _invWorldScratch.storage;
      }
      for (var s = 0; s < interactors.length; s++) {
        final inter = interactors[s];
        final r = inter.radius;
        final strength = inter.strength.clamp(0.0, 1.0);
        if (r <= 0 || strength <= 0) {
          continue;
        }
        final p = inter.position;
        if (invM == null) {
          _activeIx[activeCount] = p.x;
          _activeIy[activeCount] = p.y;
          _activeIz[activeCount] = p.z;
        } else {
          _activeIx[activeCount] =
              invM[0] * p.x + invM[4] * p.y + invM[8] * p.z + invM[12];
          _activeIy[activeCount] =
              invM[1] * p.x + invM[5] * p.y + invM[9] * p.z + invM[13];
          _activeIz[activeCount] =
              invM[2] * p.x + invM[6] * p.y + invM[10] * p.z + invM[14];
        }
        _activeIr[activeCount] = r;
        _activeIrSq[activeCount] = r * r;
        _activeIStrength[activeCount] = strength;
        activeCount++;
      }
    }

    if (activeCount == 0 && !_anyCellBent) {
      if (windStrength > 0) {
        markDrawDirty(shadows: castsShadows);
      }
      return;
    }

    final attackAlpha = (1.0 - math.exp(-trampleAttackRate * dt)).clamp(
      0.0,
      1.0,
    );
    final recoverAlpha = (1.0 - math.exp(-trampleSpringRate * dt)).clamp(
      0.0,
      1.0,
    );

    var anyChanged = false;
    var anyCellStillBent = false;

    for (var cell = 0; cell < _cellCount; cell++) {
      final cb = cell * 6;
      final cMinX = _cellBounds[cb];
      final cMinY = _cellBounds[cb + 1];
      final cMinZ = _cellBounds[cb + 2];
      final cMaxX = _cellBounds[cb + 3];
      final cMaxY = _cellBounds[cb + 4];
      final cMaxZ = _cellBounds[cb + 5];

      var cellHitCount = 0;
      for (var s = 0; s < activeCount; s++) {
        final ix = _activeIx[s];
        final iy = _activeIy[s];
        final iz = _activeIz[s];
        final r = _activeIr[s];
        if (ix + r >= cMinX &&
            ix - r <= cMaxX &&
            iy + r >= cMinY &&
            iy - r <= cMaxY &&
            iz + r >= cMinZ &&
            iz - r <= cMaxZ) {
          _cellInteractors[cellHitCount++] = s;
        }
      }

      if (cellHitCount == 0 && _cellHasBend[cell] == 0) {
        continue;
      }

      final start = _cellOffsets[cell];
      final end = start + _cellCounts[cell];
      var cellStillBent = false;

      for (var k = start; k < end; k++) {
        final i = _cellBladeIndices[k];
        var targetBx = 0.0;
        var targetBz = 0.0;
        var targetCrush = 0.0;

        if (cellHitCount > 0) {
          final bx = _posX[i];
          final by = _posY[i];
          final bz = _posZ[i];

          for (var h = 0; h < cellHitCount; h++) {
            final s = _cellInteractors[h];
            final dx = bx - _activeIx[s];
            final dy = by - _activeIy[s];
            final dz = bz - _activeIz[s];
            final distSq = dx * dx + dy * dy + dz * dz;
            if (distSq >= _activeIrSq[s]) {
              continue;
            }

            final dist = math.sqrt(distSq);
            final t = (1.0 - dist / _activeIr[s]).clamp(0.0, 1.0);
            final falloff = t * t * (3.0 - 2.0 * t) * _activeIStrength[s];

            final hLen = math.sqrt(dx * dx + dz * dz);
            final ux = hLen > 1e-5 ? dx / hLen : 1.0;
            final uz = hLen > 1e-5 ? dz / hLen : 0.0;

            targetBx += ux * falloff * maxBendAngle;
            targetBz += uz * falloff * maxBendAngle;
            if (falloff > targetCrush) {
              targetCrush = falloff;
            }
          }

          final bMag = math.sqrt(targetBx * targetBx + targetBz * targetBz);
          if (bMag > maxBendAngle && bMag > 1e-6) {
            final clampScale = maxBendAngle / bMag;
            targetBx *= clampScale;
            targetBz *= clampScale;
          }
        }

        final curCrush = _crush[i];
        final alpha = targetCrush > curCrush ? attackAlpha : recoverAlpha;
        final nextBx = _bendX[i] + (targetBx - _bendX[i]) * alpha;
        final nextBz = _bendZ[i] + (targetBz - _bendZ[i]) * alpha;
        final nextCrush = curCrush + (targetCrush - curCrush) * alpha;

        if (nextBx.abs() > 1e-4 || nextBz.abs() > 1e-4 || nextCrush > 1e-4) {
          _bendX[i] = nextBx;
          _bendZ[i] = nextBz;
          _crush[i] = nextCrush;
          cellStillBent = true;
          anyChanged = true;
        } else if (curCrush != 0 || _bendX[i] != 0 || _bendZ[i] != 0) {
          _bendX[i] = 0;
          _bendZ[i] = 0;
          _crush[i] = 0;
          anyChanged = true;
        }
      }

      _cellHasBend[cell] = cellStillBent ? 1 : 0;
      if (cellStillBent) {
        anyCellStillBent = true;
      }
    }
    _anyCellBent = anyCellStillBent;

    if (anyChanged) {
      _stateVersion++;
    }
    if (anyChanged || windStrength > 0) {
      markDrawDirty(shadows: castsShadows);
    }
  }

  void _ensureSpatialCells() {
    if (!_cellsDirty) {
      return;
    }
    _cellsDirty = false;
    final n = _bladeCount;
    if (n == 0) {
      _cellCount = 0;
      _localAabb.setZero();
      return;
    }

    final bladeNext = Int32List(n);
    const cellBias = 0x2000000;
    const cellStride = 0x4000000;
    final cellIndexByKey = <int, int>{};
    Map<(int, int), int>? overflowCells;
    final cellHeads = <int>[];
    final cellTails = <int>[];
    final cellCountsList = <int>[];

    for (var i = 0; i < n; i++) {
      final cx = (_posX[i] / cellSize).floor();
      final cz = (_posZ[i] / cellSize).floor();
      int? cellIdx;
      final inRange =
          cx >= -cellBias && cx < cellBias && cz >= -cellBias && cz < cellBias;
      if (inRange) {
        final packed = (cx + cellBias) * cellStride + (cz + cellBias);
        cellIdx = cellIndexByKey[packed];
        if (cellIdx == null) {
          cellIdx = cellHeads.length;
          cellIndexByKey[packed] = cellIdx;
          cellHeads.add(i);
          cellTails.add(i);
          cellCountsList.add(1);
          bladeNext[i] = -1;
          continue;
        }
      } else {
        final overflow = overflowCells ??= <(int, int), int>{};
        final rec = (cx, cz);
        cellIdx = overflow[rec];
        if (cellIdx == null) {
          cellIdx = cellHeads.length;
          overflow[rec] = cellIdx;
          cellHeads.add(i);
          cellTails.add(i);
          cellCountsList.add(1);
          bladeNext[i] = -1;
          continue;
        }
      }
      final tail = cellTails[cellIdx];
      bladeNext[tail] = i;
      bladeNext[i] = -1;
      cellTails[cellIdx] = i;
      cellCountsList[cellIdx]++;
    }

    final cCount = cellHeads.length;
    _cellCount = cCount;
    _cellOffsets = Int32List(cCount);
    _cellCounts = Int32List(cCount);
    _cellBladeIndices = Int32List(n);
    _cellBounds = Float32List(cCount * 6);
    _cellHasBend = Uint8List(cCount);

    final meshBox = mesh.aabb;
    final maxHalfExtent = math.max(
      math.max(meshBox.min.x.abs(), meshBox.max.x.abs()),
      math.max(meshBox.min.z.abs(), meshBox.max.z.abs()),
    );
    final meshTop = math.max(0.5, meshBox.max.y);

    var globalMinX = double.infinity;
    var globalMinY = double.infinity;
    var globalMinZ = double.infinity;
    var globalMaxX = double.negativeInfinity;
    var globalMaxY = double.negativeInfinity;
    var globalMaxZ = double.negativeInfinity;

    var cursor = 0;
    for (var cellIdx = 0; cellIdx < cCount; cellIdx++) {
      _cellOffsets[cellIdx] = cursor;
      _cellCounts[cellIdx] = cellCountsList[cellIdx];

      var minX = double.infinity;
      var minY = double.infinity;
      var minZ = double.infinity;
      var maxX = double.negativeInfinity;
      var maxY = double.negativeInfinity;
      var maxZ = double.negativeInfinity;
      var hasBent = false;

      var i = cellHeads[cellIdx];
      while (i != -1) {
        _cellBladeIndices[cursor++] = i;
        // Wind and trampling shear the blade: its tip moves sideways by up
        // to their sum times its height.
        final padXZ =
            math.max(_scaleX[i], _scaleZ[i]) * maxHalfExtent +
            (windStrength.abs() + maxBendAngle.abs()) * _scaleY[i] * meshTop;
        final topY = _posY[i] + _scaleY[i] * meshTop;
        minX = math.min(minX, _posX[i] - padXZ);
        maxX = math.max(maxX, _posX[i] + padXZ);
        minY = math.min(minY, _posY[i] - 0.1);
        maxY = math.max(maxY, topY);
        minZ = math.min(minZ, _posZ[i] - padXZ);
        maxZ = math.max(maxZ, _posZ[i] + padXZ);
        if (_crush[i] != 0.0 || _bendX[i] != 0.0 || _bendZ[i] != 0.0) {
          hasBent = true;
        }
        i = bladeNext[i];
      }

      final cb = cellIdx * 6;
      _cellBounds
        ..[cb] = minX
        ..[cb + 1] = minY
        ..[cb + 2] = minZ
        ..[cb + 3] = maxX
        ..[cb + 4] = maxY
        ..[cb + 5] = maxZ;
      _cellHasBend[cellIdx] = hasBent ? 1 : 0;

      globalMinX = math.min(globalMinX, minX);
      globalMinY = math.min(globalMinY, minY);
      globalMinZ = math.min(globalMinZ, minZ);
      globalMaxX = math.max(globalMaxX, maxX);
      globalMaxY = math.max(globalMaxY, maxY);
      globalMaxZ = math.max(globalMaxZ, maxZ);
    }

    _localAabb
      ..min.setValues(globalMinX, globalMinY, globalMinZ)
      ..max.setValues(globalMaxX, globalMaxY, globalMaxZ);
  }

  bool _tryPlaceOnTerrain(
    ChunkedTerrain3D terrain,
    double x,
    double z,
    double minSlopeCos,
    double minHeight,
    double maxHeight,
    double minScale,
    double maxScale,
    Color baseColor,
    Color variationColor,
    FoliageDensityCallback3D? densityCallback,
    double Function() next01,
    Vector3 normalScratch,
  ) {
    final y = terrain.sampleHeight(x, z);
    if (y < minHeight || y > maxHeight) {
      return false;
    }
    terrain.sampleNormal(x, z, out: normalScratch);
    if (normalScratch.y < minSlopeCos) {
      return false;
    }
    if (densityCallback != null) {
      final density = densityCallback(x, y, z, normalScratch).clamp(0.0, 1.0);
      if (density <= 0 || (density < 1.0 && next01() > density)) {
        return false;
      }
    }

    final yaw = next01() * math.pi * 2.0;
    final s = minScale + (maxScale - minScale) * next01();
    final heightVar = s * (0.85 + 0.3 * next01());
    final mixT = next01();

    return _addBladeRaw(
          x,
          y,
          z,
          yaw,
          s,
          heightVar,
          s,
          baseColor.r + (variationColor.r - baseColor.r) * mixT,
          baseColor.g + (variationColor.g - baseColor.g) * mixT,
          baseColor.b + (variationColor.b - baseColor.b) * mixT,
          1.0,
          next01() * math.pi * 2.0,
          next01(),
          notify: false,
        ) >=
        0;
  }

  static double _hashFloat01(int seed) {
    var x = seed & 0x7FFFFFFF;
    x = ((x >> 16) ^ x) * 0x45D9F3B & 0x7FFFFFFF;
    x = ((x >> 16) ^ x) * 0x45D9F3B & 0x7FFFFFFF;
    x = (x >> 16) ^ x;
    return (x & 0x7FFFFFFF) / 2147483647.0;
  }

  static void _writeWorldMul(
    Float32List w,
    double m00,
    double m01,
    double m02,
    double m10,
    double m11,
    double m12,
    double m20,
    double m21,
    double m22,
    double px,
    double py,
    double pz,
    Float32List out,
    int b,
  ) {
    out
      ..[b] = w[0] * m00 + w[4] * m01 + w[8] * m02
      ..[b + 1] = w[1] * m00 + w[5] * m01 + w[9] * m02
      ..[b + 2] = w[2] * m00 + w[6] * m01 + w[10] * m02
      ..[b + 3] = w[3] * m00 + w[7] * m01 + w[11] * m02
      ..[b + 4] = w[0] * m10 + w[4] * m11 + w[8] * m12
      ..[b + 5] = w[1] * m10 + w[5] * m11 + w[9] * m12
      ..[b + 6] = w[2] * m10 + w[6] * m11 + w[10] * m12
      ..[b + 7] = w[3] * m10 + w[7] * m11 + w[11] * m12
      ..[b + 8] = w[0] * m20 + w[4] * m21 + w[8] * m22
      ..[b + 9] = w[1] * m20 + w[5] * m21 + w[9] * m22
      ..[b + 10] = w[2] * m20 + w[6] * m21 + w[10] * m22
      ..[b + 11] = w[3] * m20 + w[7] * m21 + w[11] * m22
      ..[b + 12] = w[0] * px + w[4] * py + w[8] * pz + w[12]
      ..[b + 13] = w[1] * px + w[5] * py + w[9] * pz + w[13]
      ..[b + 14] = w[2] * px + w[6] * py + w[10] * pz + w[14]
      ..[b + 15] = w[3] * px + w[7] * py + w[11] * pz + w[15];
  }

  static Mesh _buildDefaultGrassTuftMesh(Material material) {
    // Two crossed tapered blades anchored at y = 0, peaking at y = 1.
    final stride = VertexLayout.standard.strideInFloats;
    final verts = Float32List(10 * stride);

    void put(
      int idx,
      double x,
      double y,
      double z,
      double u,
      double v,
      double r,
      double g,
      double b,
      double nx,
      double ny,
      double nz,
    ) {
      final o = idx * stride;
      verts
        ..[o] = x
        ..[o + 1] = y
        ..[o + 2] = z
        ..[o + 3] = u
        ..[o + 4] = v
        ..[o + 5] = r
        ..[o + 6] = g
        ..[o + 7] = b
        ..[o + 8] = 1
        ..[o + 9] = nx
        ..[o + 10] = ny
        ..[o + 11] = nz;
    }

    // Blade A along X axis.
    put(0, -0.14, 0, 0, 0, 1, 0.45, 0.55, 0.38, 0, 0.45, 0.89);
    put(1, 0.14, 0, 0, 1, 1, 0.45, 0.55, 0.38, 0, 0.45, 0.89);
    put(2, -0.09, 0.52, 0.02, 0.15, 0.5, 0.72, 0.86, 0.58, 0, 0.55, 0.83);
    put(3, 0.09, 0.52, 0.02, 0.85, 0.5, 0.72, 0.86, 0.58, 0, 0.55, 0.83);
    put(4, 0, 1, 0.05, 0.5, 0, 1, 1, 0.88, 0, 0.7, 0.71);

    // Blade B along Z axis.
    put(5, 0, 0, -0.14, 0, 1, 0.45, 0.55, 0.38, 0.89, 0.45, 0);
    put(6, 0, 0, 0.14, 1, 1, 0.45, 0.55, 0.38, 0.89, 0.45, 0);
    put(7, -0.02, 0.52, -0.09, 0.15, 0.5, 0.72, 0.86, 0.58, 0.83, 0.55, 0);
    put(8, -0.02, 0.52, 0.09, 0.85, 0.5, 0.72, 0.86, 0.58, 0.83, 0.55, 0);
    put(9, -0.05, 1, 0, 0.5, 0, 1, 1, 0.88, 0.71, 0.7, 0);

    final indices = Uint16List.fromList(const [
      0, 1, 3, 0, 3, 2, 2, 3, 4, //
      5, 6, 8, 5, 8, 7, 7, 8, 9, //
    ]);

    return Mesh()..addSurface(
      Surface.fromBuffers(
        vertices: verts,
        indices: indices,
        material: material,
      ),
    );
  }
}
