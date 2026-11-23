import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';

enum PrimitiveType() {
  triangles,
}

/// Displacement deltas for one blend-shape / morph target of a [Surface].
class MorphTargetData({
  required final Float32List positionDeltas,
  final String? name,
  final Float32List? normalDeltas,
});

/// The per-vertex values of an attribute that a [Surface] keeps beside its
/// vertex buffer, see [Surface.customAttributes]: [components] floats per
/// vertex, one vertex after the other, in [values].
class SurfaceAttribute(
  /// The number of floats per vertex, `1` to `4`.
  final int components,

  /// The values, [components] per vertex.
  final Float32List values,
) {
  /// The number of vertices [values] holds.
  int get vertexCount => values.length ~/ components;
}

/// {@template surface}
/// Base surface [Resource], it describes a single surface to be rendered: an
/// interleaved vertex buffer laid out as described by [layout], primitive
/// [indices] assembled with [topology], and the [material] it is drawn with.
///
/// Indices are 16-bit, or 32-bit when the surface has more than 65,535
/// vertices (or when built from a [Uint32List]).
/// {@endtemplate}
class Surface extends Resource<GpuBuffer> {
  /// {@macro surface}
  ///
  /// Builds the surface from [Vertex] objects, packed with the
  /// [VertexLayout.standard] layout (or [VertexLayout.pbrStandard] when any
  /// vertex supplies `tangent` or `texCoord1`). If [calculateNormals] is
  /// `true`, the normals are calculated when a vertex does not provide one.
  Surface({
    required List<Vertex> vertices,
    required List<int> indices,
    Material? material,
    this.jointMap,
    List<MorphTargetData> morphTargets = const [],
    bool calculateNormals = true,
    this.topology = PrimitiveTopology.triangles,
    Map<String, SurfaceAttribute> customAttributes = const {},
  }) : _material = material ?? Material.defaultMaterial,
       morphTargets = List.unmodifiable(morphTargets),
       customAttributes = Map.unmodifiable(customAttributes) {
    final normalizedVertices = _normalize(
      vertices: vertices,
      indices: indices,
      calculateNormals:
          calculateNormals &&
          topology == PrimitiveTopology.triangles &&
          indices.length >= 3,
    );
    final hasExtendedPbr = normalizedVertices.any(
      (v) => v.tangent != null || v.texCoord1 != null,
    );
    _layout = hasExtendedPbr ? VertexLayout.pbrStandard : VertexLayout.standard;
    vertexData = hasExtendedPbr
        ? _packPbrVertices(normalizedVertices)
        : _packVertices(normalizedVertices);
    vertexCount = normalizedVertices.length;
    if (this.morphTargets.isNotEmpty) {
      _baseVertexData = Float32List.fromList(vertexData);
    }
    _setIndices(_indexList(indices, vertexCount));
    _aabb = _computeAabb(vertexData, _layout, vertexCount);
    _updateAabbCenter();
  }

  /// {@macro surface}
  ///
  /// Builds the surface straight from typed arrays, without creating [Vertex]
  /// objects: [vertices] holds the interleaved floats of every vertex as
  /// described by [layout] (the [VertexLayout.standard] layout by default),
  /// and [indices] is a [Uint16List] or a [Uint32List].
  Surface.fromBuffers({
    required Float32List vertices,
    required List<int> indices,
    VertexLayout? layout,
    Material? material,
    this.jointMap,
    List<MorphTargetData> morphTargets = const [],
    Aabb3? aabb,
    this.topology = PrimitiveTopology.triangles,
    Map<String, SurfaceAttribute> customAttributes = const {},
  }) : _material = material ?? Material.defaultMaterial,
       _layout = layout ?? VertexLayout.standard,
       morphTargets = List.unmodifiable(morphTargets),
       customAttributes = Map.unmodifiable(customAttributes) {
    final stride = _layout.strideInFloats;
    if (vertices.length % stride != 0) {
      throw ArgumentError.value(
        vertices.length,
        'vertices',
        'Must hold whole vertices of ${_layout.strideInFloats} floats',
      );
    }
    if (indices is! Uint16List && indices is! Uint32List) {
      throw ArgumentError.value(
        indices.runtimeType,
        'indices',
        'Must be a Uint16List or a Uint32List',
      );
    }
    vertexData = vertices;
    vertexCount = vertices.length ~/ stride;
    if (this.morphTargets.isNotEmpty) {
      _baseVertexData = Float32List.fromList(vertexData);
    }
    _setIndices(indices);
    _aabb = aabb ?? _computeAabb(vertexData, _layout, vertexCount);
    _updateAabbCenter();
  }

  static int _nextId = 0;

  /// A number identifying this surface, used to group draws by surface.
  final int id = _nextId++;

  /// The material the surface is drawn with.
  ///
  /// Assigning another material marks every `World3D` changed (see
  /// `World3D.sceneVersion`), and their shadow casters too when the two
  /// materials differ in `Material.castsShadows`, since the surface may be
  /// drawn in any world.
  Material get material => _material;
  set material(Material value) {
    if (identical(value, _material)) {
      return;
    }
    final shadows = value.castsShadows != _material.castsShadows;
    _material = value;
    Material.noteAssignment(shadows: shadows);
  }

  Material _material;

  /// Primitive assembly topology (`triangles` by default).
  PrimitiveTopology topology;

  /// Maps the joint indices of the model to the joint indices used by this
  /// surface's vertices, for skinned surfaces.
  Map<int, int>? jointMap;

  /// Optional blend-shape / morph targets displacing [vertexData].
  final List<MorphTargetData> morphTargets;

  /// Per-vertex attributes the surface keeps beside its vertex buffer, by
  /// name: data no material reads, kept on the CPU only (the glTF readers
  /// keep a primitive's application attributes, `_NAME`, and its
  /// `TEXCOORD_1` and further texture coordinates here). Empty by default.
  ///
  /// `StylizedVertexMapping` turns them into the inputs of
  /// `StylizedMaterial`'s layout.
  final Map<String, SurfaceAttribute> customAttributes;

  Float32List? _baseVertexData;

  late VertexLayout _layout;

  /// The layout of [vertexData].
  VertexLayout get layout => _layout;

  /// The vertices before any morph weights were applied ([vertexData] when
  /// the surface has no [morphTargets] or no weights were applied).
  Float32List get restVertexData => _baseVertexData ?? vertexData;

  /// The interleaved vertex data, [VertexLayout.strideInFloats] floats per
  /// vertex.
  late Float32List vertexData;

  /// The bounds of the surface's vertices.
  Aabb3 get aabb => _aabb;
  late final Aabb3 _aabb;

  /// Cached local-space center of [aabb].
  Vector3 get aabbCenter => _aabbCenter;
  final Vector3 _aabbCenter = Vector3.zero();

  void _updateAabbCenter() {
    _aabbCenter.setValues(
      (_aabb.min.x + _aabb.max.x) * 0.5,
      (_aabb.min.y + _aabb.max.y) * 0.5,
      (_aabb.min.z + _aabb.max.z) * 0.5,
    );
  }

  /// The number of vertices.
  late final int vertexCount;

  /// The triangle indices: a [Uint16List] or a [Uint32List], see [indexType].
  List<int> get indices => _indices;
  late final List<int> _indices;

  /// The type of [indices].
  GpuIndexType get indexType => _indexType;
  late final GpuIndexType _indexType;

  /// The number of indices.
  int get indexCount => _indices.length;

  /// The size of the vertex data in bytes.
  int get verticesBytes => vertexData.lengthInBytes;

  /// The size of the index data in bytes.
  int get indicesBytes => indexCount * _indexType.bytesPerIndex;

  /// The offset of the index data in the surface's GPU buffer.
  int get indicesOffsetInBytes => verticesBytes;

  Float32List? _positions;
  SurfaceBvh? _bvh;

  /// The (x, y, z) positions of this surface's vertices, packed contiguously
  /// as `[x0, y0, z0, x1, y1, z1, ...]`. Computed on first access and updated
  /// automatically by [updateVertices].
  Float32List get positions => _positions ??= _extractPositions();

  /// Lazy flat Bounding Volume Hierarchy (`O(log T)` narrowphase ray queries)
  /// over this surface's triangles, built on first access and invalidated when
  /// [updateVertices] mutates vertex positions.
  SurfaceBvh get bvh => _bvh ??= SurfaceBvh.build(this);

  /// Uses [bvh], built elsewhere for this surface's current vertices (for
  /// example on another isolate, see `SurfaceBvh.fromPrepared`), as [bvh].
  /// Like any cached BVH it is dropped when [updateVertices] changes the
  /// vertices.
  void adoptBvh(SurfaceBvh bvh) {
    if (!identical(bvh.surface, this)) {
      throw ArgumentError.value(bvh, 'bvh', 'Was built for another surface');
    }
    _bvh = bvh;
  }

  int? _resourceSizeInBytes;

  int get _sizeInBytes => verticesBytes + _align4(indicesBytes);

  @override
  bool get recreateResource =>
      super.recreateResource || _resourceSizeInBytes != _sizeInBytes;

  @override
  GpuBuffer createResource() {
    _resourceSizeInBytes = _sizeInBytes;
    final indices = _indices as TypedData;
    return GpuBackend.instance.createBuffer(
        storageMode: GpuStorageMode.hostVisible,
        sizeInBytes: _sizeInBytes,
      )
      ..write(ByteData.sublistView(vertexData))
      ..write(
        ByteData.sublistView(indices),
        destinationOffsetInBytes: indicesOffsetInBytes,
      );
  }

  /// Computes per-vertex `vec4` tangents (`[tx, ty, tz, sign, ...]` with
  /// `sign` in `{-1.0, +1.0}`) for every vertex of this surface, by summing
  /// the UV-derived tangents of the triangles around each vertex and
  /// orthogonalizing them against the normal (Gram-Schmidt). This is not
  /// MikkTSpace: normal maps baked with MikkTSpace can show small seams.
  ///
  /// When [storeInSurface] is `true` (the default), this surface's [layout] and
  /// [vertexData] are upgraded in-place to include `vertexTangent` (and
  /// `vertexTexCoord1` from [texCoord1] or `vertexTexCoord`) so
  /// `SpatialMaterial` automatically uses the exact vertex TBN frame.
  Float32List computeTangents({
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

    final tangents = calculateTangents(
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

  /// Computes per-vertex Gram-Schmidt orthogonalized `vec4` tangents
  /// (`[tx, ty, tz, handedness]`; not MikkTSpace, see [computeTangents]) from
  /// raw [positions] (`3 * N`), [normals] (`3 * N`), [texCoords] (`2 * N`),
  /// and triangle [indices].
  static Float32List calculateTangents({
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

  /// Updates the interleaved vertex buffer in place on the GPU (when already
  /// uploaded), refreshes [aabb], and invalidates any cached [bvh].
  void updateVertices(Float32List newVertices, {Aabb3? aabb}) {
    if (newVertices.length != vertexData.length) {
      throw ArgumentError.value(
        newVertices.length,
        'newVertices',
        'Must match existing length ${vertexData.length}',
      );
    }
    if (!identical(newVertices, vertexData)) {
      vertexData.setAll(0, newVertices);
    }
    if (aabb != null) {
      _aabb.setFrom(aabb);
    } else {
      final recomputed = _computeAabb(vertexData, _layout, vertexCount);
      _aabb.setFrom(recomputed);
    }
    _updateAabbCenter();
    if (_positions != null) {
      _fillPositions(_positions!);
    }
    _bvh = null;
    if (hasResource && _resourceSizeInBytes == _sizeInBytes) {
      resource.write(ByteData.sublistView(vertexData));
    }
  }

  /// Uploads the indices `[start, start + count)` of [indices] (all of them
  /// when [count] is `null`) after they were changed in place, and
  /// invalidates the cached [bvh].
  ///
  /// Only that range of the GPU buffer is written (widened to whole 4-byte
  /// words), and only when the buffer was already uploaded; otherwise the
  /// next upload takes the new indices anyway.
  void updateIndices({int start = 0, int? count}) {
    final end = count == null ? _indices.length : start + count;
    RangeError.checkValidRange(start, end, _indices.length);
    _bvh = null;
    if (start == end || !hasResource || _resourceSizeInBytes != _sizeInBytes) {
      return;
    }
    final bytesPerIndex = _indexType.bytesPerIndex;
    var first = start;
    var last = end;
    if (bytesPerIndex == 2) {
      first &= ~1;
      last = math.min(_indices.length, (last + 1) & ~1);
    }
    // The view's range is in elements of the index list.
    resource.write(
      ByteData.sublistView(_indices as TypedData, first, last),
      destinationOffsetInBytes: indicesOffsetInBytes + first * bytesPerIndex,
    );
  }

  /// Returns a surface that shares this surface's [indices], [layout],
  /// [material], [topology], [jointMap], [morphTargets] and
  /// [customAttributes], with its own copy of the rest vertices (the vertices
  /// before any morph weights).
  ///
  /// Morph weights applied to the copy leave this surface unchanged, which is
  /// how `ModelComponent`s sharing a model keep independent morph states. The
  /// copy has its own GPU buffer and ray-casting BVH.
  Surface copyWithOwnVertices() {
    return Surface.fromBuffers(
      vertices: Float32List.fromList(_baseVertexData ?? vertexData),
      indices: _indices,
      layout: _layout,
      material: material,
      jointMap: jointMap,
      morphTargets: morphTargets,
      topology: topology,
      customAttributes: customAttributes,
    );
  }

  /// Blends [morphTargets] using [weights] onto the rest vertices of this
  /// surface with zero heap allocations and uploads the morphed vertex buffer.
  ///
  /// Only the first [targetCount] weights are used when given.
  void applyMorphWeights(List<double> weights, {int? targetCount}) {
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

  @override
  void dispose() {
    _resourceSizeInBytes = null;
    super.dispose();
  }

  void _setIndices(List<int> indices) {
    _indices = indices;
    _indexType = indices is Uint32List
        ? GpuIndexType.uint32
        : GpuIndexType.uint16;
  }

  Float32List _extractPositions() {
    final out = Float32List(vertexCount * 3);
    _fillPositions(out);
    return out;
  }

  void _fillPositions(Float32List out) {
    final offset = _layout.offsetOf(VertexLayout.positionAttribute);
    if (offset == null) {
      return;
    }
    final stride = _layout.strideInFloats;
    for (var i = 0; i < vertexCount; i++) {
      final base = i * stride + offset;
      out[i * 3] = vertexData[base];
      out[i * 3 + 1] = vertexData[base + 1];
      out[i * 3 + 2] = vertexData[base + 2];
    }
  }

  static int _align4(int value) => (value + 3) & ~3;

  static List<int> _indexList(List<int> indices, int vertexCount) {
    var wide = vertexCount > 0xFFFF;
    for (var i = 0; !wide && i < indices.length; i++) {
      wide = indices[i] >= 0xFFFF;
    }
    return wide ? Uint32List.fromList(indices) : Uint32ListOrUint16.of(indices);
  }

  static Aabb3 _computeAabb(
    Float32List data,
    VertexLayout layout,
    int vertexCount,
  ) {
    final offset = layout.offsetOf(VertexLayout.positionAttribute);
    if (offset == null || vertexCount == 0) {
      return Aabb3();
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
    return Aabb3.minMax(
      Vector3(minX, minY, minZ),
      Vector3(maxX, maxY, maxZ),
    );
  }

  static Float32List _packVertices(List<Vertex> vertices) {
    final stride = VertexLayout.standard.strideInFloats;
    final packed = Float32List(vertices.length * stride);
    for (var i = 0; i < vertices.length; i++) {
      packed.setRange(i * stride, (i + 1) * stride, vertices[i].storage);
    }
    return packed;
  }

  static Float32List _packPbrVertices(List<Vertex> vertices) {
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

  static List<Vertex> _normalize({
    required List<Vertex> vertices,
    required List<int> indices,
    required bool calculateNormals,
  }) {
    final recalculate =
        calculateNormals && vertices.any((e) => e.normal == null);
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
}

extension Uint32ListOrUint16 on Uint16List {
  static Uint16List of(List<int> indices) => Uint16List.fromList(indices);
}
