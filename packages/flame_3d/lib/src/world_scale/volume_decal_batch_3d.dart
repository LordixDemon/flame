import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Color, Rect;

import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/src/world_scale/chunked_terrain_3d.dart';

part 'volume_decal_clipper_3d.dart';
part 'volume_decal_terrain_3d.dart';

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
  final Float64List _triNormals = Float64List(9);
  final _DecalBoxFrame _boxFrame = _DecalBoxFrame();
  Float64List _terrainRowA = Float64List(0);
  Float64List _terrainRowB = Float64List(0);
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

          final norms = _triNormals;
          if (nrmOffset != null) {
            final sgn = flip ? -1.0 : 1.0;
            final no0 = idx0 * stride + nrmOffset;
            final no1 = idx1 * stride + nrmOffset;
            final no2 = idx2 * stride + nrmOffset;
            _transformNormalInto(
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
              norms,
              0,
            );
            _transformNormalInto(
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
              norms,
              3,
            );
            _transformNormalInto(
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
              norms,
              6,
            );
          } else {
            norms
              ..[0] = fnx
              ..[1] = fny
              ..[2] = fnz
              ..[3] = fnx
              ..[4] = fny
              ..[5] = fnz
              ..[6] = fnx
              ..[7] = fny
              ..[8] = fnz;
          }

          _clipAndEmitWorldTriangle(
            decal,
            boxFrame,
            w0x,
            w0y,
            w0z,
            norms[0],
            norms[1],
            norms[2],
            w1x,
            w1y,
            w1z,
            norms[3],
            norms[4],
            norms[5],
            w2x,
            w2y,
            w2z,
            norms[6],
            norms[7],
            norms[8],
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
  }) => _projectOntoTerrainImpl(decals, terrain, append: append);

  @override
  bool get usesDefaultFrustumVisibility => runtimeType == VolumeDecalBatch3D;

  @override
  Aabb3? computeLocalAabb() {
    if (_mergedSurface == null || _vertCount == 0) {
      return null;
    }
    return _localAabb;
  }

  /// Releases GPU buffers held by this batch while retaining CPU geometry so
  /// a later [onMount] recreates the surface automatically.
  void disposeGpuResources() {
    _mergedSurface?.dispose();
  }

  @override
  void onRemove() {
    disposeGpuResources();
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
