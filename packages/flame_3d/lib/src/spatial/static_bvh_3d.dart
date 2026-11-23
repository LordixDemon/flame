import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame_3d/core.dart';
import 'package:meta/meta.dart';

/// Shared flat median-split Bounding Volume Hierarchy over indexed 3D
/// primitives (`Float32List` bounds stride 6 + `Int32List` indices).
///
/// Used by both mesh surface BVHs and navigation-mesh polygon BVHs so build,
/// slab ray/line culling, AABB queries, and nearest-box distance stay in one
/// zero-allocation implementation.
@internal
class StaticBvh3D {
  /// Builds a median-split longest-centroid-axis hierarchy for [primitiveCount]
  /// items described by stride-6 [primitiveBounds] and stride-3 [centroids].
  factory StaticBvh3D.build({
    required int primitiveCount,
    required Float32List primitiveBounds,
    required Float32List centroids,
    int maxLeafPrimitives = 4,
  }) {
    if (maxLeafPrimitives < 1) {
      throw ArgumentError.value(
        maxLeafPrimitives,
        'maxLeafPrimitives',
        'Must be at least 1',
      );
    }
    if (primitiveCount <= 0) {
      return StaticBvh3D.empty();
    }

    final indices = Int32List(primitiveCount);
    for (var i = 0; i < primitiveCount; i++) {
      indices[i] = i;
    }

    final maxNodes = math.max(1, primitiveCount * 2);
    final bounds = Float32List(maxNodes * 6);
    final leftOrFirst = Int32List(maxNodes);
    final rightChild = Int32List(maxNodes);
    final counts = Int32List(maxNodes);
    var nodeCount = 0;

    int buildNode(int start, int count) {
      final node = nodeCount++;
      var minX = double.infinity;
      var minY = double.infinity;
      var minZ = double.infinity;
      var maxX = double.negativeInfinity;
      var maxY = double.negativeInfinity;
      var maxZ = double.negativeInfinity;
      var cMinX = double.infinity;
      var cMinY = double.infinity;
      var cMinZ = double.infinity;
      var cMaxX = double.negativeInfinity;
      var cMaxY = double.negativeInfinity;
      var cMaxZ = double.negativeInfinity;

      for (var i = start; i < start + count; i++) {
        final p = indices[i];
        final pb = p * 6;
        minX = math.min(minX, primitiveBounds[pb]);
        minY = math.min(minY, primitiveBounds[pb + 1]);
        minZ = math.min(minZ, primitiveBounds[pb + 2]);
        maxX = math.max(maxX, primitiveBounds[pb + 3]);
        maxY = math.max(maxY, primitiveBounds[pb + 4]);
        maxZ = math.max(maxZ, primitiveBounds[pb + 5]);

        final cb = p * 3;
        final cx = centroids[cb];
        final cy = centroids[cb + 1];
        final cz = centroids[cb + 2];
        cMinX = math.min(cMinX, cx);
        cMinY = math.min(cMinY, cy);
        cMinZ = math.min(cMinZ, cz);
        cMaxX = math.max(cMaxX, cx);
        cMaxY = math.max(cMaxY, cy);
        cMaxZ = math.max(cMaxZ, cz);
      }

      final nb = node * 6;
      bounds
        ..[nb] = minX
        ..[nb + 1] = minY
        ..[nb + 2] = minZ
        ..[nb + 3] = maxX
        ..[nb + 4] = maxY
        ..[nb + 5] = maxZ;

      if (count <= maxLeafPrimitives) {
        leftOrFirst[node] = start;
        counts[node] = count;
        return node;
      }

      final extX = cMaxX - cMinX;
      final extY = cMaxY - cMinY;
      final extZ = cMaxZ - cMinZ;
      var axis = 0;
      var split = 0.5 * (cMinX + cMaxX);
      var extent = extX;
      if (extY > extent) {
        axis = 1;
        split = 0.5 * (cMinY + cMaxY);
        extent = extY;
      }
      if (extZ > extent) {
        axis = 2;
        split = 0.5 * (cMinZ + cMaxZ);
        extent = extZ;
      }

      int mid;
      if (extent <= 1e-12) {
        mid = start + (count >> 1);
      } else {
        var i = start;
        var j = start + count - 1;
        while (i <= j) {
          if (centroids[indices[i] * 3 + axis] < split) {
            i++;
          } else {
            final tmp = indices[i];
            indices[i] = indices[j];
            indices[j] = tmp;
            j--;
          }
        }
        mid = i;
        if (mid == start || mid == start + count) {
          mid = start + (count >> 1);
        }
      }

      counts[node] = 0;
      leftOrFirst[node] = buildNode(start, mid - start);
      rightChild[node] = buildNode(mid, start + count - mid);
      return node;
    }

    buildNode(0, primitiveCount);

    return StaticBvh3D._(
      nodeCount: nodeCount,
      primitiveCount: primitiveCount,
      bounds: Float32List.sublistView(bounds, 0, nodeCount * 6),
      leftOrFirst: Int32List.sublistView(leftOrFirst, 0, nodeCount),
      rightChild: Int32List.sublistView(rightChild, 0, nodeCount),
      counts: Int32List.sublistView(counts, 0, nodeCount),
      primitives: indices,
    );
  }

  /// Wraps prebuilt flat BVH buffers (for example produced on a worker
  /// isolate).
  factory StaticBvh3D.fromPrepared({
    required int nodeCount,
    required int primitiveCount,
    required Float32List bounds,
    required Int32List leftOrFirst,
    required Int32List rightChild,
    required Int32List counts,
    required Int32List primitives,
  }) {
    if (primitiveCount == 0 || nodeCount == 0) {
      return StaticBvh3D.empty();
    }
    if (bounds.length < nodeCount * 6 ||
        leftOrFirst.length < nodeCount ||
        rightChild.length < nodeCount ||
        counts.length < nodeCount ||
        primitives.length != primitiveCount) {
      throw ArgumentError(
        'Prepared BVH does not match primitive count: $nodeCount nodes, '
        '${primitives.length} primitives (expected $primitiveCount)',
      );
    }
    return StaticBvh3D._(
      nodeCount: nodeCount,
      primitiveCount: primitiveCount,
      bounds: bounds,
      leftOrFirst: leftOrFirst,
      rightChild: rightChild,
      counts: counts,
      primitives: primitives,
    );
  }

  /// Creates an empty BVH with zero nodes and zero primitives.
  StaticBvh3D.empty()
    : nodeCount = 0,
      primitiveCount = 0,
      bounds = Float32List(0),
      leftOrFirst = Int32List(0),
      rightChild = Int32List(0),
      counts = Int32List(0),
      primitives = Int32List(0);

  StaticBvh3D._({
    required this.nodeCount,
    required this.primitiveCount,
    required this.bounds,
    required this.leftOrFirst,
    required this.rightChild,
    required this.counts,
    required this.primitives,
  });

  /// Number of nodes in the flat tree (`0` when empty).
  final int nodeCount;

  /// Number of indexed primitives.
  final int primitiveCount;

  /// Contiguous node bounds `[minX, minY, minZ, maxX, maxY, maxZ]` per node.
  final Float32List bounds;

  /// Left child node index for inner nodes, or first primitive slot for leaves.
  final Int32List leftOrFirst;

  /// Right child node index for inner nodes.
  final Int32List rightChild;

  /// Number of primitives in a leaf (`0` for inner nodes).
  final Int32List counts;

  /// Reordered primitive indices referenced by leaf spans.
  final Int32List primitives;

  /// Whether this BVH contains zero primitives.
  bool get isEmpty => nodeCount == 0;

  Int32List _queryStack = Int32List(128);
  bool _inQuery = false;

  /// Doubles an integer traversal stack while preserving the active prefix
  /// `[0 .. used)`.
  static Int32List growStack(Int32List current, int used) {
    final grown = Int32List(current.length * 2)..setRange(0, used, current);
    return grown;
  }

  /// Appends indices of all primitives whose leaf bounds overlap [box]
  /// (optionally expanded by [padding]) into [outPrimitives], returning the
  /// resulting length of [outPrimitives].
  int queryAabb(
    Aabb3 box,
    List<int> outPrimitives, {
    double padding = 0.0,
  }) {
    return queryAabbExtents(
      box.min.x,
      box.min.y,
      box.min.z,
      box.max.x,
      box.max.y,
      box.max.z,
      outPrimitives,
      padding: padding,
    );
  }

  /// Appends indices of all primitives whose leaf bounds overlap the AABB
  /// `[minX..maxX] x [minY..maxY] x [minZ..maxZ]` (expanded by [padding]) into
  /// [outPrimitives], returning the resulting length of [outPrimitives].
  int queryAabbExtents(
    double minX,
    double minY,
    double minZ,
    double maxX,
    double maxY,
    double maxZ,
    List<int> outPrimitives, {
    double padding = 0.0,
  }) {
    if (nodeCount == 0) {
      return outPrimitives.length;
    }
    final qMinX = minX - padding;
    final qMinY = minY - padding;
    final qMinZ = minZ - padding;
    final qMaxX = maxX + padding;
    final qMaxY = maxY + padding;
    final qMaxZ = maxZ + padding;

    final reentrant = _inQuery;
    var stack = reentrant ? Int32List(128) : _queryStack;
    if (!reentrant) {
      _inQuery = true;
    }
    try {
      var sp = 0;
      stack[sp++] = 0;
      while (sp > 0) {
        final node = stack[--sp];
        final nb = node * 6;
        if (bounds[nb] > qMaxX ||
            bounds[nb + 3] < qMinX ||
            bounds[nb + 1] > qMaxY ||
            bounds[nb + 4] < qMinY ||
            bounds[nb + 2] > qMaxZ ||
            bounds[nb + 5] < qMinZ) {
          continue;
        }
        final cnt = counts[node];
        if (cnt > 0) {
          final start = leftOrFirst[node];
          for (var i = start; i < start + cnt; i++) {
            outPrimitives.add(primitives[i]);
          }
        } else {
          if (sp + 2 > stack.length) {
            stack = growStack(stack, sp);
            if (!reentrant) {
              _queryStack = stack;
            }
          }
          stack[sp++] = rightChild[node];
          stack[sp++] = leftOrFirst[node];
        }
      }
    } finally {
      if (!reentrant) {
        _inQuery = false;
      }
    }
    return outPrimitives.length;
  }

  /// Appends indices of all primitives whose leaf bounds are crossed by the
  /// infinite line passing through `(ox, oy, oz)` along `(dx, dy, dz)`.
  void queryLine(
    double ox,
    double oy,
    double oz,
    double dx,
    double dy,
    double dz,
    List<int> outPrimitives, {
    double padding = 1e-4,
  }) {
    if (nodeCount == 0) {
      return;
    }
    final invX = dx.abs() > 1e-12 ? 1.0 / dx : 0.0;
    final invY = dy.abs() > 1e-12 ? 1.0 / dy : 0.0;
    final invZ = dz.abs() > 1e-12 ? 1.0 / dz : 0.0;

    final reentrant = _inQuery;
    var stack = reentrant ? Int32List(128) : _queryStack;
    if (!reentrant) {
      _inQuery = true;
    }
    try {
      var sp = 0;
      stack[sp++] = 0;
      while (sp > 0) {
        final node = stack[--sp];
        final nb = node * 6;
        var tMin = double.negativeInfinity;
        var tMax = double.infinity;
        var hit = true;
        for (var axis = 0; axis < 3 && hit; axis++) {
          final o = axis == 0 ? ox : (axis == 1 ? oy : oz);
          final inv = axis == 0 ? invX : (axis == 1 ? invY : invZ);
          final lo = bounds[nb + axis] - padding;
          final hi = bounds[nb + 3 + axis] + padding;
          if (inv == 0.0) {
            if (o < lo || o > hi) {
              hit = false;
            }
            continue;
          }
          var t1 = (lo - o) * inv;
          var t2 = (hi - o) * inv;
          if (t1 > t2) {
            final tmp = t1;
            t1 = t2;
            t2 = tmp;
          }
          if (t1 > tMin) {
            tMin = t1;
          }
          if (t2 < tMax) {
            tMax = t2;
          }
          if (tMin > tMax) {
            hit = false;
          }
        }
        if (!hit) {
          continue;
        }
        final cnt = counts[node];
        if (cnt > 0) {
          final start = leftOrFirst[node];
          for (var i = start; i < start + cnt; i++) {
            outPrimitives.add(primitives[i]);
          }
        } else {
          if (sp + 2 > stack.length) {
            stack = growStack(stack, sp);
            if (!reentrant) {
              _queryStack = stack;
            }
          }
          stack[sp++] = rightChild[node];
          stack[sp++] = leftOrFirst[node];
        }
      }
    } finally {
      if (!reentrant) {
        _inQuery = false;
      }
    }
  }

  /// Entry parameter `t >= 0` of a ray into [node]'s AABB, or `double.infinity`
  /// when missed or beyond [maxT].
  @pragma('vm:prefer-inline')
  double rayBoxEntry(
    int node,
    double ox,
    double oy,
    double oz,
    double dx,
    double dy,
    double dz,
    double maxT, {
    double padding = 1e-5,
  }) {
    final b = node * 6;
    final minX = bounds[b] - padding;
    final minY = bounds[b + 1] - padding;
    final minZ = bounds[b + 2] - padding;
    final maxX = bounds[b + 3] + padding;
    final maxY = bounds[b + 4] + padding;
    final maxZ = bounds[b + 5] + padding;

    var tMin = 0.0;
    var tMax = maxT;

    if (dx.abs() < 1e-12) {
      if (ox < minX || ox > maxX) {
        return double.infinity;
      }
    } else {
      final inv = 1.0 / dx;
      var t1 = (minX - ox) * inv;
      var t2 = (maxX - ox) * inv;
      if (t1 > t2) {
        final s = t1;
        t1 = t2;
        t2 = s;
      }
      if (t1 > tMin) {
        tMin = t1;
      }
      if (t2 < tMax) {
        tMax = t2;
      }
      if (tMin > tMax) {
        return double.infinity;
      }
    }

    if (dy.abs() < 1e-12) {
      if (oy < minY || oy > maxY) {
        return double.infinity;
      }
    } else {
      final inv = 1.0 / dy;
      var t1 = (minY - oy) * inv;
      var t2 = (maxY - oy) * inv;
      if (t1 > t2) {
        final s = t1;
        t1 = t2;
        t2 = s;
      }
      if (t1 > tMin) {
        tMin = t1;
      }
      if (t2 < tMax) {
        tMax = t2;
      }
      if (tMin > tMax) {
        return double.infinity;
      }
    }

    if (dz.abs() < 1e-12) {
      if (oz < minZ || oz > maxZ) {
        return double.infinity;
      }
    } else {
      final inv = 1.0 / dz;
      var t1 = (minZ - oz) * inv;
      var t2 = (maxZ - oz) * inv;
      if (t1 > t2) {
        final s = t1;
        t1 = t2;
        t2 = s;
      }
      if (t1 > tMin) {
        tMin = t1;
      }
      if (t2 < tMax) {
        tMax = t2;
      }
      if (tMin > tMax) {
        return double.infinity;
      }
    }

    return tMin;
  }

  /// Squared Euclidean distance from point `(qx, qy, qz)` to [node]'s AABB.
  @pragma('vm:prefer-inline')
  double boxDistanceSquared(int node, double qx, double qy, double qz) {
    final nb = node * 6;
    final minX = bounds[nb];
    final minY = bounds[nb + 1];
    final minZ = bounds[nb + 2];
    final maxX = bounds[nb + 3];
    final maxY = bounds[nb + 4];
    final maxZ = bounds[nb + 5];
    final dx = qx < minX ? minX - qx : (qx > maxX ? qx - maxX : 0.0);
    final dy = qy < minY ? minY - qy : (qy > maxY ? qy - maxY : 0.0);
    final dz = qz < minZ ? minZ - qz : (qz > maxZ ? qz - maxZ : 0.0);
    return dx * dx + dy * dy + dz * dz;
  }
}
