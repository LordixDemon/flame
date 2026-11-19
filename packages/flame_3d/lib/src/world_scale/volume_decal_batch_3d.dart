import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Color, Rect;

import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/src/world_scale/chunked_terrain_3d.dart';

/// Local axis of a [ProjectedDecalBox3D] along which the decal is projected.
enum DecalProjectionAxis3D() {
  /// Projects downward along local `-Y` (`X -> U`, `Z -> V`), receiving on
  /// surfaces facing `+Y`.
  negativeY,

  /// Projects forward along local `-Z` (`X -> U`, `Y -> V`), receiving on
  /// surfaces facing `+Z`.
  negativeZ,
}

/// Oriented 3D bounding-box decal volume projected onto arbitrary geometry by
/// [VolumeDecalBatch3D].
class ProjectedDecalBox3D({
  required Vector3 center,
  required Vector3 halfExtents,
  Quaternion? rotation,

  /// Atlas sub-rectangle `[0..1]` mapped across the projected quad footprint.
  final Rect uvRect = const Rect.fromLTWH(0, 0, 1, 1),

  /// Per-decal tint and base opacity.
  final Color color = const Color(0xFFFFFFFF),

  /// Cosine cutoff (`dot(surfaceNormal, receiveNormal) <= normalAngleFadeCos`
  /// culls back-facing and grazing surfaces).
  final double normalAngleFadeCos = 0.1,

  /// Cosine ramp width above [normalAngleFadeCos] over which alpha fades in
  /// smoothly to `1.0`.
  final double normalFadeWidth = 0.25,

  /// Local projection axis of this box.
  final DecalProjectionAxis3D projectionAxis = DecalProjectionAxis3D.negativeY,
}) {
  /// Creates an oriented 3D decal projection volume.
  this
    : assert(
        halfExtents.x > 0 && halfExtents.y > 0 && halfExtents.z > 0,
        'halfExtents must be positive on all axes',
      );

  /// World-space center of the oriented decal volume.
  final Vector3 center = center.clone();

  /// Positive half-extents `(hx, hy, hz)` of the decal box.
  final Vector3 halfExtents = halfExtents.clone();

  /// World-space orientation of the decal box.
  final Quaternion rotation = rotation?.clone() ?? Quaternion.identity();

  /// Creates a decal box projecting along world [direction] (using
  /// [DecalProjectionAxis3D.negativeZ]).
  factory ProjectedDecalBox3D.lookAlong({
    required Vector3 center,
    required Vector3 direction,
    required Vector3 halfExtents,
    Vector3? up,
    Rect uvRect = const Rect.fromLTWH(0, 0, 1, 1),
    Color color = const Color(0xFFFFFFFF),
    double normalAngleFadeCos = 0.1,
    double normalFadeWidth = 0.25,
  }) {
    final fwd = direction.normalized();
    // Local -Z aligns with `fwd`, so local +Z aligns with `-fwd`.
    final localZ = -fwd;
    var refUp = up?.normalized() ?? Vector3(0, 1, 0);
    if (localZ.dot(refUp).abs() > 0.98) {
      refUp = Vector3(1, 0, 0);
    }
    final localX = refUp.cross(localZ)..normalize();
    final localY = localZ.cross(localX)..normalize();
    final rotMat = Matrix3.columns(localX, localY, localZ);
    final q = Quaternion.fromRotation(rotMat)..normalize();
    return ProjectedDecalBox3D(
      center: center,
      halfExtents: halfExtents,
      rotation: q,
      uvRect: uvRect,
      color: color,
      normalAngleFadeCos: normalAngleFadeCos,
      normalFadeWidth: normalFadeWidth,
      projectionAxis: DecalProjectionAxis3D.negativeZ,
    );
  }
}

/// Target surface and optional world transform sampled by [VolumeDecalBatch3D].
class VolumeDecalTarget3D({
  /// Target geometry surface.
  required final Surface surface,
  Matrix4? transform,
}) {
  /// World-space transform of [surface].
  final Matrix4 transform = transform != null
      ? Matrix4.copy(transform)
      : Matrix4.identity();

  /// Expands all surfaces of [mesh] into [VolumeDecalTarget3D] entries.
  static List<VolumeDecalTarget3D> fromMesh(
    Mesh mesh, {
    Matrix4? transform,
  }) {
    return <VolumeDecalTarget3D>[
      for (final s in mesh.surfaces)
        VolumeDecalTarget3D(surface: s, transform: transform),
    ];
  }

  /// Expands all surfaces of a mounted or standalone [MeshComponent].
  static List<VolumeDecalTarget3D> fromMeshComponent(MeshComponent component) {
    return fromMesh(component.mesh, transform: component.worldTransformMatrix);
  }
}

class _DecalSurfaceAabbBvh {
  factory _DecalSurfaceAabbBvh.build(Surface surface) {
    // Ensure the surface's built-in BVH is initialized as well.
    surface.bvh;
    final posOffset = surface.layout.offsetOf(VertexLayout.positionAttribute);
    final indices = surface.indices;
    final triCount = indices.length ~/ 3;
    if (posOffset == null || triCount == 0) {
      return _DecalSurfaceAabbBvh._empty(surface.vertexCount, indices.length);
    }

    final verts = surface.vertexData;
    final stride = surface.layout.strideInFloats;
    final triOrder = Int32List(triCount);
    final triBounds = Float32List(triCount * 6);
    final centroids = Float32List(triCount * 3);

    for (var t = 0; t < triCount; t++) {
      triOrder[t] = t;
      final b = t * 3;
      final i0 = indices[b] * stride + posOffset;
      final i1 = indices[b + 1] * stride + posOffset;
      final i2 = indices[b + 2] * stride + posOffset;

      final x0 = verts[i0];
      final y0 = verts[i0 + 1];
      final z0 = verts[i0 + 2];
      final x1 = verts[i1];
      final y1 = verts[i1 + 1];
      final z1 = verts[i1 + 2];
      final x2 = verts[i2];
      final y2 = verts[i2 + 1];
      final z2 = verts[i2 + 2];

      final tb = t * 6;
      triBounds
        ..[tb] = math.min(x0, math.min(x1, x2))
        ..[tb + 1] = math.min(y0, math.min(y1, y2))
        ..[tb + 2] = math.min(z0, math.min(z1, z2))
        ..[tb + 3] = math.max(x0, math.max(x1, x2))
        ..[tb + 4] = math.max(y0, math.max(y1, y2))
        ..[tb + 5] = math.max(z0, math.max(z1, z2));

      final cb = t * 3;
      centroids
        ..[cb] = (x0 + x1 + x2) * (1.0 / 3.0)
        ..[cb + 1] = (y0 + y1 + y2) * (1.0 / 3.0)
        ..[cb + 2] = (z0 + z1 + z2) * (1.0 / 3.0);
    }

    final maxNodes = math.max(1, triCount * 2);
    final bounds = Float32List(maxNodes * 6);
    final leftOrFirst = Int32List(maxNodes);
    final rightChild = Int32List(maxNodes);
    final counts = Int32List(maxNodes);
    var nodeCount = 0;

    int build(int start, int count) {
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
        final t = triOrder[i];
        final tb = t * 6;
        minX = math.min(minX, triBounds[tb]);
        minY = math.min(minY, triBounds[tb + 1]);
        minZ = math.min(minZ, triBounds[tb + 2]);
        maxX = math.max(maxX, triBounds[tb + 3]);
        maxY = math.max(maxY, triBounds[tb + 4]);
        maxZ = math.max(maxZ, triBounds[tb + 5]);

        final cb = t * 3;
        cMinX = math.min(cMinX, centroids[cb]);
        cMinY = math.min(cMinY, centroids[cb + 1]);
        cMinZ = math.min(cMinZ, centroids[cb + 2]);
        cMaxX = math.max(cMaxX, centroids[cb]);
        cMaxY = math.max(cMaxY, centroids[cb + 1]);
        cMaxZ = math.max(cMaxZ, centroids[cb + 2]);
      }

      final nb = node * 6;
      bounds
        ..[nb] = minX
        ..[nb + 1] = minY
        ..[nb + 2] = minZ
        ..[nb + 3] = maxX
        ..[nb + 4] = maxY
        ..[nb + 5] = maxZ;

      if (count <= 4) {
        leftOrFirst[node] = start;
        counts[node] = count;
        return node;
      }

      final ex = cMaxX - cMinX;
      final ey = cMaxY - cMinY;
      final ez = cMaxZ - cMinZ;
      var axis = 0;
      var split = 0.5 * (cMinX + cMaxX);
      var ext = ex;
      if (ey > ext) {
        axis = 1;
        split = 0.5 * (cMinY + cMaxY);
        ext = ey;
      }
      if (ez > ext) {
        axis = 2;
        split = 0.5 * (cMinZ + cMaxZ);
        ext = ez;
      }

      int mid;
      if (ext <= 1e-12) {
        mid = start + (count >> 1);
      } else {
        var i = start;
        var j = start + count - 1;
        while (i <= j) {
          if (centroids[triOrder[i] * 3 + axis] < split) {
            i++;
          } else {
            final tmp = triOrder[i];
            triOrder[i] = triOrder[j];
            triOrder[j] = tmp;
            j--;
          }
        }
        mid = (i == start || i == start + count) ? start + (count >> 1) : i;
      }

      counts[node] = 0;
      leftOrFirst[node] = build(start, mid - start);
      rightChild[node] = build(mid, start + count - mid);
      return node;
    }

    build(0, triCount);
    return _DecalSurfaceAabbBvh._(
      vertexCount: surface.vertexCount,
      indexCount: indices.length,
      nodeCount: nodeCount,
      bounds: Float32List.sublistView(bounds, 0, nodeCount * 6),
      leftOrFirst: Int32List.sublistView(leftOrFirst, 0, nodeCount),
      rightChild: Int32List.sublistView(rightChild, 0, nodeCount),
      counts: Int32List.sublistView(counts, 0, nodeCount),
      triangles: triOrder,
      triBounds: triBounds,
    );
  }

  _DecalSurfaceAabbBvh._({
    required this.vertexCount,
    required this.indexCount,
    required this.nodeCount,
    required this.bounds,
    required this.leftOrFirst,
    required this.rightChild,
    required this.counts,
    required this.triangles,
    required this.triBounds,
  });

  _DecalSurfaceAabbBvh._empty(this.vertexCount, this.indexCount)
    : nodeCount = 0,
      bounds = Float32List(0),
      leftOrFirst = Int32List(0),
      rightChild = Int32List(0),
      counts = Int32List(0),
      triangles = Int32List(0),
      triBounds = Float32List(0);

  final int vertexCount;
  final int indexCount;
  final int nodeCount;
  final Float32List bounds;
  final Int32List leftOrFirst;
  final Int32List rightChild;
  final Int32List counts;
  final Int32List triangles;
  final Float32List triBounds;
  final Int32List _stack = Int32List(128);

  int queryAabb(
    double qMinX,
    double qMinY,
    double qMinZ,
    double qMaxX,
    double qMaxY,
    double qMaxZ,
    List<int> outTriangles,
  ) {
    outTriangles.clear();
    if (nodeCount == 0) {
      return 0;
    }
    var sp = 0;
    _stack[sp++] = 0;
    while (sp > 0) {
      final node = _stack[--sp];
      final nb = node * 6;
      if (qMaxX < bounds[nb] - 1e-5 ||
          qMinX > bounds[nb + 3] + 1e-5 ||
          qMaxY < bounds[nb + 1] - 1e-5 ||
          qMinY > bounds[nb + 4] + 1e-5 ||
          qMaxZ < bounds[nb + 2] - 1e-5 ||
          qMinZ > bounds[nb + 5] + 1e-5) {
        continue;
      }
      final count = counts[node];
      if (count > 0) {
        final start = leftOrFirst[node];
        for (var i = start; i < start + count; i++) {
          final tri = triangles[i];
          final tb = tri * 6;
          if (qMaxX >= triBounds[tb] - 1e-5 &&
              qMinX <= triBounds[tb + 3] + 1e-5 &&
              qMaxY >= triBounds[tb + 1] - 1e-5 &&
              qMinY <= triBounds[tb + 4] + 1e-5 &&
              qMaxZ >= triBounds[tb + 2] - 1e-5 &&
              qMinZ <= triBounds[tb + 5] + 1e-5) {
            outTriangles.add(tri);
          }
        }
      } else {
        _stack[sp++] = rightChild[node];
        _stack[sp++] = leftOrFirst[node];
      }
    }
    return outTriangles.length;
  }
}

/// Oriented 3D volume decal projector [Object3D] that clips and conforms
/// triangles from target [Surface] BVHs or [ChunkedTerrain3D] heightfields onto
/// stairs, 90-degree wall/floor corners, slopes, and uneven terrain in **1
/// batched draw call**.
class VolumeDecalBatch3D({
  Material? material,

  /// Outward displacement along the receiving surface normal preventing
  /// coplanar Z-fighting.
  var double normalOffset = 0.004,

  /// Fraction `[0..0.5]` near the projection-depth ends (`|z| -> 1`) over which
  /// decals feather smoothly to transparent (`0` disables depth feathering).
  var double boxEdgeFeather = 0.12,
  super.position,
  super.scale,
  super.rotation,
  super.children,
  super.cameraMask,
}) extends Object3D {
  /// Creates a volume decal mesh projector batch.
  this
    : assert(normalOffset >= 0, 'normalOffset must be non-negative'),
      super(castsShadows: false);

  /// Shared decal material (defaults to alpha-blended `UnlitMaterial` without
  /// depth writes).
  final Material material =
      material ??
      (UnlitMaterial()
        ..renderState = RenderState.alphaBlend
        ..castsShadows = false);

  static final Expando<_DecalSurfaceAabbBvh> _surfaceBvhCache =
      Expando<_DecalSurfaceAabbBvh>();

  Float32List _vertScratch = Float32List(1024 * 20);
  Int32List _idxScratch = Int32List(2048 * 3);
  int _vertCount = 0;
  int _idxCount = 0;
  int _projectedDecalCount = 0;

  Surface? _mergedSurface;
  final Aabb3 _localAabb = Aabb3();

  // Polygon clipping ping-pong buffers: up to 32 vertices * 6 doubles
  // `(bx, by, bz, wnx, wny, wnz)`.
  final Float64List _polyA = Float64List(32 * 6);
  final Float64List _polyB = Float64List(32 * 6);
  final List<int> _candidateTriangles = <int>[];

  final Matrix4 _invTarget = Matrix4.identity();
  final Matrix4 _invSelf = Matrix4.identity();
  final Aabb3 _decalWorldAabb = Aabb3();
  final Aabb3 _localQueryAabb = Aabb3();

  /// Merged conformal decal [Surface] built by the last projection call, or
  /// `null` when empty.
  Surface? get mergedSurface => _mergedSurface;

  /// Number of clipped decal vertices in [mergedSurface].
  int get generatedVertexCount => _vertCount;

  /// Number of clipped decal triangles in [mergedSurface].
  int get generatedTriangleCount => _idxCount ~/ 3;

  /// Number of [ProjectedDecalBox3D] volumes projected into the current batch.
  int get projectedDecalCount => _projectedDecalCount;

  /// Clears all projected geometry and disposes the GPU [mergedSurface].
  void clear() {
    _mergedSurface?.dispose();
    _mergedSurface = null;
    _vertCount = 0;
    _idxCount = 0;
    _projectedDecalCount = 0;
    _localAabb.setZero();
    markAabbDirty();
    worldOrNull?.markSceneDirty(shadows: false);
  }

  /// Clips and projects all [decals] against [targets] using cached per-surface
  /// AABB BVHs, merging every surviving conformal polygon into 1 [Surface].
  ///
  /// Set [append] to `true` to append onto existing projected geometry instead
  /// of replacing it (for example when combining [projectOntoSurfaces] and
  /// [projectOntoTerrain]).
  void projectOntoSurfaces(
    List<ProjectedDecalBox3D> decals,
    List<VolumeDecalTarget3D> targets, {
    bool append = false,
  }) {
    if (!append) {
      _resetAccumulators();
    }
    if (decals.isEmpty || targets.isEmpty) {
      _finalizeMergedSurface();
      return;
    }

    final selfWorld = worldTransformMatrix;
    final selfIsIdentity = selfWorld.isIdentity();
    if (!selfIsIdentity) {
      _invSelf
        ..setFrom(selfWorld)
        ..invert();
    }

    for (var dIdx = 0; dIdx < decals.length; dIdx++) {
      final decal = decals[dIdx];
      _projectedDecalCount++;
      final boxFrame = _prepareDecalBoxFrame(decal);

      for (var tIdx = 0; tIdx < targets.length; tIdx++) {
        final target = targets[tIdx];
        final surface = target.surface;
        final posOffset = surface.layout.offsetOf(
          VertexLayout.positionAttribute,
        );
        if (posOffset == null || surface.indexCount < 3) {
          continue;
        }
        final nrmOffset = surface.layout.offsetOf('vertexNormal');
        final stride = surface.layout.strideInFloats;

        final tf = target.transform;
        _invTarget.setFrom(tf);
        if (_invTarget.invert().abs() <= 1e-15) {
          continue;
        }

        _localQueryAabb
          ..setFrom(_decalWorldAabb)
          ..transform(_invTarget);

        final bvh = _getOrBuildBvh(surface);
        final hitCount = bvh.queryAabb(
          _localQueryAabb.min.x,
          _localQueryAabb.min.y,
          _localQueryAabb.min.z,
          _localQueryAabb.max.x,
          _localQueryAabb.max.y,
          _localQueryAabb.max.z,
          _candidateTriangles,
        );
        if (hitCount == 0) {
          continue;
        }

        final m = tf.storage;
        final c00 = m[5] * m[10] - m[6] * m[9];
        final c01 = m[6] * m[8] - m[4] * m[10];
        final c02 = m[4] * m[9] - m[5] * m[8];
        final c10 = m[2] * m[9] - m[1] * m[10];
        final c11 = m[0] * m[10] - m[2] * m[8];
        final c12 = m[1] * m[8] - m[0] * m[9];
        final c20 = m[1] * m[6] - m[2] * m[5];
        final c21 = m[2] * m[4] - m[0] * m[6];
        final c22 = m[0] * m[5] - m[1] * m[4];
        final flip = (m[0] * c00 + m[4] * c10 + m[8] * c20) < 0;

        final verts = surface.vertexData;
        final indices = surface.indices;

        for (var k = 0; k < hitCount; k++) {
          final tri = _candidateTriangles[k];
          final ib = tri * 3;
          final idx0 = indices[ib];
          final idx1 = flip ? indices[ib + 2] : indices[ib + 1];
          final idx2 = flip ? indices[ib + 1] : indices[ib + 2];

          final p0 = idx0 * stride + posOffset;
          final p1 = idx1 * stride + posOffset;
          final p2 = idx2 * stride + posOffset;

          final w0x =
              m[0] * verts[p0] +
              m[4] * verts[p0 + 1] +
              m[8] * verts[p0 + 2] +
              m[12];
          final w0y =
              m[1] * verts[p0] +
              m[5] * verts[p0 + 1] +
              m[9] * verts[p0 + 2] +
              m[13];
          final w0z =
              m[2] * verts[p0] +
              m[6] * verts[p0 + 1] +
              m[10] * verts[p0 + 2] +
              m[14];

          final w1x =
              m[0] * verts[p1] +
              m[4] * verts[p1 + 1] +
              m[8] * verts[p1 + 2] +
              m[12];
          final w1y =
              m[1] * verts[p1] +
              m[5] * verts[p1 + 1] +
              m[9] * verts[p1 + 2] +
              m[13];
          final w1z =
              m[2] * verts[p1] +
              m[6] * verts[p1 + 1] +
              m[10] * verts[p1 + 2] +
              m[14];

          final w2x =
              m[0] * verts[p2] +
              m[4] * verts[p2 + 1] +
              m[8] * verts[p2 + 2] +
              m[12];
          final w2y =
              m[1] * verts[p2] +
              m[5] * verts[p2 + 1] +
              m[9] * verts[p2 + 2] +
              m[13];
          final w2z =
              m[2] * verts[p2] +
              m[6] * verts[p2 + 1] +
              m[10] * verts[p2 + 2] +
              m[14];

          // Geometric world face normal.
          final e1x = w1x - w0x;
          final e1y = w1y - w0y;
          final e1z = w1z - w0z;
          final e2x = w2x - w0x;
          final e2y = w2y - w0y;
          final e2z = w2z - w0z;
          var fnx = e1y * e2z - e1z * e2y;
          var fny = e1z * e2x - e1x * e2z;
          var fnz = e1x * e2y - e1y * e2x;
          final fnLen = math.sqrt(fnx * fnx + fny * fny + fnz * fnz);
          if (fnLen <= 1e-12) {
            continue;
          }
          fnx /= fnLen;
          fny /= fnLen;
          fnz /= fnLen;

          double n0x;
          double n0y;
          double n0z;
          double n1x;
          double n1y;
          double n1z;
          double n2x;
          double n2y;
          double n2z;

          if (nrmOffset != null) {
            final sgn = flip ? -1.0 : 1.0;
            final no0 = idx0 * stride + nrmOffset;
            final no1 = idx1 * stride + nrmOffset;
            final no2 = idx2 * stride + nrmOffset;
            (n0x, n0y, n0z) = _transformNormal(
              c00,
              c01,
              c02,
              c10,
              c11,
              c12,
              c20,
              c21,
              c22,
              sgn,
              verts[no0],
              verts[no0 + 1],
              verts[no0 + 2],
              fnx,
              fny,
              fnz,
            );
            (n1x, n1y, n1z) = _transformNormal(
              c00,
              c01,
              c02,
              c10,
              c11,
              c12,
              c20,
              c21,
              c22,
              sgn,
              verts[no1],
              verts[no1 + 1],
              verts[no1 + 2],
              fnx,
              fny,
              fnz,
            );
            (n2x, n2y, n2z) = _transformNormal(
              c00,
              c01,
              c02,
              c10,
              c11,
              c12,
              c20,
              c21,
              c22,
              sgn,
              verts[no2],
              verts[no2 + 1],
              verts[no2 + 2],
              fnx,
              fny,
              fnz,
            );
          } else {
            n0x = n1x = n2x = fnx;
            n0y = n1y = n2y = fny;
            n0z = n1z = n2z = fnz;
          }

          _clipAndEmitWorldTriangle(
            decal,
            boxFrame,
            w0x,
            w0y,
            w0z,
            n0x,
            n0y,
            n0z,
            w1x,
            w1y,
            w1z,
            n1x,
            n1y,
            n1z,
            w2x,
            w2y,
            w2z,
            n2x,
            n2y,
            n2z,
            fnx,
            fny,
            fnz,
            selfIsIdentity: selfIsIdentity,
          );
        }
      }
    }

    _finalizeMergedSurface();
  }

  /// Clips and projects all [decals] directly against the heightfield cells of
  /// [terrain] overlapping each decal's 3D bounding box in `O(covered_cells)`.
  void projectOntoTerrain(
    List<ProjectedDecalBox3D> decals,
    ChunkedTerrain3D terrain, {
    bool append = false,
  }) {
    if (!append) {
      _resetAccumulators();
    }
    if (decals.isEmpty) {
      _finalizeMergedSurface();
      return;
    }

    final selfWorld = worldTransformMatrix;
    final selfIsIdentity = selfWorld.isIdentity();
    if (!selfIsIdentity) {
      _invSelf
        ..setFrom(selfWorld)
        ..invert();
    }

    final terrainWorld = terrain.worldTransformMatrix;
    final terrainIsIdentity = terrainWorld.isIdentity();
    _invTarget.setFrom(terrainWorld);
    if (!terrainIsIdentity && _invTarget.invert().abs() <= 1e-15) {
      _finalizeMergedSurface();
      return;
    }

    final tm = terrainWorld.storage;
    // Normals go through the inverse transpose of the terrain's matrix, which
    // keeps them perpendicular to the surface under non-uniform scale.
    final im = _invTarget.storage;
    final cols = terrain.gridColumns;
    final rows = terrain.gridRows;
    final halfW = terrain.worldWidth * 0.5;
    final halfD = terrain.worldDepth * 0.5;
    final cellW = terrain.worldWidth / (cols - 1);
    final cellD = terrain.worldDepth / (rows - 1);
    final nScratch = Vector3.zero();

    (double, double, double, double, double, double) terrainVertex(
      int c,
      int r,
    ) {
      final lx = -halfW + c * cellW;
      final lz = -halfD + r * cellD;
      final ly = terrain.heights[r * cols + c];
      terrain.sampleNormal(lx, lz, out: nScratch);
      if (terrainIsIdentity) {
        return (lx, ly, lz, nScratch.x, nScratch.y, nScratch.z);
      }
      final wx = tm[0] * lx + tm[4] * ly + tm[8] * lz + tm[12];
      final wy = tm[1] * lx + tm[5] * ly + tm[9] * lz + tm[13];
      final wz = tm[2] * lx + tm[6] * ly + tm[10] * lz + tm[14];
      var wnx = im[0] * nScratch.x + im[1] * nScratch.y + im[2] * nScratch.z;
      var wny = im[4] * nScratch.x + im[5] * nScratch.y + im[6] * nScratch.z;
      var wnz = im[8] * nScratch.x + im[9] * nScratch.y + im[10] * nScratch.z;
      final len = math.sqrt(wnx * wnx + wny * wny + wnz * wnz);
      if (len > 1e-12) {
        wnx /= len;
        wny /= len;
        wnz /= len;
      }
      return (wx, wy, wz, wnx, wny, wnz);
    }

    for (var dIdx = 0; dIdx < decals.length; dIdx++) {
      final decal = decals[dIdx];
      _projectedDecalCount++;
      final boxFrame = _prepareDecalBoxFrame(decal);

      _localQueryAabb.setFrom(_decalWorldAabb);
      if (!terrainIsIdentity) {
        _localQueryAabb.transform(_invTarget);
      }

      final c0 = ((_localQueryAabb.min.x + halfW) / cellW).floor().clamp(
        0,
        cols - 2,
      );
      final c1 = ((_localQueryAabb.max.x + halfW) / cellW).ceil().clamp(
        0,
        cols - 1,
      );
      final r0 = ((_localQueryAabb.min.z + halfD) / cellD).floor().clamp(
        0,
        rows - 2,
      );
      final r1 = ((_localQueryAabb.max.z + halfD) / cellD).ceil().clamp(
        0,
        rows - 1,
      );

      for (var r = r0; r < r1; r++) {
        for (var c = c0; c < c1; c++) {
          final v00 = terrainVertex(c, r);
          final v10 = terrainVertex(c + 1, r);
          final v11 = terrainVertex(c + 1, r + 1);
          final v01 = terrainVertex(c, r + 1);

          // Triangle 1: (v00, v01, v11) CCW +Y
          _emitTerrainTri(
            decal,
            boxFrame,
            v00,
            v01,
            v11,
            selfIsIdentity: selfIsIdentity,
          );
          // Triangle 2: (v00, v11, v10) CCW +Y
          _emitTerrainTri(
            decal,
            boxFrame,
            v00,
            v11,
            v10,
            selfIsIdentity: selfIsIdentity,
          );
        }
      }
    }

    _finalizeMergedSurface();
  }

  @override
  Aabb3? computeLocalAabb() {
    if (_mergedSurface == null || _vertCount == 0) {
      return null;
    }
    return _localAabb;
  }

  @override
  void onRemove() {
    _mergedSurface?.dispose();
    _mergedSurface = null;
    super.onRemove();
  }

  @override
  void draw(covariant RenderContext3D context) {
    final surface = _mergedSurface;
    if (surface == null || _idxCount < 3 || context.isShadowPass) {
      return;
    }
    context.drawSurface(
      surface,
      transform: worldTransformMatrix,
      material: material,
    );
  }

  void _emitTerrainTri(
    ProjectedDecalBox3D decal,
    _DecalBoxFrame boxFrame,
    (double, double, double, double, double, double) a,
    (double, double, double, double, double, double) b,
    (double, double, double, double, double, double) c, {
    required bool selfIsIdentity,
  }) {
    final e1x = b.$1 - a.$1;
    final e1y = b.$2 - a.$2;
    final e1z = b.$3 - a.$3;
    final e2x = c.$1 - a.$1;
    final e2y = c.$2 - a.$2;
    final e2z = c.$3 - a.$3;
    var fnx = e1y * e2z - e1z * e2y;
    var fny = e1z * e2x - e1x * e2z;
    var fnz = e1x * e2y - e1y * e2x;
    final len = math.sqrt(fnx * fnx + fny * fny + fnz * fnz);
    if (len <= 1e-12) {
      return;
    }
    fnx /= len;
    fny /= len;
    fnz /= len;

    _clipAndEmitWorldTriangle(
      decal,
      boxFrame,
      a.$1,
      a.$2,
      a.$3,
      a.$4,
      a.$5,
      a.$6,
      b.$1,
      b.$2,
      b.$3,
      b.$4,
      b.$5,
      b.$6,
      c.$1,
      c.$2,
      c.$3,
      c.$4,
      c.$5,
      c.$6,
      fnx,
      fny,
      fnz,
      selfIsIdentity: selfIsIdentity,
    );
  }

  void _resetAccumulators() {
    _mergedSurface?.dispose();
    _mergedSurface = null;
    _vertCount = 0;
    _idxCount = 0;
    _projectedDecalCount = 0;
    _localAabb.setZero();
  }

  void _finalizeMergedSurface() {
    _mergedSurface?.dispose();
    if (_vertCount == 0 || _idxCount < 3) {
      _mergedSurface = null;
      markAabbDirty();
      worldOrNull?.markSceneDirty(shadows: false);
      return;
    }

    final stride = VertexLayout.standard.strideInFloats;
    final verts = Float32List.fromList(
      Float32List.sublistView(_vertScratch, 0, _vertCount * stride),
    );
    final List<int> indices;
    if (_vertCount > 0xFFFF) {
      indices = Uint32List(_idxCount);
      for (var i = 0; i < _idxCount; i++) {
        indices[i] = _idxScratch[i];
      }
    } else {
      indices = Uint16List(_idxCount);
      for (var i = 0; i < _idxCount; i++) {
        indices[i] = _idxScratch[i];
      }
    }

    var minX = double.infinity;
    var minY = double.infinity;
    var minZ = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    var maxZ = double.negativeInfinity;
    for (var v = 0; v < _vertCount; v++) {
      final o = v * stride;
      final x = verts[o];
      final y = verts[o + 1];
      final z = verts[o + 2];
      minX = math.min(minX, x);
      maxX = math.max(maxX, x);
      minY = math.min(minY, y);
      maxY = math.max(maxY, y);
      minZ = math.min(minZ, z);
      maxZ = math.max(maxZ, z);
    }
    _localAabb
      ..min.setValues(minX - 1e-3, minY - 1e-3, minZ - 1e-3)
      ..max.setValues(maxX + 1e-3, maxY + 1e-3, maxZ + 1e-3);

    _mergedSurface = Surface.fromBuffers(
      vertices: verts,
      indices: indices,
      material: material,
      aabb: Aabb3.copy(_localAabb),
    );
    markAabbDirty();
    worldOrNull?.markSceneDirty(shadows: false);
  }

  _DecalBoxFrame _prepareDecalBoxFrame(ProjectedDecalBox3D decal) {
    final q = decal.rotation;
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

    final cx = decal.center.x;
    final cy = decal.center.y;
    final cz = decal.center.z;
    final hx = decal.halfExtents.x;
    final hy = decal.halfExtents.y;
    final hz = decal.halfExtents.z;

    // World AABB of the OBB.
    final extX = r0.abs() * hx + r3.abs() * hy + r6.abs() * hz;
    final extY = r1.abs() * hx + r4.abs() * hy + r7.abs() * hz;
    final extZ = r2.abs() * hx + r5.abs() * hy + r8.abs() * hz;
    _decalWorldAabb
      ..min.setValues(cx - extX, cy - extY, cz - extZ)
      ..max.setValues(cx + extX, cy + extY, cz + extZ);

    final receiveNx = decal.projectionAxis == DecalProjectionAxis3D.negativeY
        ? r3
        : r6;
    final receiveNy = decal.projectionAxis == DecalProjectionAxis3D.negativeY
        ? r4
        : r7;
    final receiveNz = decal.projectionAxis == DecalProjectionAxis3D.negativeY
        ? r5
        : r8;

    return _DecalBoxFrame(
      cx: cx,
      cy: cy,
      cz: cz,
      hx: hx,
      hy: hy,
      hz: hz,
      invHx: 1.0 / hx,
      invHy: 1.0 / hy,
      invHz: 1.0 / hz,
      r00: r0,
      r01: r3,
      r02: r6,
      r10: r1,
      r11: r4,
      r12: r7,
      r20: r2,
      r21: r5,
      r22: r8,
      receiveNx: receiveNx,
      receiveNy: receiveNy,
      receiveNz: receiveNz,
    );
  }

  void _clipAndEmitWorldTriangle(
    ProjectedDecalBox3D decal,
    _DecalBoxFrame f,
    double x0,
    double y0,
    double z0,
    double n0x,
    double n0y,
    double n0z,
    double x1,
    double y1,
    double z1,
    double n1x,
    double n1y,
    double n1z,
    double x2,
    double y2,
    double z2,
    double n2x,
    double n2y,
    double n2z,
    double faceNx,
    double faceNy,
    double faceNz, {
    required bool selfIsIdentity,
  }) {
    final cosAngle =
        faceNx * f.receiveNx + faceNy * f.receiveNy + faceNz * f.receiveNz;
    if (cosAngle <= decal.normalAngleFadeCos) {
      return;
    }

    final double angleFade;
    if (decal.normalFadeWidth <= 1e-5) {
      angleFade = 1.0;
    } else {
      final t = ((cosAngle - decal.normalAngleFadeCos) / decal.normalFadeWidth)
          .clamp(0.0, 1.0);
      angleFade = t * t * (3.0 - 2.0 * t);
    }

    _writeBoxVertex(f, x0, y0, z0, n0x, n0y, n0z, _polyA, 0);
    _writeBoxVertex(f, x1, y1, z1, n1x, n1y, n1z, _polyA, 6);
    _writeBoxVertex(f, x2, y2, z2, n2x, n2y, n2z, _polyA, 12);

    var n = 3;
    n = _clipAxis(_polyA, n, _polyB, 0, minSide: true);
    if (n < 3) {
      return;
    }
    n = _clipAxis(_polyB, n, _polyA, 0, minSide: false);
    if (n < 3) {
      return;
    }
    n = _clipAxis(_polyA, n, _polyB, 1, minSide: true);
    if (n < 3) {
      return;
    }
    n = _clipAxis(_polyB, n, _polyA, 1, minSide: false);
    if (n < 3) {
      return;
    }
    n = _clipAxis(_polyA, n, _polyB, 2, minSide: true);
    if (n < 3) {
      return;
    }
    n = _clipAxis(_polyB, n, _polyA, 2, minSide: false);
    if (n < 3) {
      return;
    }

    const stride = 20;
    _ensureVertexCapacity(_vertCount + n);
    _ensureIndexCapacity(_idxCount + (n - 2) * 3);

    final baseVert = _vertCount;
    final uvRect = decal.uvRect;
    final col = decal.color;
    final premul = material.renderState.blend == BlendState.premultipliedAlpha;
    final isNegY = decal.projectionAxis == DecalProjectionAxis3D.negativeY;
    final invS = _invSelf.storage;

    for (var i = 0; i < n; i++) {
      final po = i * 6;
      final bx = _polyA[po];
      final by = _polyA[po + 1];
      final bz = _polyA[po + 2];
      var wnx = _polyA[po + 3];
      var wny = _polyA[po + 4];
      var wnz = _polyA[po + 5];
      final nLen = math.sqrt(wnx * wnx + wny * wny + wnz * wnz);
      if (nLen > 1e-12) {
        wnx /= nLen;
        wny /= nLen;
        wnz /= nLen;
      } else {
        wnx = faceNx;
        wny = faceNy;
        wnz = faceNz;
      }

      final lx = bx * f.hx;
      final ly = by * f.hy;
      final lz = bz * f.hz;
      final wx =
          f.cx + f.r00 * lx + f.r01 * ly + f.r02 * lz + wnx * normalOffset;
      final wy =
          f.cy + f.r10 * lx + f.r11 * ly + f.r12 * lz + wny * normalOffset;
      final wz =
          f.cz + f.r20 * lx + f.r21 * ly + f.r22 * lz + wnz * normalOffset;

      double outX;
      double outY;
      double outZ;
      double outNx;
      double outNy;
      double outNz;
      if (selfIsIdentity) {
        outX = wx;
        outY = wy;
        outZ = wz;
        outNx = wnx;
        outNy = wny;
        outNz = wnz;
      } else {
        outX = invS[0] * wx + invS[4] * wy + invS[8] * wz + invS[12];
        outY = invS[1] * wx + invS[5] * wy + invS[9] * wz + invS[13];
        outZ = invS[2] * wx + invS[6] * wy + invS[10] * wz + invS[14];
        outNx = invS[0] * wnx + invS[4] * wny + invS[8] * wnz;
        outNy = invS[1] * wnx + invS[5] * wny + invS[9] * wnz;
        outNz = invS[2] * wnx + invS[6] * wny + invS[10] * wnz;
        final lLen = math.sqrt(outNx * outNx + outNy * outNy + outNz * outNz);
        if (lLen > 1e-12) {
          outNx /= lLen;
          outNy /= lLen;
          outNz /= lLen;
        }
      }

      final u01 = ((bx + 1.0) * 0.5).clamp(0.0, 1.0);
      final v01 = isNegY
          ? ((bz + 1.0) * 0.5).clamp(0.0, 1.0)
          : ((1.0 - by) * 0.5).clamp(0.0, 1.0);
      final u = uvRect.left + u01 * uvRect.width;
      final v = uvRect.top + v01 * uvRect.height;

      var depthFade = 1.0;
      if (boxEdgeFeather > 1e-5) {
        final depthCoord = (isNegY ? by : bz).abs();
        final featherStart = (1.0 - boxEdgeFeather * 2.0).clamp(0.0, 0.999);
        if (depthCoord > featherStart) {
          final dt = ((1.0 - depthCoord) / (1.0 - featherStart)).clamp(
            0.0,
            1.0,
          );
          depthFade = dt * dt * (3.0 - 2.0 * dt);
        }
      }

      final alpha = (col.a * angleFade * depthFade).clamp(0.0, 1.0);
      final rgbMul = premul ? alpha : 1.0;

      final vo = (_vertCount + i) * stride;
      _vertScratch
        ..[vo] = outX
        ..[vo + 1] = outY
        ..[vo + 2] = outZ
        ..[vo + 3] = u
        ..[vo + 4] = v
        ..[vo + 5] = col.r * rgbMul
        ..[vo + 6] = col.g * rgbMul
        ..[vo + 7] = col.b * rgbMul
        ..[vo + 8] = alpha
        ..[vo + 9] = outNx
        ..[vo + 10] = outNy
        ..[vo + 11] = outNz
        ..[vo + 12] = 0
        ..[vo + 13] = 0
        ..[vo + 14] = 0
        ..[vo + 15] = 0
        ..[vo + 16] = 0
        ..[vo + 17] = 0
        ..[vo + 18] = 0
        ..[vo + 19] = 0;
    }

    _vertCount += n;
    for (var k = 1; k + 1 < n; k++) {
      _idxScratch
        ..[_idxCount] = baseVert
        ..[_idxCount + 1] = baseVert + k
        ..[_idxCount + 2] = baseVert + k + 1;
      _idxCount += 3;
    }
  }

  static void _writeBoxVertex(
    _DecalBoxFrame f,
    double wx,
    double wy,
    double wz,
    double wnx,
    double wny,
    double wnz,
    Float64List out,
    int o,
  ) {
    final dx = wx - f.cx;
    final dy = wy - f.cy;
    final dz = wz - f.cz;
    // Transpose of orthonormal rotation `R` maps world delta to local box axes.
    out
      ..[o] = (f.r00 * dx + f.r10 * dy + f.r20 * dz) * f.invHx
      ..[o + 1] = (f.r01 * dx + f.r11 * dy + f.r21 * dz) * f.invHy
      ..[o + 2] = (f.r02 * dx + f.r12 * dy + f.r22 * dz) * f.invHz
      ..[o + 3] = wnx
      ..[o + 4] = wny
      ..[o + 5] = wnz;
  }

  static int _clipAxis(
    Float64List src,
    int count,
    Float64List dst,
    int axis, {
    required bool minSide,
  }) {
    var outCount = 0;
    for (var i = 0; i < count; i++) {
      final a = i * 6;
      final b = ((i + 1) % count) * 6;
      final da = minSide ? (src[a + axis] + 1.0) : (1.0 - src[a + axis]);
      final db = minSide ? (src[b + axis] + 1.0) : (1.0 - src[b + axis]);
      final aIn = da >= -1e-9;
      final bIn = db >= -1e-9;
      if (aIn) {
        final o = outCount++ * 6;
        for (var k = 0; k < 6; k++) {
          dst[o + k] = src[a + k];
        }
      }
      if (aIn != bIn) {
        final t = (da / (da - db)).clamp(0.0, 1.0);
        final o = outCount++ * 6;
        for (var k = 0; k < 6; k++) {
          dst[o + k] = src[a + k] + (src[b + k] - src[a + k]) * t;
        }
        dst[o + axis] = minSide ? -1.0 : 1.0;
      }
    }
    return outCount;
  }

  static (double, double, double) _transformNormal(
    double c00,
    double c01,
    double c02,
    double c10,
    double c11,
    double c12,
    double c20,
    double c21,
    double c22,
    double sgn,
    double nx,
    double ny,
    double nz,
    double fallbackX,
    double fallbackY,
    double fallbackZ,
  ) {
    final wnx = (c00 * nx + c10 * ny + c20 * nz) * sgn;
    final wny = (c01 * nx + c11 * ny + c21 * nz) * sgn;
    final wnz = (c02 * nx + c12 * ny + c22 * nz) * sgn;
    final len = math.sqrt(wnx * wnx + wny * wny + wnz * wnz);
    if (len > 1e-12) {
      return (wnx / len, wny / len, wnz / len);
    }
    return (fallbackX, fallbackY, fallbackZ);
  }

  static _DecalSurfaceAabbBvh _getOrBuildBvh(Surface surface) {
    final cached = _surfaceBvhCache[surface];
    if (cached != null &&
        cached.vertexCount == surface.vertexCount &&
        cached.indexCount == surface.indexCount) {
      return cached;
    }
    final built = _DecalSurfaceAabbBvh.build(surface);
    _surfaceBvhCache[surface] = built;
    return built;
  }

  void _ensureVertexCapacity(int requiredVerts) {
    const stride = 20;
    final neededFloats = requiredVerts * stride;
    if (_vertScratch.length >= neededFloats) {
      return;
    }
    var newCap = _vertScratch.length * 2;
    while (newCap < neededFloats) {
      newCap *= 2;
    }
    final next = Float32List(newCap)
      ..setRange(0, _vertCount * stride, _vertScratch);
    _vertScratch = next;
  }

  void _ensureIndexCapacity(int requiredIndices) {
    if (_idxScratch.length >= requiredIndices) {
      return;
    }
    var newCap = _idxScratch.length * 2;
    while (newCap < requiredIndices) {
      newCap *= 2;
    }
    final next = Int32List(newCap)..setRange(0, _idxCount, _idxScratch);
    _idxScratch = next;
  }
}

class _DecalBoxFrame({
  required final double cx,
  required final double cy,
  required final double cz,
  required final double hx,
  required final double hy,
  required final double hz,
  required final double invHx,
  required final double invHy,
  required final double invHz,
  required final double r00,
  required final double r01,
  required final double r02,
  required final double r10,
  required final double r11,
  required final double r12,
  required final double r20,
  required final double r21,
  required final double r22,
  required final double receiveNx,
  required final double receiveNy,
  required final double receiveNz,
});
