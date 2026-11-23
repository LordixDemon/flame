part of 'shapes_3d.dart';

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
        oa = Shape3D._rayScratch.localOrigin.x;
        ou = Shape3D._rayScratch.localOrigin.y;
        ov = Shape3D._rayScratch.localOrigin.z;
        da = Shape3D._rayScratch.localDir.x;
        du = Shape3D._rayScratch.localDir.y;
        dv = Shape3D._rayScratch.localDir.z;
      case Axis3D.y:
        oa = Shape3D._rayScratch.localOrigin.y;
        ou = Shape3D._rayScratch.localOrigin.x;
        ov = Shape3D._rayScratch.localOrigin.z;
        da = Shape3D._rayScratch.localDir.y;
        du = Shape3D._rayScratch.localDir.x;
        dv = Shape3D._rayScratch.localDir.z;
      case Axis3D.z:
        oa = Shape3D._rayScratch.localOrigin.z;
        ou = Shape3D._rayScratch.localOrigin.x;
        ov = Shape3D._rayScratch.localOrigin.y;
        da = Shape3D._rayScratch.localDir.z;
        du = Shape3D._rayScratch.localDir.x;
        dv = Shape3D._rayScratch.localDir.y;
    }

    final hs = halfSegment;
    final r2 = radius * radius;

    // Check if origin starts inside capsule.
    final clampedOa = oa.clamp(-hs, hs);
    final diffA = oa - clampedOa;
    if (diffA * diffA + ou * ou + ov * ov <= r2) {
      return (
        0.0,
        Vector3(
          -Shape3D._rayScratch.unitWorldDir.x,
          -Shape3D._rayScratch.unitWorldDir.y,
          -Shape3D._rayScratch.unitWorldDir.z,
        ),
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
