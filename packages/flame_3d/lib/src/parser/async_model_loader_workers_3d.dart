part of 'async_model_loader_3d.dart';

const int _standardStride = 20;
const int _maxJointsPerSurface = 64;

List<_BvhSurfaceOutput> _buildBvhsWorker(
  List<_BvhSurfaceInput> inputs,
  int maxLeafTriangles,
) {
  final outputs = <_BvhSurfaceOutput>[];
  for (final input in inputs) {
    final verts = input.vertices.materialize().asFloat32List();
    final idxBuffer = input.indices.materialize();
    final List<int> indices = input.wideIndices
        ? idxBuffer.asUint32List()
        : idxBuffer.asUint16List();
    outputs.add(
      _buildSingleBvh(
        surfaceIndex: input.surfaceIndex,
        verts: verts,
        indices: indices,
        stride: input.stride,
        posOffset: input.posOffset,
        maxLeafTriangles: maxLeafTriangles,
      ),
    );
  }
  return outputs;
}

_BvhSurfaceOutput _buildSingleBvh({
  required int surfaceIndex,
  required Float32List verts,
  required List<int> indices,
  required int stride,
  required int posOffset,
  required int maxLeafTriangles,
}) {
  final triCount = indices.length ~/ 3;
  if (triCount == 0) {
    return _BvhSurfaceOutput(
      surfaceIndex: surfaceIndex,
      nodeCount: 0,
      triangleCount: 0,
      bounds: TransferableTypedData.fromList([Uint8List(0)]),
      leftOrFirst: TransferableTypedData.fromList([Uint8List(0)]),
      rightChild: TransferableTypedData.fromList([Uint8List(0)]),
      counts: TransferableTypedData.fromList([Uint8List(0)]),
      triangles: TransferableTypedData.fromList([Uint8List(0)]),
    );
  }

  final triIndices = Int32List(triCount);
  final triBounds = Float32List(triCount * 6);
  final centroids = Float32List(triCount * 3);

  for (var t = 0; t < triCount; t++) {
    triIndices[t] = t;
    final b = t * 3;
    final i0 = indices[b] * stride + posOffset;
    final i1 = indices[b + 1] * stride + posOffset;
    final i2 = indices[b + 2] * stride + posOffset;

    final x0 = verts[i0];
    final y0 = verts[i0 + 1];
    final z0 = verts[i0 + 2];
    final x1 = verts[i1];
    final y1 = verts[i1 + 1];
    final z1 = verts[i1 + 2];
    final x2 = verts[i2];
    final y2 = verts[i2 + 1];
    final z2 = verts[i2 + 2];

    final tb = t * 6;
    triBounds
      ..[tb] = math.min(x0, math.min(x1, x2))
      ..[tb + 1] = math.min(y0, math.min(y1, y2))
      ..[tb + 2] = math.min(z0, math.min(z1, z2))
      ..[tb + 3] = math.max(x0, math.max(x1, x2))
      ..[tb + 4] = math.max(y0, math.max(y1, y2))
      ..[tb + 5] = math.max(z0, math.max(z1, z2));

    final cb = t * 3;
    centroids
      ..[cb] = (x0 + x1 + x2) * (1.0 / 3.0)
      ..[cb + 1] = (y0 + y1 + y2) * (1.0 / 3.0)
      ..[cb + 2] = (z0 + z1 + z2) * (1.0 / 3.0);
  }

  final maxNodes = math.max(1, triCount * 2);
  final bounds = Float32List(maxNodes * 6);
  final leftOrFirst = Int32List(maxNodes);
  final rightChild = Int32List(maxNodes);
  final counts = Int32List(maxNodes);
  var nodeCount = 0;

  int buildNode(int start, int count) {
    final node = nodeCount++;
    var minX = double.infinity;
    var minY = double.infinity;
    var minZ = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    var maxZ = double.negativeInfinity;
    var cMinX = double.infinity;
    var cMinY = double.infinity;
    var cMinZ = double.infinity;
    var cMaxX = double.negativeInfinity;
    var cMaxY = double.negativeInfinity;
    var cMaxZ = double.negativeInfinity;

    for (var i = start; i < start + count; i++) {
      final t = triIndices[i];
      final tb = t * 6;
      minX = math.min(minX, triBounds[tb]);
      minY = math.min(minY, triBounds[tb + 1]);
      minZ = math.min(minZ, triBounds[tb + 2]);
      maxX = math.max(maxX, triBounds[tb + 3]);
      maxY = math.max(maxY, triBounds[tb + 4]);
      maxZ = math.max(maxZ, triBounds[tb + 5]);

      final cb = t * 3;
      final cx = centroids[cb];
      final cy = centroids[cb + 1];
      final cz = centroids[cb + 2];
      cMinX = math.min(cMinX, cx);
      cMinY = math.min(cMinY, cy);
      cMinZ = math.min(cMinZ, cz);
      cMaxX = math.max(cMaxX, cx);
      cMaxY = math.max(cMaxY, cy);
      cMaxZ = math.max(cMaxZ, cz);
    }

    final nb = node * 6;
    bounds
      ..[nb] = minX
      ..[nb + 1] = minY
      ..[nb + 2] = minZ
      ..[nb + 3] = maxX
      ..[nb + 4] = maxY
      ..[nb + 5] = maxZ;

    if (count <= maxLeafTriangles) {
      leftOrFirst[node] = start;
      counts[node] = count;
      return node;
    }

    final extX = cMaxX - cMinX;
    final extY = cMaxY - cMinY;
    final extZ = cMaxZ - cMinZ;
    var axis = 0;
    var split = 0.5 * (cMinX + cMaxX);
    var extent = extX;
    if (extY > extent) {
      axis = 1;
      split = 0.5 * (cMinY + cMaxY);
      extent = extY;
    }
    if (extZ > extent) {
      axis = 2;
      split = 0.5 * (cMinZ + cMaxZ);
      extent = extZ;
    }

    int mid;
    if (extent <= 1e-12) {
      mid = start + (count >> 1);
    } else {
      var i = start;
      var j = start + count - 1;
      while (i <= j) {
        if (centroids[triIndices[i] * 3 + axis] < split) {
          i++;
        } else {
          final tmp = triIndices[i];
          triIndices[i] = triIndices[j];
          triIndices[j] = tmp;
          j--;
        }
      }
      mid = i;
      if (mid == start || mid == start + count) {
        mid = start + (count >> 1);
      }
    }

    counts[node] = 0;
    leftOrFirst[node] = buildNode(start, mid - start);
    rightChild[node] = buildNode(mid, start + count - mid);
    return node;
  }

  buildNode(0, triCount);

  TransferableTypedData wrapTyped(TypedData data, int byteLen) {
    return TransferableTypedData.fromList([
      data.buffer.asUint8List(data.offsetInBytes, byteLen),
    ]);
  }

  return _BvhSurfaceOutput(
    surfaceIndex: surfaceIndex,
    nodeCount: nodeCount,
    triangleCount: triCount,
    bounds: wrapTyped(bounds, nodeCount * 6 * 4),
    leftOrFirst: wrapTyped(leftOrFirst, nodeCount * 4),
    rightChild: wrapTyped(rightChild, nodeCount * 4),
    counts: wrapTyped(counts, nodeCount * 4),
    triangles: wrapTyped(triIndices, triCount * 4),
  );
}

// ---------------------------------------------------------------------------
// Pure-Dart OBJ worker & materializer
// ---------------------------------------------------------------------------

_PreparedObj _prepareObjInIsolate(
  String objSource,
  Map<String, String> mtlSources,
) {
  final positions = <Vector3>[];
  final normals = <Vector3>[];
  final texCoords = <Vector2>[];
  final mtlColors = <String, List<double>>{};

  void parseMtl(String mtlText) {
    String? curName;
    for (final rawLine in mtlText.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) {
        continue;
      }
      final parts = line.split(RegExp(r'\s+'));
      if (parts.isEmpty) {
        continue;
      }
      if (parts[0] == 'newmtl' && parts.length >= 2) {
        curName = parts[1];
        mtlColors[curName] = const [1.0, 1.0, 1.0];
      } else if (parts[0] == 'Kd' && curName != null && parts.length >= 4) {
        mtlColors[curName] = [
          double.parse(parts[1]),
          double.parse(parts[2]),
          double.parse(parts[3]),
        ];
      }
    }
  }

  for (final mtlText in mtlSources.values) {
    parseMtl(mtlText);
  }

  final groups = <String, List<_ObjTriCorner>>{};
  var currentMat = '__default__';

  for (final rawLine in objSource.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) {
      continue;
    }
    final parts = line.split(RegExp(r'\s+'));
    switch (parts[0]) {
      case 'v':
        if (parts.length >= 4) {
          positions.add(
            Vector3(
              double.parse(parts[1]),
              double.parse(parts[2]),
              double.parse(parts[3]),
            ),
          );
        }
      case 'vn':
        if (parts.length >= 4) {
          normals.add(
            Vector3(
              double.parse(parts[1]),
              double.parse(parts[2]),
              double.parse(parts[3]),
            ),
          );
        }
      case 'vt':
        if (parts.length >= 3) {
          texCoords.add(
            Vector2(
              double.parse(parts[1]),
              double.parse(parts[2]),
            ),
          );
        }
      case 'mtllib':
        if (parts.length >= 2) {
          final src = mtlSources[parts[1]];
          if (src != null) {
            parseMtl(src);
          }
        }
      case 'usemtl':
        if (parts.length >= 2) {
          currentMat = parts[1];
        }
      case 'f':
        if (parts.length >= 4) {
          final corners = <_ObjTriCorner>[];
          for (var i = 1; i < parts.length; i++) {
            final tokens = parts[i].split('/');
            final vRaw = int.parse(tokens[0]);
            final vIdx = vRaw < 0 ? positions.length + vRaw : vRaw - 1;
            var vtIdx = -1;
            if (tokens.length > 1 && tokens[1].isNotEmpty) {
              final tRaw = int.parse(tokens[1]);
              vtIdx = tRaw < 0 ? texCoords.length + tRaw : tRaw - 1;
            }
            var vnIdx = -1;
            if (tokens.length > 2 && tokens[2].isNotEmpty) {
              final nRaw = int.parse(tokens[2]);
              vnIdx = nRaw < 0 ? normals.length + nRaw : nRaw - 1;
            }
            corners.add(_ObjTriCorner(vIdx, vtIdx, vnIdx));
          }
          final dst = groups.putIfAbsent(currentMat, () => []);
          for (var t = 1; t < corners.length - 1; t++) {
            dst
              ..add(corners[0])
              ..add(corners[t])
              ..add(corners[t + 1]);
          }
        }
    }
  }

  final preparedSurfaces = <_PreparedObjSurface>[];
  for (final entry in groups.entries) {
    final corners = entry.value;
    if (corners.isEmpty) {
      continue;
    }
    final dedup = <String, int>{};
    final uniqueCorners = <_ObjTriCorner>[];
    final triIndices = <int>[];
    var anyMissingNormal = false;

    for (var i = 0; i < corners.length; i++) {
      final c = corners[i];
      if (c.vn < 0 || c.vn >= normals.length) {
        anyMissingNormal = true;
      }
      final key = '${c.v}/${c.vt}/${c.vn}';
      final idx = dedup.putIfAbsent(key, () {
        final id = uniqueCorners.length;
        uniqueCorners.add(c);
        return id;
      });
      triIndices.add(idx);
    }

    final vCount = uniqueCorners.length;
    List<Vector3>? computedNormals;
    if (anyMissingNormal) {
      computedNormals = List<Vector3>.generate(
        vCount,
        (_) => Vector3.zero(),
        growable: false,
      );
      for (var t = 0; t + 2 < triIndices.length; t += 3) {
        final i0 = triIndices[t];
        final i1 = triIndices[t + 1];
        final i2 = triIndices[t + 2];
        final p0 = positions[uniqueCorners[i0].v];
        final p1 = positions[uniqueCorners[i1].v];
        final p2 = positions[uniqueCorners[i2].v];
        final fn = (p1 - p0).cross(p2 - p0);
        computedNormals[i0].add(fn);
        computedNormals[i1].add(fn);
        computedNormals[i2].add(fn);
      }
      for (final n in computedNormals) {
        if (n.length2 > 1e-12) {
          n.normalize();
        } else {
          n.setValues(0, 1, 0);
        }
      }
    }

    final packed = Float32List(vCount * _standardStride);
    for (var i = 0; i < vCount; i++) {
      final c = uniqueCorners[i];
      final p = positions[c.v];
      final o = i * _standardStride;
      packed[o] = p.x;
      packed[o + 1] = p.y;
      packed[o + 2] = p.z;
      if (c.vt >= 0 && c.vt < texCoords.length) {
        final uv = texCoords[c.vt];
        packed[o + 3] = uv.x;
        packed[o + 4] = uv.y;
      }
      packed[o + 5] = 1.0;
      packed[o + 6] = 1.0;
      packed[o + 7] = 1.0;
      packed[o + 8] = 1.0;

      final n = c.vn >= 0 && c.vn < normals.length
          ? normals[c.vn]
          : computedNormals![i];
      packed[o + 9] = n.x;
      packed[o + 10] = n.y;
      packed[o + 11] = n.z;
    }

    final wide = vCount > 0xFFFF;
    final TypedData idxTyped = wide
        ? Uint32List.fromList(triIndices)
        : Uint16List.fromList(triIndices);
    final kd = mtlColors[entry.key];

    preparedSurfaces.add(
      _PreparedObjSurface(
        vertices: TransferableTypedData.fromList([
          packed.buffer.asUint8List(),
        ]),
        indices: TransferableTypedData.fromList([
          idxTyped.buffer.asUint8List(),
        ]),
        wideIndices: wide,
        kdRgb: kd,
      ),
    );
  }

  return _PreparedObj(preparedSurfaces);
}

Model _materializePreparedObj(_PreparedObj prepared) {
  final mesh = Mesh();
  for (final s in prepared.surfaces) {
    final verts = s.vertices.materialize().asFloat32List();
    final idxBuf = s.indices.materialize();
    final List<int> indices = s.wideIndices
        ? idxBuf.asUint32List()
        : idxBuf.asUint16List();
    final kd = s.kdRgb;
    final mat = kd != null
        ? SpatialMaterial(
            albedoColor: ui.Color.from(
              alpha: 1.0,
              red: kd[0].clamp(0.0, 1.0),
              green: kd[1].clamp(0.0, 1.0),
              blue: kd[2].clamp(0.0, 1.0),
            ),
          )
        : Material.defaultMaterial;
    final surface = Surface.fromBuffers(
      vertices: verts,
      indices: indices,
      material: mat,
    );
    mesh.addSurface(surface);
  }
  return Model.simple(mesh: mesh);
}
