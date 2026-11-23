part of 'volume_decal_batch_3d.dart';

extension _VolumeDecalTerrain on VolumeDecalBatch3D {
  void _projectOntoTerrainImpl(
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
      if (c1 <= c0 || r1 <= r0) {
        continue;
      }

      final needed = (c1 - c0 + 1) * 6;
      if (_terrainRowA.length < needed) {
        _terrainRowA = Float64List(needed);
        _terrainRowB = Float64List(needed);
      }
      var rowPrev = _terrainRowA;
      var rowCurr = _terrainRowB;
      _fillTerrainDecalRow(
        terrain,
        r0,
        c0,
        c1,
        halfW,
        halfD,
        cellW,
        cellD,
        terrainIsIdentity,
        tm,
        im,
        rowPrev,
      );

      for (var r = r0; r < r1; r++) {
        _fillTerrainDecalRow(
          terrain,
          r + 1,
          c0,
          c1,
          halfW,
          halfD,
          cellW,
          cellD,
          terrainIsIdentity,
          tm,
          im,
          rowCurr,
        );
        for (var c = c0; c < c1; c++) {
          final o0 = (c - c0) * 6;
          final o1 = o0 + 6;

          // Triangle 1: (v00, v01, v11) CCW +Y
          _emitTerrainTriFlat(
            decal,
            boxFrame,
            rowPrev,
            o0,
            rowCurr,
            o0,
            rowCurr,
            o1,
            selfIsIdentity: selfIsIdentity,
          );
          // Triangle 2: (v00, v11, v10) CCW +Y
          _emitTerrainTriFlat(
            decal,
            boxFrame,
            rowPrev,
            o0,
            rowCurr,
            o1,
            rowPrev,
            o1,
            selfIsIdentity: selfIsIdentity,
          );
        }
        final swap = rowPrev;
        rowPrev = rowCurr;
        rowCurr = swap;
      }
    }

    _finalizeMergedSurface();
  }
}

void _fillTerrainDecalRow(
  ChunkedTerrain3D terrain,
  int r,
  int c0,
  int c1,
  double halfW,
  double halfD,
  double cellW,
  double cellD,
  bool terrainIsIdentity,
  Float32List tm,
  Float32List im,
  Float64List out,
) {
  final heights = terrain.heights;
  final cols = terrain.gridColumns;
  final rowOff = r * cols;
  final lz = -halfD + r * cellD;
  final inv2W = 1.0 / cellW;
  final inv2D = 1.0 / cellD;
  final epsZLo = lz - cellD * 0.5;
  final epsZHi = lz + cellD * 0.5;

  for (var c = c0; c <= c1; c++) {
    final lx = -halfW + c * cellW;
    final ly = heights[rowOff + c];
    // Match `terrain.sampleNormal(lx, lz)` exactly via central differences
    // at `+- 0.5 * cellW / cellD`.
    final dhdx =
        (terrain.sampleHeight(lx + cellW * 0.5, lz) -
            terrain.sampleHeight(lx - cellW * 0.5, lz)) *
        inv2W;
    final dhdz =
        (terrain.sampleHeight(lx, epsZHi) - terrain.sampleHeight(lx, epsZLo)) *
        inv2D;
    final invN = 1.0 / math.sqrt(dhdx * dhdx + dhdz * dhdz + 1.0);
    final lnx = -dhdx * invN;
    final lny = invN;
    final lnz = -dhdz * invN;

    final o = (c - c0) * 6;
    if (terrainIsIdentity) {
      out
        ..[o] = lx
        ..[o + 1] = ly
        ..[o + 2] = lz
        ..[o + 3] = lnx
        ..[o + 4] = lny
        ..[o + 5] = lnz;
    } else {
      var wnx = im[0] * lnx + im[1] * lny + im[2] * lnz;
      var wny = im[4] * lnx + im[5] * lny + im[6] * lnz;
      var wnz = im[8] * lnx + im[9] * lny + im[10] * lnz;
      final len = math.sqrt(wnx * wnx + wny * wny + wnz * wnz);
      if (len > 1e-12) {
        wnx /= len;
        wny /= len;
        wnz /= len;
      }
      out
        ..[o] = tm[0] * lx + tm[4] * ly + tm[8] * lz + tm[12]
        ..[o + 1] = tm[1] * lx + tm[5] * ly + tm[9] * lz + tm[13]
        ..[o + 2] = tm[2] * lx + tm[6] * ly + tm[10] * lz + tm[14]
        ..[o + 3] = wnx
        ..[o + 4] = wny
        ..[o + 5] = wnz;
    }
  }
}
