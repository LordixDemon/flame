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

/// Computes effective inverse mass `1/m_a + 1/m_b + ((r_a x u)^T I_a^-1 (r_a x u)) + ((r_b x u)^T I_b^-1 (r_b x u))`
/// along unit direction [axis] for bodies [a] and [b].
@internal
double computeLinearAxisK(
  RigidBody3D a,
  Vector3 rA,
  RigidBody3D b,
  Vector3 rB,
  Vector3 axis,
  Vector3 scratch,
) {
  var k = a.inverseMass + b.inverseMass;
  if (a.inverseMass > 0.0) {
    final cx = rA.y * axis.z - rA.z * axis.y;
    final cy = rA.z * axis.x - rA.x * axis.z;
    final cz = rA.x * axis.y - rA.y * axis.x;
    a.multiplyWorldInvInertia(cx, cy, cz, scratch);
    k += cx * scratch.x + cy * scratch.y + cz * scratch.z;
  }
  if (b.inverseMass > 0.0) {
    final cx = rB.y * axis.z - rB.z * axis.y;
    final cy = rB.z * axis.x - rB.x * axis.z;
    final cz = rB.x * axis.y - rB.y * axis.x;
    b.multiplyWorldInvInertia(cx, cy, cz, scratch);
    k += cx * scratch.x + cy * scratch.y + cz * scratch.z;
  }
  return k;
}

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
