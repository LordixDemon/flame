part of 'volume_decal_batch_3d.dart';

extension _VolumeDecalClipper on VolumeDecalBatch3D {
  void _emitTerrainTriFlat(
    ProjectedDecalBox3D decal,
    _DecalBoxFrame boxFrame,
    Float64List bufA,
    int oa,
    Float64List bufB,
    int ob,
    Float64List bufC,
    int oc, {
    required bool selfIsIdentity,
  }) {
    final ax = bufA[oa];
    final ay = bufA[oa + 1];
    final az = bufA[oa + 2];
    final bx = bufB[ob];
    final by = bufB[ob + 1];
    final bz = bufB[ob + 2];
    final cx = bufC[oc];
    final cy = bufC[oc + 1];
    final cz = bufC[oc + 2];
    final e1x = bx - ax;
    final e1y = by - ay;
    final e1z = bz - az;
    final e2x = cx - ax;
    final e2y = cy - ay;
    final e2z = cz - az;
    var fnx = e1y * e2z - e1z * e2y;
    var fny = e1z * e2x - e1x * e2z;
    var fnz = e1x * e2y - e1y * e2x;
    final len = math.sqrt(fnx * fnx + fny * fny + fnz * fnz);
    if (len <= 1e-12) {
      return;
    }
    fnx /= len;
    fny /= len;
    fnz /= len;

    _clipAndEmitWorldTriangle(
      decal,
      boxFrame,
      ax,
      ay,
      az,
      bufA[oa + 3],
      bufA[oa + 4],
      bufA[oa + 5],
      bx,
      by,
      bz,
      bufB[ob + 3],
      bufB[ob + 4],
      bufB[ob + 5],
      cx,
      cy,
      cz,
      bufC[oc + 3],
      bufC[oc + 4],
      bufC[oc + 5],
      fnx,
      fny,
      fnz,
      selfIsIdentity: selfIsIdentity,
    );
  }

  void _resetAccumulators() {
    _mergedSurface?.dispose();
    _mergedSurface = null;
    _vertCount = 0;
    _idxCount = 0;
    _projectedDecalCount = 0;
    _localAabb.setZero();
  }

  void _finalizeMergedSurface() {
    _mergedSurface?.dispose();
    if (_vertCount == 0 || _idxCount < 3) {
      _mergedSurface = null;
      markAabbDirty();
      markDrawDirty(shadows: false);
      return;
    }

    final stride = VertexLayout.standard.strideInFloats;
    final verts = Float32List.fromList(
      Float32List.sublistView(_vertScratch, 0, _vertCount * stride),
    );
    final List<int> indices;
    if (_vertCount > 0xFFFF) {
      indices = Uint32List(_idxCount);
      for (var i = 0; i < _idxCount; i++) {
        indices[i] = _idxScratch[i];
      }
    } else {
      indices = Uint16List(_idxCount);
      for (var i = 0; i < _idxCount; i++) {
        indices[i] = _idxScratch[i];
      }
    }

    var minX = double.infinity;
    var minY = double.infinity;
    var minZ = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    var maxZ = double.negativeInfinity;
    for (var v = 0; v < _vertCount; v++) {
      final o = v * stride;
      final x = verts[o];
      final y = verts[o + 1];
      final z = verts[o + 2];
      minX = math.min(minX, x);
      maxX = math.max(maxX, x);
      minY = math.min(minY, y);
      maxY = math.max(maxY, y);
      minZ = math.min(minZ, z);
      maxZ = math.max(maxZ, z);
    }
    _localAabb
      ..min.setValues(minX - 1e-3, minY - 1e-3, minZ - 1e-3)
      ..max.setValues(maxX + 1e-3, maxY + 1e-3, maxZ + 1e-3);

    _mergedSurface = Surface.fromBuffers(
      vertices: verts,
      indices: indices,
      material: material,
      aabb: Aabb3.copy(_localAabb),
    );
    markAabbDirty();
    markDrawDirty(shadows: false);
  }

  _DecalBoxFrame _prepareDecalBoxFrame(ProjectedDecalBox3D decal) {
    final q = decal.rotation;
    final qx = q.x;
    final qy = q.y;
    final qz = q.z;
    final qw = q.w;
    final xx = qx * qx;
    final yy = qy * qy;
    final zz = qz * qz;
    final xy = qx * qy;
    final xz = qx * qz;
    final yz = qy * qz;
    final wx = qw * qx;
    final wy = qw * qy;
    final wz = qw * qz;

    final r0 = 1.0 - 2.0 * (yy + zz);
    final r1 = 2.0 * (xy + wz);
    final r2 = 2.0 * (xz - wy);
    final r3 = 2.0 * (xy - wz);
    final r4 = 1.0 - 2.0 * (xx + zz);
    final r5 = 2.0 * (yz + wx);
    final r6 = 2.0 * (xz + wy);
    final r7 = 2.0 * (yz - wx);
    final r8 = 1.0 - 2.0 * (xx + yy);

    final cx = decal.center.x;
    final cy = decal.center.y;
    final cz = decal.center.z;
    final hx = decal.halfExtents.x;
    final hy = decal.halfExtents.y;
    final hz = decal.halfExtents.z;

    // World AABB of the OBB.
    final extX = r0.abs() * hx + r3.abs() * hy + r6.abs() * hz;
    final extY = r1.abs() * hx + r4.abs() * hy + r7.abs() * hz;
    final extZ = r2.abs() * hx + r5.abs() * hy + r8.abs() * hz;
    _decalWorldAabb
      ..min.setValues(cx - extX, cy - extY, cz - extZ)
      ..max.setValues(cx + extX, cy + extY, cz + extZ);

    final receiveNx = decal.projectionAxis == DecalProjectionAxis3D.negativeY
        ? r3
        : r6;
    final receiveNy = decal.projectionAxis == DecalProjectionAxis3D.negativeY
        ? r4
        : r7;
    final receiveNz = decal.projectionAxis == DecalProjectionAxis3D.negativeY
        ? r5
        : r8;

    return _boxFrame
      ..cx = cx
      ..cy = cy
      ..cz = cz
      ..hx = hx
      ..hy = hy
      ..hz = hz
      ..invHx = 1.0 / hx
      ..invHy = 1.0 / hy
      ..invHz = 1.0 / hz
      ..r00 = r0
      ..r01 = r3
      ..r02 = r6
      ..r10 = r1
      ..r11 = r4
      ..r12 = r7
      ..r20 = r2
      ..r21 = r5
      ..r22 = r8
      ..receiveNx = receiveNx
      ..receiveNy = receiveNy
      ..receiveNz = receiveNz;
  }

  void _clipAndEmitWorldTriangle(
    ProjectedDecalBox3D decal,
    _DecalBoxFrame f,
    double x0,
    double y0,
    double z0,
    double n0x,
    double n0y,
    double n0z,
    double x1,
    double y1,
    double z1,
    double n1x,
    double n1y,
    double n1z,
    double x2,
    double y2,
    double z2,
    double n2x,
    double n2y,
    double n2z,
    double faceNx,
    double faceNy,
    double faceNz, {
    required bool selfIsIdentity,
  }) {
    final cosAngle =
        faceNx * f.receiveNx + faceNy * f.receiveNy + faceNz * f.receiveNz;
    if (cosAngle <= decal.normalAngleFadeCos) {
      return;
    }

    final double angleFade;
    if (decal.normalFadeWidth <= 1e-5) {
      angleFade = 1.0;
    } else {
      final t = ((cosAngle - decal.normalAngleFadeCos) / decal.normalFadeWidth)
          .clamp(0.0, 1.0);
      angleFade = t * t * (3.0 - 2.0 * t);
    }

    _writeBoxVertex(f, x0, y0, z0, n0x, n0y, n0z, _polyA, 0);
    _writeBoxVertex(f, x1, y1, z1, n1x, n1y, n1z, _polyA, 6);
    _writeBoxVertex(f, x2, y2, z2, n2x, n2y, n2z, _polyA, 12);

    var n = 3;
    n = _clipAxis(_polyA, n, _polyB, 0, minSide: true);
    if (n < 3) {
      return;
    }
    n = _clipAxis(_polyB, n, _polyA, 0, minSide: false);
    if (n < 3) {
      return;
    }
    n = _clipAxis(_polyA, n, _polyB, 1, minSide: true);
    if (n < 3) {
      return;
    }
    n = _clipAxis(_polyB, n, _polyA, 1, minSide: false);
    if (n < 3) {
      return;
    }
    n = _clipAxis(_polyA, n, _polyB, 2, minSide: true);
    if (n < 3) {
      return;
    }
    n = _clipAxis(_polyB, n, _polyA, 2, minSide: false);
    if (n < 3) {
      return;
    }

    const stride = 20;
    _ensureVertexCapacity(_vertCount + n);
    _ensureIndexCapacity(_idxCount + (n - 2) * 3);

    final baseVert = _vertCount;
    final uvRect = decal.uvRect;
    final col = decal.color;
    final premul = material.renderState.blend == BlendState.premultipliedAlpha;
    final isNegY = decal.projectionAxis == DecalProjectionAxis3D.negativeY;
    final invS = _invSelf.storage;

    for (var i = 0; i < n; i++) {
      final po = i * 6;
      final bx = _polyA[po];
      final by = _polyA[po + 1];
      final bz = _polyA[po + 2];
      var wnx = _polyA[po + 3];
      var wny = _polyA[po + 4];
      var wnz = _polyA[po + 5];
      final nLen = math.sqrt(wnx * wnx + wny * wny + wnz * wnz);
      if (nLen > 1e-12) {
        wnx /= nLen;
        wny /= nLen;
        wnz /= nLen;
      } else {
        wnx = faceNx;
        wny = faceNy;
        wnz = faceNz;
      }

      final lx = bx * f.hx;
      final ly = by * f.hy;
      final lz = bz * f.hz;
      final wx =
          f.cx + f.r00 * lx + f.r01 * ly + f.r02 * lz + wnx * normalOffset;
      final wy =
          f.cy + f.r10 * lx + f.r11 * ly + f.r12 * lz + wny * normalOffset;
      final wz =
          f.cz + f.r20 * lx + f.r21 * ly + f.r22 * lz + wnz * normalOffset;

      double outX;
      double outY;
      double outZ;
      double outNx;
      double outNy;
      double outNz;
      if (selfIsIdentity) {
        outX = wx;
        outY = wy;
        outZ = wz;
        outNx = wnx;
        outNy = wny;
        outNz = wnz;
      } else {
        outX = invS[0] * wx + invS[4] * wy + invS[8] * wz + invS[12];
        outY = invS[1] * wx + invS[5] * wy + invS[9] * wz + invS[13];
        outZ = invS[2] * wx + invS[6] * wy + invS[10] * wz + invS[14];
        outNx = invS[0] * wnx + invS[4] * wny + invS[8] * wnz;
        outNy = invS[1] * wnx + invS[5] * wny + invS[9] * wnz;
        outNz = invS[2] * wnx + invS[6] * wny + invS[10] * wnz;
        final lLen = math.sqrt(outNx * outNx + outNy * outNy + outNz * outNz);
        if (lLen > 1e-12) {
          outNx /= lLen;
          outNy /= lLen;
          outNz /= lLen;
        }
      }

      final u01 = ((bx + 1.0) * 0.5).clamp(0.0, 1.0);
      final v01 = isNegY
          ? ((bz + 1.0) * 0.5).clamp(0.0, 1.0)
          : ((1.0 - by) * 0.5).clamp(0.0, 1.0);
      final u = uvRect.left + u01 * uvRect.width;
      final v = uvRect.top + v01 * uvRect.height;

      var depthFade = 1.0;
      if (boxEdgeFeather > 1e-5) {
        final depthCoord = (isNegY ? by : bz).abs();
        final featherStart = (1.0 - boxEdgeFeather * 2.0).clamp(0.0, 0.999);
        if (depthCoord > featherStart) {
          final dt = ((1.0 - depthCoord) / (1.0 - featherStart)).clamp(
            0.0,
            1.0,
          );
          depthFade = dt * dt * (3.0 - 2.0 * dt);
        }
      }

      final alpha = (col.a * angleFade * depthFade).clamp(0.0, 1.0);
      final rgbMul = premul ? alpha : 1.0;

      final vo = (_vertCount + i) * stride;
      _vertScratch
        ..[vo] = outX
        ..[vo + 1] = outY
        ..[vo + 2] = outZ
        ..[vo + 3] = u
        ..[vo + 4] = v
        ..[vo + 5] = col.r * rgbMul
        ..[vo + 6] = col.g * rgbMul
        ..[vo + 7] = col.b * rgbMul
        ..[vo + 8] = alpha
        ..[vo + 9] = outNx
        ..[vo + 10] = outNy
        ..[vo + 11] = outNz
        ..[vo + 12] = 0
        ..[vo + 13] = 0
        ..[vo + 14] = 0
        ..[vo + 15] = 0
        ..[vo + 16] = 0
        ..[vo + 17] = 0
        ..[vo + 18] = 0
        ..[vo + 19] = 0;
    }

    _vertCount += n;
    for (var k = 1; k + 1 < n; k++) {
      _idxScratch
        ..[_idxCount] = baseVert
        ..[_idxCount + 1] = baseVert + k
        ..[_idxCount + 2] = baseVert + k + 1;
      _idxCount += 3;
    }
  }

  void _ensureVertexCapacity(int requiredVerts) {
    const stride = 20;
    final neededFloats = requiredVerts * stride;
    if (_vertScratch.length >= neededFloats) {
      return;
    }
    var newCap = _vertScratch.length * 2;
    while (newCap < neededFloats) {
      newCap *= 2;
    }
    final next = Float32List(newCap)
      ..setRange(0, _vertCount * stride, _vertScratch);
    _vertScratch = next;
  }

  void _ensureIndexCapacity(int requiredIndices) {
    if (_idxScratch.length >= requiredIndices) {
      return;
    }
    var newCap = _idxScratch.length * 2;
    while (newCap < requiredIndices) {
      newCap *= 2;
    }
    final next = Int32List(newCap)..setRange(0, _idxCount, _idxScratch);
    _idxScratch = next;
  }
}

void _writeBoxVertex(
  _DecalBoxFrame f,
  double wx,
  double wy,
  double wz,
  double wnx,
  double wny,
  double wnz,
  Float64List out,
  int o,
) {
  final dx = wx - f.cx;
  final dy = wy - f.cy;
  final dz = wz - f.cz;
  // Transpose of orthonormal rotation `R` maps world delta to local box axes.
  out
    ..[o] = (f.r00 * dx + f.r10 * dy + f.r20 * dz) * f.invHx
    ..[o + 1] = (f.r01 * dx + f.r11 * dy + f.r21 * dz) * f.invHy
    ..[o + 2] = (f.r02 * dx + f.r12 * dy + f.r22 * dz) * f.invHz
    ..[o + 3] = wnx
    ..[o + 4] = wny
    ..[o + 5] = wnz;
}

int _clipAxis(
  Float64List src,
  int count,
  Float64List dst,
  int axis, {
  required bool minSide,
}) {
  var outCount = 0;
  for (var i = 0; i < count; i++) {
    final a = i * 6;
    final b = ((i + 1) % count) * 6;
    final da = minSide ? (src[a + axis] + 1.0) : (1.0 - src[a + axis]);
    final db = minSide ? (src[b + axis] + 1.0) : (1.0 - src[b + axis]);
    final aIn = da >= -1e-9;
    final bIn = db >= -1e-9;
    if (aIn) {
      final o = outCount++ * 6;
      for (var k = 0; k < 6; k++) {
        dst[o + k] = src[a + k];
      }
    }
    if (aIn != bIn) {
      final t = (da / (da - db)).clamp(0.0, 1.0);
      final o = outCount++ * 6;
      for (var k = 0; k < 6; k++) {
        dst[o + k] = src[a + k] + (src[b + k] - src[a + k]) * t;
      }
      dst[o + axis] = minSide ? -1.0 : 1.0;
    }
  }
  return outCount;
}

void _transformNormalInto(
  double c00,
  double c01,
  double c02,
  double c10,
  double c11,
  double c12,
  double c20,
  double c21,
  double c22,
  double sgn,
  double nx,
  double ny,
  double nz,
  double fallbackX,
  double fallbackY,
  double fallbackZ,
  Float64List out,
  int offset,
) {
  final wnx = (c00 * nx + c10 * ny + c20 * nz) * sgn;
  final wny = (c01 * nx + c11 * ny + c21 * nz) * sgn;
  final wnz = (c02 * nx + c12 * ny + c22 * nz) * sgn;
  final len = math.sqrt(wnx * wnx + wny * wny + wnz * wnz);
  if (len > 1e-12) {
    out[offset] = wnx / len;
    out[offset + 1] = wny / len;
    out[offset + 2] = wnz / len;
  } else {
    out[offset] = fallbackX;
    out[offset + 1] = fallbackY;
    out[offset + 2] = fallbackZ;
  }
}

class _DecalBoxFrame() {
  double cx = 0;
  double cy = 0;
  double cz = 0;
  double hx = 1;
  double hy = 1;
  double hz = 1;
  double invHx = 1;
  double invHy = 1;
  double invHz = 1;
  double r00 = 1;
  double r01 = 0;
  double r02 = 0;
  double r10 = 0;
  double r11 = 1;
  double r12 = 0;
  double r20 = 0;
  double r21 = 0;
  double r22 = 1;
  double receiveNx = 0;
  double receiveNy = 1;
  double receiveNz = 0;
}
