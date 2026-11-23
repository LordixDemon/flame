import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/src/extensions/clip_space.dart';
import 'package:flame_3d/src/world_scale/chunked_terrain_3d.dart';

part 'foliage_system_packing_3d.dart';
part 'foliage_system_scatter_3d.dart';

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
        windPhase ??
        (_hashFoliageFloat01(i * 747796405 + 2891336453) * math.pi * 2.0);
    _windPhase[i] = resolvedPhase;
    _cosPhase[i] = math.cos(resolvedPhase);
    _sinPhase[i] = math.sin(resolvedPhase);
    _densityRank[i] =
        (densityRank ?? _hashFoliageFloat01(i * 1597334677 + 3812015801)).clamp(
          0.0,
          1.0,
        );
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
  }) => _scatterOnTerrainImpl(
    terrain,
    count: count,
    minSlopeCos: minSlopeCos,
    minHeight: minHeight,
    maxHeight: maxHeight,
    seed: seed,
    minScale: minScale,
    maxScale: maxScale,
    baseColor: baseColor,
    variationColor: variationColor,
    densityCallback: densityCallback,
  );

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
}
