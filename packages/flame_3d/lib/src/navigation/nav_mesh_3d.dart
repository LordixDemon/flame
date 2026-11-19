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
class NavPortal3D({
  required final int targetPoly,
  required final Vector3 left,
  required final Vector3 right,
  required final double cost,
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
class OffMeshLink3D({
  required Vector3 start,
  required Vector3 end,
  final bool bidirectional = true,
  final double costMultiplier = 1.0,
  final String linkTag = 'jump',
  var bool enabled = true,
}) {
  this : assert(costMultiplier > 0, 'costMultiplier must be positive');

  /// World-space start endpoint of the link.
  final Vector3 start = start.clone();

  /// World-space end endpoint of the link.
  final Vector3 end = end.clone();
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
/// blocking, [OffMeshLink3D] connections, A* search, and 3D Simple Stupid
/// Funnel string-pulling with elevation draping.
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

    polygonCosts = Float32List(polygons.length)
      ..fillRange(0, polygons.length, 1.0);
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
  late final Float32List polygonCosts;

  late final Int32List _polyObstacleRefCount;
  int _blockedPolyCount = 0;
  double _minPolygonCost = 1.0;

  final Map<NavMeshObstacle3D, Int32List> _obstaclePolys = {};
  final List<OffMeshLink3D> _offMeshLinks = [];
  final List<_ResolvedOffMeshLink> _resolvedLinks = [];
  bool _linksDirty = false;

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
    polygonCosts[polyIndex] = cost;
    if (cost < _minPolygonCost) {
      _minPolygonCost = cost;
    }
  }

  /// Returns the traversal cost multiplier of [polyIndex].
  double getPolygonCost(int polyIndex) => polygonCosts[polyIndex];

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
        polygonCosts[pIdx] = cost;
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
      return;
    }
    _linksDirty = false;
    _resolvedLinks.clear();
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
      final baseDist = math.max(1e-3, sHit.point.distanceTo(eHit.point));
      final cost = baseDist * link.costMultiplier;
      _resolvedLinks.add(
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
        _resolvedLinks.add(
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
  double? sampleHeightAt(Vector3 pos) {
    if (polygons.isEmpty) {
      return null;
    }
    final targetUp = pos.dot(upAxis);
    final pu = pos.dot(_basisU);
    final pv = pos.dot(_basisV);

    double? bestElevation;
    var bestVerticalDiff = double.infinity;

    for (var i = 0; i < polygons.length; i++) {
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

    final search = _astarSearch(sHit.polyIndex, gHit.polyIndex, gHit.point);
    if (search == null) {
      return const [];
    }

    final polySeq = search.polySequence;
    final edgeLinkIndices = search.edgeLinkIndices;

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

  /// Finds the smooth shortest 3D path between [start] and [goal] by clamping
  /// both endpoints onto the navmesh, running cost-aware A* over portals and
  /// [OffMeshLink3D]s, and string-pulling surface legs via the **3D Simple
  /// Stupid Funnel** algorithm with portal-edge elevation draping.
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

    final portalsLeft = <Vector3>[startPt];
    final portalsRight = <Vector3>[startPt];

    for (var i = fromIdx; i < toIdx; i++) {
      final curr = polygons[corridor[i]];
      final nextIdx = corridor[i + 1];
      NavPortal3D? portal;
      for (var p = 0; p < curr.portals.length; p++) {
        if (curr.portals[p].targetPoly == nextIdx) {
          portal = curr.portals[p];
          break;
        }
      }
      if (portal == null) {
        return const [];
      }
      portalsLeft.add(portal.left);
      portalsRight.add(portal.right);
    }
    portalsLeft.add(goalPt);
    portalsRight.add(goalPt);

    final cornerPoints = <Vector3>[startPt.clone()];
    final cornerPortalIndices = <int>[0];

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
            cornerPoints.add(portalLeft.clone());
            cornerPortalIndices.add(leftIndex);
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
            cornerPoints.add(portalRight.clone());
            cornerPortalIndices.add(rightIndex);
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

    if (cornerPoints.last.distanceToSquared(goalPt) > 1e-10) {
      cornerPoints.add(goalPt.clone());
      cornerPortalIndices.add(portalsLeft.length - 1);
    } else {
      cornerPoints[cornerPoints.length - 1] = goalPt.clone();
      cornerPortalIndices[cornerPortalIndices.length - 1] =
          portalsLeft.length - 1;
    }

    final smoothWaypoints = <Vector3>[cornerPoints.first];
    for (var s = 0; s < cornerPoints.length - 1; s++) {
      final wpA = cornerPoints[s];
      final wpB = cornerPoints[s + 1];
      final pStart = math.min(
        cornerPortalIndices[s],
        cornerPortalIndices[s + 1],
      );
      final pEnd = math.max(
        cornerPortalIndices[s],
        cornerPortalIndices[s + 1],
      );
      _drapeSegmentAcrossPortals(
        wpA,
        wpB,
        pStart,
        pEnd,
        portalsLeft,
        portalsRight,
        smoothWaypoints,
      );
      smoothWaypoints.add(wpB);
    }

    return smoothWaypoints;
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
    final gScore = Float64List(n)..fillRange(0, n, double.infinity);
    final cameFrom = Int32List(n)..fillRange(0, n, -1);
    final cameViaLink = Int32List(n)..fillRange(0, n, -1);
    final closed = Uint8List(n);
    final heap = _MinPolyHeap(n);

    // Admissible heuristic scaled by `_minPolygonCost` (zeroed when off-mesh
    // links exist so teleport/jump shortcuts are never pruned sub-optimally!).
    final hScale = _resolvedLinks.isEmpty ? _minPolygonCost : 0.0;

    gScore[startPoly] = 0.0;
    heap.push(
      startPoly,
      polygons[startPoly].centroid.distanceTo(goalPoint) * hScale,
    );

    while (!heap.isEmpty) {
      final current = heap.pop();
      if (current == goalPoly) {
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
      if (closed[current] != 0) {
        continue;
      }
      closed[current] = 1;

      final portals = polygons[current].portals;
      final curG = gScore[current];
      final curCost = polygonCosts[current];

      // 1. Shared-edge surface portals.
      for (var i = 0; i < portals.length; i++) {
        final portal = portals[i];
        final next = portal.targetPoly;
        if (closed[next] != 0 || _polyObstacleRefCount[next] > 0) {
          continue;
        }
        final areaWeight = 0.5 * (curCost + polygonCosts[next]);
        final tentativeG = curG + portal.cost * areaWeight;
        if (tentativeG < gScore[next]) {
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
      if (_resolvedLinks.isNotEmpty) {
        for (var l = 0; l < _resolvedLinks.length; l++) {
          final rl = _resolvedLinks[l];
          if (rl.fromPoly != current || !rl.link.enabled) {
            continue;
          }
          final next = rl.toPoly;
          if (closed[next] != 0 || _polyObstacleRefCount[next] > 0) {
            continue;
          }
          final approach =
              polygons[current].centroid.distanceTo(rl.entryPoint) * curCost +
              polygons[next].centroid.distanceTo(rl.exitPoint) *
                  polygonCosts[next];
          final tentativeG = curG + rl.cost + approach * 0.5;
          if (tentativeG < gScore[next]) {
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
