part of 'nav_mesh_3d.dart';

double _triArea2Up(Vector3 a, Vector3 b, Vector3 c, Vector3 up) {
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
bool _triangleIntersectsAabb(
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

List<Vector3> _clipAxis(
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
  bool inside(double val) => isMin ? val >= bound - 1e-6 : val <= bound + 1e-6;

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
          closestPointOnTriangle3D(
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
}
