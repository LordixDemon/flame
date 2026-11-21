import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Color, FilterQuality;

import 'package:flame/components.dart' show Component;
import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/game.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/src/scene/prefab_3d.dart';

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

  Map<String, Object?> _encodeWorld(
    World3D world,
    List<CameraComponent3D> cameras,
  ) {
    _issues = [];
    _meshIds.clear();
    _materialIds.clear();
    try {
      final nodes = <Map<String, Object?>>[];
      var index = 0;
      for (final child in world.children) {
        final encoded = _encodeComponent(child, 'nodes[${index++}]');
        if (encoded != null) {
          nodes.add(encoded);
        }
      }
      if (world.lightProbeGrid != null) {
        _issue('world.lightProbeGrid', 'light probe grids are not saved');
      }
      if (world.customPasses.isNotEmpty) {
        _issue('world.customPasses', 'custom render passes are not saved');
      }
      if (world.shadowGroup != null) {
        _issue('world.shadowGroup', 'shadow groups are not saved');
      }
      return <String, Object?>{
        'format': 'F3DS',
        'schemaVersion': currentSchemaVersion,
        'world': <String, Object?>{
          'renderScale': world.renderScale,
          'spatialIndex3DEnabled': world.spatialIndex3DEnabled,
          'prioritizeNearestLights': world.prioritizeNearestLights,
          'depthPrepassEnabled': world.depthPrepassEnabled,
          'hdrEnabled': world.hdrEnabled,
          'oitMode': world.oitMode.name,
          'grabSceneColorEnabled': world.grabSceneColorEnabled,
          'renderDebugMode3D': world.renderDebugMode3D.name,
          'scaledFilterQuality': world.scaledFilterQuality.name,
          if (world.lightGrid case final grid?)
            'lightGrid': _encodeLightGrid(grid),
          if (world.fog case final fog?) 'fog': _encodeFog(fog),
          if (world.bloom case final bloom?) 'bloom': _encodeBloom(bloom),
          if (world.postProcess case final post?)
            'postProcess': _encodePostProcess(post),
        },
        if (cameras.isNotEmpty)
          'cameras': [
            for (var i = 0; i < cameras.length; i++)
              _encodeCamera(cameras[i], 'cameras[$i]'),
          ],
        'nodes': nodes,
      };
    } finally {
      _meshIds.clear();
      _materialIds.clear();
    }
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

  void Function(World3D target) _decodeWorldSettings(
    Map<String, Object?> worldData,
  ) {
    final scale = _asDouble(worldData['renderScale']);
    final spatialIndex = worldData['spatialIndex3DEnabled'];
    final nearestLights = worldData['prioritizeNearestLights'];
    final depthPrepass = worldData['depthPrepassEnabled'];
    final hdr = worldData['hdrEnabled'];
    final oit = _enumByName(OitMode3D.values, worldData['oitMode']);
    final grab = worldData['grabSceneColorEnabled'];
    final debugMode = _enumByName(
      RenderDebugMode3D.values,
      worldData['renderDebugMode3D'],
    );
    final filter = _enumByName(
      FilterQuality.values,
      worldData['scaledFilterQuality'],
    );
    final lightGrid = switch (_asMap(worldData['lightGrid'])) {
      final g? => _decodeLightGrid(g),
      null => null,
    };
    final fog = switch (_asMap(worldData['fog'])) {
      final f? => _decodeFog(f),
      null => null,
    };
    final bloom = switch (_asMap(worldData['bloom'])) {
      final b? => _decodeBloom(b),
      null => null,
    };
    final post = switch (_asMap(worldData['postProcess'])) {
      final p? => _decodePostProcess(p),
      null => null,
    };
    return (target) {
      if (scale != null && scale > 0) {
        target.renderScale = scale;
      }
      if (spatialIndex case final bool b) {
        target.spatialIndex3DEnabled = b;
      }
      if (nearestLights case final bool b) {
        target.prioritizeNearestLights = b;
      }
      if (depthPrepass case final bool b) {
        target.depthPrepassEnabled = b;
      }
      if (hdr case final bool b) {
        target.hdrEnabled = b;
      }
      if (oit != null) {
        target.oitMode = oit;
      }
      if (grab case final bool b) {
        target.grabSceneColorEnabled = b;
      }
      if (debugMode != null) {
        target.renderDebugMode3D = debugMode;
      }
      if (filter != null) {
        target.scaledFilterQuality = filter;
      }
      target
        ..lightGrid = lightGrid
        ..fog = fog
        ..bloom = bloom
        ..postProcess = post;
    };
  }

  static Map<String, Object?> _encodeLightGrid(LightGridSettings grid) => {
    'cellSize': ?grid.cellSize,
    'maxCells': grid.maxCells,
    'maxLights': grid.maxLights,
    'maxPointLightsPerCell': grid.maxPointLightsPerCell,
    'maxSpotLightsPerCell': grid.maxSpotLightsPerCell,
    'beyondLimitsOnly': grid.beyondLimitsOnly,
  };

  static LightGridSettings _decodeLightGrid(Map<String, Object?> data) {
    const defaults = LightGridSettings();
    final size = _asDouble(data['cellSize']);
    return LightGridSettings(
      cellSize: size != null && size > 0 ? size : null,
      maxCells: (_asInt(data['maxCells']) ?? defaults.maxCells).clamp(
        1,
        65536,
      ),
      maxLights: (_asInt(data['maxLights']) ?? defaults.maxLights).clamp(
        1,
        16384,
      ),
      maxPointLightsPerCell:
          (_asInt(data['maxPointLightsPerCell']) ??
                  defaults.maxPointLightsPerCell)
              .clamp(1, LightGridSettings.maxPointLightsPerCellLimit),
      maxSpotLightsPerCell:
          (_asInt(data['maxSpotLightsPerCell']) ??
                  defaults.maxSpotLightsPerCell)
              .clamp(1, LightGridSettings.maxSpotLightsPerCellLimit),
      beyondLimitsOnly: data['beyondLimitsOnly'] != false,
    );
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
  }) {
    final table = _crc32Table;
    var crc = 0xFFFFFFFF;
    for (var i = 0; i < data.length; i++) {
      if (i >= skipRangeStart && i < skipRangeEnd) {
        continue;
      }
      final idx = (crc ^ data[i]) & 0xFF;
      crc = (crc >>> 8) ^ table[idx];
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }

  static final Uint32List _crc32Table = _buildCrc32Table();

  static Uint32List _buildCrc32Table() {
    final table = Uint32List(256);
    for (var i = 0; i < 256; i++) {
      var c = i;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
      }
      table[i] = c;
    }
    return table;
  }

  // ---------------------------------------------------------------------------
  // Components.

  Map<String, Object?>? _encodeComponent(Component component, String path) {
    for (final codec in _nodeCodecs) {
      if (codec._matches(component)) {
        final node = <String, Object?>{
          'type': 'custom',
          'codec': codec.typeId,
          'payload': codec._encode(component),
        };
        if (component is Component3D) {
          _writeCommonComponent3D(node, component, path, includeChildren: true);
        }
        return node;
      }
    }

    if (component is CameraComponent3D) {
      return <String, Object?>{
        'type': 'camera',
        ..._encodeCamera(component, path),
      };
    }

    if (component is! Component3D) {
      _issue(
        path,
        '${component.runtimeType} is not a Component3D and has no '
        'SceneNodeCodec3D: not saved',
      );
      return null;
    }

    final pid = component.prefabId;
    if (pid != null && (prefabRegistry?.contains(pid) ?? false)) {
      final node = <String, Object?>{
        'type': 'prefab',
        'prefabId': pid,
      };
      _writeCommonComponent3D(node, component, path, includeChildren: false);
      if (component is MeshComponent) {
        node['color'] = _encodeColor(component.color);
      } else if (component is LodMeshComponent) {
        node['color'] = _encodeColor(component.color);
      }
      return node;
    }

    final Map<String, Object?> node;
    switch (component) {
      case final MeshComponent meshComp:
        _checkExactType(component, MeshComponent, 'MeshComponent', path);
        if (meshComp.jointTransforms != null) {
          _issue(
            '$path.jointTransforms',
            'joint matrices are not saved: the mesh loads in its rest pose',
          );
        }
        node = <String, Object?>{
          'type': 'mesh',
          'castsShadows': meshComp.castsShadows,
          'color': _encodeColor(meshComp.color),
          'instanceData': _encodeVec4(meshComp.instanceData),
          'mesh': _encodeMesh(meshComp.mesh, '$path.mesh'),
        };
      case final LodMeshComponent lod:
        _checkExactType(component, LodMeshComponent, 'LodMeshComponent', path);
        node = <String, Object?>{
          'type': 'lod',
          'castsShadows': lod.castsShadows,
          'color': _encodeColor(lod.color),
          'instanceData': _encodeVec4(lod.instanceData),
          'lowestLodInShadowPass': lod.lowestLodInShadowPass,
          'levels': [
            for (var i = 0; i < lod.levels.length; i++)
              <String, Object?>{
                'mesh': _encodeMesh(lod.levels[i].mesh, '$path.levels[$i]'),
                if (lod.levels[i].maxDistance.isFinite)
                  'maxDistance': lod.levels[i].maxDistance,
                'minScreenHeightRatio': lod.levels[i].minScreenHeightRatio,
              },
          ],
          if (lod.shadowMesh case final shadowMesh?)
            'shadowMesh': _encodeMesh(shadowMesh, '$path.shadowMesh'),
        };
      case final InstancedGroup3D group:
        _checkExactType(component, InstancedGroup3D, 'InstancedGroup3D', path);
        node = <String, Object?>{
          'type': 'instanced',
          'castsShadows': group.castsShadows,
          'mesh': _encodeMesh(group.mesh, '$path.mesh'),
          'instances': _encodeInstances(group),
        };
      case final LightComponent lightComp:
        _checkExactType(component, LightComponent, 'LightComponent', path);
        node = <String, Object?>{
          'type': 'light',
          'lightMask': lightComp.lightMask,
          'source': _encodeLightSource(lightComp.source, '$path.source'),
        };
      case _:
        if (component.runtimeType != Group3D) {
          _issue(
            path,
            '${component.runtimeType} has no built-in encoding and no '
            'SceneNodeCodec3D (register one, or give it the prefabId of a '
            'registered prefab); a lossy save keeps only its transform, tags '
            'and children, as a Group3D',
          );
        }
        node = <String, Object?>{'type': 'group'};
    }
    _writeCommonComponent3D(node, component, path, includeChildren: true);
    return node;
  }

  void _checkExactType(
    Component component,
    Type type,
    String typeName,
    String path,
  ) {
    if (component.runtimeType != type) {
      _issue(
        path,
        '${component.runtimeType} is a subclass of $typeName and has no '
        'SceneNodeCodec3D: a lossy save saves it as a plain $typeName',
      );
    }
  }

  static List<double> _encodeInstances(InstancedGroup3D group) {
    const stride = VertexLayout.instanceStrideInFloats;
    final out = List<double>.filled(group.length * stride, 0);
    final matrix = Matrix4.zero();
    final data = Vector4.zero();
    for (var i = 0; i < group.length; i++) {
      final base = i * stride;
      group.instanceTransform(i, out: matrix);
      for (var k = 0; k < 16; k++) {
        out[base + k] = matrix.storage[k];
      }
      final color = group.instanceColor(i);
      out[base + 16] = color.r;
      out[base + 17] = color.g;
      out[base + 18] = color.b;
      out[base + 19] = color.a;
      group.instanceDataAt(i, out: data);
      out[base + 20] = data.x;
      out[base + 21] = data.y;
      out[base + 22] = data.z;
      out[base + 23] = data.w;
    }
    return out;
  }

  void _writeCommonComponent3D(
    Map<String, Object?> out,
    Component3D component,
    String path, {
    required bool includeChildren,
  }) {
    out['position'] = _encodeVec3(component.position);
    out['rotation'] = _encodeQuat(component.rotation);
    out['scale'] = _encodeVec3(component.scale);
    out['visible'] = component.visible;
    out['cameraMask'] = component.cameraMask;
    out['priority'] = component.priority;
    if (component.prefabId case final pid?) {
      out['prefabId'] = pid;
    }
    if (component.tags3D.isNotEmpty) {
      out['tags3D'] = List<String>.of(component.tags3D);
    }
    if (includeChildren && component.hasChildren) {
      final encodedChildren = <Map<String, Object?>>[];
      var index = 0;
      for (final child in component.children) {
        final childData = _encodeComponent(
          child,
          '$path.children[${index++}]',
        );
        if (childData != null) {
          encodedChildren.add(childData);
        }
      }
      if (encodedChildren.isNotEmpty) {
        out['children'] = encodedChildren;
      }
    }
  }

  Component? _decodeComponent(Map<String, Object?> data) {
    final type = data['type'];
    if (type is! String) {
      throw const FormatException('Scene node missing string "type" field.');
    }

    switch (type) {
      case 'custom':
        final codecId = data['codec'];
        if (codecId is! String) {
          throw const FormatException('Custom scene node missing "codec" id.');
        }
        final codec = _nodeCodecsById[codecId];
        if (codec == null) {
          throw StateError('Unregistered SceneNodeCodec3D "$codecId".');
        }
        final payload = _asMap(data['payload']) ?? const <String, Object?>{};
        final comp = codec._decode(payload);
        if (comp is Component3D) {
          _applyCommonComponent3D(comp, data, includeChildren: true);
        }
        return comp;

      case 'camera':
        return _decodeCameraData(data);

      case 'prefab':
        final pid = data['prefabId'];
        if (pid is! String) {
          throw const FormatException('Prefab node missing "prefabId".');
        }
        final registry = prefabRegistry;
        if (registry == null || !registry.contains(pid)) {
          throw StateError('PrefabRegistry3D missing prefab "$pid".');
        }
        final tagsList = _asStringList(data['tags3D']);
        final overrides = PrefabOverrides3D(
          position: _decodeVec3OrNull(data['position']),
          rotation: _decodeQuatOrNull(data['rotation']),
          scale: _decodeVec3OrNull(data['scale']),
          color: _decodeColorOrNull(data['color']),
          visible: data['visible'] is bool ? data['visible']! as bool : null,
          cameraMask: _asInt(data['cameraMask']),
          tags: tagsList == null ? null : Set<String>.of(tagsList),
          replaceTags: tagsList != null,
        );
        final instance = registry.instantiate(pid, overrides);
        if (_asInt(data['priority']) case final prio?) {
          instance.priority = prio;
        }
        return instance;

      case 'mesh':
        final meshData = _asMap(data['mesh']);
        if (meshData == null) {
          throw const FormatException('Mesh node missing "mesh" descriptor.');
        }
        final mesh = _decodeMesh(meshData);
        final comp = MeshComponent(
          mesh: mesh,
          castsShadows:
              data['castsShadows'] is! bool || (data['castsShadows']! as bool),
          color: _decodeColorOrNull(data['color']) ?? const Color(0xFFFFFFFF),
          instanceData: _decodeVec4OrNull(data['instanceData']),
        );
        _applyCommonComponent3D(comp, data, includeChildren: true);
        return comp;

      case 'lod':
        final rawLevels = _asList(data['levels']);
        if (rawLevels == null || rawLevels.isEmpty) {
          throw const FormatException('LOD node missing "levels".');
        }
        final levels = <MeshLodLevel>[];
        for (final rawLevel in rawLevels) {
          final level = _asMap(rawLevel);
          final meshData = level == null ? null : _asMap(level['mesh']);
          if (level == null || meshData == null) {
            throw const FormatException('LOD level missing "mesh".');
          }
          levels.add(
            MeshLodLevel(
              mesh: _decodeMesh(meshData),
              maxDistance: _asDouble(level['maxDistance']) ?? double.infinity,
              minScreenHeightRatio:
                  _asDouble(level['minScreenHeightRatio']) ?? 0,
            ),
          );
        }
        final comp = LodMeshComponent(
          levels: levels,
          shadowMesh: switch (_asMap(data['shadowMesh'])) {
            final m? => _decodeMesh(m),
            null => null,
          },
          lowestLodInShadowPass: data['lowestLodInShadowPass'] == true,
          color: _decodeColorOrNull(data['color']) ?? const Color(0xFFFFFFFF),
          instanceData: _decodeVec4OrNull(data['instanceData']),
          castsShadows:
              data['castsShadows'] is! bool || (data['castsShadows']! as bool),
        );
        _applyCommonComponent3D(comp, data, includeChildren: true);
        return comp;

      case 'instanced':
        final meshData = _asMap(data['mesh']);
        if (meshData == null) {
          throw const FormatException(
            'Instanced node missing "mesh" descriptor.',
          );
        }
        const stride = VertexLayout.instanceStrideInFloats;
        final instances = _asDoubleList(data['instances']) ?? const <double>[];
        if (instances.length % stride != 0) {
          throw const FormatException(
            'Instanced node "instances" must hold 24 floats per instance.',
          );
        }
        final count = instances.length ~/ stride;
        final comp = InstancedGroup3D(
          mesh: _decodeMesh(meshData),
          initialCapacity: math.max(1, count),
          castsShadows:
              data['castsShadows'] is! bool || (data['castsShadows']! as bool),
        );
        final matrix = Matrix4.zero();
        for (var i = 0; i < count; i++) {
          final base = i * stride;
          for (var k = 0; k < 16; k++) {
            matrix.storage[k] = instances[base + k];
          }
          comp.addInstance(
            transform: matrix,
            color: Color.from(
              red: instances[base + 16].clamp(0.0, 1.0),
              green: instances[base + 17].clamp(0.0, 1.0),
              blue: instances[base + 18].clamp(0.0, 1.0),
              alpha: instances[base + 19].clamp(0.0, 1.0),
            ),
            instanceData: Vector4(
              instances[base + 20],
              instances[base + 21],
              instances[base + 22],
              instances[base + 23],
            ),
          );
        }
        _applyCommonComponent3D(comp, data, includeChildren: true);
        return comp;

      case 'light':
        final srcMap = _asMap(data['source']);
        if (srcMap == null) {
          throw const FormatException('Light node missing "source" data.');
        }
        final comp = LightComponent(
          source: _decodeLightSource(srcMap),
          lightMask: _asInt(data['lightMask']) ?? 0xFFFFFFFF,
        );
        _applyCommonComponent3D(comp, data, includeChildren: true);
        return comp;

      case 'group':
        final comp = Group3D();
        _applyCommonComponent3D(comp, data, includeChildren: true);
        return comp;

      case _:
        throw FormatException('Unknown scene node type "$type".');
    }
  }

  void _applyCommonComponent3D(
    Component3D target,
    Map<String, Object?> data, {
    required bool includeChildren,
  }) {
    if (_decodeVec3OrNull(data['position']) case final pos?) {
      target.position.setFrom(pos);
    }
    if (_decodeQuatOrNull(data['rotation']) case final rot?) {
      target.rotation.setFrom(rot);
    }
    if (_decodeVec3OrNull(data['scale']) case final scl?) {
      target.scale.setFrom(scl);
    }
    if (data['visible'] case final bool vis) {
      target.visible = vis;
    }
    if (_asInt(data['cameraMask']) case final mask?) {
      target.cameraMask = mask;
    }
    if (_asInt(data['priority']) case final prio?) {
      target.priority = prio;
    }
    if (data['prefabId'] case final String pid) {
      target.prefabId = pid;
    }
    if (_asStringList(data['tags3D']) case final tags?) {
      target.clearTags3D();
      for (final tag in tags) {
        target.addTag3D(tag);
      }
    }
    if (includeChildren) {
      if (_asList(data['children']) case final rawChildren?) {
        for (final rawChild in rawChildren) {
          if (_asMap(rawChild) case final childMap?) {
            final child = _decodeComponent(childMap);
            if (child != null) {
              target.add(child);
            }
          }
        }
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Meshes.

  Map<String, Object?> _encodeMesh(Mesh mesh, String path) {
    if (_keysByMesh[mesh] case final assetKey?) {
      return <String, Object?>{
        'kind': 'asset',
        'key': assetKey,
      };
    }
    if (_meshIds[mesh] case final id?) {
      return <String, Object?>{'kind': 'ref', 'id': id};
    }
    final id = _meshIds.length;
    _meshIds[mesh] = id;

    final surfaces = mesh.surfaces.toList(growable: false);
    if (_encodePrimitive(mesh, surfaces) case final primitive?) {
      return <String, Object?>{
        ...primitive,
        'id': id,
        'material': _encodeMaterial(
          surfaces.first.material,
          '$path.surfaces[0].material',
        ),
      };
    }
    return <String, Object?>{
      'kind': 'raw',
      'id': id,
      'surfaces': [
        for (var i = 0; i < surfaces.length; i++)
          _encodeRawSurface(surfaces[i], '$path.surfaces[$i]'),
      ],
    };
  }

  /// The descriptor of [mesh] as a built-in primitive, or `null` when it is
  /// not one or was changed after it was built: the primitive the descriptor
  /// builds must have exactly the same surfaces.
  static Map<String, Object?>? _encodePrimitive(
    Mesh mesh,
    List<Surface> surfaces,
  ) {
    if (surfaces.isEmpty) {
      return null;
    }
    final material = surfaces.first.material;
    for (final surface in surfaces) {
      if (!identical(surface.material, material) ||
          surface.jointMap != null ||
          surface.morphTargets.isNotEmpty) {
        return null;
      }
    }
    for (final (descriptor, build) in _primitiveCandidates(mesh, surfaces)) {
      final candidate = build(material);
      if (_sameGeometry(surfaces, candidate.surfaces.toList())) {
        return descriptor;
      }
    }
    return null;
  }

  static Iterable<(Map<String, Object?>, Mesh Function(Material))>
  _primitiveCandidates(Mesh mesh, List<Surface> surfaces) sync* {
    final vc = surfaces.first.vertexCount;
    final ic = surfaces.first.indexCount;
    switch (mesh) {
      case final CuboidMesh m:
        final size = Vector3.copy(m.size);
        for (final faceNormals in const [true, false]) {
          yield (
            <String, Object?>{
              'kind': 'cuboid',
              'size': _encodeVec3(size),
              'useFaceNormals': faceNormals,
            },
            (mat) => CuboidMesh(
              size: size.clone(),
              material: mat,
              useFaceNormals: faceNormals,
            ),
          );
        }
      case final SphereMesh m:
        final segments = math.sqrt(vc).round() - 1;
        if (segments >= 3) {
          yield (
            <String, Object?>{
              'kind': 'sphere',
              'radius': m.radius,
              'segments': segments,
            },
            (mat) => SphereMesh(
              radius: m.radius,
              segments: segments,
              material: mat,
            ),
          );
        }
      case final CylinderMesh m:
        final total = surfaces.fold(0, (sum, s) => sum + s.vertexCount);
        for (final segments in {(vc - 2) ~/ 2, (total - 6) ~/ 4, vc - 1}) {
          if (segments >= 3) {
            yield (
              <String, Object?>{
                'kind': 'cylinder',
                'radius': m.radius,
                'height': m.height,
                'segments': segments,
              },
              (mat) => CylinderMesh(
                radius: m.radius,
                height: m.height,
                segments: segments,
                material: mat,
              ),
            );
          }
        }
      case final ConeMesh m:
        // The first base vertex is at (radius, 0, 0) and the tip at
        // (0, height, 0).
        final bounds = m.aabb;
        final radius = bounds.max.x;
        final height = bounds.max.y;
        for (final segments in {vc - 1, vc - 2, vc}) {
          if (segments >= 3) {
            yield (
              <String, Object?>{
                'kind': 'cone',
                'radius': radius,
                'height': height,
                'segments': segments,
              },
              (mat) => ConeMesh(
                radius: radius,
                height: height,
                segments: segments,
                material: mat,
              ),
            );
          }
        }
      case final PlaneMesh m:
        final bounds = m.aabb;
        final size = Vector2(
          bounds.max.x - bounds.min.x,
          bounds.max.z - bounds.min.z,
        );
        yield (
          <String, Object?>{
            'kind': 'plane',
            'size': _encodeVec2(size),
          },
          (mat) => PlaneMesh(size: size.clone(), material: mat),
        );
      case final CapsuleMesh m:
        // (2 * rings + 2) * (segments + 1) vertices and
        // 6 * (2 * rings + 1) * segments indices.
        for (var segments = 3; segments < vc; segments++) {
          if (vc % (segments + 1) != 0) {
            continue;
          }
          final rows = vc ~/ (segments + 1);
          if (rows.isOdd || rows < 4) {
            continue;
          }
          final rings = (rows - 2) ~/ 2;
          if (6 * (2 * rings + 1) * segments != ic) {
            continue;
          }
          yield (
            <String, Object?>{
              'kind': 'capsule',
              'radius': m.radius,
              'height': m.height,
              'segments': segments,
              'hemisphereRings': rings,
            },
            (mat) => CapsuleMesh(
              radius: m.radius,
              height: m.height,
              segments: segments,
              hemisphereRings: rings,
              material: mat,
            ),
          );
        }
      case final TorusMesh m:
        // (major + 1) * (minor + 1) vertices and 6 * major * minor indices.
        for (var major = 3; major < vc; major++) {
          if (vc % (major + 1) != 0) {
            continue;
          }
          final minor = vc ~/ (major + 1) - 1;
          if (minor < 3 || 6 * major * minor != ic) {
            continue;
          }
          yield (
            <String, Object?>{
              'kind': 'torus',
              'majorRadius': m.majorRadius,
              'minorRadius': m.minorRadius,
              'majorSegments': major,
              'minorSegments': minor,
            },
            (mat) => TorusMesh(
              majorRadius: m.majorRadius,
              minorRadius: m.minorRadius,
              majorSegments: major,
              minorSegments: minor,
              material: mat,
            ),
          );
        }
      case _:
        break;
    }
  }

  static bool _sameGeometry(List<Surface> a, List<Surface> b) {
    if (a.length != b.length) {
      return false;
    }
    for (var s = 0; s < a.length; s++) {
      final sa = a[s];
      final sb = b[s];
      if (sa.layout != sb.layout ||
          sa.topology != sb.topology ||
          sa.indexType != sb.indexType ||
          sa.vertexData.length != sb.vertexData.length ||
          sa.indexCount != sb.indexCount) {
        return false;
      }
      final va = sa.vertexData;
      final vb = sb.vertexData;
      // A primitive rebuilt from parameters read back from its bounds (the
      // radius of a cone) can differ in the last bit of a float.
      for (var i = 0; i < va.length; i++) {
        final d = (va[i] - vb[i]).abs();
        if (d > 1e-5 * math.max(1, va[i].abs())) {
          return false;
        }
      }
      final ia = sa.indices;
      final ib = sb.indices;
      for (var i = 0; i < ia.length; i++) {
        if (ia[i] != ib[i]) {
          return false;
        }
      }
    }
    return true;
  }

  Map<String, Object?> _encodeRawSurface(Surface surface, String path) {
    if (surface.morphTargets.isNotEmpty) {
      _issue(
        '$path.morphTargets',
        'morph targets are not saved: the surface loads with its current '
            'vertices and no targets',
      );
    }
    final layout = surface.layout;
    final box = surface.aabb;
    return <String, Object?>{
      if (layout != VertexLayout.standard)
        'layout': [
          for (final attribute in layout.attributes)
            <Object?>[attribute.name, attribute.components],
        ],
      if (surface.topology != PrimitiveTopology.triangles)
        'topology': surface.topology.name,
      'indexType': surface.indexType.name,
      'vertices': List<double>.of(surface.vertexData),
      'indices': List<int>.of(surface.indices),
      'aabb': <double>[
        box.min.x,
        box.min.y,
        box.min.z,
        box.max.x,
        box.max.y,
        box.max.z,
      ],
      if (surface.jointMap case final jointMap?)
        'jointMap': <int>[
          for (final entry in jointMap.entries) ...[entry.key, entry.value],
        ],
      'material': _encodeMaterial(surface.material, '$path.material'),
    };
  }

  Mesh _decodeMesh(Map<String, Object?> data) {
    final kind = data['kind'];
    if (kind is! String) {
      throw const FormatException('Mesh descriptor missing "kind".');
    }
    if (kind == 'asset') {
      final key = data['key'];
      if (key is! String) {
        throw const FormatException('Asset mesh descriptor missing "key".');
      }
      final registered = _meshesByKey[key];
      if (registered == null) {
        throw StateError('Unregistered asset Mesh key "$key".');
      }
      return registered;
    }
    final id = _asInt(data['id']);
    if (kind == 'ref') {
      final shared = id == null ? null : _decodedMeshes[id];
      if (shared == null) {
        throw FormatException('Mesh reference to unknown id $id.');
      }
      return shared;
    }

    final mat = switch (_asMap(data['material'])) {
      final m? => _decodeMaterial(m),
      null => null,
    };
    final Mesh mesh;
    switch (kind) {
      case 'cuboid':
        mesh = CuboidMesh(
          size: _decodeVec3OrNull(data['size']) ?? Vector3.all(1),
          material: mat,
          useFaceNormals: data['useFaceNormals'] != false,
        );
      case 'sphere':
        mesh = SphereMesh(
          radius: _asDouble(data['radius']) ?? 0.5,
          segments: _asInt(data['segments']) ?? 32,
          material: mat,
        );
      case 'cylinder':
        mesh = CylinderMesh(
          radius: _asDouble(data['radius']) ?? 0.5,
          height: _asDouble(data['height']) ?? 1.0,
          segments: _asInt(data['segments']) ?? 16,
          material: mat,
        );
      case 'cone':
        mesh = ConeMesh(
          radius: _asDouble(data['radius']) ?? 0.5,
          height: _asDouble(data['height']) ?? 1.0,
          segments: _asInt(data['segments']) ?? 32,
          material: mat ?? SpatialMaterial(),
        );
      case 'plane':
        mesh = PlaneMesh(
          size: _decodeVec2OrNull(data['size']) ?? Vector2.all(1),
          material: mat,
        );
      case 'capsule':
        mesh = CapsuleMesh(
          radius: _asDouble(data['radius']) ?? 0.5,
          height: _asDouble(data['height']) ?? 2.0,
          segments: _asInt(data['segments']) ?? 16,
          hemisphereRings: _asInt(data['hemisphereRings']) ?? 6,
          material: mat,
        );
      case 'torus':
        mesh = TorusMesh(
          majorRadius: _asDouble(data['majorRadius']) ?? 0.7,
          minorRadius: _asDouble(data['minorRadius']) ?? 0.22,
          majorSegments: _asInt(data['majorSegments']) ?? 28,
          minorSegments: _asInt(data['minorSegments']) ?? 14,
          material: mat,
        );
      case 'raw':
        mesh = Mesh();
        if (_asList(data['surfaces']) case final surfaces?) {
          for (final rawSurf in surfaces) {
            if (_asMap(rawSurf) case final surfMap?) {
              mesh.addSurface(_decodeRawSurface(surfMap));
            }
          }
        }
      case _:
        throw FormatException('Unknown mesh kind "$kind".');
    }
    if (id != null) {
      _decodedMeshes[id] = mesh;
    }
    return mesh;
  }

  Surface _decodeRawSurface(Map<String, Object?> data) {
    final verts = _asFloat32List(data['vertices']);
    final idxs = _asIntList(data['indices']);
    if (verts == null || idxs == null) {
      throw const FormatException('Raw surface missing vertices or indices.');
    }
    final layout = _decodeLayout(data['layout']);
    if (verts.length % layout.strideInFloats != 0) {
      throw FormatException(
        'Raw surface vertices (${verts.length} floats) do not fit its vertex '
        'layout of ${layout.strideInFloats} floats.',
      );
    }
    final vertexCount = verts.length ~/ layout.strideInFloats;
    final indexType = data['indexType'];
    final wide = indexType is String
        ? indexType == GpuIndexType.uint32.name
        : vertexCount > 0xFFFF;
    final typedIdx = wide
        ? Uint32List.fromList(idxs)
        : Uint16List.fromList(idxs);
    final topology =
        _enumByName(PrimitiveTopology.values, data['topology']) ??
        PrimitiveTopology.triangles;
    Aabb3? aabb;
    if (_asDoubleList(data['aabb']) case final b? when b.length >= 6) {
      aabb = Aabb3.minMax(
        Vector3(b[0], b[1], b[2]),
        Vector3(b[3], b[4], b[5]),
      );
    }
    Map<int, int>? jointMap;
    if (_asIntList(data['jointMap']) case final flat? when flat.length >= 2) {
      jointMap = {
        for (var i = 0; i + 1 < flat.length; i += 2) flat[i]: flat[i + 1],
      };
    }
    return Surface.fromBuffers(
      vertices: verts,
      indices: typedIdx,
      layout: layout,
      material: switch (_asMap(data['material'])) {
        final m? => _decodeMaterial(m),
        null => null,
      },
      jointMap: jointMap,
      aabb: aabb,
      topology: topology,
    );
  }

  static VertexLayout _decodeLayout(Object? raw) {
    final list = _asList(raw);
    if (list == null) {
      return VertexLayout.standard;
    }
    final attributes = <VertexAttribute>[];
    for (final item in list) {
      final pair = _asList(item);
      if (pair == null ||
          pair.length < 2 ||
          pair[0] is! String ||
          pair[1] is! num) {
        throw const FormatException('Malformed raw surface vertex layout.');
      }
      attributes.add(
        VertexAttribute(pair[0]! as String, (pair[1]! as num).toInt()),
      );
    }
    final layout = VertexLayout(attributes);
    // Reuse the built-in layouts, which materials compare by identity to
    // cache their vertex shader variants.
    for (final known in [
      VertexLayout.standard,
      VertexLayout.pbrStandard,
      StylizedMaterial.vertexLayout,
      StylizedMaterial.texturedVertexLayout,
      StylizedMaterial.texturedSkinnedVertexLayout,
    ]) {
      if (known == layout) {
        return known;
      }
    }
    return layout;
  }

  // ---------------------------------------------------------------------------
  // Materials.

  Map<String, Object?> _encodeMaterial(Material material, String path) {
    if (_materialIds[material] case final id?) {
      return <String, Object?>{'kind': 'ref', 'id': id};
    }
    final id = _materialIds.length;
    _materialIds[material] = id;
    return <String, Object?>{
      ..._encodeMaterialBody(material, path),
      'id': id,
      'castsShadows': material.castsShadows,
      'renderState': _encodeRenderState(material.renderState),
    };
  }

  Map<String, Object?> _encodeMaterialBody(Material material, String path) {
    final type = material.runtimeType;
    if (type == SpatialMaterial) {
      final m = material as SpatialMaterial;
      if (m.environmentProbe != null) {
        _issue(
          '$path.environmentProbe',
          'environment probes are not saved',
        );
      }
      return <String, Object?>{
        'kind': 'spatial',
        'albedoColor': _encodeColor(m.albedoColor),
        'albedoTex': ?_textureKey(
          m.albedoTexture,
          '$path.albedoTexture',
          none: Texture.standard,
        ),
        'metallic': m.metallic,
        'roughness': m.roughness,
        'normalTex': ?_textureKey(m.normalTexture, '$path.normalTexture'),
        'normalScale': m.normalScale,
        'metallicRoughnessTex': ?_textureKey(
          m.metallicRoughnessTexture,
          '$path.metallicRoughnessTexture',
        ),
        'occlusionTex': ?_textureKey(
          m.occlusionTexture,
          '$path.occlusionTexture',
        ),
        'occlusionStrength': m.occlusionStrength,
        'emissiveColor': _encodeColor(m.emissiveColor),
        'emissiveStrength': m.emissiveStrength,
        'emissiveTex': ?_textureKey(m.emissiveTexture, '$path.emissiveTexture'),
        'environmentTex': ?_textureKey(
          m.environmentTexture,
          '$path.environmentTexture',
        ),
        'environmentIntensity': m.environmentIntensity,
        'lightmapTex': ?_textureKey(m.lightmapTexture, '$path.lightmapTexture'),
        'lightmapIntensity': m.lightmapIntensity,
        'clearcoat': m.clearcoat,
        'clearcoatRoughness': m.clearcoatRoughness,
        'transmission': m.transmission,
        'ior': m.ior,
        'uvScale': _encodeVec2(m.uvScale),
        'uvOffset': _encodeVec2(m.uvOffset),
        'alphaCutoff': m.alphaCutoff,
        'doubleSided': m.doubleSided,
        'ditherFade': m.ditherFade,
      };
    }
    if (type == UnlitMaterial) {
      final m = material as UnlitMaterial;
      return <String, Object?>{
        'kind': 'unlit',
        'albedoColor': _encodeColor(m.albedoColor),
        'albedoTex': ?_textureKey(
          m.albedoTexture,
          '$path.albedoTexture',
          none: Texture.standard,
        ),
      };
    }
    if (type == StylizedMaterial) {
      final m = material as StylizedMaterial;
      return <String, Object?>{
        'kind': 'stylized',
        'albedoColor': _encodeColor(m.albedoColor),
        'accentColor': _encodeColor(m.accentColor),
        if (m.accentPalette.isNotEmpty)
          'accentPalette': [for (final c in m.accentPalette) _encodeColor(c)],
        'emissiveColor': _encodeColor(m.emissiveColor),
        'emissiveStrength': m.emissiveStrength,
        if (m.emissiveBoostColor case final boost?)
          'emissiveBoostColor': _encodeColor(boost),
        'highlightColor': _encodeColor(m.highlightColor),
        'ambientBase': _encodeColor(m.ambientBase),
        'skyFill': m.skyFill,
        'skyFillWeight': _encodeVec3(m.skyFillWeight),
        'groundBounce': m.groundBounce,
        'pointLightWrap': m.pointLightWrap,
        'specularStrength': m.specularStrength,
        'specularPower': m.specularPower,
        'specularThreshold': m.specularThreshold,
        'rimStrength': m.rimStrength,
        'rimPower': m.rimPower,
        'rimColor': _encodeColor(m.rimColor),
        'matCapTex': ?_textureKey(m.matCapTexture, '$path.matCapTexture'),
        'matCapStrength': m.matCapStrength,
        'matCapThreshold': m.matCapThreshold,
        'matCapGlossWeight': m.matCapGlossWeight,
        'gemMatCapTex': ?_textureKey(
          m.gemMatCapTexture,
          '$path.gemMatCapTexture',
        ),
        'gemMatCapStrength': m.gemMatCapStrength,
        'gemThreshold': m.gemThreshold,
        'matCapMetallic': m.matCapMetallic,
        'saturation': m.saturation,
        'overlayColor': _encodeColor(m.overlayColor),
        'windDirection': _encodeVec3(m.windDirection),
        'windAmplitude': m.windAmplitude,
        'windSpace': m.windSpace.name,
        'windUpAxis': _encodeVec3(m.windUpAxis),
        'windFrequency': m.windFrequency,
        'windPhase': _encodeVec3(m.windPhase),
        'windFlutterAmplitude': m.windFlutterAmplitude,
        'windFlutterFrequency': m.windFlutterFrequency,
        'windGustAmplitude': m.windGustAmplitude,
        'windGustFrequency': m.windGustFrequency,
        'windGustDirection': _encodeVec3(m.windGustDirection),
        'windGustPhaseScale': m.windGustPhaseScale,
        'windTime': m.windTime,
        'ditherFade': m.ditherFade,
        'baseColorTex': ?_textureKey(
          m.baseColorTexture,
          '$path.baseColorTexture',
        ),
        if (m.baseColorTextureMode != BaseColorTextureMode.multiply)
          'baseColorTextureMode': m.baseColorTextureMode.name,
        if (m.alphaCutoff != 0) 'alphaCutoff': m.alphaCutoff,
      };
    }
    if (type == ShadowCatcherMaterial) {
      final m = material as ShadowCatcherMaterial;
      return <String, Object?>{
        'kind': 'shadowCatcher',
        'color': _encodeColor(m.color),
      };
    }
    _issue(
      path,
      '${material.runtimeType} has no built-in encoding: a lossy save '
      'replaces it with a default SpatialMaterial',
    );
    return <String, Object?>{'kind': 'spatial'};
  }

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

  Texture? _decodeTexture(Object? key) {
    if (key == null) {
      return null;
    }
    if (key is! String) {
      throw const FormatException('Texture key must be a string.');
    }
    final texture = _texturesByKey[key];
    if (texture == null) {
      throw StateError('Unregistered Texture key "$key".');
    }
    return texture;
  }

  Material _decodeMaterial(Map<String, Object?> data) {
    final kind = data['kind'] as String? ?? 'spatial';
    final id = _asInt(data['id']);
    if (kind == 'ref') {
      final shared = id == null ? null : _decodedMaterials[id];
      if (shared == null) {
        throw FormatException('Material reference to unknown id $id.');
      }
      return shared;
    }
    final Material material;
    switch (kind) {
      case 'unlit':
        material = UnlitMaterial(
          albedoColor:
              _decodeColorOrNull(data['albedoColor']) ??
              const Color(0xFFFFFFFF),
          albedoTexture: _decodeTexture(data['albedoTex']),
        );
      case 'shadowCatcher':
        material = ShadowCatcherMaterial(
          color: _decodeColorOrNull(data['color']) ?? const Color(0x80000000),
        );
      case 'stylized':
        final paletteRaw = _asList(data['accentPalette']);
        material = StylizedMaterial(
          albedoColor:
              _decodeColorOrNull(data['albedoColor']) ??
              const Color(0xFFFFFFFF),
          accentColor:
              _decodeColorOrNull(data['accentColor']) ??
              const Color(0xFFFFFFFF),
          accentPalette: paletteRaw == null
              ? const []
              : [
                  for (final item in paletteRaw) ?_decodeColorOrNull(item),
                ],
          emissiveColor:
              _decodeColorOrNull(data['emissiveColor']) ??
              const Color(0xFFFFFFFF),
          emissiveStrength: _asDouble(data['emissiveStrength']) ?? 1.0,
          emissiveBoostColor: _decodeColorOrNull(data['emissiveBoostColor']),
          highlightColor:
              _decodeColorOrNull(data['highlightColor']) ??
              const Color(0xFFFFFFFF),
          ambientBase:
              _decodeColorOrNull(data['ambientBase']) ??
              const Color.from(alpha: 1, red: 0.65, green: 0.65, blue: 0.65),
          skyFill: _asDouble(data['skyFill']) ?? 0.35,
          skyFillWeight: _decodeVec3OrNull(data['skyFillWeight']),
          groundBounce: _asDouble(data['groundBounce']) ?? 0.1,
          pointLightWrap: _asDouble(data['pointLightWrap']) ?? 0.18,
          specularStrength: _asDouble(data['specularStrength']) ?? 0.28,
          specularPower: _asDouble(data['specularPower']) ?? 8,
          specularThreshold: _asDouble(data['specularThreshold']) ?? 0.12,
          rimStrength: _asDouble(data['rimStrength']) ?? 0.14,
          rimPower: _asDouble(data['rimPower']) ?? 3,
          rimColor:
              _decodeColorOrNull(data['rimColor']) ?? const Color(0xFF000000),
          matCapTexture: _decodeTexture(data['matCapTex']),
          matCapStrength: _asDouble(data['matCapStrength']) ?? 1.0,
          matCapThreshold: _asDouble(data['matCapThreshold']) ?? 0,
          matCapGlossWeight: _asDouble(data['matCapGlossWeight']) ?? 1,
          gemMatCapTexture: _decodeTexture(data['gemMatCapTex']),
          gemMatCapStrength: _asDouble(data['gemMatCapStrength']) ?? 1.0,
          gemThreshold: _asDouble(data['gemThreshold']) ?? 1.0,
          matCapMetallic: _asDouble(data['matCapMetallic']) ?? 0,
          saturation: _asDouble(data['saturation']) ?? 1,
          overlayColor:
              _decodeColorOrNull(data['overlayColor']) ??
              const Color(0x00000000),
          windDirection: _decodeVec3OrNull(data['windDirection']),
          windAmplitude: _asDouble(data['windAmplitude']) ?? 0.032,
          windSpace:
              _enumByName(WindSpace.values, data['windSpace']) ??
              WindSpace.world,
          windUpAxis: _decodeVec3OrNull(data['windUpAxis']),
          windFrequency: _asDouble(data['windFrequency']) ?? 2.3,
          windPhase: _decodeVec3OrNull(data['windPhase']),
          windFlutterAmplitude: _asDouble(data['windFlutterAmplitude']) ?? 0,
          windFlutterFrequency: _asDouble(data['windFlutterFrequency']) ?? 12,
          windGustAmplitude: _asDouble(data['windGustAmplitude']) ?? 0,
          windGustFrequency: _asDouble(data['windGustFrequency']) ?? 0.8,
          windGustDirection: _decodeVec3OrNull(data['windGustDirection']),
          windGustPhaseScale: _asDouble(data['windGustPhaseScale']) ?? 0.5,
          windTime: _asDouble(data['windTime']) ?? 0,
          ditherFade: data['ditherFade'] == true,
          baseColorTexture: _decodeTexture(data['baseColorTex']),
          baseColorTextureMode:
              _enumByName(
                BaseColorTextureMode.values,
                data['baseColorTextureMode'],
              ) ??
              BaseColorTextureMode.multiply,
          alphaCutoff: _asDouble(data['alphaCutoff']) ?? 0,
        );
      case 'spatial':
      case _:
        material = SpatialMaterial(
          albedoColor:
              _decodeColorOrNull(data['albedoColor']) ??
              const Color(0xFFFFFFFF),
          albedoTexture: _decodeTexture(data['albedoTex']),
          metallic: _asDouble(data['metallic']) ?? 0.8,
          roughness: _asDouble(data['roughness']) ?? 0.6,
          normalTexture: _decodeTexture(data['normalTex']),
          normalScale: _asDouble(data['normalScale']) ?? 1.0,
          metallicRoughnessTexture: _decodeTexture(
            data['metallicRoughnessTex'],
          ),
          occlusionTexture: _decodeTexture(data['occlusionTex']),
          occlusionStrength: _asDouble(data['occlusionStrength']) ?? 1.0,
          emissiveColor:
              _decodeColorOrNull(data['emissiveColor']) ??
              const Color(0xFF000000),
          emissiveStrength: _asDouble(data['emissiveStrength']) ?? 1.0,
          emissiveTexture: _decodeTexture(data['emissiveTex']),
          environmentTexture: _decodeTexture(data['environmentTex']),
          environmentIntensity: _asDouble(data['environmentIntensity']) ?? 1.0,
          lightmapTexture: _decodeTexture(data['lightmapTex']),
          lightmapIntensity: _asDouble(data['lightmapIntensity']) ?? 1.0,
          clearcoat: _asDouble(data['clearcoat']) ?? 0.0,
          clearcoatRoughness: _asDouble(data['clearcoatRoughness']) ?? 0.1,
          transmission: _asDouble(data['transmission']) ?? 0.0,
          ior: _asDouble(data['ior']) ?? 1.5,
          uvScale: _decodeVec2OrNull(data['uvScale']),
          uvOffset: _decodeVec2OrNull(data['uvOffset']),
          alphaCutoff: _asDouble(data['alphaCutoff']) ?? 0.0,
          doubleSided: data['doubleSided'] == true,
          ditherFade: data['ditherFade'] == true,
        );
    }

    if (data['castsShadows'] case final bool cs) {
      material.castsShadows = cs;
    }
    if (_asMap(data['renderState']) case final rsMap?) {
      material.renderState = _decodeRenderState(rsMap);
    }
    if (id != null) {
      _decodedMaterials[id] = material;
    }
    return material;
  }

  static Map<String, Object?> _encodeRenderState(RenderState state) {
    return <String, Object?>{
      'blend': state.blend.name,
      'depthTest': state.depthTest,
      'depthCompare': state.depthCompare.name,
      'depthWrite': state.depthWrite,
      'cullMode': state.cullMode.name,
      'depthPrepass': state.depthPrepass,
      'translucent': state.translucent,
      'polygonMode': state.polygonMode.name,
      if (state.stencil case final stencil?)
        'stencil': <String, Object?>{
          'compare': stencil.compare.name,
          'stencilFail': stencil.stencilFail.name,
          'depthFail': stencil.depthFail.name,
          'pass': stencil.pass.name,
          'readMask': stencil.readMask,
          'writeMask': stencil.writeMask,
          'referenceValue': stencil.referenceValue,
        },
    };
  }

  static RenderState _decodeRenderState(Map<String, Object?> data) {
    StencilState? stencil;
    if (_asMap(data['stencil']) case final s?) {
      stencil = StencilState(
        compare:
            _enumByName(CompareFunction.values, s['compare']) ??
            CompareFunction.always,
        stencilFail:
            _enumByName(StencilOp.values, s['stencilFail']) ?? StencilOp.keep,
        depthFail:
            _enumByName(StencilOp.values, s['depthFail']) ?? StencilOp.keep,
        pass: _enumByName(StencilOp.values, s['pass']) ?? StencilOp.keep,
        readMask: _asInt(s['readMask']) ?? 0xFF,
        writeMask: _asInt(s['writeMask']) ?? 0xFF,
        referenceValue: _asInt(s['referenceValue']) ?? 0,
      );
    }
    return RenderState(
      blend: _enumByName(BlendState.values, data['blend']) ?? BlendState.opaque,
      depthTest: data['depthTest'] is! bool || (data['depthTest']! as bool),
      depthCompare:
          _enumByName(CompareFunction.values, data['depthCompare']) ??
          CompareFunction.less,
      depthWrite: data['depthWrite'] is! bool || (data['depthWrite']! as bool),
      cullMode: _enumByName(CullMode.values, data['cullMode']) ?? CullMode.none,
      stencil: stencil,
      polygonMode:
          _enumByName(PolygonFillMode.values, data['polygonMode']) ??
          PolygonFillMode.fill,
      translucent: data['translucent'] is bool
          ? data['translucent']! as bool
          : null,
      depthPrepass: data['depthPrepass'] == true,
    );
  }

  // ---------------------------------------------------------------------------
  // Lights.

  Map<String, Object?> _encodeLightSource(LightSource source, String path) {
    final type = source.runtimeType;
    if (type == AmbientLight) {
      final s = source as AmbientLight;
      return <String, Object?>{
        'kind': 'ambient',
        'color': _encodeColor(s.color),
        'intensity': s.intensity,
      };
    }
    if (type == HemisphereLight) {
      final s = source as HemisphereLight;
      return <String, Object?>{
        'kind': 'hemisphere',
        'skyColor': _encodeColor(s.skyColor),
        'groundColor': _encodeColor(s.groundColor),
        'intensity': s.intensity,
        'up': _encodeVec3(s.up),
      };
    }
    if (type == DirectionalLight) {
      final s = source as DirectionalLight;
      return <String, Object?>{
        'kind': 'directional',
        'color': _encodeColor(s.color),
        'intensity': s.intensity,
        if (s.direction case final d?) 'direction': _encodeVec3(d),
        'specular': s.specular,
        if (s.shadows case final sh?) 'shadows': _encodeShadows(sh),
      };
    }
    if (type == PointLight) {
      final s = source as PointLight;
      return <String, Object?>{
        'kind': 'point',
        'color': _encodeColor(s.color),
        'intensity': s.intensity,
        'range': ?s.range,
        if (s.shadows case final sh?) 'shadows': _encodeShadows(sh),
      };
    }
    if (type == SpotLight) {
      final s = source as SpotLight;
      return <String, Object?>{
        'kind': 'spot',
        'color': _encodeColor(s.color),
        'intensity': s.intensity,
        if (s.direction case final d?) 'direction': _encodeVec3(d),
        'innerConeAngle': s.innerConeAngle,
        'outerConeAngle': s.outerConeAngle,
        'range': ?s.range,
        'specular': s.specular,
        if (s.shadows case final sh?) 'shadows': _encodeShadows(sh),
      };
    }
    _issue(
      path,
      '${source.runtimeType} has no built-in encoding: a lossy save replaces '
      'it with an AmbientLight of the same color and intensity',
    );
    return <String, Object?>{
      'kind': 'ambient',
      'color': _encodeColor(source.color),
      'intensity': source.intensity,
    };
  }

  static LightSource _decodeLightSource(Map<String, Object?> data) {
    final kind = data['kind'] as String? ?? 'ambient';
    ShadowSettings? shadows() => switch (_asMap(data['shadows'])) {
      final sh? => _decodeShadows(sh),
      null => null,
    };
    switch (kind) {
      case 'hemisphere':
        return HemisphereLight(
          skyColor:
              _decodeColorOrNull(data['skyColor']) ?? const Color(0xFFFFFFFF),
          groundColor:
              _decodeColorOrNull(data['groundColor']) ??
              const Color(0xFF808080),
          intensity: _asDouble(data['intensity']) ?? 0.5,
          up: _decodeVec3OrNull(data['up']),
        );
      case 'directional':
        return DirectionalLight(
          color: _decodeColorOrNull(data['color']) ?? const Color(0xFFFFFFFF),
          intensity: _asDouble(data['intensity']) ?? 1.0,
          direction: _decodeVec3OrNull(data['direction']),
          specular: _asDouble(data['specular']) ?? 1.0,
          shadows: shadows(),
        );
      case 'point':
        return PointLight(
          color: _decodeColorOrNull(data['color']) ?? const Color(0xFFFFFFFF),
          intensity: _asDouble(data['intensity']) ?? 1.0,
          range: _asDouble(data['range']),
          shadows: shadows(),
        );
      case 'spot':
        return SpotLight(
          color: _decodeColorOrNull(data['color']) ?? const Color(0xFFFFFFFF),
          intensity: _asDouble(data['intensity']) ?? 1.0,
          direction: _decodeVec3OrNull(data['direction']),
          innerConeAngle: _asDouble(data['innerConeAngle']) ?? math.pi / 8,
          outerConeAngle: _asDouble(data['outerConeAngle']) ?? math.pi / 4,
          range: _asDouble(data['range']),
          specular: _asDouble(data['specular']) ?? 1.0,
          shadows: shadows(),
        );
      case 'ambient':
      case _:
        return AmbientLight(
          color: _decodeColorOrNull(data['color']) ?? const Color(0xFFFFFFFF),
          intensity: _asDouble(data['intensity']) ?? 0.2,
        );
    }
  }

  static Map<String, Object?> _encodeShadows(ShadowSettings s) {
    return <String, Object?>{
      'resolution': s.resolution,
      'fit': s.fit.name,
      if (s.bounds case final b?)
        'bounds': <double>[
          b.min.x,
          b.min.y,
          b.min.z,
          b.max.x,
          b.max.y,
          b.max.z,
        ],
      if (s.casterBounds case final b?)
        'casterBounds': <double>[
          b.min.x,
          b.min.y,
          b.min.z,
          b.max.x,
          b.max.y,
          b.max.z,
        ],
      'maxDistance': ?s.maxDistance,
      'strength': s.strength,
      'color': _encodeColor(s.color),
      'softness': s.softness,
      'depthBias': s.depthBias,
      'normalBias': s.normalBias,
      'encoding': s.encoding.name,
      'stabilize': s.stabilize,
      'cacheWhenStatic': s.cacheWhenStatic,
      if (s.cacheStillCasters) 'cacheStillCasters': true,
      if (s.stillCasterFrames != 30) 'stillCasterFrames': s.stillCasterFrames,
      'cascades': s.cascades,
      'cascadeSplitRatio': s.cascadeSplitRatio,
      if (s.cascadeSplits case final splits?)
        'cascadeSplits': List<double>.of(splits),
      'cascadeBlendRange': s.cascadeBlendRange,
    };
  }

  static ShadowSettings _decodeShadows(Map<String, Object?> data) {
    Aabb3? bounds;
    if (_asDoubleList(data['bounds']) case final b? when b.length >= 6) {
      bounds = Aabb3.minMax(
        Vector3(b[0], b[1], b[2]),
        Vector3(b[3], b[4], b[5]),
      );
    }
    Aabb3? casterBounds;
    if (_asDoubleList(data['casterBounds']) case final b? when b.length >= 6) {
      casterBounds = Aabb3.minMax(
        Vector3(b[0], b[1], b[2]),
        Vector3(b[3], b[4], b[5]),
      );
    }
    return ShadowSettings(
      resolution: _asInt(data['resolution']) ?? 1024,
      fit: _enumByName(ShadowFit.values, data['fit']) ?? ShadowFit.view,
      bounds: bounds,
      casterBounds: casterBounds,
      maxDistance: _asDouble(data['maxDistance']),
      strength: _asDouble(data['strength']) ?? 1.0,
      color: _decodeColorOrNull(data['color']) ?? const Color(0xFF000000),
      softness: _asInt(data['softness']) ?? 1,
      depthBias: _asDouble(data['depthBias']) ?? 1.0,
      normalBias: _asDouble(data['normalBias']) ?? 0.5,
      encoding:
          _enumByName(ShadowMapEncoding.values, data['encoding']) ??
          ShadowMapEncoding.auto,
      stabilize: data['stabilize'] is! bool || (data['stabilize']! as bool),
      cacheWhenStatic: data['cacheWhenStatic'] == true,
      cacheStillCasters: data['cacheStillCasters'] == true,
      stillCasterFrames: math.max(1, _asInt(data['stillCasterFrames']) ?? 30),
      cascades: _asInt(data['cascades']) ?? 1,
      cascadeSplitRatio: _asDouble(data['cascadeSplitRatio']) ?? 0.28,
      cascadeSplits: _asDoubleList(data['cascadeSplits']),
      cascadeBlendRange: _asDouble(data['cascadeBlendRange']) ?? 0.1,
    );
  }

  // ---------------------------------------------------------------------------
  // Cameras and world settings.

  Map<String, Object?> _encodeCamera(CameraComponent3D cam, String path) {
    if (cam.runtimeType != CameraComponent3D) {
      _issue(
        path,
        '${cam.runtimeType} is a subclass of CameraComponent3D and has no '
        'SceneNodeCodec3D: a lossy save saves it as a plain CameraComponent3D',
      );
    }
    return <String, Object?>{
      'projection': cam.projection.name,
      'fovY': cam.fovY,
      'orthographicHeight': ?cam.orthographicHeight,
      'near': cam.near,
      'far': cam.far,
      'position': _encodeVec3(cam.position),
      'target': _encodeVec3(cam.target),
      'up': _encodeVec3(cam.up),
      'rotation': _encodeQuat(cam.rotation),
      'cameraMask': cam.cameraMask,
      if (cam.customViewMatrix case final m?)
        'customViewMatrix': List<double>.of(m.storage),
      if (cam.customProjectionMatrix case final m?)
        'customProjectionMatrix': List<double>.of(m.storage),
    };
  }

  static CameraComponent3D _decodeCameraData(Map<String, Object?> data) {
    return CameraComponent3D(
      projection:
          _enumByName(CameraProjection.values, data['projection']) ??
          CameraProjection.perspective,
      fovY: _asDouble(data['fovY']) ?? 60,
      orthographicHeight: _asDouble(data['orthographicHeight']),
      near: _asDouble(data['near']) ?? CameraComponent3D.distanceNear,
      far: _asDouble(data['far']) ?? CameraComponent3D.distanceFar,
      position: _decodeVec3OrNull(data['position']),
      target: _decodeVec3OrNull(data['target']),
      up: _decodeVec3OrNull(data['up']),
      rotation: _decodeQuatOrNull(data['rotation']),
      cameraMask: _asInt(data['cameraMask']) ?? 0xFFFFFFFF,
      customViewMatrix: _decodeMatrix4OrNull(data['customViewMatrix']),
      customProjectionMatrix: _decodeMatrix4OrNull(
        data['customProjectionMatrix'],
      ),
    );
  }

  static Map<String, Object?> _encodeFog(FogSettings f) {
    return <String, Object?>{
      'color': _encodeColor(f.color),
      'start': f.start,
      'end': f.end,
      'density': f.density,
      'heightFalloff': f.heightFalloff,
      'baseHeight': f.baseHeight,
      'maxOpacity': f.maxOpacity,
      'up': _encodeVec3(f.up),
    };
  }

  static FogSettings _decodeFog(Map<String, Object?> data) {
    return FogSettings(
      color: _decodeColorOrNull(data['color']) ?? const Color(0xFFB8C8DC),
      start: _asDouble(data['start']) ?? 10.0,
      end: _asDouble(data['end']) ?? 60.0,
      density: _asDouble(data['density']) ?? 0.0,
      heightFalloff: _asDouble(data['heightFalloff']) ?? 0.0,
      baseHeight: _asDouble(data['baseHeight']) ?? 0.0,
      maxOpacity: _asDouble(data['maxOpacity']) ?? 1.0,
      up: _decodeVec3OrNull(data['up']),
    );
  }

  static Map<String, Object?> _encodeBloom(BloomSettings b) {
    return <String, Object?>{
      'threshold': b.threshold,
      'softKnee': b.softKnee,
      'intensity': b.intensity,
      'radius': b.radius,
      'passes': b.passes,
    };
  }

  static BloomSettings _decodeBloom(Map<String, Object?> data) {
    return BloomSettings(
      threshold: _asDouble(data['threshold']) ?? 0.8,
      softKnee: _asDouble(data['softKnee']) ?? 0.5,
      intensity: _asDouble(data['intensity']) ?? 0.6,
      radius: _asDouble(data['radius']) ?? 1.0,
      passes: _asInt(data['passes']) ?? 2,
    );
  }

  Map<String, Object?> _encodePostProcess(PostProcessSettings p) {
    if (p.colorLut != null) {
      _issue(
        'world.postProcess.colorLut',
        'color lookup tables are not saved',
      );
    }
    return <String, Object?>{
      'toneMap': p.toneMap.name,
      'exposure': p.exposure,
      'contrast': p.contrast,
      'saturation': p.saturation,
      'vignetteIntensity': p.vignetteIntensity,
      'vignetteSmoothness': p.vignetteSmoothness,
      'tint': _encodeColor(p.tint),
      'fxaa': p.fxaa,
      'colorLutIntensity': p.colorLutIntensity,
      'ssaoIntensity': p.ssaoIntensity,
      'ssaoRadius': p.ssaoRadius,
      'dofFocusDepth': p.dofFocusDepth,
      'dofFocusRange': p.dofFocusRange,
      'dofBlurStrength': p.dofBlurStrength,
    };
  }

  static PostProcessSettings _decodePostProcess(Map<String, Object?> data) {
    return PostProcessSettings(
      toneMap:
          _enumByName(ToneMapMode.values, data['toneMap']) ?? ToneMapMode.none,
      exposure: _asDouble(data['exposure']) ?? 1.0,
      contrast: _asDouble(data['contrast']) ?? 1.0,
      saturation: _asDouble(data['saturation']) ?? 1.0,
      vignetteIntensity: _asDouble(data['vignetteIntensity']) ?? 0.0,
      vignetteSmoothness: _asDouble(data['vignetteSmoothness']) ?? 0.5,
      tint: _decodeColorOrNull(data['tint']) ?? const Color(0xFFFFFFFF),
      fxaa: data['fxaa'] == true,
      colorLutIntensity: _asDouble(data['colorLutIntensity']) ?? 1.0,
      ssaoIntensity: _asDouble(data['ssaoIntensity']) ?? 0.0,
      ssaoRadius: _asDouble(data['ssaoRadius']) ?? 1.5,
      dofFocusDepth: _asDouble(data['dofFocusDepth']) ?? 0.5,
      dofFocusRange: _asDouble(data['dofFocusRange']) ?? 0.15,
      dofBlurStrength: _asDouble(data['dofBlurStrength']) ?? 0.0,
    );
  }

  // ---------------------------------------------------------------------------
  // Values.

  static T? _enumByName<T extends Enum>(List<T> values, Object? name) {
    if (name is! String) {
      return null;
    }
    for (final value in values) {
      if (value.name == name) {
        return value;
      }
    }
    return null;
  }

  static List<double> _encodeVec2(Vector2 v) => <double>[v.x, v.y];
  static List<double> _encodeVec3(Vector3 v) => <double>[v.x, v.y, v.z];
  static List<double> _encodeVec4(Vector4 v) => <double>[v.x, v.y, v.z, v.w];
  static List<double> _encodeQuat(Quaternion q) => <double>[q.x, q.y, q.z, q.w];
  static List<double> _encodeColor(Color c) => <double>[c.a, c.r, c.g, c.b];

  static Vector2? _decodeVec2OrNull(Object? raw) {
    final list = _asDoubleList(raw);
    return list != null && list.length >= 2 ? Vector2(list[0], list[1]) : null;
  }

  static Vector3? _decodeVec3OrNull(Object? raw) {
    final list = _asDoubleList(raw);
    return list != null && list.length >= 3
        ? Vector3(list[0], list[1], list[2])
        : null;
  }

  static Vector4? _decodeVec4OrNull(Object? raw) {
    final list = _asDoubleList(raw);
    return list != null && list.length >= 4
        ? Vector4(list[0], list[1], list[2], list[3])
        : null;
  }

  static Quaternion? _decodeQuatOrNull(Object? raw) {
    final list = _asDoubleList(raw);
    return list != null && list.length >= 4
        ? Quaternion(list[0], list[1], list[2], list[3])
        : null;
  }

  static Matrix4? _decodeMatrix4OrNull(Object? raw) {
    final list = _asDoubleList(raw);
    if (list == null || list.length < 16) {
      return null;
    }
    return Matrix4.fromList(list.sublist(0, 16));
  }

  static Color? _decodeColorOrNull(Object? raw) {
    final list = _asDoubleList(raw);
    if (list == null || list.length < 4) {
      return null;
    }
    return Color.from(
      alpha: list[0].clamp(0.0, 1.0),
      red: list[1].clamp(0.0, 1.0),
      green: list[2].clamp(0.0, 1.0),
      blue: list[3].clamp(0.0, 1.0),
    );
  }

  static int? _asInt(Object? v) {
    if (v is int) {
      return v;
    }
    if (v is num) {
      return v.toInt();
    }
    return null;
  }

  static double? _asDouble(Object? v) => v is num ? v.toDouble() : null;

  static Map<String, Object?>? _asMap(Object? v) {
    if (v is Map<String, Object?>) {
      return v;
    }
    if (v is Map) {
      return <String, Object?>{
        for (final entry in v.entries)
          if (entry.key is String) entry.key as String: entry.value,
      };
    }
    return null;
  }

  static List<Object?>? _asList(Object? v) {
    if (v is List<Object?>) {
      return v;
    }
    if (v is List) {
      return List<Object?>.of(v);
    }
    return null;
  }

  static List<String>? _asStringList(Object? v) {
    final list = _asList(v);
    if (list == null) {
      return null;
    }
    return <String>[
      for (final item in list)
        if (item is String) item,
    ];
  }

  static List<int>? _asIntList(Object? v) {
    final list = _asList(v);
    if (list == null) {
      return null;
    }
    return <int>[
      for (final item in list)
        if (item is num) item.toInt(),
    ];
  }

  static List<double>? _asDoubleList(Object? v) {
    final list = _asList(v);
    if (list == null) {
      return null;
    }
    return <double>[
      for (final item in list)
        if (item is num) item.toDouble(),
    ];
  }

  static Float32List? _asFloat32List(Object? v) {
    final list = _asDoubleList(v);
    return list == null ? null : Float32List.fromList(list);
  }
}

class _BinarySceneWriter() {
  static const int _tagNull = 0;
  static const int _tagFalse = 1;
  static const int _tagTrue = 2;
  static const int _tagInt32 = 3;
  static const int _tagUint32 = 4;
  static const int _tagFloat64 = 5;
  static const int _tagString = 6;
  static const int _tagList = 7;
  static const int _tagMap = 8;

  final Map<String, int> _stringIds = {};
  final List<Uint8List> _stringBytes = [];
  final BytesBuilder _body = BytesBuilder(copy: false);
  final ByteData _scratch = ByteData(8);

  Uint8List encodeRoot(Map<String, Object?> root) {
    _writeValue(root);
    final bodyBytes = _body.takeBytes();

    final out = BytesBuilder(copy: false);
    _appendUint32(out, _stringBytes.length);
    for (final utf8Bytes in _stringBytes) {
      _appendUint32(out, utf8Bytes.length);
      out.add(utf8Bytes);
    }
    out.add(bodyBytes);
    return out.takeBytes();
  }

  int _intern(String value) {
    return _stringIds.putIfAbsent(value, () {
      final id = _stringBytes.length;
      _stringBytes.add(utf8.encode(value));
      return id;
    });
  }

  void _writeValue(Object? value) {
    if (value == null) {
      _body.addByte(_tagNull);
      return;
    }
    if (value is bool) {
      _body.addByte(value ? _tagTrue : _tagFalse);
      return;
    }
    if (value is int) {
      if (value >= -0x80000000 && value <= 0x7FFFFFFF) {
        _body.addByte(_tagInt32);
        _scratch.setInt32(0, value, Endian.little);
        _body.add(Uint8List.fromList(_scratch.buffer.asUint8List(0, 4)));
      } else if (value >= 0 && value <= 0xFFFFFFFF) {
        _body.addByte(_tagUint32);
        _scratch.setUint32(0, value, Endian.little);
        _body.add(Uint8List.fromList(_scratch.buffer.asUint8List(0, 4)));
      } else {
        _body.addByte(_tagFloat64);
        _scratch.setFloat64(0, value.toDouble(), Endian.little);
        _body.add(Uint8List.fromList(_scratch.buffer.asUint8List(0, 8)));
      }
      return;
    }
    if (value is num) {
      _body.addByte(_tagFloat64);
      _scratch.setFloat64(0, value.toDouble(), Endian.little);
      _body.add(Uint8List.fromList(_scratch.buffer.asUint8List(0, 8)));
      return;
    }
    if (value is String) {
      _body.addByte(_tagString);
      _writeUint32(_intern(value));
      return;
    }
    if (value is List) {
      _body.addByte(_tagList);
      _writeUint32(value.length);
      for (final item in value) {
        _writeValue(item);
      }
      return;
    }
    if (value is Map) {
      _body.addByte(_tagMap);
      final entries = <MapEntry<String, Object?>>[
        for (final e in value.entries)
          if (e.key is String) MapEntry(e.key as String, e.value),
      ];
      _writeUint32(entries.length);
      for (final entry in entries) {
        _writeUint32(_intern(entry.key));
        _writeValue(entry.value);
      }
      return;
    }
    throw FormatException('Unsupported value in binary scene: $value');
  }

  void _writeUint32(int v) => _appendUint32(_body, v);

  void _appendUint32(BytesBuilder target, int v) {
    _scratch.setUint32(0, v, Endian.little);
    target.add(Uint8List.fromList(_scratch.buffer.asUint8List(0, 4)));
  }
}

class _BinarySceneReader(final Uint8List _bytes) {
  late final ByteData _view = ByteData.sublistView(_bytes);
  int _offset = 0;
  final List<String> _strings = [];

  Map<String, Object?> decodeRoot() {
    final stringCount = _readUint32();
    for (var i = 0; i < stringCount; i++) {
      final byteLen = _readUint32();
      _require(byteLen);
      _strings.add(
        utf8.decode(
          Uint8List.sublistView(_bytes, _offset, _offset + byteLen),
        ),
      );
      _offset += byteLen;
    }
    final root = _readValue();
    if (root is! Map<String, Object?>) {
      throw const FormatException('F3DS binary root is not a map.');
    }
    return root;
  }

  Object? _readValue() {
    _require(1);
    final tag = _bytes[_offset++];
    switch (tag) {
      case _BinarySceneWriter._tagNull:
        return null;
      case _BinarySceneWriter._tagFalse:
        return false;
      case _BinarySceneWriter._tagTrue:
        return true;
      case _BinarySceneWriter._tagInt32:
        _require(4);
        final v = _view.getInt32(_offset, Endian.little);
        _offset += 4;
        return v;
      case _BinarySceneWriter._tagUint32:
        _require(4);
        final v = _view.getUint32(_offset, Endian.little);
        _offset += 4;
        return v;
      case _BinarySceneWriter._tagFloat64:
        _require(8);
        final v = _view.getFloat64(_offset, Endian.little);
        _offset += 8;
        return v;
      case _BinarySceneWriter._tagString:
        return _readInternedString();
      case _BinarySceneWriter._tagList:
        final count = _readUint32();
        return <Object?>[for (var i = 0; i < count; i++) _readValue()];
      case _BinarySceneWriter._tagMap:
        final count = _readUint32();
        final map = <String, Object?>{};
        for (var i = 0; i < count; i++) {
          final key = _readInternedString();
          map[key] = _readValue();
        }
        return map;
      case _:
        throw FormatException('Invalid F3DS binary value tag: $tag');
    }
  }

  String _readInternedString() {
    final idx = _readUint32();
    if (idx >= _strings.length) {
      throw FormatException('Out-of-bounds F3DS string index: $idx');
    }
    return _strings[idx];
  }

  int _readUint32() {
    _require(4);
    final v = _view.getUint32(_offset, Endian.little);
    _offset += 4;
    return v;
  }

  void _require(int count) {
    if (_offset + count > _bytes.length) {
      throw const FormatException('Unexpected end of F3DS binary stream.');
    }
  }
}
