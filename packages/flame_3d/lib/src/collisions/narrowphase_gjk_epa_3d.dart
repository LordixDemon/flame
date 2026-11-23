part of 'collision_manifold_3d.dart';

const double _faceContactTolerance = 0.002;
const double _faceAlignmentCos = 0.995;
final _SupportFace3D _faceA = _SupportFace3D();
final _SupportFace3D _faceB = _SupportFace3D();
final _ClipBuffer3D _clip = _ClipBuffer3D();
final _ObbFrame _obbFace = _ObbFrame();
final Int32List _chosen = Int32List(4);
final Float32List _f32Contact = Float32List(9);
final List<Vector3> _epaSeedDirs = _buildSphereDirs();

bool _clipRefIsA = false;
double _clipRnx = 0.0;
double _clipRny = 0.0;
double _clipRnz = 0.0;
int _clipBase = 0;
int _clipPick = 0;
int _clipKept = 0;

// Flat zero-allocation GJK + EPA scratch storage and scalar outputs.
const int _maxEpaVerts = 64;
const int _gjkTempSlot = 64;
final Float64List _gjkP = Float64List((_maxEpaVerts + 4) * 3);
final Float64List _gjkA = Float64List((_maxEpaVerts + 4) * 3);
final Float64List _gjkB = Float64List((_maxEpaVerts + 4) * 3);
int _gjkVertCount = 0;
double _gjkDx = 0.0;
double _gjkDy = 0.0;
double _gjkDz = 0.0;
final Vector3 _gjkDirVec = Vector3.zero();
final Vector3 _gjkNegDirVec = Vector3.zero();
final Vector3 _gjkSupA = Vector3.zero();
final Vector3 _gjkSupB = Vector3.zero();

int _epaFaceCap = 256;
Int32List _epaI0 = Int32List(256);
Int32List _epaI1 = Int32List(256);
Int32List _epaI2 = Int32List(256);
Float64List _epaFn = Float64List(256 * 3);
Float64List _epaFd = Float64List(256);
Uint8List _epaVisible = Uint8List(256);
int _epaFaceCount = 0;

int _epaHorizCap = 256;
Int32List _epaHorizA = Int32List(256);
Int32List _epaHorizB = Int32List(256);
int _epaHorizCount = 0;

double _epaNx = 0.0;
double _epaNy = 0.0;
double _epaNz = 0.0;
double _epaDepth = 0.0;
double _epaAx = 0.0;
double _epaAy = 0.0;
double _epaAz = 0.0;
double _epaBx = 0.0;
double _epaBy = 0.0;
double _epaBz = 0.0;

/// General Convex-Convex narrowphase using GJK + Expanding Polytope Algorithm
/// (with spherical direction fallback for degenerate simplices).
///
/// When both shapes have faces (boxes and non-degenerate hulls) and the EPA
/// normal is within about 5.7 degrees of one of their supporting faces, the
/// incident face is clipped against the reference face, which gives up to
/// four contact points with stable feature ids; otherwise (edge against
/// edge, or a curved shape) the manifold has the single EPA point.
CollisionManifold3D? _npConvexConvex(
  Shape3D shapeA,
  Matrix4 transformA,
  Shape3D shapeB,
  Matrix4 transformB,
) {
  final cA = centerOfMatrix3D(transformA, _cAScratch);
  final cB = centerOfMatrix3D(transformB, _cBScratch);
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
    return null;
  }
  if (_writeSupportFace(shapeA, transformA, _epaNx, _epaNy, _epaNz, _faceA) &&
      _writeSupportFace(
        shapeB,
        transformB,
        -_epaNx,
        -_epaNy,
        -_epaNz,
        _faceB,
      )) {
    final faced = _clipSupportFaces(
      _epaNx,
      _epaNy,
      _epaNz,
      _faceA,
      _faceB,
    );
    if (faced != null) {
      return faced;
    }
  }
  return CollisionManifold3D(
    normal: Vector3(_epaNx, _epaNy, _epaNz),
    penetrationDepth: _epaDepth,
    contactPointA: Vector3(_epaAx, _epaAy, _epaAz),
    contactPointB: Vector3(_epaBx, _epaBy, _epaBz),
  );
}

void _convexConvexInto(
  Shape3D shapeA,
  Matrix4 transformA,
  Shape3D shapeB,
  Matrix4 transformB,
  MutableManifoldBuffer3D out,
) {
  final cA = centerOfMatrix3D(transformA, _cAScratch);
  final cB = centerOfMatrix3D(transformB, _cBScratch);
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
  if (_writeSupportFace(shapeA, transformA, _epaNx, _epaNy, _epaNz, _faceA) &&
      _writeSupportFace(
        shapeB,
        transformB,
        -_epaNx,
        -_epaNy,
        -_epaNz,
        _faceB,
      )) {
    if (_clipSupportFacesInto(
      _epaNx,
      _epaNy,
      _epaNz,
      _faceA,
      _faceB,
      out,
      quantizeFloat32: true,
    )) {
      return;
    }
  }
  _f32Contact[0] = _epaNx;
  _f32Contact[1] = _epaNy;
  _f32Contact[2] = _epaNz;
  _f32Contact[3] = _epaAx;
  _f32Contact[4] = _epaAy;
  _f32Contact[5] = _epaAz;
  _f32Contact[6] = _epaBx;
  _f32Contact[7] = _epaBy;
  _f32Contact[8] = _epaBz;
  out.pushSingle(
    _f32Contact[0],
    _f32Contact[1],
    _f32Contact[2],
    _epaDepth,
    _f32Contact[3],
    _f32Contact[4],
    _f32Contact[5],
    _f32Contact[6],
    _f32Contact[7],
    _f32Contact[8],
  );
}

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
  if (shape is BoxShape3D) {
    _obbFace.extract(shape, m);
    _writeObbFace(_obbFace, dx, dy, dz, out);
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

  final clip = _clip..load(inc);
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
  final pick = kept <= 4 ? kept : clip.selectFour(rnx, rny, rnz, _chosen);
  _clipRefIsA = refIsA;
  _clipRnx = rnx;
  _clipRny = rny;
  _clipRnz = rnz;
  _clipBase = _mixId(_mixId(refIsA ? 1 : 2, ref.faceId), inc.faceId);
  _clipPick = pick;
  _clipKept = kept;
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
  final refIsA = _clipRefIsA;
  final rnx = _clipRnx;
  final rny = _clipRny;
  final rnz = _clipRnz;
  final base = _clipBase;
  final pick = _clipPick;
  final kept = _clipKept;
  final clip = _clip;
  var outNx = refIsA ? rnx : -rnx;
  var outNy = refIsA ? rny : -rny;
  var outNz = refIsA ? rnz : -rnz;
  if (quantizeFloat32) {
    _f32Contact[0] = outNx;
    _f32Contact[1] = outNy;
    _f32Contact[2] = outNz;
    outNx = _f32Contact[0];
    outNy = _f32Contact[1];
    outNz = _f32Contact[2];
  }
  final mIdx = out.beginManifold(
    outNx,
    outNy,
    outNz,
    depthOverride >= 0.0 ? depthOverride : 0.0,
  );
  var maxDepth = 0.0;
  for (var k = 0; k < pick; k++) {
    final idx = kept <= 4 ? k : _chosen[k];
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
      _f32Contact[3] = refX;
      _f32Contact[4] = refY;
      _f32Contact[5] = refZ;
      _f32Contact[6] = incX;
      _f32Contact[7] = incY;
      _f32Contact[8] = incZ;
      refX = _f32Contact[3];
      refY = _f32Contact[4];
      refZ = _f32Contact[5];
      incX = _f32Contact[6];
      incY = _f32Contact[7];
      incZ = _f32Contact[8];
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

CollisionManifold3D? _clipSupportFaces(
  double nx,
  double ny,
  double nz,
  _SupportFace3D fA,
  _SupportFace3D fB, {
  int forceReference = 0,
  double depthOverride = -1.0,
}) {
  if (!_prepareClippedFaces(
    nx,
    ny,
    nz,
    fA,
    fB,
    forceReference: forceReference,
  )) {
    return null;
  }
  final refIsA = _clipRefIsA;
  final rnx = _clipRnx;
  final rny = _clipRny;
  final rnz = _clipRnz;
  final base = _clipBase;
  final pick = _clipPick;
  final kept = _clipKept;
  final clip = _clip;
  final contacts = <ContactPoint3D>[];
  var maxDepth = 0.0;
  var ax = 0.0;
  var ay = 0.0;
  var az = 0.0;
  var bx = 0.0;
  var by = 0.0;
  var bz = 0.0;
  for (var k = 0; k < pick; k++) {
    final idx = kept <= 4 ? k : _chosen[k];
    final px = clip.keptX(idx);
    final py = clip.keptY(idx);
    final pz = clip.keptZ(idx);
    final sep = clip.keptSep(idx);
    final depth = sep < 0.0 ? -sep : 0.0;
    if (depth > maxDepth) {
      maxDepth = depth;
    }
    final pInc = Vector3(px, py, pz);
    final pRef = Vector3(px - rnx * sep, py - rny * sep, pz - rnz * sep);
    final pa = refIsA ? pRef : pInc;
    final pb = refIsA ? pInc : pRef;
    ax += pa.x;
    ay += pa.y;
    az += pa.z;
    bx += pb.x;
    by += pb.y;
    bz += pb.z;
    contacts.add(
      ContactPoint3D(
        pointA: pa,
        pointB: pb,
        penetrationDepth: depth,
        featureId: _mixId(base, clip.keptId(idx)),
      ),
    );
  }
  final inv = 1.0 / pick;
  return CollisionManifold3D(
    normal: refIsA ? Vector3(rnx, rny, rnz) : Vector3(-rnx, -rny, -rnz),
    penetrationDepth: depthOverride >= 0.0 ? depthOverride : maxDepth,
    contactPointA: Vector3(ax * inv, ay * inv, az * inv),
    contactPointB: Vector3(bx * inv, by * inv, bz * inv),
    contacts: contacts,
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
  _gjkDirVec.setValues(dx, dy, dz);
  shapeA.supportPoint(_gjkDirVec, transformA, _gjkSupA);
  _gjkNegDirVec.setValues(-dx, -dy, -dz);
  if (shapeB != null) {
    shapeB.supportPoint(_gjkNegDirVec, transformB!, _gjkSupB);
  } else {
    triangleSupport3D(triV0!, triV1!, triV2!, _gjkNegDirVec, _gjkSupB);
  }
  final o = slot * 3;
  final ax = _gjkSupA.x;
  final ay = _gjkSupA.y;
  final az = _gjkSupA.z;
  final bx = _gjkSupB.x;
  final by = _gjkSupB.y;
  final bz = _gjkSupB.z;
  _gjkA[o] = ax;
  _gjkA[o + 1] = ay;
  _gjkA[o + 2] = az;
  _gjkB[o] = bx;
  _gjkB[o + 1] = by;
  _gjkB[o + 2] = bz;
  _gjkP[o] = ax - bx;
  _gjkP[o + 1] = ay - by;
  _gjkP[o + 2] = az - bz;
}

@pragma('vm:prefer-inline')
void _copyGjkVert(int dst, int src) {
  final d = dst * 3;
  final s = src * 3;
  _gjkP[d] = _gjkP[s];
  _gjkP[d + 1] = _gjkP[s + 1];
  _gjkP[d + 2] = _gjkP[s + 2];
  _gjkA[d] = _gjkA[s];
  _gjkA[d + 1] = _gjkA[s + 1];
  _gjkA[d + 2] = _gjkA[s + 2];
  _gjkB[d] = _gjkB[s];
  _gjkB[d + 1] = _gjkB[s + 1];
  _gjkB[d + 2] = _gjkB[s + 2];
}

@pragma('vm:prefer-inline')
void _removeGjkVert(int index) {
  final last = _gjkVertCount - 1;
  for (var i = index; i < last; i++) {
    _copyGjkVert(i, i + 1);
  }
  _gjkVertCount = last;
}

@pragma('vm:prefer-inline')
void _swapGjkVerts(int i, int j) {
  _copyGjkVert(_gjkTempSlot, i);
  _copyGjkVert(i, j);
  _copyGjkVert(j, _gjkTempSlot);
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
  _gjkDx = cBx - cAx;
  _gjkDy = cBy - cAy;
  _gjkDz = cBz - cAz;
  if (_gjkDx * _gjkDx + _gjkDy * _gjkDy + _gjkDz * _gjkDz < 1e-12) {
    _gjkDx = 1.0;
    _gjkDy = 0.0;
    _gjkDz = 0.0;
  }

  _gjkVertCount = 1;
  _supportMinkowskiAt(
    0,
    _gjkDx,
    _gjkDy,
    _gjkDz,
    shapeA,
    transformA,
    shapeB,
    transformB,
    triV0,
    triV1,
    triV2,
  );
  _gjkDx = -_gjkP[0];
  _gjkDy = -_gjkP[1];
  _gjkDz = -_gjkP[2];

  var hit = false;
  for (var iter = 0; iter < 48; iter++) {
    if (_gjkDx * _gjkDx + _gjkDy * _gjkDy + _gjkDz * _gjkDz < 1e-16) {
      hit = true;
      break;
    }
    final slot = _gjkVertCount;
    _supportMinkowskiAt(
      slot,
      _gjkDx,
      _gjkDy,
      _gjkDz,
      shapeA,
      transformA,
      shapeB,
      transformB,
      triV0,
      triV1,
      triV2,
    );
    final o = slot * 3;
    if (_gjkP[o] * _gjkDx + _gjkP[o + 1] * _gjkDy + _gjkP[o + 2] * _gjkDz <
        -1e-9) {
      return false;
    }
    _gjkVertCount = slot + 1;
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
  if (_gjkVertCount == 2) {
    final ax = _gjkP[3];
    final ay = _gjkP[4];
    final az = _gjkP[5];
    final abx = _gjkP[0] - ax;
    final aby = _gjkP[1] - ay;
    final abz = _gjkP[2] - az;
    final aox = -ax;
    final aoy = -ay;
    final aoz = -az;
    if (abx * aox + aby * aoy + abz * aoz > 0.0) {
      // (ab x ao) x ab
      final t1x = aby * aoz - abz * aoy;
      final t1y = abz * aox - abx * aoz;
      final t1z = abx * aoy - aby * aox;
      _gjkDx = t1y * abz - t1z * aby;
      _gjkDy = t1z * abx - t1x * abz;
      _gjkDz = t1x * aby - t1y * abx;
      if (_gjkDx * _gjkDx + _gjkDy * _gjkDy + _gjkDz * _gjkDz < 1e-16) {
        _anyPerpScalars(abx, aby, abz);
      }
    } else {
      _removeGjkVert(0);
      _gjkDx = aox;
      _gjkDy = aoy;
      _gjkDz = aoz;
    }
    return false;
  }
  if (_gjkVertCount == 3) {
    final ax = _gjkP[6];
    final ay = _gjkP[7];
    final az = _gjkP[8];
    final abx = _gjkP[3] - ax;
    final aby = _gjkP[4] - ay;
    final abz = _gjkP[5] - az;
    final acx = _gjkP[0] - ax;
    final acy = _gjkP[1] - ay;
    final acz = _gjkP[2] - az;
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
        _gjkDx = t1y * acz - t1z * acy;
        _gjkDy = t1z * acx - t1x * acz;
        _gjkDz = t1x * acy - t1y * acx;
      } else if (abx * aox + aby * aoy + abz * aoz > 0.0) {
        _removeGjkVert(0);
        final t1x = aby * aoz - abz * aoy;
        final t1y = abz * aox - abx * aoz;
        final t1z = abx * aoy - aby * aox;
        _gjkDx = t1y * abz - t1z * aby;
        _gjkDy = t1z * abx - t1x * abz;
        _gjkDz = t1x * aby - t1y * abx;
      } else {
        _removeGjkVert(1);
        _removeGjkVert(0);
        _gjkDx = aox;
        _gjkDy = aoy;
        _gjkDz = aoz;
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
        _gjkDx = t1y * abz - t1z * aby;
        _gjkDy = t1z * abx - t1x * abz;
        _gjkDz = t1x * aby - t1y * abx;
      } else {
        _removeGjkVert(1);
        _removeGjkVert(0);
        _gjkDx = aox;
        _gjkDy = aoy;
        _gjkDz = aoz;
      }
      return false;
    }

    if (abcx * aox + abcy * aoy + abcz * aoz > 0.0) {
      _gjkDx = abcx;
      _gjkDy = abcy;
      _gjkDz = abcz;
    } else {
      _swapGjkVerts(0, 1);
      _gjkDx = -abcx;
      _gjkDy = -abcy;
      _gjkDz = -abcz;
    }
    return false;
  }

  // Tetrahedron slots `[0:d, 1:c, 2:b, 3:a]`.
  final ax = _gjkP[9];
  final ay = _gjkP[10];
  final az = _gjkP[11];
  final aox = -ax;
  final aoy = -ay;
  final aoz = -az;
  final abx = _gjkP[6] - ax;
  final aby = _gjkP[7] - ay;
  final abz = _gjkP[8] - az;
  final acx = _gjkP[3] - ax;
  final acy = _gjkP[4] - ay;
  final acz = _gjkP[5] - az;
  final adx = _gjkP[0] - ax;
  final ady = _gjkP[1] - ay;
  final adz = _gjkP[2] - az;

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
    _gjkDx = abcx;
    _gjkDy = abcy;
    _gjkDz = abcz;
    return false;
  }
  if (acdx * aox + acdy * aoy + acdz * aoz > 1e-12) {
    _removeGjkVert(2);
    _gjkDx = acdx;
    _gjkDy = acdy;
    _gjkDz = acdz;
    return false;
  }
  if (adbx * aox + adby * aoy + adbz * aoz > 1e-12) {
    _removeGjkVert(1);
    _gjkDx = adbx;
    _gjkDy = adby;
    _gjkDz = adbz;
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
    _gjkDx = 0.0;
    _gjkDy = 1.0;
    _gjkDz = 0.0;
  } else {
    _gjkDx = x;
    _gjkDy = y;
    _gjkDz = z;
  }
}

void _ensureEpaFaceCapacity(int count) {
  if (_epaFaceCap >= count) {
    return;
  }
  final newCap = _epaFaceCap * 2;
  _epaI0 = Int32List(newCap)..setRange(0, _epaFaceCount, _epaI0);
  _epaI1 = Int32List(newCap)..setRange(0, _epaFaceCount, _epaI1);
  _epaI2 = Int32List(newCap)..setRange(0, _epaFaceCount, _epaI2);
  _epaFn = Float64List(newCap * 3)..setRange(0, _epaFaceCount * 3, _epaFn);
  _epaFd = Float64List(newCap)..setRange(0, _epaFaceCount, _epaFd);
  _epaVisible = Uint8List(newCap);
  _epaFaceCap = newCap;
}

void _ensureEpaHorizonCapacity(int count) {
  if (_epaHorizCap >= count) {
    return;
  }
  final newCap = _epaHorizCap * 2;
  _epaHorizA = Int32List(newCap)..setRange(0, _epaHorizCount, _epaHorizA);
  _epaHorizB = Int32List(newCap)..setRange(0, _epaHorizCount, _epaHorizB);
  _epaHorizCap = newCap;
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
  final p0x = _gjkP[o0];
  final p0y = _gjkP[o0 + 1];
  final p0z = _gjkP[o0 + 2];
  final e1x = _gjkP[o1] - p0x;
  final e1y = _gjkP[o1 + 1] - p0y;
  final e1z = _gjkP[o1 + 2] - p0z;
  final e2x = _gjkP[o2] - p0x;
  final e2y = _gjkP[o2 + 1] - p0y;
  final e2z = _gjkP[o2 + 2] - p0z;
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
  final fIdx = _epaFaceCount;
  _ensureEpaFaceCapacity(fIdx + 1);
  _epaFaceCount = fIdx + 1;
  _epaI0[fIdx] = i0;
  _epaI1[fIdx] = b1;
  _epaI2[fIdx] = b2;
  final fo = fIdx * 3;
  _epaFn[fo] = nx;
  _epaFn[fo + 1] = ny;
  _epaFn[fo + 2] = nz;
  _epaFd[fIdx] = dist;
}

void _addHorizonEdgeFlat(int a, int b) {
  for (var i = 0; i < _epaHorizCount; i++) {
    if (_epaHorizA[i] == b && _epaHorizB[i] == a) {
      final last = _epaHorizCount - 1;
      for (var k = i; k < last; k++) {
        _epaHorizA[k] = _epaHorizA[k + 1];
        _epaHorizB[k] = _epaHorizB[k + 1];
      }
      _epaHorizCount = last;
      return;
    }
  }
  final idx = _epaHorizCount;
  _ensureEpaHorizonCapacity(idx + 1);
  _epaHorizCount = idx + 1;
  _epaHorizA[idx] = a;
  _epaHorizB[idx] = b;
}

double _tetraVolumeAbsFlat() {
  final abx = _gjkP[3] - _gjkP[0];
  final aby = _gjkP[4] - _gjkP[1];
  final abz = _gjkP[5] - _gjkP[2];
  final acx = _gjkP[6] - _gjkP[0];
  final acy = _gjkP[7] - _gjkP[1];
  final acz = _gjkP[8] - _gjkP[2];
  final adx = _gjkP[9] - _gjkP[0];
  final ady = _gjkP[10] - _gjkP[1];
  final adz = _gjkP[11] - _gjkP[2];
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
  for (var d = 0; d < _epaSeedDirs.length; d++) {
    if (_gjkVertCount >= 4 && _tetraVolumeAbsFlat() > 1e-9) {
      break;
    }
    final probe = _epaSeedDirs[d];
    _supportMinkowskiAt(
      _gjkTempSlot,
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
    final cx = _gjkP[_gjkTempSlot * 3];
    final cy = _gjkP[_gjkTempSlot * 3 + 1];
    final cz = _gjkP[_gjkTempSlot * 3 + 2];
    var dup = false;
    for (var i = 0; i < _gjkVertCount; i++) {
      final eo = i * 3;
      final dx = _gjkP[eo] - cx;
      final dy = _gjkP[eo + 1] - cy;
      final dz = _gjkP[eo + 2] - cz;
      if (dx * dx + dy * dy + dz * dz < 1e-10) {
        dup = true;
        break;
      }
    }
    if (!dup) {
      if (_gjkVertCount < 4) {
        _copyGjkVert(_gjkVertCount, _gjkTempSlot);
        _gjkVertCount++;
      } else {
        _copyGjkVert(3, _gjkTempSlot);
      }
    }
  }

  if (_gjkVertCount < 4 || _tetraVolumeAbsFlat() <= 1e-9) {
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
  final ix = (_gjkP[0] + _gjkP[3] + _gjkP[6] + _gjkP[9]) * 0.25;
  final iy = (_gjkP[1] + _gjkP[4] + _gjkP[7] + _gjkP[10]) * 0.25;
  final iz = (_gjkP[2] + _gjkP[5] + _gjkP[8] + _gjkP[11]) * 0.25;
  _epaFaceCount = 0;
  _appendEpaFace(0, 1, 2, ix, iy, iz);
  _appendEpaFace(0, 2, 3, ix, iy, iz);
  _appendEpaFace(0, 3, 1, ix, iy, iz);
  _appendEpaFace(1, 3, 2, ix, iy, iz);

  if (_epaFaceCount == 0) {
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
    var bestDist = _epaFd[0];
    for (var i = 1; i < _epaFaceCount; i++) {
      final fd = _epaFd[i];
      if (fd < bestDist) {
        bestDist = fd;
        bestIdx = i;
      }
    }
    final bestI0 = _epaI0[bestIdx];
    final bestI1 = _epaI1[bestIdx];
    final bestI2 = _epaI2[bestIdx];
    final bestFo = bestIdx * 3;
    final bestNx = _epaFn[bestFo];
    final bestNy = _epaFn[bestFo + 1];
    final bestNz = _epaFn[bestFo + 2];

    _supportMinkowskiAt(
      _gjkTempSlot,
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
    final sx = _gjkP[_gjkTempSlot * 3];
    final sy = _gjkP[_gjkTempSlot * 3 + 1];
    final sz = _gjkP[_gjkTempSlot * 3 + 2];
    final supportDist = sx * bestNx + sy * bestNy + sz * bestNz;

    if (supportDist - bestDist <= 1e-4 || _gjkVertCount >= _maxEpaVerts) {
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

    final newIdx = _gjkVertCount;
    _copyGjkVert(newIdx, _gjkTempSlot);
    _gjkVertCount = newIdx + 1;

    // Remove all faces visible from `sup.p` (preserving order) and collect
    // horizon edges in the same reverse sweep.
    _epaHorizCount = 0;
    for (var i = _epaFaceCount - 1; i >= 0; i--) {
      final fo = i * 3;
      final fnx = _epaFn[fo];
      final fny = _epaFn[fo + 1];
      final fnz = _epaFn[fo + 2];
      final f0 = _epaI0[i];
      final o0 = f0 * 3;
      final dot =
          fnx * (sx - _gjkP[o0]) +
          fny * (sy - _gjkP[o0 + 1]) +
          fnz * (sz - _gjkP[o0 + 2]);
      if (dot > 1e-7) {
        _epaVisible[i] = 1;
        final f1 = _epaI1[i];
        final f2 = _epaI2[i];
        _addHorizonEdgeFlat(f0, f1);
        _addHorizonEdgeFlat(f1, f2);
        _addHorizonEdgeFlat(f2, f0);
      } else {
        _epaVisible[i] = 0;
      }
    }
    var write = 0;
    for (var i = 0; i < _epaFaceCount; i++) {
      if (_epaVisible[i] == 0) {
        if (write != i) {
          _epaI0[write] = _epaI0[i];
          _epaI1[write] = _epaI1[i];
          _epaI2[write] = _epaI2[i];
          final wo = write * 3;
          final ro = i * 3;
          _epaFn[wo] = _epaFn[ro];
          _epaFn[wo + 1] = _epaFn[ro + 1];
          _epaFn[wo + 2] = _epaFn[ro + 2];
          _epaFd[write] = _epaFd[i];
        }
        write++;
      }
    }
    _epaFaceCount = write;

    if (_epaHorizCount == 0) {
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

    for (var h = 0; h < _epaHorizCount; h++) {
      _appendEpaFace(_epaHorizA[h], _epaHorizB[h], newIdx, ix, iy, iz);
    }

    if (_epaFaceCount == 0) {
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
  var bestDist = _epaFd[0];
  for (var i = 1; i < _epaFaceCount; i++) {
    if (_epaFd[i] < bestDist) {
      bestDist = _epaFd[i];
      bestIdx = i;
    }
  }
  final fo = bestIdx * 3;
  _manifoldFromEpaFaceFlat(
    _epaI0[bestIdx],
    _epaI1[bestIdx],
    _epaI2[bestIdx],
    _epaFn[fo],
    _epaFn[fo + 1],
    _epaFn[fo + 2],
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
  final p0x = _gjkP[o0];
  final p0y = _gjkP[o0 + 1];
  final p0z = _gjkP[o0 + 2];

  // Project origin onto triangle `(v0.p, v1.p, v2.p)` to interpolate exact
  // witness points on A and B via barycentric weights.
  final e0x = _gjkP[o1] - p0x;
  final e0y = _gjkP[o1 + 1] - p0y;
  final e0z = _gjkP[o1 + 2] - p0z;
  final e1x = _gjkP[o2] - p0x;
  final e1y = _gjkP[o2 + 1] - p0y;
  final e1z = _gjkP[o2 + 2] - p0z;
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

  _epaNx = nx;
  _epaNy = ny;
  _epaNz = nz;
  _epaDepth = dist;
  _epaAx = _gjkA[o0] * u + _gjkA[o1] * v + _gjkA[o2] * w;
  _epaAy = _gjkA[o0 + 1] * u + _gjkA[o1 + 1] * v + _gjkA[o2 + 1] * w;
  _epaAz = _gjkA[o0 + 2] * u + _gjkA[o1 + 2] * v + _gjkA[o2 + 2] * w;
  _epaBx = _gjkB[o0] * u + _gjkB[o1] * v + _gjkB[o2] * w;
  _epaBy = _gjkB[o0 + 1] * u + _gjkB[o1 + 1] * v + _gjkB[o2 + 1] * w;
  _epaBz = _gjkB[o0 + 2] * u + _gjkB[o1 + 2] * v + _gjkB[o2 + 2] * w;
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

  const co = _gjkTempSlot * 3;
  for (var i = 0; i < _epaSeedDirs.length; i++) {
    final dir = _epaSeedDirs[i];
    _supportMinkowskiAt(
      _gjkTempSlot,
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
    final d = _gjkP[co] * dir.x + _gjkP[co + 1] * dir.y + _gjkP[co + 2] * dir.z;
    if (d >= 0.0 && d < bestDepth) {
      bestDepth = d;
      bestNx = dir.x;
      bestNy = dir.y;
      bestNz = dir.z;
      bestAx = _gjkA[co];
      bestAy = _gjkA[co + 1];
      bestAz = _gjkA[co + 2];
      bestBx = _gjkB[co];
      bestBy = _gjkB[co + 1];
      bestBz = _gjkB[co + 2];
    }
  }
  if (!bestDepth.isFinite) {
    bestDepth = 0.0;
  }
  _epaNx = bestNx;
  _epaNy = bestNy;
  _epaNz = bestNz;
  _epaDepth = bestDepth;
  _epaAx = bestAx;
  _epaAy = bestAy;
  _epaAz = bestAz;
  _epaBx = bestBx;
  _epaBy = bestBy;
  _epaBz = bestBz;
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
