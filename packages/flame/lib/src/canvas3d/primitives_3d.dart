import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Color;

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

/// Immutable 3D axis-aligned bounding box and zero-allocation slab/sphere ray
/// intersection primitives.
@immutable
class const Aabb3D({
  required final double minX,
  required final double minY,
  required final double minZ,
  required final double maxX,
  required final double maxY,
  required final double maxZ,
}) {
  /// Intersects [ray] against this box within `[0 .. maxDistance]`.
  double? intersectRay(Ray3D ray, {double maxDistance = double.infinity}) =>
      intersectRayDistance(
        ray,
        minX: minX,
        minY: minY,
        minZ: minZ,
        maxX: maxX,
        maxY: maxY,
        maxZ: maxZ,
        maxDistance: maxDistance,
      );

  /// Slab-method ray vs axis-aligned bounding box test returning the
  /// non-negative entry distance `t` along [ray], or `null` on a miss.
  static double? intersectRayDistance(
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

  /// Analytical ray vs 3D bounding sphere intersection returning the
  /// non-negative entry distance `t` (`0.0` if [ray] starts inside), or `null`
  /// on a miss.
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
}

/// Exact 3D triangle intersection result returned by `Raycaster3D`.
@immutable
class const RaycastHit3D({
  required final int id,
  required final double distance,
  required final double worldX,
  required final double worldY,
  required final double worldZ,
  required final int faceIndex,
});

/// World-positioned 3D triangle mesh collider tested by `Raycaster3D`.
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

/// Hemisphere + directional sun lighting configuration for
/// `BatchMeshRenderer3D` and `StaticMeshChunk3D`.
class DirectionalLight3D({
  double sunDirX = -0.45,
  double sunDirY = -0.35,
  double sunDirZ = 0.82,
  var Color sunColor = const Color(0xFFFFF4DC),
  var Color skyColor = const Color(0xFFD6ECFF),
  var Color groundColor = const Color(0xFF6D5D53),
  var double ambientIntensity = 0.44,
  var double diffuseIntensity = 0.66,
  var double rimIntensity = 0.16,
}) {
  this {
    setDirection(sunDirX, sunDirY, sunDirZ);
  }

  double _lx = -0.45;
  double _ly = -0.35;
  double _lz = 0.82;

  /// Unit vector X pointing towards the directional light source.
  double get dirX => _lx;

  /// Unit vector Y pointing towards the directional light source.
  double get dirY => _ly;

  /// Unit vector Z pointing towards the directional light source.
  double get dirZ => _lz;

  /// Normalizes and updates the directional light vector `(x, y, z)`.
  void setDirection(double x, double y, double z) {
    final len = math.sqrt(x * x + y * y + z * z);
    if (len > 1e-7) {
      _lx = x / len;
      _ly = y / len;
      _lz = z / len;
    }
  }

  /// Computes a fast 31-bit state signature across light direction, colors, and
  /// intensities so `StaticMeshChunk3D` automatically invalidates on lighting
  /// changes.
  int computeSignature() {
    var h = 17;
    h = 0x1fffffff & (h * 31 + (_lx * 10000).round());
    h = 0x1fffffff & (h * 31 + (_ly * 10000).round());
    h = 0x1fffffff & (h * 31 + (_lz * 10000).round());
    h = 0x1fffffff & (h * 31 + sunColor.toARGB32());
    h = 0x1fffffff & (h * 31 + skyColor.toARGB32());
    h = 0x1fffffff & (h * 31 + groundColor.toARGB32());
    h = 0x1fffffff & (h * 31 + (ambientIntensity * 1000).round());
    h = 0x1fffffff & (h * 31 + (diffuseIntensity * 1000).round());
    h = 0x1fffffff & (h * 31 + (rimIntensity * 1000).round());
    return h;
  }
}

/// Triangle depth representative mode used by `BatchMeshRenderer3D` when
/// sorting triangles back-to-front.
enum TriangleDepthMode3D() {
  /// Mean depth of the three vertices (`(d0 + d1 + d2) / 3`).
  centroid,

  /// Closest vertex to the camera (`max(d0, d1, d2)`).
  nearestVertex,

  /// Farthest vertex from the camera (`min(d0, d1, d2)`).
  farthestVertex;

  /// Sort depth of a triangle whose vertices have view depths [d0], [d1] and
  /// [d2] (larger = closer to the camera).
  double depthOf(double d0, double d1, double d2) {
    return switch (this) {
      TriangleDepthMode3D.centroid => (d0 + d1 + d2) * (1.0 / 3.0),
      TriangleDepthMode3D.nearestVertex => math.max(d0, math.max(d1, d2)),
      TriangleDepthMode3D.farthestVertex => math.min(d0, math.min(d1, d2)),
    };
  }
}
