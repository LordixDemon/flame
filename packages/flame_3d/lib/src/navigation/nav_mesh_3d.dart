import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame_3d/core.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/src/extensions/geometry_math.dart';
import 'package:flame_3d/src/spatial/static_bvh_3d.dart';

part 'nav_mesh_bvh_3d.dart';
part 'nav_mesh_factories_3d.dart';
part 'nav_mesh_funnel_3d.dart';
part 'nav_mesh_obstacles_3d.dart';
part 'nav_mesh_pathfinder_3d.dart';
part 'nav_mesh_query_context_3d.dart';
part 'nav_mesh_types_3d.dart';

/// 3D triangle navigation mesh built from any [Mesh] or by the voxel
/// `NavMeshBuilder3D` (the first stages of Recast only), featuring spatial
/// vertex welding, portal adjacency, weighted polygon area costs, `O(log P)`
/// dynamic [NavMeshObstacle3D] blocking (of whole polygons), [OffMeshLink3D]
/// connections, A* search, and 3D Simple Stupid Funnel string-pulling with
/// elevation draping.
///
/// Queries are not re-entrant: the search state is kept on the mesh and
/// reused by every query (it is allocated once, `O(P)`).
class NavMesh3D._({
  required final List<Vector3> vertices,
  required final List<NavPoly3D> polygons,
  required Vector3 upAxis,
}) {
  this {
    buildUpTangentBasis3D(this.upAxis, _basisU, _basisV);

    _polygonCosts = Float32List(polygons.length)
      ..fillRange(0, polygons.length, 1.0);
    polygonCosts = _polygonCosts.asUnmodifiableView();
    _polyObstacleRefCount = Int32List(polygons.length);
  }

  /// Extracts walkable triangles from [mesh] and builds portal adjacency.
  factory NavMesh3D.fromMesh(
    Mesh mesh, {
    Matrix4? transform,
    Vector3? upAxis,
    double maxSlopeAngleRad = 0.8,
    double weldEpsilon = 1e-3,
  }) => _buildNavMeshFromMesh(
    mesh,
    transform: transform,
    upAxis: upAxis,
    maxSlopeAngleRad: maxSlopeAngleRad,
    weldEpsilon: weldEpsilon,
  );

  /// Builds a [NavMesh3D] directly from [vertices] and `(i0, i1, i2, normal)`
  /// [triangles], connecting shared edges into [NavPortal3D]s.
  factory NavMesh3D.fromIndexedTriangles({
    required List<Vector3> vertices,
    required List<(int, int, int, Vector3)> triangles,
    Vector3? upAxis,
  }) => _buildNavMeshFromIndexedTriangles(
    vertices: vertices,
    triangles: triangles,
    upAxis: upAxis,
  );

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

  final NavQueryContext3D _defaultQuery = NavQueryContext3D();

  final Vector3 _basisU = Vector3.zero();
  final Vector3 _basisV = Vector3.zero();
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

  /// Sets traversal [cost] on every polygon overlapping [bounds].
  int setRegionCostInAabb(Aabb3 bounds, double cost) =>
      _setRegionCostInAabbImpl(bounds, cost);

  /// Adds a dynamic obstacle updating overlapping polygon blocks.
  void addObstacle(NavMeshObstacle3D obstacle) => _addObstacleImpl(obstacle);

  /// Recomputes polygon blocks for a moved [obstacle].
  void updateObstacle(NavMeshObstacle3D obstacle) =>
      _updateObstacleImpl(obstacle);

  /// Removes a dynamic [obstacle] from this navmesh.
  void removeObstacle(NavMeshObstacle3D obstacle) =>
      _removeObstacleImpl(obstacle);

  /// Registers an [OffMeshLink3D].
  void addOffMeshLink(OffMeshLink3D link) => _addOffMeshLinkImpl(link);

  /// Unregisters an [OffMeshLink3D].
  void removeOffMeshLink(OffMeshLink3D link) => _removeOffMeshLinkImpl(link);

  Int32List _computeBlockedPolygons(NavMeshObstacle3D obstacle) {
    if (polygons.isEmpty) {
      return Int32List(0);
    }
    final worldBox = obstacle.computeWorldAabb();
    final candidates = _defaultQuery.bvhCandidates..clear();
    _bvh.queryAabb(worldBox, candidates);
    if (candidates.isEmpty) {
      return Int32List(0);
    }

    final rotT = obstacle.rotation.conjugated();
    final localBox = Aabb3.minMax(-obstacle.halfExtents, obstacle.halfExtents);
    final v0L = Vector3.zero();
    final v1L = Vector3.zero();
    final v2L = Vector3.zero();
    final matched = <int>[];

    for (var i = 0; i < candidates.length; i++) {
      final pIdx = candidates[i];
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

  /// Finds the nearest walkable polygon hit to [point].
  NavPolyHit3D? findNearestPoly(
    Vector3 point, {
    bool ignoreObstacles = false,
    NavQueryContext3D? context,
  }) => _findNearestPolyImpl(
    point,
    ignoreObstacles: ignoreObstacles,
  );

  /// Samples the walkable surface elevation (coordinate along [upAxis]) at the
  /// horizontal projection of [pos], picking the layer closest in elevation to
  /// [pos] on multi-level bridges/overpasses, or `null` if [pos] lies outside
  /// all unblocked walkable polygons horizontally.
  ///
  /// Only the polygons whose bounds the vertical line through [pos] crosses
  /// are tested (through the navmesh BVH), so a query costs `O(log P)` plus
  /// the number of layers at that point.
  double? sampleHeightAt(Vector3 pos, {NavQueryContext3D? context}) {
    if (polygons.isEmpty) {
      return null;
    }
    final targetUp = pos.dot(upAxis);
    final pu = pos.dot(_basisU);
    final pv = pos.dot(_basisV);

    double? bestElevation;
    var bestVerticalDiff = double.infinity;

    final candidates = (context ?? _defaultQuery).bvhCandidates..clear();
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

  /// Returns a centroid waypoint path from [start] to [goal].
  List<Vector3> findCentroidPath(
    Vector3 start,
    Vector3 goal, {
    NavQueryContext3D? context,
  }) => _findCentroidPathImpl(start, goal, context ?? _defaultQuery);

  /// Computes a segmented path including off-mesh traversal segments.
  List<NavPathSegment3D> findSegmentedPath(
    Vector3 start,
    Vector3 goal, {
    NavQueryContext3D? context,
  }) => _findSegmentedPathImpl(start, goal, context ?? _defaultQuery);

  /// Computes a funnel-smoothed path from [start] to [goal].
  List<Vector3> findPath(
    Vector3 start,
    Vector3 goal, {
    NavQueryContext3D? context,
  }) => _findPathImpl(start, goal, context ?? _defaultQuery);
}
