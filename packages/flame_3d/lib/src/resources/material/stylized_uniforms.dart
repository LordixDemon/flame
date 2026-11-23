part of 'stylized_material.dart';

extension _StylizedUniforms on StylizedMaterial {
  void _recordVertexFull(Shader shader, int nonTimeVersion, int deviceGen) {
    if (_vertFullNonTimeVersion != nonTimeVersion ||
        _vertFullDeviceGen != deviceGen) {
      _vertFullNonTimeVersion = nonTimeVersion;
      _vertFullDeviceGen = deviceGen;
      _vertFullMask = 0;
      _vertFullCustomShader = null;
    }
    final slot = _variantSlot(shader);
    if (slot < 0) {
      _vertFullCustomShader = shader;
      _vertFullCustomGen = shader.generation;
    } else {
      _vertFullMask |= 1 << slot;
      _vertFullVarGens[slot] = shader.generation;
    }
  }

  void _applyUniforms(RenderContext context) {
    final nonTimeVersion = version - animationVersion;
    final deviceGen = GpuBackend.deviceGeneration;
    final frag = fragmentShader;
    frag.resource;
    final fragClean =
        _fragAppliedNonTimeVersion == nonTimeVersion &&
        identical(_fragAppliedShader, frag) &&
        _fragAppliedGen == frag.generation &&
        _fragAppliedDeviceGen == deviceGen;
    final activeVert = context is RenderContext3D
        ? context.activeApplyVertexShader
        : null;
    if (activeVert != null && fragClean) {
      activeVert.resource;
      final slot = _variantSlot(activeVert);
      final vertGen = activeVert.generation;
      final vertClean =
          _vertFullNonTimeVersion == nonTimeVersion &&
          _vertFullDeviceGen == deviceGen &&
          (slot < 0
              ? (identical(_vertFullCustomShader, activeVert) &&
                    _vertFullCustomGen == vertGen)
              : ((_vertFullMask & (1 << slot)) != 0 &&
                    _vertFullVarGens[slot] == vertGen));
      if (vertClean) {
        if (!identical(activeVert, _standardVertexShader) &&
            !identical(activeVert, _texturedStandardVertexShader)) {
          _applyWindTimeOnly(activeVert);
        }
        return;
      }
    }

    final space = windSpace;
    if (activeVert != null) {
      if (identical(activeVert, _standardVertexShader) ||
          identical(activeVert, _texturedStandardVertexShader)) {
        _applyDepthBias(activeVert);
      } else {
        _unitOrZero(
          _upAxis,
          space == WindSpace.worldScaled ? windUpAxis : StylizedMaterial._zero,
          1,
        );
        _unitOrZero(_gustWave, windGustDirection, windGustPhaseScale);
        _applyWind(activeVert, space);
      }
      _recordVertexFull(activeVert, nonTimeVersion, deviceGen);
    } else {
      _unitOrZero(
        _upAxis,
        space == WindSpace.worldScaled ? windUpAxis : StylizedMaterial._zero,
        1,
      );
      _unitOrZero(_gustWave, windGustDirection, windGustPhaseScale);
      _applyWind(vertexShader, space);
      _recordVertexFull(vertexShader, nonTimeVersion, deviceGen);
      if (_skinnedInUse) {
        _applyWind(_skinnedVertexShader, space);
        _recordVertexFull(_skinnedVertexShader, nonTimeVersion, deviceGen);
      }
      if (_standardInUse) {
        _applyDepthBias(_standardVertexShader);
        _recordVertexFull(_standardVertexShader, nonTimeVersion, deviceGen);
      }
      if (_texturedInUse) {
        _applyWind(_texturedVertexShader, space);
        _recordVertexFull(_texturedVertexShader, nonTimeVersion, deviceGen);
      }
      if (_texturedSkinnedInUse) {
        _applyWind(_texturedSkinnedVertexShader, space);
        _recordVertexFull(
          _texturedSkinnedVertexShader,
          nonTimeVersion,
          deviceGen,
        );
      }
      if (_texturedStandardInUse) {
        _applyDepthBias(_texturedStandardVertexShader);
        _recordVertexFull(
          _texturedStandardVertexShader,
          nonTimeVersion,
          deviceGen,
        );
      }
      if (_batchedInUse) {
        _applyWind(_batchedVertexShader, space);
        _recordVertexFull(_batchedVertexShader, nonTimeVersion, deviceGen);
      }
    }

    if (fragClean) {
      return;
    }
    final baseColor = baseColorTexture;
    final isTextured = baseColor != null && _textured;
    final matCap = matCapTexture;
    final gemMatCap = gemMatCapTexture;
    final samplers = _samplersFor(frag);
    if (isTextured) {
      if (samplers._baseColor >= 0) {
        frag.setTextureAt(samplers._baseColor, baseColor);
      } else {
        frag.setTexture('baseColorTexture', baseColor);
      }
    }
    if (samplers._matCap >= 0) {
      frag.setTextureAt(samplers._matCap, matCap ?? Texture.empty);
    } else {
      frag.setTexture('matCapTexture', matCap ?? Texture.empty);
    }
    if (samplers._gemMatCap >= 0) {
      frag.setTextureAt(samplers._gemMatCap, gemMatCap ?? Texture.empty);
    } else {
      frag.setTexture('gemMatCapTexture', gemMatCap ?? Texture.empty);
    }

    final matIdx = frag.blockIndexOf('Material');
    if (matIdx < 0) {
      return;
    }
    final matBlock = frag.blockAt(matIdx);
    final off =
        (matBlock.cachedWriterOffsets as _StylizedMaterialOffsets?) ??
        (matBlock.cachedWriterOffsets = _StylizedMaterialOffsets(matBlock));

    if (isTextured) {
      if (off._baseColorReplace >= 0) {
        matBlock.writeFloatAt(
          off._baseColorReplace,
          baseColorTextureMode == BaseColorTextureMode.replace ? 1 : 0,
        );
      }
      if (off._alphaCutoff >= 0) {
        matBlock.writeFloatAt(off._alphaCutoff, alphaCutoff);
      }
    }

    final paletteCount =
        accentPalette.length < StylizedMaterial.maxAccentPaletteSize
        ? accentPalette.length
        : StylizedMaterial.maxAccentPaletteSize;
    if (off._accentPaletteCount >= 0) {
      matBlock.writeFloatAt(off._accentPaletteCount, paletteCount.toDouble());
    }
    if (off._accentPalette >= 0) {
      for (var i = 0; i < paletteCount; i++) {
        matBlock.writeColorAt(off._accentPalette + i * 4, accentPalette[i]);
      }
    }
    if (off._rimPaletteCount >= 0) {
      final rimCount = rimPalette.length < StylizedMaterial.maxRimPaletteSize
          ? rimPalette.length
          : StylizedMaterial.maxRimPaletteSize;
      matBlock.writeFloatAt(off._rimPaletteCount, rimCount.toDouble());
      if (off._rimPalettePower >= 0) {
        matBlock.writeFloatAt(off._rimPalettePower, rimPalettePower);
      }
      if (off._rimPaletteStrength >= 0) {
        matBlock.writeFloatAt(off._rimPaletteStrength, rimPaletteStrength);
      }
      if (off._rimPalette >= 0) {
        for (var i = 0; i < rimCount; i++) {
          matBlock.writeColorAt(off._rimPalette + i * 4, rimPalette[i]);
        }
      }
    }

    if (off._emissiveColorSource >= 0) {
      matBlock.writeFloatAt(
        off._emissiveColorSource,
        emissiveColorSource.index.toDouble(),
      );
    }
    if (off._emissiveBoostFollows >= 0) {
      matBlock.writeFloatAt(
        off._emissiveBoostFollows,
        emissiveBoostColor == null ? 1 : 0,
      );
    }

    final weight = skyFillWeight;
    if (off._albedoColor >= 0) {
      matBlock.writeColorAt(off._albedoColor, albedoColor);
    }
    if (off._accentColor >= 0) {
      matBlock.writeColorAt(off._accentColor, accentColor);
    }
    if (off._emissiveColor >= 0) {
      matBlock.writeColorAt(off._emissiveColor, emissiveColor);
    }
    if (off._emissiveBoostColor >= 0) {
      matBlock.writeColorAt(
        off._emissiveBoostColor,
        emissiveBoostColor ?? emissiveColor,
      );
    }
    if (off._ambientBase >= 0) {
      matBlock.writeColorAt(off._ambientBase, ambientBase);
    }
    if (off._skyFill >= 0) {
      matBlock.writeVec4ValuesAt(
        off._skyFill,
        skyFill * weight.x,
        skyFill * weight.y,
        skyFill * weight.z,
        0,
      );
    }
    if (off._rimColor >= 0) {
      matBlock.writeColorAt(off._rimColor, rimColor);
    }
    if (off._highlightColor >= 0) {
      matBlock.writeColorAt(off._highlightColor, highlightColor);
    }
    if (off._emissiveStrength >= 0) {
      matBlock.writeFloatAt(off._emissiveStrength, emissiveStrength);
    }
    if (off._groundBounce >= 0) {
      matBlock.writeFloatAt(off._groundBounce, groundBounce);
    }
    if (off._pointLightWrap >= 0) {
      matBlock.writeFloatAt(off._pointLightWrap, pointLightWrap);
    }
    if (off._specularStrength >= 0) {
      matBlock.writeFloatAt(off._specularStrength, specularStrength);
    }
    if (off._specularPower >= 0) {
      matBlock.writeFloatAt(off._specularPower, specularPower);
    }
    if (off._specularThreshold >= 0) {
      matBlock.writeFloatAt(off._specularThreshold, specularThreshold);
    }
    if (off._rimStrength >= 0) {
      matBlock.writeFloatAt(off._rimStrength, rimStrength);
    }
    if (off._rimPower >= 0) {
      matBlock.writeFloatAt(off._rimPower, rimPower);
    }
    if (off._matCapStrength >= 0) {
      matBlock.writeFloatAt(
        off._matCapStrength,
        matCap == null ? 0 : matCapStrength,
      );
    }
    // Without a MatCap texture no vertex gets one: a metallic material
    // then keeps the lit color instead of reflecting nothing.
    if (off._matCapThreshold >= 0) {
      matBlock.writeFloatAt(
        off._matCapThreshold,
        matCap == null ? StylizedMaterial._never : matCapThreshold,
      );
    }
    if (off._matCapGlossWeight >= 0) {
      matBlock.writeFloatAt(off._matCapGlossWeight, matCapGlossWeight);
    }
    if (off._gemMatCapStrength >= 0) {
      matBlock.writeFloatAt(
        off._gemMatCapStrength,
        gemMatCap == null ? 0 : gemMatCapStrength,
      );
    }
    // Without a gem texture no vertex is a gem: every glossy vertex gets
    // the first MatCap texture.
    if (off._gemThreshold >= 0) {
      matBlock.writeFloatAt(
        off._gemThreshold,
        gemMatCap == null ? StylizedMaterial._never : gemThreshold,
      );
    }
    if (off._matCapMetallic >= 0) {
      matBlock.writeFloatAt(off._matCapMetallic, matCapMetallic);
    }
    if (off._saturation >= 0) {
      matBlock.writeFloatAt(off._saturation, saturation);
    }
    if (off._overlayColor >= 0) {
      matBlock.writeColorAt(off._overlayColor, overlayColor);
    }
    if (off._ditherFade >= 0) {
      matBlock.writeFloatAt(off._ditherFade, ditherFade ? 1.0 : 0.0);
    }
    _fragAppliedNonTimeVersion = nonTimeVersion;
    _fragAppliedShader = frag;
    _fragAppliedGen = frag.generation;
    _fragAppliedDeviceGen = deviceGen;
  }

  _StylizedSamplerIndices _samplersFor(Shader frag) {
    if (!identical(_samplerCacheFrag, frag) ||
        _samplerCacheGen != frag.generation) {
      _samplerCacheFrag = frag;
      _samplerCacheGen = frag.generation;
      _samplerCache = _StylizedSamplerIndices(
        frag.samplerIndexOf('matCapTexture'),
        frag.samplerIndexOf('gemMatCapTexture'),
        frag.samplerIndexOf('baseColorTexture'),
      );
    }
    return _samplerCache!;
  }

  void _applyDepthBias(Shader shader) {
    shader.resource;
    final idx = shader.blockIndexOf(StylizedMaterial._depthBlock);
    if (idx < 0) {
      shader.setFloat('${StylizedMaterial._depthBlock}.bias', depthBias);
      return;
    }
    final block = shader.blockAt(idx);
    final off =
        (block.cachedWriterOffsets as int?) ??
        (block.cachedWriterOffsets = block.resolveOffset('bias'));
    if (off >= 0) {
      block.writeFloatAt(off, depthBias);
    }
  }

  void _applyWindTimeOnly(Shader shader) {
    shader.resource;
    final idx = shader.blockIndexOf('Wind');
    if (idx < 0) {
      return;
    }
    final block = shader.blockAt(idx);
    final off =
        (block.cachedWriterOffsets as _WindBlockOffsets?) ??
        (block.cachedWriterOffsets = _WindBlockOffsets(block));
    if (off._time >= 0) {
      block.writeFloatAt(off._time, windTime);
    }
  }

  void _applyWind(Shader shader, WindSpace space) {
    shader.resource;
    final idx = shader.blockIndexOf('Wind');
    if (idx < 0) {
      return;
    }
    final block = shader.blockAt(idx);
    final off =
        (block.cachedWriterOffsets as _WindBlockOffsets?) ??
        (block.cachedWriterOffsets = _WindBlockOffsets(block));
    final inModelSpace = space == WindSpace.model;
    final dir = inModelSpace ? StylizedMaterial._zero : windDirection;
    final modelDir = inModelSpace ? windDirection : StylizedMaterial._zero;
    if (off._direction >= 0) {
      block.writeVec3ValuesAt(off._direction, dir.x, dir.y, dir.z);
    }
    if (off._modelDirection >= 0) {
      block.writeVec3ValuesAt(
        off._modelDirection,
        modelDir.x,
        modelDir.y,
        modelDir.z,
      );
    }
    if (off._amplitude >= 0) {
      block.writeFloatAt(off._amplitude, windAmplitude);
    }
    if (off._phaseScale >= 0) {
      block.writeVec3ValuesAt(
        off._phaseScale,
        windPhase.x,
        windPhase.y,
        windPhase.z,
      );
    }
    if (off._frequency >= 0) {
      block.writeFloatAt(off._frequency, windFrequency);
    }
    if (off._time >= 0) {
      block.writeFloatAt(off._time, windTime);
    }
    if (off._upAxis >= 0) {
      block.writeVec3ValuesAt(off._upAxis, _upAxis.x, _upAxis.y, _upAxis.z);
    }
    if (off._flutterAmplitude >= 0) {
      block.writeFloatAt(off._flutterAmplitude, windFlutterAmplitude);
    }
    if (off._flutterFrequency >= 0) {
      block.writeFloatAt(off._flutterFrequency, windFlutterFrequency);
    }
    if (off._gustWave >= 0) {
      block.writeVec3ValuesAt(
        off._gustWave,
        _gustWave.x,
        _gustWave.y,
        _gustWave.z,
      );
    }
    if (off._gustAmplitude >= 0) {
      block.writeFloatAt(off._gustAmplitude, windGustAmplitude);
    }
    if (off._gustFrequency >= 0) {
      block.writeFloatAt(off._gustFrequency, windGustFrequency);
    }
    if (off._depthBias >= 0) {
      block.writeFloatAt(off._depthBias, depthBias);
    }
  }
}

/// Sets [target] to [direction] normalized, times [scale], or to zero when
/// [direction] is zero.
void _unitOrZero(Vector3 target, Vector3 direction, double scale) {
  final length = direction.length;
  if (length == 0) {
    target.setZero();
  } else {
    target
      ..setFrom(direction)
      ..scale(scale / length);
  }
}

class _StylizedSamplerIndices(
  final int _matCap,
  final int _gemMatCap,
  final int _baseColor,
);

class _StylizedMaterialOffsets(final UniformBlock _b) {
  late final int _baseColorReplace = _b.resolveOffset('baseColorReplace');
  late final int _alphaCutoff = _b.resolveOffset('alphaCutoff');
  late final int _accentPaletteCount = _b.resolveOffset('accentPaletteCount');
  late final int _accentPalette = _b.resolveOffset('accentPalette');
  late final int _rimPaletteCount = _b.resolveOffset('rimPaletteCount');
  late final int _rimPalettePower = _b.resolveOffset('rimPalettePower');
  late final int _rimPaletteStrength = _b.resolveOffset('rimPaletteStrength');
  late final int _rimPalette = _b.resolveOffset('rimPalette');
  late final int _emissiveColorSource = _b.resolveOffset('emissiveColorSource');
  late final int _emissiveBoostFollows = _b.resolveOffset(
    'emissiveBoostFollows',
  );
  late final int _albedoColor = _b.resolveOffset('albedoColor');
  late final int _accentColor = _b.resolveOffset('accentColor');
  late final int _emissiveColor = _b.resolveOffset('emissiveColor');
  late final int _emissiveBoostColor = _b.resolveOffset('emissiveBoostColor');
  late final int _ambientBase = _b.resolveOffset('ambientBase');
  late final int _skyFill = _b.resolveOffset('skyFill');
  late final int _rimColor = _b.resolveOffset('rimColor');
  late final int _highlightColor = _b.resolveOffset('highlightColor');
  late final int _emissiveStrength = _b.resolveOffset('emissiveStrength');
  late final int _groundBounce = _b.resolveOffset('groundBounce');
  late final int _pointLightWrap = _b.resolveOffset('pointLightWrap');
  late final int _specularStrength = _b.resolveOffset('specularStrength');
  late final int _specularPower = _b.resolveOffset('specularPower');
  late final int _specularThreshold = _b.resolveOffset('specularThreshold');
  late final int _rimStrength = _b.resolveOffset('rimStrength');
  late final int _rimPower = _b.resolveOffset('rimPower');
  late final int _matCapStrength = _b.resolveOffset('matCapStrength');
  late final int _matCapThreshold = _b.resolveOffset('matCapThreshold');
  late final int _matCapGlossWeight = _b.resolveOffset('matCapGlossWeight');
  late final int _gemMatCapStrength = _b.resolveOffset('gemMatCapStrength');
  late final int _gemThreshold = _b.resolveOffset('gemThreshold');
  late final int _matCapMetallic = _b.resolveOffset('matCapMetallic');
  late final int _saturation = _b.resolveOffset('saturation');
  late final int _overlayColor = _b.resolveOffset('overlayColor');
  late final int _ditherFade = _b.resolveOffset('ditherFade');
}

class _WindBlockOffsets(final UniformBlock _b) {
  late final int _direction = _b.resolveOffset('direction');
  late final int _modelDirection = _b.resolveOffset('modelDirection');
  late final int _amplitude = _b.resolveOffset('amplitude');
  late final int _phaseScale = _b.resolveOffset('phaseScale');
  late final int _frequency = _b.resolveOffset('frequency');
  late final int _time = _b.resolveOffset('time');
  late final int _upAxis = _b.resolveOffset('upAxis');
  late final int _flutterAmplitude = _b.resolveOffset('flutterAmplitude');
  late final int _flutterFrequency = _b.resolveOffset('flutterFrequency');
  late final int _gustWave = _b.resolveOffset('gustWave');
  late final int _gustAmplitude = _b.resolveOffset('gustAmplitude');
  late final int _gustFrequency = _b.resolveOffset('gustFrequency');
  late final int _depthBias = _b.resolveOffset('depthBias');
}
