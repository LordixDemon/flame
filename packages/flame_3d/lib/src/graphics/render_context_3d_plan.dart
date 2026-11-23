part of 'render_context_3d.dart';

class _PassUniformRegistry() {
  final Map<String, PassUniformWriter> writers = {};
  final Map<String, PassTextureProvider> textures = {};
  final Map<String, int> customWriterKinds = {};
  int version = 0;

  final Int32List passKindEpochs = Int32List(_passKindCount)
    ..fillRange(0, _passKindCount, 1);
  final Int32List sharedPassEpochs = Int32List(_passKindCount)
    ..fillRange(0, _passKindCount, -1);
  final Int32List sharedPassFrames = Int32List(_passKindCount)
    ..fillRange(0, _passKindCount, -1);
  final Int32List sharedPassSigs = Int32List(_passKindCount);
  final List<GpuBuffer?> sharedPassBuffers = List.filled(_passKindCount, null);
  final Int32List sharedPassOffsets = Int32List(_passKindCount);
  final Int32List sharedPassLengths = Int32List(_passKindCount);

  final Map<GpuUniformSlot, UniformBlock> passBlocks = {};
  final Map<GpuUniformSlot, UniformBlock> jointBlocks = {};
  final Map<UniformBlock, List<UniformBlock>> stylizedPassViews = {};
  final Map<UniformBlock, List<UniformBlock>> spatialPassViews = {};

  void bumpAll(int epoch) {
    for (var k = 0; k < _passKindCount; k++) {
      passKindEpochs[k] = epoch;
    }
  }

  void bumpSceneColor(int epoch) {
    passKindEpochs[_passKindSceneColor] = epoch;
    passKindEpochs[_passKindPassOptions] = epoch;
    passKindEpochs[_passKindSpatial] = epoch;
    passKindEpochs[_passKindCustom] = epoch;
  }

  void bumpPassOptions(int epoch) {
    passKindEpochs[_passKindPassOptions] = epoch;
    passKindEpochs[_passKindSpatial] = epoch;
    passKindEpochs[_passKindCustom] = epoch;
  }

  void registerUniform(String name, PassUniformWriter? writer) {
    if (writer == null) {
      writers.remove(name);
      customWriterKinds.remove(name);
    } else {
      writers[name] = writer;
      final defaultKind = _defaultPassKindFor(name, writer);
      if (defaultKind > 0) {
        customWriterKinds.remove(name);
      } else {
        customWriterKinds[name] = 1;
      }
    }
    version++;
  }

  void registerTexture(String name, PassTextureProvider? provider) {
    if (provider == null) {
      textures.remove(name);
    } else {
      textures[name] = provider;
    }
    version++;
  }

  int resolvedPassKind(String name, PassUniformWriter writer) {
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
    if (customWriterKinds.containsKey(name)) {
      return _passKindCustom;
    }
    return _defaultPassKindFor(name, writer);
  }

  bool _allDefaultPassParts(List<String> parts) {
    for (var i = 0; i < parts.length; i++) {
      if (customWriterKinds.containsKey(parts[i])) {
        return false;
      }
    }
    return true;
  }
}

extension _RenderContext3DPlan on RenderContext3D {
  bool get _probeChanged =>
      _probeSelector.drawProbeSlot != _probeSelector.boundProbeSlot ||
      _probeSelector.drawProbeWeight != _probeSelector.boundProbeWeight;

  void _applyMaterial(
    Material material,
    Shader vertexShader,
    Shader fragmentShader,
  ) {
    RenderProfile.lap(RenderPhase.binding);
    _probeSelector
      ..boundProbeSlot = _probeSelector.drawProbeSlot
      ..boundProbeWeight = _probeSelector.drawProbeWeight;
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
    _jointCache.writeAndBind(device, js, joints);
  }

  void _bindBatchObjects(Shader vertexShader, RigidBatchBuffer? batch) {
    if (batch == null) {
      return;
    }
    final slot = _planFor(vertexShader).batchObjectsSlot;
    if (slot == null) {
      return;
    }
    device.bindRigidBatch(slot, batch);
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
    final reg = _passRegistry;
    final frame = device.frame;
    if (reg.sharedPassEpochs[_passKindJointsIdentity] == frame &&
        reg.sharedPassSigs[_passKindJointsIdentity] == js.layoutSignature) {
      final buf = reg.sharedPassBuffers[_passKindJointsIdentity];
      if (buf != null) {
        device.bindUniformSlice(
          js.slot,
          buf,
          offsetInBytes: reg.sharedPassOffsets[_passKindJointsIdentity],
          lengthInBytes: reg.sharedPassLengths[_passKindJointsIdentity],
        );
        return;
      }
    }
    device.bindUniformBlock(js.defaultBlock);
    if (!device.isSuspended && js.defaultBlock.uploadBuffer != null) {
      reg.sharedPassEpochs[_passKindJointsIdentity] = frame;
      reg.sharedPassSigs[_passKindJointsIdentity] = js.layoutSignature;
      reg.sharedPassBuffers[_passKindJointsIdentity] =
          js.defaultBlock.uploadBuffer;
      reg.sharedPassOffsets[_passKindJointsIdentity] =
          js.defaultBlock.uploadOffset;
      reg.sharedPassLengths[_passKindJointsIdentity] =
          js.defaultBlock.bytes.lengthInBytes;
    }
  }

  void _bindPassBlockEntry(_PassBlockEntry entry) {
    final reg = _passRegistry;
    final kind = entry.passKind;
    final epoch = reg.passKindEpochs[kind];
    final frame = device.frame;
    if (kind > 0 &&
        reg.sharedPassEpochs[kind] == epoch &&
        reg.sharedPassFrames[kind] == frame &&
        reg.sharedPassSigs[kind] == entry.layoutSignature) {
      final buf = reg.sharedPassBuffers[kind];
      if (buf != null) {
        device.bindUniformSlice(
          entry.slot,
          buf,
          offsetInBytes: reg.sharedPassOffsets[kind],
          lengthInBytes: reg.sharedPassLengths[kind],
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
      reg.sharedPassEpochs[kind] = epoch;
      reg.sharedPassFrames[kind] = frame;
      reg.sharedPassSigs[kind] = entry.layoutSignature;
      reg.sharedPassBuffers[kind] = entry.block.uploadBuffer;
      reg.sharedPassOffsets[kind] = entry.block.uploadOffset;
      reg.sharedPassLengths[kind] = entry.block.bytes.lengthInBytes;
    }
  }

  _ShaderPlan _planFor(Shader shader) {
    shader.resource;
    final reg = _passRegistry;
    final cached = shader.renderCache;
    if (cached is _ShaderPlan &&
        identical(cached.context, this) &&
        cached.version == reg.version &&
        cached.generation == shader.generation) {
      return cached;
    }
    final passBlocks = <_PassBlockEntry>[];
    final passSamplers = <_PassSamplerEntry>[];
    final materialBlocks = <_MatBlockEntry>[];
    final materialSamplers = <_MatSamplerEntry>[];
    _JointsEntry? jointsSlot;
    GpuUniformSlot? batchObjectsSlot;

    final shaderSlots = shader.slots;
    final resolvedSlots = shader.resolvedSlots;
    for (var i = 0; i < shaderSlots.length; i++) {
      final name = shaderSlots[i];
      final slot = resolvedSlots[i];
      if (slot.sizeInBytes == null) {
        final provider = reg.textures[name];
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
          reg.writers[name] ??
          (name == RenderContext3D.stylizedPassBlock
              ? _writeStylizedPass
              : (name == RenderContext3D.spatialPassBlock
                    ? _writeSpatialPass
                    : null));
      if (writer != null) {
        final block = reg.passBlocks[slot] ??= UniformBlock(slot);
        final kind = reg.resolvedPassKind(name, writer);
        final sig = kind > 0 ? _passLayoutSignature(kind, block) : 0;
        passBlocks.add(_PassBlockEntry(slot, block, writer, kind, sig));
      } else if (name == RenderContext3D.jointMatricesBlock) {
        final defaultBlock = reg.jointBlocks[slot] ??= UniformBlock(slot);
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
      } else if (name == RenderContext3D.batchObjectsBlock) {
        batchObjectsSlot = slot;
      } else {
        materialBlocks.add(
          _MatBlockEntry(slot, shader.blockIndexOf(name)),
        );
      }
    }

    final plan = _ShaderPlan(
      context: this,
      version: reg.version,
      generation: shader.generation,
      passBlocks: passBlocks,
      passSamplers: passSamplers,
      materialBlocks: materialBlocks,
      materialSamplers: materialSamplers,
      jointsSlot: jointsSlot,
      batchObjectsSlot: batchObjectsSlot,
    );
    shader.renderCache = plan;
    return plan;
  }
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
  required final GpuUniformSlot? batchObjectsSlot,
});
