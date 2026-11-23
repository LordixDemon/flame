part of 'scene_serializer_3d.dart';

class _BuiltInNodeCodec<T extends Component3D>({
  required final String typeId,
  required final String typeName,
  required final Map<String, Object?> Function(
    SceneSerializer3D serializer,
    T component,
    String path,
  )
  encode,
  required final T Function(
    SceneSerializer3D serializer,
    Map<String, Object?> data,
  )
  decode,
}) {
  bool matches(Component3D component) => component is T;

  Map<String, Object?> encodeNode(
    SceneSerializer3D serializer,
    Component3D component,
    String path,
  ) {
    if (component.runtimeType != T) {
      serializer._issue(
        path,
        '${component.runtimeType} is a subclass of $typeName and has no '
        'SceneNodeCodec3D: a lossy save saves it as a plain $typeName',
      );
    }
    return <String, Object?>{
      'type': typeId,
      ...encode(serializer, component as T, path),
    };
  }
}

abstract final class _BuiltInCodecs._() {
  static final List<_BuiltInNodeCodec<Component3D>> all = [
    _BuiltInNodeCodec<MeshComponent>(
      typeId: 'mesh',
      typeName: 'MeshComponent',
      encode: _encodeMeshNode,
      decode: _decodeMeshNode,
    ),
    _BuiltInNodeCodec<LodMeshComponent>(
      typeId: 'lod',
      typeName: 'LodMeshComponent',
      encode: _encodeLodNode,
      decode: _decodeLodNode,
    ),
    _BuiltInNodeCodec<InstancedGroup3D>(
      typeId: 'instanced',
      typeName: 'InstancedGroup3D',
      encode: _encodeInstancedNode,
      decode: _decodeInstancedNode,
    ),
    _BuiltInNodeCodec<LightComponent>(
      typeId: 'light',
      typeName: 'LightComponent',
      encode: _encodeLightNode,
      decode: _decodeLightNode,
    ),
  ];

  static final _groupCodec = _BuiltInNodeCodec<Group3D>(
    typeId: 'group',
    typeName: 'Group3D',
    encode: _encodeGroupNode,
    decode: _decodeGroupNode,
  );

  static _BuiltInNodeCodec<Component3D>? byType(String type) {
    if (type == 'group') {
      return _groupCodec;
    }
    for (final codec in all) {
      if (codec.typeId == type) {
        return codec;
      }
    }
    return null;
  }
}

Map<String, Object?> _encodeMeshNode(
  SceneSerializer3D serializer,
  MeshComponent meshComp,
  String path,
) {
  if (meshComp.jointTransforms != null) {
    serializer._issue(
      '$path.jointTransforms',
      'joint matrices are not saved: the mesh loads in its rest pose',
    );
  }
  return <String, Object?>{
    'castsShadows': meshComp.castsShadows,
    'color': _encodeColor(meshComp.color),
    'instanceData': _encodeVec4(meshComp.instanceData),
    'mesh': serializer._encodeMesh(meshComp.mesh, '$path.mesh'),
  };
}

MeshComponent _decodeMeshNode(
  SceneSerializer3D serializer,
  Map<String, Object?> data,
) {
  final meshData = _asMap(data['mesh']);
  if (meshData == null) {
    throw const FormatException('Mesh node missing "mesh" descriptor.');
  }
  return MeshComponent(
    mesh: serializer._decodeMesh(meshData),
    castsShadows:
        data['castsShadows'] is! bool || (data['castsShadows']! as bool),
    color: _decodeColorOrNull(data['color']) ?? const Color(0xFFFFFFFF),
    instanceData: _decodeVec4OrNull(data['instanceData']),
  );
}

Map<String, Object?> _encodeLodNode(
  SceneSerializer3D serializer,
  LodMeshComponent lod,
  String path,
) {
  return <String, Object?>{
    'castsShadows': lod.castsShadows,
    'color': _encodeColor(lod.color),
    'instanceData': _encodeVec4(lod.instanceData),
    'lowestLodInShadowPass': lod.lowestLodInShadowPass,
    'levels': [
      for (var i = 0; i < lod.levels.length; i++)
        <String, Object?>{
          'mesh': serializer._encodeMesh(
            lod.levels[i].mesh,
            '$path.levels[$i]',
          ),
          if (lod.levels[i].maxDistance.isFinite)
            'maxDistance': lod.levels[i].maxDistance,
          'minScreenHeightRatio': lod.levels[i].minScreenHeightRatio,
        },
    ],
    if (lod.shadowMesh case final shadowMesh?)
      'shadowMesh': serializer._encodeMesh(shadowMesh, '$path.shadowMesh'),
  };
}

LodMeshComponent _decodeLodNode(
  SceneSerializer3D serializer,
  Map<String, Object?> data,
) {
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
        mesh: serializer._decodeMesh(meshData),
        maxDistance: _asDouble(level['maxDistance']) ?? double.infinity,
        minScreenHeightRatio: _asDouble(level['minScreenHeightRatio']) ?? 0,
      ),
    );
  }
  return LodMeshComponent(
    levels: levels,
    shadowMesh: switch (_asMap(data['shadowMesh'])) {
      final m? => serializer._decodeMesh(m),
      null => null,
    },
    lowestLodInShadowPass: data['lowestLodInShadowPass'] == true,
    color: _decodeColorOrNull(data['color']) ?? const Color(0xFFFFFFFF),
    instanceData: _decodeVec4OrNull(data['instanceData']),
    castsShadows:
        data['castsShadows'] is! bool || (data['castsShadows']! as bool),
  );
}

Map<String, Object?> _encodeInstancedNode(
  SceneSerializer3D serializer,
  InstancedGroup3D group,
  String path,
) {
  return <String, Object?>{
    'castsShadows': group.castsShadows,
    'mesh': serializer._encodeMesh(group.mesh, '$path.mesh'),
    'instances': _encodeInstances(group),
  };
}

InstancedGroup3D _decodeInstancedNode(
  SceneSerializer3D serializer,
  Map<String, Object?> data,
) {
  final meshData = _asMap(data['mesh']);
  if (meshData == null) {
    throw const FormatException('Instanced node missing "mesh" descriptor.');
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
    mesh: serializer._decodeMesh(meshData),
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
  return comp;
}

Map<String, Object?> _encodeLightNode(
  SceneSerializer3D serializer,
  LightComponent lightComp,
  String path,
) {
  return <String, Object?>{
    'lightMask': lightComp.lightMask,
    'source': serializer._encodeLightSource(lightComp.source, '$path.source'),
  };
}

LightComponent _decodeLightNode(
  SceneSerializer3D serializer,
  Map<String, Object?> data,
) {
  final srcMap = _asMap(data['source']);
  if (srcMap == null) {
    throw const FormatException('Light node missing "source" data.');
  }
  return LightComponent(
    source: _decodeLightSource(srcMap),
    lightMask: _asInt(data['lightMask']) ?? 0xFFFFFFFF,
  );
}

Map<String, Object?> _encodeGroupNode(
  SceneSerializer3D serializer,
  Group3D group,
  String path,
) => const <String, Object?>{};

Group3D _decodeGroupNode(
  SceneSerializer3D serializer,
  Map<String, Object?> data,
) => Group3D();

extension _SceneSerializerComponents on SceneSerializer3D {
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

    Map<String, Object?>? node;
    for (final codec in _BuiltInCodecs.all) {
      if (codec.matches(component)) {
        node = codec.encodeNode(this, component, path);
        break;
      }
    }
    if (node == null) {
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

      case _:
        final codec = _BuiltInCodecs.byType(type);
        if (codec == null) {
          throw FormatException('Unknown scene node type "$type".');
        }
        final comp = codec.decode(this, data);
        _applyCommonComponent3D(comp, data, includeChildren: true);
        return comp;
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
}
