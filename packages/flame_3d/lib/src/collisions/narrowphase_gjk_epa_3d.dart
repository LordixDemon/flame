part of 'collision_manifold_3d.dart';

/// General Convex-Convex narrowphase using GJK + Expanding Polytope Algorithm
/// (with spherical direction fallback for degenerate simplices).
///
/// When both shapes have faces (boxes and non-degenerate hulls) and the EPA
/// normal is within about 5.7 degrees of one of their supporting faces, the
/// incident face is clipped against the reference face, which gives up to
/// four contact points with stable feature ids; otherwise (edge against
/// edge, or a curved shape) the manifold has the single EPA point.
void _convexConvexInto(
  Shape3D shapeA,
  Matrix4 transformA,
  Shape3D shapeB,
  Matrix4 transformB,
  MutableManifoldBuffer3D out,
) {
  final cA = centerOfMatrix3D(transformA, Narrowphase3D._scratch.gjk.cA);
  final cB = centerOfMatrix3D(transformB, Narrowphase3D._scratch.gjk.cB);
  if (!_gjkEpaRun(
    shapeA: shapeA,
    transformA: transformA,
    shapeB: shapeB,
    transformB: transformB,
    cAx: cA.x,
    cAy: cA.y,
    cAz: cA.z,
    cBx: cB.x,
    cBy: cB.y,
    cBz: cB.z,
  )) {
    return;
  }
  if (_writeSupportFace(
        shapeA,
        transformA,
        Narrowphase3D._scratch.gjk.epaNx,
        Narrowphase3D._scratch.gjk.epaNy,
        Narrowphase3D._scratch.gjk.epaNz,
        Narrowphase3D._scratch.clip.faceA,
      ) &&
      _writeSupportFace(
        shapeB,
        transformB,
        -Narrowphase3D._scratch.gjk.epaNx,
        -Narrowphase3D._scratch.gjk.epaNy,
        -Narrowphase3D._scratch.gjk.epaNz,
        Narrowphase3D._scratch.clip.faceB,
      )) {
    if (_clipSupportFacesInto(
      Narrowphase3D._scratch.gjk.epaNx,
      Narrowphase3D._scratch.gjk.epaNy,
      Narrowphase3D._scratch.gjk.epaNz,
      Narrowphase3D._scratch.clip.faceA,
      Narrowphase3D._scratch.clip.faceB,
      out,
      quantizeFloat32: true,
    )) {
      return;
    }
  }
  Narrowphase3D._scratch.clip.f32Contact[0] = Narrowphase3D._scratch.gjk.epaNx;
  Narrowphase3D._scratch.clip.f32Contact[1] = Narrowphase3D._scratch.gjk.epaNy;
  Narrowphase3D._scratch.clip.f32Contact[2] = Narrowphase3D._scratch.gjk.epaNz;
  Narrowphase3D._scratch.clip.f32Contact[3] = Narrowphase3D._scratch.gjk.epaAx;
  Narrowphase3D._scratch.clip.f32Contact[4] = Narrowphase3D._scratch.gjk.epaAy;
  Narrowphase3D._scratch.clip.f32Contact[5] = Narrowphase3D._scratch.gjk.epaAz;
  Narrowphase3D._scratch.clip.f32Contact[6] = Narrowphase3D._scratch.gjk.epaBx;
  Narrowphase3D._scratch.clip.f32Contact[7] = Narrowphase3D._scratch.gjk.epaBy;
  Narrowphase3D._scratch.clip.f32Contact[8] = Narrowphase3D._scratch.gjk.epaBz;
  out.pushSingle(
    Narrowphase3D._scratch.clip.f32Contact[0],
    Narrowphase3D._scratch.clip.f32Contact[1],
    Narrowphase3D._scratch.clip.f32Contact[2],
    Narrowphase3D._scratch.gjk.epaDepth,
    Narrowphase3D._scratch.clip.f32Contact[3],
    Narrowphase3D._scratch.clip.f32Contact[4],
    Narrowphase3D._scratch.clip.f32Contact[5],
    Narrowphase3D._scratch.clip.f32Contact[6],
    Narrowphase3D._scratch.clip.f32Contact[7],
    Narrowphase3D._scratch.clip.f32Contact[8],
  );
}

@pragma('vm:prefer-inline')
void _supportMinkowskiAt(
  int slot,
  double dx,
  double dy,
  double dz,
  Shape3D shapeA,
  Matrix4 transformA,
  Shape3D? shapeB,
  Matrix4? transformB,
  Vector3? triV0,
  Vector3? triV1,
  Vector3? triV2,
) {
  Narrowphase3D._scratch.gjk.gjkDirVec.setValues(dx, dy, dz);
  shapeA.supportPoint(
    Narrowphase3D._scratch.gjk.gjkDirVec,
    transformA,
    Narrowphase3D._scratch.gjk.gjkSupA,
  );
  Narrowphase3D._scratch.gjk.gjkNegDirVec.setValues(-dx, -dy, -dz);
  if (shapeB != null) {
    shapeB.supportPoint(
      Narrowphase3D._scratch.gjk.gjkNegDirVec,
      transformB!,
      Narrowphase3D._scratch.gjk.gjkSupB,
    );
  } else {
    triangleSupport3D(
      triV0!,
      triV1!,
      triV2!,
      Narrowphase3D._scratch.gjk.gjkNegDirVec,
      Narrowphase3D._scratch.gjk.gjkSupB,
    );
  }
  final o = slot * 3;
  final ax = Narrowphase3D._scratch.gjk.gjkSupA.x;
  final ay = Narrowphase3D._scratch.gjk.gjkSupA.y;
  final az = Narrowphase3D._scratch.gjk.gjkSupA.z;
  final bx = Narrowphase3D._scratch.gjk.gjkSupB.x;
  final by = Narrowphase3D._scratch.gjk.gjkSupB.y;
  final bz = Narrowphase3D._scratch.gjk.gjkSupB.z;
  Narrowphase3D._scratch.gjk.gjkA[o] = ax;
  Narrowphase3D._scratch.gjk.gjkA[o + 1] = ay;
  Narrowphase3D._scratch.gjk.gjkA[o + 2] = az;
  Narrowphase3D._scratch.gjk.gjkB[o] = bx;
  Narrowphase3D._scratch.gjk.gjkB[o + 1] = by;
  Narrowphase3D._scratch.gjk.gjkB[o + 2] = bz;
  Narrowphase3D._scratch.gjk.gjkP[o] = ax - bx;
  Narrowphase3D._scratch.gjk.gjkP[o + 1] = ay - by;
  Narrowphase3D._scratch.gjk.gjkP[o + 2] = az - bz;
}

@pragma('vm:prefer-inline')
void _copyGjkVert(int dst, int src) {
  final d = dst * 3;
  final s = src * 3;
  Narrowphase3D._scratch.gjk.gjkP[d] = Narrowphase3D._scratch.gjk.gjkP[s];
  Narrowphase3D._scratch.gjk.gjkP[d + 1] =
      Narrowphase3D._scratch.gjk.gjkP[s + 1];
  Narrowphase3D._scratch.gjk.gjkP[d + 2] =
      Narrowphase3D._scratch.gjk.gjkP[s + 2];
  Narrowphase3D._scratch.gjk.gjkA[d] = Narrowphase3D._scratch.gjk.gjkA[s];
  Narrowphase3D._scratch.gjk.gjkA[d + 1] =
      Narrowphase3D._scratch.gjk.gjkA[s + 1];
  Narrowphase3D._scratch.gjk.gjkA[d + 2] =
      Narrowphase3D._scratch.gjk.gjkA[s + 2];
  Narrowphase3D._scratch.gjk.gjkB[d] = Narrowphase3D._scratch.gjk.gjkB[s];
  Narrowphase3D._scratch.gjk.gjkB[d + 1] =
      Narrowphase3D._scratch.gjk.gjkB[s + 1];
  Narrowphase3D._scratch.gjk.gjkB[d + 2] =
      Narrowphase3D._scratch.gjk.gjkB[s + 2];
}

@pragma('vm:prefer-inline')
void _removeGjkVert(int index) {
  final last = Narrowphase3D._scratch.gjk.gjkVertCount - 1;
  for (var i = index; i < last; i++) {
    _copyGjkVert(i, i + 1);
  }
  Narrowphase3D._scratch.gjk.gjkVertCount = last;
}

@pragma('vm:prefer-inline')
void _swapGjkVerts(int i, int j) {
  _copyGjkVert(_GjkEpaScratch.gjkTempSlot, i);
  _copyGjkVert(i, j);
  _copyGjkVert(j, _GjkEpaScratch.gjkTempSlot);
}

bool _gjkEpaRun({
  required Shape3D shapeA,
  required Matrix4 transformA,
  required double cAx,
  required double cAy,
  required double cAz,
  required double cBx,
  required double cBy,
  required double cBz,
  Shape3D? shapeB,
  Matrix4? transformB,
  Vector3? triV0,
  Vector3? triV1,
  Vector3? triV2,
}) {
  Narrowphase3D._scratch.gjk.gjkDx = cBx - cAx;
  Narrowphase3D._scratch.gjk.gjkDy = cBy - cAy;
  Narrowphase3D._scratch.gjk.gjkDz = cBz - cAz;
  if (Narrowphase3D._scratch.gjk.gjkDx * Narrowphase3D._scratch.gjk.gjkDx +
          Narrowphase3D._scratch.gjk.gjkDy * Narrowphase3D._scratch.gjk.gjkDy +
          Narrowphase3D._scratch.gjk.gjkDz * Narrowphase3D._scratch.gjk.gjkDz <
      1e-12) {
    Narrowphase3D._scratch.gjk.gjkDx = 1.0;
    Narrowphase3D._scratch.gjk.gjkDy = 0.0;
    Narrowphase3D._scratch.gjk.gjkDz = 0.0;
  }

  Narrowphase3D._scratch.gjk.gjkVertCount = 1;
  _supportMinkowskiAt(
    0,
    Narrowphase3D._scratch.gjk.gjkDx,
    Narrowphase3D._scratch.gjk.gjkDy,
    Narrowphase3D._scratch.gjk.gjkDz,
    shapeA,
    transformA,
    shapeB,
    transformB,
    triV0,
    triV1,
    triV2,
  );
  Narrowphase3D._scratch.gjk.gjkDx = -Narrowphase3D._scratch.gjk.gjkP[0];
  Narrowphase3D._scratch.gjk.gjkDy = -Narrowphase3D._scratch.gjk.gjkP[1];
  Narrowphase3D._scratch.gjk.gjkDz = -Narrowphase3D._scratch.gjk.gjkP[2];

  var hit = false;
  for (var iter = 0; iter < 48; iter++) {
    if (Narrowphase3D._scratch.gjk.gjkDx * Narrowphase3D._scratch.gjk.gjkDx +
            Narrowphase3D._scratch.gjk.gjkDy *
                Narrowphase3D._scratch.gjk.gjkDy +
            Narrowphase3D._scratch.gjk.gjkDz *
                Narrowphase3D._scratch.gjk.gjkDz <
        1e-16) {
      hit = true;
      break;
    }
    final slot = Narrowphase3D._scratch.gjk.gjkVertCount;
    _supportMinkowskiAt(
      slot,
      Narrowphase3D._scratch.gjk.gjkDx,
      Narrowphase3D._scratch.gjk.gjkDy,
      Narrowphase3D._scratch.gjk.gjkDz,
      shapeA,
      transformA,
      shapeB,
      transformB,
      triV0,
      triV1,
      triV2,
    );
    final o = slot * 3;
    if (Narrowphase3D._scratch.gjk.gjkP[o] * Narrowphase3D._scratch.gjk.gjkDx +
            Narrowphase3D._scratch.gjk.gjkP[o + 1] *
                Narrowphase3D._scratch.gjk.gjkDy +
            Narrowphase3D._scratch.gjk.gjkP[o + 2] *
                Narrowphase3D._scratch.gjk.gjkDz <
        -1e-9) {
      return false;
    }
    Narrowphase3D._scratch.gjk.gjkVertCount = slot + 1;
    if (_updateGjkSimplexFlat()) {
      hit = true;
      break;
    }
  }
  if (!hit) {
    return false;
  }

  _epaSolveFlat(
    shapeA,
    transformA,
    shapeB,
    transformB,
    triV0,
    triV1,
    triV2,
    cAx,
    cAy,
    cAz,
    cBx,
    cBy,
    cBz,
  );
  return true;
}

bool _updateGjkSimplexFlat() {
  if (Narrowphase3D._scratch.gjk.gjkVertCount == 2) {
    final ax = Narrowphase3D._scratch.gjk.gjkP[3];
    final ay = Narrowphase3D._scratch.gjk.gjkP[4];
    final az = Narrowphase3D._scratch.gjk.gjkP[5];
    final abx = Narrowphase3D._scratch.gjk.gjkP[0] - ax;
    final aby = Narrowphase3D._scratch.gjk.gjkP[1] - ay;
    final abz = Narrowphase3D._scratch.gjk.gjkP[2] - az;
    final aox = -ax;
    final aoy = -ay;
    final aoz = -az;
    if (abx * aox + aby * aoy + abz * aoz > 0.0) {
      // (ab x ao) x ab
      final t1x = aby * aoz - abz * aoy;
      final t1y = abz * aox - abx * aoz;
      final t1z = abx * aoy - aby * aox;
      Narrowphase3D._scratch.gjk.gjkDx = t1y * abz - t1z * aby;
      Narrowphase3D._scratch.gjk.gjkDy = t1z * abx - t1x * abz;
      Narrowphase3D._scratch.gjk.gjkDz = t1x * aby - t1y * abx;
      if (Narrowphase3D._scratch.gjk.gjkDx * Narrowphase3D._scratch.gjk.gjkDx +
              Narrowphase3D._scratch.gjk.gjkDy *
                  Narrowphase3D._scratch.gjk.gjkDy +
              Narrowphase3D._scratch.gjk.gjkDz *
                  Narrowphase3D._scratch.gjk.gjkDz <
          1e-16) {
        _anyPerpScalars(abx, aby, abz);
      }
    } else {
      _removeGjkVert(0);
      Narrowphase3D._scratch.gjk.gjkDx = aox;
      Narrowphase3D._scratch.gjk.gjkDy = aoy;
      Narrowphase3D._scratch.gjk.gjkDz = aoz;
    }
    return false;
  }
  if (Narrowphase3D._scratch.gjk.gjkVertCount == 3) {
    final ax = Narrowphase3D._scratch.gjk.gjkP[6];
    final ay = Narrowphase3D._scratch.gjk.gjkP[7];
    final az = Narrowphase3D._scratch.gjk.gjkP[8];
    final abx = Narrowphase3D._scratch.gjk.gjkP[3] - ax;
    final aby = Narrowphase3D._scratch.gjk.gjkP[4] - ay;
    final abz = Narrowphase3D._scratch.gjk.gjkP[5] - az;
    final acx = Narrowphase3D._scratch.gjk.gjkP[0] - ax;
    final acy = Narrowphase3D._scratch.gjk.gjkP[1] - ay;
    final acz = Narrowphase3D._scratch.gjk.gjkP[2] - az;
    final abcx = aby * acz - abz * acy;
    final abcy = abz * acx - abx * acz;
    final abcz = abx * acy - aby * acx;
    final aox = -ax;
    final aoy = -ay;
    final aoz = -az;

    final c1x = abcy * acz - abcz * acy;
    final c1y = abcz * acx - abcx * acz;
    final c1z = abcx * acy - abcy * acx;
    if (c1x * aox + c1y * aoy + c1z * aoz > 0.0) {
      if (acx * aox + acy * aoy + acz * aoz > 0.0) {
        _removeGjkVert(1);
        final t1x = acy * aoz - acz * aoy;
        final t1y = acz * aox - acx * aoz;
        final t1z = acx * aoy - acy * aox;
        Narrowphase3D._scratch.gjk.gjkDx = t1y * acz - t1z * acy;
        Narrowphase3D._scratch.gjk.gjkDy = t1z * acx - t1x * acz;
        Narrowphase3D._scratch.gjk.gjkDz = t1x * acy - t1y * acx;
      } else if (abx * aox + aby * aoy + abz * aoz > 0.0) {
        _removeGjkVert(0);
        final t1x = aby * aoz - abz * aoy;
        final t1y = abz * aox - abx * aoz;
        final t1z = abx * aoy - aby * aox;
        Narrowphase3D._scratch.gjk.gjkDx = t1y * abz - t1z * aby;
        Narrowphase3D._scratch.gjk.gjkDy = t1z * abx - t1x * abz;
        Narrowphase3D._scratch.gjk.gjkDz = t1x * aby - t1y * abx;
      } else {
        _removeGjkVert(1);
        _removeGjkVert(0);
        Narrowphase3D._scratch.gjk.gjkDx = aox;
        Narrowphase3D._scratch.gjk.gjkDy = aoy;
        Narrowphase3D._scratch.gjk.gjkDz = aoz;
      }
      return false;
    }

    final c2x = aby * abcz - abz * abcy;
    final c2y = abz * abcx - abx * abcz;
    final c2z = abx * abcy - aby * abcx;
    if (c2x * aox + c2y * aoy + c2z * aoz > 0.0) {
      if (abx * aox + aby * aoy + abz * aoz > 0.0) {
        _removeGjkVert(0);
        final t1x = aby * aoz - abz * aoy;
        final t1y = abz * aox - abx * aoz;
        final t1z = abx * aoy - aby * aox;
        Narrowphase3D._scratch.gjk.gjkDx = t1y * abz - t1z * aby;
        Narrowphase3D._scratch.gjk.gjkDy = t1z * abx - t1x * abz;
        Narrowphase3D._scratch.gjk.gjkDz = t1x * aby - t1y * abx;
      } else {
        _removeGjkVert(1);
        _removeGjkVert(0);
        Narrowphase3D._scratch.gjk.gjkDx = aox;
        Narrowphase3D._scratch.gjk.gjkDy = aoy;
        Narrowphase3D._scratch.gjk.gjkDz = aoz;
      }
      return false;
    }

    if (abcx * aox + abcy * aoy + abcz * aoz > 0.0) {
      Narrowphase3D._scratch.gjk.gjkDx = abcx;
      Narrowphase3D._scratch.gjk.gjkDy = abcy;
      Narrowphase3D._scratch.gjk.gjkDz = abcz;
    } else {
      _swapGjkVerts(0, 1);
      Narrowphase3D._scratch.gjk.gjkDx = -abcx;
      Narrowphase3D._scratch.gjk.gjkDy = -abcy;
      Narrowphase3D._scratch.gjk.gjkDz = -abcz;
    }
    return false;
  }

  // Tetrahedron slots `[0:d, 1:c, 2:b, 3:a]`.
  final ax = Narrowphase3D._scratch.gjk.gjkP[9];
  final ay = Narrowphase3D._scratch.gjk.gjkP[10];
  final az = Narrowphase3D._scratch.gjk.gjkP[11];
  final aox = -ax;
  final aoy = -ay;
  final aoz = -az;
  final abx = Narrowphase3D._scratch.gjk.gjkP[6] - ax;
  final aby = Narrowphase3D._scratch.gjk.gjkP[7] - ay;
  final abz = Narrowphase3D._scratch.gjk.gjkP[8] - az;
  final acx = Narrowphase3D._scratch.gjk.gjkP[3] - ax;
  final acy = Narrowphase3D._scratch.gjk.gjkP[4] - ay;
  final acz = Narrowphase3D._scratch.gjk.gjkP[5] - az;
  final adx = Narrowphase3D._scratch.gjk.gjkP[0] - ax;
  final ady = Narrowphase3D._scratch.gjk.gjkP[1] - ay;
  final adz = Narrowphase3D._scratch.gjk.gjkP[2] - az;

  var abcx = aby * acz - abz * acy;
  var abcy = abz * acx - abx * acz;
  var abcz = abx * acy - aby * acx;
  if (abcx * adx + abcy * ady + abcz * adz > 0.0) {
    abcx = -abcx;
    abcy = -abcy;
    abcz = -abcz;
  }
  var acdx = acy * adz - acz * ady;
  var acdy = acz * adx - acx * adz;
  var acdz = acx * ady - acy * adx;
  if (acdx * abx + acdy * aby + acdz * abz > 0.0) {
    acdx = -acdx;
    acdy = -acdy;
    acdz = -acdz;
  }
  var adbx = ady * abz - adz * aby;
  var adby = adz * abx - adx * abz;
  var adbz = adx * aby - ady * abx;
  if (adbx * acx + adby * acy + adbz * acz > 0.0) {
    adbx = -adbx;
    adby = -adby;
    adbz = -adbz;
  }

  if (abcx * aox + abcy * aoy + abcz * aoz > 1e-12) {
    _removeGjkVert(0);
    Narrowphase3D._scratch.gjk.gjkDx = abcx;
    Narrowphase3D._scratch.gjk.gjkDy = abcy;
    Narrowphase3D._scratch.gjk.gjkDz = abcz;
    return false;
  }
  if (acdx * aox + acdy * aoy + acdz * aoz > 1e-12) {
    _removeGjkVert(2);
    Narrowphase3D._scratch.gjk.gjkDx = acdx;
    Narrowphase3D._scratch.gjk.gjkDy = acdy;
    Narrowphase3D._scratch.gjk.gjkDz = acdz;
    return false;
  }
  if (adbx * aox + adby * aoy + adbz * aoz > 1e-12) {
    _removeGjkVert(1);
    Narrowphase3D._scratch.gjk.gjkDx = adbx;
    Narrowphase3D._scratch.gjk.gjkDy = adby;
    Narrowphase3D._scratch.gjk.gjkDz = adbz;
    return false;
  }
  return true;
}

void _anyPerpScalars(double vx, double vy, double vz) {
  double x;
  double y;
  double z;
  if (vx.abs() < 0.9) {
    x = 0.0;
    y = -vz;
    z = vy;
  } else {
    x = -vz;
    y = 0.0;
    z = vx;
  }
  if (x * x + y * y + z * z < 1e-18) {
    Narrowphase3D._scratch.gjk.gjkDx = 0.0;
    Narrowphase3D._scratch.gjk.gjkDy = 1.0;
    Narrowphase3D._scratch.gjk.gjkDz = 0.0;
  } else {
    Narrowphase3D._scratch.gjk.gjkDx = x;
    Narrowphase3D._scratch.gjk.gjkDy = y;
    Narrowphase3D._scratch.gjk.gjkDz = z;
  }
}

void _appendEpaFace(
  int i0,
  int i1,
  int i2,
  double ix,
  double iy,
  double iz,
) {
  final o0 = i0 * 3;
  final o1 = i1 * 3;
  final o2 = i2 * 3;
  final p0x = Narrowphase3D._scratch.gjk.gjkP[o0];
  final p0y = Narrowphase3D._scratch.gjk.gjkP[o0 + 1];
  final p0z = Narrowphase3D._scratch.gjk.gjkP[o0 + 2];
  final e1x = Narrowphase3D._scratch.gjk.gjkP[o1] - p0x;
  final e1y = Narrowphase3D._scratch.gjk.gjkP[o1 + 1] - p0y;
  final e1z = Narrowphase3D._scratch.gjk.gjkP[o1 + 2] - p0z;
  final e2x = Narrowphase3D._scratch.gjk.gjkP[o2] - p0x;
  final e2y = Narrowphase3D._scratch.gjk.gjkP[o2 + 1] - p0y;
  final e2z = Narrowphase3D._scratch.gjk.gjkP[o2 + 2] - p0z;
  var nx = e1y * e2z - e1z * e2y;
  var ny = e1z * e2x - e1x * e2z;
  var nz = e1x * e2y - e1y * e2x;
  final len = math.sqrt(nx * nx + ny * ny + nz * nz);
  if (len <= 1e-12) {
    return;
  }
  final invLen = 1.0 / len;
  nx *= invLen;
  ny *= invLen;
  nz *= invLen;
  var b1 = i1;
  var b2 = i2;
  if (nx * (p0x - ix) + ny * (p0y - iy) + nz * (p0z - iz) < 0.0) {
    nx = -nx;
    ny = -ny;
    nz = -nz;
    b1 = i2;
    b2 = i1;
  }
  final dist = math.max(0.0, nx * p0x + ny * p0y + nz * p0z);
  final fIdx = Narrowphase3D._scratch.gjk.epaFaceCount;
  Narrowphase3D._scratch.gjk.ensureEpaFaceCapacity(fIdx + 1);
  Narrowphase3D._scratch.gjk.epaFaceCount = fIdx + 1;
  Narrowphase3D._scratch.gjk.epaI0[fIdx] = i0;
  Narrowphase3D._scratch.gjk.epaI1[fIdx] = b1;
  Narrowphase3D._scratch.gjk.epaI2[fIdx] = b2;
  final fo = fIdx * 3;
  Narrowphase3D._scratch.gjk.epaFn[fo] = nx;
  Narrowphase3D._scratch.gjk.epaFn[fo + 1] = ny;
  Narrowphase3D._scratch.gjk.epaFn[fo + 2] = nz;
  Narrowphase3D._scratch.gjk.epaFd[fIdx] = dist;
}

void _addHorizonEdgeFlat(int a, int b) {
  for (var i = 0; i < Narrowphase3D._scratch.gjk.epaHorizCount; i++) {
    if (Narrowphase3D._scratch.gjk.epaHorizA[i] == b &&
        Narrowphase3D._scratch.gjk.epaHorizB[i] == a) {
      final last = Narrowphase3D._scratch.gjk.epaHorizCount - 1;
      for (var k = i; k < last; k++) {
        Narrowphase3D._scratch.gjk.epaHorizA[k] =
            Narrowphase3D._scratch.gjk.epaHorizA[k + 1];
        Narrowphase3D._scratch.gjk.epaHorizB[k] =
            Narrowphase3D._scratch.gjk.epaHorizB[k + 1];
      }
      Narrowphase3D._scratch.gjk.epaHorizCount = last;
      return;
    }
  }
  final idx = Narrowphase3D._scratch.gjk.epaHorizCount;
  Narrowphase3D._scratch.gjk.ensureEpaHorizonCapacity(idx + 1);
  Narrowphase3D._scratch.gjk.epaHorizCount = idx + 1;
  Narrowphase3D._scratch.gjk.epaHorizA[idx] = a;
  Narrowphase3D._scratch.gjk.epaHorizB[idx] = b;
}

double _tetraVolumeAbsFlat() {
  final abx =
      Narrowphase3D._scratch.gjk.gjkP[3] - Narrowphase3D._scratch.gjk.gjkP[0];
  final aby =
      Narrowphase3D._scratch.gjk.gjkP[4] - Narrowphase3D._scratch.gjk.gjkP[1];
  final abz =
      Narrowphase3D._scratch.gjk.gjkP[5] - Narrowphase3D._scratch.gjk.gjkP[2];
  final acx =
      Narrowphase3D._scratch.gjk.gjkP[6] - Narrowphase3D._scratch.gjk.gjkP[0];
  final acy =
      Narrowphase3D._scratch.gjk.gjkP[7] - Narrowphase3D._scratch.gjk.gjkP[1];
  final acz =
      Narrowphase3D._scratch.gjk.gjkP[8] - Narrowphase3D._scratch.gjk.gjkP[2];
  final adx =
      Narrowphase3D._scratch.gjk.gjkP[9] - Narrowphase3D._scratch.gjk.gjkP[0];
  final ady =
      Narrowphase3D._scratch.gjk.gjkP[10] - Narrowphase3D._scratch.gjk.gjkP[1];
  final adz =
      Narrowphase3D._scratch.gjk.gjkP[11] - Narrowphase3D._scratch.gjk.gjkP[2];
  final cx = aby * acz - abz * acy;
  final cy = abz * acx - abx * acz;
  final cz = abx * acy - aby * acx;
  return (cx * adx + cy * ady + cz * adz).abs();
}

void _epaSolveFlat(
  Shape3D shapeA,
  Matrix4 transformA,
  Shape3D? shapeB,
  Matrix4? transformB,
  Vector3? triV0,
  Vector3? triV1,
  Vector3? triV2,
  double cAx,
  double cAy,
  double cAz,
  double cBx,
  double cBy,
  double cBz,
) {
  // Pad simplex to 4 non-coplanar vertices if GJK terminated early on an
  // edge/triangle containing the origin.
  for (var d = 0; d < _GjkEpaScratch.seedDirs.length; d++) {
    if (Narrowphase3D._scratch.gjk.gjkVertCount >= 4 &&
        _tetraVolumeAbsFlat() > 1e-9) {
      break;
    }
    final probe = _GjkEpaScratch.seedDirs[d];
    _supportMinkowskiAt(
      _GjkEpaScratch.gjkTempSlot,
      probe.x,
      probe.y,
      probe.z,
      shapeA,
      transformA,
      shapeB,
      transformB,
      triV0,
      triV1,
      triV2,
    );
    final cx = Narrowphase3D._scratch.gjk.gjkP[_GjkEpaScratch.gjkTempSlot * 3];
    final cy =
        Narrowphase3D._scratch.gjk.gjkP[_GjkEpaScratch.gjkTempSlot * 3 + 1];
    final cz =
        Narrowphase3D._scratch.gjk.gjkP[_GjkEpaScratch.gjkTempSlot * 3 + 2];
    var dup = false;
    for (var i = 0; i < Narrowphase3D._scratch.gjk.gjkVertCount; i++) {
      final eo = i * 3;
      final dx = Narrowphase3D._scratch.gjk.gjkP[eo] - cx;
      final dy = Narrowphase3D._scratch.gjk.gjkP[eo + 1] - cy;
      final dz = Narrowphase3D._scratch.gjk.gjkP[eo + 2] - cz;
      if (dx * dx + dy * dy + dz * dz < 1e-10) {
        dup = true;
        break;
      }
    }
    if (!dup) {
      if (Narrowphase3D._scratch.gjk.gjkVertCount < 4) {
        _copyGjkVert(
          Narrowphase3D._scratch.gjk.gjkVertCount,
          _GjkEpaScratch.gjkTempSlot,
        );
        Narrowphase3D._scratch.gjk.gjkVertCount++;
      } else {
        _copyGjkVert(3, _GjkEpaScratch.gjkTempSlot);
      }
    }
  }

  if (Narrowphase3D._scratch.gjk.gjkVertCount < 4 ||
      _tetraVolumeAbsFlat() <= 1e-9) {
    _sampledFallbackManifoldFlat(
      shapeA,
      transformA,
      shapeB,
      transformB,
      triV0,
      triV1,
      triV2,
      cAx,
      cAy,
      cAz,
      cBx,
      cBy,
      cBz,
    );
    return;
  }

  // Orient initial tetrahedron faces outward from its interior centroid.
  final ix =
      (Narrowphase3D._scratch.gjk.gjkP[0] +
          Narrowphase3D._scratch.gjk.gjkP[3] +
          Narrowphase3D._scratch.gjk.gjkP[6] +
          Narrowphase3D._scratch.gjk.gjkP[9]) *
      0.25;
  final iy =
      (Narrowphase3D._scratch.gjk.gjkP[1] +
          Narrowphase3D._scratch.gjk.gjkP[4] +
          Narrowphase3D._scratch.gjk.gjkP[7] +
          Narrowphase3D._scratch.gjk.gjkP[10]) *
      0.25;
  final iz =
      (Narrowphase3D._scratch.gjk.gjkP[2] +
          Narrowphase3D._scratch.gjk.gjkP[5] +
          Narrowphase3D._scratch.gjk.gjkP[8] +
          Narrowphase3D._scratch.gjk.gjkP[11]) *
      0.25;
  Narrowphase3D._scratch.gjk.epaFaceCount = 0;
  _appendEpaFace(0, 1, 2, ix, iy, iz);
  _appendEpaFace(0, 2, 3, ix, iy, iz);
  _appendEpaFace(0, 3, 1, ix, iy, iz);
  _appendEpaFace(1, 3, 2, ix, iy, iz);

  if (Narrowphase3D._scratch.gjk.epaFaceCount == 0) {
    _sampledFallbackManifoldFlat(
      shapeA,
      transformA,
      shapeB,
      transformB,
      triV0,
      triV1,
      triV2,
      cAx,
      cAy,
      cAz,
      cBx,
      cBy,
      cBz,
    );
    return;
  }

  for (var iter = 0; iter < 48; iter++) {
    var bestIdx = 0;
    var bestDist = Narrowphase3D._scratch.gjk.epaFd[0];
    for (var i = 1; i < Narrowphase3D._scratch.gjk.epaFaceCount; i++) {
      final fd = Narrowphase3D._scratch.gjk.epaFd[i];
      if (fd < bestDist) {
        bestDist = fd;
        bestIdx = i;
      }
    }
    final bestI0 = Narrowphase3D._scratch.gjk.epaI0[bestIdx];
    final bestI1 = Narrowphase3D._scratch.gjk.epaI1[bestIdx];
    final bestI2 = Narrowphase3D._scratch.gjk.epaI2[bestIdx];
    final bestFo = bestIdx * 3;
    final bestNx = Narrowphase3D._scratch.gjk.epaFn[bestFo];
    final bestNy = Narrowphase3D._scratch.gjk.epaFn[bestFo + 1];
    final bestNz = Narrowphase3D._scratch.gjk.epaFn[bestFo + 2];

    _supportMinkowskiAt(
      _GjkEpaScratch.gjkTempSlot,
      bestNx,
      bestNy,
      bestNz,
      shapeA,
      transformA,
      shapeB,
      transformB,
      triV0,
      triV1,
      triV2,
    );
    final sx = Narrowphase3D._scratch.gjk.gjkP[_GjkEpaScratch.gjkTempSlot * 3];
    final sy =
        Narrowphase3D._scratch.gjk.gjkP[_GjkEpaScratch.gjkTempSlot * 3 + 1];
    final sz =
        Narrowphase3D._scratch.gjk.gjkP[_GjkEpaScratch.gjkTempSlot * 3 + 2];
    final supportDist = sx * bestNx + sy * bestNy + sz * bestNz;

    if (supportDist - bestDist <= 1e-4 ||
        Narrowphase3D._scratch.gjk.gjkVertCount >= _GjkEpaScratch.maxEpaVerts) {
      _manifoldFromEpaFaceFlat(
        bestI0,
        bestI1,
        bestI2,
        bestNx,
        bestNy,
        bestNz,
        bestDist,
      );
      return;
    }

    final newIdx = Narrowphase3D._scratch.gjk.gjkVertCount;
    _copyGjkVert(newIdx, _GjkEpaScratch.gjkTempSlot);
    Narrowphase3D._scratch.gjk.gjkVertCount = newIdx + 1;

    // Remove all faces visible from `sup.p` (preserving order) and collect
    // horizon edges in the same reverse sweep.
    Narrowphase3D._scratch.gjk.epaHorizCount = 0;
    for (var i = Narrowphase3D._scratch.gjk.epaFaceCount - 1; i >= 0; i--) {
      final fo = i * 3;
      final fnx = Narrowphase3D._scratch.gjk.epaFn[fo];
      final fny = Narrowphase3D._scratch.gjk.epaFn[fo + 1];
      final fnz = Narrowphase3D._scratch.gjk.epaFn[fo + 2];
      final f0 = Narrowphase3D._scratch.gjk.epaI0[i];
      final o0 = f0 * 3;
      final dot =
          fnx * (sx - Narrowphase3D._scratch.gjk.gjkP[o0]) +
          fny * (sy - Narrowphase3D._scratch.gjk.gjkP[o0 + 1]) +
          fnz * (sz - Narrowphase3D._scratch.gjk.gjkP[o0 + 2]);
      if (dot > 1e-7) {
        Narrowphase3D._scratch.gjk.epaVisible[i] = 1;
        final f1 = Narrowphase3D._scratch.gjk.epaI1[i];
        final f2 = Narrowphase3D._scratch.gjk.epaI2[i];
        _addHorizonEdgeFlat(f0, f1);
        _addHorizonEdgeFlat(f1, f2);
        _addHorizonEdgeFlat(f2, f0);
      } else {
        Narrowphase3D._scratch.gjk.epaVisible[i] = 0;
      }
    }
    var write = 0;
    for (var i = 0; i < Narrowphase3D._scratch.gjk.epaFaceCount; i++) {
      if (Narrowphase3D._scratch.gjk.epaVisible[i] == 0) {
        if (write != i) {
          Narrowphase3D._scratch.gjk.epaI0[write] =
              Narrowphase3D._scratch.gjk.epaI0[i];
          Narrowphase3D._scratch.gjk.epaI1[write] =
              Narrowphase3D._scratch.gjk.epaI1[i];
          Narrowphase3D._scratch.gjk.epaI2[write] =
              Narrowphase3D._scratch.gjk.epaI2[i];
          final wo = write * 3;
          final ro = i * 3;
          Narrowphase3D._scratch.gjk.epaFn[wo] =
              Narrowphase3D._scratch.gjk.epaFn[ro];
          Narrowphase3D._scratch.gjk.epaFn[wo + 1] =
              Narrowphase3D._scratch.gjk.epaFn[ro + 1];
          Narrowphase3D._scratch.gjk.epaFn[wo + 2] =
              Narrowphase3D._scratch.gjk.epaFn[ro + 2];
          Narrowphase3D._scratch.gjk.epaFd[write] =
              Narrowphase3D._scratch.gjk.epaFd[i];
        }
        write++;
      }
    }
    Narrowphase3D._scratch.gjk.epaFaceCount = write;

    if (Narrowphase3D._scratch.gjk.epaHorizCount == 0) {
      _manifoldFromEpaFaceFlat(
        bestI0,
        bestI1,
        bestI2,
        bestNx,
        bestNy,
        bestNz,
        bestDist,
      );
      return;
    }

    for (var h = 0; h < Narrowphase3D._scratch.gjk.epaHorizCount; h++) {
      _appendEpaFace(
        Narrowphase3D._scratch.gjk.epaHorizA[h],
        Narrowphase3D._scratch.gjk.epaHorizB[h],
        newIdx,
        ix,
        iy,
        iz,
      );
    }

    if (Narrowphase3D._scratch.gjk.epaFaceCount == 0) {
      _manifoldFromEpaFaceFlat(
        bestI0,
        bestI1,
        bestI2,
        bestNx,
        bestNy,
        bestNz,
        bestDist,
      );
      return;
    }
  }

  var bestIdx = 0;
  var bestDist = Narrowphase3D._scratch.gjk.epaFd[0];
  for (var i = 1; i < Narrowphase3D._scratch.gjk.epaFaceCount; i++) {
    if (Narrowphase3D._scratch.gjk.epaFd[i] < bestDist) {
      bestDist = Narrowphase3D._scratch.gjk.epaFd[i];
      bestIdx = i;
    }
  }
  final fo = bestIdx * 3;
  _manifoldFromEpaFaceFlat(
    Narrowphase3D._scratch.gjk.epaI0[bestIdx],
    Narrowphase3D._scratch.gjk.epaI1[bestIdx],
    Narrowphase3D._scratch.gjk.epaI2[bestIdx],
    Narrowphase3D._scratch.gjk.epaFn[fo],
    Narrowphase3D._scratch.gjk.epaFn[fo + 1],
    Narrowphase3D._scratch.gjk.epaFn[fo + 2],
    bestDist,
  );
}

void _manifoldFromEpaFaceFlat(
  int i0,
  int i1,
  int i2,
  double nx,
  double ny,
  double nz,
  double dist,
) {
  final o0 = i0 * 3;
  final o1 = i1 * 3;
  final o2 = i2 * 3;
  final p0x = Narrowphase3D._scratch.gjk.gjkP[o0];
  final p0y = Narrowphase3D._scratch.gjk.gjkP[o0 + 1];
  final p0z = Narrowphase3D._scratch.gjk.gjkP[o0 + 2];

  // Project origin onto triangle `(v0.p, v1.p, v2.p)` to interpolate exact
  // witness points on A and B via barycentric weights.
  final e0x = Narrowphase3D._scratch.gjk.gjkP[o1] - p0x;
  final e0y = Narrowphase3D._scratch.gjk.gjkP[o1 + 1] - p0y;
  final e0z = Narrowphase3D._scratch.gjk.gjkP[o1 + 2] - p0z;
  final e1x = Narrowphase3D._scratch.gjk.gjkP[o2] - p0x;
  final e1y = Narrowphase3D._scratch.gjk.gjkP[o2 + 1] - p0y;
  final e1z = Narrowphase3D._scratch.gjk.gjkP[o2 + 2] - p0z;
  final epx = nx * dist - p0x;
  final epy = ny * dist - p0y;
  final epz = nz * dist - p0z;
  final d00 = e0x * e0x + e0y * e0y + e0z * e0z;
  final d01 = e0x * e1x + e0y * e1y + e0z * e1z;
  final d11 = e1x * e1x + e1y * e1y + e1z * e1z;
  final d20 = epx * e0x + epy * e0y + epz * e0z;
  final d21 = epx * e1x + epy * e1y + epz * e1z;
  final denom = d00 * d11 - d01 * d01;
  var u = 1.0 / 3.0;
  var v = 1.0 / 3.0;
  var w = 1.0 / 3.0;
  if (denom.abs() > 1e-14) {
    v = ((d11 * d20 - d01 * d21) / denom).clamp(0.0, 1.0);
    w = ((d00 * d21 - d01 * d20) / denom).clamp(0.0, 1.0 - v);
    u = 1.0 - v - w;
  }

  Narrowphase3D._scratch.gjk.epaNx = nx;
  Narrowphase3D._scratch.gjk.epaNy = ny;
  Narrowphase3D._scratch.gjk.epaNz = nz;
  Narrowphase3D._scratch.gjk.epaDepth = dist;
  Narrowphase3D._scratch.gjk.epaAx =
      Narrowphase3D._scratch.gjk.gjkA[o0] * u +
      Narrowphase3D._scratch.gjk.gjkA[o1] * v +
      Narrowphase3D._scratch.gjk.gjkA[o2] * w;
  Narrowphase3D._scratch.gjk.epaAy =
      Narrowphase3D._scratch.gjk.gjkA[o0 + 1] * u +
      Narrowphase3D._scratch.gjk.gjkA[o1 + 1] * v +
      Narrowphase3D._scratch.gjk.gjkA[o2 + 1] * w;
  Narrowphase3D._scratch.gjk.epaAz =
      Narrowphase3D._scratch.gjk.gjkA[o0 + 2] * u +
      Narrowphase3D._scratch.gjk.gjkA[o1 + 2] * v +
      Narrowphase3D._scratch.gjk.gjkA[o2 + 2] * w;
  Narrowphase3D._scratch.gjk.epaBx =
      Narrowphase3D._scratch.gjk.gjkB[o0] * u +
      Narrowphase3D._scratch.gjk.gjkB[o1] * v +
      Narrowphase3D._scratch.gjk.gjkB[o2] * w;
  Narrowphase3D._scratch.gjk.epaBy =
      Narrowphase3D._scratch.gjk.gjkB[o0 + 1] * u +
      Narrowphase3D._scratch.gjk.gjkB[o1 + 1] * v +
      Narrowphase3D._scratch.gjk.gjkB[o2 + 1] * w;
  Narrowphase3D._scratch.gjk.epaBz =
      Narrowphase3D._scratch.gjk.gjkB[o0 + 2] * u +
      Narrowphase3D._scratch.gjk.gjkB[o1 + 2] * v +
      Narrowphase3D._scratch.gjk.gjkB[o2 + 2] * w;
}

void _sampledFallbackManifoldFlat(
  Shape3D shapeA,
  Matrix4 transformA,
  Shape3D? shapeB,
  Matrix4? transformB,
  Vector3? triV0,
  Vector3? triV1,
  Vector3? triV2,
  double cAx,
  double cAy,
  double cAz,
  double cBx,
  double cBy,
  double cBz,
) {
  var bestDepth = double.infinity;
  var bestNx = 0.0;
  var bestNy = 1.0;
  var bestNz = 0.0;
  var bestAx = cAx;
  var bestAy = cAy;
  var bestAz = cAz;
  var bestBx = cBx;
  var bestBy = cBy;
  var bestBz = cBz;

  const co = _GjkEpaScratch.gjkTempSlot * 3;
  for (var i = 0; i < _GjkEpaScratch.seedDirs.length; i++) {
    final dir = _GjkEpaScratch.seedDirs[i];
    _supportMinkowskiAt(
      _GjkEpaScratch.gjkTempSlot,
      dir.x,
      dir.y,
      dir.z,
      shapeA,
      transformA,
      shapeB,
      transformB,
      triV0,
      triV1,
      triV2,
    );
    final d =
        Narrowphase3D._scratch.gjk.gjkP[co] * dir.x +
        Narrowphase3D._scratch.gjk.gjkP[co + 1] * dir.y +
        Narrowphase3D._scratch.gjk.gjkP[co + 2] * dir.z;
    if (d >= 0.0 && d < bestDepth) {
      bestDepth = d;
      bestNx = dir.x;
      bestNy = dir.y;
      bestNz = dir.z;
      bestAx = Narrowphase3D._scratch.gjk.gjkA[co];
      bestAy = Narrowphase3D._scratch.gjk.gjkA[co + 1];
      bestAz = Narrowphase3D._scratch.gjk.gjkA[co + 2];
      bestBx = Narrowphase3D._scratch.gjk.gjkB[co];
      bestBy = Narrowphase3D._scratch.gjk.gjkB[co + 1];
      bestBz = Narrowphase3D._scratch.gjk.gjkB[co + 2];
    }
  }
  if (!bestDepth.isFinite) {
    bestDepth = 0.0;
  }
  Narrowphase3D._scratch.gjk.epaNx = bestNx;
  Narrowphase3D._scratch.gjk.epaNy = bestNy;
  Narrowphase3D._scratch.gjk.epaNz = bestNz;
  Narrowphase3D._scratch.gjk.epaDepth = bestDepth;
  Narrowphase3D._scratch.gjk.epaAx = bestAx;
  Narrowphase3D._scratch.gjk.epaAy = bestAy;
  Narrowphase3D._scratch.gjk.epaAz = bestAz;
  Narrowphase3D._scratch.gjk.epaBx = bestBx;
  Narrowphase3D._scratch.gjk.epaBy = bestBy;
  Narrowphase3D._scratch.gjk.epaBz = bestBz;
}

List<Vector3> _buildSphereDirs() {
  final dirs = <Vector3>[
    Vector3(1, 0, 0),
    Vector3(-1, 0, 0),
    Vector3(0, 1, 0),
    Vector3(0, -1, 0),
    Vector3(0, 0, 1),
    Vector3(0, 0, -1),
  ];
  const s2 = 0.7071067811865475;
  const s3 = 0.5773502691896258;
  for (final sx in const [-1.0, 1.0]) {
    for (final sy in const [-1.0, 1.0]) {
      dirs
        ..add(Vector3(sx * s2, sy * s2, 0))
        ..add(Vector3(sx * s2, 0, sy * s2))
        ..add(Vector3(0, sx * s2, sy * s2));
      for (final sz in const [-1.0, 1.0]) {
        dirs.add(Vector3(sx * s3, sy * s3, sz * s3));
      }
    }
  }
  return List.unmodifiable(dirs);
}
