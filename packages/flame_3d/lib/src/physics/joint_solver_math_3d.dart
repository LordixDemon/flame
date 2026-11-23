part of 'joints_3d.dart';

void _buildPointToPointInvK(
  RigidBody3D a,
  Vector3 rA,
  RigidBody3D b,
  Vector3 rB,
  Matrix3 invKOut,
) {
  final invM = a.inverseMass + b.inverseMass;
  var k00 = invM;
  var k01 = 0.0;
  var k02 = 0.0;
  var k11 = invM;
  var k12 = 0.0;
  var k22 = invM;

  void addSkewInertia(RigidBody3D body, Vector3 r) {
    if (body.inverseMass <= 0.0) {
      return;
    }
    // `-[r]_x * I * [r]_x` where `I = body.worldInvInertia` (symmetric).
    final i = body.worldInvInertia.storage;
    final i00 = i[0];
    final i01 = i[1];
    final i02 = i[2];
    final i11 = i[4];
    final i12 = i[5];
    final i22 = i[8];
    final rx = r.x;
    final ry = r.y;
    final rz = r.z;

    // Columns of `I * [r]_x`: `[r]_x * e_0 = (0, rz, -ry)`, etc.
    // Specifically `(v^T (-[r]_x I [r]_x) v) = (r x v)^T I (r x v)`:
    // For basis vectors e_x, e_y, e_z:
    // c0 = r x e_x = (0, rz, -ry)
    // c1 = r x e_y = (-rz, 0, rx)
    // c2 = r x e_z = (ry, -rx, 0)
    final ic0y = i01 * 0.0 + i11 * rz - i12 * ry;
    final ic0z = i02 * 0.0 + i12 * rz - i22 * ry;

    final ic1x = -i00 * rz + i02 * rx;
    final ic1z = -i02 * rz + i22 * rx;

    final ic2x = i00 * ry - i01 * rx;
    final ic2y = i01 * ry - i11 * rx;

    k00 += rz * ic0y - ry * ic0z;
    k01 += -rz * (i01 * rz - i02 * ry) + rx * ic0z;
    k02 += ry * (i01 * rz - i02 * ry) - rx * ic0y;
    k11 += -rz * ic1x + rx * ic1z;
    k12 += ry * ic1x - rx * (-i01 * rz + i12 * rx);
    k22 += ry * ic2x - rx * ic2y;
  }

  addSkewInertia(a, rA);
  addSkewInertia(b, rB);

  final c00 = k11 * k22 - k12 * k12;
  final c01 = -(k01 * k22 - k12 * k02);
  final c02 = k01 * k12 - k11 * k02;
  final c11 = k00 * k22 - k02 * k02;
  final c12 = -(k00 * k12 - k01 * k02);
  final c22 = k00 * k11 - k01 * k01;

  final det = k00 * c00 + k01 * c01 + k02 * c02;
  if (det.abs() <= 1e-14) {
    invKOut.setZero();
    return;
  }
  final invDet = 1.0 / det;
  final s = invKOut.storage;
  s[0] = c00 * invDet;
  s[1] = c01 * invDet;
  s[2] = c02 * invDet;
  s[3] = c01 * invDet;
  s[4] = c11 * invDet;
  s[5] = c12 * invDet;
  s[6] = c02 * invDet;
  s[7] = c12 * invDet;
  s[8] = c22 * invDet;
}

void _mulMat3Neg(Matrix3 m, Vector3 v, Vector3 out) {
  final s = m.storage;
  out.setValues(
    -(s[0] * v.x + s[3] * v.y + s[6] * v.z),
    -(s[1] * v.x + s[4] * v.y + s[7] * v.z),
    -(s[2] * v.x + s[5] * v.y + s[8] * v.z),
  );
}

void _sumInvInertiaMul(
  RigidBody3D a,
  RigidBody3D b,
  Vector3 v,
  Vector3 out,
) {
  final sA = a.worldInvInertia.storage;
  final sB = b.worldInvInertia.storage;
  out.setValues(
    (sA[0] + sB[0]) * v.x + (sA[3] + sB[3]) * v.y + (sA[6] + sB[6]) * v.z,
    (sA[1] + sB[1]) * v.x + (sA[4] + sB[4]) * v.y + (sA[7] + sB[7]) * v.z,
    (sA[2] + sB[2]) * v.x + (sA[5] + sB[5]) * v.y + (sA[8] + sB[8]) * v.z,
  );
}

double _relVelAlongAxis(
  RigidBody3D a,
  Vector3 rA,
  RigidBody3D b,
  Vector3 rB,
  Vector3 u,
) {
  final vAx =
      a.linearVelocity.x +
      (a.angularVelocity.y * rA.z - a.angularVelocity.z * rA.y);
  final vAy =
      a.linearVelocity.y +
      (a.angularVelocity.z * rA.x - a.angularVelocity.x * rA.z);
  final vAz =
      a.linearVelocity.z +
      (a.angularVelocity.x * rA.y - a.angularVelocity.y * rA.x);

  final vBx =
      b.linearVelocity.x +
      (b.angularVelocity.y * rB.z - b.angularVelocity.z * rB.y);
  final vBy =
      b.linearVelocity.y +
      (b.angularVelocity.z * rB.x - b.angularVelocity.x * rB.z);
  final vBz =
      b.linearVelocity.z +
      (b.angularVelocity.x * rB.y - b.angularVelocity.y * rB.x);

  return (vBx - vAx) * u.x + (vBy - vAy) * u.y + (vBz - vAz) * u.z;
}

void _relVel3(
  RigidBody3D a,
  Vector3 rA,
  RigidBody3D b,
  Vector3 rB,
  Vector3 out,
) {
  final vAx =
      a.linearVelocity.x +
      (a.angularVelocity.y * rA.z - a.angularVelocity.z * rA.y);
  final vAy =
      a.linearVelocity.y +
      (a.angularVelocity.z * rA.x - a.angularVelocity.x * rA.z);
  final vAz =
      a.linearVelocity.z +
      (a.angularVelocity.x * rA.y - a.angularVelocity.y * rA.x);

  final vBx =
      b.linearVelocity.x +
      (b.angularVelocity.y * rB.z - b.angularVelocity.z * rB.y);
  final vBy =
      b.linearVelocity.y +
      (b.angularVelocity.z * rB.x - b.angularVelocity.x * rB.z);
  final vBz =
      b.linearVelocity.z +
      (b.angularVelocity.x * rB.y - b.angularVelocity.y * rB.x);

  out.setValues(vBx - vAx, vBy - vAy, vBz - vAz);
}

void _applyLinearPairImpulse(
  RigidBody3D a,
  Vector3 rA,
  RigidBody3D b,
  Vector3 rB,
  double px,
  double py,
  double pz,
  Vector3 scratch,
) {
  if (a.inverseMass > 0.0) {
    a.linearVelocity.setValues(
      a.linearVelocity.x - px * a.inverseMass,
      a.linearVelocity.y - py * a.inverseMass,
      a.linearVelocity.z - pz * a.inverseMass,
    );
    final tx = rA.y * pz - rA.z * py;
    final ty = rA.z * px - rA.x * pz;
    final tz = rA.x * py - rA.y * px;
    a.multiplyWorldInvInertia(tx, ty, tz, scratch);
    a.angularVelocity.sub(scratch);
  }
  if (b.inverseMass > 0.0) {
    b.linearVelocity.setValues(
      b.linearVelocity.x + px * b.inverseMass,
      b.linearVelocity.y + py * b.inverseMass,
      b.linearVelocity.z + pz * b.inverseMass,
    );
    final tx = rB.y * pz - rB.z * py;
    final ty = rB.z * px - rB.x * pz;
    final tz = rB.x * py - rB.y * px;
    b.multiplyWorldInvInertia(tx, ty, tz, scratch);
    b.angularVelocity.add(scratch);
  }
}

void _applyAngularPairImpulse(
  RigidBody3D a,
  RigidBody3D b,
  double tx,
  double ty,
  double tz,
  Vector3 scratch,
) {
  if (a.inverseMass > 0.0) {
    a.multiplyWorldInvInertia(tx, ty, tz, scratch);
    a.angularVelocity.sub(scratch);
  }
  if (b.inverseMass > 0.0) {
    b.multiplyWorldInvInertia(tx, ty, tz, scratch);
    b.angularVelocity.add(scratch);
  }
}

void _applyPositionPairImpulse(
  RigidBody3D a,
  Vector3 rA,
  RigidBody3D b,
  Vector3 rB,
  double px,
  double py,
  double pz,
  Vector3 scratch,
) {
  if (a.inverseMass > 0.0) {
    final posA = a.bodyPosition;
    posA.setValues(
      posA.x - px * a.inverseMass,
      posA.y - py * a.inverseMass,
      posA.z - pz * a.inverseMass,
    );
    final tx = rA.y * pz - rA.z * py;
    final ty = rA.z * px - rA.x * pz;
    final tz = rA.x * py - rA.y * px;
    a.multiplyWorldInvInertia(-tx, -ty, -tz, scratch);
    applyDeltaQuatToBody(a, scratch);
  }
  if (b.inverseMass > 0.0) {
    final posB = b.bodyPosition;
    posB.setValues(
      posB.x + px * b.inverseMass,
      posB.y + py * b.inverseMass,
      posB.z + pz * b.inverseMass,
    );
    final tx = rB.y * pz - rB.z * py;
    final ty = rB.z * px - rB.x * pz;
    final tz = rB.x * py - rB.y * px;
    b.multiplyWorldInvInertia(tx, ty, tz, scratch);
    applyDeltaQuatToBody(b, scratch);
  }
}

void _applyAngularPositionPairImpulse(
  RigidBody3D a,
  RigidBody3D b,
  double tx,
  double ty,
  double tz,
  Vector3 scratch,
) {
  if (a.inverseMass > 0.0) {
    a.multiplyWorldInvInertia(-tx, -ty, -tz, scratch);
    applyDeltaQuatToBody(a, scratch);
  }
  if (b.inverseMass > 0.0) {
    b.multiplyWorldInvInertia(tx, ty, tz, scratch);
    applyDeltaQuatToBody(b, scratch);
  }
}

void _computeWorldAnchorAndLever(
  RigidBody3D body,
  Vector3 localAnchor,
  Vector3 outWorldAnchor,
  Vector3 outLever,
) {
  rotateVectorByQuat(body.bodyRotation, localAnchor, outWorldAnchor);
  outWorldAnchor.add(body.bodyPosition);
  final com = body.worldCenterOfMass;
  outLever.setValues(
    outWorldAnchor.x - com.x,
    outWorldAnchor.y - com.y,
    outWorldAnchor.z - com.z,
  );
}

double _computeLinearCoupledK(
  RigidBody3D a,
  Vector3 rA,
  RigidBody3D b,
  Vector3 rB,
  Vector3 u1,
  Vector3 u2,
  Vector3 scratch,
) {
  var k = 0.0;
  if (a.inverseMass > 0.0) {
    final c1x = rA.y * u1.z - rA.z * u1.y;
    final c1y = rA.z * u1.x - rA.x * u1.z;
    final c1z = rA.x * u1.y - rA.y * u1.x;
    final c2x = rA.y * u2.z - rA.z * u2.y;
    final c2y = rA.z * u2.x - rA.x * u2.z;
    final c2z = rA.x * u2.y - rA.y * u2.x;
    a.multiplyWorldInvInertia(c2x, c2y, c2z, scratch);
    k += c1x * scratch.x + c1y * scratch.y + c1z * scratch.z;
  }
  if (b.inverseMass > 0.0) {
    final c1x = rB.y * u1.z - rB.z * u1.y;
    final c1y = rB.z * u1.x - rB.x * u1.z;
    final c1z = rB.x * u1.y - rB.y * u1.x;
    final c2x = rB.y * u2.z - rB.z * u2.y;
    final c2y = rB.z * u2.x - rB.x * u2.z;
    final c2z = rB.x * u2.y - rB.y * u2.x;
    b.multiplyWorldInvInertia(c2x, c2y, c2z, scratch);
    k += c1x * scratch.x + c1y * scratch.y + c1z * scratch.z;
  }
  return k;
}

void _buildAngularInvK(RigidBody3D a, RigidBody3D b, Matrix3 invKOut) {
  final sA = a.worldInvInertia.storage;
  final sB = b.worldInvInertia.storage;
  final k00 = sA[0] + sB[0];
  final k01 = sA[1] + sB[1];
  final k02 = sA[2] + sB[2];
  final k11 = sA[4] + sB[4];
  final k12 = sA[5] + sB[5];
  final k22 = sA[8] + sB[8];

  final c00 = k11 * k22 - k12 * k12;
  final c01 = -(k01 * k22 - k12 * k02);
  final c02 = k01 * k12 - k11 * k02;
  final c11 = k00 * k22 - k02 * k02;
  final c12 = -(k00 * k12 - k01 * k02);
  final c22 = k00 * k11 - k01 * k01;

  final det = k00 * c00 + k01 * c01 + k02 * c02;
  if (det.abs() <= 1e-14) {
    invKOut.setZero();
    return;
  }
  final invDet = 1.0 / det;
  final s = invKOut.storage;
  s[0] = c00 * invDet;
  s[1] = c01 * invDet;
  s[2] = c02 * invDet;
  s[3] = c01 * invDet;
  s[4] = c11 * invDet;
  s[5] = c12 * invDet;
  s[6] = c02 * invDet;
  s[7] = c12 * invDet;
  s[8] = c22 * invDet;
}

void _quatMul(Quaternion a, Quaternion b, Quaternion out) {
  final ax = a.x;
  final ay = a.y;
  final az = a.z;
  final aw = a.w;
  final bx = b.x;
  final by = b.y;
  final bz = b.z;
  final bw = b.w;
  out.setValues(
    aw * bx + ax * bw + ay * bz - az * by,
    aw * by - ax * bz + ay * bw + az * bx,
    aw * bz + ax * by - ay * bx + az * bw,
    aw * bw - ax * bx - ay * by - az * bz,
  );
  out.normalize();
}

void _quatMulConjA(Quaternion a, Quaternion b, Quaternion out) {
  final ax = -a.x;
  final ay = -a.y;
  final az = -a.z;
  final aw = a.w;
  final bx = b.x;
  final by = b.y;
  final bz = b.z;
  final bw = b.w;
  out.setValues(
    aw * bx + ax * bw + ay * bz - az * by,
    aw * by - ax * bz + ay * bw + az * bx,
    aw * bz + ax * by - ay * bx + az * bw,
    aw * bw - ax * bx - ay * by - az * bz,
  );
  out.normalize();
}

void _computeWorldRotationError(
  Quaternion qA,
  Quaternion qB,
  Quaternion qRef,
  Quaternion qTargetScratch,
  Quaternion qErrScratch,
  Vector3 outErrorWorld,
) {
  // Target orientation for B is `qTarget = qA * qRef`.
  // World-space rotation bringing `qTarget` to `qB` is `qErr = qB * qTarget^*`.
  _quatMul(qA, qRef, qTargetScratch);
  final tx = -qTargetScratch.x;
  final ty = -qTargetScratch.y;
  final tz = -qTargetScratch.z;
  final tw = qTargetScratch.w;
  final bx = qB.x;
  final by = qB.y;
  final bz = qB.z;
  final bw = qB.w;
  var ex = bw * tx + bx * tw + by * tz - bz * ty;
  var ey = bw * ty - bx * tz + by * tw + bz * tx;
  var ez = bw * tz + bx * ty - by * tx + bz * tw;
  var ew = bw * tw - bx * tx - by * ty - bz * tz;
  if (ew < 0.0) {
    ex = -ex;
    ey = -ey;
    ez = -ez;
    ew = -ew;
  }
  qErrScratch.setValues(ex, ey, ez, ew);
  final vLen = math.sqrt(ex * ex + ey * ey + ez * ez);
  if (vLen > 1e-8) {
    final angle = 2.0 * math.atan2(vLen, ew);
    final scale = angle / vLen;
    outErrorWorld.setValues(ex * scale, ey * scale, ez * scale);
  } else {
    outErrorWorld.setValues(2.0 * ex, 2.0 * ey, 2.0 * ez);
  }
}

void _quatFromXAxis(Vector3 unitX, Quaternion out) {
  // Shortest-arc rotation from `(1, 0, 0)` to `unitX`.
  if (unitX.x > 0.999999) {
    out.setValues(0.0, 0.0, 0.0, 1.0);
    return;
  }
  if (unitX.x < -0.999999) {
    out.setValues(0.0, 1.0, 0.0, 0.0);
    return;
  }
  final s = math.sqrt((1.0 + unitX.x) * 2.0);
  final invS = 1.0 / s;
  out.setValues(0.0, -unitX.z * invS, unitX.y * invS, 0.5 * s);
  out.normalize();
}

void _quatFromXAndRefY(Vector3 unitX, Vector3 refY, Quaternion out) {
  final yProj = refY.clone()..addScaled(unitX, -refY.dot(unitX));
  if (yProj.length2 <= 1e-10) {
    _quatFromXAxis(unitX, out);
    return;
  }
  yProj.normalize();
  final unitZ = unitX.cross(yProj)..normalize();
  final m = Matrix3.columns(unitX, yProj, unitZ);
  out.setFromRotation(m);
  out.normalize();
}

void _extractIntrinsicXyzAngles(Quaternion qIn, Vector3 out) {
  var x = qIn.x;
  var y = qIn.y;
  var z = qIn.z;
  var w = qIn.w;
  if (w < 0.0) {
    x = -x;
    y = -y;
    z = -z;
    w = -w;
  }

  final sinrCosp = 2.0 * (w * x + y * z);
  final cosrCosp = 1.0 - 2.0 * (x * x + y * y);
  final rx = math.atan2(sinrCosp, cosrCosp);

  final sinp = (2.0 * (w * y - z * x)).clamp(-1.0, 1.0);
  final ry = math.asin(sinp);

  final sinyCosp = 2.0 * (w * z + x * y);
  final cosyCosp = 1.0 - 2.0 * (y * y + z * z);
  final rz = math.atan2(sinyCosp, cosyCosp);

  out.setValues(rx, ry, rz);
}
