part of 'collision_manifold_3d.dart';

final Vector3 _boxNormalScratch = Vector3.zero();
final Vector3 _boxNormalNegScratch = Vector3.zero();
final _ObbFrame _obbA = _ObbFrame();
final _ObbFrame _obbB = _ObbFrame();
int _satBestAxisCode = -1;
double _satMinPen = 0.0;

void _sphereSphereInto(
  SphereShape3D a,
  Matrix4 transformA,
  SphereShape3D b,
  Matrix4 transformB,
  MutableManifoldBuffer3D out,
) {
  final mA = transformA.storage;
  final mB = transformB.storage;
  _pushSphereSphereInto(
    mA[12],
    mA[13],
    mA[14],
    a.worldRadius(transformA),
    mB[12],
    mB[13],
    mB[14],
    b.worldRadius(transformB),
    out,
    flip: false,
  );
}

void _sphereCapsuleInto(
  SphereShape3D a,
  Matrix4 transformA,
  CapsuleShape3D b,
  Matrix4 transformB,
  MutableManifoldBuffer3D out, {
  required bool flip,
}) {
  final mA = transformA.storage;
  final cAx = mA[12];
  final cAy = mA[13];
  final cAz = mA[14];
  final rA = a.worldRadius(transformA);
  final rB = b.worldSpine(transformB, _segB0, _segB1);
  closestPointOnSegment3D(cAx, cAy, cAz, _segB0, _segB1, _ptB);
  _pushSphereSphereInto(
    cAx,
    cAy,
    cAz,
    rA,
    _ptB.x,
    _ptB.y,
    _ptB.z,
    rB,
    out,
    flip: flip,
  );
}

void _capsuleCapsuleInto(
  CapsuleShape3D a,
  Matrix4 transformA,
  CapsuleShape3D b,
  Matrix4 transformB,
  MutableManifoldBuffer3D out,
) {
  final rA = a.worldSpine(transformA, _segA0, _segA1);
  final rB = b.worldSpine(transformB, _segB0, _segB1);
  closestPointsSegmentSegment3D(_segA0, _segA1, _segB0, _segB1, _ptA, _ptB);
  _pushSphereSphereInto(
    _ptA.x,
    _ptA.y,
    _ptA.z,
    rA,
    _ptB.x,
    _ptB.y,
    _ptB.z,
    rB,
    out,
    flip: false,
  );
}

void _sphereBoxInto(
  SphereShape3D a,
  Matrix4 transformA,
  BoxShape3D b,
  Matrix4 transformB,
  MutableManifoldBuffer3D out, {
  required bool flip,
}) {
  final mA = transformA.storage;
  final rA = a.worldRadius(transformA);
  _obbB.extract(b, transformB);
  _pushSphereObbInto(mA[12], mA[13], mA[14], rA, _obbB, out, flip: flip);
}

void _capsuleBoxInto(
  CapsuleShape3D a,
  Matrix4 transformA,
  BoxShape3D b,
  Matrix4 transformB,
  MutableManifoldBuffer3D out, {
  required bool flip,
}) {
  final rA = a.worldSpine(transformA, _segA0, _segA1);
  _obbB.extract(b, transformB);

  final p0x = _obbB.toLocalX(_segA0.x, _segA0.y, _segA0.z);
  final p0y = _obbB.toLocalY(_segA0.x, _segA0.y, _segA0.z);
  final p0z = _obbB.toLocalZ(_segA0.x, _segA0.y, _segA0.z);
  final p1x = _obbB.toLocalX(_segA1.x, _segA1.y, _segA1.z);
  final p1y = _obbB.toLocalY(_segA1.x, _segA1.y, _segA1.z);
  final p1z = _obbB.toLocalZ(_segA1.x, _segA1.y, _segA1.z);

  final bestT = _closestSegmentParamToAabb(
    p0x,
    p0y,
    p0z,
    p1x - p0x,
    p1y - p0y,
    p1z - p0z,
    _obbB.ex,
    _obbB.ey,
    _obbB.ez,
  );

  final sx = _segA0.x + (_segA1.x - _segA0.x) * bestT;
  final sy = _segA0.y + (_segA1.y - _segA0.y) * bestT;
  final sz = _segA0.z + (_segA1.z - _segA0.z) * bestT;
  _pushSphereObbInto(sx, sy, sz, rA, _obbB, out, flip: flip);
}

void _boxBoxInto(
  BoxShape3D a,
  Matrix4 transformA,
  BoxShape3D b,
  Matrix4 transformB,
  MutableManifoldBuffer3D out,
) {
  if (!_solveBoxBoxSat(a, transformA, b, transformB)) {
    return;
  }
  final bestAxisCode = _satBestAxisCode;
  final minPen = _satMinPen;
  final nx = _boxNormalScratch.x;
  final ny = _boxNormalScratch.y;
  final nz = _boxNormalScratch.z;

  if (bestAxisCode < 6) {
    _writeObbFace(_obbA, nx, ny, nz, _faceA);
    _writeObbFace(_obbB, -nx, -ny, -nz, _faceB);
    if (_clipSupportFacesInto(
      nx,
      ny,
      nz,
      _faceA,
      _faceB,
      out,
      forceReference: bestAxisCode < 3 ? 1 : 2,
      depthOverride: minPen,
    )) {
      return;
    }
  }

  if (bestAxisCode >= 6) {
    final edgePair = bestAxisCode - 6;
    final axisA = edgePair ~/ 3;
    final axisB = edgePair % 3;
    _obbA.supportEdge(axisA, nx, ny, nz, _segA0, _segA1);
    _obbB.supportEdge(axisB, -nx, -ny, -nz, _segB0, _segB1);
    closestPointsSegmentSegment3D(
      _segA0,
      _segA1,
      _segB0,
      _segB1,
      _ptA,
      _ptB,
    );
    out.pushSingle(
      nx,
      ny,
      nz,
      minPen,
      _ptA.x,
      _ptA.y,
      _ptA.z,
      _ptB.x,
      _ptB.y,
      _ptB.z,
    );
    return;
  }

  a.supportPoint(_boxNormalScratch, transformA, _ptA);
  _boxNormalNegScratch.setValues(-nx, -ny, -nz);
  b.supportPoint(_boxNormalNegScratch, transformB, _ptB);
  out.pushSingle(
    nx,
    ny,
    nz,
    minPen,
    _ptA.x,
    _ptA.y,
    _ptA.z,
    _ptB.x,
    _ptB.y,
    _ptB.z,
  );
}

bool _solveBoxBoxSat(
  BoxShape3D a,
  Matrix4 transformA,
  BoxShape3D b,
  Matrix4 transformB,
) {
  _obbA.extract(a, transformA);
  _obbB.extract(b, transformB);

  final tx = _obbB.cx - _obbA.cx;
  final ty = _obbB.cy - _obbA.cy;
  final tz = _obbB.cz - _obbA.cz;

  var minPen = double.infinity;
  var bestAxisCode = -1;

  bool testAxis(
    double ax,
    double ay,
    double az,
    int code,
    double bias, [
    double slack = 0.0,
  ]) {
    final len2 = ax * ax + ay * ay + az * az;
    if (len2 < 1e-10) {
      return true;
    }
    final invLen = 1.0 / math.sqrt(len2);
    var ux = ax * invLen;
    var uy = ay * invLen;
    var uz = az * invLen;

    final projA = _obbA.projectRadius(ux, uy, uz);
    final projB = _obbB.projectRadius(ux, uy, uz);
    var dist = tx * ux + ty * uy + tz * uz;
    if (dist < 0.0) {
      dist = -dist;
      ux = -ux;
      uy = -uy;
      uz = -uz;
    }
    final overlap = projA + projB - dist;
    if (overlap < 0.0) {
      return false;
    }
    if (overlap * bias + slack < minPen) {
      minPen = overlap;
      bestAxisCode = code;
      _boxNormalScratch.setValues(ux, uy, uz);
    }
    return true;
  }

  if (!testAxis(_obbA.u0x, _obbA.u0y, _obbA.u0z, 0, 1.0) ||
      !testAxis(_obbA.u1x, _obbA.u1y, _obbA.u1z, 1, 1.0) ||
      !testAxis(_obbA.u2x, _obbA.u2y, _obbA.u2z, 2, 1.0) ||
      !testAxis(_obbB.u0x, _obbB.u0y, _obbB.u0z, 3, 1.05, 2e-4) ||
      !testAxis(_obbB.u1x, _obbB.u1y, _obbB.u1z, 4, 1.05, 2e-4) ||
      !testAxis(_obbB.u2x, _obbB.u2y, _obbB.u2z, 5, 1.05, 2e-4)) {
    return false;
  }

  for (var i = 0; i < 3; i++) {
    final aUx = _obbA.axisX(i);
    final aUy = _obbA.axisY(i);
    final aUz = _obbA.axisZ(i);
    for (var j = 0; j < 3; j++) {
      final bUx = _obbB.axisX(j);
      final bUy = _obbB.axisY(j);
      final bUz = _obbB.axisZ(j);
      final cx = aUy * bUz - aUz * bUy;
      final cy = aUz * bUx - aUx * bUz;
      final cz = aUx * bUy - aUy * bUx;
      if (!testAxis(cx, cy, cz, 6 + i * 3 + j, 1.05, 2e-4)) {
        return false;
      }
    }
  }

  if (bestAxisCode < 0 || !minPen.isFinite) {
    return false;
  }

  if (tx * _boxNormalScratch.x +
          ty * _boxNormalScratch.y +
          tz * _boxNormalScratch.z <
      0.0) {
    _boxNormalScratch.negate();
  }
  _satBestAxisCode = bestAxisCode;
  _satMinPen = minPen;
  return true;
}

void _pushSphereSphereInto(
  double ax,
  double ay,
  double az,
  double rA,
  double bx,
  double by,
  double bz,
  double rB,
  MutableManifoldBuffer3D out, {
  required bool flip,
}) {
  final dx = bx - ax;
  final dy = by - ay;
  final dz = bz - az;
  final dist2 = dx * dx + dy * dy + dz * dz;
  final rSum = rA + rB;
  if (dist2 > rSum * rSum) {
    return;
  }
  final dist = math.sqrt(dist2);
  final double nx;
  final double ny;
  final double nz;
  if (dist > 1e-9) {
    final inv = 1.0 / dist;
    nx = dx * inv;
    ny = dy * inv;
    nz = dz * inv;
  } else {
    nx = 0.0;
    ny = 1.0;
    nz = 0.0;
  }
  final pax = ax + nx * rA;
  final pay = ay + ny * rA;
  final paz = az + nz * rA;
  final pbx = bx - nx * rB;
  final pby = by - ny * rB;
  final pbz = bz - nz * rB;
  final depth = rSum - dist;
  if (flip) {
    out.pushSingle(-nx, -ny, -nz, depth, pbx, pby, pbz, pax, pay, paz);
  } else {
    out.pushSingle(nx, ny, nz, depth, pax, pay, paz, pbx, pby, pbz);
  }
}

void _pushSphereObbInto(
  double sx,
  double sy,
  double sz,
  double rA,
  _ObbFrame obb,
  MutableManifoldBuffer3D out, {
  required bool flip,
}) {
  final lx = obb.toLocalX(sx, sy, sz);
  final ly = obb.toLocalY(sx, sy, sz);
  final lz = obb.toLocalZ(sx, sy, sz);
  final hx = obb.ex;
  final hy = obb.ey;
  final hz = obb.ez;

  final cx = lx.clamp(-hx, hx);
  final cy = ly.clamp(-hy, hy);
  final cz = lz.clamp(-hz, hz);

  final dx = lx - cx;
  final dy = ly - cy;
  final dz = lz - cz;
  final dist2 = dx * dx + dy * dy + dz * dz;
  if (dist2 > rA * rA) {
    return;
  }

  if (dist2 > 1e-12) {
    final dist = math.sqrt(dist2);
    obb.toWorld(cx, cy, cz, _ptB);
    final inv = 1.0 / dist;
    final nx = (_ptB.x - sx) * inv;
    final ny = (_ptB.y - sy) * inv;
    final nz = (_ptB.z - sz) * inv;
    final pax = sx + nx * rA;
    final pay = sy + ny * rA;
    final paz = sz + nz * rA;
    final depth = rA - dist;
    if (flip) {
      out.pushSingle(
        -nx,
        -ny,
        -nz,
        depth,
        _ptB.x,
        _ptB.y,
        _ptB.z,
        pax,
        pay,
        paz,
      );
    } else {
      out.pushSingle(
        nx,
        ny,
        nz,
        depth,
        pax,
        pay,
        paz,
        _ptB.x,
        _ptB.y,
        _ptB.z,
      );
    }
    return;
  }

  final penX = hx - lx.abs();
  final penY = hy - ly.abs();
  final penZ = hz - lz.abs();

  var nLx = 0.0;
  var nLy = 0.0;
  var nLz = 0.0;
  var faceLx = lx;
  var faceLy = ly;
  var faceLz = lz;
  double faceDist;

  if (penX <= penY && penX <= penZ) {
    faceDist = penX;
    final sign = lx >= 0.0 ? 1.0 : -1.0;
    nLx = -sign;
    faceLx = sign * hx;
  } else if (penY <= penZ) {
    faceDist = penY;
    final sign = ly >= 0.0 ? 1.0 : -1.0;
    nLy = -sign;
    faceLy = sign * hy;
  } else {
    faceDist = penZ;
    final sign = lz >= 0.0 ? 1.0 : -1.0;
    nLz = -sign;
    faceLz = sign * hz;
  }

  obb.dirToWorld(nLx, nLy, nLz, _boxNormalScratch);
  obb.toWorld(faceLx, faceLy, faceLz, _ptB);
  final nx = _boxNormalScratch.x;
  final ny = _boxNormalScratch.y;
  final nz = _boxNormalScratch.z;
  final pax = sx + nx * rA;
  final pay = sy + ny * rA;
  final paz = sz + nz * rA;
  final depth = rA + faceDist;
  if (flip) {
    out.pushSingle(
      -nx,
      -ny,
      -nz,
      depth,
      _ptB.x,
      _ptB.y,
      _ptB.z,
      pax,
      pay,
      paz,
    );
  } else {
    out.pushSingle(
      nx,
      ny,
      nz,
      depth,
      pax,
      pay,
      paz,
      _ptB.x,
      _ptB.y,
      _ptB.z,
    );
  }
}

class _ObbFrame() {
  double cx = 0.0;
  double cy = 0.0;
  double cz = 0.0;
  double u0x = 1.0;
  double u0y = 0.0;
  double u0z = 0.0;
  double u1x = 0.0;
  double u1y = 1.0;
  double u1z = 0.0;
  double u2x = 0.0;
  double u2y = 0.0;
  double u2z = 1.0;
  double ex = 0.5;
  double ey = 0.5;
  double ez = 0.5;

  void extract(BoxShape3D box, Matrix4 m4) {
    final m = m4.storage;
    cx = m[12];
    cy = m[13];
    cz = m[14];

    final s0 = math.sqrt(m[0] * m[0] + m[1] * m[1] + m[2] * m[2]);
    final s1 = math.sqrt(m[4] * m[4] + m[5] * m[5] + m[6] * m[6]);
    final s2 = math.sqrt(m[8] * m[8] + m[9] * m[9] + m[10] * m[10]);

    if (s0 > 1e-12) {
      u0x = m[0] / s0;
      u0y = m[1] / s0;
      u0z = m[2] / s0;
    } else {
      u0x = 1.0;
      u0y = 0.0;
      u0z = 0.0;
    }
    if (s1 > 1e-12) {
      u1x = m[4] / s1;
      u1y = m[5] / s1;
      u1z = m[6] / s1;
    } else {
      u1x = 0.0;
      u1y = 1.0;
      u1z = 0.0;
    }
    if (s2 > 1e-12) {
      u2x = m[8] / s2;
      u2y = m[9] / s2;
      u2z = m[10] / s2;
    } else {
      u2x = 0.0;
      u2y = 0.0;
      u2z = 1.0;
    }

    ex = math.max(1e-6, box.halfExtents.x * s0);
    ey = math.max(1e-6, box.halfExtents.y * s1);
    ez = math.max(1e-6, box.halfExtents.z * s2);
  }

  double toLocalX(double wx, double wy, double wz) =>
      (wx - cx) * u0x + (wy - cy) * u0y + (wz - cz) * u0z;

  double toLocalY(double wx, double wy, double wz) =>
      (wx - cx) * u1x + (wy - cy) * u1y + (wz - cz) * u1z;

  double toLocalZ(double wx, double wy, double wz) =>
      (wx - cx) * u2x + (wy - cy) * u2y + (wz - cz) * u2z;

  void toWorld(double lx, double ly, double lz, Vector3 out) {
    out.setValues(
      cx + u0x * lx + u1x * ly + u2x * lz,
      cy + u0y * lx + u1y * ly + u2y * lz,
      cz + u0z * lx + u1z * ly + u2z * lz,
    );
  }

  void dirToWorld(double lx, double ly, double lz, Vector3 out) {
    out.setValues(
      u0x * lx + u1x * ly + u2x * lz,
      u0y * lx + u1y * ly + u2y * lz,
      u0z * lx + u1z * ly + u2z * lz,
    );
  }

  double projectRadius(double ax, double ay, double az) {
    return ex * (u0x * ax + u0y * ay + u0z * az).abs() +
        ey * (u1x * ax + u1y * ay + u1z * az).abs() +
        ez * (u2x * ax + u2y * ay + u2z * az).abs();
  }

  double axisX(int i) => i == 0 ? u0x : (i == 1 ? u1x : u2x);
  double axisY(int i) => i == 0 ? u0y : (i == 1 ? u1y : u2y);
  double axisZ(int i) => i == 0 ? u0z : (i == 1 ? u1z : u2z);
  double extent(int i) => i == 0 ? ex : (i == 1 ? ey : ez);

  static final Float64List _edgeS = Float64List(3);

  void supportEdge(
    int edgeAxis,
    double dx,
    double dy,
    double dz,
    Vector3 out0,
    Vector3 out1,
  ) {
    final s = _edgeS;
    for (var k = 0; k < 3; k++) {
      if (k == edgeAxis) {
        s[k] = 0.0;
      } else {
        final dot = axisX(k) * dx + axisY(k) * dy + axisZ(k) * dz;
        s[k] = (dot >= 0.0 ? 1.0 : -1.0) * extent(k);
      }
    }
    final e = extent(edgeAxis);
    s[edgeAxis] = -e;
    toWorld(s[0], s[1], s[2], out0);
    s[edgeAxis] = e;
    toWorld(s[0], s[1], s[2], out1);
  }
}

/// A shape's supporting face in world space: a convex polygon and its outward
/// unit normal (reused between narrowphase calls).
