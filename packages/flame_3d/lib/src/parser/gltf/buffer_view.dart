import 'dart:typed_data';

import 'package:flame_3d/src/parser/gltf/buffer.dart';
import 'package:flame_3d/src/parser/gltf/buffer_view_target.dart';
import 'package:flame_3d/src/parser/gltf/gltf_node.dart';
import 'package:flame_3d/src/parser/gltf/gltf_node_with_data.dart';
import 'package:flame_3d/src/parser/gltf/gltf_ref.dart';
import 'package:flame_3d/src/parser/gltf/gltf_root.dart';
import 'package:flame_3d/src/parser/meshopt_decoder_3d.dart';

/// Parsed `EXT_meshopt_compression` payload attached to a glTF [BufferView].
class ExtMeshoptCompression({
  required final GltfRef<Buffer> buffer,
  required final int byteOffset,
  required final int byteLength,
  required final int byteStride,
  required final int count,
  required final MeshoptMode3D mode,
  final MeshoptFilter3D filter = MeshoptFilter3D.none,
}) {
  static ExtMeshoptCompression? maybeParse(
    GltfRoot root,
    Map<String, Object?> map,
  ) {
    final ext = Parser.extensions(map)?['EXT_meshopt_compression'];
    if (ext is! Map<String, Object?>) {
      return null;
    }
    final bufRef = Parser.ref<Buffer>(root, ext, 'buffer');
    if (bufRef == null) {
      return null;
    }
    return ExtMeshoptCompression(
      buffer: bufRef,
      byteOffset: Parser.integer(ext, 'byteOffset') ?? 0,
      byteLength: Parser.integer(ext, 'byteLength')!,
      byteStride: Parser.integer(ext, 'byteStride')!,
      count: Parser.integer(ext, 'count')!,
      mode: MeshoptMode3D.valueOf(Parser.string(ext, 'mode')!),
      filter: MeshoptFilter3D.valueOf(Parser.string(ext, 'filter')),
    );
  }
}

/// A view into a buffer generally representing a subset of the buffer.
class BufferView({
  required super.root,

  /// The reference to the buffer.
  required final GltfRef<Buffer> buffer,

  /// The length of the bufferView in bytes.
  required final int byteLength,

  /// The offset into the buffer in bytes.
  required final int byteOffset,

  /// The stride, in bytes, between vertex attributes.
  ///
  /// When this is not defined, data is tightly packed.
  /// When two or more accessors use the same buffer view, this field **MUST**
  /// be defined.
  required final int? byteStride,

  /// The hint representing the intended GPU buffer type to use with this
  /// buffer view.
  required final BufferViewTarget? target,

  /// Optional `EXT_meshopt_compression` stream descriptor.
  final ExtMeshoptCompression? meshoptCompression,
}) extends GltfNode with GltfNodeWithData<Uint8List> {
  factory BufferView.parse(
    GltfRoot root,
    Map<String, Object?> map,
  ) {
    final meshopt = ExtMeshoptCompression.maybeParse(root, map);
    final bufRef = Parser.ref<Buffer>(root, map, 'buffer') ?? meshopt?.buffer;
    if (bufRef == null) {
      throw const FormatException('BufferView missing buffer reference');
    }
    return BufferView(
      root: root,
      buffer: bufRef,
      byteLength: Parser.integer(map, 'byteLength')!,
      byteOffset: Parser.integer(map, 'byteOffset') ?? 0,
      byteStride: Parser.integer(map, 'byteStride'),
      target: BufferViewTarget.parse(map, 'target'),
      meshoptCompression: meshopt,
    );
  }

  @override
  Future<Uint8List> loadData() async {
    if (meshoptCompression case final meshopt?) {
      final raw = await root.readChunk(meshopt.buffer);
      final compressedSlice = Uint8List.sublistView(
        raw,
        meshopt.byteOffset,
        meshopt.byteOffset + meshopt.byteLength,
      );
      return MeshoptDecoder3D.decodeBufferView(
        compressedSlice,
        count: meshopt.count,
        byteStride: meshopt.byteStride,
        mode: meshopt.mode,
        filter: meshopt.filter,
      );
    }
    return await root.readChunk(buffer);
  }

  Uint8List data() {
    final loaded = getData();
    if (meshoptCompression != null) {
      return loaded;
    }
    return loaded.sublist(
      byteOffset,
      byteOffset + byteLength,
    );
  }
}
