import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame_3d/core.dart';
import 'package:flame_3d/resources.dart';

/// Nearest walkable polygon query result returned by
/// [NavMesh3D.findNearestPoly].
class NavPolyHit3D({
  required final int polyIndex,
  required final Vector3 point,
  required final double distanceSquared,
});

/// Directed shared edge portal from one walkable triangle into an adjacent
/// walkable triangle.
///
/// [left] and [right] are the edge's end points as seen when leaving the
/// owning polygon towards [targetPoly]; [leftVertex] and [rightVertex] are
/// their indices in [NavMesh3D.vertices] (`-1` when the portal was not built
/// from a mesh vertex list).
class NavPortal3D({
  required final int targetPoly,
  required final Vector3 left,
  required final Vector3 right,
  required final double cost,
  final int leftVertex = -1,
  final int rightVertex = -1,
});

/// A single walkable triangle polygon inside a [NavMesh3D].
class NavPoly3D({
  required final int index,
  required final int v0,
  required final int v1,
  required final int v2,
  required final Vector3 centroid,
  required final Vector3 normal,
  required final List<NavPortal3D> portals,
});

/// Dynamic oriented box obstacle that blocks overlapping [NavMesh3D] polygons
/// in `O(log P)` via the navmesh BVH without rebuilding static geometry.
///
/// An obstacle blocks **whole polygons**: every polygon the box touches is
/// excluded from searches, nearest-polygon queries and height sampling. It
/// does not cut the polygons along the box, and it does not grow the box by
/// an agent radius. On a `NavMeshBuilder3D` mesh the blocked area is therefore
/// the box rounded out to whole voxel cells (`cellSize`); on a coarse mesh
/// (for example a floor of two triangles from `NavMesh3D.fromMesh`) a small
/// box can block a large triangle. Grow [halfExtents] by the agent radius
/// yourself when agents must keep clear of the box.
class NavMeshObstacle3D({
  required Vector3 center,
  required Vector3 halfExtents,
  Quaternion? rotation,
  var bool enabled = true,
}) {
  this
    : assert(
        halfExtents.x > 0 && halfExtents.y > 0 && halfExtents.z > 0,
        'halfExtents must be positive',
      );

  /// Creates an axis-aligned obstacle covering [bounds].
  factory NavMeshObstacle3D.fromAabb(Aabb3 bounds, {bool enabled = true}) {
    final center = Vector3(
      0.5 * (bounds.min.x + bounds.max.x),
      0.5 * (bounds.min.y + bounds.max.y),
      0.5 * (bounds.min.z + bounds.max.z),
    );
    final half = Vector3(
      math.max(1e-3, 0.5 * (bounds.max.x - bounds.min.x)),
      math.max(1e-3, 0.5 * (bounds.max.y - bounds.min.y)),
      math.max(1e-3, 0.5 * (bounds.max.z - bounds.min.z)),
    );
    return NavMeshObstacle3D(
      center: center,
      halfExtents: half,
      enabled: enabled,
    );
  }

  /// World-space center of this obstacle.
  final Vector3 center = center.clone();

  /// Local half-extents `(hx, hy, hz)`.
  final Vector3 halfExtents = halfExtents.clone();

  /// World-space orientation of this obstacle.
  final Quaternion rotation = (rotation?.clone() ?? Quaternion.identity())
    ..normalize();

  final Matrix3 _rotMat = Matrix3.zero();
  final Aabb3 _worldAabb = Aabb3();

  /// Computes the tight world-space AABB enclosing this oriented box.
  Aabb3 computeWorldAabb({Aabb3? out}) {
    final res = out ?? _worldAabb;
    _rotMat.setFrom(rotation.asRotationMatrix());
    final r = _rotMat.storage;
    final hx = halfExtents.x;
    final hy = halfExtents.y;
    final hz = halfExtents.z;
    final ex = r[0].abs() * hx + r[3].abs() * hy + r[6].abs() * hz;
    final ey = r[1].abs() * hx + r[4].abs() * hy + r[7].abs() * hz;
    final ez = r[2].abs() * hx + r[5].abs() * hy + r[8].abs() * hz;
    res.min.setValues(center.x - ex, center.y - ey, center.z - ez);
    res.max.setValues(center.x + ex, center.y + ey, center.z + ez);
    return res;
  }
}

/// Traversal connection bridging two disconnected or elevated points on a
/// [NavMesh3D] (such as a jump pad, gap leap, ladder, or teleporter).
///
/// Each end point is snapped to the nearest unblocked polygon when a path is
/// planned; an end point farther than `snapRadius` from every such polygon
/// leaves the link unconnected. Changes to [enabled], [start] and [end]
/// (including in-place edits such as `link.end.setValues(...)`) are picked up
/// by the next query.
class OffMeshLink3D({
  required Vector3 start,
  required Vector3 end,
  final bool bidirectional = true,
  final double costMultiplier = 1.0,
  final String linkTag = 'jump',
  var bool enabled = true,
  final double snapRadius = double.infinity,
}) {
  this
    : assert(costMultiplier > 0, 'costMultiplier must be positive'),
      assert(snapRadius > 0, 'snapRadius must be positive');

  /// World-space start endpoint of the link.
  final Vector3 start = start.clone();

  /// World-space end endpoint of the link.
  final Vector3 end = end.clone();

  // The state the link had when its owning mesh last resolved it.
  bool _resolvedEnabled = false;
  final Vector3 _resolvedStart = Vector3.all(double.nan);
  final Vector3 _resolvedEnd = Vector3.all(double.nan);

  bool _changedSinceResolve() {
    return enabled != _resolvedEnabled ||
        start.x != _resolvedStart.x ||
        start.y != _resolvedStart.y ||
        start.z != _resolvedStart.z ||
        end.x != _resolvedEnd.x ||
        end.y != _resolvedEnd.y ||
        end.z != _resolvedEnd.z;
  }

  void _markResolved() {
    _resolvedEnabled = enabled;
    _resolvedStart.setFrom(start);
    _resolvedEnd.setFrom(end);
  }
}

/// A contiguous surface walk leg or [OffMeshLink3D] traversal leg returned by
/// [NavMesh3D.findSegmentedPath].
class NavPathSegment3D({
  required List<Vector3> waypoints,
  this.offMeshLink,
  this.linkTag,
}) {
  /// Ordered 3D waypoints along this segment (`[entry, exit]` for off-mesh
  /// links; string-pulled funnel waypoints for surface walk legs).
  final List<Vector3> waypoints = List.unmodifiable(waypoints);

  /// The traversed [OffMeshLink3D], or `null` for an ordinary surface walk leg.
  final OffMeshLink3D? offMeshLink;

  /// Semantic traversal tag (e.g. `'jump'`, `'ladder'`) when [isOffMeshLink] is
  /// `true`, or `null` for surface walk legs.
  final String? linkTag;

  /// Whether this segment traverses an [OffMeshLink3D].
  bool get isOffMeshLink => offMeshLink != null;
}

/// 3D triangle navigation mesh built from any [Mesh] or Recast voxel
/// `NavMeshBuilder3D`, featuring spatial vertex welding, portal adjacency,
/// weighted polygon area costs, `O(log P)` dynamic [NavMeshObstacle3D]
/// blocking (of whole polygons), [OffMeshLink3D] connections, A* search, and
/// 3D Simple Stupid Funnel string-pulling with elevation draping.
///
/// Queries are not re-entrant: the search state is kept on the mesh and
/// reused by every query (it is allocated once, `O(P)`).
class NavMesh3D._({
  required final List<Vector3> vertices,
  required final List<NavPoly3D> polygons,
  required Vector3 upAxis,
}) {
  this {
    if (this.upAxis.x.abs() < 0.9) {
      _basisU.setValues(1.0, 0.0, 0.0);
    } else {
      _basisU.setValues(0.0, 1.0, 0.0);
    }
    _basisU
      ..addScaled(this.upAxis, -_basisU.dot(this.upAxis))
      ..normalize();
    _basisV.setFrom(this.upAxis.cross(_basisU)..normalize());

    _polygonCosts = Float32List(polygons.length)
      ..fillRange(0, polygons.length, 1.0);
    polygonCosts = _polygonCosts.asUnmodifiableView();
    _polyObstacleRefCount = Int32List(polygons.length);
  }

  /// Extracts walkable triangles (`normal.dot(up) >= cos(maxSlopeAngleRad)`)
  /// from [mesh] (optionally transformed by [transform]), welds vertices within
  /// [weldEpsilon], and builds triangle portal adjacency.
  factory NavMesh3D.fromMesh(
    Mesh mesh, {
    Matrix4? transform,
    Vector3? upAxis,
    double maxSlopeAngleRad = 0.8,
    double weldEpsilon = 1e-3,
  }) {
    final up = (upAxis?.clone() ?? Vector3(0.0, 1.0, 0.0))..normalize();
    final minCos = math.cos(maxSlopeAngleRad);
    final eps = math.max(1e-7, weldEpsilon);
    final eps2 = eps * eps;
    final invCell = 1.0 / eps;

    final weldedVerts = <Vector3>[];
    final spatialHash = <(int, int, int), List<int>>{};

    int weldVertex(double wx, double wy, double wz) {
      final cx = (wx * invCell).floor();
      final cy = (wy * invCell).floor();
      final cz = (wz * invCell).floor();
      for (var dx = -1; dx <= 1; dx++) {
        for (var dy = -1; dy <= 1; dy++) {
          for (var dz = -1; dz <= 1; dz++) {
            final bucket = spatialHash[(cx + dx, cy + dy, cz + dz)];
            if (bucket == null) {
              continue;
            }
            for (var k = 0; k < bucket.length; k++) {
              final idx = bucket[k];
              final existing = weldedVerts[idx];
              final ex = existing.x - wx;
              final ey = existing.y - wy;
              final ez = existing.z - wz;
              if (ex * ex + ey * ey + ez * ez <= eps2) {
                return idx;
              }
            }
          }
        }
      }
      final newIdx = weldedVerts.length;
      weldedVerts.add(Vector3(wx, wy, wz));
      (spatialHash[(cx, cy, cz)] ??= <int>[]).add(newIdx);
      return newIdx;
    }

    final m = transform?.storage;
    final rawTris = <(int, int, int, Vector3)>[];

    for (final surface in mesh.surfaces) {
      if (surface.indexCount < 3) {
        continue;
      }
      final pos = surface.positions;
      final indices = surface.indices;
      final triCount = indices.length ~/ 3;

      for (var t = 0; t < triCount; t++) {
        final base = t * 3;
        final raw0 = indices[base] * 3;
        final raw1 = indices[base + 1] * 3;
        final raw2 = indices[base + 2] * 3;

        var x0 = pos[raw0];
        var y0 = pos[raw0 + 1];
        var z0 = pos[raw0 + 2];
        var x1 = pos[raw1];
        var y1 = pos[raw1 + 1];
        var z1 = pos[raw1 + 2];
        var x2 = pos[raw2];
        var y2 = pos[raw2 + 1];
        var z2 = pos[raw2 + 2];

        if (m != null) {
          final tx0 = m[0] * x0 + m[4] * y0 + m[8] * z0 + m[12];
          final ty0 = m[1] * x0 + m[5] * y0 + m[9] * z0 + m[13];
          final tz0 = m[2] * x0 + m[6] * y0 + m[10] * z0 + m[14];
          final tx1 = m[0] * x1 + m[4] * y1 + m[8] * z1 + m[12];
          final ty1 = m[1] * x1 + m[5] * y1 + m[9] * z1 + m[13];
          final tz1 = m[2] * x1 + m[6] * y1 + m[10] * z1 + m[14];
          final tx2 = m[0] * x2 + m[4] * y2 + m[8] * z2 + m[12];
          final ty2 = m[1] * x2 + m[5] * y2 + m[9] * z2 + m[13];
          final tz2 = m[2] * x2 + m[6] * y2 + m[10] * z2 + m[14];
          x0 = tx0;
          y0 = ty0;
          z0 = tz0;
          x1 = tx1;
          y1 = ty1;
          z1 = tz1;
          x2 = tx2;
          y2 = ty2;
          z2 = tz2;
        }

        final e1x = x1 - x0;
        final e1y = y1 - y0;
        final e1z = z1 - z0;
        final e2x = x2 - x0;
        final e2y = y2 - y0;
        final e2z = z2 - z0;
        var nx = e1y * e2z - e1z * e2y;
        var ny = e1z * e2x - e1x * e2z;
        var nz = e1x * e2y - e1y * e2x;
        final nLen = math.sqrt(nx * nx + ny * ny + nz * nz);
        if (nLen <= 1e-10) {
          continue;
        }
        nx /= nLen;
        ny /= nLen;
        nz /= nLen;

        var flipWinding = false;
        if (transform != null && transform.determinant() < 0.0) {
          nx = -nx;
          ny = -ny;
          nz = -nz;
          flipWinding = true;
        }

        final cosSlope = nx * up.x + ny * up.y + nz * up.z;
        if (cosSlope < minCos) {
          continue;
        }

        final w0 = weldVertex(x0, y0, z0);
        final w1 = weldVertex(x1, y1, z1);
        final w2 = weldVertex(x2, y2, z2);
        if (w0 == w1 || w1 == w2 || w2 == w0) {
          continue;
        }

        final i0 = w0;
        final i1 = flipWinding ? w2 : w1;
        final i2 = flipWinding ? w1 : w2;
        rawTris.add((i0, i1, i2, Vector3(nx, ny, nz)));
      }
    }

    return NavMesh3D.fromIndexedTriangles(
      vertices: weldedVerts,
      triangles: rawTris,
      upAxis: up,
    );
  }

  /// Builds a [NavMesh3D] directly from pre-welded [vertices] and walkable
  /// `(i0, i1, i2, normal)` [triangles], connecting shared edges into
  /// [NavPortal3D]s.
  factory NavMesh3D.fromIndexedTriangles({
    required List<Vector3> vertices,
    required List<(int, int, int, Vector3)> triangles,
    Vector3? upAxis,
  }) {
    final up = (upAxis?.clone() ?? Vector3(0.0, 1.0, 0.0))..normalize();
    final rawPolys = <(int, int, int, Vector3, Vector3)>[];

    for (var idx = 0; idx < triangles.length; idx++) {
      final (i0, i1, i2, norm) = triangles[idx];
      if (i0 == i1 || i1 == i2 || i2 == i0) {
        continue;
      }
      final p0 = vertices[i0];
      final p1 = vertices[i1];
      final p2 = vertices[i2];
      final centroid = Vector3(
        (p0.x + p1.x + p2.x) * (1.0 / 3.0),
        (p0.y + p1.y + p2.y) * (1.0 / 3.0),
        (p0.z + p1.z + p2.z) * (1.0 / 3.0),
      );
      rawPolys.add((i0, i1, i2, centroid, norm.clone()));
    }

    final edgeMap = <(int, int), List<int>>{};
    for (var pIdx = 0; pIdx < rawPolys.length; pIdx++) {
      final (i0, i1, i2, _, _) = rawPolys[pIdx];
      for (final (ea, eb) in [(i0, i1), (i1, i2), (i2, i0)]) {
        final key = ea < eb ? (ea, eb) : (eb, ea);
        (edgeMap[key] ??= <int>[]).add(pIdx);
      }
    }

    final portalLists = List<List<NavPortal3D>>.generate(
      rawPolys.length,
      (_) => <NavPortal3D>[],
    );

    for (final entry in edgeMap.entries) {
      final (ea, eb) = entry.key;
      final owners = entry.value;
      if (owners.length < 2) {
        continue;
      }
      final va = vertices[ea];
      final vb = vertices[eb];

      for (var i = 0; i < owners.length; i++) {
        final polyA = owners[i];
        final (a0, a1, a2, centA, _) = rawPolys[polyA];
        final oppIdx = (a0 != ea && a0 != eb)
            ? a0
            : ((a1 != ea && a1 != eb) ? a1 : a2);
        final opp = vertices[oppIdx];

        final orient = _triArea2Up(opp, va, vb, up);
        final right = orient >= 0.0 ? va : vb;
        final left = orient >= 0.0 ? vb : va;
        final rightIdx = orient >= 0.0 ? ea : eb;
        final leftIdx = orient >= 0.0 ? eb : ea;

        for (var j = 0; j < owners.length; j++) {
          if (i == j) {
            continue;
          }
          final polyB = owners[j];
          final (_, _, _, centB, _) = rawPolys[polyB];
          portalLists[polyA].add(
            NavPortal3D(
              targetPoly: polyB,
              left: left,
              right: right,
              cost: centA.distanceTo(centB),
              leftVertex: leftIdx,
              rightVertex: rightIdx,
            ),
          );
        }
      }
    }

    final polys = List<NavPoly3D>.generate(rawPolys.length, (idx) {
      final (i0, i1, i2, cent, norm) = rawPolys[idx];
      return NavPoly3D(
        index: idx,
        v0: i0,
        v1: i1,
        v2: i2,
        centroid: cent,
        normal: norm,
        portals: List.unmodifiable(portalLists[idx]),
      );
    }, growable: false);

    return NavMesh3D._(
      vertices: List.unmodifiable([for (final v in vertices) v.clone()]),
      polygons: List.unmodifiable(polys),
      upAxis: up,
    );
  }

  /// Normalized up axis used when classifying walkable slopes and orienting
  /// portals.
  final Vector3 upAxis = upAxis.normalized();

  /// Per-polygon traversal cost multipliers (`1.0` default; higher values such
  /// as `3.5` represent slow mud/sand, respected by A* pathfinding).
  ///
  /// This is a read-only view: change costs with [setPolygonCost] or
  /// [setRegionCostInAabb], which keep the search's distance estimate
  /// admissible. Writing into the list throws an [UnsupportedError].
  late final Float32List polygonCosts;
  late final Float32List _polygonCosts;

  late final Int32List _polyObstacleRefCount;
  int _blockedPolyCount = 0;
  double _minPolygonCost = 1.0;

  final Map<NavMeshObstacle3D, Int32List> _obstaclePolys = {};
  final List<OffMeshLink3D> _offMeshLinks = [];
  final List<_ResolvedOffMeshLink> _resolvedLinks = [];
  // Indices into `_resolvedLinks` of the links leaving each polygon.
  final Map<int, List<int>> _linksFromPoly = {};
  bool _linksDirty = false;

  // Search state reused by every A* query (`O(P)` once, not per query). An
  // entry is valid for the running search only when its stamp equals
  // `_searchStamp`.
  Float64List? _gScore;
  Int32List? _cameFrom;
  Int32List? _cameViaLink;
  Int32List? _openStamp;
  Int32List? _closedStamp;
  _MinPolyHeap? _heap;
  int _searchStamp = 0;

  // Scratch of the corridor string pulling.
  final List<Vector3> _portalLeft = [];
  final List<Vector3> _portalRight = [];
  final List<int> _portalLeftVertex = [];
  final List<int> _portalRightVertex = [];
  final List<Vector3> _cornerPoints = [];
  final List<int> _cornerPortal = [];
  final List<int> _cornerVertex = [];
  final List<int> _cornerSide = [];

  final Vector3 _basisU = Vector3.zero();
  final Vector3 _basisV = Vector3.zero();
  final List<int> _bvhCandidatesScratch = [];
  late final _NavPolyBvh _bvh = _NavPolyBvh.build(vertices, polygons);

  /// Number of walkable triangles in this navmesh.
  int get polyCount => polygons.length;

  /// Number of polygons currently blocked by active [NavMeshObstacle3D]s.
  int get blockedPolygonCount => _blockedPolyCount;

  /// Registered [OffMeshLink3D] connections.
  List<OffMeshLink3D> get offMeshLinks => List.unmodifiable(_offMeshLinks);

  /// Returns `true` when polygon [polyIndex] is currently blocked by at least
  /// one active [NavMeshObstacle3D].
  bool isPolygonBlocked(int polyIndex) => _polyObstacleRefCount[polyIndex] > 0;

  /// Sets the traversal cost multiplier of [polyIndex] (`> 0`).
  void setPolygonCost(int polyIndex, double cost) {
    assert(cost > 0, 'polygon cost must be positive');
    _polygonCosts[polyIndex] = cost;
    if (cost < _minPolygonCost) {
      _minPolygonCost = cost;
    }
  }

  /// Returns the traversal cost multiplier of [polyIndex].
  double getPolygonCost(int polyIndex) => _polygonCosts[polyIndex];

  /// Sets the traversal [cost] (`> 0`) of all walkable polygons intersecting
  /// [bounds] in `O(log P)` via the navmesh BVH, returning the number of
  /// updated polygons.
  int setRegionCostInAabb(Aabb3 bounds, double cost) {
    assert(cost > 0, 'region cost must be positive');
    if (polygons.isEmpty) {
      return 0;
    }
    _bvhCandidatesScratch.clear();
    _bvh.queryAabb(bounds, _bvhCandidatesScratch);
    var updated = 0;
    for (var i = 0; i < _bvhCandidatesScratch.length; i++) {
      final pIdx = _bvhCandidatesScratch[i];
      final poly = polygons[pIdx];
      if (_triangleIntersectsAabb(
        vertices[poly.v0],
        vertices[poly.v1],
        vertices[poly.v2],
        bounds,
      )) {
        _polygonCosts[pIdx] = cost;
        updated++;
      }
    }
    if (updated > 0 && cost < _minPolygonCost) {
      _minPolygonCost = cost;
    }
    return updated;
  }

  /// Dynamically blocks all walkable polygons intersected by [obstacle] in
  /// `O(log P)` via the BVH.
  void addObstacle(NavMeshObstacle3D obstacle) {
    if (_obstaclePolys.containsKey(obstacle)) {
      updateObstacle(obstacle);
      return;
    }
    final blocked = obstacle.enabled
        ? _computeBlockedPolygons(obstacle)
        : Int32List(0);
    _obstaclePolys[obstacle] = blocked;
    _incrementRefCounts(blocked);
    _linksDirty = true;
  }

  /// Refreshes the blocked polygon set after [obstacle] moves, rotates,
  /// resizes, or toggles `enabled`.
  void updateObstacle(NavMeshObstacle3D obstacle) {
    final prev = _obstaclePolys[obstacle];
    if (prev != null) {
      _decrementRefCounts(prev);
    }
    final next = obstacle.enabled
        ? _computeBlockedPolygons(obstacle)
        : Int32List(0);
    _obstaclePolys[obstacle] = next;
    _incrementRefCounts(next);
    _linksDirty = true;
  }

  /// Removes [obstacle] and immediately unblocks its polygons.
  void removeObstacle(NavMeshObstacle3D obstacle) {
    final prev = _obstaclePolys.remove(obstacle);
    if (prev != null) {
      _decrementRefCounts(prev);
      _linksDirty = true;
    }
  }

  /// Registers an [OffMeshLink3D] (jump, drop, ladder, or teleporter) for
  /// seamless A* traversal.
  void addOffMeshLink(OffMeshLink3D link) {
    if (!_offMeshLinks.contains(link)) {
      _offMeshLinks.add(link);
      _linksDirty = true;
    }
  }

  /// Unregisters [link].
  void removeOffMeshLink(OffMeshLink3D link) {
    if (_offMeshLinks.remove(link)) {
      _linksDirty = true;
    }
  }

  Int32List _computeBlockedPolygons(NavMeshObstacle3D obstacle) {
    if (polygons.isEmpty) {
      return Int32List(0);
    }
    final worldBox = obstacle.computeWorldAabb();
    _bvhCandidatesScratch.clear();
    _bvh.queryAabb(worldBox, _bvhCandidatesScratch);
    if (_bvhCandidatesScratch.isEmpty) {
      return Int32List(0);
    }

    final rotT = obstacle.rotation.conjugated();
    final localBox = Aabb3.minMax(-obstacle.halfExtents, obstacle.halfExtents);
    final v0L = Vector3.zero();
    final v1L = Vector3.zero();
    final v2L = Vector3.zero();
    final matched = <int>[];

    for (var i = 0; i < _bvhCandidatesScratch.length; i++) {
      final pIdx = _bvhCandidatesScratch[i];
      final poly = polygons[pIdx];
      _toLocalObb(vertices[poly.v0], obstacle.center, rotT, v0L);
      _toLocalObb(vertices[poly.v1], obstacle.center, rotT, v1L);
      _toLocalObb(vertices[poly.v2], obstacle.center, rotT, v2L);
      if (_triangleIntersectsAabb(v0L, v1L, v2L, localBox)) {
        matched.add(pIdx);
      }
    }
    return Int32List.fromList(matched);
  }

  static void _toLocalObb(
    Vector3 worldPt,
    Vector3 center,
    Quaternion invRot,
    Vector3 out,
  ) {
    out
      ..setFrom(worldPt)
      ..sub(center);
    invRot.rotate(out);
  }

  void _incrementRefCounts(Int32List polyIds) {
    for (var i = 0; i < polyIds.length; i++) {
      final p = polyIds[i];
      if (_polyObstacleRefCount[p] == 0) {
        _blockedPolyCount++;
      }
      _polyObstacleRefCount[p]++;
    }
  }

  void _decrementRefCounts(Int32List polyIds) {
    for (var i = 0; i < polyIds.length; i++) {
      final p = polyIds[i];
      if (_polyObstacleRefCount[p] > 0) {
        _polyObstacleRefCount[p]--;
        if (_polyObstacleRefCount[p] == 0) {
          _blockedPolyCount--;
        }
      }
    }
  }

  void _ensureLinksResolved() {
    if (!_linksDirty) {
      for (var i = 0; i < _offMeshLinks.length; i++) {
        if (_offMeshLinks[i]._changedSinceResolve()) {
          _linksDirty = true;
          break;
        }
      }
      if (!_linksDirty) {
        return;
      }
    }
    _linksDirty = false;
    _resolvedLinks.clear();
    _linksFromPoly.clear();
    for (var i = 0; i < _offMeshLinks.length; i++) {
      _offMeshLinks[i]._markResolved();
    }
    if (polygons.isEmpty || _offMeshLinks.isEmpty) {
      return;
    }

    for (var i = 0; i < _offMeshLinks.length; i++) {
      final link = _offMeshLinks[i];
      if (!link.enabled) {
        continue;
      }
      final sHit = findNearestPoly(link.start);
      final eHit = findNearestPoly(link.end);
      if (sHit == null || eHit == null || sHit.polyIndex == eHit.polyIndex) {
        continue;
      }
      final snap2 = link.snapRadius * link.snapRadius;
      if (sHit.distanceSquared > snap2 || eHit.distanceSquared > snap2) {
        continue;
      }
      final baseDist = math.max(1e-3, sHit.point.distanceTo(eHit.point));
      final cost = baseDist * link.costMultiplier;
      _addResolvedLink(
        _ResolvedOffMeshLink(
          link: link,
          fromPoly: sHit.polyIndex,
          toPoly: eHit.polyIndex,
          entryPoint: sHit.point,
          exitPoint: eHit.point,
          cost: cost,
        ),
      );
      if (link.bidirectional) {
        _addResolvedLink(
          _ResolvedOffMeshLink(
            link: link,
            fromPoly: eHit.polyIndex,
            toPoly: sHit.polyIndex,
            entryPoint: eHit.point,
            exitPoint: sHit.point,
            cost: cost,
          ),
        );
      }
    }
  }

  void _addResolvedLink(_ResolvedOffMeshLink resolved) {
    (_linksFromPoly[resolved.fromPoly] ??= <int>[]).add(_resolvedLinks.length);
    _resolvedLinks.add(resolved);
  }

  /// Clamps an arbitrary 3D [point] onto the closest unblocked walkable
  /// triangle, returning `null` when no unblocked walkable polygon exists.
  NavPolyHit3D? findNearestPoly(
    Vector3 point, {
    bool ignoreObstacles = false,
  }) {
    if (polygons.isEmpty) {
      return null;
    }
    return _bvh.findNearest(
      point,
      vertices,
      polygons,
      ignoreObstacles ? null : _polyObstacleRefCount,
    );
  }

  /// Samples the walkable surface elevation (coordinate along [upAxis]) at the
  /// horizontal projection of [pos], picking the layer closest in elevation to
  /// [pos] on multi-level bridges/overpasses, or `null` if [pos] lies outside
  /// all unblocked walkable polygons horizontally.
  ///
  /// Only the polygons whose bounds the vertical line through [pos] crosses
  /// are tested (through the navmesh BVH), so a query costs `O(log P)` plus
  /// the number of layers at that point.
  double? sampleHeightAt(Vector3 pos) {
    if (polygons.isEmpty) {
      return null;
    }
    final targetUp = pos.dot(upAxis);
    final pu = pos.dot(_basisU);
    final pv = pos.dot(_basisV);

    double? bestElevation;
    var bestVerticalDiff = double.infinity;

    final candidates = _bvhCandidatesScratch..clear();
    _bvh.queryLine(pos, upAxis, candidates);
    for (var k = 0; k < candidates.length; k++) {
      final i = candidates[k];
      if (_polyObstacleRefCount[i] > 0) {
        continue;
      }
      final poly = polygons[i];
      final a = vertices[poly.v0];
      final b = vertices[poly.v1];
      final c = vertices[poly.v2];

      final au = a.dot(_basisU);
      final av = a.dot(_basisV);
      final bu = b.dot(_basisU);
      final bv = b.dot(_basisV);
      final cu = c.dot(_basisU);
      final cv = c.dot(_basisV);

      final v0u = bu - au;
      final v0v = bv - av;
      final v1u = cu - au;
      final v1v = cv - av;
      final denom = v0u * v1v - v1u * v0v;
      if (denom.abs() <= 1e-12) {
        continue;
      }
      final inv = 1.0 / denom;
      final qpu = pu - au;
      final qpv = pv - av;
      final w1 = (qpu * v1v - v1u * qpv) * inv;
      final w2 = (v0u * qpv - qpu * v0v) * inv;
      const tol = -1e-4;
      if (w1 < tol || w2 < tol || w1 + w2 > 1.0 - tol) {
        continue;
      }
      final w0 = 1.0 - w1 - w2;
      final elev = w0 * a.dot(upAxis) + w1 * b.dot(upAxis) + w2 * c.dot(upAxis);
      final diff = (elev - targetUp).abs();
      if (diff < bestVerticalDiff) {
        bestVerticalDiff = diff;
        bestElevation = elev;
      }
    }
    return bestElevation;
  }

  /// Computes the raw A* corridor of polygon centroids between [start] and
  /// [goal] (without funnel string-pulling), returning `[]` if unreachable.
  List<Vector3> findCentroidPath(Vector3 start, Vector3 goal) {
    final sHit = findNearestPoly(start);
    final gHit = findNearestPoly(goal);
    if (sHit == null || gHit == null) {
      return const [];
    }
    final res = _astarSearch(sHit.polyIndex, gHit.polyIndex, gHit.point);
    if (res == null) {
      return const [];
    }
    return [
      sHit.point.clone(),
      for (final pIdx in res.polySequence) polygons[pIdx].centroid.clone(),
      gHit.point.clone(),
    ];
  }

  /// Plans a path from [start] to [goal] segmented into surface walk legs and
  /// [OffMeshLink3D] traversal legs (preserving `linkTag` metadata such as
  /// `'jump'` or `'ladder'`).
  List<NavPathSegment3D> findSegmentedPath(Vector3 start, Vector3 goal) {
    final sHit = findNearestPoly(start);
    final gHit = findNearestPoly(goal);
    if (sHit == null || gHit == null) {
      return const [];
    }
    if (sHit.polyIndex == gHit.polyIndex) {
      final pts = sHit.point.distanceToSquared(gHit.point) <= 1e-12
          ? [sHit.point.clone()]
          : [sHit.point.clone(), gHit.point.clone()];
      return [NavPathSegment3D(waypoints: pts)];
    }

    _ensureLinksResolved();
    List<int>? polySeq;
    List<int>? edgeLinkIndices;
    if (_resolvedLinks.isEmpty) {
      // Straight line of cheapest polygons from start to goal: nothing can be
      // shorter, so the search is skipped.
      final direct = <int>[];
      if (_raycastWalk(
        sHit.polyIndex,
        sHit.point,
        gHit.point,
        gHit.polyIndex,
        _minPolygonCost + 1e-9,
        direct,
      )) {
        polySeq = direct;
        edgeLinkIndices = List<int>.filled(direct.length - 1, -1);
      }
    }
    if (polySeq == null || edgeLinkIndices == null) {
      final search = _astarSearch(sHit.polyIndex, gHit.polyIndex, gHit.point);
      if (search == null) {
        return const [];
      }
      polySeq = search.polySequence;
      edgeLinkIndices = search.edgeLinkIndices;
    }

    final segments = <NavPathSegment3D>[];
    var subStartIdx = 0;
    var subStartPoint = sHit.point;

    for (var e = 0; e < edgeLinkIndices.length; e++) {
      final linkIdx = edgeLinkIndices[e];
      if (linkIdx < 0) {
        continue;
      }
      final resolved = _resolvedLinks[linkIdx];

      // 1. Walk segment from `subStartPoint` (`polySeq[subStartIdx..e]`) to
      // `resolved.entryPoint`.
      final walkPts = _funnelSubCorridor(
        polySeq,
        subStartIdx,
        e,
        subStartPoint,
        resolved.entryPoint,
      );
      if (walkPts.isNotEmpty) {
        segments.add(NavPathSegment3D(waypoints: walkPts));
      }

      // 2. Off-mesh link traversal segment `[entryPoint, exitPoint]`.
      segments.add(
        NavPathSegment3D(
          waypoints: [resolved.entryPoint.clone(), resolved.exitPoint.clone()],
          offMeshLink: resolved.link,
          linkTag: resolved.link.linkTag,
        ),
      );

      subStartIdx = e + 1;
      subStartPoint = resolved.exitPoint;
    }

    // Final walk segment from `subStartPoint` to `gHit.point`.
    final tailWalk = _funnelSubCorridor(
      polySeq,
      subStartIdx,
      polySeq.length - 1,
      subStartPoint,
      gHit.point,
    );
    if (tailWalk.isNotEmpty) {
      segments.add(NavPathSegment3D(waypoints: tailWalk));
    }
    return segments;
  }

  /// Finds a short 3D path between [start] and [goal] by clamping both
  /// endpoints onto the navmesh, running cost-aware A* over portals and
  /// [OffMeshLink3D]s, and string-pulling surface legs via the **3D Simple
  /// Stupid Funnel** algorithm with portal-edge elevation draping.
  ///
  /// When the straight line from start to goal stays on polygons of the
  /// lowest cost (and no off-mesh link is registered), it is returned
  /// directly without a search. Otherwise the funnel runs over the A*
  /// corridor widened along lines of sight and around every bend at a vertex
  /// that is not on the boundary of the walkable area, so paths over open
  /// ground are straight and bend only at real corners: of walls, of blocked
  /// polygons, and of more expensive regions that the search avoided. The
  /// result is the shortest path through the chosen sequence of open regions;
  /// it can still be longer than the true shortest path when A* chose a
  /// different way around an obstacle. Waypoints the path goes straight
  /// through are left out; extra waypoints are inserted where the path
  /// crosses a portal at a different elevation (ramps, steps).
  List<Vector3> findPath(Vector3 start, Vector3 goal) {
    final segments = findSegmentedPath(start, goal);
    if (segments.isEmpty) {
      return const [];
    }
    if (segments.length == 1) {
      return [for (final p in segments.first.waypoints) p.clone()];
    }
    final combined = <Vector3>[];
    for (var s = 0; s < segments.length; s++) {
      final wps = segments[s].waypoints;
      for (var i = 0; i < wps.length; i++) {
        final pt = wps[i];
        if (combined.isEmpty || combined.last.distanceToSquared(pt) > 1e-10) {
          combined.add(pt.clone());
        }
      }
    }
    return combined;
  }

  List<Vector3> _funnelSubCorridor(
    List<int> corridor,
    int fromIdx,
    int toIdx,
    Vector3 startPt,
    Vector3 goalPt,
  ) {
    if (fromIdx == toIdx) {
      if (startPt.distanceToSquared(goalPt) <= 1e-12) {
        return [startPt.clone()];
      }
      return [startPt.clone(), goalPt.clone()];
    }

    final polys = corridor.sublist(fromIdx, toIdx + 1);
    if (!_tightenCorridor(polys, startPt, goalPt)) {
      return const [];
    }

    final cornerPoints = _cornerPoints;
    final cornerPortals = _cornerPortal;
    final smoothWaypoints = <Vector3>[cornerPoints.first.clone()];
    for (var s = 0; s < cornerPoints.length - 1; s++) {
      final wpA = cornerPoints[s];
      final wpB = cornerPoints[s + 1];
      final pStart = math.min(cornerPortals[s], cornerPortals[s + 1]);
      final pEnd = math.max(cornerPortals[s], cornerPortals[s + 1]);
      _drapeSegmentAcrossPortals(
        wpA,
        wpB,
        pStart,
        pEnd,
        _portalLeft,
        _portalRight,
        smoothWaypoints,
      );
      smoothWaypoints.add(wpB.clone());
    }
    return smoothWaypoints;
  }

  /// String-pulls [polys] from [startPt] to [goalPt], widening the corridor
  /// until the path is taut, and leaves the result in the corner scratch
  /// lists. Returns `false` when consecutive polygons do not share a portal.
  ///
  /// The funnel gives the shortest path inside the corridor that A* chose,
  /// but on a fine mesh (a voxel grid, a terrain) many corridors tie and the
  /// chosen one is often a staircase, so the path bends at vertices that are
  /// not obstacles. A shortest path only bends at vertices on the boundary of
  /// the walkable area. So every bend at a vertex whose polygon fan is
  /// complete is removed by moving the corridor to the other side of that
  /// vertex (which strictly shortens the path), until no such bend remains.
  /// Polygons more expensive than the ones they replace, blocked polygons and
  /// polygons already in the corridor are never added.
  bool _tightenCorridor(List<int> polys, Vector3 startPt, Vector3 goalPt) {
    if (!_buildCorridorPortals(polys, startPt, goalPt)) {
      return false;
    }
    _stringPull();
    if (_cornerPoints.length > 2 && _shortcutByVisibility(polys, goalPt)) {
      if (!_buildCorridorPortals(polys, startPt, goalPt)) {
        return false;
      }
      _stringPull();
    }
    var length = _cornerPathLength();
    final maxRounds = 32 + polys.length;
    Set<int>? members;
    for (var round = 0; round < maxRounds; round++) {
      final previous = List<int>.of(polys);
      if (!_widenAtFreeCorners(polys, members ??= polys.toSet())) {
        return true;
      }
      if (!_buildCorridorPortals(polys, startPt, goalPt)) {
        polys
          ..clear()
          ..addAll(previous);
        break;
      }
      _stringPull();
      final next = _cornerPathLength();
      if (next >= length - 1e-9) {
        polys
          ..clear()
          ..addAll(previous);
        break;
      }
      length = next;
    }
    // Restore the corner lists of the corridor that was kept.
    _buildCorridorPortals(polys, startPt, goalPt);
    _stringPull();
    return true;
  }

  /// Replaces stretches of [polys] by the polygons along straight lines of
  /// sight: from the start, the farthest corner of the current path that a
  /// straight walk over the mesh reaches (through polygons no more expensive
  /// than the stretch it replaces) becomes the next anchor, and so on. Uses
  /// the corner lists of the current corridor. Returns whether [polys]
  /// changed.
  bool _shortcutByVisibility(List<int> polys, Vector3 goalPt) {
    final cornerCount = _cornerPoints.length;
    final last = cornerCount - 1;
    final oldIndex = <int, int>{};
    for (var i = 0; i < polys.length; i++) {
      oldIndex[polys[i]] = i;
    }
    final targets = List<Vector3>.filled(cornerCount, goalPt);
    final targetIdx = List<int>.filled(cornerCount, polys.length - 1);
    for (var j = 1; j < last; j++) {
      // A point just inside the polygon the path enters at corner `j`.
      final idx = _cornerPortal[j].clamp(0, polys.length - 1);
      final corner = _cornerPoints[j];
      final centroid = polygons[polys[idx]].centroid;
      targets[j] = Vector3.copy(corner)..addScaled(centroid - corner, 0.01);
      targetIdx[j] = idx;
    }

    final result = <int>[polys[0]];
    final inResult = <int>{polys[0]};
    final walk = <int>[];
    var anchor = _cornerPoints[0];
    var anchorIdx = 0;
    var k = 0;
    var changed = false;
    while (k < last) {
      var advanced = false;
      for (var j = last; j >= k + 2; j--) {
        final xIdx = targetIdx[j];
        if (xIdx <= anchorIdx) {
          continue;
        }
        var maxCost = 0.0;
        for (var i = anchorIdx; i <= xIdx; i++) {
          maxCost = math.max(maxCost, _polygonCosts[polys[i]]);
        }
        walk.clear();
        if (!_raycastWalk(
          polys[anchorIdx],
          anchor,
          targets[j],
          polys[xIdx],
          maxCost + 1e-9,
          walk,
        )) {
          continue;
        }
        var clash = false;
        for (var i = 1; i < walk.length && !clash; i++) {
          final q = walk[i];
          final o = oldIndex[q];
          clash = inResult.contains(q) || (o != null && o > xIdx);
        }
        if (clash) {
          continue;
        }
        for (var i = 1; i < walk.length; i++) {
          result.add(walk[i]);
          inResult.add(walk[i]);
        }
        anchor = targets[j];
        anchorIdx = xIdx;
        k = j;
        advanced = true;
        changed = true;
        break;
      }
      if (advanced) {
        continue;
      }
      // No line of sight beyond the next corner: keep the corridor up to it.
      final next = k + 1;
      final xIdx = math.max(anchorIdx, targetIdx[next]);
      for (var i = anchorIdx + 1; i <= xIdx; i++) {
        if (!inResult.add(polys[i])) {
          return false;
        }
        result.add(polys[i]);
      }
      anchor = targets[next];
      anchorIdx = xIdx;
      k = next;
    }
    if (!changed) {
      return false;
    }
    for (var i = anchorIdx + 1; i < polys.length; i++) {
      if (!inResult.add(polys[i])) {
        return false;
      }
      result.add(polys[i]);
    }
    polys
      ..clear()
      ..addAll(result);
    return true;
  }

  /// Walks the mesh from [fromPoly] along the straight horizontal line from
  /// [from] to [to] through shared edges, appending each polygon to [out].
  /// Succeeds when it reaches [targetPoly] containing [to]; fails at the
  /// boundary of the walkable area, at a blocked polygon, or at a polygon
  /// costing more than [maxCost].
  bool _raycastWalk(
    int fromPoly,
    Vector3 from,
    Vector3 to,
    int targetPoly,
    double maxCost,
    List<int> out,
  ) {
    final su = from.dot(_basisU);
    final sv = from.dot(_basisV);
    final du = to.dot(_basisU) - su;
    final dv = to.dot(_basisV) - sv;
    var cur = fromPoly;
    var prev = -1;
    for (var step = 0; step <= polygons.length; step++) {
      if (_polyObstacleRefCount[cur] > 0 || _polygonCosts[cur] > maxCost) {
        return false;
      }
      out.add(cur);
      if (cur == targetPoly) {
        return true;
      }
      final poly = polygons[cur];
      final a = vertices[poly.v0];
      final b = vertices[poly.v1];
      final c = vertices[poly.v2];
      final orient = _triArea2Horiz(a, b, c) >= 0.0 ? 1.0 : -1.0;
      var tExit = double.infinity;
      var exitA = -1;
      var exitB = -1;
      for (var e = 0; e < 3; e++) {
        final ia = e == 0 ? poly.v0 : (e == 1 ? poly.v1 : poly.v2);
        final ib = e == 0 ? poly.v1 : (e == 1 ? poly.v2 : poly.v0);
        final pa = vertices[ia];
        final pb = vertices[ib];
        final au = pa.dot(_basisU);
        final av = pa.dot(_basisV);
        final eu = pb.dot(_basisU) - au;
        final ev = pb.dot(_basisV) - av;
        // Outward normal of the edge in the horizontal plane.
        final nu = orient * ev;
        final nv = -orient * eu;
        final denom = nu * du + nv * dv;
        if (denom <= 1e-14) {
          continue;
        }
        final t = (nu * (au - su) + nv * (av - sv)) / denom;
        if (t < tExit) {
          tExit = t;
          exitA = ia;
          exitB = ib;
        }
      }
      if (exitA < 0) {
        return false;
      }
      var next = -1;
      var matches = 0;
      for (final portal in poly.portals) {
        final l = portal.leftVertex;
        final r = portal.rightVertex;
        if ((l == exitA && r == exitB) || (l == exitB && r == exitA)) {
          next = portal.targetPoly;
          matches++;
        }
      }
      if (tExit >= 1.0 - 1e-9) {
        // The line ends in this polygon (or on its edge): only an end point
        // on the edge shared with the target counts.
        if (matches == 1 && next == targetPoly && tExit <= 1.0 + 1e-6) {
          if (_polyObstacleRefCount[next] > 0 ||
              _polygonCosts[next] > maxCost) {
            return false;
          }
          out.add(next);
          return true;
        }
        return false;
      }
      if (matches != 1 || next == prev) {
        return false;
      }
      prev = cur;
      cur = next;
    }
    return false;
  }

  /// Moves the corridor to the other side of every bend vertex that has a
  /// free polygon fan, from the goal end back, skipping bends whose polygons
  /// overlap a change made earlier in the same pass. Returns whether
  /// anything changed.
  bool _widenAtFreeCorners(List<int> polys, Set<int> members) {
    final n = polys.length - 1; // portals are indices 1..n
    var limit = polys.length;
    var changed = false;
    for (var k = _cornerPoints.length - 2; k >= 1; k--) {
      final v = _cornerVertex[k];
      if (v < 0) {
        continue;
      }
      final sideVerts = _cornerSide[k] > 0
          ? _portalLeftVertex
          : _portalRightVertex;
      final p = _cornerPortal[k];
      if (p < 1 || p > n || sideVerts[p] != v) {
        continue;
      }
      var a = p;
      while (a - 1 >= 1 && sideVerts[a - 1] == v) {
        a--;
      }
      var b = p;
      while (b + 1 <= n && sideVerts[b + 1] == v) {
        b++;
      }
      final arcStart = a - 1;
      final arcEnd = b;
      if (arcEnd >= limit || arcStart < 0) {
        continue;
      }
      final replacement = _fanComplement(
        v,
        polys[arcStart],
        polys[arcStart + 1],
        polys[arcEnd],
      );
      if (replacement == null) {
        continue;
      }
      var maxCost = 0.0;
      for (var i = arcStart; i <= arcEnd; i++) {
        maxCost = math.max(maxCost, _polygonCosts[polys[i]]);
      }
      var accepted = true;
      for (var i = 0; i < replacement.length && accepted; i++) {
        final q = replacement[i];
        if (members.contains(q) || _polygonCosts[q] > maxCost + 1e-9) {
          accepted = false;
        }
      }
      if (!accepted) {
        continue;
      }
      for (var i = arcStart + 1; i < arcEnd; i++) {
        members.remove(polys[i]);
      }
      members.addAll(replacement);
      polys.replaceRange(arcStart + 1, arcEnd, replacement);
      limit = arcStart;
      changed = true;
    }
    return changed;
  }

  /// Walks around vertex [v] from [startPoly], away from [oldNext] (the
  /// polygon the corridor currently enters next), until [endPoly] is reached,
  /// returning the polygons strictly between them, or `null` when the walk
  /// meets the boundary of the walkable area (a missing, ambiguous or
  /// blocked neighbour), so that [v] is a real corner.
  List<int>? _fanComplement(int v, int startPoly, int oldNext, int endPoly) {
    final out = <int>[];
    var prev = oldNext;
    var cur = startPoly;
    for (var step = 0; step < 64; step++) {
      final poly = polygons[cur];
      final prevPoly = polygons[prev];
      // The vertex of `cur` shared with `prev` (besides `v`) marks the edge
      // the walk came across; it leaves through the edge to the other one.
      var exitVertex = -1;
      var sharedCount = 0;
      for (var c = 0; c < 3; c++) {
        final w = c == 0 ? poly.v0 : (c == 1 ? poly.v1 : poly.v2);
        if (w == v) {
          continue;
        }
        if (w == prevPoly.v0 || w == prevPoly.v1 || w == prevPoly.v2) {
          sharedCount++;
        } else {
          exitVertex = w;
        }
      }
      if (sharedCount != 1 || exitVertex < 0) {
        return null;
      }
      var next = -1;
      var matches = 0;
      for (final portal in poly.portals) {
        final l = portal.leftVertex;
        final r = portal.rightVertex;
        if ((l == v && r == exitVertex) || (l == exitVertex && r == v)) {
          next = portal.targetPoly;
          matches++;
        }
      }
      if (matches != 1 || _polyObstacleRefCount[next] > 0) {
        return null;
      }
      if (next == endPoly) {
        return out;
      }
      if (next == startPoly || next == oldNext) {
        return null;
      }
      out.add(next);
      prev = cur;
      cur = next;
    }
    return null;
  }

  bool _buildCorridorPortals(
    List<int> polys,
    Vector3 startPt,
    Vector3 goalPt,
  ) {
    _portalLeft
      ..clear()
      ..add(startPt);
    _portalRight
      ..clear()
      ..add(startPt);
    _portalLeftVertex
      ..clear()
      ..add(-1);
    _portalRightVertex
      ..clear()
      ..add(-1);
    for (var i = 0; i < polys.length - 1; i++) {
      final curr = polygons[polys[i]];
      final nextIdx = polys[i + 1];
      NavPortal3D? portal;
      for (var p = 0; p < curr.portals.length; p++) {
        if (curr.portals[p].targetPoly == nextIdx) {
          portal = curr.portals[p];
          break;
        }
      }
      if (portal == null) {
        return false;
      }
      _portalLeft.add(portal.left);
      _portalRight.add(portal.right);
      _portalLeftVertex.add(portal.leftVertex);
      _portalRightVertex.add(portal.rightVertex);
    }
    _portalLeft.add(goalPt);
    _portalRight.add(goalPt);
    _portalLeftVertex.add(-1);
    _portalRightVertex.add(-1);
    return true;
  }

  /// Simple Stupid Funnel over the portal scratch lists. Fills the corner
  /// lists with the path's corners, each with its portal index, the mesh
  /// vertex it sits on (`-1` for the end points) and its side (`1` left, `-1`
  /// right, `0` end point), and drops corners the path passes straight
  /// through.
  void _stringPull() {
    final portalsLeft = _portalLeft;
    final portalsRight = _portalRight;
    final startPt = portalsLeft.first;
    final goalPt = portalsLeft.last;
    final cornerPoints = _cornerPoints
      ..clear()
      ..add(startPt);
    final cornerPortals = _cornerPortal
      ..clear()
      ..add(0);
    final cornerVertices = _cornerVertex
      ..clear()
      ..add(-1);
    final cornerSides = _cornerSide
      ..clear()
      ..add(0);

    var apex = startPt;
    var portalLeft = startPt;
    var portalRight = startPt;
    var apexIndex = 0;
    var leftIndex = 0;
    var rightIndex = 0;

    for (var i = 1; i < portalsLeft.length; i++) {
      final left = portalsLeft[i];
      final right = portalsRight[i];

      if (_triArea2Horiz(apex, portalRight, right) >= 0.0) {
        if (_horizDist2(apex, portalRight) <= 1e-12 ||
            _triArea2Horiz(apex, portalLeft, right) < 0.0) {
          portalRight = right;
          rightIndex = i;
        } else {
          if (_horizDist2(cornerPoints.last, portalLeft) > 1e-10) {
            cornerPoints.add(portalLeft);
            cornerPortals.add(leftIndex);
            cornerVertices.add(_portalLeftVertex[leftIndex]);
            cornerSides.add(1);
          }
          apex = portalLeft;
          apexIndex = leftIndex;
          portalLeft = apex;
          portalRight = apex;
          leftIndex = apexIndex;
          rightIndex = apexIndex;
          i = apexIndex;
          continue;
        }
      }

      if (_triArea2Horiz(apex, portalLeft, left) <= 0.0) {
        if (_horizDist2(apex, portalLeft) <= 1e-12 ||
            _triArea2Horiz(apex, portalRight, left) > 0.0) {
          portalLeft = left;
          leftIndex = i;
        } else {
          if (_horizDist2(cornerPoints.last, portalRight) > 1e-10) {
            cornerPoints.add(portalRight);
            cornerPortals.add(rightIndex);
            cornerVertices.add(_portalRightVertex[rightIndex]);
            cornerSides.add(-1);
          }
          apex = portalRight;
          apexIndex = rightIndex;
          portalLeft = apex;
          portalRight = apex;
          leftIndex = apexIndex;
          rightIndex = apexIndex;
          i = apexIndex;
          continue;
        }
      }
    }

    final goalIndex = portalsLeft.length - 1;
    if (cornerPoints.length > 1 &&
        cornerPoints.last.distanceToSquared(goalPt) <= 1e-10) {
      cornerPoints.removeLast();
      cornerPortals.removeLast();
      cornerVertices.removeLast();
      cornerSides.removeLast();
    }
    if (cornerPoints.length == 1 &&
        startPt.distanceToSquared(goalPt) <= 1e-10) {
      cornerPortals[0] = goalIndex;
      return;
    }
    cornerPoints.add(goalPt);
    cornerPortals.add(goalIndex);
    cornerVertices.add(-1);
    cornerSides.add(0);

    // Drop corners the path goes straight through (the funnel reports a
    // corner wherever a portal end point is exactly on the current line).
    var kept = 1;
    for (var k = 1; k < cornerPoints.length - 1; k++) {
      final a = cornerPoints[kept - 1];
      final b = cornerPoints[k];
      final c = cornerPoints[k + 1];
      final ab = math.sqrt(_horizDist2(a, b));
      final bc = math.sqrt(_horizDist2(b, c));
      final cross = _triArea2Horiz(a, b, c).abs();
      if (ab <= 1e-9 || bc <= 1e-9 || cross <= 1e-6 * ab * bc) {
        continue;
      }
      cornerPoints[kept] = b;
      cornerPortals[kept] = cornerPortals[k];
      cornerVertices[kept] = cornerVertices[k];
      cornerSides[kept] = cornerSides[k];
      kept++;
    }
    final last = cornerPoints.length - 1;
    cornerPoints[kept] = cornerPoints[last];
    cornerPortals[kept] = cornerPortals[last];
    cornerVertices[kept] = cornerVertices[last];
    cornerSides[kept] = cornerSides[last];
    cornerPoints.length = kept + 1;
    cornerPortals.length = kept + 1;
    cornerVertices.length = kept + 1;
    cornerSides.length = kept + 1;
  }

  double _cornerPathLength() {
    var sum = 0.0;
    for (var i = 0; i < _cornerPoints.length - 1; i++) {
      sum += math.sqrt(_horizDist2(_cornerPoints[i], _cornerPoints[i + 1]));
    }
    return sum;
  }

  void _drapeSegmentAcrossPortals(
    Vector3 wpA,
    Vector3 wpB,
    int pStart,
    int pEnd,
    List<Vector3> portalsLeft,
    List<Vector3> portalsRight,
    List<Vector3> out,
  ) {
    if (pEnd - pStart <= 1) {
      return;
    }
    final au = wpA.dot(_basisU);
    final av = wpA.dot(_basisV);
    final bu = wpB.dot(_basisU);
    final bv = wpB.dot(_basisV);
    final du = bu - au;
    final dv = bv - av;
    final segLen2 = du * du + dv * dv;
    if (segLen2 <= 1e-10) {
      return;
    }

    var bestDev = 1e-3;
    Vector3? splitPoint;
    var splitPortal = -1;

    final aUp = wpA.dot(upAxis);
    final bUp = wpB.dot(upAxis);

    for (var p = pStart + 1; p < pEnd; p++) {
      final l = portalsLeft[p];
      final r = portalsRight[p];
      final lu = l.dot(_basisU);
      final lv = l.dot(_basisV);
      final eu = r.dot(_basisU) - lu;
      final ev = r.dot(_basisV) - lv;

      final denom = du * ev - dv * eu;
      if (denom.abs() <= 1e-10) {
        continue;
      }
      final inv = 1.0 / denom;
      final qx = lu - au;
      final qy = lv - av;
      final t = (qx * ev - qy * eu) * inv;
      final s = ((qx * dv - qy * du) * inv).clamp(0.0, 1.0);
      if (t <= 1e-3 || t >= 1.0 - 1e-3) {
        continue;
      }

      final crossPt = Vector3(
        l.x + (r.x - l.x) * s,
        l.y + (r.y - l.y) * s,
        l.z + (r.z - l.z) * s,
      );
      final chordUp = aUp + (bUp - aUp) * t;
      final dev = (crossPt.dot(upAxis) - chordUp).abs();
      if (dev > bestDev) {
        bestDev = dev;
        splitPoint = crossPt;
        splitPortal = p;
      }
    }

    if (splitPoint != null && splitPortal > pStart && splitPortal < pEnd) {
      _drapeSegmentAcrossPortals(
        wpA,
        splitPoint,
        pStart,
        splitPortal,
        portalsLeft,
        portalsRight,
        out,
      );
      out.add(splitPoint);
      _drapeSegmentAcrossPortals(
        splitPoint,
        wpB,
        splitPortal,
        pEnd,
        portalsLeft,
        portalsRight,
        out,
      );
    }
  }

  _AStarCorridorResult? _astarSearch(
    int startPoly,
    int goalPoly,
    Vector3 goalPoint,
  ) {
    if (_polyObstacleRefCount[startPoly] > 0 ||
        _polyObstacleRefCount[goalPoly] > 0) {
      return null;
    }
    _ensureLinksResolved();

    final n = polygons.length;
    final gScore = _gScore ??= Float64List(n);
    final cameFrom = _cameFrom ??= Int32List(n);
    final cameViaLink = _cameViaLink ??= Int32List(n);
    final openStamp = _openStamp ??= Int32List(n);
    final closedStamp = _closedStamp ??= Int32List(n);
    final heap = _heap ??= _MinPolyHeap(n);
    if (_searchStamp >= 0x3FFFFFFF) {
      openStamp.fillRange(0, n, 0);
      closedStamp.fillRange(0, n, 0);
      _searchStamp = 0;
    }
    final stamp = ++_searchStamp;
    heap.clear();

    // Admissible heuristic scaled by `_minPolygonCost` (zeroed when off-mesh
    // links exist so teleport/jump shortcuts are never pruned sub-optimally!).
    final hScale = _resolvedLinks.isEmpty ? _minPolygonCost : 0.0;

    gScore[startPoly] = 0.0;
    cameFrom[startPoly] = -1;
    cameViaLink[startPoly] = -1;
    openStamp[startPoly] = stamp;
    heap.push(
      startPoly,
      polygons[startPoly].centroid.distanceTo(goalPoint) * hScale,
    );

    while (!heap.isEmpty) {
      final current = heap.pop();
      if (current == goalPoly) {
        heap.clear();
        final revPolys = <int>[];
        final revLinks = <int>[];
        var curr = goalPoly;
        while (curr != -1) {
          revPolys.add(curr);
          final prev = cameFrom[curr];
          if (prev != -1) {
            revLinks.add(cameViaLink[curr]);
          }
          curr = prev;
        }
        return _AStarCorridorResult(
          polySequence: revPolys.reversed.toList(growable: false),
          edgeLinkIndices: revLinks.reversed.toList(growable: false),
        );
      }
      if (closedStamp[current] == stamp) {
        continue;
      }
      closedStamp[current] = stamp;

      final portals = polygons[current].portals;
      final curG = gScore[current];
      final curCost = _polygonCosts[current];

      // 1. Shared-edge surface portals.
      for (var i = 0; i < portals.length; i++) {
        final portal = portals[i];
        final next = portal.targetPoly;
        if (closedStamp[next] == stamp || _polyObstacleRefCount[next] > 0) {
          continue;
        }
        final areaWeight = 0.5 * (curCost + _polygonCosts[next]);
        final tentativeG = curG + portal.cost * areaWeight;
        if (openStamp[next] != stamp || tentativeG < gScore[next]) {
          openStamp[next] = stamp;
          gScore[next] = tentativeG;
          cameFrom[next] = current;
          cameViaLink[next] = -1;
          final f =
              tentativeG +
              polygons[next].centroid.distanceTo(goalPoint) * hScale;
          heap.pushOrDecrease(next, f);
        }
      }

      // 2. Outgoing OffMeshLink3D connections originating on `current`.
      final outgoing = _linksFromPoly[current];
      if (outgoing != null) {
        for (var k = 0; k < outgoing.length; k++) {
          final l = outgoing[k];
          final rl = _resolvedLinks[l];
          final next = rl.toPoly;
          if (closedStamp[next] == stamp || _polyObstacleRefCount[next] > 0) {
            continue;
          }
          final approach =
              polygons[current].centroid.distanceTo(rl.entryPoint) * curCost +
              polygons[next].centroid.distanceTo(rl.exitPoint) *
                  _polygonCosts[next];
          final tentativeG = curG + rl.cost + approach * 0.5;
          if (openStamp[next] != stamp || tentativeG < gScore[next]) {
            openStamp[next] = stamp;
            gScore[next] = tentativeG;
            cameFrom[next] = current;
            cameViaLink[next] = l;
            final f =
                tentativeG +
                polygons[next].centroid.distanceTo(goalPoint) * hScale;
            heap.pushOrDecrease(next, f);
          }
        }
      }
    }
    heap.clear();
    return null;
  }

  double _horizDist2(Vector3 a, Vector3 b) {
    final dx = b.x - a.x;
    final dy = b.y - a.y;
    final dz = b.z - a.z;
    final du = dx * _basisU.x + dy * _basisU.y + dz * _basisU.z;
    final dv = dx * _basisV.x + dy * _basisV.y + dz * _basisV.z;
    return du * du + dv * dv;
  }

  double _triArea2Horiz(Vector3 a, Vector3 b, Vector3 c) {
    return _triArea2Up(a, b, c, upAxis);
  }

  static double _triArea2Up(Vector3 a, Vector3 b, Vector3 c, Vector3 up) {
    final abx = b.x - a.x;
    final aby = b.y - a.y;
    final abz = b.z - a.z;
    final acx = c.x - a.x;
    final acy = c.y - a.y;
    final acz = c.z - a.z;
    final cx = aby * acz - abz * acy;
    final cy = abz * acx - abx * acz;
    final cz = abx * acy - aby * acx;
    return cx * up.x + cy * up.y + cz * up.z;
  }

  /// Exact 3D Triangle-vs-AABB intersection via 6-plane Sutherland-Hodgman
  /// clipping.
  static bool _triangleIntersectsAabb(
    Vector3 v0,
    Vector3 v1,
    Vector3 v2,
    Aabb3 box,
  ) {
    final min = box.min;
    final max = box.max;
    if (math.max(v0.x, math.max(v1.x, v2.x)) < min.x - 1e-6 ||
        math.min(v0.x, math.min(v1.x, v2.x)) > max.x + 1e-6 ||
        math.max(v0.y, math.max(v1.y, v2.y)) < min.y - 1e-6 ||
        math.min(v0.y, math.min(v1.y, v2.y)) > max.y + 1e-6 ||
        math.max(v0.z, math.max(v1.z, v2.z)) < min.z - 1e-6 ||
        math.min(v0.z, math.min(v1.z, v2.z)) > max.z + 1e-6) {
      return false;
    }

    var poly = <Vector3>[v0, v1, v2];
    poly = _clipAxis(poly, 0, min.x, isMin: true);
    if (poly.isEmpty) {
      return false;
    }
    poly = _clipAxis(poly, 0, max.x, isMin: false);
    if (poly.isEmpty) {
      return false;
    }
    poly = _clipAxis(poly, 1, min.y, isMin: true);
    if (poly.isEmpty) {
      return false;
    }
    poly = _clipAxis(poly, 1, max.y, isMin: false);
    if (poly.isEmpty) {
      return false;
    }
    poly = _clipAxis(poly, 2, min.z, isMin: true);
    if (poly.isEmpty) {
      return false;
    }
    poly = _clipAxis(poly, 2, max.z, isMin: false);
    return poly.isNotEmpty;
  }

  static List<Vector3> _clipAxis(
    List<Vector3> poly,
    int axis,
    double bound, {
    required bool isMin,
  }) {
    final out = <Vector3>[];
    final n = poly.length;
    if (n == 0) {
      return out;
    }
    double coord(Vector3 v) => axis == 0 ? v.x : (axis == 1 ? v.y : v.z);
    bool inside(double val) =>
        isMin ? val >= bound - 1e-6 : val <= bound + 1e-6;

    var prev = poly[n - 1];
    var prevVal = coord(prev);
    var prevIn = inside(prevVal);

    for (var i = 0; i < n; i++) {
      final curr = poly[i];
      final currVal = coord(curr);
      final currIn = inside(currVal);
      if (prevIn != currIn) {
        final denom = currVal - prevVal;
        final t = denom.abs() > 1e-12
            ? ((bound - prevVal) / denom).clamp(0.0, 1.0)
            : 0.5;
        out.add(
          Vector3(
            prev.x + (curr.x - prev.x) * t,
            prev.y + (curr.y - prev.y) * t,
            prev.z + (curr.z - prev.z) * t,
          ),
        );
      }
      if (currIn) {
        out.add(curr);
      }
      prev = curr;
      prevVal = currVal;
      prevIn = currIn;
    }
    return out;
  }
}

class _ResolvedOffMeshLink({
  required final OffMeshLink3D link,
  required final int fromPoly,
  required final int toPoly,
  required final Vector3 entryPoint,
  required final Vector3 exitPoint,
  required final double cost,
});

class _AStarCorridorResult({
  required final List<int> polySequence,
  required final List<int> edgeLinkIndices,
});

class _MinPolyHeap(int maxPolys) {
  final Int32List _nodes = Int32List(maxPolys + 1);
  final Float64List _priorities = Float64List(maxPolys + 1);
  final Int32List _heapPos = Int32List(maxPolys)..fillRange(0, maxPolys, -1);
  int _size = 0;

  bool get isEmpty => _size == 0;

  /// Empties the heap, resetting the positions of the polygons still in it.
  void clear() {
    for (var i = 0; i < _size; i++) {
      _heapPos[_nodes[i]] = -1;
    }
    _size = 0;
  }

  void push(int poly, double f) {
    final idx = _size++;
    _nodes[idx] = poly;
    _priorities[idx] = f;
    _heapPos[poly] = idx;
    _siftUp(idx);
  }

  void pushOrDecrease(int poly, double f) {
    final existing = _heapPos[poly];
    if (existing >= 0) {
      if (f < _priorities[existing]) {
        _priorities[existing] = f;
        _siftUp(existing);
      }
      return;
    }
    push(poly, f);
  }

  int pop() {
    final top = _nodes[0];
    _heapPos[top] = -1;
    _size--;
    if (_size > 0) {
      _nodes[0] = _nodes[_size];
      _priorities[0] = _priorities[_size];
      _heapPos[_nodes[0]] = 0;
      _siftDown(0);
    }
    return top;
  }

  void _siftUp(int index) {
    var i = index;
    while (i > 0) {
      final parent = (i - 1) >> 1;
      if (_priorities[i] >= _priorities[parent]) {
        break;
      }
      _swap(i, parent);
      i = parent;
    }
  }

  void _siftDown(int index) {
    var i = index;
    while (true) {
      final left = (i << 1) + 1;
      if (left >= _size) {
        break;
      }
      var smallest = left;
      final right = left + 1;
      if (right < _size && _priorities[right] < _priorities[left]) {
        smallest = right;
      }
      if (_priorities[i] <= _priorities[smallest]) {
        break;
      }
      _swap(i, smallest);
      i = smallest;
    }
  }

  void _swap(int a, int b) {
    final na = _nodes[a];
    final nb = _nodes[b];
    final pa = _priorities[a];
    _nodes[a] = nb;
    _nodes[b] = na;
    _priorities[a] = _priorities[b];
    _priorities[b] = pa;
    _heapPos[nb] = a;
    _heapPos[na] = b;
  }
}

class _NavPolyBvh._({
  required final int nodeCount,
  required final Float32List bounds,
  required final Int32List leftOrFirst,
  required final Int32List rightChild,
  required final Int32List counts,
  required final Int32List polyIndices,
}) {
  factory _NavPolyBvh.build(List<Vector3> verts, List<NavPoly3D> polys) {
    final n = polys.length;
    if (n == 0) {
      return _NavPolyBvh._(
        nodeCount: 0,
        bounds: Float32List(0),
        leftOrFirst: Int32List(0),
        rightChild: Int32List(0),
        counts: Int32List(0),
        polyIndices: Int32List(0),
      );
    }

    final indices = Int32List(n);
    final triBounds = Float32List(n * 6);
    for (var i = 0; i < n; i++) {
      indices[i] = i;
      final p = polys[i];
      final v0 = verts[p.v0];
      final v1 = verts[p.v1];
      final v2 = verts[p.v2];
      final tb = i * 6;
      triBounds
        ..[tb] = math.min(v0.x, math.min(v1.x, v2.x))
        ..[tb + 1] = math.min(v0.y, math.min(v1.y, v2.y))
        ..[tb + 2] = math.min(v0.z, math.min(v1.z, v2.z))
        ..[tb + 3] = math.max(v0.x, math.max(v1.x, v2.x))
        ..[tb + 4] = math.max(v0.y, math.max(v1.y, v2.y))
        ..[tb + 5] = math.max(v0.z, math.max(v1.z, v2.z));
    }

    final maxNodes = math.max(1, n * 2);
    final bounds = Float32List(maxNodes * 6);
    final leftOrFirst = Int32List(maxNodes);
    final rightChild = Int32List(maxNodes);
    final counts = Int32List(maxNodes);
    var nodeCount = 0;

    int build(int start, int count) {
      final node = nodeCount++;
      var minX = double.infinity;
      var minY = double.infinity;
      var minZ = double.infinity;
      var maxX = double.negativeInfinity;
      var maxY = double.negativeInfinity;
      var maxZ = double.negativeInfinity;
      var cMinX = double.infinity;
      var cMinY = double.infinity;
      var cMinZ = double.infinity;
      var cMaxX = double.negativeInfinity;
      var cMaxY = double.negativeInfinity;
      var cMaxZ = double.negativeInfinity;

      for (var i = start; i < start + count; i++) {
        final pIdx = indices[i];
        final tb = pIdx * 6;
        minX = math.min(minX, triBounds[tb]);
        minY = math.min(minY, triBounds[tb + 1]);
        minZ = math.min(minZ, triBounds[tb + 2]);
        maxX = math.max(maxX, triBounds[tb + 3]);
        maxY = math.max(maxY, triBounds[tb + 4]);
        maxZ = math.max(maxZ, triBounds[tb + 5]);

        final c = polys[pIdx].centroid;
        cMinX = math.min(cMinX, c.x);
        cMinY = math.min(cMinY, c.y);
        cMinZ = math.min(cMinZ, c.z);
        cMaxX = math.max(cMaxX, c.x);
        cMaxY = math.max(cMaxY, c.y);
        cMaxZ = math.max(cMaxZ, c.z);
      }

      final nb = node * 6;
      bounds
        ..[nb] = minX
        ..[nb + 1] = minY
        ..[nb + 2] = minZ
        ..[nb + 3] = maxX
        ..[nb + 4] = maxY
        ..[nb + 5] = maxZ;

      if (count <= 4) {
        leftOrFirst[node] = start;
        counts[node] = count;
        return node;
      }

      var axis = 0;
      var split = 0.5 * (cMinX + cMaxX);
      var ext = cMaxX - cMinX;
      if (cMaxY - cMinY > ext) {
        axis = 1;
        split = 0.5 * (cMinY + cMaxY);
        ext = cMaxY - cMinY;
      }
      if (cMaxZ - cMinZ > ext) {
        axis = 2;
        split = 0.5 * (cMinZ + cMaxZ);
        ext = cMaxZ - cMinZ;
      }

      int mid;
      if (ext <= 1e-12) {
        mid = start + (count >> 1);
      } else {
        var i = start;
        var j = start + count - 1;
        while (i <= j) {
          final c = polys[indices[i]].centroid;
          final val = axis == 0 ? c.x : (axis == 1 ? c.y : c.z);
          if (val < split) {
            i++;
          } else {
            final tmp = indices[i];
            indices[i] = indices[j];
            indices[j] = tmp;
            j--;
          }
        }
        mid = i;
        if (mid == start || mid == start + count) {
          mid = start + (count >> 1);
        }
      }

      counts[node] = 0;
      leftOrFirst[node] = build(start, mid - start);
      rightChild[node] = build(mid, start + count - mid);
      return node;
    }

    build(0, n);
    return _NavPolyBvh._(
      nodeCount: nodeCount,
      bounds: Float32List.sublistView(bounds, 0, nodeCount * 6),
      leftOrFirst: Int32List.sublistView(leftOrFirst, 0, nodeCount),
      rightChild: Int32List.sublistView(rightChild, 0, nodeCount),
      counts: Int32List.sublistView(counts, 0, nodeCount),
      polyIndices: indices,
    );
  }

  Int32List _stack = Int32List(128);
  final Vector3 _cand = Vector3.zero();

  void queryAabb(Aabb3 box, List<int> outPolyIndices) {
    if (nodeCount == 0) {
      return;
    }
    final qMinX = box.min.x;
    final qMinY = box.min.y;
    final qMinZ = box.min.z;
    final qMaxX = box.max.x;
    final qMaxY = box.max.y;
    final qMaxZ = box.max.z;

    var sp = 0;
    _push(sp++, 0);
    while (sp > 0) {
      final node = _stack[--sp];
      final nb = node * 6;
      if (bounds[nb + 3] < qMinX ||
          bounds[nb] > qMaxX ||
          bounds[nb + 4] < qMinY ||
          bounds[nb + 1] > qMaxY ||
          bounds[nb + 5] < qMinZ ||
          bounds[nb + 2] > qMaxZ) {
        continue;
      }
      final cnt = counts[node];
      if (cnt > 0) {
        final start = leftOrFirst[node];
        for (var i = start; i < start + cnt; i++) {
          outPolyIndices.add(polyIndices[i]);
        }
      } else {
        _push(sp++, rightChild[node]);
        _push(sp++, leftOrFirst[node]);
      }
    }
  }

  /// Collects the polygons whose bounds the infinite line through [origin]
  /// along [direction] crosses.
  void queryLine(Vector3 origin, Vector3 direction, List<int> outPolyIndices) {
    if (nodeCount == 0) {
      return;
    }
    const pad = 1e-4;
    final ox = origin.x;
    final oy = origin.y;
    final oz = origin.z;
    final dx = direction.x;
    final dy = direction.y;
    final dz = direction.z;
    final invX = dx.abs() > 1e-12 ? 1.0 / dx : 0.0;
    final invY = dy.abs() > 1e-12 ? 1.0 / dy : 0.0;
    final invZ = dz.abs() > 1e-12 ? 1.0 / dz : 0.0;

    var sp = 0;
    _push(sp++, 0);
    while (sp > 0) {
      final node = _stack[--sp];
      final nb = node * 6;
      var tMin = double.negativeInfinity;
      var tMax = double.infinity;
      var hit = true;
      for (var axis = 0; axis < 3 && hit; axis++) {
        final o = axis == 0 ? ox : (axis == 1 ? oy : oz);
        final inv = axis == 0 ? invX : (axis == 1 ? invY : invZ);
        final lo = bounds[nb + axis] - pad;
        final hi = bounds[nb + 3 + axis] + pad;
        if (inv == 0.0) {
          if (o < lo || o > hi) {
            hit = false;
          }
          continue;
        }
        var t1 = (lo - o) * inv;
        var t2 = (hi - o) * inv;
        if (t1 > t2) {
          final tmp = t1;
          t1 = t2;
          t2 = tmp;
        }
        if (t1 > tMin) {
          tMin = t1;
        }
        if (t2 < tMax) {
          tMax = t2;
        }
        if (tMin > tMax) {
          hit = false;
        }
      }
      if (!hit) {
        continue;
      }
      final cnt = counts[node];
      if (cnt > 0) {
        final start = leftOrFirst[node];
        for (var i = start; i < start + cnt; i++) {
          outPolyIndices.add(polyIndices[i]);
        }
      } else {
        _push(sp++, rightChild[node]);
        _push(sp++, leftOrFirst[node]);
      }
    }
  }

  NavPolyHit3D? findNearest(
    Vector3 query,
    List<Vector3> verts,
    List<NavPoly3D> polys,
    Int32List? blockedRefCounts,
  ) {
    if (nodeCount == 0) {
      return null;
    }
    final qx = query.x;
    final qy = query.y;
    final qz = query.z;

    var bestPoly = -1;
    var bestD2 = double.infinity;
    final bestPt = Vector3.zero();

    var sp = 0;
    _push(sp++, 0);

    while (sp > 0) {
      final node = _stack[--sp];
      if (_boxDist2(node, qx, qy, qz) >= bestD2) {
        continue;
      }
      final cnt = counts[node];
      if (cnt > 0) {
        final start = leftOrFirst[node];
        for (var i = start; i < start + cnt; i++) {
          final pIdx = polyIndices[i];
          if (blockedRefCounts != null && blockedRefCounts[pIdx] > 0) {
            continue;
          }
          final poly = polys[pIdx];
          _closestPointOnTri(
            qx,
            qy,
            qz,
            verts[poly.v0],
            verts[poly.v1],
            verts[poly.v2],
            _cand,
          );
          final dx = _cand.x - qx;
          final dy = _cand.y - qy;
          final dz = _cand.z - qz;
          final d2 = dx * dx + dy * dy + dz * dz;
          if (d2 < bestD2) {
            bestD2 = d2;
            bestPoly = pIdx;
            bestPt.setFrom(_cand);
          }
        }
      } else {
        final left = leftOrFirst[node];
        final right = rightChild[node];
        final dL = _boxDist2(left, qx, qy, qz);
        final dR = _boxDist2(right, qx, qy, qz);
        if (dL < dR) {
          if (dR < bestD2) {
            _push(sp++, right);
          }
          if (dL < bestD2) {
            _push(sp++, left);
          }
        } else {
          if (dL < bestD2) {
            _push(sp++, left);
          }
          if (dR < bestD2) {
            _push(sp++, right);
          }
        }
      }
    }

    if (bestPoly < 0) {
      return null;
    }
    return NavPolyHit3D(
      polyIndex: bestPoly,
      point: bestPt,
      distanceSquared: bestD2,
    );
  }

  void _push(int sp, int node) {
    if (sp >= _stack.length) {
      _stack = Int32List(_stack.length * 2)..setAll(0, _stack);
    }
    _stack[sp] = node;
  }

  double _boxDist2(int node, double qx, double qy, double qz) {
    final nb = node * 6;
    final minX = bounds[nb];
    final minY = bounds[nb + 1];
    final minZ = bounds[nb + 2];
    final maxX = bounds[nb + 3];
    final maxY = bounds[nb + 4];
    final maxZ = bounds[nb + 5];
    final dx = qx < minX ? minX - qx : (qx > maxX ? qx - maxX : 0.0);
    final dy = qy < minY ? minY - qy : (qy > maxY ? qy - maxY : 0.0);
    final dz = qz < minZ ? minZ - qz : (qz > maxZ ? qz - maxZ : 0.0);
    return dx * dx + dy * dy + dz * dz;
  }

  static void _closestPointOnTri(
    double px,
    double py,
    double pz,
    Vector3 a,
    Vector3 b,
    Vector3 c,
    Vector3 out,
  ) {
    final abx = b.x - a.x;
    final aby = b.y - a.y;
    final abz = b.z - a.z;
    final acx = c.x - a.x;
    final acy = c.y - a.y;
    final acz = c.z - a.z;
    final apx = px - a.x;
    final apy = py - a.y;
    final apz = pz - a.z;

    final d1 = abx * apx + aby * apy + abz * apz;
    final d2 = acx * apx + acy * apy + acz * apz;
    if (d1 <= 0.0 && d2 <= 0.0) {
      out.setFrom(a);
      return;
    }

    final bpx = px - b.x;
    final bpy = py - b.y;
    final bpz = pz - b.z;
    final d3 = abx * bpx + aby * bpy + abz * bpz;
    final d4 = acx * bpx + acy * bpy + acz * bpz;
    if (d3 >= 0.0 && d4 <= d3) {
      out.setFrom(b);
      return;
    }

    final vc = d1 * d4 - d3 * d2;
    if (vc <= 0.0 && d1 >= 0.0 && d3 <= 0.0) {
      final v = d1 / (d1 - d3);
      out.setValues(a.x + v * abx, a.y + v * aby, a.z + v * abz);
      return;
    }

    final cpx = px - c.x;
    final cpy = py - c.y;
    final cpz = pz - c.z;
    final d5 = abx * cpx + aby * cpy + abz * cpz;
    final d6 = acx * cpx + acy * cpy + acz * cpz;
    if (d6 >= 0.0 && d5 <= d6) {
      out.setFrom(c);
      return;
    }

    final vb = d5 * d2 - d1 * d6;
    if (vb <= 0.0 && d2 >= 0.0 && d6 <= 0.0) {
      final w = d2 / (d2 - d6);
      out.setValues(a.x + w * acx, a.y + w * acy, a.z + w * acz);
      return;
    }

    final va = d3 * d6 - d5 * d4;
    if (va <= 0.0 && (d4 - d3) >= 0.0 && (d5 - d6) >= 0.0) {
      final w = (d4 - d3) / ((d4 - d3) + (d5 - d6));
      out.setValues(
        b.x + w * (c.x - b.x),
        b.y + w * (c.y - b.y),
        b.z + w * (c.z - b.z),
      );
      return;
    }

    final denom = 1.0 / (va + vb + vc);
    final v = vb * denom;
    final w = vc * denom;
    out.setValues(
      a.x + abx * v + acx * w,
      a.y + aby * v + acy * w,
      a.z + abz * v + acz * w,
    );
  }
}
