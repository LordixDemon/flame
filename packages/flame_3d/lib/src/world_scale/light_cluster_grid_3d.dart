import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:flame_3d/core.dart';
import 'package:flame_3d/resources.dart';

/// Type of local light stored in a [LightClusterGrid3D].
enum ClusterLightKind3D() {
  /// Omnidirectional point light with spherical attenuation radius.
  point,

  /// Directional cone spotlight with spherical range and inner/outer angles.
  spot,
}

/// Descriptor for a local point or spot light assigned into a
/// [LightClusterGrid3D].
class ClusterLightEntry3D({
  /// Whether this entry represents a point or spot light.
  required final ClusterLightKind3D kind,
  required Vector3 position,

  /// Cutoff radius in world units.
  required var double range,
  Vector3? direction,

  /// Cosine of the inner spotlight half-angle (`1.0` for point lights).
  var double innerConeCos = 1.0,

  /// Cosine of the outer spotlight half-angle (`-1.0` for point lights).
  var double outerConeCos = -1.0,

  /// Light tint color.
  var Color color = const Color(0xFFFFFFFF),

  /// Luminous intensity multiplier.
  var double intensity = 1.0,

  /// 32-bit layer bitmask matched against `cameraMask`.
  var int lightMask = 0xFFFFFFFF,
}) {
  /// Creates a local light entry directly from precomputed cone cosines.
  this : assert(range > 0, 'range must be positive') {
    final len = this.direction.length;
    if (len > 1e-12) {
      this.direction.scale(1.0 / len);
    } else {
      this.direction.setValues(0, -1, 0);
    }
  }

  /// World-space position of the light emitter.
  final Vector3 position = position.clone();

  /// Unit world-space direction pointing away from the light along its cone.
  final Vector3 direction = direction?.clone() ?? Vector3(0, -1, 0);

  /// Creates an omnidirectional point light entry.
  factory ClusterLightEntry3D.point({
    required Vector3 position,
    double range = 12.0,
    Color color = const Color(0xFFFFFFFF),
    double intensity = 1.0,
    int lightMask = 0xFFFFFFFF,
  }) {
    return ClusterLightEntry3D(
      kind: ClusterLightKind3D.point,
      position: position,
      range: range,
      color: color,
      intensity: intensity,
      lightMask: lightMask,
    );
  }

  /// Creates a cone spotlight entry from half-angles in radians.
  factory ClusterLightEntry3D.spot({
    required Vector3 position,
    required Vector3 direction,
    double range = 16.0,
    double innerConeAngle = math.pi / 8,
    double outerConeAngle = math.pi / 4,
    Color color = const Color(0xFFFFFFFF),
    double intensity = 1.0,
    int lightMask = 0xFFFFFFFF,
  }) {
    final clampedOuter = outerConeAngle.clamp(1e-4, math.pi - 1e-4);
    final clampedInner = innerConeAngle.clamp(0.0, clampedOuter);
    return ClusterLightEntry3D(
      kind: ClusterLightKind3D.spot,
      position: position,
      range: range,
      direction: direction,
      innerConeCos: math.cos(clampedInner),
      outerConeCos: math.cos(clampedOuter),
      color: color,
      intensity: intensity,
      lightMask: lightMask,
    );
  }

  /// Converts a scene [Light] (`PointLight` or `SpotLight`) into a
  /// [ClusterLightEntry3D], or returns `null` for non-local light types.
  static ClusterLightEntry3D? fromSceneLight(
    Light light, {
    double fallbackRange = 20.0,
  }) {
    final src = light.source;
    if (src is PointLight) {
      final r = (src.range != null && src.range! > 0)
          ? src.range!
          : fallbackRange;
      return ClusterLightEntry3D.point(
        position: light.position,
        range: r,
        color: src.color,
        intensity: src.intensity,
        lightMask: light.lightMask,
      );
    }
    if (src is SpotLight) {
      final r = (src.range != null && src.range! > 0)
          ? src.range!
          : fallbackRange;
      final toSurface = light.direction(_lightDirScratch);
      return ClusterLightEntry3D.spot(
        position: light.position,
        direction: Vector3(-toSurface.x, -toSurface.y, -toSurface.z),
        range: r,
        innerConeAngle: src.innerConeAngle,
        outerConeAngle: src.outerConeAngle,
        color: src.color,
        intensity: src.intensity,
        lightMask: light.lightMask,
      );
    }
    return null;
  }

  static final Vector3 _lightDirScratch = Vector3.zero();
}

/// Top ranked local lights overlapping a world-space region in a
/// [LightClusterGrid3D].
class ClusterLightSelection3D(
  /// Indices of the highest-contributing point lights in the grid.
  final Int32List pointLightIndices,

  /// Indices of the highest-contributing spot lights in the grid.
  final Int32List spotLightIndices,
);

/// 3D Clustered Forward+ frustum light assignment grid (`16 x 8 x 16` by
/// default) with exponential depth slicing and zero-allocation per-frame
/// assignment for up to `512` (or [maxLights]) point and spot lights.
class LightClusterGrid3D({
  /// Horizontal cluster subdivision count across normalized screen X.
  final int clustersX = 16,

  /// Vertical cluster subdivision count across normalized screen Y.
  final int clustersY = 8,

  /// Exponential depth slice count between `near` and `far`.
  final int clustersZ = 16,

  /// Maximum number of local lights supported by pre-allocated buffers.
  final int maxLights = 512,

  /// Maximum light indices stored in any single cluster cell.
  final int maxLightsPerCluster = 64,
}) {
  /// Creates a 3D clustered frustum grid.
  this
    : assert(clustersX >= 1, 'clustersX must be at least 1'),
      assert(clustersY >= 1, 'clustersY must be at least 1'),
      assert(clustersZ >= 1, 'clustersZ must be at least 1'),
      assert(maxLights >= 1, 'maxLights must be at least 1'),
      assert(
        maxLightsPerCluster >= 1,
        'maxLightsPerCluster must be at least 1',
      );

  /// Total number of 3D clusters (`clustersX * clustersY * clustersZ`).
  final int totalClusters = clustersX * clustersY * clustersZ;

  /// Start offset of each cluster inside [lightIndexList].
  final Int32List clusterOffsets = Int32List(clustersX * clustersY * clustersZ);

  /// Number of assigned lights for each cluster.
  final Int32List clusterCounts = Int32List(clustersX * clustersY * clustersZ);

  /// Packed array of light indices referenced by [clusterOffsets] and
  /// [clusterCounts].
  final Int32List lightIndexList = Int32List(
    clustersX * clustersY * clustersZ * maxLightsPerCluster,
  );

  final List<ClusterLightEntry3D> _lights = <ClusterLightEntry3D>[];

  final Int32List _scratchCounts = Int32List(clustersX * clustersY * clustersZ);
  final Int32List _scratchIndices = Int32List(
    clustersX * clustersY * clustersZ * maxLightsPerCluster,
  );
  final Float32List _clusterBoundsView = Float32List(
    clustersX * clustersY * clustersZ * 6,
  );
  final Float32List _rowBoundsY = Float32List(clustersY * clustersZ * 2);
  final Float32List _sliceNear = Float32List(clustersZ);
  final Float32List _sliceFar = Float32List(clustersZ);
  final Float32List _cornerNearView = Float32List(
    (clustersX + 1) * (clustersY + 1) * 3,
  );
  final Float32List _cornerFarView = Float32List(
    (clustersX + 1) * (clustersY + 1) * 3,
  );

  final Float32List _viewPosX = Float32List(maxLights);
  final Float32List _viewPosY = Float32List(maxLights);
  final Float32List _viewPosZ = Float32List(maxLights);
  final Float32List _viewDirX = Float32List(maxLights);
  final Float32List _viewDirY = Float32List(maxLights);
  final Float32List _viewDirZ = Float32List(maxLights);
  final Float32List _lightRange = Float32List(maxLights);
  final Float32List _lightOuterCos = Float32List(maxLights);
  final Float32List _lightOuterSin = Float32List(maxLights);
  final Float32List _lightIntensity = Float32List(maxLights);
  final Int32List _lightKind = Int32List(maxLights);

  final Int32List _seenStamp = Int32List(maxLights);
  int _stampGeneration = 0;
  final Int32List _candidatePointIds = Int32List(maxLights);
  final Float32List _candidatePointScores = Float32List(maxLights);
  final Int32List _candidateSpotIds = Int32List(maxLights);
  final Float32List _candidateSpotScores = Float32List(maxLights);

  final Float64List _cachedProjection = Float64List(16);
  final Matrix4 _invProjScratch = Matrix4.identity();
  bool _hasCachedProjection = false;
  double _near = 0.1;
  double _far = 100.0;
  double _logFarOverNear = math.log(1000.0);
  int _totalAssignedLightRefs = 0;

  static final Int32List _emptyInts = Int32List(0);

  /// Active near clip distance from the most recent [assignLights] call.
  double get near => _near;

  /// Active far clip distance from the most recent [assignLights] call.
  double get far => _far;

  /// Number of registered [ClusterLightEntry3D] lights.
  int get lightCount => _lights.length;

  /// Total light-cluster references written during the last [assignLights]
  /// pass.
  int get totalAssignedLightRefs => _totalAssignedLightRefs;

  /// Unmodifiable view of the registered lights.
  List<ClusterLightEntry3D> get lights => List.unmodifiable(_lights);

  /// Removes all registered lights without reallocating internal buffers.
  void clearLights() {
    _lights.clear();
  }

  /// Appends [light] up to [maxLights] and returns its index.
  int addLight(ClusterLightEntry3D light) {
    if (_lights.length >= maxLights) {
      throw StateError(
        'LightClusterGrid3D capacity ($maxLights) exceeded; increase maxLights',
      );
    }
    final idx = _lights.length;
    _lights.add(light);
    return idx;
  }

  /// Replaces the registered lights with up to [maxLights] entries from
  /// [entries].
  void setLights(Iterable<ClusterLightEntry3D> entries) {
    _lights.clear();
    for (final entry in entries) {
      if (_lights.length >= maxLights) {
        break;
      }
      _lights.add(entry);
    }
  }

  /// Returns the registered light at [index].
  ClusterLightEntry3D lightAt(int index) => _lights[index];

  /// Computes the exponential depth slice index `0 .. clustersZ - 1` for a
  /// positive [viewDepth] (`floor(log(viewZ / near) / log(far / near) * Z)`).
  int zSliceForViewDepth(double viewDepth) {
    if (viewDepth <= _near) {
      return 0;
    }
    if (viewDepth >= _far) {
      return clustersZ - 1;
    }
    final raw = (math.log(viewDepth / _near) / _logFarOverNear * clustersZ)
        .floor();
    return raw.clamp(0, clustersZ - 1);
  }

  /// Returns the near view-space distance of exponential depth slice [zSlice].
  double sliceNearDepth(int zSlice) {
    RangeError.checkValidIndex(zSlice, _sliceNear, 'zSlice', clustersZ);
    return _sliceNear[zSlice];
  }

  /// Returns the far view-space distance of exponential depth slice [zSlice].
  double sliceFarDepth(int zSlice) {
    RangeError.checkValidIndex(zSlice, _sliceFar, 'zSlice', clustersZ);
    return _sliceFar[zSlice];
  }

  /// Linear cluster index for integer coordinates `(x, y, z)`.
  int clusterIndex(int x, int y, int z) {
    assert(
      x >= 0 &&
          x < clustersX &&
          y >= 0 &&
          y < clustersY &&
          z >= 0 &&
          z < clustersZ,
      'Cluster coordinates ($x, $y, $z) out of bounds',
    );
    return (z * clustersY + y) * clustersX + x;
  }

  /// Resolves the 3D cluster index for normalized screen coordinates
  /// `([normX], [normY])` in `[0, 1]` (`0` = left/bottom, `1` = right/top) and
  /// positive view-space depth [viewDepth].
  int clusterIndexForScreenDepth(
    double normX,
    double normY,
    double viewDepth,
  ) {
    final ix = (normX * clustersX).floor().clamp(0, clustersX - 1);
    final iy = (normY * clustersY).floor().clamp(0, clustersY - 1);
    final iz = zSliceForViewDepth(viewDepth);
    return (iz * clustersY + iy) * clustersX + ix;
  }

  /// Returns a zero-allocation `Int32List` view of the light indices assigned
  /// to [clusterIndex].
  Int32List lightsForCluster(int clusterIndex) {
    RangeError.checkValidIndex(
      clusterIndex,
      clusterCounts,
      'clusterIndex',
      totalClusters,
    );
    final count = clusterCounts[clusterIndex];
    if (count == 0) {
      return _emptyInts;
    }
    final offset = clusterOffsets[clusterIndex];
    return Int32List.sublistView(lightIndexList, offset, offset + count);
  }

  /// Reads the view-space AABB of [clusterIndex] computed by [assignLights].
  Aabb3 clusterViewBounds(int clusterIndex, {Aabb3? out}) {
    RangeError.checkValidIndex(
      clusterIndex,
      clusterCounts,
      'clusterIndex',
      totalClusters,
    );
    final b = clusterIndex * 6;
    final res = out ?? Aabb3();
    res.min.setValues(
      _clusterBoundsView[b],
      _clusterBoundsView[b + 1],
      _clusterBoundsView[b + 2],
    );
    res.max.setValues(
      _clusterBoundsView[b + 3],
      _clusterBoundsView[b + 4],
      _clusterBoundsView[b + 5],
    );
    return res;
  }

  /// Assigns all active [lights] into the `clustersX x clustersY x clustersZ`
  /// exponential frustum grid with zero heap allocations.
  void assignLights(
    Matrix4 view,
    Matrix4 projection, {
    required double near,
    required double far,
    int cameraMask = 0xFFFFFFFF,
  }) {
    if (near <= 0 || far <= near) {
      throw ArgumentError(
        'Expected 0 < near < far, got near=$near, far=$far',
      );
    }

    _ensureClusterBounds(projection, near, far);
    _scratchCounts.fillRange(0, totalClusters, 0);

    final v = view.storage;
    final count = _lights.length;

    for (var i = 0; i < count; i++) {
      final entry = _lights[i];
      if (entry.intensity <= 0 || (entry.lightMask & cameraMask) == 0) {
        _lightIntensity[i] = 0;
        continue;
      }

      final px = entry.position.x;
      final py = entry.position.y;
      final pz = entry.position.z;
      final vx = v[0] * px + v[4] * py + v[8] * pz + v[12];
      final vy = v[1] * px + v[5] * py + v[9] * pz + v[13];
      final vz = v[2] * px + v[6] * py + v[10] * pz + v[14];
      final r = entry.range;

      _viewPosX[i] = vx;
      _viewPosY[i] = vy;
      _viewPosZ[i] = vz;
      _lightRange[i] = r;
      _lightIntensity[i] = entry.intensity;

      final isSpot = entry.kind == ClusterLightKind3D.spot;
      _lightKind[i] = isSpot ? 1 : 0;

      var vdx = 0.0;
      var vdy = 0.0;
      var vdz = -1.0;
      var cosA = -1.0;
      var sinA = 0.0;
      if (isSpot) {
        final dx = entry.direction.x;
        final dy = entry.direction.y;
        final dz = entry.direction.z;
        vdx = v[0] * dx + v[4] * dy + v[8] * dz;
        vdy = v[1] * dx + v[5] * dy + v[9] * dz;
        vdz = v[2] * dx + v[6] * dy + v[10] * dz;
        final dLen = math.sqrt(vdx * vdx + vdy * vdy + vdz * vdz);
        if (dLen > 1e-12) {
          final inv = 1.0 / dLen;
          vdx *= inv;
          vdy *= inv;
          vdz *= inv;
        }
        cosA = entry.outerConeCos.clamp(-1.0, 1.0);
        sinA = math.sqrt(math.max(0.0, 1.0 - cosA * cosA));
        _viewDirX[i] = vdx;
        _viewDirY[i] = vdy;
        _viewDirZ[i] = vdz;
        _lightOuterCos[i] = cosA;
        _lightOuterSin[i] = sinA;
      }

      // View-space depth runs along -Z (`viewDepth = -vz`).
      final minDepth = -vz - r;
      final maxDepth = -vz + r;
      if (maxDepth < near || minDepth > far) {
        continue;
      }

      final iz0 = zSliceForViewDepth(math.max(near, minDepth));
      final iz1 = zSliceForViewDepth(math.min(far, maxDepth));
      final rSq = r * r;

      for (var iz = iz0; iz <= iz1; iz++) {
        final rowBase = iz * clustersY;
        for (var iy = 0; iy < clustersY; iy++) {
          final rb = (rowBase + iy) * 2;
          if (vy + r < _rowBoundsY[rb] || vy - r > _rowBoundsY[rb + 1]) {
            continue;
          }

          final cellBase = (rowBase + iy) * clustersX;
          for (var ix = 0; ix < clustersX; ix++) {
            final c = cellBase + ix;
            final slotCount = _scratchCounts[c];
            if (slotCount >= maxLightsPerCluster) {
              continue;
            }
            final b = c * 6;
            final bMinX = _clusterBoundsView[b];
            final bMinY = _clusterBoundsView[b + 1];
            final bMinZ = _clusterBoundsView[b + 2];
            final bMaxX = _clusterBoundsView[b + 3];
            final bMaxY = _clusterBoundsView[b + 4];
            final bMaxZ = _clusterBoundsView[b + 5];

            final qx = vx < bMinX ? bMinX - vx : (vx > bMaxX ? vx - bMaxX : 0);
            final qy = vy < bMinY ? bMinY - vy : (vy > bMaxY ? vy - bMaxY : 0);
            final qz = vz < bMinZ ? bMinZ - vz : (vz > bMaxZ ? vz - bMaxZ : 0);
            if (qx * qx + qy * qy + qz * qz > rSq) {
              continue;
            }

            if (isSpot &&
                !_coneIntersectsAabb(
                  vx,
                  vy,
                  vz,
                  vdx,
                  vdy,
                  vdz,
                  r,
                  cosA,
                  sinA,
                  bMinX,
                  bMinY,
                  bMinZ,
                  bMaxX,
                  bMaxY,
                  bMaxZ,
                )) {
              continue;
            }

            _scratchIndices[c * maxLightsPerCluster + slotCount] = i;
            _scratchCounts[c] = slotCount + 1;
          }
        }
      }
    }

    // Compact into CSR arrays `clusterOffsets`, `clusterCounts`, and
    // `lightIndexList`.
    var writeCursor = 0;
    for (var c = 0; c < totalClusters; c++) {
      clusterOffsets[c] = writeCursor;
      final n = _scratchCounts[c];
      clusterCounts[c] = n;
      if (n > 0) {
        final srcStart = c * maxLightsPerCluster;
        for (var k = 0; k < n; k++) {
          lightIndexList[writeCursor + k] = _scratchIndices[srcStart + k];
        }
        writeCursor += n;
      }
    }
    _totalAssignedLightRefs = writeCursor;
  }

  /// Queries the clusters overlapping [worldAabb] in [view] space and returns
  /// the highest-contributing local point and spot light indices.
  ClusterLightSelection3D gatherTopLightsForAabb(
    Aabb3 worldAabb,
    Matrix4 view, {
    int maxPointLights = 8,
    int maxSpotLights = 4,
  }) {
    final v = view.storage;
    var vMinX = double.infinity;
    var vMinY = double.infinity;
    var vMinZ = double.infinity;
    var vMaxX = double.negativeInfinity;
    var vMaxY = double.negativeInfinity;
    var vMaxZ = double.negativeInfinity;

    for (var corner = 0; corner < 8; corner++) {
      final wx = (corner & 1) == 0 ? worldAabb.min.x : worldAabb.max.x;
      final wy = (corner & 2) == 0 ? worldAabb.min.y : worldAabb.max.y;
      final wz = (corner & 4) == 0 ? worldAabb.min.z : worldAabb.max.z;
      final tx = v[0] * wx + v[4] * wy + v[8] * wz + v[12];
      final ty = v[1] * wx + v[5] * wy + v[9] * wz + v[13];
      final tz = v[2] * wx + v[6] * wy + v[10] * wz + v[14];
      if (tx < vMinX) {
        vMinX = tx;
      }
      if (tx > vMaxX) {
        vMaxX = tx;
      }
      if (ty < vMinY) {
        vMinY = ty;
      }
      if (ty > vMaxY) {
        vMaxY = ty;
      }
      if (tz < vMinZ) {
        vMinZ = tz;
      }
      if (tz > vMaxZ) {
        vMaxZ = tz;
      }
    }

    final minDepth = -vMaxZ;
    final maxDepth = -vMinZ;
    if (maxDepth < _near || minDepth > _far) {
      return ClusterLightSelection3D(_emptyInts, _emptyInts);
    }

    final iz0 = zSliceForViewDepth(math.max(_near, minDepth));
    final iz1 = zSliceForViewDepth(math.min(_far, maxDepth));
    final stamp = ++_stampGeneration;

    final centerVx = 0.5 * (vMinX + vMaxX);
    final centerVy = 0.5 * (vMinY + vMaxY);
    final centerVz = 0.5 * (vMinZ + vMaxZ);

    var pointCount = 0;
    var spotCount = 0;

    for (var iz = iz0; iz <= iz1; iz++) {
      final rowBase = iz * clustersY;
      for (var iy = 0; iy < clustersY; iy++) {
        final rb = (rowBase + iy) * 2;
        if (vMaxY < _rowBoundsY[rb] || vMinY > _rowBoundsY[rb + 1]) {
          continue;
        }
        final cellBase = (rowBase + iy) * clustersX;
        for (var ix = 0; ix < clustersX; ix++) {
          final c = cellBase + ix;
          final b = c * 6;
          if (vMaxX < _clusterBoundsView[b] ||
              vMinX > _clusterBoundsView[b + 3] ||
              vMaxY < _clusterBoundsView[b + 1] ||
              vMinY > _clusterBoundsView[b + 4] ||
              vMaxZ < _clusterBoundsView[b + 2] ||
              vMinZ > _clusterBoundsView[b + 5]) {
            continue;
          }

          final cCount = clusterCounts[c];
          final cOffset = clusterOffsets[c];
          for (var k = 0; k < cCount; k++) {
            final lightIdx = lightIndexList[cOffset + k];
            if (_seenStamp[lightIdx] == stamp) {
              continue;
            }
            _seenStamp[lightIdx] = stamp;

            final lx = _viewPosX[lightIdx];
            final ly = _viewPosY[lightIdx];
            final lz = _viewPosZ[lightIdx];
            final r = _lightRange[lightIdx];

            // Exact sphere vs view-space AABB check.
            final qx = lx < vMinX ? vMinX - lx : (lx > vMaxX ? lx - vMaxX : 0);
            final qy = ly < vMinY ? vMinY - ly : (ly > vMaxY ? ly - vMaxY : 0);
            final qz = lz < vMinZ ? vMinZ - lz : (lz > vMaxZ ? lz - vMaxZ : 0);
            if (qx * qx + qy * qy + qz * qz > r * r) {
              continue;
            }

            final dx = centerVx - lx;
            final dy = centerVy - ly;
            final dz = centerVz - lz;
            final dist = math.sqrt(dx * dx + dy * dy + dz * dz);
            final atten = math.max(0.01, 1.0 - (dist / r).clamp(0.0, 0.99));
            final score = _lightIntensity[lightIdx] * atten * atten;

            if (_lightKind[lightIdx] == 0) {
              _candidatePointIds[pointCount] = lightIdx;
              _candidatePointScores[pointCount] = score;
              pointCount++;
            } else {
              _candidateSpotIds[spotCount] = lightIdx;
              _candidateSpotScores[spotCount] = score;
              spotCount++;
            }
          }
        }
      }
    }

    _partialSortTopK(
      _candidatePointIds,
      _candidatePointScores,
      pointCount,
      maxPointLights,
    );
    _partialSortTopK(
      _candidateSpotIds,
      _candidateSpotScores,
      spotCount,
      maxSpotLights,
    );

    final outPointCount = math.min(pointCount, math.max(0, maxPointLights));
    final outSpotCount = math.min(spotCount, math.max(0, maxSpotLights));

    return ClusterLightSelection3D(
      outPointCount == 0
          ? _emptyInts
          : Int32List.fromList(
              Int32List.sublistView(_candidatePointIds, 0, outPointCount),
            ),
      outSpotCount == 0
          ? _emptyInts
          : Int32List.fromList(
              Int32List.sublistView(_candidateSpotIds, 0, outSpotCount),
            ),
    );
  }

  /// Packs per-cluster `(offsetLo, offsetHi, count, firstLightOrZero)` into an
  /// RGBA8 byte table (`totalClusters * 4` bytes) suitable for GPU texture
  /// upload.
  Uint8List packClusterDataRgba8({Uint8List? out}) {
    final bytes = out != null && out.length >= totalClusters * 4
        ? out
        : Uint8List(totalClusters * 4);
    for (var c = 0; c < totalClusters; c++) {
      final offset = clusterOffsets[c];
      final count = clusterCounts[c];
      final first = count > 0 ? (lightIndexList[offset] & 0xFF) : 0;
      final b = c * 4;
      bytes
        ..[b] = offset & 0xFF
        ..[b + 1] = (offset >> 8) & 0xFF
        ..[b + 2] = count.clamp(0, 255)
        ..[b + 3] = first;
    }
    return bytes;
  }

  /// Builds a 2D RGBA8 lookup [Texture] (`width = clustersX * clustersY`,
  /// `height = clustersZ`) holding [packClusterDataRgba8].
  Texture createClusterLookupTexture() {
    final data = packClusterDataRgba8();
    return Texture(
      ByteData.sublistView(data),
      width: clustersX * clustersY,
      height: clustersZ,
    );
  }

  void _ensureClusterBounds(Matrix4 projection, double near, double far) {
    final p = projection.storage;
    var same = _hasCachedProjection && near == _near && far == _far;
    if (same) {
      for (var i = 0; i < 16; i++) {
        if (p[i] != _cachedProjection[i]) {
          same = false;
          break;
        }
      }
    }
    if (same) {
      return;
    }

    _hasCachedProjection = true;
    _near = near;
    _far = far;
    _logFarOverNear = math.log(far / near);
    for (var i = 0; i < 16; i++) {
      _cachedProjection[i] = p[i];
    }

    final ratio = far / near;
    for (var iz = 0; iz < clustersZ; iz++) {
      _sliceNear[iz] = near * math.pow(ratio, iz / clustersZ);
      _sliceFar[iz] = near * math.pow(ratio, (iz + 1) / clustersZ);
    }

    _invProjScratch.setFrom(projection);
    final det = _invProjScratch.invert();
    final inv = _invProjScratch.storage;
    final cols = clustersX + 1;
    final rows = clustersY + 1;

    if (det.abs() > 1e-15) {
      for (var iy = 0; iy < rows; iy++) {
        final ndcY = (iy / clustersY) * 2.0 - 1.0;
        for (var ix = 0; ix < cols; ix++) {
          final ndcX = (ix / clustersX) * 2.0 - 1.0;
          final o = (iy * cols + ix) * 3;
          _unprojectClipPoint(inv, ndcX, ndcY, 0, near, _cornerNearView, o);
          _unprojectClipPoint(inv, ndcX, ndcY, 1, far, _cornerFarView, o);
        }
      }
    } else {
      // Degenerate fallback box if a singular matrix is supplied.
      for (var iy = 0; iy < rows; iy++) {
        final ndcY = (iy / clustersY) * 2.0 - 1.0;
        for (var ix = 0; ix < cols; ix++) {
          final ndcX = (ix / clustersX) * 2.0 - 1.0;
          final o = (iy * cols + ix) * 3;
          _cornerNearView
            ..[o] = ndcX * near
            ..[o + 1] = ndcY * near
            ..[o + 2] = -near;
          _cornerFarView
            ..[o] = ndcX * far
            ..[o + 1] = ndcY * far
            ..[o + 2] = -far;
        }
      }
    }

    final invSpan = 1.0 / (far - near);
    for (var iz = 0; iz < clustersZ; iz++) {
      final d0 = _sliceNear[iz];
      final d1 = _sliceFar[iz];
      final t0 = (d0 - near) * invSpan;
      final t1 = (d1 - near) * invSpan;

      for (var iy = 0; iy < clustersY; iy++) {
        var rMinY = double.infinity;
        var rMaxY = double.negativeInfinity;

        for (var ix = 0; ix < clustersX; ix++) {
          var minX = double.infinity;
          var minY = double.infinity;
          var maxX = double.negativeInfinity;
          var maxY = double.negativeInfinity;

          for (var dy = 0; dy <= 1; dy++) {
            for (var dx = 0; dx <= 1; dx++) {
              final co = ((iy + dy) * cols + (ix + dx)) * 3;
              final nx = _cornerNearView[co];
              final ny = _cornerNearView[co + 1];
              final fx = _cornerFarView[co];
              final fy = _cornerFarView[co + 1];

              final x0 = nx + (fx - nx) * t0;
              final y0 = ny + (fy - ny) * t0;
              final x1 = nx + (fx - nx) * t1;
              final y1 = ny + (fy - ny) * t1;

              minX = math.min(minX, math.min(x0, x1));
              maxX = math.max(maxX, math.max(x0, x1));
              minY = math.min(minY, math.min(y0, y1));
              maxY = math.max(maxY, math.max(y0, y1));
            }
          }

          if (minY < rMinY) {
            rMinY = minY;
          }
          if (maxY > rMaxY) {
            rMaxY = maxY;
          }

          final cb = ((iz * clustersY + iy) * clustersX + ix) * 6;
          _clusterBoundsView
            ..[cb] = minX
            ..[cb + 1] = minY
            ..[cb + 2] = -d1
            ..[cb + 3] = maxX
            ..[cb + 4] = maxY
            ..[cb + 5] = -d0;
        }

        final rb = (iz * clustersY + iy) * 2;
        _rowBoundsY
          ..[rb] = rMinY
          ..[rb + 1] = rMaxY;
      }
    }
  }

  static void _unprojectClipPoint(
    Float32List invProj,
    double ndcX,
    double ndcY,
    double ndcZ,
    double fallbackDepth,
    Float32List out,
    int offset,
  ) {
    final x =
        invProj[0] * ndcX + invProj[4] * ndcY + invProj[8] * ndcZ + invProj[12];
    final y =
        invProj[1] * ndcX + invProj[5] * ndcY + invProj[9] * ndcZ + invProj[13];
    final z =
        invProj[2] * ndcX +
        invProj[6] * ndcY +
        invProj[10] * ndcZ +
        invProj[14];
    final w =
        invProj[3] * ndcX +
        invProj[7] * ndcY +
        invProj[11] * ndcZ +
        invProj[15];
    if (w.abs() > 1e-12) {
      final invW = 1.0 / w;
      out
        ..[offset] = x * invW
        ..[offset + 1] = y * invW
        ..[offset + 2] = z * invW;
    } else {
      out
        ..[offset] = ndcX * fallbackDepth
        ..[offset + 1] = ndcY * fallbackDepth
        ..[offset + 2] = -fallbackDepth;
    }
  }

  /// Conservative spotlight cone vs cluster bounding-sphere test in view space.
  static bool _coneIntersectsAabb(
    double lx,
    double ly,
    double lz,
    double dx,
    double dy,
    double dz,
    double range,
    double cosA,
    double sinA,
    double minX,
    double minY,
    double minZ,
    double maxX,
    double maxY,
    double maxZ,
  ) {
    final cx = 0.5 * (minX + maxX);
    final cy = 0.5 * (minY + maxY);
    final cz = 0.5 * (minZ + maxZ);
    final hx = 0.5 * (maxX - minX);
    final hy = 0.5 * (maxY - minY);
    final hz = 0.5 * (maxZ - minZ);
    final cr = math.sqrt(hx * hx + hy * hy + hz * hz);

    final vx = cx - lx;
    final vy = cy - ly;
    final vz = cz - lz;
    final vLenSq = vx * vx + vy * vy + vz * vz;
    if (vLenSq <= cr * cr) {
      return true;
    }

    final axial = vx * dx + vy * dy + vz * dz;
    if (axial > range + cr) {
      return false;
    }
    if (cosA >= 0 && axial < -cr) {
      return false;
    }

    final vLen = math.sqrt(vLenSq);
    // Sphere center lies inside infinite cone (`cos(theta) >= cos(alpha)`).
    if (axial >= vLen * cosA) {
      return true;
    }

    final perp = math.sqrt(math.max(0.0, vLenSq - axial * axial));
    // When `cos(theta - alpha) >= 0`, closest point on the cone lies on its
    // side ray at perpendicular distance `perp * cosA - axial * sinA`.
    if (axial * cosA + perp * sinA >= 0) {
      return perp * cosA - axial * sinA <= cr;
    }
    // Otherwise closest point on the solid cone is the apex itself
    // (`vLen <= cr` already returned `true` above).
    return false;
  }

  static void _partialSortTopK(
    Int32List ids,
    Float32List scores,
    int length,
    int k,
  ) {
    final limit = math.min(length, math.max(0, k));
    for (var i = 0; i < limit; i++) {
      var best = i;
      var bestScore = scores[i];
      for (var j = i + 1; j < length; j++) {
        if (scores[j] > bestScore) {
          bestScore = scores[j];
          best = j;
        }
      }
      if (best != i) {
        final tmpId = ids[i];
        ids[i] = ids[best];
        ids[best] = tmpId;
        final tmpScore = scores[i];
        scores[i] = scores[best];
        scores[best] = tmpScore;
      }
    }
  }
}
