part of 'collision_manifold_3d.dart';

const double _faceContactTolerance = 0.002;
const double _faceAlignmentCos = 0.995;

/// Mixes two small non-negative integers into a 30-bit feature id.
int _mixId(int a, int b) {
  var h = (a ^ 0x2545F491) & 0x3FFFFFFF;
  h = (h * 1031 + (b & 0x3FFFFFFF) * 7 + 0x9E37) & 0x3FFFFFFF;
  h ^= h >> 13;
  return (h * 997) & 0x3FFFFFFF;
}

/// Writes into [out] the face of [shape] (under [m]) whose outward normal is
/// closest to the world direction `(dx, dy, dz)`, returning `false` for
/// shapes without faces (spheres, capsules, degenerate hulls).
bool _writeSupportFace(
  Shape3D shape,
  Matrix4 m,
  double dx,
  double dy,
  double dz,
  _SupportFace3D out,
) {
  if (!shape.hasSupportFace) {
    return false;
  }
  if (shape is BoxShape3D) {
    Narrowphase3D._scratch.clip.obbFace.extract(shape, m);
    _writeObbFace(Narrowphase3D._scratch.clip.obbFace, dx, dy, dz, out);
    return true;
  }
  if (shape is ConvexHullShape3D) {
    return _writeHullFace(shape, m, dx, dy, dz, out);
  }
  return false;
}

void _writeObbFace(
  _ObbFrame obb,
  double dx,
  double dy,
  double dz,
  _SupportFace3D out,
) {
  var axis = 0;
  var best = -1.0;
  var sign = 1.0;
  for (var k = 0; k < 3; k++) {
    final d = obb.axisX(k) * dx + obb.axisY(k) * dy + obb.axisZ(k) * dz;
    if (d.abs() > best) {
      best = d.abs();
      axis = k;
      sign = d >= 0.0 ? 1.0 : -1.0;
    }
  }
  final a0 = (axis + 1) % 3;
  final a1 = (axis + 2) % 3;
  final nx = sign * obb.axisX(axis);
  final ny = sign * obb.axisY(axis);
  final nz = sign * obb.axisZ(axis);
  final e = obb.extent(axis);
  final fcx = obb.cx + nx * e;
  final fcy = obb.cy + ny * e;
  final fcz = obb.cz + nz * e;
  final ux = obb.axisX(a0) * obb.extent(a0);
  final uy = obb.axisY(a0) * obb.extent(a0);
  final uz = obb.axisZ(a0) * obb.extent(a0);
  final vx = obb.axisX(a1) * obb.extent(a1) * sign;
  final vy = obb.axisY(a1) * obb.extent(a1) * sign;
  final vz = obb.axisZ(a1) * obb.extent(a1) * sign;
  out
    ..reset(4)
    ..nx = nx
    ..ny = ny
    ..nz = nz
    ..faceId = axis * 2 + (sign > 0.0 ? 0 : 1)
    ..setVertex(0, fcx + ux + vx, fcy + uy + vy, fcz + uz + vz)
    ..setVertex(1, fcx - ux + vx, fcy - uy + vy, fcz - uz + vz)
    ..setVertex(2, fcx - ux - vx, fcy - uy - vy, fcz - uz - vz)
    ..setVertex(3, fcx + ux - vx, fcy + uy - vy, fcz + uz - vz);
}

bool _writeHullFace(
  ConvexHullShape3D hull,
  Matrix4 transform,
  double dx,
  double dy,
  double dz,
  _SupportFace3D out,
) {
  final normals = hull.hullFaceNormals;
  final start = hull.hullFaceStart;
  final verts = hull.hullFaceVertices;
  if (normals == null || start == null || verts == null) {
    return false;
  }
  final m = transform.storage;
  final c0x = m[0];
  final c0y = m[1];
  final c0z = m[2];
  final c1x = m[4];
  final c1y = m[5];
  final c1z = m[6];
  final c2x = m[8];
  final c2y = m[9];
  final c2z = m[10];
  // Columns of the cofactor matrix: world normals are `cof * localNormal`.
  var k0x = c1y * c2z - c1z * c2y;
  var k0y = c1z * c2x - c1x * c2z;
  var k0z = c1x * c2y - c1y * c2x;
  var k1x = c2y * c0z - c2z * c0y;
  var k1y = c2z * c0x - c2x * c0z;
  var k1z = c2x * c0y - c2y * c0x;
  var k2x = c0y * c1z - c0z * c1y;
  var k2y = c0z * c1x - c0x * c1z;
  var k2z = c0x * c1y - c0y * c1x;
  if (c0x * k0x + c0y * k0y + c0z * k0z < 0.0) {
    k0x = -k0x;
    k0y = -k0y;
    k0z = -k0z;
    k1x = -k1x;
    k1y = -k1y;
    k1z = -k1z;
    k2x = -k2x;
    k2y = -k2y;
    k2z = -k2z;
  }
  final faceCount = start.length - 1;
  var bestFace = 0;
  var bestDot = double.negativeInfinity;
  var bnx = 0.0;
  var bny = 0.0;
  var bnz = 0.0;
  for (var f = 0; f < faceCount; f++) {
    final lx = normals[f * 3];
    final ly = normals[f * 3 + 1];
    final lz = normals[f * 3 + 2];
    final wx = k0x * lx + k1x * ly + k2x * lz;
    final wy = k0y * lx + k1y * ly + k2y * lz;
    final wz = k0z * lx + k1z * ly + k2z * lz;
    final len = math.sqrt(wx * wx + wy * wy + wz * wz);
    if (len <= 1e-30) {
      continue;
    }
    final d = (wx * dx + wy * dy + wz * dz) / len;
    if (d > bestDot) {
      bestDot = d;
      bestFace = f;
      bnx = wx / len;
      bny = wy / len;
      bnz = wz / len;
    }
  }
  if (bestDot == double.negativeInfinity) {
    return false;
  }
  final coords = hull.hullCoords;
  final s = start[bestFace];
  final count = start[bestFace + 1] - s;
  out
    ..reset(count)
    ..nx = bnx
    ..ny = bny
    ..nz = bnz
    ..faceId = bestFace;
  for (var k = 0; k < count; k++) {
    final o = verts[s + k] * 3;
    final lx = coords[o];
    final ly = coords[o + 1];
    final lz = coords[o + 2];
    out.setVertex(
      k,
      m[0] * lx + m[4] * ly + m[8] * lz + m[12],
      m[1] * lx + m[5] * ly + m[9] * lz + m[13],
      m[2] * lx + m[6] * ly + m[10] * lz + m[14],
    );
  }
  return true;
}

/// Builds a multi-point manifold by clipping the incident face against the
/// side planes of the reference face (the supporting face better aligned
/// with the A-to-B normal `(nx, ny, nz)`), or returns `null` when the faces
/// are not aligned enough for a face contact or nothing survives clipping.
///
/// [forceReference] picks the reference face (`1`: A, `2`: B) instead.
/// Each contact point gets a feature id built from the two faces and the
/// clipped features, stable while the same features stay in contact.
bool _prepareClippedFaces(
  double nx,
  double ny,
  double nz,
  _SupportFace3D fA,
  _SupportFace3D fB, {
  int forceReference = 0,
}) {
  final alignA = fA.nx * nx + fA.ny * ny + fA.nz * nz;
  final alignB = -(fB.nx * nx + fB.ny * ny + fB.nz * nz);
  final bool refIsA;
  if (forceReference == 0) {
    if (math.max(alignA, alignB) < _faceAlignmentCos) {
      return false;
    }
    refIsA = alignA >= alignB - 1e-4;
  } else {
    refIsA = forceReference == 1;
  }
  final ref = refIsA ? fA : fB;
  final inc = refIsA ? fB : fA;
  final rnx = ref.nx;
  final rny = ref.ny;
  final rnz = ref.nz;
  final rv = ref.xyz;
  final rCount = ref.count;

  var ccx = 0.0;
  var ccy = 0.0;
  var ccz = 0.0;
  for (var i = 0; i < rCount; i++) {
    ccx += rv[i * 3];
    ccy += rv[i * 3 + 1];
    ccz += rv[i * 3 + 2];
  }
  ccx /= rCount;
  ccy /= rCount;
  ccz /= rCount;

  final clip = Narrowphase3D._scratch.clip.clip..load(inc);
  for (var i = 0; i < rCount; i++) {
    final j = i + 1 == rCount ? 0 : i + 1;
    final vix = rv[i * 3];
    final viy = rv[i * 3 + 1];
    final viz = rv[i * 3 + 2];
    final ex = rv[j * 3] - vix;
    final ey = rv[j * 3 + 1] - viy;
    final ez = rv[j * 3 + 2] - viz;
    var sx = ey * rnz - ez * rny;
    var sy = ez * rnx - ex * rnz;
    var sz = ex * rny - ey * rnx;
    final len = math.sqrt(sx * sx + sy * sy + sz * sz);
    if (len <= 1e-12) {
      continue;
    }
    sx /= len;
    sy /= len;
    sz /= len;
    if (sx * (ccx - vix) + sy * (ccy - viy) + sz * (ccz - viz) > 0.0) {
      sx = -sx;
      sy = -sy;
      sz = -sz;
    }
    final limit = sx * vix + sy * viy + sz * viz;
    if (!clip.clipHalfspace(sx, sy, sz, limit, i + 1)) {
      return false;
    }
  }

  final refD = rnx * rv[0] + rny * rv[1] + rnz * rv[2];
  final kept = clip.keepBelow(rnx, rny, rnz, refD, _faceContactTolerance);
  if (kept == 0) {
    return false;
  }
  final pick = kept <= 4
      ? kept
      : clip.selectFour(rnx, rny, rnz, Narrowphase3D._scratch.clip.chosen);
  Narrowphase3D._scratch.clip.refIsA = refIsA;
  Narrowphase3D._scratch.clip.rnx = rnx;
  Narrowphase3D._scratch.clip.rny = rny;
  Narrowphase3D._scratch.clip.rnz = rnz;
  Narrowphase3D._scratch.clip.base = _mixId(
    _mixId(refIsA ? 1 : 2, ref.faceId),
    inc.faceId,
  );
  Narrowphase3D._scratch.clip.pick = pick;
  Narrowphase3D._scratch.clip.kept = kept;
  return true;
}

bool _clipSupportFacesInto(
  double nx,
  double ny,
  double nz,
  _SupportFace3D fA,
  _SupportFace3D fB,
  MutableManifoldBuffer3D out, {
  int forceReference = 0,
  double depthOverride = -1.0,
  bool quantizeFloat32 = false,
}) {
  if (!_prepareClippedFaces(
    nx,
    ny,
    nz,
    fA,
    fB,
    forceReference: forceReference,
  )) {
    return false;
  }
  final refIsA = Narrowphase3D._scratch.clip.refIsA;
  final rnx = Narrowphase3D._scratch.clip.rnx;
  final rny = Narrowphase3D._scratch.clip.rny;
  final rnz = Narrowphase3D._scratch.clip.rnz;
  final base = Narrowphase3D._scratch.clip.base;
  final pick = Narrowphase3D._scratch.clip.pick;
  final kept = Narrowphase3D._scratch.clip.kept;
  final clip = Narrowphase3D._scratch.clip.clip;
  var outNx = refIsA ? rnx : -rnx;
  var outNy = refIsA ? rny : -rny;
  var outNz = refIsA ? rnz : -rnz;
  if (quantizeFloat32) {
    Narrowphase3D._scratch.clip.f32Contact[0] = outNx;
    Narrowphase3D._scratch.clip.f32Contact[1] = outNy;
    Narrowphase3D._scratch.clip.f32Contact[2] = outNz;
    outNx = Narrowphase3D._scratch.clip.f32Contact[0];
    outNy = Narrowphase3D._scratch.clip.f32Contact[1];
    outNz = Narrowphase3D._scratch.clip.f32Contact[2];
  }
  final mIdx = out.beginManifold(
    outNx,
    outNy,
    outNz,
    depthOverride >= 0.0 ? depthOverride : 0.0,
  );
  var maxDepth = 0.0;
  for (var k = 0; k < pick; k++) {
    final idx = kept <= 4 ? k : Narrowphase3D._scratch.clip.chosen[k];
    final px = clip.keptX(idx);
    final py = clip.keptY(idx);
    final pz = clip.keptZ(idx);
    final sep = clip.keptSep(idx);
    final depth = sep < 0.0 ? -sep : 0.0;
    if (depth > maxDepth) {
      maxDepth = depth;
    }
    var refX = px - rnx * sep;
    var refY = py - rny * sep;
    var refZ = pz - rnz * sep;
    var incX = px;
    var incY = py;
    var incZ = pz;
    if (quantizeFloat32) {
      Narrowphase3D._scratch.clip.f32Contact[3] = refX;
      Narrowphase3D._scratch.clip.f32Contact[4] = refY;
      Narrowphase3D._scratch.clip.f32Contact[5] = refZ;
      Narrowphase3D._scratch.clip.f32Contact[6] = incX;
      Narrowphase3D._scratch.clip.f32Contact[7] = incY;
      Narrowphase3D._scratch.clip.f32Contact[8] = incZ;
      refX = Narrowphase3D._scratch.clip.f32Contact[3];
      refY = Narrowphase3D._scratch.clip.f32Contact[4];
      refZ = Narrowphase3D._scratch.clip.f32Contact[5];
      incX = Narrowphase3D._scratch.clip.f32Contact[6];
      incY = Narrowphase3D._scratch.clip.f32Contact[7];
      incZ = Narrowphase3D._scratch.clip.f32Contact[8];
    }
    final feat = _mixId(base, clip.keptId(idx));
    if (refIsA) {
      out.addContact(mIdx, refX, refY, refZ, incX, incY, incZ, depth, feat);
    } else {
      out.addContact(mIdx, incX, incY, incZ, refX, refY, refZ, depth, feat);
    }
  }
  if (depthOverride < 0.0) {
    out.setDepth(mIdx, maxDepth);
  }
  return true;
}

class _SupportFace3D() {
  Float64List xyz = Float64List(48);
  int count = 0;
  double nx = 0.0;
  double ny = 0.0;
  double nz = 0.0;
  int faceId = 0;

  void reset(int vertexCount) {
    if (xyz.length < vertexCount * 3) {
      xyz = Float64List(vertexCount * 3);
    }
    count = vertexCount;
  }

  void setVertex(int i, double x, double y, double z) {
    xyz[i * 3] = x;
    xyz[i * 3 + 1] = y;
    xyz[i * 3 + 2] = z;
  }

  void setTriangle(Vector3 v0, Vector3 v1, Vector3 v2) {
    reset(3);
    setVertex(0, v0.x, v0.y, v0.z);
    setVertex(1, v1.x, v1.y, v1.z);
    setVertex(2, v2.x, v2.y, v2.z);
  }
}

/// Ping-pong polygon buffers for Sutherland-Hodgman clipping with feature ids
/// per vertex, growing only when a larger polygon is seen.
class _ClipBuffer3D() {
  Float64List _a = Float64List(96);
  Float64List _b = Float64List(96);
  Int32List _aId = Int32List(32);
  Int32List _bId = Int32List(32);
  int _count = 0;
  Float64List _kept = Float64List(128);
  Int32List _keptId = Int32List(32);

  void _ensure(int vertices) {
    if (_aId.length < vertices) {
      final cap = vertices * 2;
      _a = Float64List(cap * 3)..setRange(0, _count * 3, _a);
      _aId = Int32List(cap)..setRange(0, _count, _aId);
      _b = Float64List(cap * 3);
      _bId = Int32List(cap);
      _kept = Float64List(cap * 4);
      _keptId = Int32List(cap);
    }
  }

  void load(_SupportFace3D face) {
    _count = 0;
    _ensure(face.count + 8);
    for (var i = 0; i < face.count; i++) {
      _a[i * 3] = face.xyz[i * 3];
      _a[i * 3 + 1] = face.xyz[i * 3 + 1];
      _a[i * 3 + 2] = face.xyz[i * 3 + 2];
      _aId[i] = i;
    }
    _count = face.count;
  }

  /// Keeps the part of the polygon with `n . x <= limit`; returns `false`
  /// when nothing is left.
  bool clipHalfspace(double nx, double ny, double nz, double limit, int plane) {
    _ensure(_count * 2 + 2);
    var outCount = 0;
    final n = _count;
    if (n == 0) {
      return false;
    }
    var prev = n - 1;
    var prevDist =
        _a[prev * 3] * nx +
        _a[prev * 3 + 1] * ny +
        _a[prev * 3 + 2] * nz -
        limit;
    for (var i = 0; i < n; i++) {
      final currDist =
          _a[i * 3] * nx + _a[i * 3 + 1] * ny + _a[i * 3 + 2] * nz - limit;
      // A vertex within 10 micrometres of the plane stays in (with its own
      // feature id): equal faces stacked edge on edge otherwise flip between
      // kept and clipped vertices with float noise.
      final prevIn = prevDist <= 1e-5;
      final currIn = currDist <= 1e-5;
      if (prevIn != currIn) {
        final t = prevDist / (prevDist - currDist);
        _b[outCount * 3] = _a[prev * 3] + (_a[i * 3] - _a[prev * 3]) * t;
        _b[outCount * 3 + 1] =
            _a[prev * 3 + 1] + (_a[i * 3 + 1] - _a[prev * 3 + 1]) * t;
        _b[outCount * 3 + 2] =
            _a[prev * 3 + 2] + (_a[i * 3 + 2] - _a[prev * 3 + 2]) * t;
        _bId[outCount] = _mixId(
          _mixId(_aId[prev] + 64, _aId[i] + 64),
          plane,
        );
        outCount++;
      }
      if (currIn) {
        _b[outCount * 3] = _a[i * 3];
        _b[outCount * 3 + 1] = _a[i * 3 + 1];
        _b[outCount * 3 + 2] = _a[i * 3 + 2];
        _bId[outCount] = _aId[i];
        outCount++;
      }
      prev = i;
      prevDist = currDist;
    }
    final t = _a;
    _a = _b;
    _b = t;
    final tId = _aId;
    _aId = _bId;
    _bId = tId;
    _count = outCount;
    return outCount > 0;
  }

  /// Keeps the vertices at most [tolerance] above the plane `n . x = d`,
  /// storing their signed separation; returns how many were kept.
  int keepBelow(double nx, double ny, double nz, double d, double tolerance) {
    var kept = 0;
    for (var i = 0; i < _count; i++) {
      final x = _a[i * 3];
      final y = _a[i * 3 + 1];
      final z = _a[i * 3 + 2];
      final sep = nx * x + ny * y + nz * z - d;
      if (sep <= tolerance) {
        _kept[kept * 4] = x;
        _kept[kept * 4 + 1] = y;
        _kept[kept * 4 + 2] = z;
        _kept[kept * 4 + 3] = sep;
        _keptId[kept] = _aId[i];
        kept++;
      }
    }
    _keptCount = kept;
    return kept;
  }

  int _keptCount = 0;

  double keptX(int i) => _kept[i * 4];
  double keptY(int i) => _kept[i * 4 + 1];
  double keptZ(int i) => _kept[i * 4 + 2];
  double keptSep(int i) => _kept[i * 4 + 3];
  int keptId(int i) => _keptId[i];

  double _dist2(int i, int j) {
    final dx = keptX(i) - keptX(j);
    final dy = keptY(i) - keptY(j);
    final dz = keptZ(i) - keptZ(j);
    return dx * dx + dy * dy + dz * dz;
  }

  /// Picks four well-spread kept points (the deepest, the farthest from it,
  /// the one spanning the largest triangle with both, then the farthest from
  /// those three) into [out]; returns `4`.
  int selectFour(double nx, double ny, double nz, Int32List out) {
    final n = _keptCount;
    var i0 = 0;
    for (var i = 1; i < n; i++) {
      if (keptSep(i) < keptSep(i0)) {
        i0 = i;
      }
    }
    var i1 = i0 == 0 ? 1 : 0;
    var best = -1.0;
    for (var i = 0; i < n; i++) {
      if (i == i0) {
        continue;
      }
      final dx = keptX(i) - keptX(i0);
      final dy = keptY(i) - keptY(i0);
      final dz = keptZ(i) - keptZ(i0);
      final d2 = dx * dx + dy * dy + dz * dz;
      if (d2 > best) {
        best = d2;
        i1 = i;
      }
    }
    var i2 = -1;
    best = -1.0;
    final e1x = keptX(i1) - keptX(i0);
    final e1y = keptY(i1) - keptY(i0);
    final e1z = keptZ(i1) - keptZ(i0);
    for (var i = 0; i < n; i++) {
      if (i == i0 || i == i1) {
        continue;
      }
      final e2x = keptX(i) - keptX(i0);
      final e2y = keptY(i) - keptY(i0);
      final e2z = keptZ(i) - keptZ(i0);
      final cx = e1y * e2z - e1z * e2y;
      final cy = e1z * e2x - e1x * e2z;
      final cz = e1x * e2y - e1y * e2x;
      final area = (cx * nx + cy * ny + cz * nz).abs();
      if (area > best) {
        best = area;
        i2 = i;
      }
    }
    var i3 = -1;
    best = -1.0;
    for (var i = 0; i < n; i++) {
      if (i == i0 || i == i1 || i == i2) {
        continue;
      }
      final dMin = math.min(
        _dist2(i, i0),
        math.min(_dist2(i, i1), i2 < 0 ? double.infinity : _dist2(i, i2)),
      );
      if (dMin > best) {
        best = dMin;
        i3 = i;
      }
    }
    out[0] = i0;
    out[1] = i1;
    out[2] = i2;
    out[3] = i3;
    return 4;
  }
}
