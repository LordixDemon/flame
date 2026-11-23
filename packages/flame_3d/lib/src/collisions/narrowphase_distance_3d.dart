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
  closestPointsSegmentSegment3D(p0, p1, v0, v1, _candSeg, _candTri);
  consider(_candSeg, _candTri);
  closestPointsSegmentSegment3D(p0, p1, v1, v2, _candSeg, _candTri);
  consider(_candSeg, _candTri);
  closestPointsSegmentSegment3D(p0, p1, v2, v0, _candSeg, _candTri);
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
