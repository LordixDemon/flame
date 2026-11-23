import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/src/extensions/geometry_math.dart';

class _PalettePart3D(
  final int partId,
  final Mesh mesh,
  final Float32List color,
  final Matrix4 transform, {
  required bool visible,
}) {
  bool visible = visible;
}

/// Matrix-palette rigid batcher ([Object3D]) that merges up to `64`
/// independent rigid [Mesh] parts sharing a [material] into a single [Surface]
/// and renders them in **1 draw call** via `JointMatrices` skinning.
///
/// Each part receives rigid joint weight `1.0` on its `partId`
/// (`vertexJoints`), so [setPartTransform] and [setPartVisible] update parts in
/// `O(1)` by modifying a single `Matrix4` without rebuilding or re-uploading
/// vertex buffers.
class PaletteMeshBatch3D({
  required final Material material,
  final int maxParts = 64,
  final bool bakeVertexColor = true,
  super.position,
  super.rotation,
  super.scale,
  super.children,
  super.castsShadows,
  super.cameraMask,
}) extends Object3D {
  /// Creates a matrix-palette batch sharing [material] across at most
  /// [maxParts] (`1..64`) independently articulated parts.
  this
    : assert(
        maxParts >= 1 && maxParts <= maxJoints,
        'maxParts must be in 1..$maxJoints',
      );

  /// Hard limit imposed by the shader `JointMatrices` uniform block (`64`).
  static const int maxJoints = 64;

  static final Aabb3 _partBoundsScratch = Aabb3();

  final List<_PalettePart3D> _parts = <_PalettePart3D>[];
  final List<Matrix4> _activeJoints = <Matrix4>[];

  Surface? _mergedSurface;
  bool _surfaceDirty = true;
  bool _boundsDirty = true;
  final Aabb3 _localAabb = Aabb3();
  int _visiblePartCount = 0;
  int _lastDrawnCalls = 0;

  /// Number of registered parts (`<= maxParts`).
  int get partCount => _parts.length;

  /// Number of currently visible parts.
  int get visiblePartCount => _visiblePartCount;

  /// Number of GPU draw submissions emitted by the most recent [draw] call
  /// (`0` or `1`).
  int get lastDrawnCalls => _lastDrawnCalls;

  /// Appends [mesh] as rigid part `partId` with initial local [transform],
  /// optional baked [color], and initial [visible] state.
  ///
  /// Throws [StateError] when [maxParts] has been reached, or [ArgumentError]
  /// when any surface of [mesh] is not a triangle list.
  int addPart({
    required Mesh mesh,
    Matrix4? transform,
    Color color = const Color(0xFFFFFFFF),
    bool visible = true,
  }) {
    if (_parts.length >= maxParts) {
      throw StateError(
        'PaletteMeshBatch3D cannot hold more than $maxParts parts',
      );
    }
    for (final surface in mesh.surfaces) {
      if (surface.topology != PrimitiveTopology.triangles) {
        throw ArgumentError.value(
          surface.topology,
          'mesh',
          'PaletteMeshBatch3D merges triangle lists only',
        );
      }
    }
    final partId = _parts.length;
    final mat = transform != null ? transform.clone() : Matrix4.identity();
    final part = _PalettePart3D(
      partId,
      mesh,
      Float32List.fromList([color.r, color.g, color.b, color.a]),
      mat,
      visible: visible,
    );
    _parts.add(part);
    _activeJoints.add(visible ? mat.clone() : Matrix4.zero());
    if (visible) {
      _visiblePartCount++;
    }
    _surfaceDirty = true;
    _boundsDirty = true;
    markAabbDirty();
    markDrawDirty(shadows: castsShadows);
    return partId;
  }

  /// Updates the local transform of [partId] in `O(1)` without rebuilding
  /// geometry or uploading vertex buffers.
  void setPartTransform(int partId, Matrix4 transform) {
    RangeError.checkValidIndex(partId, _parts, 'partId');
    final part = _parts[partId];
    part.transform.setFrom(transform);
    if (part.visible) {
      _activeJoints[partId].setFrom(transform);
    }
    _boundsDirty = true;
    markAabbDirty();
    markDrawDirty(shadows: castsShadows);
  }

  /// Shows or hides [partId] in `O(1)` without rebuilding or uploading vertex
  /// buffers.
  void setPartVisible(int partId, {required bool visible}) {
    RangeError.checkValidIndex(partId, _parts, 'partId');
    final part = _parts[partId];
    if (part.visible == visible) {
      return;
    }
    part.visible = visible;
    if (visible) {
      _visiblePartCount++;
      _activeJoints[partId].setFrom(part.transform);
    } else {
      _visiblePartCount--;
      _activeJoints[partId].setZero();
    }
    _boundsDirty = true;
    markAabbDirty();
    markDrawDirty(shadows: castsShadows);
  }

  /// Whether [partId] is currently visible.
  bool isPartVisible(int partId) {
    RangeError.checkValidIndex(partId, _parts, 'partId');
    return _parts[partId].visible;
  }

  /// Copies the current local transform of [partId] into [out] (or a new
  /// [Matrix4]).
  Matrix4 partTransform(int partId, {Matrix4? out}) {
    RangeError.checkValidIndex(partId, _parts, 'partId');
    final dst = out ?? Matrix4.zero();
    dst.setFrom(_parts[partId].transform);
    return dst;
  }

  /// Removes all parts and disposes any merged GPU surface.
  void clear() {
    _parts.clear();
    _activeJoints.clear();
    _mergedSurface?.dispose();
    _mergedSurface = null;
    _surfaceDirty = false;
    _visiblePartCount = 0;
    _lastDrawnCalls = 0;
    _boundsDirty = true;
    markAabbDirty();
    markDrawDirty(shadows: castsShadows);
  }

  /// Eagerly builds or rebuilds the merged palette [Surface] if needed.
  void bake() {
    if (_surfaceDirty) {
      _ensureBaked();
    }
  }

  void _ensureBaked() {
    if (!_surfaceDirty) {
      return;
    }
    _surfaceDirty = false;
    _mergedSurface?.dispose();
    _mergedSurface = null;
    if (_parts.isEmpty) {
      return;
    }

    var usePbr = false;
    var totalVertices = 0;
    var totalIndices = 0;
    for (var i = 0; i < _parts.length; i++) {
      for (final src in _parts[i].mesh.surfaces) {
        if (src.vertexCount == 0 || src.indexCount < 3) {
          continue;
        }
        totalVertices += src.vertexCount;
        totalIndices += src.indexCount;
        if (src.layout.offsetOf(VertexLayout.tangentAttribute) != null ||
            src.layout.offsetOf(VertexLayout.texCoord1Attribute) != null) {
          usePbr = true;
        }
      }
    }
    if (totalVertices == 0 || totalIndices == 0) {
      return;
    }

    final dstLayout = usePbr ? VertexLayout.pbrStandard : VertexLayout.standard;
    final dstStride = dstLayout.strideInFloats;
    final dstPos = dstLayout.offsetOf(VertexLayout.positionAttribute)!;
    final dstUv = dstLayout.offsetOf('vertexTexCoord')!;
    final dstCol = dstLayout.offsetOf('vertexColor')!;
    final dstNrm = dstLayout.offsetOf('vertexNormal')!;
    final dstJoint = dstLayout.offsetOf('vertexJoints')!;
    final dstWeight = dstLayout.offsetOf('vertexWeights')!;
    final dstTan = usePbr
        ? dstLayout.offsetOf(VertexLayout.tangentAttribute)!
        : -1;
    final dstUv1 = usePbr
        ? dstLayout.offsetOf(VertexLayout.texCoord1Attribute)!
        : -1;

    final verts = Float32List(totalVertices * dstStride);
    final useWide = totalVertices > 0xFFFF;
    final List<int> indices = useWide
        ? Uint32List(totalIndices)
        : Uint16List(totalIndices);

    var vertBase = 0;
    var idxCursor = 0;

    for (var pIdx = 0; pIdx < _parts.length; pIdx++) {
      final part = _parts[pIdx];
      final jointId = part.partId.toDouble();
      final pCol = part.color;

      for (final src in part.mesh.surfaces) {
        final vCount = src.vertexCount;
        final srcIndices = src.indices;
        final iCount = srcIndices.length;
        if (vCount == 0 || iCount < 3) {
          continue;
        }

        final sLayout = src.layout;
        final sStride = sLayout.strideInFloats;
        final sData = src.vertexData;
        final sPos = sLayout.offsetOf(VertexLayout.positionAttribute);
        final sUv = sLayout.offsetOf('vertexTexCoord');
        final sCol = sLayout.offsetOf('vertexColor');
        final sNrm = sLayout.offsetOf('vertexNormal');
        final sTan = sLayout.offsetOf(VertexLayout.tangentAttribute);
        final sUv1 = sLayout.offsetOf(VertexLayout.texCoord1Attribute);

        for (var v = 0; v < vCount; v++) {
          final so = v * sStride;
          final doBase = (vertBase + v) * dstStride;
          if (sPos != null) {
            verts[doBase + dstPos] = sData[so + sPos];
            verts[doBase + dstPos + 1] = sData[so + sPos + 1];
            verts[doBase + dstPos + 2] = sData[so + sPos + 2];
          }
          if (sUv != null) {
            verts[doBase + dstUv] = sData[so + sUv];
            verts[doBase + dstUv + 1] = sData[so + sUv + 1];
          }
          final cr = sCol != null ? sData[so + sCol] : 1.0;
          final cg = sCol != null ? sData[so + sCol + 1] : 1.0;
          final cb = sCol != null ? sData[so + sCol + 2] : 1.0;
          final ca = sCol != null ? sData[so + sCol + 3] : 1.0;
          if (bakeVertexColor) {
            verts[doBase + dstCol] = cr * pCol[0];
            verts[doBase + dstCol + 1] = cg * pCol[1];
            verts[doBase + dstCol + 2] = cb * pCol[2];
            verts[doBase + dstCol + 3] = ca * pCol[3];
          } else {
            verts[doBase + dstCol] = cr;
            verts[doBase + dstCol + 1] = cg;
            verts[doBase + dstCol + 2] = cb;
            verts[doBase + dstCol + 3] = ca;
          }
          if (sNrm != null) {
            verts[doBase + dstNrm] = sData[so + sNrm];
            verts[doBase + dstNrm + 1] = sData[so + sNrm + 1];
            verts[doBase + dstNrm + 2] = sData[so + sNrm + 2];
          } else {
            verts[doBase + dstNrm + 1] = 1.0;
          }
          verts[doBase + dstJoint] = jointId;
          verts[doBase + dstWeight] = 1.0;
          if (usePbr) {
            if (sTan != null) {
              verts[doBase + dstTan] = sData[so + sTan];
              verts[doBase + dstTan + 1] = sData[so + sTan + 1];
              verts[doBase + dstTan + 2] = sData[so + sTan + 2];
              verts[doBase + dstTan + 3] = sData[so + sTan + 3];
            } else {
              verts[doBase + dstTan] = 1.0;
              verts[doBase + dstTan + 3] = 1.0;
            }
            if (sUv1 != null) {
              verts[doBase + dstUv1] = sData[so + sUv1];
              verts[doBase + dstUv1 + 1] = sData[so + sUv1 + 1];
            }
          }
        }

        for (var k = 0; k < iCount; k++) {
          indices[idxCursor + k] = vertBase + srcIndices[k];
        }
        vertBase += vCount;
        idxCursor += iCount;
      }
    }

    _mergedSurface = Surface.fromBuffers(
      vertices: verts,
      indices: indices,
      layout: dstLayout,
      material: material,
    );
  }

  @override
  Aabb3? computeLocalAabb() {
    if (_visiblePartCount == 0) {
      return null;
    }
    if (_boundsDirty) {
      _boundsDirty = false;
      var minX = double.infinity;
      var minY = double.infinity;
      var minZ = double.infinity;
      var maxX = double.negativeInfinity;
      var maxY = double.negativeInfinity;
      var maxZ = double.negativeInfinity;
      var any = false;

      for (var i = 0; i < _parts.length; i++) {
        final part = _parts[i];
        if (!part.visible) {
          continue;
        }
        final box = part.mesh.aabb;
        transformAabbArvo(
          part.transform.storage,
          0,
          0.5 * (box.min.x + box.max.x),
          0.5 * (box.min.y + box.max.y),
          0.5 * (box.min.z + box.max.z),
          0.5 * (box.max.x - box.min.x),
          0.5 * (box.max.y - box.min.y),
          0.5 * (box.max.z - box.min.z),
          _partBoundsScratch,
        );

        minX = math.min(minX, _partBoundsScratch.min.x);
        minY = math.min(minY, _partBoundsScratch.min.y);
        minZ = math.min(minZ, _partBoundsScratch.min.z);
        maxX = math.max(maxX, _partBoundsScratch.max.x);
        maxY = math.max(maxY, _partBoundsScratch.max.y);
        maxZ = math.max(maxZ, _partBoundsScratch.max.z);
        any = true;
      }

      if (!any) {
        return null;
      }
      _localAabb
        ..min.setValues(minX, minY, minZ)
        ..max.setValues(maxX, maxY, maxZ);
    }
    return _localAabb;
  }

  @override
  void draw(covariant RenderContext3D context) {
    _lastDrawnCalls = 0;
    if (_parts.isEmpty || _visiblePartCount == 0) {
      return;
    }
    _ensureBaked();
    final surface = _mergedSurface;
    if (surface == null) {
      return;
    }
    context.drawSurface(
      surface,
      transform: worldTransformMatrix,
      jointTransforms: _activeJoints,
      material: material,
    );
    _lastDrawnCalls = 1;
  }

  @override
  RayHit3D? raycast(
    Ray worldRay, {
    double maxDistance = double.infinity,
    CullMode? cullMode,
  }) {
    if (_visiblePartCount == 0 || !(maxDistance > 0)) {
      return null;
    }
    final worldMat = worldTransformMatrix;
    RayHit3D? best;
    var bestPartId = 0;
    var limit = maxDistance;
    for (var i = 0; i < _parts.length; i++) {
      final part = _parts[i];
      if (!part.visible) {
        continue;
      }
      _rayMatrixScratch
        ..setFrom(worldMat)
        ..multiply(part.transform);
      final hit = RayHit3D.intersectMesh(
        owner: this,
        mesh: part.mesh,
        modelMatrix: _rayMatrixScratch,
        worldRay: worldRay,
        maxDistance: limit,
        cullMode: cullMode,
      );
      if (hit != null && hit.distance < limit) {
        limit = hit.distance;
        best = hit;
        bestPartId = part.partId;
      }
    }
    return best?.onInstance(bestPartId);
  }

  @override
  void onRemove() {
    _mergedSurface?.dispose();
    _mergedSurface = null;
    _surfaceDirty = true;
    super.onRemove();
  }

  static final Matrix4 _rayMatrixScratch = Matrix4.identity();
}
