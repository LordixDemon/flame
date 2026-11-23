part of 'static_mesh_batcher_3d.dart';

extension _StaticMeshBatcherBaker on StaticMeshBatcher3D {
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
          _touchesChunkBoundary(batch.localAabb, piece.localBounds)) {
        _recomputeChunkAabb(batch);
      }
    }
    // The surface shares [indices]: upload only the slot's range (and drop
    // its ray-cast BVH, built from the old indices).
    batch.surface?.updateIndices(start: start, count: count);
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
        final det = determinant3x3(m);
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

bool _touchesChunkBoundary(Aabb3 box, Aabb3 pieceBox) {
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

void _recomputeChunkAabb(_MergedChunkBatch3D batch) {
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
