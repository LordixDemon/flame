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

/// Zero-allocation exact 3D Triangle-vs-AABB intersection via 13-axis SAT.
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

  final cx = 0.5 * (min.x + max.x);
  final cy = 0.5 * (min.y + max.y);
  final cz = 0.5 * (min.z + max.z);
  final hx = 0.5 * (max.x - min.x) + 1e-6;
  final hy = 0.5 * (max.y - min.y) + 1e-6;
  final hz = 0.5 * (max.z - min.z) + 1e-6;

  final p0x = v0.x - cx;
  final p0y = v0.y - cy;
  final p0z = v0.z - cz;
  final p1x = v1.x - cx;
  final p1y = v1.y - cy;
  final p1z = v1.z - cz;
  final p2x = v2.x - cx;
  final p2y = v2.y - cy;
  final p2z = v2.z - cz;

  final e0x = p1x - p0x;
  final e0y = p1y - p0y;
  final e0z = p1z - p0z;
  final e1x = p2x - p1x;
  final e1y = p2y - p1y;
  final e1z = p2z - p1z;
  final e2x = p0x - p2x;
  final e2y = p0y - p2y;
  final e2z = p0z - p2z;

  if (!_satEdgeBox(
        e0x,
        e0y,
        e0z,
        p0x,
        p0y,
        p0z,
        p1x,
        p1y,
        p1z,
        p2x,
        p2y,
        p2z,
        hx,
        hy,
        hz,
      ) ||
      !_satEdgeBox(
        e1x,
        e1y,
        e1z,
        p0x,
        p0y,
        p0z,
        p1x,
        p1y,
        p1z,
        p2x,
        p2y,
        p2z,
        hx,
        hy,
        hz,
      ) ||
      !_satEdgeBox(
        e2x,
        e2y,
        e2z,
        p0x,
        p0y,
        p0z,
        p1x,
        p1y,
        p1z,
        p2x,
        p2y,
        p2z,
        hx,
        hy,
        hz,
      )) {
    return false;
  }

  final f2x = p2x - p0x;
  final f2y = p2y - p0y;
  final f2z = p2z - p0z;
  final nx = e0y * f2z - e0z * f2y;
  final ny = e0z * f2x - e0x * f2z;
  final nz = e0x * f2y - e0y * f2x;
  final r = nx.abs() * hx + ny.abs() * hy + nz.abs() * hz;
  final d = nx * p0x + ny * p0y + nz * p0z;
  return d.abs() <= r;
}

@pragma('vm:prefer-inline')
bool _satEdgeBox(
  double ex,
  double ey,
  double ez,
  double p0x,
  double p0y,
  double p0z,
  double p1x,
  double p1y,
  double p1z,
  double p2x,
  double p2y,
  double p2z,
  double hx,
  double hy,
  double hz,
) {
  final ax = ex.abs();
  final ay = ey.abs();
  final az = ez.abs();

  // X x e = (0, -ez, ey)
  var q0 = -ez * p0y + ey * p0z;
  var q1 = -ez * p1y + ey * p1z;
  var q2 = -ez * p2y + ey * p2z;
  var r = az * hy + ay * hz;
  if (math.min(q0, math.min(q1, q2)) > r ||
      math.max(q0, math.max(q1, q2)) < -r) {
    return false;
  }

  // Y x e = (ez, 0, -ex)
  q0 = ez * p0x - ex * p0z;
  q1 = ez * p1x - ex * p1z;
  q2 = ez * p2x - ex * p2z;
  r = az * hx + ax * hz;
  if (math.min(q0, math.min(q1, q2)) > r ||
      math.max(q0, math.max(q1, q2)) < -r) {
    return false;
  }

  // Z x e = (-ey, ex, 0)
  q0 = -ey * p0x + ex * p0y;
  q1 = -ey * p1x + ex * p1y;
  q2 = -ey * p2x + ex * p2y;
  r = ay * hx + ax * hy;
  if (math.min(q0, math.min(q1, q2)) > r ||
      math.max(q0, math.max(q1, q2)) < -r) {
    return false;
  }

  return true;
}

class _NavPolyBvh._({
  required final StaticBvh3D bvh,
}) {
  factory _NavPolyBvh.build(List<Vector3> verts, List<NavPoly3D> polys) {
    final n = polys.length;
    if (n == 0) {
      return _NavPolyBvh._(bvh: StaticBvh3D.empty());
    }

    final triBounds = Float32List(n * 6);
    final centroids = Float32List(n * 3);
    for (var i = 0; i < n; i++) {
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

      final c = p.centroid;
      final cb = i * 3;
      centroids
        ..[cb] = c.x
        ..[cb + 1] = c.y
        ..[cb + 2] = c.z;
    }

    return _NavPolyBvh._(
      bvh: StaticBvh3D.build(
        primitiveCount: n,
        primitiveBounds: triBounds,
        centroids: centroids,
      ),
    );
  }

  Int32List _stack = Int32List(128);
  bool _inNearest = false;
  final Vector3 _cand = Vector3.zero();

  void queryAabb(Aabb3 box, List<int> outPolyIndices) {
    bvh.queryAabb(box, outPolyIndices);
  }

  /// Collects the polygons whose bounds the infinite line through [origin]
  /// along [direction] crosses.
  void queryLine(Vector3 origin, Vector3 direction, List<int> outPolyIndices) {
    bvh.queryLine(
      origin.x,
      origin.y,
      origin.z,
      direction.x,
      direction.y,
      direction.z,
      outPolyIndices,
    );
  }

  NavPolyHit3D? findNearest(
    Vector3 query,
    List<Vector3> verts,
    List<NavPoly3D> polys,
    Int32List? blockedRefCounts,
  ) {
    if (bvh.isEmpty) {
      return null;
    }
    final qx = query.x;
    final qy = query.y;
    final qz = query.z;

    var bestPoly = -1;
    var bestD2 = double.infinity;
    final bestPt = Vector3.zero();

    final counts = bvh.counts;
    final leftOrFirst = bvh.leftOrFirst;
    final rightChild = bvh.rightChild;
    final polyIndices = bvh.primitives;

    final reentrant = _inNearest;
    var stack = reentrant ? Int32List(128) : _stack;
    if (!reentrant) {
      _inNearest = true;
    }

    try {
      var sp = 0;
      stack[sp++] = 0;

      while (sp > 0) {
        final node = stack[--sp];
        if (bvh.boxDistanceSquared(node, qx, qy, qz) >= bestD2) {
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
          final dL = bvh.boxDistanceSquared(left, qx, qy, qz);
          final dR = bvh.boxDistanceSquared(right, qx, qy, qz);
          if (sp + 2 > stack.length) {
            stack = StaticBvh3D.growStack(stack, sp);
            if (!reentrant) {
              _stack = stack;
            }
          }
          if (dL < dR) {
            if (dR < bestD2) {
              stack[sp++] = right;
            }
            if (dL < bestD2) {
              stack[sp++] = left;
            }
          } else {
            if (dL < bestD2) {
              stack[sp++] = left;
            }
            if (dR < bestD2) {
              stack[sp++] = right;
            }
          }
        }
      }
    } finally {
      if (!reentrant) {
        _inNearest = false;
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
}
