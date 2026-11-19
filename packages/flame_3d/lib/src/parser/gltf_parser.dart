import 'package:flame/flame.dart';
import 'package:flame_3d/src/model/model.dart';
import 'package:flame_3d/src/parser/gltf/glb_chunk.dart';
import 'package:flame_3d/src/parser/gltf/gltf_root.dart';
import 'package:flame_3d/src/parser/model_parser.dart';

/// Parses GLB and GLTF file formats as per specified by:
/// https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.pdf
class GltfParser() extends ModelParser {
  @override
  Future<Model> parseModel(String filePath) async {
    final root = await parseGltf(filePath);
    return root.toFlameModel();
  }

  /// Parses an in-memory `.gltf` JSON root map into a [Model].
  Future<Model> parseGltfJson(
    Map<String, dynamic> json, {
    String prefix = '',
    List<GlbChunk> chunks = const [],
  }) async {
    final root = await GltfRoot.from(
      prefix: prefix,
      json: json,
      chunks: chunks,
    );
    return root.toFlameModel();
  }

  Future<GltfRoot> parseGltf(String filePath) async {
    final content = await Flame.assets.readJson(filePath);
    return await GltfRoot.from(
      prefix: ModelParser.prefix(filePath),
      json: content,
      chunks: [],
    );
  }
}
