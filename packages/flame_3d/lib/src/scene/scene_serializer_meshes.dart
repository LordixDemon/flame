part of 'scene_serializer_3d.dart';

extension _SceneSerializerMeshes on SceneSerializer3D {
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
}

/// The descriptor of [mesh] as a built-in primitive, or `null` when it is
/// not one or was changed after it was built: the primitive the descriptor
/// builds must have exactly the same surfaces.
Map<String, Object?>? _encodePrimitive(
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

Iterable<(Map<String, Object?>, Mesh Function(Material))> _primitiveCandidates(
  Mesh mesh,
  List<Surface> surfaces,
) sync* {
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

bool _sameGeometry(List<Surface> a, List<Surface> b) {
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

VertexLayout _decodeLayout(Object? raw) {
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
