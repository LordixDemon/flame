import 'dart:typed_data';

import 'package:flame_3d/game.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';

enum PrimitiveType() {
  triangles,
}

/// {@template surface}
/// Base surface [Resource], it describes a single surface to be rendered: an
/// interleaved vertex buffer laid out as described by [layout], triangle
/// indices, and the [material] it is drawn with.
///
/// Indices are 16-bit, or 32-bit when the surface has more than 65,535
/// vertices (or when built from a [Uint32List]).
/// {@endtemplate}
class Surface extends Resource<GpuBuffer> {
  /// {@macro surface}
  ///
  /// Builds the surface from [Vertex] objects, packed with the
  /// [VertexLayout.standard] layout. If [calculateNormals] is `true`, the
  /// normals are calculated when a vertex does not provide one.
  Surface({
    required List<Vertex> vertices,
    required List<int> indices,
    Material? material,
    this.jointMap,
    bool calculateNormals = true,
  }) : material = material ?? Material.defaultMaterial,
       layout = VertexLayout.standard {
    final normalizedVertices = _normalize(
      vertices: vertices,
      indices: indices,
      calculateNormals: calculateNormals,
    );
    vertexData = _packVertices(normalizedVertices);
    vertexCount = normalizedVertices.length;
    _setIndices(_indexList(indices, vertexCount));
    _aabb = _computeAabb(vertexData, layout, vertexCount);
  }

  /// {@macro surface}
  ///
  /// Builds the surface straight from typed arrays, without creating [Vertex]
  /// objects: [vertices] holds the interleaved floats of every vertex as
  /// described by [layout] (the [VertexLayout.standard] layout by default),
  /// and [indices] is a [Uint16List] or a [Uint32List].
  ///
  /// The arrays are used as given, not copied. The bounds are computed from
  /// the [VertexLayout.positionAttribute] unless [aabb] is given.
  Surface.fromBuffers({
    required Float32List vertices,
    required List<int> indices,
    VertexLayout? layout,
    Material? material,
    this.jointMap,
    Aabb3? aabb,
  }) : material = material ?? Material.defaultMaterial,
       layout = layout ?? VertexLayout.standard {
    final stride = this.layout.strideInFloats;
    if (vertices.length % stride != 0) {
      throw ArgumentError.value(
        vertices.length,
        'vertices',
        'Must hold whole vertices of ${this.layout.strideInFloats} floats',
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
    _setIndices(indices);
    _aabb = aabb ?? _computeAabb(vertexData, this.layout, vertexCount);
  }

  static int _nextId = 0;

  /// A number identifying this surface, used to group draws by surface.
  final int id = _nextId++;

  /// The material the surface is drawn with.
  Material material;

  /// Maps the joint indices of the model to the joint indices used by this
  /// surface's vertices, for skinned surfaces.
  Map<int, int>? jointMap;

  /// The layout of [vertexData].
  final VertexLayout layout;

  /// The interleaved vertex data, [VertexLayout.strideInFloats] floats per
  /// vertex.
  late final Float32List vertexData;

  /// The bounds of the surface's vertices.
  Aabb3 get aabb => _aabb;
  late final Aabb3 _aabb;

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

  /// The (x, y, z) positions of this surface's vertices, packed contiguously
  /// as `[x0, y0, z0, x1, y1, z1, ...]`. Computed on first access.
  late final Float32List positions = _extractPositions();

  int? _resourceSizeInBytes;

  int get _sizeInBytes => verticesBytes + _align4(indicesBytes);

  @override
  bool get recreateResource => _resourceSizeInBytes != _sizeInBytes;

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

  void _setIndices(List<int> indices) {
    _indices = indices;
    _indexType = indices is Uint32List
        ? GpuIndexType.uint32
        : GpuIndexType.uint16;
  }

  Float32List _extractPositions() {
    final offset = layout.offsetOf(VertexLayout.positionAttribute);
    final positions = Float32List(vertexCount * 3);
    if (offset == null) {
      return positions;
    }
    final stride = layout.strideInFloats;
    for (var i = 0; i < vertexCount; i++) {
      final base = i * stride + offset;
      positions[i * 3] = vertexData[base];
      positions[i * 3 + 1] = vertexData[base + 1];
      positions[i * 3 + 2] = vertexData[base + 2];
    }
    return positions;
  }

  static int _align4(int value) => (value + 3) & ~3;

  /// Indices as 16-bit integers, or 32-bit ones when they do not fit or the
  /// surface has more than 65,535 vertices (keeping index 65535 free, as some
  /// APIs reserve it to restart primitives).
  static List<int> _indexList(List<int> indices, int vertexCount) {
    var wide = vertexCount > 0xFFFF;
    for (var i = 0; !wide && i < indices.length; i++) {
      wide = indices[i] >= 0xFFFF;
    }
    return wide ? Uint32List.fromList(indices) : Uint16List.fromList(indices);
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
