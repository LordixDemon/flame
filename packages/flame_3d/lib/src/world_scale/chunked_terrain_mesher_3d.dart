part of 'chunked_terrain_3d.dart';

extension _ChunkedTerrainMesher on ChunkedTerrain3D {
  void _selectNodesInto(
    List<_TerrainQuadNode3D> out,
    Vector3 worldCameraPos,
    Frustum? worldFrustum,
  ) {
    out.clear();
    final worldMat = worldTransformMatrix;
    _syncInverseWorld(worldMat);

    if (_invWorldIsIdentity) {
      _localCamScratch.setFrom(worldCameraPos);
    } else if (_invWorldValid) {
      final m = _invWorldScratch.storage;
      final cx = worldCameraPos.x;
      final cy = worldCameraPos.y;
      final cz = worldCameraPos.z;
      _localCamScratch.setValues(
        m[0] * cx + m[4] * cy + m[8] * cz + m[12],
        m[1] * cx + m[5] * cy + m[9] * cz + m[13],
        m[2] * cx + m[6] * cy + m[10] * cz + m[14],
      );
    } else {
      _localCamScratch.setFrom(worldCameraPos);
    }

    final camX = _localCamScratch.x;
    final camY = _localCamScratch.y;
    final camZ = _localCamScratch.z;
    final nodeStack = _nodeStack..clear();
    final insideStack = _insideStack..clear();
    for (var i = _roots.length - 1; i >= 0; i--) {
      nodeStack.add(_roots[i]);
      insideStack.add(false);
    }

    while (nodeStack.isNotEmpty) {
      final node = nodeStack.removeLast();
      var inside = insideStack.removeLast();
      if (!inside && worldFrustum != null) {
        final Aabb3 box;
        if (_invWorldIsIdentity) {
          box = node.localBounds;
        } else {
          box = _worldNodeBox
            ..setFrom(node.localBounds)
            ..transform(worldMat);
        }
        final res = box.frustumCullTest(worldFrustum);
        if (res == CullResult.outside) {
          continue;
        }
        inside = res == CullResult.inside;
      }

      final kids = node.children;
      if (kids != null && kids.isNotEmpty && node.lodLevel > 0) {
        final distSq = _distanceSqPointToAabb(
          camX,
          camY,
          camZ,
          node.localBounds,
        );
        final spanX = node.localBounds.max.x - node.localBounds.min.x;
        final spanZ = node.localBounds.max.z - node.localBounds.min.z;
        final splitThreshold = math.max(spanX, spanZ) * lodSplitFactor;
        if (distSq < splitThreshold * splitThreshold) {
          for (var i = kids.length - 1; i >= 0; i--) {
            nodeStack.add(kids[i]);
            insideStack.add(inside);
          }
          continue;
        }
      }

      out.add(node);
    }
  }

  void _buildQuadtree() {
    final cellsX = gridColumns - 1;
    final cellsZ = gridRows - 1;
    final maxStep = 1 << (lodLevels - 1);

    final minTotalCells = math.min(cellsX, cellsZ);
    final autoLeaf = math.max(1, minTotalCells ~/ maxStep);
    final leafCells = math.min(leafChunkQuads, autoLeaf);
    final rootSpan = leafCells * maxStep;

    _roots.clear();
    for (var r0 = 0; r0 < cellsZ; r0 += rootSpan) {
      final r1 = math.min(cellsZ, r0 + rootSpan);
      for (var c0 = 0; c0 < cellsX; c0 += rootSpan) {
        final c1 = math.min(cellsX, c0 + rootSpan);
        _roots.add(_buildNodeRecursive(c0, c1, r0, r1, lodLevels - 1));
      }
    }
  }

  _TerrainQuadNode3D _buildNodeRecursive(
    int c0,
    int c1,
    int r0,
    int r1,
    int lod,
  ) {
    final bounds = _computeRegionBounds(c0, c1, r0, r1);
    final node = _TerrainQuadNode3D(
      colStart: c0,
      colEnd: c1,
      rowStart: r0,
      rowEnd: r1,
      lodLevel: lod,
      localBounds: bounds,
    );

    if (lod > 0) {
      final childStep = 1 << (lod - 1);
      final spanC = c1 - c0;
      final spanR = r1 - r0;
      if (spanC >= childStep * 2 || spanR >= childStep * 2) {
        final midC = _alignedMidpoint(c0, c1, childStep);
        final midR = _alignedMidpoint(r0, r1, childStep);
        final kids = <_TerrainQuadNode3D>[];
        if (midC > c0 && midR > r0) {
          kids.add(_buildNodeRecursive(c0, midC, r0, midR, lod - 1));
        }
        if (c1 > midC && midR > r0) {
          kids.add(_buildNodeRecursive(midC, c1, r0, midR, lod - 1));
        }
        if (midC > c0 && r1 > midR) {
          kids.add(_buildNodeRecursive(c0, midC, midR, r1, lod - 1));
        }
        if (c1 > midC && r1 > midR) {
          kids.add(_buildNodeRecursive(midC, c1, midR, r1, lod - 1));
        }
        if (kids.length > 1) {
          node.children = kids;
        }
      }
    }
    return node;
  }

  Aabb3 _computeRegionBounds(int c0, int c1, int r0, int r1) {
    final x0 = -worldWidth * 0.5 + (c0 / (gridColumns - 1)) * worldWidth;
    final x1 = -worldWidth * 0.5 + (c1 / (gridColumns - 1)) * worldWidth;
    final z0 = -worldDepth * 0.5 + (r0 / (gridRows - 1)) * worldDepth;
    final z1 = -worldDepth * 0.5 + (r1 / (gridRows - 1)) * worldDepth;

    var minH = double.infinity;
    var maxH = double.negativeInfinity;
    for (var r = r0; r <= r1; r++) {
      final rowBase = r * gridColumns;
      for (var c = c0; c <= c1; c++) {
        final h = heights[rowBase + c];
        if (h < minH) {
          minH = h;
        }
        if (h > maxH) {
          maxH = h;
        }
      }
    }
    return Aabb3.minMax(
      Vector3(x0, minH - skirtDepth, z0),
      Vector3(x1, maxH, z1),
    );
  }

  Surface _ensureChunkSurface(_TerrainQuadNode3D node) {
    final existing = node.cachedSurface;
    if (existing != null) {
      return existing;
    }

    final step = node.step;
    final cols = _buildSampleAxis(node.colStart, node.colEnd, step);
    final rows = _buildSampleAxis(node.rowStart, node.rowEnd, step);
    final nCols = cols.length;
    final nRows = rows.length;

    final topVertCount = nCols * nRows;
    final skirtVertCount = 2 * nCols + 2 * nRows;
    final totalVerts = topVertCount + skirtVertCount;

    final stride = VertexLayout.standard.strideInFloats;
    final verts = Float32List(totalVerts * stride);

    final inv2Dx = 1.0 / (2.0 * (worldWidth / (gridColumns - 1)));
    final inv2Dz = 1.0 / (2.0 * (worldDepth / (gridRows - 1)));
    final invColsMinus1 = 1.0 / (gridColumns - 1);
    final invRowsMinus1 = 1.0 / (gridRows - 1);
    final halfW = worldWidth * 0.5;
    final halfD = worldDepth * 0.5;
    final baseMinH = math.min(0.0, _minElevation);
    final invMaxHeight = 1.0 / maxHeight;

    // 1. Top grid vertices.
    var vCursor = 0;
    for (var r = 0; r < nRows; r++) {
      final rSample = rows[r];
      for (var c = 0; c < nCols; c++) {
        _writeChunkVertex(
          verts,
          stride,
          vCursor++,
          cols[c],
          rSample,
          0.0,
          invColsMinus1,
          invRowsMinus1,
          halfW,
          halfD,
          inv2Dx,
          inv2Dz,
          baseMinH,
          invMaxHeight,
        );
      }
    }

    // 2. Vertical skirt bottom vertices along North, South, West, East borders.
    final northSkirtStart = vCursor;
    for (var c = 0; c < nCols; c++) {
      _writeChunkVertex(
        verts,
        stride,
        vCursor++,
        cols[c],
        rows[0],
        -skirtDepth,
        invColsMinus1,
        invRowsMinus1,
        halfW,
        halfD,
        inv2Dx,
        inv2Dz,
        baseMinH,
        invMaxHeight,
      );
    }
    final southSkirtStart = vCursor;
    for (var c = 0; c < nCols; c++) {
      _writeChunkVertex(
        verts,
        stride,
        vCursor++,
        cols[c],
        rows[nRows - 1],
        -skirtDepth,
        invColsMinus1,
        invRowsMinus1,
        halfW,
        halfD,
        inv2Dx,
        inv2Dz,
        baseMinH,
        invMaxHeight,
      );
    }
    final westSkirtStart = vCursor;
    for (var r = 0; r < nRows; r++) {
      _writeChunkVertex(
        verts,
        stride,
        vCursor++,
        cols[0],
        rows[r],
        -skirtDepth,
        invColsMinus1,
        invRowsMinus1,
        halfW,
        halfD,
        inv2Dx,
        inv2Dz,
        baseMinH,
        invMaxHeight,
      );
    }
    final eastSkirtStart = vCursor;
    for (var r = 0; r < nRows; r++) {
      _writeChunkVertex(
        verts,
        stride,
        vCursor++,
        cols[nCols - 1],
        rows[r],
        -skirtDepth,
        invColsMinus1,
        invRowsMinus1,
        halfW,
        halfD,
        inv2Dx,
        inv2Dz,
        baseMinH,
        invMaxHeight,
      );
    }

    final topQuads = (nCols - 1) * (nRows - 1);
    final skirtQuads = 2 * (nCols - 1) + 2 * (nRows - 1);
    final totalIndices = (topQuads + skirtQuads) * 6;
    final List<int> indices = totalVerts > 0xFFFF
        ? Uint32List(totalIndices)
        : Uint16List(totalIndices);

    var k = 0;
    // Top grid triangles (CCW +Y up).
    for (var r = 0; r < nRows - 1; r++) {
      final row0 = r * nCols;
      final row1 = (r + 1) * nCols;
      for (var c = 0; c < nCols - 1; c++) {
        final i0 = row0 + c;
        final i1 = i0 + 1;
        final i2 = row1 + c + 1;
        final i3 = row1 + c;
        indices
          ..[k] = i0
          ..[k + 1] = i3
          ..[k + 2] = i2
          ..[k + 3] = i0
          ..[k + 4] = i2
          ..[k + 5] = i1;
        k += 6;
      }
    }

    // North skirt (r = 0, outward normal -Z).
    for (var c = 0; c < nCols - 1; c++) {
      final t0 = c;
      final t1 = c + 1;
      final b0 = northSkirtStart + c;
      final b1 = northSkirtStart + c + 1;
      indices
        ..[k] = t0
        ..[k + 1] = t1
        ..[k + 2] = b1
        ..[k + 3] = t0
        ..[k + 4] = b1
        ..[k + 5] = b0;
      k += 6;
    }

    // South skirt (r = nRows - 1, outward normal +Z).
    final lastRowBase = (nRows - 1) * nCols;
    for (var c = 0; c < nCols - 1; c++) {
      final t0 = lastRowBase + c;
      final t1 = lastRowBase + c + 1;
      final b0 = southSkirtStart + c;
      final b1 = southSkirtStart + c + 1;
      indices
        ..[k] = t0
        ..[k + 1] = b0
        ..[k + 2] = b1
        ..[k + 3] = t0
        ..[k + 4] = b1
        ..[k + 5] = t1;
      k += 6;
    }

    // West skirt (c = 0, outward normal -X).
    for (var r = 0; r < nRows - 1; r++) {
      final t0 = r * nCols;
      final t1 = (r + 1) * nCols;
      final b0 = westSkirtStart + r;
      final b1 = westSkirtStart + r + 1;
      indices
        ..[k] = t0
        ..[k + 1] = b0
        ..[k + 2] = b1
        ..[k + 3] = t0
        ..[k + 4] = b1
        ..[k + 5] = t1;
      k += 6;
    }

    // East skirt (c = nCols - 1, outward normal +X).
    for (var r = 0; r < nRows - 1; r++) {
      final t0 = r * nCols + (nCols - 1);
      final t1 = (r + 1) * nCols + (nCols - 1);
      final b0 = eastSkirtStart + r;
      final b1 = eastSkirtStart + r + 1;
      indices
        ..[k] = t0
        ..[k + 1] = t1
        ..[k + 2] = b1
        ..[k + 3] = t0
        ..[k + 4] = b1
        ..[k + 5] = b0;
      k += 6;
    }

    final surface = Surface.fromBuffers(
      vertices: verts,
      indices: indices,
      material: material,
      aabb: Aabb3.copy(node.localBounds),
    );
    node
      ..cachedSurface = surface
      ..topVertexCount = topVertCount
      ..skirtVertexCount = skirtVertCount
      ..skirtTriangleCount = skirtQuads * 2;
    return surface;
  }

  void _writeChunkVertex(
    Float32List verts,
    int stride,
    int vertIdx,
    int cSample,
    int rSample,
    double yOffset,
    double invColsMinus1,
    double invRowsMinus1,
    double halfW,
    double halfD,
    double inv2Dx,
    double inv2Dz,
    double baseMinH,
    double invMaxHeight,
  ) {
    final uNorm = cSample * invColsMinus1;
    final vNorm = rSample * invRowsMinus1;
    final x = -halfW + uNorm * worldWidth;
    final z = -halfD + vNorm * worldDepth;
    final rowOff = rSample * gridColumns;
    final h = heights[rowOff + cSample];

    final cPrev = cSample > 0 ? cSample - 1 : 0;
    final cNext = cSample + 1 < gridColumns ? cSample + 1 : gridColumns - 1;
    final rPrev = rSample > 0 ? rSample - 1 : 0;
    final rNext = rSample + 1 < gridRows ? rSample + 1 : gridRows - 1;

    final dhdx = (heights[rowOff + cNext] - heights[rowOff + cPrev]) * inv2Dx;
    final dhdz =
        (heights[rNext * gridColumns + cSample] -
            heights[rPrev * gridColumns + cSample]) *
        inv2Dz;
    final invN = 1.0 / math.sqrt(dhdx * dhdx + dhdz * dhdz + 1.0);
    final nx = -dhdx * invN;
    final ny = invN;
    final nz = -dhdz * invN;

    final hNorm = ((h - baseMinH) * invMaxHeight).clamp(0.0, 1.0);
    final o = vertIdx * stride;
    verts
      ..[o] = x
      ..[o + 1] = h + yOffset
      ..[o + 2] = z
      ..[o + 3] = uNorm * uvScale
      ..[o + 4] = vNorm * uvScale;
    biomePalette.writeColorTo(hNorm, ny, verts, o + 5);
    verts
      ..[o + 9] = nx
      ..[o + 10] = ny
      ..[o + 11] = nz;
  }
}

int _alignedMidpoint(int start, int end, int alignStep) {
  final span = end - start;
  if (span <= alignStep) {
    return end;
  }
  final rawHalf = span >> 1;
  final aligned = (rawHalf ~/ alignStep) * alignStep;
  final stepOffset = math.max(alignStep, aligned);
  return math.min(end, start + stepOffset);
}

Int32List _buildSampleAxis(int start, int end, int step) {
  final count = ((end - start + step - 1) ~/ step) + 1;
  final out = Int32List(count);
  var idx = 0;
  for (var v = start; v < end; v += step) {
    out[idx++] = v;
  }
  out[idx] = end;
  return out;
}

double _distanceSqPointToAabb(
  double px,
  double py,
  double pz,
  Aabb3 box,
) {
  final dx = px < box.min.x
      ? box.min.x - px
      : (px > box.max.x ? px - box.max.x : 0.0);
  final dy = py < box.min.y
      ? box.min.y - py
      : (py > box.max.y ? py - box.max.y : 0.0);
  final dz = pz < box.min.z
      ? box.min.z - pz
      : (pz > box.max.z ? pz - box.max.z : 0.0);
  return dx * dx + dy * dy + dz * dz;
}
