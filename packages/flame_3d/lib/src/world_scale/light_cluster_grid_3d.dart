import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:flame_3d/core.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/src/graphics/light_culling_math.dart';

part 'light_cluster_grid_assignment_3d.dart';

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

/// A CPU helper that bins point and spot lights into the clusters of a
/// camera frustum (`16 x 8 x 16` by default, with exponential depth
/// slices), without allocating per frame, for up to `512` (or [maxLights])
/// lights.
///
/// It is not part of the renderer: no built-in material or render pass reads
/// it, and adding lights to it lights nothing. Every render pass still
/// shades at most `RenderContext3D.maxPointLights` (8) point lights and
/// `RenderContext3D.maxSpotLights` (4) spot lights, chosen once per pass for
/// the whole pass (see `World3D.prioritizeNearestLights`); the others are
/// left out. Use the grid to find, among many lights, those that reach a
/// region of the screen or of the world ([lightsForCluster],
/// [gatherTopLightsForAabb]), for instance to decide which lights to add to
/// the world, or which to bake into a `LightProbeGrid3D`; or pack it
/// ([packClusterDataRgba8]) for a clustered shader of your own.
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
  final Float32List _clusterSpheres = Float32List(
    clustersX * clustersY * clustersZ * 4,
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
  }) => _assignLightsImpl(
    view,
    projection,
    near: near,
    far: far,
    cameraMask: cameraMask,
  );

  /// Queries the clusters overlapping [worldAabb] in [view] space and returns
  /// the highest-contributing local point and spot light indices.
  ///
  /// It allocates the returned selection and its two lists (unless they are
  /// empty): call it when the lights change, not for every object of every
  /// frame.
  ClusterLightSelection3D gatherTopLightsForAabb(
    Aabb3 worldAabb,
    Matrix4 view, {
    int maxPointLights = 8,
    int maxSpotLights = 4,
  }) => _gatherTopLightsForAabbImpl(
    worldAabb,
    view,
    maxPointLights: maxPointLights,
    maxSpotLights: maxSpotLights,
  );

  /// Packs per-cluster `(offsetLo, offsetHi, count, firstLightOrZero)` into an
  /// RGBA8 byte table (`totalClusters * 4` bytes) suitable for GPU texture
  /// upload.
  ///
  /// The offset into [lightIndexList] takes 16 bits, the count and the index
  /// of the cluster's first light 8 bits each: when an offset is above
  /// 65,535, a count above 255 or a first light index above 255 (with more
  /// than 256 lights), it throws a [StateError] rather than wrap the value.
  /// Read [clusterOffsets], [clusterCounts] and [lightIndexList] directly for
  /// such grids. No index list texture is provided.
  Uint8List packClusterDataRgba8({Uint8List? out}) {
    final bytes = out != null && out.length >= totalClusters * 4
        ? out
        : Uint8List(totalClusters * 4);
    for (var c = 0; c < totalClusters; c++) {
      final offset = clusterOffsets[c];
      final count = clusterCounts[c];
      final first = count > 0 ? lightIndexList[offset] : 0;
      if (offset > 0xFFFF || count > 0xFF || first > 0xFF) {
        throw StateError(
          'Cluster $c does not fit in 8-bit texels (offset $offset of at most '
          '65535, count $count and first light index $first of at most 255)',
        );
      }
      final b = c * 4;
      bytes
        ..[b] = offset & 0xFF
        ..[b + 1] = (offset >> 8) & 0xFF
        ..[b + 2] = count
        ..[b + 3] = first;
    }
    return bytes;
  }

  /// Builds a 2D RGBA8 lookup [Texture] (`width = clustersX * clustersY`,
  /// `height = clustersZ`) holding [packClusterDataRgba8] (which throws for
  /// grids whose values do not fit), for a shader of your own: no built-in
  /// shader reads it.
  Texture createClusterLookupTexture() {
    final data = packClusterDataRgba8();
    return Texture(
      ByteData.sublistView(data),
      width: clustersX * clustersY,
      height: clustersZ,
    );
  }
}
