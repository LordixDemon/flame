import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame/src/canvas3d/deformable_mesh_3d.dart';
import 'package:flame/src/canvas3d/mesh_3d.dart';
import 'package:flame/src/canvas3d/node_uv_decal_3d.dart';
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
  /// Slab-method ray vs axis-aligned bounding box test returning the
  /// non-negative entry distance `t` along [ray], or `null` if the ray misses
  /// `[0..maxDistance]`.
  static double? intersectAabbDistance(
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
        return null;
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
        return null;
      }
    }

    if (ray.dy.abs() < 1e-8) {
      if (ray.oy < minY || ray.oy > maxY) {
        return null;
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
        return null;
      }
    }

    if (ray.dz.abs() < 1e-8) {
      if (ray.oz < minZ || ray.oz > maxZ) {
        return null;
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
        return null;
      }
    }

    return tMax >= 0.0 ? tMin : null;
  }

  /// Fast slab-method ray vs axis-aligned bounding box boolean test.
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
    return intersectAabbDistance(
          ray,
          minX: minX,
          minY: minY,
          minZ: minZ,
          maxX: maxX,
          maxY: maxY,
          maxZ: maxZ,
          maxDistance: maxDistance,
        ) !=
        null;
  }

  /// Fast analytical ray vs 3D bounding sphere intersection returning the
  /// non-negative entry distance `t` (`0.0` if [ray] originates inside the
  /// sphere), or `null` if the ray misses `[0..maxDistance]`.
  static double? intersectSphereDistance(
    Ray3D ray, {
    required double cx,
    required double cy,
    required double cz,
    required double radius,
    double maxDistance = double.infinity,
  }) {
    if (radius < 0.0) {
      return null;
    }
    final ocX = ray.ox - cx;
    final ocY = ray.oy - cy;
    final ocZ = ray.oz - cz;
    final c = ocX * ocX + ocY * ocY + ocZ * ocZ - radius * radius;
    if (c <= 0.0) {
      return 0.0;
    }
    final a = ray.dx * ray.dx + ray.dy * ray.dy + ray.dz * ray.dz;
    if (a <= 1e-12) {
      return null;
    }
    final halfB = ocX * ray.dx + ocY * ray.dy + ocZ * ray.dz;
    if (halfB >= 0.0) {
      return null;
    }
    final disc = halfB * halfB - a * c;
    if (disc < 0.0) {
      return null;
    }
    final t = (-halfB - math.sqrt(disc)) / a;
    if (t < 0.0 || t > maxDistance) {
      return null;
    }
    return t;
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

  static final Float32List _rayRotScratch = Float32List(9);

  /// Intersects [worldRay] against [mesh] under full 3D world translation
  /// `(worldX, worldY, worldZ)`, arbitrary `3x3` orientation
  /// ([rotationMatrix3], [rotationQuat], or Euler
  /// `(yawRad, pitchRad, rollRad)`), and non-uniform
  /// `(scaleX, scaleY, scaleZ)`, accelerated by `O(log T)` [Mesh3D.bvh] when
  /// [useBvh] is `true`.
  ///
  /// Returns `(worldDistance, faceIndex)` in world units along [worldRay], or
  /// `null` on a miss.
  static (double distance, int faceIndex)? raycastMeshTransform(
    Ray3D worldRay,
    Mesh3D mesh, {
    required double worldX,
    required double worldY,
    double worldZ = 0.0,
    double scaleX = 1.0,
    double scaleY = 1.0,
    double scaleZ = 1.0,
    double yawRad = 0.0,
    double pitchRad = 0.0,
    double rollRad = 0.0,
    (double, double, double, double)? rotationQuat,
    Float32List? rotationMatrix3,
    double maxDistance = double.infinity,
    bool cullBackfaces = true,
    bool useBvh = true,
  }) {
    if (scaleX.abs() <= 1e-6 ||
        scaleY.abs() <= 1e-6 ||
        scaleZ.abs() <= 1e-6 ||
        mesh.triangleCount == 0) {
      return null;
    }

    final Float32List rot;
    if (rotationMatrix3 != null && rotationMatrix3.length >= 9) {
      rot = rotationMatrix3;
    } else if (rotationQuat != null) {
      final (qx, qy, qz, qw) = rotationQuat;
      Quaternion3D.writeMatrix3(qx, qy, qz, qw, _rayRotScratch);
      rot = _rayRotScratch;
    } else {
      Quaternion3D.writeEulerMatrix3(
        yawRad: yawRad,
        pitchRad: pitchRad,
        rollRad: rollRad,
        out: _rayRotScratch,
      );
      rot = _rayRotScratch;
    }

    final invSx = 1.0 / scaleX;
    final invSy = 1.0 / scaleY;
    final invSz = 1.0 / scaleZ;

    final relX = worldRay.ox - worldX;
    final relY = worldRay.oy - worldY;
    final relZ = worldRay.oz - worldZ;

    // R^T * rel, then divide by non-uniform scale:
    final lox = (rot[0] * relX + rot[3] * relY + rot[6] * relZ) * invSx;
    final loy = (rot[1] * relX + rot[4] * relY + rot[7] * relZ) * invSy;
    final loz = (rot[2] * relX + rot[5] * relY + rot[8] * relZ) * invSz;

    final rawDx =
        (rot[0] * worldRay.dx + rot[3] * worldRay.dy + rot[6] * worldRay.dz) *
        invSx;
    final rawDy =
        (rot[1] * worldRay.dx + rot[4] * worldRay.dy + rot[7] * worldRay.dz) *
        invSy;
    final rawDz =
        (rot[2] * worldRay.dx + rot[5] * worldRay.dy + rot[8] * worldRay.dz) *
        invSz;

    final localDirLen = math.sqrt(
      rawDx * rawDx + rawDy * rawDy + rawDz * rawDz,
    );
    if (localDirLen <= 1e-12) {
      return null;
    }
    final invLocalDirLen = 1.0 / localDirLen;
    final localRay = Ray3D(
      ox: lox,
      oy: loy,
      oz: loz,
      dx: rawDx * invLocalDirLen,
      dy: rawDy * invLocalDirLen,
      dz: rawDz * invLocalDirLen,
    );
    final maxLocalT = maxDistance.isFinite
        ? maxDistance * localDirLen
        : double.infinity;
    // Note: Transforming worldRay by S^-1 already reflects localRay when
    // det(S) = scaleX * scaleY * scaleZ < 0, so outward faces of a mirrored
    // mesh (which keep outward winding in the renderer per glTF §3.7.4) still
    // have det_local > 0 in mesh-local space.

    if (useBvh) {
      final hit = mesh.bvh.raycastLocal(
        localRay,
        maxLocalDistance: maxLocalT,
        cullBackfaces: cullBackfaces,
      );
      if (hit == null) {
        return null;
      }
      return (hit.$1 * invLocalDirLen, hit.$2);
    }

    if (!intersectAabb(
      localRay,
      minX: mesh.minX,
      minY: mesh.minY,
      minZ: mesh.minZ,
      maxX: mesh.maxX,
      maxY: mesh.maxY,
      maxZ: mesh.maxZ,
      maxDistance: maxLocalT,
    )) {
      return null;
    }

    final pos = mesh.positions;
    final idx = mesh.indices;
    final faceCount = idx.length ~/ 3;
    var bestLocalT = maxLocalT;
    var bestFace = -1;
    final ldx = localRay.dx;
    final ldy = localRay.dy;
    final ldz = localRay.dz;

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
    return (bestLocalT * invLocalDirLen, bestFace);
  }

  /// Intersects [worldRay] against all visible meshes in a [Node3D] hierarchy,
  /// returning the closest hit node, world distance, face index, and world hit
  /// point.
  static ({
    Node3D node,
    double distance,
    int faceIndex,
    double worldX,
    double worldY,
    double worldZ,
  })?
  raycastNodeHierarchy(
    Ray3D worldRay,
    Node3D root, {
    double maxDistance = double.infinity,
    bool cullBackfaces = true,
  }) {
    if (root.parent == null) {
      root.updateWorldTransforms();
    }
    Node3D? bestNode;
    var bestDist = maxDistance;
    var bestFace = -1;

    void visit(Node3D n) {
      if (!n.visible || n.opacity <= 0.0) {
        return;
      }
      final m = n.mesh;
      if (m != null) {
        final hit = raycastMeshTransform(
          worldRay,
          m,
          worldX: n.worldX,
          worldY: n.worldY,
          worldZ: n.worldZ,
          scaleX: n.worldScaleX,
          scaleY: n.worldScaleY,
          scaleZ: n.worldScaleZ,
          rotationMatrix3: n.worldRotationMatrix,
          maxDistance: bestDist,
          cullBackfaces: cullBackfaces,
        );
        if (hit != null && hit.$1 < bestDist) {
          bestDist = hit.$1;
          bestFace = hit.$2;
          bestNode = n;
        }
      }
      final kids = n.children;
      for (var i = 0; i < kids.length; i++) {
        visit(kids[i]);
      }
    }

    visit(root);
    if (bestNode == null) {
      return null;
    }
    final (hx, hy, hz) = worldRay.pointAt(bestDist);
    return (
      node: bestNode!,
      distance: bestDist,
      faceIndex: bestFace,
      worldX: hx,
      worldY: hy,
      worldZ: hz,
    );
  }
}
