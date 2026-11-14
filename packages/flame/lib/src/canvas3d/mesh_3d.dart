import 'dart:math' as math;
import 'dart:typed_data';

/// Immutable Struct-of-Arrays 3D triangle mesh for `BatchMeshRenderer3D`.
///
/// Coordinates follow Flame `canvas3d`'s right-handed world convention where
/// `+X` and `+Y` span the ground plane and `+Z` points upward, with
/// counter-clockwise (`CCW`) outward-facing triangle winding.
class Mesh3D({
  required final Float32List positions,
  required final Float32List normals,
  required final Uint16List indices,
  final Float32List? ambientOcclusion,
  final Int32List? vertexColors,
}) {
  this
    : assert(
        positions.length % 3 == 0,
        'positions length must be a multiple of 3',
      ),
      assert(
        normals.length == positions.length,
        'normals length must match positions length',
      ),
      assert(
        indices.length % 3 == 0,
        'indices length must be a multiple of 3',
      ),
      assert(
        ambientOcclusion == null ||
            ambientOcclusion.length == positions.length ~/ 3,
        'ambientOcclusion length must equal vertexCount',
      ),
      assert(
        vertexColors == null || vertexColors.length == positions.length ~/ 3,
        'vertexColors length must equal vertexCount',
      ) {
    final vCount = positions.length ~/ 3;
    if (vCount == 0) {
      minX = 0;
      minY = 0;
      minZ = 0;
      maxX = 0;
      maxY = 0;
      maxZ = 0;
      boundingRadius = 0;
      return;
    }
    var loX = double.infinity;
    var loY = double.infinity;
    var loZ = double.infinity;
    var hiX = double.negativeInfinity;
    var hiY = double.negativeInfinity;
    var hiZ = double.negativeInfinity;
    var maxR2 = 0.0;
    for (var i = 0; i < positions.length; i += 3) {
      final x = positions[i];
      final y = positions[i + 1];
      final z = positions[i + 2];
      if (x < loX) {
        loX = x;
      }
      if (y < loY) {
        loY = y;
      }
      if (z < loZ) {
        loZ = z;
      }
      if (x > hiX) {
        hiX = x;
      }
      if (y > hiY) {
        hiY = y;
      }
      if (z > hiZ) {
        hiZ = z;
      }
      final r2 = x * x + y * y + z * z;
      if (r2 > maxR2) {
        maxR2 = r2;
      }
    }
    minX = loX;
    minY = loY;
    minZ = loZ;
    maxX = hiX;
    maxY = hiY;
    maxZ = hiZ;
    boundingRadius = math.sqrt(maxR2);
  }

  /// Creates a [Mesh3D] and automatically computes area-weighted smooth vertex
  /// normals when [normals] is omitted.
  factory Mesh3D.fromRaw({
    required Float32List positions,
    required Uint16List indices,
    Float32List? normals,
    Float32List? ambientOcclusion,
    Int32List? vertexColors,
  }) {
    return Mesh3D(
      positions: positions,
      normals: normals ?? computeVertexNormals(positions, indices),
      indices: indices,
      ambientOcclusion: ambientOcclusion,
      vertexColors: vertexColors,
    );
  }

  /// Builds an axis-aligned 3D box centered at `(0, 0, centerZ)` with flat
  /// per-face normals (24 vertices, 12 triangles).
  factory Mesh3D.box({
    double sizeX = 1.0,
    double sizeY = 1.0,
    double sizeZ = 1.0,
    double centerZ = 0.0,
    double bottomAo = 0.72,
  }) {
    final hx = sizeX * 0.5;
    final hy = sizeY * 0.5;
    final z0 = centerZ - sizeZ * 0.5;
    final z1 = centerZ + sizeZ * 0.5;

    final pos = Float32List(24 * 3);
    final nrm = Float32List(24 * 3);
    final ao = Float32List(24);
    final idx = Uint16List(12 * 3);

    var vCursor = 0;
    var iCursor = 0;

    void addQuad(
      double x0,
      double y0,
      double za,
      double a0,
      double x1,
      double y1,
      double zb,
      double a1,
      double x2,
      double y2,
      double zc,
      double a2,
      double x3,
      double y3,
      double zd,
      double a3,
      double nx,
      double ny,
      double nz,
    ) {
      final base = vCursor;
      void put(double x, double y, double z, double vAo) {
        final p = vCursor * 3;
        pos[p] = x;
        pos[p + 1] = y;
        pos[p + 2] = z;
        nrm[p] = nx;
        nrm[p + 1] = ny;
        nrm[p + 2] = nz;
        ao[vCursor] = vAo;
        vCursor++;
      }

      put(x0, y0, za, a0);
      put(x1, y1, zb, a1);
      put(x2, y2, zc, a2);
      put(x3, y3, zd, a3);

      idx[iCursor++] = base;
      idx[iCursor++] = base + 1;
      idx[iCursor++] = base + 2;
      idx[iCursor++] = base;
      idx[iCursor++] = base + 2;
      idx[iCursor++] = base + 3;
    }

    // +Z top
    addQuad(
      -hx,
      -hy,
      z1,
      1.0,
      hx,
      -hy,
      z1,
      1.0,
      hx,
      hy,
      z1,
      1.0,
      -hx,
      hy,
      z1,
      1.0,
      0,
      0,
      1,
    );
    // -Z bottom
    addQuad(
      -hx,
      hy,
      z0,
      bottomAo,
      hx,
      hy,
      z0,
      bottomAo,
      hx,
      -hy,
      z0,
      bottomAo,
      -hx,
      -hy,
      z0,
      bottomAo,
      0,
      0,
      -1,
    );
    // +X east
    addQuad(
      hx,
      -hy,
      z0,
      bottomAo,
      hx,
      hy,
      z0,
      bottomAo,
      hx,
      hy,
      z1,
      1.0,
      hx,
      -hy,
      z1,
      1.0,
      1,
      0,
      0,
    );
    // -X west
    addQuad(
      -hx,
      hy,
      z0,
      bottomAo,
      -hx,
      -hy,
      z0,
      bottomAo,
      -hx,
      -hy,
      z1,
      1.0,
      -hx,
      hy,
      z1,
      1.0,
      -1,
      0,
      0,
    );
    // +Y south
    addQuad(
      hx,
      hy,
      z0,
      bottomAo,
      -hx,
      hy,
      z0,
      bottomAo,
      -hx,
      hy,
      z1,
      1.0,
      hx,
      hy,
      z1,
      1.0,
      0,
      1,
      0,
    );
    // -Y north
    addQuad(
      -hx,
      -hy,
      z0,
      bottomAo,
      hx,
      -hy,
      z0,
      bottomAo,
      hx,
      -hy,
      z1,
      1.0,
      -hx,
      -hy,
      z1,
      1.0,
      0,
      -1,
      0,
    );

    return Mesh3D(
      positions: pos,
      normals: nrm,
      indices: idx,
      ambientOcclusion: ao,
    );
  }

  /// Builds a 4-sided 3D pyramid rising from `baseZ` to `baseZ + height` with
  /// crisp faceted normals.
  factory Mesh3D.pyramid({
    double baseX = 1.0,
    double baseY = 1.0,
    double height = 1.0,
    double baseZ = 0.0,
    bool includeBase = true,
    double bottomAo = 0.75,
  }) {
    final hx = baseX * 0.5;
    final hy = baseY * 0.5;
    final topZ = baseZ + height;
    final vCount = includeBase ? 16 : 12;
    final tCount = includeBase ? 6 : 4;
    final pos = Float32List(vCount * 3);
    final nrm = Float32List(vCount * 3);
    final ao = Float32List(vCount);
    final idx = Uint16List(tCount * 3);

    var vCursor = 0;
    var iCursor = 0;

    void addSide(double x0, double y0, double x1, double y1) {
      final base = vCursor;
      final ux = x1 - x0;
      final uy = y1 - y0;
      final vx = -x0;
      final vy = -y0;
      final vz = height;
      var nx = uy * vz;
      var ny = -ux * vz;
      var nz = ux * vy - uy * vx;
      final len = math.sqrt(nx * nx + ny * ny + nz * nz);
      if (len > 1e-7) {
        nx /= len;
        ny /= len;
        nz /= len;
      }
      void put(double x, double y, double z, double vAo) {
        final p = vCursor * 3;
        pos[p] = x;
        pos[p + 1] = y;
        pos[p + 2] = z;
        nrm[p] = nx;
        nrm[p + 1] = ny;
        nrm[p + 2] = nz;
        ao[vCursor] = vAo;
        vCursor++;
      }

      put(x0, y0, baseZ, bottomAo);
      put(x1, y1, baseZ, bottomAo);
      put(0, 0, topZ, 1.0);
      idx[iCursor++] = base;
      idx[iCursor++] = base + 1;
      idx[iCursor++] = base + 2;
    }

    addSide(hx, -hy, hx, hy);
    addSide(hx, hy, -hx, hy);
    addSide(-hx, hy, -hx, -hy);
    addSide(-hx, -hy, hx, -hy);

    if (includeBase) {
      final base = vCursor;
      final corners = [
        (-hx, hy),
        (hx, hy),
        (hx, -hy),
        (-hx, -hy),
      ];
      for (final (cx, cy) in corners) {
        final p = vCursor * 3;
        pos[p] = cx;
        pos[p + 1] = cy;
        pos[p + 2] = baseZ;
        nrm[p] = 0;
        nrm[p + 1] = 0;
        nrm[p + 2] = -1;
        ao[vCursor] = bottomAo;
        vCursor++;
      }
      idx[iCursor++] = base;
      idx[iCursor++] = base + 1;
      idx[iCursor++] = base + 2;
      idx[iCursor++] = base;
      idx[iCursor++] = base + 2;
      idx[iCursor++] = base + 3;
    }

    return Mesh3D(
      positions: pos,
      normals: nrm,
      indices: idx,
      ambientOcclusion: ao,
    );
  }

  /// Builds an 8-faced faceted octahedron crystal centered at
  /// `(0, 0, centerZ)`.
  factory Mesh3D.octahedron({
    double radiusXY = 0.5,
    double halfHeight = 0.75,
    double centerZ = 0.0,
  }) {
    final pos = Float32List(24 * 3);
    final nrm = Float32List(24 * 3);
    final ao = Float32List(24);
    final idx = Uint16List(8 * 3);

    final ring = [
      (radiusXY, 0.0),
      (0.0, radiusXY),
      (-radiusXY, 0.0),
      (0.0, -radiusXY),
    ];

    var vCursor = 0;
    var iCursor = 0;

    void addTri(
      double ax,
      double ay,
      double az,
      double aAo,
      double bx,
      double by,
      double bz,
      double bAo,
      double cx,
      double cy,
      double cz,
      double cAo,
    ) {
      final base = vCursor;
      final ux = bx - ax;
      final uy = by - ay;
      final uz = bz - az;
      final vx = cx - ax;
      final vy = cy - ay;
      final vz = cz - az;
      var nx = uy * vz - uz * vy;
      var ny = uz * vx - ux * vz;
      var nz = ux * vy - uy * vx;
      final len = math.sqrt(nx * nx + ny * ny + nz * nz);
      if (len > 1e-7) {
        nx /= len;
        ny /= len;
        nz /= len;
      }

      void put(double x, double y, double z, double vAo) {
        final p = vCursor * 3;
        pos[p] = x;
        pos[p + 1] = y;
        pos[p + 2] = z;
        nrm[p] = nx;
        nrm[p + 1] = ny;
        nrm[p + 2] = nz;
        ao[vCursor] = vAo;
        vCursor++;
      }

      put(ax, ay, az, aAo);
      put(bx, by, bz, bAo);
      put(cx, cy, cz, cAo);
      idx[iCursor++] = base;
      idx[iCursor++] = base + 1;
      idx[iCursor++] = base + 2;
    }

    for (var k = 0; k < 4; k++) {
      final (x0, y0) = ring[k];
      final (x1, y1) = ring[(k + 1) & 3];
      // Upper facet
      addTri(
        x0,
        y0,
        centerZ,
        0.92,
        x1,
        y1,
        centerZ,
        0.92,
        0.0,
        0.0,
        centerZ + halfHeight,
        1.0,
      );
      // Lower facet
      addTri(
        x1,
        y1,
        centerZ,
        0.90,
        x0,
        y0,
        centerZ,
        0.90,
        0.0,
        0.0,
        centerZ - halfHeight,
        0.78,
      );
    }

    return Mesh3D(
      positions: pos,
      normals: nrm,
      indices: idx,
      ambientOcclusion: ao,
    );
  }

  /// Builds an `N`-sided regular prism (pillar, pedestal, crown cylinder) from
  /// `baseZ` to `baseZ + height`.
  factory Mesh3D.prism({
    int sides = 6,
    double radius = 0.5,
    double? topRadius,
    double height = 1.0,
    double baseZ = 0.0,
    bool smoothSides = false,
    double bottomAo = 0.74,
  }) {
    final n = math.max(3, sides);
    final rTop = topRadius ?? radius;
    final topZ = baseZ + height;
    // Side quads: 4*n verts (2*n tris); caps: 2*(n+1) verts (2*n tris).
    final vCount = 4 * n + 2 * (n + 1);
    final tCount = 4 * n;

    final pos = Float32List(vCount * 3);
    final nrm = Float32List(vCount * 3);
    final ao = Float32List(vCount);
    final idx = Uint16List(tCount * 3);

    var vCursor = 0;
    var iCursor = 0;

    void put(
      double x,
      double y,
      double z,
      double nx,
      double ny,
      double nz,
      double vAo,
    ) {
      final p = vCursor * 3;
      pos[p] = x;
      pos[p + 1] = y;
      pos[p + 2] = z;
      nrm[p] = nx;
      nrm[p + 1] = ny;
      nrm[p + 2] = nz;
      ao[vCursor] = vAo;
      vCursor++;
    }

    final step = (2.0 * math.pi) / n;
    final slopeZ = radius - rTop;

    for (var k = 0; k < n; k++) {
      final a0 = k * step;
      final a1 = (k + 1) * step;
      final c0 = math.cos(a0);
      final s0 = math.sin(a0);
      final c1 = math.cos(a1);
      final s1 = math.sin(a1);

      final base = vCursor;
      if (smoothSides) {
        double nLen(double nx, double ny, double nz) =>
            math.sqrt(nx * nx + ny * ny + nz * nz);
        final l0 = nLen(c0 * height, s0 * height, slopeZ);
        final inv0 = l0 > 1e-7 ? 1.0 / l0 : 1.0;
        final l1 = nLen(c1 * height, s1 * height, slopeZ);
        final inv1 = l1 > 1e-7 ? 1.0 / l1 : 1.0;

        put(
          c0 * radius,
          s0 * radius,
          baseZ,
          c0 * height * inv0,
          s0 * height * inv0,
          slopeZ * inv0,
          bottomAo,
        );
        put(
          c1 * radius,
          s1 * radius,
          baseZ,
          c1 * height * inv1,
          s1 * height * inv1,
          slopeZ * inv1,
          bottomAo,
        );
        put(
          c1 * rTop,
          s1 * rTop,
          topZ,
          c1 * height * inv1,
          s1 * height * inv1,
          slopeZ * inv1,
          1.0,
        );
        put(
          c0 * rTop,
          s0 * rTop,
          topZ,
          c0 * height * inv0,
          s0 * height * inv0,
          slopeZ * inv0,
          1.0,
        );
      } else {
        final am = (k + 0.5) * step;
        var nx = math.cos(am) * height;
        var ny = math.sin(am) * height;
        var nz = slopeZ;
        final len = math.sqrt(nx * nx + ny * ny + nz * nz);
        if (len > 1e-7) {
          nx /= len;
          ny /= len;
          nz /= len;
        }
        put(c0 * radius, s0 * radius, baseZ, nx, ny, nz, bottomAo);
        put(c1 * radius, s1 * radius, baseZ, nx, ny, nz, bottomAo);
        put(c1 * rTop, s1 * rTop, topZ, nx, ny, nz, 1.0);
        put(c0 * rTop, s0 * rTop, topZ, nx, ny, nz, 1.0);
      }
      idx[iCursor++] = base;
      idx[iCursor++] = base + 1;
      idx[iCursor++] = base + 2;
      idx[iCursor++] = base;
      idx[iCursor++] = base + 2;
      idx[iCursor++] = base + 3;
    }

    // Top cap (+Z)
    final topCenter = vCursor;
    put(0, 0, topZ, 0, 0, 1, 1.0);
    for (var k = 0; k < n; k++) {
      final a = k * step;
      put(math.cos(a) * rTop, math.sin(a) * rTop, topZ, 0, 0, 1, 1.0);
    }
    for (var k = 0; k < n; k++) {
      idx[iCursor++] = topCenter;
      idx[iCursor++] = topCenter + 1 + k;
      idx[iCursor++] = topCenter + 1 + ((k + 1) % n);
    }

    // Bottom cap (-Z)
    final botCenter = vCursor;
    put(0, 0, baseZ, 0, 0, -1, bottomAo);
    for (var k = 0; k < n; k++) {
      final a = k * step;
      put(
        math.cos(a) * radius,
        math.sin(a) * radius,
        baseZ,
        0,
        0,
        -1,
        bottomAo,
      );
    }
    for (var k = 0; k < n; k++) {
      idx[iCursor++] = botCenter;
      idx[iCursor++] = botCenter + 1 + ((k + 1) % n);
      idx[iCursor++] = botCenter + 1 + k;
    }

    return Mesh3D(
      positions: pos,
      normals: nrm,
      indices: idx,
      ambientOcclusion: ao,
    );
  }

  /// Computes normalized area-weighted smooth normals for [positions] and
  /// [indices].
  static Float32List computeVertexNormals(
    Float32List positions,
    Uint16List indices,
  ) {
    final out = Float32List(positions.length);
    for (var i = 0; i < indices.length; i += 3) {
      final i0 = indices[i] * 3;
      final i1 = indices[i + 1] * 3;
      final i2 = indices[i + 2] * 3;

      final ux = positions[i1] - positions[i0];
      final uy = positions[i1 + 1] - positions[i0 + 1];
      final uz = positions[i1 + 2] - positions[i0 + 2];

      final vx = positions[i2] - positions[i0];
      final vy = positions[i2 + 1] - positions[i0 + 1];
      final vz = positions[i2 + 2] - positions[i0 + 2];

      final nx = uy * vz - uz * vy;
      final ny = uz * vx - ux * vz;
      final nz = ux * vy - uy * vx;

      out[i0] += nx;
      out[i0 + 1] += ny;
      out[i0 + 2] += nz;

      out[i1] += nx;
      out[i1 + 1] += ny;
      out[i1 + 2] += nz;

      out[i2] += nx;
      out[i2 + 1] += ny;
      out[i2 + 2] += nz;
    }

    for (var i = 0; i < out.length; i += 3) {
      final nx = out[i];
      final ny = out[i + 1];
      final nz = out[i + 2];
      final len = math.sqrt(nx * nx + ny * ny + nz * nz);
      if (len > 1e-7) {
        final inv = 1.0 / len;
        out[i] = nx * inv;
        out[i + 1] = ny * inv;
        out[i + 2] = nz * inv;
      } else {
        out[i + 2] = 1.0;
      }
    }
    return out;
  }

  /// Local AABB minimum X.
  late final double minX;

  /// Local AABB minimum Y.
  late final double minY;

  /// Local AABB minimum Z.
  late final double minZ;

  /// Local AABB maximum X.
  late final double maxX;

  /// Local AABB maximum Y.
  late final double maxY;

  /// Local AABB maximum Z.
  late final double maxZ;

  /// Radius of the origin-centered bounding sphere enclosing all vertices.
  late final double boundingRadius;

  /// Number of vertices in this mesh.
  int get vertexCount => positions.length ~/ 3;

  /// Number of triangles in this mesh.
  int get triangleCount => indices.length ~/ 3;
}
