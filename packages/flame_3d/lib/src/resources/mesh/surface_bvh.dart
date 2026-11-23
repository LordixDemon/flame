import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame_3d/core.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/src/graphics/backend.dart';
import 'package:flame_3d/src/spatial/static_bvh_3d.dart';

/// {@template surface_ray_hit}
/// A narrowphase ray intersection on a [Surface] in the surface's local space.
/// {@endtemplate}
class SurfaceRayHit({
  /// Distance along the local ray from its origin (`origin + direction * t`).
  required final double distance,

  /// Hit point in surface local space.
  required final Vector3 point,

  /// Geometric face normal at the hit point in surface local space (unit
  /// length, oriented counter-clockwise `(v1 - v0) x (v2 - v0)`).
  required final Vector3 normal,

  /// First barycentric coordinate on edge `v1 - v0`.
  required final double barycentricU,

  /// Second barycentric coordinate on edge `v2 - v0`.
  required final double barycentricV,

  /// Zero-based triangle index (`indices[triangleIndex * 3 .. +2]`).
  required final int triangleIndex,
});

/// {@template surface_bvh}
/// Zero-allocation flat median-split Bounding Volume Hierarchy over the
/// triangles of a [Surface] for `O(log T)` ray-mesh queries.
///
/// Node bounds and child/leaf indices live in contiguous [Float32List] and
/// [Int32List] buffers, and ray traversal uses a fixed iterative stack with
/// nearest-child-first ordering so occluded subtrees are pruned early.
/// {@endtemplate}
class SurfaceBvh {
  /// Builds a BVH for [surface]. Prefer reading `surface.bvh`, which caches
  /// the hierarchy lazily on the surface.
  factory SurfaceBvh.build(Surface surface, {int maxLeafTriangles = 4}) {
    if (maxLeafTriangles < 1) {
      throw ArgumentError.value(
        maxLeafTriangles,
        'maxLeafTriangles',
        'Must be at least 1',
      );
    }
    final posOffset = surface.layout.offsetOf(VertexLayout.positionAttribute);
    if (posOffset == null) {
      return SurfaceBvh._empty(surface);
    }
    final indices = surface.indices;
    final triCount = indices.length ~/ 3;
    if (triCount == 0) {
      return SurfaceBvh._empty(surface);
    }

    final verts = surface.vertexData;
    final stride = surface.layout.strideInFloats;
    final triBounds = Float32List(triCount * 6);
    final centroids = Float32List(triCount * 3);

    for (var t = 0; t < triCount; t++) {
      final b = t * 3;
      final i0 = indices[b] * stride + posOffset;
      final i1 = indices[b + 1] * stride + posOffset;
      final i2 = indices[b + 2] * stride + posOffset;

      final x0 = verts[i0];
      final y0 = verts[i0 + 1];
      final z0 = verts[i0 + 2];
      final x1 = verts[i1];
      final y1 = verts[i1 + 1];
      final z1 = verts[i1 + 2];
      final x2 = verts[i2];
      final y2 = verts[i2 + 1];
      final z2 = verts[i2 + 2];

      final tb = t * 6;
      triBounds
        ..[tb] = math.min(x0, math.min(x1, x2))
        ..[tb + 1] = math.min(y0, math.min(y1, y2))
        ..[tb + 2] = math.min(z0, math.min(z1, z2))
        ..[tb + 3] = math.max(x0, math.max(x1, x2))
        ..[tb + 4] = math.max(y0, math.max(y1, y2))
        ..[tb + 5] = math.max(z0, math.max(z1, z2));

      final cb = t * 3;
      centroids
        ..[cb] = (x0 + x1 + x2) * (1.0 / 3.0)
        ..[cb + 1] = (y0 + y1 + y2) * (1.0 / 3.0)
        ..[cb + 2] = (z0 + z1 + z2) * (1.0 / 3.0);
    }

    return SurfaceBvh._(
      surface: surface,
      positionOffset: posOffset,
      stride: stride,
      bvh: StaticBvh3D.build(
        primitiveCount: triCount,
        primitiveBounds: triBounds,
        centroids: centroids,
        maxLeafPrimitives: maxLeafTriangles,
      ),
    );
  }

  /// Wraps a hierarchy built elsewhere for [surface]'s current vertices, in
  /// the layout [SurfaceBvh.build] produces: `6` floats of bounds per node
  /// (`minX, minY, minZ, maxX, maxY, maxZ`), the left child or first triangle
  /// slot per node, the right child per node, the triangle count per node
  /// (`0` for inner nodes) and the triangle order. Used to adopt hierarchies
  /// built on another isolate (see `Surface.adoptBvh`).
  factory SurfaceBvh.fromPrepared({
    required Surface surface,
    required int nodeCount,
    required Float32List bounds,
    required Int32List leftOrFirst,
    required Int32List rightChild,
    required Int32List counts,
    required Int32List triangles,
  }) {
    final triCount = surface.indices.length ~/ 3;
    final posOffset = surface.layout.offsetOf(VertexLayout.positionAttribute);
    if (posOffset == null || triCount == 0 || nodeCount == 0) {
      return SurfaceBvh._empty(surface);
    }
    return SurfaceBvh._(
      surface: surface,
      positionOffset: posOffset,
      stride: surface.layout.strideInFloats,
      bvh: StaticBvh3D.fromPrepared(
        nodeCount: nodeCount,
        primitiveCount: triCount,
        bounds: bounds,
        leftOrFirst: leftOrFirst,
        rightChild: rightChild,
        counts: counts,
        primitives: triangles,
      ),
    );
  }

  SurfaceBvh._({
    required this.surface,
    required this._positionOffset,
    required this._stride,
    required this._bvh,
  });

  SurfaceBvh._empty(this.surface)
    : _positionOffset = 0,
      _stride = 0,
      _bvh = StaticBvh3D.empty();

  /// The surface indexed by this BVH.
  final Surface surface;

  final int _positionOffset;
  final int _stride;
  final StaticBvh3D _bvh;

  /// Number of BVH nodes (`0` when the surface has no triangles).
  int get nodeCount => _bvh.nodeCount;

  /// Number of indexed triangles in [surface].
  int get triangleCount => _bvh.primitiveCount;

  Int32List _stack = Int32List(128);
  bool _inRaycast = false;

  /// Appends indices of triangles in [surface] whose BVH leaf (or individual
  /// triangle bounds when [filterTriangles] is `true`) overlaps [localAabb].
  ///
  /// Returns `outTriangles.length`. Pass an empty [outTriangles] list to
  /// collect only results for this query.
  int queryAabb(
    Aabb3 localAabb,
    List<int> outTriangles, {
    bool filterTriangles = false,
  }) {
    return queryAabbExtents(
      localAabb.min.x,
      localAabb.min.y,
      localAabb.min.z,
      localAabb.max.x,
      localAabb.max.y,
      localAabb.max.z,
      outTriangles,
      filterTriangles: filterTriangles,
    );
  }

  /// Appends indices of triangles in [surface] whose BVH leaf (or individual
  /// triangle bounds when [filterTriangles] is `true`) overlaps the local-space
  /// box `[minX..maxX] x [minY..maxY] x [minZ..maxZ]`.
  ///
  /// Returns `outTriangles.length`.
  int queryAabbExtents(
    double minX,
    double minY,
    double minZ,
    double maxX,
    double maxY,
    double maxZ,
    List<int> outTriangles, {
    bool filterTriangles = false,
  }) {
    if (_bvh.isEmpty) {
      return outTriangles.length;
    }
    const pad = 1e-5;
    final startLen = outTriangles.length;
    _bvh.queryAabbExtents(
      minX,
      minY,
      minZ,
      maxX,
      maxY,
      maxZ,
      outTriangles,
      padding: pad,
    );
    if (!filterTriangles || outTriangles.length == startLen) {
      return outTriangles.length;
    }

    final qMinX = minX - pad;
    final qMinY = minY - pad;
    final qMinZ = minZ - pad;
    final qMaxX = maxX + pad;
    final qMaxY = maxY + pad;
    final qMaxZ = maxZ + pad;

    final verts = surface.vertexData;
    final indices = surface.indices;
    final stride = _stride;
    final posOffset = _positionOffset;
    var write = startLen;
    for (var i = startLen; i < outTriangles.length; i++) {
      final tri = outTriangles[i];
      final b = tri * 3;
      final i0 = indices[b] * stride + posOffset;
      final i1 = indices[b + 1] * stride + posOffset;
      final i2 = indices[b + 2] * stride + posOffset;

      final x0 = verts[i0];
      final x1 = verts[i1];
      final x2 = verts[i2];
      if (math.min(x0, math.min(x1, x2)) > qMaxX ||
          math.max(x0, math.max(x1, x2)) < qMinX) {
        continue;
      }
      final y0 = verts[i0 + 1];
      final y1 = verts[i1 + 1];
      final y2 = verts[i2 + 1];
      if (math.min(y0, math.min(y1, y2)) > qMaxY ||
          math.max(y0, math.max(y1, y2)) < qMinY) {
        continue;
      }
      final z0 = verts[i0 + 2];
      final z1 = verts[i1 + 2];
      final z2 = verts[i2 + 2];
      if (math.min(z0, math.min(z1, z2)) > qMaxZ ||
          math.max(z0, math.max(z1, z2)) < qMinZ) {
        continue;
      }
      outTriangles[write++] = tri;
    }
    outTriangles.length = write;
    return write;
  }

  /// Finds the closest intersection of [ray] (in [surface]'s local space)
  /// within `[0, maxDistance]`, or `null` when nothing is hit.
  ///
  /// [cullMode] controls whether back-facing (`det < 0`) or front-facing
  /// (`det > 0`) triangles are ignored; defaults to [CullMode.none] (both
  /// sides hit).
  SurfaceRayHit? raycast(
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

    final reentrant = _inRaycast;
    var stack = reentrant ? Int32List(128) : _stack;
    if (!reentrant) {
      _inRaycast = true;
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
                  continue;
                }
              case CullMode.backFace:
                if (det < 1e-12) {
                  continue;
                }
              case CullMode.frontFace:
                if (det > -1e-12) {
                  continue;
                }
            }

            final invDet = 1.0 / det;
            final sx = ox - v0x;
            final sy = oy - v0y;
            final sz = oz - v0z;
            final u = (sx * hx + sy * hy + sz * hz) * invDet;
            if (u < -1e-6 || u > 1.0 + 1e-6) {
              continue;
            }

            final qx = sy * e1z - sz * e1y;
            final qy = sz * e1x - sx * e1z;
            final qz = sx * e1y - sy * e1x;
            final v = (dx * qx + dy * qy + dz * qz) * invDet;
            if (v < -1e-6 || u + v > 1.0 + 1e-6) {
              continue;
            }

            final t = (e2x * qx + e2y * qy + e2z * qz) * invDet;
            if (t > 1e-7 && t < bestT) {
              bestT = t;
              bestU = u;
              bestV = v;
              bestTri = tri;
              bestNx = e1y * e2z - e1z * e2y;
              bestNy = e1z * e2x - e1x * e2z;
              bestNz = e1x * e2y - e1y * e2x;
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
              _stack = stack;
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
        _inRaycast = false;
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

  /// Appends all intersections of [ray] within `[0, maxDistance]` into [out].
  void raycastAll(
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

    final reentrant = _inRaycast;
    var stack = reentrant ? Int32List(128) : _stack;
    if (!reentrant) {
      _inRaycast = true;
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
                  continue;
                }
              case CullMode.backFace:
                if (det < 1e-12) {
                  continue;
                }
              case CullMode.frontFace:
                if (det > -1e-12) {
                  continue;
                }
            }

            final invDet = 1.0 / det;
            final sx = ox - v0x;
            final sy = oy - v0y;
            final sz = oz - v0z;
            final u = (sx * hx + sy * hy + sz * hz) * invDet;
            if (u < -1e-6 || u > 1.0 + 1e-6) {
              continue;
            }

            final qx = sy * e1z - sz * e1y;
            final qy = sz * e1x - sx * e1z;
            final qz = sx * e1y - sy * e1x;
            final v = (dx * qx + dy * qy + dz * qz) * invDet;
            if (v < -1e-6 || u + v > 1.0 + 1e-6) {
              continue;
            }

            final t = (e2x * qx + e2y * qy + e2z * qz) * invDet;
            if (t > 1e-7 && t <= maxDistance) {
              final nx = e1y * e2z - e1z * e2y;
              final ny = e1z * e2x - e1x * e2z;
              final nz = e1x * e2y - e1y * e2x;
              final nLen = math.sqrt(nx * nx + ny * ny + nz * nz);
              final invLen = nLen > 1e-12 ? 1.0 / nLen : 0.0;
              out.add(
                SurfaceRayHit(
                  distance: t,
                  point: Vector3(ox + dx * t, oy + dy * t, oz + dz * t),
                  normal: Vector3(nx * invLen, ny * invLen, nz * invLen),
                  barycentricU: u,
                  barycentricV: v,
                  triangleIndex: tri,
                ),
              );
            }
          }
        } else {
          if (sp + 2 > stack.length) {
            stack = StaticBvh3D.growStack(stack, sp);
            if (!reentrant) {
              _stack = stack;
            }
          }
          stack[sp++] = rightChild[node];
          stack[sp++] = leftOrFirst[node];
        }
      }
    } finally {
      if (!reentrant) {
        _inRaycast = false;
      }
    }
  }
}
