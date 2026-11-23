import 'dart:math' as math;

import 'package:flame_3d/core.dart';
import 'package:flame_3d/physics.dart';
import 'package:flame_3d/src/extensions/geometry_math.dart';
import 'package:meta/meta.dart';

final Vector3 _comRotScratch = Vector3.zero();

/// Applies a small angular pseudo-rotation delta [dTheta] (in radians) to
/// [body] while preserving its world center of mass and updating its world
/// inverse inertia tensor.
@internal
void applyDeltaQuatToBody(RigidBody3D body, Vector3 dTheta) {
  final angle = dTheta.length;
  if (angle <= 1e-8) {
    return;
  }
  final hasCom = body.hasCenterOfMassOffset;
  var oldComX = 0.0;
  var oldComY = 0.0;
  var oldComZ = 0.0;
  if (hasCom) {
    final com = body.worldCenterOfMass;
    oldComX = com.x;
    oldComY = com.y;
    oldComZ = com.z;
  }

  final half = 0.5 * angle;
  final s = math.sin(half) / angle;
  final dqx = dTheta.x * s;
  final dqy = dTheta.y * s;
  final dqz = dTheta.z * s;
  final dqw = math.cos(half);

  final q = body.bodyRotation;
  final qx = q.x;
  final qy = q.y;
  final qz = q.z;
  final qw = q.w;

  final nx = dqw * qx + dqx * qw + dqy * qz - dqz * qy;
  final ny = dqw * qy - dqx * qz + dqy * qw + dqz * qx;
  final nz = dqw * qz + dqx * qy - dqy * qx + dqz * qw;
  final nw = dqw * qw - dqx * qx - dqy * qy - dqz * qz;
  final invNorm = 1.0 / math.sqrt(nx * nx + ny * ny + nz * nz + nw * nw);
  q.setValues(nx * invNorm, ny * invNorm, nz * invNorm, nw * invNorm);
  if (hasCom) {
    rotateVectorByQuat(q, body.localCenterOfMass, _comRotScratch);
    body.bodyPosition.setValues(
      oldComX - _comRotScratch.x,
      oldComY - _comRotScratch.y,
      oldComZ - _comRotScratch.z,
    );
  }
  body.updateWorldInertia();
}

/// Computes effective inverse mass `imA + imB + ((rA x u)^T I_a^-1 (rA x u))`
/// `+ ((rB x u)^T I_b^-1 (rB x u))` using explicit active inverse masses [imA]
/// and [imB] (zero disables that body's contribution, e.g. static/sleeping).
@internal
@pragma('vm:prefer-inline')
double computeLinearAxisKWithInvMass(
  RigidBody3D a,
  double imA,
  Vector3 rA,
  RigidBody3D b,
  double imB,
  Vector3 rB,
  Vector3 axis,
  Vector3 scratch,
) {
  var k = imA + imB;
  if (imA > 0.0) {
    final cx = rA.y * axis.z - rA.z * axis.y;
    final cy = rA.z * axis.x - rA.x * axis.z;
    final cz = rA.x * axis.y - rA.y * axis.x;
    a.multiplyWorldInvInertia(cx, cy, cz, scratch);
    k += cx * scratch.x + cy * scratch.y + cz * scratch.z;
  }
  if (imB > 0.0) {
    final cx = rB.y * axis.z - rB.z * axis.y;
    final cy = rB.z * axis.x - rB.x * axis.z;
    final cz = rB.x * axis.y - rB.y * axis.x;
    b.multiplyWorldInvInertia(cx, cy, cz, scratch);
    k += cx * scratch.x + cy * scratch.y + cz * scratch.z;
  }
  return k;
}

/// Computes effective inverse mass along unit direction [axis] for bodies [a]
/// and [b] using their intrinsic `inverseMass` values.
@internal
double computeLinearAxisK(
  RigidBody3D a,
  Vector3 rA,
  RigidBody3D b,
  Vector3 rB,
  Vector3 axis,
  Vector3 scratch,
) => computeLinearAxisKWithInvMass(
  a,
  a.inverseMass,
  rA,
  b,
  b.inverseMass,
  rB,
  axis,
  scratch,
);

/// Computes single-body effective inverse mass along unit [axis] at lever arm
/// [r] relative to [body]'s center of mass.
@internal
double computeSingleBodyAxisK(
  RigidBody3D body,
  Vector3 r,
  Vector3 axis,
  Vector3 scratch,
) {
  final cx = r.y * axis.z - r.z * axis.y;
  final cy = r.z * axis.x - r.x * axis.z;
  final cz = r.x * axis.y - r.y * axis.x;
  body.multiplyWorldInvInertia(cx, cy, cz, scratch);
  return body.inverseMass + cx * scratch.x + cy * scratch.y + cz * scratch.z;
}

/// Writes linear velocity of [body] at lever arm [r] (`v + omega x r`) into
/// [out].
@internal
@pragma('vm:prefer-inline')
void velocityAtLever(RigidBody3D body, Vector3 r, Vector3 out) {
  final lv = body.linearVelocity;
  final av = body.angularVelocity;
  out.setValues(
    lv.x + (av.y * r.z - av.z * r.y),
    lv.y + (av.z * r.x - av.x * r.z),
    lv.z + (av.x * r.y - av.y * r.x),
  );
}

/// Returns relative velocity `(vB + wB x rB) - (vA + wA x rA)` projected along
/// [axis].
@internal
@pragma('vm:prefer-inline')
double relativeVelocityAlongAxis(
  RigidBody3D a,
  Vector3 rA,
  RigidBody3D b,
  Vector3 rB,
  Vector3 axis,
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

  return (vBx - vAx) * axis.x + (vBy - vAy) * axis.y + (vBz - vAz) * axis.z;
}

/// Writes relative velocity `(vB + wB x rB) - (vA + wA x rA)` into [out].
@internal
@pragma('vm:prefer-inline')
void relativeVelocityAtLevers(
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

/// Applies a linear velocity impulse `(-p, +p)` at lever arms [rA] and [rB]
/// using explicit active inverse masses [imA] and [imB].
@internal
@pragma('vm:prefer-inline')
void applyLinearPairImpulseWithInvMass(
  RigidBody3D a,
  double imA,
  Vector3 rA,
  RigidBody3D b,
  double imB,
  Vector3 rB,
  double px,
  double py,
  double pz,
  Vector3 scratch,
) {
  if (imA > 0.0) {
    a.linearVelocity.setValues(
      a.linearVelocity.x - px * imA,
      a.linearVelocity.y - py * imA,
      a.linearVelocity.z - pz * imA,
    );
    final tx = rA.y * pz - rA.z * py;
    final ty = rA.z * px - rA.x * pz;
    final tz = rA.x * py - rA.y * px;
    a.multiplyWorldInvInertia(tx, ty, tz, scratch);
    a.angularVelocity.sub(scratch);
  }
  if (imB > 0.0) {
    b.linearVelocity.setValues(
      b.linearVelocity.x + px * imB,
      b.linearVelocity.y + py * imB,
      b.linearVelocity.z + pz * imB,
    );
    final tx = rB.y * pz - rB.z * py;
    final ty = rB.z * px - rB.x * pz;
    final tz = rB.x * py - rB.y * px;
    b.multiplyWorldInvInertia(tx, ty, tz, scratch);
    b.angularVelocity.add(scratch);
  }
}

/// Applies a linear velocity impulse `(-p, +p)` at lever arms [rA] and [rB]
/// using `a.inverseMass` and `b.inverseMass`.
@internal
@pragma('vm:prefer-inline')
void applyLinearPairImpulse(
  RigidBody3D a,
  Vector3 rA,
  RigidBody3D b,
  Vector3 rB,
  double px,
  double py,
  double pz,
  Vector3 scratch,
) => applyLinearPairImpulseWithInvMass(
  a,
  a.inverseMass,
  rA,
  b,
  b.inverseMass,
  rB,
  px,
  py,
  pz,
  scratch,
);

/// Applies an angular velocity impulse `(-tau, +tau)` to [a] and [b].
@internal
@pragma('vm:prefer-inline')
void applyAngularPairImpulse(
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

/// Applies a linear + angular pseudo-position impulse `(-p, +p)` at lever arms
/// [rA] and [rB] using explicit active inverse masses [imA] and [imB].
@internal
@pragma('vm:prefer-inline')
void applyPositionPairImpulseWithInvMass(
  RigidBody3D a,
  double imA,
  Vector3 rA,
  RigidBody3D b,
  double imB,
  Vector3 rB,
  double px,
  double py,
  double pz,
  Vector3 scratch,
) {
  if (imA > 0.0) {
    final posA = a.bodyPosition;
    posA.setValues(
      posA.x - px * imA,
      posA.y - py * imA,
      posA.z - pz * imA,
    );
    final tx = rA.y * pz - rA.z * py;
    final ty = rA.z * px - rA.x * pz;
    final tz = rA.x * py - rA.y * px;
    a.multiplyWorldInvInertia(-tx, -ty, -tz, scratch);
    applyDeltaQuatToBody(a, scratch);
  }
  if (imB > 0.0) {
    final posB = b.bodyPosition;
    posB.setValues(
      posB.x + px * imB,
      posB.y + py * imB,
      posB.z + pz * imB,
    );
    final tx = rB.y * pz - rB.z * py;
    final ty = rB.z * px - rB.x * pz;
    final tz = rB.x * py - rB.y * px;
    b.multiplyWorldInvInertia(tx, ty, tz, scratch);
    applyDeltaQuatToBody(b, scratch);
  }
}

/// Applies a linear + angular pseudo-position impulse `(-p, +p)` at lever arms
/// [rA] and [rB] using `a.inverseMass` and `b.inverseMass`.
@internal
@pragma('vm:prefer-inline')
void applyPositionPairImpulse(
  RigidBody3D a,
  Vector3 rA,
  RigidBody3D b,
  Vector3 rB,
  double px,
  double py,
  double pz,
  Vector3 scratch,
) => applyPositionPairImpulseWithInvMass(
  a,
  a.inverseMass,
  rA,
  b,
  b.inverseMass,
  rB,
  px,
  py,
  pz,
  scratch,
);

/// Applies an angular pseudo-position delta `(-tau, +tau)` to [a] and [b].
@internal
@pragma('vm:prefer-inline')
void applyAngularPositionPairImpulse(
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

/// Writes world-space anchor point and center-of-mass lever arm of
/// [localAnchor] on [body].
@internal
@pragma('vm:prefer-inline')
void computeWorldAnchorAndLever(
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

/// Builds the 3x3 point-to-point inverse effective mass matrix `(K)^-1` into
/// [invKOut] (zeroed if singular).
@internal
void buildPointToPointInvK(
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

    final ic0y = i11 * rz - i12 * ry;
    final ic0z = i12 * rz - i22 * ry;
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

  if (!invertSymmetricValues3D(k00, k01, k02, k11, k12, k22, invKOut)) {
    invKOut.setZero();
  }
}

/// Builds the 3x3 angular inverse effective mass matrix `(I_a^-1 + I_b^-1)^-1`
/// into [invKOut] (zeroed if singular).
@internal
void buildAngularInvK(RigidBody3D a, RigidBody3D b, Matrix3 invKOut) {
  final sA = a.worldInvInertia.storage;
  final sB = b.worldInvInertia.storage;
  if (!invertSymmetricValues3D(
    sA[0] + sB[0],
    sA[1] + sB[1],
    sA[2] + sB[2],
    sA[4] + sB[4],
    sA[5] + sB[5],
    sA[8] + sB[8],
    invKOut,
  )) {
    invKOut.setZero();
  }
}

/// Computes `out = -(m * v)`.
@internal
@pragma('vm:prefer-inline')
void mulMat3Neg(Matrix3 m, Vector3 v, Vector3 out) {
  final s = m.storage;
  out.setValues(
    -(s[0] * v.x + s[3] * v.y + s[6] * v.z),
    -(s[1] * v.x + s[4] * v.y + s[7] * v.z),
    -(s[2] * v.x + s[5] * v.y + s[8] * v.z),
  );
}

/// Computes `out = (a.worldInvInertia + b.worldInvInertia) * v`.
@internal
@pragma('vm:prefer-inline')
void sumInvInertiaMul(RigidBody3D a, RigidBody3D b, Vector3 v, Vector3 out) {
  final sA = a.worldInvInertia.storage;
  final sB = b.worldInvInertia.storage;
  out.setValues(
    (sA[0] + sB[0]) * v.x + (sA[3] + sB[3]) * v.y + (sA[6] + sB[6]) * v.z,
    (sA[1] + sB[1]) * v.x + (sA[4] + sB[4]) * v.y + (sA[7] + sB[7]) * v.z,
    (sA[2] + sB[2]) * v.x + (sA[5] + sB[5]) * v.y + (sA[8] + sB[8]) * v.z,
  );
}

/// Computes the off-diagonal coupled linear inertia term along [u1] and [u2].
@internal
double computeLinearCoupledK(
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

/// Computes world-space axis-angle rotation error from target `qA * qRef` to
/// [qB] into [outErrorWorld].
@internal
void computeWorldRotationError(
  Quaternion qA,
  Quaternion qB,
  Quaternion qRef,
  Quaternion qTargetScratch,
  Quaternion qErrScratch,
  Vector3 outErrorWorld,
) {
  quatMul(qA, qRef, qTargetScratch);
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

/// Builds the shortest-arc quaternion rotating `+X` onto [unitX] into [out].
@internal
void quatFromXAxis(Vector3 unitX, Quaternion out) {
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
  out
    ..setValues(0.0, -unitX.z * invS, unitX.y * invS, 0.5 * s)
    ..normalize();
}

/// Builds an orthonormal quaternion whose local `+X` aligns with [unitX] and
/// local `+Y` aligns with [refY] projected perpendicular to [unitX].
@internal
void quatFromXAndRefY(Vector3 unitX, Vector3 refY, Quaternion out) {
  final yProj = refY.clone()..addScaled(unitX, -refY.dot(unitX));
  if (yProj.length2 <= 1e-10) {
    quatFromXAxis(unitX, out);
    return;
  }
  yProj.normalize();
  final unitZ = unitX.cross(yProj)..normalize();
  final m = Matrix3.columns(unitX, yProj, unitZ);
  out
    ..setFromRotation(m)
    ..normalize();
}

/// Extracts intrinsic XYZ Euler angles (radians) from unit quaternion [qIn]
/// into [out].
@internal
void extractIntrinsicXyzAngles(Quaternion qIn, Vector3 out) {
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
