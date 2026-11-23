part of 'xpbd_cloth_3d.dart';

extension _XpbdRopeMesh3D on XpbdRope3D {
  void _syncTubeSurface() {
    final pCount = segmentCount + 1;
    final cols = radialSegments + 1;
    final vBuf = _surface.vertexData;

    _computeRopeTangent(0, pCount, _tangent);
    if (_tangent.y.abs() < 0.9) {
      _normalFrame.setValues(_tangent.z, 0.0, -_tangent.x);
    } else {
      _normalFrame.setValues(0.0, -_tangent.z, _tangent.y);
    }
    _normalFrame.normalize();
    _prevTangent.setFrom(_tangent);

    var minX = double.infinity;
    var minY = double.infinity;
    var minZ = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    var maxZ = double.negativeInfinity;

    for (var i = 0; i < pCount; i++) {
      _computeRopeTangent(i, pCount, _tangent);
      if (i > 0) {
        // Parallel transport: turn the frame by the rotation taking the
        // previous tangent onto this one (Rodrigues; vector_math's
        // `Quaternion.rotate` would apply the inverse rotation).
        _prevTangent.crossInto(_tangent, _rotAxis);
        final sinA = _rotAxis.length;
        if (sinA > 1e-6) {
          _rotAxis.scale(1.0 / sinA);
          final cosA = _prevTangent.dot(_tangent).clamp(-1.0, 1.0);
          final kx = _rotAxis.x;
          final ky = _rotAxis.y;
          final kz = _rotAxis.z;
          final vx = _normalFrame.x;
          final vy = _normalFrame.y;
          final vz = _normalFrame.z;
          final kv = kx * vx + ky * vy + kz * vz;
          _normalFrame
            ..setValues(
              vx * cosA + (ky * vz - kz * vy) * sinA + kx * kv * (1 - cosA),
              vy * cosA + (kz * vx - kx * vz) * sinA + ky * kv * (1 - cosA),
              vz * cosA + (kx * vy - ky * vx) * sinA + kz * kv * (1 - cosA),
            )
            ..normalize();
        }
        _prevTangent.setFrom(_tangent);
      }
      _tangent.crossInto(_normalFrame, _binormal);
      _binormal.normalize();

      final po = i * 3;
      final cx = _pos[po];
      final cy = _pos[po + 1];
      final cz = _pos[po + 2];

      if (cx - radius < minX) {
        minX = cx - radius;
      }
      if (cy - radius < minY) {
        minY = cy - radius;
      }
      if (cz - radius < minZ) {
        minZ = cz - radius;
      }
      if (cx + radius > maxX) {
        maxX = cx + radius;
      }
      if (cy + radius > maxY) {
        maxY = cy + radius;
      }
      if (cz + radius > maxZ) {
        maxZ = cz + radius;
      }

      for (var j = 0; j < cols; j++) {
        final cosP = _ringCos[j];
        final sinP = _ringSin[j];

        final nx = _normalFrame.x * cosP + _binormal.x * sinP;
        final ny = _normalFrame.y * cosP + _binormal.y * sinP;
        final nz = _normalFrame.z * cosP + _binormal.z * sinP;

        final vb = (i * cols + j) * _vertexStride;
        vBuf[vb + _posAttrOffset] = cx + nx * radius;
        vBuf[vb + _posAttrOffset + 1] = cy + ny * radius;
        vBuf[vb + _posAttrOffset + 2] = cz + nz * radius;
        if (_nrmAttrOffset >= 0) {
          vBuf[vb + _nrmAttrOffset] = nx;
          vBuf[vb + _nrmAttrOffset + 1] = ny;
          vBuf[vb + _nrmAttrOffset + 2] = nz;
        }
      }
    }

    _localAabb.min.setValues(minX, minY, minZ);
    _localAabb.max.setValues(maxX, maxY, maxZ);
    _surface.updateVertices(vBuf, aabb: _localAabb);
    markAabbDirty();
    // The vertices were written in place: report it, so that retained
    // layers and kept shadows follow.
    markDrawDirty();
  }

  void _computeRopeTangent(int i, int pCount, Vector3 out) {
    final i0 = math.max(0, i - 1) * 3;
    final i1 = math.min(pCount - 1, i + 1) * 3;
    out.setValues(
      _pos[i1] - _pos[i0],
      _pos[i1 + 1] - _pos[i0 + 1],
      _pos[i1 + 2] - _pos[i0 + 2],
    );
    if (out.length2 > 1e-12) {
      out.normalize();
    } else {
      out.setValues(0.0, -1.0, 0.0);
    }
  }
}
