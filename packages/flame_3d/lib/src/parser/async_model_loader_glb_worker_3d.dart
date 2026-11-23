part of 'async_model_loader_3d.dart';

_PreparedGlb _prepareGlbInIsolate(
  TransferableTypedData glbTransfer,
  String prefix,
) {
  final content = glbTransfer.materialize().asUint8List();
  if (content.length < 12) {
    throw FormatException('GLB buffer too short: ${content.length} bytes');
  }
  final headerView = ByteData.sublistView(content);
  final magic = String.fromCharCodes(Uint8List.sublistView(content, 0, 4));
  if (magic != 'glTF') {
    throw FormatException('Invalid GLB magic: $magic');
  }
  final version = headerView.getUint32(4, Endian.little);
  if (version != 2) {
    throw FormatException('Unsupported GLB version: $version');
  }

  Map<String, Object?>? jsonMap;
  final binChunks = <Uint8List>[];
  var cursor = 12;
  while (cursor + 8 <= content.length) {
    final chunkLen = headerView.getUint32(cursor, Endian.little);
    final chunkType = String.fromCharCodes(
      Uint8List.sublistView(content, cursor + 4, cursor + 8),
    );
    cursor += 8;
    final chunkData = Uint8List.sublistView(
      content,
      cursor,
      cursor + chunkLen,
    );
    cursor += chunkLen;
    if (chunkType == 'JSON') {
      jsonMap = jsonDecode(utf8.decode(chunkData)) as Map<String, Object?>;
    } else if (chunkType == 'BIN\x00') {
      binChunks.add(chunkData);
    }
  }
  if (jsonMap == null) {
    throw const FormatException('GLB missing JSON chunk');
  }
  // Reported on the main isolate, see `GltfWarnings`.
  final warnings = <String>[];
  final extensionsUsed = jsonMap['extensionsUsed'];
  if (extensionsUsed is List) {
    final unread = unreadExtensionsWarning(
      extensionsUsed.whereType<String>(),
    );
    if (unread != null) {
      warnings.add(unread);
    }
  }

  Uint8List resolveUriBytes(String uri) {
    final commaIdx = uri.indexOf(';base64,');
    if (uri.startsWith('data:') && commaIdx != -1) {
      return base64Decode(uri.substring(commaIdx + 8));
    }
    throw UnsupportedError(
      'External URI "$prefix$uri" cannot be read inside pure isolate; '
      'pack buffers/images into GLB or data: URIs.',
    );
  }

  // Buffers & BufferViews
  final rawBuffers = (jsonMap['buffers'] as List<Object?>?) ?? const [];
  final resolvedBuffers = <Uint8List>[];
  for (var i = 0; i < rawBuffers.length; i++) {
    if (i < binChunks.length) {
      resolvedBuffers.add(binChunks[i]);
    } else {
      final bm = rawBuffers[i]! as Map<String, Object?>;
      final uri = bm['uri'] as String?;
      // A buffer without URI outside the GLB chunk is a placeholder (the
      // fallback of `EXT_meshopt_compression`); reading it fails below.
      resolvedBuffers.add(uri == null ? Uint8List(0) : resolveUriBytes(uri));
    }
  }

  final rawViews = (jsonMap['bufferViews'] as List<Object?>?) ?? const [];
  final decodedViews = <int, Uint8List>{};
  Uint8List sliceView(int viewIdx) {
    final cached = decodedViews[viewIdx];
    if (cached != null) {
      return cached;
    }
    final vm = rawViews[viewIdx]! as Map<String, Object?>;
    final extensions = vm['extensions'] as Map<String, Object?>?;
    final meshopt =
        extensions?['EXT_meshopt_compression'] as Map<String, Object?>?;
    if (meshopt != null) {
      final source = resolvedBuffers[(meshopt['buffer']! as num).toInt()];
      final offset = (meshopt['byteOffset'] as num?)?.toInt() ?? 0;
      final length = (meshopt['byteLength']! as num).toInt();
      return decodedViews[viewIdx] = MeshoptDecoder3D.decodeBufferView(
        Uint8List.sublistView(source, offset, offset + length),
        count: (meshopt['count']! as num).toInt(),
        byteStride: (meshopt['byteStride']! as num).toInt(),
        mode: MeshoptMode3D.valueOf(meshopt['mode']! as String),
        filter: MeshoptFilter3D.valueOf(meshopt['filter'] as String?),
      );
    }
    final bufIdx = (vm['buffer']! as num).toInt();
    final offset = (vm['byteOffset'] as num?)?.toInt() ?? 0;
    final length = (vm['byteLength']! as num).toInt();
    if (offset + length > resolvedBuffers[bufIdx].length) {
      throw FormatException(
        'bufferView $viewIdx reads past the end of buffer $bufIdx',
      );
    }
    return Uint8List.sublistView(
      resolvedBuffers[bufIdx],
      offset,
      offset + length,
    );
  }

  int? strideOfView(int viewIdx) {
    final vm = rawViews[viewIdx]! as Map<String, Object?>;
    return (vm['byteStride'] as num?)?.toInt();
  }

  int componentSize(int compType) => switch (compType) {
    5120 || 5121 => 1,
    5122 || 5123 => 2,
    5125 || 5126 => 4,
    _ => throw FormatException('Unknown componentType $compType'),
  };

  num readComponent(ByteData bd, int compType, int off) => switch (compType) {
    5120 => bd.getInt8(off),
    5121 => bd.getUint8(off),
    5122 => bd.getInt16(off, Endian.little),
    5123 => bd.getUint16(off, Endian.little),
    5125 => bd.getUint32(off, Endian.little),
    _ => bd.getFloat32(off, Endian.little),
  };

  // Accessors
  final rawAccessors = (jsonMap['accessors'] as List<Object?>?) ?? const [];

  /// The raw components of accessor [accIdx]: those of its buffer view (zeros
  /// without one) with the `sparse` substitutions applied.
  Float64List readComponents(int accIdx, int components) {
    final am = rawAccessors[accIdx]! as Map<String, Object?>;
    final compType = (am['componentType']! as num).toInt();
    final count = (am['count']! as num).toInt();
    final compSize = componentSize(compType);
    final out = Float64List(count * components);
    final viewIdx = (am['bufferView'] as num?)?.toInt();
    if (viewIdx != null) {
      final byteOffset = (am['byteOffset'] as num?)?.toInt() ?? 0;
      final bd = ByteData.sublistView(sliceView(viewIdx));
      final stride = strideOfView(viewIdx) ?? (components * compSize);
      for (var elem = 0; elem < count; elem++) {
        final base = byteOffset + elem * stride;
        for (var c = 0; c < components; c++) {
          out[elem * components + c] = readComponent(
            bd,
            compType,
            base + c * compSize,
          ).toDouble();
        }
      }
    }
    final sparse = am['sparse'] as Map<String, Object?>?;
    if (sparse != null) {
      final sparseCount = (sparse['count']! as num).toInt();
      final im = sparse['indices']! as Map<String, Object?>;
      final vm = sparse['values']! as Map<String, Object?>;
      final indexType = (im['componentType']! as num).toInt();
      final indexSize = componentSize(indexType);
      final indexOffset = (im['byteOffset'] as num?)?.toInt() ?? 0;
      final valueOffset = (vm['byteOffset'] as num?)?.toInt() ?? 0;
      final indexData = ByteData.sublistView(
        sliceView((im['bufferView']! as num).toInt()),
      );
      final valueData = ByteData.sublistView(
        sliceView((vm['bufferView']! as num).toInt()),
      );
      for (var i = 0; i < sparseCount; i++) {
        final target = readComponent(
          indexData,
          indexType,
          indexOffset + i * indexSize,
        ).toInt();
        if (target < 0 || target >= count) {
          throw FormatException(
            'Sparse accessor index $target out of range 0..${count - 1}',
          );
        }
        final base = valueOffset + i * components * compSize;
        for (var c = 0; c < components; c++) {
          out[target * components + c] = readComponent(
            valueData,
            compType,
            base + c * compSize,
          ).toDouble();
        }
      }
    }
    return out;
  }

  List<double> readDoubles(int accIdx, int expectedComponents) {
    final am = rawAccessors[accIdx]! as Map<String, Object?>;
    final compType = (am['componentType']! as num).toInt();
    final normalized = (am['normalized'] as bool?) ?? false;
    final out = readComponents(accIdx, expectedComponents);
    if (normalized) {
      for (var i = 0; i < out.length; i++) {
        final v = out[i];
        out[i] = switch (compType) {
          5120 => math.max(v / 127.0, -1.0),
          5121 => v / 255.0,
          5122 => math.max(v / 32767.0, -1.0),
          5123 => v / 65535.0,
          _ => v,
        };
      }
    }
    return out;
  }

  List<int> readScalarInts(int accIdx) {
    final raw = readComponents(accIdx, 1);
    return List<int>.generate(
      raw.length,
      (i) => raw[i].toInt(),
      growable: false,
    );
  }

  // Images, Samplers, Textures, Materials
  final rawImages = (jsonMap['images'] as List<Object?>?) ?? const [];
  final imageTransfers = <TransferableTypedData>[];
  for (final item in rawImages) {
    final im = item! as Map<String, Object?>;
    final Uint8List imgBytes;
    if (im['uri'] case final String uri) {
      imgBytes = resolveUriBytes(uri);
    } else {
      imgBytes = sliceView((im['bufferView']! as num).toInt());
    }
    imageTransfers.add(
      TransferableTypedData.fromList([Uint8List.fromList(imgBytes)]),
    );
  }

  final rawSamplers = (jsonMap['samplers'] as List<Object?>?) ?? const [];
  final samplers = <_PreparedSampler>[
    for (final item in rawSamplers)
      _PreparedSampler.fromMap(item! as Map<String, Object?>),
  ];

  final rawTextures = (jsonMap['textures'] as List<Object?>?) ?? const [];
  final textures = <({int source, int? sampler})>[
    for (final item in rawTextures)
      if (item case final Map<String, Object?> tm)
        (
          source: (tm['source']! as num).toInt(),
          sampler: (tm['sampler'] as num?)?.toInt(),
        ),
  ];

  final rawMaterials = (jsonMap['materials'] as List<Object?>?) ?? const [];
  final materials = <_PreparedMaterial>[
    for (final item in rawMaterials)
      _PreparedMaterial.fromMap(item! as Map<String, Object?>),
  ];

  // Meshes & Primitives
  final rawMeshes = (jsonMap['meshes'] as List<Object?>?) ?? const [];
  final preparedMeshes = <_PreparedMesh>[];
  for (final meshObj in rawMeshes) {
    final mm = meshObj! as Map<String, Object?>;
    final meshWeights = (mm['weights'] as List<Object?>?)
        ?.map((e) => (e! as num).toDouble())
        .toList(growable: false);
    final rawPrims = (mm['primitives'] as List<Object?>?) ?? const [];
    final surfaces = <_PreparedSurface>[];
    for (final primObj in rawPrims) {
      final pm = primObj! as Map<String, Object?>;
      surfaces.addAll(
        _packGlbPrimitive(
          pm: pm,
          rawAccessors: rawAccessors,
          readDoubles: readDoubles,
          readScalarInts: readScalarInts,
          warnings: warnings,
        ),
      );
    }
    preparedMeshes.add(_PreparedMesh(surfaces, meshWeights));
  }

  // Skins
  final rawSkins = (jsonMap['skins'] as List<Object?>?) ?? const [];
  final skins = <_PreparedSkin>[];
  for (final skinObj in rawSkins) {
    final sm = skinObj! as Map<String, Object?>;
    final joints = ((sm['joints'] as List<Object?>?) ?? const [])
        .map((e) => (e! as num).toInt())
        .toList(growable: false);
    final ibmIdx = (sm['inverseBindMatrices'] as num?)?.toInt();
    final ibms = ibmIdx != null
        ? Float64List.fromList(readDoubles(ibmIdx, 16))
        : null;
    skins.add(_PreparedSkin(joints, ibms));
  }

  // Nodes & Active Scene
  final rawNodes = (jsonMap['nodes'] as List<Object?>?) ?? const [];
  final rawScenes = (jsonMap['scenes'] as List<Object?>?) ?? const [];
  final sceneIdx = (jsonMap['scene'] as num?)?.toInt() ?? 0;
  final rootNodeIndices = rawScenes.isNotEmpty && sceneIdx < rawScenes.length
      ? (((rawScenes[sceneIdx]! as Map<String, Object?>)['nodes']
                    as List<Object?>?) ??
                const [])
            .map((e) => (e! as num).toInt())
            .toList(growable: false)
      : <int>[for (var i = 0; i < rawNodes.length; i++) i];

  final preparedNodes = <_PreparedNode>[];
  void visitNode(int idx, int? parentIdx) {
    final nm = rawNodes[idx]! as Map<String, Object?>;
    final matFloats = (nm['matrix'] as List<Object?>?)
        ?.map((e) => (e! as num).toDouble())
        .toList(growable: false);
    final Matrix4 localMat;
    if (matFloats != null && matFloats.length == 16) {
      localMat = Matrix4.fromList(matFloats);
    } else {
      final tList = (nm['translation'] as List<Object?>?)
          ?.map((e) => (e! as num).toDouble())
          .toList(growable: false);
      final rList = (nm['rotation'] as List<Object?>?)
          ?.map((e) => (e! as num).toDouble())
          .toList(growable: false);
      final sList = (nm['scale'] as List<Object?>?)
          ?.map((e) => (e! as num).toDouble())
          .toList(growable: false);
      localMat = Matrix4.compose(
        tList != null ? Vector3(tList[0], tList[1], tList[2]) : Vector3.zero(),
        rList != null
            ? Quaternion(rList[0], rList[1], rList[2], rList[3])
            : Quaternion.identity(),
        sList != null ? Vector3(sList[0], sList[1], sList[2]) : Vector3.all(1),
      );
    }
    preparedNodes.add(
      _PreparedNode(
        nodeIndex: idx,
        parentNodeIndex: parentIdx,
        name: nm['name'] as String?,
        transformStorage: Float64List.fromList(localMat.storage),
        meshIndex: (nm['mesh'] as num?)?.toInt(),
        skinIndex: (nm['skin'] as num?)?.toInt(),
        weights: (nm['weights'] as List<Object?>?)
            ?.map((e) => (e! as num).toDouble())
            .toList(growable: false),
      ),
    );
    final children = (nm['children'] as List<Object?>?) ?? const [];
    for (final c in children) {
      visitNode((c! as num).toInt(), idx);
    }
  }

  for (final rIdx in rootNodeIndices) {
    visitNode(rIdx, null);
  }

  // Animations
  final rawAnimations = (jsonMap['animations'] as List<Object?>?) ?? const [];
  final animations = <_PreparedAnimation>[];
  for (final animObj in rawAnimations) {
    final am = animObj! as Map<String, Object?>;
    final animName = am['name'] as String?;
    final aSamplers = (am['samplers'] as List<Object?>?) ?? const [];
    final aChannels = (am['channels'] as List<Object?>?) ?? const [];
    final channels = <_PreparedAnimChannel>[];

    for (final chObj in aChannels) {
      final cm = chObj! as Map<String, Object?>;
      final target = cm['target']! as Map<String, Object?>;
      final targetNode = (target['node'] as num?)?.toInt();
      final path = target['path'] as String?;
      if (targetNode == null ||
          path == null ||
          !const {'translation', 'rotation', 'scale', 'weights'}.contains(
            path,
          )) {
        warnings.add(
          'animation channels targeting "$path" are skipped: only node '
          'translation, rotation, scale and weights are animated',
        );
        continue;
      }
      final samp =
          aSamplers[(cm['sampler']! as num).toInt()]! as Map<String, Object?>;
      final interp = (samp['interpolation'] as String?) ?? 'LINEAR';
      final inAcc = (samp['input']! as num).toInt();
      final outAcc = (samp['output']! as num).toInt();
      final times = Float64List.fromList(readDoubles(inAcc, 1));
      final outComp = switch (path) {
        'translation' || 'scale' => 3,
        'rotation' => 4,
        _ => 1,
      };
      final values = Float64List.fromList(readDoubles(outAcc, outComp));
      channels.add(
        _PreparedAnimChannel(
          nodeIndex: targetNode,
          path: path,
          interpolation: interp,
          times: times,
          values: values,
        ),
      );
    }
    animations.add(_PreparedAnimation(animName, channels));
  }

  return _PreparedGlb(
    images: imageTransfers,
    samplers: samplers,
    textures: textures,
    materials: materials,
    meshes: preparedMeshes,
    skins: skins,
    nodes: preparedNodes,
    animations: animations,
    warnings: warnings,
  );
}
