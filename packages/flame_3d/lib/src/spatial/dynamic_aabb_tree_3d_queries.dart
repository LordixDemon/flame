part of 'dynamic_aabb_tree_3d.dart';

extension _DynamicAabbTree3DQueries<T> on DynamicAabbTree3D<T> {
  /// Appends all items whose fat AABB overlaps [bounds] into [out].
  List<T> _queryAabbImpl(
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
  void _queryAabbCallbackImpl(
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
  List<T> _querySphereImpl(
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
  List<T> _queryFrustumImpl(
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
  DynamicTreeRayHit3D<T>? _raycastImpl(
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
  List<DynamicTreeRayHit3D<T>> _raycastAllImpl(
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
  bool _validateStructureImpl() {
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
}
