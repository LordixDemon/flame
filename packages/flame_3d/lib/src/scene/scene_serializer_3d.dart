import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Color, FilterQuality;

import 'package:flame/components.dart' show Component;
import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/src/core/crc32.dart';
import 'package:flame_3d/src/scene/prefab_3d.dart';

part 'scene_serializer_binary.dart';
part 'scene_serializer_components.dart';
part 'scene_serializer_materials.dart';
part 'scene_serializer_meshes.dart';

/// Custom component codec registered with [SceneSerializer3D] to serialize and
/// deserialize application-defined [Component] / [Component3D] subclasses.
class SceneNodeCodec3D<T extends Component>({
  required final String typeId,
  required final Map<String, Object?> Function(T component) encode,
  required final T Function(Map<String, Object?> payload) decode,
}) {
  bool _matches(Component component) => component is T;

  Map<String, Object?> _encode(Component component) => encode(component as T);

  Component _decode(Map<String, Object?> payload) => decode(payload);
}

/// One piece of scene content that [SceneSerializer3D] cannot represent, at
/// [path] in the saved scene (for instance `nodes[2].children[0]`).
class SceneSerializationIssue3D({
  /// Where the content is: the node path, followed by the property when the
  /// node itself is saved (`nodes[1].mesh.surfaces[0].material`).
  required final String path,

  /// What cannot be saved, and how to save it instead.
  required final String message,
}) {
  @override
  String toString() => '$path: $message';
}

/// Thrown by [SceneSerializer3D] when a scene holds content it cannot
/// represent and [SceneSerializer3D.allowLossy] is `false`.
class SceneSerializationException3D(
  List<SceneSerializationIssue3D> issues,
) implements Exception {
  /// Every piece of content that cannot be saved.
  final List<SceneSerializationIssue3D> issues = List.unmodifiable(issues);

  @override
  String toString() {
    final buffer = StringBuffer(
      'SceneSerializationException3D: ${issues.length} item(s) of the scene '
      'cannot be saved (register a SceneNodeCodec3D, a mesh or a texture, '
      'or pass allowLossy: true to save without them):',
    );
    for (final issue in issues) {
      buffer.write('\n  - $issue');
    }
    return buffer.toString();
  }
}

/// Versioned human-readable JSON and compact CRC32-verified `'F3DS'` binary
/// serializer for [World3D] scene graphs.
///
/// The built-in node types are [MeshComponent], [LodMeshComponent],
/// [InstancedGroup3D], [LightComponent], [Group3D], [CameraComponent3D],
/// references to [PrefabRegistry3D] prefabs (any component whose `prefabId` is
/// registered) and components of a registered [SceneNodeCodec3D]. Meshes are
/// saved by registered key ([registerMesh]), as a primitive when they are
/// unchanged built-in primitives, or vertex by vertex with their
/// [VertexLayout]; [SpatialMaterial], [UnlitMaterial], [StylizedMaterial] and
/// [ShadowCatcherMaterial] are saved with all their values, their textures by
/// registered key ([registerTexture]). A mesh or material shared by several
/// components is saved once and shared again after loading.
///
/// Anything else (another component or material type, a subclass of a
/// built-in type, an unregistered texture, a `ModelComponent`, a light probe
/// grid, ...) is not representable: the save throws a
/// [SceneSerializationException3D] listing every such item, unless
/// [allowLossy] is `true`.
class SceneSerializer3D({
  final PrefabRegistry3D? prefabRegistry,

  /// Whether a save may leave out what it cannot represent instead of
  /// throwing a [SceneSerializationException3D].
  ///
  /// A lossy save writes an unknown component as a [Group3D] that keeps its
  /// transform, tags and children, a subclass of a built-in type as that
  /// type, an unknown material as a default [SpatialMaterial] and an unknown
  /// light source as an [AmbientLight], drops unregistered textures and other
  /// unrepresentable values, and lists each item in [lastIssues].
  final bool allowLossy = false,
}) {
  /// Current schema version written into JSON and `'F3DS'` binary headers.
  static const int currentSchemaVersion = 2;

  /// The oldest schema version [fromJsonInto] and [decodeBinaryInto] read.
  static const int oldestSupportedSchemaVersion = 1;

  /// Four-byte ASCII magic header (`'F3DS'`) of binary scene snapshots.
  static const List<int> binaryMagic = [0x46, 0x33, 0x44, 0x53];

  final Map<String, Mesh> _meshesByKey = {};
  final Map<Mesh, String> _keysByMesh = {};
  final Map<String, Texture> _texturesByKey = {};
  final Map<Texture, String> _keysByTexture = {};
  final List<SceneNodeCodec3D<Component>> _nodeCodecs = [];
  final Map<String, SceneNodeCodec3D<Component>> _nodeCodecsById = {};

  // State of the save in progress.
  List<SceneSerializationIssue3D> _issues = [];
  final Map<Mesh, int> _meshIds = Map.identity();
  final Map<Material, int> _materialIds = Map.identity();

  // State of the load in progress.
  final Map<int, Mesh> _decodedMeshes = {};
  final Map<int, Material> _decodedMaterials = {};

  /// The content the last save could not represent; empty when it saved
  /// everything. A lossy save (see [allowLossy]) left these items out.
  List<SceneSerializationIssue3D> get lastIssues => List.unmodifiable(_issues);

  /// Registers an asset [mesh] under [key] so [MeshComponent]s sharing it
  /// serialize by key reference rather than duplicating vertex buffers.
  void registerMesh(String key, Mesh mesh) {
    _meshesByKey[key] = mesh;
    _keysByMesh[mesh] = key;
  }

  /// Looks up a previously registered asset [Mesh] by [key].
  Mesh? lookupMesh(String key) => _meshesByKey[key];

  /// Registers a [Texture] under [key] for material texture round-tripping.
  void registerTexture(String key, Texture texture) {
    _texturesByKey[key] = texture;
    _keysByTexture[texture] = key;
  }

  /// Looks up a previously registered [Texture] by [key].
  Texture? lookupTexture(String key) => _texturesByKey[key];

  /// Registers a custom [SceneNodeCodec3D] for user-defined scene components.
  void registerNodeCodec<T extends Component>(SceneNodeCodec3D<T> codec) {
    _nodeCodecs.removeWhere((c) => c.typeId == codec.typeId);
    _nodeCodecs.add(codec);
    _nodeCodecsById[codec.typeId] = codec;
  }

  /// Lists what a save of [world] (and [cameras]) could not represent,
  /// without throwing; an empty list means it saves losslessly.
  List<SceneSerializationIssue3D> findIssues(
    World3D world, {
    List<CameraComponent3D> cameras = const [],
  }) {
    _encodeWorld(world, cameras);
    return lastIssues;
  }

  /// Serializes [world] (and optional detached [cameras]) into a versioned
  /// JSON-compatible map.
  ///
  /// Throws a [SceneSerializationException3D] when the scene holds content
  /// that cannot be represented, unless [allowLossy] is `true`.
  Map<String, Object?> toJson(
    World3D world, {
    List<CameraComponent3D> cameras = const [],
  }) {
    final map = _encodeWorld(world, cameras);
    if (_issues.isNotEmpty && !allowLossy) {
      throw SceneSerializationException3D(_issues);
    }
    return map;
  }

  void _issue(String path, String message) {
    _issues.add(SceneSerializationIssue3D(path: path, message: message));
  }

  /// Encodes [world] as a UTF-8 JSON string.
  ///
  /// Throws a [SceneSerializationException3D] when the scene holds content
  /// that cannot be represented, unless [allowLossy] is `true`.
  String encodeJson(
    World3D world, {
    List<CameraComponent3D> cameras = const [],
    bool pretty = false,
  }) {
    final map = toJson(world, cameras: cameras);
    return pretty
        ? const JsonEncoder.withIndent('  ').convert(map)
        : jsonEncode(map);
  }

  /// Restores [map] into [target], returning any top-level `cameras` stored in
  /// the snapshot.
  ///
  /// The whole snapshot is decoded before [target] is touched: when decoding
  /// fails (a [FormatException] or a [StateError] for a missing prefab, mesh
  /// or codec), [target] is left unchanged.
  List<CameraComponent3D> fromJsonInto(
    Map<String, Object?> map,
    World3D target, {
    bool clearTarget = false,
  }) {
    final version = _asInt(map['schemaVersion']);
    if (version == null ||
        version < oldestSupportedSchemaVersion ||
        version > currentSchemaVersion) {
      throw FormatException('Unsupported scene schemaVersion: $version');
    }

    _decodedMeshes.clear();
    _decodedMaterials.clear();
    final List<CameraComponent3D> decodedCameras;
    final List<Component> nodes;
    final void Function(World3D target)? applyWorld;
    try {
      applyWorld = switch (_asMap(map['world'])) {
        final worldData? => _decodeWorldSettings(worldData),
        null => null,
      };

      decodedCameras = <CameraComponent3D>[];
      if (_asList(map['cameras']) case final camList?) {
        for (final rawCam in camList) {
          if (_asMap(rawCam) case final camMap?) {
            decodedCameras.add(_decodeCameraData(camMap));
          }
        }
      }

      nodes = <Component>[];
      if (_asList(map['nodes']) case final nodeList?) {
        for (final rawNode in nodeList) {
          if (_asMap(rawNode) case final nodeMap?) {
            final comp = _decodeComponent(nodeMap);
            if (comp != null) {
              if (comp is CameraComponent3D) {
                decodedCameras.add(comp);
              }
              nodes.add(comp);
            }
          }
        }
      }
    } finally {
      _decodedMeshes.clear();
      _decodedMaterials.clear();
    }

    if (clearTarget && target.children.isNotEmpty) {
      target.removeAll(List<Component>.of(target.children));
    }
    applyWorld?.call(target);
    nodes.forEach(target.add);
    return decodedCameras;
  }

  /// Parses [json] and decodes the scene into [target].
  List<CameraComponent3D> decodeJsonInto(
    String json,
    World3D target, {
    bool clearTarget = false,
  }) {
    Object? parsed;
    Object? decodeError;
    try {
      parsed = jsonDecode(json);
    } on Object catch (error) {
      decodeError = error;
    }
    if (decodeError != null) {
      throw FormatException('Malformed scene JSON: $decodeError');
    }
    final root = _asMap(parsed);
    if (root == null) {
      throw const FormatException('Scene JSON root must be a JSON object.');
    }
    return fromJsonInto(root, target, clearTarget: clearTarget);
  }

  /// Encodes [world] into a compact binary `Uint8List` prefixed with magic
  /// `'F3DS'`, `uint16` schema version, `uint16` flags, `uint32` payload size,
  /// and IEEE 802.3 `CRC32` checksum.
  ///
  /// Throws a [SceneSerializationException3D] when the scene holds content
  /// that cannot be represented, unless [allowLossy] is `true`.
  Uint8List encodeBinary(
    World3D world, {
    List<CameraComponent3D> cameras = const [],
  }) {
    final root = toJson(world, cameras: cameras);
    final writer = _BinarySceneWriter();
    final payload = writer.encodeRoot(root);

    final totalLength = 16 + payload.length;
    final out = Uint8List(totalLength);
    final header = ByteData.sublistView(out, 0, 16);
    out[0] = binaryMagic[0];
    out[1] = binaryMagic[1];
    out[2] = binaryMagic[2];
    out[3] = binaryMagic[3];
    header
      ..setUint16(4, currentSchemaVersion, Endian.little)
      ..setUint16(6, 0, Endian.little)
      ..setUint32(8, payload.length, Endian.little);
    out.setRange(16, totalLength, payload);

    final crc = computeCrc32(out, skipRangeStart: 12, skipRangeEnd: 16);
    header.setUint32(12, crc, Endian.little);
    return out;
  }

  /// Verifies the `'F3DS'` header, schema version, and `CRC32` integrity of
  /// [bytes], then decodes the scene into [target].
  ///
  /// Throws a [FormatException] if [bytes] is truncated, corrupted, or uses an
  /// unsupported schema version.
  List<CameraComponent3D> decodeBinaryInto(
    Uint8List bytes,
    World3D target, {
    bool clearTarget = false,
  }) {
    if (bytes.length < 16) {
      throw FormatException(
        'Truncated F3DS binary: expected at least 16 bytes, got '
        '${bytes.length}.',
      );
    }
    if (bytes[0] != binaryMagic[0] ||
        bytes[1] != binaryMagic[1] ||
        bytes[2] != binaryMagic[2] ||
        bytes[3] != binaryMagic[3]) {
      throw const FormatException('Invalid F3DS binary magic header.');
    }

    final header = ByteData.sublistView(bytes, 0, 16);
    final version = header.getUint16(4, Endian.little);
    if (version < oldestSupportedSchemaVersion ||
        version > currentSchemaVersion) {
      throw FormatException('Unsupported F3DS binary schemaVersion: $version');
    }

    final payloadLength = header.getUint32(8, Endian.little);
    if (bytes.length != 16 + payloadLength) {
      throw FormatException(
        'F3DS binary payload length mismatch: expected ${16 + payloadLength} '
        'bytes, got ${bytes.length}.',
      );
    }

    final expectedCrc = header.getUint32(12, Endian.little);
    final actualCrc = computeCrc32(
      bytes,
      skipRangeStart: 12,
      skipRangeEnd: 16,
    );
    if (actualCrc != expectedCrc) {
      throw FormatException(
        'F3DS binary CRC32 checksum mismatch: '
        'expected 0x${expectedCrc.toRadixString(16)}, '
        'computed 0x${actualCrc.toRadixString(16)}.',
      );
    }

    final payload = Uint8List.sublistView(bytes, 16, 16 + payloadLength);
    final root = _BinarySceneReader(payload).decodeRoot();
    return fromJsonInto(root, target, clearTarget: clearTarget);
  }

  /// Computes standard IEEE 802.3 `CRC32` over [data], optionally skipping
  /// `[skipRangeStart, skipRangeEnd)` (used for the embedded checksum field).
  static int computeCrc32(
    Uint8List data, {
    int skipRangeStart = -1,
    int skipRangeEnd = -1,
  }) => computeCrc32Bytes(
    data,
    skipRangeStart: skipRangeStart,
    skipRangeEnd: skipRangeEnd,
  );

  // ---------------------------------------------------------------------------
  // Components.

  // ---------------------------------------------------------------------------
  // Meshes.

  // ---------------------------------------------------------------------------
  // Materials.

  /// The registered key of [texture], or `null` when there is no texture
  /// (`null` or [none]); an unregistered texture is an issue.
  String? _textureKey(Texture? texture, String path, {Texture? none}) {
    if (texture == null || identical(texture, none)) {
      return null;
    }
    final key = _keysByTexture[texture];
    if (key == null) {
      _issue(
        path,
        'the texture is not registered (see registerTexture): a lossy save '
        'leaves it out',
      );
    }
    return key;
  }

  // ---------------------------------------------------------------------------
  // Lights.

  // ---------------------------------------------------------------------------
  // Cameras and world settings.

  // ---------------------------------------------------------------------------
  // Values.
}
