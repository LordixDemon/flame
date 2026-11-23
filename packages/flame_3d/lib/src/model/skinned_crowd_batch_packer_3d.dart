part of 'skinned_crowd_batch_3d.dart';

extension _SkinnedCrowdBatchPacker on SkinnedCrowdBatch3D {
  void _classifyMeshNodes() {
    _skinnedMeshSlots.clear();
    _staticMeshSlots.clear();
    if (poseBanks.isEmpty || poseBanks.first.frames.isEmpty) {
      return;
    }
    final firstFrame = poseBanks.first.frames.first;
    for (var slot = 0; slot < firstFrame.length; slot++) {
      if (firstFrame[slot].isSkinned) {
        _skinnedMeshSlots.add(slot);
      } else {
        _staticMeshSlots.add(slot);
      }
    }
    _staticInstanceBuffers = List<Float32List>.generate(
      _staticMeshSlots.length,
      (_) => Float32List(_capacity * SkinnedCrowdBatch3D._instanceStride),
      growable: false,
    );
    _skinnedInstanceBuffers = List<Float32List>.generate(
      _skinnedMeshSlots.length,
      (_) => Float32List(_capacity * SkinnedCrowdBatch3D._instanceStride),
      growable: false,
    );
    _clipBaseOffsets = Int32List(poseBanks.length);
    var totalPoses = 0;
    for (var i = 0; i < poseBanks.length; i++) {
      _clipBaseOffsets[i] = totalPoses;
      totalPoses += poseBanks[i].frameCount;
    }
    _totalPoseCount = math.max(1, totalPoses);
    _bucketHead = Int32List(_totalPoseCount * 2)
      ..fillRange(0, _totalPoseCount * 2, -1);
    _usedBuckets = Int32List(_totalPoseCount * 2);
    _bucketNext = Int32List(_capacity);

    final skinnedCount = _skinnedMeshSlots.length;
    final maxBuckets = _totalPoseCount * 2;
    _skinnedPoseMirrorBits = List<Uint8List>.generate(
      skinnedCount,
      (s) {
        final slot = _skinnedMeshSlots[s];
        final bits = Uint8List(_totalPoseCount);
        for (var clipIdx = 0; clipIdx < poseBanks.length; clipIdx++) {
          final frames = poseBanks[clipIdx].frames;
          final base = _clipBaseOffsets[clipIdx];
          for (var frameIdx = 0; frameIdx < frames.length; frameIdx++) {
            final pose = frames[frameIdx][slot];
            bits[base + frameIdx] =
                isMirrored3x3(pose.combinedTransform.storage) ? 1 : 0;
          }
        }
        return bits;
      },
      growable: false,
    );
    _cachedBucketCount = Int32List(skinnedCount);
    _bucketStart = List<Int32List>.generate(
      skinnedCount,
      (_) => Int32List(maxBuckets),
      growable: false,
    );
    _bucketLen = List<Int32List>.generate(
      skinnedCount,
      (_) => Int32List(maxBuckets),
      growable: false,
    );
    _bucketClipIdx = List<Int32List>.generate(
      skinnedCount,
      (_) => Int32List(maxBuckets),
      growable: false,
    );
    _bucketFrameIdx = List<Int32List>.generate(
      skinnedCount,
      (_) => Int32List(maxBuckets),
      growable: false,
    );
    _bucketMirrored = List<Uint8List>.generate(
      skinnedCount,
      (_) => Uint8List(maxBuckets),
      growable: false,
    );
    _bucketCenters = List<Float32List>.generate(
      skinnedCount,
      (_) => Float32List(maxBuckets * 3),
      growable: false,
    );
  }

  void _rebuildPackedDraws(Matrix4 batchWorld, int worldVer) {
    final batchIsIdentity = batchWorld.isIdentity();
    final batchMirrorBit = !batchIsIdentity && isMirrored3x3(batchWorld.storage)
        ? 1
        : 0;

    var skinnedNodeDraws = 0;
    for (var s = 0; s < _skinnedMeshSlots.length; s++) {
      final slot = _skinnedMeshSlots[s];
      final samplePose = poseBanks.first.frames.first[slot];
      final mesh = samplePose.node.mesh;
      if (mesh == null) {
        _cachedBucketCount[s] = 0;
        continue;
      }
      final instBuf = _skinnedInstanceBuffers[s];
      final poseMirrorBits = _skinnedPoseMirrorBits[s];

      var usedBucketCount = 0;
      for (var i = _length - 1; i >= 0; i--) {
        final clipIdx = _clipIndices[i];
        final frameIdx = _frameIndices[i];
        final poseIdx = _clipBaseOffsets[clipIdx] + frameIdx;
        final poseMirrorBit = poseMirrorBits[poseIdx];
        final mirrorBit = batchMirrorBit ^ _agentMirrorBits[i] ^ poseMirrorBit;
        final bucketId = (poseIdx << 1) | mirrorBit;

        final prevHead = _bucketHead[bucketId];
        if (prevHead == -1) {
          _usedBuckets[usedBucketCount++] = bucketId;
        }
        _bucketNext[i] = prevHead;
        _bucketHead[bucketId] = i;
      }

      final starts = _bucketStart[s];
      final lens = _bucketLen[s];
      final clips = _bucketClipIdx[s];
      final frames = _bucketFrameIdx[s];
      final mirrored = _bucketMirrored[s];
      final centers = _bucketCenters[s];

      var cursor = 0;
      for (var u = 0; u < usedBucketCount; u++) {
        final bucketId = _usedBuckets[u];
        var i = _bucketHead[bucketId];
        _bucketHead[bucketId] = -1;

        final firstAgent = i;
        final startAgent = cursor;
        var sumX = 0.0;
        var sumY = 0.0;
        var sumZ = 0.0;

        while (i != -1) {
          final pose =
              poseBanks[_clipIndices[i]].frames[_frameIndices[i]][slot];
          _loadAgentWorldMatrix(
            batchWorld,
            i,
            _agentWorldScratch,
            batchIsIdentity: batchIsIdentity,
          );
          _drawMatrixScratch
            ..setFrom(_agentWorldScratch)
            ..multiply(pose.combinedTransform);

          final outBase = cursor * SkinnedCrowdBatch3D._instanceStride;
          final ms = _drawMatrixScratch.storage;
          for (var k = 0; k < 16; k++) {
            instBuf[outBase + k] = ms[k];
          }
          sumX += ms[12];
          sumY += ms[13];
          sumZ += ms[14];

          final cb = i * 8;
          for (var k = 0; k < 8; k++) {
            instBuf[outBase + 16 + k] = _colorsAndData[cb + k];
          }
          cursor++;
          skinnedNodeDraws++;
          i = _bucketNext[i];
        }

        final bucketCount = cursor - startAgent;
        final invCount = 1.0 / bucketCount;
        starts[u] = startAgent;
        lens[u] = bucketCount;
        clips[u] = _clipIndices[firstAgent];
        frames[u] = _frameIndices[firstAgent];
        mirrored[u] = bucketId & 1;
        final cOff = u * 3;
        centers[cOff] = sumX * invCount;
        centers[cOff + 1] = sumY * invCount;
        centers[cOff + 2] = sumZ * invCount;
      }
      _cachedBucketCount[s] = usedBucketCount;
    }

    for (var u = 0; u < _staticMeshSlots.length; u++) {
      final slot = _staticMeshSlots[u];
      final samplePose = poseBanks.first.frames.first[slot];
      if (samplePose.node.mesh == null) {
        continue;
      }
      final instBuf = _staticInstanceBuffers[u];
      for (var i = 0; i < _length; i++) {
        final pose = poseBanks[_clipIndices[i]].frames[_frameIndices[i]][slot];
        _loadAgentWorldMatrix(
          batchWorld,
          i,
          _agentWorldScratch,
          batchIsIdentity: batchIsIdentity,
        );
        _drawMatrixScratch
          ..setFrom(_agentWorldScratch)
          ..multiply(pose.combinedTransform);

        final outBase = i * SkinnedCrowdBatch3D._instanceStride;
        final ms = _drawMatrixScratch.storage;
        for (var k = 0; k < 16; k++) {
          instBuf[outBase + k] = ms[k];
        }
        final cb = i * 8;
        for (var k = 0; k < 8; k++) {
          instBuf[outBase + 16 + k] = _colorsAndData[cb + k];
        }
      }
    }

    _cachedSkinnedNodeDraws = skinnedNodeDraws;
    _packedStateVersion = _stateVersion;
    _packedWorldVersion = worldVer;
    _packedLength = _length;
    _packedInstanceVersion++;
  }

  void _loadAgentWorldMatrix(
    Matrix4 batchWorld,
    int index,
    Matrix4 out, {
    bool? batchIsIdentity,
  }) {
    final b = index * 16;
    for (var k = 0; k < 16; k++) {
      _agentLocalScratch.storage[k] = _transforms[b + k];
    }
    if (batchIsIdentity ?? batchWorld.isIdentity()) {
      out.setFrom(_agentLocalScratch);
    } else {
      out
        ..setFrom(batchWorld)
        ..multiply(_agentLocalScratch);
    }
  }

  void _writeAgentMatrix(int index, Matrix4 m) {
    final base = index * 16;
    final s = m.storage;
    for (var k = 0; k < 16; k++) {
      _transforms[base + k] = s[k];
    }
    _agentMirrorBits[index] = isMirrored3x3(s) ? 1 : 0;
  }
}

List<BakedClipPoseBank3D> _bakeCrowdModel(Model model, double fps) {
  final workspace = ModelPoseWorkspace.forModel(model);
  final state = AnimationState();
  final meshNodeIndices = <int>[
    for (var i = 0; i < workspace.orderedNodes.length; i++)
      if (workspace.orderedNodes[i].node.mesh != null) i,
  ];

  BakedClipPoseBank3D bakeSingle({
    required String? name,
    required double duration,
    required void Function(double time) evaluateAt,
  }) {
    final count = duration > 1e-9 ? math.max(1, (duration * fps).round()) : 1;
    final frames = <List<BakedNodePose3D>>[];
    final primaryBank = <Map<int, List<Matrix4>>>[];

    for (var f = 0; f < count; f++) {
      final t = count <= 1 ? 0.0 : (f / fps).clamp(0.0, duration);
      evaluateAt(t);

      final nodePoses = <BakedNodePose3D>[];
      Map<int, List<Matrix4>>? firstSkinnedJoints;
      for (final orderIdx in meshNodeIndices) {
        final processed = workspace.orderedNodes[orderIdx];
        final clonedJoints = <int, List<Matrix4>>{
          for (final entry in processed.jointTransforms.entries)
            entry.key: List<Matrix4>.unmodifiable([
              for (final jm in entry.value) jm.clone(),
            ]),
        };
        firstSkinnedJoints ??= clonedJoints.isNotEmpty ? clonedJoints : null;
        nodePoses.add(
          BakedNodePose3D(
            node: processed.node,
            combinedTransform: processed.combinedTransform.clone(),
            jointTransforms: Map<int, List<Matrix4>>.unmodifiable(clonedJoints),
          ),
        );
      }
      frames.add(List<BakedNodePose3D>.unmodifiable(nodePoses));
      primaryBank.add(firstSkinnedJoints ?? const {});
    }

    return BakedClipPoseBank3D(
      name: name,
      duration: duration,
      bakedFps: fps,
      frames: List<List<BakedNodePose3D>>.unmodifiable(frames),
      primaryJointBank: List<Map<int, List<Matrix4>>>.unmodifiable(primaryBank),
    );
  }

  if (model.animations.isEmpty) {
    return List<BakedClipPoseBank3D>.unmodifiable([
      bakeSingle(
        name: null,
        duration: 0.0,
        evaluateAt: (_) => model.evaluateInto(state, workspace),
      ),
    ]);
  }

  final banks = <BakedClipPoseBank3D>[];
  for (final clip in model.animations) {
    state.startAnimation(clip, mode: AnimationPlayMode.once);
    banks.add(
      bakeSingle(
        name: clip.name,
        duration: clip.lastTime,
        evaluateAt: (time) {
          state.clock = time;
          model.evaluateInto(state, workspace);
        },
      ),
    );
  }
  return List<BakedClipPoseBank3D>.unmodifiable(banks);
}
