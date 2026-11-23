part of 'scene_serializer_3d.dart';

extension _SceneSerializerMaterials on SceneSerializer3D {
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
}

Map<String, Object?> _encodeRenderState(RenderState state) {
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

RenderState _decodeRenderState(Map<String, Object?> data) {
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
