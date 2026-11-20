import 'dart:convert';
import 'dart:typed_data';

/// Packs [json] and [bin] into a GLB container.
Uint8List glb(Map<String, Object?> json, Uint8List bin) {
  final jsonBytes = utf8.encode(jsonEncode(json));
  final jsonLength = (jsonBytes.length + 3) & ~3;
  final binLength = (bin.length + 3) & ~3;
  final out = Uint8List(12 + 8 + jsonLength + 8 + binLength);
  final bd = ByteData.sublistView(out);
  out.setRange(0, 4, 'glTF'.codeUnits);
  bd
    ..setUint32(4, 2, Endian.little)
    ..setUint32(8, out.length, Endian.little)
    ..setUint32(12, jsonLength, Endian.little);
  out
    ..setRange(16, 20, 'JSON'.codeUnits)
    ..setRange(20, 20 + jsonBytes.length, jsonBytes)
    ..fillRange(20 + jsonBytes.length, 20 + jsonLength, 0x20);
  final binStart = 20 + jsonLength;
  bd.setUint32(binStart, binLength, Endian.little);
  out
    ..setRange(binStart + 4, binStart + 8, 'BIN\x00'.codeUnits)
    ..setRange(binStart + 8, binStart + 8 + bin.length, bin);
  return out;
}

/// Builds the binary chunk, buffer views, accessors and images of a test
/// GLB file.
class GlbBuilder() {
  final BytesBuilder bytes = BytesBuilder();
  final List<Map<String, Object?>> views = [];
  final List<Map<String, Object?>> accessors = [];

  int _view(Uint8List data) {
    while (bytes.length % 4 != 0) {
      bytes.addByte(0);
    }
    views.add({
      'buffer': 0,
      'byteOffset': bytes.length,
      'byteLength': data.length,
    });
    bytes.add(data);
    return views.length - 1;
  }

  static int _size(String type) => switch (type) {
    'SCALAR' => 1,
    'VEC2' => 2,
    'VEC3' => 3,
    'MAT4' => 16,
    _ => 4,
  };

  int floats(List<double> values, String type) {
    accessors.add({
      'bufferView': _view(Float32List.fromList(values).buffer.asUint8List()),
      'componentType': 5126,
      'count': values.length ~/ _size(type),
      'type': type,
    });
    return accessors.length - 1;
  }

  /// Unsigned bytes, normalized to `[0, 1]` when [normalized].
  int bytesOf(List<int> values, String type, {bool normalized = false}) {
    accessors.add({
      'bufferView': _view(Uint8List.fromList(values)),
      'componentType': 5121,
      'count': values.length ~/ _size(type),
      'type': type,
      if (normalized) 'normalized': true,
    });
    return accessors.length - 1;
  }

  /// An image of [bytes] (a PNG file) in a buffer view: returns its index.
  int image(Uint8List bytes) {
    images.add({'bufferView': _view(bytes), 'mimeType': 'image/png'});
    return images.length - 1;
  }

  /// The images added by [image].
  final List<Map<String, Object?>> images = [];

  int shorts(List<int> values) {
    accessors.add({
      'bufferView': _view(Uint16List.fromList(values).buffer.asUint8List()),
      'componentType': 5123,
      'count': values.length,
      'type': 'SCALAR',
    });
    return accessors.length - 1;
  }

  Uint8List file({
    required List<Map<String, Object?>> nodes,
    required List<Map<String, Object?>> meshes,
    List<Map<String, Object?>> materials = const [],
    List<Map<String, Object?>> skins = const [],
    List<Map<String, Object?>> textures = const [],
  }) {
    return glb({
      'asset': {'version': '2.0'},
      'scene': 0,
      'scenes': [
        {
          'nodes': [for (var i = 0; i < nodes.length; i++) i],
        },
      ],
      'nodes': nodes,
      'meshes': meshes,
      if (materials.isNotEmpty) 'materials': materials,
      if (skins.isNotEmpty) 'skins': skins,
      if (images.isNotEmpty) 'images': images,
      if (textures.isNotEmpty) 'textures': textures,
      'buffers': [
        {'byteLength': bytes.length},
      ],
      'bufferViews': views,
      'accessors': accessors,
    }, bytes.toBytes());
  }
}
