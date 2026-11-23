part of 'async_model_loader_3d.dart';

List<_PreparedSurface> _packGlbPrimitive({
  required Map<String, Object?> pm,
  required List<Object?> rawAccessors,
  required List<double> Function(int accIdx, int components) readDoubles,
  required List<int> Function(int accIdx) readScalarInts,
  required List<String> warnings,
}) {
  final mode = (pm['mode'] as num?)?.toInt() ?? 4;
  if (mode < 4 || mode > 6) {
    warnings.add(
      'primitives of mode $mode are skipped: only triangles, triangle '
      'strips and triangle fans can be drawn',
    );
    return const [];
  }
  final attrs = pm['attributes']! as Map<String, Object?>;
  final unread = unreadAttributesWarning(attrs.keys);
  if (unread != null) {
    warnings.add(unread);
  }
  final posAcc = (attrs['POSITION']! as num).toInt();
  final posData = readDoubles(posAcc, 3);
  final vertTotal = posData.length ~/ 3;

  final idxAcc = (pm['indices'] as num?)?.toInt();
  final rawIndices = gltfTriangleList(
    mode,
    idxAcc != null
        ? readScalarInts(idxAcc)
        : List<int>.generate(vertTotal, (i) => i, growable: false),
  )!;

  final maxIdx = rawIndices.isEmpty ? -1 : rawIndices.reduce(math.max);
  final vertCount = maxIdx + 1;
  final matIdx = (pm['material'] as num?)?.toInt();

  if (vertCount <= 0) {
    return [
      _PreparedSurface(
        vertices: TransferableTypedData.fromList([Uint8List(0)]),
        indices: TransferableTypedData.fromList([Uint8List(0)]),
        wideIndices: false,
        materialIndex: matIdx,
        jointMap: null,
        morphTargets: const [],
        customAttributes: const {},
      ),
    ];
  }

  // The attributes kept in Surface.customAttributes.
  final customData = <String, (int, Float32List)>{};
  for (final MapEntry(key: name, value: accRaw) in attrs.entries) {
    if (!gltfKeepsAttribute(name)) {
      continue;
    }
    final accIdx = (accRaw! as num).toInt();
    final type =
        (rawAccessors[accIdx]! as Map<String, Object?>)['type'] as String?;
    final components = gltfKeptComponents(type);
    if (components == 0) {
      warnings.add(droppedAttributeWarning(name, type));
      continue;
    }
    final values = readDoubles(accIdx, components);
    final out = Float32List(vertCount * components);
    final limit = math.min(values.length, out.length);
    for (var k = 0; k < limit; k++) {
      out[k] = values[k];
    }
    customData[name] = (components, out);
  }

  final uvAcc = (attrs['TEXCOORD_0'] as num?)?.toInt();
  final uvData = uvAcc != null ? readDoubles(uvAcc, 2) : null;

  final nrmAcc = (attrs['NORMAL'] as num?)?.toInt();
  List<double> nrmData;
  if (nrmAcc != null) {
    nrmData = readDoubles(nrmAcc, 3);
  } else {
    final posVecs = List<Vector3>.generate(
      vertTotal,
      (i) => Vector3(posData[i * 3], posData[i * 3 + 1], posData[i * 3 + 2]),
      growable: false,
    );
    final calc = Vertex.calculateVertexNormals(posVecs, rawIndices);
    final flat = Float64List(calc.length * 3);
    for (var i = 0; i < calc.length; i++) {
      flat[i * 3] = calc[i].x;
      flat[i * 3 + 1] = calc[i].y;
      flat[i * 3 + 2] = calc[i].z;
    }
    nrmData = flat;
  }

  Float32List? colorData;
  final colAcc = (attrs['COLOR_0'] as num?)?.toInt();
  if (colAcc != null) {
    final colMap = rawAccessors[colAcc]! as Map<String, Object?>;
    final colType = colMap['type']! as String;
    final comps = colType == 'VEC4' ? 4 : 3;
    final rawCol = readDoubles(colAcc, comps);
    final count = rawCol.length ~/ comps;
    colorData = Float32List(vertCount * 4);
    for (var i = 0; i < vertCount && i < count; i++) {
      colorData[i * 4] = rawCol[i * comps].clamp(0.0, 1.0);
      colorData[i * 4 + 1] = rawCol[i * comps + 1].clamp(0.0, 1.0);
      colorData[i * 4 + 2] = rawCol[i * comps + 2].clamp(0.0, 1.0);
      colorData[i * 4 + 3] = comps == 4
          ? rawCol[i * 4 + 3].clamp(0.0, 1.0)
          : 1.0;
    }
  }

  final jointsAcc = (attrs['JOINTS_0'] as num?)?.toInt();
  final weightsAcc = (attrs['WEIGHTS_0'] as num?)?.toInt();
  final jointsData = jointsAcc != null ? readDoubles(jointsAcc, 4) : null;
  final weightsData = weightsAcc != null ? readDoubles(weightsAcc, 4) : null;
  if (jointsData != null && weightsData != null) {
    final joints1Acc = (attrs['JOINTS_1'] as num?)?.toInt();
    final weights1Acc = (attrs['WEIGHTS_1'] as num?)?.toInt();
    final dropped = reduceJointInfluences(
      jointsData,
      weightsData,
      joints1Acc != null ? readDoubles(joints1Acc, 4) : null,
      weights1Acc != null ? readDoubles(weights1Acc, 4) : null,
      math.min(jointsData.length, weightsData.length) ~/ 4,
    );
    if (dropped) {
      warnings.add(
        'vertices influenced by more than 4 joints keep their 4 largest '
        'influences',
      );
    }
  }

  // Morph targets
  final rawTargets = (pm['targets'] as List<Object?>?) ?? const [];
  final fullMorphs = <({Float32List pos, Float32List? nrm, String name})>[];
  for (var ti = 0; ti < rawTargets.length; ti++) {
    final tm = rawTargets[ti]! as Map<String, Object?>;
    final mpAcc = (tm['POSITION'] as num?)?.toInt();
    if (mpAcc == null) {
      continue;
    }
    final mp = readDoubles(mpAcc, 3);
    final pDeltas = Float32List(vertCount * 3);
    final pLimit = math.min(vertCount * 3, mp.length);
    for (var k = 0; k < pLimit; k++) {
      pDeltas[k] = mp[k];
    }
    Float32List? nDeltas;
    final mnAcc = (tm['NORMAL'] as num?)?.toInt();
    if (mnAcc != null) {
      final mn = readDoubles(mnAcc, 3);
      nDeltas = Float32List(vertCount * 3);
      final nLimit = math.min(vertCount * 3, mn.length);
      for (var k = 0; k < nLimit; k++) {
        nDeltas[k] = mn[k];
      }
    }
    fullMorphs.add((pos: pDeltas, nrm: nDeltas, name: 'target_$ti'));
  }

  _PreparedSurface packBatch(List<int>? vertRemap, List<int> triIndices) {
    final vLen = vertRemap?.length ?? vertCount;
    final packed = Float32List(vLen * _standardStride);
    final globalToLocal = <int, int>{};

    int mapJoint(double rawJ, double w) {
      if (w <= 0.0) {
        return 0;
      }
      final jIdx = rawJ.toInt();
      return globalToLocal.putIfAbsent(jIdx, () => globalToLocal.length);
    }

    for (var local = 0; local < vLen; local++) {
      final src = vertRemap != null ? vertRemap[local] : local;
      final o = local * _standardStride;
      packed[o] = posData[src * 3];
      packed[o + 1] = posData[src * 3 + 1];
      packed[o + 2] = posData[src * 3 + 2];

      if (uvData != null && src * 2 + 1 < uvData.length) {
        packed[o + 3] = uvData[src * 2];
        packed[o + 4] = uvData[src * 2 + 1];
      }
      if (colorData != null && src * 4 + 3 < colorData.length) {
        packed[o + 5] = colorData[src * 4];
        packed[o + 6] = colorData[src * 4 + 1];
        packed[o + 7] = colorData[src * 4 + 2];
        packed[o + 8] = colorData[src * 4 + 3];
      } else {
        packed[o + 5] = 1.0;
        packed[o + 6] = 1.0;
        packed[o + 7] = 1.0;
        packed[o + 8] = 1.0;
      }
      if (src * 3 + 2 < nrmData.length) {
        packed[o + 9] = nrmData[src * 3];
        packed[o + 10] = nrmData[src * 3 + 1];
        packed[o + 11] = nrmData[src * 3 + 2];
      } else {
        packed[o + 10] = 1.0;
      }
      if (jointsData != null &&
          weightsData != null &&
          src * 4 + 3 < jointsData.length &&
          src * 4 + 3 < weightsData.length) {
        final jb = src * 4;
        final w0 = weightsData[jb];
        final w1 = weightsData[jb + 1];
        final w2 = weightsData[jb + 2];
        final w3 = weightsData[jb + 3];
        packed[o + 12] = mapJoint(jointsData[jb], w0).toDouble();
        packed[o + 13] = mapJoint(jointsData[jb + 1], w1).toDouble();
        packed[o + 14] = mapJoint(jointsData[jb + 2], w2).toDouble();
        packed[o + 15] = mapJoint(jointsData[jb + 3], w3).toDouble();
        packed[o + 16] = w0;
        packed[o + 17] = w1;
        packed[o + 18] = w2;
        packed[o + 19] = w3;
      }
    }

    var wide = vLen > 0xFFFF;
    for (var i = 0; !wide && i < triIndices.length; i++) {
      wide = triIndices[i] >= 0xFFFF;
    }
    final TypedData idxTyped = wide
        ? Uint32List.fromList(triIndices)
        : Uint16List.fromList(triIndices);

    final morphPayloads = <_PreparedMorph>[];
    for (final m in fullMorphs) {
      final pOut = vertRemap == null
          ? m.pos
          : Float32List.fromList([
              for (var i = 0; i < vLen; i++) ...[
                m.pos[vertRemap[i] * 3],
                m.pos[vertRemap[i] * 3 + 1],
                m.pos[vertRemap[i] * 3 + 2],
              ],
            ]);
      final nOut = m.nrm == null
          ? null
          : (vertRemap == null
                ? m.nrm!
                : Float32List.fromList([
                    for (var i = 0; i < vLen; i++) ...[
                      m.nrm![vertRemap[i] * 3],
                      m.nrm![vertRemap[i] * 3 + 1],
                      m.nrm![vertRemap[i] * 3 + 2],
                    ],
                  ]));
      morphPayloads.add(
        _PreparedMorph(
          name: m.name,
          posDeltas: TransferableTypedData.fromList([
            pOut.buffer.asUint8List(),
          ]),
          nrmDeltas: nOut == null
              ? null
              : TransferableTypedData.fromList([nOut.buffer.asUint8List()]),
        ),
      );
    }

    final customPayloads = <String, (int, TransferableTypedData)>{};
    for (final MapEntry(key: name, value: (components, values))
        in customData.entries) {
      final Float32List out;
      if (vertRemap == null) {
        out = values;
      } else {
        out = Float32List(vLen * components);
        for (var i = 0; i < vLen; i++) {
          final from = vertRemap[i] * components;
          for (var c = 0; c < components; c++) {
            out[i * components + c] = values[from + c];
          }
        }
      }
      customPayloads[name] = (
        components,
        TransferableTypedData.fromList([out.buffer.asUint8List()]),
      );
    }

    return _PreparedSurface(
      vertices: TransferableTypedData.fromList([packed.buffer.asUint8List()]),
      indices: TransferableTypedData.fromList([
        idxTyped.buffer.asUint8List(),
      ]),
      wideIndices: wide,
      materialIndex: matIdx,
      jointMap: globalToLocal.isEmpty ? null : globalToLocal,
      morphTargets: morphPayloads,
      customAttributes: customPayloads,
    );
  }

  final uniqueJoints = <int>{};
  if (jointsData != null && weightsData != null) {
    for (var v = 0; v < vertCount && v * 4 + 3 < jointsData.length; v++) {
      for (var k = 0; k < 4; k++) {
        if (weightsData[v * 4 + k] > 0.0) {
          uniqueJoints.add(jointsData[v * 4 + k].toInt());
        }
      }
    }
  }
  if (uniqueJoints.length <= _maxJointsPerSurface) {
    return [packBatch(null, rawIndices)];
  }

  final batches = <_PreparedSurface>[];
  final batchTris = <int>[];
  final batchJoints = <int>{};
  final triJoints = <int>{};

  void flush() {
    if (batchTris.isEmpty) {
      return;
    }
    final remap = <int, int>{};
    final used = <int>[];
    final localTris = <int>[];
    for (final oldV in batchTris) {
      final nextV = remap.putIfAbsent(oldV, () {
        final id = used.length;
        used.add(oldV);
        return id;
      });
      localTris.add(nextV);
    }
    batches.add(packBatch(used, localTris));
    batchTris.clear();
    batchJoints.clear();
  }

  for (var t = 0; t + 2 < rawIndices.length; t += 3) {
    triJoints.clear();
    for (var c = 0; c < 3; c++) {
      final v = rawIndices[t + c];
      if (jointsData != null &&
          weightsData != null &&
          v * 4 + 3 < jointsData.length) {
        for (var k = 0; k < 4; k++) {
          if (weightsData[v * 4 + k] > 0.0) {
            triJoints.add(jointsData[v * 4 + k].toInt());
          }
        }
      }
    }
    var added = 0;
    for (final j in triJoints) {
      if (!batchJoints.contains(j)) {
        added++;
      }
    }
    if (batchJoints.isNotEmpty &&
        batchJoints.length + added > _maxJointsPerSurface) {
      flush();
    }
    batchJoints.addAll(triJoints);
    batchTris
      ..add(rawIndices[t])
      ..add(rawIndices[t + 1])
      ..add(rawIndices[t + 2]);
  }
  flush();
  return batches;
}

Future<ImageTexture> _decodeImageBytes(Uint8List bytes) async {
  // Support uncompressed 24/32-bit little-endian BMP directly on CPU as a
  // fast fallback, otherwise decode with `ui.instantiateImageCodec`.
  if (bytes.length >= 54 && bytes[0] == 0x42 && bytes[1] == 0x4D) {
    final bd = ByteData.sublistView(bytes);
    final dataOffset = bd.getUint32(10, Endian.little);
    final w = bd.getInt32(18, Endian.little).abs();
    final rawH = bd.getInt32(22, Endian.little);
    final topDown = rawH < 0;
    final h = rawH.abs();
    final bpp = bd.getUint16(28, Endian.little);
    final compression = bd.getUint32(30, Endian.little);
    if ((bpp == 24 || bpp == 32) && compression == 0 && w > 0 && h > 0) {
      final rowStride = ((bpp * w + 31) ~/ 32) * 4;
      if (dataOffset + rowStride * h <= bytes.length) {
        final rgba = Uint8List(w * h * 4);
        final pxBytes = bpp ~/ 8;
        for (var y = 0; y < h; y++) {
          final srcY = topDown ? y : (h - 1 - y);
          final srcRow = dataOffset + srcY * rowStride;
          for (var x = 0; x < w; x++) {
            final s = srcRow + x * pxBytes;
            final d = (y * w + x) * 4;
            rgba[d] = bytes[s + 2];
            rgba[d + 1] = bytes[s + 1];
            rgba[d + 2] = bytes[s];
            rgba[d + 3] = pxBytes == 4 ? bytes[s + 3] : 255;
          }
        }
        return ImageTexture(
          ByteData.sublistView(rgba),
          width: w,
          height: h,
        );
      }
    }
  }

  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final tex = await ImageTexture.create(frame.image);
  frame.image.dispose();
  return tex;
}

Future<Model> _materializePreparedGlb(_PreparedGlb prepared) async {
  prepared.warnings.forEach(GltfWarnings.report);
  final decodedImages = <ImageTexture>[];
  for (final imgTransfer in prepared.images) {
    final imgBytes = imgTransfer.materialize().asUint8List();
    decodedImages.add(await _decodeImageBytes(imgBytes));
  }

  Texture? resolveTexture(int? texIdx) {
    if (texIdx == null || texIdx < 0 || texIdx >= prepared.textures.length) {
      return null;
    }
    final t = prepared.textures[texIdx];
    final baseImg = decodedImages[t.source];
    final sampIdx = t.sampler;
    if (sampIdx == null || sampIdx < 0 || sampIdx >= prepared.samplers.length) {
      return baseImg;
    }
    final flameSampler = prepared.samplers[sampIdx].toFlameSampler();
    return ImageTexture(
      baseImg.sourceData,
      width: baseImg.width,
      height: baseImg.height,
      sampler: flameSampler,
      mipmaps: baseImg.mipmaps,
      gpuTexture: baseImg.gpuTexture,
    );
  }

  final builtMaterials = <Material>[];
  for (final pm in prepared.materials) {
    final cullMode = pm.doubleSided ? CullMode.none : CullMode.backFace;
    if (pm.isUnlit) {
      final unlit = UnlitMaterial(
        albedoColor: pm.baseColor,
        albedoTexture: resolveTexture(pm.baseColorTex),
      );
      unlit.renderState = pm.alphaMode == 'BLEND'
          ? RenderState.alphaBlend.copyWith(cullMode: cullMode)
          : RenderState.opaque;
      builtMaterials.add(unlit);
    } else {
      final mat = SpatialMaterial(
        albedoColor: pm.baseColor,
        albedoTexture: resolveTexture(pm.baseColorTex),
        metallic: pm.metallic,
        roughness: pm.roughness,
        metallicRoughnessTexture: resolveTexture(pm.metallicRoughnessTex),
        normalTexture: resolveTexture(pm.normalTex),
        normalScale: pm.normalScale,
        occlusionTexture: resolveTexture(pm.occlusionTex),
        occlusionStrength: pm.occlusionStrength,
        emissiveTexture: resolveTexture(pm.emissiveTex),
        emissiveColor: pm.emissiveColor,
        emissiveStrength: pm.emissiveStrength,
        uvOffset: Vector2(pm.uvOffsetX, pm.uvOffsetY),
        uvScale: Vector2(pm.uvScaleX, pm.uvScaleY),
        alphaCutoff: pm.alphaMode == 'MASK' ? pm.alphaCutoff : 0.0,
        doubleSided: pm.doubleSided,
        translucent: pm.alphaMode == 'BLEND',
      );
      mat.renderState = mat.renderState.copyWith(cullMode: cullMode);
      builtMaterials.add(mat);
    }
  }

  // A transferred buffer can be materialized once: meshes used by several
  // nodes get copies of the vertices (each node has its own surfaces, as
  // with ModelParser) and share the indices.
  final materialized =
      <
        _PreparedSurface,
        (
          Float32List,
          List<int>,
          List<MorphTargetData>,
          Map<String, SurfaceAttribute>,
        )
      >{};

  Mesh buildMesh(_PreparedMesh pm, List<double>? nodeWeights) {
    final mesh = Mesh();
    final weights = nodeWeights ?? pm.weights;
    for (final ps in pm.surfaces) {
      final Float32List verts;
      final List<int> indices;
      final List<MorphTargetData> morphs;
      final Map<String, SurfaceAttribute> custom;
      if (materialized[ps] case (final v, final i, final m, final c)) {
        verts = Float32List.fromList(v);
        indices = i;
        morphs = m;
        custom = c;
      } else {
        verts = ps.vertices.materialize().asFloat32List();
        final idxBuf = ps.indices.materialize();
        indices = ps.wideIndices
            ? idxBuf.asUint32List()
            : idxBuf.asUint16List();
        morphs = <MorphTargetData>[
          for (final m in ps.morphTargets)
            MorphTargetData(
              name: m.name,
              positionDeltas: m.posDeltas.materialize().asFloat32List(),
              normalDeltas: m.nrmDeltas?.materialize().asFloat32List(),
            ),
        ];
        custom = {
          for (final MapEntry(key: name, value: (components, values))
              in ps.customAttributes.entries)
            name: SurfaceAttribute(
              components,
              values.materialize().asFloat32List(),
            ),
        };
        materialized[ps] = (
          Float32List.fromList(verts),
          indices,
          morphs,
          custom,
        );
      }
      final mat =
          ps.materialIndex != null && ps.materialIndex! < builtMaterials.length
          ? builtMaterials[ps.materialIndex!]
          : SpatialMaterial(albedoColor: const ui.Color(0xFFFF00FF));
      final surface = Surface.fromBuffers(
        vertices: verts,
        indices: indices,
        material: mat,
        jointMap: ps.jointMap,
        morphTargets: morphs,
        customAttributes: custom,
      );
      if (weights != null && weights.isNotEmpty) {
        surface.applyMorphWeights(weights);
      }
      mesh.addSurface(surface);
    }
    return mesh;
  }

  final nodes = <int, ModelNode>{};
  for (final pn in prepared.nodes) {
    final mesh = pn.meshIndex != null
        ? buildMesh(prepared.meshes[pn.meshIndex!], pn.weights)
        : null;
    final modelJoints = <int, ModelJoint>{};
    if (pn.skinIndex != null) {
      final skin = prepared.skins[pn.skinIndex!];
      for (var j = 0; j < skin.joints.length; j++) {
        final ibm = skin.ibms != null && (j + 1) * 16 <= skin.ibms!.length
            ? Matrix4.fromList(skin.ibms!.sublist(j * 16, (j + 1) * 16))
            : Matrix4.identity();
        modelJoints[j] = ModelJoint(
          nodeIndex: skin.joints[j],
          inverseBindMatrix: ibm,
        );
      }
    }
    nodes[pn.nodeIndex] = ModelNode(
      name: pn.name,
      nodeIndex: pn.nodeIndex,
      parentNodeIndex: pn.parentNodeIndex,
      transform: Matrix4.fromList(pn.transformStorage),
      mesh: mesh,
      joints: modelJoints,
    );
  }

  final animations = <ModelAnimation>[];
  for (final pa in prepared.animations) {
    final ctrls = <int, List<AnimationController>>{};
    final morphs = <int, MorphWeightsChannel>{};
    for (final ch in pa.channels) {
      final interp = AnimationInterpolation.valueOf(ch.interpolation);
      final times = ch.times.toList(growable: false);
      if (ch.path == 'weights') {
        final divisor = interp == AnimationInterpolation.cubicSpline
            ? times.length * 3
            : times.length;
        final targetCount = divisor > 0 ? ch.values.length ~/ divisor : 0;
        if (targetCount > 0) {
          morphs[ch.nodeIndex] = MorphWeightsChannel(
            interpolation: interp,
            times: times,
            weights: ch.values.toList(growable: false),
            targetCount: targetCount,
          );
        }
        continue;
      }
      if (ch.path == 'translation') {
        final vecs = List<Vector3>.generate(
          ch.values.length ~/ 3,
          (i) => Vector3(
            ch.values[i * 3],
            ch.values[i * 3 + 1],
            ch.values[i * 3 + 2],
          ),
          growable: false,
        );
        (ctrls[ch.nodeIndex] ??= []).add(
          AnimationController(
            animation: TranslationAnimationSpline.from(
              interpolation: interp,
              times: times,
              values: vecs,
            ),
          ),
        );
      } else if (ch.path == 'scale') {
        final vecs = List<Vector3>.generate(
          ch.values.length ~/ 3,
          (i) => Vector3(
            ch.values[i * 3],
            ch.values[i * 3 + 1],
            ch.values[i * 3 + 2],
          ),
          growable: false,
        );
        (ctrls[ch.nodeIndex] ??= []).add(
          AnimationController(
            animation: ScaleAnimationSpline.from(
              interpolation: interp,
              times: times,
              values: vecs,
            ),
          ),
        );
      } else if (ch.path == 'rotation') {
        final quats = List<Quaternion>.generate(
          ch.values.length ~/ 4,
          (i) => Quaternion(
            ch.values[i * 4],
            ch.values[i * 4 + 1],
            ch.values[i * 4 + 2],
            ch.values[i * 4 + 3],
          ),
          growable: false,
        );
        (ctrls[ch.nodeIndex] ??= []).add(
          AnimationController(
            animation: RotationAnimationSpline.from(
              interpolation: interp,
              times: times,
              values: quats,
            ),
          ),
        );
      }
    }
    final nodeKeys = <int>{...ctrls.keys, ...morphs.keys};
    animations.add(
      ModelAnimation(
        name: pa.name,
        nodes: {
          for (final k in nodeKeys)
            k: NodeAnimation(
              channels: ctrls[k] ?? const [],
              morphWeights: morphs[k],
            ),
        },
      ),
    );
  }

  return Model(nodes: nodes, animations: animations);
}
