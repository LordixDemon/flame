import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame/src/canvas3d/mesh_bvh_3d.dart';

/// Immutable Struct-of-Arrays 3D triangle mesh for `BatchMeshRenderer3D`.
///
/// Coordinates follow Flame `canvas3d`'s right-handed world convention where
/// `+X` and `+Y` span the ground plane and `+Z` points upward, with
/// counter-clockwise (`CCW`) outward-facing triangle winding.
///
/// [indices] are 16-bit, so one mesh addresses at most [maxVertexCount]
/// vertices. The generators throw an [ArgumentError] rather than wrap when a
/// tessellation would exceed that; build larger geometry with 32-bit indices
/// and split it with [partitionByVertexLimit].
class Mesh3D({
  required final Float32List positions,
  required final Float32List normals,
  required final Uint16List indices,
  final Float32List? ambientOcclusion,
  final Int32List? vertexColors,
  final Float32List? uvs,
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
      ),
      assert(
        uvs == null || uvs.length == (positions.length ~/ 3) * 2,
        'uvs length must equal vertexCount * 2',
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
    Float32List? uvs,
  }) {
    return Mesh3D(
      positions: positions,
      normals: normals ?? computeVertexNormals(positions, indices),
      indices: indices,
      ambientOcclusion: ambientOcclusion,
      vertexColors: vertexColors,
      uvs: uvs,
    );
  }

  /// Builds a horizontal `+Z`-facing quad centered at `(0, 0, z)` with
  /// normalized `[0..1]` UV coordinates (4 vertices, 2 triangles).
  factory Mesh3D.plane({
    double sizeX = 1.0,
    double sizeY = 1.0,
    double z = 0.0,
  }) {
    final hx = sizeX * 0.5;
    final hy = sizeY * 0.5;
    return Mesh3D(
      positions: Float32List.fromList(<double>[
        -hx,
        -hy,
        z,
        hx,
        -hy,
        z,
        hx,
        hy,
        z,
        -hx,
        hy,
        z,
      ]),
      normals: Float32List.fromList(<double>[
        0,
        0,
        1,
        0,
        0,
        1,
        0,
        0,
        1,
        0,
        0,
        1,
      ]),
      uvs: Float32List.fromList(<double>[
        0.0,
        0.0,
        1.0,
        0.0,
        1.0,
        1.0,
        0.0,
        1.0,
      ]),
      indices: Uint16List.fromList(<int>[0, 1, 2, 0, 2, 3]),
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
    final uv = Float32List(24 * 2);
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
      void put(double x, double y, double z, double vAo, double u, double v) {
        final p = vCursor * 3;
        pos[p] = x;
        pos[p + 1] = y;
        pos[p + 2] = z;
        nrm[p] = nx;
        nrm[p + 1] = ny;
        nrm[p + 2] = nz;
        final t = vCursor * 2;
        uv[t] = u;
        uv[t + 1] = v;
        ao[vCursor] = vAo;
        vCursor++;
      }

      put(x0, y0, za, a0, 0.0, 1.0);
      put(x1, y1, zb, a1, 1.0, 1.0);
      put(x2, y2, zc, a2, 1.0, 0.0);
      put(x3, y3, zd, a3, 0.0, 0.0);

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
      uvs: uv,
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
  /// `baseZ` to `baseZ + height`, with faceted sides by default and no UVs.
  ///
  /// Use [Mesh3D.cylinder] for a round, UV-mapped column.
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
    _checkVertexLimit('prism', vCount);
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

  /// Builds a smooth analytic UV sphere centered at `(0, 0, centerZ)` with
  /// [segments] longitudinal slices and [rings] latitudinal bands.
  ///
  /// Its UVs are equirectangular: `u` runs once around (the seam vertices are
  /// duplicated) and `v` from the top pole (`0`) to the bottom pole (`1`).
  factory Mesh3D.uvSphere({
    double radius = 0.5,
    int segments = 16,
    int rings = 12,
    double centerZ = 0.0,
    double bottomAo = 0.76,
  }) {
    final segs = math.max(4, segments);
    final rgs = math.max(3, rings);
    final cols = segs + 1;
    final rows = rgs + 1;
    final vCount = cols * rows;
    _checkVertexLimit('uvSphere', vCount);
    final tCount = segs * rgs * 2;

    final pos = Float32List(vCount * 3);
    final nrm = Float32List(vCount * 3);
    final uv = Float32List(vCount * 2);
    final ao = Float32List(vCount);
    final idx = Uint16List(tCount * 3);

    var v = 0;
    for (var r = 0; r <= rgs; r++) {
      final phi = math.pi * (r / rgs);
      final sinPhi = math.sin(phi);
      final cosPhi = math.cos(phi);
      final aoVal = bottomAo + (1.0 - bottomAo) * (cosPhi * 0.5 + 0.5);
      for (var s = 0; s <= segs; s++) {
        final theta = 2.0 * math.pi * (s / segs);
        final nx = sinPhi * math.cos(theta);
        final ny = sinPhi * math.sin(theta);
        final nz = cosPhi;
        final pIdx = v * 3;
        pos[pIdx] = nx * radius;
        pos[pIdx + 1] = ny * radius;
        pos[pIdx + 2] = centerZ + nz * radius;
        nrm[pIdx] = nx;
        nrm[pIdx + 1] = ny;
        nrm[pIdx + 2] = nz;
        uv[v * 2] = s / segs;
        uv[v * 2 + 1] = r / rgs;
        ao[v] = aoVal;
        v++;
      }
    }

    var k = 0;
    for (var r = 0; r < rgs; r++) {
      for (var s = 0; s < segs; s++) {
        final i00 = r * cols + s;
        final i10 = i00 + 1;
        final i01 = (r + 1) * cols + s;
        final i11 = i01 + 1;
        idx[k++] = i00;
        idx[k++] = i01;
        idx[k++] = i10;
        idx[k++] = i10;
        idx[k++] = i01;
        idx[k++] = i11;
      }
    }

    return Mesh3D(
      positions: pos,
      normals: nrm,
      indices: idx,
      ambientOcclusion: ao,
      uvs: uv,
    );
  }

  /// Builds a capped cylinder around `+Z` from `baseZ` to `baseZ + height`,
  /// or a frustum when [radiusTop] and [radiusBottom] differ. [radiusBottom]
  /// is the radius at `baseZ`; a negative [height] builds downwards from
  /// there.
  ///
  /// The side has smooth normals and UVs that wrap once around (`u`) and run
  /// from the top (`v = 0`) to the bottom (`v = 1`); the caps are flat discs
  /// with their own vertices and disc-shaped UVs. A cap whose radius is `0` is
  /// left out.
  factory Mesh3D.cylinder({
    double radiusTop = 0.5,
    double radiusBottom = 0.5,
    double height = 1.0,
    int segments = 16,
    double baseZ = 0.0,
    bool capTop = true,
    bool capBottom = true,
    double bottomAo = 0.74,
  }) {
    _checkDimension('cylinder', 'radiusTop', radiusTop);
    _checkDimension('cylinder', 'radiusBottom', radiusBottom);
    _checkDimension('cylinder', 'height', height, allowNegative: true);
    if (radiusTop == 0.0 && radiusBottom == 0.0) {
      throw ArgumentError('Mesh3D.cylinder needs a non-zero radius at one end');
    }
    final segs = math.max(3, segments);
    final hasTop = capTop && radiusTop > 0.0;
    final hasBottom = capBottom && radiusBottom > 0.0;
    // Built upright; a negative height is mirrored about `baseZ` at the end.
    final rise = height.abs();
    final vCount =
        2 * (segs + 1) + (hasTop ? segs + 1 : 0) + (hasBottom ? segs + 1 : 0);
    _checkVertexLimit('cylinder', vCount);
    final tCount = 2 * segs + (hasTop ? segs : 0) + (hasBottom ? segs : 0);
    final b = _MeshBuilder(vCount, tCount);
    final topZ = baseZ + rise;
    // The side normal leans by the slope of the wall, the same all around.
    final slopeZ = radiusBottom - radiusTop;
    final slant = math.sqrt(rise * rise + slopeZ * slopeZ);
    final nOut = slant > 1e-7 ? rise / slant : 1.0;
    final nz = slant > 1e-7 ? slopeZ / slant : 0.0;

    for (var s = 0; s <= segs; s++) {
      final a = 2.0 * math.pi * (s / segs);
      final c = math.cos(a);
      final sn = math.sin(a);
      final nx = c * nOut;
      final ny = sn * nOut;
      final u = s / segs;
      b
        ..vertex(c * radiusBottom, sn * radiusBottom, baseZ, nx, ny, nz, u, 1.0)
        ..ao(bottomAo)
        ..vertex(c * radiusTop, sn * radiusTop, topZ, nx, ny, nz, u, 0.0)
        ..ao(1.0);
    }
    for (var s = 0; s < segs; s++) {
      final b0 = 2 * s;
      b
        ..triangle(b0, b0 + 2, b0 + 3)
        ..triangle(b0, b0 + 3, b0 + 1);
    }
    if (hasTop) {
      b.disc(radiusTop, topZ, segs, up: true, aoValue: 1.0);
    }
    if (hasBottom) {
      b.disc(radiusBottom, baseZ, segs, up: false, aoValue: bottomAo);
    }
    if (height < 0.0) {
      b.mirrorZ(baseZ);
    }
    return b.build();
  }

  /// Builds a cone around `+Z` with its base at `baseZ` and its apex at
  /// `baseZ + height` (below the base for a negative [height]).
  ///
  /// The side has smooth normals; the apex is one vertex per segment so that
  /// each carries the normal of its own side strip. UVs wrap once around
  /// (`u`) and run from the apex (`v = 0`) to the base (`v = 1`); the base
  /// cap is a flat disc with disc-shaped UVs.
  factory Mesh3D.cone({
    double radius = 0.5,
    double height = 1.0,
    int segments = 16,
    double baseZ = 0.0,
    bool capBottom = true,
    double bottomAo = 0.74,
  }) {
    _checkDimension('cone', 'radius', radius);
    _checkDimension('cone', 'height', height, allowNegative: true);
    final segs = math.max(3, segments);
    final hasBottom = capBottom && radius > 0.0;
    final vCount = (segs + 1) + segs + (hasBottom ? segs + 1 : 0);
    _checkVertexLimit('cone', vCount);
    final tCount = segs + (hasBottom ? segs : 0);
    final b = _MeshBuilder(vCount, tCount);
    // Built upright; a negative height is mirrored about `baseZ` at the end.
    final rise = height.abs();
    final topZ = baseZ + rise;
    final slant = math.sqrt(rise * rise + radius * radius);
    final nOut = slant > 1e-7 ? rise / slant : 0.0;
    final nz = slant > 1e-7 ? radius / slant : 1.0;

    for (var s = 0; s <= segs; s++) {
      final a = 2.0 * math.pi * (s / segs);
      final c = math.cos(a);
      final sn = math.sin(a);
      b
        ..vertex(
          c * radius,
          sn * radius,
          baseZ,
          c * nOut,
          sn * nOut,
          nz,
          s / segs,
          1.0,
        )
        ..ao(bottomAo);
    }
    final apexBase = segs + 1;
    for (var s = 0; s < segs; s++) {
      final a = 2.0 * math.pi * ((s + 0.5) / segs);
      b
        ..vertex(
          0.0,
          0.0,
          topZ,
          math.cos(a) * nOut,
          math.sin(a) * nOut,
          nz,
          (s + 0.5) / segs,
          0.0,
        )
        ..ao(1.0);
    }
    for (var s = 0; s < segs; s++) {
      b.triangle(s, s + 1, apexBase + s);
    }
    if (hasBottom) {
      b.disc(radius, baseZ, segs, up: false, aoValue: bottomAo);
    }
    if (height < 0.0) {
      b.mirrorZ(baseZ);
    }
    return b.build();
  }

  /// Builds a torus (ring) lying in the ground plane around `+Z`, centred at
  /// `(0, 0, centerZ)`: a tube of radius [minorRadius] swept along a circle of
  /// radius [majorRadius].
  ///
  /// Normals are smooth. UVs run once around the ring (`u`) and once around
  /// the tube (`v`), with the seam vertices duplicated.
  factory Mesh3D.torus({
    double majorRadius = 0.5,
    double minorRadius = 0.15,
    int majorSegments = 24,
    int minorSegments = 12,
    double centerZ = 0.0,
    double bottomAo = 0.76,
  }) {
    _checkDimension('torus', 'majorRadius', majorRadius);
    _checkDimension('torus', 'minorRadius', minorRadius);
    final major = math.max(3, majorSegments);
    final minor = math.max(3, minorSegments);
    final cols = minor + 1;
    final vCount = (major + 1) * cols;
    _checkVertexLimit('torus', vCount);
    final b = _MeshBuilder(vCount, major * minor * 2);

    for (var i = 0; i <= major; i++) {
      final phi = 2.0 * math.pi * (i / major);
      final cPhi = math.cos(phi);
      final sPhi = math.sin(phi);
      for (var j = 0; j <= minor; j++) {
        final theta = 2.0 * math.pi * (j / minor);
        final cTheta = math.cos(theta);
        final sTheta = math.sin(theta);
        final nx = cPhi * cTheta;
        final ny = sPhi * cTheta;
        final nz = sTheta;
        b
          ..vertex(
            cPhi * majorRadius + nx * minorRadius,
            sPhi * majorRadius + ny * minorRadius,
            centerZ + nz * minorRadius,
            nx,
            ny,
            nz,
            i / major,
            j / minor,
          )
          ..ao(bottomAo + (1.0 - bottomAo) * (sTheta * 0.5 + 0.5));
      }
    }
    for (var i = 0; i < major; i++) {
      for (var j = 0; j < minor; j++) {
        final a = i * cols + j;
        final next = (i + 1) * cols + j;
        b
          ..triangle(a, next, a + 1)
          ..triangle(a + 1, next, next + 1);
      }
    }
    return b.build();
  }

  /// Extrudes a flat polygon along `+Z` from `baseZ` to `baseZ + height`
  /// (walls, floor plans, letters, arrows).
  ///
  /// [outline] lists the corners of a simple polygon in the ground plane as
  /// flat `x0, y0, x1, y1, ...` pairs. It may be convex or concave and wound
  /// either way, but must not cross itself or contain holes. A closing point
  /// that repeats the first one is ignored.
  ///
  /// Each wall is a flat quad with its own vertices and normal; its UVs run
  /// along the outline (`u`, proportional to edge length) and from the top
  /// (`v = 0`) to the bottom (`v = 1`). The caps are triangulated by ear
  /// clipping and mapped with the polygon's bounding box as `[0..1]` UVs.
  factory Mesh3D.extrudePolygon({
    required List<double> outline,
    double height = 1.0,
    double baseZ = 0.0,
    bool capTop = true,
    bool capBottom = true,
    double bottomAo = 0.74,
  }) {
    if (outline.length.isOdd) {
      throw ArgumentError.value(
        outline.length,
        'outline',
        'must hold x, y pairs, so an even number of values',
      );
    }
    _checkDimension('extrudePolygon', 'height', height, allowNegative: true);
    for (final value in outline) {
      if (!value.isFinite) {
        throw ArgumentError.value(outline, 'outline', 'must be finite');
      }
    }
    final xs = <double>[];
    final ys = <double>[];
    for (var i = 0; i + 1 < outline.length; i += 2) {
      final x = outline[i];
      final y = outline[i + 1];
      // Skip a point that repeats its predecessor: it adds no edge.
      if (xs.isNotEmpty && xs.last == x && ys.last == y) {
        continue;
      }
      xs.add(x);
      ys.add(y);
    }
    if (xs.length > 1 && xs.first == xs.last && ys.first == ys.last) {
      xs.removeLast();
      ys.removeLast();
    }
    final n = xs.length;
    if (n < 3) {
      throw ArgumentError.value(
        outline,
        'outline',
        'needs at least three distinct corners',
      );
    }

    var area2 = 0.0;
    var perimeter = 0.0;
    var loX = double.infinity;
    var loY = double.infinity;
    var hiX = double.negativeInfinity;
    var hiY = double.negativeInfinity;
    for (var i = 0; i < n; i++) {
      final j = (i + 1) % n;
      area2 += xs[i] * ys[j] - xs[j] * ys[i];
      final ex = xs[j] - xs[i];
      final ey = ys[j] - ys[i];
      perimeter += math.sqrt(ex * ex + ey * ey);
      loX = math.min(loX, xs[i]);
      loY = math.min(loY, ys[i]);
      hiX = math.max(hiX, xs[i]);
      hiY = math.max(hiY, ys[i]);
    }
    final spanX = hiX - loX;
    final spanY = hiY - loY;
    if (area2.abs() <= 1e-12 * math.max(1.0, spanX * spanY)) {
      throw ArgumentError.value(
        outline,
        'outline',
        'encloses no area',
      );
    }
    if (area2 < 0.0) {
      // Clockwise: reverse it so that walls and caps face outwards.
      for (var i = 0, j = n - 1; i < j; i++, j--) {
        final tx = xs[i];
        xs[i] = xs[j];
        xs[j] = tx;
        final ty = ys[i];
        ys[i] = ys[j];
        ys[j] = ty;
      }
    }

    final vCount = 4 * n + (capTop ? n : 0) + (capBottom ? n : 0);
    _checkVertexLimit('extrudePolygon', vCount);
    final capTriangles = _triangulatePolygon(xs, ys);
    final capTriCount = capTriangles.length ~/ 3;
    final b = _MeshBuilder(
      vCount,
      2 * n + (capTop ? capTriCount : 0) + (capBottom ? capTriCount : 0),
    );
    final z0 = math.min(baseZ, baseZ + height);
    final z1 = math.max(baseZ, baseZ + height);

    var travelled = 0.0;
    for (var i = 0; i < n; i++) {
      final j = (i + 1) % n;
      final ex = xs[j] - xs[i];
      final ey = ys[j] - ys[i];
      final len = math.sqrt(ex * ex + ey * ey);
      // A counter-clockwise outline has its outside on the right of travel.
      final nx = ey / len;
      final ny = -ex / len;
      final u0 = travelled / perimeter;
      travelled += len;
      final u1 = travelled / perimeter;
      final base = b.vertexCount;
      b
        ..vertex(xs[i], ys[i], z0, nx, ny, 0.0, u0, 1.0)
        ..ao(bottomAo)
        ..vertex(xs[j], ys[j], z0, nx, ny, 0.0, u1, 1.0)
        ..ao(bottomAo)
        ..vertex(xs[j], ys[j], z1, nx, ny, 0.0, u1, 0.0)
        ..ao(1.0)
        ..vertex(xs[i], ys[i], z1, nx, ny, 0.0, u0, 0.0)
        ..ao(1.0)
        ..triangle(base, base + 1, base + 2)
        ..triangle(base, base + 2, base + 3);
    }

    void cap(double z, {required bool up}) {
      final base = b.vertexCount;
      for (var i = 0; i < n; i++) {
        b
          ..vertex(
            xs[i],
            ys[i],
            z,
            0.0,
            0.0,
            up ? 1.0 : -1.0,
            spanX > 0.0 ? (xs[i] - loX) / spanX : 0.0,
            spanY > 0.0 ? (ys[i] - loY) / spanY : 0.0,
          )
          ..ao(up ? 1.0 : bottomAo);
      }
      for (var t = 0; t < capTriangles.length; t += 3) {
        if (up) {
          b.triangle(
            base + capTriangles[t],
            base + capTriangles[t + 1],
            base + capTriangles[t + 2],
          );
        } else {
          b.triangle(
            base + capTriangles[t],
            base + capTriangles[t + 2],
            base + capTriangles[t + 1],
          );
        }
      }
    }

    if (capTop) {
      cap(z1, up: true);
    }
    if (capBottom) {
      cap(z0, up: false);
    }
    return b.build();
  }

  /// Ear-clips the counter-clockwise simple polygon `(xs, ys)` into
  /// counter-clockwise triangles (flat index triples into the corner lists).
  static List<int> _triangulatePolygon(List<double> xs, List<double> ys) {
    final remaining = List<int>.generate(xs.length, (i) => i);
    final out = <int>[];

    double cross(int a, int b, int c) =>
        (xs[b] - xs[a]) * (ys[c] - ys[a]) - (ys[b] - ys[a]) * (xs[c] - xs[a]);

    while (remaining.length > 3) {
      var clipped = false;
      for (var i = 0; i < remaining.length; i++) {
        final ia = remaining[(i + remaining.length - 1) % remaining.length];
        final ib = remaining[i];
        final ic = remaining[(i + 1) % remaining.length];
        final turn = cross(ia, ib, ic);
        if (turn.abs() <= 1e-12) {
          // A corner on a straight line adds no area: drop it.
          remaining.removeAt(i);
          clipped = true;
          break;
        }
        if (turn < 0.0) {
          continue; // Reflex corner: not an ear.
        }
        var blocked = false;
        for (final ip in remaining) {
          if (ip == ia || ip == ib || ip == ic) {
            continue;
          }
          if (cross(ia, ib, ip) >= 0.0 &&
              cross(ib, ic, ip) >= 0.0 &&
              cross(ic, ia, ip) >= 0.0) {
            blocked = true;
            break;
          }
        }
        if (blocked) {
          continue;
        }
        out
          ..add(ia)
          ..add(ib)
          ..add(ic);
        remaining.removeAt(i);
        clipped = true;
        break;
      }
      if (!clipped) {
        // No ear left: the outline crosses itself. Fan what remains so that
        // the caller still gets a mesh.
        break;
      }
    }
    for (var k = 1; k + 1 < remaining.length; k++) {
      out
        ..add(remaining[0])
        ..add(remaining[k])
        ..add(remaining[k + 1]);
    }
    return out;
  }

  /// Largest number of vertices one [Mesh3D] can address with its 16-bit
  /// [indices].
  static const int maxVertexCount = 65535;

  static void _checkDimension(
    String generator,
    String name,
    double value, {
    bool allowNegative = false,
  }) {
    if (!value.isFinite || (!allowNegative && value < 0.0)) {
      throw ArgumentError.value(
        value,
        name,
        'Mesh3D.$generator needs a finite ${allowNegative ? '' : 'non-negative '}'
        'value',
      );
    }
  }

  static void _checkVertexLimit(String generator, int vertexCount) {
    if (vertexCount > maxVertexCount) {
      throw ArgumentError(
        'Mesh3D.$generator would need $vertexCount vertices, but a Mesh3D '
        'addresses at most $maxVertexCount with its 16-bit indices. Lower '
        'the tessellation, or build the buffers with 32-bit indices and '
        'split them with Mesh3D.partitionByVertexLimit.',
      );
    }
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

  MeshBvh3D? _bvh;

  /// Whether the lazy [bvh] spatial acceleration structure has been built.
  bool get hasBuiltBvh => _bvh != null;

  /// Lazily constructed flat SoA [MeshBvh3D] for `O(log T)` 3D raycasting.
  MeshBvh3D get bvh =>
      _bvh ??= MeshBvh3D.build(positions: positions, indices: indices);

  /// Splits this mesh into sub-meshes of at most [maxVerticesPerPart]
  /// (`<= 65,535`) vertices each while preserving connectivity, normals, UVs,
  /// AO, and vertex colors.
  List<Mesh3D> splitByVertexLimit({int maxVerticesPerPart = 65535}) {
    final idx32 = Uint32List(indices.length);
    for (var i = 0; i < indices.length; i++) {
      idx32[i] = indices[i];
    }
    return partitionByVertexLimit(
      positions: positions,
      normals: normals,
      indices: idx32,
      uvs: uvs,
      ambientOcclusion: ambientOcclusion,
      vertexColors: vertexColors,
      maxVerticesPerPart: maxVerticesPerPart,
    );
  }

  /// Partitions a 32-bit indexed mesh (`> 65,535` vertices) into compact
  /// 16-bit [Mesh3D] sub-meshes of at most [maxVerticesPerPart] (`<= 65,535`)
  /// vertices each, preserving exact triangle connectivity, normals, UVs, AO,
  /// and vertex colors.
  static List<Mesh3D> partitionByVertexLimit({
    required Float32List positions,
    required Float32List normals,
    required Uint32List indices,
    Float32List? uvs,
    Float32List? ambientOcclusion,
    Int32List? vertexColors,
    int maxVerticesPerPart = 65535,
  }) {
    assert(
      maxVerticesPerPart >= 3 && maxVerticesPerPart <= 65535,
      'maxVerticesPerPart must be in [3..65535]',
    );
    final totalVertices = positions.length ~/ 3;
    final totalFaces = indices.length ~/ 3;
    if (totalFaces == 0) {
      return <Mesh3D>[];
    }
    if (totalVertices <= maxVerticesPerPart) {
      final idx16 = Uint16List(indices.length);
      for (var i = 0; i < indices.length; i++) {
        idx16[i] = indices[i];
      }
      return <Mesh3D>[
        Mesh3D(
          positions: positions,
          normals: normals,
          indices: idx16,
          uvs: uvs,
          ambientOcclusion: ambientOcclusion,
          vertexColors: vertexColors,
        ),
      ];
    }

    final remap = Int32List(totalVertices)..fillRange(0, totalVertices, -1);
    final usedGlobals = Int32List(maxVerticesPerPart);
    final partIndices = Uint16List(totalFaces * 3);
    final parts = <Mesh3D>[];

    var localVertCount = 0;
    var localIndexCount = 0;

    void flushPart() {
      if (localIndexCount == 0) {
        return;
      }
      final subPos = Float32List(localVertCount * 3);
      final subNrm = Float32List(localVertCount * 3);
      final subUvs = uvs != null ? Float32List(localVertCount * 2) : null;
      final subAo = ambientOcclusion != null
          ? Float32List(localVertCount)
          : null;
      final subCols = vertexColors != null ? Int32List(localVertCount) : null;

      for (var lv = 0; lv < localVertCount; lv++) {
        final gv = usedGlobals[lv];
        remap[gv] = -1;
        final l3 = lv * 3;
        final g3 = gv * 3;
        subPos[l3] = positions[g3];
        subPos[l3 + 1] = positions[g3 + 1];
        subPos[l3 + 2] = positions[g3 + 2];
        subNrm[l3] = normals[g3];
        subNrm[l3 + 1] = normals[g3 + 1];
        subNrm[l3 + 2] = normals[g3 + 2];
        if (subUvs != null) {
          final l2 = lv * 2;
          final g2 = gv * 2;
          subUvs[l2] = uvs![g2];
          subUvs[l2 + 1] = uvs[g2 + 1];
        }
        if (subAo != null) {
          subAo[lv] = ambientOcclusion![gv];
        }
        if (subCols != null) {
          subCols[lv] = vertexColors![gv];
        }
      }

      final subIdx = Uint16List(localIndexCount)
        ..setRange(0, localIndexCount, partIndices);
      parts.add(
        Mesh3D(
          positions: subPos,
          normals: subNrm,
          indices: subIdx,
          uvs: subUvs,
          ambientOcclusion: subAo,
          vertexColors: subCols,
        ),
      );
      localVertCount = 0;
      localIndexCount = 0;
    }

    for (var f = 0; f < totalFaces; f++) {
      final f3 = f * 3;
      final g0 = indices[f3];
      final g1 = indices[f3 + 1];
      final g2 = indices[f3 + 2];

      var needed = 0;
      if (remap[g0] < 0) {
        needed++;
      }
      if (g1 != g0 && remap[g1] < 0) {
        needed++;
      }
      if (g2 != g0 && g2 != g1 && remap[g2] < 0) {
        needed++;
      }

      if (localVertCount + needed > maxVerticesPerPart) {
        flushPart();
      }

      int mapVertex(int gv) {
        var lv = remap[gv];
        if (lv < 0) {
          lv = localVertCount++;
          remap[gv] = lv;
          usedGlobals[lv] = gv;
        }
        return lv;
      }

      partIndices[localIndexCount++] = mapVertex(g0);
      partIndices[localIndexCount++] = mapVertex(g1);
      partIndices[localIndexCount++] = mapVertex(g2);
    }

    flushPart();
    return parts;
  }
}

/// Fills the Struct-of-Arrays buffers of a generated [Mesh3D].
class _MeshBuilder(int vertexCapacity, int triangleCapacity) {
  final Float32List positions = Float32List(vertexCapacity * 3);
  final Float32List normals = Float32List(vertexCapacity * 3);
  final Float32List uvs = Float32List(vertexCapacity * 2);
  final Float32List aoValues = Float32List(vertexCapacity);
  final Uint16List indices = Uint16List(triangleCapacity * 3);

  /// Number of vertices added so far.
  int vertexCount = 0;
  int _indexCount = 0;

  /// Appends a vertex with full ambient occlusion (`1.0`).
  void vertex(
    double x,
    double y,
    double z,
    double nx,
    double ny,
    double nz,
    double u,
    double v,
  ) {
    final p = vertexCount * 3;
    positions[p] = x;
    positions[p + 1] = y;
    positions[p + 2] = z;
    normals[p] = nx;
    normals[p + 1] = ny;
    normals[p + 2] = nz;
    final t = vertexCount * 2;
    uvs[t] = u;
    uvs[t + 1] = v;
    aoValues[vertexCount] = 1.0;
    vertexCount++;
  }

  /// Sets the ambient occlusion of the vertex added last.
  void ao(double value) {
    aoValues[vertexCount - 1] = value;
  }

  /// Appends the counter-clockwise triangle `(a, b, c)`.
  void triangle(int a, int b, int c) {
    indices[_indexCount++] = a;
    indices[_indexCount++] = b;
    indices[_indexCount++] = c;
  }

  /// Appends a flat disc of [segments] triangles around `(0, 0, z)` facing
  /// `+Z` ([up]) or `-Z`.
  void disc(
    double radius,
    double z,
    int segments, {
    required bool up,
    required double aoValue,
  }) {
    final nz = up ? 1.0 : -1.0;
    final center = vertexCount;
    vertex(0.0, 0.0, z, 0.0, 0.0, nz, 0.5, 0.5);
    ao(aoValue);
    for (var k = 0; k < segments; k++) {
      final a = 2.0 * math.pi * (k / segments);
      final c = math.cos(a);
      final s = math.sin(a);
      vertex(
        c * radius,
        s * radius,
        z,
        0.0,
        0.0,
        nz,
        0.5 + 0.5 * c,
        0.5 + 0.5 * s,
      );
      ao(aoValue);
    }
    for (var k = 0; k < segments; k++) {
      final current = center + 1 + k;
      final next = center + 1 + ((k + 1) % segments);
      if (up) {
        triangle(center, current, next);
      } else {
        triangle(center, next, current);
      }
    }
  }

  /// Mirrors everything built so far in the plane `z = planeZ`, flipping
  /// normals and winding with it so that the surface still faces outwards.
  void mirrorZ(double planeZ) {
    for (var v = 0; v < vertexCount; v++) {
      final p = v * 3 + 2;
      positions[p] = 2.0 * planeZ - positions[p];
      normals[p] = -normals[p];
    }
    for (var i = 0; i + 2 < _indexCount; i += 3) {
      final swap = indices[i + 1];
      indices[i + 1] = indices[i + 2];
      indices[i + 2] = swap;
    }
  }

  Mesh3D build() {
    assert(
      vertexCount * 3 == positions.length && _indexCount == indices.length,
      'generator filled $vertexCount vertices / $_indexCount indices, '
      'expected ${positions.length ~/ 3} / ${indices.length}',
    );
    return Mesh3D(
      positions: positions,
      normals: normals,
      indices: indices,
      ambientOcclusion: aoValues,
      uvs: uvs,
    );
  }
}
