import 'dart:collection' show UnmodifiableListView;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame_3d/camera.dart' show SceneOcclusionCuller3D;
import 'package:flame_3d/core.dart';
import 'package:flame_3d/src/extensions/clip_space.dart';

part 'occlusion_culler_rasterizer.dart';

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
/// max-depth mips (`64 x 32` and `32 x 16`).
///
/// The rasterization is conservative: a subpixel takes an occluder's depth
/// only when the whole subpixel square lies inside the occluder's projection
/// (a quad, or the silhouette of a box), and it takes the farthest depth the
/// occluder has over that square. A pixel is therefore occluded only where it
/// is entirely covered, and [isAabbVisible] may fail to cull an object, but
/// never reports a visible one hidden. Each occluder covers on its own: a gap
/// between two occluders, however narrow, is not filled.
class OcclusionCuller3D({
  /// Base Hi-Z buffer width (`128` by default).
  final int width = 128,

  /// Base Hi-Z buffer height (`64` by default).
  final int height = 64,
}) implements SceneOcclusionCuller3D {
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

  // The convex screen-space polygon being rasterized, in subpixels: up to 16
  // (x, y) vertices, counter-clockwise.
  final Float64List _screenPoly = Float64List(32);
  // Its edge functions: (a, b, c) with `a * x + b * y + c >= 0` when the
  // subpixel square centered on (x, y) is inside the edge.
  final Float64List _edges = Float64List(48);
  // Its depth planes: (a, b, c) with `a * x + b * y + c` the farthest depth
  // of the plane over the subpixel square centered on (x, y).
  final Float64List _planes = Float64List(18);
  // The eight projected box corners (x, y, z) and the hull scratch.
  final Float64List _boxScreen = Float64List(24);
  final Int32List _hullOrder = Int32List(8);
  final Int32List _hull = Int32List(17);
  final Float64List _rowPlaneBase = Float64List(6);

  int _testedCount = 0;
  int _occludedCount = 0;
  int _rasterizedOccluderCount = 0;

  /// Number of [isAabbVisible] queries executed since the last [clearDepth] /
  /// [rasterizeOccluders].
  int get testedCount => _testedCount;

  /// Number of [isAabbVisible] queries culled as 100% occluded behind walls.
  int get occludedCount => _occludedCount;

  /// Number of occluder primitives rasterized in the current frame.
  @override
  int get rasterizedOccluderCount => _rasterizedOccluderCount;

  /// Whether at least one box or quad occluder is registered.
  @override
  bool get hasOccluders => _boxes.isNotEmpty || _quads.isNotEmpty;

  late final List<OccluderBox3D> _boxesView = UnmodifiableListView(_boxes);
  late final List<OccluderQuad3D> _quadsView = UnmodifiableListView(_quads);

  /// Registered box occluders.
  List<OccluderBox3D> get boxes => _boxesView;

  /// Registered quad occluders.
  List<OccluderQuad3D> get quads => _quadsView;

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
  @override
  void rasterizeOccluders(Matrix4 viewProjection) {
    _subDepth.fillRange(0, _subDepth.length, 1.0);
    _testedCount = 0;
    _occludedCount = 0;
    _rasterizedOccluderCount = 0;
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
  @override
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
    var occludedM2 = true;
    mip2Loop:
    for (var y = m2y0; y <= m2y1; y++) {
      final row = y * mip2Width;
      for (var x = m2x0; x <= m2x1; x++) {
        if (minZ <= depthMip2[row + x] + depthBias) {
          occludedM2 = false;
          break mip2Loop;
        }
      }
    }
    if (occludedM2) {
      _occludedCount++;
      return false;
    }

    final m1x0 = px0 >> 1;
    final m1x1 = px1 >> 1;
    final m1y0 = py0 >> 1;
    final m1y1 = py1 >> 1;
    var occludedM1 = true;
    mip1Loop:
    for (var y = m1y0; y <= m1y1; y++) {
      final row = y * mip1Width;
      for (var x = m1x0; x <= m1x1; x++) {
        if (minZ <= depthMip1[row + x] + depthBias) {
          occludedM1 = false;
          break mip1Loop;
        }
      }
    }
    if (occludedM1) {
      _occludedCount++;
      return false;
    }

    for (var y = py0; y <= py1; y++) {
      final row = y * width;
      for (var x = px0; x <= px1; x++) {
        if (minZ <= depthMip0[row + x] + depthBias) {
          return true;
        }
      }
    }

    _occludedCount++;
    return false;
  }

  // Six CCW outward faces of the 8 box corners.
}
