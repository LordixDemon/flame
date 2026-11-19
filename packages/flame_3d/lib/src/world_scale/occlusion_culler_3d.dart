import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame_3d/core.dart';

/// Oriented or axis-aligned 3D box occluder rasterized into
/// [OcclusionCuller3D].
class OccluderBox3D({
  required Vector3 center,
  required Vector3 halfExtents,
  Quaternion? rotation,
}) {
  /// Creates an oriented 3D box occluder centered at `center` with
  /// `halfExtents` and optional `rotation`.
  this
    : assert(
        halfExtents.x > 0 && halfExtents.y > 0 && halfExtents.z > 0,
        'halfExtents must be positive on all axes',
      );

  /// World-space center of the box.
  final Vector3 center = center.clone();

  /// Positive half-extents along local X, Y, Z axes.
  final Vector3 halfExtents = halfExtents.clone();

  /// World orientation of the box.
  final Quaternion rotation = rotation?.clone() ?? Quaternion.identity();

  /// Creates an axis-aligned box occluder from [bounds].
  factory OccluderBox3D.fromAabb(Aabb3 bounds) {
    final cx = 0.5 * (bounds.min.x + bounds.max.x);
    final cy = 0.5 * (bounds.min.y + bounds.max.y);
    final cz = 0.5 * (bounds.min.z + bounds.max.z);
    final hx = math.max(1e-4, 0.5 * (bounds.max.x - bounds.min.x));
    final hy = math.max(1e-4, 0.5 * (bounds.max.y - bounds.min.y));
    final hz = math.max(1e-4, 0.5 * (bounds.max.z - bounds.min.z));
    return OccluderBox3D(
      center: Vector3(cx, cy, cz),
      halfExtents: Vector3(hx, hy, hz),
    );
  }
}

/// Planar 4-corner world-space occluder quad (walls, gates, terrain ridges)
/// rasterized into [OcclusionCuller3D].
class OccluderQuad3D({
  required Vector3 v0,
  required Vector3 v1,
  required Vector3 v2,
  required Vector3 v3,

  /// Whether both sides of the quad occlude geometry behind it.
  var bool doubleSided = true,
}) {
  /// First corner in world space.
  final Vector3 v0 = v0.clone();

  /// Second corner in world space.
  final Vector3 v1 = v1.clone();

  /// Third corner in world space.
  final Vector3 v2 = v2.clone();

  /// Fourth corner in world space.
  final Vector3 v3 = v3.clone();

  /// Convenience factory for a vertical wall rising `+Y` by [height] between
  /// [bottomStart] and [bottomEnd].
  factory OccluderQuad3D.wall({
    required Vector3 bottomStart,
    required Vector3 bottomEnd,
    required double height,
    bool doubleSided = true,
  }) {
    return OccluderQuad3D(
      v0: bottomStart,
      v1: bottomEnd,
      v2: Vector3(bottomEnd.x, bottomEnd.y + height, bottomEnd.z),
      v3: Vector3(bottomStart.x, bottomStart.y + height, bottomStart.z),
      doubleSided: doubleSided,
    );
  }
}

/// Conservative software Hierarchical Z-Buffer (Hi-Z) occlusion culler.
///
/// Rasterizes registered [OccluderBox3D] and [OccluderQuad3D] primitives at
/// `2x2` subpixel resolution and downsamples via conservative `max` reduction
/// into `width x height` (`128 x 64` by default) plus two hierarchical `2x2`
/// max-depth mips (`64 x 32` and `32 x 16`). Partially covered silhouette
/// pixels retain far depth (`1.0`), ensuring visible geometry is never falsely
/// culled.
class OcclusionCuller3D({
  /// Base Hi-Z buffer width (`128` by default).
  final int width = 128,

  /// Base Hi-Z buffer height (`64` by default).
  final int height = 64,
}) {
  /// Creates a software Hi-Z occlusion culler with dimensions divisible by 4.
  this
    : assert(width >= 4 && width % 4 == 0, 'width must be a multiple of 4'),
      assert(height >= 4 && height % 4 == 0, 'height must be a multiple of 4') {
    clearDepth();
  }

  /// Width of hierarchical mip level 1 (`width / 2`).
  final int mip1Width = width >> 1;

  /// Height of hierarchical mip level 1 (`height / 2`).
  final int mip1Height = height >> 1;

  /// Width of hierarchical mip level 2 (`width / 4`).
  final int mip2Width = width >> 2;

  /// Height of hierarchical mip level 2 (`height / 4`).
  final int mip2Height = height >> 2;

  final int _subWidth = width << 1;
  final int _subHeight = height << 1;
  final Float32List _subDepth = Float32List((width << 1) * (height << 1));

  /// Base conservative depth buffer (`width * height`, `[0..1]`, `1` = far).
  final Float32List depthMip0 = Float32List(width * height);

  /// First `2x2` max-depth pyramid level (`(width / 2) * (height / 2)`).
  final Float32List depthMip1 = Float32List((width >> 1) * (height >> 1));

  /// Second `2x2` max-depth pyramid level (`(width / 4) * (height / 4)`).
  final Float32List depthMip2 = Float32List((width >> 2) * (height >> 2));

  final List<OccluderBox3D> _boxes = <OccluderBox3D>[];
  final List<OccluderQuad3D> _quads = <OccluderQuad3D>[];

  // Pre-allocated homogeneous clip-space polygon ping-pong buffers (up to 16
  // vertices * 4 doubles).
  final Float64List _polyA = Float64List(64);
  final Float64List _polyB = Float64List(64);
  final Float64List _boxCorners = Float64List(24);

  int _testedCount = 0;
  int _occludedCount = 0;
  int _rasterizedOccluderCount = 0;

  /// Number of [isAabbVisible] queries executed since the last [clearDepth] /
  /// [rasterizeOccluders].
  int get testedCount => _testedCount;

  /// Number of [isAabbVisible] queries culled as 100% occluded behind walls.
  int get occludedCount => _occludedCount;

  /// Number of occluder primitives rasterized in the current frame.
  int get rasterizedOccluderCount => _rasterizedOccluderCount;

  /// Registered box occluders.
  List<OccluderBox3D> get boxes => List.unmodifiable(_boxes);

  /// Registered quad occluders.
  List<OccluderQuad3D> get quads => List.unmodifiable(_quads);

  /// Registers a box occluder.
  void addBox(OccluderBox3D box) {
    _boxes.add(box);
  }

  /// Registers a quad occluder.
  void addQuad(OccluderQuad3D quad) {
    _quads.add(quad);
  }

  /// Removes all registered box and quad occluders.
  void clearOccluders() {
    _boxes.clear();
    _quads.clear();
  }

  /// Resets the Hi-Z depth pyramid to `1.0` (far plane) and zeroes telemetry.
  void clearDepth() {
    _subDepth.fillRange(0, _subDepth.length, 1.0);
    depthMip0.fillRange(0, depthMip0.length, 1.0);
    depthMip1.fillRange(0, depthMip1.length, 1.0);
    depthMip2.fillRange(0, depthMip2.length, 1.0);
    _testedCount = 0;
    _occludedCount = 0;
    _rasterizedOccluderCount = 0;
  }

  /// Clears the depth pyramid, rasterizes all registered [boxes] and [quads]
  /// for [viewProjection], and builds [depthMip0], [depthMip1], and
  /// [depthMip2].
  void rasterizeOccluders(Matrix4 viewProjection) {
    clearDepth();
    for (var i = 0; i < _boxes.length; i++) {
      _rasterizeBoxInternal(_boxes[i], viewProjection);
      _rasterizedOccluderCount++;
    }
    for (var i = 0; i < _quads.length; i++) {
      final q = _quads[i];
      _rasterizeWorldQuad(
        q.v0.x,
        q.v0.y,
        q.v0.z,
        q.v1.x,
        q.v1.y,
        q.v1.z,
        q.v2.x,
        q.v2.y,
        q.v2.z,
        q.v3.x,
        q.v3.y,
        q.v3.z,
        viewProjection.storage,
        doubleSided: q.doubleSided,
      );
      _rasterizedOccluderCount++;
    }
    rebuildHierarchy();
  }

  /// Recomputes [depthMip0], [depthMip1], and [depthMip2] from the subpixel
  /// raster buffer using conservative `2x2` `max` downsampling.
  void rebuildHierarchy() {
    final sw = _subWidth;
    for (var y = 0; y < height; y++) {
      final sy0 = (y << 1) * sw;
      final sy1 = sy0 + sw;
      final rowOut = y * width;
      for (var x = 0; x < width; x++) {
        final sx = x << 1;
        final d0 = math.max(_subDepth[sy0 + sx], _subDepth[sy0 + sx + 1]);
        final d1 = math.max(_subDepth[sy1 + sx], _subDepth[sy1 + sx + 1]);
        depthMip0[rowOut + x] = math.max(d0, d1);
      }
    }

    for (var y = 0; y < mip1Height; y++) {
      final r0 = (y << 1) * width;
      final r1 = r0 + width;
      final outRow = y * mip1Width;
      for (var x = 0; x < mip1Width; x++) {
        final sx = x << 1;
        final d0 = math.max(depthMip0[r0 + sx], depthMip0[r0 + sx + 1]);
        final d1 = math.max(depthMip0[r1 + sx], depthMip0[r1 + sx + 1]);
        depthMip1[outRow + x] = math.max(d0, d1);
      }
    }

    for (var y = 0; y < mip2Height; y++) {
      final r0 = (y << 1) * mip1Width;
      final r1 = r0 + mip1Width;
      final outRow = y * mip2Width;
      for (var x = 0; x < mip2Width; x++) {
        final sx = x << 1;
        final d0 = math.max(depthMip1[r0 + sx], depthMip1[r0 + sx + 1]);
        final d1 = math.max(depthMip1[r1 + sx], depthMip1[r1 + sx + 1]);
        depthMip2[outRow + x] = math.max(d0, d1);
      }
    }
  }

  /// Tests whether [worldBounds] is potentially visible in [viewProjection].
  ///
  /// Returns `true` if [worldBounds] straddles the near clip plane or if its
  /// nearest projected depth `minZ <= maxOccluderDepthInRect + depthBias`, and
  /// `false` when 100% occluded behind rasterized occluders (or completely
  /// outside the clip volume).
  bool isAabbVisible(
    Aabb3 worldBounds,
    Matrix4 viewProjection, {
    double depthBias = 0.002,
  }) {
    _testedCount++;
    final vp = viewProjection.storage;

    var minNdcX = double.infinity;
    var minNdcY = double.infinity;
    var minZ = double.infinity;
    var maxNdcX = double.negativeInfinity;
    var maxNdcY = double.negativeInfinity;
    var maxZ = double.negativeInfinity;

    for (var c = 0; c < 8; c++) {
      final wx = (c & 1) == 0 ? worldBounds.min.x : worldBounds.max.x;
      final wy = (c & 2) == 0 ? worldBounds.min.y : worldBounds.max.y;
      final wz = (c & 4) == 0 ? worldBounds.min.z : worldBounds.max.z;

      final cx = vp[0] * wx + vp[4] * wy + vp[8] * wz + vp[12];
      final cy = vp[1] * wx + vp[5] * wy + vp[9] * wz + vp[13];
      final cz = vp[2] * wx + vp[6] * wy + vp[10] * wz + vp[14];
      final cw = vp[3] * wx + vp[7] * wy + vp[11] * wz + vp[15];

      // Straddles eye or near clip plane: conservatively visible.
      if (cw <= 1e-5 || cz < 0) {
        return true;
      }

      final invW = 1.0 / cw;
      final ndcX = cx * invW;
      final ndcY = cy * invW;
      final ndcZ = cz * invW;

      if (ndcX < minNdcX) {
        minNdcX = ndcX;
      }
      if (ndcX > maxNdcX) {
        maxNdcX = ndcX;
      }
      if (ndcY < minNdcY) {
        minNdcY = ndcY;
      }
      if (ndcY > maxNdcY) {
        maxNdcY = ndcY;
      }
      if (ndcZ < minZ) {
        minZ = ndcZ;
      }
      if (ndcZ > maxZ) {
        maxZ = ndcZ;
      }
    }

    if (maxNdcX < -1.0 ||
        minNdcX > 1.0 ||
        maxNdcY < -1.0 ||
        minNdcY > 1.0 ||
        maxZ < 0.0 ||
        minZ > 1.0) {
      return false;
    }

    final clampedMinX = minNdcX.clamp(-1.0, 1.0);
    final clampedMaxX = maxNdcX.clamp(-1.0, 1.0);
    final clampedMinY = minNdcY.clamp(-1.0, 1.0);
    final clampedMaxY = maxNdcY.clamp(-1.0, 1.0);

    final px0 = ((clampedMinX * 0.5 + 0.5) * width).floor().clamp(0, width - 1);
    final px1 = math.max(
      px0,
      (((clampedMaxX * 0.5 + 0.5) * width).ceil() - 1).clamp(0, width - 1),
    );
    final py0 = ((clampedMinY * 0.5 + 0.5) * height).floor().clamp(
      0,
      height - 1,
    );
    final py1 = math.max(
      py0,
      (((clampedMaxY * 0.5 + 0.5) * height).ceil() - 1).clamp(0, height - 1),
    );

    // Coarse-to-fine Hi-Z test: since mip levels store `max` depths,
    // `maxDepth(mip0_rect) <= maxDepth(mip2_rect)`. If `minZ` exceeds the
    // coarse max + bias, the entire rect is provably occluded in O(1).
    final m2x0 = px0 >> 2;
    final m2x1 = px1 >> 2;
    final m2y0 = py0 >> 2;
    final m2y1 = py1 >> 2;
    var maxM2 = 0.0;
    for (var y = m2y0; y <= m2y1; y++) {
      final row = y * mip2Width;
      for (var x = m2x0; x <= m2x1; x++) {
        final d = depthMip2[row + x];
        if (d > maxM2) {
          maxM2 = d;
        }
      }
    }
    if (minZ > maxM2 + depthBias) {
      _occludedCount++;
      return false;
    }

    final m1x0 = px0 >> 1;
    final m1x1 = px1 >> 1;
    final m1y0 = py0 >> 1;
    final m1y1 = py1 >> 1;
    var maxM1 = 0.0;
    for (var y = m1y0; y <= m1y1; y++) {
      final row = y * mip1Width;
      for (var x = m1x0; x <= m1x1; x++) {
        final d = depthMip1[row + x];
        if (d > maxM1) {
          maxM1 = d;
        }
      }
    }
    if (minZ > maxM1 + depthBias) {
      _occludedCount++;
      return false;
    }

    var maxM0 = 0.0;
    for (var y = py0; y <= py1; y++) {
      final row = y * width;
      for (var x = px0; x <= px1; x++) {
        final d = depthMip0[row + x];
        if (d > maxM0) {
          maxM0 = d;
          if (minZ <= maxM0 + depthBias) {
            return true;
          }
        }
      }
    }

    if (minZ <= maxM0 + depthBias) {
      return true;
    }
    _occludedCount++;
    return false;
  }

  // Six CCW outward faces of the 8 box corners.
  static const List<int> _boxFaceQuads = <int>[
    0, 2, 3, 1, // -Z
    4, 5, 7, 6, // +Z
    0, 4, 6, 2, // -X
    1, 3, 7, 5, // +X
    0, 1, 5, 4, // -Y
    2, 6, 7, 3, // +Y
  ];

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
    _project4(vp, x0, y0, z0, _polyA, 0);
    _project4(vp, x1, y1, z1, _polyA, 4);
    _project4(vp, x2, y2, z2, _polyA, 8);
    _project4(vp, x3, y3, z3, _polyA, 12);

    // Clip against w >= 1e-4 and z >= 0 (near plane).
    final countW = _clipPolygonW(_polyA, 4, _polyB);
    if (countW < 3) {
      return;
    }
    final countZ = _clipPolygonNearZ(_polyB, countW, _polyA);
    if (countZ < 3) {
      return;
    }

    // Convert clipped vertices in `_polyA` to subpixel screen `(sx, sy, ndcZ)`
    // in `_polyB`.
    final halfW = _subWidth * 0.5;
    final halfH = _subHeight * 0.5;
    for (var i = 0; i < countZ; i++) {
      final o = i * 4;
      final invW = 1.0 / _polyA[o + 3];
      _polyB
        ..[o] = (_polyA[o] * invW + 1.0) * halfW
        ..[o + 1] = (_polyA[o + 1] * invW + 1.0) * halfH
        ..[o + 2] = (_polyA[o + 2] * invW).clamp(0.0, 1.0);
    }

    final sx0 = _polyB[0];
    final sy0 = _polyB[1];
    final sz0 = _polyB[2];
    for (var k = 1; k + 1 < countZ; k++) {
      final o1 = k * 4;
      final o2 = (k + 1) * 4;
      _rasterizeScreenTriangle(
        sx0,
        sy0,
        sz0,
        _polyB[o1],
        _polyB[o1 + 1],
        _polyB[o1 + 2],
        _polyB[o2],
        _polyB[o2 + 1],
        _polyB[o2 + 2],
        doubleSided: doubleSided,
      );
    }
  }

  static void _project4(
    Float32List vp,
    double wx,
    double wy,
    double wz,
    Float64List out,
    int offset,
  ) {
    out
      ..[offset] = vp[0] * wx + vp[4] * wy + vp[8] * wz + vp[12]
      ..[offset + 1] = vp[1] * wx + vp[5] * wy + vp[9] * wz + vp[13]
      ..[offset + 2] = vp[2] * wx + vp[6] * wy + vp[10] * wz + vp[14]
      ..[offset + 3] = vp[3] * wx + vp[7] * wy + vp[11] * wz + vp[15];
  }

  static int _clipPolygonW(Float64List src, int count, Float64List dst) {
    const minW = 1e-4;
    var outCount = 0;
    for (var i = 0; i < count; i++) {
      final a = i * 4;
      final b = ((i + 1) % count) * 4;
      final da = src[a + 3] - minW;
      final db = src[b + 3] - minW;
      final aIn = da >= 0;
      final bIn = db >= 0;
      if (aIn) {
        final o = outCount++ * 4;
        dst
          ..[o] = src[a]
          ..[o + 1] = src[a + 1]
          ..[o + 2] = src[a + 2]
          ..[o + 3] = src[a + 3];
      }
      if (aIn != bIn) {
        final t = da / (da - db);
        final o = outCount++ * 4;
        dst
          ..[o] = src[a] + (src[b] - src[a]) * t
          ..[o + 1] = src[a + 1] + (src[b + 1] - src[a + 1]) * t
          ..[o + 2] = src[a + 2] + (src[b + 2] - src[a + 2]) * t
          ..[o + 3] = minW;
      }
    }
    return outCount;
  }

  static int _clipPolygonNearZ(Float64List src, int count, Float64List dst) {
    var outCount = 0;
    for (var i = 0; i < count; i++) {
      final a = i * 4;
      final b = ((i + 1) % count) * 4;
      final da = src[a + 2];
      final db = src[b + 2];
      final aIn = da >= 0;
      final bIn = db >= 0;
      if (aIn) {
        final o = outCount++ * 4;
        dst
          ..[o] = src[a]
          ..[o + 1] = src[a + 1]
          ..[o + 2] = src[a + 2]
          ..[o + 3] = src[a + 3];
      }
      if (aIn != bIn) {
        final t = da / (da - db);
        final o = outCount++ * 4;
        dst
          ..[o] = src[a] + (src[b] - src[a]) * t
          ..[o + 1] = src[a + 1] + (src[b + 1] - src[a + 1]) * t
          ..[o + 2] = 0
          ..[o + 3] = src[a + 3] + (src[b + 3] - src[a + 3]) * t;
      }
    }
    return outCount;
  }

  void _rasterizeScreenTriangle(
    double ax,
    double ay,
    double az,
    double bx,
    double by,
    double bz,
    double cx,
    double cy,
    double cz, {
    required bool doubleSided,
  }) {
    var x1 = bx;
    var y1 = by;
    var z1 = bz;
    var x2 = cx;
    var y2 = cy;
    var z2 = cz;
    var area = (x1 - ax) * (y2 - ay) - (y1 - ay) * (x2 - ax);
    if (!doubleSided && area <= 1e-8) {
      return;
    }
    if (area.abs() <= 1e-8) {
      return;
    }
    if (area < 0) {
      final tx = x1;
      final ty = y1;
      final tz = z1;
      x1 = x2;
      y1 = y2;
      z1 = z2;
      x2 = tx;
      y2 = ty;
      z2 = tz;
      area = -area;
    }

    final minX = math.min(ax, math.min(x1, x2));
    final maxX = math.max(ax, math.max(x1, x2));
    final minY = math.min(ay, math.min(y1, y2));
    final maxY = math.max(ay, math.max(y1, y2));

    final sx0 = math.max(0, (minX - 0.5).ceil());
    final sx1 = math.min(_subWidth - 1, (maxX - 0.5).floor());
    final sy0 = math.max(0, (minY - 0.5).ceil());
    final sy1 = math.min(_subHeight - 1, (maxY - 0.5).floor());
    if (sx0 > sx1 || sy0 > sy1) {
      return;
    }

    final invArea = 1.0 / area;
    final dzdx = ((y1 - y2) * az + (y2 - ay) * z1 + (ay - y1) * z2) * invArea;
    final dzdy = ((x2 - x1) * az + (ax - x2) * z1 + (x1 - ax) * z2) * invArea;
    final slopePad = 0.5 * (dzdx.abs() + dzdy.abs());

    for (var sy = sy0; sy <= sy1; sy++) {
      final py = sy + 0.5;
      final row = sy * _subWidth;
      for (var sx = sx0; sx <= sx1; sx++) {
        final px = sx + 0.5;
        final w0 = (x1 - px) * (y2 - py) - (y1 - py) * (x2 - px);
        if (w0 < -1e-7) {
          continue;
        }
        final w1 = (x2 - px) * (ay - py) - (y2 - py) * (ax - px);
        if (w1 < -1e-7) {
          continue;
        }
        final w2 = (ax - px) * (y1 - py) - (ay - py) * (x1 - px);
        if (w2 < -1e-7) {
          continue;
        }

        final b0 = w0 * invArea;
        final b1 = w1 * invArea;
        final b2 = 1.0 - b0 - b1;
        final zCenter = b0 * az + b1 * z1 + b2 * z2;
        final zConservative = (zCenter + slopePad).clamp(0.0, 1.0);
        final idx = row + sx;
        if (zConservative < _subDepth[idx]) {
          _subDepth[idx] = zConservative;
        }
      }
    }
  }
}

/// Normalized 2D screen scissor rectangle `[minX, minY, maxX, maxY]` in
/// `[0, 1]` produced by [PortalOcclusionGraph3D].
class PortalScissorRect3D(
  final double minX,
  final double minY,
  final double maxX,
  final double maxY,
) {
  /// Whether this scissor has a positive non-empty area.
  bool get isValid => maxX > minX && maxY > minY;
}

/// An indoor room node in a [PortalOcclusionGraph3D].
class OcclusionRoom3D({
  /// Non-negative room identifier.
  required final int id,
  required Aabb3 bounds,

  /// Optional diagnostic label.
  final String? name,
}) {
  /// Creates an indoor visibility room with unique `id` and world `bounds`.
  this : assert(id >= 0, 'Room id must be non-negative');

  /// World-space bounding box of this room.
  final Aabb3 bounds = Aabb3.copy(bounds);
}

/// A convex doorway/window portal connecting [roomA] and [roomB] in a
/// [PortalOcclusionGraph3D].
class OcclusionPortal3D({
  /// First connected room id.
  required final int roomA,

  /// Second connected room id.
  required final int roomB,
  required List<Vector3> vertices,

  /// Whether this portal is open (`false` for closed doors/shutters).
  var bool isOpen = true,
}) {
  /// Creates a portal polygon with world-space `vertices` connecting `roomA`
  /// and `roomB`.
  this : assert(vertices.length >= 3, 'A portal needs at least 3 vertices') {
    var minX = double.infinity;
    var minY = double.infinity;
    var minZ = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    var maxZ = double.negativeInfinity;
    for (final v in this.vertices) {
      minX = math.min(minX, v.x);
      minY = math.min(minY, v.y);
      minZ = math.min(minZ, v.z);
      maxX = math.max(maxX, v.x);
      maxY = math.max(maxY, v.y);
      maxZ = math.max(maxZ, v.z);
    }
    bounds = Aabb3.minMax(
      Vector3(minX - 0.15, minY - 0.15, minZ - 0.15),
      Vector3(maxX + 0.15, maxY + 0.15, maxZ + 0.15),
    );
  }

  /// World-space convex polygon corners of the portal opening.
  final List<Vector3> vertices = List.unmodifiable([
    for (final v in vertices) v.clone(),
  ]);

  /// Inflated world-space bounds used to detect when the camera stands inside
  /// the doorway itself.
  late final Aabb3 bounds;

  /// Convenience factory for an axis-aligned or wall-aligned rectangular door
  /// portal rising `+Y` by [height] from [bottomStart] to [bottomEnd].
  factory OcclusionPortal3D.rect({
    required int roomA,
    required int roomB,
    required Vector3 bottomStart,
    required Vector3 bottomEnd,
    required double height,
    bool isOpen = true,
  }) {
    return OcclusionPortal3D(
      roomA: roomA,
      roomB: roomB,
      vertices: [
        bottomStart,
        bottomEnd,
        Vector3(bottomEnd.x, bottomEnd.y + height, bottomEnd.z),
        Vector3(bottomStart.x, bottomStart.y + height, bottomStart.z),
      ],
      isOpen: isOpen,
    );
  }

  /// Returns the opposite room id across this portal from [roomId].
  int otherRoom(int roomId) => roomId == roomA ? roomB : roomA;
}

/// Recursive indoor portal-room visibility graph narrowing 2D normalized screen
/// scissor rectangles `[minX, minY, maxX, maxY]` across open portals in
/// `O(visible_portals)`.
class PortalOcclusionGraph3D() {
  final Map<int, OcclusionRoom3D> _rooms = <int, OcclusionRoom3D>{};
  final Map<int, List<OcclusionPortal3D>> _adjacency =
      <int, List<OcclusionPortal3D>>{};
  final List<OcclusionPortal3D> _portals = <OcclusionPortal3D>[];

  final Set<int> _visibleRooms = <int>{};
  final Set<int> _activeStack = <int>{};
  Float64List _roomScissors = Float64List(64);
  int _maxRoomId = -1;
  int _traversedPortalCount = 0;

  final Float64List _clipA = Float64List(96);
  final Float64List _clipB = Float64List(96);

  /// Registered rooms by id.
  Iterable<OcclusionRoom3D> get rooms => _rooms.values;

  /// Registered portals.
  List<OcclusionPortal3D> get portals => List.unmodifiable(_portals);

  /// Room ids marked visible during the most recent [evaluateVisibility] call.
  Set<int> get visibleRoomIds => Set.unmodifiable(_visibleRooms);

  /// Number of open portal crossings evaluated in the last traversal.
  int get traversedPortalCount => _traversedPortalCount;

  /// Adds [room] to the visibility graph.
  void addRoom(OcclusionRoom3D room) {
    _rooms[room.id] = room;
    _adjacency.putIfAbsent(room.id, () => <OcclusionPortal3D>[]);
    if (room.id > _maxRoomId) {
      _maxRoomId = room.id;
      final needed = (_maxRoomId + 1) * 4;
      if (_roomScissors.length < needed) {
        _roomScissors = Float64List(math.max(needed, _roomScissors.length * 2));
      }
    }
  }

  /// Connects two rooms via [portal].
  void addPortal(OcclusionPortal3D portal) {
    _portals.add(portal);
    _adjacency
        .putIfAbsent(portal.roomA, () => <OcclusionPortal3D>[])
        .add(portal);
    _adjacency
        .putIfAbsent(portal.roomB, () => <OcclusionPortal3D>[])
        .add(portal);
  }

  /// Clears all rooms and portals.
  void clear() {
    _rooms.clear();
    _adjacency.clear();
    _portals.clear();
    _visibleRooms.clear();
    _activeStack.clear();
    _maxRoomId = -1;
    _traversedPortalCount = 0;
  }

  /// Evaluates room and portal visibility starting from [cameraRoomId] (or any
  /// room whose bounds contain [cameraPosition]).
  void evaluateVisibility({
    required Vector3 cameraPosition,
    required Matrix4 viewProjection,
    int? cameraRoomId,
    int maxPortalDepth = 16,
  }) {
    _visibleRooms.clear();
    _activeStack.clear();
    _traversedPortalCount = 0;

    final limit = (_maxRoomId + 1) * 4;
    for (var i = 0; i < limit; i += 4) {
      _roomScissors
        ..[i] = 1.0
        ..[i + 1] = 1.0
        ..[i + 2] = 0.0
        ..[i + 3] = 0.0;
    }

    if (_rooms.isEmpty) {
      return;
    }

    final startRooms = <int>[];
    if (cameraRoomId != null && _rooms.containsKey(cameraRoomId)) {
      startRooms.add(cameraRoomId);
    } else {
      for (final room in _rooms.values) {
        if (room.bounds.containsVector3(cameraPosition)) {
          startRooms.add(room.id);
        }
      }
    }

    if (startRooms.isEmpty) {
      // Camera is outdoors / outside all registered rooms: mark rooms whose
      // bounds project onscreen as visible roots.
      for (final room in _rooms.values) {
        final rect = _projectAabbNormalized(room.bounds, viewProjection);
        if (rect != null) {
          _expandRoomScissor(
            room.id,
            rect.minX,
            rect.minY,
            rect.maxX,
            rect.maxY,
          );
          _traverse(
            room.id,
            rect.minX,
            rect.minY,
            rect.maxX,
            rect.maxY,
            cameraPosition,
            viewProjection,
            0,
            maxPortalDepth,
          );
        }
      }
      return;
    }

    for (final startId in startRooms) {
      _expandRoomScissor(startId, 0, 0, 1, 1);
      _traverse(
        startId,
        0,
        0,
        1,
        1,
        cameraPosition,
        viewProjection,
        0,
        maxPortalDepth,
      );
    }
  }

  /// Whether [roomId] was reached through aligned open portals.
  bool isRoomVisible(int roomId) => _visibleRooms.contains(roomId);

  /// Returns the accumulated normalized `[0, 1]` screen scissor for [roomId],
  /// or `null` when [roomId] is culled.
  PortalScissorRect3D? roomScissor(int roomId) {
    if (!_visibleRooms.contains(roomId)) {
      return null;
    }
    final b = roomId * 4;
    return PortalScissorRect3D(
      _roomScissors[b],
      _roomScissors[b + 1],
      _roomScissors[b + 2],
      _roomScissors[b + 3],
    );
  }

  /// Tests whether [worldBounds] inside [roomId] is visible through [roomId]'s
  /// narrowed portal screen scissor.
  bool isAabbVisibleInRoom(
    int roomId,
    Aabb3 worldBounds,
    Matrix4 viewProjection,
  ) {
    if (!_visibleRooms.contains(roomId)) {
      return false;
    }
    final rect = _projectAabbNormalized(worldBounds, viewProjection);
    if (rect == null) {
      return false;
    }
    final b = roomId * 4;
    final sMinX = _roomScissors[b];
    final sMinY = _roomScissors[b + 1];
    final sMaxX = _roomScissors[b + 2];
    final sMaxY = _roomScissors[b + 3];
    return rect.maxX > sMinX &&
        rect.minX < sMaxX &&
        rect.maxY > sMinY &&
        rect.minY < sMaxY;
  }

  void _traverse(
    int roomId,
    double sMinX,
    double sMinY,
    double sMaxX,
    double sMaxY,
    Vector3 cameraPos,
    Matrix4 viewProjection,
    int depth,
    int maxDepth,
  ) {
    if (depth >= maxDepth) {
      return;
    }
    final portals = _adjacency[roomId];
    if (portals == null || portals.isEmpty) {
      return;
    }

    _activeStack.add(roomId);
    for (var i = 0; i < portals.length; i++) {
      final portal = portals[i];
      if (!portal.isOpen) {
        continue;
      }
      final nextRoom = portal.otherRoom(roomId);
      if (!_rooms.containsKey(nextRoom) || _activeStack.contains(nextRoom)) {
        continue;
      }

      _traversedPortalCount++;
      double nMinX;
      double nMinY;
      double nMaxX;
      double nMaxY;

      if (portal.bounds.containsVector3(cameraPos)) {
        // Camera stands right in the doorway: pass current scissor unchanged.
        nMinX = sMinX;
        nMinY = sMinY;
        nMaxX = sMaxX;
        nMaxY = sMaxY;
      } else {
        final pRect = _projectPortalNormalized(portal, viewProjection);
        if (pRect == null) {
          continue;
        }
        nMinX = math.max(sMinX, pRect.minX);
        nMinY = math.max(sMinY, pRect.minY);
        nMaxX = math.min(sMaxX, pRect.maxX);
        nMaxY = math.min(sMaxY, pRect.maxY);
      }

      if (nMinX >= nMaxX || nMinY >= nMaxY) {
        continue;
      }

      if (_expandRoomScissor(nextRoom, nMinX, nMinY, nMaxX, nMaxY)) {
        _traverse(
          nextRoom,
          nMinX,
          nMinY,
          nMaxX,
          nMaxY,
          cameraPos,
          viewProjection,
          depth + 1,
          maxDepth,
        );
      } else {
        // Even if nextRoom's union didn't grow, a distinct sub-beam might align
        // with a downstream portal if not previously covered; `_expand` returns
        // false only when `[nMin..nMax]` is already contained in nextRoom's
        // visited scissor!
      }
    }
    _activeStack.remove(roomId);
  }

  /// Unions `[minX, minY, maxX, maxY]` into [roomId]'s scissor and returns
  /// `true` if the room became newly visible or its scissor expanded.
  bool _expandRoomScissor(
    int roomId,
    double minX,
    double minY,
    double maxX,
    double maxY,
  ) {
    final b = roomId * 4;
    final wasVisible = _visibleRooms.add(roomId);
    if (wasVisible) {
      _roomScissors
        ..[b] = minX
        ..[b + 1] = minY
        ..[b + 2] = maxX
        ..[b + 3] = maxY;
      return true;
    }

    final curMinX = _roomScissors[b];
    final curMinY = _roomScissors[b + 1];
    final curMaxX = _roomScissors[b + 2];
    final curMaxY = _roomScissors[b + 3];
    if (minX >= curMinX - 1e-6 &&
        minY >= curMinY - 1e-6 &&
        maxX <= curMaxX + 1e-6 &&
        maxY <= curMaxY + 1e-6) {
      return false;
    }
    _roomScissors
      ..[b] = math.min(curMinX, minX)
      ..[b + 1] = math.min(curMinY, minY)
      ..[b + 2] = math.max(curMaxX, maxX)
      ..[b + 3] = math.max(curMaxY, maxY);
    return true;
  }

  PortalScissorRect3D? _projectPortalNormalized(
    OcclusionPortal3D portal,
    Matrix4 viewProjection,
  ) {
    final verts = portal.vertices;
    final count = math.min(verts.length, 16);
    final vp = viewProjection.storage;

    for (var i = 0; i < count; i++) {
      final v = verts[i];
      final o = i * 4;
      _clipA
        ..[o] = vp[0] * v.x + vp[4] * v.y + vp[8] * v.z + vp[12]
        ..[o + 1] = vp[1] * v.x + vp[5] * v.y + vp[9] * v.z + vp[13]
        ..[o + 2] = vp[2] * v.x + vp[6] * v.y + vp[10] * v.z + vp[14]
        ..[o + 3] = vp[3] * v.x + vp[7] * v.y + vp[11] * v.z + vp[15];
    }

    final nW = OcclusionCuller3D._clipPolygonW(_clipA, count, _clipB);
    if (nW < 3) {
      return null;
    }
    final nZ = OcclusionCuller3D._clipPolygonNearZ(_clipB, nW, _clipA);
    if (nZ < 3) {
      return null;
    }

    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    var minDepth = double.infinity;

    for (var i = 0; i < nZ; i++) {
      final o = i * 4;
      final invW = 1.0 / _clipA[o + 3];
      final sx = _clipA[o] * invW * 0.5 + 0.5;
      final sy = _clipA[o + 1] * invW * 0.5 + 0.5;
      final sz = _clipA[o + 2] * invW;
      minX = math.min(minX, sx);
      maxX = math.max(maxX, sx);
      minY = math.min(minY, sy);
      maxY = math.max(maxY, sy);
      minDepth = math.min(minDepth, sz);
    }

    if (minDepth > 1.0 || maxX <= 0.0 || minX >= 1.0 || maxY <= 0.0) {
      return null;
    }
    if (minY >= 1.0) {
      return null;
    }

    final cMinX = minX.clamp(0.0, 1.0);
    final cMinY = minY.clamp(0.0, 1.0);
    final cMaxX = maxX.clamp(0.0, 1.0);
    final cMaxY = maxY.clamp(0.0, 1.0);
    if (cMinX >= cMaxX || cMinY >= cMaxY) {
      return null;
    }
    return PortalScissorRect3D(cMinX, cMinY, cMaxX, cMaxY);
  }

  static PortalScissorRect3D? _projectAabbNormalized(
    Aabb3 box,
    Matrix4 viewProjection,
  ) {
    final vp = viewProjection.storage;
    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    var maxZ = double.negativeInfinity;
    var minZ = double.infinity;

    for (var c = 0; c < 8; c++) {
      final wx = (c & 1) == 0 ? box.min.x : box.max.x;
      final wy = (c & 2) == 0 ? box.min.y : box.max.y;
      final wz = (c & 4) == 0 ? box.min.z : box.max.z;
      final cx = vp[0] * wx + vp[4] * wy + vp[8] * wz + vp[12];
      final cy = vp[1] * wx + vp[5] * wy + vp[9] * wz + vp[13];
      final cz = vp[2] * wx + vp[6] * wy + vp[10] * wz + vp[14];
      final cw = vp[3] * wx + vp[7] * wy + vp[11] * wz + vp[15];
      if (cw <= 1e-5 || cz < 0) {
        return PortalScissorRect3D(0, 0, 1, 1);
      }
      final invW = 1.0 / cw;
      final sx = cx * invW * 0.5 + 0.5;
      final sy = cy * invW * 0.5 + 0.5;
      final sz = cz * invW;
      minX = math.min(minX, sx);
      maxX = math.max(maxX, sx);
      minY = math.min(minY, sy);
      maxY = math.max(maxY, sy);
      minZ = math.min(minZ, sz);
      maxZ = math.max(maxZ, sz);
    }

    if (maxZ < 0 || minZ > 1 || maxX <= 0 || minX >= 1 || maxY <= 0) {
      return null;
    }
    if (minY >= 1) {
      return null;
    }
    final cMinX = minX.clamp(0.0, 1.0);
    final cMinY = minY.clamp(0.0, 1.0);
    final cMaxX = maxX.clamp(0.0, 1.0);
    final cMaxY = maxY.clamp(0.0, 1.0);
    if (cMinX >= cMaxX || cMinY >= cMaxY) {
      return null;
    }
    return PortalScissorRect3D(cMinX, cMinY, cMaxX, cMaxY);
  }
}
