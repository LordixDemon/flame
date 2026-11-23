import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/src/extensions/geometry_math.dart';
import 'package:meta/meta.dart';

part 'static_mesh_batcher_baker_3d.dart';

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
  bool get usesDefaultFrustumVisibility => runtimeType == StaticMeshBatcher3D;

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
}
