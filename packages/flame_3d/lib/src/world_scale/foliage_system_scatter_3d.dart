part of 'foliage_system_3d.dart';

extension _FoliageSystemScatter on FoliageSystem3D {
  int _scatterOnTerrainImpl(
    ChunkedTerrain3D terrain, {
    int count = 4096,
    double minSlopeCos = 0.72,
    double minHeight = -double.infinity,
    double maxHeight = double.infinity,
    int seed = 1337,
    double minScale = 0.75,
    double maxScale = 1.35,
    Color baseColor = const Color(0xFF4B8F38),
    Color variationColor = const Color(0xFF79B846),
    FoliageDensityCallback3D? densityCallback,
  }) {
    clear();
    final targetCount = math.min(count, capacity);
    if (targetCount <= 0) {
      return 0;
    }

    // Stratified jittered grid with oversampling when slope/height filters
    // reject candidates, guaranteeing even spacing without clumping.
    var rngState = (seed ^ 0x5DEECE66) & 0x7FFFFFFF;
    if (rngState == 0) {
      rngState = 1337;
    }
    double next01() {
      rngState = (rngState * 48271) % 2147483647;
      return (rngState & 0x7FFFFFFF) / 2147483647.0;
    }

    final normalScratch = Vector3.zero();
    final aspect = math.sqrt(terrain.worldWidth / terrain.worldDepth);
    final gridCols = math.max(1, (math.sqrt(targetCount) * aspect).ceil());
    final gridRows = math.max(1, (targetCount / gridCols).ceil());
    final cellW = terrain.worldWidth / gridCols;
    final cellD = terrain.worldDepth / gridRows;
    final halfW = terrain.worldWidth * 0.5;
    final halfD = terrain.worldDepth * 0.5;

    var placed = 0;
    // Pass 1: stratified jittered cells.
    for (var gr = 0; gr < gridRows && placed < targetCount; gr++) {
      for (var gc = 0; gc < gridCols && placed < targetCount; gc++) {
        final jx = 0.12 + 0.76 * next01();
        final jz = 0.12 + 0.76 * next01();
        final x = -halfW + (gc + jx) * cellW;
        final z = -halfD + (gr + jz) * cellD;
        if (_tryPlaceOnTerrain(
          terrain,
          x,
          z,
          minSlopeCos,
          minHeight,
          maxHeight,
          minScale,
          maxScale,
          baseColor,
          variationColor,
          densityCallback,
          next01,
          normalScratch,
        )) {
          placed++;
        }
      }
    }

    // Pass 2: top up remaining quota if slope/height masks rejected some cells.
    final maxAttempts = targetCount * 6;
    var attempts = 0;
    while (placed < targetCount && attempts < maxAttempts) {
      attempts++;
      final x = (next01() - 0.5) * terrain.worldWidth;
      final z = (next01() - 0.5) * terrain.worldDepth;
      if (_tryPlaceOnTerrain(
        terrain,
        x,
        z,
        minSlopeCos,
        minHeight,
        maxHeight,
        minScale,
        maxScale,
        baseColor,
        variationColor,
        densityCallback,
        next01,
        normalScratch,
      )) {
        placed++;
      }
    }

    _ensureSpatialCells();
    if (placed > 0) {
      _stateVersion++;
    }
    markAabbDirty();
    markDrawDirty(shadows: castsShadows);
    return placed;
  }

  void _ensureSpatialCells() {
    if (!_cellsDirty) {
      return;
    }
    _cellsDirty = false;
    final n = _bladeCount;
    if (n == 0) {
      _cellCount = 0;
      _localAabb.setZero();
      return;
    }

    final bladeNext = Int32List(n);
    const cellBias = 0x2000000;
    const cellStride = 0x4000000;
    final cellIndexByKey = <int, int>{};
    Map<(int, int), int>? overflowCells;
    final cellHeads = <int>[];
    final cellTails = <int>[];
    final cellCountsList = <int>[];

    for (var i = 0; i < n; i++) {
      final cx = (_posX[i] / cellSize).floor();
      final cz = (_posZ[i] / cellSize).floor();
      int? cellIdx;
      final inRange =
          cx >= -cellBias && cx < cellBias && cz >= -cellBias && cz < cellBias;
      if (inRange) {
        final packed = (cx + cellBias) * cellStride + (cz + cellBias);
        cellIdx = cellIndexByKey[packed];
        if (cellIdx == null) {
          cellIdx = cellHeads.length;
          cellIndexByKey[packed] = cellIdx;
          cellHeads.add(i);
          cellTails.add(i);
          cellCountsList.add(1);
          bladeNext[i] = -1;
          continue;
        }
      } else {
        final overflow = overflowCells ??= <(int, int), int>{};
        final rec = (cx, cz);
        cellIdx = overflow[rec];
        if (cellIdx == null) {
          cellIdx = cellHeads.length;
          overflow[rec] = cellIdx;
          cellHeads.add(i);
          cellTails.add(i);
          cellCountsList.add(1);
          bladeNext[i] = -1;
          continue;
        }
      }
      final tail = cellTails[cellIdx];
      bladeNext[tail] = i;
      bladeNext[i] = -1;
      cellTails[cellIdx] = i;
      cellCountsList[cellIdx]++;
    }

    final cCount = cellHeads.length;
    _cellCount = cCount;
    _cellOffsets = Int32List(cCount);
    _cellCounts = Int32List(cCount);
    _cellBladeIndices = Int32List(n);
    _cellBounds = Float32List(cCount * 6);
    _cellHasBend = Uint8List(cCount);

    final meshBox = mesh.aabb;
    final maxHalfExtent = math.max(
      math.max(meshBox.min.x.abs(), meshBox.max.x.abs()),
      math.max(meshBox.min.z.abs(), meshBox.max.z.abs()),
    );
    final meshTop = math.max(0.5, meshBox.max.y);

    var globalMinX = double.infinity;
    var globalMinY = double.infinity;
    var globalMinZ = double.infinity;
    var globalMaxX = double.negativeInfinity;
    var globalMaxY = double.negativeInfinity;
    var globalMaxZ = double.negativeInfinity;

    var cursor = 0;
    for (var cellIdx = 0; cellIdx < cCount; cellIdx++) {
      _cellOffsets[cellIdx] = cursor;
      _cellCounts[cellIdx] = cellCountsList[cellIdx];

      var minX = double.infinity;
      var minY = double.infinity;
      var minZ = double.infinity;
      var maxX = double.negativeInfinity;
      var maxY = double.negativeInfinity;
      var maxZ = double.negativeInfinity;
      var hasBent = false;

      var i = cellHeads[cellIdx];
      while (i != -1) {
        _cellBladeIndices[cursor++] = i;
        // Wind and trampling shear the blade: its tip moves sideways by up
        // to their sum times its height.
        final padXZ =
            math.max(_scaleX[i], _scaleZ[i]) * maxHalfExtent +
            (windStrength.abs() + maxBendAngle.abs()) * _scaleY[i] * meshTop;
        final topY = _posY[i] + _scaleY[i] * meshTop;
        minX = math.min(minX, _posX[i] - padXZ);
        maxX = math.max(maxX, _posX[i] + padXZ);
        minY = math.min(minY, _posY[i] - 0.1);
        maxY = math.max(maxY, topY);
        minZ = math.min(minZ, _posZ[i] - padXZ);
        maxZ = math.max(maxZ, _posZ[i] + padXZ);
        if (_crush[i] != 0.0 || _bendX[i] != 0.0 || _bendZ[i] != 0.0) {
          hasBent = true;
        }
        i = bladeNext[i];
      }

      final cb = cellIdx * 6;
      _cellBounds
        ..[cb] = minX
        ..[cb + 1] = minY
        ..[cb + 2] = minZ
        ..[cb + 3] = maxX
        ..[cb + 4] = maxY
        ..[cb + 5] = maxZ;
      _cellHasBend[cellIdx] = hasBent ? 1 : 0;

      globalMinX = math.min(globalMinX, minX);
      globalMinY = math.min(globalMinY, minY);
      globalMinZ = math.min(globalMinZ, minZ);
      globalMaxX = math.max(globalMaxX, maxX);
      globalMaxY = math.max(globalMaxY, maxY);
      globalMaxZ = math.max(globalMaxZ, maxZ);
    }

    _localAabb
      ..min.setValues(globalMinX, globalMinY, globalMinZ)
      ..max.setValues(globalMaxX, globalMaxY, globalMaxZ);
  }

  bool _tryPlaceOnTerrain(
    ChunkedTerrain3D terrain,
    double x,
    double z,
    double minSlopeCos,
    double minHeight,
    double maxHeight,
    double minScale,
    double maxScale,
    Color baseColor,
    Color variationColor,
    FoliageDensityCallback3D? densityCallback,
    double Function() next01,
    Vector3 normalScratch,
  ) {
    final y = terrain.sampleHeight(x, z);
    if (y < minHeight || y > maxHeight) {
      return false;
    }
    terrain.sampleNormal(x, z, out: normalScratch);
    if (normalScratch.y < minSlopeCos) {
      return false;
    }
    if (densityCallback != null) {
      final density = densityCallback(x, y, z, normalScratch).clamp(0.0, 1.0);
      if (density <= 0 || (density < 1.0 && next01() > density)) {
        return false;
      }
    }

    final yaw = next01() * math.pi * 2.0;
    final s = minScale + (maxScale - minScale) * next01();
    final heightVar = s * (0.85 + 0.3 * next01());
    final mixT = next01();

    return _addBladeRaw(
          x,
          y,
          z,
          yaw,
          s,
          heightVar,
          s,
          baseColor.r + (variationColor.r - baseColor.r) * mixT,
          baseColor.g + (variationColor.g - baseColor.g) * mixT,
          baseColor.b + (variationColor.b - baseColor.b) * mixT,
          1.0,
          next01() * math.pi * 2.0,
          next01(),
          notify: false,
        ) >=
        0;
  }
}

double _hashFoliageFloat01(int seed) {
  var x = seed & 0x7FFFFFFF;
  x = ((x >> 16) ^ x) * 0x45D9F3B & 0x7FFFFFFF;
  x = ((x >> 16) ^ x) * 0x45D9F3B & 0x7FFFFFFF;
  x = (x >> 16) ^ x;
  return (x & 0x7FFFFFFF) / 2147483647.0;
}

Mesh _buildDefaultGrassTuftMesh(Material material) {
  // Two crossed tapered blades anchored at y = 0, peaking at y = 1.
  final stride = VertexLayout.standard.strideInFloats;
  final verts = Float32List(10 * stride);

  void put(
    int idx,
    double x,
    double y,
    double z,
    double u,
    double v,
    double r,
    double g,
    double b,
    double nx,
    double ny,
    double nz,
  ) {
    final o = idx * stride;
    verts
      ..[o] = x
      ..[o + 1] = y
      ..[o + 2] = z
      ..[o + 3] = u
      ..[o + 4] = v
      ..[o + 5] = r
      ..[o + 6] = g
      ..[o + 7] = b
      ..[o + 8] = 1
      ..[o + 9] = nx
      ..[o + 10] = ny
      ..[o + 11] = nz;
  }

  // Blade A along X axis.
  put(0, -0.14, 0, 0, 0, 1, 0.45, 0.55, 0.38, 0, 0.45, 0.89);
  put(1, 0.14, 0, 0, 1, 1, 0.45, 0.55, 0.38, 0, 0.45, 0.89);
  put(2, -0.09, 0.52, 0.02, 0.15, 0.5, 0.72, 0.86, 0.58, 0, 0.55, 0.83);
  put(3, 0.09, 0.52, 0.02, 0.85, 0.5, 0.72, 0.86, 0.58, 0, 0.55, 0.83);
  put(4, 0, 1, 0.05, 0.5, 0, 1, 1, 0.88, 0, 0.7, 0.71);

  // Blade B along Z axis.
  put(5, 0, 0, -0.14, 0, 1, 0.45, 0.55, 0.38, 0.89, 0.45, 0);
  put(6, 0, 0, 0.14, 1, 1, 0.45, 0.55, 0.38, 0.89, 0.45, 0);
  put(7, -0.02, 0.52, -0.09, 0.15, 0.5, 0.72, 0.86, 0.58, 0.83, 0.55, 0);
  put(8, -0.02, 0.52, 0.09, 0.85, 0.5, 0.72, 0.86, 0.58, 0.83, 0.55, 0);
  put(9, -0.05, 1, 0, 0.5, 0, 1, 1, 0.88, 0.71, 0.7, 0);

  final indices = Uint16List.fromList(const [
    0, 1, 3, 0, 3, 2, 2, 3, 4, //
    5, 6, 8, 5, 8, 7, 7, 8, 9, //
  ]);

  return Mesh()..addSurface(
    Surface.fromBuffers(
      vertices: verts,
      indices: indices,
      material: material,
    ),
  );
}
