import 'dart:typed_data';

import 'package:flame_3d/src/parser/gltf/gltf_node.dart';

/// Specifies if the accessor's elements are scalars, vectors, or matrices.
enum AccessorType(final String name, final int size) {
  scalar('SCALAR', 1),
  vec2('VEC2', 2),
  vec3('VEC3', 3),
  vec4('VEC4', 4),
  mat2('MAT2', 4),
  mat3('MAT3', 9),
  mat4('MAT4', 16);

  static AccessorType valueOf(String name) {
    return values.firstWhere((e) => e.name == name);
  }

  static AccessorType? parse(Map<String, Object?> map, String key) {
    return Parser.stringEnum(map, key, valueOf);
  }
}

/// The material's alpha rendering mode enumeration specifying the
/// interpretation of the alpha value of the base color.
enum AlphaMode(final String value) {
  /// The alpha value is ignored, and the rendered output is fully opaque.
  opaque('OPAQUE'),

  /// The rendered output is either fully opaque or fully transparent depending
  /// on the alpha value and the specified `alphaCutoff` value;
  /// the exact appearance of the edges **MAY** be subject to
  /// implementation-specific techniques such as "Alpha-to-Coverage"
  mask('MASK'),

  /// The alpha value is used to composite the source and destination areas.
  /// The rendered output is combined with the background using the normal
  /// painting operation (i.e. the Porter and Duff over operator).
  blend('BLEND');

  static AlphaMode valueOf(String value) {
    return values.firstWhere((e) => e.value == value);
  }

  static AlphaMode? parse(Map<String, Object?> map, String key) {
    return Parser.stringEnum(map, key, valueOf);
  }
}

/// The name of the node's TRS property to modify.
enum AnimationPath(final String value) {
  translation('translation'),
  rotation('rotation'),
  scale('scale'),
  weights('weights');

  static AnimationPath valueOf(String value) {
    return values.firstWhere((e) => e.value == value);
  }

  /// The path named [value], or `null` when it is missing or not one of the
  /// node paths of glTF 2.0.
  static AnimationPath? tryParse(String? value) {
    for (final path in values) {
      if (path.value == value) {
        return path;
      }
    }
    return null;
  }

  static AnimationPath? parse(Map<String, Object?> map, String key) {
    return Parser.stringEnum(map, key, valueOf);
  }
}

/// The target that the WebGL buffer should be bound to.
enum BufferViewTarget(final int value) {
  arrayBuffer(34962),
  elementArrayBuffer(34963);

  static BufferViewTarget valueOf(int value) {
    return values.firstWhere((e) => e.value == value);
  }

  static BufferViewTarget? parse(Map<String, Object?> map, String key) {
    return Parser.integerEnum(map, key, valueOf);
  }
}

/// Specifies if the camera uses a perspective or orthographic projection.
enum CameraType() {
  perspective,
  orthographic;

  static CameraType valueOf(String value) {
    return values.firstWhere((e) => e.name == value);
  }

  static CameraType? parse(Map<String, Object?> map, String key) {
    return Parser.stringEnum(map, key, valueOf);
  }
}

/// The datatype of the accessor's components.
enum ComponentType({
  required final int value,
  required final int byteSize,
}) {
  byte(value: 5120, byteSize: 1),
  unsignedByte(value: 5121, byteSize: 1),
  short(value: 5122, byteSize: 2),
  unsignedShort(value: 5123, byteSize: 2),
  unsignedInt(value: 5125, byteSize: 4),
  float(value: 5126, byteSize: 4);

  num parseData(ByteData byteData, {int cursor = 0}) {
    return switch (this) {
      ComponentType.byte => byteData.getInt8(cursor),
      ComponentType.unsignedByte => byteData.getUint8(cursor),
      ComponentType.short => byteData.getInt16(cursor, Endian.little),
      ComponentType.unsignedShort => byteData.getUint16(cursor, Endian.little),
      ComponentType.unsignedInt => byteData.getUint32(cursor, Endian.little),
      ComponentType.float => byteData.getFloat32(cursor, Endian.little),
    };
  }

  static ComponentType valueOf(int value) {
    return values.firstWhere((e) => e.value == value);
  }

  static ComponentType? parse(Map<String, Object?> map, String key) {
    return Parser.integerEnum(map, key, valueOf);
  }
}

/// Magnification filter. Valid values correspond to WebGL enums.
enum MagFilter(final String name, final int value) {
  nearest('NEAREST', 9728),
  linear('LINEAR', 9729);

  static MagFilter valueOf(int value) {
    return values.firstWhere((e) => e.value == value);
  }

  static MagFilter? parse(Map<String, Object?> map, String key) {
    return Parser.integerEnum(map, key, valueOf);
  }
}

enum MimeType(final String value) {
  jpeg('image/jpeg'),
  png('image/png'),
  string('string');

  static MimeType valueOf(String value) {
    return values.firstWhere((e) => e.value == value);
  }

  static MimeType? parse(Map<String, Object?> map, String key) {
    return Parser.stringEnum(map, key, valueOf);
  }
}

/// Minification filter. Valid values correspond to WebGL enums.
enum MinFilter(final String name, final int value) {
  nearest('NEAREST', 9728),
  linear('LINEAR', 9729),
  nearestMipmapNearest('NEAREST_MIPMAP_NEAREST', 9984),
  linearMipmapNearest('LINEAR_MIPMAP_NEAREST', 9985),
  nearestMipmapLinear('NEAREST_MIPMAP_LINEAR', 9986),
  linearMipmapLinear('LINEAR_MIPMAP_LINEAR', 9987);

  static MinFilter valueOf(int value) {
    return values.firstWhere((e) => e.value == value);
  }

  static MinFilter? parse(Map<String, Object?> map, String key) {
    return Parser.integerEnum(map, key, valueOf);
  }
}

/// The topology type of primitives to render.
enum PrimitiveMode(final int value) {
  points(0),
  lines(1),
  lineLoop(2),
  lineStrip(3),
  triangles(4),
  triangleStrip(5),
  triangleFan(6);

  static PrimitiveMode valueOf(int value) {
    return values.firstWhere((e) => e.value == value);
  }

  static PrimitiveMode? parse(Map<String, Object?> map, String key) {
    return Parser.integerEnum(map, key, valueOf);
  }
}

/// Texture formats; values correspond to WebGL enums.
enum TextureFormat(final String name, final int value) {
  alpha('ALPHA', 6406),
  rgb('RGB', 6407),
  rgba('RGBA', 6408),
  luminance('LUMINANCE', 6409),
  luminanceAlpha('LUMINANCE_ALPHA', 6410);

  static TextureFormat valueOf(String name) {
    return values.firstWhere((e) => e.name == name);
  }

  static TextureFormat? parse(Map<String, Object?> map, String key) {
    return Parser.stringEnum(map, key, valueOf);
  }
}

/// Texture targets; values correspond to WebGL enums.
enum TextureTarget(final String name, final int value) {
  texture2d('TEXTURE_2D', 3553);

  static TextureTarget valueOf(String name) {
    return values.firstWhere((e) => e.name == name);
  }

  static TextureTarget? parse(Map<String, Object?> map, String key) {
    return Parser.stringEnum(map, key, valueOf);
  }
}

/// Texture formats; values correspond to WebGL enums.
enum TextureType(final String name, final int value) {
  unsignedByte('UNSIGNED_BYTE', 5121),
  unsignedShort565('UNSIGNED_SHORT_5_6_5', 33635),
  unsignedShort4444('UNSIGNED_SHORT_4_4_4_4', 32819),
  unsignedShort5551('UNSIGNED_SHORT_5_5_5_1', 32820);

  static TextureType valueOf(int value) {
    return values.firstWhere((e) => e.value == value);
  }

  static TextureType? parse(Map<String, Object?> map, String key) {
    return Parser.integerEnum(map, key, valueOf);
  }
}

/// Wrapping mode. Valid values correspond to WebGL enums.
enum WrapMode(final String name, final int value) {
  clampToEdge('CLAMP_TO_EDGE', 33071),
  mirroredRepeat('MIRRORED_REPEAT', 33648),
  repeat('REPEAT', 10497);

  static WrapMode valueOf(int value) {
    return values.firstWhere((e) => e.value == value);
  }

  static WrapMode? parse(Map<String, Object?> map, String key) {
    return Parser.integerEnum(map, key, valueOf);
  }
}
