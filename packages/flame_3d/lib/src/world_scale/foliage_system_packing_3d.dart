part of 'foliage_system_3d.dart';

extension _FoliageSystemPacking on FoliageSystem3D {
  int _packVisibleInstances({
    required Vector3 cameraPosition,
    required Float32List outBuffer,
    Frustum? frustum,
  }) {
    _lastVisibleCellCount = 0;
    _lastVisibleInstanceCount = 0;
    if (_bladeCount == 0) {
      return 0;
    }
    _ensureSpatialCells();

    final worldMat = worldTransformMatrix;
    final isIdentity = worldMat.isIdentity();
    if (isIdentity) {
      _localCamScratch.setFrom(cameraPosition);
    } else {
      _invWorldScratch.setFrom(worldMat);
      if (_invWorldScratch.invert().abs() > 1e-15) {
        final m = _invWorldScratch.storage;
        _localCamScratch.setValues(
          m[0] * cameraPosition.x +
              m[4] * cameraPosition.y +
              m[8] * cameraPosition.z +
              m[12],
          m[1] * cameraPosition.x +
              m[5] * cameraPosition.y +
              m[9] * cameraPosition.z +
              m[13],
          m[2] * cameraPosition.x +
              m[6] * cameraPosition.y +
              m[10] * cameraPosition.z +
              m[14],
        );
      } else {
        _localCamScratch.setFrom(cameraPosition);
      }
    }

    final camX = _localCamScratch.x;
    final camY = _localCamScratch.y;
    final camZ = _localCamScratch.z;
    final maxDist = maxDrawDistance;
    final maxDistSq = maxDist * maxDist;
    final fadeStart = maxDist * fadeStartFraction;
    final fadeStartSq64 = fadeStart * fadeStart * 0.64;
    final fadeSpan = math.max(1e-4, maxDist - fadeStart);

    final wStorage = worldMat.storage;
    final windDirX = windDirection.x;
    final windDirZ = windDirection.y;
    final windAmp = windStrength;
    final hasWind = windAmp != 0.0;
    final windDirLen = hasWind
        ? math.sqrt(windDirX * windDirX + windDirZ * windDirZ)
        : 0.0;
    final windOmega = _windTime * windFrequency;
    final cosW = hasWind ? math.cos(windOmega) : 1.0;
    final sinW = hasWind ? math.sin(windOmega) : 0.0;

    var outInstances = 0;
    const stride = VertexLayout.instanceStrideInFloats;

    for (var cell = 0; cell < _cellCount; cell++) {
      final cb = cell * 6;
      final cMinX = _cellBounds[cb];
      final cMinY = _cellBounds[cb + 1];
      final cMinZ = _cellBounds[cb + 2];
      final cMaxX = _cellBounds[cb + 3];
      final cMaxY = _cellBounds[cb + 4];
      final cMaxZ = _cellBounds[cb + 5];

      final qx = camX < cMinX
          ? cMinX - camX
          : (camX > cMaxX ? camX - cMaxX : 0);
      final qy = camY < cMinY
          ? cMinY - camY
          : (camY > cMaxY ? camY - cMaxY : 0);
      final qz = camZ < cMinZ
          ? cMinZ - camZ
          : (camZ > cMaxZ ? camZ - cMaxZ : 0);
      if (qx * qx + qy * qy + qz * qz > maxDistSq) {
        continue;
      }

      if (frustum != null) {
        _cellBoxScratch
          ..min.setValues(cMinX, cMinY, cMinZ)
          ..max.setValues(cMaxX, cMaxY, cMaxZ);
        if (!isIdentity) {
          _cellBoxScratch.transform(worldMat);
        }
        if (_cellBoxScratch.frustumCullTest(frustum) == CullResult.outside) {
          continue;
        }
      }

      _lastVisibleCellCount++;
      final cellBent = _cellHasBend[cell] != 0;
      final start = _cellOffsets[cell];
      final end = start + _cellCounts[cell];

      for (var k = start; k < end; k++) {
        final i = _cellBladeIndices[k];
        final px = _posX[i];
        final py = _posY[i];
        final pz = _posZ[i];

        final dx = px - camX;
        final dy = py - camY;
        final dz = pz - camZ;
        final distSq = dx * dx + dy * dy + dz * dz;
        if (distSq >= maxDistSq) {
          continue;
        }

        // Per-blade deterministic cutoff distance produces continuous density
        // thinning AND smooth zero-pop scale-down to 0 right at cutoff!
        var distScale = 1.0;
        if (distSq > fadeStartSq64) {
          final dist = math.sqrt(distSq);
          final bladeCutoff = fadeStart + _densityRank[i] * fadeSpan;
          if (dist >= bladeCutoff) {
            continue;
          }
          final rampStart = bladeCutoff * 0.8;
          if (dist > rampStart) {
            final t =
                ((bladeCutoff - dist) / math.max(1e-4, bladeCutoff - rampStart))
                    .clamp(0.0, 1.0);
            distScale = t * t * (3.0 - 2.0 * t);
          }
        }
        if (distScale <= 1e-3) {
          continue;
        }

        final crush = cellBent ? _crush[i] : 0.0;
        final sx = _scaleX[i] * distScale;
        final sy = cellBent
            ? _scaleY[i] * distScale * (1.0 - 0.65 * crush)
            : _scaleY[i] * distScale;
        final sz = _scaleZ[i] * distScale;

        final cy = _cosYaw[i];
        final syaw = _sinYaw[i];

        final double tiltX;
        final double tiltZ;
        final double m11;
        final double tiltMag;
        if (!cellBent && !hasWind) {
          tiltX = 0.0;
          tiltZ = 0.0;
          m11 = sy;
          tiltMag = 0.0;
        } else if (!cellBent) {
          final sinTotal = sinW * _cosPhase[i] + cosW * _sinPhase[i];
          final sway = windAmp * sinTotal;
          tiltX = windDirX * sway;
          tiltZ = windDirZ * sway;
          tiltMag = sway.abs() * windDirLen;
          final tiltSq = tiltMag * tiltMag;
          m11 = tiltSq == 0.0 ? sy : sy / math.sqrt(1.0 + tiltSq);
        } else {
          final double sway;
          if (hasWind) {
            final sinTotal = sinW * _cosPhase[i] + cosW * _sinPhase[i];
            sway = windAmp * sinTotal * (1.0 - 0.5 * crush);
          } else {
            sway = 0.0;
          }
          tiltX = _bendX[i] + windDirX * sway;
          tiltZ = _bendZ[i] + windDirZ * sway;
          final tiltSq = tiltX * tiltX + tiltZ * tiltZ;
          if (tiltSq == 0.0) {
            m11 = sy;
            tiltMag = 0.0;
          } else {
            m11 = sy / math.sqrt(1.0 + tiltSq);
            tiltMag = math.sqrt(tiltSq);
          }
        }

        // Local columns: X and Z rotated by `yaw`, Y tilted outward by trample
        // + wind while anchoring `y = 0` in the ground!
        final m00 = cy * sx;
        const m01 = 0.0;
        final m02 = -syaw * sx;

        final m10 = tiltX * sy;
        final m12 = tiltZ * sy;

        final m20 = syaw * sz;
        const m21 = 0.0;
        final m22 = cy * sz;

        final base = outInstances * stride;
        if (isIdentity) {
          outBuffer
            ..[base] = m00
            ..[base + 1] = m01
            ..[base + 2] = m02
            ..[base + 3] = 0
            ..[base + 4] = m10
            ..[base + 5] = m11
            ..[base + 6] = m12
            ..[base + 7] = 0
            ..[base + 8] = m20
            ..[base + 9] = m21
            ..[base + 10] = m22
            ..[base + 11] = 0
            ..[base + 12] = px
            ..[base + 13] = py
            ..[base + 14] = pz
            ..[base + 15] = 1;
        } else {
          _writeFoliageWorldMul(
            wStorage,
            m00,
            m01,
            m02,
            m10,
            m11,
            m12,
            m20,
            m21,
            m22,
            px,
            py,
            pz,
            outBuffer,
            base,
          );
        }

        outBuffer
          ..[base + 16] = _colorR[i]
          ..[base + 17] = _colorG[i]
          ..[base + 18] = _colorB[i]
          ..[base + 19] = _colorA[i]
          ..[base + 20] = _windPhase[i]
          ..[base + 21] = windAmp
          ..[base + 22] = crush
          ..[base + 23] = tiltMag;
        outInstances++;
      }
    }

    _lastVisibleInstanceCount = outInstances;
    return outInstances;
  }

  void _ensureInteractorScratch(int count) {
    if (_activeIx.length >= count) {
      return;
    }
    var cap = math.max(16, _activeIx.length);
    while (cap < count) {
      cap *= 2;
    }
    _activeIx = Float64List(cap);
    _activeIy = Float64List(cap);
    _activeIz = Float64List(cap);
    _activeIr = Float64List(cap);
    _activeIrSq = Float64List(cap);
    _activeIStrength = Float64List(cap);
    _cellInteractors = Int32List(cap);
  }

  void _updateInteractors(double dt) {
    _ensureSpatialCells();
    if (_cellCount == 0) {
      return;
    }

    var activeCount = 0;
    if (interactors.isNotEmpty) {
      _ensureInteractorScratch(interactors.length);
      final worldMat = worldTransformMatrix;
      final isIdentity = worldMat.isIdentity();
      Float32List? invM;
      if (!isIdentity) {
        _invWorldScratch.setFrom(worldMat);
        _invWorldScratch.invert();
        invM = _invWorldScratch.storage;
      }
      for (var s = 0; s < interactors.length; s++) {
        final inter = interactors[s];
        final r = inter.radius;
        final strength = inter.strength.clamp(0.0, 1.0);
        if (r <= 0 || strength <= 0) {
          continue;
        }
        final p = inter.position;
        if (invM == null) {
          _activeIx[activeCount] = p.x;
          _activeIy[activeCount] = p.y;
          _activeIz[activeCount] = p.z;
        } else {
          _activeIx[activeCount] =
              invM[0] * p.x + invM[4] * p.y + invM[8] * p.z + invM[12];
          _activeIy[activeCount] =
              invM[1] * p.x + invM[5] * p.y + invM[9] * p.z + invM[13];
          _activeIz[activeCount] =
              invM[2] * p.x + invM[6] * p.y + invM[10] * p.z + invM[14];
        }
        _activeIr[activeCount] = r;
        _activeIrSq[activeCount] = r * r;
        _activeIStrength[activeCount] = strength;
        activeCount++;
      }
    }

    if (activeCount == 0 && !_anyCellBent) {
      if (windStrength > 0) {
        markDrawDirty(shadows: castsShadows);
      }
      return;
    }

    final attackAlpha = (1.0 - math.exp(-trampleAttackRate * dt)).clamp(
      0.0,
      1.0,
    );
    final recoverAlpha = (1.0 - math.exp(-trampleSpringRate * dt)).clamp(
      0.0,
      1.0,
    );

    var anyChanged = false;
    var anyCellStillBent = false;

    for (var cell = 0; cell < _cellCount; cell++) {
      final cb = cell * 6;
      final cMinX = _cellBounds[cb];
      final cMinY = _cellBounds[cb + 1];
      final cMinZ = _cellBounds[cb + 2];
      final cMaxX = _cellBounds[cb + 3];
      final cMaxY = _cellBounds[cb + 4];
      final cMaxZ = _cellBounds[cb + 5];

      var cellHitCount = 0;
      for (var s = 0; s < activeCount; s++) {
        final ix = _activeIx[s];
        final iy = _activeIy[s];
        final iz = _activeIz[s];
        final r = _activeIr[s];
        if (ix + r >= cMinX &&
            ix - r <= cMaxX &&
            iy + r >= cMinY &&
            iy - r <= cMaxY &&
            iz + r >= cMinZ &&
            iz - r <= cMaxZ) {
          _cellInteractors[cellHitCount++] = s;
        }
      }

      if (cellHitCount == 0 && _cellHasBend[cell] == 0) {
        continue;
      }

      final start = _cellOffsets[cell];
      final end = start + _cellCounts[cell];
      var cellStillBent = false;

      for (var k = start; k < end; k++) {
        final i = _cellBladeIndices[k];
        var targetBx = 0.0;
        var targetBz = 0.0;
        var targetCrush = 0.0;

        if (cellHitCount > 0) {
          final bx = _posX[i];
          final by = _posY[i];
          final bz = _posZ[i];

          for (var h = 0; h < cellHitCount; h++) {
            final s = _cellInteractors[h];
            final dx = bx - _activeIx[s];
            final dy = by - _activeIy[s];
            final dz = bz - _activeIz[s];
            final distSq = dx * dx + dy * dy + dz * dz;
            if (distSq >= _activeIrSq[s]) {
              continue;
            }

            final dist = math.sqrt(distSq);
            final t = (1.0 - dist / _activeIr[s]).clamp(0.0, 1.0);
            final falloff = t * t * (3.0 - 2.0 * t) * _activeIStrength[s];

            final hLen = math.sqrt(dx * dx + dz * dz);
            final ux = hLen > 1e-5 ? dx / hLen : 1.0;
            final uz = hLen > 1e-5 ? dz / hLen : 0.0;

            targetBx += ux * falloff * maxBendAngle;
            targetBz += uz * falloff * maxBendAngle;
            if (falloff > targetCrush) {
              targetCrush = falloff;
            }
          }

          final bMag = math.sqrt(targetBx * targetBx + targetBz * targetBz);
          if (bMag > maxBendAngle && bMag > 1e-6) {
            final clampScale = maxBendAngle / bMag;
            targetBx *= clampScale;
            targetBz *= clampScale;
          }
        }

        final curCrush = _crush[i];
        final alpha = targetCrush > curCrush ? attackAlpha : recoverAlpha;
        final nextBx = _bendX[i] + (targetBx - _bendX[i]) * alpha;
        final nextBz = _bendZ[i] + (targetBz - _bendZ[i]) * alpha;
        final nextCrush = curCrush + (targetCrush - curCrush) * alpha;

        if (nextBx.abs() > 1e-4 || nextBz.abs() > 1e-4 || nextCrush > 1e-4) {
          _bendX[i] = nextBx;
          _bendZ[i] = nextBz;
          _crush[i] = nextCrush;
          cellStillBent = true;
          anyChanged = true;
        } else if (curCrush != 0 || _bendX[i] != 0 || _bendZ[i] != 0) {
          _bendX[i] = 0;
          _bendZ[i] = 0;
          _crush[i] = 0;
          anyChanged = true;
        }
      }

      _cellHasBend[cell] = cellStillBent ? 1 : 0;
      if (cellStillBent) {
        anyCellStillBent = true;
      }
    }
    _anyCellBent = anyCellStillBent;

    if (anyChanged) {
      _stateVersion++;
    }
    if (anyChanged || windStrength > 0) {
      markDrawDirty(shadows: castsShadows);
    }
  }
}

void _writeFoliageWorldMul(
  Float32List w,
  double m00,
  double m01,
  double m02,
  double m10,
  double m11,
  double m12,
  double m20,
  double m21,
  double m22,
  double px,
  double py,
  double pz,
  Float32List out,
  int b,
) {
  out
    ..[b] = w[0] * m00 + w[4] * m01 + w[8] * m02
    ..[b + 1] = w[1] * m00 + w[5] * m01 + w[9] * m02
    ..[b + 2] = w[2] * m00 + w[6] * m01 + w[10] * m02
    ..[b + 3] = w[3] * m00 + w[7] * m01 + w[11] * m02
    ..[b + 4] = w[0] * m10 + w[4] * m11 + w[8] * m12
    ..[b + 5] = w[1] * m10 + w[5] * m11 + w[9] * m12
    ..[b + 6] = w[2] * m10 + w[6] * m11 + w[10] * m12
    ..[b + 7] = w[3] * m10 + w[7] * m11 + w[11] * m12
    ..[b + 8] = w[0] * m20 + w[4] * m21 + w[8] * m22
    ..[b + 9] = w[1] * m20 + w[5] * m21 + w[9] * m22
    ..[b + 10] = w[2] * m20 + w[6] * m21 + w[10] * m22
    ..[b + 11] = w[3] * m20 + w[7] * m21 + w[11] * m22
    ..[b + 12] = w[0] * px + w[4] * py + w[8] * pz + w[12]
    ..[b + 13] = w[1] * px + w[5] * py + w[9] * pz + w[13]
    ..[b + 14] = w[2] * px + w[6] * py + w[10] * pz + w[14]
    ..[b + 15] = w[3] * px + w[7] * py + w[11] * pz + w[15];
}
