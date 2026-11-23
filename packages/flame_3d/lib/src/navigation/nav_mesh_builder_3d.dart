import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame_3d/core.dart';
import 'package:flame_3d/navigation.dart';
import 'package:flame_3d/resources.dart';

/// Configuration parameters for Recast-style voxel [NavMeshBuilder3D]
/// generation.
class const NavMeshBuildConfig3D({
  final double cellSize = 0.25,
  final double cellHeight = 0.15,
  final double agentHeight = 1.8,
  final double agentRadius = 0.35,
  final double maxClimb = 0.45,
  final double maxSlopeDeg = 45.0,
}) {
  this
    : assert(cellSize > 0, 'cellSize must be positive'),
      assert(cellHeight > 0, 'cellHeight must be positive'),
      assert(agentHeight > 0, 'agentHeight must be positive'),
      assert(agentRadius >= 0, 'agentRadius must be non-negative'),
      assert(maxClimb >= 0, 'maxClimb must be non-negative'),
      assert(
        maxSlopeDeg >= 0 && maxSlopeDeg < 90,
        'maxSlopeDeg must be in [0, 90)',
      );
}

/// Triangle soup input descriptor (`(positions, indices, transform)`) consumed
/// by [NavMeshBuilder3D.fromGeometry].
class NavMeshGeometrySource3D({
  required final Float32List positions,
  required final List<int> indices,
  Matrix4? transform,
}) {
  /// Optional world transform applied to [positions] (`Matrix4.identity()` when
  /// omitted).
  final Matrix4 transform = transform?.clone() ?? Matrix4.identity();

  /// Extracts all surfaces of [mesh] into [NavMeshGeometrySource3D] entries.
  static List<NavMeshGeometrySource3D> fromMesh(
    Mesh mesh, {
    Matrix4? transform,
  }) {
    return [
      for (final surface in mesh.surfaces)
        if (surface.indexCount >= 3)
          NavMeshGeometrySource3D(
            positions: surface.positions,
            indices: surface.indices,
            transform: transform,
          ),
    ];
  }
}

/// Recast-style 3D voxel heightfield navigation mesh generator.
///
/// Voxelizes arbitrary triangle soup geometry into a multi-span solid column
/// heightfield, filters walkable top spans with `agentHeight` vertical
/// headroom, erodes walkable cells within `agentRadius` of walls and impassable
/// ledges (`|dh| > maxClimb`), and emits a portal-connected [NavMesh3D].
///
/// Only these first Recast stages are implemented: there are no regions,
/// contours or polygon simplification, so the output has two triangles per
/// walkable cell (about `2 * area / cellSize²` triangles). The up axis is
/// `+Y`, and a triangle counts as floor only when it is wound
/// counter-clockwise seen from above; clockwise floors are skipped like
/// ceilings.
abstract final class NavMeshBuilder3D._() {
  /// Builds a [NavMesh3D] by voxelizing [sources] with [config].
  static NavMesh3D fromGeometry(
    List<NavMeshGeometrySource3D> sources, {
    NavMeshBuildConfig3D config = const NavMeshBuildConfig3D(),
  }) {
    final emptyUp = Vector3(0.0, 1.0, 0.0);
    if (sources.isEmpty) {
      return NavMesh3D.fromIndexedTriangles(
        vertices: const [],
        triangles: const [],
        upAxis: emptyUp,
      );
    }

    // 1. Transform triangles into world space and compute overall world AABB.
    final worldTris = Float64List(_countTotalTriangles(sources) * 9);
    final triWalkable = Uint8List(worldTris.length ~/ 9);
    final minCosSlope = math.cos(config.maxSlopeDeg * (math.pi / 180.0));

    var minX = double.infinity;
    var minY = double.infinity;
    var minZ = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    var maxZ = double.negativeInfinity;

    var validTriCount = 0;
    for (var s = 0; s < sources.length; s++) {
      final src = sources[s];
      final pos = src.positions;
      final idx = src.indices;
      final m = src.transform.storage;
      final flip = src.transform.determinant() < 0.0;
      final triCount = idx.length ~/ 3;

      for (var t = 0; t < triCount; t++) {
        final b = t * 3;
        final i0 = idx[b] * 3;
        final i1 = (flip ? idx[b + 2] : idx[b + 1]) * 3;
        final i2 = (flip ? idx[b + 1] : idx[b + 2]) * 3;
        if (i0 + 2 >= pos.length ||
            i1 + 2 >= pos.length ||
            i2 + 2 >= pos.length) {
          continue;
        }

        final rx0 = pos[i0];
        final ry0 = pos[i0 + 1];
        final rz0 = pos[i0 + 2];
        final rx1 = pos[i1];
        final ry1 = pos[i1 + 1];
        final rz1 = pos[i1 + 2];
        final rx2 = pos[i2];
        final ry2 = pos[i2 + 1];
        final rz2 = pos[i2 + 2];

        final x0 = m[0] * rx0 + m[4] * ry0 + m[8] * rz0 + m[12];
        final y0 = m[1] * rx0 + m[5] * ry0 + m[9] * rz0 + m[13];
        final z0 = m[2] * rx0 + m[6] * ry0 + m[10] * rz0 + m[14];

        final x1 = m[0] * rx1 + m[4] * ry1 + m[8] * rz1 + m[12];
        final y1 = m[1] * rx1 + m[5] * ry1 + m[9] * rz1 + m[13];
        final z1 = m[2] * rx1 + m[6] * ry1 + m[10] * rz1 + m[14];

        final x2 = m[0] * rx2 + m[4] * ry2 + m[8] * rz2 + m[12];
        final y2 = m[1] * rx2 + m[5] * ry2 + m[9] * rz2 + m[13];
        final z2 = m[2] * rx2 + m[6] * ry2 + m[10] * rz2 + m[14];

        final e1x = x1 - x0;
        final e1y = y1 - y0;
        final e1z = z1 - z0;
        final e2x = x2 - x0;
        final e2y = y2 - y0;
        final e2z = z2 - z0;
        final nx = e1y * e2z - e1z * e2y;
        final ny = e1z * e2x - e1x * e2z;
        final nz = e1x * e2y - e1y * e2x;
        final nLen = math.sqrt(nx * nx + ny * ny + nz * nz);
        if (nLen <= 1e-10) {
          continue;
        }

        final nyUnit = ny / nLen;
        final walkable = nyUnit >= minCosSlope;

        final o = validTriCount * 9;
        worldTris[o] = x0;
        worldTris[o + 1] = y0;
        worldTris[o + 2] = z0;
        worldTris[o + 3] = x1;
        worldTris[o + 4] = y1;
        worldTris[o + 5] = z1;
        worldTris[o + 6] = x2;
        worldTris[o + 7] = y2;
        worldTris[o + 8] = z2;
        triWalkable[validTriCount] = walkable ? 1 : 0;
        validTriCount++;

        minX = math.min(minX, math.min(x0, math.min(x1, x2)));
        minY = math.min(minY, math.min(y0, math.min(y1, y2)));
        minZ = math.min(minZ, math.min(z0, math.min(z1, z2)));
        maxX = math.max(maxX, math.max(x0, math.max(x1, x2)));
        maxY = math.max(maxY, math.max(y0, math.max(y1, y2)));
        maxZ = math.max(maxZ, math.max(z0, math.max(z1, z2)));
      }
    }

    if (validTriCount == 0 || !minX.isFinite) {
      return NavMesh3D.fromIndexedTriangles(
        vertices: const [],
        triangles: const [],
        upAxis: emptyUp,
      );
    }

    final cs = config.cellSize;
    final ch = config.cellHeight;
    final invCs = 1.0 / cs;
    final invCh = 1.0 / ch;

    final cols = math.max(1, ((maxX - minX) * invCs).ceil());
    final rows = math.max(1, ((maxZ - minZ) * invCs).ceil());
    final mergeThrVoxels = math.max(1, (config.maxClimb * invCh).floor());

    // 2. Voxelize triangles into solid column heightfield (`cols * rows`).
    final columns = List<List<_SolidSpan>?>.filled(cols * rows, null);

    for (var t = 0; t < validTriCount; t++) {
      final o = t * 9;
      final x0 = worldTris[o];
      final y0 = worldTris[o + 1];
      final z0 = worldTris[o + 2];
      final x1 = worldTris[o + 3];
      final y1 = worldTris[o + 4];
      final z1 = worldTris[o + 5];
      final x2 = worldTris[o + 6];
      final y2 = worldTris[o + 7];
      final z2 = worldTris[o + 8];
      final walkable = triWalkable[t] != 0;

      final tMinX = math.min(x0, math.min(x1, x2));
      final tMaxX = math.max(x0, math.max(x1, x2));
      final tMinZ = math.min(z0, math.min(z1, z2));
      final tMaxZ = math.max(z0, math.max(z1, z2));

      final c0 = ((tMinX - minX) * invCs).floor().clamp(0, cols - 1);
      final c1 = ((tMaxX - minX) * invCs).floor().clamp(0, cols - 1);
      final r0 = ((tMinZ - minZ) * invCs).floor().clamp(0, rows - 1);
      final r1 = ((tMaxZ - minZ) * invCs).floor().clamp(0, rows - 1);

      for (var r = r0; r <= r1; r++) {
        final zLo = minZ + r * cs;
        final zHi = zLo + cs;
        for (var c = c0; c <= c1; c++) {
          final xLo = minX + c * cs;
          final xHi = xLo + cs;

          if (!_clipTriangleColumnYRange(
            x0,
            y0,
            z0,
            x1,
            y1,
            z1,
            x2,
            y2,
            z2,
            xLo,
            xHi,
            zLo,
            zHi,
          )) {
            continue;
          }
          final sMinY = _clipMinY;
          final sMaxY = _clipMaxY;
          final sMin = math.max(0, ((sMinY - minY) * invCh).floor());
          final sMax = math.max(sMin, ((sMaxY - minY) * invCh).floor());

          final cellIdx = r * cols + c;
          final list = columns[cellIdx] ??= <_SolidSpan>[];
          _insertSolidSpan(
            list,
            sMin: sMin,
            sMax: sMax,
            topY: sMaxY,
            walkable: walkable,
            mergeThr: mergeThrVoxels,
          );
        }
      }
    }

    // 3. Extract compact walkable spans with `>= agentHeight` ceiling headroom.
    final walkableSpans = <_WalkableSpan>[];
    final cellSpanStart = Int32List(cols * rows)..fillRange(0, cols * rows, -1);
    final cellSpanCount = Int32List(cols * rows);
    final minHeadroomVoxels = (config.agentHeight * invCh).ceil();

    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        final cellIdx = r * cols + c;
        final list = columns[cellIdx];
        if (list == null || list.isEmpty) {
          continue;
        }
        var firstIdx = -1;
        var count = 0;
        for (var i = 0; i < list.length; i++) {
          final sp = list[i];
          if (!sp.walkable) {
            continue;
          }
          final ceilingMinVoxel = i + 1 < list.length
              ? list[i + 1].sMin
              : 0x3FFFFFFF;
          final ceilingY = i + 1 < list.length
              ? minY + list[i + 1].sMin * ch
              : double.infinity;
          if (ceilingMinVoxel - sp.sMax < minHeadroomVoxels ||
              ceilingY - sp.topY < config.agentHeight - 1e-4) {
            continue;
          }
          final wIdx = walkableSpans.length;
          if (firstIdx < 0) {
            firstIdx = wIdx;
          }
          count++;
          walkableSpans.add(
            _WalkableSpan(
              col: c,
              row: r,
              topY: sp.topY,
              ceilingY: ceilingY,
            ),
          );
        }
        if (count > 0) {
          cellSpanStart[cellIdx] = firstIdx;
          cellSpanCount[cellIdx] = count;
        }
      }
    }

    if (walkableSpans.isEmpty) {
      return NavMesh3D.fromIndexedTriangles(
        vertices: const [],
        triangles: const [],
        upAxis: emptyUp,
      );
    }

    // 4. Connect 4-cardinal neighbor spans (`|dh| <= maxClimb` + headroom).
    // Directions: 0 = -X, 1 = +Z, 2 = +X, 3 = -Z.
    const dirDx = [-1, 0, 1, 0];
    const dirDz = [0, 1, 0, -1];

    for (var sIdx = 0; sIdx < walkableSpans.length; sIdx++) {
      final s = walkableSpans[sIdx];
      for (var dir = 0; dir < 4; dir++) {
        final nc = s.col + dirDx[dir];
        final nr = s.row + dirDz[dir];
        if (nc < 0 || nc >= cols || nr < 0 || nr >= rows) {
          continue;
        }
        final nCell = nr * cols + nc;
        final nStart = cellSpanStart[nCell];
        final nCnt = cellSpanCount[nCell];
        if (nCnt == 0) {
          continue;
        }

        var bestNeighbor = -1;
        var bestDh = double.infinity;
        for (var k = 0; k < nCnt; k++) {
          final candIdx = nStart + k;
          final cand = walkableSpans[candIdx];
          final dh = (cand.topY - s.topY).abs();
          if (dh > config.maxClimb + 1e-4) {
            continue;
          }
          final sharedFloor = math.max(s.topY, cand.topY);
          final sharedCeil = math.min(s.ceilingY, cand.ceilingY);
          if (sharedCeil - sharedFloor < config.agentHeight - 1e-4) {
            continue;
          }
          if (dh < bestDh) {
            bestDh = dh;
            bestNeighbor = candIdx;
          }
        }
        s.neighbors[dir] = bestNeighbor;
      }
    }

    // 5. Distance-field `agentRadius` boundary erosion (Recast Chamfer pass).
    final spanCount = walkableSpans.length;
    final alive = Uint8List(spanCount)..fillRange(0, spanCount, 1);

    if (config.agentRadius > 1e-6) {
      final dist = Float64List(spanCount)..fillRange(0, spanCount, 1e9);

      // Seed boundary spans (missing at least one cardinal neighbor) at
      // `0.5 * cellSize` (distance from cell center to its blocked edge).
      for (var i = 0; i < spanCount; i++) {
        final s = walkableSpans[i];
        if (s.neighbors[0] < 0 ||
            s.neighbors[1] < 0 ||
            s.neighbors[2] < 0 ||
            s.neighbors[3] < 0) {
          dist[i] = 0.5 * cs;
        }
      }

      final diagStep = cs * math.sqrt2;

      // Pass 1: bottom-left to top-right (`-X`, `-Z`, and `-Z` diagonals).
      for (var i = 0; i < spanCount; i++) {
        final s = walkableSpans[i];
        final nWest = s.neighbors[0];
        if (nWest >= 0) {
          if (dist[nWest] + cs < dist[i]) {
            dist[i] = dist[nWest] + cs;
          }
          final nSouthWest = walkableSpans[nWest].neighbors[3];
          if (nSouthWest >= 0 && dist[nSouthWest] + diagStep < dist[i]) {
            dist[i] = dist[nSouthWest] + diagStep;
          }
        }
        final nSouth = s.neighbors[3];
        if (nSouth >= 0) {
          if (dist[nSouth] + cs < dist[i]) {
            dist[i] = dist[nSouth] + cs;
          }
          final nSouthEast = walkableSpans[nSouth].neighbors[2];
          if (nSouthEast >= 0 && dist[nSouthEast] + diagStep < dist[i]) {
            dist[i] = dist[nSouthEast] + diagStep;
          }
        }
      }

      // Pass 2: top-right to bottom-left (`+X`, `+Z`, and `+Z` diagonals).
      for (var i = spanCount - 1; i >= 0; i--) {
        final s = walkableSpans[i];
        final nEast = s.neighbors[2];
        if (nEast >= 0) {
          if (dist[nEast] + cs < dist[i]) {
            dist[i] = dist[nEast] + cs;
          }
          final nNorthEast = walkableSpans[nEast].neighbors[1];
          if (nNorthEast >= 0 && dist[nNorthEast] + diagStep < dist[i]) {
            dist[i] = dist[nNorthEast] + diagStep;
          }
        }
        final nNorth = s.neighbors[1];
        if (nNorth >= 0) {
          if (dist[nNorth] + cs < dist[i]) {
            dist[i] = dist[nNorth] + cs;
          }
          final nNorthWest = walkableSpans[nNorth].neighbors[0];
          if (nNorthWest >= 0 && dist[nNorthWest] + diagStep < dist[i]) {
            dist[i] = dist[nNorthWest] + diagStep;
          }
        }
      }

      for (var i = 0; i < spanCount; i++) {
        if (dist[i] < config.agentRadius - 1e-6) {
          alive[i] = 0;
        }
      }
    }

    // 6. Emit connected walkable quads with height-clustered corner vertices so
    // connected neighbor spans (`|dh| <= maxClimb`) share exact portal edges
    // while multi-level bridge decks and cliffs stay cleanly separated.
    final outVerts = <Vector3>[];
    final cornerClusters =
        <(int, int), List<(int vertIdx, double ySum, int n)>>{};

    int resolveCornerVertex(int gx, int gz, double spanY) {
      final list = cornerClusters[(gx, gz)] ??= <(int, double, int)>[];
      for (var i = 0; i < list.length; i++) {
        final (vIdx, ySum, cnt) = list[i];
        final curAvg = ySum / cnt;
        if ((curAvg - spanY).abs() <= config.maxClimb + 1e-4) {
          final nextSum = ySum + spanY;
          final nextCnt = cnt + 1;
          list[i] = (vIdx, nextSum, nextCnt);
          outVerts[vIdx].y = nextSum / nextCnt;
          return vIdx;
        }
      }
      final newIdx = outVerts.length;
      outVerts.add(Vector3(minX + gx * cs, spanY, minZ + gz * cs));
      list.add((newIdx, spanY, 1));
      return newIdx;
    }

    final spanCorners = Int32List(spanCount * 4);
    var survivingCount = 0;
    for (var i = 0; i < spanCount; i++) {
      if (alive[i] == 0) {
        continue;
      }
      survivingCount++;
      final s = walkableSpans[i];
      final b = i * 4;
      // Corner order around cell `(c, r)` in XZ:
      // `v00 = (c, r)`, `v10 = (c+1, r)`, `v11 = (c+1, r+1)`, `v01 = (c, r+1)`.
      spanCorners[b] = resolveCornerVertex(s.col, s.row, s.topY);
      spanCorners[b + 1] = resolveCornerVertex(s.col + 1, s.row, s.topY);
      spanCorners[b + 2] = resolveCornerVertex(s.col + 1, s.row + 1, s.topY);
      spanCorners[b + 3] = resolveCornerVertex(s.col, s.row + 1, s.topY);
    }

    if (survivingCount == 0) {
      return NavMesh3D.fromIndexedTriangles(
        vertices: const [],
        triangles: const [],
        upAxis: emptyUp,
      );
    }

    final indexedTris = <(int, int, int, Vector3)>[];
    for (var i = 0; i < spanCount; i++) {
      if (alive[i] == 0) {
        continue;
      }
      final b = i * 4;
      final v00 = spanCorners[b];
      final v10 = spanCorners[b + 1];
      final v11 = spanCorners[b + 2];
      final v01 = spanCorners[b + 3];

      // CCW from +Y: `(v00, v01, v11)` and `(v00, v11, v10)`.
      indexedTris
        ..add((
          v00,
          v01,
          v11,
          _triUpNormal(outVerts[v00], outVerts[v01], outVerts[v11]),
        ))
        ..add((
          v00,
          v11,
          v10,
          _triUpNormal(outVerts[v00], outVerts[v11], outVerts[v10]),
        ));
    }

    return NavMesh3D.fromIndexedTriangles(
      vertices: outVerts,
      triangles: indexedTris,
      upAxis: emptyUp,
    );
  }

  /// Convenience builder accepting `(Mesh, Matrix4?)` pairs directly.
  static NavMesh3D fromMeshes(
    List<(Mesh mesh, Matrix4? transform)> meshes, {
    NavMeshBuildConfig3D config = const NavMeshBuildConfig3D(),
  }) {
    final sources = <NavMeshGeometrySource3D>[];
    for (final (mesh, transform) in meshes) {
      sources.addAll(
        NavMeshGeometrySource3D.fromMesh(mesh, transform: transform),
      );
    }
    return fromGeometry(sources, config: config);
  }

  static int _countTotalTriangles(List<NavMeshGeometrySource3D> sources) {
    var total = 0;
    for (var i = 0; i < sources.length; i++) {
      total += sources[i].indices.length ~/ 3;
    }
    return total;
  }

  static void _insertSolidSpan(
    List<_SolidSpan> column, {
    required int sMin,
    required int sMax,
    required double topY,
    required bool walkable,
    required int mergeThr,
  }) {
    var curMin = sMin;
    var curMax = sMax;
    var curTopY = topY;
    var curWalkable = walkable;

    var idx = 0;
    while (idx < column.length) {
      final ex = column[idx];
      if (ex.sMax < curMin - 1) {
        idx++;
        continue;
      }
      if (ex.sMin > curMax + 1) {
        break;
      }

      // Overlapping or vertically adjacent spans merge into one solid column
      // interval, inheriting walkability at whichever top surface wins.
      if ((curMax - ex.sMax).abs() <= mergeThr) {
        curWalkable = curWalkable || ex.walkable;
      } else if (ex.sMax > curMax) {
        curWalkable = ex.walkable;
      }
      if (ex.topY > curTopY) {
        curTopY = ex.topY;
      }
      curMin = math.min(curMin, ex.sMin);
      curMax = math.max(curMax, ex.sMax);
      column.removeAt(idx);
    }

    column.insert(
      idx,
      _SolidSpan(
        sMin: curMin,
        sMax: curMax,
        topY: curTopY,
        walkable: curWalkable,
      ),
    );
  }

  static final Float64List _clipA = Float64List(24);
  static final Float64List _clipB = Float64List(24);
  static double _clipMinY = 0.0;
  static double _clipMaxY = 0.0;

  static bool _clipTriangleColumnYRange(
    double x0,
    double y0,
    double z0,
    double x1,
    double y1,
    double z1,
    double x2,
    double y2,
    double z2,
    double xLo,
    double xHi,
    double zLo,
    double zHi,
  ) {
    final a = _clipA;
    final b = _clipB;
    a[0] = x0;
    a[1] = y0;
    a[2] = z0;
    a[3] = x1;
    a[4] = y1;
    a[5] = z1;
    a[6] = x2;
    a[7] = y2;
    a[8] = z2;

    var count = _clipSlabXZ(a, b, 3, useX: true, bound: xLo, isMin: true);
    if (count == 0) {
      return false;
    }
    count = _clipSlabXZ(b, a, count, useX: true, bound: xHi, isMin: false);
    if (count == 0) {
      return false;
    }
    count = _clipSlabXZ(a, b, count, useX: false, bound: zLo, isMin: true);
    if (count == 0) {
      return false;
    }
    count = _clipSlabXZ(b, a, count, useX: false, bound: zHi, isMin: false);
    if (count == 0) {
      return false;
    }

    var lo = double.infinity;
    var hi = double.negativeInfinity;
    for (var i = 0; i < count; i++) {
      final y = a[i * 3 + 1];
      if (y < lo) {
        lo = y;
      }
      if (y > hi) {
        hi = y;
      }
    }
    if (!lo.isFinite) {
      return false;
    }
    _clipMinY = lo;
    _clipMaxY = hi;
    return true;
  }

  static int _clipSlabXZ(
    Float64List src,
    Float64List dst,
    int n, {
    required bool useX,
    required double bound,
    required bool isMin,
  }) {
    if (n == 0) {
      return 0;
    }
    var outCount = 0;
    final coordOffset = useX ? 0 : 2;
    var prevOff = (n - 1) * 3;
    var prevVal = src[prevOff + coordOffset];
    var prevIn = isMin ? prevVal >= bound - 1e-7 : prevVal <= bound + 1e-7;

    for (var i = 0; i < n; i++) {
      final currOff = i * 3;
      final currVal = src[currOff + coordOffset];
      final currIn = isMin ? currVal >= bound - 1e-7 : currVal <= bound + 1e-7;
      if (prevIn != currIn) {
        final denom = currVal - prevVal;
        final t = denom.abs() > 1e-12
            ? ((bound - prevVal) / denom).clamp(0.0, 1.0)
            : 0.5;
        final outOff = outCount * 3;
        dst[outOff] = src[prevOff] + (src[currOff] - src[prevOff]) * t;
        dst[outOff + 1] =
            src[prevOff + 1] + (src[currOff + 1] - src[prevOff + 1]) * t;
        dst[outOff + 2] =
            src[prevOff + 2] + (src[currOff + 2] - src[prevOff + 2]) * t;
        outCount++;
      }
      if (currIn) {
        final outOff = outCount * 3;
        dst[outOff] = src[currOff];
        dst[outOff + 1] = src[currOff + 1];
        dst[outOff + 2] = src[currOff + 2];
        outCount++;
      }
      prevOff = currOff;
      prevVal = currVal;
      prevIn = currIn;
    }
    return outCount;
  }

  static Vector3 _triUpNormal(Vector3 a, Vector3 b, Vector3 c) {
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
      return Vector3(nx / len, ny / len, nz / len);
    }
    return Vector3(0.0, 1.0, 0.0);
  }
}

class _SolidSpan({
  required final int sMin,
  required final int sMax,
  required final double topY,
  required final bool walkable,
});

class _WalkableSpan({
  required final int col,
  required final int row,
  required final double topY,
  required final double ceilingY,
}) {
  final Int32List neighbors = Int32List(4)..fillRange(0, 4, -1);
}
