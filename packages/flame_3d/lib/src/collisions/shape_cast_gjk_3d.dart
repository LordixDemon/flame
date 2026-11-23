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
    _dirPos.setValues(dx, dy, dz);
    _dirNeg.setValues(-dx, -dy, -dz);
    supportB(_dirPos, outB);
    supportA(_dirNeg, _supA);
    outM
      ..setFrom(outB)
      ..sub(_supA);
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
      supportM(initDx, initDy, initDz, _supM, _supB);
      _mx[0] = _supM.x;
      _my[0] = _supM.y;
      _mz[0] = _supM.z;
      _bx[0] = _supB.x;
      _by[0] = _supB.y;
      _bz[0] = _supB.z;
      count = 1;
    }

    count = _reduceSimplexClosestTo(xx, xy, xz, count, _closestM, _closestB);
    final vx = xx - _closestM.x;
    final vy = xy - _closestM.y;
    final vz = xz - _closestM.z;
    final vLen2 = vx * vx + vy * vy + vz * vz;

    if (vLen2 <= 1e-10) {
      if (!hasNormal) {
        // Started overlapping at `lambda == 0`. Only report hit if moving
        // deeper into the obstacle; ignore parallel/separating skin touches!
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
        point: _closestB.clone(),
        normal: nLen > 1e-12
            ? Vector3(nx / nLen, ny / nLen, nz / nLen)
            : Vector3(-rx, -ry, -rz).normalized(),
      );
    }

    supportM(vx, vy, vz, _supM, _supB);
    final wx = _supM.x;
    final wy = _supM.y;
    final wz = _supM.z;

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
      final dx = _mx[i] - wx;
      final dy = _my[i] - wy;
      final dz = _mz[i] - wz;
      if (dx * dx + dy * dy + dz * dz <= 1e-11) {
        duplicate = true;
        break;
      }
    }
    if (duplicate) {
      if (vp > 1e-6) {
        return null;
      }
      if (!hasNormal) {
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
        point: _closestB.clone(),
        normal: nLen > 1e-12
            ? Vector3(nx / nLen, ny / nLen, nz / nLen)
            : Vector3(-rx, -ry, -rz).normalized(),
      );
    }

    final slot = count < 4 ? count++ : 3;
    _mx[slot] = wx;
    _my[slot] = wy;
    _mz[slot] = wz;
    _bx[slot] = _supB.x;
    _by[slot] = _supB.y;
    _bz[slot] = _supB.z;
  }

  if (hasNormal && lambda <= maxToi) {
    final d2 =
        (xx - _closestM.x) * (xx - _closestM.x) +
        (xy - _closestM.y) * (xy - _closestM.y) +
        (xz - _closestM.z) * (xz - _closestM.z);
    if (d2 <= 1e-6) {
      final nLen = math.sqrt(nx * nx + ny * ny + nz * nz);
      return _SweepResult(
        toi: lambda,
        point: _closestB.clone(),
        normal: nLen > 1e-12
            ? Vector3(nx / nLen, ny / nLen, nz / nLen)
            : Vector3(-rx, -ry, -rz).normalized(),
      );
    }
  }
  return null;
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
    outM.setValues(_mx[0], _my[0], _mz[0]);
    outB.setValues(_bx[0], _by[0], _bz[0]);
    return 1;
  }
  if (count == 2) {
    final ax = _mx[0] - px;
    final ay = _my[0] - py;
    final az = _mz[0] - pz;
    final abx = (_mx[1] - px) - ax;
    final aby = (_my[1] - py) - ay;
    final abz = (_mz[1] - pz) - az;
    final denom = abx * abx + aby * aby + abz * abz;
    if (denom <= 1e-16) {
      outM.setValues(_mx[0], _my[0], _mz[0]);
      outB.setValues(_bx[0], _by[0], _bz[0]);
      return 1;
    }
    final t = -(ax * abx + ay * aby + az * abz) / denom;
    if (t <= 0.0) {
      outM.setValues(_mx[0], _my[0], _mz[0]);
      outB.setValues(_bx[0], _by[0], _bz[0]);
      return 1;
    }
    if (t >= 1.0) {
      _copySlot(1, 0);
      outM.setValues(_mx[0], _my[0], _mz[0]);
      outB.setValues(_bx[0], _by[0], _bz[0]);
      return 1;
    }
    outM.setValues(_mx[0] + t * abx, _my[0] + t * aby, _mz[0] + t * abz);
    outB.setValues(
      _bx[0] + t * (_bx[1] - _bx[0]),
      _by[0] + t * (_by[1] - _by[0]),
      _bz[0] + t * (_bz[1] - _bz[0]),
    );
    return 2;
  }
  if (count == 3) {
    return _reduceTriangleClosestTo(px, py, pz, outM, outB);
  }
  return _reduceTetraClosestTo(px, py, pz, outM, outB);
}

void _copySlot(int from, int to) {
  _mx[to] = _mx[from];
  _my[to] = _my[from];
  _mz[to] = _mz[from];
  _bx[to] = _bx[from];
  _by[to] = _by[from];
  _bz[to] = _bz[from];
}

int _reduceTriangleClosestTo(
  double px,
  double py,
  double pz,
  Vector3 outM,
  Vector3 outB,
) {
  final ax = _mx[0] - px;
  final ay = _my[0] - py;
  final az = _mz[0] - pz;
  final bx = _mx[1] - px;
  final by = _my[1] - py;
  final bz = _mz[1] - pz;
  final cx = _mx[2] - px;
  final cy = _my[2] - py;
  final cz = _mz[2] - pz;

  final abx = bx - ax;
  final aby = by - ay;
  final abz = bz - az;
  final acx = cx - ax;
  final acy = cy - ay;
  final acz = cz - az;

  final d1 = -(abx * ax + aby * ay + abz * az);
  final d2 = -(acx * ax + acy * ay + acz * az);
  if (d1 <= 0.0 && d2 <= 0.0) {
    outM.setValues(_mx[0], _my[0], _mz[0]);
    outB.setValues(_bx[0], _by[0], _bz[0]);
    return 1;
  }

  final d3 = -(abx * bx + aby * by + abz * bz);
  final d4 = -(acx * bx + acy * by + acz * bz);
  if (d3 >= 0.0 && d4 <= d3) {
    _copySlot(1, 0);
    outM.setValues(_mx[0], _my[0], _mz[0]);
    outB.setValues(_bx[0], _by[0], _bz[0]);
    return 1;
  }

  final vc = d1 * d4 - d3 * d2;
  if (vc <= 0.0 && d1 >= 0.0 && d3 <= 0.0) {
    final v = d1 / (d1 - d3);
    outM.setValues(_mx[0] + v * abx, _my[0] + v * aby, _mz[0] + v * abz);
    outB.setValues(
      _bx[0] + v * (_bx[1] - _bx[0]),
      _by[0] + v * (_by[1] - _by[0]),
      _bz[0] + v * (_bz[1] - _bz[0]),
    );
    return 2;
  }

  final d5 = -(abx * cx + aby * cy + abz * cz);
  final d6 = -(acx * cx + acy * cy + acz * cz);
  if (d6 >= 0.0 && d5 <= d6) {
    _copySlot(2, 0);
    outM.setValues(_mx[0], _my[0], _mz[0]);
    outB.setValues(_bx[0], _by[0], _bz[0]);
    return 1;
  }

  final vb = d5 * d2 - d1 * d6;
  if (vb <= 0.0 && d2 >= 0.0 && d6 <= 0.0) {
    final w = d2 / (d2 - d6);
    outM.setValues(_mx[0] + w * acx, _my[0] + w * acy, _mz[0] + w * acz);
    outB.setValues(
      _bx[0] + w * (_bx[2] - _bx[0]),
      _by[0] + w * (_by[2] - _by[0]),
      _bz[0] + w * (_bz[2] - _bz[0]),
    );
    _copySlot(2, 1);
    return 2;
  }

  final va = d3 * d6 - d5 * d4;
  if (va <= 0.0 && (d4 - d3) >= 0.0 && (d5 - d6) >= 0.0) {
    final w = (d4 - d3) / ((d4 - d3) + (d5 - d6));
    outM.setValues(
      _mx[1] + w * (_mx[2] - _mx[1]),
      _my[1] + w * (_my[2] - _my[1]),
      _mz[1] + w * (_mz[2] - _mz[1]),
    );
    outB.setValues(
      _bx[1] + w * (_bx[2] - _bx[1]),
      _by[1] + w * (_by[2] - _by[1]),
      _bz[1] + w * (_bz[2] - _bz[1]),
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
    _mx[0] * u + _mx[1] * v + _mx[2] * w,
    _my[0] * u + _my[1] * v + _my[2] * w,
    _mz[0] * u + _mz[1] * v + _mz[2] * w,
  );
  outB.setValues(
    _bx[0] * u + _bx[1] * v + _bx[2] * w,
    _by[0] * u + _by[1] * v + _by[2] * w,
    _bz[0] * u + _bz[1] * v + _bz[2] * w,
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
    _tmx[k] = _mx[k];
    _tmy[k] = _my[k];
    _tmz[k] = _mz[k];
    _tbx[k] = _bx[k];
    _tby[k] = _by[k];
    _tbz[k] = _bz[k];
  }

  var bestD2 = double.infinity;
  var bestCount = 4;
  var bestOutMx = px;
  var bestOutMy = py;
  var bestOutMz = pz;
  var bestOutBx = _tbx[0];
  var bestOutBy = _tby[0];
  var bestOutBz = _tbz[0];
  var outsideAny = false;

  for (final (i0, i1, i2, opp) in faces) {
    final e1x = _tmx[i1] - _tmx[i0];
    final e1y = _tmy[i1] - _tmy[i0];
    final e1z = _tmz[i1] - _tmz[i0];
    final e2x = _tmx[i2] - _tmx[i0];
    final e2y = _tmy[i2] - _tmy[i0];
    final e2z = _tmz[i2] - _tmz[i0];
    final fnx = e1y * e2z - e1z * e2y;
    final fny = e1z * e2x - e1x * e2z;
    final fnz = e1x * e2y - e1y * e2x;

    final signP =
        fnx * (px - _tmx[i0]) + fny * (py - _tmy[i0]) + fnz * (pz - _tmz[i0]);
    final signOpp =
        fnx * (_tmx[opp] - _tmx[i0]) +
        fny * (_tmy[opp] - _tmy[i0]) +
        fnz * (_tmz[opp] - _tmz[i0]);

    if (signP * signOpp <= 0.0) {
      outsideAny = true;
      _mx[0] = _tmx[i0];
      _my[0] = _tmy[i0];
      _mz[0] = _tmz[i0];
      _bx[0] = _tbx[i0];
      _by[0] = _tby[i0];
      _bz[0] = _tbz[i0];
      _mx[1] = _tmx[i1];
      _my[1] = _tmy[i1];
      _mz[1] = _tmz[i1];
      _bx[1] = _tbx[i1];
      _by[1] = _tby[i1];
      _bz[1] = _tbz[i1];
      _mx[2] = _tmx[i2];
      _my[2] = _tmy[i2];
      _mz[2] = _tmz[i2];
      _bx[2] = _tbx[i2];
      _by[2] = _tby[i2];
      _bz[2] = _tbz[i2];
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
          _bestMx[s] = _mx[s];
          _bestMy[s] = _my[s];
          _bestMz[s] = _mz[s];
          _bestBx[s] = _bx[s];
          _bestBy[s] = _by[s];
          _bestBz[s] = _bz[s];
        }
      }
    }
  }

  if (!outsideAny) {
    for (var k = 0; k < 4; k++) {
      _mx[k] = _tmx[k];
      _my[k] = _tmy[k];
      _mz[k] = _tmz[k];
      _bx[k] = _tbx[k];
      _by[k] = _tby[k];
      _bz[k] = _tbz[k];
    }
    outM.setValues(px, py, pz);
    outB.setValues(_tbx[0], _tby[0], _tbz[0]);
    return 4;
  }

  for (var s = 0; s < bestCount; s++) {
    _mx[s] = _bestMx[s];
    _my[s] = _bestMy[s];
    _mz[s] = _bestMz[s];
    _bx[s] = _bestBx[s];
    _by[s] = _bestBy[s];
    _bz[s] = _bestBz[s];
  }
  outM.setValues(bestOutMx, bestOutMy, bestOutMz);
  outB.setValues(bestOutBx, bestOutBy, bestOutBz);
  return bestCount;
}

final Quaternion _identityQuat = Quaternion.identity();
final Vector3 _unitScale = Vector3.all(1.0);
final Matrix4 _startMat = Matrix4.identity();
final Matrix4 _endMat = Matrix4.identity();
final Matrix4 _nodeMat = Matrix4.identity();
final Matrix4 _invMesh = Matrix4.identity();
final Aabb3 _aabbStart = Aabb3();
final Aabb3 _aabbEnd = Aabb3();
final Aabb3 _sweptAabb = Aabb3();
final Aabb3 _localSweptAabb = Aabb3();
final List<Collider3D> _colliderScratch = [];
final List<int> _triCandidates = [];

final Vector3 _cA = Vector3.zero();
final Vector3 _cB = Vector3.zero();
final Vector3 _tv0 = Vector3.zero();
final Vector3 _tv1 = Vector3.zero();
final Vector3 _tv2 = Vector3.zero();
final Vector3 _triCenter = Vector3.zero();

final Vector3 _dirPos = Vector3.zero();
final Vector3 _dirNeg = Vector3.zero();
final Vector3 _supA = Vector3.zero();
final Vector3 _supB = Vector3.zero();
final Vector3 _supM = Vector3.zero();
final Vector3 _closestM = Vector3.zero();
final Vector3 _closestB = Vector3.zero();

final Float64List _mx = Float64List(4);
final Float64List _my = Float64List(4);
final Float64List _mz = Float64List(4);
final Float64List _bx = Float64List(4);
final Float64List _by = Float64List(4);
final Float64List _bz = Float64List(4);

final Float64List _tmx = Float64List(4);
final Float64List _tmy = Float64List(4);
final Float64List _tmz = Float64List(4);
final Float64List _tbx = Float64List(4);
final Float64List _tby = Float64List(4);
final Float64List _tbz = Float64List(4);

final Float64List _bestMx = Float64List(3);
final Float64List _bestMy = Float64List(3);
final Float64List _bestMz = Float64List(3);
final Float64List _bestBx = Float64List(3);
final Float64List _bestBy = Float64List(3);
final Float64List _bestBz = Float64List(3);

class _SweepResult({
  required final double toi,
  required final Vector3 point,
  required final Vector3 normal,
});
