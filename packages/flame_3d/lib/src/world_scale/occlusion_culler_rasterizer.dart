part of 'occlusion_culler_3d.dart';

const List<int> _boxFaceQuads = <int>[
  0, 2, 3, 1, // -Z
  4, 5, 7, 6, // +Z
  0, 4, 6, 2, // -X
  1, 3, 7, 5, // +X
  0, 1, 5, 4, // -Y
  2, 6, 7, 3, // +Y
];

extension _OcclusionCullerRasterizer on OcclusionCuller3D {
  void _rasterizeBoxInternal(OccluderBox3D box, Matrix4 viewProjection) {
    final q = box.rotation;
    final qx = q.x;
    final qy = q.y;
    final qz = q.z;
    final qw = q.w;
    final xx = qx * qx;
    final yy = qy * qy;
    final zz = qz * qz;
    final xy = qx * qy;
    final xz = qx * qz;
    final yz = qy * qz;
    final wx = qw * qx;
    final wy = qw * qy;
    final wz = qw * qz;

    final r0 = 1.0 - 2.0 * (yy + zz);
    final r1 = 2.0 * (xy + wz);
    final r2 = 2.0 * (xz - wy);
    final r3 = 2.0 * (xy - wz);
    final r4 = 1.0 - 2.0 * (xx + zz);
    final r5 = 2.0 * (yz + wx);
    final r6 = 2.0 * (xz + wy);
    final r7 = 2.0 * (yz - wx);
    final r8 = 1.0 - 2.0 * (xx + yy);

    final cx = box.center.x;
    final cy = box.center.y;
    final cz = box.center.z;
    final hx = box.halfExtents.x;
    final hy = box.halfExtents.y;
    final hz = box.halfExtents.z;

    for (var i = 0; i < 8; i++) {
      final lx = (i & 1) == 0 ? -hx : hx;
      final ly = (i & 2) == 0 ? -hy : hy;
      final lz = (i & 4) == 0 ? -hz : hz;
      final o = i * 3;
      _boxCorners
        ..[o] = cx + r0 * lx + r3 * ly + r6 * lz
        ..[o + 1] = cy + r1 * lx + r4 * ly + r7 * lz
        ..[o + 2] = cz + r2 * lx + r5 * ly + r8 * lz;
    }

    final vp = viewProjection.storage;
    if (_rasterizeBoxSilhouette(vp)) {
      return;
    }
    // The box crosses the near plane: rasterize its faces one by one. Their
    // shared edges are covered by neither face, so the box occludes a little
    // less than it could, never more.
    for (var f = 0; f < 6; f++) {
      final fb = f * 4;
      final i0 = _boxFaceQuads[fb] * 3;
      final i1 = _boxFaceQuads[fb + 1] * 3;
      final i2 = _boxFaceQuads[fb + 2] * 3;
      final i3 = _boxFaceQuads[fb + 3] * 3;
      _rasterizeWorldQuad(
        _boxCorners[i0],
        _boxCorners[i0 + 1],
        _boxCorners[i0 + 2],
        _boxCorners[i1],
        _boxCorners[i1 + 1],
        _boxCorners[i1 + 2],
        _boxCorners[i2],
        _boxCorners[i2 + 1],
        _boxCorners[i2 + 2],
        _boxCorners[i3],
        _boxCorners[i3 + 1],
        _boxCorners[i3 + 2],
        vp,
        doubleSided: false,
      );
    }
  }

  /// Rasterizes the box whose corners are in [_boxCorners] as its convex
  /// screen silhouette, at the depth where each view ray enters it (the
  /// farthest of its front-face planes). Returns `false`, rasterizing
  /// nothing, when a corner is behind the near plane.
  bool _rasterizeBoxSilhouette(Float32List vp) {
    final halfW = _subWidth * 0.5;
    final halfH = _subHeight * 0.5;
    for (var i = 0; i < 8; i++) {
      final o = i * 3;
      final wx = _boxCorners[o];
      final wy = _boxCorners[o + 1];
      final wz = _boxCorners[o + 2];
      final cx = vp[0] * wx + vp[4] * wy + vp[8] * wz + vp[12];
      final cy = vp[1] * wx + vp[5] * wy + vp[9] * wz + vp[13];
      final cz = vp[2] * wx + vp[6] * wy + vp[10] * wz + vp[14];
      final cw = vp[3] * wx + vp[7] * wy + vp[11] * wz + vp[15];
      if (cw <= 1e-4 || cz < 0) {
        return false;
      }
      final invW = 1.0 / cw;
      _boxScreen
        ..[o] = (cx * invW + 1.0) * halfW
        ..[o + 1] = (cy * invW + 1.0) * halfH
        ..[o + 2] = cz * invW;
    }

    var planeCount = 0;
    for (var f = 0; f < 6; f++) {
      final fb = f * 4;
      final i0 = _boxFaceQuads[fb] * 3;
      final i1 = _boxFaceQuads[fb + 1] * 3;
      final i2 = _boxFaceQuads[fb + 2] * 3;
      final i3 = _boxFaceQuads[fb + 3] * 3;
      // Faces are counter-clockwise seen from outside: a positive area faces
      // the camera. Edge-on faces cannot be where a ray enters the box.
      final area =
          _triangleArea2(_boxScreen, i0, i1, i2) +
          _triangleArea2(_boxScreen, i0, i2, i3);
      if (area <= 1e-6) {
        continue;
      }
      final firstLarger =
          _triangleArea2(_boxScreen, i0, i1, i2).abs() >=
          _triangleArea2(_boxScreen, i0, i2, i3).abs();
      final added = firstLarger
          ? _addPlane(_boxScreen, 3, i0 ~/ 3, i1 ~/ 3, i2 ~/ 3, planeCount)
          : _addPlane(_boxScreen, 3, i0 ~/ 3, i2 ~/ 3, i3 ~/ 3, planeCount);
      if (added) {
        planeCount++;
      }
    }
    if (planeCount == 0) {
      return true;
    }

    final hullCount = _convexHullOfBox();
    if (hullCount < 3) {
      return true;
    }
    _rasterizeConvexPolygon(hullCount, 1, planeCount);
    return true;
  }

  /// Stores in [_planes] at [index] the depth plane through the points
  /// [i0], [i1] and [i2] of [points] (x, y, z, with [stride] values per
  /// point), padded to its farthest depth over a subpixel square. Returns
  /// `false` for a degenerate triangle.
  bool _addPlane(
    Float64List points,
    int stride,
    int i0,
    int i1,
    int i2,
    int index,
  ) {
    final o0 = i0 * stride;
    final o1 = i1 * stride;
    final o2 = i2 * stride;
    final x0 = points[o0];
    final y0 = points[o0 + 1];
    final z0 = points[o0 + 2];
    final dx1 = points[o1] - x0;
    final dy1 = points[o1 + 1] - y0;
    final dz1 = points[o1 + 2] - z0;
    final dx2 = points[o2] - x0;
    final dy2 = points[o2 + 1] - y0;
    final dz2 = points[o2 + 2] - z0;
    final area = dx1 * dy2 - dy1 * dx2;
    if (area.abs() <= 1e-9) {
      return false;
    }
    final a = (dz1 * dy2 - dy1 * dz2) / area;
    final b = (dx1 * dz2 - dz1 * dx2) / area;
    final o = index * 3;
    _planes
      ..[o] = a
      ..[o + 1] = b
      ..[o + 2] = z0 - a * x0 - b * y0 + 0.5 * (a.abs() + b.abs());
    return true;
  }

  /// Writes the counter-clockwise convex hull of the eight projected box
  /// corners into [_screenPoly] and returns its vertex count (monotone
  /// chain, without allocating).
  int _convexHullOfBox() {
    final pts = _boxScreen;
    final order = _hullOrder;
    for (var i = 0; i < 8; i++) {
      order[i] = i;
    }
    // Insertion sort by x, then y.
    for (var i = 1; i < 8; i++) {
      final key = order[i];
      final kx = pts[key * 3];
      final ky = pts[key * 3 + 1];
      var j = i - 1;
      while (j >= 0) {
        final jx = pts[order[j] * 3];
        final jy = pts[order[j] * 3 + 1];
        if (jx < kx || (jx == kx && jy <= ky)) {
          break;
        }
        order[j + 1] = order[j];
        j--;
      }
      order[j + 1] = key;
    }

    final hull = _hull;
    var k = 0;
    for (var i = 0; i < 8; i++) {
      while (k >= 2 && _turn(pts, hull[k - 2], hull[k - 1], order[i]) <= 0) {
        k--;
      }
      hull[k++] = order[i];
    }
    final lowerSize = k + 1;
    for (var i = 6; i >= 0; i--) {
      while (k >= lowerSize &&
          _turn(pts, hull[k - 2], hull[k - 1], order[i]) <= 0) {
        k--;
      }
      hull[k++] = order[i];
    }
    final count = k - 1;
    for (var i = 0; i < count; i++) {
      _screenPoly
        ..[i * 2] = pts[hull[i] * 3]
        ..[i * 2 + 1] = pts[hull[i] * 3 + 1];
    }
    return count;
  }

  /// Rasterizes the convex polygon of [count] vertices in [_screenPoly]
  /// ([orientation] `1` when counter-clockwise, `-1` when clockwise) with the
  /// first [planeCount] depth planes of [_planes]: every subpixel whose whole
  /// square is inside the polygon takes the farthest depth of the planes
  /// over that square, when nearer than what it holds.
  void _rasterizeConvexPolygon(int count, double orientation, int planeCount) {
    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    for (var i = 0; i < count; i++) {
      final x = _screenPoly[i * 2];
      final y = _screenPoly[i * 2 + 1];
      final x1 = _screenPoly[((i + 1) % count) * 2];
      final y1 = _screenPoly[((i + 1) % count) * 2 + 1];
      minX = math.min(minX, x);
      maxX = math.max(maxX, x);
      minY = math.min(minY, y);
      maxY = math.max(maxY, y);
      // Inside of the edge from (x, y) to (x1, y1): orientation * cross >= 0.
      final ex = x1 - x;
      final ey = y1 - y;
      final a = -orientation * ey;
      final b = orientation * ex;
      final c = orientation * (ey * x - ex * y);
      // The square is inside when its worst corner is.
      _edges
        ..[i * 3] = a
        ..[i * 3 + 1] = b
        ..[i * 3 + 2] = c - 0.5 * (a.abs() + b.abs());
    }

    // Subpixel sx covers [sx, sx + 1]: only squares within the bounds can be
    // inside.
    final sx0 = math.max(0, minX.ceil());
    final sx1 = math.min(_subWidth - 1, maxX.floor() - 1);
    final sy0 = math.max(0, minY.ceil());
    final sy1 = math.min(_subHeight - 1, maxY.floor() - 1);
    if (sx0 > sx1 || sy0 > sy1) {
      return;
    }

    for (var sy = sy0; sy <= sy1; sy++) {
      final py = sy + 0.5;
      final row = sy * _subWidth;
      for (var sx = sx0; sx <= sx1; sx++) {
        final px = sx + 0.5;
        var inside = true;
        for (var e = 0; e < count; e++) {
          final o = e * 3;
          if (_edges[o] * px + _edges[o + 1] * py + _edges[o + 2] < 0) {
            inside = false;
            break;
          }
        }
        if (!inside) {
          continue;
        }
        var depth = double.negativeInfinity;
        for (var p = 0; p < planeCount; p++) {
          final o = p * 3;
          final d = _planes[o] * px + _planes[o + 1] * py + _planes[o + 2];
          if (d > depth) {
            depth = d;
          }
        }
        final z = depth.clamp(0.0, 1.0);
        final idx = row + sx;
        if (z < _subDepth[idx]) {
          _subDepth[idx] = z;
        }
      }
    }
  }

  void _rasterizeWorldQuad(
    double x0,
    double y0,
    double z0,
    double x1,
    double y1,
    double z1,
    double x2,
    double y2,
    double z2,
    double x3,
    double y3,
    double z3,
    Float32List vp, {
    required bool doubleSided,
  }) {
    projectClipPoint4(vp, x0, y0, z0, _polyA, 0);
    projectClipPoint4(vp, x1, y1, z1, _polyA, 4);
    projectClipPoint4(vp, x2, y2, z2, _polyA, 8);
    projectClipPoint4(vp, x3, y3, z3, _polyA, 12);

    // Clip against w >= 1e-4 and z >= 0 (near plane).
    final countW = clipPolygonW(_polyA, 4, _polyB);
    if (countW < 3) {
      return;
    }
    final countZ = clipPolygonNearZ(_polyB, countW, _polyA);
    if (countZ < 3) {
      return;
    }

    // Convert clipped vertices in `_polyA` to subpixel screen `(sx, sy, ndcZ)`
    // in `_polyB`, and the (x, y) in `_screenPoly`.
    final halfW = _subWidth * 0.5;
    final halfH = _subHeight * 0.5;
    var area = 0.0;
    for (var i = 0; i < countZ; i++) {
      final o = i * 4;
      final invW = 1.0 / _polyA[o + 3];
      final x = (_polyA[o] * invW + 1.0) * halfW;
      final y = (_polyA[o + 1] * invW + 1.0) * halfH;
      _polyB
        ..[o] = x
        ..[o + 1] = y
        ..[o + 2] = _polyA[o + 2] * invW;
      _screenPoly
        ..[i * 2] = x
        ..[i * 2 + 1] = y;
    }
    for (var i = 0; i < countZ; i++) {
      final j = (i + 1) % countZ;
      area +=
          _screenPoly[i * 2] * _screenPoly[j * 2 + 1] -
          _screenPoly[j * 2] * _screenPoly[i * 2 + 1];
    }
    if (area.abs() <= 1e-8 || (!doubleSided && area <= 0)) {
      return;
    }
    final orientation = area > 0 ? 1.0 : -1.0;

    // Only a convex outline can be tested edge by edge; a non-convex quad
    // occludes nothing.
    for (var i = 0; i < countZ; i++) {
      final a = i * 2;
      final b = ((i + 1) % countZ) * 2;
      final c = ((i + 2) % countZ) * 2;
      final turn =
          (_screenPoly[b] - _screenPoly[a]) *
              (_screenPoly[c + 1] - _screenPoly[b + 1]) -
          (_screenPoly[b + 1] - _screenPoly[a + 1]) *
              (_screenPoly[c] - _screenPoly[b]);
      if (turn * orientation < -1e-9) {
        return;
      }
    }

    // The quad is planar: its depth plane through the largest fan triangle.
    var best = -1;
    var bestArea = 0.0;
    for (var k = 1; k + 1 < countZ; k++) {
      final t = _triangleArea2(_polyB, 0, k * 4, (k + 1) * 4).abs();
      if (t > bestArea) {
        bestArea = t;
        best = k;
      }
    }
    if (best < 0 || !_addPlane(_polyB, 4, 0, best, best + 1, 0)) {
      return;
    }
    _rasterizeConvexPolygon(countZ, orientation, 1);
  }
}

/// Twice the signed area of the triangle of the (x, y) points at offsets
/// [a], [b] and [c] of [points].
double _triangleArea2(Float64List points, int a, int b, int c) {
  return (points[b] - points[a]) * (points[c + 1] - points[a + 1]) -
      (points[b + 1] - points[a + 1]) * (points[c] - points[a]);
}

/// The turn from corner [o] to [a] to [b] of the (x, y, z) [points]:
/// positive when counter-clockwise.
double _turn(Float64List points, int o, int a, int b) =>
    _triangleArea2(points, o * 3, a * 3, b * 3);
