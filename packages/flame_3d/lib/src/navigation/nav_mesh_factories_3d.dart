part of 'nav_mesh_3d.dart';

/// Extracts walkable triangles (`normal.dot(up) >= cos(maxSlopeAngleRad)`)
/// from [mesh] (optionally transformed by [transform]), welds vertices within
/// [weldEpsilon], and builds triangle portal adjacency.
NavMesh3D _buildNavMeshFromMesh(
  Mesh mesh, {
  Matrix4? transform,
  Vector3? upAxis,
  double maxSlopeAngleRad = 0.8,
  double weldEpsilon = 1e-3,
}) {
  final up = (upAxis?.clone() ?? Vector3(0.0, 1.0, 0.0))..normalize();
  final minCos = math.cos(maxSlopeAngleRad);
  final eps = math.max(1e-7, weldEpsilon);
  final eps2 = eps * eps;
  final invCell = 1.0 / eps;

  final weldedVerts = <Vector3>[];
  final spatialHash = <(int, int, int), List<int>>{};

  int weldVertex(double wx, double wy, double wz) {
    final cx = (wx * invCell).floor();
    final cy = (wy * invCell).floor();
    final cz = (wz * invCell).floor();
    for (var dx = -1; dx <= 1; dx++) {
      for (var dy = -1; dy <= 1; dy++) {
        for (var dz = -1; dz <= 1; dz++) {
          final bucket = spatialHash[(cx + dx, cy + dy, cz + dz)];
          if (bucket == null) {
            continue;
          }
          for (var k = 0; k < bucket.length; k++) {
            final idx = bucket[k];
            final existing = weldedVerts[idx];
            final ex = existing.x - wx;
            final ey = existing.y - wy;
            final ez = existing.z - wz;
            if (ex * ex + ey * ey + ez * ez <= eps2) {
              return idx;
            }
          }
        }
      }
    }
    final newIdx = weldedVerts.length;
    weldedVerts.add(Vector3(wx, wy, wz));
    (spatialHash[(cx, cy, cz)] ??= <int>[]).add(newIdx);
    return newIdx;
  }

  final m = transform?.storage;
  final rawTris = <(int, int, int, Vector3)>[];

  for (final surface in mesh.surfaces) {
    if (surface.indexCount < 3) {
      continue;
    }
    final pos = surface.positions;
    final indices = surface.indices;
    final triCount = indices.length ~/ 3;

    for (var t = 0; t < triCount; t++) {
      final base = t * 3;
      final raw0 = indices[base] * 3;
      final raw1 = indices[base + 1] * 3;
      final raw2 = indices[base + 2] * 3;

      var x0 = pos[raw0];
      var y0 = pos[raw0 + 1];
      var z0 = pos[raw0 + 2];
      var x1 = pos[raw1];
      var y1 = pos[raw1 + 1];
      var z1 = pos[raw1 + 2];
      var x2 = pos[raw2];
      var y2 = pos[raw2 + 1];
      var z2 = pos[raw2 + 2];

      if (m != null) {
        final tx0 = m[0] * x0 + m[4] * y0 + m[8] * z0 + m[12];
        final ty0 = m[1] * x0 + m[5] * y0 + m[9] * z0 + m[13];
        final tz0 = m[2] * x0 + m[6] * y0 + m[10] * z0 + m[14];
        final tx1 = m[0] * x1 + m[4] * y1 + m[8] * z1 + m[12];
        final ty1 = m[1] * x1 + m[5] * y1 + m[9] * z1 + m[13];
        final tz1 = m[2] * x1 + m[6] * y1 + m[10] * z1 + m[14];
        final tx2 = m[0] * x2 + m[4] * y2 + m[8] * z2 + m[12];
        final ty2 = m[1] * x2 + m[5] * y2 + m[9] * z2 + m[13];
        final tz2 = m[2] * x2 + m[6] * y2 + m[10] * z2 + m[14];
        x0 = tx0;
        y0 = ty0;
        z0 = tz0;
        x1 = tx1;
        y1 = ty1;
        z1 = tz1;
        x2 = tx2;
        y2 = ty2;
        z2 = tz2;
      }

      final e1x = x1 - x0;
      final e1y = y1 - y0;
      final e1z = z1 - z0;
      final e2x = x2 - x0;
      final e2y = y2 - y0;
      final e2z = z2 - z0;
      var nx = e1y * e2z - e1z * e2y;
      var ny = e1z * e2x - e1x * e2z;
      var nz = e1x * e2y - e1y * e2x;
      final nLen = math.sqrt(nx * nx + ny * ny + nz * nz);
      if (nLen <= 1e-10) {
        continue;
      }
      nx /= nLen;
      ny /= nLen;
      nz /= nLen;

      var flipWinding = false;
      if (transform != null && transform.determinant() < 0.0) {
        nx = -nx;
        ny = -ny;
        nz = -nz;
        flipWinding = true;
      }

      final cosSlope = nx * up.x + ny * up.y + nz * up.z;
      if (cosSlope < minCos) {
        continue;
      }

      final w0 = weldVertex(x0, y0, z0);
      final w1 = weldVertex(x1, y1, z1);
      final w2 = weldVertex(x2, y2, z2);
      if (w0 == w1 || w1 == w2 || w2 == w0) {
        continue;
      }

      final i0 = w0;
      final i1 = flipWinding ? w2 : w1;
      final i2 = flipWinding ? w1 : w2;
      rawTris.add((i0, i1, i2, Vector3(nx, ny, nz)));
    }
  }

  return NavMesh3D.fromIndexedTriangles(
    vertices: weldedVerts,
    triangles: rawTris,
    upAxis: up,
  );
}

/// Builds a [NavMesh3D] directly from pre-welded [vertices] and walkable
/// `(i0, i1, i2, normal)` [triangles], connecting shared edges into
/// [NavPortal3D]s.
NavMesh3D _buildNavMeshFromIndexedTriangles({
  required List<Vector3> vertices,
  required List<(int, int, int, Vector3)> triangles,
  Vector3? upAxis,
}) {
  final up = (upAxis?.clone() ?? Vector3(0.0, 1.0, 0.0))..normalize();
  final rawPolys = <(int, int, int, Vector3, Vector3)>[];

  for (var idx = 0; idx < triangles.length; idx++) {
    final (i0, i1, i2, norm) = triangles[idx];
    if (i0 == i1 || i1 == i2 || i2 == i0) {
      continue;
    }
    final p0 = vertices[i0];
    final p1 = vertices[i1];
    final p2 = vertices[i2];
    final centroid = Vector3(
      (p0.x + p1.x + p2.x) * (1.0 / 3.0),
      (p0.y + p1.y + p2.y) * (1.0 / 3.0),
      (p0.z + p1.z + p2.z) * (1.0 / 3.0),
    );
    rawPolys.add((i0, i1, i2, centroid, norm.clone()));
  }

  final edgeMap = <(int, int), List<int>>{};
  for (var pIdx = 0; pIdx < rawPolys.length; pIdx++) {
    final (i0, i1, i2, _, _) = rawPolys[pIdx];
    for (final (ea, eb) in [(i0, i1), (i1, i2), (i2, i0)]) {
      final key = ea < eb ? (ea, eb) : (eb, ea);
      (edgeMap[key] ??= <int>[]).add(pIdx);
    }
  }

  final portalLists = List<List<NavPortal3D>>.generate(
    rawPolys.length,
    (_) => <NavPortal3D>[],
  );

  for (final entry in edgeMap.entries) {
    final (ea, eb) = entry.key;
    final owners = entry.value;
    if (owners.length < 2) {
      continue;
    }
    final va = vertices[ea];
    final vb = vertices[eb];

    for (var i = 0; i < owners.length; i++) {
      final polyA = owners[i];
      final (a0, a1, a2, centA, _) = rawPolys[polyA];
      final oppIdx = (a0 != ea && a0 != eb)
          ? a0
          : ((a1 != ea && a1 != eb) ? a1 : a2);
      final opp = vertices[oppIdx];

      final orient = _triArea2Up(opp, va, vb, up);
      final right = orient >= 0.0 ? va : vb;
      final left = orient >= 0.0 ? vb : va;
      final rightIdx = orient >= 0.0 ? ea : eb;
      final leftIdx = orient >= 0.0 ? eb : ea;

      for (var j = 0; j < owners.length; j++) {
        if (i == j) {
          continue;
        }
        final polyB = owners[j];
        final (_, _, _, centB, _) = rawPolys[polyB];
        portalLists[polyA].add(
          NavPortal3D(
            targetPoly: polyB,
            left: left,
            right: right,
            cost: centA.distanceTo(centB),
            leftVertex: leftIdx,
            rightVertex: rightIdx,
          ),
        );
      }
    }
  }

  final polys = List<NavPoly3D>.generate(rawPolys.length, (idx) {
    final (i0, i1, i2, cent, norm) = rawPolys[idx];
    return NavPoly3D(
      index: idx,
      v0: i0,
      v1: i1,
      v2: i2,
      centroid: cent,
      normal: norm,
      portals: List.unmodifiable(portalLists[idx]),
    );
  }, growable: false);

  return NavMesh3D._(
    vertices: List.unmodifiable([for (final v in vertices) v.clone()]),
    polygons: List.unmodifiable(polys),
    upAxis: up,
  );
}
