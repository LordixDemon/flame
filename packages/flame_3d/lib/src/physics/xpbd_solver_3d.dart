part of 'xpbd_cloth_3d.dart';

void _pushOutSphere(
  Float32List pos,
  Float32List invMass,
  int count,
  double cx,
  double cy,
  double cz,
  double minR,
) {
  final r2 = minR * minR;
  for (var i = 0; i < count; i++) {
    if (invMass[i] <= 0.0) {
      continue;
    }
    final o = i * 3;
    final dx = pos[o] - cx;
    final dy = pos[o + 1] - cy;
    final dz = pos[o + 2] - cz;
    final d2 = dx * dx + dy * dy + dz * dz;
    if (d2 < r2) {
      if (d2 > 1e-12) {
        final s = minR / math.sqrt(d2);
        pos[o] = cx + dx * s;
        pos[o + 1] = cy + dy * s;
        pos[o + 2] = cz + dz * s;
      } else {
        pos[o] = cx;
        pos[o + 1] = cy + minR;
        pos[o + 2] = cz;
      }
    }
  }
}

void _pushOutCapsule(
  Float32List pos,
  Float32List invMass,
  int count,
  double ax,
  double ay,
  double az,
  double bx,
  double by,
  double bz,
  double minR,
) {
  final abx = bx - ax;
  final aby = by - ay;
  final abz = bz - az;
  final abLen2 = abx * abx + aby * aby + abz * abz;
  final r2 = minR * minR;

  for (var i = 0; i < count; i++) {
    if (invMass[i] <= 0.0) {
      continue;
    }
    final o = i * 3;
    final px = pos[o];
    final py = pos[o + 1];
    final pz = pos[o + 2];
    final t = abLen2 > 1e-14
        ? (((px - ax) * abx + (py - ay) * aby + (pz - az) * abz) / abLen2)
              .clamp(0.0, 1.0)
        : 0.0;
    final cx = ax + abx * t;
    final cy = ay + aby * t;
    final cz = az + abz * t;
    final dx = px - cx;
    final dy = py - cy;
    final dz = pz - cz;
    final d2 = dx * dx + dy * dy + dz * dz;
    if (d2 < r2) {
      if (d2 > 1e-12) {
        final s = minR / math.sqrt(d2);
        pos[o] = cx + dx * s;
        pos[o + 1] = cy + dy * s;
        pos[o + 2] = cz + dz * s;
      } else {
        pos[o] = cx;
        pos[o + 1] = cy + minR;
        pos[o + 2] = cz;
      }
    }
  }
}

void _transformPt(Float32List m, Vector3 v, Vector3 out) {
  out.setValues(
    m[0] * v.x + m[4] * v.y + m[8] * v.z + m[12],
    m[1] * v.x + m[5] * v.y + m[9] * v.z + m[13],
    m[2] * v.x + m[6] * v.y + m[10] * v.z + m[14],
  );
}

void _transformDir(Float32List m, Vector3 v, Vector3 out) {
  out.setValues(
    m[0] * v.x + m[4] * v.y + m[8] * v.z,
    m[1] * v.x + m[5] * v.y + m[9] * v.z,
    m[2] * v.x + m[6] * v.y + m[10] * v.z,
  );
}

void _solveXpbdDistanceConstraints(
  int constraintCount,
  Int32List edgeA,
  Int32List edgeB,
  Float32List invMass,
  Float32List restLen,
  Float32List compliance,
  Float32List pos,
  Float32List lambda,
  double invH2,
) {
  for (var k = 0; k < constraintCount; k++) {
    final a = edgeA[k];
    final b = edgeB[k];
    final wA = invMass[a];
    final wB = invMass[b];
    final wSum = wA + wB;
    if (wSum <= 0.0) {
      continue;
    }
    final oa = a * 3;
    final ob = b * 3;
    final dx = pos[oa] - pos[ob];
    final dy = pos[oa + 1] - pos[ob + 1];
    final dz = pos[oa + 2] - pos[ob + 2];
    final dist = math.sqrt(dx * dx + dy * dy + dz * dz);
    if (dist <= 1e-9) {
      continue;
    }
    final cErr = dist - restLen[k];
    final alphaTilde = compliance[k] * invH2;
    final dLambda = (-cErr - alphaTilde * lambda[k]) / (wSum + alphaTilde);
    lambda[k] += dLambda;
    final s = dLambda / dist;
    if (wA > 0.0) {
      pos[oa] += dx * (s * wA);
      pos[oa + 1] += dy * (s * wA);
      pos[oa + 2] += dz * (s * wA);
    }
    if (wB > 0.0) {
      pos[ob] -= dx * (s * wB);
      pos[ob + 1] -= dy * (s * wB);
      pos[ob + 2] -= dz * (s * wB);
    }
  }
}

void _deriveXpbdVelocities(
  int count,
  Float32List invMass,
  Float32List pos,
  Float32List prevPos,
  Float32List vel,
  double invH,
) {
  for (var i = 0; i < count; i++) {
    if (invMass[i] <= 0.0) {
      continue;
    }
    final o = i * 3;
    vel[o] = (pos[o] - prevPos[o]) * invH;
    vel[o + 1] = (pos[o + 1] - prevPos[o + 1]) * invH;
    vel[o + 2] = (pos[o + 2] - prevPos[o + 2]) * invH;
  }
}
