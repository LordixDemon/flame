import 'dart:math' as math;
import 'dart:ui' show Color;

import 'package:flame_3d/core.dart';
import 'package:flame_3d/resources.dart';

/// Collects vertex-colored triangles for a [StylizedMaterial] surface, in a
/// world whose up axis is z.
class PoolMeshBuilder() {
  final List<double> _positions = [];
  final List<double> _normals = [];
  final List<double> _colors = [];
  final List<double> _occlusion = [];
  final List<double> _emissive = [];
  final List<double> _gloss = [];
  final List<int> _indices = [];

  int get _vertexCount => _positions.length ~/ 3;

  /// Adds a vertex and returns its index.
  int vertex(
    Vector3 position,
    Vector3 normal,
    Color color, {
    double occlusion = 1,
    double emissive = 0,
    double gloss = 0,
  }) {
    _positions.addAll([position.x, position.y, position.z]);
    _normals.addAll([normal.x, normal.y, normal.z]);
    _colors.addAll([color.r, color.g, color.b, color.a]);
    _occlusion.add(occlusion);
    _emissive.add(emissive);
    _gloss.add(gloss);
    return _vertexCount - 1;
  }

  /// Adds the triangle of the vertices [a], [b] and [c], counter-clockwise
  /// seen from the side it faces.
  void triangle(int a, int b, int c) => _indices.addAll([a, b, c]);

  /// Adds the flat quad of the corners [a], [b], [c] and [d], counter-
  /// clockwise seen from the side it faces. [occlusion] darkens each corner.
  void quad(
    Vector3 a,
    Vector3 b,
    Vector3 c,
    Vector3 d,
    Color color, {
    List<double> occlusion = const [1, 1, 1, 1],
    double emissive = 0,
    double gloss = 0,
  }) {
    final normal = (b - a).cross(d - a)..normalize();
    final corners = [a, b, c, d];
    final first = _vertexCount;
    for (var i = 0; i < 4; i++) {
      vertex(
        corners[i],
        normal,
        color,
        occlusion: occlusion[i],
        emissive: emissive,
        gloss: gloss,
      );
    }
    triangle(first, first + 1, first + 2);
    triangle(first, first + 2, first + 3);
  }

  /// Adds a box from [min] to [max]: [top] colors its top face, [side] the
  /// others. The sides darken towards their bottom by [footShade].
  void box(
    Vector3 min,
    Vector3 max,
    Color side, {
    Color? top,
    double footShade = 0.75,
    bool bottom = false,
    double emissive = 0,
  }) {
    final x0 = min.x;
    final y0 = min.y;
    final z0 = min.z;
    final x1 = max.x;
    final y1 = max.y;
    final z1 = max.z;
    final low = [footShade, footShade, 1.0, 1.0];
    quad(
      Vector3(x0, y0, z1),
      Vector3(x1, y0, z1),
      Vector3(x1, y1, z1),
      Vector3(x0, y1, z1),
      top ?? side,
      emissive: emissive,
    );
    quad(
      Vector3(x0, y0, z0),
      Vector3(x1, y0, z0),
      Vector3(x1, y0, z1),
      Vector3(x0, y0, z1),
      side,
      occlusion: low,
      emissive: emissive,
    );
    quad(
      Vector3(x1, y0, z0),
      Vector3(x1, y1, z0),
      Vector3(x1, y1, z1),
      Vector3(x1, y0, z1),
      side,
      occlusion: low,
      emissive: emissive,
    );
    quad(
      Vector3(x1, y1, z0),
      Vector3(x0, y1, z0),
      Vector3(x0, y1, z1),
      Vector3(x1, y1, z1),
      side,
      occlusion: low,
      emissive: emissive,
    );
    quad(
      Vector3(x0, y1, z0),
      Vector3(x0, y0, z0),
      Vector3(x0, y0, z1),
      Vector3(x0, y1, z1),
      side,
      occlusion: low,
      emissive: emissive,
    );
    if (bottom) {
      quad(
        Vector3(x0, y1, z0),
        Vector3(x1, y1, z0),
        Vector3(x1, y0, z0),
        Vector3(x0, y0, z0),
        side,
        emissive: emissive,
      );
    }
  }

  /// Adds a box from [min] to [max] whose top edges are chamfered by
  /// [bevel]: a slab or a coping stone.
  void bevelledBox(
    Vector3 min,
    Vector3 max,
    double bevel,
    Color side, {
    required Color top,
    Color? edge,
    double footShade = 0.8,
  }) {
    final x0 = min.x;
    final y0 = min.y;
    final z0 = min.z;
    final x1 = max.x;
    final y1 = max.y;
    final z1 = max.z;
    final zb = z1 - bevel;
    final edgeColor = edge ?? top;
    // The top, inset by the bevel.
    quad(
      Vector3(x0 + bevel, y0 + bevel, z1),
      Vector3(x1 - bevel, y0 + bevel, z1),
      Vector3(x1 - bevel, y1 - bevel, z1),
      Vector3(x0 + bevel, y1 - bevel, z1),
      top,
    );
    // The chamfers.
    quad(
      Vector3(x0, y0, zb),
      Vector3(x1, y0, zb),
      Vector3(x1 - bevel, y0 + bevel, z1),
      Vector3(x0 + bevel, y0 + bevel, z1),
      edgeColor,
    );
    quad(
      Vector3(x1, y0, zb),
      Vector3(x1, y1, zb),
      Vector3(x1 - bevel, y1 - bevel, z1),
      Vector3(x1 - bevel, y0 + bevel, z1),
      edgeColor,
    );
    quad(
      Vector3(x1, y1, zb),
      Vector3(x0, y1, zb),
      Vector3(x0 + bevel, y1 - bevel, z1),
      Vector3(x1 - bevel, y1 - bevel, z1),
      edgeColor,
    );
    quad(
      Vector3(x0, y1, zb),
      Vector3(x0, y0, zb),
      Vector3(x0 + bevel, y0 + bevel, z1),
      Vector3(x0 + bevel, y1 - bevel, z1),
      edgeColor,
    );
    final low = [footShade, footShade, 1.0, 1.0];
    quad(
      Vector3(x0, y0, z0),
      Vector3(x1, y0, z0),
      Vector3(x1, y0, zb),
      Vector3(x0, y0, zb),
      side,
      occlusion: low,
    );
    quad(
      Vector3(x1, y0, z0),
      Vector3(x1, y1, z0),
      Vector3(x1, y1, zb),
      Vector3(x1, y0, zb),
      side,
      occlusion: low,
    );
    quad(
      Vector3(x1, y1, z0),
      Vector3(x0, y1, z0),
      Vector3(x0, y1, zb),
      Vector3(x1, y1, zb),
      side,
      occlusion: low,
    );
    quad(
      Vector3(x0, y1, z0),
      Vector3(x0, y0, z0),
      Vector3(x0, y0, zb),
      Vector3(x0, y1, zb),
      side,
      occlusion: low,
    );
  }

  /// Adds an upright prism of [sides] sides around [center] (its bottom),
  /// [radius] wide and [height] tall, with a top of [top] color, whose top
  /// edge is chamfered by [bevel].
  void prism(
    Vector3 center,
    double radius,
    double height,
    Color side, {
    required Color top,
    int sides = 8,
    double bevel = 0,
    double phase = 0,
    double footShade = 0.7,
  }) {
    Vector3 ring(int i, double r, double z) {
      final a = phase + i * 2 * math.pi / sides;
      return Vector3(
        center.x + math.cos(a) * r,
        center.y + math.sin(a) * r,
        center.z + z,
      );
    }

    final zb = height - bevel;
    final inner = radius - bevel;
    for (var i = 0; i < sides; i++) {
      final j = (i + 1) % sides;
      quad(
        ring(i, radius, 0),
        ring(j, radius, 0),
        ring(j, radius, zb),
        ring(i, radius, zb),
        side,
        occlusion: [footShade, footShade, 1, 1],
      );
      if (bevel > 0) {
        quad(
          ring(i, radius, zb),
          ring(j, radius, zb),
          ring(j, inner, height),
          ring(i, inner, height),
          top,
        );
      }
    }
    final up = Vector3(0, 0, 1);
    final middle = vertex(center + Vector3(0, 0, height), up, top);
    final first = vertex(ring(0, inner, height), up, top);
    for (var i = 1; i < sides; i++) {
      vertex(ring(i, inner, height), up, top);
    }
    for (var i = 0; i < sides; i++) {
      triangle(middle, first + i, first + (i + 1) % sides);
    }
  }

  /// Adds a height field over `[x0, x1] × [y0, y1]`, [columns] by [rows]
  /// cells, at the heights [height] gives, colored by [color].
  void heightField(
    double x0,
    double x1,
    double y0,
    double y1,
    int columns,
    int rows, {
    required double Function(double x, double y) height,
    required Color Function(double x, double y) color,
    double Function(double x, double y)? occlusion,
  }) {
    final first = _vertexCount;
    final dx = (x1 - x0) / columns;
    final dy = (y1 - y0) / rows;
    for (var j = 0; j <= rows; j++) {
      for (var i = 0; i <= columns; i++) {
        final x = x0 + i * dx;
        final y = y0 + j * dy;
        final normal = Vector3(
          height(x - dx * 0.5, y) - height(x + dx * 0.5, y),
          height(x, y - dy * 0.5) - height(x, y + dy * 0.5),
          dx,
        )..normalize();
        vertex(
          Vector3(x, y, height(x, y)),
          normal,
          color(x, y),
          occlusion: occlusion?.call(x, y) ?? 1,
        );
      }
    }
    for (var j = 0; j < rows; j++) {
      for (var i = 0; i < columns; i++) {
        final a = first + j * (columns + 1) + i;
        final b = a + 1;
        final c = a + columns + 2;
        final d = a + columns + 1;
        triangle(a, b, c);
        triangle(a, c, d);
      }
    }
  }

  /// The surface of what was added, drawn with [material].
  Surface build(Material material) {
    return StylizedMaterial.buildSurface(
      positions: _positions,
      normals: _normals,
      colors: _colors,
      occlusion: _occlusion,
      emissive: _emissive,
      gloss: _gloss,
      indices: _indices,
      material: material,
    );
  }

  /// A mesh of what was added, drawn with [material].
  Mesh mesh(Material material) => Mesh()..addSurface(build(material));
}
