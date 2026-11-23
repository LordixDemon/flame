part of 'light_cluster_grid_3d.dart';

extension _LightClusterGridAssignment on LightClusterGrid3D {
  void _assignLightsImpl(
    Matrix4 view,
    Matrix4 projection, {
    required double near,
    required double far,
    int cameraMask = 0xFFFFFFFF,
  }) {
    if (near <= 0 || far <= near) {
      throw ArgumentError(
        'Expected 0 < near < far, got near=$near, far=$far',
      );
    }

    _ensureClusterBounds(projection, near, far);
    _scratchCounts.fillRange(0, totalClusters, 0);

    final v = view.storage;
    final count = _lights.length;

    for (var i = 0; i < count; i++) {
      final entry = _lights[i];
      if (entry.intensity <= 0 || (entry.lightMask & cameraMask) == 0) {
        _lightIntensity[i] = 0;
        continue;
      }

      final px = entry.position.x;
      final py = entry.position.y;
      final pz = entry.position.z;
      final vx = v[0] * px + v[4] * py + v[8] * pz + v[12];
      final vy = v[1] * px + v[5] * py + v[9] * pz + v[13];
      final vz = v[2] * px + v[6] * py + v[10] * pz + v[14];
      final r = entry.range;

      _viewPosX[i] = vx;
      _viewPosY[i] = vy;
      _viewPosZ[i] = vz;
      _lightRange[i] = r;
      _lightIntensity[i] = entry.intensity;

      final isSpot = entry.kind == ClusterLightKind3D.spot;
      _lightKind[i] = isSpot ? 1 : 0;

      var vdx = 0.0;
      var vdy = 0.0;
      var vdz = -1.0;
      var cosA = -1.0;
      var sinA = 0.0;
      if (isSpot) {
        final dx = entry.direction.x;
        final dy = entry.direction.y;
        final dz = entry.direction.z;
        vdx = v[0] * dx + v[4] * dy + v[8] * dz;
        vdy = v[1] * dx + v[5] * dy + v[9] * dz;
        vdz = v[2] * dx + v[6] * dy + v[10] * dz;
        final dLen = math.sqrt(vdx * vdx + vdy * vdy + vdz * vdz);
        if (dLen > 1e-12) {
          final inv = 1.0 / dLen;
          vdx *= inv;
          vdy *= inv;
          vdz *= inv;
        }
        cosA = entry.outerConeCos.clamp(-1.0, 1.0);
        sinA = math.sqrt(math.max(0.0, 1.0 - cosA * cosA));
        _viewDirX[i] = vdx;
        _viewDirY[i] = vdy;
        _viewDirZ[i] = vdz;
        _lightOuterCos[i] = cosA;
        _lightOuterSin[i] = sinA;
      }

      // View-space depth runs along -Z (`viewDepth = -vz`).
      final minDepth = -vz - r;
      final maxDepth = -vz + r;
      if (maxDepth < near || minDepth > far) {
        continue;
      }

      final iz0 = zSliceForViewDepth(math.max(near, minDepth));
      final iz1 = zSliceForViewDepth(math.min(far, maxDepth));
      final rSq = r * r;
      final cosA2 = cosA * cosA;
      final sinA2 = sinA * sinA;
      final outerEps = cosA <= -1.0 + 1e-6 ? math.pi : 0.0;

      for (var iz = iz0; iz <= iz1; iz++) {
        final rowBase = iz * clustersY;
        for (var iy = 0; iy < clustersY; iy++) {
          final rb = (rowBase + iy) * 2;
          if (vy + r < _rowBoundsY[rb] || vy - r > _rowBoundsY[rb + 1]) {
            continue;
          }

          final cellBase = (rowBase + iy) * clustersX;
          for (var ix = 0; ix < clustersX; ix++) {
            final c = cellBase + ix;
            final slotCount = _scratchCounts[c];
            if (slotCount >= maxLightsPerCluster) {
              continue;
            }
            final b = c * 6;
            if (!sphereIntersectsAabb(
              vx,
              vy,
              vz,
              rSq,
              _clusterBoundsView[b],
              _clusterBoundsView[b + 1],
              _clusterBoundsView[b + 2],
              _clusterBoundsView[b + 3],
              _clusterBoundsView[b + 4],
              _clusterBoundsView[b + 5],
            )) {
              continue;
            }

            if (isSpot) {
              final cs = c * 4;
              final cx = _clusterSpheres[cs];
              final cy = _clusterSpheres[cs + 1];
              final cz = _clusterSpheres[cs + 2];
              final cr = _clusterSpheres[cs + 3];
              final axial = (cx - vx) * vdx + (cy - vy) * vdy + (cz - vz) * vdz;
              if (axial > r + cr ||
                  !coneIntersectsSphereFast(
                    vx,
                    vy,
                    vz,
                    vdx,
                    vdy,
                    vdz,
                    outerEps,
                    sinA,
                    cosA,
                    cosA2,
                    sinA2,
                    cx,
                    cy,
                    cz,
                    cr,
                  )) {
                continue;
              }
            }

            _scratchIndices[c * maxLightsPerCluster + slotCount] = i;
            _scratchCounts[c] = slotCount + 1;
          }
        }
      }
    }

    // Compact into CSR arrays `clusterOffsets`, `clusterCounts`, and
    // `lightIndexList`.
    var writeCursor = 0;
    for (var c = 0; c < totalClusters; c++) {
      clusterOffsets[c] = writeCursor;
      final n = _scratchCounts[c];
      clusterCounts[c] = n;
      if (n > 0) {
        final srcStart = c * maxLightsPerCluster;
        for (var k = 0; k < n; k++) {
          lightIndexList[writeCursor + k] = _scratchIndices[srcStart + k];
        }
        writeCursor += n;
      }
    }
    _totalAssignedLightRefs = writeCursor;
  }

  ClusterLightSelection3D _gatherTopLightsForAabbImpl(
    Aabb3 worldAabb,
    Matrix4 view, {
    int maxPointLights = 8,
    int maxSpotLights = 4,
  }) {
    final v = view.storage;
    var vMinX = double.infinity;
    var vMinY = double.infinity;
    var vMinZ = double.infinity;
    var vMaxX = double.negativeInfinity;
    var vMaxY = double.negativeInfinity;
    var vMaxZ = double.negativeInfinity;

    for (var corner = 0; corner < 8; corner++) {
      final wx = (corner & 1) == 0 ? worldAabb.min.x : worldAabb.max.x;
      final wy = (corner & 2) == 0 ? worldAabb.min.y : worldAabb.max.y;
      final wz = (corner & 4) == 0 ? worldAabb.min.z : worldAabb.max.z;
      final tx = v[0] * wx + v[4] * wy + v[8] * wz + v[12];
      final ty = v[1] * wx + v[5] * wy + v[9] * wz + v[13];
      final tz = v[2] * wx + v[6] * wy + v[10] * wz + v[14];
      if (tx < vMinX) {
        vMinX = tx;
      }
      if (tx > vMaxX) {
        vMaxX = tx;
      }
      if (ty < vMinY) {
        vMinY = ty;
      }
      if (ty > vMaxY) {
        vMaxY = ty;
      }
      if (tz < vMinZ) {
        vMinZ = tz;
      }
      if (tz > vMaxZ) {
        vMaxZ = tz;
      }
    }

    final minDepth = -vMaxZ;
    final maxDepth = -vMinZ;
    if (maxDepth < _near || minDepth > _far) {
      return ClusterLightSelection3D(
        LightClusterGrid3D._emptyInts,
        LightClusterGrid3D._emptyInts,
      );
    }

    final iz0 = zSliceForViewDepth(math.max(_near, minDepth));
    final iz1 = zSliceForViewDepth(math.min(_far, maxDepth));
    final stamp = ++_stampGeneration;

    final centerVx = 0.5 * (vMinX + vMaxX);
    final centerVy = 0.5 * (vMinY + vMaxY);
    final centerVz = 0.5 * (vMinZ + vMaxZ);

    var pointCount = 0;
    var spotCount = 0;

    for (var iz = iz0; iz <= iz1; iz++) {
      final rowBase = iz * clustersY;
      for (var iy = 0; iy < clustersY; iy++) {
        final rb = (rowBase + iy) * 2;
        if (vMaxY < _rowBoundsY[rb] || vMinY > _rowBoundsY[rb + 1]) {
          continue;
        }
        final cellBase = (rowBase + iy) * clustersX;
        for (var ix = 0; ix < clustersX; ix++) {
          final c = cellBase + ix;
          final b = c * 6;
          if (vMaxX < _clusterBoundsView[b] ||
              vMinX > _clusterBoundsView[b + 3] ||
              vMaxY < _clusterBoundsView[b + 1] ||
              vMinY > _clusterBoundsView[b + 4] ||
              vMaxZ < _clusterBoundsView[b + 2] ||
              vMinZ > _clusterBoundsView[b + 5]) {
            continue;
          }

          final cCount = clusterCounts[c];
          final cOffset = clusterOffsets[c];
          for (var k = 0; k < cCount; k++) {
            final lightIdx = lightIndexList[cOffset + k];
            if (_seenStamp[lightIdx] == stamp) {
              continue;
            }
            _seenStamp[lightIdx] = stamp;

            final lx = _viewPosX[lightIdx];
            final ly = _viewPosY[lightIdx];
            final lz = _viewPosZ[lightIdx];
            final r = _lightRange[lightIdx];

            // Exact sphere vs view-space AABB check.
            final qx = lx < vMinX ? vMinX - lx : (lx > vMaxX ? lx - vMaxX : 0);
            final qy = ly < vMinY ? vMinY - ly : (ly > vMaxY ? ly - vMaxY : 0);
            final qz = lz < vMinZ ? vMinZ - lz : (lz > vMaxZ ? lz - vMaxZ : 0);
            if (qx * qx + qy * qy + qz * qz > r * r) {
              continue;
            }

            final dx = centerVx - lx;
            final dy = centerVy - ly;
            final dz = centerVz - lz;
            final dist = math.sqrt(dx * dx + dy * dy + dz * dz);
            final atten = math.max(0.01, 1.0 - (dist / r).clamp(0.0, 0.99));
            final score = _lightIntensity[lightIdx] * atten * atten;

            if (_lightKind[lightIdx] == 0) {
              _candidatePointIds[pointCount] = lightIdx;
              _candidatePointScores[pointCount] = score;
              pointCount++;
            } else {
              _candidateSpotIds[spotCount] = lightIdx;
              _candidateSpotScores[spotCount] = score;
              spotCount++;
            }
          }
        }
      }
    }

    _partialSortClusterTopK(
      _candidatePointIds,
      _candidatePointScores,
      pointCount,
      maxPointLights,
    );
    _partialSortClusterTopK(
      _candidateSpotIds,
      _candidateSpotScores,
      spotCount,
      maxSpotLights,
    );

    final outPointCount = math.min(pointCount, math.max(0, maxPointLights));
    final outSpotCount = math.min(spotCount, math.max(0, maxSpotLights));

    return ClusterLightSelection3D(
      outPointCount == 0
          ? LightClusterGrid3D._emptyInts
          : Int32List.fromList(
              Int32List.sublistView(_candidatePointIds, 0, outPointCount),
            ),
      outSpotCount == 0
          ? LightClusterGrid3D._emptyInts
          : Int32List.fromList(
              Int32List.sublistView(_candidateSpotIds, 0, outSpotCount),
            ),
    );
  }

  void _ensureClusterBounds(Matrix4 projection, double near, double far) {
    final p = projection.storage;
    var same = _hasCachedProjection && near == _near && far == _far;
    if (same) {
      for (var i = 0; i < 16; i++) {
        if (p[i] != _cachedProjection[i]) {
          same = false;
          break;
        }
      }
    }
    if (same) {
      return;
    }

    _hasCachedProjection = true;
    _near = near;
    _far = far;
    _logFarOverNear = math.log(far / near);
    for (var i = 0; i < 16; i++) {
      _cachedProjection[i] = p[i];
    }

    final ratio = far / near;
    for (var iz = 0; iz < clustersZ; iz++) {
      _sliceNear[iz] = near * math.pow(ratio, iz / clustersZ);
      _sliceFar[iz] = near * math.pow(ratio, (iz + 1) / clustersZ);
    }

    _invProjScratch.setFrom(projection);
    final det = _invProjScratch.invert();
    final inv = _invProjScratch.storage;
    final cols = clustersX + 1;
    final rows = clustersY + 1;

    if (det.abs() > 1e-15) {
      for (var iy = 0; iy < rows; iy++) {
        final ndcY = (iy / clustersY) * 2.0 - 1.0;
        for (var ix = 0; ix < cols; ix++) {
          final ndcX = (ix / clustersX) * 2.0 - 1.0;
          final o = (iy * cols + ix) * 3;
          _unprojectClusterClipPoint(
            inv,
            ndcX,
            ndcY,
            0,
            near,
            _cornerNearView,
            o,
          );
          _unprojectClusterClipPoint(
            inv,
            ndcX,
            ndcY,
            1,
            far,
            _cornerFarView,
            o,
          );
        }
      }
    } else {
      // Degenerate fallback box if a singular matrix is supplied.
      for (var iy = 0; iy < rows; iy++) {
        final ndcY = (iy / clustersY) * 2.0 - 1.0;
        for (var ix = 0; ix < cols; ix++) {
          final ndcX = (ix / clustersX) * 2.0 - 1.0;
          final o = (iy * cols + ix) * 3;
          _cornerNearView
            ..[o] = ndcX * near
            ..[o + 1] = ndcY * near
            ..[o + 2] = -near;
          _cornerFarView
            ..[o] = ndcX * far
            ..[o + 1] = ndcY * far
            ..[o + 2] = -far;
        }
      }
    }

    final invSpan = 1.0 / (far - near);
    for (var iz = 0; iz < clustersZ; iz++) {
      final d0 = _sliceNear[iz];
      final d1 = _sliceFar[iz];
      final t0 = (d0 - near) * invSpan;
      final t1 = (d1 - near) * invSpan;

      for (var iy = 0; iy < clustersY; iy++) {
        var rMinY = double.infinity;
        var rMaxY = double.negativeInfinity;

        for (var ix = 0; ix < clustersX; ix++) {
          var minX = double.infinity;
          var minY = double.infinity;
          var maxX = double.negativeInfinity;
          var maxY = double.negativeInfinity;

          for (var dy = 0; dy <= 1; dy++) {
            for (var dx = 0; dx <= 1; dx++) {
              final co = ((iy + dy) * cols + (ix + dx)) * 3;
              final nx = _cornerNearView[co];
              final ny = _cornerNearView[co + 1];
              final fx = _cornerFarView[co];
              final fy = _cornerFarView[co + 1];

              final x0 = nx + (fx - nx) * t0;
              final y0 = ny + (fy - ny) * t0;
              final x1 = nx + (fx - nx) * t1;
              final y1 = ny + (fy - ny) * t1;

              minX = math.min(minX, math.min(x0, x1));
              maxX = math.max(maxX, math.max(x0, x1));
              minY = math.min(minY, math.min(y0, y1));
              maxY = math.max(maxY, math.max(y0, y1));
            }
          }

          if (minY < rMinY) {
            rMinY = minY;
          }
          if (maxY > rMaxY) {
            rMaxY = maxY;
          }

          final clusterIdx = (iz * clustersY + iy) * clustersX + ix;
          final cb = clusterIdx * 6;
          _clusterBoundsView
            ..[cb] = minX
            ..[cb + 1] = minY
            ..[cb + 2] = -d1
            ..[cb + 3] = maxX
            ..[cb + 4] = maxY
            ..[cb + 5] = -d0;
          final hx = 0.5 * (maxX - minX);
          final hy = 0.5 * (maxY - minY);
          final hz = 0.5 * (d1 - d0);
          final cs = clusterIdx * 4;
          _clusterSpheres
            ..[cs] = 0.5 * (minX + maxX)
            ..[cs + 1] = 0.5 * (minY + maxY)
            ..[cs + 2] = -0.5 * (d0 + d1)
            ..[cs + 3] = math.sqrt(hx * hx + hy * hy + hz * hz);
        }

        final rb = (iz * clustersY + iy) * 2;
        _rowBoundsY
          ..[rb] = rMinY
          ..[rb + 1] = rMaxY;
      }
    }
  }
}

void _unprojectClusterClipPoint(
  Float32List invProj,
  double ndcX,
  double ndcY,
  double ndcZ,
  double fallbackDepth,
  Float32List out,
  int offset,
) {
  final x =
      invProj[0] * ndcX + invProj[4] * ndcY + invProj[8] * ndcZ + invProj[12];
  final y =
      invProj[1] * ndcX + invProj[5] * ndcY + invProj[9] * ndcZ + invProj[13];
  final z =
      invProj[2] * ndcX + invProj[6] * ndcY + invProj[10] * ndcZ + invProj[14];
  final w =
      invProj[3] * ndcX + invProj[7] * ndcY + invProj[11] * ndcZ + invProj[15];
  if (w.abs() > 1e-12) {
    final invW = 1.0 / w;
    out
      ..[offset] = x * invW
      ..[offset + 1] = y * invW
      ..[offset + 2] = z * invW;
  } else {
    out
      ..[offset] = ndcX * fallbackDepth
      ..[offset + 1] = ndcY * fallbackDepth
      ..[offset + 2] = -fallbackDepth;
  }
}

void _partialSortClusterTopK(
  Int32List ids,
  Float32List scores,
  int length,
  int k,
) {
  final limit = math.min(length, math.max(0, k));
  for (var i = 0; i < limit; i++) {
    var best = i;
    var bestScore = scores[i];
    for (var j = i + 1; j < length; j++) {
      if (scores[j] > bestScore) {
        bestScore = scores[j];
        best = j;
      }
    }
    if (best != i) {
      final tmpId = ids[i];
      ids[i] = ids[best];
      ids[best] = tmpId;
      final tmpScore = scores[i];
      scores[i] = scores[best];
      scores[best] = tmpScore;
    }
  }
}
