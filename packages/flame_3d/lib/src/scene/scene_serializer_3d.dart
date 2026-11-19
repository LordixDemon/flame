import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Color;

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

/// Versioned human-readable JSON and compact CRC32-verified `'F3DS'` binary
/// serializer for [World3D] scene graphs.
class SceneSerializer3D({
  final PrefabRegistry3D? prefabRegistry,
}) {
  /// Current schema version written into JSON and `'F3DS'` binary headers.
  static const int currentSchemaVersion = 1;

  /// Four-byte ASCII magic header (`'F3DS'`) of binary scene snapshots.
  static const List<int> binaryMagic = [0x46, 0x33, 0x44, 0x53];

  final Map<String, Mesh> _meshesByKey = {};
  final Map<Mesh, String> _keysByMesh = {};
  final Map<String, Texture> _texturesByKey = {};
  final Map<Texture, String> _keysByTexture = {};
  final List<SceneNodeCodec3D<Component>> _nodeCodecs = [];
  final Map<String, SceneNodeCodec3D<Component>> _nodeCodecsById = {};

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

  /// Serializes [world] (and optional detached [cameras]) into a versioned
  /// JSON-compatible map.
  Map<String, Object?> toJson(
    World3D world, {
    List<CameraComponent3D> cameras = const [],
  }) {
    final nodes = <Map<String, Object?>>[];
    for (final child in world.children) {
      final encoded = _encodeComponent(child);
      if (encoded != null) {
        nodes.add(encoded);
      }
    }
    return <String, Object?>{
      'format': 'F3DS',
      'schemaVersion': currentSchemaVersion,
      'world': <String, Object?>{
        'renderScale': world.renderScale,
        'spatialIndex3DEnabled': world.spatialIndex3DEnabled,
        'prioritizeNearestLights': world.prioritizeNearestLights,
        'depthPrepassEnabled': world.depthPrepassEnabled,
        if (world.fog case final fog?) 'fog': _encodeFog(fog),
        if (world.bloom case final bloom?) 'bloom': _encodeBloom(bloom),
        if (world.postProcess case final post?)
          'postProcess': _encodePostProcess(post),
      },
      if (cameras.isNotEmpty)
        'cameras': [for (final cam in cameras) _encodeCameraData(cam)],
      'nodes': nodes,
    };
  }

  /// Encodes [world] as a UTF-8 JSON string.
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
  List<CameraComponent3D> fromJsonInto(
    Map<String, Object?> map,
    World3D target, {
    bool clearTarget = false,
  }) {
    final version = _asInt(map['schemaVersion']);
    if (version == null || version != currentSchemaVersion) {
      throw FormatException('Unsupported scene schemaVersion: $version');
    }

    if (clearTarget && target.children.isNotEmpty) {
      target.removeAll(List<Component>.of(target.children));
    }

    if (_asMap(map['world']) case final worldData?) {
      if (_asDouble(worldData['renderScale']) case final scale?
          when scale > 0) {
        target.renderScale = scale;
      }
      if (worldData['spatialIndex3DEnabled'] case final bool b) {
        target.spatialIndex3DEnabled = b;
      }
      if (worldData['prioritizeNearestLights'] case final bool b) {
        target.prioritizeNearestLights = b;
      }
      if (worldData['depthPrepassEnabled'] case final bool b) {
        target.depthPrepassEnabled = b;
      }
      target
        ..fog = switch (_asMap(worldData['fog'])) {
          final f? => _decodeFog(f),
          null => null,
        }
        ..bloom = switch (_asMap(worldData['bloom'])) {
          final b? => _decodeBloom(b),
          null => null,
        }
        ..postProcess = switch (_asMap(worldData['postProcess'])) {
          final p? => _decodePostProcess(p),
          null => null,
        };
    }

    final decodedCameras = <CameraComponent3D>[];
    if (_asList(map['cameras']) case final camList?) {
      for (final rawCam in camList) {
        if (_asMap(rawCam) case final camMap?) {
          decodedCameras.add(_decodeCameraData(camMap));
        }
      }
    }

    if (_asList(map['nodes']) case final nodeList?) {
      for (final rawNode in nodeList) {
        if (_asMap(rawNode) case final nodeMap?) {
          final comp = _decodeComponent(nodeMap);
          if (comp != null) {
            if (comp is CameraComponent3D) {
              decodedCameras.add(comp);
            }
            target.add(comp);
          }
        }
      }
    }
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
    if (version != currentSchemaVersion) {
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

  Map<String, Object?>? _encodeComponent(Component component) {
    for (final codec in _nodeCodecs) {
      if (codec._matches(component)) {
        final node = <String, Object?>{
          'type': 'custom',
          'codec': codec.typeId,
          'payload': codec._encode(component),
        };
        if (component is Component3D) {
          _writeCommonComponent3D(node, component, includeChildren: true);
        }
        return node;
      }
    }

    if (component is CameraComponent3D) {
      return <String, Object?>{
        'type': 'camera',
        ..._encodeCameraData(component),
      };
    }

    if (component is! Component3D) {
      return null;
    }

    final pid = component.prefabId;
    if (pid != null && (prefabRegistry?.contains(pid) ?? false)) {
      final node = <String, Object?>{
        'type': 'prefab',
        'prefabId': pid,
      };
      _writeCommonComponent3D(node, component, includeChildren: false);
      if (component is MeshComponent) {
        node['color'] = _encodeColor(component.color);
      } else if (component is LodMeshComponent) {
        node['color'] = _encodeColor(component.color);
      }
      return node;
    }

    switch (component) {
      case final MeshComponent meshComp:
        final node = <String, Object?>{
          'type': 'mesh',
          'castsShadows': meshComp.castsShadows,
          'color': _encodeColor(meshComp.color),
          'instanceData': _encodeVec4(meshComp.instanceData),
          'mesh': _encodeMesh(meshComp.mesh),
        };
        _writeCommonComponent3D(node, meshComp, includeChildren: true);
        return node;
      case final LightComponent lightComp:
        final node = <String, Object?>{
          'type': 'light',
          'lightMask': lightComp.lightMask,
          'source': _encodeLightSource(lightComp.source),
        };
        _writeCommonComponent3D(node, lightComp, includeChildren: true);
        return node;
      case _:
        final node = <String, Object?>{
          'type': 'group',
        };
        _writeCommonComponent3D(node, component, includeChildren: true);
        return node;
    }
  }

  void _writeCommonComponent3D(
    Map<String, Object?> out,
    Component3D component, {
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
      for (final child in component.children) {
        final childData = _encodeComponent(child);
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

  Map<String, Object?> _encodeMesh(Mesh mesh) {
    if (_keysByMesh[mesh] case final assetKey?) {
      return <String, Object?>{
        'kind': 'asset',
        'key': assetKey,
      };
    }

    final firstMaterial = mesh.surfaceCount > 0
        ? _encodeMaterial(mesh.surfaces.first.material)
        : null;

    switch (mesh) {
      case final CuboidMesh m:
        return <String, Object?>{
          'kind': 'cuboid',
          'size': _encodeVec3(m.size),
          'material': ?firstMaterial,
        };
      case final SphereMesh m:
        final vc = m.surfaces.first.vertexCount;
        final seg = math.max(3, math.sqrt(vc).round() - 1);
        return <String, Object?>{
          'kind': 'sphere',
          'radius': m.radius,
          'segments': seg,
          'material': ?firstMaterial,
        };
      case final CylinderMesh m:
        final vc = m.surfaces.first.vertexCount;
        final seg = math.max(3, (vc - 6) ~/ 4);
        return <String, Object?>{
          'kind': 'cylinder',
          'radius': m.radius,
          'height': m.height,
          'segments': seg,
          'material': ?firstMaterial,
        };
      case final ConeMesh m:
        final bounds = m.aabb;
        final radius = (bounds.max.x - bounds.min.x) * 0.5;
        final height = bounds.max.y - bounds.min.y;
        final seg = math.max(3, m.surfaces.first.vertexCount - 1);
        return <String, Object?>{
          'kind': 'cone',
          'radius': radius,
          'height': height,
          'segments': seg,
          'material': ?firstMaterial,
        };
      case final PlaneMesh m:
        final bounds = m.aabb;
        return <String, Object?>{
          'kind': 'plane',
          'size': <double>[
            bounds.max.x - bounds.min.x,
            bounds.max.z - bounds.min.z,
          ],
          'material': ?firstMaterial,
        };
      case final CapsuleMesh m:
        return <String, Object?>{
          'kind': 'capsule',
          'radius': m.radius,
          'height': m.height,
          'material': ?firstMaterial,
        };
      case final TorusMesh m:
        return <String, Object?>{
          'kind': 'torus',
          'majorRadius': m.majorRadius,
          'minorRadius': m.minorRadius,
          'material': ?firstMaterial,
        };
      case _:
        return <String, Object?>{
          'kind': 'raw',
          'surfaces': [
            for (final s in mesh.surfaces)
              <String, Object?>{
                'vertices': List<double>.of(s.vertexData),
                'indices': List<int>.of(s.indices),
                'material': _encodeMaterial(s.material),
              },
          ],
        };
    }
  }

  Mesh _decodeMesh(Map<String, Object?> data) {
    final kind = data['kind'];
    if (kind is! String) {
      throw const FormatException('Mesh descriptor missing "kind".');
    }
    final mat = switch (_asMap(data['material'])) {
      final m? => _decodeMaterial(m),
      null => null,
    };

    switch (kind) {
      case 'asset':
        final key = data['key'];
        if (key is! String) {
          throw const FormatException('Asset mesh descriptor missing "key".');
        }
        final registered = _meshesByKey[key];
        if (registered == null) {
          throw StateError('Unregistered asset Mesh key "$key".');
        }
        return registered;
      case 'cuboid':
        return CuboidMesh(
          size: _decodeVec3OrNull(data['size']) ?? Vector3.all(1),
          material: mat,
        );
      case 'sphere':
        return SphereMesh(
          radius: _asDouble(data['radius']) ?? 0.5,
          segments: _asInt(data['segments']) ?? 32,
          material: mat,
        );
      case 'cylinder':
        return CylinderMesh(
          radius: _asDouble(data['radius']) ?? 0.5,
          height: _asDouble(data['height']) ?? 1.0,
          segments: _asInt(data['segments']) ?? 16,
          material: mat,
        );
      case 'cone':
        return ConeMesh(
          radius: _asDouble(data['radius']) ?? 0.5,
          height: _asDouble(data['height']) ?? 1.0,
          segments: _asInt(data['segments']) ?? 32,
          material: mat ?? SpatialMaterial(),
        );
      case 'plane':
        return PlaneMesh(
          size: _decodeVec2OrNull(data['size']) ?? Vector2.all(1),
          material: mat,
        );
      case 'capsule':
        return CapsuleMesh(
          radius: _asDouble(data['radius']) ?? 0.5,
          height: _asDouble(data['height']) ?? 2.0,
          material: mat,
        );
      case 'torus':
        return TorusMesh(
          majorRadius: _asDouble(data['majorRadius']) ?? 0.7,
          minorRadius: _asDouble(data['minorRadius']) ?? 0.22,
          material: mat,
        );
      case 'raw':
        final mesh = Mesh();
        if (_asList(data['surfaces']) case final surfaces?) {
          for (final rawSurf in surfaces) {
            if (_asMap(rawSurf) case final surfMap?) {
              final verts = _asFloat32List(surfMap['vertices']);
              final idxs = _asIntList(surfMap['indices']);
              final surfMat = switch (_asMap(surfMap['material'])) {
                final m? => _decodeMaterial(m),
                null => null,
              };
              if (verts != null && idxs != null) {
                final typedIdx = verts.length ~/ 12 > 0xFFFF
                    ? Uint32List.fromList(idxs)
                    : Uint16List.fromList(idxs);
                mesh.addSurface(
                  Surface.fromBuffers(
                    vertices: verts,
                    indices: typedIdx,
                    material: surfMat,
                  ),
                );
              }
            }
          }
        }
        return mesh;
      case _:
        throw FormatException('Unknown mesh kind "$kind".');
    }
  }

  Map<String, Object?> _encodeMaterial(Material material) {
    final state = _encodeRenderState(material.renderState);
    switch (material) {
      case final SpatialMaterial m:
        return <String, Object?>{
          'kind': 'spatial',
          'albedoColor': _encodeColor(m.albedoColor),
          'albedoTex': ?_keysByTexture[m.albedoTexture],
          'metallic': m.metallic,
          'roughness': m.roughness,
          'normalScale': m.normalScale,
          'occlusionStrength': m.occlusionStrength,
          'emissiveColor': _encodeColor(m.emissiveColor),
          'emissiveStrength': m.emissiveStrength,
          'environmentIntensity': m.environmentIntensity,
          'uvScale': _encodeVec2(m.uvScale),
          'uvOffset': _encodeVec2(m.uvOffset),
          'alphaCutoff': m.alphaCutoff,
          'doubleSided': m.doubleSided,
          'ditherFade': m.ditherFade,
          'castsShadows': m.castsShadows,
          'renderState': state,
        };
      case final UnlitMaterial m:
        return <String, Object?>{
          'kind': 'unlit',
          'albedoColor': _encodeColor(m.albedoColor),
          'albedoTex': ?_keysByTexture[m.albedoTexture],
          'castsShadows': m.castsShadows,
          'renderState': state,
        };
      case final StylizedMaterial m:
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
          'matCapMetallic': m.matCapMetallic,
          'saturation': m.saturation,
          'overlayColor': _encodeColor(m.overlayColor),
          'windDirection': _encodeVec3(m.windDirection),
          'windAmplitude': m.windAmplitude,
          'windSpace': m.windSpace.name,
          'windFrequency': m.windFrequency,
          'ditherFade': m.ditherFade,
          'castsShadows': m.castsShadows,
          'renderState': state,
        };
      case _:
        return <String, Object?>{
          'kind': 'spatial',
          'castsShadows': material.castsShadows,
          'renderState': state,
        };
    }
  }

  Material _decodeMaterial(Map<String, Object?> data) {
    final kind = data['kind'] as String? ?? 'spatial';
    final Material material;
    switch (kind) {
      case 'unlit':
        final texKey = data['albedoTex'];
        material = UnlitMaterial(
          albedoColor:
              _decodeColorOrNull(data['albedoColor']) ??
              const Color(0xFFFFFFFF),
          albedoTexture: texKey is String ? _texturesByKey[texKey] : null,
        );
      case 'stylized':
        final paletteRaw = _asList(data['accentPalette']);
        final windSpaceName = data['windSpace'] as String?;
        final windSpace = WindSpace.values.firstWhere(
          (w) => w.name == windSpaceName,
          orElse: () => WindSpace.world,
        );
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
          matCapMetallic: _asDouble(data['matCapMetallic']) ?? 0,
          saturation: _asDouble(data['saturation']) ?? 1,
          overlayColor:
              _decodeColorOrNull(data['overlayColor']) ??
              const Color(0x00000000),
          windDirection: _decodeVec3OrNull(data['windDirection']),
          windAmplitude: _asDouble(data['windAmplitude']) ?? 0.032,
          windSpace: windSpace,
          windFrequency: _asDouble(data['windFrequency']) ?? 2.3,
          ditherFade: data['ditherFade'] == true,
        );
      case 'spatial':
      case _:
        final texKey = data['albedoTex'];
        material = SpatialMaterial(
          albedoColor:
              _decodeColorOrNull(data['albedoColor']) ??
              const Color(0xFFFFFFFF),
          albedoTexture: texKey is String ? _texturesByKey[texKey] : null,
          metallic: _asDouble(data['metallic']) ?? 0.8,
          roughness: _asDouble(data['roughness']) ?? 0.6,
          normalScale: _asDouble(data['normalScale']) ?? 1.0,
          occlusionStrength: _asDouble(data['occlusionStrength']) ?? 1.0,
          emissiveColor:
              _decodeColorOrNull(data['emissiveColor']) ??
              const Color(0xFF000000),
          emissiveStrength: _asDouble(data['emissiveStrength']) ?? 1.0,
          environmentIntensity: _asDouble(data['environmentIntensity']) ?? 1.0,
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
    };
  }

  static RenderState _decodeRenderState(Map<String, Object?> data) {
    final blend = BlendState.values.firstWhere(
      (b) => b.name == data['blend'],
      orElse: () => BlendState.opaque,
    );
    final compare = CompareFunction.values.firstWhere(
      (c) => c.name == data['depthCompare'],
      orElse: () => CompareFunction.less,
    );
    final cull = CullMode.values.firstWhere(
      (c) => c.name == data['cullMode'],
      orElse: () => CullMode.none,
    );
    return RenderState(
      blend: blend,
      depthTest: data['depthTest'] is! bool || (data['depthTest']! as bool),
      depthCompare: compare,
      depthWrite: data['depthWrite'] is! bool || (data['depthWrite']! as bool),
      cullMode: cull,
      depthPrepass: data['depthPrepass'] == true,
    );
  }

  static Map<String, Object?> _encodeLightSource(LightSource source) {
    switch (source) {
      case final AmbientLight s:
        return <String, Object?>{
          'kind': 'ambient',
          'color': _encodeColor(s.color),
          'intensity': s.intensity,
        };
      case final HemisphereLight s:
        return <String, Object?>{
          'kind': 'hemisphere',
          'skyColor': _encodeColor(s.skyColor),
          'groundColor': _encodeColor(s.groundColor),
          'intensity': s.intensity,
          'up': _encodeVec3(s.up),
        };
      case final DirectionalLight s:
        return <String, Object?>{
          'kind': 'directional',
          'color': _encodeColor(s.color),
          'intensity': s.intensity,
          if (s.direction case final d?) 'direction': _encodeVec3(d),
          'specular': s.specular,
          if (s.shadows case final sh?) 'shadows': _encodeShadows(sh),
        };
      case final PointLight s:
        return <String, Object?>{
          'kind': 'point',
          'color': _encodeColor(s.color),
          'intensity': s.intensity,
          'range': ?s.range,
        };
      case final SpotLight s:
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
      case _:
        return <String, Object?>{
          'kind': 'ambient',
          'color': _encodeColor(source.color),
          'intensity': source.intensity,
        };
    }
  }

  static LightSource _decodeLightSource(Map<String, Object?> data) {
    final kind = data['kind'] as String? ?? 'ambient';
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
          shadows: switch (_asMap(data['shadows'])) {
            final sh? => _decodeShadows(sh),
            null => null,
          },
        );
      case 'point':
        return PointLight(
          color: _decodeColorOrNull(data['color']) ?? const Color(0xFFFFFFFF),
          intensity: _asDouble(data['intensity']) ?? 1.0,
          range: _asDouble(data['range']),
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
          shadows: switch (_asMap(data['shadows'])) {
            final sh? => _decodeShadows(sh),
            null => null,
          },
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
      'maxDistance': ?s.maxDistance,
      'strength': s.strength,
      'color': _encodeColor(s.color),
      'softness': s.softness,
      'depthBias': s.depthBias,
      'normalBias': s.normalBias,
      'encoding': s.encoding.name,
      'stabilize': s.stabilize,
      'cacheWhenStatic': s.cacheWhenStatic,
      'cascades': s.cascades,
      'cascadeSplitRatio': s.cascadeSplitRatio,
    };
  }

  static ShadowSettings _decodeShadows(Map<String, Object?> data) {
    final fit = ShadowFit.values.firstWhere(
      (f) => f.name == data['fit'],
      orElse: () => ShadowFit.view,
    );
    final encoding = ShadowMapEncoding.values.firstWhere(
      (e) => e.name == data['encoding'],
      orElse: () => ShadowMapEncoding.auto,
    );
    Aabb3? bounds;
    if (_asDoubleList(data['bounds']) case final b? when b.length >= 6) {
      bounds = Aabb3.minMax(
        Vector3(b[0], b[1], b[2]),
        Vector3(b[3], b[4], b[5]),
      );
    }
    return ShadowSettings(
      resolution: _asInt(data['resolution']) ?? 1024,
      fit: fit,
      bounds: bounds,
      maxDistance: _asDouble(data['maxDistance']),
      strength: _asDouble(data['strength']) ?? 1.0,
      color: _decodeColorOrNull(data['color']) ?? const Color(0xFF000000),
      softness: _asInt(data['softness']) ?? 1,
      depthBias: _asDouble(data['depthBias']) ?? 1.0,
      normalBias: _asDouble(data['normalBias']) ?? 0.5,
      encoding: encoding,
      stabilize: data['stabilize'] is! bool || (data['stabilize']! as bool),
      cacheWhenStatic: data['cacheWhenStatic'] == true,
      cascades: _asInt(data['cascades']) ?? 1,
      cascadeSplitRatio: _asDouble(data['cascadeSplitRatio']) ?? 0.28,
    );
  }

  static Map<String, Object?> _encodeCameraData(CameraComponent3D cam) {
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
    final projection = CameraProjection.values.firstWhere(
      (p) => p.name == data['projection'],
      orElse: () => CameraProjection.perspective,
    );
    return CameraComponent3D(
      projection: projection,
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

  static Map<String, Object?> _encodePostProcess(PostProcessSettings p) {
    return <String, Object?>{
      'toneMap': p.toneMap.name,
      'exposure': p.exposure,
      'contrast': p.contrast,
      'saturation': p.saturation,
      'vignetteIntensity': p.vignetteIntensity,
      'vignetteSmoothness': p.vignetteSmoothness,
      'tint': _encodeColor(p.tint),
      'fxaa': p.fxaa,
      'ssaoIntensity': p.ssaoIntensity,
      'ssaoRadius': p.ssaoRadius,
      'dofFocusDepth': p.dofFocusDepth,
      'dofFocusRange': p.dofFocusRange,
      'dofBlurStrength': p.dofBlurStrength,
    };
  }

  static PostProcessSettings _decodePostProcess(Map<String, Object?> data) {
    final toneMap = ToneMapMode.values.firstWhere(
      (t) => t.name == data['toneMap'],
      orElse: () => ToneMapMode.none,
    );
    return PostProcessSettings(
      toneMap: toneMap,
      exposure: _asDouble(data['exposure']) ?? 1.0,
      contrast: _asDouble(data['contrast']) ?? 1.0,
      saturation: _asDouble(data['saturation']) ?? 1.0,
      vignetteIntensity: _asDouble(data['vignetteIntensity']) ?? 0.0,
      vignetteSmoothness: _asDouble(data['vignetteSmoothness']) ?? 0.5,
      tint: _decodeColorOrNull(data['tint']) ?? const Color(0xFFFFFFFF),
      fxaa: data['fxaa'] == true,
      ssaoIntensity: _asDouble(data['ssaoIntensity']) ?? 0.0,
      ssaoRadius: _asDouble(data['ssaoRadius']) ?? 1.5,
      dofFocusDepth: _asDouble(data['dofFocusDepth']) ?? 0.5,
      dofFocusRange: _asDouble(data['dofFocusRange']) ?? 0.15,
      dofBlurStrength: _asDouble(data['dofBlurStrength']) ?? 0.0,
    );
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
