import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame_3d/camera.dart' show Ray;
import 'package:flame_3d/core.dart';
import 'package:meta/meta.dart';

/// Alias for [Shape3D] used across compound and general collision APIs.
typedef CollisionShape3D = Shape3D;

/// Combining rule for friction or restitution between two [PhysicsMaterial3D]
/// instances in contact.
enum PhysicsCombineMode3D() {
  /// Arithmetic average `0.5 * (a + b)` (lowest priority).
  average,

  /// Smaller coefficient `min(a, b)`.
  minimum,

  /// Product `a * b`.
  multiply,

  /// Larger coefficient `max(a, b)` (highest priority).
  maximum;

  /// Combines [a] and [b] using this mode.
  double combine(double a, double b) {
    return switch (this) {
      PhysicsCombineMode3D.average => 0.5 * (a + b),
      PhysicsCombineMode3D.minimum => math.min(a, b),
      PhysicsCombineMode3D.multiply => a * b,
      PhysicsCombineMode3D.maximum => math.max(a, b),
    };
  }
}

/// Surface material properties (friction, restitution, combine rules, and
/// semantic [surfaceTag]) attachable to a `Collider3D` or `RigidBody3D`.
@immutable
class const PhysicsMaterial3D({
  final double friction = 0.5,
  final double restitution = 0.2,
  final PhysicsCombineMode3D frictionCombine = PhysicsCombineMode3D.average,
  final PhysicsCombineMode3D restitutionCombine = PhysicsCombineMode3D.maximum,
  final String surfaceTag = 'default',
}) {
  /// Combines the friction coefficients of [a] and [b], honoring the higher
  /// priority [PhysicsCombineMode3D].
  static double combineFriction(PhysicsMaterial3D a, PhysicsMaterial3D b) {
    final mode = a.frictionCombine.index >= b.frictionCombine.index
        ? a.frictionCombine
        : b.frictionCombine;
    return math.max(0.0, mode.combine(a.friction, b.friction));
  }

  /// Combines the restitution coefficients of [a] and [b], honoring the higher
  /// priority [PhysicsCombineMode3D].
  static double combineRestitution(PhysicsMaterial3D a, PhysicsMaterial3D b) {
    final mode = a.restitutionCombine.index >= b.restitutionCombine.index
        ? a.restitutionCombine
        : b.restitutionCombine;
    return mode.combine(a.restitution, b.restitution).clamp(0.0, 1.0);
  }
}

/// Principal coordinate axis in 3D space.
enum Axis3D() {
  /// The `+X` axis `(1, 0, 0)`.
  x,

  /// The `+Y` axis `(0, 1, 0)`.
  y,

  /// The `+Z` axis `(0, 0, 1)`.
  z;

  /// Writes this axis's positive unit vector into [out] and returns [out].
  Vector3 writeUnitVector(Vector3 out) {
    switch (this) {
      case Axis3D.x:
        out.setValues(1.0, 0.0, 0.0);
      case Axis3D.y:
        out.setValues(0.0, 1.0, 0.0);
      case Axis3D.z:
        out.setValues(0.0, 0.0, 1.0);
    }
    return out;
  }

  /// Allocates and returns this axis's positive unit vector.
  Vector3 get unitVector => writeUnitVector(Vector3.zero());
}

/// Base class for 3D collision shapes (convex primitives, [CompoundShape3D],
/// and [HeightfieldShape3D]).
///
/// Shapes are lightweight geometric descriptors in local space; world-space
/// queries take an explicit `worldTransform` [Matrix4] so one shape instance
/// can be shared across many colliders or rigid bodies.
sealed class Shape3D() {
  /// Minimum inscribed sphere radius used by default for continuous collision
  /// detection (`RigidBody3D.ccdSweptSphereRadius`).
  double get inscribedSphereRadius;

  /// Geometric volume in local space used when distributing mass across
  /// [CompoundShape3D] children or estimating buoyancy displacement.
  double estimateLocalVolume();

  /// Local-space center of mass offset (`(0, 0, 0)` for centered primitives;
  /// volume-weighted composite center of mass for [CompoundShape3D]).
  Vector3 get localCenterOfMass => _zeroCenterOfMass;

  /// Writes the local-space axis-aligned bounding box of this shape into [out].
  Aabb3 computeLocalAabb({Aabb3? out});

  /// Writes the world-space axis-aligned bounding box under [worldTransform]
  /// into [out].
  void computeWorldAabb(Matrix4 worldTransform, Aabb3 out);

  /// Writes the furthest point on this shape along `worldDir` (in world space)
  /// under [worldTransform] into [out].
  void supportPoint(Vector3 worldDir, Matrix4 worldTransform, Vector3 out);

  /// Intersects [worldRay] against this shape transformed by [worldTransform]
  /// within [maxDistance] world units, returning `(distance, worldNormal)` or
  /// `null` when missed.
  (double distance, Vector3 normal)? raycast(
    Ray worldRay,
    Matrix4 worldTransform, {
    double maxDistance = double.infinity,
  });

  /// Computes the local-space diagonal moment of inertia `(Ix, Iy, Iz)` for a
  /// uniform solid body of [mass].
  Vector3 computeLocalInertiaDiagonal(double mass, {Vector3? out});

  /// Computes the full `3x3` symmetric local-space inertia tensor for [mass].
  Matrix3 computeLocalInertiaTensor(double mass, {Matrix3? out}) {
    final m = out ?? Matrix3.zero();
    m.setZero();
    final d = computeLocalInertiaDiagonal(mass, out: _inertiaDiagScratch);
    m.storage[0] = d.x;
    m.storage[4] = d.y;
    m.storage[8] = d.z;
    return m;
  }

  static final Vector3 _zeroCenterOfMass = Vector3.zero();
  static final Vector3 _inertiaDiagScratch = Vector3.zero();
}

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
    final ox = _localOrigin.x;
    final oy = _localOrigin.y;
    final oz = _localOrigin.z;
    final dx = _localDir.x;
    final dy = _localDir.y;
    final dz = _localDir.z;

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
    return (t, Vector3(-_unitWorldDir.x, -_unitWorldDir.y, -_unitWorldDir.z));
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

/// A 3D capsule collision shape aligned along [axis] and centered at the local
/// origin.
///
/// [height] is the **total** tip-to-tip height (`height >= 2 * radius`), so the
/// internal cylindrical spine segment runs from `-halfSegment` to
/// `+halfSegment` along [axis], where `halfSegment = height * 0.5 - radius`.
class CapsuleShape3D({
  required final double radius,
  required final double height,
  final Axis3D axis = Axis3D.y,
}) extends Shape3D {
  this
    : assert(radius > 0, 'radius must be positive'),
      assert(
        height >= 2 * radius - 1e-6,
        'height must be at least 2 * radius (total capsule height)',
      );

  /// Half-length of the internal cylindrical spine segment.
  double get halfSegment => math.max(0.0, height * 0.5 - radius);

  /// Writes the world-space segment endpoints `[outA, outB]` and returns the
  /// effective world-space cap radius under [worldTransform].
  double worldSpine(Matrix4 worldTransform, Vector3 outA, Vector3 outB) {
    final m = worldTransform.storage;
    final hs = halfSegment;
    final sx = math.sqrt(m[0] * m[0] + m[1] * m[1] + m[2] * m[2]);
    final sy = math.sqrt(m[4] * m[4] + m[5] * m[5] + m[6] * m[6]);
    final sz = math.sqrt(m[8] * m[8] + m[9] * m[9] + m[10] * m[10]);

    switch (axis) {
      case Axis3D.x:
        outA.setValues(
          m[12] - m[0] * hs,
          m[13] - m[1] * hs,
          m[14] - m[2] * hs,
        );
        outB.setValues(
          m[12] + m[0] * hs,
          m[13] + m[1] * hs,
          m[14] + m[2] * hs,
        );
        return radius * math.max(sy, sz);
      case Axis3D.y:
        outA.setValues(
          m[12] - m[4] * hs,
          m[13] - m[5] * hs,
          m[14] - m[6] * hs,
        );
        outB.setValues(
          m[12] + m[4] * hs,
          m[13] + m[5] * hs,
          m[14] + m[6] * hs,
        );
        return radius * math.max(sx, sz);
      case Axis3D.z:
        outA.setValues(
          m[12] - m[8] * hs,
          m[13] - m[9] * hs,
          m[14] - m[10] * hs,
        );
        outB.setValues(
          m[12] + m[8] * hs,
          m[13] + m[9] * hs,
          m[14] + m[10] * hs,
        );
        return radius * math.max(sx, sy);
    }
  }

  @override
  Aabb3 computeLocalAabb({Aabb3? out}) {
    final box = out ?? Aabb3();
    final halfH = halfSegment + radius;
    switch (axis) {
      case Axis3D.x:
        box.min.setValues(-halfH, -radius, -radius);
        box.max.setValues(halfH, radius, radius);
      case Axis3D.y:
        box.min.setValues(-radius, -halfH, -radius);
        box.max.setValues(radius, halfH, radius);
      case Axis3D.z:
        box.min.setValues(-radius, -radius, -halfH);
        box.max.setValues(radius, radius, halfH);
    }
    return box;
  }

  @override
  void computeWorldAabb(Matrix4 worldTransform, Aabb3 out) {
    final r = worldSpine(worldTransform, _capEndA, _capEndB);
    out.min.setValues(
      math.min(_capEndA.x, _capEndB.x) - r,
      math.min(_capEndA.y, _capEndB.y) - r,
      math.min(_capEndA.z, _capEndB.z) - r,
    );
    out.max.setValues(
      math.max(_capEndA.x, _capEndB.x) + r,
      math.max(_capEndA.y, _capEndB.y) + r,
      math.max(_capEndA.z, _capEndB.z) + r,
    );
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

    final hs = halfSegment;
    var sx = 0.0;
    var sy = 0.0;
    var sz = 0.0;
    switch (axis) {
      case Axis3D.x:
        sx = lx >= 0.0 ? hs : -hs;
      case Axis3D.y:
        sy = ly >= 0.0 ? hs : -hs;
      case Axis3D.z:
        sz = lz >= 0.0 ? hs : -hs;
    }

    final len2 = lx * lx + ly * ly + lz * lz;
    if (len2 > 1e-24) {
      final inv = radius / math.sqrt(len2);
      lx = sx + lx * inv;
      ly = sy + ly * inv;
      lz = sz + lz * inv;
    } else {
      lx = sx + radius;
      ly = sy;
      lz = sz;
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
    // Map coordinates so `oa`, `da` are along the spine axis, and `(ou, ov)`
    // are the radial plane coordinates.
    final double oa;
    final double ou;
    final double ov;
    final double da;
    final double du;
    final double dv;
    switch (axis) {
      case Axis3D.x:
        oa = _localOrigin.x;
        ou = _localOrigin.y;
        ov = _localOrigin.z;
        da = _localDir.x;
        du = _localDir.y;
        dv = _localDir.z;
      case Axis3D.y:
        oa = _localOrigin.y;
        ou = _localOrigin.x;
        ov = _localOrigin.z;
        da = _localDir.y;
        du = _localDir.x;
        dv = _localDir.z;
      case Axis3D.z:
        oa = _localOrigin.z;
        ou = _localOrigin.x;
        ov = _localOrigin.y;
        da = _localDir.z;
        du = _localDir.x;
        dv = _localDir.y;
    }

    final hs = halfSegment;
    final r2 = radius * radius;

    // Check if origin starts inside capsule.
    final clampedOa = oa.clamp(-hs, hs);
    final diffA = oa - clampedOa;
    if (diffA * diffA + ou * ou + ov * ov <= r2) {
      return (
        0.0,
        Vector3(-_unitWorldDir.x, -_unitWorldDir.y, -_unitWorldDir.z),
      );
    }

    var bestT = double.infinity;
    var bestNa = 0.0;
    var bestNu = 0.0;
    var bestNv = 0.0;

    // 1. Cylindrical wall intersection on `[-hs, +hs]`.
    final qa = du * du + dv * dv;
    if (qa > 1e-18) {
      final halfQb = ou * du + ov * dv;
      final qc = ou * ou + ov * ov - r2;
      final disc = halfQb * halfQb - qa * qc;
      if (disc >= 0.0) {
        final tCyl = (-halfQb - math.sqrt(disc)) / qa;
        if (tCyl >= 0.0 && tCyl <= maxDistance) {
          final hitA = oa + da * tCyl;
          if (hitA >= -hs && hitA <= hs) {
            bestT = tCyl;
            bestNa = 0.0;
            bestNu = (ou + du * tCyl) / radius;
            bestNv = (ov + dv * tCyl) / radius;
          }
        }
      }
    }

    // 2. Two hemispherical caps at `capA = -hs` and `capA = +hs`.
    final rayLen2 = da * da + qa;
    if (rayLen2 > 1e-24) {
      final invRayLen2 = 1.0 / rayLen2;
      for (var capIdx = 0; capIdx < 2; capIdx++) {
        final capA = capIdx == 0 ? -hs : hs;
        final roa = oa - capA;
        final halfB = roa * da + ou * du + ov * dv;
        final c = roa * roa + ou * ou + ov * ov - r2;
        final disc = halfB * halfB - rayLen2 * c;
        if (disc < 0.0) {
          continue;
        }
        final tCap = (-halfB - math.sqrt(disc)) * invRayLen2;
        if (tCap >= 0.0 && tCap < bestT && tCap <= maxDistance) {
          bestT = tCap;
          bestNa = (roa + da * tCap) / radius;
          bestNu = (ou + du * tCap) / radius;
          bestNv = (ov + dv * tCap) / radius;
        }
      }
    }

    if (!bestT.isFinite) {
      return null;
    }

    final double lnx;
    final double lny;
    final double lnz;
    switch (axis) {
      case Axis3D.x:
        lnx = bestNa;
        lny = bestNu;
        lnz = bestNv;
      case Axis3D.y:
        lnx = bestNu;
        lny = bestNa;
        lnz = bestNv;
      case Axis3D.z:
        lnx = bestNu;
        lny = bestNv;
        lnz = bestNa;
    }
    return (bestT, _transformLocalNormalToWorld(lnx, lny, lnz));
  }

  @override
  Vector3 computeLocalInertiaDiagonal(double mass, {Vector3? out}) {
    final res = out ?? Vector3.zero();
    if (mass <= 0.0) {
      res.setZero();
      return res;
    }
    final r = radius;
    final r2 = r * r;
    final cylLen = 2.0 * halfSegment;
    final vCyl = math.pi * r2 * cylLen;
    final vSph = (4.0 / 3.0) * math.pi * r2 * r;
    final vTot = vCyl + vSph;
    final mCyl = mass * (vCyl / vTot);
    final mSph = mass * (vSph / vTot);

    final iAxial = mCyl * (0.5 * r2) + mSph * (0.4 * r2);
    final iTrans =
        mCyl * ((1.0 / 12.0) * cylLen * cylLen + 0.25 * r2) +
        mSph * (0.4 * r2 + 0.375 * r * cylLen + 0.25 * cylLen * cylLen);

    switch (axis) {
      case Axis3D.x:
        res.setValues(iAxial, iTrans, iTrans);
      case Axis3D.y:
        res.setValues(iTrans, iAxial, iTrans);
      case Axis3D.z:
        res.setValues(iTrans, iTrans, iAxial);
    }
    return res;
  }

  @override
  double get inscribedSphereRadius => radius;

  @override
  double estimateLocalVolume() {
    final r2 = radius * radius;
    return math.pi * r2 * (2.0 * halfSegment) +
        (4.0 / 3.0) * math.pi * r2 * radius;
  }

  static final Vector3 _capEndA = Vector3.zero();
  static final Vector3 _capEndB = Vector3.zero();
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
    final ox = _localOrigin.x;
    final oy = _localOrigin.y;
    final oz = _localOrigin.z;
    final dx = _localDir.x;
    final dy = _localDir.y;
    final dz = _localDir.z;
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
        Vector3(-_unitWorldDir.x, -_unitWorldDir.y, -_unitWorldDir.z),
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

/// A 3D convex polyhedron collision shape defined as the convex hull of
/// [vertices] in local space.
///
/// The hull is built once, when the shape is created: its polygonal faces
/// (coplanar triangles merged, see [faceCount]), its exact volume, center of
/// mass and inertia tensor (of a solid of uniform density), and its inradius.
/// Points inside the hull are ignored by every query. Degenerate input (fewer
/// than four points, or all of them on one line or one plane) has no faces:
/// the shape then still collides through its support points, with a single
/// contact point per step, and takes its mass properties from its bounding
/// box.
class ConvexHullShape3D({
  required List<Vector3> vertices,
}) extends Shape3D {
  this : assert(vertices.isNotEmpty, 'vertices must not be empty') {
    _localCenter = Vector3(
      0.5 * (_localAabb.min.x + _localAabb.max.x),
      0.5 * (_localAabb.min.y + _localAabb.max.y),
      0.5 * (_localAabb.min.z + _localAabb.max.z),
    );
    final topology = _HullTopology3D.build(vertices);
    _topology = topology;
    _coords = topology?.coords ?? _packCoords(vertices);
  }

  /// Immutable snapshot of local hull vertices.
  final List<Vector3> vertices = List.unmodifiable([
    for (final v in vertices) v.clone(),
  ]);

  late final Float64List _coords;
  late final _HullTopology3D? _topology;
  final Aabb3 _localAabb = _computeBounds(vertices);
  late final Vector3 _localCenter;

  /// Number of polygonal faces of the hull (`0` for degenerate input).
  int get faceCount => _topology?.faceCount ?? 0;

  /// Writes the outward unit normal of [face] (in local space) into [out] and
  /// returns it.
  Vector3 faceNormal(int face, [Vector3? out]) {
    final t = _topology;
    if (t == null) {
      throw RangeError('$this has no faces (degenerate vertices)');
    }
    RangeError.checkValueInInterval(face, 0, t.faceCount - 1, 'face');
    final res = out ?? Vector3.zero();
    return res..setValues(
      t.faceNormals[face * 3],
      t.faceNormals[face * 3 + 1],
      t.faceNormals[face * 3 + 2],
    );
  }

  /// Indices into [vertices] of the corners of [face], counter-clockwise
  /// around its outward normal.
  List<int> faceVertexIndices(int face) {
    final t = _topology;
    if (t == null) {
      throw RangeError('$this has no faces (degenerate vertices)');
    }
    RangeError.checkValueInInterval(face, 0, t.faceCount - 1, 'face');
    return List.unmodifiable([
      for (var k = t.faceStart[face]; k < t.faceStart[face + 1]; k++)
        t.sourceIndex[t.faceVerts[k]],
    ]);
  }

  /// Hull vertex coordinates `(x, y, z, ...)` used by the narrowphase.
  @internal
  Float64List get hullCoords => _coords;

  /// First index into [hullFaceVertices] of each face, plus one end entry.
  @internal
  Int32List? get hullFaceStart => _topology?.faceStart;

  /// Corner indices (into [hullCoords] triples) of all faces.
  @internal
  Int32List? get hullFaceVertices => _topology?.faceVerts;

  /// Outward unit face normals `(x, y, z, ...)` in local space.
  @internal
  Float64List? get hullFaceNormals => _topology?.faceNormals;

  static Float64List _packCoords(List<Vector3> verts) {
    final data = Float64List(verts.length * 3);
    for (var i = 0; i < verts.length; i++) {
      final v = verts[i];
      final o = i * 3;
      data[o] = v.x;
      data[o + 1] = v.y;
      data[o + 2] = v.z;
    }
    return data;
  }

  static Aabb3 _computeBounds(List<Vector3> verts) {
    var minX = double.infinity;
    var minY = double.infinity;
    var minZ = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    var maxZ = double.negativeInfinity;
    for (final v in verts) {
      if (v.x < minX) {
        minX = v.x;
      }
      if (v.y < minY) {
        minY = v.y;
      }
      if (v.z < minZ) {
        minZ = v.z;
      }
      if (v.x > maxX) {
        maxX = v.x;
      }
      if (v.y > maxY) {
        maxY = v.y;
      }
      if (v.z > maxZ) {
        maxZ = v.z;
      }
    }
    return Aabb3.minMax(
      Vector3(minX, minY, minZ),
      Vector3(maxX, maxY, maxZ),
    );
  }

  /// Local centroid of this hull's bounding box.
  Vector3 get localCenter => _localCenter;

  /// Local center of mass of the solid hull (the bounding-box center for
  /// degenerate input).
  @override
  Vector3 get localCenterOfMass => _topology?.centerOfMass ?? _localCenter;

  /// Radius of the largest sphere centered on [localCenterOfMass] that fits
  /// inside the hull: the distance from the center of mass to the nearest
  /// face plane.
  @override
  double get inscribedSphereRadius {
    final t = _topology;
    if (t != null) {
      return t.inscribedRadius;
    }
    final hx = 0.5 * (_localAabb.max.x - _localAabb.min.x);
    final hy = 0.5 * (_localAabb.max.y - _localAabb.min.y);
    final hz = 0.5 * (_localAabb.max.z - _localAabb.min.z);
    return math.max(1e-3, math.min(hx, math.min(hy, hz)));
  }

  /// Exact volume of the hull (half the bounding box for degenerate input).
  @override
  double estimateLocalVolume() {
    final t = _topology;
    if (t != null) {
      return t.volume;
    }
    final wx = math.max(1e-4, _localAabb.max.x - _localAabb.min.x);
    final wy = math.max(1e-4, _localAabb.max.y - _localAabb.min.y);
    final wz = math.max(1e-4, _localAabb.max.z - _localAabb.min.z);
    return 0.5 * wx * wy * wz;
  }

  @override
  Aabb3 computeLocalAabb({Aabb3? out}) {
    final box = out ?? Aabb3();
    box.min.setFrom(_localAabb.min);
    box.max.setFrom(_localAabb.max);
    return box;
  }

  @override
  void computeWorldAabb(Matrix4 worldTransform, Aabb3 out) {
    final m = worldTransform.storage;
    var minX = double.infinity;
    var minY = double.infinity;
    var minZ = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    var maxZ = double.negativeInfinity;
    final coords = _coords;
    for (var i = 0; i < coords.length; i += 3) {
      final lx = coords[i];
      final ly = coords[i + 1];
      final lz = coords[i + 2];
      final wx = m[0] * lx + m[4] * ly + m[8] * lz + m[12];
      final wy = m[1] * lx + m[5] * ly + m[9] * lz + m[13];
      final wz = m[2] * lx + m[6] * ly + m[10] * lz + m[14];
      if (wx < minX) {
        minX = wx;
      }
      if (wy < minY) {
        minY = wy;
      }
      if (wz < minZ) {
        minZ = wz;
      }
      if (wx > maxX) {
        maxX = wx;
      }
      if (wy > maxY) {
        maxY = wy;
      }
      if (wz > maxZ) {
        maxZ = wz;
      }
    }
    out.min.setValues(minX, minY, minZ);
    out.max.setValues(maxX, maxY, maxZ);
  }

  @override
  void supportPoint(Vector3 worldDir, Matrix4 worldTransform, Vector3 out) {
    final m = worldTransform.storage;
    final dx = worldDir.x;
    final dy = worldDir.y;
    final dz = worldDir.z;
    final lxDir = m[0] * dx + m[1] * dy + m[2] * dz;
    final lyDir = m[4] * dx + m[5] * dy + m[6] * dz;
    final lzDir = m[8] * dx + m[9] * dy + m[10] * dz;

    final coords = _coords;
    var bestIdx = 0;
    var bestDot = coords[0] * lxDir + coords[1] * lyDir + coords[2] * lzDir;
    for (var i = 3; i < coords.length; i += 3) {
      final d =
          coords[i] * lxDir + coords[i + 1] * lyDir + coords[i + 2] * lzDir;
      if (d > bestDot) {
        bestDot = d;
        bestIdx = i;
      }
    }
    final lx = coords[bestIdx];
    final ly = coords[bestIdx + 1];
    final lz = coords[bestIdx + 2];
    out.setValues(
      m[0] * lx + m[4] * ly + m[8] * lz + m[12],
      m[1] * lx + m[5] * ly + m[9] * lz + m[13],
      m[2] * lx + m[6] * ly + m[10] * lz + m[14],
    );
  }

  void _localSupport(double dx, double dy, double dz, Vector3 out) {
    final coords = _coords;
    var bestIdx = 0;
    var bestDot = coords[0] * dx + coords[1] * dy + coords[2] * dz;
    for (var i = 3; i < coords.length; i += 3) {
      final d = coords[i] * dx + coords[i + 1] * dy + coords[i + 2] * dz;
      if (d > bestDot) {
        bestDot = d;
        bestIdx = i;
      }
    }
    out.setValues(coords[bestIdx], coords[bestIdx + 1], coords[bestIdx + 2]);
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
    // GJK conservative advancement in local space: ray `x(t) = o + t * d`
    // for `t in [0, maxDistance]`.
    var lambda = 0.0;
    var xx = _localOrigin.x;
    var xy = _localOrigin.y;
    var xz = _localOrigin.z;
    final rx = _localDir.x;
    final ry = _localDir.y;
    final rz = _localDir.z;

    var nx = 0.0;
    var ny = 0.0;
    var nz = 0.0;
    var hasNormal = false;

    var simplexCount = 0;
    for (var iter = 0; iter < 48; iter++) {
      if (simplexCount == 0) {
        _localSupport(
          xx - _localCenter.x,
          xy - _localCenter.y,
          xz - _localCenter.z,
          _supScratch,
        );
        _sx[0] = _supScratch.x;
        _sy[0] = _supScratch.y;
        _sz[0] = _supScratch.z;
        simplexCount = 1;
      }

      simplexCount = _closestPointOnSimplexToPoint(
        xx,
        xy,
        xz,
        simplexCount,
        _closestScratch,
      );
      final vx = xx - _closestScratch.x;
      final vy = xy - _closestScratch.y;
      final vz = xz - _closestScratch.z;
      final vLen2 = vx * vx + vy * vy + vz * vz;

      if (vLen2 <= 1e-12) {
        if (!hasNormal) {
          return (
            lambda,
            Vector3(-_unitWorldDir.x, -_unitWorldDir.y, -_unitWorldDir.z),
          );
        }
        return (lambda, _transformLocalNormalToWorld(nx, ny, nz));
      }

      _localSupport(vx, vy, vz, _supScratch);
      final wx = _supScratch.x;
      final wy = _supScratch.y;
      final wz = _supScratch.z;

      final vp = vx * (xx - wx) + vy * (xy - wy) + vz * (xz - wz);
      final vr = vx * rx + vy * ry + vz * rz;

      if (vp > 0.0) {
        if (vr >= -1e-12) {
          return null;
        }
        final deltaLambda = vp / (-vr);
        lambda += deltaLambda;
        if (lambda > maxDistance) {
          return null;
        }
        xx = _localOrigin.x + lambda * rx;
        xy = _localOrigin.y + lambda * ry;
        xz = _localOrigin.z + lambda * rz;
        nx = vx;
        ny = vy;
        nz = vz;
        hasNormal = true;
      }

      // Check duplicate support vertex to avoid cycling.
      var duplicate = false;
      for (var i = 0; i < simplexCount; i++) {
        final ex = _sx[i] - wx;
        final ey = _sy[i] - wy;
        final ez = _sz[i] - wz;
        if (ex * ex + ey * ey + ez * ez <= 1e-12) {
          duplicate = true;
          break;
        }
      }
      if (duplicate) {
        if (vp > 1e-8) {
          return null;
        }
        if (!hasNormal) {
          return (lambda, _transformLocalNormalToWorld(vx, vy, vz));
        }
        return (lambda, _transformLocalNormalToWorld(nx, ny, nz));
      }

      if (simplexCount < 4) {
        _sx[simplexCount] = wx;
        _sy[simplexCount] = wy;
        _sz[simplexCount] = wz;
        simplexCount++;
      } else {
        _sx[3] = wx;
        _sy[3] = wy;
        _sz[3] = wz;
      }
    }
    return null;
  }

  /// Diagonal of [computeLocalInertiaTensor] (the tensor of the solid hull
  /// about its center of mass, in the shape's axes).
  @override
  Vector3 computeLocalInertiaDiagonal(double mass, {Vector3? out}) {
    final res = out ?? Vector3.zero();
    if (mass <= 0.0) {
      res.setZero();
      return res;
    }
    final t = _topology;
    if (t != null) {
      final u = t.unitInertia;
      res.setValues(mass * u[0], mass * u[4], mass * u[8]);
      return res;
    }
    final hx = math.max(1e-4, 0.5 * (_localAabb.max.x - _localAabb.min.x));
    final hy = math.max(1e-4, 0.5 * (_localAabb.max.y - _localAabb.min.y));
    final hz = math.max(1e-4, 0.5 * (_localAabb.max.z - _localAabb.min.z));
    final k = mass / 3.0;
    res.setValues(
      k * (hy * hy + hz * hz),
      k * (hx * hx + hz * hz),
      k * (hx * hx + hy * hy),
    );
    return res;
  }

  /// Full inertia tensor of the solid hull of [mass] about its center of
  /// mass, including the products of inertia.
  @override
  Matrix3 computeLocalInertiaTensor(double mass, {Matrix3? out}) {
    final t = _topology;
    if (t == null || mass <= 0.0) {
      return super.computeLocalInertiaTensor(mass, out: out);
    }
    final m = out ?? Matrix3.zero();
    final u = t.unitInertia;
    final st = m.storage;
    for (var i = 0; i < 9; i++) {
      st[i] = mass * u[i];
    }
    return m;
  }

  static final Float64List _sx = Float64List(4);
  static final Float64List _sy = Float64List(4);
  static final Float64List _sz = Float64List(4);
  static final Vector3 _supScratch = Vector3.zero();
  static final Vector3 _closestScratch = Vector3.zero();

  static int _closestPointOnSimplexToPoint(
    double px,
    double py,
    double pz,
    int count,
    Vector3 out,
  ) {
    // Shift simplex by `-p` so we find the closest point to `(0, 0, 0)`.
    if (count == 1) {
      out.setValues(_sx[0], _sy[0], _sz[0]);
      return 1;
    }
    if (count == 2) {
      final ax = _sx[0] - px;
      final ay = _sy[0] - py;
      final az = _sz[0] - pz;
      final bx = _sx[1] - px;
      final by = _sy[1] - py;
      final bz = _sz[1] - pz;
      final abx = bx - ax;
      final aby = by - ay;
      final abz = bz - az;
      final denom = abx * abx + aby * aby + abz * abz;
      if (denom <= 1e-16) {
        out.setValues(_sx[0], _sy[0], _sz[0]);
        return 1;
      }
      final t = -(ax * abx + ay * aby + az * abz) / denom;
      if (t <= 0.0) {
        out.setValues(_sx[0], _sy[0], _sz[0]);
        return 1;
      }
      if (t >= 1.0) {
        _sx[0] = _sx[1];
        _sy[0] = _sy[1];
        _sz[0] = _sz[1];
        out.setValues(_sx[0], _sy[0], _sz[0]);
        return 1;
      }
      out.setValues(
        _sx[0] + t * abx,
        _sy[0] + t * aby,
        _sz[0] + t * abz,
      );
      return 2;
    }
    if (count == 3) {
      return _closestOnTriangleSimplex(px, py, pz, out);
    }
    return _closestOnTetraSimplex(px, py, pz, out);
  }

  static int _closestOnTriangleSimplex(
    double px,
    double py,
    double pz,
    Vector3 out,
  ) {
    final ax = _sx[0] - px;
    final ay = _sy[0] - py;
    final az = _sz[0] - pz;
    final bx = _sx[1] - px;
    final by = _sy[1] - py;
    final bz = _sz[1] - pz;
    final cx = _sx[2] - px;
    final cy = _sy[2] - py;
    final cz = _sz[2] - pz;

    final abx = bx - ax;
    final aby = by - ay;
    final abz = bz - az;
    final acx = cx - ax;
    final acy = cy - ay;
    final acz = cz - az;

    final d1 = -(abx * ax + aby * ay + abz * az);
    final d2 = -(acx * ax + acy * ay + acz * az);
    if (d1 <= 0.0 && d2 <= 0.0) {
      out.setValues(_sx[0], _sy[0], _sz[0]);
      return 1;
    }

    final d3 = -(abx * bx + aby * by + abz * bz);
    final d4 = -(acx * bx + acy * by + acz * bz);
    if (d3 >= 0.0 && d4 <= d3) {
      _sx[0] = _sx[1];
      _sy[0] = _sy[1];
      _sz[0] = _sz[1];
      out.setValues(_sx[0], _sy[0], _sz[0]);
      return 1;
    }

    final vc = d1 * d4 - d3 * d2;
    if (vc <= 0.0 && d1 >= 0.0 && d3 <= 0.0) {
      final v = d1 / (d1 - d3);
      out.setValues(_sx[0] + v * abx, _sy[0] + v * aby, _sz[0] + v * abz);
      return 2;
    }

    final d5 = -(abx * cx + aby * cy + abz * cz);
    final d6 = -(acx * cx + acy * cy + acz * cz);
    if (d6 >= 0.0 && d5 <= d6) {
      _sx[0] = _sx[2];
      _sy[0] = _sy[2];
      _sz[0] = _sz[2];
      out.setValues(_sx[0], _sy[0], _sz[0]);
      return 1;
    }

    final vb = d5 * d2 - d1 * d6;
    if (vb <= 0.0 && d2 >= 0.0 && d6 <= 0.0) {
      final w = d2 / (d2 - d6);
      _sx[1] = _sx[2];
      _sy[1] = _sy[2];
      _sz[1] = _sz[2];
      out.setValues(_sx[0] + w * acx, _sy[0] + w * acy, _sz[0] + w * acz);
      return 2;
    }

    final va = d3 * d6 - d5 * d4;
    if (va <= 0.0 && (d4 - d3) >= 0.0 && (d5 - d6) >= 0.0) {
      final w = (d4 - d3) / ((d4 - d3) + (d5 - d6));
      final bcx = _sx[2] - _sx[1];
      final bcy = _sy[2] - _sy[1];
      final bcz = _sz[2] - _sz[1];
      out.setValues(_sx[1] + w * bcx, _sy[1] + w * bcy, _sz[1] + w * bcz);
      _sx[0] = _sx[1];
      _sy[0] = _sy[1];
      _sz[0] = _sz[1];
      _sx[1] = _sx[2];
      _sy[1] = _sy[2];
      _sz[1] = _sz[2];
      return 2;
    }

    final denom = 1.0 / (va + vb + vc);
    final v = vb * denom;
    final w = vc * denom;
    out.setValues(
      _sx[0] + abx * v + acx * w,
      _sy[0] + aby * v + acy * w,
      _sz[0] + abz * v + acz * w,
    );
    return 3;
  }

  static int _closestOnTetraSimplex(
    double px,
    double py,
    double pz,
    Vector3 out,
  ) {
    // Test whether `(px, py, pz)` lies strictly inside the tetrahedron; if not,
    // pick the closest of the 4 boundary triangles.
    const faces = [
      (0, 1, 2, 3),
      (0, 2, 3, 1),
      (0, 3, 1, 2),
      (1, 3, 2, 0),
    ];
    final tx = Float64List.fromList(_sx);
    final ty = Float64List.fromList(_sy);
    final tz = Float64List.fromList(_sz);

    var bestDist2 = double.infinity;
    var bestCount = 4;
    var bestX = px;
    var bestY = py;
    var bestZ = pz;
    final bestVertsX = Float64List(3);
    final bestVertsY = Float64List(3);
    final bestVertsZ = Float64List(3);
    var outsideAny = false;

    for (final (i0, i1, i2, opp) in faces) {
      final e1x = tx[i1] - tx[i0];
      final e1y = ty[i1] - ty[i0];
      final e1z = tz[i1] - tz[i0];
      final e2x = tx[i2] - tx[i0];
      final e2y = ty[i2] - ty[i0];
      final e2z = tz[i2] - tz[i0];
      final fnx = e1y * e2z - e1z * e2y;
      final fny = e1z * e2x - e1x * e2z;
      final fnz = e1x * e2y - e1y * e2x;

      final signP =
          fnx * (px - tx[i0]) + fny * (py - ty[i0]) + fnz * (pz - tz[i0]);
      final signOpp =
          fnx * (tx[opp] - tx[i0]) +
          fny * (ty[opp] - ty[i0]) +
          fnz * (tz[opp] - tz[i0]);

      if (signP * signOpp <= 0.0) {
        outsideAny = true;
        _sx[0] = tx[i0];
        _sy[0] = ty[i0];
        _sz[0] = tz[i0];
        _sx[1] = tx[i1];
        _sy[1] = ty[i1];
        _sz[1] = tz[i1];
        _sx[2] = tx[i2];
        _sy[2] = ty[i2];
        _sz[2] = tz[i2];
        final cnt = _closestOnTriangleSimplex(px, py, pz, out);
        final dx = out.x - px;
        final dy = out.y - py;
        final dz = out.z - pz;
        final d2 = dx * dx + dy * dy + dz * dz;
        if (d2 < bestDist2) {
          bestDist2 = d2;
          bestCount = cnt;
          bestX = out.x;
          bestY = out.y;
          bestZ = out.z;
          for (var k = 0; k < cnt; k++) {
            bestVertsX[k] = _sx[k];
            bestVertsY[k] = _sy[k];
            bestVertsZ[k] = _sz[k];
          }
        }
      }
    }

    if (!outsideAny) {
      for (var k = 0; k < 4; k++) {
        _sx[k] = tx[k];
        _sy[k] = ty[k];
        _sz[k] = tz[k];
      }
      out.setValues(px, py, pz);
      return 4;
    }

    for (var k = 0; k < bestCount; k++) {
      _sx[k] = bestVertsX[k];
      _sy[k] = bestVertsY[k];
      _sz[k] = bestVertsZ[k];
    }
    out.setValues(bestX, bestY, bestZ);
    return bestCount;
  }
}

/// Child shape entry inside a [CompoundShape3D] with its local [position],
/// [rotation], and optional relative [massWeight].
class CompoundChildShape3D({
  required final CollisionShape3D shape,
  Vector3? position,
  Quaternion? rotation,
  final double massWeight = 1.0,
}) {
  this : assert(massWeight >= 0, 'massWeight must be non-negative') {
    if (this.rotation.length2 > 1e-12) {
      this.rotation.normalize();
    } else {
      this.rotation.setValues(0.0, 0.0, 0.0, 1.0);
    }
    localTransform.setFromTranslationRotationScale(
      this.position,
      this.rotation,
      _unitScaleVec,
    );
    shape.computeWorldAabb(localTransform, localAabb);
  }

  /// Local translation of [shape] inside the parent [CompoundShape3D].
  final Vector3 position = position?.clone() ?? Vector3.zero();

  /// Local rotation of [shape] inside the parent [CompoundShape3D].
  final Quaternion rotation = rotation?.clone() ?? Quaternion.identity();

  /// Precomputed `4x4` local transform combining [position] and [rotation].
  final Matrix4 localTransform = Matrix4.identity();

  /// Precomputed local-space AABB of this child inside the compound frame.
  final Aabb3 localAabb = Aabb3();

  static final Vector3 _unitScaleVec = Vector3.all(1.0);
}

/// Composite 3D collision shape formed from one or more [CompoundChildShape3D]
/// sub-shapes, supporting concave rigid bodies with exact composite AABB,
/// raycasting, narrowphase contact generation, and Huygens–Steiner
/// parallel-axis center-of-mass and inertia tensor calculation.
class CompoundShape3D(List<CompoundChildShape3D> children) extends Shape3D {
  this : assert(children.isNotEmpty, 'CompoundShape3D requires >= 1 child') {
    _localAabb
      ..min.setFrom(this.children.first.localAabb.min)
      ..max.setFrom(this.children.first.localAabb.max);
    for (var i = 1; i < this.children.length; i++) {
      _localAabb.hull(this.children[i].localAabb);
    }

    var totalW = 0.0;
    var sumVolume = 0.0;
    final rotCom = Vector3.zero();
    for (var i = 0; i < this.children.length; i++) {
      final c = this.children[i];
      final vol = math.max(1e-6, c.shape.estimateLocalVolume());
      sumVolume += vol;
      final w = vol * c.massWeight;
      _childWeights[i] = w;
      totalW += w;

      // `localTransform` rotates like `asRotationMatrix()`; vector_math's
      // `Quaternion.rotate` would apply the inverse rotation.
      c.localTransform.rotate3(rotCom..setFrom(c.shape.localCenterOfMass));
      final cx = c.position.x + rotCom.x;
      final cy = c.position.y + rotCom.y;
      final cz = c.position.z + rotCom.z;
      _childComCoords[i * 3] = cx;
      _childComCoords[i * 3 + 1] = cy;
      _childComCoords[i * 3 + 2] = cz;
    }

    _totalVolume = sumVolume;
    if (totalW > 1e-12) {
      var comX = 0.0;
      var comY = 0.0;
      var comZ = 0.0;
      for (var i = 0; i < this.children.length; i++) {
        final frac = _childWeights[i] / totalW;
        _childWeights[i] = frac;
        comX += frac * _childComCoords[i * 3];
        comY += frac * _childComCoords[i * 3 + 1];
        comZ += frac * _childComCoords[i * 3 + 2];
      }
      _centerOfMass.setValues(comX, comY, comZ);
    } else {
      final frac = 1.0 / this.children.length;
      for (var i = 0; i < this.children.length; i++) {
        _childWeights[i] = frac;
      }
      _centerOfMass.setZero();
    }
  }

  /// Immutable list of child shapes in local space.
  final List<CompoundChildShape3D> children = List.unmodifiable(children);

  final Aabb3 _localAabb = Aabb3();
  final Vector3 _centerOfMass = Vector3.zero();
  final Float64List _childWeights = Float64List(children.length);
  final Float64List _childComCoords = Float64List(children.length * 3);
  double _totalVolume = 0.0;

  /// Volume-weighted composite center-of-mass offset in local space.
  Vector3 get centerOfMass => _centerOfMass;

  @override
  Vector3 get localCenterOfMass => _centerOfMass;

  @override
  double get inscribedSphereRadius {
    var best = double.infinity;
    for (var i = 0; i < children.length; i++) {
      final r = children[i].shape.inscribedSphereRadius;
      if (r > 0.0 && r < best) {
        best = r;
      }
    }
    return best.isFinite ? best : 0.05;
  }

  @override
  double estimateLocalVolume() => _totalVolume;

  @override
  Aabb3 computeLocalAabb({Aabb3? out}) {
    final box = out ?? Aabb3();
    box.min.setFrom(_localAabb.min);
    box.max.setFrom(_localAabb.max);
    return box;
  }

  @override
  void computeWorldAabb(Matrix4 worldTransform, Aabb3 out) {
    final childMat = Matrix4.identity();
    final childBox = Aabb3();
    for (var i = 0; i < children.length; i++) {
      final c = children[i];
      childMat
        ..setFrom(worldTransform)
        ..multiply(c.localTransform);
      c.shape.computeWorldAabb(childMat, childBox);
      if (i == 0) {
        out.min.setFrom(childBox.min);
        out.max.setFrom(childBox.max);
      } else {
        out.hull(childBox);
      }
    }
  }

  @override
  void supportPoint(Vector3 worldDir, Matrix4 worldTransform, Vector3 out) {
    final childMat = Matrix4.identity();
    final cand = Vector3.zero();
    var bestDot = double.negativeInfinity;
    for (var i = 0; i < children.length; i++) {
      final c = children[i];
      childMat
        ..setFrom(worldTransform)
        ..multiply(c.localTransform);
      c.shape.supportPoint(worldDir, childMat, cand);
      final d = cand.dot(worldDir);
      if (d > bestDot) {
        bestDot = d;
        out.setFrom(cand);
      }
    }
  }

  @override
  (double distance, Vector3 normal)? raycast(
    Ray worldRay,
    Matrix4 worldTransform, {
    double maxDistance = double.infinity,
  }) {
    if (!(maxDistance >= 0.0)) {
      return null;
    }
    final childMat = Matrix4.identity();
    var limit = maxDistance;
    (double, Vector3)? best;
    for (var i = 0; i < children.length; i++) {
      final c = children[i];
      childMat
        ..setFrom(worldTransform)
        ..multiply(c.localTransform);
      final hit = c.shape.raycast(worldRay, childMat, maxDistance: limit);
      if (hit != null && hit.$1 <= limit) {
        limit = hit.$1;
        best = hit;
      }
    }
    return best;
  }

  /// Computes the exact `3x3` symmetric inertia tensor using the
  /// **Huygens–Steiner parallel-axis theorem**:
  /// `I_total = sum(R_i I_i R_i^T + m_i ((d_i . d_i) E - d_i (x) d_i))`.
  @override
  Matrix3 computeLocalInertiaTensor(
    double mass, {
    Matrix3? out,
    bool aboutCenterOfMass = true,
  }) {
    final res = out ?? Matrix3.zero();
    res.setZero();
    if (mass <= 0.0) {
      return res;
    }

    final refX = aboutCenterOfMass ? _centerOfMass.x : 0.0;
    final refY = aboutCenterOfMass ? _centerOfMass.y : 0.0;
    final refZ = aboutCenterOfMass ? _centerOfMass.z : 0.0;

    final childI = Matrix3.zero();
    final rotMat = Matrix3.zero();
    final temp = Matrix3.zero();
    final rotT = Matrix3.zero();
    final s = res.storage;

    for (var i = 0; i < children.length; i++) {
      final child = children[i];
      final mI = mass * _childWeights[i];
      if (mI <= 0.0) {
        continue;
      }
      child.shape.computeLocalInertiaTensor(mI, out: childI);
      rotMat.setFrom(child.rotation.asRotationMatrix());
      rotT
        ..setFrom(rotMat)
        ..transpose();
      // `temp = rotMat * childI * rotMat^T`.
      temp
        ..setFrom(rotMat)
        ..multiply(childI)
        ..multiply(rotT);

      final dx = _childComCoords[i * 3] - refX;
      final dy = _childComCoords[i * 3 + 1] - refY;
      final dz = _childComCoords[i * 3 + 2] - refZ;
      final d2 = dx * dx + dy * dy + dz * dz;

      final ts = temp.storage;
      s[0] += ts[0] + mI * (d2 - dx * dx);
      s[1] += ts[1] - mI * dy * dx;
      s[2] += ts[2] - mI * dz * dx;
      s[3] += ts[3] - mI * dx * dy;
      s[4] += ts[4] + mI * (d2 - dy * dy);
      s[5] += ts[5] - mI * dz * dy;
      s[6] += ts[6] - mI * dx * dz;
      s[7] += ts[7] - mI * dy * dz;
      s[8] += ts[8] + mI * (d2 - dz * dz);
    }
    return res;
  }

  @override
  Vector3 computeLocalInertiaDiagonal(double mass, {Vector3? out}) {
    final res = out ?? Vector3.zero();
    if (mass <= 0.0) {
      res.setZero();
      return res;
    }
    computeLocalInertiaTensor(mass, out: _tensorScratch);
    final s = _tensorScratch.storage;
    res.setValues(s[0], s[4], s[8]);
    return res;
  }

  static final Matrix3 _tensorScratch = Matrix3.zero();
}

/// Analytical 3D `columns x rows` grid heightfield collision shape spanning
/// `[-width * 0.5 .. +width * 0.5]` along `X` and
/// `[-depth * 0.5 .. +depth * 0.5]` along `Z`, with `O(1)` grid-cell contact
/// lookup, piecewise-linear [sampleHeight], and 2D grid-DDA [raycast].
class HeightfieldShape3D({
  required Float32List heights,
  required final int columns,
  required final int rows,
  required final double width,
  required final double depth,
  final double heightScale = 1.0,
}) extends Shape3D {
  this
    : assert(columns >= 2 && rows >= 2, 'grid must be at least 2x2'),
      assert(width > 0 && depth > 0, 'width and depth must be positive'),
      assert(
        heights.length == columns * rows,
        'heights length must equal columns * rows',
      ) {
    var minH = double.infinity;
    var maxH = double.negativeInfinity;
    for (var i = 0; i < this.heights.length; i++) {
      final h = this.heights[i] * heightScale;
      if (h < minH) {
        minH = h;
      }
      if (h > maxH) {
        maxH = h;
      }
    }
    _minY = minH.isFinite ? minH : 0.0;
    _maxY = maxH.isFinite ? maxH : 0.0;
  }

  /// Immutable copy of the `columns * rows` raw height grid.
  final Float32List heights = Float32List.fromList(heights);

  late final double _minY;
  late final double _maxY;

  /// Cell width along `X` (`width / (columns - 1)`).
  double get cellWidth => width / (columns - 1);

  /// Cell depth along `Z` (`depth / (rows - 1)`).
  double get cellDepth => depth / (rows - 1);

  /// Minimum scaled local `Y` elevation across the heightfield.
  double get minHeight => _minY;

  /// Maximum scaled local `Y` elevation across the heightfield.
  double get maxHeight => _maxY;

  @override
  double get inscribedSphereRadius => 0.0;

  @override
  double estimateLocalVolume() =>
      width * depth * math.max(0.1, _maxY - _minY + 0.1);

  /// Returns the scaled elevation at grid vertex `(col, row)`.
  double vertexHeight(int col, int row) {
    final c = col.clamp(0, columns - 1);
    final r = row.clamp(0, rows - 1);
    return heights[r * columns + c] * heightScale;
  }

  /// Samples the exact piecewise-linear two-triangle surface height at local
  /// `(x, z)` coordinates (clamped to the heightfield footprint).
  double sampleHeight(double x, double z) {
    final halfW = width * 0.5;
    final halfD = depth * 0.5;
    final fx = ((x + halfW) / width * (columns - 1)).clamp(0.0, columns - 1.0);
    final fz = ((z + halfD) / depth * (rows - 1)).clamp(0.0, rows - 1.0);
    final c = fx.floor().clamp(0, columns - 2);
    final r = fz.floor().clamp(0, rows - 2);
    final tx = (fx - c).clamp(0.0, 1.0);
    final tz = (fz - r).clamp(0.0, 1.0);

    final h00 = heights[r * columns + c] * heightScale;
    final h10 = heights[r * columns + c + 1] * heightScale;
    final h01 = heights[(r + 1) * columns + c] * heightScale;
    final h11 = heights[(r + 1) * columns + c + 1] * heightScale;

    // Matches `TerrainMesh3D` diagonal `(v00 -> v11)`:
    // Triangle 0 `(v00, v01, v11)` covers `tz >= tx`;
    // Triangle 1 `(v00, v11, v10)` covers `tx > tz`.
    if (tz >= tx) {
      return h00 + tz * (h01 - h00) + tx * (h11 - h01);
    }
    return h00 + tx * (h10 - h00) + tz * (h11 - h10);
  }

  /// Computes the unit upward surface normal of the active triangle at local
  /// `(x, z)`.
  Vector3 sampleNormal(double x, double z, {Vector3? out}) {
    final res = out ?? Vector3.zero();
    final halfW = width * 0.5;
    final halfD = depth * 0.5;
    final fx = ((x + halfW) / width * (columns - 1)).clamp(0.0, columns - 1.0);
    final fz = ((z + halfD) / depth * (rows - 1)).clamp(0.0, rows - 1.0);
    final c = fx.floor().clamp(0, columns - 2);
    final r = fz.floor().clamp(0, rows - 2);
    final tx = fx - c;
    final tz = fz - r;

    writeCellVerticesLocal(c, r, _v00, _v01, _v11, _v10);
    if (tz >= tx) {
      _triangleNormal(_v00, _v01, _v11, res);
    } else {
      _triangleNormal(_v00, _v11, _v10, res);
    }
    return res;
  }

  /// Clamps a local `[minX..maxX, minZ..maxZ]` footprint in `O(1)` to
  /// overlapping grid cell indices `(c0, c1, r0, r1)`, or `null` when
  /// horizontally disjoint.
  (int c0, int c1, int r0, int r1)? cellRangeForLocalBounds(
    double minX,
    double maxX,
    double minZ,
    double maxZ,
  ) {
    final halfW = width * 0.5;
    final halfD = depth * 0.5;
    if (maxX < -halfW || minX > halfW || maxZ < -halfD || minZ > halfD) {
      return null;
    }
    final invCw = (columns - 1) / width;
    final invCd = (rows - 1) / depth;
    final c0 = ((minX + halfW) * invCw).floor().clamp(0, columns - 2);
    final c1 = ((maxX + halfW) * invCw).floor().clamp(0, columns - 2);
    final r0 = ((minZ + halfD) * invCd).floor().clamp(0, rows - 2);
    final r1 = ((maxZ + halfD) * invCd).floor().clamp(0, rows - 2);
    return (c0, c1, r0, r1);
  }

  /// Writes the 4 local-space corner positions `(v00, v01, v11, v10)` of grid
  /// cell `(col, row)`, where Triangle 0 is `(v00, v01, v11)` and Triangle 1 is
  /// `(v00, v11, v10)` (CCW when viewed from `+Y`).
  void writeCellVerticesLocal(
    int col,
    int row,
    Vector3 v00,
    Vector3 v01,
    Vector3 v11,
    Vector3 v10,
  ) {
    final cw = width / (columns - 1);
    final cd = depth / (rows - 1);
    final x0 = -width * 0.5 + col * cw;
    final x1 = x0 + cw;
    final z0 = -depth * 0.5 + row * cd;
    final z1 = z0 + cd;
    final r0 = row * columns;
    final r1 = (row + 1) * columns;
    v00.setValues(x0, heights[r0 + col] * heightScale, z0);
    v10.setValues(x1, heights[r0 + col + 1] * heightScale, z0);
    v01.setValues(x0, heights[r1 + col] * heightScale, z1);
    v11.setValues(x1, heights[r1 + col + 1] * heightScale, z1);
  }

  @override
  Aabb3 computeLocalAabb({Aabb3? out}) {
    final box = out ?? Aabb3();
    final halfW = width * 0.5;
    final halfD = depth * 0.5;
    box.min.setValues(-halfW, _minY, -halfD);
    box.max.setValues(halfW, _maxY, halfD);
    return box;
  }

  @override
  void computeWorldAabb(Matrix4 worldTransform, Aabb3 out) {
    final m = worldTransform.storage;
    final hx = width * 0.5;
    final hz = depth * 0.5;
    final midY = 0.5 * (_minY + _maxY);
    final hy = math.max(1e-4, 0.5 * (_maxY - _minY));

    final cx = m[4] * midY + m[12];
    final cy = m[5] * midY + m[13];
    final cz = m[6] * midY + m[14];

    final ex = m[0].abs() * hx + m[4].abs() * hy + m[8].abs() * hz;
    final ey = m[1].abs() * hx + m[5].abs() * hy + m[9].abs() * hz;
    final ez = m[2].abs() * hx + m[6].abs() * hy + m[10].abs() * hz;
    out.min.setValues(cx - ex, cy - ey, cz - ez);
    out.max.setValues(cx + ex, cy + ey, cz + ez);
  }

  @override
  void supportPoint(Vector3 worldDir, Matrix4 worldTransform, Vector3 out) {
    // Evaluate over the local bounding box corners when queried conservatively.
    final m = worldTransform.storage;
    final dx = worldDir.x;
    final dy = worldDir.y;
    final dz = worldDir.z;
    final halfW = width * 0.5;
    final halfD = depth * 0.5;
    final lx = m[0] * dx + m[1] * dy + m[2] * dz >= 0.0 ? halfW : -halfW;
    final ly = m[4] * dx + m[5] * dy + m[6] * dz >= 0.0 ? _maxY : _minY;
    final lz = m[8] * dx + m[9] * dy + m[10] * dz >= 0.0 ? halfD : -halfD;
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
    final ox = _localOrigin.x;
    final oy = _localOrigin.y;
    final oz = _localOrigin.z;
    final dx = _localDir.x;
    final dy = _localDir.y;
    final dz = _localDir.z;

    final halfW = width * 0.5;
    final halfD = depth * 0.5;

    // 1. Clip `[0, maxDistance]` against the local heightfield AABB.
    var tEntry = 0.0;
    var tExit = maxDistance;

    bool clipSlab(double o, double d, double lo, double hi) {
      if (d.abs() < 1e-12) {
        return o >= lo - 1e-5 && o <= hi + 1e-5;
      }
      final inv = 1.0 / d;
      var t1 = (lo - 1e-5 - o) * inv;
      var t2 = (hi + 1e-5 - o) * inv;
      if (t1 > t2) {
        final s = t1;
        t1 = t2;
        t2 = s;
      }
      if (t1 > tEntry) {
        tEntry = t1;
      }
      if (t2 < tExit) {
        tExit = t2;
      }
      return tEntry <= tExit;
    }

    if (!clipSlab(ox, dx, -halfW, halfW) ||
        !clipSlab(oy, dy, _minY - 1e-3, _maxY + 1e-3) ||
        !clipSlab(oz, dz, -halfD, halfD)) {
      return null;
    }

    // 2. 2D Amanatides & Woo Grid-DDA across `(col, row)` cells.
    final cw = width / (columns - 1);
    final cd = depth / (rows - 1);
    final invCw = 1.0 / cw;
    final invCd = 1.0 / cd;

    var tCur = math.max(0.0, tEntry);
    var tStop = tExit;

    final startX = ox + dx * tCur;
    final startZ = oz + dz * tCur;
    var c = ((startX + halfW) * invCw).floor().clamp(0, columns - 2);
    var r = ((startZ + halfD) * invCd).floor().clamp(0, rows - 2);

    final int stepC;
    double tMaxX;
    final double tDeltaX;
    if (dx > 1e-12) {
      stepC = 1;
      final nextX = -halfW + (c + 1) * cw;
      tMaxX = tCur + (nextX - startX) / dx;
      tDeltaX = cw / dx;
    } else if (dx < -1e-12) {
      stepC = -1;
      final nextX = -halfW + c * cw;
      tMaxX = tCur + (nextX - startX) / dx;
      tDeltaX = -cw / dx;
    } else {
      stepC = 0;
      tMaxX = double.infinity;
      tDeltaX = double.infinity;
    }

    final int stepR;
    double tMaxZ;
    final double tDeltaZ;
    if (dz > 1e-12) {
      stepR = 1;
      final nextZ = -halfD + (r + 1) * cd;
      tMaxZ = tCur + (nextZ - startZ) / dz;
      tDeltaZ = cd / dz;
    } else if (dz < -1e-12) {
      stepR = -1;
      final nextZ = -halfD + r * cd;
      tMaxZ = tCur + (nextZ - startZ) / dz;
      tDeltaZ = -cd / dz;
    } else {
      stepR = 0;
      tMaxZ = double.infinity;
      tDeltaZ = double.infinity;
    }

    var bestT = double.infinity;
    var bestNx = 0.0;
    var bestNy = 1.0;
    var bestNz = 0.0;

    while (c >= 0 &&
        c <= columns - 2 &&
        r >= 0 &&
        r <= rows - 2 &&
        tCur <= tStop + 1e-5) {
      final tCellEnd = math.min(tStop, math.min(tMaxX, tMaxZ));
      final ry0 = oy + dy * tCur;
      final ry1 = oy + dy * tCellEnd;
      final segMinY = math.min(ry0, ry1) - 1e-4;
      final segMaxY = math.max(ry0, ry1) + 1e-4;

      writeCellVerticesLocal(c, r, _v00, _v01, _v11, _v10);
      final cellMinY = math.min(
        math.min(_v00.y, _v01.y),
        math.min(_v11.y, _v10.y),
      );
      final cellMaxY = math.max(
        math.max(_v00.y, _v01.y),
        math.max(_v11.y, _v10.y),
      );

      if (segMaxY >= cellMinY && segMinY <= cellMaxY) {
        final t0 = _rayTriangleLocal(ox, oy, oz, dx, dy, dz, _v00, _v01, _v11);
        if (t0 != null && t0 >= 0.0 && t0 < bestT && t0 <= maxDistance) {
          bestT = t0;
          _triangleNormal(_v00, _v01, _v11, _nrmScratch);
          bestNx = _nrmScratch.x;
          bestNy = _nrmScratch.y;
          bestNz = _nrmScratch.z;
          if (bestT < tStop) {
            tStop = bestT;
          }
        }
        final t1 = _rayTriangleLocal(ox, oy, oz, dx, dy, dz, _v00, _v11, _v10);
        if (t1 != null && t1 >= 0.0 && t1 < bestT && t1 <= maxDistance) {
          bestT = t1;
          _triangleNormal(_v00, _v11, _v10, _nrmScratch);
          bestNx = _nrmScratch.x;
          bestNy = _nrmScratch.y;
          bestNz = _nrmScratch.z;
          if (bestT < tStop) {
            tStop = bestT;
          }
        }
        if (bestT <= tCellEnd + 1e-5) {
          break;
        }
      }

      if (tMaxX < tMaxZ) {
        tCur = tMaxX;
        tMaxX += tDeltaX;
        c += stepC;
      } else {
        tCur = tMaxZ;
        tMaxZ += tDeltaZ;
        r += stepR;
      }
    }

    if (!bestT.isFinite) {
      return null;
    }
    return (bestT, _transformLocalNormalToWorld(bestNx, bestNy, bestNz));
  }

  @override
  Vector3 computeLocalInertiaDiagonal(double mass, {Vector3? out}) {
    final res = out ?? Vector3.zero();
    res.setZero();
    return res;
  }

  static double? _rayTriangleLocal(
    double ox,
    double oy,
    double oz,
    double dx,
    double dy,
    double dz,
    Vector3 a,
    Vector3 b,
    Vector3 c,
  ) {
    final e1x = b.x - a.x;
    final e1y = b.y - a.y;
    final e1z = b.z - a.z;
    final e2x = c.x - a.x;
    final e2y = c.y - a.y;
    final e2z = c.z - a.z;

    final px = dy * e2z - dz * e2y;
    final py = dz * e2x - dx * e2z;
    final pz = dx * e2y - dy * e2x;
    final det = e1x * px + e1y * py + e1z * pz;
    if (det.abs() <= 1e-12) {
      return null;
    }
    final invDet = 1.0 / det;

    final tx = ox - a.x;
    final ty = oy - a.y;
    final tz = oz - a.z;
    final u = (tx * px + ty * py + tz * pz) * invDet;
    if (u < -1e-6 || u > 1.0 + 1e-6) {
      return null;
    }

    final qx = ty * e1z - tz * e1y;
    final qy = tz * e1x - tx * e1z;
    final qz = tx * e1y - ty * e1x;
    final v = (dx * qx + dy * qy + dz * qz) * invDet;
    if (v < -1e-6 || u + v > 1.0 + 1e-6) {
      return null;
    }

    final t = (e2x * qx + e2y * qy + e2z * qz) * invDet;
    return t >= 0.0 ? t : null;
  }

  static void _triangleNormal(Vector3 a, Vector3 b, Vector3 c, Vector3 out) {
    final e1x = b.x - a.x;
    final e1y = b.y - a.y;
    final e1z = b.z - a.z;
    final e2x = c.x - a.x;
    final e2y = c.y - a.y;
    final e2z = c.z - a.z;
    final nx = e1y * e2z - e1z * e2y;
    final ny = e1z * e2x - e1x * e2z;
    final nz = e1x * e2y - e1y * e2x;
    final len = math.sqrt(nx * nx + ny * ny + nz * nz);
    if (len > 1e-12) {
      out.setValues(nx / len, ny / len, nz / len);
    } else {
      out.setValues(0.0, 1.0, 0.0);
    }
  }

  static final Vector3 _v00 = Vector3.zero();
  static final Vector3 _v01 = Vector3.zero();
  static final Vector3 _v11 = Vector3.zero();
  static final Vector3 _v10 = Vector3.zero();
  static final Vector3 _nrmScratch = Vector3.zero();
}

final Matrix4 _invTransform = Matrix4.identity();
final Vector3 _unitWorldDir = Vector3.zero();
final Vector3 _localOrigin = Vector3.zero();
final Vector3 _localDir = Vector3.zero();

bool _prepareLocalRay(
  Ray worldRay,
  Matrix4 worldTransform,
  double maxDistance,
) {
  if (!(maxDistance >= 0.0)) {
    return false;
  }
  final dirLen = worldRay.direction.length;
  if (dirLen <= 1e-12) {
    return false;
  }
  final invLen = 1.0 / dirLen;
  final wx = worldRay.direction.x * invLen;
  final wy = worldRay.direction.y * invLen;
  final wz = worldRay.direction.z * invLen;
  _unitWorldDir.setValues(wx, wy, wz);

  _invTransform.setFrom(worldTransform);
  final det = _invTransform.invert();
  if (det.abs() < 1e-15) {
    return false;
  }
  final m = _invTransform.storage;
  final ox = worldRay.origin.x;
  final oy = worldRay.origin.y;
  final oz = worldRay.origin.z;
  _localOrigin.setValues(
    m[0] * ox + m[4] * oy + m[8] * oz + m[12],
    m[1] * ox + m[5] * oy + m[9] * oz + m[13],
    m[2] * ox + m[6] * oy + m[10] * oz + m[14],
  );
  _localDir.setValues(
    m[0] * wx + m[4] * wy + m[8] * wz,
    m[1] * wx + m[5] * wy + m[9] * wz,
    m[2] * wx + m[6] * wy + m[10] * wz,
  );
  return true;
}

Vector3 _transformLocalNormalToWorld(double lnx, double lny, double lnz) {
  final m = _invTransform.storage;
  var wnx = m[0] * lnx + m[1] * lny + m[2] * lnz;
  var wny = m[4] * lnx + m[5] * lny + m[6] * lnz;
  var wnz = m[8] * lnx + m[9] * lny + m[10] * lnz;
  final len = math.sqrt(wnx * wnx + wny * wny + wnz * wnz);
  if (len > 1e-12) {
    wnx /= len;
    wny /= len;
    wnz /= len;
  }
  return Vector3(wnx, wny, wnz);
}

/// Polygonal topology and mass properties of a convex hull, built once from a
/// point cloud by an incremental (quickhull-style) construction.
///
/// Faces are convex polygons whose vertices run counter-clockwise around the
/// outward normal; coplanar triangles are merged into one face.
class _HullTopology3D._({
  required final Float64List coords,
  required final Int32List sourceIndex,
  required final Int32List faceStart,
  required final Int32List faceVerts,
  required final Float64List faceNormals,
  required final Float64List faceOffsets,
  required final double volume,
  required final Vector3 centerOfMass,
  required final Float64List unitInertia,
  required final double inscribedRadius,
}) {
  int get faceCount => faceOffsets.length;

  /// Builds the topology of the hull of [input], or returns `null` when the
  /// points are degenerate (fewer than four, collinear or coplanar).
  static _HullTopology3D? build(List<Vector3> input) {
    if (input.length < 4) {
      return null;
    }
    var minX = double.infinity;
    var minY = double.infinity;
    var minZ = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    var maxZ = double.negativeInfinity;
    for (final v in input) {
      minX = math.min(minX, v.x);
      minY = math.min(minY, v.y);
      minZ = math.min(minZ, v.z);
      maxX = math.max(maxX, v.x);
      maxY = math.max(maxY, v.y);
      maxZ = math.max(maxZ, v.z);
    }
    final scale = math.max(maxX - minX, math.max(maxY - minY, maxZ - minZ));
    if (!scale.isFinite || scale <= 0.0) {
      return null;
    }
    // Vertices are stored as 32-bit floats: points closer than this to a plane
    // count as lying on it.
    final tol = scale * 1e-6;
    final tol2 = tol * tol;

    // 1. Unique points.
    final px = <double>[];
    final py = <double>[];
    final pz = <double>[];
    final src = <int>[];
    for (var i = 0; i < input.length; i++) {
      final v = input[i];
      var dup = false;
      for (var k = 0; k < px.length; k++) {
        final dx = px[k] - v.x;
        final dy = py[k] - v.y;
        final dz = pz[k] - v.z;
        if (dx * dx + dy * dy + dz * dz <= tol2) {
          dup = true;
          break;
        }
      }
      if (!dup) {
        px.add(v.x);
        py.add(v.y);
        pz.add(v.z);
        src.add(i);
      }
    }
    final n = px.length;
    if (n < 4) {
      return null;
    }

    // 2. Initial tetrahedron from extreme points.
    final ex = maxX - minX;
    final ey = maxY - minY;
    final ez = maxZ - minZ;
    final axisVals = ex >= ey && ex >= ez ? px : (ey >= ez ? py : pz);
    var i0 = 0;
    var i1 = 0;
    for (var i = 1; i < n; i++) {
      if (axisVals[i] < axisVals[i0]) {
        i0 = i;
      }
      if (axisVals[i] > axisVals[i1]) {
        i1 = i;
      }
    }
    if (i0 == i1) {
      return null;
    }
    final lx = px[i1] - px[i0];
    final ly = py[i1] - py[i0];
    final lz = pz[i1] - pz[i0];
    final lLen2 = lx * lx + ly * ly + lz * lz;
    var i2 = -1;
    var bestLine = tol2;
    for (var i = 0; i < n; i++) {
      final wx = px[i] - px[i0];
      final wy = py[i] - py[i0];
      final wz = pz[i] - pz[i0];
      final cx = wy * lz - wz * ly;
      final cy = wz * lx - wx * lz;
      final cz = wx * ly - wy * lx;
      final d2 = (cx * cx + cy * cy + cz * cz) / lLen2;
      if (d2 > bestLine) {
        bestLine = d2;
        i2 = i;
      }
    }
    if (i2 < 0) {
      return null;
    }
    var pnx = ly * (pz[i2] - pz[i0]) - lz * (py[i2] - py[i0]);
    var pny = lz * (px[i2] - px[i0]) - lx * (pz[i2] - pz[i0]);
    var pnz = lx * (py[i2] - py[i0]) - ly * (px[i2] - px[i0]);
    final pnLen = math.sqrt(pnx * pnx + pny * pny + pnz * pnz);
    pnx /= pnLen;
    pny /= pnLen;
    pnz /= pnLen;
    var i3 = -1;
    var bestPlane = tol;
    for (var i = 0; i < n; i++) {
      final d =
          ((px[i] - px[i0]) * pnx +
                  (py[i] - py[i0]) * pny +
                  (pz[i] - pz[i0]) * pnz)
              .abs();
      if (d > bestPlane) {
        bestPlane = d;
        i3 = i;
      }
    }
    if (i3 < 0) {
      return null;
    }

    // Face storage (triangles) and directed-edge adjacency.
    final fa = <int>[];
    final fb = <int>[];
    final fc = <int>[];
    final fnx = <double>[];
    final fny = <double>[];
    final fnz = <double>[];
    final fd = <double>[];
    final alive = <bool>[];
    final outside = <List<int>?>[];
    final mark = <int>[];
    final edgeFace = <int, int>{};

    double dist(int f, int p) =>
        fnx[f] * px[p] + fny[f] * py[p] + fnz[f] * pz[p] - fd[f];

    int addFace(int a, int b, int c) {
      final abx = px[b] - px[a];
      final aby = py[b] - py[a];
      final abz = pz[b] - pz[a];
      final acx = px[c] - px[a];
      final acy = py[c] - py[a];
      final acz = pz[c] - pz[a];
      var nx = aby * acz - abz * acy;
      var ny = abz * acx - abx * acz;
      var nz = abx * acy - aby * acx;
      final len = math.sqrt(nx * nx + ny * ny + nz * nz);
      if (len > 0.0) {
        nx /= len;
        ny /= len;
        nz /= len;
      }
      final idx = fa.length;
      fa.add(a);
      fb.add(b);
      fc.add(c);
      fnx.add(nx);
      fny.add(ny);
      fnz.add(nz);
      fd.add(nx * px[a] + ny * py[a] + nz * pz[a]);
      alive.add(true);
      outside.add(null);
      mark.add(0);
      edgeFace[a * n + b] = idx;
      edgeFace[b * n + c] = idx;
      edgeFace[c * n + a] = idx;
      return idx;
    }

    void addOriented(int a, int b, int c, int opposite) {
      final abx = px[b] - px[a];
      final aby = py[b] - py[a];
      final abz = pz[b] - pz[a];
      final acx = px[c] - px[a];
      final acy = py[c] - py[a];
      final acz = pz[c] - pz[a];
      final nx = aby * acz - abz * acy;
      final ny = abz * acx - abx * acz;
      final nz = abx * acy - aby * acx;
      final side =
          nx * (px[opposite] - px[a]) +
          ny * (py[opposite] - py[a]) +
          nz * (pz[opposite] - pz[a]);
      if (side > 0.0) {
        addFace(a, c, b);
      } else {
        addFace(a, b, c);
      }
    }

    addOriented(i0, i1, i2, i3);
    addOriented(i0, i1, i3, i2);
    addOriented(i0, i2, i3, i1);
    addOriented(i1, i2, i3, i0);

    bool assign(int p, int firstFace) {
      var best = -1;
      var bestD = tol;
      for (var f = firstFace; f < fa.length; f++) {
        if (!alive[f]) {
          continue;
        }
        final d = dist(f, p);
        if (d > bestD) {
          bestD = d;
          best = f;
        }
      }
      if (best < 0) {
        return false;
      }
      (outside[best] ??= <int>[]).add(p);
      return true;
    }

    for (var p = 0; p < n; p++) {
      if (p != i0 && p != i1 && p != i2 && p != i3) {
        assign(p, 0);
      }
    }

    // 3. Incremental expansion, farthest point first.
    var stamp = 0;
    var guard = 0;
    final visible = <int>[];
    final stack = <int>[];
    final horizonU = <int>[];
    final horizonV = <int>[];
    final orphans = <int>[];
    while (true) {
      var f0 = -1;
      for (var f = 0; f < fa.length; f++) {
        if (alive[f] && (outside[f]?.isNotEmpty ?? false)) {
          f0 = f;
          break;
        }
      }
      if (f0 < 0) {
        break;
      }
      if (++guard > 4 * n + 64) {
        return null;
      }
      final pts = outside[f0]!;
      var p = pts[0];
      var pd = dist(f0, p);
      for (var k = 1; k < pts.length; k++) {
        final d = dist(f0, pts[k]);
        if (d > pd) {
          pd = d;
          p = pts[k];
        }
      }

      stamp++;
      visible
        ..clear()
        ..add(f0);
      stack
        ..clear()
        ..add(f0);
      mark[f0] = stamp;
      horizonU.clear();
      horizonV.clear();
      while (stack.isNotEmpty) {
        final g = stack.removeLast();
        for (var e = 0; e < 3; e++) {
          final u = e == 0 ? fa[g] : (e == 1 ? fb[g] : fc[g]);
          final v = e == 0 ? fb[g] : (e == 1 ? fc[g] : fa[g]);
          final h = edgeFace[v * n + u];
          if (h == null || !alive[h]) {
            return null;
          }
          if (mark[h] == stamp) {
            continue;
          }
          if (dist(h, p) > tol) {
            mark[h] = stamp;
            visible.add(h);
            stack.add(h);
          } else {
            horizonU.add(u);
            horizonV.add(v);
          }
        }
      }

      orphans.clear();
      for (final g in visible) {
        alive[g] = false;
        final o = outside[g];
        if (o != null) {
          orphans.addAll(o);
          outside[g] = null;
        }
        for (var e = 0; e < 3; e++) {
          final u = e == 0 ? fa[g] : (e == 1 ? fb[g] : fc[g]);
          final v = e == 0 ? fb[g] : (e == 1 ? fc[g] : fa[g]);
          if (edgeFace[u * n + v] == g) {
            edgeFace.remove(u * n + v);
          }
        }
      }
      final firstNew = fa.length;
      for (var k = 0; k < horizonU.length; k++) {
        addFace(horizonU[k], horizonV[k], p);
      }
      for (final q in orphans) {
        if (q == p) {
          continue;
        }
        if (!assign(q, firstNew)) {
          // Not above a new face: check the kept faces as well.
          assign(q, 0);
        }
      }
    }

    // 4. Validate closure and merge coplanar triangles into polygons.
    final faceIds = <int>[];
    for (var f = 0; f < fa.length; f++) {
      if (!alive[f]) {
        continue;
      }
      faceIds.add(f);
      for (var e = 0; e < 3; e++) {
        final u = e == 0 ? fa[f] : (e == 1 ? fb[f] : fc[f]);
        final v = e == 0 ? fb[f] : (e == 1 ? fc[f] : fa[f]);
        final h = edgeFace[v * n + u];
        if (h == null || !alive[h]) {
          return null;
        }
      }
      if (fnx[f] == 0.0 && fny[f] == 0.0 && fnz[f] == 0.0) {
        return null;
      }
    }
    final parent = <int, int>{for (final f in faceIds) f: f};
    int find(int f) {
      var r = f;
      while (parent[r] != r) {
        r = parent[r]!;
      }
      var c = f;
      while (parent[c] != r) {
        final next = parent[c]!;
        parent[c] = r;
        c = next;
      }
      return r;
    }

    const coplanarDot = 1.0 - 1e-6;
    for (final f in faceIds) {
      for (var e = 0; e < 3; e++) {
        final u = e == 0 ? fa[f] : (e == 1 ? fb[f] : fc[f]);
        final v = e == 0 ? fb[f] : (e == 1 ? fc[f] : fa[f]);
        final h = edgeFace[v * n + u]!;
        final dot = fnx[f] * fnx[h] + fny[f] * fny[h] + fnz[f] * fnz[h];
        if (dot >= coplanarDot) {
          final rf = find(f);
          final rh = find(h);
          if (rf != rh) {
            if (rf < rh) {
              parent[rh] = rf;
            } else {
              parent[rf] = rh;
            }
          }
        }
      }
    }

    final groupOrder = <int>[];
    final groupSeen = <int>{};
    for (final f in faceIds) {
      final r = find(f);
      if (groupSeen.add(r)) {
        groupOrder.add(r);
      }
    }

    final loops = <List<int>>[];
    final next = <int, int>{};
    for (final root in groupOrder) {
      next.clear();
      var edgeCount = 0;
      var start = -1;
      for (final f in faceIds) {
        if (find(f) != root) {
          continue;
        }
        for (var e = 0; e < 3; e++) {
          final u = e == 0 ? fa[f] : (e == 1 ? fb[f] : fc[f]);
          final v = e == 0 ? fb[f] : (e == 1 ? fc[f] : fa[f]);
          final h = edgeFace[v * n + u]!;
          if (find(h) == root) {
            continue;
          }
          if (next.containsKey(u)) {
            return null;
          }
          next[u] = v;
          edgeCount++;
          if (start < 0 || u < start) {
            start = u;
          }
        }
      }
      final loop = <int>[start];
      var cur = next[start];
      while (cur != null && cur != start && loop.length <= edgeCount) {
        loop.add(cur);
        cur = next[cur];
      }
      if (cur != start || loop.length != edgeCount) {
        return null;
      }
      // Drop vertices lying on the segment between their neighbours.
      var changed = true;
      while (changed && loop.length > 3) {
        changed = false;
        for (var k = 0; k < loop.length; k++) {
          final a = loop[(k + loop.length - 1) % loop.length];
          final b = loop[k];
          final c = loop[(k + 1) % loop.length];
          final acx = px[c] - px[a];
          final acy = py[c] - py[a];
          final acz = pz[c] - pz[a];
          final abx = px[b] - px[a];
          final aby = py[b] - py[a];
          final abz = pz[b] - pz[a];
          final cx = aby * acz - abz * acy;
          final cy = abz * acx - abx * acz;
          final cz = abx * acy - aby * acx;
          final acLen2 = acx * acx + acy * acy + acz * acz;
          if (acLen2 <= 0.0 || (cx * cx + cy * cy + cz * cz) / acLen2 <= tol2) {
            loop.removeAt(k);
            changed = true;
            break;
          }
        }
      }
      if (loop.length < 3) {
        return null;
      }
      loops.add(loop);
    }

    // 5. Compact hull vertices and face arrays.
    final hullIndexOf = <int, int>{};
    final hullPoints = <int>[];
    for (final loop in loops) {
      for (final v in loop) {
        if (!hullIndexOf.containsKey(v)) {
          hullIndexOf[v] = hullPoints.length;
          hullPoints.add(v);
        }
      }
    }
    final coords = Float64List(hullPoints.length * 3);
    final sourceIndex = Int32List(hullPoints.length);
    var ox = 0.0;
    var oy = 0.0;
    var oz = 0.0;
    for (var k = 0; k < hullPoints.length; k++) {
      final v = hullPoints[k];
      coords[k * 3] = px[v];
      coords[k * 3 + 1] = py[v];
      coords[k * 3 + 2] = pz[v];
      sourceIndex[k] = src[v];
      ox += px[v];
      oy += py[v];
      oz += pz[v];
    }
    ox /= hullPoints.length;
    oy /= hullPoints.length;
    oz /= hullPoints.length;

    var totalVerts = 0;
    for (final loop in loops) {
      totalVerts += loop.length;
    }
    final faceStart = Int32List(loops.length + 1);
    final faceVerts = Int32List(totalVerts);
    final faceNormals = Float64List(loops.length * 3);
    final faceOffsets = Float64List(loops.length);
    var cursor = 0;
    for (var f = 0; f < loops.length; f++) {
      final loop = loops[f];
      faceStart[f] = cursor;
      var nx = 0.0;
      var ny = 0.0;
      var nz = 0.0;
      for (var k = 0; k < loop.length; k++) {
        final a = loop[k];
        final b = loop[(k + 1) % loop.length];
        nx += (py[a] - py[b]) * (pz[a] + pz[b]);
        ny += (pz[a] - pz[b]) * (px[a] + px[b]);
        nz += (px[a] - px[b]) * (py[a] + py[b]);
        faceVerts[cursor++] = hullIndexOf[a]!;
      }
      final len = math.sqrt(nx * nx + ny * ny + nz * nz);
      if (!(len > 0.0)) {
        return null;
      }
      nx /= len;
      ny /= len;
      nz /= len;
      var d = double.negativeInfinity;
      for (final a in loop) {
        d = math.max(d, nx * px[a] + ny * py[a] + nz * pz[a]);
      }
      faceNormals[f * 3] = nx;
      faceNormals[f * 3 + 1] = ny;
      faceNormals[f * 3 + 2] = nz;
      faceOffsets[f] = d;
    }
    faceStart[loops.length] = cursor;

    // 6. Volume, center of mass and inertia from the tetrahedra spanned by
    // the reference point (the vertex mean) and each fan triangle.
    var vol = 0.0;
    var mx = 0.0;
    var my = 0.0;
    var mz = 0.0;
    var cxx = 0.0;
    var cyy = 0.0;
    var czz = 0.0;
    var cxy = 0.0;
    var cxz = 0.0;
    var cyz = 0.0;
    for (final loop in loops) {
      final a = loop[0];
      final ax = px[a] - ox;
      final ay = py[a] - oy;
      final az = pz[a] - oz;
      for (var k = 1; k + 1 < loop.length; k++) {
        final b = loop[k];
        final c = loop[k + 1];
        final bx = px[b] - ox;
        final by = py[b] - oy;
        final bz = pz[b] - oz;
        final cx = px[c] - ox;
        final cy = py[c] - oy;
        final cz = pz[c] - oz;
        final v =
            (ax * (by * cz - bz * cy) +
                ay * (bz * cx - bx * cz) +
                az * (bx * cy - by * cx)) /
            6.0;
        vol += v;
        final sx = ax + bx + cx;
        final sy = ay + by + cy;
        final sz = az + bz + cz;
        mx += v * sx * 0.25;
        my += v * sy * 0.25;
        mz += v * sz * 0.25;
        final k20 = v / 20.0;
        cxx += k20 * (ax * ax + bx * bx + cx * cx + sx * sx);
        cyy += k20 * (ay * ay + by * by + cy * cy + sy * sy);
        czz += k20 * (az * az + bz * bz + cz * cz + sz * sz);
        cxy += k20 * (ax * ay + bx * by + cx * cy + sx * sy);
        cxz += k20 * (ax * az + bx * bz + cx * cz + sx * sz);
        cyz += k20 * (ay * az + by * bz + cy * cz + sy * sz);
      }
    }
    if (!(vol > scale * scale * scale * 1e-12)) {
      return null;
    }
    final comX = mx / vol;
    final comY = my / vol;
    final comZ = mz / vol;
    cxx -= vol * comX * comX;
    cyy -= vol * comY * comY;
    czz -= vol * comZ * comZ;
    cxy -= vol * comX * comY;
    cxz -= vol * comX * comZ;
    cyz -= vol * comY * comZ;
    final trace = cxx + cyy + czz;
    final unitInertia = Float64List(9);
    unitInertia[0] = (trace - cxx) / vol;
    unitInertia[4] = (trace - cyy) / vol;
    unitInertia[8] = (trace - czz) / vol;
    unitInertia[1] = unitInertia[3] = -cxy / vol;
    unitInertia[2] = unitInertia[6] = -cxz / vol;
    unitInertia[5] = unitInertia[7] = -cyz / vol;

    final com = Vector3(ox + comX, oy + comY, oz + comZ);
    var inradius = double.infinity;
    for (var f = 0; f < loops.length; f++) {
      final d =
          faceOffsets[f] -
          (faceNormals[f * 3] * com.x +
              faceNormals[f * 3 + 1] * com.y +
              faceNormals[f * 3 + 2] * com.z);
      inradius = math.min(inradius, d);
    }

    return _HullTopology3D._(
      coords: coords,
      sourceIndex: sourceIndex,
      faceStart: faceStart,
      faceVerts: faceVerts,
      faceNormals: faceNormals,
      faceOffsets: faceOffsets,
      volume: vol,
      centerOfMass: com,
      unitInertia: unitInertia,
      inscribedRadius: math.max(inradius, scale * 1e-4),
    );
  }
}
