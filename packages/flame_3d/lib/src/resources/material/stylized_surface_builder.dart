part of 'stylized_material.dart';

/// Builds a [StylizedMaterial] surface in [StylizedMaterial.vertexLayout].
Surface _buildStylizedSurface({
  required List<double> positions,
  required List<double> normals,
  required List<int> indices,
  required Material material,
  List<double>? colors,
  List<double>? occlusion,
  List<double>? tint,
  List<double>? accent,
  List<double>? emissive,
  List<double>? gloss,
  List<double>? sway,
  List<double>? windPhase,
  List<double>? windFlutter,
  List<double>? joints,
  List<double>? weights,
  List<double>? texCoords,
  Aabb3? aabb,
}) {
  final count = positions.length ~/ 3;
  checkVertexArrayLength(positions, 'positions', count, 3);
  checkVertexArrayLength(normals, 'normals', count, 3);
  checkVertexArrayLength(colors, 'colors', count, 4);
  checkVertexArrayLength(occlusion, 'occlusion', count, 1);
  checkVertexArrayLength(tint, 'tint', count, 1);
  checkVertexArrayLength(accent, 'accent', count, 1);
  checkVertexArrayLength(emissive, 'emissive', count, 1);
  checkVertexArrayLength(gloss, 'gloss', count, 1);
  checkVertexArrayLength(sway, 'sway', count, 1);
  checkVertexArrayLength(windPhase, 'windPhase', count, 1);
  checkVertexArrayLength(windFlutter, 'windFlutter', count, 1);
  checkVertexArrayLength(joints, 'joints', count, 4);
  checkVertexArrayLength(weights, 'weights', count, 4);
  checkVertexArrayLength(texCoords, 'texCoords', count, 2);
  if ((joints == null) != (weights == null)) {
    throw ArgumentError(
      'joints and weights must be given together: '
      'a skinned surface needs both',
    );
  }
  if (joints != null) {
    for (var i = 0; i < joints.length; i++) {
      final joint = joints[i];
      if (joint < 0 ||
          joint >= StylizedMaterial.maxJoints ||
          joint != joint.roundToDouble()) {
        throw ArgumentError.value(
          joint,
          'joints',
          'Joint indices must be whole numbers from 0 to '
              '${StylizedMaterial.maxJoints - 1}',
        );
      }
    }
  }

  final skinned = joints != null;
  final textured = texCoords != null;
  final layout = switch ((skinned, textured)) {
    (false, false) => StylizedMaterial.vertexLayout,
    (true, false) => StylizedMaterial.skinnedVertexLayout,
    (false, true) => StylizedMaterial.texturedVertexLayout,
    (true, true) => StylizedMaterial.texturedSkinnedVertexLayout,
  };
  final stride = layout.strideInFloats;
  // Texture coordinates follow StylizedMaterial.vertexLayout's 18 floats, then
  // come joints and weights.
  final skinOffset = textured ? 20 : 18;
  final data = Float32List(count * stride);
  for (var i = 0; i < count; i++) {
    final o = i * stride;
    data
      ..[o] = positions[i * 3]
      ..[o + 1] = positions[i * 3 + 1]
      ..[o + 2] = positions[i * 3 + 2]
      ..[o + 3] = normals[i * 3]
      ..[o + 4] = normals[i * 3 + 1]
      ..[o + 5] = normals[i * 3 + 2]
      ..[o + 6] = colors == null ? 1 : colors[i * 4]
      ..[o + 7] = colors == null ? 1 : colors[i * 4 + 1]
      ..[o + 8] = colors == null ? 1 : colors[i * 4 + 2]
      ..[o + 9] = colors == null ? 1 : colors[i * 4 + 3]
      ..[o + 10] = tint?[i] ?? 0
      ..[o + 11] = accent?[i] ?? 0
      ..[o + 12] = emissive?[i] ?? 0
      ..[o + 13] = gloss?[i] ?? 0
      ..[o + 14] = occlusion?[i] ?? 1
      ..[o + 15] = sway?[i] ?? 0
      ..[o + 16] = windPhase?[i] ?? 0
      ..[o + 17] = windFlutter?[i] ?? 0;
    if (textured) {
      data
        ..[o + 18] = texCoords[i * 2]
        ..[o + 19] = texCoords[i * 2 + 1];
    }
    if (skinned) {
      for (var k = 0; k < 4; k++) {
        data
          ..[o + skinOffset + k] = joints[i * 4 + k]
          ..[o + skinOffset + 4 + k] = weights![i * 4 + k];
      }
    }
  }
  return Surface.fromBuffers(
    vertices: data,
    indices: packTriangleIndices(indices, count),
    layout: layout,
    material: material,
    aabb: aabb,
  );
}

Surface _buildBatchedStylizedSurface({
  required List<Surface> surfaces,
  required Material material,
  Aabb3? aabb,
}) {
  if (surfaces.isEmpty) {
    throw ArgumentError.value(surfaces, 'surfaces', 'Must not be empty');
  }
  if (surfaces.length > StylizedMaterial.maxBatchObjects) {
    throw ArgumentError.value(
      surfaces.length,
      'surfaces',
      'At most ${StylizedMaterial.maxBatchObjects} surfaces per rigid batch',
    );
  }
  var totalVertices = 0;
  var totalIndices = 0;
  for (var i = 0; i < surfaces.length; i++) {
    final s = surfaces[i];
    if (s.layout != StylizedMaterial.vertexLayout) {
      throw ArgumentError.value(
        s.layout,
        'surfaces[$i]',
        'Rigid batches require StylizedMaterial.vertexLayout',
      );
    }
    if (s.topology != PrimitiveTopology.triangles) {
      throw ArgumentError.value(
        s.topology,
        'surfaces[$i]',
        'Rigid batches merge triangle lists only',
      );
    }
    totalVertices += s.vertexCount;
    totalIndices += s.indexCount;
  }

  const srcStride = 18;
  const dstStride = 19;
  final verts = Float32List(totalVertices * dstStride);
  final List<int> indices = totalVertices > 0xFFFF
      ? Uint32List(totalIndices)
      : Uint16List(totalIndices);

  var vertBase = 0;
  var idxCursor = 0;
  for (var objIdx = 0; objIdx < surfaces.length; objIdx++) {
    final s = surfaces[objIdx];
    final vCount = s.vertexCount;
    final srcVerts = s.vertexData;
    final objId = objIdx.toDouble();
    for (var v = 0; v < vCount; v++) {
      final srcOff = v * srcStride;
      final dstOff = (vertBase + v) * dstStride;
      for (var k = 0; k < srcStride; k++) {
        verts[dstOff + k] = srcVerts[srcOff + k];
      }
      verts[dstOff + srcStride] = objId;
    }
    final srcIndices = s.indices;
    final iCount = srcIndices.length;
    for (var t = 0; t < iCount; t++) {
      indices[idxCursor + t] = vertBase + srcIndices[t];
    }
    vertBase += vCount;
    idxCursor += iCount;
  }

  return Surface.fromBuffers(
    vertices: verts,
    indices: indices,
    layout: StylizedMaterial.batchedVertexLayout,
    material: material,
    aabb: aabb,
  );
}
