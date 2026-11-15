import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame/src/canvas3d/primitives_3d.dart';

/// Flat, zero-heap-node Struct-of-Arrays Bounding Volume Hierarchy (BVH) for
/// `O(log T)` Möller–Trumbore raycasting against 3D triangle meshes.
///
/// All internal and leaf nodes are packed into contiguous typed arrays
/// ([nodeBounds], [leftOrFirst], [rightOrCount], [triIndices]) with `0`
/// per-node Dart heap object allocations, and traversed iteratively using a
/// fixed 64-entry integer stack (`0` per-ray allocations).
class MeshBvh3D._({
  required this.positions,
  required this.indices,
  required this.nodeBounds,
  required this.leftOrFirst,
  required this.rightOrCount,
  required this.triIndices,
  required this.nodeCount,
}) {
  /// Builds a flat [MeshBvh3D] over [positions] (`vertexCount * 3`) and
  /// 16-bit triangle [indices] (`faceCount * 3`).
  factory MeshBvh3D.build({
    required Float32List positions,
    required Uint16List indices,
    int maxLeafTriangles = 4,
  }) => MeshBvh3D._buildInternal(
    positions: positions,
    indices16: indices,
    indices32: null,
    maxLeafTriangles: math.max(1, maxLeafTriangles),
  );

  /// Builds a flat [MeshBvh3D] over 32-bit triangle [indices] (`> 65,535`
  /// vertices).
  factory MeshBvh3D.build32({
    required Float32List positions,
    required Uint32List indices,
    int maxLeafTriangles = 4,
  }) => MeshBvh3D._buildInternal(
    positions: positions,
    indices16: null,
    indices32: indices,
    maxLeafTriangles: math.max(1, maxLeafTriangles),
  );

  factory MeshBvh3D._buildInternal({
    required Float32List positions,
    required Uint16List? indices16,
    required Uint32List? indices32,
    required int maxLeafTriangles,
  }) {
    final rawLen = indices16?.length ?? indices32!.length;
    final faceCount = rawLen ~/ 3;
    if (faceCount == 0) {
      return MeshBvh3D._(
        positions: positions,
        indices: indices16 ?? Uint16List(0),
        nodeBounds: Float32List(0),
        leftOrFirst: Int32List(0),
        rightOrCount: Int32List(0),
        triIndices: Int32List(0),
        nodeCount: 0,
      ).._indices32 = indices32;
    }

    final triIndices = Int32List(faceCount);
    final triBounds = Float32List(faceCount * 6);
    final centroids = Float32List(faceCount * 3);

    for (var f = 0; f < faceCount; f++) {
      triIndices[f] = f;
      final f3 = f * 3;
      final int i0;
      final int i1;
      final int i2;
      if (indices16 != null) {
        i0 = indices16[f3] * 3;
        i1 = indices16[f3 + 1] * 3;
        i2 = indices16[f3 + 2] * 3;
      } else {
        i0 = indices32![f3] * 3;
        i1 = indices32[f3 + 1] * 3;
        i2 = indices32[f3 + 2] * 3;
      }

      final x0 = positions[i0];
      final y0 = positions[i0 + 1];
      final z0 = positions[i0 + 2];
      final x1 = positions[i1];
      final y1 = positions[i1 + 1];
      final z1 = positions[i1 + 2];
      final x2 = positions[i2];
      final y2 = positions[i2 + 1];
      final z2 = positions[i2 + 2];

      final minX = math.min(x0, math.min(x1, x2));
      final minY = math.min(y0, math.min(y1, y2));
      final minZ = math.min(z0, math.min(z1, z2));
      final maxX = math.max(x0, math.max(x1, x2));
      final maxY = math.max(y0, math.max(y1, y2));
      final maxZ = math.max(z0, math.max(z1, z2));

      final b6 = f * 6;
      triBounds[b6] = minX;
      triBounds[b6 + 1] = minY;
      triBounds[b6 + 2] = minZ;
      triBounds[b6 + 3] = maxX;
      triBounds[b6 + 4] = maxY;
      triBounds[b6 + 5] = maxZ;

      final c3 = f * 3;
      centroids[c3] = (x0 + x1 + x2) * (1.0 / 3.0);
      centroids[c3 + 1] = (y0 + y1 + y2) * (1.0 / 3.0);
      centroids[c3 + 2] = (z0 + z1 + z2) * (1.0 / 3.0);
    }

    final maxNodes = math.max(1, faceCount * 2);
    var nodeBounds = Float32List(maxNodes * 6);
    var leftOrFirst = Int32List(maxNodes);
    var rightOrCount = Int32List(maxNodes);
    var usedNodes = 0;

    void ensureNodeCap(int needed) {
      if (needed <= leftOrFirst.length) {
        return;
      }
      final nextCap = math.max(needed, leftOrFirst.length * 2);
      nodeBounds = Float32List(nextCap * 6)
        ..setRange(0, usedNodes * 6, nodeBounds);
      leftOrFirst = Int32List(nextCap)..setRange(0, usedNodes, leftOrFirst);
      rightOrCount = Int32List(nextCap)..setRange(0, usedNodes, rightOrCount);
    }

    int buildNode(int start, int count) {
      ensureNodeCap(usedNodes + 1);
      final nodeIdx = usedNodes++;

      var bMinX = double.infinity;
      var bMinY = double.infinity;
      var bMinZ = double.infinity;
      var bMaxX = double.negativeInfinity;
      var bMaxY = double.negativeInfinity;
      var bMaxZ = double.negativeInfinity;

      var cMinX = double.infinity;
      var cMinY = double.infinity;
      var cMinZ = double.infinity;
      var cMaxX = double.negativeInfinity;
      var cMaxY = double.negativeInfinity;
      var cMaxZ = double.negativeInfinity;

      for (var i = start; i < start + count; i++) {
        final f = triIndices[i];
        final b6 = f * 6;
        if (triBounds[b6] < bMinX) {
          bMinX = triBounds[b6];
        }
        if (triBounds[b6 + 1] < bMinY) {
          bMinY = triBounds[b6 + 1];
        }
        if (triBounds[b6 + 2] < bMinZ) {
          bMinZ = triBounds[b6 + 2];
        }
        if (triBounds[b6 + 3] > bMaxX) {
          bMaxX = triBounds[b6 + 3];
        }
        if (triBounds[b6 + 4] > bMaxY) {
          bMaxY = triBounds[b6 + 4];
        }
        if (triBounds[b6 + 5] > bMaxZ) {
          bMaxZ = triBounds[b6 + 5];
        }

        final c3 = f * 3;
        final cx = centroids[c3];
        final cy = centroids[c3 + 1];
        final cz = centroids[c3 + 2];
        if (cx < cMinX) {
          cMinX = cx;
        }
        if (cy < cMinY) {
          cMinY = cy;
        }
        if (cz < cMinZ) {
          cMinZ = cz;
        }
        if (cx > cMaxX) {
          cMaxX = cx;
        }
        if (cy > cMaxY) {
          cMaxY = cy;
        }
        if (cz > cMaxZ) {
          cMaxZ = cz;
        }
      }

      final nb = nodeIdx * 6;
      nodeBounds[nb] = bMinX;
      nodeBounds[nb + 1] = bMinY;
      nodeBounds[nb + 2] = bMinZ;
      nodeBounds[nb + 3] = bMaxX;
      nodeBounds[nb + 4] = bMaxY;
      nodeBounds[nb + 5] = bMaxZ;

      if (count <= maxLeafTriangles) {
        leftOrFirst[nodeIdx] = start;
        rightOrCount[nodeIdx] = count;
        return nodeIdx;
      }

      final extX = cMaxX - cMinX;
      final extY = cMaxY - cMinY;
      final extZ = cMaxZ - cMinZ;
      var axis = 0;
      var maxExt = extX;
      if (extY > maxExt) {
        axis = 1;
        maxExt = extY;
      }
      if (extZ > maxExt) {
        axis = 2;
        maxExt = extZ;
      }

      var mid = start + (count >> 1);
      if (maxExt > 1e-6) {
        final splitPos = axis == 0
            ? (cMinX + cMaxX) * 0.5
            : (axis == 1 ? (cMinY + cMaxY) * 0.5 : (cMinZ + cMaxZ) * 0.5);
        var i = start;
        var j = start + count - 1;
        while (i <= j) {
          final f = triIndices[i];
          if (centroids[f * 3 + axis] < splitPos) {
            i++;
          } else {
            final tmp = triIndices[i];
            triIndices[i] = triIndices[j];
            triIndices[j] = tmp;
            j--;
          }
        }
        if (i > start && i < start + count) {
          mid = i;
        }
      }

      final leftCount = mid - start;
      final rightCount = count - leftCount;
      final leftChild = buildNode(start, leftCount);
      final rightChild = buildNode(mid, rightCount);
      leftOrFirst[nodeIdx] = leftChild;
      // Negative encoding marks internal node pointing to `rightChild > 0`.
      rightOrCount[nodeIdx] = -rightChild;
      return nodeIdx;
    }

    buildNode(0, faceCount);

    return MeshBvh3D._(
      positions: positions,
      indices: indices16 ?? Uint16List(0),
      nodeBounds: Float32List.sublistView(nodeBounds, 0, usedNodes * 6),
      leftOrFirst: Int32List.sublistView(leftOrFirst, 0, usedNodes),
      rightOrCount: Int32List.sublistView(rightOrCount, 0, usedNodes),
      triIndices: triIndices,
      nodeCount: usedNodes,
    ).._indices32 = indices32;
  }

  /// Mesh vertex positions (`vertexCount * 3`).
  final Float32List positions;

  /// 16-bit triangle index buffer (`empty` when built via [MeshBvh3D.build32]).
  final Uint16List indices;

  Uint32List? _indices32;

  /// Packed node AABBs (`nodeCount * 6`: `minX, minY, minZ, maxX, maxY, maxZ`).
  final Float32List nodeBounds;

  /// Left child node index for internal nodes, or starting offset into
  /// [triIndices] for leaf nodes.
  final Int32List leftOrFirst;

  /// Negated right child index (`< 0`) for internal nodes, or positive triangle
  /// count (`> 0`) for leaf nodes.
  final Int32List rightOrCount;

  /// Permuted triangle face indices (`0 .. faceCount - 1`).
  final Int32List triIndices;

  /// Total BVH nodes allocated.
  final int nodeCount;

  final Int32List _stack = Int32List(128);
  int _lastNodesVisited = 0;
  int _lastTrianglesTested = 0;

  /// Number of BVH nodes visited by the most recent [raycastLocal] call.
  int get lastNodesVisited => _lastNodesVisited;

  /// Number of Möller–Trumbore triangle intersections tested by the most recent
  /// [raycastLocal] call.
  int get lastTrianglesTested => _lastTrianglesTested;

  /// Total indexed triangles covered by this BVH.
  int get triangleCount => triIndices.length;

  /// Intersects [localRay] (in mesh-local coordinates) against this BVH,
  /// returning `(localDistance, faceIndex)` for the closest hit in
  /// `(1e-5 .. maxLocalDistance)` or `null` on a miss.
  ///
  /// When [flipWinding] is `true` (used automatically when an ancestor
  /// transform has negative determinant / mirrored scale), backface culling
  /// tests `-det` instead of `+det`.
  (double distance, int faceIndex)? raycastLocal(
    Ray3D localRay, {
    double maxLocalDistance = double.infinity,
    bool cullBackfaces = true,
    bool flipWinding = false,
  }) {
    _lastNodesVisited = 0;
    _lastTrianglesTested = 0;
    if (nodeCount == 0) {
      return null;
    }

    final rootDist = Aabb3D.intersectRayDistance(
      localRay,
      minX: nodeBounds[0],
      minY: nodeBounds[1],
      minZ: nodeBounds[2],
      maxX: nodeBounds[3],
      maxY: nodeBounds[4],
      maxZ: nodeBounds[5],
      maxDistance: maxLocalDistance,
    );
    if (rootDist == null) {
      return null;
    }

    var bestT = maxLocalDistance;
    var bestFace = -1;
    var sp = 0;
    _stack[sp++] = 0;

    final lox = localRay.ox;
    final loy = localRay.oy;
    final loz = localRay.oz;
    final ldx = localRay.dx;
    final ldy = localRay.dy;
    final ldz = localRay.dz;
    final pos = positions;
    final idx16 = _indices32 == null ? indices : null;
    final idx32 = _indices32;

    while (sp > 0) {
      final node = _stack[--sp];
      _lastNodesVisited++;
      final rc = rightOrCount[node];
      if (rc > 0) {
        final first = leftOrFirst[node];
        final end = first + rc;
        for (var k = first; k < end; k++) {
          _lastTrianglesTested++;
          final f = triIndices[k];
          final f3 = f * 3;
          final int i0;
          final int i1;
          final int i2;
          if (idx16 != null) {
            i0 = idx16[f3] * 3;
            i1 = idx16[f3 + 1] * 3;
            i2 = idx16[f3 + 2] * 3;
          } else {
            i0 = idx32![f3] * 3;
            i1 = idx32[f3 + 1] * 3;
            i2 = idx32[f3 + 2] * 3;
          }

          final v0x = pos[i0];
          final v0y = pos[i0 + 1];
          final v0z = pos[i0 + 2];

          final e1x = pos[i1] - v0x;
          final e1y = pos[i1 + 1] - v0y;
          final e1z = pos[i1 + 2] - v0z;

          final e2x = pos[i2] - v0x;
          final e2y = pos[i2 + 1] - v0y;
          final e2z = pos[i2 + 2] - v0z;

          final px = ldy * e2z - ldz * e2y;
          final py = ldz * e2x - ldx * e2z;
          final pz = ldx * e2y - ldy * e2x;

          final det = e1x * px + e1y * py + e1z * pz;
          if (cullBackfaces) {
            if (flipWinding ? det > -1e-7 : det < 1e-7) {
              continue;
            }
          } else if (det.abs() < 1e-7) {
            continue;
          }

          final invDet = 1.0 / det;
          final tx = lox - v0x;
          final ty = loy - v0y;
          final tz = loz - v0z;

          final u = (tx * px + ty * py + tz * pz) * invDet;
          if (u < 0.0 || u > 1.0) {
            continue;
          }

          final qx = ty * e1z - tz * e1y;
          final qy = tz * e1x - tx * e1z;
          final qz = tx * e1y - ty * e1x;

          final v = (ldx * qx + ldy * qy + ldz * qz) * invDet;
          if (v < 0.0 || u + v > 1.0) {
            continue;
          }

          final t = (e2x * qx + e2y * qy + e2z * qz) * invDet;
          if (t > 1e-5 && t < bestT) {
            bestT = t;
            bestFace = f;
          }
        }
      } else {
        final left = leftOrFirst[node];
        final right = -rc;
        final lb = left * 6;
        final rb = right * 6;
        final dLeft = Aabb3D.intersectRayDistance(
          localRay,
          minX: nodeBounds[lb],
          minY: nodeBounds[lb + 1],
          minZ: nodeBounds[lb + 2],
          maxX: nodeBounds[lb + 3],
          maxY: nodeBounds[lb + 4],
          maxZ: nodeBounds[lb + 5],
          maxDistance: bestT,
        );
        final dRight = Aabb3D.intersectRayDistance(
          localRay,
          minX: nodeBounds[rb],
          minY: nodeBounds[rb + 1],
          minZ: nodeBounds[rb + 2],
          maxX: nodeBounds[rb + 3],
          maxY: nodeBounds[rb + 4],
          maxZ: nodeBounds[rb + 5],
          maxDistance: bestT,
        );

        if (dLeft != null && dRight != null) {
          // Push farther child first so nearer child is popped first.
          if (dLeft <= dRight) {
            if (sp + 2 <= _stack.length) {
              _stack[sp++] = right;
              _stack[sp++] = left;
            }
          } else {
            if (sp + 2 <= _stack.length) {
              _stack[sp++] = left;
              _stack[sp++] = right;
            }
          }
        } else if (dLeft != null) {
          if (sp < _stack.length) {
            _stack[sp++] = left;
          }
        } else if (dRight != null) {
          if (sp < _stack.length) {
            _stack[sp++] = right;
          }
        }
      }
    }

    if (bestFace < 0) {
      return null;
    }
    return (bestT, bestFace);
  }
}
