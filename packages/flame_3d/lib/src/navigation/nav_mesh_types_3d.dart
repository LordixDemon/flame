part of 'nav_mesh_3d.dart';

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
