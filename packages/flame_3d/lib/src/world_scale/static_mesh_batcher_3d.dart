import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:meta/meta.dart';

@immutable
class const _ChunkKey3D(
  final int cx,
  final int cy,
  final int cz,
) {
  @override
  bool operator ==(Object other) =>
      other is _ChunkKey3D &&
      other.cx == cx &&
      other.cy == cy &&
      other.cz == cz;

  @override
  int get hashCode => Object.hash(cx, cy, cz);
}

@immutable
class const _BatchGroupKey3D(
  final _ChunkKey3D chunk,
  final Material material,
  final VertexLayout layout,

  /// The instance color the merged surface is drawn with: white when the
  /// pieces' colors are baked into their vertex colors.
  final Color color,

  /// The instance data the merged surface is drawn with.
  final (double, double, double, double) instanceData, {

  /// Whether piece colors should be baked into vertex colors when supported by
  /// [material] and [layout].
  this.bakeColor = true,
}) {
  /// Whether vertex colors should be baked for pieces matching this key.
  final bool bakeColor;

  /// Whether the pieces' colors are multiplied into their vertex colors
  /// instead of being drawn as the instance color.
  bool get bakesColor => bakeColor && _bakesColor(material, layout);

  /// Whether [material] multiplies its vertex colors and its instance color
  /// alike, so that a color baked into the vertex colors of [layout] looks
  /// the same as the instance color.
  static bool _bakesColor(Material material, VertexLayout layout) {
    final type = material.runtimeType;
    return (type == SpatialMaterial || type == UnlitMaterial) &&
        layout.offsetOf('vertexColor') != null;
  }

  @override
  bool operator ==(Object other) =>
      other is _BatchGroupKey3D &&
      other.chunk == chunk &&
      identical(other.material, material) &&
      other.layout == layout &&
      other.color == color &&
      other.instanceData == instanceData &&
      other.bakeColor == bakeColor;

  @override
  int get hashCode => Object.hash(
    chunk,
    identityHashCode(material),
    layout,
    color,
    instanceData,
    bakeColor,
  );
}

class _SlotPiece3D(
  final int slotId,
  final Surface sourceSurface,
  final Float32List transformStorage,
  final double colorR,
  final double colorG,
  final double colorB,
  final double colorA,
  final Aabb3 localBounds,
) {
  bool visible = true;
  bool removed = false;
  int indexOffset = 0;
  int indexCount = 0;
  Int32List? bakedIndices;
}

class _MergedChunkBatch3D(
  final _BatchGroupKey3D key,
) {
  final List<_SlotPiece3D> pieces = <_SlotPiece3D>[];
  Float32List? bakedVertices;
  List<int>? bakedIndices;
  Surface? surface;
  final Aabb3 localAabb = Aabb3();
  // Whether any piece is visible, i.e. [localAabb] holds geometry.
  bool hasVisibleGeometry = false;
  bool needsFullBake = true;
  int activePieceCount = 0;
  late final Vector4 instanceData = Vector4(
    key.instanceData.$1,
    key.instanceData.$2,
    key.instanceData.$3,
    key.instanceData.$4,
  );

  void disposeSurface() {
    surface?.dispose();
    surface = null;
  }
}

class _SlotRecord3D(final int slotId) {
  bool visible = true;
  bool removed = false;
  final List<(_MergedChunkBatch3D, _SlotPiece3D)> bindings =
      <(_MergedChunkBatch3D, _SlotPiece3D)>[];
}

/// Spatial static-geometry batcher merging heterogeneous [Mesh] instances into
/// 1 [Surface] per spatial grid chunk (`chunkSize = 32.0` by default) and
/// per [Material], [VertexLayout], instance color and instance data.
///
/// Transforms vertex positions, inverse-transpose normals and tangents
/// (preserving outward CCW winding even on mirrored negative-scale
/// transforms) into merged chunk buffers. Each merged surface is drawn with
/// the instance color and instance data its pieces share, so a merged piece
/// looks as it would drawn on its own. For a [SpatialMaterial] or an
/// [UnlitMaterial] on a layout with vertex colors, which multiply vertex and
/// instance colors alike, the color is baked into the vertex colors instead,
/// so pieces of different colors still merge.
///
/// [setSlotVisible] and [removeSlot] rewrite only the slot's indices and
/// upload only that range of the merged surface's buffer, without rebuilding
/// any chunk. Surfaces must be triangle lists.
class StaticMeshBatcher3D({
  final double chunkSize = 32.0,
  final bool bakeVertexColor = true,
  super.position,
  super.scale,
  super.rotation,
  super.children,
  super.castsShadows,
  super.cameraMask,
}) extends Object3D {
  this : assert(chunkSize > 0, 'chunkSize must be positive');

  final Map<_BatchGroupKey3D, _MergedChunkBatch3D> _batches =
      <_BatchGroupKey3D, _MergedChunkBatch3D>{};
  final Map<int, _SlotRecord3D> _slots = <int, _SlotRecord3D>{};

  int _nextSlotId = 0;
  int _fullBakeCount = 0;
  int _surgicalUpdateCount = 0;
  int _lastDrawnBatchCount = 0;

  final Aabb3 _localAabb = Aabb3();
  bool _localBoundsDirty = true;
  bool _hasLocalBounds = false;
  final Aabb3 _worldChunkAabbScratch = Aabb3();

  /// Number of active (non-removed) static instance slots.
  int get activeSlotCount => _slots.length;

  /// Number of distinct spatial `(cx, cy, cz)` grid cells holding geometry.
  int get chunkCount {
    final uniqueChunks = <_ChunkKey3D>{};
    for (final batch in _batches.values) {
      if (batch.activePieceCount > 0) {
        uniqueChunks.add(batch.key.chunk);
      }
    }
    return uniqueChunks.length;
  }

  /// Number of merged `(chunk, material, layout)` surfaces currently managed.
  int get surfaceBatchCount {
    var count = 0;
    for (final batch in _batches.values) {
      if (batch.activePieceCount > 0) {
        count++;
      }
    }
    return count;
  }

  /// Number of merged chunk surfaces submitted in the most recent [draw] call.
  int get lastDrawnBatchCount => _lastDrawnBatchCount;

  /// Total full chunk-bake passes executed so far.
  int get fullBakeCount => _fullBakeCount;

  /// Total surgical index-only slot updates executed without re-transforming
  /// vertices or touching other chunks.
  int get surgicalUpdateCount => _surgicalUpdateCount;

  /// Adds a static [mesh] with local [transform], [color], and optional
  /// [instanceData], returning a handle `slotId` for [setSlotVisible] or
  /// [removeSlot].
  ///
  /// The merged surface is drawn with [color] as its instance color (or with
  /// [color] baked into the vertex colors, see [StaticMeshBatcher3D]) and
  /// with [instanceData]: instances that differ in them are merged into
  /// separate surfaces.
  ///
  /// Throws an [ArgumentError] when a surface of [mesh] is not a triangle
  /// list.
  int addStaticInstance({
    required Mesh mesh,
    required Matrix4 transform,
    Color color = const Color(0xFFFFFFFF),
    Vector4? instanceData,
  }) {
    for (final surface in mesh.surfaces) {
      if (surface.topology != PrimitiveTopology.triangles) {
        throw ArgumentError.value(
          surface.topology,
          'mesh',
          'StaticMeshBatcher3D merges triangle lists only',
        );
      }
    }
    final slotId = _nextSlotId++;
    final record = _SlotRecord3D(slotId);
    final tfStorage = Float32List.fromList(transform.storage);
    final data = (
      instanceData?.x ?? 0.0,
      instanceData?.y ?? 0.0,
      instanceData?.z ?? 0.0,
      instanceData?.w ?? 0.0,
    );

    final meshBox = mesh.aabb;
    final centroidLocalX = 0.5 * (meshBox.min.x + meshBox.max.x);
    final centroidLocalY = 0.5 * (meshBox.min.y + meshBox.max.y);
    final centroidLocalZ = 0.5 * (meshBox.min.z + meshBox.max.z);
    final cxWorld =
        tfStorage[0] * centroidLocalX +
        tfStorage[4] * centroidLocalY +
        tfStorage[8] * centroidLocalZ +
        tfStorage[12];
    final cyWorld =
        tfStorage[1] * centroidLocalX +
        tfStorage[5] * centroidLocalY +
        tfStorage[9] * centroidLocalZ +
        tfStorage[13];
    final czWorld =
        tfStorage[2] * centroidLocalX +
        tfStorage[6] * centroidLocalY +
        tfStorage[10] * centroidLocalZ +
        tfStorage[14];

    final chunkKey = _ChunkKey3D(
      (cxWorld / chunkSize).floor(),
      (cyWorld / chunkSize).floor(),
      (czWorld / chunkSize).floor(),
    );

    for (final srcSurface in mesh.surfaces) {
      if (srcSurface.vertexCount == 0 || srcSurface.indexCount < 3) {
        continue;
      }
      final pieceBounds = Aabb3.copy(srcSurface.aabb)..transform(transform);
      final material = srcSurface.material;
      final layout = srcSurface.layout;
      final bakePieceColor =
          bakeVertexColor && _BatchGroupKey3D._bakesColor(material, layout);
      final groupKey = _BatchGroupKey3D(
        chunkKey,
        material,
        layout,
        bakePieceColor ? const Color(0xFFFFFFFF) : color,
        data,
        bakeColor: bakePieceColor,
      );
      final batch = _batches.putIfAbsent(
        groupKey,
        () => _MergedChunkBatch3D(groupKey),
      );
      final piece = _SlotPiece3D(
        slotId,
        srcSurface,
        tfStorage,
        color.r,
        color.g,
        color.b,
        color.a,
        pieceBounds,
      );
      batch.pieces.add(piece);
      batch.activePieceCount++;
      batch.needsFullBake = true;
      record.bindings.add((batch, piece));
    }

    _slots[slotId] = record;
    _localBoundsDirty = true;
    markAabbDirty();
    markDrawDirty(shadows: castsShadows);
    return slotId;
  }

  /// Returns whether [slotId] is currently registered and visible.
  bool isSlotVisible(int slotId) {
    final record = _slots[slotId];
    return record != null && record.visible;
  }

  /// Shows or hides [slotId] in `O(T_slot)` by surgically toggling only that
  /// slot's triangle indices inside its owning spatial chunk(s), and
  /// uploading only those indices.
  void setSlotVisible(int slotId, {required bool visible}) {
    final record = _slots[slotId];
    if (record == null || record.visible == visible) {
      return;
    }
    record.visible = visible;

    for (final (batch, piece) in record.bindings) {
      piece.visible = visible;
      if (!batch.needsFullBake &&
          batch.bakedVertices != null &&
          batch.bakedIndices != null &&
          piece.bakedIndices != null) {
        _applyPieceIndexState(batch, piece);
        _surgicalUpdateCount++;
      } else {
        batch.needsFullBake = true;
      }
    }

    _localBoundsDirty = true;
    markAabbDirty();
    markDrawDirty(shadows: castsShadows);
  }

  /// Removes [slotId] from the batcher, zeroing its indices in its owning
  /// spatial chunk (and freeing the chunk if it becomes empty).
  bool removeSlot(int slotId) {
    final record = _slots.remove(slotId);
    if (record == null) {
      return false;
    }
    record.removed = true;

    for (final (batch, piece) in record.bindings) {
      piece
        ..removed = true
        ..visible = false;
      batch.activePieceCount--;
      if (batch.activePieceCount <= 0) {
        batch.disposeSurface();
        _batches.remove(batch.key);
      } else if (!batch.needsFullBake &&
          batch.bakedVertices != null &&
          batch.bakedIndices != null &&
          piece.bakedIndices != null) {
        _applyPieceIndexState(batch, piece);
        _recomputeChunkAabb(batch);
        _surgicalUpdateCount++;
      } else {
        batch.needsFullBake = true;
      }
    }

    _localBoundsDirty = true;
    markAabbDirty();
    markDrawDirty(shadows: castsShadows);
    return true;
  }

  /// Disposes all merged GPU buffers and removes all slots.
  void clear() {
    for (final batch in _batches.values) {
      batch.disposeSurface();
    }
    _batches.clear();
    _slots.clear();
    _localBoundsDirty = true;
    markAabbDirty();
    markDrawDirty(shadows: castsShadows);
  }

  /// Bakes any spatial chunks marked dirty since the last frame.
  void bakeDirtyChunks() {
    for (final batch in _batches.values) {
      if (batch.needsFullBake && batch.activePieceCount > 0) {
        _bakeChunkBatch(batch);
      }
    }
  }

  @override
  void onRemove() {
    for (final batch in _batches.values) {
      batch.disposeSurface();
    }
    for (final batch in _batches.values) {
      batch.needsFullBake = true;
    }
    super.onRemove();
  }

  @override
  Aabb3? computeLocalAabb() {
    if (_slots.isEmpty) {
      return null;
    }
    bakeDirtyChunks();
    if (_localBoundsDirty) {
      _localBoundsDirty = false;
      _hasLocalBounds = false;
      for (final batch in _batches.values) {
        if (batch.activePieceCount <= 0 ||
            batch.surface == null ||
            !batch.hasVisibleGeometry) {
          continue;
        }
        if (!_hasLocalBounds) {
          _localAabb.setFrom(batch.localAabb);
          _hasLocalBounds = true;
        } else {
          _localAabb.hull(batch.localAabb);
        }
      }
    }
    return _hasLocalBounds ? _localAabb : null;
  }

  @override
  void draw(covariant RenderContext3D context) {
    _lastDrawnBatchCount = 0;
    if (_slots.isEmpty) {
      return;
    }
    bakeDirtyChunks();

    final worldMat = worldTransformMatrix;
    final isIdentity = worldMat.isIdentity();
    final frustum = context.frustum;

    for (final batch in _batches.values) {
      final surface = batch.surface;
      if (surface == null ||
          batch.activePieceCount <= 0 ||
          !batch.hasVisibleGeometry) {
        continue;
      }

      final Aabb3 testBox;
      if (isIdentity) {
        testBox = batch.localAabb;
      } else {
        testBox = _worldChunkAabbScratch
          ..setFrom(batch.localAabb)
          ..transform(worldMat);
      }
      if (testBox.frustumCullTest(frustum) == CullResult.outside) {
        continue;
      }

      context.drawSurface(
        surface,
        transform: worldMat,
        material: batch.key.material,
        color: batch.key.color,
        instanceData: batch.instanceData,
      );
      _lastDrawnBatchCount++;
    }
  }

  @override
  RayHit3D? raycast(
    Ray worldRay, {
    double maxDistance = double.infinity,
    CullMode? cullMode,
  }) {
    if (_slots.isEmpty || !(maxDistance > 0)) {
      return null;
    }
    bakeDirtyChunks();

    final worldMat = worldTransformMatrix;
    RayHit3D? best;
    var limit = maxDistance;
    var batchIdx = 0;

    for (final batch in _batches.values) {
      final surface = batch.surface;
      if (surface == null || batch.activePieceCount <= 0) {
        continue;
      }
      final hit = RayHit3D.intersectSurface(
        owner: this,
        surface: surface,
        surfaceIndex: batchIdx++,
        modelMatrix: worldMat,
        worldRay: worldRay,
        maxDistance: limit,
        cullMode: cullMode ?? batch.key.material.renderState.cullMode,
      );
      if (hit != null && hit.distance < limit) {
        limit = hit.distance;
        best = hit;
      }
    }
    return best;
  }

  void _applyPieceIndexState(_MergedChunkBatch3D batch, _SlotPiece3D piece) {
    final indices = batch.bakedIndices!;
    final saved = piece.bakedIndices!;
    final start = piece.indexOffset;
    final count = piece.indexCount;
    if (piece.visible && !piece.removed) {
      for (var i = 0; i < count; i++) {
        indices[start + i] = saved[i];
      }
      if (!batch.hasVisibleGeometry) {
        batch.localAabb.setFrom(piece.localBounds);
        batch.hasVisibleGeometry = true;
      } else {
        batch.localAabb.hull(piece.localBounds);
      }
    } else {
      for (var i = 0; i < count; i++) {
        indices[start + i] = 0;
      }
      if (batch.hasVisibleGeometry &&
          _touchesBoundary(batch.localAabb, piece.localBounds)) {
        _recomputeChunkAabb(batch);
      }
    }
    // The surface shares [indices]: upload only the slot's range (and drop
    // its ray-cast BVH, built from the old indices).
    batch.surface?.updateIndices(start: start, count: count);
  }

  static bool _touchesBoundary(Aabb3 box, Aabb3 pieceBox) {
    const eps = 1e-5;
    final bMin = box.min;
    final bMax = box.max;
    final pMin = pieceBox.min;
    final pMax = pieceBox.max;
    return pMin.x <= bMin.x + eps ||
        pMax.x >= bMax.x - eps ||
        pMin.y <= bMin.y + eps ||
        pMax.y >= bMax.y - eps ||
        pMin.z <= bMin.z + eps ||
        pMax.z >= bMax.z - eps;
  }

  static void _recomputeChunkAabb(_MergedChunkBatch3D batch) {
    var any = false;
    for (var i = 0; i < batch.pieces.length; i++) {
      final p = batch.pieces[i];
      if (p.removed || !p.visible) {
        continue;
      }
      if (!any) {
        batch.localAabb.setFrom(p.localBounds);
        any = true;
      } else {
        batch.localAabb.hull(p.localBounds);
      }
    }
    if (!any) {
      batch.localAabb.setZero();
    }
    batch.hasVisibleGeometry = any;
  }

  void _bakeChunkBatch(_MergedChunkBatch3D batch) {
    _fullBakeCount++;
    batch.needsFullBake = false;
    batch.disposeSurface();

    // Prune permanently removed pieces during a full bake.
    batch.pieces.removeWhere((p) => p.removed);
    if (batch.pieces.isEmpty) {
      batch.activePieceCount = 0;
      batch.bakedVertices = null;
      batch.bakedIndices = null;
      return;
    }

    final layout = batch.key.layout;
    final stride = layout.strideInFloats;
    final posOffset = layout.offsetOf(VertexLayout.positionAttribute);
    final nrmOffset = layout.offsetOf('vertexNormal');
    final colOffset = batch.key.bakesColor
        ? layout.offsetOf('vertexColor')
        : null;
    final tanOffset = layout.offsetOf('vertexTangent');

    var totalVertices = 0;
    var totalIndices = 0;
    for (var i = 0; i < batch.pieces.length; i++) {
      final src = batch.pieces[i].sourceSurface;
      totalVertices += src.vertexCount;
      totalIndices += src.indexCount;
    }

    final mergedVerts = Float32List(totalVertices * stride);
    final useWide = totalVertices > 0xFFFF;
    final List<int> mergedIndices = useWide
        ? Uint32List(totalIndices)
        : Uint16List(totalIndices);

    var vertBase = 0;
    var idxCursor = 0;

    for (var pIdx = 0; pIdx < batch.pieces.length; pIdx++) {
      final piece = batch.pieces[pIdx];
      final src = piece.sourceSurface;
      final srcData = src.vertexData;
      final vCount = src.vertexCount;
      final m = piece.transformStorage;
      final m0 = m[0];
      final m1 = m[1];
      final m2 = m[2];
      final m4 = m[4];
      final m5 = m[5];
      final m6 = m[6];
      final m8 = m[8];
      final m9 = m[9];
      final m10 = m[10];

      // Detect orthogonal uniform-scale transforms so rigid/uniform pieces
      // skip cofactor calculation and unit-scale rotations skip per-vertex
      // normal renormalization.
      final l0 = m0 * m0 + m1 * m1 + m2 * m2;
      final l1 = m4 * m4 + m5 * m5 + m6 * m6;
      final l2 = m8 * m8 + m9 * m9 + m10 * m10;
      final d01 = m0 * m4 + m1 * m5 + m2 * m6;
      final d12 = m4 * m8 + m5 * m9 + m6 * m10;
      final d02 = m0 * m8 + m1 * m9 + m2 * m10;
      final tol = 1e-4 * l0;
      final isUniformOrtho =
          l0 > 1e-12 &&
          (l0 - l1).abs() <= tol &&
          (l0 - l2).abs() <= tol &&
          d01.abs() <= tol &&
          d12.abs() <= tol &&
          d02.abs() <= tol;

      double c00 = 0;
      double c01 = 0;
      double c02 = 0;
      double c10 = 0;
      double c11 = 0;
      double c12 = 0;
      double c20 = 0;
      double c21 = 0;
      double c22 = 0;
      bool flipWinding;
      double nSign;
      bool needsNormalNormalize;

      if (isUniformOrtho) {
        final det =
            m0 * (m5 * m10 - m6 * m9) +
            m4 * (m6 * m8 - m2 * m10) +
            m8 * (m2 * m9 - m5 * m8);
        flipWinding = det < 0;
        nSign = flipWinding ? -1.0 : 1.0;
        needsNormalNormalize = (l0 - 1.0).abs() > 1e-4;
      } else {
        c00 = m5 * m10 - m6 * m9;
        c01 = m6 * m8 - m4 * m10;
        c02 = m4 * m9 - m5 * m8;
        c10 = m2 * m9 - m1 * m10;
        c11 = m0 * m10 - m2 * m8;
        c12 = m1 * m8 - m0 * m9;
        c20 = m1 * m6 - m2 * m5;
        c21 = m2 * m4 - m0 * m6;
        c22 = m0 * m5 - m1 * m4;
        final det = m0 * c00 + m4 * c10 + m8 * c20;
        flipWinding = det < 0;
        nSign = flipWinding ? -1.0 : 1.0;
        needsNormalNormalize = true;
      }

      // Copy all attributes first, then transform position/normal/color in
      // place.
      final dstVertStart = vertBase * stride;
      mergedVerts.setRange(
        dstVertStart,
        dstVertStart + vCount * stride,
        srcData,
      );

      for (var v = 0; v < vCount; v++) {
        final vo = dstVertStart + v * stride;
        if (posOffset != null) {
          final po = vo + posOffset;
          final px = mergedVerts[po];
          final py = mergedVerts[po + 1];
          final pz = mergedVerts[po + 2];
          mergedVerts
            ..[po] = m0 * px + m4 * py + m8 * pz + m[12]
            ..[po + 1] = m1 * px + m5 * py + m9 * pz + m[13]
            ..[po + 2] = m2 * px + m6 * py + m10 * pz + m[14];
        }
        if (nrmOffset != null) {
          final no = vo + nrmOffset;
          final nx = mergedVerts[no];
          final ny = mergedVerts[no + 1];
          final nz = mergedVerts[no + 2];
          var wnx = isUniformOrtho
              ? (m0 * nx + m4 * ny + m8 * nz) * nSign
              : (c00 * nx + c10 * ny + c20 * nz) * nSign;
          var wny = isUniformOrtho
              ? (m1 * nx + m5 * ny + m9 * nz) * nSign
              : (c01 * nx + c11 * ny + c21 * nz) * nSign;
          var wnz = isUniformOrtho
              ? (m2 * nx + m6 * ny + m10 * nz) * nSign
              : (c02 * nx + c12 * ny + c22 * nz) * nSign;
          if (needsNormalNormalize) {
            final len = math.sqrt(wnx * wnx + wny * wny + wnz * wnz);
            if (len > 1e-12) {
              final inv = 1.0 / len;
              wnx *= inv;
              wny *= inv;
              wnz *= inv;
            }
          }
          mergedVerts
            ..[no] = wnx
            ..[no + 1] = wny
            ..[no + 2] = wnz;
        }
        if (colOffset != null) {
          final co = vo + colOffset;
          mergedVerts
            ..[co] *= piece.colorR
            ..[co + 1] *= piece.colorG
            ..[co + 2] *= piece.colorB
            ..[co + 3] *= piece.colorA;
        }
        if (tanOffset != null) {
          final to = vo + tanOffset;
          final tx = mergedVerts[to];
          final ty = mergedVerts[to + 1];
          final tz = mergedVerts[to + 2];
          var wtx = m0 * tx + m4 * ty + m8 * tz;
          var wty = m1 * tx + m5 * ty + m9 * tz;
          var wtz = m2 * tx + m6 * ty + m10 * tz;
          if (needsNormalNormalize) {
            final tLen = math.sqrt(wtx * wtx + wty * wty + wtz * wtz);
            if (tLen > 1e-12) {
              final inv = 1.0 / tLen;
              wtx *= inv;
              wty *= inv;
              wtz *= inv;
            }
          }
          mergedVerts
            ..[to] = wtx
            ..[to + 1] = wty
            ..[to + 2] = wtz
            ..[to + 3] *= nSign;
        }
      }

      final srcIndices = src.indices;
      final iCount = srcIndices.length;
      final saved = Int32List(iCount);
      for (var t = 0; t + 2 < iCount; t += 3) {
        final a = vertBase + srcIndices[t];
        final b = vertBase + srcIndices[t + 1];
        final c = vertBase + srcIndices[t + 2];
        saved[t] = a;
        if (flipWinding) {
          saved[t + 1] = c;
          saved[t + 2] = b;
        } else {
          saved[t + 1] = b;
          saved[t + 2] = c;
        }
      }

      piece
        ..indexOffset = idxCursor
        ..indexCount = iCount
        ..bakedIndices = saved;

      if (piece.visible) {
        for (var k = 0; k < iCount; k++) {
          mergedIndices[idxCursor + k] = saved[k];
        }
      } else {
        for (var k = 0; k < iCount; k++) {
          mergedIndices[idxCursor + k] = 0;
        }
      }

      vertBase += vCount;
      idxCursor += iCount;
    }

    batch
      ..bakedVertices = mergedVerts
      ..bakedIndices = mergedIndices;
    _recomputeChunkAabb(batch);
    batch.surface = Surface.fromBuffers(
      vertices: mergedVerts,
      indices: mergedIndices,
      layout: layout,
      material: batch.key.material,
      aabb: Aabb3.copy(batch.localAabb),
    );
  }
}
