import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:flame/src/game/game.dart';
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
///
/// Every setter (and [setDirection]) calls `Game.notifyVisualMutation` when
/// the value really changes, so on-demand rendering repaints, and changes
/// [computeSignature], so `StaticMeshChunk3D` re-bakes its lighting.
class DirectionalLight3D({
  double sunDirX = -0.45,
  double sunDirY = -0.35,
  double sunDirZ = 0.82,
  Color sunColor = const Color(0xFFFFF4DC),
  Color skyColor = const Color(0xFFD6ECFF),
  Color groundColor = const Color(0xFF6D5D53),
  double ambientIntensity = 0.44,
  double diffuseIntensity = 0.66,
  double rimIntensity = 0.16,
}) {
  this {
    _setDirection(sunDirX, sunDirY, sunDirZ);
  }

  double _lx = -0.45;
  double _ly = -0.35;
  double _lz = 0.82;
  Color _sunColor = sunColor;
  Color _skyColor = skyColor;
  Color _groundColor = groundColor;
  double _ambientIntensity = ambientIntensity;
  double _diffuseIntensity = diffuseIntensity;
  double _rimIntensity = rimIntensity;

  /// Colour of the directional (sun) light.
  Color get sunColor => _sunColor;
  set sunColor(Color value) {
    if (_sunColor != value) {
      _sunColor = value;
      Game.notifyVisualMutation();
    }
  }

  /// Hemisphere colour reaching surfaces that face up.
  Color get skyColor => _skyColor;
  set skyColor(Color value) {
    if (_skyColor != value) {
      _skyColor = value;
      Game.notifyVisualMutation();
    }
  }

  /// Hemisphere colour reaching surfaces that face down.
  Color get groundColor => _groundColor;
  set groundColor(Color value) {
    if (_groundColor != value) {
      _groundColor = value;
      Game.notifyVisualMutation();
    }
  }

  /// Strength of the hemisphere (ambient) term.
  double get ambientIntensity => _ambientIntensity;
  set ambientIntensity(double value) {
    if (_ambientIntensity != value) {
      _ambientIntensity = value;
      Game.notifyVisualMutation();
    }
  }

  /// Strength of the Lambertian sun term.
  double get diffuseIntensity => _diffuseIntensity;
  set diffuseIntensity(double value) {
    if (_diffuseIntensity != value) {
      _diffuseIntensity = value;
      Game.notifyVisualMutation();
    }
  }

  /// Strength of the sky-coloured view-angle rim term.
  double get rimIntensity => _rimIntensity;
  set rimIntensity(double value) {
    if (_rimIntensity != value) {
      _rimIntensity = value;
      Game.notifyVisualMutation();
    }
  }

  /// Unit vector X pointing towards the directional light source.
  double get dirX => _lx;

  /// Unit vector Y pointing towards the directional light source.
  double get dirY => _ly;

  /// Unit vector Z pointing towards the directional light source.
  double get dirZ => _lz;

  /// Normalizes and updates the directional light vector `(x, y, z)`.
  void setDirection(double x, double y, double z) {
    if (_setDirection(x, y, z)) {
      Game.notifyVisualMutation();
    }
  }

  bool _setDirection(double x, double y, double z) {
    final len = math.sqrt(x * x + y * y + z * z);
    if (len <= 1e-7) {
      return false;
    }
    final nx = x / len;
    final ny = y / len;
    final nz = z / len;
    if (nx == _lx && ny == _ly && nz == _lz) {
      return false;
    }
    _lx = nx;
    _ly = ny;
    _lz = nz;
    return true;
  }

  /// Computes a fast 31-bit state signature across light direction, colors, and
  /// intensities so `StaticMeshChunk3D` automatically invalidates on lighting
  /// changes.
  int computeSignature() {
    var h = 17;
    h = 0x1fffffff & (h * 31 + (_lx * 10000).round());
    h = 0x1fffffff & (h * 31 + (_ly * 10000).round());
    h = 0x1fffffff & (h * 31 + (_lz * 10000).round());
    h = 0x1fffffff & (h * 31 + _sunColor.toARGB32());
    h = 0x1fffffff & (h * 31 + _skyColor.toARGB32());
    h = 0x1fffffff & (h * 31 + _groundColor.toARGB32());
    h = 0x1fffffff & (h * 31 + (_ambientIntensity * 1000).round());
    h = 0x1fffffff & (h * 31 + (_diffuseIntensity * 1000).round());
    h = 0x1fffffff & (h * 31 + (_rimIntensity * 1000).round());
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
