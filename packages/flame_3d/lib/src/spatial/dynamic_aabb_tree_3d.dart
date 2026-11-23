import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame_3d/core.dart';

/// Ray hit result returned by [DynamicAabbTree3D.raycast] and
/// [DynamicAabbTree3D.raycastAll].
class DynamicTreeRayHit3D<T>({
  required final T item,
  required final int proxyId,
  required final double distance,
  final Vector3? normal,
});

/// Incremental Surface-Area-Heuristic (SAH) dynamic Bounding Volume Hierarchy
/// (BVH) with fat-AABB hysteresis and AVL-style height-balancing rotations.
///
/// Small motions whose updated world AABB remains inside a proxy's fat AABB
/// return `false` from [update] with `0` tree restructures or allocations.
class DynamicAabbTree3D<T>({
  final double fatMargin = 0.12,
  final double displacementMultiplier = 2.0,
  int initialCapacity = 32,
}) {
  this
    : assert(fatMargin >= 0, 'fatMargin must be non-negative'),
      assert(initialCapacity >= 2, 'initialCapacity must be >= 2') {
    _initStorage(math.max(16, initialCapacity));
  }

  static const int _nullNode = -1;

  int _capacity = 0;
  int _root = _nullNode;
  int _freeList = _nullNode;
  int _leafCount = 0;
  int _activeNodeCount = 0;
  int _reinsertCount = 0;

  late Float64List _bounds;
  late Int32List _parentOrNext;
  late Int32List _left;
  late Int32List _right;
  late Int32List _height;
  late List<T?> _items;

  Int32List _stack = Int32List(64);
  Float64List _stackDist = Float64List(64);
  final Aabb3 _scratchAabb = Aabb3();
  final Ray _unitRay = Ray();

  /// Number of leaf proxies currently stored in the tree.
  int get leafCount => _leafCount;

  /// Total number of active leaf + internal nodes in the tree.
  int get nodeCount => _activeNodeCount;

  /// Current root height (`0` when empty or single-leaf).
  int get height => _root == _nullNode ? 0 : _height[_root];

  /// Cumulative number of leaf re-insertions triggered by [update] calls that
  /// escaped their fat AABB.
  int get reinsertCount => _reinsertCount;

  /// Whether this tree contains zero leaves.
  bool get isEmpty => _root == _nullNode;

  /// Resets [reinsertCount] to zero.
  void resetTelemetry() {
    _reinsertCount = 0;
  }

  /// Removes all proxies and resets the tree while retaining allocated arrays.
  void clear() {
    _root = _nullNode;
    _leafCount = 0;
    _activeNodeCount = 0;
    _reinsertCount = 0;
    for (var i = 0; i < _capacity; i++) {
      _parentOrNext[i] = i + 1 < _capacity ? i + 1 : _nullNode;
      _left[i] = _nullNode;
      _right[i] = _nullNode;
      _height[i] = -1;
      _items[i] = null;
    }
    _freeList = 0;
  }

  /// Returns the payload stored at leaf [proxyId].
  T getItem(int proxyId) {
    assert(
      proxyId >= 0 && proxyId < _capacity && _isLeaf(proxyId),
      'Invalid leaf proxyId: $proxyId',
    );
    return _items[proxyId] as T;
  }

  /// Writes the fat AABB of [proxyId] into [out] and returns [out].
  Aabb3 getFatAabb(int proxyId, {Aabb3? out}) {
    assert(
      proxyId >= 0 && proxyId < _capacity && _height[proxyId] >= 0,
      'Invalid active proxyId: $proxyId',
    );
    final res = out ?? Aabb3();
    final o = proxyId * 6;
    res.min.setValues(_bounds[o], _bounds[o + 1], _bounds[o + 2]);
    res.max.setValues(_bounds[o + 3], _bounds[o + 4], _bounds[o + 5]);
    return res;
  }

  /// Inserts [item] with tight world [bounds], expanding by [fatMargin], and
  /// returns its stable integer `proxyId`.
  int insert(T item, Aabb3 bounds) {
    final proxyId = _allocateNode();
    final o = proxyId * 6;
    _bounds[o] = bounds.min.x - fatMargin;
    _bounds[o + 1] = bounds.min.y - fatMargin;
    _bounds[o + 2] = bounds.min.z - fatMargin;
    _bounds[o + 3] = bounds.max.x + fatMargin;
    _bounds[o + 4] = bounds.max.y + fatMargin;
    _bounds[o + 5] = bounds.max.z + fatMargin;
    _items[proxyId] = item;
    _height[proxyId] = 0;
    _insertLeaf(proxyId);
    _leafCount++;
    return proxyId;
  }

  /// Removes leaf [proxyId] from the tree and recycles its slot.
  void remove(int proxyId) {
    assert(
      proxyId >= 0 && proxyId < _capacity && _isLeaf(proxyId),
      'Invalid leaf proxyId: $proxyId',
    );
    _removeLeaf(proxyId);
    _freeNode(proxyId);
    _leafCount--;
  }

  /// Updates leaf [proxyId] with its new tight world [bounds] (and optional
  /// motion [displacement]).
  ///
  /// Returns `false` immediately without modifying the tree when [bounds] still
  /// fits inside the proxy's fat AABB (`0` tree churn for small jitter).
  bool update(int proxyId, Aabb3 bounds, {Vector3? displacement}) {
    assert(
      proxyId >= 0 && proxyId < _capacity && _isLeaf(proxyId),
      'Invalid leaf proxyId: $proxyId',
    );
    final o = proxyId * 6;
    final minX = bounds.min.x;
    final minY = bounds.min.y;
    final minZ = bounds.min.z;
    final maxX = bounds.max.x;
    final maxY = bounds.max.y;
    final maxZ = bounds.max.z;

    if (_bounds[o] <= minX &&
        maxX <= _bounds[o + 3] &&
        _bounds[o + 1] <= minY &&
        maxY <= _bounds[o + 4] &&
        _bounds[o + 2] <= minZ &&
        maxZ <= _bounds[o + 5]) {
      return false;
    }

    _removeLeaf(proxyId);

    var fMinX = minX - fatMargin;
    var fMinY = minY - fatMargin;
    var fMinZ = minZ - fatMargin;
    var fMaxX = maxX + fatMargin;
    var fMaxY = maxY + fatMargin;
    var fMaxZ = maxZ + fatMargin;

    if (displacement != null) {
      final dx = displacement.x * displacementMultiplier;
      final dy = displacement.y * displacementMultiplier;
      final dz = displacement.z * displacementMultiplier;
      if (dx < 0.0) {
        fMinX += dx;
      } else {
        fMaxX += dx;
      }
      if (dy < 0.0) {
        fMinY += dy;
      } else {
        fMaxY += dy;
      }
      if (dz < 0.0) {
        fMinZ += dz;
      } else {
        fMaxZ += dz;
      }
    }

    _bounds[o] = fMinX;
    _bounds[o + 1] = fMinY;
    _bounds[o + 2] = fMinZ;
    _bounds[o + 3] = fMaxX;
    _bounds[o + 4] = fMaxY;
    _bounds[o + 5] = fMaxZ;

    _insertLeaf(proxyId);
    _reinsertCount++;
    return true;
  }

  /// Appends all items whose fat AABB overlaps [bounds] into [out].
  List<T> queryAabb(
    Aabb3 bounds, {
    List<T>? out,
    bool Function(T item)? filter,
  }) {
    final result = out ?? <T>[];
    if (_root == _nullNode) {
      return result;
    }
    final qMinX = bounds.min.x;
    final qMinY = bounds.min.y;
    final qMinZ = bounds.min.z;
    final qMaxX = bounds.max.x;
    final qMaxY = bounds.max.y;
    final qMaxZ = bounds.max.z;

    var sp = 0;
    _pushStack(sp++, _root, 0.0);
    while (sp > 0) {
      final node = _stack[--sp];
      if (node == _nullNode) {
        continue;
      }
      final o = node * 6;
      if (_bounds[o + 3] < qMinX ||
          _bounds[o] > qMaxX ||
          _bounds[o + 4] < qMinY ||
          _bounds[o + 1] > qMaxY ||
          _bounds[o + 5] < qMinZ ||
          _bounds[o + 2] > qMaxZ) {
        continue;
      }
      if (_isLeaf(node)) {
        final item = _items[node] as T;
        if (filter == null || filter(item)) {
          result.add(item);
        }
      } else {
        _pushStack(sp++, _right[node], 0.0);
        _pushStack(sp++, _left[node], 0.0);
      }
    }
    return result;
  }

  /// Visits every leaf overlapping [bounds] without allocating a result list.
  void queryAabbCallback(
    Aabb3 bounds,
    void Function(int proxyId, T item) onOverlap,
  ) {
    if (_root == _nullNode) {
      return;
    }
    final qMinX = bounds.min.x;
    final qMinY = bounds.min.y;
    final qMinZ = bounds.min.z;
    final qMaxX = bounds.max.x;
    final qMaxY = bounds.max.y;
    final qMaxZ = bounds.max.z;

    var sp = 0;
    _pushStack(sp++, _root, 0.0);
    while (sp > 0) {
      final node = _stack[--sp];
      if (node == _nullNode) {
        continue;
      }
      final o = node * 6;
      if (_bounds[o + 3] < qMinX ||
          _bounds[o] > qMaxX ||
          _bounds[o + 4] < qMinY ||
          _bounds[o + 1] > qMaxY ||
          _bounds[o + 5] < qMinZ ||
          _bounds[o + 2] > qMaxZ) {
        continue;
      }
      if (_isLeaf(node)) {
        onOverlap(node, _items[node] as T);
      } else {
        _pushStack(sp++, _right[node], 0.0);
        _pushStack(sp++, _left[node], 0.0);
      }
    }
  }

  /// Appends all items whose fat AABB overlaps the sphere `(center, radius)`
  /// into [out].
  List<T> querySphere(
    Vector3 center,
    double radius, {
    List<T>? out,
    bool Function(T item)? filter,
  }) {
    final result = out ?? <T>[];
    if (_root == _nullNode || radius < 0.0) {
      return result;
    }
    final cx = center.x;
    final cy = center.y;
    final cz = center.z;
    final r2 = radius * radius;

    var sp = 0;
    _pushStack(sp++, _root, 0.0);
    while (sp > 0) {
      final node = _stack[--sp];
      if (node == _nullNode) {
        continue;
      }
      if (_pointBoxDistSq(node * 6, cx, cy, cz) > r2) {
        continue;
      }
      if (_isLeaf(node)) {
        final item = _items[node] as T;
        if (filter == null || filter(item)) {
          result.add(item);
        }
      } else {
        _pushStack(sp++, _right[node], 0.0);
        _pushStack(sp++, _left[node], 0.0);
      }
    }
    return result;
  }

  /// Appends all items whose fat AABB intersects [frustum] into [out].
  List<T> queryFrustum(
    Frustum frustum, {
    List<T>? out,
    bool Function(T item)? filter,
  }) {
    final result = out ?? <T>[];
    if (_root == _nullNode) {
      return result;
    }

    var sp = 0;
    _pushStack(sp++, _root, 0.0);
    while (sp > 0) {
      final node = _stack[--sp];
      if (node == _nullNode) {
        continue;
      }
      final o = node * 6;
      _scratchAabb.min.setValues(_bounds[o], _bounds[o + 1], _bounds[o + 2]);
      _scratchAabb.max.setValues(
        _bounds[o + 3],
        _bounds[o + 4],
        _bounds[o + 5],
      );
      if (!frustum.intersectsWithAabb3(_scratchAabb)) {
        continue;
      }
      if (_isLeaf(node)) {
        final item = _items[node] as T;
        if (filter == null || filter(item)) {
          result.add(item);
        }
      } else {
        _pushStack(sp++, _right[node], 0.0);
        _pushStack(sp++, _left[node], 0.0);
      }
    }
    return result;
  }

  /// Front-to-back raycast against the BVH up to [maxDistance].
  ///
  /// When [narrowphase] is provided, candidate leaves invoke
  /// `narrowphase(item, unitRay, currentMaxDist)` to confirm exact shape hits
  /// and shrink the pruning distance; when omitted, returns the closest fat
  /// AABB hit.
  DynamicTreeRayHit3D<T>? raycast(
    Ray ray, {
    double maxDistance = double.infinity,
    (double distance, Vector3? normal)? Function(
      T item,
      Ray unitRay,
      double maxDistance,
    )?
    narrowphase,
    bool Function(T item)? filter,
  }) {
    if (_root == _nullNode || !(maxDistance >= 0.0)) {
      return null;
    }
    final dirLen = ray.direction.length;
    if (dirLen <= 1e-12) {
      return null;
    }
    _unitRay.origin.setFrom(ray.origin);
    _unitRay.direction
      ..setFrom(ray.direction)
      ..scale(1.0 / dirLen);

    final ox = _unitRay.origin.x;
    final oy = _unitRay.origin.y;
    final oz = _unitRay.origin.z;
    final dx = _unitRay.direction.x;
    final dy = _unitRay.direction.y;
    final dz = _unitRay.direction.z;

    var limit = maxDistance;
    final rootT = _rayAabbDistance(_root * 6, ox, oy, oz, dx, dy, dz, limit);
    if (!rootT.isFinite || rootT > limit) {
      return null;
    }

    DynamicTreeRayHit3D<T>? best;
    var sp = 0;
    _pushStack(sp++, _root, rootT);

    while (sp > 0) {
      sp--;
      final node = _stack[sp];
      final nodeDist = _stackDist[sp];
      if (!nodeDist.isFinite || nodeDist > limit) {
        continue;
      }

      if (_isLeaf(node)) {
        final item = _items[node] as T;
        if (filter != null && !filter(item)) {
          continue;
        }
        if (narrowphase != null) {
          final hit = narrowphase(item, _unitRay, limit);
          if (hit != null && hit.$1 <= limit) {
            limit = hit.$1;
            best = DynamicTreeRayHit3D<T>(
              item: item,
              proxyId: node,
              distance: hit.$1,
              normal: hit.$2,
            );
          }
        } else if (nodeDist <= limit) {
          limit = nodeDist;
          best = DynamicTreeRayHit3D<T>(
            item: item,
            proxyId: node,
            distance: nodeDist,
          );
        }
      } else {
        final left = _left[node];
        final right = _right[node];
        final tL = _rayAabbDistance(left * 6, ox, oy, oz, dx, dy, dz, limit);
        final tR = _rayAabbDistance(right * 6, ox, oy, oz, dx, dy, dz, limit);
        final hitL = tL.isFinite && tL <= limit;
        final hitR = tR.isFinite && tR <= limit;
        if (hitL && hitR) {
          if (tL <= tR) {
            _pushStack(sp++, right, tR);
            _pushStack(sp++, left, tL);
          } else {
            _pushStack(sp++, left, tL);
            _pushStack(sp++, right, tR);
          }
        } else if (hitL) {
          _pushStack(sp++, left, tL);
        } else if (hitR) {
          _pushStack(sp++, right, tR);
        }
      }
    }
    return best;
  }

  /// Collects all hits along [ray] within [maxDistance], sorted by ascending
  /// hit distance.
  List<DynamicTreeRayHit3D<T>> raycastAll(
    Ray ray, {
    double maxDistance = double.infinity,
    (double distance, Vector3? normal)? Function(
      T item,
      Ray unitRay,
      double maxDistance,
    )?
    narrowphase,
    bool Function(T item)? filter,
  }) {
    final hits = <DynamicTreeRayHit3D<T>>[];
    if (_root == _nullNode || !(maxDistance >= 0.0)) {
      return hits;
    }
    final dirLen = ray.direction.length;
    if (dirLen <= 1e-12) {
      return hits;
    }
    _unitRay.origin.setFrom(ray.origin);
    _unitRay.direction
      ..setFrom(ray.direction)
      ..scale(1.0 / dirLen);

    final ox = _unitRay.origin.x;
    final oy = _unitRay.origin.y;
    final oz = _unitRay.origin.z;
    final dx = _unitRay.direction.x;
    final dy = _unitRay.direction.y;
    final dz = _unitRay.direction.z;

    final rootT = _rayAabbDistance(
      _root * 6,
      ox,
      oy,
      oz,
      dx,
      dy,
      dz,
      maxDistance,
    );
    if (!rootT.isFinite || rootT > maxDistance) {
      return hits;
    }

    var sp = 0;
    _pushStack(sp++, _root, rootT);
    while (sp > 0) {
      sp--;
      final node = _stack[sp];
      final nodeDist = _stackDist[sp];
      if (!nodeDist.isFinite || nodeDist > maxDistance) {
        continue;
      }

      if (_isLeaf(node)) {
        final item = _items[node] as T;
        if (filter != null && !filter(item)) {
          continue;
        }
        if (narrowphase != null) {
          final hit = narrowphase(item, _unitRay, maxDistance);
          if (hit != null && hit.$1 <= maxDistance) {
            hits.add(
              DynamicTreeRayHit3D<T>(
                item: item,
                proxyId: node,
                distance: hit.$1,
                normal: hit.$2,
              ),
            );
          }
        } else {
          hits.add(
            DynamicTreeRayHit3D<T>(
              item: item,
              proxyId: node,
              distance: nodeDist,
            ),
          );
        }
      } else {
        final left = _left[node];
        final right = _right[node];
        final tL = _rayAabbDistance(
          left * 6,
          ox,
          oy,
          oz,
          dx,
          dy,
          dz,
          maxDistance,
        );
        final tR = _rayAabbDistance(
          right * 6,
          ox,
          oy,
          oz,
          dx,
          dy,
          dz,
          maxDistance,
        );
        if (tL.isFinite && tL <= maxDistance) {
          _pushStack(sp++, left, tL);
        }
        if (tR.isFinite && tR <= maxDistance) {
          _pushStack(sp++, right, tR);
        }
      }
    }
    hits.sort((a, b) => a.distance.compareTo(b.distance));
    return hits;
  }

  /// Verifies all parent/child invariants, node heights, and AABB containment.
  bool validateStructure() {
    if (_root == _nullNode) {
      return _leafCount == 0 && _activeNodeCount == 0;
    }
    if (_parentOrNext[_root] != _nullNode) {
      return false;
    }
    var countedLeaves = 0;
    var countedNodes = 0;

    bool check(int node) {
      if (node < 0 || node >= _capacity || _height[node] < 0) {
        return false;
      }
      countedNodes++;
      final l = _left[node];
      final r = _right[node];
      if (_isLeaf(node)) {
        countedLeaves++;
        return l == _nullNode && r == _nullNode && _height[node] == 0;
      }
      if (l == _nullNode || r == _nullNode) {
        return false;
      }
      if (_parentOrNext[l] != node || _parentOrNext[r] != node) {
        return false;
      }
      if (!check(l) || !check(r)) {
        return false;
      }
      final expectedH = 1 + math.max(_height[l], _height[r]);
      if (_height[node] != expectedH) {
        return false;
      }
      if ((_height[r] - _height[l]).abs() > 1) {
        return false;
      }
      final o = node * 6;
      final ol = l * 6;
      final or = r * 6;
      return _bounds[o] <= math.min(_bounds[ol], _bounds[or]) + 1e-9 &&
          _bounds[o + 1] <= math.min(_bounds[ol + 1], _bounds[or + 1]) + 1e-9 &&
          _bounds[o + 2] <= math.min(_bounds[ol + 2], _bounds[or + 2]) + 1e-9 &&
          _bounds[o + 3] >= math.max(_bounds[ol + 3], _bounds[or + 3]) - 1e-9 &&
          _bounds[o + 4] >= math.max(_bounds[ol + 4], _bounds[or + 4]) - 1e-9 &&
          _bounds[o + 5] >= math.max(_bounds[ol + 5], _bounds[or + 5]) - 1e-9;
    }

    if (!check(_root)) {
      return false;
    }
    return countedLeaves == _leafCount && countedNodes == _activeNodeCount;
  }

  void _initStorage(int cap) {
    _capacity = cap;
    _bounds = Float64List(cap * 6);
    _parentOrNext = Int32List(cap);
    _left = Int32List(cap)..fillRange(0, cap, _nullNode);
    _right = Int32List(cap)..fillRange(0, cap, _nullNode);
    _height = Int32List(cap)..fillRange(0, cap, -1);
    _items = List<T?>.filled(cap, null);
    for (var i = 0; i < cap; i++) {
      _parentOrNext[i] = i + 1 < cap ? i + 1 : _nullNode;
    }
    _freeList = 0;
  }

  void _growStorage() {
    final oldCap = _capacity;
    final newCap = oldCap * 2;
    _bounds = Float64List(newCap * 6)..setAll(0, _bounds);
    _parentOrNext = Int32List(newCap)..setAll(0, _parentOrNext);
    _left = Int32List(newCap)
      ..fillRange(oldCap, newCap, _nullNode)
      ..setAll(0, _left);
    _right = Int32List(newCap)
      ..fillRange(oldCap, newCap, _nullNode)
      ..setAll(0, _right);
    _height = Int32List(newCap)
      ..fillRange(oldCap, newCap, -1)
      ..setAll(0, _height);
    final nextItems = List<T?>.filled(newCap, null);
    for (var i = 0; i < oldCap; i++) {
      nextItems[i] = _items[i];
    }
    _items = nextItems;
    for (var i = oldCap; i < newCap; i++) {
      _parentOrNext[i] = i + 1 < newCap ? i + 1 : _nullNode;
    }
    _freeList = oldCap;
    _capacity = newCap;
  }

  int _allocateNode() {
    if (_freeList == _nullNode) {
      _growStorage();
    }
    final node = _freeList;
    _freeList = _parentOrNext[node];
    _parentOrNext[node] = _nullNode;
    _left[node] = _nullNode;
    _right[node] = _nullNode;
    _height[node] = 0;
    _items[node] = null;
    _activeNodeCount++;
    return node;
  }

  void _freeNode(int node) {
    _parentOrNext[node] = _freeList;
    _left[node] = _nullNode;
    _right[node] = _nullNode;
    _height[node] = -1;
    _items[node] = null;
    _freeList = node;
    _activeNodeCount--;
  }

  bool _isLeaf(int node) => _left[node] == _nullNode;

  void _insertLeaf(int leaf) {
    if (_root == _nullNode) {
      _root = leaf;
      _parentOrNext[leaf] = _nullNode;
      return;
    }

    // Descend tree via SAH minimizing total surface area increase.
    final lo = leaf * 6;
    final lMinX = _bounds[lo];
    final lMinY = _bounds[lo + 1];
    final lMinZ = _bounds[lo + 2];
    final lMaxX = _bounds[lo + 3];
    final lMaxY = _bounds[lo + 4];
    final lMaxZ = _bounds[lo + 5];

    var index = _root;
    while (!_isLeaf(index)) {
      final child1 = _left[index];
      final child2 = _right[index];

      final area = _surfaceArea(index * 6);
      final combinedArea = _unionAreaWithLeaf(
        index * 6,
        lMinX,
        lMinY,
        lMinZ,
        lMaxX,
        lMaxY,
        lMaxZ,
      );
      final cost = 2.0 * combinedArea;
      final inheritanceCost = 2.0 * (combinedArea - area);

      final c1Combined = _unionAreaWithLeaf(
        child1 * 6,
        lMinX,
        lMinY,
        lMinZ,
        lMaxX,
        lMaxY,
        lMaxZ,
      );
      final cost1 = _isLeaf(child1)
          ? c1Combined + inheritanceCost
          : (c1Combined - _surfaceArea(child1 * 6)) + inheritanceCost;

      final c2Combined = _unionAreaWithLeaf(
        child2 * 6,
        lMinX,
        lMinY,
        lMinZ,
        lMaxX,
        lMaxY,
        lMaxZ,
      );
      final cost2 = _isLeaf(child2)
          ? c2Combined + inheritanceCost
          : (c2Combined - _surfaceArea(child2 * 6)) + inheritanceCost;

      if (cost < cost1 && cost < cost2) {
        break;
      }
      index = cost1 < cost2 ? child1 : child2;
    }

    final sibling = index;
    final oldParent = _parentOrNext[sibling];
    final newParent = _allocateNode();
    _parentOrNext[newParent] = oldParent;
    _combineBounds(newParent * 6, leaf * 6, sibling * 6);
    _height[newParent] = _height[sibling] + 1;

    if (oldParent != _nullNode) {
      if (_left[oldParent] == sibling) {
        _left[oldParent] = newParent;
      } else {
        _right[oldParent] = newParent;
      }
    } else {
      _root = newParent;
    }

    _left[newParent] = sibling;
    _right[newParent] = leaf;
    _parentOrNext[sibling] = newParent;
    _parentOrNext[leaf] = newParent;

    // Walk back up refitting AABBs and applying AVL height rotations.
    var curr = _parentOrNext[leaf];
    while (curr != _nullNode) {
      curr = _balance(curr);
      final c1 = _left[curr];
      final c2 = _right[curr];
      _height[curr] = 1 + math.max(_height[c1], _height[c2]);
      _combineBounds(curr * 6, c1 * 6, c2 * 6);
      curr = _parentOrNext[curr];
    }
  }

  void _removeLeaf(int leaf) {
    if (leaf == _root) {
      _root = _nullNode;
      return;
    }

    final parent = _parentOrNext[leaf];
    final grandParent = _parentOrNext[parent];
    final sibling = _left[parent] == leaf ? _right[parent] : _left[parent];

    if (grandParent != _nullNode) {
      if (_left[grandParent] == parent) {
        _left[grandParent] = sibling;
      } else {
        _right[grandParent] = sibling;
      }
      _parentOrNext[sibling] = grandParent;
      _freeNode(parent);

      var curr = grandParent;
      while (curr != _nullNode) {
        curr = _balance(curr);
        final c1 = _left[curr];
        final c2 = _right[curr];
        _height[curr] = 1 + math.max(_height[c1], _height[c2]);
        _combineBounds(curr * 6, c1 * 6, c2 * 6);
        curr = _parentOrNext[curr];
      }
    } else {
      _root = sibling;
      _parentOrNext[sibling] = _nullNode;
      _freeNode(parent);
    }
  }

  int _balance(int iA) {
    if (_isLeaf(iA) || _height[iA] < 2) {
      return iA;
    }

    final iB = _left[iA];
    final iC = _right[iA];
    final balance = _height[iC] - _height[iB];

    // Rotate C up.
    if (balance > 1) {
      final iF = _left[iC];
      final iG = _right[iC];

      _left[iC] = iA;
      final parentA = _parentOrNext[iA];
      _parentOrNext[iC] = parentA;
      _parentOrNext[iA] = iC;

      if (parentA != _nullNode) {
        if (_left[parentA] == iA) {
          _left[parentA] = iC;
        } else {
          _right[parentA] = iC;
        }
      } else {
        _root = iC;
      }

      if (_height[iF] > _height[iG]) {
        _right[iC] = iF;
        _right[iA] = iG;
        _parentOrNext[iG] = iA;
        _combineBounds(iA * 6, iB * 6, iG * 6);
        _height[iA] = 1 + math.max(_height[iB], _height[iG]);
      } else {
        _right[iC] = iG;
        _right[iA] = iF;
        _parentOrNext[iF] = iA;
        _combineBounds(iA * 6, iB * 6, iF * 6);
        _height[iA] = 1 + math.max(_height[iB], _height[iF]);
      }
      _balance(iA);
      final c1 = _left[iC];
      final c2 = _right[iC];
      _combineBounds(iC * 6, c1 * 6, c2 * 6);
      _height[iC] = 1 + math.max(_height[c1], _height[c2]);
      return iC;
    }

    // Rotate B up.
    if (balance < -1) {
      final iD = _left[iB];
      final iE = _right[iB];

      _left[iB] = iA;
      final parentA = _parentOrNext[iA];
      _parentOrNext[iB] = parentA;
      _parentOrNext[iA] = iB;

      if (parentA != _nullNode) {
        if (_left[parentA] == iA) {
          _left[parentA] = iB;
        } else {
          _right[parentA] = iB;
        }
      } else {
        _root = iB;
      }

      if (_height[iD] > _height[iE]) {
        _right[iB] = iD;
        _left[iA] = iE;
        _parentOrNext[iE] = iA;
        _combineBounds(iA * 6, iC * 6, iE * 6);
        _height[iA] = 1 + math.max(_height[iC], _height[iE]);
      } else {
        _right[iB] = iE;
        _left[iA] = iD;
        _parentOrNext[iD] = iA;
        _combineBounds(iA * 6, iC * 6, iD * 6);
        _height[iA] = 1 + math.max(_height[iC], _height[iD]);
      }
      _balance(iA);
      final c1 = _left[iB];
      final c2 = _right[iB];
      _combineBounds(iB * 6, c1 * 6, c2 * 6);
      _height[iB] = 1 + math.max(_height[c1], _height[c2]);
      return iB;
    }

    return iA;
  }

  double _surfaceArea(int o) {
    final wx = _bounds[o + 3] - _bounds[o];
    final wy = _bounds[o + 4] - _bounds[o + 1];
    final wz = _bounds[o + 5] - _bounds[o + 2];
    return 2.0 * (wx * wy + wy * wz + wz * wx);
  }

  double _unionAreaWithLeaf(
    int o,
    double lMinX,
    double lMinY,
    double lMinZ,
    double lMaxX,
    double lMaxY,
    double lMaxZ,
  ) {
    final minX = math.min(_bounds[o], lMinX);
    final minY = math.min(_bounds[o + 1], lMinY);
    final minZ = math.min(_bounds[o + 2], lMinZ);
    final maxX = math.max(_bounds[o + 3], lMaxX);
    final maxY = math.max(_bounds[o + 4], lMaxY);
    final maxZ = math.max(_bounds[o + 5], lMaxZ);
    final wx = maxX - minX;
    final wy = maxY - minY;
    final wz = maxZ - minZ;
    return 2.0 * (wx * wy + wy * wz + wz * wx);
  }

  void _combineBounds(int out, int a, int b) {
    _bounds[out] = math.min(_bounds[a], _bounds[b]);
    _bounds[out + 1] = math.min(_bounds[a + 1], _bounds[b + 1]);
    _bounds[out + 2] = math.min(_bounds[a + 2], _bounds[b + 2]);
    _bounds[out + 3] = math.max(_bounds[a + 3], _bounds[b + 3]);
    _bounds[out + 4] = math.max(_bounds[a + 4], _bounds[b + 4]);
    _bounds[out + 5] = math.max(_bounds[a + 5], _bounds[b + 5]);
  }

  double _pointBoxDistSq(int o, double px, double py, double pz) {
    final minX = _bounds[o];
    final minY = _bounds[o + 1];
    final minZ = _bounds[o + 2];
    final maxX = _bounds[o + 3];
    final maxY = _bounds[o + 4];
    final maxZ = _bounds[o + 5];
    final dx = px < minX ? minX - px : (px > maxX ? px - maxX : 0.0);
    final dy = py < minY ? minY - py : (py > maxY ? py - maxY : 0.0);
    final dz = pz < minZ ? minZ - pz : (pz > maxZ ? pz - maxZ : 0.0);
    return dx * dx + dy * dy + dz * dz;
  }

  double _rayAabbDistance(
    int o,
    double ox,
    double oy,
    double oz,
    double dx,
    double dy,
    double dz,
    double maxDist,
  ) {
    var tMin = 0.0;
    var tMax = maxDist;

    final minX = _bounds[o] - 1e-6;
    final maxX = _bounds[o + 3] + 1e-6;
    if (dx.abs() < 1e-12) {
      if (ox < minX || ox > maxX) {
        return double.infinity;
      }
    } else {
      final inv = 1.0 / dx;
      var t1 = (minX - ox) * inv;
      var t2 = (maxX - ox) * inv;
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
        return double.infinity;
      }
    }

    final minY = _bounds[o + 1] - 1e-6;
    final maxY = _bounds[o + 4] + 1e-6;
    if (dy.abs() < 1e-12) {
      if (oy < minY || oy > maxY) {
        return double.infinity;
      }
    } else {
      final inv = 1.0 / dy;
      var t1 = (minY - oy) * inv;
      var t2 = (maxY - oy) * inv;
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
        return double.infinity;
      }
    }

    final minZ = _bounds[o + 2] - 1e-6;
    final maxZ = _bounds[o + 5] + 1e-6;
    if (dz.abs() < 1e-12) {
      if (oz < minZ || oz > maxZ) {
        return double.infinity;
      }
    } else {
      final inv = 1.0 / dz;
      var t1 = (minZ - oz) * inv;
      var t2 = (maxZ - oz) * inv;
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
        return double.infinity;
      }
    }

    return tMin;
  }

  void _pushStack(int sp, int node, double dist) {
    if (sp >= _stack.length) {
      final next = _stack.length * 2;
      _stack = Int32List(next)..setAll(0, _stack);
      _stackDist = Float64List(next)..setAll(0, _stackDist);
    }
    _stack[sp] = node;
    _stackDist[sp] = dist;
  }
}
