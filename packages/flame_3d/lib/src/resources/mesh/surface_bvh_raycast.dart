part of 'surface_bvh.dart';

class _RayHitScratch() {
  double t = 0.0;
  double u = 0.0;
  double v = 0.0;
  double nx = 0.0;
  double ny = 0.0;
  double nz = 0.0;
}

class _BvhTraversalScratch() {
  Int32List stack = Int32List(128);
  final _RayHitScratch hit = _RayHitScratch();
  bool inRaycast = false;
}

@pragma('vm:prefer-inline')
bool _intersectTriangle(
  Float32List verts,
  List<int> indices,
  int stride,
  int posOffset,
  int tri,
  double ox,
  double oy,
  double oz,
  double dx,
  double dy,
  double dz,
  double maxT,
  CullMode cullMode,
  _RayHitScratch out, {
  required bool inclusiveMax,
}) {
  final b = tri * 3;
  final i0 = indices[b] * stride + posOffset;
  final i1 = indices[b + 1] * stride + posOffset;
  final i2 = indices[b + 2] * stride + posOffset;

  final v0x = verts[i0];
  final v0y = verts[i0 + 1];
  final v0z = verts[i0 + 2];
  final e1x = verts[i1] - v0x;
  final e1y = verts[i1 + 1] - v0y;
  final e1z = verts[i1 + 2] - v0z;
  final e2x = verts[i2] - v0x;
  final e2y = verts[i2 + 1] - v0y;
  final e2z = verts[i2 + 2] - v0z;

  final hx = dy * e2z - dz * e2y;
  final hy = dz * e2x - dx * e2z;
  final hz = dx * e2y - dy * e2x;
  final det = e1x * hx + e1y * hy + e1z * hz;

  switch (cullMode) {
    case CullMode.none:
      if (det.abs() < 1e-12) {
        return false;
      }
    case CullMode.backFace:
      if (det < 1e-12) {
        return false;
      }
    case CullMode.frontFace:
      if (det > -1e-12) {
        return false;
      }
  }

  final invDet = 1.0 / det;
  final sx = ox - v0x;
  final sy = oy - v0y;
  final sz = oz - v0z;
  final u = (sx * hx + sy * hy + sz * hz) * invDet;
  if (u < -1e-6 || u > 1.0 + 1e-6) {
    return false;
  }

  final qx = sy * e1z - sz * e1y;
  final qy = sz * e1x - sx * e1z;
  final qz = sx * e1y - sy * e1x;
  final v = (dx * qx + dy * qy + dz * qz) * invDet;
  if (v < -1e-6 || u + v > 1.0 + 1e-6) {
    return false;
  }

  final t = (e2x * qx + e2y * qy + e2z * qz) * invDet;
  if (t <= 1e-7 || (inclusiveMax ? t > maxT : t >= maxT)) {
    return false;
  }

  out.t = t;
  out.u = u;
  out.v = v;
  out.nx = e1y * e2z - e1z * e2y;
  out.ny = e1z * e2x - e1x * e2z;
  out.nz = e1x * e2y - e1y * e2x;
  return true;
}

extension _SurfaceBvhRaycast on SurfaceBvh {
  SurfaceRayHit? _raycastImpl(
    Ray ray, {
    double maxDistance = double.infinity,
    CullMode cullMode = CullMode.none,
  }) {
    if (_bvh.isEmpty || maxDistance <= 0) {
      return null;
    }
    final ox = ray.origin.x;
    final oy = ray.origin.y;
    final oz = ray.origin.z;
    final dx = ray.direction.x;
    final dy = ray.direction.y;
    final dz = ray.direction.z;

    if (_bvh.rayBoxEntry(0, ox, oy, oz, dx, dy, dz, maxDistance) ==
        double.infinity) {
      return null;
    }

    final counts = _bvh.counts;
    final leftOrFirst = _bvh.leftOrFirst;
    final rightChild = _bvh.rightChild;
    final triangles = _bvh.primitives;
    final verts = surface.vertexData;
    final indices = surface.indices;
    final stride = _stride;
    final posOffset = _positionOffset;

    var bestT = maxDistance;
    var bestU = 0.0;
    var bestV = 0.0;
    var bestTri = -1;
    var bestNx = 0.0;
    var bestNy = 0.0;
    var bestNz = 1.0;

    final reentrant = _scratch.inRaycast;
    var stack = reentrant ? Int32List(128) : _scratch.stack;
    final hit = reentrant ? _RayHitScratch() : _scratch.hit;
    if (!reentrant) {
      _scratch.inRaycast = true;
    }

    var sp = 0;
    stack[sp++] = 0;

    try {
      while (sp > 0) {
        final node = stack[--sp];
        if (_bvh.rayBoxEntry(node, ox, oy, oz, dx, dy, dz, bestT) ==
            double.infinity) {
          continue;
        }

        final count = counts[node];
        if (count > 0) {
          final start = leftOrFirst[node];
          for (var i = start; i < start + count; i++) {
            final tri = triangles[i];
            if (_intersectTriangle(
              verts,
              indices,
              stride,
              posOffset,
              tri,
              ox,
              oy,
              oz,
              dx,
              dy,
              dz,
              bestT,
              cullMode,
              hit,
              inclusiveMax: false,
            )) {
              bestT = hit.t;
              bestU = hit.u;
              bestV = hit.v;
              bestTri = tri;
              bestNx = hit.nx;
              bestNy = hit.ny;
              bestNz = hit.nz;
            }
          }
        } else {
          final left = leftOrFirst[node];
          final right = rightChild[node];
          final tLeft = _bvh.rayBoxEntry(left, ox, oy, oz, dx, dy, dz, bestT);
          final tRight = _bvh.rayBoxEntry(right, ox, oy, oz, dx, dy, dz, bestT);
          if (sp + 2 > stack.length) {
            stack = StaticBvh3D.growStack(stack, sp);
            if (!reentrant) {
              _scratch.stack = stack;
            }
          }
          if (tLeft < tRight) {
            if (tRight < bestT) {
              stack[sp++] = right;
            }
            if (tLeft < bestT) {
              stack[sp++] = left;
            }
          } else {
            if (tLeft < bestT) {
              stack[sp++] = left;
            }
            if (tRight < bestT) {
              stack[sp++] = right;
            }
          }
        }
      }
    } finally {
      if (!reentrant) {
        _scratch.inRaycast = false;
      }
    }

    if (bestTri < 0) {
      return null;
    }
    final nLen = math.sqrt(bestNx * bestNx + bestNy * bestNy + bestNz * bestNz);
    final invLen = nLen > 1e-12 ? 1.0 / nLen : 0.0;
    return SurfaceRayHit(
      distance: bestT,
      point: Vector3(ox + dx * bestT, oy + dy * bestT, oz + dz * bestT),
      normal: Vector3(bestNx * invLen, bestNy * invLen, bestNz * invLen),
      barycentricU: bestU,
      barycentricV: bestV,
      triangleIndex: bestTri,
    );
  }

  void _raycastAllImpl(
    Ray ray,
    List<SurfaceRayHit> out, {
    double maxDistance = double.infinity,
    CullMode cullMode = CullMode.none,
  }) {
    if (_bvh.isEmpty || maxDistance <= 0) {
      return;
    }
    final ox = ray.origin.x;
    final oy = ray.origin.y;
    final oz = ray.origin.z;
    final dx = ray.direction.x;
    final dy = ray.direction.y;
    final dz = ray.direction.z;

    if (_bvh.rayBoxEntry(0, ox, oy, oz, dx, dy, dz, maxDistance) ==
        double.infinity) {
      return;
    }

    final counts = _bvh.counts;
    final leftOrFirst = _bvh.leftOrFirst;
    final rightChild = _bvh.rightChild;
    final triangles = _bvh.primitives;
    final verts = surface.vertexData;
    final indices = surface.indices;
    final stride = _stride;
    final posOffset = _positionOffset;

    final reentrant = _scratch.inRaycast;
    var stack = reentrant ? Int32List(128) : _scratch.stack;
    final hit = reentrant ? _RayHitScratch() : _scratch.hit;
    if (!reentrant) {
      _scratch.inRaycast = true;
    }

    var sp = 0;
    stack[sp++] = 0;

    try {
      while (sp > 0) {
        final node = stack[--sp];
        if (_bvh.rayBoxEntry(node, ox, oy, oz, dx, dy, dz, maxDistance) ==
            double.infinity) {
          continue;
        }

        final count = counts[node];
        if (count > 0) {
          final start = leftOrFirst[node];
          for (var i = start; i < start + count; i++) {
            final tri = triangles[i];
            if (_intersectTriangle(
              verts,
              indices,
              stride,
              posOffset,
              tri,
              ox,
              oy,
              oz,
              dx,
              dy,
              dz,
              maxDistance,
              cullMode,
              hit,
              inclusiveMax: true,
            )) {
              final nx = hit.nx;
              final ny = hit.ny;
              final nz = hit.nz;
              final nLen = math.sqrt(nx * nx + ny * ny + nz * nz);
              final invLen = nLen > 1e-12 ? 1.0 / nLen : 0.0;
              final t = hit.t;
              out.add(
                SurfaceRayHit(
                  distance: t,
                  point: Vector3(ox + dx * t, oy + dy * t, oz + dz * t),
                  normal: Vector3(nx * invLen, ny * invLen, nz * invLen),
                  barycentricU: hit.u,
                  barycentricV: hit.v,
                  triangleIndex: tri,
                ),
              );
            }
          }
        } else {
          if (sp + 2 > stack.length) {
            stack = StaticBvh3D.growStack(stack, sp);
            if (!reentrant) {
              _scratch.stack = stack;
            }
          }
          stack[sp++] = rightChild[node];
          stack[sp++] = leftOrFirst[node];
        }
      }
    } finally {
      if (!reentrant) {
        _scratch.inRaycast = false;
      }
    }
  }
}
