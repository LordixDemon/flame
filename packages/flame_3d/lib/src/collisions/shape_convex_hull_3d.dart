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
    // GJK conservative advancement in local space: ray `x(t) = o + t * d`
    // for `t in [0, maxDistance]`.
    var lambda = 0.0;
    var xx = _localOrigin.x;
    var xy = _localOrigin.y;
    var xz = _localOrigin.z;
    final rx = _localDir.x;
    final ry = _localDir.y;
    final rz = _localDir.z;

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
            Vector3(-_unitWorldDir.x, -_unitWorldDir.y, -_unitWorldDir.z),
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
        xx = _localOrigin.x + lambda * rx;
        xy = _localOrigin.y + lambda * ry;
        xz = _localOrigin.z + lambda * rz;
        nx = vx;
        ny = vy;
        nz = vz;
        hasNormal = true;
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
    final tx = Float64List.fromList(_sx);
    final ty = Float64List.fromList(_sy);
    final tz = Float64List.fromList(_sz);

    var bestDist2 = double.infinity;
    var bestCount = 4;
    var bestX = px;
    var bestY = py;
    var bestZ = pz;
    final bestVertsX = Float64List(3);
    final bestVertsY = Float64List(3);
    final bestVertsZ = Float64List(3);
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

/// Polygonal topology and mass properties of a convex hull, built once from a
/// point cloud by an incremental (quickhull-style) construction.
///
/// Faces are convex polygons whose vertices run counter-clockwise around the
/// outward normal; coplanar triangles are merged into one face.
class _HullTopology3D._({
  required final Float64List coords,
  required final Int32List sourceIndex,
  required final Int32List faceStart,
  required final Int32List faceVerts,
  required final Float64List faceNormals,
  required final Float64List faceOffsets,
  required final double volume,
  required final Vector3 centerOfMass,
  required final Float64List unitInertia,
  required final double inscribedRadius,
}) {
  int get faceCount => faceOffsets.length;

  /// Builds the topology of the hull of [input], or returns `null` when the
  /// points are degenerate (fewer than four, collinear or coplanar).
  static _HullTopology3D? build(List<Vector3> input) {
    if (input.length < 4) {
      return null;
    }
    var minX = double.infinity;
    var minY = double.infinity;
    var minZ = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    var maxZ = double.negativeInfinity;
    for (final v in input) {
      minX = math.min(minX, v.x);
      minY = math.min(minY, v.y);
      minZ = math.min(minZ, v.z);
      maxX = math.max(maxX, v.x);
      maxY = math.max(maxY, v.y);
      maxZ = math.max(maxZ, v.z);
    }
    final scale = math.max(maxX - minX, math.max(maxY - minY, maxZ - minZ));
    if (!scale.isFinite || scale <= 0.0) {
      return null;
    }
    // Vertices are stored as 32-bit floats: points closer than this to a plane
    // count as lying on it.
    final tol = scale * 1e-6;
    final tol2 = tol * tol;

    // 1. Unique points.
    final px = <double>[];
    final py = <double>[];
    final pz = <double>[];
    final src = <int>[];
    for (var i = 0; i < input.length; i++) {
      final v = input[i];
      var dup = false;
      for (var k = 0; k < px.length; k++) {
        final dx = px[k] - v.x;
        final dy = py[k] - v.y;
        final dz = pz[k] - v.z;
        if (dx * dx + dy * dy + dz * dz <= tol2) {
          dup = true;
          break;
        }
      }
      if (!dup) {
        px.add(v.x);
        py.add(v.y);
        pz.add(v.z);
        src.add(i);
      }
    }
    final n = px.length;
    if (n < 4) {
      return null;
    }

    // 2. Initial tetrahedron from extreme points.
    final ex = maxX - minX;
    final ey = maxY - minY;
    final ez = maxZ - minZ;
    final axisVals = ex >= ey && ex >= ez ? px : (ey >= ez ? py : pz);
    var i0 = 0;
    var i1 = 0;
    for (var i = 1; i < n; i++) {
      if (axisVals[i] < axisVals[i0]) {
        i0 = i;
      }
      if (axisVals[i] > axisVals[i1]) {
        i1 = i;
      }
    }
    if (i0 == i1) {
      return null;
    }
    final lx = px[i1] - px[i0];
    final ly = py[i1] - py[i0];
    final lz = pz[i1] - pz[i0];
    final lLen2 = lx * lx + ly * ly + lz * lz;
    var i2 = -1;
    var bestLine = tol2;
    for (var i = 0; i < n; i++) {
      final wx = px[i] - px[i0];
      final wy = py[i] - py[i0];
      final wz = pz[i] - pz[i0];
      final cx = wy * lz - wz * ly;
      final cy = wz * lx - wx * lz;
      final cz = wx * ly - wy * lx;
      final d2 = (cx * cx + cy * cy + cz * cz) / lLen2;
      if (d2 > bestLine) {
        bestLine = d2;
        i2 = i;
      }
    }
    if (i2 < 0) {
      return null;
    }
    var pnx = ly * (pz[i2] - pz[i0]) - lz * (py[i2] - py[i0]);
    var pny = lz * (px[i2] - px[i0]) - lx * (pz[i2] - pz[i0]);
    var pnz = lx * (py[i2] - py[i0]) - ly * (px[i2] - px[i0]);
    final pnLen = math.sqrt(pnx * pnx + pny * pny + pnz * pnz);
    pnx /= pnLen;
    pny /= pnLen;
    pnz /= pnLen;
    var i3 = -1;
    var bestPlane = tol;
    for (var i = 0; i < n; i++) {
      final d =
          ((px[i] - px[i0]) * pnx +
                  (py[i] - py[i0]) * pny +
                  (pz[i] - pz[i0]) * pnz)
              .abs();
      if (d > bestPlane) {
        bestPlane = d;
        i3 = i;
      }
    }
    if (i3 < 0) {
      return null;
    }

    // Face storage (triangles) and directed-edge adjacency.
    final fa = <int>[];
    final fb = <int>[];
    final fc = <int>[];
    final fnx = <double>[];
    final fny = <double>[];
    final fnz = <double>[];
    final fd = <double>[];
    final alive = <bool>[];
    final outside = <List<int>?>[];
    final mark = <int>[];
    final edgeFace = <int, int>{};

    double dist(int f, int p) =>
        fnx[f] * px[p] + fny[f] * py[p] + fnz[f] * pz[p] - fd[f];

    int addFace(int a, int b, int c) {
      final abx = px[b] - px[a];
      final aby = py[b] - py[a];
      final abz = pz[b] - pz[a];
      final acx = px[c] - px[a];
      final acy = py[c] - py[a];
      final acz = pz[c] - pz[a];
      var nx = aby * acz - abz * acy;
      var ny = abz * acx - abx * acz;
      var nz = abx * acy - aby * acx;
      final len = math.sqrt(nx * nx + ny * ny + nz * nz);
      if (len > 0.0) {
        nx /= len;
        ny /= len;
        nz /= len;
      }
      final idx = fa.length;
      fa.add(a);
      fb.add(b);
      fc.add(c);
      fnx.add(nx);
      fny.add(ny);
      fnz.add(nz);
      fd.add(nx * px[a] + ny * py[a] + nz * pz[a]);
      alive.add(true);
      outside.add(null);
      mark.add(0);
      edgeFace[a * n + b] = idx;
      edgeFace[b * n + c] = idx;
      edgeFace[c * n + a] = idx;
      return idx;
    }

    void addOriented(int a, int b, int c, int opposite) {
      final abx = px[b] - px[a];
      final aby = py[b] - py[a];
      final abz = pz[b] - pz[a];
      final acx = px[c] - px[a];
      final acy = py[c] - py[a];
      final acz = pz[c] - pz[a];
      final nx = aby * acz - abz * acy;
      final ny = abz * acx - abx * acz;
      final nz = abx * acy - aby * acx;
      final side =
          nx * (px[opposite] - px[a]) +
          ny * (py[opposite] - py[a]) +
          nz * (pz[opposite] - pz[a]);
      if (side > 0.0) {
        addFace(a, c, b);
      } else {
        addFace(a, b, c);
      }
    }

    addOriented(i0, i1, i2, i3);
    addOriented(i0, i1, i3, i2);
    addOriented(i0, i2, i3, i1);
    addOriented(i1, i2, i3, i0);

    bool assign(int p, int firstFace) {
      var best = -1;
      var bestD = tol;
      for (var f = firstFace; f < fa.length; f++) {
        if (!alive[f]) {
          continue;
        }
        final d = dist(f, p);
        if (d > bestD) {
          bestD = d;
          best = f;
        }
      }
      if (best < 0) {
        return false;
      }
      (outside[best] ??= <int>[]).add(p);
      return true;
    }

    for (var p = 0; p < n; p++) {
      if (p != i0 && p != i1 && p != i2 && p != i3) {
        assign(p, 0);
      }
    }

    // 3. Incremental expansion, farthest point first.
    var stamp = 0;
    var guard = 0;
    final visible = <int>[];
    final stack = <int>[];
    final horizonU = <int>[];
    final horizonV = <int>[];
    final orphans = <int>[];
    while (true) {
      var f0 = -1;
      for (var f = 0; f < fa.length; f++) {
        if (alive[f] && (outside[f]?.isNotEmpty ?? false)) {
          f0 = f;
          break;
        }
      }
      if (f0 < 0) {
        break;
      }
      if (++guard > 4 * n + 64) {
        return null;
      }
      final pts = outside[f0]!;
      var p = pts[0];
      var pd = dist(f0, p);
      for (var k = 1; k < pts.length; k++) {
        final d = dist(f0, pts[k]);
        if (d > pd) {
          pd = d;
          p = pts[k];
        }
      }

      stamp++;
      visible
        ..clear()
        ..add(f0);
      stack
        ..clear()
        ..add(f0);
      mark[f0] = stamp;
      horizonU.clear();
      horizonV.clear();
      while (stack.isNotEmpty) {
        final g = stack.removeLast();
        for (var e = 0; e < 3; e++) {
          final u = e == 0 ? fa[g] : (e == 1 ? fb[g] : fc[g]);
          final v = e == 0 ? fb[g] : (e == 1 ? fc[g] : fa[g]);
          final h = edgeFace[v * n + u];
          if (h == null || !alive[h]) {
            return null;
          }
          if (mark[h] == stamp) {
            continue;
          }
          if (dist(h, p) > tol) {
            mark[h] = stamp;
            visible.add(h);
            stack.add(h);
          } else {
            horizonU.add(u);
            horizonV.add(v);
          }
        }
      }

      orphans.clear();
      for (final g in visible) {
        alive[g] = false;
        final o = outside[g];
        if (o != null) {
          orphans.addAll(o);
          outside[g] = null;
        }
        for (var e = 0; e < 3; e++) {
          final u = e == 0 ? fa[g] : (e == 1 ? fb[g] : fc[g]);
          final v = e == 0 ? fb[g] : (e == 1 ? fc[g] : fa[g]);
          if (edgeFace[u * n + v] == g) {
            edgeFace.remove(u * n + v);
          }
        }
      }
      final firstNew = fa.length;
      for (var k = 0; k < horizonU.length; k++) {
        addFace(horizonU[k], horizonV[k], p);
      }
      for (final q in orphans) {
        if (q == p) {
          continue;
        }
        if (!assign(q, firstNew)) {
          // Not above a new face: check the kept faces as well.
          assign(q, 0);
        }
      }
    }

    // 4. Validate closure and merge coplanar triangles into polygons.
    final faceIds = <int>[];
    for (var f = 0; f < fa.length; f++) {
      if (!alive[f]) {
        continue;
      }
      faceIds.add(f);
      for (var e = 0; e < 3; e++) {
        final u = e == 0 ? fa[f] : (e == 1 ? fb[f] : fc[f]);
        final v = e == 0 ? fb[f] : (e == 1 ? fc[f] : fa[f]);
        final h = edgeFace[v * n + u];
        if (h == null || !alive[h]) {
          return null;
        }
      }
      if (fnx[f] == 0.0 && fny[f] == 0.0 && fnz[f] == 0.0) {
        return null;
      }
    }
    final parent = <int, int>{for (final f in faceIds) f: f};
    int find(int f) {
      var r = f;
      while (parent[r] != r) {
        r = parent[r]!;
      }
      var c = f;
      while (parent[c] != r) {
        final next = parent[c]!;
        parent[c] = r;
        c = next;
      }
      return r;
    }

    const coplanarDot = 1.0 - 1e-6;
    for (final f in faceIds) {
      for (var e = 0; e < 3; e++) {
        final u = e == 0 ? fa[f] : (e == 1 ? fb[f] : fc[f]);
        final v = e == 0 ? fb[f] : (e == 1 ? fc[f] : fa[f]);
        final h = edgeFace[v * n + u]!;
        final dot = fnx[f] * fnx[h] + fny[f] * fny[h] + fnz[f] * fnz[h];
        if (dot >= coplanarDot) {
          final rf = find(f);
          final rh = find(h);
          if (rf != rh) {
            if (rf < rh) {
              parent[rh] = rf;
            } else {
              parent[rf] = rh;
            }
          }
        }
      }
    }

    final groupOrder = <int>[];
    final groupSeen = <int>{};
    for (final f in faceIds) {
      final r = find(f);
      if (groupSeen.add(r)) {
        groupOrder.add(r);
      }
    }

    final loops = <List<int>>[];
    final next = <int, int>{};
    for (final root in groupOrder) {
      next.clear();
      var edgeCount = 0;
      var start = -1;
      for (final f in faceIds) {
        if (find(f) != root) {
          continue;
        }
        for (var e = 0; e < 3; e++) {
          final u = e == 0 ? fa[f] : (e == 1 ? fb[f] : fc[f]);
          final v = e == 0 ? fb[f] : (e == 1 ? fc[f] : fa[f]);
          final h = edgeFace[v * n + u]!;
          if (find(h) == root) {
            continue;
          }
          if (next.containsKey(u)) {
            return null;
          }
          next[u] = v;
          edgeCount++;
          if (start < 0 || u < start) {
            start = u;
          }
        }
      }
      final loop = <int>[start];
      var cur = next[start];
      while (cur != null && cur != start && loop.length <= edgeCount) {
        loop.add(cur);
        cur = next[cur];
      }
      if (cur != start || loop.length != edgeCount) {
        return null;
      }
      // Drop vertices lying on the segment between their neighbours.
      var changed = true;
      while (changed && loop.length > 3) {
        changed = false;
        for (var k = 0; k < loop.length; k++) {
          final a = loop[(k + loop.length - 1) % loop.length];
          final b = loop[k];
          final c = loop[(k + 1) % loop.length];
          final acx = px[c] - px[a];
          final acy = py[c] - py[a];
          final acz = pz[c] - pz[a];
          final abx = px[b] - px[a];
          final aby = py[b] - py[a];
          final abz = pz[b] - pz[a];
          final cx = aby * acz - abz * acy;
          final cy = abz * acx - abx * acz;
          final cz = abx * acy - aby * acx;
          final acLen2 = acx * acx + acy * acy + acz * acz;
          if (acLen2 <= 0.0 || (cx * cx + cy * cy + cz * cz) / acLen2 <= tol2) {
            loop.removeAt(k);
            changed = true;
            break;
          }
        }
      }
      if (loop.length < 3) {
        return null;
      }
      loops.add(loop);
    }

    // 5. Compact hull vertices and face arrays.
    final hullIndexOf = <int, int>{};
    final hullPoints = <int>[];
    for (final loop in loops) {
      for (final v in loop) {
        if (!hullIndexOf.containsKey(v)) {
          hullIndexOf[v] = hullPoints.length;
          hullPoints.add(v);
        }
      }
    }
    final coords = Float64List(hullPoints.length * 3);
    final sourceIndex = Int32List(hullPoints.length);
    var ox = 0.0;
    var oy = 0.0;
    var oz = 0.0;
    for (var k = 0; k < hullPoints.length; k++) {
      final v = hullPoints[k];
      coords[k * 3] = px[v];
      coords[k * 3 + 1] = py[v];
      coords[k * 3 + 2] = pz[v];
      sourceIndex[k] = src[v];
      ox += px[v];
      oy += py[v];
      oz += pz[v];
    }
    ox /= hullPoints.length;
    oy /= hullPoints.length;
    oz /= hullPoints.length;

    var totalVerts = 0;
    for (final loop in loops) {
      totalVerts += loop.length;
    }
    final faceStart = Int32List(loops.length + 1);
    final faceVerts = Int32List(totalVerts);
    final faceNormals = Float64List(loops.length * 3);
    final faceOffsets = Float64List(loops.length);
    var cursor = 0;
    for (var f = 0; f < loops.length; f++) {
      final loop = loops[f];
      faceStart[f] = cursor;
      var nx = 0.0;
      var ny = 0.0;
      var nz = 0.0;
      for (var k = 0; k < loop.length; k++) {
        final a = loop[k];
        final b = loop[(k + 1) % loop.length];
        nx += (py[a] - py[b]) * (pz[a] + pz[b]);
        ny += (pz[a] - pz[b]) * (px[a] + px[b]);
        nz += (px[a] - px[b]) * (py[a] + py[b]);
        faceVerts[cursor++] = hullIndexOf[a]!;
      }
      final len = math.sqrt(nx * nx + ny * ny + nz * nz);
      if (!(len > 0.0)) {
        return null;
      }
      nx /= len;
      ny /= len;
      nz /= len;
      var d = double.negativeInfinity;
      for (final a in loop) {
        d = math.max(d, nx * px[a] + ny * py[a] + nz * pz[a]);
      }
      faceNormals[f * 3] = nx;
      faceNormals[f * 3 + 1] = ny;
      faceNormals[f * 3 + 2] = nz;
      faceOffsets[f] = d;
    }
    faceStart[loops.length] = cursor;

    // 6. Volume, center of mass and inertia from the tetrahedra spanned by
    // the reference point (the vertex mean) and each fan triangle.
    var vol = 0.0;
    var mx = 0.0;
    var my = 0.0;
    var mz = 0.0;
    var cxx = 0.0;
    var cyy = 0.0;
    var czz = 0.0;
    var cxy = 0.0;
    var cxz = 0.0;
    var cyz = 0.0;
    for (final loop in loops) {
      final a = loop[0];
      final ax = px[a] - ox;
      final ay = py[a] - oy;
      final az = pz[a] - oz;
      for (var k = 1; k + 1 < loop.length; k++) {
        final b = loop[k];
        final c = loop[k + 1];
        final bx = px[b] - ox;
        final by = py[b] - oy;
        final bz = pz[b] - oz;
        final cx = px[c] - ox;
        final cy = py[c] - oy;
        final cz = pz[c] - oz;
        final v =
            (ax * (by * cz - bz * cy) +
                ay * (bz * cx - bx * cz) +
                az * (bx * cy - by * cx)) /
            6.0;
        vol += v;
        final sx = ax + bx + cx;
        final sy = ay + by + cy;
        final sz = az + bz + cz;
        mx += v * sx * 0.25;
        my += v * sy * 0.25;
        mz += v * sz * 0.25;
        final k20 = v / 20.0;
        cxx += k20 * (ax * ax + bx * bx + cx * cx + sx * sx);
        cyy += k20 * (ay * ay + by * by + cy * cy + sy * sy);
        czz += k20 * (az * az + bz * bz + cz * cz + sz * sz);
        cxy += k20 * (ax * ay + bx * by + cx * cy + sx * sy);
        cxz += k20 * (ax * az + bx * bz + cx * cz + sx * sz);
        cyz += k20 * (ay * az + by * bz + cy * cz + sy * sz);
      }
    }
    if (!(vol > scale * scale * scale * 1e-12)) {
      return null;
    }
    final comX = mx / vol;
    final comY = my / vol;
    final comZ = mz / vol;
    cxx -= vol * comX * comX;
    cyy -= vol * comY * comY;
    czz -= vol * comZ * comZ;
    cxy -= vol * comX * comY;
    cxz -= vol * comX * comZ;
    cyz -= vol * comY * comZ;
    final trace = cxx + cyy + czz;
    final unitInertia = Float64List(9);
    unitInertia[0] = (trace - cxx) / vol;
    unitInertia[4] = (trace - cyy) / vol;
    unitInertia[8] = (trace - czz) / vol;
    unitInertia[1] = unitInertia[3] = -cxy / vol;
    unitInertia[2] = unitInertia[6] = -cxz / vol;
    unitInertia[5] = unitInertia[7] = -cyz / vol;

    final com = Vector3(ox + comX, oy + comY, oz + comZ);
    var inradius = double.infinity;
    for (var f = 0; f < loops.length; f++) {
      final d =
          faceOffsets[f] -
          (faceNormals[f * 3] * com.x +
              faceNormals[f * 3 + 1] * com.y +
              faceNormals[f * 3 + 2] * com.z);
      inradius = math.min(inradius, d);
    }

    return _HullTopology3D._(
      coords: coords,
      sourceIndex: sourceIndex,
      faceStart: faceStart,
      faceVerts: faceVerts,
      faceNormals: faceNormals,
      faceOffsets: faceOffsets,
      volume: vol,
      centerOfMass: com,
      unitInertia: unitInertia,
      inscribedRadius: math.max(inradius, scale * 1e-4),
    );
  }
}
