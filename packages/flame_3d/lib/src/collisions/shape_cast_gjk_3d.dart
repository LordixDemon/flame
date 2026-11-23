part of 'shape_cast_3d.dart';

/// Van den Bergen's GJK Raycast (`x(t) = t * delta` entering Minkowski
/// difference `M = B - A_0`, where `s_M(v) = s_B(v) - s_{A_0}(-v)`).
_SweepResult? _gjkConvexSweep(
  void Function(Vector3 dir, Vector3 out) supportA,
  void Function(Vector3 dir, Vector3 out) supportB,
  CollisionManifold3D? Function() initialOverlapTest,
  Vector3 centerA,
  Vector3 centerB,
  Vector3 delta,
  double maxToi,
) {
  void supportM(
    double dx,
    double dy,
    double dz,
    Vector3 outM,
    Vector3 outB,
  ) {
    ShapeCast3D._scratch.dirPos.setValues(dx, dy, dz);
    ShapeCast3D._scratch.dirNeg.setValues(-dx, -dy, -dz);
    supportB(ShapeCast3D._scratch.dirPos, outB);
    supportA(ShapeCast3D._scratch.dirNeg, ShapeCast3D._scratch.supA);
    outM
      ..setFrom(outB)
      ..sub(ShapeCast3D._scratch.supA);
  }

  var lambda = 0.0;
  var xx = 0.0;
  var xy = 0.0;
  var xz = 0.0;
  final rx = delta.x;
  final ry = delta.y;
  final rz = delta.z;

  var nx = 0.0;
  var ny = 0.0;
  var nz = 0.0;
  var hasNormal = false;

  var count = 0;

  for (var iter = 0; iter < 48; iter++) {
    if (count == 0) {
      var initDx = centerA.x - centerB.x;
      var initDy = centerA.y - centerB.y;
      var initDz = centerA.z - centerB.z;
      if (initDx * initDx + initDy * initDy + initDz * initDz < 1e-12) {
        initDx = -rx;
        initDy = -ry;
        initDz = -rz;
      }
      supportM(
        initDx,
        initDy,
        initDz,
        ShapeCast3D._scratch.supM,
        ShapeCast3D._scratch.supB,
      );
      ShapeCast3D._scratch.mx[0] = ShapeCast3D._scratch.supM.x;
      ShapeCast3D._scratch.my[0] = ShapeCast3D._scratch.supM.y;
      ShapeCast3D._scratch.mz[0] = ShapeCast3D._scratch.supM.z;
      ShapeCast3D._scratch.bx[0] = ShapeCast3D._scratch.supB.x;
      ShapeCast3D._scratch.by[0] = ShapeCast3D._scratch.supB.y;
      ShapeCast3D._scratch.bz[0] = ShapeCast3D._scratch.supB.z;
      count = 1;
    }

    count = _reduceSimplexClosestTo(
      xx,
      xy,
      xz,
      count,
      ShapeCast3D._scratch.closestM,
      ShapeCast3D._scratch.closestB,
    );
    final vx = xx - ShapeCast3D._scratch.closestM.x;
    final vy = xy - ShapeCast3D._scratch.closestM.y;
    final vz = xz - ShapeCast3D._scratch.closestM.z;
    final vLen2 = vx * vx + vy * vy + vz * vz;

    if (vLen2 <= 1e-10) {
      return _finalizeSweepHit(
        hasNormal: hasNormal,
        initialOverlapTest: initialOverlapTest,
        delta: delta,
        lambda: lambda,
        closestB: ShapeCast3D._scratch.closestB,
        nx: nx,
        ny: ny,
        nz: nz,
      );
    }

    supportM(vx, vy, vz, ShapeCast3D._scratch.supM, ShapeCast3D._scratch.supB);
    final wx = ShapeCast3D._scratch.supM.x;
    final wy = ShapeCast3D._scratch.supM.y;
    final wz = ShapeCast3D._scratch.supM.z;

    final vp = vx * (xx - wx) + vy * (xy - wy) + vz * (xz - wz);
    final vr = vx * rx + vy * ry + vz * rz;

    if (vp > 0.0) {
      if (vr >= -1e-12) {
        return null;
      }
      lambda += vp / (-vr);
      if (lambda > maxToi) {
        return null;
      }
      xx = lambda * rx;
      xy = lambda * ry;
      xz = lambda * rz;
      nx = vx;
      ny = vy;
      nz = vz;
      hasNormal = true;
    }

    var duplicate = false;
    for (var i = 0; i < count; i++) {
      final dx = ShapeCast3D._scratch.mx[i] - wx;
      final dy = ShapeCast3D._scratch.my[i] - wy;
      final dz = ShapeCast3D._scratch.mz[i] - wz;
      if (dx * dx + dy * dy + dz * dz <= 1e-11) {
        duplicate = true;
        break;
      }
    }
    if (duplicate) {
      if (vp > 1e-6) {
        return null;
      }
      return _finalizeSweepHit(
        hasNormal: hasNormal,
        initialOverlapTest: initialOverlapTest,
        delta: delta,
        lambda: lambda,
        closestB: ShapeCast3D._scratch.closestB,
        nx: nx,
        ny: ny,
        nz: nz,
      );
    }

    final slot = count < 4 ? count++ : 3;
    ShapeCast3D._scratch.mx[slot] = wx;
    ShapeCast3D._scratch.my[slot] = wy;
    ShapeCast3D._scratch.mz[slot] = wz;
    ShapeCast3D._scratch.bx[slot] = ShapeCast3D._scratch.supB.x;
    ShapeCast3D._scratch.by[slot] = ShapeCast3D._scratch.supB.y;
    ShapeCast3D._scratch.bz[slot] = ShapeCast3D._scratch.supB.z;
  }

  if (hasNormal && lambda <= maxToi) {
    final d2 =
        (xx - ShapeCast3D._scratch.closestM.x) *
            (xx - ShapeCast3D._scratch.closestM.x) +
        (xy - ShapeCast3D._scratch.closestM.y) *
            (xy - ShapeCast3D._scratch.closestM.y) +
        (xz - ShapeCast3D._scratch.closestM.z) *
            (xz - ShapeCast3D._scratch.closestM.z);
    if (d2 <= 1e-6) {
      final nLen = math.sqrt(nx * nx + ny * ny + nz * nz);
      return _SweepResult(
        toi: lambda,
        point: ShapeCast3D._scratch.closestB.clone(),
        normal: nLen > 1e-12
            ? Vector3(nx / nLen, ny / nLen, nz / nLen)
            : Vector3(-rx, -ry, -rz).normalized(),
      );
    }
  }
  return null;
}

_SweepResult? _finalizeSweepHit({
  required bool hasNormal,
  required CollisionManifold3D? Function() initialOverlapTest,
  required Vector3 delta,
  required double lambda,
  required Vector3 closestB,
  required double nx,
  required double ny,
  required double nz,
}) {
  if (!hasNormal) {
    // Started overlapping at `lambda == 0`. Only report hit if moving deeper
    // into the obstacle; ignore parallel/separating skin touches.
    final manifold = initialOverlapTest();
    if (manifold == null || manifold.penetrationDepth <= 1e-4) {
      return null;
    }
    final obsNormal = -manifold.normal;
    if (obsNormal.dot(delta) >= -1e-6) {
      return null;
    }
    return _SweepResult(
      toi: 0.0,
      point: manifold.contactPointB.clone(),
      normal: obsNormal,
    );
  }
  final nLen = math.sqrt(nx * nx + ny * ny + nz * nz);
  return _SweepResult(
    toi: lambda,
    point: closestB.clone(),
    normal: nLen > 1e-12
        ? Vector3(nx / nLen, ny / nLen, nz / nLen)
        : (-delta).normalized(),
  );
}

int _reduceSimplexClosestTo(
  double px,
  double py,
  double pz,
  int count,
  Vector3 outM,
  Vector3 outB,
) {
  if (count == 1) {
    outM.setValues(
      ShapeCast3D._scratch.mx[0],
      ShapeCast3D._scratch.my[0],
      ShapeCast3D._scratch.mz[0],
    );
    outB.setValues(
      ShapeCast3D._scratch.bx[0],
      ShapeCast3D._scratch.by[0],
      ShapeCast3D._scratch.bz[0],
    );
    return 1;
  }
  if (count == 2) {
    final ax = ShapeCast3D._scratch.mx[0] - px;
    final ay = ShapeCast3D._scratch.my[0] - py;
    final az = ShapeCast3D._scratch.mz[0] - pz;
    final abx = (ShapeCast3D._scratch.mx[1] - px) - ax;
    final aby = (ShapeCast3D._scratch.my[1] - py) - ay;
    final abz = (ShapeCast3D._scratch.mz[1] - pz) - az;
    final denom = abx * abx + aby * aby + abz * abz;
    if (denom <= 1e-16) {
      outM.setValues(
        ShapeCast3D._scratch.mx[0],
        ShapeCast3D._scratch.my[0],
        ShapeCast3D._scratch.mz[0],
      );
      outB.setValues(
        ShapeCast3D._scratch.bx[0],
        ShapeCast3D._scratch.by[0],
        ShapeCast3D._scratch.bz[0],
      );
      return 1;
    }
    final t = -(ax * abx + ay * aby + az * abz) / denom;
    if (t <= 0.0) {
      outM.setValues(
        ShapeCast3D._scratch.mx[0],
        ShapeCast3D._scratch.my[0],
        ShapeCast3D._scratch.mz[0],
      );
      outB.setValues(
        ShapeCast3D._scratch.bx[0],
        ShapeCast3D._scratch.by[0],
        ShapeCast3D._scratch.bz[0],
      );
      return 1;
    }
    if (t >= 1.0) {
      _copySlot(1, 0);
      outM.setValues(
        ShapeCast3D._scratch.mx[0],
        ShapeCast3D._scratch.my[0],
        ShapeCast3D._scratch.mz[0],
      );
      outB.setValues(
        ShapeCast3D._scratch.bx[0],
        ShapeCast3D._scratch.by[0],
        ShapeCast3D._scratch.bz[0],
      );
      return 1;
    }
    outM.setValues(
      ShapeCast3D._scratch.mx[0] + t * abx,
      ShapeCast3D._scratch.my[0] + t * aby,
      ShapeCast3D._scratch.mz[0] + t * abz,
    );
    outB.setValues(
      ShapeCast3D._scratch.bx[0] +
          t * (ShapeCast3D._scratch.bx[1] - ShapeCast3D._scratch.bx[0]),
      ShapeCast3D._scratch.by[0] +
          t * (ShapeCast3D._scratch.by[1] - ShapeCast3D._scratch.by[0]),
      ShapeCast3D._scratch.bz[0] +
          t * (ShapeCast3D._scratch.bz[1] - ShapeCast3D._scratch.bz[0]),
    );
    return 2;
  }
  if (count == 3) {
    return _reduceTriangleClosestTo(px, py, pz, outM, outB);
  }
  return _reduceTetraClosestTo(px, py, pz, outM, outB);
}

void _copySlot(int from, int to) {
  ShapeCast3D._scratch.mx[to] = ShapeCast3D._scratch.mx[from];
  ShapeCast3D._scratch.my[to] = ShapeCast3D._scratch.my[from];
  ShapeCast3D._scratch.mz[to] = ShapeCast3D._scratch.mz[from];
  ShapeCast3D._scratch.bx[to] = ShapeCast3D._scratch.bx[from];
  ShapeCast3D._scratch.by[to] = ShapeCast3D._scratch.by[from];
  ShapeCast3D._scratch.bz[to] = ShapeCast3D._scratch.bz[from];
}

int _reduceTriangleClosestTo(
  double px,
  double py,
  double pz,
  Vector3 outM,
  Vector3 outB,
) {
  final ax = ShapeCast3D._scratch.mx[0] - px;
  final ay = ShapeCast3D._scratch.my[0] - py;
  final az = ShapeCast3D._scratch.mz[0] - pz;
  final bx = ShapeCast3D._scratch.mx[1] - px;
  final by = ShapeCast3D._scratch.my[1] - py;
  final bz = ShapeCast3D._scratch.mz[1] - pz;
  final cx = ShapeCast3D._scratch.mx[2] - px;
  final cy = ShapeCast3D._scratch.my[2] - py;
  final cz = ShapeCast3D._scratch.mz[2] - pz;

  final abx = bx - ax;
  final aby = by - ay;
  final abz = bz - az;
  final acx = cx - ax;
  final acy = cy - ay;
  final acz = cz - az;

  final d1 = -(abx * ax + aby * ay + abz * az);
  final d2 = -(acx * ax + acy * ay + acz * az);
  if (d1 <= 0.0 && d2 <= 0.0) {
    outM.setValues(
      ShapeCast3D._scratch.mx[0],
      ShapeCast3D._scratch.my[0],
      ShapeCast3D._scratch.mz[0],
    );
    outB.setValues(
      ShapeCast3D._scratch.bx[0],
      ShapeCast3D._scratch.by[0],
      ShapeCast3D._scratch.bz[0],
    );
    return 1;
  }

  final d3 = -(abx * bx + aby * by + abz * bz);
  final d4 = -(acx * bx + acy * by + acz * bz);
  if (d3 >= 0.0 && d4 <= d3) {
    _copySlot(1, 0);
    outM.setValues(
      ShapeCast3D._scratch.mx[0],
      ShapeCast3D._scratch.my[0],
      ShapeCast3D._scratch.mz[0],
    );
    outB.setValues(
      ShapeCast3D._scratch.bx[0],
      ShapeCast3D._scratch.by[0],
      ShapeCast3D._scratch.bz[0],
    );
    return 1;
  }

  final vc = d1 * d4 - d3 * d2;
  if (vc <= 0.0 && d1 >= 0.0 && d3 <= 0.0) {
    final v = d1 / (d1 - d3);
    outM.setValues(
      ShapeCast3D._scratch.mx[0] + v * abx,
      ShapeCast3D._scratch.my[0] + v * aby,
      ShapeCast3D._scratch.mz[0] + v * abz,
    );
    outB.setValues(
      ShapeCast3D._scratch.bx[0] +
          v * (ShapeCast3D._scratch.bx[1] - ShapeCast3D._scratch.bx[0]),
      ShapeCast3D._scratch.by[0] +
          v * (ShapeCast3D._scratch.by[1] - ShapeCast3D._scratch.by[0]),
      ShapeCast3D._scratch.bz[0] +
          v * (ShapeCast3D._scratch.bz[1] - ShapeCast3D._scratch.bz[0]),
    );
    return 2;
  }

  final d5 = -(abx * cx + aby * cy + abz * cz);
  final d6 = -(acx * cx + acy * cy + acz * cz);
  if (d6 >= 0.0 && d5 <= d6) {
    _copySlot(2, 0);
    outM.setValues(
      ShapeCast3D._scratch.mx[0],
      ShapeCast3D._scratch.my[0],
      ShapeCast3D._scratch.mz[0],
    );
    outB.setValues(
      ShapeCast3D._scratch.bx[0],
      ShapeCast3D._scratch.by[0],
      ShapeCast3D._scratch.bz[0],
    );
    return 1;
  }

  final vb = d5 * d2 - d1 * d6;
  if (vb <= 0.0 && d2 >= 0.0 && d6 <= 0.0) {
    final w = d2 / (d2 - d6);
    outM.setValues(
      ShapeCast3D._scratch.mx[0] + w * acx,
      ShapeCast3D._scratch.my[0] + w * acy,
      ShapeCast3D._scratch.mz[0] + w * acz,
    );
    outB.setValues(
      ShapeCast3D._scratch.bx[0] +
          w * (ShapeCast3D._scratch.bx[2] - ShapeCast3D._scratch.bx[0]),
      ShapeCast3D._scratch.by[0] +
          w * (ShapeCast3D._scratch.by[2] - ShapeCast3D._scratch.by[0]),
      ShapeCast3D._scratch.bz[0] +
          w * (ShapeCast3D._scratch.bz[2] - ShapeCast3D._scratch.bz[0]),
    );
    _copySlot(2, 1);
    return 2;
  }

  final va = d3 * d6 - d5 * d4;
  if (va <= 0.0 && (d4 - d3) >= 0.0 && (d5 - d6) >= 0.0) {
    final w = (d4 - d3) / ((d4 - d3) + (d5 - d6));
    outM.setValues(
      ShapeCast3D._scratch.mx[1] +
          w * (ShapeCast3D._scratch.mx[2] - ShapeCast3D._scratch.mx[1]),
      ShapeCast3D._scratch.my[1] +
          w * (ShapeCast3D._scratch.my[2] - ShapeCast3D._scratch.my[1]),
      ShapeCast3D._scratch.mz[1] +
          w * (ShapeCast3D._scratch.mz[2] - ShapeCast3D._scratch.mz[1]),
    );
    outB.setValues(
      ShapeCast3D._scratch.bx[1] +
          w * (ShapeCast3D._scratch.bx[2] - ShapeCast3D._scratch.bx[1]),
      ShapeCast3D._scratch.by[1] +
          w * (ShapeCast3D._scratch.by[2] - ShapeCast3D._scratch.by[1]),
      ShapeCast3D._scratch.bz[1] +
          w * (ShapeCast3D._scratch.bz[2] - ShapeCast3D._scratch.bz[1]),
    );
    _copySlot(1, 0);
    _copySlot(2, 1);
    return 2;
  }

  final denom = 1.0 / (va + vb + vc);
  final v = vb * denom;
  final w = vc * denom;
  final u = 1.0 - v - w;
  outM.setValues(
    ShapeCast3D._scratch.mx[0] * u +
        ShapeCast3D._scratch.mx[1] * v +
        ShapeCast3D._scratch.mx[2] * w,
    ShapeCast3D._scratch.my[0] * u +
        ShapeCast3D._scratch.my[1] * v +
        ShapeCast3D._scratch.my[2] * w,
    ShapeCast3D._scratch.mz[0] * u +
        ShapeCast3D._scratch.mz[1] * v +
        ShapeCast3D._scratch.mz[2] * w,
  );
  outB.setValues(
    ShapeCast3D._scratch.bx[0] * u +
        ShapeCast3D._scratch.bx[1] * v +
        ShapeCast3D._scratch.bx[2] * w,
    ShapeCast3D._scratch.by[0] * u +
        ShapeCast3D._scratch.by[1] * v +
        ShapeCast3D._scratch.by[2] * w,
    ShapeCast3D._scratch.bz[0] * u +
        ShapeCast3D._scratch.bz[1] * v +
        ShapeCast3D._scratch.bz[2] * w,
  );
  return 3;
}

int _reduceTetraClosestTo(
  double px,
  double py,
  double pz,
  Vector3 outM,
  Vector3 outB,
) {
  const faces = [
    (0, 1, 2, 3),
    (0, 2, 3, 1),
    (0, 3, 1, 2),
    (1, 3, 2, 0),
  ];
  for (var k = 0; k < 4; k++) {
    ShapeCast3D._scratch.tmx[k] = ShapeCast3D._scratch.mx[k];
    ShapeCast3D._scratch.tmy[k] = ShapeCast3D._scratch.my[k];
    ShapeCast3D._scratch.tmz[k] = ShapeCast3D._scratch.mz[k];
    ShapeCast3D._scratch.tbx[k] = ShapeCast3D._scratch.bx[k];
    ShapeCast3D._scratch.tby[k] = ShapeCast3D._scratch.by[k];
    ShapeCast3D._scratch.tbz[k] = ShapeCast3D._scratch.bz[k];
  }

  var bestD2 = double.infinity;
  var bestCount = 4;
  var bestOutMx = px;
  var bestOutMy = py;
  var bestOutMz = pz;
  var bestOutBx = ShapeCast3D._scratch.tbx[0];
  var bestOutBy = ShapeCast3D._scratch.tby[0];
  var bestOutBz = ShapeCast3D._scratch.tbz[0];
  var outsideAny = false;

  for (final (i0, i1, i2, opp) in faces) {
    final e1x = ShapeCast3D._scratch.tmx[i1] - ShapeCast3D._scratch.tmx[i0];
    final e1y = ShapeCast3D._scratch.tmy[i1] - ShapeCast3D._scratch.tmy[i0];
    final e1z = ShapeCast3D._scratch.tmz[i1] - ShapeCast3D._scratch.tmz[i0];
    final e2x = ShapeCast3D._scratch.tmx[i2] - ShapeCast3D._scratch.tmx[i0];
    final e2y = ShapeCast3D._scratch.tmy[i2] - ShapeCast3D._scratch.tmy[i0];
    final e2z = ShapeCast3D._scratch.tmz[i2] - ShapeCast3D._scratch.tmz[i0];
    final fnx = e1y * e2z - e1z * e2y;
    final fny = e1z * e2x - e1x * e2z;
    final fnz = e1x * e2y - e1y * e2x;

    final signP =
        fnx * (px - ShapeCast3D._scratch.tmx[i0]) +
        fny * (py - ShapeCast3D._scratch.tmy[i0]) +
        fnz * (pz - ShapeCast3D._scratch.tmz[i0]);
    final signOpp =
        fnx * (ShapeCast3D._scratch.tmx[opp] - ShapeCast3D._scratch.tmx[i0]) +
        fny * (ShapeCast3D._scratch.tmy[opp] - ShapeCast3D._scratch.tmy[i0]) +
        fnz * (ShapeCast3D._scratch.tmz[opp] - ShapeCast3D._scratch.tmz[i0]);

    if (signP * signOpp <= 0.0) {
      outsideAny = true;
      ShapeCast3D._scratch.mx[0] = ShapeCast3D._scratch.tmx[i0];
      ShapeCast3D._scratch.my[0] = ShapeCast3D._scratch.tmy[i0];
      ShapeCast3D._scratch.mz[0] = ShapeCast3D._scratch.tmz[i0];
      ShapeCast3D._scratch.bx[0] = ShapeCast3D._scratch.tbx[i0];
      ShapeCast3D._scratch.by[0] = ShapeCast3D._scratch.tby[i0];
      ShapeCast3D._scratch.bz[0] = ShapeCast3D._scratch.tbz[i0];
      ShapeCast3D._scratch.mx[1] = ShapeCast3D._scratch.tmx[i1];
      ShapeCast3D._scratch.my[1] = ShapeCast3D._scratch.tmy[i1];
      ShapeCast3D._scratch.mz[1] = ShapeCast3D._scratch.tmz[i1];
      ShapeCast3D._scratch.bx[1] = ShapeCast3D._scratch.tbx[i1];
      ShapeCast3D._scratch.by[1] = ShapeCast3D._scratch.tby[i1];
      ShapeCast3D._scratch.bz[1] = ShapeCast3D._scratch.tbz[i1];
      ShapeCast3D._scratch.mx[2] = ShapeCast3D._scratch.tmx[i2];
      ShapeCast3D._scratch.my[2] = ShapeCast3D._scratch.tmy[i2];
      ShapeCast3D._scratch.mz[2] = ShapeCast3D._scratch.tmz[i2];
      ShapeCast3D._scratch.bx[2] = ShapeCast3D._scratch.tbx[i2];
      ShapeCast3D._scratch.by[2] = ShapeCast3D._scratch.tby[i2];
      ShapeCast3D._scratch.bz[2] = ShapeCast3D._scratch.tbz[i2];
      final cnt = _reduceTriangleClosestTo(px, py, pz, outM, outB);
      final dx = outM.x - px;
      final dy = outM.y - py;
      final dz = outM.z - pz;
      final d2 = dx * dx + dy * dy + dz * dz;
      if (d2 < bestD2) {
        bestD2 = d2;
        bestCount = cnt;
        bestOutMx = outM.x;
        bestOutMy = outM.y;
        bestOutMz = outM.z;
        bestOutBx = outB.x;
        bestOutBy = outB.y;
        bestOutBz = outB.z;
        for (var s = 0; s < cnt; s++) {
          ShapeCast3D._scratch.bestMx[s] = ShapeCast3D._scratch.mx[s];
          ShapeCast3D._scratch.bestMy[s] = ShapeCast3D._scratch.my[s];
          ShapeCast3D._scratch.bestMz[s] = ShapeCast3D._scratch.mz[s];
          ShapeCast3D._scratch.bestBx[s] = ShapeCast3D._scratch.bx[s];
          ShapeCast3D._scratch.bestBy[s] = ShapeCast3D._scratch.by[s];
          ShapeCast3D._scratch.bestBz[s] = ShapeCast3D._scratch.bz[s];
        }
      }
    }
  }

  if (!outsideAny) {
    for (var k = 0; k < 4; k++) {
      ShapeCast3D._scratch.mx[k] = ShapeCast3D._scratch.tmx[k];
      ShapeCast3D._scratch.my[k] = ShapeCast3D._scratch.tmy[k];
      ShapeCast3D._scratch.mz[k] = ShapeCast3D._scratch.tmz[k];
      ShapeCast3D._scratch.bx[k] = ShapeCast3D._scratch.tbx[k];
      ShapeCast3D._scratch.by[k] = ShapeCast3D._scratch.tby[k];
      ShapeCast3D._scratch.bz[k] = ShapeCast3D._scratch.tbz[k];
    }
    outM.setValues(px, py, pz);
    outB.setValues(
      ShapeCast3D._scratch.tbx[0],
      ShapeCast3D._scratch.tby[0],
      ShapeCast3D._scratch.tbz[0],
    );
    return 4;
  }

  for (var s = 0; s < bestCount; s++) {
    ShapeCast3D._scratch.mx[s] = ShapeCast3D._scratch.bestMx[s];
    ShapeCast3D._scratch.my[s] = ShapeCast3D._scratch.bestMy[s];
    ShapeCast3D._scratch.mz[s] = ShapeCast3D._scratch.bestMz[s];
    ShapeCast3D._scratch.bx[s] = ShapeCast3D._scratch.bestBx[s];
    ShapeCast3D._scratch.by[s] = ShapeCast3D._scratch.bestBy[s];
    ShapeCast3D._scratch.bz[s] = ShapeCast3D._scratch.bestBz[s];
  }
  outM.setValues(bestOutMx, bestOutMy, bestOutMz);
  outB.setValues(bestOutBx, bestOutBy, bestOutBz);
  return bestCount;
}

class _ShapeCastScratch() {
  final Quaternion identityQuat = Quaternion.identity();
  final Vector3 unitScale = Vector3.all(1.0);
  final Matrix4 startMat = Matrix4.identity();
  final Matrix4 endMat = Matrix4.identity();
  final Matrix4 invMesh = Matrix4.identity();
  final Aabb3 aabbStart = Aabb3();
  final Aabb3 aabbEnd = Aabb3();
  final Aabb3 sweptAabb = Aabb3();
  final Aabb3 localSweptAabb = Aabb3();
  final List<Collider3D> colliderScratch = [];
  final List<int> triCandidates = [];

  final Vector3 cA = Vector3.zero();
  final Vector3 cB = Vector3.zero();
  final Vector3 tv0 = Vector3.zero();
  final Vector3 tv1 = Vector3.zero();
  final Vector3 tv2 = Vector3.zero();
  final Vector3 triCenter = Vector3.zero();

  final Vector3 dirPos = Vector3.zero();
  final Vector3 dirNeg = Vector3.zero();
  final Vector3 supA = Vector3.zero();
  final Vector3 supB = Vector3.zero();
  final Vector3 supM = Vector3.zero();
  final Vector3 closestM = Vector3.zero();
  final Vector3 closestB = Vector3.zero();

  final Float64List mx = Float64List(4);
  final Float64List my = Float64List(4);
  final Float64List mz = Float64List(4);
  final Float64List bx = Float64List(4);
  final Float64List by = Float64List(4);
  final Float64List bz = Float64List(4);

  final Float64List tmx = Float64List(4);
  final Float64List tmy = Float64List(4);
  final Float64List tmz = Float64List(4);
  final Float64List tbx = Float64List(4);
  final Float64List tby = Float64List(4);
  final Float64List tbz = Float64List(4);

  final Float64List bestMx = Float64List(3);
  final Float64List bestMy = Float64List(3);
  final Float64List bestMz = Float64List(3);
  final Float64List bestBx = Float64List(3);
  final Float64List bestBy = Float64List(3);
  final Float64List bestBz = Float64List(3);
}

class _SweepResult({
  required final double toi,
  required final Vector3 point,
  required final Vector3 normal,
});
