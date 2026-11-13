import 'dart:math' as math;
import 'dart:typed_data';

import 'package:meta/meta.dart';

/// Immutable 3D ray in world coordinates `(x, y, z)` with unit direction
/// `(dx, dy, dz)`.
@immutable
class const Ray3D({
  required final double ox,
  required final double oy,
  required final double oz,
  required final double dx,
  required final double dy,
  required final double dz,
}) {
  /// Evaluates `origin + direction * t` along this ray.
  (double, double, double) pointAt(double t) => (
    ox + dx * t,
    oy + dy * t,
    oz + dz * t,
  );
}

/// Exact 3D triangle intersection result returned by [Raycaster3D].
@immutable
class const RaycastHit3D({
  required final int id,
  required final double distance,
  required final double worldX,
  required final double worldY,
  required final double worldZ,
  required final int faceIndex,
});

/// World-positioned 3D triangle mesh collider tested by [Raycaster3D].
@immutable
class const MeshCollider3D({
  required final int id,
  required final Float32List positions,
  required final Uint16List indices,
  required final double minX,
  required final double minY,
  required final double minZ,
  required final double maxX,
  required final double maxY,
  required final double maxZ,
  required final double worldX,
  required final double worldY,
  final double worldZ = 0.0,
  final double yawRad = 0.0,
  final double scale = 1.0,
});

/// Zero-allocation 3D slab AABB + Möller–Trumbore triangle raycaster.
class const Raycaster3D._() {
  /// Fast slab-method ray vs axis-aligned bounding box test.
  static bool intersectAabb(
    Ray3D ray, {
    required double minX,
    required double minY,
    required double minZ,
    required double maxX,
    required double maxY,
    required double maxZ,
    double maxDistance = double.infinity,
  }) {
    var tMin = 0.0;
    var tMax = maxDistance;

    if (ray.dx.abs() < 1e-8) {
      if (ray.ox < minX || ray.ox > maxX) {
        return false;
      }
    } else {
      final inv = 1.0 / ray.dx;
      var t1 = (minX - ray.ox) * inv;
      var t2 = (maxX - ray.ox) * inv;
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
        return false;
      }
    }

    if (ray.dy.abs() < 1e-8) {
      if (ray.oy < minY || ray.oy > maxY) {
        return false;
      }
    } else {
      final inv = 1.0 / ray.dy;
      var t1 = (minY - ray.oy) * inv;
      var t2 = (maxY - ray.oy) * inv;
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
        return false;
      }
    }

    if (ray.dz.abs() < 1e-8) {
      if (ray.oz < minZ || ray.oz > maxZ) {
        return false;
      }
    } else {
      final inv = 1.0 / ray.dz;
      var t1 = (minZ - ray.oz) * inv;
      var t2 = (maxZ - ray.oz) * inv;
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
        return false;
      }
    }

    return tMax >= 0.0;
  }

  /// Intersects [worldRay] against an indexed triangle mesh positioned at
  /// `(worldX, worldY, worldZ)` with Z-axis rotation [MeshCollider3D.yawRad]
  /// and uniform [MeshCollider3D.scale], returning `(worldDistance, faceIndex)`
  /// or null on miss.
  static (double, int)? raycastCollider(
    Ray3D worldRay,
    MeshCollider3D collider, {
    double maxDistance = double.infinity,
    bool cullBackfaces = true,
  }) {
    final s = collider.scale;
    if (s <= 1e-6) {
      return null;
    }

    final invS = 1.0 / s;
    final cy = math.cos(-collider.yawRad);
    final sy = math.sin(-collider.yawRad);

    final relX = (worldRay.ox - collider.worldX) * invS;
    final relY = (worldRay.oy - collider.worldY) * invS;
    final relZ = (worldRay.oz - collider.worldZ) * invS;

    final lox = relX * cy - relY * sy;
    final loy = relX * sy + relY * cy;
    final loz = relZ;

    final ldx = worldRay.dx * cy - worldRay.dy * sy;
    final ldy = worldRay.dx * sy + worldRay.dy * cy;
    final ldz = worldRay.dz;

    final localRay = Ray3D(
      ox: lox,
      oy: loy,
      oz: loz,
      dx: ldx,
      dy: ldy,
      dz: ldz,
    );
    final maxLocalT = maxDistance * invS;

    if (!intersectAabb(
      localRay,
      minX: collider.minX,
      minY: collider.minY,
      minZ: collider.minZ,
      maxX: collider.maxX,
      maxY: collider.maxY,
      maxZ: collider.maxZ,
      maxDistance: maxLocalT,
    )) {
      return null;
    }

    final pos = collider.positions;
    final idx = collider.indices;
    final faceCount = idx.length ~/ 3;
    var bestLocalT = maxLocalT;
    var bestFace = -1;

    for (var f = 0; f < faceCount; f++) {
      final f3 = f * 3;
      final i0 = idx[f3] * 3;
      final i1 = idx[f3 + 1] * 3;
      final i2 = idx[f3 + 2] * 3;

      final v0x = pos[i0];
      final v0y = pos[i0 + 1];
      final v0z = pos[i0 + 2];

      final e1x = pos[i1] - v0x;
      final e1y = pos[i1 + 1] - v0y;
      final e1z = pos[i1 + 2] - v0z;

      final e2x = pos[i2] - v0x;
      final e2y = pos[i2 + 1] - v0y;
      final e2z = pos[i2 + 2] - v0z;

      final px = ldy * e2z - ldz * e2y;
      final py = ldz * e2x - ldx * e2z;
      final pz = ldx * e2y - ldy * e2x;

      final det = e1x * px + e1y * py + e1z * pz;
      if (cullBackfaces) {
        if (det < 1e-7) {
          continue;
        }
      } else if (det.abs() < 1e-7) {
        continue;
      }

      final invDet = 1.0 / det;
      final tx = lox - v0x;
      final ty = loy - v0y;
      final tz = loz - v0z;

      final u = (tx * px + ty * py + tz * pz) * invDet;
      if (u < 0.0 || u > 1.0) {
        continue;
      }

      final qx = ty * e1z - tz * e1y;
      final qy = tz * e1x - tx * e1z;
      final qz = tx * e1y - ty * e1x;

      final v = (ldx * qx + ldy * qy + ldz * qz) * invDet;
      if (v < 0.0 || u + v > 1.0) {
        continue;
      }

      final t = (e2x * qx + e2y * qy + e2z * qz) * invDet;
      if (t > 1e-5 && t < bestLocalT) {
        bestLocalT = t;
        bestFace = f;
      }
    }

    if (bestFace < 0) {
      return null;
    }
    return (bestLocalT * s, bestFace);
  }

  /// Finds the closest 3D mesh collider intersected by [worldRay].
  static RaycastHit3D? pickClosest(
    Ray3D worldRay,
    Iterable<MeshCollider3D> colliders, {
    bool cullBackfaces = true,
  }) {
    var bestT = double.infinity;
    var bestId = -1;
    var bestFace = -1;

    for (final c in colliders) {
      final hit = raycastCollider(
        worldRay,
        c,
        maxDistance: bestT,
        cullBackfaces: cullBackfaces,
      );
      if (hit != null && hit.$1 < bestT) {
        bestT = hit.$1;
        bestId = c.id;
        bestFace = hit.$2;
      }
    }

    if (bestId < 0) {
      return null;
    }
    final (hx, hy, hz) = worldRay.pointAt(bestT);
    return RaycastHit3D(
      id: bestId,
      distance: bestT,
      worldX: hx,
      worldY: hy,
      worldZ: hz,
      faceIndex: bestFace,
    );
  }
}
