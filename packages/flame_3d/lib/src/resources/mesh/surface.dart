import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame_3d/core.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/src/graphics/backend.dart';

part 'surface_geometry.dart';

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
    this.hasVertexAnimation = false,
    Map<String, SurfaceAttribute> customAttributes = const {},
  }) : _material = material ?? Material.defaultMaterial,
       morphTargets = List.unmodifiable(morphTargets),
       customAttributes = Map.unmodifiable(customAttributes) {
    final normalizedVertices = _normalizeVertices(
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
        ? _packPbrVerticesImpl(normalizedVertices)
        : _packStandardVertices(normalizedVertices);
    vertexCount = normalizedVertices.length;
    if (this.morphTargets.isNotEmpty) {
      _baseVertexData = Float32List.fromList(vertexData);
    }
    _setIndices(_indexList(indices, vertexCount));
    _aabb = _computeSurfaceAabb(vertexData, _layout, vertexCount);
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
    this.hasVertexAnimation = false,
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
    _aabb = aabb ?? _computeSurfaceAabb(vertexData, _layout, vertexCount);
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

  /// Whether vertices carry non-zero shader animation attributes (such as wind
  /// sway or flutter) that displace them over time.
  final bool hasVertexAnimation;

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
  }) => _computeTangentsImpl(
    storeInSurface: storeInSurface,
    texCoord1: texCoord1,
  );

  /// Computes per-vertex Gram-Schmidt orthogonalized `vec4` tangents
  /// (`[tx, ty, tz, handedness]`; not MikkTSpace, see [computeTangents]) from
  /// raw [positions] (`3 * N`), [normals] (`3 * N`), [texCoords] (`2 * N`),
  /// and triangle [indices].
  static Float32List calculateTangents({
    required Float32List positions,
    required Float32List normals,
    required Float32List texCoords,
    required List<int> indices,
  }) => _calculateTangentsImpl(
    positions: positions,
    normals: normals,
    texCoords: texCoords,
    indices: indices,
  );

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
      _computeSurfaceAabbInto(vertexData, _layout, vertexCount, _aabb);
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
      hasVertexAnimation: hasVertexAnimation,
      customAttributes: customAttributes,
    );
  }

  /// Blends [morphTargets] using [weights] onto the rest vertices of this
  /// surface with zero heap allocations and uploads the morphed vertex buffer.
  ///
  /// Only the first [targetCount] weights are used when given.
  void applyMorphWeights(List<double> weights, {int? targetCount}) =>
      _applyMorphWeightsImpl(weights, targetCount: targetCount);

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
}

extension Uint32ListOrUint16 on Uint16List {
  static Uint16List of(List<int> indices) => Uint16List.fromList(indices);
}
