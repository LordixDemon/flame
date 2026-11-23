part of 'light_grid_3d.dart';

class _LightGridTextureRing() {
  final List<Texture?> _ring = List.filled(3, null);
  final List<GpuTexture?> _ringGpu = List.filled(3, null);
  final Int32List _ringVersion = Int32List(3)..fillRange(0, 3, -1);
  final Int32List _ringGeneration = Int32List(3)..fillRange(0, 3, -1);
  final List<GpuBackend?> _ringBackend = List.filled(3, null);
  int _ringNext = 0;

  /// The texture holding [texels] for [backend], uploaded when its contents
  /// changed since it was last uploaded (or the GPU device was lost).
  Texture uploadIfChanged(
    GpuBackend backend,
    Float32List texels,
    int contentVersion,
    LightGridStats stats,
  ) {
    final generation = GpuBackend.deviceGeneration;
    for (var i = 0; i < 3; i++) {
      if (_ringVersion[i] == contentVersion &&
          _ringGeneration[i] == generation &&
          identical(_ringBackend[i], backend)) {
        return _ring[i]!;
      }
    }
    final slot = _ringNext;
    _ringNext = (_ringNext + 1) % 3;
    final height = stats.textureHeight;
    var texture = _ring[slot];
    var gpuTexture = _ringGpu[slot];
    if (texture == null ||
        gpuTexture == null ||
        texture.height != height ||
        !identical(_ringBackend[slot], backend)) {
      gpuTexture = backend.createTexture(
        storageMode: GpuStorageMode.hostVisible,
        width: LightGrid3D.textureWidth,
        height: height,
        format: GpuPixelFormat.rgbaFloat32,
      );
      texture = Texture(
        null,
        width: LightGrid3D.textureWidth,
        height: height,
        format: PixelFormat.rgbaFloat32,
        gpuTexture: gpuTexture,
      );
      _ring[slot] = texture;
      _ringGpu[slot] = gpuTexture;
      _ringBackend[slot] = backend;
    }
    gpuTexture.write(
      ByteData.sublistView(texels, 0, height * LightGrid3D.textureWidth * 4),
    );
    _ringVersion[slot] = contentVersion;
    _ringGeneration[slot] = generation;
    stats.uploads++;
    return texture;
  }
}

extension _LightGridPacking on LightGrid3D {
  int _layOut(
    LightGridSettings settings,
    double minX,
    double minY,
    double minZ,
    double maxX,
    double maxY,
    double maxZ,
  ) {
    final s = stats;
    final cell = s.cellSize;
    final nx = s.cellsX;
    final ny = s.cellsY;
    final nz = s.cellsZ;
    final cells = nx * ny * nz;
    final ox = origin.x;
    final oy = origin.y;
    final oz = origin.z;

    // The lights that reach the box, and among them the maxLights of the
    // most power.
    var kept = 0;
    for (var k = 0; k < _lightCount; k++) {
      final o = k * LightGrid3D._stride;
      final x = _light[o];
      final y = _light[o + 1];
      final z = _light[o + 2];
      final r = _light[o + 3] + LightGrid3D._margin(cell, x, y, z);
      final reaches =
          x + r >= minX &&
          x - r <= maxX &&
          y + r >= minY &&
          y - r <= maxY &&
          z + r >= minZ &&
          z - r <= maxZ;
      _light[o + 15] = reaches ? 1 : 0;
      if (reaches) {
        kept++;
      }
    }
    var dropped = 0;
    if (kept > settings.maxLights) {
      dropped = _keepStrongest(settings.maxLights);
    }

    _pointPairs = 0;
    _spotPairs = 0;
    var points = 0;
    var spots = 0;
    for (var k = 0; k < _lightCount; k++) {
      final o = k * LightGrid3D._stride;
      if (_light[o + 15] == 0) {
        continue;
      }
      final x = _light[o];
      final y = _light[o + 1];
      final z = _light[o + 2];
      final range = _light[o + 3];
      final r = range + LightGrid3D._margin(cell, x, y, z);
      final isSpot = _lightKind[k] == 1;
      if (isSpot) {
        spots++;
      } else {
        points++;
      }
      final cx0 = math.max(0, ((x - r - ox) / cell).floor());
      final cy0 = math.max(0, ((y - r - oy) / cell).floor());
      final cz0 = math.max(0, ((z - r - oz) / cell).floor());
      final cx1 = math.min(nx - 1, ((x + r - ox) / cell).floor());
      final cy1 = math.min(ny - 1, ((y + r - oy) / cell).floor());
      final cz1 = math.min(nz - 1, ((z + r - oz) / cell).floor());
      final r2 = r * r;
      // The cone of a spot light, against the sphere around a cell.
      final cellRadius = cell * 0.8660254037844386;
      final sphereRadius = cellRadius + LightGrid3D._margin(cell, x, y, z);
      final ax = -_light[o + 8];
      final ay = -_light[o + 9];
      final az = -_light[o + 10];
      final outerEps = _light[o + 14] + 1e-3;
      final sinA = math.sin(outerEps);
      final cosA = math.cos(outerEps);
      final cosA2 = cosA * cosA;
      final sinA2 = sinA * sinA;
      for (var cz = cz0; cz <= cz1; cz++) {
        final bz0 = oz + cz * cell;
        final dz = z < bz0 ? bz0 - z : (z > bz0 + cell ? z - bz0 - cell : 0.0);
        for (var cy = cy0; cy <= cy1; cy++) {
          final by0 = oy + cy * cell;
          final dy = y < by0
              ? by0 - y
              : (y > by0 + cell ? y - by0 - cell : 0.0);
          for (var cx = cx0; cx <= cx1; cx++) {
            final bx0 = ox + cx * cell;
            final dx = x < bx0
                ? bx0 - x
                : (x > bx0 + cell ? x - bx0 - cell : 0.0);
            if (dx * dx + dy * dy + dz * dz > r2) {
              continue;
            }
            if (isSpot &&
                !coneIntersectsSphereFast(
                  x,
                  y,
                  z,
                  ax,
                  ay,
                  az,
                  outerEps,
                  sinA,
                  cosA,
                  cosA2,
                  sinA2,
                  bx0 + cell * 0.5,
                  by0 + cell * 0.5,
                  bz0 + cell * 0.5,
                  sphereRadius,
                )) {
              continue;
            }
            final index = cx + nx * (cy + ny * cz);
            if (isSpot) {
              _addSpotPair(index, k);
            } else {
              _addPointPair(index, k);
            }
          }
        }
      }
    }
    s
      ..pointLights = points
      ..spotLights = spots
      ..droppedLights = dropped;

    // The texels: the headers, then each cell's point and spot lights.
    if (_cellCounts.length < cells) {
      final cap = _nextPow2(cells);
      _cellCounts = Int32List(cap);
      _cellStarts = Int32List(cap);
    }
    final pointCap = settings.maxPointLightsPerCell;
    final spotCap = settings.maxSpotLightsPerCell;
    var needed = cells;
    // Count first, to know the size.
    final pointsPerCell = _countPairs(_pointCells, _pointPairs, cells);
    for (var c = 0; c < cells; c++) {
      needed += 2 * math.min(pointsPerCell[c], pointCap);
    }
    final spotsPerCell = _countSpotPairs(cells);
    for (var c = 0; c < cells; c++) {
      needed += 4 * math.min(spotsPerCell[c], spotCap);
    }
    if (needed > LightGrid3D.maxTexels) {
      return needed;
    }
    _ensureTexels(needed);
    final t = _texels..fillRange(0, cells * 4, 0);
    var next = cells;
    var entries = 0;
    var occupied = 0;
    var dropped2 = 0;
    var maxPoints = 0;
    var maxSpots = 0;

    // Point lights.
    _sortPairs(_pointCells, _pointLights, _pointPairs, pointsPerCell, cells);
    for (var c = 0; c < cells; c++) {
      final n = pointsPerCell[c];
      if (n == 0) {
        continue;
      }
      final start = _cellStarts[c];
      final chosen = _choose(c, start, n, pointCap);
      dropped2 += n - chosen;
      maxPoints = math.max(maxPoints, chosen);
      t
        ..[c * 4] = next.toDouble()
        ..[c * 4 + 1] = chosen.toDouble();
      for (var j = 0; j < chosen; j++) {
        final k = n > pointCap ? _chosen[j] : _ordered[start + j];
        final o = k * LightGrid3D._stride;
        final at = next * 4;
        t
          ..[at] = _light[o]
          ..[at + 1] = _light[o + 1]
          ..[at + 2] = _light[o + 2]
          ..[at + 3] = _light[o + 3]
          ..[at + 4] = _light[o + 4]
          ..[at + 5] = _light[o + 5]
          ..[at + 6] = _light[o + 6]
          ..[at + 7] = _light[o + 7];
        next += 2;
      }
      entries += chosen;
    }

    // Spot lights.
    _sortPairs(_spotCells, _spotLights, _spotPairs, spotsPerCell, cells);
    for (var c = 0; c < cells; c++) {
      final n = spotsPerCell[c];
      if (n == 0) {
        continue;
      }
      final start = _cellStarts[c];
      final chosen = _choose(c, start, n, spotCap);
      dropped2 += n - chosen;
      maxSpots = math.max(maxSpots, chosen);
      t
        ..[c * 4 + 2] = next.toDouble()
        ..[c * 4 + 3] = chosen.toDouble();
      for (var j = 0; j < chosen; j++) {
        final k = n > spotCap ? _chosen[j] : _ordered[start + j];
        final o = k * LightGrid3D._stride;
        final at = next * 4;
        for (var i = 0; i < 8; i++) {
          t[at + i] = _light[o + i];
        }
        t
          ..[at + 8] = _light[o + 8]
          ..[at + 9] = _light[o + 9]
          ..[at + 10] = _light[o + 10]
          ..[at + 11] = _light[o + 11]
          ..[at + 12] = _light[o + 12]
          ..[at + 13] = _light[o + 13]
          ..[at + 14] = 0
          ..[at + 15] = 0;
        next += 4;
      }
      entries += chosen;
    }
    for (var c = 0; c < cells; c++) {
      if (t[c * 4 + 1] > 0 || t[c * 4 + 3] > 0) {
        occupied++;
      }
    }
    s
      ..entries = entries
      ..occupiedCells = occupied
      ..droppedEntries = dropped2
      ..maxPointLightsInCell = maxPoints
      ..maxSpotLightsInCell = maxSpots
      ..active = entries > 0;
    _finishTexels(next);
    return next;
  }

  void _addPointPair(int cell, int light) {
    if (_pointPairs == _pointCells.length) {
      _pointCells = _grown(_pointCells, _pointPairs * 2);
      _pointLights = _grown(_pointLights, _pointPairs * 2);
    }
    _pointCells[_pointPairs] = cell;
    _pointLights[_pointPairs++] = light;
  }

  void _addSpotPair(int cell, int light) {
    if (_spotPairs == _spotCells.length) {
      _spotCells = _grown(_spotCells, _spotPairs * 2);
      _spotLights = _grown(_spotLights, _spotPairs * 2);
    }
    _spotCells[_spotPairs] = cell;
    _spotLights[_spotPairs++] = light;
  }

  Int32List _countPairs(Int32List pairCells, int pairs, int cells) {
    final counts = _cellCounts..fillRange(0, cells, 0);
    for (var i = 0; i < pairs; i++) {
      counts[pairCells[i]]++;
    }
    return counts;
  }

  Int32List _countSpotPairs(int cells) {
    if (_spotCounts.length < cells) {
      _spotCounts = Int32List(_nextPow2(cells));
    }
    final counts = _spotCounts..fillRange(0, cells, 0);
    for (var i = 0; i < _spotPairs; i++) {
      counts[_spotCells[i]]++;
    }
    return counts;
  }

  void _sortPairs(
    Int32List pairCells,
    Int32List pairLights,
    int pairs,
    Int32List counts,
    int cells,
  ) {
    var at = 0;
    for (var c = 0; c < cells; c++) {
      _cellStarts[c] = at;
      at += counts[c];
    }
    if (_ordered.length < pairs) {
      _ordered = Int32List(math.max(pairs, _ordered.length * 2));
    }
    for (var i = 0; i < pairs; i++) {
      final c = pairCells[i];
      _ordered[_cellStarts[c]++] = pairLights[i];
    }
    for (var c = 0; c < cells; c++) {
      _cellStarts[c] -= counts[c];
    }
  }

  int _choose(int c, int start, int n, int cap) {
    if (n <= cap) {
      return n;
    }
    final s = stats;
    final cell = s.cellSize;
    final nx = s.cellsX;
    final ny = s.cellsY;
    final cx = c % nx;
    final cy = (c ~/ nx) % ny;
    final cz = c ~/ (nx * ny);
    final bx0 = origin.x + cx * cell;
    final by0 = origin.y + cy * cell;
    final bz0 = origin.z + cz * cell;
    var count = 0;
    for (var j = 0; j < n; j++) {
      final k = _ordered[start + j];
      final o = k * LightGrid3D._stride;
      final x = _light[o];
      final y = _light[o + 1];
      final z = _light[o + 2];
      final dx = x < bx0 ? bx0 - x : (x > bx0 + cell ? x - bx0 - cell : 0.0);
      final dy = y < by0 ? by0 - y : (y > by0 + cell ? y - by0 - cell : 0.0);
      final dz = z < bz0 ? bz0 - z : (z > bz0 + cell ? z - bz0 - cell : 0.0);
      final fade = math.max(
        0.0,
        1 - math.sqrt(dx * dx + dy * dy + dz * dz) / _light[o + 3],
      );
      final score = _brightness(o) * fade * fade;
      int pos;
      if (count < cap) {
        pos = count++;
      } else if (score > _chosenScores[cap - 1]) {
        pos = cap - 1;
      } else {
        continue;
      }
      while (pos > 0 && _chosenScores[pos - 1] < score) {
        _chosenScores[pos] = _chosenScores[pos - 1];
        _chosen[pos] = _chosen[pos - 1];
        pos--;
      }
      _chosenScores[pos] = score;
      _chosen[pos] = k;
    }
    for (var i = 1; i < count; i++) {
      final k = _chosen[i];
      var j = i - 1;
      while (j >= 0 && _chosen[j] > k) {
        _chosen[j + 1] = _chosen[j];
        j--;
      }
      _chosen[j + 1] = k;
    }
    return count;
  }

  double _brightness(int o) =>
      _light[o + 7].abs() *
      (0.2126 * _light[o + 4] +
          0.7152 * _light[o + 5] +
          0.0722 * _light[o + 6]);

  int _keepStrongest(int max) {
    if (_power.length < _lightIndex.length) {
      _power = Float64List(_lightIndex.length);
      _powerScratch = Float64List(_lightIndex.length);
    }
    var n = 0;
    for (var k = 0; k < _lightCount; k++) {
      final o = k * LightGrid3D._stride;
      if (_light[o + 15] != 0) {
        final range = _light[o + 3];
        final power = _brightness(o) * range * range;
        _power[k] = power;
        _powerScratch[n++] = power;
      } else {
        _power[k] = -1;
      }
    }
    final threshold = _selectPowerRank(_powerScratch, n, max - 1);
    var above = 0;
    for (var k = 0; k < _lightCount; k++) {
      if (_power[k] > threshold) {
        above++;
      }
    }
    var ties = max - above;
    for (var k = 0; k < _lightCount; k++) {
      final o = k * LightGrid3D._stride;
      if (_light[o + 15] == 0) {
        continue;
      }
      final power = _power[k];
      if (power > threshold) {
        continue;
      }
      if (power == threshold && ties > 0) {
        ties--;
        continue;
      }
      _light[o + 15] = 0;
    }
    return n - max;
  }

  void _ensureTexels(int texels) {
    final rows =
        (texels + LightGrid3D.textureWidth - 1) ~/ LightGrid3D.textureWidth;
    var height = 1;
    while (height < rows) {
      height *= 2;
    }
    final floats = height * LightGrid3D.textureWidth * 4;
    if (_texels.length < floats) {
      _texels = Float32List(floats);
    }
  }

  void _finishTexels(int texels) {
    _ensureTexels(math.max(texels, 1));
    final rows =
        (math.max(texels, 1) + LightGrid3D.textureWidth - 1) ~/
        LightGrid3D.textureWidth;
    var height = 1;
    while (height < rows) {
      height *= 2;
    }
    _texels.fillRange(texels * 4, height * LightGrid3D.textureWidth * 4, 0);
    _texelCount = texels;
    stats
      ..usedTexels = texels
      ..textureHeight = height;
  }
}

int _nextPow2(int n) {
  var cap = 64;
  while (cap < n) {
    cap *= 2;
  }
  return cap;
}

Int32List _grown(Int32List list, int capacity) =>
    Int32List(capacity)..setRange(0, list.length, list);

double _selectPowerRank(Float64List values, int n, int rank) {
  var lo = 0;
  var hi = n - 1;
  while (lo < hi) {
    final pivot = values[(lo + hi) >> 1];
    var i = lo;
    var j = hi;
    while (i <= j) {
      while (values[i] > pivot) {
        i++;
      }
      while (values[j] < pivot) {
        j--;
      }
      if (i <= j) {
        final t = values[i];
        values[i] = values[j];
        values[j] = t;
        i++;
        j--;
      }
    }
    if (rank <= j) {
      hi = j;
    } else if (rank >= i) {
      lo = i;
    } else {
      return values[rank];
    }
  }
  return values[rank];
}
