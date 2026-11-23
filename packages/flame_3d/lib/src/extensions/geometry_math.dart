import 'dart:math' as math;
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:vector_math/vector_math.dart';

/// Determinant of the upper-left `3x3` submatrix of column-major 4x4 matrix
/// [m] starting at [base].
@internal
@pragma('vm:prefer-inline')
double determinant3x3(List<double> m, [int base = 0]) {
  final m0 = m[base];
  final m1 = m[base + 1];
  final m2 = m[base + 2];
  final m4 = m[base + 4];
  final m5 = m[base + 5];
  final m6 = m[base + 6];
  final m8 = m[base + 8];
  final m9 = m[base + 9];
  final m10 = m[base + 10];
  return m0 * (m5 * m10 - m6 * m9) +
      m4 * (m2 * m9 - m1 * m10) +
      m8 * (m1 * m6 - m2 * m5);
}

/// Whether the upper-left `3x3` submatrix of column-major 4x4 matrix [m]
/// (starting at [base]) reverses triangle winding (`determinant < 0`).
@internal
@pragma('vm:prefer-inline')
bool isMirrored3x3(List<double> m, [int base = 0]) =>
    determinant3x3(m, base) < 0.0;

/// Uniform isotropic volume scale `cbrt(|det3x3|)` of column-major 4x4 matrix
/// [m] starting at [base].
@internal
double uniformScale3x3(List<double> m, [int base = 0]) {
  final volume = determinant3x3(m, base).abs();
  if (volume == 1.0) {
    return 1.0;
  }
  return volume == 0.0 ? 0.0 : math.pow(volume, 1.0 / 3.0).toDouble();
}

/// Transforms a local center/half-extents box by the column-major 4x4 matrix
/// [m] starting at [base] into [out] using Arvo's method (1990).
@internal
@pragma('vm:prefer-inline')
void transformAabbArvo(
  List<double> m,
  int base,
  double cx,
  double cy,
  double cz,
  double hx,
  double hy,
  double hz,
  Aabb3 out,
) {
  final m0 = m[base];
  final m1 = m[base + 1];
  final m2 = m[base + 2];
  final m4 = m[base + 4];
  final m5 = m[base + 5];
  final m6 = m[base + 6];
  final m8 = m[base + 8];
  final m9 = m[base + 9];
  final m10 = m[base + 10];
  final wx = m0 * cx + m4 * cy + m8 * cz + m[base + 12];
  final wy = m1 * cx + m5 * cy + m9 * cz + m[base + 13];
  final wz = m2 * cx + m6 * cy + m10 * cz + m[base + 14];
  final ex = m0.abs() * hx + m4.abs() * hy + m8.abs() * hz;
  final ey = m1.abs() * hx + m5.abs() * hy + m9.abs() * hz;
  final ez = m2.abs() * hx + m6.abs() * hy + m10.abs() * hz;
  out
    ..min.setValues(wx - ex, wy - ey, wz - ez)
    ..max.setValues(wx + ex, wy + ey, wz + ez);
}

/// Computes the union [out] of [localBox] transformed by [count] consecutive
/// column-major 4x4 matrices stored at [stride] floats apart in [buffer].
///
/// Returns `false` when [count] is zero.
@internal
bool expandAabbByTransformedInstances(
  Float32List buffer,
  int count,
  int stride,
  Aabb3 localBox,
  Aabb3 out,
) {
  if (count <= 0) {
    return false;
  }
  final bMin = localBox.min;
  final bMax = localBox.max;
  final cx = 0.5 * (bMin.x + bMax.x);
  final cy = 0.5 * (bMin.y + bMax.y);
  final cz = 0.5 * (bMin.z + bMax.z);
  final hx = 0.5 * (bMax.x - bMin.x);
  final hy = 0.5 * (bMax.y - bMin.y);
  final hz = 0.5 * (bMax.z - bMin.z);

  var minX = double.infinity;
  var minY = double.infinity;
  var minZ = double.infinity;
  var maxX = double.negativeInfinity;
  var maxY = double.negativeInfinity;
  var maxZ = double.negativeInfinity;

  for (var i = 0; i < count; i++) {
    final base = i * stride;
    final m0 = buffer[base];
    final m1 = buffer[base + 1];
    final m2 = buffer[base + 2];
    final m4 = buffer[base + 4];
    final m5 = buffer[base + 5];
    final m6 = buffer[base + 6];
    final m8 = buffer[base + 8];
    final m9 = buffer[base + 9];
    final m10 = buffer[base + 10];

    final wx = m0 * cx + m4 * cy + m8 * cz + buffer[base + 12];
    final wy = m1 * cx + m5 * cy + m9 * cz + buffer[base + 13];
    final wz = m2 * cx + m6 * cy + m10 * cz + buffer[base + 14];
    final ex = m0.abs() * hx + m4.abs() * hy + m8.abs() * hz;
    final ey = m1.abs() * hx + m5.abs() * hy + m9.abs() * hz;
    final ez = m2.abs() * hx + m6.abs() * hy + m10.abs() * hz;

    minX = math.min(minX, wx - ex);
    minY = math.min(minY, wy - ey);
    minZ = math.min(minZ, wz - ez);
    maxX = math.max(maxX, wx + ex);
    maxY = math.max(maxY, wy + ey);
    maxZ = math.max(maxZ, wz + ez);
  }

  out
    ..min.setValues(minX, minY, minZ)
    ..max.setValues(maxX, maxY, maxZ);
  return true;
}

/// Exact AABB-AABB overlap check (inclusive boundaries).
@internal
@pragma('vm:prefer-inline')
bool aabbOverlaps(Aabb3 a, Aabb3 b) {
  return a.min.x <= b.max.x &&
      a.max.x >= b.min.x &&
      a.min.y <= b.max.y &&
      a.max.y >= b.min.y &&
      a.min.z <= b.max.z &&
      a.max.z >= b.min.z;
}

/// Slab intersection test for [ray] against [box] within `[0, maxDistance]`.
@internal
bool rayHitsAabb(Ray ray, Aabb3 box, double maxDistance) {
  var tMin = 0.0;
  var tMax = maxDistance;

  bool slab(double o, double d, double lo, double hi) {
    final minV = lo - 1e-5;
    final maxV = hi + 1e-5;
    if (d.abs() < 1e-12) {
      return o >= minV && o <= maxV;
    }
    final inv = 1.0 / d;
    var t1 = (minV - o) * inv;
    var t2 = (maxV - o) * inv;
    if (t1 > t2) {
      final s = t1;
      t1 = t2;
      t2 = s;
    }
    if (t1 > tMin) {
      tMin = t1;
    }
    if (t2 < tMax) {
      tMax = t2;
    }
    return tMin <= tMax;
  }

  return slab(ray.origin.x, ray.direction.x, box.min.x, box.max.x) &&
      slab(ray.origin.y, ray.direction.y, box.min.y, box.max.y) &&
      slab(ray.origin.z, ray.direction.z, box.min.z, box.max.z);
}

/// Rotates [v] by unit quaternion [q] and stores the result in [out].
///
/// Safe when [out] aliases [v].
@internal
@pragma('vm:prefer-inline')
void rotateVectorByQuat(Quaternion q, Vector3 v, Vector3 out) {
  final qx = q.x;
  final qy = q.y;
  final qz = q.z;
  final qw = q.w;
  final vx = v.x;
  final vy = v.y;
  final vz = v.z;
  final tx = 2.0 * (qy * vz - qz * vy);
  final ty = 2.0 * (qz * vx - qx * vz);
  final tz = 2.0 * (qx * vy - qy * vx);
  out.setValues(
    vx + qw * tx + (qy * tz - qz * ty),
    vy + qw * ty + (qz * tx - qx * tz),
    vz + qw * tz + (qx * ty - qy * tx),
  );
}

/// Rotates [v] by the inverse (conjugate) of unit quaternion [q] into [out].
///
/// Safe when [out] aliases [v].
@internal
@pragma('vm:prefer-inline')
void unrotateVectorByQuat(Quaternion q, Vector3 v, Vector3 out) {
  final qx = -q.x;
  final qy = -q.y;
  final qz = -q.z;
  final qw = q.w;
  final vx = v.x;
  final vy = v.y;
  final vz = v.z;
  final tx = 2.0 * (qy * vz - qz * vy);
  final ty = 2.0 * (qz * vx - qx * vz);
  final tz = 2.0 * (qx * vy - qy * vx);
  out.setValues(
    vx + qw * tx + (qy * tz - qz * ty),
    vy + qw * ty + (qz * tx - qx * tz),
    vz + qw * tz + (qx * ty - qy * tx),
  );
}

/// Writes the translation component (`columns 12..14`) of [m] into [out] and
/// returns [out].
@internal
@pragma('vm:prefer-inline')
Vector3 centerOfMatrix3D(Matrix4 m, Vector3 out) {
  final s = m.storage;
  out.setValues(s[12], s[13], s[14]);
  return out;
}

/// Transforms local point `(x, y, z)` by column-major 4x4 matrix storage [m]
/// into [out].
@internal
@pragma('vm:prefer-inline')
void transformPoint3D(
  List<double> m,
  double x,
  double y,
  double z,
  Vector3 out,
) {
  out.setValues(
    m[0] * x + m[4] * y + m[8] * z + m[12],
    m[1] * x + m[5] * y + m[9] * z + m[13],
    m[2] * x + m[6] * y + m[10] * z + m[14],
  );
}

/// Writes the triangle vertex of `(v0, v1, v2)` furthest along [dir] into
/// [out].
@internal
@pragma('vm:prefer-inline')
void triangleSupport3D(
  Vector3 v0,
  Vector3 v1,
  Vector3 v2,
  Vector3 dir,
  Vector3 out,
) {
  final d0 = v0.dot(dir);
  final d1 = v1.dot(dir);
  final d2 = v2.dot(dir);
  if (d0 >= d1 && d0 >= d2) {
    out.setFrom(v0);
  } else if (d1 >= d2) {
    out.setFrom(v1);
  } else {
    out.setFrom(v2);
  }
}

/// Builds unit tangent vectors [t1] and [t2] forming a right-handed
/// orthonormal basis around unit [normal].
@internal
void buildOrthonormalBasis3D(Vector3 normal, Vector3 t1, Vector3 t2) {
  if (normal.x.abs() < 0.9) {
    t1.setValues(0.0, -normal.z, normal.y);
  } else {
    t1.setValues(-normal.z, 0.0, normal.x);
  }
  t1.normalize();
  t2.setValues(
    normal.y * t1.z - normal.z * t1.y,
    normal.z * t1.x - normal.x * t1.z,
    normal.x * t1.y - normal.y * t1.x,
  );
}

/// Builds orthonormal horizontal axes [basisU] and [basisV] perpendicular to
/// [upAxis] (Gram-Schmidt from `(1, 0, 0)` / `(0, 0, 1)`).
@internal
void buildUpTangentBasis3D(Vector3 upAxis, Vector3 basisU, Vector3 basisV) {
  basisU.setValues(1.0, 0.0, 0.0);
  if (upAxis.dot(basisU).abs() > 0.9) {
    basisU.setValues(0.0, 0.0, 1.0);
  }
  basisV
    ..setFrom(upAxis)
    ..crossInto(basisU, basisV);
  if (basisV.length2 <= 1e-12) {
    basisV.setValues(0.0, 0.0, 1.0);
  } else {
    basisV.normalize();
  }
  basisV.crossInto(upAxis, basisU);
  basisU.normalize();
}

/// Computes the inverse of a symmetric 3x3 matrix [sym] via cofactors into
/// [out]. Returns `false` if [sym] is singular.
@internal
bool invertSymmetric3D(Matrix3 sym, Matrix3 out) {
  final s = sym.storage;
  final a00 = s[0];
  final a01 = s[1];
  final a02 = s[2];
  final a11 = s[4];
  final a12 = s[5];
  final a22 = s[8];

  final c00 = a11 * a22 - a12 * a12;
  final c01 = -(a01 * a22 - a12 * a02);
  final c02 = a01 * a12 - a11 * a02;
  final c11 = a00 * a22 - a02 * a02;
  final c12 = -(a00 * a12 - a01 * a02);
  final c22 = a00 * a11 - a01 * a01;

  final det = a00 * c00 + a01 * c01 + a02 * c02;
  if (det.abs() <= 1e-14) {
    return false;
  }
  final invDet = 1.0 / det;
  final o = out.storage;
  o[0] = c00 * invDet;
  o[1] = c01 * invDet;
  o[2] = c02 * invDet;
  o[3] = c01 * invDet;
  o[4] = c11 * invDet;
  o[5] = c12 * invDet;
  o[6] = c02 * invDet;
  o[7] = c12 * invDet;
  o[8] = c22 * invDet;
  return true;
}

/// Computes the closest point on triangle `(a, b, c)` to point `(px, py, pz)`
/// and writes it into [out] using Ericson's Voronoi region algorithm.
@internal
void closestPointOnTriangle3D(
  double px,
  double py,
  double pz,
  Vector3 a,
  Vector3 b,
  Vector3 c,
  Vector3 out,
) {
  final abx = b.x - a.x;
  final aby = b.y - a.y;
  final abz = b.z - a.z;
  final acx = c.x - a.x;
  final acy = c.y - a.y;
  final acz = c.z - a.z;
  final apx = px - a.x;
  final apy = py - a.y;
  final apz = pz - a.z;

  final d1 = abx * apx + aby * apy + abz * apz;
  final d2 = acx * apx + acy * apy + acz * apz;
  if (d1 <= 0.0 && d2 <= 0.0) {
    out.setFrom(a);
    return;
  }

  final bpx = px - b.x;
  final bpy = py - b.y;
  final bpz = pz - b.z;
  final d3 = abx * bpx + aby * bpy + abz * bpz;
  final d4 = acx * bpx + acy * bpy + acz * bpz;
  if (d3 >= 0.0 && d4 <= d3) {
    out.setFrom(b);
    return;
  }

  final vc = d1 * d4 - d3 * d2;
  if (vc <= 0.0 && d1 >= 0.0 && d3 <= 0.0) {
    final v = d1 / (d1 - d3);
    out.setValues(a.x + v * abx, a.y + v * aby, a.z + v * abz);
    return;
  }

  final cpx = px - c.x;
  final cpy = py - c.y;
  final cpz = pz - c.z;
  final d5 = abx * cpx + aby * cpy + abz * cpz;
  final d6 = acx * cpx + acy * cpy + acz * cpz;
  if (d6 >= 0.0 && d5 <= d6) {
    out.setFrom(c);
    return;
  }

  final vb = d5 * d2 - d1 * d6;
  if (vb <= 0.0 && d2 >= 0.0 && d6 <= 0.0) {
    final w = d2 / (d2 - d6);
    out.setValues(a.x + w * acx, a.y + w * acy, a.z + w * acz);
    return;
  }

  final va = d3 * d6 - d5 * d4;
  if (va <= 0.0 && (d4 - d3) >= 0.0 && (d5 - d6) >= 0.0) {
    final w = (d4 - d3) / ((d4 - d3) + (d5 - d6));
    out.setValues(
      b.x + w * (c.x - b.x),
      b.y + w * (c.y - b.y),
      b.z + w * (c.z - b.z),
    );
    return;
  }

  final denom = 1.0 / (va + vb + vc);
  final v = vb * denom;
  final w = vc * denom;
  out.setValues(
    a.x + abx * v + acx * w,
    a.y + aby * v + acy * w,
    a.z + abz * v + acz * w,
  );
}

final Uint32List _crc32Table = _buildCrc32Table();

Uint32List _buildCrc32Table() {
  final table = Uint32List(256);
  for (var i = 0; i < 256; i++) {
    var c = i;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
    }
    table[i] = c & 0xFFFFFFFF;
  }
  return table;
}

/// Computes the standard IEEE 802.3 CRC32 checksum of `data[start..end)`,
/// optionally skipping bytes in `[skipRangeStart, skipRangeEnd)`.
@internal
int computeCrc32Bytes(
  Uint8List data, {
  int start = 0,
  int? end,
  int skipRangeStart = -1,
  int skipRangeEnd = -1,
}) {
  final table = _crc32Table;
  final stop = end ?? data.length;
  var crc = 0xFFFFFFFF;
  for (var i = start; i < stop; i++) {
    if (i >= skipRangeStart && i < skipRangeEnd) {
      continue;
    }
    crc = (crc >>> 8) ^ table[(crc ^ data[i]) & 0xFF];
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
