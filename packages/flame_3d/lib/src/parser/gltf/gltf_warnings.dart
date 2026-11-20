import 'package:flutter/foundation.dart';

/// Reports what the glTF readers drop or approximate (an attribute they do
/// not read, an unsupported extension, a primitive mode they cannot draw),
/// once per message and only in debug builds.
///
/// Messages go to [debugPrint], or to [onWarning] when set.
abstract final class GltfWarnings._() {
  static final Set<String> _reported = {};

  /// Receives the messages instead of [debugPrint] when set.
  static void Function(String message)? onWarning;

  /// Reports [message] once, in debug builds only.
  static void report(String message) {
    assert(() {
      if (_reported.add(message)) {
        (onWarning ?? debugPrint)('flame_3d glTF: $message');
      }
      return true;
    }(), 'unreachable');
  }

  /// Forgets the messages already reported, so they are reported again.
  @visibleForTesting
  static void reset() => _reported.clear();
}

/// Attributes of a glTF primitive both readers read.
const Set<String> gltfReadAttributes = {
  'POSITION',
  'NORMAL',
  'TEXCOORD_0',
  'COLOR_0',
  'JOINTS_0',
  'WEIGHTS_0',
  'JOINTS_1',
  'WEIGHTS_1',
};

/// Extensions the glTF readers (with `SceneLoader3D`) read.
const Set<String> gltfReadExtensions = {
  'EXT_meshopt_compression',
  'EXT_mesh_gpu_instancing',
  'KHR_lights_punctual',
  'KHR_materials_emissive_strength',
  'KHR_materials_unlit',
  'KHR_mesh_quantization',
  'KHR_texture_transform',
};

/// Whether the glTF readers keep the primitive attribute [name] in
/// `Surface.customAttributes` rather than in the vertex buffer: application
/// attributes (`_NAME`) and the texture coordinates after the first
/// (`TEXCOORD_1` and up), when they are scalars or vectors.
bool gltfKeepsAttribute(String name) =>
    name.startsWith('_') || _extraTexCoord.hasMatch(name);

final RegExp _extraTexCoord = RegExp(r'^TEXCOORD_[1-9][0-9]*$');

/// The components per vertex of a kept attribute whose accessor is of
/// [type] (`SCALAR`, `VEC2`, `VEC3` or `VEC4`), or `0` for matrices, which
/// are not kept.
int gltfKeptComponents(String? type) => switch (type) {
  'SCALAR' => 1,
  'VEC2' => 2,
  'VEC3' => 3,
  'VEC4' => 4,
  _ => 0,
};

/// The message reported for a kept attribute ([gltfKeepsAttribute]) that is
/// dropped because its accessor holds matrices.
String droppedAttributeWarning(String name, String? type) =>
    'primitive attribute $name ($type) is dropped: only scalar and vector '
    'attributes are kept in Surface.customAttributes';

/// The message reported for the primitive attributes in [attributes] that
/// are not read, or `null` when every attribute is read. The attributes kept
/// in `Surface.customAttributes` ([gltfKeepsAttribute]) are not reported.
String? unreadAttributesWarning(Iterable<String> attributes) {
  final unread = [
    for (final name in attributes)
      if (!gltfReadAttributes.contains(name) && !gltfKeepsAttribute(name)) name,
  ]..sort();
  if (unread.isEmpty) {
    return null;
  }
  final hint = unread.contains('TANGENT')
      ? ' (call Surface.computeTangents() for tangents)'
      : '';
  return 'primitive attributes ${unread.join(', ')} are not read$hint';
}

/// The message reported for the extensions of [extensionsUsed] that are not
/// read, or `null`.
String? unreadExtensionsWarning(Iterable<String> extensionsUsed) {
  final unread = [
    for (final name in extensionsUsed)
      if (!gltfReadExtensions.contains(name)) name,
  ]..sort();
  if (unread.isEmpty) {
    return null;
  }
  return 'extensions ${unread.join(', ')} are not supported and are ignored';
}

/// Converts the indices of a glTF primitive of mode [mode] (`4` triangles,
/// `5` triangle strip, `6` triangle fan) to a triangle list, following the
/// glTF specification and dropping the degenerate triangles strips use as
/// restarts; returns `null` for points and lines.
List<int>? gltfTriangleList(int mode, List<int> indices) {
  switch (mode) {
    case 4:
      return indices;
    case 5:
      final out = <int>[];
      for (var i = 0; i + 2 < indices.length; i++) {
        final a = indices[i];
        final b = indices[i + 1 + i % 2];
        final c = indices[i + 2 - i % 2];
        if (a != b && b != c && a != c) {
          out
            ..add(a)
            ..add(b)
            ..add(c);
        }
      }
      return out;
    case 6:
      final out = <int>[];
      for (var i = 0; i + 2 < indices.length; i++) {
        out
          ..add(indices[i + 1])
          ..add(indices[i + 2])
          ..add(indices[0]);
      }
      return out;
    default:
      return null;
  }
}

/// Reduces the joint influences of [vertexCount] vertices to the 4 largest
/// and renormalizes their weights to a sum of 1 (vertices whose weights are
/// all zero stay unskinned).
///
/// [joints0] and [weights0] hold 4 values per vertex and are updated in
/// place; [joints1] and [weights1], when given, hold the influences 5 to 8.
/// Returns `true` when some vertex lost a non-zero influence.
bool reduceJointInfluences(
  List<double> joints0,
  List<double> weights0,
  List<double>? joints1,
  List<double>? weights1,
  int vertexCount,
) {
  final hasSecond =
      joints1 != null &&
      weights1 != null &&
      joints1.length >= vertexCount * 4 &&
      weights1.length >= vertexCount * 4;
  final joints = Float64List(8);
  final weights = Float64List(8);
  var dropped = false;
  for (var v = 0; v < vertexCount; v++) {
    final o = v * 4;
    var n = 0;
    for (var k = 0; k < 4; k++) {
      joints[n] = joints0[o + k];
      weights[n] = weights0[o + k];
      n++;
    }
    if (hasSecond) {
      for (var k = 0; k < 4; k++) {
        joints[n] = joints1[o + k];
        weights[n] = weights1[o + k];
        n++;
      }
      // Partial selection sort: the 4 largest weights first.
      for (var i = 0; i < 4; i++) {
        var best = i;
        for (var j = i + 1; j < n; j++) {
          if (weights[j] > weights[best]) {
            best = j;
          }
        }
        if (best != i) {
          final w = weights[i];
          weights[i] = weights[best];
          weights[best] = w;
          final jt = joints[i];
          joints[i] = joints[best];
          joints[best] = jt;
        }
      }
      for (var k = 4; k < n; k++) {
        if (weights[k] > 0.0) {
          dropped = true;
        }
      }
    }
    var sum = 0.0;
    for (var k = 0; k < 4; k++) {
      sum += weights[k] > 0.0 ? weights[k] : 0.0;
    }
    for (var k = 0; k < 4; k++) {
      final w = weights[k] > 0.0 ? weights[k] : 0.0;
      joints0[o + k] = w > 0.0 ? joints[k] : 0.0;
      weights0[o + k] = sum > 0.0 ? w / sum : 0.0;
    }
  }
  return dropped;
}
