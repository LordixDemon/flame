part of 'shapes_3d.dart';

/// A 3D convex polyhedron collision shape defined as the convex hull of
/// [vertices] in local space.
///
/// The hull is built once, when the shape is created: its polygonal faces
/// (coplanar triangles merged, see [faceCount]), its exact volume, center of
/// mass and inertia tensor (of a solid of uniform density), and its inradius.
/// Points inside the hull are ignored by every query. Degenerate input (fewer
/// than four points, or all of them on one line or one plane) has no faces:
/// the shape then still collides through its support points, with a single
/// contact point per step, and takes its mass properties from its bounding
/// box.
class ConvexHullShape3D({
  required List<Vector3> vertices,
}) extends Shape3D {
  this : assert(vertices.isNotEmpty, 'vertices must not be empty') {
    _localCenter = Vector3(
      0.5 * (_localAabb.min.x + _localAabb.max.x),
      0.5 * (_localAabb.min.y + _localAabb.max.y),
      0.5 * (_localAabb.min.z + _localAabb.max.z),
    );
    final topology = _HullTopology3D.build(vertices);
    _topology = topology;
    _coords = topology?.coords ?? _packCoords(vertices);
  }

  /// Immutable snapshot of local hull vertices.
  final List<Vector3> vertices = List.unmodifiable([
    for (final v in vertices) v.clone(),
  ]);

  late final Float64List _coords;
  late final _HullTopology3D? _topology;
  final Aabb3 _localAabb = _computeBounds(vertices);
  late final Vector3 _localCenter;

  /// Number of polygonal faces of the hull (`0` for degenerate input).
  int get faceCount => _topology?.faceCount ?? 0;

  @override
  bool get hasSupportFace => faceCount > 0;

  /// Writes the outward unit normal of [face] (in local space) into [out] and
  /// returns it.
  Vector3 faceNormal(int face, [Vector3? out]) {
    final t = _topology;
    if (t == null) {
      throw RangeError('$this has no faces (degenerate vertices)');
    }
    RangeError.checkValueInInterval(face, 0, t.faceCount - 1, 'face');
    final res = out ?? Vector3.zero();
    return res..setValues(
      t.faceNormals[face * 3],
      t.faceNormals[face * 3 + 1],
      t.faceNormals[face * 3 + 2],
    );
  }

  /// Indices into [vertices] of the corners of [face], counter-clockwise
  /// around its outward normal.
  List<int> faceVertexIndices(int face) {
    final t = _topology;
    if (t == null) {
      throw RangeError('$this has no faces (degenerate vertices)');
    }
    RangeError.checkValueInInterval(face, 0, t.faceCount - 1, 'face');
    return List.unmodifiable([
      for (var k = t.faceStart[face]; k < t.faceStart[face + 1]; k++)
        t.sourceIndex[t.faceVerts[k]],
    ]);
  }

  /// Hull vertex coordinates `(x, y, z, ...)` used by the narrowphase.
  @internal
  Float64List get hullCoords => _coords;

  /// First index into [hullFaceVertices] of each face, plus one end entry.
  @internal
  Int32List? get hullFaceStart => _topology?.faceStart;

  /// Corner indices (into [hullCoords] triples) of all faces.
  @internal
  Int32List? get hullFaceVertices => _topology?.faceVerts;

  /// Outward unit face normals `(x, y, z, ...)` in local space.
  @internal
  Float64List? get hullFaceNormals => _topology?.faceNormals;

  static Float64List _packCoords(List<Vector3> verts) {
    final data = Float64List(verts.length * 3);
    for (var i = 0; i < verts.length; i++) {
      final v = verts[i];
      final o = i * 3;
      data[o] = v.x;
      data[o + 1] = v.y;
      data[o + 2] = v.z;
    }
    return data;
  }

  static Aabb3 _computeBounds(List<Vector3> verts) {
    var minX = double.infinity;
    var minY = double.infinity;
    var minZ = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    var maxZ = double.negativeInfinity;
    for (final v in verts) {
      if (v.x < minX) {
        minX = v.x;
      }
      if (v.y < minY) {
        minY = v.y;
      }
      if (v.z < minZ) {
        minZ = v.z;
      }
      if (v.x > maxX) {
        maxX = v.x;
      }
      if (v.y > maxY) {
        maxY = v.y;
      }
      if (v.z > maxZ) {
        maxZ = v.z;
      }
    }
    return Aabb3.minMax(
      Vector3(minX, minY, minZ),
      Vector3(maxX, maxY, maxZ),
    );
  }

  /// Local centroid of this hull's bounding box.
  Vector3 get localCenter => _localCenter;

  /// Local center of mass of the solid hull (the bounding-box center for
  /// degenerate input).
  @override
  Vector3 get localCenterOfMass => _topology?.centerOfMass ?? _localCenter;

  /// Radius of the largest sphere centered on [localCenterOfMass] that fits
  /// inside the hull: the distance from the center of mass to the nearest
  /// face plane.
  @override
  double get inscribedSphereRadius {
    final t = _topology;
    if (t != null) {
      return t.inscribedRadius;
    }
    final hx = 0.5 * (_localAabb.max.x - _localAabb.min.x);
    final hy = 0.5 * (_localAabb.max.y - _localAabb.min.y);
    final hz = 0.5 * (_localAabb.max.z - _localAabb.min.z);
    return math.max(1e-3, math.min(hx, math.min(hy, hz)));
  }

  /// Exact volume of the hull (half the bounding box for degenerate input).
  @override
  double estimateLocalVolume() {
    final t = _topology;
    if (t != null) {
      return t.volume;
    }
    final wx = math.max(1e-4, _localAabb.max.x - _localAabb.min.x);
    final wy = math.max(1e-4, _localAabb.max.y - _localAabb.min.y);
    final wz = math.max(1e-4, _localAabb.max.z - _localAabb.min.z);
    return 0.5 * wx * wy * wz;
  }

  @override
  Aabb3 computeLocalAabb({Aabb3? out}) {
    final box = out ?? Aabb3();
    box.min.setFrom(_localAabb.min);
    box.max.setFrom(_localAabb.max);
    return box;
  }

  @override
  void computeWorldAabb(Matrix4 worldTransform, Aabb3 out) {
    final m = worldTransform.storage;
    var minX = double.infinity;
    var minY = double.infinity;
    var minZ = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    var maxZ = double.negativeInfinity;
    final coords = _coords;
    for (var i = 0; i < coords.length; i += 3) {
      final lx = coords[i];
      final ly = coords[i + 1];
      final lz = coords[i + 2];
      final wx = m[0] * lx + m[4] * ly + m[8] * lz + m[12];
      final wy = m[1] * lx + m[5] * ly + m[9] * lz + m[13];
      final wz = m[2] * lx + m[6] * ly + m[10] * lz + m[14];
      if (wx < minX) {
        minX = wx;
      }
      if (wy < minY) {
        minY = wy;
      }
      if (wz < minZ) {
        minZ = wz;
      }
      if (wx > maxX) {
        maxX = wx;
      }
      if (wy > maxY) {
        maxY = wy;
      }
      if (wz > maxZ) {
        maxZ = wz;
      }
    }
    out.min.setValues(minX, minY, minZ);
    out.max.setValues(maxX, maxY, maxZ);
  }

  @override
  void supportPoint(Vector3 worldDir, Matrix4 worldTransform, Vector3 out) {
    final m = worldTransform.storage;
    final dx = worldDir.x;
    final dy = worldDir.y;
    final dz = worldDir.z;
    final lxDir = m[0] * dx + m[1] * dy + m[2] * dz;
    final lyDir = m[4] * dx + m[5] * dy + m[6] * dz;
    final lzDir = m[8] * dx + m[9] * dy + m[10] * dz;

    final coords = _coords;
    var bestIdx = 0;
    var bestDot = coords[0] * lxDir + coords[1] * lyDir + coords[2] * lzDir;
    for (var i = 3; i < coords.length; i += 3) {
      final d =
          coords[i] * lxDir + coords[i + 1] * lyDir + coords[i + 2] * lzDir;
      if (d > bestDot) {
        bestDot = d;
        bestIdx = i;
      }
    }
    final lx = coords[bestIdx];
    final ly = coords[bestIdx + 1];
    final lz = coords[bestIdx + 2];
    out.setValues(
      m[0] * lx + m[4] * ly + m[8] * lz + m[12],
      m[1] * lx + m[5] * ly + m[9] * lz + m[13],
      m[2] * lx + m[6] * ly + m[10] * lz + m[14],
    );
  }

  void _localSupport(double dx, double dy, double dz, Vector3 out) {
    final coords = _coords;
    var bestIdx = 0;
    var bestDot = coords[0] * dx + coords[1] * dy + coords[2] * dz;
    for (var i = 3; i < coords.length; i += 3) {
      final d = coords[i] * dx + coords[i + 1] * dy + coords[i + 2] * dz;
      if (d > bestDot) {
        bestDot = d;
        bestIdx = i;
      }
    }
    out.setValues(coords[bestIdx], coords[bestIdx + 1], coords[bestIdx + 2]);
  }

  @override
  (double distance, Vector3 normal)? raycast(
    Ray worldRay,
    Matrix4 worldTransform, {
    double maxDistance = double.infinity,
  }) {
    if (!_prepareLocalRay(worldRay, worldTransform, maxDistance)) {
      return null;
    }
    final ox = Shape3D._rayScratch.localOrigin.x;
    final oy = Shape3D._rayScratch.localOrigin.y;
    final oz = Shape3D._rayScratch.localOrigin.z;
    final rx = Shape3D._rayScratch.localDir.x;
    final ry = Shape3D._rayScratch.localDir.y;
    final rz = Shape3D._rayScratch.localDir.z;

    final topology = _topology;
    if (topology != null) {
      final normals = topology.faceNormals;
      final offsets = topology.faceOffsets;
      final faceCount = topology.faceCount;
      var tMin = 0.0;
      var tMax = maxDistance;
      var hitFace = -1;
      for (var f = 0; f < faceCount; f++) {
        final f3 = f * 3;
        final fnx = normals[f3];
        final fny = normals[f3 + 1];
        final fnz = normals[f3 + 2];
        final num = offsets[f] - (fnx * ox + fny * oy + fnz * oz);
        final denom = fnx * rx + fny * ry + fnz * rz;
        if (denom.abs() <= 1e-12) {
          if (num < -1e-9) {
            return null;
          }
          continue;
        }
        final t = num / denom;
        if (denom < 0.0) {
          if (t > tMin) {
            tMin = t;
            hitFace = f;
          }
        } else if (t < tMax) {
          tMax = t;
        }
        if (tMin > tMax + 1e-9) {
          return null;
        }
      }
      if (tMin > maxDistance) {
        return null;
      }
      if (hitFace < 0) {
        final unitDir = Shape3D._rayScratch.unitWorldDir;
        return (0.0, Vector3(-unitDir.x, -unitDir.y, -unitDir.z));
      }
      final h3 = hitFace * 3;
      return (
        tMin,
        _transformLocalNormalToWorld(
          normals[h3],
          normals[h3 + 1],
          normals[h3 + 2],
        ),
      );
    }

    // GJK conservative advancement fallback for degenerate hulls without faces.
    var lambda = 0.0;
    var xx = ox;
    var xy = oy;
    var xz = oz;

    var nx = 0.0;
    var ny = 0.0;
    var nz = 0.0;
    var hasNormal = false;

    var simplexCount = 0;
    for (var iter = 0; iter < 48; iter++) {
      if (simplexCount == 0) {
        _localSupport(
          xx - _localCenter.x,
          xy - _localCenter.y,
          xz - _localCenter.z,
          _supScratch,
        );
        _sx[0] = _supScratch.x;
        _sy[0] = _supScratch.y;
        _sz[0] = _supScratch.z;
        simplexCount = 1;
      }

      simplexCount = _closestPointOnSimplexToPoint(
        xx,
        xy,
        xz,
        simplexCount,
        _closestScratch,
      );
      final vx = xx - _closestScratch.x;
      final vy = xy - _closestScratch.y;
      final vz = xz - _closestScratch.z;
      final vLen2 = vx * vx + vy * vy + vz * vz;

      if (vLen2 <= 1e-12) {
        if (!hasNormal) {
          return (
            lambda,
            Vector3(
              -Shape3D._rayScratch.unitWorldDir.x,
              -Shape3D._rayScratch.unitWorldDir.y,
              -Shape3D._rayScratch.unitWorldDir.z,
            ),
          );
        }
        return (lambda, _transformLocalNormalToWorld(nx, ny, nz));
      }

      _localSupport(vx, vy, vz, _supScratch);
      final wx = _supScratch.x;
      final wy = _supScratch.y;
      final wz = _supScratch.z;

      final vp = vx * (xx - wx) + vy * (xy - wy) + vz * (xz - wz);
      final vr = vx * rx + vy * ry + vz * rz;

      if (vp > 0.0) {
        if (vr >= -1e-12) {
          return null;
        }
        final deltaLambda = vp / (-vr);
        lambda += deltaLambda;
        if (lambda > maxDistance) {
          return null;
        }
        xx = ox + lambda * rx;
        xy = oy + lambda * ry;
        xz = oz + lambda * rz;
        nx = vx;
        ny = vy;
        nz = vz;
        hasNormal = true;
        _sx[0] = wx;
        _sy[0] = wy;
        _sz[0] = wz;
        simplexCount = 1;
        continue;
      }

      // Check duplicate support vertex to avoid cycling.
      var duplicate = false;
      for (var i = 0; i < simplexCount; i++) {
        final ex = _sx[i] - wx;
        final ey = _sy[i] - wy;
        final ez = _sz[i] - wz;
        if (ex * ex + ey * ey + ez * ez <= 1e-12) {
          duplicate = true;
          break;
        }
      }
      if (duplicate) {
        if (vp > 1e-8) {
          return null;
        }
        if (!hasNormal) {
          return (lambda, _transformLocalNormalToWorld(vx, vy, vz));
        }
        return (lambda, _transformLocalNormalToWorld(nx, ny, nz));
      }

      if (simplexCount < 4) {
        _sx[simplexCount] = wx;
        _sy[simplexCount] = wy;
        _sz[simplexCount] = wz;
        simplexCount++;
      } else {
        _sx[3] = wx;
        _sy[3] = wy;
        _sz[3] = wz;
      }
    }
    return null;
  }

  /// Diagonal of [computeLocalInertiaTensor] (the tensor of the solid hull
  /// about its center of mass, in the shape's axes).
  @override
  Vector3 computeLocalInertiaDiagonal(double mass, {Vector3? out}) {
    final res = out ?? Vector3.zero();
    if (mass <= 0.0) {
      res.setZero();
      return res;
    }
    final t = _topology;
    if (t != null) {
      final u = t.unitInertia;
      res.setValues(mass * u[0], mass * u[4], mass * u[8]);
      return res;
    }
    final hx = math.max(1e-4, 0.5 * (_localAabb.max.x - _localAabb.min.x));
    final hy = math.max(1e-4, 0.5 * (_localAabb.max.y - _localAabb.min.y));
    final hz = math.max(1e-4, 0.5 * (_localAabb.max.z - _localAabb.min.z));
    final k = mass / 3.0;
    res.setValues(
      k * (hy * hy + hz * hz),
      k * (hx * hx + hz * hz),
      k * (hx * hx + hy * hy),
    );
    return res;
  }

  /// Full inertia tensor of the solid hull of [mass] about its center of
  /// mass, including the products of inertia.
  @override
  Matrix3 computeLocalInertiaTensor(double mass, {Matrix3? out}) {
    final t = _topology;
    if (t == null || mass <= 0.0) {
      return super.computeLocalInertiaTensor(mass, out: out);
    }
    final m = out ?? Matrix3.zero();
    final u = t.unitInertia;
    final st = m.storage;
    for (var i = 0; i < 9; i++) {
      st[i] = mass * u[i];
    }
    return m;
  }

  static final Float64List _sx = Float64List(4);
  static final Float64List _sy = Float64List(4);
  static final Float64List _sz = Float64List(4);
  static final Vector3 _supScratch = Vector3.zero();
  static final Vector3 _closestScratch = Vector3.zero();

  static int _closestPointOnSimplexToPoint(
    double px,
    double py,
    double pz,
    int count,
    Vector3 out,
  ) {
    // Shift simplex by `-p` so we find the closest point to `(0, 0, 0)`.
    if (count == 1) {
      out.setValues(_sx[0], _sy[0], _sz[0]);
      return 1;
    }
    if (count == 2) {
      final ax = _sx[0] - px;
      final ay = _sy[0] - py;
      final az = _sz[0] - pz;
      final bx = _sx[1] - px;
      final by = _sy[1] - py;
      final bz = _sz[1] - pz;
      final abx = bx - ax;
      final aby = by - ay;
      final abz = bz - az;
      final denom = abx * abx + aby * aby + abz * abz;
      if (denom <= 1e-16) {
        out.setValues(_sx[0], _sy[0], _sz[0]);
        return 1;
      }
      final t = -(ax * abx + ay * aby + az * abz) / denom;
      if (t <= 0.0) {
        out.setValues(_sx[0], _sy[0], _sz[0]);
        return 1;
      }
      if (t >= 1.0) {
        _sx[0] = _sx[1];
        _sy[0] = _sy[1];
        _sz[0] = _sz[1];
        out.setValues(_sx[0], _sy[0], _sz[0]);
        return 1;
      }
      out.setValues(
        _sx[0] + t * abx,
        _sy[0] + t * aby,
        _sz[0] + t * abz,
      );
      return 2;
    }
    if (count == 3) {
      return _closestOnTriangleSimplex(px, py, pz, out);
    }
    return _closestOnTetraSimplex(px, py, pz, out);
  }

  static int _closestOnTriangleSimplex(
    double px,
    double py,
    double pz,
    Vector3 out,
  ) {
    final ax = _sx[0] - px;
    final ay = _sy[0] - py;
    final az = _sz[0] - pz;
    final bx = _sx[1] - px;
    final by = _sy[1] - py;
    final bz = _sz[1] - pz;
    final cx = _sx[2] - px;
    final cy = _sy[2] - py;
    final cz = _sz[2] - pz;

    final abx = bx - ax;
    final aby = by - ay;
    final abz = bz - az;
    final acx = cx - ax;
    final acy = cy - ay;
    final acz = cz - az;

    final d1 = -(abx * ax + aby * ay + abz * az);
    final d2 = -(acx * ax + acy * ay + acz * az);
    if (d1 <= 0.0 && d2 <= 0.0) {
      out.setValues(_sx[0], _sy[0], _sz[0]);
      return 1;
    }

    final d3 = -(abx * bx + aby * by + abz * bz);
    final d4 = -(acx * bx + acy * by + acz * bz);
    if (d3 >= 0.0 && d4 <= d3) {
      _sx[0] = _sx[1];
      _sy[0] = _sy[1];
      _sz[0] = _sz[1];
      out.setValues(_sx[0], _sy[0], _sz[0]);
      return 1;
    }

    final vc = d1 * d4 - d3 * d2;
    if (vc <= 0.0 && d1 >= 0.0 && d3 <= 0.0) {
      final v = d1 / (d1 - d3);
      out.setValues(_sx[0] + v * abx, _sy[0] + v * aby, _sz[0] + v * abz);
      return 2;
    }

    final d5 = -(abx * cx + aby * cy + abz * cz);
    final d6 = -(acx * cx + acy * cy + acz * cz);
    if (d6 >= 0.0 && d5 <= d6) {
      _sx[0] = _sx[2];
      _sy[0] = _sy[2];
      _sz[0] = _sz[2];
      out.setValues(_sx[0], _sy[0], _sz[0]);
      return 1;
    }

    final vb = d5 * d2 - d1 * d6;
    if (vb <= 0.0 && d2 >= 0.0 && d6 <= 0.0) {
      final w = d2 / (d2 - d6);
      _sx[1] = _sx[2];
      _sy[1] = _sy[2];
      _sz[1] = _sz[2];
      out.setValues(_sx[0] + w * acx, _sy[0] + w * acy, _sz[0] + w * acz);
      return 2;
    }

    final va = d3 * d6 - d5 * d4;
    if (va <= 0.0 && (d4 - d3) >= 0.0 && (d5 - d6) >= 0.0) {
      final w = (d4 - d3) / ((d4 - d3) + (d5 - d6));
      final bcx = _sx[2] - _sx[1];
      final bcy = _sy[2] - _sy[1];
      final bcz = _sz[2] - _sz[1];
      out.setValues(_sx[1] + w * bcx, _sy[1] + w * bcy, _sz[1] + w * bcz);
      _sx[0] = _sx[1];
      _sy[0] = _sy[1];
      _sz[0] = _sz[1];
      _sx[1] = _sx[2];
      _sy[1] = _sy[2];
      _sz[1] = _sz[2];
      return 2;
    }

    final denom = 1.0 / (va + vb + vc);
    final v = vb * denom;
    final w = vc * denom;
    out.setValues(
      _sx[0] + abx * v + acx * w,
      _sy[0] + aby * v + acy * w,
      _sz[0] + abz * v + acz * w,
    );
    return 3;
  }

  static final Float64List _tetraTx = Float64List(4);
  static final Float64List _tetraTy = Float64List(4);
  static final Float64List _tetraTz = Float64List(4);
  static final Float64List _tetraBestX = Float64List(3);
  static final Float64List _tetraBestY = Float64List(3);
  static final Float64List _tetraBestZ = Float64List(3);

  static int _closestOnTetraSimplex(
    double px,
    double py,
    double pz,
    Vector3 out,
  ) {
    // Test whether `(px, py, pz)` lies strictly inside the tetrahedron; if not,
    // pick the closest of the 4 boundary triangles.
    const faces = [
      (0, 1, 2, 3),
      (0, 2, 3, 1),
      (0, 3, 1, 2),
      (1, 3, 2, 0),
    ];
    final tx = _tetraTx;
    final ty = _tetraTy;
    final tz = _tetraTz;
    for (var k = 0; k < 4; k++) {
      tx[k] = _sx[k];
      ty[k] = _sy[k];
      tz[k] = _sz[k];
    }

    var bestDist2 = double.infinity;
    var bestCount = 4;
    var bestX = px;
    var bestY = py;
    var bestZ = pz;
    final bestVertsX = _tetraBestX;
    final bestVertsY = _tetraBestY;
    final bestVertsZ = _tetraBestZ;
    var outsideAny = false;

    for (final (i0, i1, i2, opp) in faces) {
      final e1x = tx[i1] - tx[i0];
      final e1y = ty[i1] - ty[i0];
      final e1z = tz[i1] - tz[i0];
      final e2x = tx[i2] - tx[i0];
      final e2y = ty[i2] - ty[i0];
      final e2z = tz[i2] - tz[i0];
      final fnx = e1y * e2z - e1z * e2y;
      final fny = e1z * e2x - e1x * e2z;
      final fnz = e1x * e2y - e1y * e2x;

      final signP =
          fnx * (px - tx[i0]) + fny * (py - ty[i0]) + fnz * (pz - tz[i0]);
      final signOpp =
          fnx * (tx[opp] - tx[i0]) +
          fny * (ty[opp] - ty[i0]) +
          fnz * (tz[opp] - tz[i0]);

      if (signP * signOpp <= 0.0) {
        outsideAny = true;
        _sx[0] = tx[i0];
        _sy[0] = ty[i0];
        _sz[0] = tz[i0];
        _sx[1] = tx[i1];
        _sy[1] = ty[i1];
        _sz[1] = tz[i1];
        _sx[2] = tx[i2];
        _sy[2] = ty[i2];
        _sz[2] = tz[i2];
        final cnt = _closestOnTriangleSimplex(px, py, pz, out);
        final dx = out.x - px;
        final dy = out.y - py;
        final dz = out.z - pz;
        final d2 = dx * dx + dy * dy + dz * dz;
        if (d2 < bestDist2) {
          bestDist2 = d2;
          bestCount = cnt;
          bestX = out.x;
          bestY = out.y;
          bestZ = out.z;
          for (var k = 0; k < cnt; k++) {
            bestVertsX[k] = _sx[k];
            bestVertsY[k] = _sy[k];
            bestVertsZ[k] = _sz[k];
          }
        }
      }
    }

    if (!outsideAny) {
      for (var k = 0; k < 4; k++) {
        _sx[k] = tx[k];
        _sy[k] = ty[k];
        _sz[k] = tz[k];
      }
      out.setValues(px, py, pz);
      return 4;
    }

    for (var k = 0; k < bestCount; k++) {
      _sx[k] = bestVertsX[k];
      _sy[k] = bestVertsY[k];
      _sz[k] = bestVertsZ[k];
    }
    out.setValues(bestX, bestY, bestZ);
    return bestCount;
  }
}
