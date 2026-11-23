part of 'chunked_terrain_3d.dart';

extension _ChunkedTerrainRaycast on ChunkedTerrain3D {
  void _syncInverseWorld(Matrix4 worldMat) {
    final ver = worldTransformVersion;
    if (ver == _invWorldVer) {
      return;
    }
    _invWorldVer = ver;
    _invWorldIsIdentity = worldMat.isIdentity();
    if (_invWorldIsIdentity) {
      _invWorldValid = true;
      return;
    }
    _invWorldScratch.setFrom(worldMat);
    _invWorldValid = _invWorldScratch.invert().abs() > 1e-15;
  }

  RayHit3D? _raycastImpl(
    Ray worldRay, {
    double maxDistance = double.infinity,
    CullMode? cullMode,
  }) {
    if (!(maxDistance > 0)) {
      return null;
    }
    final worldMat = worldTransformMatrix;
    _syncInverseWorld(worldMat);
    if (!_invWorldIsIdentity && !_invWorldValid) {
      return null;
    }

    if (_invWorldIsIdentity) {
      if (!rayHitsAabb(worldRay, _localAabb, maxDistance)) {
        return null;
      }
    } else {
      _worldNodeBox
        ..setFrom(_localAabb)
        ..transform(worldMat);
      if (!rayHitsAabb(worldRay, _worldNodeBox, maxDistance)) {
        return null;
      }
    }

    final ox = worldRay.origin.x;
    final oy = worldRay.origin.y;
    final oz = worldRay.origin.z;
    final dx = worldRay.direction.x;
    final dy = worldRay.direction.y;
    final dz = worldRay.direction.z;

    final double lox;
    final double loy;
    final double loz;
    final double ldx;
    final double ldy;
    final double ldz;
    if (_invWorldIsIdentity) {
      lox = ox;
      loy = oy;
      loz = oz;
      ldx = dx;
      ldy = dy;
      ldz = dz;
    } else {
      final m = _invWorldScratch.storage;
      lox = m[0] * ox + m[4] * oy + m[8] * oz + m[12];
      loy = m[1] * ox + m[5] * oy + m[9] * oz + m[13];
      loz = m[2] * ox + m[6] * oy + m[10] * oz + m[14];
      ldx = m[0] * dx + m[4] * dy + m[8] * dz;
      ldy = m[1] * dx + m[5] * dy + m[9] * dz;
      ldz = m[2] * dx + m[6] * dy + m[10] * dz;
    }

    final invDx = ldx.abs() > 1e-18 ? 1.0 / ldx : double.infinity;
    final invDy = ldy.abs() > 1e-18 ? 1.0 / ldy : double.infinity;
    final invDz = ldz.abs() > 1e-18 ? 1.0 / ldz : double.infinity;
    final effectiveCull = cullMode ?? material.renderState.cullMode;

    final dxCell = worldWidth / (gridColumns - 1);
    final dzCell = worldDepth / (gridRows - 1);
    final halfW = worldWidth * 0.5;
    final halfD = worldDepth * 0.5;

    _TerrainQuadNode3D? bestNode;
    var bestDist = maxDistance;
    var bestLocalX = 0.0;
    var bestLocalY = 0.0;
    var bestLocalZ = 0.0;
    var bestNx = 0.0;
    var bestNy = 1.0;
    var bestNz = 0.0;
    var bestTriIndex = 0;
    var bestSurfaceIndex = 0;
    var leafIdx = 0;

    final stack = _nodeStack..clear();
    for (var i = _roots.length - 1; i >= 0; i--) {
      stack.add(_roots[i]);
    }
    while (stack.isNotEmpty) {
      final node = stack.removeLast();
      if (!_localRayHitsAabb(
        lox,
        loy,
        loz,
        ldx,
        ldy,
        ldz,
        invDx,
        invDy,
        invDz,
        node.localBounds,
        bestDist,
      )) {
        continue;
      }
      final kids = node.children;
      if (kids != null && kids.isNotEmpty) {
        for (var i = kids.length - 1; i >= 0; i--) {
          stack.add(kids[i]);
        }
        continue;
      }

      final curLeaf = leafIdx++;
      final step = node.step;
      final cEnd = node.colEnd;
      final rEnd = node.rowEnd;
      final strideCols = (cEnd - node.colStart + step - 1) ~/ step;
      var rCell = 0;

      for (var r0 = node.rowStart; r0 < rEnd; r0 += step, rCell++) {
        final r1 = r0 + step < rEnd ? r0 + step : rEnd;
        final z0 = -halfD + r0 * dzCell;
        final z1 = -halfD + r1 * dzCell;
        final rowBase0 = r0 * gridColumns;
        final rowBase1 = r1 * gridColumns;
        var cCell = 0;

        for (var c0 = node.colStart; c0 < cEnd; c0 += step, cCell++) {
          final c1 = c0 + step < cEnd ? c0 + step : cEnd;
          final x0 = -halfW + c0 * dxCell;
          final x1 = -halfW + c1 * dxCell;
          final h00 = heights[rowBase0 + c0];
          final h10 = heights[rowBase0 + c1];
          final h01 = heights[rowBase1 + c0];
          final h11 = heights[rowBase1 + c1];

          var minY = h00;
          var maxY = h00;
          if (h10 < minY) {
            minY = h10;
          }
          if (h10 > maxY) {
            maxY = h10;
          }
          if (h01 < minY) {
            minY = h01;
          }
          if (h01 > maxY) {
            maxY = h01;
          }
          if (h11 < minY) {
            minY = h11;
          }
          if (h11 > maxY) {
            maxY = h11;
          }

          if (!_localRayHitsExtents(
            lox,
            loy,
            loz,
            ldx,
            ldy,
            ldz,
            invDx,
            invDy,
            invDz,
            x0,
            minY,
            z0,
            x1,
            maxY,
            z1,
            bestDist,
          )) {
            continue;
          }

          final triBase = (rCell * strideCols + cCell) * 2;

          // Tri 1: (v00, v01, v11)
          final t1 = _intersectLocalTri(
            lox,
            loy,
            loz,
            ldx,
            ldy,
            ldz,
            x0,
            h00,
            z0,
            x0,
            h01,
            z1,
            x1,
            h11,
            z1,
            bestDist,
            effectiveCull,
          );
          if (t1 >= 0.0 && t1 < bestDist) {
            bestDist = t1;
            bestNode = node;
            bestSurfaceIndex = curLeaf;
            bestTriIndex = triBase;
            bestLocalX = lox + ldx * t1;
            bestLocalY = loy + ldy * t1;
            bestLocalZ = loz + ldz * t1;
            const e1x = 0.0;
            final e1y = h01 - h00;
            final e1z = z1 - z0;
            final e2x = x1 - x0;
            final e2y = h11 - h00;
            final e2z = z1 - z0;
            bestNx = e1y * e2z - e1z * e2y;
            bestNy = e1z * e2x - e1x * e2z;
            bestNz = e1x * e2y - e1y * e2x;
          }

          // Tri 2: (v00, v11, v10)
          final t2 = _intersectLocalTri(
            lox,
            loy,
            loz,
            ldx,
            ldy,
            ldz,
            x0,
            h00,
            z0,
            x1,
            h11,
            z1,
            x1,
            h10,
            z0,
            bestDist,
            effectiveCull,
          );
          if (t2 >= 0.0 && t2 < bestDist) {
            bestDist = t2;
            bestNode = node;
            bestSurfaceIndex = curLeaf;
            bestTriIndex = triBase + 1;
            bestLocalX = lox + ldx * t2;
            bestLocalY = loy + ldy * t2;
            bestLocalZ = loz + ldz * t2;
            final e1x = x1 - x0;
            final e1y = h11 - h00;
            final e1z = z1 - z0;
            final e2x = x1 - x0;
            final e2y = h10 - h00;
            const e2z = 0.0;
            bestNx = e1y * e2z - e1z * e2y;
            bestNy = e1z * e2x - e1x * e2z;
            bestNz = e1x * e2y - e1y * e2x;
          }
        }
      }
    }

    if (bestNode == null) {
      return null;
    }

    final nLen = math.sqrt(bestNx * bestNx + bestNy * bestNy + bestNz * bestNz);
    if (nLen > 1e-12) {
      bestNx /= nLen;
      bestNy /= nLen;
      bestNz /= nLen;
    } else {
      bestNx = 0.0;
      bestNy = 1.0;
      bestNz = 0.0;
    }

    double wnx;
    double wny;
    double wnz;
    if (_invWorldIsIdentity) {
      wnx = bestNx;
      wny = bestNy;
      wnz = bestNz;
    } else {
      final m = _invWorldScratch.storage;
      wnx = m[0] * bestNx + m[1] * bestNy + m[2] * bestNz;
      wny = m[4] * bestNx + m[5] * bestNy + m[6] * bestNz;
      wnz = m[8] * bestNx + m[9] * bestNy + m[10] * bestNz;
      final wnLen = math.sqrt(wnx * wnx + wny * wny + wnz * wnz);
      if (wnLen > 1e-12) {
        wnx /= wnLen;
        wny /= wnLen;
        wnz /= wnLen;
      }
    }

    final hitSurface =
        bestNode.cachedSurface ??
        (_raycastFallbackSurface ??= Surface.fromBuffers(
          vertices: Float32List(VertexLayout.standard.strideInFloats),
          indices: Uint16List(0),
          material: material,
          aabb: Aabb3.copy(_localAabb),
        ));

    return RayHit3D(
      object: this,
      surface: hitSurface,
      surfaceIndex: bestSurfaceIndex,
      distance: bestDist,
      worldPoint: Vector3(
        ox + dx * bestDist,
        oy + dy * bestDist,
        oz + dz * bestDist,
      ),
      worldNormal: Vector3(wnx, wny, wnz),
      localPoint: Vector3(bestLocalX, bestLocalY, bestLocalZ),
      localNormal: Vector3(bestNx, bestNy, bestNz),
      triangleIndex: bestTriIndex,
    );
  }
}

bool _localRayHitsAabb(
  double ox,
  double oy,
  double oz,
  double dx,
  double dy,
  double dz,
  double invDx,
  double invDy,
  double invDz,
  Aabb3 box,
  double maxDist,
) => _localRayHitsExtents(
  ox,
  oy,
  oz,
  dx,
  dy,
  dz,
  invDx,
  invDy,
  invDz,
  box.min.x,
  box.min.y,
  box.min.z,
  box.max.x,
  box.max.y,
  box.max.z,
  maxDist,
);

bool _localRayHitsExtents(
  double ox,
  double oy,
  double oz,
  double dx,
  double dy,
  double dz,
  double invDx,
  double invDy,
  double invDz,
  double minX,
  double minY,
  double minZ,
  double maxX,
  double maxY,
  double maxZ,
  double maxDist,
) {
  var tMin = 0.0;
  var tMax = maxDist;

  if (dx.abs() <= 1e-18) {
    if (ox < minX || ox > maxX) {
      return false;
    }
  } else {
    var t0 = (minX - ox) * invDx;
    var t1 = (maxX - ox) * invDx;
    if (t0 > t1) {
      final tmp = t0;
      t0 = t1;
      t1 = tmp;
    }
    if (t0 > tMin) {
      tMin = t0;
    }
    if (t1 < tMax) {
      tMax = t1;
    }
    if (tMax < tMin) {
      return false;
    }
  }

  if (dy.abs() <= 1e-18) {
    if (oy < minY || oy > maxY) {
      return false;
    }
  } else {
    var t0 = (minY - oy) * invDy;
    var t1 = (maxY - oy) * invDy;
    if (t0 > t1) {
      final tmp = t0;
      t0 = t1;
      t1 = tmp;
    }
    if (t0 > tMin) {
      tMin = t0;
    }
    if (t1 < tMax) {
      tMax = t1;
    }
    if (tMax < tMin) {
      return false;
    }
  }

  if (dz.abs() <= 1e-18) {
    if (oz < minZ || oz > maxZ) {
      return false;
    }
  } else {
    var t0 = (minZ - oz) * invDz;
    var t1 = (maxZ - oz) * invDz;
    if (t0 > t1) {
      final tmp = t0;
      t0 = t1;
      t1 = tmp;
    }
    if (t0 > tMin) {
      tMin = t0;
    }
    if (t1 < tMax) {
      tMax = t1;
    }
    if (tMax < tMin) {
      return false;
    }
  }

  return true;
}

double _intersectLocalTri(
  double ox,
  double oy,
  double oz,
  double dx,
  double dy,
  double dz,
  double ax,
  double ay,
  double az,
  double bx,
  double by,
  double bz,
  double cx,
  double cy,
  double cz,
  double maxDist,
  CullMode cullMode,
) {
  final e1x = bx - ax;
  final e1y = by - ay;
  final e1z = bz - az;
  final e2x = cx - ax;
  final e2y = cy - ay;
  final e2z = cz - az;

  final px = dy * e2z - dz * e2y;
  final py = dz * e2x - dx * e2z;
  final pz = dx * e2y - dy * e2x;

  final det = e1x * px + e1y * py + e1z * pz;
  switch (cullMode) {
    case CullMode.backFace:
      if (det <= 1e-12) {
        return -1.0;
      }
    case CullMode.frontFace:
      if (det >= -1e-12) {
        return -1.0;
      }
    case CullMode.none:
      if (det.abs() <= 1e-12) {
        return -1.0;
      }
  }

  final invDet = 1.0 / det;
  final tx = ox - ax;
  final ty = oy - ay;
  final tz = oz - az;
  final u = (tx * px + ty * py + tz * pz) * invDet;
  if (u < -1e-6 || u > 1.0 + 1e-6) {
    return -1.0;
  }

  final qx = ty * e1z - tz * e1y;
  final qy = tz * e1x - tx * e1z;
  final qz = tx * e1y - ty * e1x;
  final v = (dx * qx + dy * qy + dz * qz) * invDet;
  if (v < -1e-6 || u + v > 1.0 + 1e-6) {
    return -1.0;
  }

  final t = (e2x * qx + e2y * qy + e2z * qz) * invDet;
  if (t < 0.0 || t >= maxDist) {
    return -1.0;
  }
  return t;
}
