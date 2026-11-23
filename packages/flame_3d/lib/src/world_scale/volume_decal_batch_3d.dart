import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Color, Rect;

import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/src/world_scale/chunked_terrain_3d.dart';

part 'volume_decal_clipper_3d.dart';

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
    markDrawDirty(shadows: false);
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

        _candidateTriangles.clear();
        final hitCount = surface.bvh.queryAabbExtents(
          _localQueryAabb.min.x,
          _localQueryAabb.min.y,
          _localQueryAabb.min.z,
          _localQueryAabb.max.x,
          _localQueryAabb.max.y,
          _localQueryAabb.max.z,
          _candidateTriangles,
          filterTriangles: true,
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
}
