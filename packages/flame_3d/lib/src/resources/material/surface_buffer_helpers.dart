import 'dart:typed_data';

import 'package:meta/meta.dart';

/// Validates that an optional per-vertex attribute array [values] holds
/// `vertexCount * perVertex` floats.
@internal
void checkVertexArrayLength(
  List<double>? values,
  String name,
  int vertexCount,
  int perVertex,
) {
  if (values != null && values.length != vertexCount * perVertex) {
    throw ArgumentError.value(
      values.length,
      name,
      'Must hold $perVertex float(s) for each of the $vertexCount vertices',
    );
  }
}

/// Converts [indices] into a `Uint16List` or `Uint32List` typed index buffer,
/// keeping `0xFFFF` free for primitive restart by promoting to `Uint32List`
/// whenever `vertexCount > 0xFFFF` or any index is `>= 0xFFFF`.
@internal
List<int> packTriangleIndices(List<int> indices, int vertexCount) {
  if (indices is Uint16List || indices is Uint32List) {
    return indices;
  }
  var wide = vertexCount > 0xFFFF;
  for (var i = 0; !wide && i < indices.length; i++) {
    wide = indices[i] >= 0xFFFF;
  }
  return wide ? Uint32List.fromList(indices) : Uint16List.fromList(indices);
}
