part of 'collision_manifold_3d.dart';

const double _faceContactTolerance = 0.002;
const double _faceAlignmentCos = 0.995;
final _SupportFace3D _faceA = _SupportFace3D();
final _SupportFace3D _faceB = _SupportFace3D();
final _ClipBuffer3D _clip = _ClipBuffer3D();
final _ObbFrame _obbFace = _ObbFrame();
final Int32List _chosen = Int32List(4);
final Vector3 _negDir = Vector3.zero();
final Vector3 _gjkDir = Vector3.zero();
final List<Vector3> _epaSeedDirs = _buildSphereDirs();

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
  final epa = _gjkEpa(
    (dir, out) => shapeA.supportPoint(dir, transformA, out),
    (dir, out) => shapeB.supportPoint(dir, transformB, out),
    centerOfMatrix3D(transformA, _cAScratch),
    centerOfMatrix3D(transformB, _cBScratch),
  );
  if (epa == null) {
    return null;
  }
  final n = epa.normal;
  if (_writeSupportFace(shapeA, transformA, n.x, n.y, n.z, _faceA) &&
      _writeSupportFace(shapeB, transformB, -n.x, -n.y, -n.z, _faceB)) {
    final faced = _clipSupportFaces(n.x, n.y, n.z, _faceA, _faceB);
    if (faced != null) {
      return faced;
    }
  }
  return epa;
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
(bool, double, double, double, int, int, int)? _prepareClippedFaces(
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
      return null;
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
      return null;
    }
  }

  final refD = rnx * rv[0] + rny * rv[1] + rnz * rv[2];
  final kept = clip.keepBelow(rnx, rny, rnz, refD, _faceContactTolerance);
  if (kept == 0) {
    return null;
  }
  final pick = kept <= 4 ? kept : clip.selectFour(rnx, rny, rnz, _chosen);
  final base = _mixId(
    _mixId(refIsA ? 1 : 2, ref.faceId),
    inc.faceId,
  );
  return (refIsA, rnx, rny, rnz, base, pick, kept);
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
}) {
  final prep = _prepareClippedFaces(
    nx,
    ny,
    nz,
    fA,
    fB,
    forceReference: forceReference,
  );
  if (prep == null) {
    return false;
  }
  final (refIsA, rnx, rny, rnz, base, pick, kept) = prep;
  final clip = _clip;
  final mIdx = out.beginManifold(
    refIsA ? rnx : -rnx,
    refIsA ? rny : -rny,
    refIsA ? rnz : -rnz,
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
    final refX = px - rnx * sep;
    final refY = py - rny * sep;
    final refZ = pz - rnz * sep;
    final feat = _mixId(base, clip.keptId(idx));
    if (refIsA) {
      out.addContact(mIdx, refX, refY, refZ, px, py, pz, depth, feat);
    } else {
      out.addContact(mIdx, px, py, pz, refX, refY, refZ, depth, feat);
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
  final prep = _prepareClippedFaces(
    nx,
    ny,
    nz,
    fA,
    fB,
    forceReference: forceReference,
  );
  if (prep == null) {
    return null;
  }
  final (refIsA, rnx, rny, rnz, base, pick, kept) = prep;
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

CollisionManifold3D? _gjkEpa(
  void Function(Vector3 dir, Vector3 out) supportA,
  void Function(Vector3 dir, Vector3 out) supportB,
  Vector3 centerA,
  Vector3 centerB,
) {
  void supportMinkowski(Vector3 dir, _MinkowskiVert out) {
    supportA(dir, out.a);
    _negDir.setValues(-dir.x, -dir.y, -dir.z);
    supportB(_negDir, out.b);
    out.p
      ..setFrom(out.a)
      ..sub(out.b);
  }

  _gjkDir
    ..setFrom(centerB)
    ..sub(centerA);
  if (_gjkDir.length2 < 1e-12) {
    _gjkDir.setValues(1.0, 0.0, 0.0);
  }

  final simplex = <_MinkowskiVert>[];
  final v0 = _MinkowskiVert();
  supportMinkowski(_gjkDir, v0);
  simplex.add(v0);
  _gjkDir
    ..setFrom(v0.p)
    ..negate();

  var hit = false;
  for (var iter = 0; iter < 48; iter++) {
    if (_gjkDir.length2 < 1e-16) {
      hit = true;
      break;
    }
    final next = _MinkowskiVert();
    supportMinkowski(_gjkDir, next);
    if (next.p.dot(_gjkDir) < -1e-9) {
      return null;
    }
    simplex.add(next);
    if (_updateGjkSimplex(simplex, _gjkDir)) {
      hit = true;
      break;
    }
  }
  if (!hit) {
    return null;
  }

  return _epaSolve(simplex, supportMinkowski, centerA, centerB);
}

bool _updateGjkSimplex(List<_MinkowskiVert> s, Vector3 dir) {
  if (s.length == 2) {
    final a = s[1].p;
    final b = s[0].p;
    final ab = b - a;
    final ao = -a;
    if (ab.dot(ao) > 0.0) {
      dir.setFrom(ab.cross(ao).cross(ab));
      if (dir.length2 < 1e-16) {
        _anyPerp(ab, dir);
      }
    } else {
      s.removeAt(0);
      dir.setFrom(ao);
    }
    return false;
  }
  if (s.length == 3) {
    final a = s[2].p;
    final b = s[1].p;
    final c = s[0].p;
    final ab = b - a;
    final ac = c - a;
    final abc = ab.cross(ac);
    final ao = -a;

    if (abc.cross(ac).dot(ao) > 0.0) {
      if (ac.dot(ao) > 0.0) {
        s.removeAt(1);
        dir.setFrom(ac.cross(ao).cross(ac));
      } else if (ab.dot(ao) > 0.0) {
        s.removeAt(0);
        dir.setFrom(ab.cross(ao).cross(ab));
      } else {
        s
          ..removeAt(1)
          ..removeAt(0);
        dir.setFrom(ao);
      }
    } else if (ab.cross(abc).dot(ao) > 0.0) {
      if (ab.dot(ao) > 0.0) {
        s.removeAt(0);
        dir.setFrom(ab.cross(ao).cross(ab));
      } else {
        s
          ..removeAt(1)
          ..removeAt(0);
        dir.setFrom(ao);
      }
    } else {
      if (abc.dot(ao) > 0.0) {
        dir.setFrom(abc);
      } else {
        final tmp = s[0];
        s[0] = s[1];
        s[1] = tmp;
        dir
          ..setFrom(abc)
          ..negate();
      }
    }
    return false;
  }

  // Tetrahedron `s = [d, c, b, a]` where `a = s[3]` was just added.
  final a = s[3].p;
  final b = s[2].p;
  final c = s[1].p;
  final d = s[0].p;
  final ao = -a;
  final ab = b - a;
  final ac = c - a;
  final ad = d - a;

  var abc = ab.cross(ac);
  if (abc.dot(ad) > 0.0) {
    abc = -abc;
  }
  var acd = ac.cross(ad);
  if (acd.dot(ab) > 0.0) {
    acd = -acd;
  }
  var adb = ad.cross(ab);
  if (adb.dot(ac) > 0.0) {
    adb = -adb;
  }

  if (abc.dot(ao) > 1e-12) {
    s.removeAt(0); // Drop d, keep [c, b, a].
    dir.setFrom(abc);
    return false;
  }
  if (acd.dot(ao) > 1e-12) {
    s.removeAt(2); // Drop b, keep [d, c, a].
    dir.setFrom(acd);
    return false;
  }
  if (adb.dot(ao) > 1e-12) {
    s.removeAt(1); // Drop c, keep [d, b, a].
    dir.setFrom(adb);
    return false;
  }
  return true;
}

void _anyPerp(Vector3 v, Vector3 out) {
  if (v.x.abs() < 0.9) {
    out.setValues(0.0, -v.z, v.y);
  } else {
    out.setValues(-v.z, 0.0, v.x);
  }
  if (out.length2 < 1e-18) {
    out.setValues(0.0, 1.0, 0.0);
  }
}

CollisionManifold3D _epaSolve(
  List<_MinkowskiVert> initialSimplex,
  void Function(Vector3 dir, _MinkowskiVert out) supportMinkowski,
  Vector3 centerA,
  Vector3 centerB,
) {
  final verts = List<_MinkowskiVert>.of(initialSimplex);

  // Pad simplex to 4 non-coplanar vertices if GJK terminated early on an
  // edge/triangle containing the origin.
  for (final probe in _epaSeedDirs) {
    if (verts.length >= 4 && _tetraVolumeAbs(verts) > 1e-9) {
      break;
    }
    final cand = _MinkowskiVert();
    supportMinkowski(probe, cand);
    var dup = false;
    for (final existing in verts) {
      if (existing.p.distanceToSquared(cand.p) < 1e-10) {
        dup = true;
        break;
      }
    }
    if (!dup) {
      if (verts.length < 4) {
        verts.add(cand);
      } else {
        verts[3] = cand;
      }
    }
  }

  if (verts.length < 4 || _tetraVolumeAbs(verts) <= 1e-9) {
    return _sampledFallbackManifold(supportMinkowski, centerA, centerB);
  }

  // Orient initial tetrahedron faces outward from its interior centroid.
  final centroid = (verts[0].p + verts[1].p + verts[2].p + verts[3].p)
    ..scale(0.25);
  final faces = <_EpaFace>[];
  for (final (i0, i1, i2) in const [
    (0, 1, 2),
    (0, 2, 3),
    (0, 3, 1),
    (1, 3, 2),
  ]) {
    final f = _makeEpaFace(verts, i0, i1, i2, centroid);
    if (f != null) {
      faces.add(f);
    }
  }

  if (faces.isEmpty) {
    return _sampledFallbackManifold(supportMinkowski, centerA, centerB);
  }

  for (var iter = 0; iter < 48; iter++) {
    var bestIdx = 0;
    for (var i = 1; i < faces.length; i++) {
      if (faces[i].distance < faces[bestIdx].distance) {
        bestIdx = i;
      }
    }
    final best = faces[bestIdx];

    final sup = _MinkowskiVert();
    supportMinkowski(best.normal, sup);
    final supportDist = sup.p.dot(best.normal);

    if (supportDist - best.distance <= 1e-4 || verts.length >= 64) {
      return _manifoldFromEpaFace(best, verts);
    }

    final newIdx = verts.length;
    verts.add(sup);

    // Remove all faces visible from `sup.p` and collect horizon edges.
    final horizon = <(int, int)>[];
    for (var i = faces.length - 1; i >= 0; i--) {
      final f = faces[i];
      if (f.normal.dot(sup.p - verts[f.i0].p) > 1e-7) {
        faces.removeAt(i);
        _addHorizonEdge(horizon, f.i0, f.i1);
        _addHorizonEdge(horizon, f.i1, f.i2);
        _addHorizonEdge(horizon, f.i2, f.i0);
      }
    }

    if (horizon.isEmpty) {
      return _manifoldFromEpaFace(best, verts);
    }

    for (final (e0, e1) in horizon) {
      final nf = _makeEpaFace(verts, e0, e1, newIdx, centroid);
      if (nf != null) {
        faces.add(nf);
      }
    }

    if (faces.isEmpty) {
      return _manifoldFromEpaFace(best, verts);
    }
  }

  var best = faces[0];
  for (var i = 1; i < faces.length; i++) {
    if (faces[i].distance < best.distance) {
      best = faces[i];
    }
  }
  return _manifoldFromEpaFace(best, verts);
}

void _addHorizonEdge(List<(int, int)> horizon, int a, int b) {
  for (var i = 0; i < horizon.length; i++) {
    final (ha, hb) = horizon[i];
    if (ha == b && hb == a) {
      horizon.removeAt(i);
      return;
    }
  }
  horizon.add((a, b));
}

double _tetraVolumeAbs(List<_MinkowskiVert> v) {
  final ab = v[1].p - v[0].p;
  final ac = v[2].p - v[0].p;
  final ad = v[3].p - v[0].p;
  return ab.cross(ac).dot(ad).abs();
}

_EpaFace? _makeEpaFace(
  List<_MinkowskiVert> verts,
  int i0,
  int i1,
  int i2,
  Vector3 interiorPoint,
) {
  final p0 = verts[i0].p;
  final p1 = verts[i1].p;
  final p2 = verts[i2].p;
  final n = (p1 - p0).cross(p2 - p0);
  final len = n.length;
  if (len <= 1e-12) {
    return null;
  }
  n.scale(1.0 / len);
  var b1 = i1;
  var b2 = i2;
  if (n.dot(p0 - interiorPoint) < 0.0) {
    n.negate();
    b1 = i2;
    b2 = i1;
  }
  final dist = math.max(0.0, n.dot(p0));
  return _EpaFace(i0, b1, b2, n, dist);
}

CollisionManifold3D _manifoldFromEpaFace(
  _EpaFace face,
  List<_MinkowskiVert> verts,
) {
  final v0 = verts[face.i0];
  final v1 = verts[face.i1];
  final v2 = verts[face.i2];

  // Project origin onto triangle `(v0.p, v1.p, v2.p)` to interpolate exact
  // witness points on A and B via barycentric weights.
  final proj = face.normal * face.distance;
  final e0 = v1.p - v0.p;
  final e1 = v2.p - v0.p;
  final ep = proj - v0.p;
  final d00 = e0.dot(e0);
  final d01 = e0.dot(e1);
  final d11 = e1.dot(e1);
  final d20 = ep.dot(e0);
  final d21 = ep.dot(e1);
  final denom = d00 * d11 - d01 * d01;
  var u = 1.0 / 3.0;
  var v = 1.0 / 3.0;
  var w = 1.0 / 3.0;
  if (denom.abs() > 1e-14) {
    v = ((d11 * d20 - d01 * d21) / denom).clamp(0.0, 1.0);
    w = ((d00 * d21 - d01 * d20) / denom).clamp(0.0, 1.0 - v);
    u = 1.0 - v - w;
  }

  final ptA = Vector3(
    v0.a.x * u + v1.a.x * v + v2.a.x * w,
    v0.a.y * u + v1.a.y * v + v2.a.y * w,
    v0.a.z * u + v1.a.z * v + v2.a.z * w,
  );
  final ptB = Vector3(
    v0.b.x * u + v1.b.x * v + v2.b.x * w,
    v0.b.y * u + v1.b.y * v + v2.b.y * w,
    v0.b.z * u + v1.b.z * v + v2.b.z * w,
  );
  return CollisionManifold3D(
    normal: face.normal,
    penetrationDepth: face.distance,
    contactPointA: ptA,
    contactPointB: ptB,
  );
}

CollisionManifold3D _sampledFallbackManifold(
  void Function(Vector3 dir, _MinkowskiVert out) supportMinkowski,
  Vector3 centerA,
  Vector3 centerB,
) {
  final cand = _MinkowskiVert();
  var bestDepth = double.infinity;
  final bestN = Vector3(0.0, 1.0, 0.0);
  final bestA = Vector3.copy(centerA);
  final bestB = Vector3.copy(centerB);

  for (final dir in _epaSeedDirs) {
    supportMinkowski(dir, cand);
    final d = cand.p.dot(dir);
    if (d >= 0.0 && d < bestDepth) {
      bestDepth = d;
      bestN.setFrom(dir);
      bestA.setFrom(cand.a);
      bestB.setFrom(cand.b);
    }
  }
  if (!bestDepth.isFinite) {
    bestDepth = 0.0;
  }
  return CollisionManifold3D(
    normal: bestN,
    penetrationDepth: bestDepth,
    contactPointA: bestA,
    contactPointB: bestB,
  );
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

class _MinkowskiVert() {
  final Vector3 p = Vector3.zero();
  final Vector3 a = Vector3.zero();
  final Vector3 b = Vector3.zero();
}

class _EpaFace(this.i0, this.i1, this.i2, this.normal, this.distance) {
  final int i0;
  final int i1;
  final int i2;
  final Vector3 normal;
  final double distance;
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
