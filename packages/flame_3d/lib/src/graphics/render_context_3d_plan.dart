part of 'render_context_3d.dart';

extension _RenderContext3DPlan on RenderContext3D {
  bool get _probeChanged =>
      _drawProbeSlot != _boundProbeSlot ||
      _drawProbeWeight != _boundProbeWeight;

  void _applyMaterial(
    Material material,
    Shader vertexShader,
    Shader fragmentShader,
  ) {
    RenderProfile.lap(RenderPhase.binding);
    _boundProbeSlot = _drawProbeSlot;
    _boundProbeWeight = _drawProbeWeight;
    materialTracker?.note(material);
    if (!material.cachesApply ||
        !material.isApplyCacheValid(this, vertexShader, fragmentShader)) {
      _activeApplyVertexShader = vertexShader;
      try {
        material.apply(this);
      } finally {
        _activeApplyVertexShader = null;
      }
      if (material.cachesApply) {
        material.recordApplyCache(this, vertexShader, fragmentShader);
      }
    }
    RenderProfile.lap(RenderPhase.materialApply);
    _bindMaterialPlan(_planFor(vertexShader), vertexShader);
    _bindMaterialPlan(_planFor(fragmentShader), fragmentShader);
    if (!identical(material, _boundMaterial)) {
      device.stats.materialChanges++;
      _boundMaterial = material;
    }
  }

  void _bindPassSlots(
    Material material,
    Shader vertexShader, {
    Shader? fragmentShader,
    bool skipJoints = false,
  }) {
    _bindPassPlan(_planFor(vertexShader), skipJoints: skipJoints);
    _bindPassPlan(
      _planFor(fragmentShader ?? material.fragmentShader),
      skipJoints: true,
    );
  }

  void _bindJoints(Shader vertexShader, List<Matrix4>? joints) {
    if (joints == null) {
      return;
    }
    final js = _planFor(vertexShader).jointsSlot;
    if (js == null) {
      return;
    }
    _writeAndBindJoints(js, joints);
  }

  void _bindMaterialPlan(_ShaderPlan plan, Shader shader) {
    final blocks = plan.materialBlocks;
    for (var i = 0; i < blocks.length; i++) {
      device.bindUniformBlock(shader.blockAt(blocks[i].blockIndex));
    }
    final samplers = plan.materialSamplers;
    for (var i = 0; i < samplers.length; i++) {
      final s = samplers[i];
      device.bindTexture(
        s.slot,
        shader.textureAt(s.samplerIndex) ?? Texture.standard,
      );
    }
  }

  void _bindPassPlan(_ShaderPlan plan, {bool skipJoints = false}) {
    final blocks = plan.passBlocks;
    for (var i = 0; i < blocks.length; i++) {
      _bindPassBlockEntry(blocks[i]);
    }
    final samplers = plan.passSamplers;
    for (var i = 0; i < samplers.length; i++) {
      final s = samplers[i];
      device.bindTexture(s.slot, s.provider(this));
    }
    final js = plan.jointsSlot;
    if (js != null && !skipJoints) {
      _bindDefaultJoints(js);
    }
  }

  void _bindDefaultJoints(_JointsEntry js) {
    final frame = device.frame;
    if (_sharedPassEpochs[_passKindJointsIdentity] == frame &&
        _sharedPassSigs[_passKindJointsIdentity] == js.layoutSignature) {
      final buf = _sharedPassBuffers[_passKindJointsIdentity];
      if (buf != null) {
        device.bindUniformSlice(
          js.slot,
          buf,
          offsetInBytes: _sharedPassOffsets[_passKindJointsIdentity],
          lengthInBytes: _sharedPassLengths[_passKindJointsIdentity],
        );
        return;
      }
    }
    device.bindUniformBlock(js.defaultBlock);
    if (!device.isSuspended && js.defaultBlock.uploadBuffer != null) {
      _sharedPassEpochs[_passKindJointsIdentity] = frame;
      _sharedPassSigs[_passKindJointsIdentity] = js.layoutSignature;
      _sharedPassBuffers[_passKindJointsIdentity] =
          js.defaultBlock.uploadBuffer;
      _sharedPassOffsets[_passKindJointsIdentity] =
          js.defaultBlock.uploadOffset;
      _sharedPassLengths[_passKindJointsIdentity] =
          js.defaultBlock.bytes.lengthInBytes;
    }
  }

  void _bindPassBlockEntry(_PassBlockEntry entry) {
    final kind = entry.passKind;
    final epoch = _passKindEpochs[kind];
    final frame = device.frame;
    if (kind > 0 &&
        _sharedPassEpochs[kind] == epoch &&
        _sharedPassFrames[kind] == frame &&
        _sharedPassSigs[kind] == entry.layoutSignature) {
      final buf = _sharedPassBuffers[kind];
      if (buf != null) {
        device.bindUniformSlice(
          entry.slot,
          buf,
          offsetInBytes: _sharedPassOffsets[kind],
          lengthInBytes: _sharedPassLengths[kind],
        );
        return;
      }
    }
    if (entry.writtenPass != epoch) {
      entry.writtenPass = epoch;
      RenderProfile.lap(RenderPhase.binding);
      entry.writer(this, entry.block);
      RenderProfile.lap(RenderPhase.uniformWrite);
    }
    device.bindUniformBlock(entry.block);
    if (kind > 0 && !device.isSuspended && entry.block.uploadBuffer != null) {
      _sharedPassEpochs[kind] = epoch;
      _sharedPassFrames[kind] = frame;
      _sharedPassSigs[kind] = entry.layoutSignature;
      _sharedPassBuffers[kind] = entry.block.uploadBuffer;
      _sharedPassOffsets[kind] = entry.block.uploadOffset;
      _sharedPassLengths[kind] = entry.block.bytes.lengthInBytes;
    }
  }

  _ShaderPlan _planFor(Shader shader) {
    shader.resource;
    final cached = shader.renderCache;
    if (cached is _ShaderPlan &&
        identical(cached.context, this) &&
        cached.version == _passUniformsVersion &&
        cached.generation == shader.generation) {
      return cached;
    }
    final passBlocks = <_PassBlockEntry>[];
    final passSamplers = <_PassSamplerEntry>[];
    final materialBlocks = <_MatBlockEntry>[];
    final materialSamplers = <_MatSamplerEntry>[];
    _JointsEntry? jointsSlot;

    final shaderSlots = shader.slots;
    final resolvedSlots = shader.resolvedSlots;
    for (var i = 0; i < shaderSlots.length; i++) {
      final name = shaderSlots[i];
      final slot = resolvedSlots[i];
      if (slot.sizeInBytes == null) {
        final provider = _passTextures[name];
        if (provider != null) {
          passSamplers.add(_PassSamplerEntry(slot, provider));
        } else {
          materialSamplers.add(
            _MatSamplerEntry(slot, shader.samplerIndexOf(name)),
          );
        }
        continue;
      }
      final writer =
          _passUniforms[name] ??
          (name == RenderContext3D.stylizedPassBlock
              ? _writeStylizedPass
              : (name == RenderContext3D.spatialPassBlock
                    ? _writeSpatialPass
                    : null));
      if (writer != null) {
        final block = _passBlocks[slot] ??= UniformBlock(slot);
        final kind = _resolvedPassKind(name, writer);
        final sig = kind > 0 ? _passLayoutSignature(kind, block) : 0;
        passBlocks.add(_PassBlockEntry(slot, block, writer, kind, sig));
      } else if (name == RenderContext3D.jointMatricesBlock) {
        final defaultBlock = _jointBlocks[slot] ??= UniformBlock(slot);
        final rows = defaultBlock.resolveOffset(
          RenderContext3D.jointRowsMember,
        );
        final joints = rows >= 0
            ? UniformBlock.missingOffset
            : (defaultBlock.memberOffset('joints') ?? 0);
        final capacity = rows >= 0
            ? (defaultBlock.data.length - rows) ~/ 12
            : (defaultBlock.data.length - joints) ~/ 16;
        final sig = Object.hash(slot.sizeInBytes ?? 0, rows, joints);
        jointsSlot = _JointsEntry(
          slot,
          defaultBlock,
          rows,
          joints,
          capacity,
          sig,
        );
      } else {
        materialBlocks.add(
          _MatBlockEntry(slot, shader.blockIndexOf(name)),
        );
      }
    }

    final plan = _ShaderPlan(
      context: this,
      version: _passUniformsVersion,
      generation: shader.generation,
      passBlocks: passBlocks,
      passSamplers: passSamplers,
      materialBlocks: materialBlocks,
      materialSamplers: materialSamplers,
      jointsSlot: jointsSlot,
    );
    shader.renderCache = plan;
    return plan;
  }

  int _resolvedPassKind(String name, PassUniformWriter writer) {
    if (name == RenderContext3D.stylizedPassBlock &&
        identical(writer, _writeStylizedPass)) {
      return _allDefaultPassParts(RenderContext3D._stylizedPassParts)
          ? _passKindStylized
          : _passKindCustom;
    }
    if (name == RenderContext3D.spatialPassBlock &&
        identical(writer, _writeSpatialPass)) {
      return _allDefaultPassParts(RenderContext3D._spatialPassParts)
          ? _passKindSpatial
          : _passKindCustom;
    }
    if (_customWriterKinds.containsKey(name)) {
      return _passKindCustom;
    }
    return _defaultPassKindFor(name, writer);
  }

  bool _allDefaultPassParts(List<String> parts) {
    for (var i = 0; i < parts.length; i++) {
      if (_customWriterKinds.containsKey(parts[i])) {
        return false;
      }
    }
    return true;
  }

  void _writeAndBindJoints(_JointsEntry js, List<Matrix4> joints) {
    final count = joints.length;
    if (count > js.capacity) {
      throw StateError(
        'At most ${js.capacity} joints per surface are supported; '
        'found $count',
      );
    }
    final isRow = js.isRowMode;
    final stride = isRow ? 12 : 16;
    final base = isRow ? js.rowsOffset : js.jointsOffset;
    final floatLen = js.defaultBlock.data.length;
    final byteLen = floatLen * 4;

    final frame = device.frame;
    if (_jointCacheFrame != frame) {
      _jointCacheFrame = frame;
      final table = _jointHashTable;
      for (var k = 0; k < _jointHashCount; k++) {
        final slot = _jointHashUsed[k];
        final e = table[slot];
        if (e != null) {
          _jointCachePool.add(e);
          table[slot] = null;
        }
      }
      _jointHashCount = 0;
    }

    final hash = _hashJoints(joints, count, isRow, floatLen, base);
    final table = _jointHashTable;
    var slot = hash & RenderContext3D._jointHashTableMask;
    while (true) {
      final e = table[slot];
      if (e == null) {
        break;
      }
      if (e.hash == hash &&
          e.isRow == isRow &&
          e.floatLen == floatLen &&
          e.jointCount == count &&
          e.base == base &&
          _jointsMatchSnapshot(e.snapshot, joints, count, isRow)) {
        RenderProfile.lap(RenderPhase.uniformWrite);
        device.bindUniformSlice(
          js.slot,
          e.buffer,
          offsetInBytes: e.offset,
          lengthInBytes: byteLen,
        );
        return;
      }
      slot = (slot + 1) & RenderContext3D._jointHashTableMask;
    }

    if (_jointPackScratch.length < floatLen) {
      _jointPackScratch = Float32List(floatLen);
      _jointPackBytes = _jointPackScratch.buffer.asUint8List();
      _jointPackDirtyStart = 0;
      _jointPackDirtyEnd = 0;
    }
    final scratch = _jointPackScratch;
    final writtenEnd = base + count * stride;
    if (_jointPackDirtyEnd > _jointPackDirtyStart) {
      if (_jointPackDirtyStart < base) {
        final clearEnd = base < _jointPackDirtyEnd ? base : _jointPackDirtyEnd;
        if (clearEnd > _jointPackDirtyStart) {
          scratch.fillRange(_jointPackDirtyStart, clearEnd, 0.0);
        }
      }
      if (writtenEnd < _jointPackDirtyEnd) {
        final clearStart = writtenEnd > _jointPackDirtyStart
            ? writtenEnd
            : _jointPackDirtyStart;
        if (_jointPackDirtyEnd > clearStart) {
          scratch.fillRange(clearStart, _jointPackDirtyEnd, 0.0);
        }
      }
    }
    _jointPackDirtyStart = base;
    _jointPackDirtyEnd = writtenEnd;

    if (isRow) {
      for (var i = 0; i < count; i++) {
        final m = joints[i].storage;
        final o = base + i * 12;
        scratch
          ..[o] = m[0]
          ..[o + 1] = m[4]
          ..[o + 2] = m[8]
          ..[o + 3] = m[12]
          ..[o + 4] = m[1]
          ..[o + 5] = m[5]
          ..[o + 6] = m[9]
          ..[o + 7] = m[13]
          ..[o + 8] = m[2]
          ..[o + 9] = m[6]
          ..[o + 10] = m[10]
          ..[o + 11] = m[14];
      }
    } else {
      for (var i = 0; i < count; i++) {
        scratch.setRange(base + i * 16, base + (i + 1) * 16, joints[i].storage);
      }
    }

    RenderProfile.lap(RenderPhase.uniformWrite);
    final buf = device.uploadUniformRange(_jointPackBytes, byteLen);
    if (buf == null) {
      return;
    }
    final off = device.lastUploadedOffset;
    device.bindUniformSlice(
      js.slot,
      buf,
      offsetInBytes: off,
      lengthInBytes: byteLen,
    );
    if (_jointHashCount >= RenderContext3D._maxJointCacheEntries) {
      return;
    }
    final entry = _jointCachePool.isNotEmpty
        ? _jointCachePool.removeLast()
        : _JointUploadEntry();
    entry.store(
      hash: hash,
      isRow: isRow,
      floatLen: floatLen,
      jointCount: count,
      base: base,
      joints: joints,
      written: count * stride,
      buffer: buf,
      offset: off,
    );
    table[slot] = entry;
    _jointHashUsed[_jointHashCount++] = slot;
  }
}

final Float32List _jointHashF32 = Float32List(18);
final Uint32List _jointHashU32 = _jointHashF32.buffer.asUint32List();

@pragma('vm:prefer-inline')
void _writeJointHashSample(List<Matrix4> joints, int index, int dstFloat) {
  final m = joints[index].storage;
  _jointHashF32
    ..[dstFloat] = m[0]
    ..[dstFloat + 1] = m[5]
    ..[dstFloat + 2] = m[10]
    ..[dstFloat + 3] = m[12]
    ..[dstFloat + 4] = m[13]
    ..[dstFloat + 5] = m[14];
}

int _hashJoints(
  List<Matrix4> joints,
  int count,
  bool isRow,
  int floatLen,
  int base,
) {
  var h = (isRow ? 1 : 0) ^ (floatLen * 31) ^ (count * 131) ^ (base * 1009);
  if (count <= 0) {
    return h & 0x1fffffff;
  }
  int floats;
  _writeJointHashSample(joints, 0, 0);
  if (count == 1) {
    floats = 6;
  } else if (count == 2) {
    _writeJointHashSample(joints, 1, 6);
    floats = 12;
  } else {
    _writeJointHashSample(joints, count >> 1, 6);
    _writeJointHashSample(joints, count - 1, 12);
    floats = 18;
  }
  final u32 = _jointHashU32;
  for (var k = 0; k < floats; k++) {
    final bits = u32[k];
    final norm = bits == 0x80000000 ? 0 : bits;
    h = 0x1fffffff & (h * 31 + norm);
  }
  return h;
}

bool _jointsMatchSnapshot(
  Float64List snapshot,
  List<Matrix4> joints,
  int count,
  bool isRow,
) {
  if (isRow) {
    for (var i = 0; i < count; i++) {
      final m = joints[i].storage;
      final o = i * 12;
      if (snapshot[o] != m[0] ||
          snapshot[o + 1] != m[4] ||
          snapshot[o + 2] != m[8] ||
          snapshot[o + 3] != m[12] ||
          snapshot[o + 4] != m[1] ||
          snapshot[o + 5] != m[5] ||
          snapshot[o + 6] != m[9] ||
          snapshot[o + 7] != m[13] ||
          snapshot[o + 8] != m[2] ||
          snapshot[o + 9] != m[6] ||
          snapshot[o + 10] != m[10] ||
          snapshot[o + 11] != m[14]) {
        return false;
      }
    }
    return true;
  }
  for (var i = 0; i < count; i++) {
    final m = joints[i].storage;
    final o = i * 16;
    for (var k = 0; k < 16; k++) {
      if (snapshot[o + k] != m[k]) {
        return false;
      }
    }
  }
  return true;
}

const int _passKindCustom = 0;
const int _passKindCameraMatrices = 1;
const int _passKindCamera = 2;
const int _passKindAmbient = 3;
const int _passKindLights = 4;
const int _passKindDirLights = 5;
const int _passKindSpotLights = 6;
const int _passKindHemi = 7;
const int _passKindLightGrid = 8;
const int _passKindShadows = 9;
const int _passKindShadowAtlas = 10;
const int _passKindFog = 11;
const int _passKindWaterVolume = 12;
const int _passKindDepthNormal = 13;
const int _passKindSceneColor = 14;
const int _passKindPassOptions = 15;
const int _passKindShadowCaster = 16;
const int _passKindStylized = 17;
const int _passKindSpatial = 18;
const int _passKindJointsIdentity = 19;
const int _passKindCount = 20;

int _defaultPassKindFor(String name, PassUniformWriter writer) {
  if (name == RenderContext3D.cameraMatricesBlock &&
      identical(writer, RenderContext3D.writeCameraUniforms)) {
    return _passKindCameraMatrices;
  }
  if (name == RenderContext3D.cameraBlock &&
      identical(writer, RenderContext3D.writeCameraUniforms)) {
    return _passKindCamera;
  }
  if (name == RenderContext3D.ambientLightBlock &&
      identical(writer, RenderContext3D.writeAmbientLightUniforms)) {
    return _passKindAmbient;
  }
  if (name == RenderContext3D.lightsBlock &&
      identical(writer, RenderContext3D.writeLightsUniforms)) {
    return _passKindLights;
  }
  if (name == RenderContext3D.directionalLightsBlock &&
      identical(writer, RenderContext3D.writeDirectionalLightsUniforms)) {
    return _passKindDirLights;
  }
  if (name == RenderContext3D.spotLightsBlock &&
      identical(writer, RenderContext3D.writeSpotLightsUniforms)) {
    return _passKindSpotLights;
  }
  if (name == RenderContext3D.hemisphereLightBlock &&
      identical(writer, RenderContext3D.writeHemisphereLightUniforms)) {
    return _passKindHemi;
  }
  if (name == RenderContext3D.lightGridBlock &&
      identical(writer, RenderContext3D.writeLightGridUniforms)) {
    return _passKindLightGrid;
  }
  if (name == RenderContext3D.shadowsBlock &&
      identical(writer, RenderContext3D.writeShadowsUniforms)) {
    return _passKindShadows;
  }
  if (name == RenderContext3D.shadowAtlasBlock &&
      identical(writer, _ShadowPass.writeAtlasUniforms)) {
    return _passKindShadowAtlas;
  }
  if (name == RenderContext3D.fogBlock &&
      identical(writer, RenderContext3D.writeFogUniforms)) {
    return _passKindFog;
  }
  if (name == RenderContext3D.waterVolumeBlock &&
      identical(writer, RenderContext3D.writeWaterVolumeUniforms)) {
    return _passKindWaterVolume;
  }
  if (name == RenderContext3D.depthNormalBlock &&
      identical(writer, _DepthNormalPass.writeUniforms)) {
    return _passKindDepthNormal;
  }
  if (name == RenderContext3D.sceneColorBlock &&
      identical(writer, _OitAndGrabPass.writeSceneColorUniforms)) {
    return _passKindSceneColor;
  }
  if (name == RenderContext3D.passOptionsBlock &&
      identical(writer, RenderContext3D.writePassOptionsUniforms)) {
    return _passKindPassOptions;
  }
  if (name == RenderContext3D.shadowCasterBlock &&
      identical(writer, _ShadowPass.writeCasterUniforms)) {
    return _passKindShadowCaster;
  }
  return _passKindCustom;
}

int _passLayoutSignature(int kind, UniformBlock block) {
  final len = block.bytes.lengthInBytes;
  if (kind == _passKindSpatial) {
    return Object.hash(
      len,
      block.resolveOffset('PassOptions_flags'),
      block.resolveOffset('Lights_numLights'),
      block.resolveOffset('Shadows_atlas'),
      block.resolveOffset('LightGrid_counts'),
    );
  }
  if (kind == _passKindStylized) {
    return Object.hash(
      len,
      block.resolveOffset('Camera_view'),
      block.resolveOffset('Lights_numLights'),
      block.resolveOffset('WaterVolume_plane'),
    );
  }
  return len;
}

class _PassBlockEntry(
  final GpuUniformSlot slot,
  final UniformBlock block,
  final PassUniformWriter writer,
  final int passKind,
  final int layoutSignature,
) {
  int writtenPass = -1;
}

class _PassSamplerEntry(
  final GpuUniformSlot slot,
  final PassTextureProvider provider,
);

class _MatBlockEntry(
  final GpuUniformSlot slot,
  final int blockIndex,
);

class _MatSamplerEntry(
  final GpuUniformSlot slot,
  final int samplerIndex,
);

class _JointsEntry(
  final GpuUniformSlot slot,
  final UniformBlock defaultBlock,
  final int rowsOffset,
  final int jointsOffset,
  final int capacity,
  final int layoutSignature,
) {
  bool get isRowMode => rowsOffset >= 0;
}

class _ShaderPlan({
  required final RenderContext3D context,
  required final int version,
  required final int generation,
  required final List<_PassBlockEntry> passBlocks,
  required final List<_PassSamplerEntry> passSamplers,
  required final List<_MatBlockEntry> materialBlocks,
  required final List<_MatSamplerEntry> materialSamplers,
  required final _JointsEntry? jointsSlot,
});

class _JointUploadEntry() {
  int hash = 0;
  bool isRow = false;
  int floatLen = 0;
  int jointCount = 0;
  int base = 0;
  Float64List snapshot = Float64List(0);
  late GpuBuffer buffer;
  int offset = 0;

  void store({
    required int hash,
    required bool isRow,
    required int floatLen,
    required int jointCount,
    required int base,
    required List<Matrix4> joints,
    required int written,
    required GpuBuffer buffer,
    required int offset,
  }) {
    this.hash = hash;
    this.isRow = isRow;
    this.floatLen = floatLen;
    this.jointCount = jointCount;
    this.base = base;
    this.buffer = buffer;
    this.offset = offset;
    if (snapshot.length < written) {
      snapshot = Float64List(written);
    }
    if (isRow) {
      for (var i = 0; i < jointCount; i++) {
        final m = joints[i].storage;
        final o = i * 12;
        snapshot
          ..[o] = m[0]
          ..[o + 1] = m[4]
          ..[o + 2] = m[8]
          ..[o + 3] = m[12]
          ..[o + 4] = m[1]
          ..[o + 5] = m[5]
          ..[o + 6] = m[9]
          ..[o + 7] = m[13]
          ..[o + 8] = m[2]
          ..[o + 9] = m[6]
          ..[o + 10] = m[10]
          ..[o + 11] = m[14];
      }
    } else {
      for (var i = 0; i < jointCount; i++) {
        snapshot.setRange(i * 16, (i + 1) * 16, joints[i].storage);
      }
    }
  }
}
