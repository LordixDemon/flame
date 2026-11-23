part of 'surface.dart';

extension _SurfaceGeometry on Surface {
  Float32List _computeTangentsImpl({
    bool storeInSurface = true,
    Float32List? texCoord1,
  }) {
    final posOff = _layout.offsetOf(VertexLayout.positionAttribute);
    final nrmOff = _layout.offsetOf('vertexNormal');
    final uvOff = _layout.offsetOf('vertexTexCoord');
    if (posOff == null || nrmOff == null) {
      return Float32List(vertexCount * 4);
    }

    final stride = _layout.strideInFloats;
    final pos = Float32List(vertexCount * 3);
    final nrm = Float32List(vertexCount * 3);
    final uv = Float32List(vertexCount * 2);
    for (var v = 0; v < vertexCount; v++) {
      final base = v * stride;
      pos[v * 3] = vertexData[base + posOff];
      pos[v * 3 + 1] = vertexData[base + posOff + 1];
      pos[v * 3 + 2] = vertexData[base + posOff + 2];
      nrm[v * 3] = vertexData[base + nrmOff];
      nrm[v * 3 + 1] = vertexData[base + nrmOff + 1];
      nrm[v * 3 + 2] = vertexData[base + nrmOff + 2];
      if (uvOff != null) {
        uv[v * 2] = vertexData[base + uvOff];
        uv[v * 2 + 1] = vertexData[base + uvOff + 1];
      }
    }

    final tangents = _calculateTangentsImpl(
      positions: pos,
      normals: nrm,
      texCoords: uv,
      indices: _indices,
    );

    if (!storeInSurface) {
      return tangents;
    }

    final existingTanOff = _layout.offsetOf(VertexLayout.tangentAttribute);
    final existingUv1Off = _layout.offsetOf(VertexLayout.texCoord1Attribute);
    if (existingTanOff != null &&
        (texCoord1 == null || existingUv1Off != null)) {
      for (var v = 0; v < vertexCount; v++) {
        final base = v * stride;
        vertexData[base + existingTanOff] = tangents[v * 4];
        vertexData[base + existingTanOff + 1] = tangents[v * 4 + 1];
        vertexData[base + existingTanOff + 2] = tangents[v * 4 + 2];
        vertexData[base + existingTanOff + 3] = tangents[v * 4 + 3];
        if (texCoord1 != null && existingUv1Off != null) {
          vertexData[base + existingUv1Off] = texCoord1[v * 2];
          vertexData[base + existingUv1Off + 1] = texCoord1[v * 2 + 1];
        }
      }
      if (_baseVertexData != null) {
        _baseVertexData = Float32List.fromList(vertexData);
      }
      if (hasResource && _resourceSizeInBytes == _sizeInBytes) {
        resource.write(ByteData.sublistView(vertexData));
      }
    } else {
      final newAttrs = <VertexAttribute>[
        ..._layout.attributes,
        if (existingTanOff == null)
          const VertexAttribute(VertexLayout.tangentAttribute, 4),
        if (existingUv1Off == null)
          const VertexAttribute(VertexLayout.texCoord1Attribute, 2),
      ];
      // Layouts compare by value: reuse the shared instance when it matches.
      final newLayout = VertexLayout(newAttrs);
      final resolvedLayout = newLayout == VertexLayout.pbrStandard
          ? VertexLayout.pbrStandard
          : newLayout;
      final newStride = resolvedLayout.strideInFloats;
      final newTanOff = resolvedLayout.offsetOf(VertexLayout.tangentAttribute)!;
      final newUv1Off = resolvedLayout.offsetOf(
        VertexLayout.texCoord1Attribute,
      )!;
      final repacked = Float32List(vertexCount * newStride);
      for (var v = 0; v < vertexCount; v++) {
        final oldBase = v * stride;
        final newBase = v * newStride;
        repacked.setRange(newBase, newBase + stride, vertexData, oldBase);
        repacked[newBase + newTanOff] = tangents[v * 4];
        repacked[newBase + newTanOff + 1] = tangents[v * 4 + 1];
        repacked[newBase + newTanOff + 2] = tangents[v * 4 + 2];
        repacked[newBase + newTanOff + 3] = tangents[v * 4 + 3];
        if (texCoord1 != null && v * 2 + 1 < texCoord1.length) {
          repacked[newBase + newUv1Off] = texCoord1[v * 2];
          repacked[newBase + newUv1Off + 1] = texCoord1[v * 2 + 1];
        } else if (existingUv1Off != null) {
          repacked[newBase + newUv1Off] = vertexData[oldBase + existingUv1Off];
          repacked[newBase + newUv1Off + 1] =
              vertexData[oldBase + existingUv1Off + 1];
        } else if (uvOff != null) {
          repacked[newBase + newUv1Off] = vertexData[oldBase + uvOff];
          repacked[newBase + newUv1Off + 1] = vertexData[oldBase + uvOff + 1];
        }
      }
      _layout = resolvedLayout;
      vertexData = repacked;
      if (_baseVertexData != null) {
        _baseVertexData = Float32List.fromList(vertexData);
      }
      if (hasResource) {
        dispose();
      }
    }

    return tangents;
  }

  void _applyMorphWeightsImpl(List<double> weights, {int? targetCount}) {
    if (morphTargets.isEmpty) {
      return;
    }
    final base = _baseVertexData ??= Float32List.fromList(vertexData);
    vertexData.setAll(0, base);

    final posOffset = _layout.offsetOf(VertexLayout.positionAttribute);
    final nrmOffset = _layout.offsetOf('vertexNormal');
    final stride = _layout.strideInFloats;
    final count = math.min(
      math.min(targetCount ?? weights.length, weights.length),
      morphTargets.length,
    );

    for (var t = 0; t < count; t++) {
      final w = weights[t];
      if (w.abs() <= 1e-6) {
        continue;
      }
      final target = morphTargets[t];
      final pDeltas = target.positionDeltas;
      if (posOffset != null && pDeltas.length >= vertexCount * 3) {
        for (var v = 0; v < vertexCount; v++) {
          final vo = v * stride + posOffset;
          final po = v * 3;
          vertexData[vo] += pDeltas[po] * w;
          vertexData[vo + 1] += pDeltas[po + 1] * w;
          vertexData[vo + 2] += pDeltas[po + 2] * w;
        }
      }
      final nDeltas = target.normalDeltas;
      if (nrmOffset != null &&
          nDeltas != null &&
          nDeltas.length >= vertexCount * 3) {
        for (var v = 0; v < vertexCount; v++) {
          final vo = v * stride + nrmOffset;
          final no = v * 3;
          vertexData[vo] += nDeltas[no] * w;
          vertexData[vo + 1] += nDeltas[no + 1] * w;
          vertexData[vo + 2] += nDeltas[no + 2] * w;
        }
      }
    }

    if (nrmOffset != null) {
      for (var v = 0; v < vertexCount; v++) {
        final vo = v * stride + nrmOffset;
        final nx = vertexData[vo];
        final ny = vertexData[vo + 1];
        final nz = vertexData[vo + 2];
        final len2 = nx * nx + ny * ny + nz * nz;
        if (len2 > 1e-12) {
          final inv = 1.0 / math.sqrt(len2);
          vertexData[vo] = nx * inv;
          vertexData[vo + 1] = ny * inv;
          vertexData[vo + 2] = nz * inv;
        }
      }
    }

    updateVertices(vertexData);
  }
}

Float32List _calculateTangentsImpl({
  required Float32List positions,
  required Float32List normals,
  required Float32List texCoords,
  required List<int> indices,
}) {
  final vertexCount = positions.length ~/ 3;
  final tan1 = Float32List(vertexCount * 3);
  final tan2 = Float32List(vertexCount * 3);

  for (var i = 0; i + 2 < indices.length; i += 3) {
    final i0 = indices[i];
    final i1 = indices[i + 1];
    final i2 = indices[i + 2];

    final p0x = positions[i0 * 3];
    final p0y = positions[i0 * 3 + 1];
    final p0z = positions[i0 * 3 + 2];

    final dx1 = positions[i1 * 3] - p0x;
    final dy1 = positions[i1 * 3 + 1] - p0y;
    final dz1 = positions[i1 * 3 + 2] - p0z;

    final dx2 = positions[i2 * 3] - p0x;
    final dy2 = positions[i2 * 3 + 1] - p0y;
    final dz2 = positions[i2 * 3 + 2] - p0z;

    final u0 = texCoords[i0 * 2];
    final v0 = texCoords[i0 * 2 + 1];
    final du1 = texCoords[i1 * 2] - u0;
    final dv1 = texCoords[i1 * 2 + 1] - v0;
    final du2 = texCoords[i2 * 2] - u0;
    final dv2 = texCoords[i2 * 2 + 1] - v0;

    final denom = du1 * dv2 - du2 * dv1;
    if (denom.abs() <= 1e-10) {
      continue;
    }
    final r = 1.0 / denom;

    final sx = (dv2 * dx1 - dv1 * dx2) * r;
    final sy = (dv2 * dy1 - dv1 * dy2) * r;
    final sz = (dv2 * dz1 - dv1 * dz2) * r;

    final tx = (du1 * dx2 - du2 * dx1) * r;
    final ty = (du1 * dy2 - du2 * dy1) * r;
    final tz = (du1 * dz2 - du2 * dz1) * r;

    tan1[i0 * 3] += sx;
    tan1[i0 * 3 + 1] += sy;
    tan1[i0 * 3 + 2] += sz;
    tan1[i1 * 3] += sx;
    tan1[i1 * 3 + 1] += sy;
    tan1[i1 * 3 + 2] += sz;
    tan1[i2 * 3] += sx;
    tan1[i2 * 3 + 1] += sy;
    tan1[i2 * 3 + 2] += sz;

    tan2[i0 * 3] += tx;
    tan2[i0 * 3 + 1] += ty;
    tan2[i0 * 3 + 2] += tz;
    tan2[i1 * 3] += tx;
    tan2[i1 * 3 + 1] += ty;
    tan2[i1 * 3 + 2] += tz;
    tan2[i2 * 3] += tx;
    tan2[i2 * 3 + 1] += ty;
    tan2[i2 * 3 + 2] += tz;
  }

  final out = Float32List(vertexCount * 4);
  for (var v = 0; v < vertexCount; v++) {
    final nx = normals[v * 3];
    final ny = normals[v * 3 + 1];
    final nz = normals[v * 3 + 2];

    final tx = tan1[v * 3];
    final ty = tan1[v * 3 + 1];
    final tz = tan1[v * 3 + 2];

    // Gram-Schmidt orthogonalization: t' = normalize(t - n * dot(n, t)).
    final nDotT = nx * tx + ny * ty + nz * tz;
    var ox = tx - nx * nDotT;
    var oy = ty - ny * nDotT;
    var oz = tz - nz * nDotT;
    final len2 = ox * ox + oy * oy + oz * oz;

    if (len2 > 1e-12) {
      final invLen = 1.0 / math.sqrt(len2);
      ox *= invLen;
      oy *= invLen;
      oz *= invLen;

      // Handedness: sign(dot(cross(n, t), b)).
      final cx = ny * tx - nz * ty;
      final cy = nz * tx - nx * tz;
      final cz = nx * ty - ny * tx;
      final bx = tan2[v * 3];
      final by = tan2[v * 3 + 1];
      final bz = tan2[v * 3 + 2];
      final sign = (cx * bx + cy * by + cz * bz) < 0.0 ? -1.0 : 1.0;

      out[v * 4] = ox;
      out[v * 4 + 1] = oy;
      out[v * 4 + 2] = oz;
      out[v * 4 + 3] = sign;
    } else {
      // Fallback orthonormal tangent when UVs are degenerate.
      final rx = ny.abs() < 0.9 ? 0.0 : 1.0;
      final ry = ny.abs() < 0.9 ? 1.0 : 0.0;
      var fx = ry * nz;
      var fy = -rx * nz;
      var fz = rx * ny - ry * nx;
      final fl = math.sqrt(math.max(1e-12, fx * fx + fy * fy + fz * fz));
      fx /= fl;
      fy /= fl;
      fz /= fl;
      out[v * 4] = fx;
      out[v * 4 + 1] = fy;
      out[v * 4 + 2] = fz;
      out[v * 4 + 3] = 1.0;
    }
  }
  return out;
}

void _computeSurfaceAabbInto(
  Float32List data,
  VertexLayout layout,
  int vertexCount,
  Aabb3 out,
) {
  final offset = layout.offsetOf(VertexLayout.positionAttribute);
  if (offset == null || vertexCount == 0) {
    out.min.setZero();
    out.max.setZero();
    return;
  }
  final stride = layout.strideInFloats;
  var minX = double.infinity;
  var minY = double.infinity;
  var minZ = double.infinity;
  var maxX = double.negativeInfinity;
  var maxY = double.negativeInfinity;
  var maxZ = double.negativeInfinity;
  for (var i = offset; i < data.length; i += stride) {
    final x = data[i];
    final y = data[i + 1];
    final z = data[i + 2];
    if (x < minX) {
      minX = x;
    }
    if (x > maxX) {
      maxX = x;
    }
    if (y < minY) {
      minY = y;
    }
    if (y > maxY) {
      maxY = y;
    }
    if (z < minZ) {
      minZ = z;
    }
    if (z > maxZ) {
      maxZ = z;
    }
  }
  out.min.setValues(minX, minY, minZ);
  out.max.setValues(maxX, maxY, maxZ);
}

Aabb3 _computeSurfaceAabb(
  Float32List data,
  VertexLayout layout,
  int vertexCount,
) {
  final out = Aabb3();
  _computeSurfaceAabbInto(data, layout, vertexCount, out);
  return out;
}

Float32List _packStandardVertices(List<Vertex> vertices) {
  final stride = VertexLayout.standard.strideInFloats;
  final packed = Float32List(vertices.length * stride);
  for (var i = 0; i < vertices.length; i++) {
    packed.setRange(i * stride, (i + 1) * stride, vertices[i].storage);
  }
  return packed;
}

Float32List _packPbrVerticesImpl(List<Vertex> vertices) {
  final stride = VertexLayout.pbrStandard.strideInFloats;
  final packed = Float32List(vertices.length * stride);
  for (var i = 0; i < vertices.length; i++) {
    final v = vertices[i];
    final base = i * stride;
    packed.setRange(base, base + 20, v.storage);
    final tan = v.tangent;
    if (tan != null) {
      packed[base + 20] = tan.x;
      packed[base + 21] = tan.y;
      packed[base + 22] = tan.z;
      packed[base + 23] = tan.w;
    } else {
      packed[base + 20] = 1.0;
      packed[base + 21] = 0.0;
      packed[base + 22] = 0.0;
      packed[base + 23] = 1.0;
    }
    final uv1 = v.texCoord1 ?? v.texCoord;
    packed[base + 24] = uv1.x;
    packed[base + 25] = uv1.y;
  }
  return packed;
}

List<Vertex> _normalizeVertices({
  required List<Vertex> vertices,
  required List<int> indices,
  required bool calculateNormals,
}) {
  final recalculate = calculateNormals && vertices.any((e) => e.normal == null);
  if (!recalculate) {
    return vertices;
  }

  final normals = Vertex.calculateVertexNormals(
    vertices.map((e) => e.position.mutable).toList(),
    indices,
  );
  return [
    for (final (i, v) in vertices.indexed)
      v.copyWith(normal: v.normal?.mutable ?? normals[i]),
  ];
}
