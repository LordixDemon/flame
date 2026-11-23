import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Color, Rect;

import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/src/components/instance_buffer_3d.dart';
import 'package:flame_3d/src/extensions/clip_space.dart';
import 'package:flame_3d/src/resources/mesh/unit_quad_surface.dart';

/// {@template decal_batch_3d}
/// Draws many flat 3D surface decals in a single instanced draw call using
/// [DecalMaterial].
///
/// Each decal sits on a unit quad in its local XY plane (`[-0.5, 0.5]^2`),
/// oriented and scaled by its 3D transform (or placed with [addFlatDecal] for
/// ground/floor decals aligned to an arbitrary plane), with its own color and
/// optional normalized UV sub-rectangle (`0..1`) into an atlas texture.
///
/// The decals are drawn in the order they were added, unless
/// [sortByDepth] is set: overlapping translucent decals then blend back to
/// front.
/// {@endtemplate}
class DecalBatch3D({
  DecalMaterial? material,
  int initialCapacity = 16,
  bool sortByDepth = false,
  super.position,
  super.scale,
  super.rotation,
  super.children,
}) extends Object3D {
  /// {@macro decal_batch_3d}
  this : super(castsShadows: false);

  /// The material shared by all decals in this batch.
  final DecalMaterial material = material ?? DecalMaterial();

  final InstanceBuffer3D _buffer = InstanceBuffer3D(
    initialCapacity: initialCapacity,
  );

  /// Whether the decals are drawn back to front, from the farthest from the
  /// camera of the pass to the nearest (by the depth of their centers), so
  /// that overlapping translucent decals blend in the right order whatever
  /// order they were added in. With `false` (the default) they are drawn in
  /// the order they were added.
  ///
  /// The order is computed again only when the camera of the pass or the
  /// decals changed (one sort per change, `O(n log n)`, without allocating
  /// after the first), into a second instance buffer of the batch's
  /// capacity. Decals at the same depth keep the order they were added in.
  bool get sortByDepth => _sortByDepth;
  set sortByDepth(bool value) {
    if (value == _sortByDepth) {
      return;
    }
    _sortByDepth = value;
    _sortedValid = false;
    worldOrNull?.markSceneDirty(shadows: false);
  }

  bool _sortByDepth = sortByDepth;

  /// The number of times the decals were sorted by depth, see
  /// [sortByDepth], for tests and profiling.
  int get sortCount => _sortCount;
  int _sortCount = 0;

  static const int _stride = InstanceBuffer3D.stride;

  final Aabb3 _localAabb = Aabb3();
  bool _localBoundsDirty = true;

  /// Number of decals currently in the batch.
  int get length => _buffer.length;

  /// Whether the batch has no decals.
  bool get isEmpty => _buffer.isEmpty;

  /// Appends a decal with an arbitrary 3D [transform] (mapping the unit XY quad
  /// `[-0.5, 0.5]^2` into the batch's local space) and returns its index.
  int addDecal({
    required Matrix4 transform,
    Color color = const Color(0xFFFFFFFF),
    Rect? uvRect,
  }) {
    final index = _buffer.append(
      transform,
      color,
      uvRect?.left ?? 0,
      uvRect?.top ?? 0,
      uvRect?.width ?? 0,
      uvRect?.height ?? 0,
    );
    _invalidate();
    return index;
  }

  /// Convenience helper that places a decal at [center] oriented by [normal]
  /// (defaults to `(0, 1, 0)` Y-up; pass `(0, 0, 1)` for Z-up boards), rotated
  /// in-plane by [angle] radians and sized `(width, height)`.
  int addFlatDecal({
    required Vector3 center,
    double width = 1.0,
    double height = 1.0,
    double angle = 0.0,
    Vector3? normal,
    Color color = const Color(0xFFFFFFFF),
    Rect? uvRect,
  }) {
    _composeFlatMatrix(_scratch, center, width, height, angle, normal);
    return addDecal(transform: _scratch, color: color, uvRect: uvRect);
  }

  /// Updates the decal at [index] in place.
  void setDecal(
    int index, {
    Matrix4? transform,
    Color? color,
    Rect? uvRect,
  }) {
    RangeError.checkValidIndex(index, this, 'index', _buffer.length);
    _buffer.update(
      index,
      transform: transform,
      color: color,
      d0: uvRect?.left,
      d1: uvRect?.top,
      d2: uvRect?.width,
      d3: uvRect?.height,
    );
    if (transform != null) {
      _localBoundsDirty = true;
      markAabbDirty();
    }
    worldOrNull?.markSceneDirty(shadows: false);
  }

  /// Places a height-attenuated circular mobile drop-shadow decal at
  /// [groundPoint] for an object floating [elevation] world units above it:
  /// expands slightly and fades out smoothly up to [maxElevation].
  int? addBlobShadow({
    required Vector3 groundPoint,
    required double radius,
    double elevation = 0.0,
    double maxElevation = 4.0,
    double baseOpacity = 0.55,
    Color shadowColor = const Color(0xFF0A0F1E),
    Vector3? normal,
  }) {
    final h = math.max(0.0, elevation);
    if (maxElevation > 0 && h >= maxElevation) {
      return null;
    }
    final t = maxElevation > 0 ? (h / maxElevation).clamp(0.0, 1.0) : 0.0;
    final fade = (1.0 - t) * (1.0 - t);
    final alpha = (baseOpacity * fade).clamp(0.0, 1.0);
    if (alpha <= 0.005) {
      return null;
    }
    final diameter = radius * 2.0 * (1.0 + 0.45 * t);
    final c = Color.fromARGB(
      (alpha * 255).round(),
      (shadowColor.r * 255).round(),
      (shadowColor.g * 255).round(),
      (shadowColor.b * 255).round(),
    );
    return addFlatDecal(
      center: groundPoint,
      width: diameter,
      height: diameter,
      normal: normal,
      color: c,
    );
  }

  /// Removes the decal at [index] in `O(1)` by swapping with the last entry.
  void removeAtSwapLast(int index) {
    RangeError.checkValidIndex(index, this, 'index', _buffer.length);
    _buffer.removeAtSwapLast(index);
    _invalidate();
  }

  /// Removes all decals without freeing capacity.
  void clear() {
    if (!_buffer.clear()) {
      return;
    }
    _invalidate();
  }

  @override
  bool get usesDefaultFrustumVisibility => runtimeType == DecalBatch3D;

  @override
  Aabb3? computeLocalAabb() {
    final count = _buffer.length;
    if (count == 0) {
      return null;
    }
    if (_localBoundsDirty) {
      _localBoundsDirty = false;
      final instances = _buffer.localData;
      var minX = double.infinity;
      var minY = double.infinity;
      var minZ = double.infinity;
      var maxX = double.negativeInfinity;
      var maxY = double.negativeInfinity;
      var maxZ = double.negativeInfinity;
      for (var idx = 0; idx < count; idx++) {
        final b = idx * _stride;
        for (var corner = 0; corner < 4; corner++) {
          final cx = (corner & 1) == 0 ? -0.5 : 0.5;
          final cy = (corner & 2) == 0 ? -0.5 : 0.5;
          final wx =
              instances[b] * cx + instances[b + 4] * cy + instances[b + 12];
          final wy =
              instances[b + 1] * cx + instances[b + 5] * cy + instances[b + 13];
          final wz =
              instances[b + 2] * cx + instances[b + 6] * cy + instances[b + 14];
          minX = math.min(minX, wx);
          minY = math.min(minY, wy);
          minZ = math.min(minZ, wz);
          maxX = math.max(maxX, wx);
          maxY = math.max(maxY, wy);
          maxZ = math.max(maxZ, wz);
        }
      }
      _localAabb
        ..min.setValues(minX - 1e-3, minY - 1e-3, minZ - 1e-3)
        ..max.setValues(maxX + 1e-3, maxY + 1e-3, maxZ + 1e-3);
    }
    return _localAabb;
  }

  @override
  void draw(covariant RenderContext3D context) {
    final count = _buffer.length;
    if (count == 0 || context.isShadowPass) {
      return;
    }
    // Sorted among the translucent draws at the center of the decals.
    final local = computeLocalAabb()!;
    final center = _drawCenter
      ..setFrom(local.min)
      ..add(local.max)
      ..scale(0.5);
    final world = worldTransformMatrix;
    final worldVer = worldTransformVersion;
    world.transform3(center);
    final buffer = _buffer.resolveWorld(world, worldVer);
    context.drawInstances(
      unitQuadSurface3D,
      instances: _sortByDepth
          ? _sortedBuffer(buffer, worldVer, context)
          : buffer,
      count: count,
      material: material,
      center: center,
    );
  }

  final Vector3 _drawCenter = Vector3.zero();

  // The decals of [_buffer] back to front, see [sortByDepth], and what they
  // were sorted for.
  Float32List? _sorted;
  Int32List _order = Int32List(0);
  Int32List _orderScratch = Int32List(0);
  Float64List _sortDepths = Float64List(0);
  bool _sortedValid = false;
  int _sortedVersion = -1;
  int _sortedWorldVer = -1;
  Float32List? _sortedSource;
  final Float32List _sortedViewProjection = Float32List(16);

  /// The decals of [source] (in world space) from the farthest to the
  /// nearest for the camera of [context], sorted again only when the camera,
  /// the decals or the batch's transform changed.
  Float32List _sortedBuffer(
    Float32List source,
    int worldVer,
    RenderContext3D context,
  ) {
    final count = _buffer.length;
    final localVer = _buffer.localVersion;
    final cap = _buffer.capacity;
    final viewProjection = context.viewProjection.storage;
    var sorted = _sorted;
    if (sorted == null || sorted.length < count * _stride) {
      sorted = _sorted = Float32List(cap * _stride);
      _order = Int32List(cap);
      _orderScratch = Int32List(cap);
      _sortDepths = Float64List(cap);
      _sortedValid = false;
    }
    if (_sortedValid &&
        _sortedVersion == localVer &&
        identical(_sortedSource, source) &&
        _sortedWorldVer == worldVer &&
        sameMatrix16(_sortedViewProjection, viewProjection)) {
      return sorted;
    }
    _sortedValid = true;
    _sortedVersion = localVer;
    _sortedSource = source;
    _sortedWorldVer = worldVer;
    _sortedViewProjection.setAll(0, viewProjection);
    _sortCount++;

    // The depth the render context sorts translucent draws by: clip w under
    // a perspective projection, clip z otherwise, larger farther.
    final m = viewProjection;
    final perspective = m[3] * m[3] + m[7] * m[7] + m[11] * m[11] > 1e-12;
    final row = perspective ? 3 : 2;
    final d0 = m[row];
    final d1 = m[4 + row];
    final d2 = m[8 + row];
    final d3 = m[12 + row];
    final order = _order;
    final depths = _sortDepths;
    for (var i = 0; i < count; i++) {
      final b = i * _stride;
      // The center of the decal is the translation of its matrix.
      depths[i] =
          d0 * source[b + 12] +
          d1 * source[b + 13] +
          d2 * source[b + 14] +
          d3 * source[b + 15];
      order[i] = i;
    }
    _mergeSortFarthestFirst(order, _orderScratch, depths, count);
    for (var i = 0; i < count; i++) {
      final from = order[i] * _stride;
      sorted.setRange(i * _stride, (i + 1) * _stride, source, from);
    }
    return sorted;
  }

  /// Sorts the first [count] indices of [order] by decreasing [depths],
  /// keeping the order of equal depths, with [scratch] as the second buffer
  /// of a bottom-up merge sort.
  static void _mergeSortFarthestFirst(
    Int32List order,
    Int32List scratch,
    Float64List depths,
    int count,
  ) {
    var from = order;
    var to = scratch;
    for (var width = 1; width < count; width *= 2) {
      for (var left = 0; left < count; left += 2 * width) {
        final mid = math.min(left + width, count);
        final right = math.min(left + 2 * width, count);
        var i = left;
        var j = mid;
        var k = left;
        while (i < mid && j < right) {
          // Strictly nearer on the right goes after: ties keep their order.
          if (depths[from[j]] > depths[from[i]]) {
            to[k++] = from[j++];
          } else {
            to[k++] = from[i++];
          }
        }
        while (i < mid) {
          to[k++] = from[i++];
        }
        while (j < right) {
          to[k++] = from[j++];
        }
      }
      final swap = from;
      from = to;
      to = swap;
    }
    if (!identical(from, order)) {
      order.setRange(0, count, from);
    }
  }

  void _invalidate() {
    _localBoundsDirty = true;
    markAabbDirty();
    worldOrNull?.markSceneDirty(shadows: false);
  }

  static void _composeFlatMatrix(
    Matrix4 out,
    Vector3 center,
    double width,
    double height,
    double angle,
    Vector3? normal,
  ) {
    var nx = normal?.x ?? 0.0;
    var ny = normal?.y ?? 1.0;
    var nz = normal?.z ?? 0.0;
    final nLen = math.sqrt(nx * nx + ny * ny + nz * nz);
    if (nLen > 1e-12) {
      nx /= nLen;
      ny /= nLen;
      nz /= nLen;
    } else {
      nx = 0.0;
      ny = 1.0;
      nz = 0.0;
    }

    // Build an orthonormal tangent basis `(tx, ty, tz)` x `(bx, by, bz)` in
    // the decal plane perpendicular to `n`.
    final refX = nx.abs() < 0.9 ? 1.0 : 0.0;
    final refY = nx.abs() < 0.9 ? 0.0 : 1.0;
    var tx = refY * nz;
    var ty = -refX * nz;
    var tz = refX * ny - refY * nx;
    final tLen = math.sqrt(tx * tx + ty * ty + tz * tz);
    tx /= tLen;
    ty /= tLen;
    tz /= tLen;

    final bx = ny * tz - nz * ty;
    final by = nz * tx - nx * tz;
    final bz = nx * ty - ny * tx;

    final c = math.cos(angle);
    final s = math.sin(angle);
    final ux = (c * tx + s * bx) * width;
    final uy = (c * ty + s * by) * width;
    final uz = (c * tz + s * bz) * width;
    final vx = (-s * tx + c * bx) * height;
    final vy = (-s * ty + c * by) * height;
    final vz = (-s * tz + c * bz) * height;

    out.storage
      ..[0] = ux
      ..[1] = uy
      ..[2] = uz
      ..[3] = 0.0
      ..[4] = vx
      ..[5] = vy
      ..[6] = vz
      ..[7] = 0.0
      ..[8] = nx
      ..[9] = ny
      ..[10] = nz
      ..[11] = 0.0
      ..[12] = center.x
      ..[13] = center.y
      ..[14] = center.z
      ..[15] = 1.0;
  }

  static final Matrix4 _scratch = Matrix4.identity();
}
