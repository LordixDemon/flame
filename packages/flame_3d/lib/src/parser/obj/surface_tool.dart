// ignore_for_file: use_setters_to_change_properties

import 'dart:collection';
import 'dart:ui';

import 'package:flame_3d/core.dart';
import 'package:flame_3d/resources.dart';

/// Procedural triangle/vertex builder that deduplicates shared vertices into an
/// indexed [Mesh] [Surface] with optional normals, UVs, colors, and tangents.
class SurfaceTool() {
  final List<Vertex> _vertices = [];
  final List<int> _indices = [];

  Color _lastColor = const Color(0xFFFFFFFF);
  Vector3? _lastNormal;
  Vector4? _lastTangent;
  final Vector2 _lastTexCoord = Vector2.zero();
  Material _lastMaterial = SpatialMaterial();

  void setColor(Color color) => _lastColor = color;

  void setNormal(Vector3? normal) {
    if (normal == null) {
      _lastNormal = null;
    } else {
      (_lastNormal ??= Vector3.zero()).setFrom(normal);
    }
  }

  /// Sets the tangent (`xyz` tangent direction, `w` bitangent sign) applied to
  /// subsequently added vertices, or `null` to omit tangents.
  void setTangent(Vector4? tangent) {
    if (tangent == null) {
      _lastTangent = null;
    } else {
      (_lastTangent ??= Vector4.zero()).setFrom(tangent);
    }
  }

  void setTexCoord(Vector2 texCoord) => _lastTexCoord.setFrom(texCoord);

  void setMaterial(Material material) => _lastMaterial = material;

  void addTriangleFan(
    List<Vector3> vertices,
    List<Vector2> texCoords, [
    List<Vector3> normals = const [],
    List<Color> colors = const [],
    List<Vector4> tangents = const [],
  ]) {
    assert(vertices.length == 3, 'Expected a length of 3 for vertices');

    void addPoint(int n) {
      if (texCoords.length > n) {
        setTexCoord(texCoords[n]);
      }
      if (colors.length > n) {
        setColor(colors[n]);
      }
      if (normals.length > n) {
        setNormal(normals[n]);
      } else {
        setNormal(null);
      }
      if (tangents.length > n) {
        setTangent(tangents[n]);
      } else {
        setTangent(null);
      }
      addVertex(vertices[n]);
    }

    for (var i = 0; i < vertices.length - 2; i++) {
      addPoint(0);
      addPoint(i + 1);
      addPoint(i + 2);
    }
  }

  void addVertex(Vector3 position) {
    final vertex = Vertex(
      position: position,
      texCoord: _lastTexCoord,
      normal: _lastNormal,
      color: _lastColor,
      tangent: _lastTangent,
    );

    _vertices.add(vertex);
  }

  void addIndex(int index) {
    _indices.add(index);
  }

  void index() {
    if (_indices.isNotEmpty) {
      return;
    }

    final indexMap = HashMap<Vertex, int>();
    final oldVertices = List<Vertex>.from(_vertices);
    _vertices.clear();

    for (final vertex in oldVertices) {
      var index = indexMap[vertex];
      if (index == null) {
        index = indexMap.length;
        _vertices.add(vertex);
        indexMap[vertex] = index;
      }
      _indices.add(index);
    }
  }

  Mesh apply([Mesh? mesh]) {
    index();
    mesh ??= Mesh();
    return mesh..addSurface(
      Surface(
        vertices: _vertices,
        indices: _indices,
        material: _lastMaterial,
      ),
    );
  }
}
