part of 'shapes_3d.dart';

/// Analytical 3D `columns x rows` grid heightfield collision shape spanning
/// `[-width * 0.5 .. +width * 0.5]` along `X` and
/// `[-depth * 0.5 .. +depth * 0.5]` along `Z`, with `O(1)` grid-cell contact
/// lookup, piecewise-linear [sampleHeight], and 2D grid-DDA [raycast].
class HeightfieldShape3D({
  required Float32List heights,
  required final int columns,
  required final int rows,
  required final double width,
  required final double depth,
  final double heightScale = 1.0,
}) extends Shape3D {
  this
    : assert(columns >= 2 && rows >= 2, 'grid must be at least 2x2'),
      assert(width > 0 && depth > 0, 'width and depth must be positive'),
      assert(
        heights.length == columns * rows,
        'heights length must equal columns * rows',
      ) {
    var minH = double.infinity;
    var maxH = double.negativeInfinity;
    for (var i = 0; i < this.heights.length; i++) {
      final h = this.heights[i] * heightScale;
      if (h < minH) {
        minH = h;
      }
      if (h > maxH) {
        maxH = h;
      }
    }
    _minY = minH.isFinite ? minH : 0.0;
    _maxY = maxH.isFinite ? maxH : 0.0;
  }

  @override
  bool get isConvex => false;

  /// Immutable copy of the `columns * rows` raw height grid.
  final Float32List heights = Float32List.fromList(heights);

  late final double _minY;
  late final double _maxY;

  /// Cell width along `X` (`width / (columns - 1)`).
  double get cellWidth => width / (columns - 1);

  /// Cell depth along `Z` (`depth / (rows - 1)`).
  double get cellDepth => depth / (rows - 1);

  /// Minimum scaled local `Y` elevation across the heightfield.
  double get minHeight => _minY;

  /// Maximum scaled local `Y` elevation across the heightfield.
  double get maxHeight => _maxY;

  @override
  double get inscribedSphereRadius => 0.0;

  @override
  double estimateLocalVolume() =>
      width * depth * math.max(0.1, _maxY - _minY + 0.1);

  /// Returns the scaled elevation at grid vertex `(col, row)`.
  double vertexHeight(int col, int row) {
    final c = col.clamp(0, columns - 1);
    final r = row.clamp(0, rows - 1);
    return heights[r * columns + c] * heightScale;
  }

  /// Samples the exact piecewise-linear two-triangle surface height at local
  /// `(x, z)` coordinates (clamped to the heightfield footprint).
  double sampleHeight(double x, double z) {
    final halfW = width * 0.5;
    final halfD = depth * 0.5;
    final fx = ((x + halfW) / width * (columns - 1)).clamp(0.0, columns - 1.0);
    final fz = ((z + halfD) / depth * (rows - 1)).clamp(0.0, rows - 1.0);
    final c = fx.floor().clamp(0, columns - 2);
    final r = fz.floor().clamp(0, rows - 2);
    final tx = (fx - c).clamp(0.0, 1.0);
    final tz = (fz - r).clamp(0.0, 1.0);

    final h00 = heights[r * columns + c] * heightScale;
    final h10 = heights[r * columns + c + 1] * heightScale;
    final h01 = heights[(r + 1) * columns + c] * heightScale;
    final h11 = heights[(r + 1) * columns + c + 1] * heightScale;

    // Matches `TerrainMesh3D` diagonal `(v00 -> v11)`:
    // Triangle 0 `(v00, v01, v11)` covers `tz >= tx`;
    // Triangle 1 `(v00, v11, v10)` covers `tx > tz`.
    if (tz >= tx) {
      return h00 + tz * (h01 - h00) + tx * (h11 - h01);
    }
    return h00 + tx * (h10 - h00) + tz * (h11 - h10);
  }

  /// Computes the unit upward surface normal of the active triangle at local
  /// `(x, z)`.
  Vector3 sampleNormal(double x, double z, {Vector3? out}) {
    final res = out ?? Vector3.zero();
    final halfW = width * 0.5;
    final halfD = depth * 0.5;
    final fx = ((x + halfW) / width * (columns - 1)).clamp(0.0, columns - 1.0);
    final fz = ((z + halfD) / depth * (rows - 1)).clamp(0.0, rows - 1.0);
    final c = fx.floor().clamp(0, columns - 2);
    final r = fz.floor().clamp(0, rows - 2);
    final tx = fx - c;
    final tz = fz - r;

    writeCellVerticesLocal(c, r, _v00, _v01, _v11, _v10);
    if (tz >= tx) {
      _triangleNormal(_v00, _v01, _v11, res);
    } else {
      _triangleNormal(_v00, _v11, _v10, res);
    }
    return res;
  }

  /// Clamps a local `[minX..maxX, minZ..maxZ]` footprint in `O(1)` to
  /// overlapping grid cell indices `(c0, c1, r0, r1)`, or `null` when
  /// horizontally disjoint.
  (int c0, int c1, int r0, int r1)? cellRangeForLocalBounds(
    double minX,
    double maxX,
    double minZ,
    double maxZ,
  ) {
    final halfW = width * 0.5;
    final halfD = depth * 0.5;
    if (maxX < -halfW || minX > halfW || maxZ < -halfD || minZ > halfD) {
      return null;
    }
    final invCw = (columns - 1) / width;
    final invCd = (rows - 1) / depth;
    final c0 = ((minX + halfW) * invCw).floor().clamp(0, columns - 2);
    final c1 = ((maxX + halfW) * invCw).floor().clamp(0, columns - 2);
    final r0 = ((minZ + halfD) * invCd).floor().clamp(0, rows - 2);
    final r1 = ((maxZ + halfD) * invCd).floor().clamp(0, rows - 2);
    return (c0, c1, r0, r1);
  }

  /// Writes the 4 local-space corner positions `(v00, v01, v11, v10)` of grid
  /// cell `(col, row)`, where Triangle 0 is `(v00, v01, v11)` and Triangle 1 is
  /// `(v00, v11, v10)` (CCW when viewed from `+Y`).
  void writeCellVerticesLocal(
    int col,
    int row,
    Vector3 v00,
    Vector3 v01,
    Vector3 v11,
    Vector3 v10,
  ) {
    final cw = width / (columns - 1);
    final cd = depth / (rows - 1);
    final x0 = -width * 0.5 + col * cw;
    final x1 = x0 + cw;
    final z0 = -depth * 0.5 + row * cd;
    final z1 = z0 + cd;
    final r0 = row * columns;
    final r1 = (row + 1) * columns;
    v00.setValues(x0, heights[r0 + col] * heightScale, z0);
    v10.setValues(x1, heights[r0 + col + 1] * heightScale, z0);
    v01.setValues(x0, heights[r1 + col] * heightScale, z1);
    v11.setValues(x1, heights[r1 + col + 1] * heightScale, z1);
  }

  @override
  Aabb3 computeLocalAabb({Aabb3? out}) {
    final box = out ?? Aabb3();
    final halfW = width * 0.5;
    final halfD = depth * 0.5;
    box.min.setValues(-halfW, _minY, -halfD);
    box.max.setValues(halfW, _maxY, halfD);
    return box;
  }

  @override
  void computeWorldAabb(Matrix4 worldTransform, Aabb3 out) {
    final m = worldTransform.storage;
    final hx = width * 0.5;
    final hz = depth * 0.5;
    final midY = 0.5 * (_minY + _maxY);
    final hy = math.max(1e-4, 0.5 * (_maxY - _minY));

    final cx = m[4] * midY + m[12];
    final cy = m[5] * midY + m[13];
    final cz = m[6] * midY + m[14];

    final ex = m[0].abs() * hx + m[4].abs() * hy + m[8].abs() * hz;
    final ey = m[1].abs() * hx + m[5].abs() * hy + m[9].abs() * hz;
    final ez = m[2].abs() * hx + m[6].abs() * hy + m[10].abs() * hz;
    out.min.setValues(cx - ex, cy - ey, cz - ez);
    out.max.setValues(cx + ex, cy + ey, cz + ez);
  }

  @override
  void supportPoint(Vector3 worldDir, Matrix4 worldTransform, Vector3 out) {
    // Evaluate over the local bounding box corners when queried conservatively.
    final m = worldTransform.storage;
    final dx = worldDir.x;
    final dy = worldDir.y;
    final dz = worldDir.z;
    final halfW = width * 0.5;
    final halfD = depth * 0.5;
    final lx = m[0] * dx + m[1] * dy + m[2] * dz >= 0.0 ? halfW : -halfW;
    final ly = m[4] * dx + m[5] * dy + m[6] * dz >= 0.0 ? _maxY : _minY;
    final lz = m[8] * dx + m[9] * dy + m[10] * dz >= 0.0 ? halfD : -halfD;
    out.setValues(
      m[0] * lx + m[4] * ly + m[8] * lz + m[12],
      m[1] * lx + m[5] * ly + m[9] * lz + m[13],
      m[2] * lx + m[6] * ly + m[10] * lz + m[14],
    );
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
    final dx = Shape3D._rayScratch.localDir.x;
    final dy = Shape3D._rayScratch.localDir.y;
    final dz = Shape3D._rayScratch.localDir.z;

    final halfW = width * 0.5;
    final halfD = depth * 0.5;

    // 1. Clip `[0, maxDistance]` against the local heightfield AABB.
    var tEntry = 0.0;
    var tExit = maxDistance;

    bool clipSlab(double o, double d, double lo, double hi) {
      if (d.abs() < 1e-12) {
        return o >= lo - 1e-5 && o <= hi + 1e-5;
      }
      final inv = 1.0 / d;
      var t1 = (lo - 1e-5 - o) * inv;
      var t2 = (hi + 1e-5 - o) * inv;
      if (t1 > t2) {
        final s = t1;
        t1 = t2;
        t2 = s;
      }
      if (t1 > tEntry) {
        tEntry = t1;
      }
      if (t2 < tExit) {
        tExit = t2;
      }
      return tEntry <= tExit;
    }

    if (!clipSlab(ox, dx, -halfW, halfW) ||
        !clipSlab(oy, dy, _minY - 1e-3, _maxY + 1e-3) ||
        !clipSlab(oz, dz, -halfD, halfD)) {
      return null;
    }

    // 2. 2D Amanatides & Woo Grid-DDA across `(col, row)` cells.
    final cw = width / (columns - 1);
    final cd = depth / (rows - 1);
    final invCw = 1.0 / cw;
    final invCd = 1.0 / cd;

    var tCur = math.max(0.0, tEntry);
    var tStop = tExit;

    final startX = ox + dx * tCur;
    final startZ = oz + dz * tCur;
    var c = ((startX + halfW) * invCw).floor().clamp(0, columns - 2);
    var r = ((startZ + halfD) * invCd).floor().clamp(0, rows - 2);

    final int stepC;
    double tMaxX;
    final double tDeltaX;
    if (dx > 1e-12) {
      stepC = 1;
      final nextX = -halfW + (c + 1) * cw;
      tMaxX = tCur + (nextX - startX) / dx;
      tDeltaX = cw / dx;
    } else if (dx < -1e-12) {
      stepC = -1;
      final nextX = -halfW + c * cw;
      tMaxX = tCur + (nextX - startX) / dx;
      tDeltaX = -cw / dx;
    } else {
      stepC = 0;
      tMaxX = double.infinity;
      tDeltaX = double.infinity;
    }

    final int stepR;
    double tMaxZ;
    final double tDeltaZ;
    if (dz > 1e-12) {
      stepR = 1;
      final nextZ = -halfD + (r + 1) * cd;
      tMaxZ = tCur + (nextZ - startZ) / dz;
      tDeltaZ = cd / dz;
    } else if (dz < -1e-12) {
      stepR = -1;
      final nextZ = -halfD + r * cd;
      tMaxZ = tCur + (nextZ - startZ) / dz;
      tDeltaZ = -cd / dz;
    } else {
      stepR = 0;
      tMaxZ = double.infinity;
      tDeltaZ = double.infinity;
    }

    var bestT = double.infinity;
    var bestNx = 0.0;
    var bestNy = 1.0;
    var bestNz = 0.0;

    while (c >= 0 &&
        c <= columns - 2 &&
        r >= 0 &&
        r <= rows - 2 &&
        tCur <= tStop + 1e-5) {
      final tCellEnd = math.min(tStop, math.min(tMaxX, tMaxZ));
      final ry0 = oy + dy * tCur;
      final ry1 = oy + dy * tCellEnd;
      final segMinY = math.min(ry0, ry1) - 1e-4;
      final segMaxY = math.max(ry0, ry1) + 1e-4;

      writeCellVerticesLocal(c, r, _v00, _v01, _v11, _v10);
      final cellMinY = math.min(
        math.min(_v00.y, _v01.y),
        math.min(_v11.y, _v10.y),
      );
      final cellMaxY = math.max(
        math.max(_v00.y, _v01.y),
        math.max(_v11.y, _v10.y),
      );

      if (segMaxY >= cellMinY && segMinY <= cellMaxY) {
        final t0 = _rayTriangleLocal(ox, oy, oz, dx, dy, dz, _v00, _v01, _v11);
        if (t0 != null && t0 >= 0.0 && t0 < bestT && t0 <= maxDistance) {
          bestT = t0;
          _triangleNormal(_v00, _v01, _v11, _nrmScratch);
          bestNx = _nrmScratch.x;
          bestNy = _nrmScratch.y;
          bestNz = _nrmScratch.z;
          if (bestT < tStop) {
            tStop = bestT;
          }
        }
        final t1 = _rayTriangleLocal(ox, oy, oz, dx, dy, dz, _v00, _v11, _v10);
        if (t1 != null && t1 >= 0.0 && t1 < bestT && t1 <= maxDistance) {
          bestT = t1;
          _triangleNormal(_v00, _v11, _v10, _nrmScratch);
          bestNx = _nrmScratch.x;
          bestNy = _nrmScratch.y;
          bestNz = _nrmScratch.z;
          if (bestT < tStop) {
            tStop = bestT;
          }
        }
        if (bestT <= tCellEnd + 1e-5) {
          break;
        }
      }

      if (tMaxX < tMaxZ) {
        tCur = tMaxX;
        tMaxX += tDeltaX;
        c += stepC;
      } else {
        tCur = tMaxZ;
        tMaxZ += tDeltaZ;
        r += stepR;
      }
    }

    if (!bestT.isFinite) {
      return null;
    }
    return (bestT, _transformLocalNormalToWorld(bestNx, bestNy, bestNz));
  }

  @override
  Vector3 computeLocalInertiaDiagonal(double mass, {Vector3? out}) {
    final res = out ?? Vector3.zero();
    res.setZero();
    return res;
  }

  static double? _rayTriangleLocal(
    double ox,
    double oy,
    double oz,
    double dx,
    double dy,
    double dz,
    Vector3 a,
    Vector3 b,
    Vector3 c,
  ) {
    final e1x = b.x - a.x;
    final e1y = b.y - a.y;
    final e1z = b.z - a.z;
    final e2x = c.x - a.x;
    final e2y = c.y - a.y;
    final e2z = c.z - a.z;

    final px = dy * e2z - dz * e2y;
    final py = dz * e2x - dx * e2z;
    final pz = dx * e2y - dy * e2x;
    final det = e1x * px + e1y * py + e1z * pz;
    if (det.abs() <= 1e-12) {
      return null;
    }
    final invDet = 1.0 / det;

    final tx = ox - a.x;
    final ty = oy - a.y;
    final tz = oz - a.z;
    final u = (tx * px + ty * py + tz * pz) * invDet;
    if (u < -1e-6 || u > 1.0 + 1e-6) {
      return null;
    }

    final qx = ty * e1z - tz * e1y;
    final qy = tz * e1x - tx * e1z;
    final qz = tx * e1y - ty * e1x;
    final v = (dx * qx + dy * qy + dz * qz) * invDet;
    if (v < -1e-6 || u + v > 1.0 + 1e-6) {
      return null;
    }

    final t = (e2x * qx + e2y * qy + e2z * qz) * invDet;
    return t >= 0.0 ? t : null;
  }

  static void _triangleNormal(Vector3 a, Vector3 b, Vector3 c, Vector3 out) {
    final e1x = b.x - a.x;
    final e1y = b.y - a.y;
    final e1z = b.z - a.z;
    final e2x = c.x - a.x;
    final e2y = c.y - a.y;
    final e2z = c.z - a.z;
    final nx = e1y * e2z - e1z * e2y;
    final ny = e1z * e2x - e1x * e2z;
    final nz = e1x * e2y - e1y * e2x;
    final len = math.sqrt(nx * nx + ny * ny + nz * nz);
    if (len > 1e-12) {
      out.setValues(nx / len, ny / len, nz / len);
    } else {
      out.setValues(0.0, 1.0, 0.0);
    }
  }

  static final Vector3 _v00 = Vector3.zero();
  static final Vector3 _v01 = Vector3.zero();
  static final Vector3 _v11 = Vector3.zero();
  static final Vector3 _v10 = Vector3.zero();
  static final Vector3 _nrmScratch = Vector3.zero();
}
