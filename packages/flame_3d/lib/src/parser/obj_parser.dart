import 'dart:ui';

import 'package:flame/flame.dart';
import 'package:flame_3d/game.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/src/model/model.dart';
import 'package:flame_3d/src/parser/model_parser.dart';
import 'package:flame_3d/src/parser/obj/surface_tool.dart';

// These are keywords used in the OBJ syntax.
// cSpell:ignore usemtl newmtl mtllib

/// Reads Wavefront OBJ files: positions, normals, texture coordinates, faces
/// of any number of corners (triangulated as fans, with positive or negative
/// indices) and the diffuse color (`Kd`) of `mtllib` materials, one surface
/// per material.
class ObjParser() extends ModelParser {
  @override
  Future<Model> parseModel(String filePath) async {
    final mesh = await parseMesh(filePath);
    return Model.simple(mesh: mesh);
  }

  /// Reads the OBJ file at [filePath] (a full asset path) into a [Mesh]
  /// (or adds its surfaces to [applyTo]). Material libraries are read next to
  /// the file.
  Future<Mesh> parseMesh(String filePath, {Mesh? applyTo}) async {
    final source = await Flame.assets.readFile(filePath);
    return await parseObjString(
      source,
      directory: ModelParser.prefix(filePath),
      applyTo: applyTo,
    );
  }

  /// Builds a [Mesh] from the contents of an OBJ file. Material libraries
  /// (`mtllib`) are read through `Flame.assets` from [directory].
  Future<Mesh> parseObjString(
    String source, {
    String directory = '',
    Mesh? applyTo,
  }) async {
    final vertices = <Vector3>[];
    final normals = <Vector3>[];
    final texCoords = <Vector2>[];
    final faces = <String, List<Face>>{};

    // if not material is specified, this will be used, and the default
    // material will be applied.
    var matName = '__default__';

    final materials = <String, SpatialMaterial>{};
    for (final rawLine in source.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) {
        continue;
      }
      final [type, ...parts] = line.split(_whitespace);

      switch (type) {
        // Vertex (a fourth `w` or vertex colors are ignored)
        case 'v':
          vertices.add(_vector3(parts, line));
        // Normal
        case 'vn':
          normals.add(_vector3(parts, line));
        // UV (a third `w` is ignored)
        case 'vt':
          if (parts.isEmpty) {
            throw FormatException('Malformed OBJ texture coordinate: $line');
          }
          texCoords.add(
            Vector2(
              double.parse(parts[0]),
              parts.length > 1 ? double.parse(parts[1]) : 0.0,
            ),
          );
        // Face, with any number of corners
        case 'f':
          if (parts.length < 3) {
            continue;
          }
          final face = Face.empty();
          for (final value in parts) {
            // format is v, v/vt, v/vt/vn or v//vn; negative indices count
            // back from the last element read so far
            final indices = value.split('/');
            face.vertex.add(_index(indices[0], vertices.length, line));
            if (indices.length > 1 && indices[1].isNotEmpty) {
              face.texCoord.add(_index(indices[1], texCoords.length, line));
            }
            if (indices.length > 2 && indices[2].isNotEmpty) {
              face.normal.add(_index(indices[2], normals.length, line));
            }
          }
          (faces[matName] ??= []).add(face);
        // Material library
        case 'mtllib':
          final library = parts.join(' ');
          materials.addAll(await _parseMaterial('$directory$library'));
        // Material
        case 'usemtl':
          matName = parts.join(' ');

          if (!faces.containsKey(matName)) {
            if (!materials.containsKey(matName)) {
              throw AssertionError('Material not found: $matName');
            }
            faces[matName] = [];
          }
      }
    }

    var mesh = applyTo ?? Mesh();
    for (final materialGroup in faces.keys) {
      final groupFaces = faces[materialGroup]!;
      if (groupFaces.isEmpty) {
        continue;
      }
      final material = materials[materialGroup] ?? Material.defaultMaterial;
      final surface = SurfaceTool()..setMaterial(material);

      for (final face in groupFaces) {
        final corners = face.vertex.length;
        final hasTexCoords = face.texCoord.length == corners;
        final hasNormals = face.normal.length == corners;
        // Fan triangulation: (0, i, i + 1).
        for (var i = 1; i < corners - 1; i++) {
          final order = [0, i, i + 1];
          surface.addTriangleFan(
            [for (final k in order) vertices[face.vertex[k]]],
            [
              if (hasTexCoords)
                for (final k in order) texCoords[face.texCoord[k]],
            ],
            [
              if (hasNormals)
                for (final k in order) normals[face.normal[k]],
            ],
          );
        }
      }
      mesh = surface.apply(mesh);
    }
    return mesh;
  }

  static final RegExp _whitespace = RegExp(r'\s+');

  static Vector3 _vector3(List<String> parts, String line) {
    if (parts.length < 3) {
      throw FormatException('Malformed OBJ vector: $line');
    }
    return Vector3(
      double.parse(parts[0]),
      double.parse(parts[1]),
      double.parse(parts[2]),
    );
  }

  /// Converts a 1-based (or negative, relative) OBJ index to a 0-based one.
  static int _index(String token, int count, String line) {
    final raw = int.parse(token);
    final index = raw < 0 ? count + raw : raw - 1;
    if (index < 0 || index >= count) {
      throw FormatException('OBJ index $raw out of range: $line');
    }
    return index;
  }

  Future<Map<String, SpatialMaterial>> _parseMaterial(
    String filePath,
  ) async {
    final lines = (await Flame.assets.readFile(filePath)).split('\n');

    final materials = <String, SpatialMaterial>{};
    SpatialMaterial? currentMat;
    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty) {
        continue;
      }
      final [type, ...parts] = line.split(_whitespace);
      switch (type) {
        // Comment
        case '#':
          continue;
        // Creating a new material
        case 'newmtl':
          currentMat = SpatialMaterial(
            albedoTexture: ColorTexture(const Color(0xFFFFFFFF)),
          );
          materials[parts.join(' ')] = currentMat;
        // Diffuse color
        case 'Kd':
          currentMat?.albedoColor = Color.from(
            alpha: 1.0,
            red: double.parse(parts[0]),
            green: double.parse(parts[1]),
            blue: double.parse(parts[2]),
          );
      }
    }
    return materials;
  }
}

class Face {
  const Face(this.vertex, this.texCoord, this.normal);

  final List<int> vertex;
  final List<int> texCoord;
  final List<int> normal;

  Face.empty() : vertex = [], texCoord = [], normal = [];
}
