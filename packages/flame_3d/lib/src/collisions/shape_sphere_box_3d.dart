part of 'shapes_3d.dart';

/// A 3D sphere collision shape centered at the local origin with [radius].
class SphereShape3D({
  required final double radius,
}) extends Shape3D {
  this : assert(radius > 0, 'radius must be positive');

  /// Maximum world-space radius under the scale of [worldTransform].
  double worldRadius(Matrix4 worldTransform) {
    final m = worldTransform.storage;
    final sx2 = m[0] * m[0] + m[1] * m[1] + m[2] * m[2];
    final sy2 = m[4] * m[4] + m[5] * m[5] + m[6] * m[6];
    final sz2 = m[8] * m[8] + m[9] * m[9] + m[10] * m[10];
    return radius * math.sqrt(math.max(sx2, math.max(sy2, sz2)));
  }

  @override
  Aabb3 computeLocalAabb({Aabb3? out}) {
    final box = out ?? Aabb3();
    box.min.setValues(-radius, -radius, -radius);
    box.max.setValues(radius, radius, radius);
    return box;
  }

  @override
  void computeWorldAabb(Matrix4 worldTransform, Aabb3 out) {
    final m = worldTransform.storage;
    final cx = m[12];
    final cy = m[13];
    final cz = m[14];
    final ex = radius * math.sqrt(m[0] * m[0] + m[4] * m[4] + m[8] * m[8]);
    final ey = radius * math.sqrt(m[1] * m[1] + m[5] * m[5] + m[9] * m[9]);
    final ez = radius * math.sqrt(m[2] * m[2] + m[6] * m[6] + m[10] * m[10]);
    out.min.setValues(cx - ex, cy - ey, cz - ez);
    out.max.setValues(cx + ex, cy + ey, cz + ez);
  }

  @override
  void supportPoint(Vector3 worldDir, Matrix4 worldTransform, Vector3 out) {
    final m = worldTransform.storage;
    final dx = worldDir.x;
    final dy = worldDir.y;
    final dz = worldDir.z;
    var lx = m[0] * dx + m[1] * dy + m[2] * dz;
    var ly = m[4] * dx + m[5] * dy + m[6] * dz;
    var lz = m[8] * dx + m[9] * dy + m[10] * dz;
    final len2 = lx * lx + ly * ly + lz * lz;
    if (len2 > 1e-24) {
      final s = radius / math.sqrt(len2);
      lx *= s;
      ly *= s;
      lz *= s;
    } else {
      lx = radius;
      ly = 0.0;
      lz = 0.0;
    }
    out.setValues(
      m[0] * lx + m[4] * ly + m[8] * lz + m[12],
      m[1] * lx + m[5] * ly + m[9] * lz + m[13],
      m[2] * lx + m[6] * ly + m[10] * lz + m[14],
    );
  }

  @override
  (double distance, Vector3 normal)? raycast(
    Ray worldRay,
    Matrix4 worldTransform, {
    double maxDistance = double.infinity,
  }) {
    if (!_prepareLocalRay(worldRay, worldTransform, maxDistance)) {
      return null;
    }
    final ox = Shape3D._rayScratch.localOrigin.x;
    final oy = Shape3D._rayScratch.localOrigin.y;
    final oz = Shape3D._rayScratch.localOrigin.z;
    final dx = Shape3D._rayScratch.localDir.x;
    final dy = Shape3D._rayScratch.localDir.y;
    final dz = Shape3D._rayScratch.localDir.z;

    final a = dx * dx + dy * dy + dz * dz;
    if (a <= 1e-24) {
      return null;
    }
    final halfB = ox * dx + oy * dy + oz * dz;
    final c = ox * ox + oy * oy + oz * oz - radius * radius;
    final disc = halfB * halfB - a * c;
    if (disc < 0.0) {
      return null;
    }
    final sqrtDisc = math.sqrt(disc);
    final invA = 1.0 / a;
    final t0 = (-halfB - sqrtDisc) * invA;
    final t1 = (-halfB + sqrtDisc) * invA;
    if (t1 < 0.0) {
      return null;
    }
    final t = t0 >= 0.0 ? t0 : 0.0;
    if (t > maxDistance) {
      return null;
    }
    final px = ox + dx * t;
    final py = oy + dy * t;
    final pz = oz + dz * t;
    final pLen = math.sqrt(px * px + py * py + pz * pz);
    if (pLen > 1e-12) {
      return (
        t,
        _transformLocalNormalToWorld(px / pLen, py / pLen, pz / pLen),
      );
    }
    return (
      t,
      Vector3(
        -Shape3D._rayScratch.unitWorldDir.x,
        -Shape3D._rayScratch.unitWorldDir.y,
        -Shape3D._rayScratch.unitWorldDir.z,
      ),
    );
  }

  @override
  double get inscribedSphereRadius => radius;

  @override
  double estimateLocalVolume() =>
      (4.0 / 3.0) * math.pi * radius * radius * radius;

  @override
  Vector3 computeLocalInertiaDiagonal(double mass, {Vector3? out}) {
    final res = out ?? Vector3.zero();
    if (mass <= 0.0) {
      res.setZero();
      return res;
    }
    final i = 0.4 * mass * radius * radius;
    res.setValues(i, i, i);
    return res;
  }
}

/// A 3D oriented bounding box (OBB) collision shape centered at the local
/// origin with positive [halfExtents] `(hx, hy, hz)`.
///
/// Under an arbitrary `worldTransform`, rotation and non-uniform scale produce
/// a true world-space OBB.
class BoxShape3D({
  required Vector3 halfExtents,
}) extends Shape3D {
  this
    : assert(
        halfExtents.x > 0 && halfExtents.y > 0 && halfExtents.z > 0,
        'halfExtents components must be positive',
      );

  /// Local half-extents `(hx, hy, hz)`.
  final Vector3 halfExtents = halfExtents.clone();

  @override
  bool get hasSupportFace => true;

  @override
  double get inscribedSphereRadius =>
      math.min(halfExtents.x, math.min(halfExtents.y, halfExtents.z));

  @override
  double estimateLocalVolume() =>
      8.0 * halfExtents.x * halfExtents.y * halfExtents.z;

  @override
  Aabb3 computeLocalAabb({Aabb3? out}) {
    final box = out ?? Aabb3();
    box.min.setValues(-halfExtents.x, -halfExtents.y, -halfExtents.z);
    box.max.setFrom(halfExtents);
    return box;
  }

  @override
  void computeWorldAabb(Matrix4 worldTransform, Aabb3 out) {
    final m = worldTransform.storage;
    final hx = halfExtents.x;
    final hy = halfExtents.y;
    final hz = halfExtents.z;
    final cx = m[12];
    final cy = m[13];
    final cz = m[14];
    final ex = m[0].abs() * hx + m[4].abs() * hy + m[8].abs() * hz;
    final ey = m[1].abs() * hx + m[5].abs() * hy + m[9].abs() * hz;
    final ez = m[2].abs() * hx + m[6].abs() * hy + m[10].abs() * hz;
    out.min.setValues(cx - ex, cy - ey, cz - ez);
    out.max.setValues(cx + ex, cy + ey, cz + ez);
  }

  @override
  void supportPoint(Vector3 worldDir, Matrix4 worldTransform, Vector3 out) {
    final m = worldTransform.storage;
    final dx = worldDir.x;
    final dy = worldDir.y;
    final dz = worldDir.z;
    final lx = m[0] * dx + m[1] * dy + m[2] * dz >= 0.0
        ? halfExtents.x
        : -halfExtents.x;
    final ly = m[4] * dx + m[5] * dy + m[6] * dz >= 0.0
        ? halfExtents.y
        : -halfExtents.y;
    final lz = m[8] * dx + m[9] * dy + m[10] * dz >= 0.0
        ? halfExtents.z
        : -halfExtents.z;
    out.setValues(
      m[0] * lx + m[4] * ly + m[8] * lz + m[12],
      m[1] * lx + m[5] * ly + m[9] * lz + m[13],
      m[2] * lx + m[6] * ly + m[10] * lz + m[14],
    );
  }

  @override
  (double distance, Vector3 normal)? raycast(
    Ray worldRay,
    Matrix4 worldTransform, {
    double maxDistance = double.infinity,
  }) {
    if (!_prepareLocalRay(worldRay, worldTransform, maxDistance)) {
      return null;
    }
    final ox = Shape3D._rayScratch.localOrigin.x;
    final oy = Shape3D._rayScratch.localOrigin.y;
    final oz = Shape3D._rayScratch.localOrigin.z;
    final dx = Shape3D._rayScratch.localDir.x;
    final dy = Shape3D._rayScratch.localDir.y;
    final dz = Shape3D._rayScratch.localDir.z;
    final hx = halfExtents.x;
    final hy = halfExtents.y;
    final hz = halfExtents.z;

    var tMin = -double.infinity;
    var tMax = double.infinity;
    var nx = 0.0;
    var ny = 0.0;
    var nz = 0.0;

    // X slab.
    if (dx.abs() < 1e-12) {
      if (ox < -hx || ox > hx) {
        return null;
      }
    } else {
      final inv = 1.0 / dx;
      var t1 = (-hx - ox) * inv;
      var t2 = (hx - ox) * inv;
      var sign = -1.0;
      if (t1 > t2) {
        final s = t1;
        t1 = t2;
        t2 = s;
        sign = 1.0;
      }
      if (t1 > tMin) {
        tMin = t1;
        nx = sign;
        ny = 0.0;
        nz = 0.0;
      }
      if (t2 < tMax) {
        tMax = t2;
      }
      if (tMin > tMax) {
        return null;
      }
    }

    // Y slab.
    if (dy.abs() < 1e-12) {
      if (oy < -hy || oy > hy) {
        return null;
      }
    } else {
      final inv = 1.0 / dy;
      var t1 = (-hy - oy) * inv;
      var t2 = (hy - oy) * inv;
      var sign = -1.0;
      if (t1 > t2) {
        final s = t1;
        t1 = t2;
        t2 = s;
        sign = 1.0;
      }
      if (t1 > tMin) {
        tMin = t1;
        nx = 0.0;
        ny = sign;
        nz = 0.0;
      }
      if (t2 < tMax) {
        tMax = t2;
      }
      if (tMin > tMax) {
        return null;
      }
    }

    // Z slab.
    if (dz.abs() < 1e-12) {
      if (oz < -hz || oz > hz) {
        return null;
      }
    } else {
      final inv = 1.0 / dz;
      var t1 = (-hz - oz) * inv;
      var t2 = (hz - oz) * inv;
      var sign = -1.0;
      if (t1 > t2) {
        final s = t1;
        t1 = t2;
        t2 = s;
        sign = 1.0;
      }
      if (t1 > tMin) {
        tMin = t1;
        nx = 0.0;
        ny = 0.0;
        nz = sign;
      }
      if (t2 < tMax) {
        tMax = t2;
      }
      if (tMin > tMax) {
        return null;
      }
    }

    if (tMax < 0.0) {
      return null;
    }
    if (tMin < 0.0) {
      return (
        0.0,
        Vector3(
          -Shape3D._rayScratch.unitWorldDir.x,
          -Shape3D._rayScratch.unitWorldDir.y,
          -Shape3D._rayScratch.unitWorldDir.z,
        ),
      );
    }
    if (tMin > maxDistance) {
      return null;
    }
    return (tMin, _transformLocalNormalToWorld(nx, ny, nz));
  }

  @override
  Vector3 computeLocalInertiaDiagonal(double mass, {Vector3? out}) {
    final res = out ?? Vector3.zero();
    if (mass <= 0.0) {
      res.setZero();
      return res;
    }
    final hx2 = halfExtents.x * halfExtents.x;
    final hy2 = halfExtents.y * halfExtents.y;
    final hz2 = halfExtents.z * halfExtents.z;
    final k = mass / 3.0;
    res.setValues(k * (hy2 + hz2), k * (hx2 + hz2), k * (hx2 + hy2));
    return res;
  }
}
