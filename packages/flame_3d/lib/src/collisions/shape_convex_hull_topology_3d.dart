part of 'shapes_3d.dart';

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
