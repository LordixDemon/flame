part of 'collision_manifold_3d.dart';

final Vector3 _segA0 = Vector3.zero();
final Vector3 _segA1 = Vector3.zero();
final Vector3 _segB0 = Vector3.zero();
final Vector3 _segB1 = Vector3.zero();
final Vector3 _ptA = Vector3.zero();
final Vector3 _ptB = Vector3.zero();
final Float64List _segBreaks = Float64List(8);
final Vector3 _candSeg = Vector3.zero();
final Vector3 _candTri = Vector3.zero();

double _closestSegmentParamToAabb(
  double p0x,
  double p0y,
  double p0z,
  double dx,
  double dy,
  double dz,
  double hx,
  double hy,
  double hz,
) {
  final breaks = _segBreaks;
  var count = 2;
  breaks[0] = 0.0;
  breaks[1] = 1.0;

  void addCrossings(double o, double d, double h) {
    if (d.abs() > 1e-12) {
      final t1 = (-h - o) / d;
      if (t1 > 0.0 && t1 < 1.0) {
        breaks[count++] = t1;
      }
      final t2 = (h - o) / d;
      if (t2 > 0.0 && t2 < 1.0) {
        breaks[count++] = t2;
      }
    }
  }

  addCrossings(p0x, dx, hx);
  addCrossings(p0y, dy, hy);
  addCrossings(p0z, dz, hz);

  // Insertion sort `breaks[0..count-1]`.
  for (var i = 1; i < count; i++) {
    final key = breaks[i];
    var j = i - 1;
    while (j >= 0 && breaks[j] > key) {
      breaks[j + 1] = breaks[j];
      j--;
    }
    breaks[j + 1] = key;
  }

  double distSqAt(double t) {
    final x = p0x + dx * t;
    final y = p0y + dy * t;
    final z = p0z + dz * t;
    final ex = x < -hx ? x + hx : (x > hx ? x - hx : 0.0);
    final ey = y < -hy ? y + hy : (y > hy ? y - hy : 0.0);
    final ez = z < -hz ? z + hz : (z > hz ? z - hz : 0.0);
    return ex * ex + ey * ey + ez * ez;
  }

  var bestT = 0.0;
  var bestD2 = distSqAt(0.0);

  for (var i = 0; i < count - 1; i++) {
    final tA = breaks[i];
    final tB = breaks[i + 1];
    if (tB - tA <= 1e-12) {
      continue;
    }
    final tMid = 0.5 * (tA + tB);
    final mx = p0x + dx * tMid;
    final my = p0y + dy * tMid;
    final mz = p0z + dz * tMid;

    // On `[tA, tB]`, the set of active outside axes is constant!
    var qa = 0.0;
    var qb = 0.0;
    if (mx < -hx) {
      qa += dx * dx;
      qb += dx * (p0x + hx);
    } else if (mx > hx) {
      qa += dx * dx;
      qb += dx * (p0x - hx);
    }
    if (my < -hy) {
      qa += dy * dy;
      qb += dy * (p0y + hy);
    } else if (my > hy) {
      qa += dy * dy;
      qb += dy * (p0y - hy);
    }
    if (mz < -hz) {
      qa += dz * dz;
      qb += dz * (p0z + hz);
    } else if (mz > hz) {
      qa += dz * dz;
      qb += dz * (p0z - hz);
    }

    if (qa <= 1e-18) {
      // Entire sub-interval lies inside AABB (`distSq == 0`)!
      return tMid;
    }
    final tStar = (-qb / qa).clamp(tA, tB);
    final d2 = distSqAt(tStar);
    if (d2 < bestD2) {
      bestD2 = d2;
      bestT = tStar;
    }
  }

  final dEnd = distSqAt(1.0);
  if (dEnd < bestD2) {
    bestT = 1.0;
  }
  return bestT;
}

void _closestPointOnSegment(
  double px,
  double py,
  double pz,
  Vector3 a,
  Vector3 b,
  Vector3 out,
) {
  final abx = b.x - a.x;
  final aby = b.y - a.y;
  final abz = b.z - a.z;
  final len2 = abx * abx + aby * aby + abz * abz;
  if (len2 <= 1e-16) {
    out.setFrom(a);
    return;
  }
  final t = (((px - a.x) * abx + (py - a.y) * aby + (pz - a.z) * abz) / len2)
      .clamp(0.0, 1.0);
  out.setValues(a.x + abx * t, a.y + aby * t, a.z + abz * t);
}

void _closestPointsSegmentSegment(
  Vector3 p1,
  Vector3 q1,
  Vector3 p2,
  Vector3 q2,
  Vector3 out1,
  Vector3 out2,
) {
  final d1x = q1.x - p1.x;
  final d1y = q1.y - p1.y;
  final d1z = q1.z - p1.z;
  final d2x = q2.x - p2.x;
  final d2y = q2.y - p2.y;
  final d2z = q2.z - p2.z;
  final rx = p1.x - p2.x;
  final ry = p1.y - p2.y;
  final rz = p1.z - p2.z;

  final a = d1x * d1x + d1y * d1y + d1z * d1z;
  final e = d2x * d2x + d2y * d2y + d2z * d2z;
  final f = d2x * rx + d2y * ry + d2z * rz;

  double s;
  double t;
  if (a <= 1e-14 && e <= 1e-14) {
    s = 0.0;
    t = 0.0;
  } else if (a <= 1e-14) {
    s = 0.0;
    t = (f / e).clamp(0.0, 1.0);
  } else {
    final c = d1x * rx + d1y * ry + d1z * rz;
    if (e <= 1e-14) {
      t = 0.0;
      s = (-c / a).clamp(0.0, 1.0);
    } else {
      final b = d1x * d2x + d1y * d2y + d1z * d2z;
      final denom = a * e - b * b;
      s = denom > 1e-14 ? ((b * f - c * e) / denom).clamp(0.0, 1.0) : 0.0;
      t = (b * s + f) / e;
      if (t < 0.0) {
        t = 0.0;
        s = (-c / a).clamp(0.0, 1.0);
      } else if (t > 1.0) {
        t = 1.0;
        s = ((b - c) / a).clamp(0.0, 1.0);
      }
    }
  }

  out1.setValues(p1.x + d1x * s, p1.y + d1y * s, p1.z + d1z * s);
  out2.setValues(p2.x + d2x * t, p2.y + d2y * t, p2.z + d2z * t);
}

void _closestPointsSegmentTriangle(
  Vector3 p0,
  Vector3 p1,
  Vector3 v0,
  Vector3 v1,
  Vector3 v2,
  Vector3 outSeg,
  Vector3 outTri,
) {
  var bestD2 = double.infinity;

  void consider(Vector3 candSeg, Vector3 candTri) {
    final dx = candSeg.x - candTri.x;
    final dy = candSeg.y - candTri.y;
    final dz = candSeg.z - candTri.z;
    final d2 = dx * dx + dy * dy + dz * dz;
    if (d2 < bestD2) {
      bestD2 = d2;
      outSeg.setFrom(candSeg);
      outTri.setFrom(candTri);
    }
  }

  // 1. Segment endpoints against triangle.
  closestPointOnTriangle3D(p0.x, p0.y, p0.z, v0, v1, v2, _candTri);
  consider(p0, _candTri);
  closestPointOnTriangle3D(p1.x, p1.y, p1.z, v0, v1, v2, _candTri);
  consider(p1, _candTri);

  // 2. Segment against the 3 triangle edges.
  _closestPointsSegmentSegment(p0, p1, v0, v1, _candSeg, _candTri);
  consider(_candSeg, _candTri);
  _closestPointsSegmentSegment(p0, p1, v1, v2, _candSeg, _candTri);
  consider(_candSeg, _candTri);
  _closestPointsSegmentSegment(p0, p1, v2, v0, _candSeg, _candTri);
  consider(_candSeg, _candTri);

  // 3. Segment piercing the triangle plane.
  final e1x = v1.x - v0.x;
  final e1y = v1.y - v0.y;
  final e1z = v1.z - v0.z;
  final e2x = v2.x - v0.x;
  final e2y = v2.y - v0.y;
  final e2z = v2.z - v0.z;
  final nx = e1y * e2z - e1z * e2y;
  final ny = e1z * e2x - e1x * e2z;
  final nz = e1x * e2y - e1y * e2x;
  final dx = p1.x - p0.x;
  final dy = p1.y - p0.y;
  final dz = p1.z - p0.z;
  final denom = nx * dx + ny * dy + nz * dz;
  if (denom.abs() > 1e-12) {
    final t =
        -(nx * (p0.x - v0.x) + ny * (p0.y - v0.y) + nz * (p0.z - v0.z)) / denom;
    if (t > 0.0 && t < 1.0) {
      _candSeg.setValues(p0.x + dx * t, p0.y + dy * t, p0.z + dz * t);
      closestPointOnTriangle3D(
        _candSeg.x,
        _candSeg.y,
        _candSeg.z,
        v0,
        v1,
        v2,
        _candTri,
      );
      consider(_candSeg, _candTri);
    }
  }
}

List<ContactPoint3D> _reduceContactsToFour(
  List<ContactPoint3D> contacts,
  double nx,
  double ny,
  double nz,
) {
  // Keep deepest point first, then farthest from it, then maximize triangle
  // area, then farthest from triangle edges.
  var i0 = 0;
  for (var i = 1; i < contacts.length; i++) {
    if (contacts[i].penetrationDepth > contacts[i0].penetrationDepth) {
      i0 = i;
    }
  }
  var i1 = 0;
  var bestD2 = -1.0;
  final p0 = contacts[i0].pointA;
  for (var i = 0; i < contacts.length; i++) {
    final d2 = contacts[i].pointA.distanceToSquared(p0);
    if (d2 > bestD2) {
      bestD2 = d2;
      i1 = i;
    }
  }
  var i2 = 0;
  var bestArea = -1.0;
  final p1 = contacts[i1].pointA;
  for (var i = 0; i < contacts.length; i++) {
    if (i == i0 || i == i1) {
      continue;
    }
    final p = contacts[i].pointA;
    final e1x = p1.x - p0.x;
    final e1y = p1.y - p0.y;
    final e1z = p1.z - p0.z;
    final e2x = p.x - p0.x;
    final e2y = p.y - p0.y;
    final e2z = p.z - p0.z;
    final cx = e1y * e2z - e1z * e2y;
    final cy = e1z * e2x - e1x * e2z;
    final cz = e1x * e2y - e1y * e2x;
    final area = (cx * nx + cy * ny + cz * nz).abs();
    if (area > bestArea) {
      bestArea = area;
      i2 = i;
    }
  }
  var i3 = 0;
  var bestFourth = -1.0;
  final p2 = contacts[i2].pointA;
  for (var i = 0; i < contacts.length; i++) {
    if (i == i0 || i == i1 || i == i2) {
      continue;
    }
    final p = contacts[i].pointA;
    final d = math.min(
      p.distanceToSquared(p0),
      math.min(p.distanceToSquared(p1), p.distanceToSquared(p2)),
    );
    if (d > bestFourth) {
      bestFourth = d;
      i3 = i;
    }
  }
  final chosen = <int>{i0, i1, i2, i3};
  return [for (final idx in chosen) contacts[idx]];
}
