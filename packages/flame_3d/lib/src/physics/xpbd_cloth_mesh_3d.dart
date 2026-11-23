part of 'xpbd_cloth_3d.dart';

extension _XpbdClothMesh3D on XpbdCloth3D {
  void _syncSurfaceBuffer() {
    final n = columns * rows;
    _normals.fillRange(0, n * 3, 0.0);

    for (var t = 0; t < _triIndices.length; t += 3) {
      final v0 = _triIndices[t];
      final v1 = _triIndices[t + 1];
      final v2 = _triIndices[t + 2];
      final o0 = v0 * 3;
      final o1 = v1 * 3;
      final o2 = v2 * 3;

      final e1x = _pos[o1] - _pos[o0];
      final e1y = _pos[o1 + 1] - _pos[o0 + 1];
      final e1z = _pos[o1 + 2] - _pos[o0 + 2];
      final e2x = _pos[o2] - _pos[o0];
      final e2y = _pos[o2 + 1] - _pos[o0 + 1];
      final e2z = _pos[o2 + 2] - _pos[o0 + 2];

      final nx = e1y * e2z - e1z * e2y;
      final ny = e1z * e2x - e1x * e2z;
      final nz = e1x * e2y - e1y * e2x;

      _normals[o0] += nx;
      _normals[o0 + 1] += ny;
      _normals[o0 + 2] += nz;
      _normals[o1] += nx;
      _normals[o1 + 1] += ny;
      _normals[o1 + 2] += nz;
      _normals[o2] += nx;
      _normals[o2 + 1] += ny;
      _normals[o2 + 2] += nz;
    }

    final vBuf = _surface.vertexData;
    var minX = double.infinity;
    var minY = double.infinity;
    var minZ = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    var maxZ = double.negativeInfinity;

    for (var i = 0; i < n; i++) {
      final o = i * 3;
      final px = _pos[o];
      final py = _pos[o + 1];
      final pz = _pos[o + 2];

      if (px < minX) {
        minX = px;
      }
      if (py < minY) {
        minY = py;
      }
      if (pz < minZ) {
        minZ = pz;
      }
      if (px > maxX) {
        maxX = px;
      }
      if (py > maxY) {
        maxY = py;
      }
      if (pz > maxZ) {
        maxZ = pz;
      }

      var nx = _normals[o];
      var ny = _normals[o + 1];
      var nz = _normals[o + 2];
      final nLen = math.sqrt(nx * nx + ny * ny + nz * nz);
      if (nLen > 1e-12) {
        nx /= nLen;
        ny /= nLen;
        nz /= nLen;
      } else {
        nx = 0.0;
        ny = 0.0;
        nz = 1.0;
      }
      _normals[o] = nx;
      _normals[o + 1] = ny;
      _normals[o + 2] = nz;

      final vb = i * _vertexStride;
      vBuf[vb + _posAttrOffset] = px;
      vBuf[vb + _posAttrOffset + 1] = py;
      vBuf[vb + _posAttrOffset + 2] = pz;
      if (_nrmAttrOffset >= 0) {
        vBuf[vb + _nrmAttrOffset] = nx;
        vBuf[vb + _nrmAttrOffset + 1] = ny;
        vBuf[vb + _nrmAttrOffset + 2] = nz;
      }
    }

    _localAabb.min.setValues(
      minX - particleThickness,
      minY - particleThickness,
      minZ - particleThickness,
    );
    _localAabb.max.setValues(
      maxX + particleThickness,
      maxY + particleThickness,
      maxZ + particleThickness,
    );
    _surface.updateVertices(vBuf, aabb: _localAabb);
    markAabbDirty();
    // The vertices were written in place: report it, so that retained
    // layers and kept shadows follow.
    markDrawDirty();
  }
}
