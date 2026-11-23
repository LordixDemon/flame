part of 'scene_serializer_3d.dart';

extension _SceneSerializerSettings on SceneSerializer3D {
  Map<String, Object?> _encodeWorld(
    World3D world,
    List<CameraComponent3D> cameras,
  ) {
    _issues = [];
    _meshIds.clear();
    _materialIds.clear();
    try {
      final nodes = <Map<String, Object?>>[];
      var index = 0;
      for (final child in world.children) {
        final encoded = _encodeComponent(child, 'nodes[${index++}]');
        if (encoded != null) {
          nodes.add(encoded);
        }
      }
      if (world.lightProbeGrid != null) {
        _issue('world.lightProbeGrid', 'light probe grids are not saved');
      }
      if (world.customPasses.isNotEmpty) {
        _issue('world.customPasses', 'custom render passes are not saved');
      }
      if (world.shadowGroup != null) {
        _issue('world.shadowGroup', 'shadow groups are not saved');
      }
      if (world.waterVolume != null) {
        _issue('world.waterVolume', 'water volumes are not saved');
      }
      if (world.occlusionCuller != null) {
        _issue('world.occlusionCuller', 'occlusion cullers are not saved');
      }
      return <String, Object?>{
        'format': 'F3DS',
        'schemaVersion': SceneSerializer3D.currentSchemaVersion,
        'world': <String, Object?>{
          'renderScale': world.renderScale,
          'spatialIndex3DEnabled': world.spatialIndex3DEnabled,
          'prioritizeNearestLights': world.prioritizeNearestLights,
          'depthPrepassEnabled': world.depthPrepassEnabled,
          'hdrEnabled': world.hdrEnabled,
          'oitMode': world.oitMode.name,
          'grabSceneColorEnabled': world.grabSceneColorEnabled,
          'renderDebugMode3D': world.renderDebugMode3D.name,
          'scaledFilterQuality': world.scaledFilterQuality.name,
          if (world.lightGrid case final grid?)
            'lightGrid': _encodeLightGrid(grid),
          if (world.fog case final fog?) 'fog': _encodeFog(fog),
          if (world.bloom case final bloom?) 'bloom': _encodeBloom(bloom),
          if (world.postProcess case final post?)
            'postProcess': _encodePostProcess(post),
        },
        if (cameras.isNotEmpty)
          'cameras': [
            for (var i = 0; i < cameras.length; i++)
              _encodeCamera(cameras[i], 'cameras[$i]'),
          ],
        'nodes': nodes,
      };
    } finally {
      _meshIds.clear();
      _materialIds.clear();
    }
  }

  void Function(World3D target) _decodeWorldSettings(
    Map<String, Object?> worldData,
  ) {
    final scale = _asDouble(worldData['renderScale']);
    final spatialIndex = worldData['spatialIndex3DEnabled'];
    final nearestLights = worldData['prioritizeNearestLights'];
    final depthPrepass = worldData['depthPrepassEnabled'];
    final hdr = worldData['hdrEnabled'];
    final oit = _enumByName(OitMode3D.values, worldData['oitMode']);
    final grab = worldData['grabSceneColorEnabled'];
    final debugMode = _enumByName(
      RenderDebugMode3D.values,
      worldData['renderDebugMode3D'],
    );
    final filter = _enumByName(
      FilterQuality.values,
      worldData['scaledFilterQuality'],
    );
    final lightGrid = switch (_asMap(worldData['lightGrid'])) {
      final g? => _decodeLightGrid(g),
      null => null,
    };
    final fog = switch (_asMap(worldData['fog'])) {
      final f? => _decodeFog(f),
      null => null,
    };
    final bloom = switch (_asMap(worldData['bloom'])) {
      final b? => _decodeBloom(b),
      null => null,
    };
    final post = switch (_asMap(worldData['postProcess'])) {
      final p? => _decodePostProcess(p),
      null => null,
    };
    return (target) {
      if (scale != null && scale > 0) {
        target.renderScale = scale;
      }
      if (spatialIndex case final bool b) {
        target.spatialIndex3DEnabled = b;
      }
      if (nearestLights case final bool b) {
        target.prioritizeNearestLights = b;
      }
      if (depthPrepass case final bool b) {
        target.depthPrepassEnabled = b;
      }
      if (hdr case final bool b) {
        target.hdrEnabled = b;
      }
      if (oit != null) {
        target.oitMode = oit;
      }
      if (grab case final bool b) {
        target.grabSceneColorEnabled = b;
      }
      if (debugMode != null) {
        target.renderDebugMode3D = debugMode;
      }
      if (filter != null) {
        target.scaledFilterQuality = filter;
      }
      target
        ..lightGrid = lightGrid
        ..fog = fog
        ..bloom = bloom
        ..postProcess = post;
    };
  }

  Map<String, Object?> _encodeLightSource(LightSource source, String path) {
    final type = source.runtimeType;
    if (type == AmbientLight) {
      final s = source as AmbientLight;
      return <String, Object?>{
        'kind': 'ambient',
        'color': _encodeColor(s.color),
        'intensity': s.intensity,
      };
    }
    if (type == HemisphereLight) {
      final s = source as HemisphereLight;
      return <String, Object?>{
        'kind': 'hemisphere',
        'skyColor': _encodeColor(s.skyColor),
        'groundColor': _encodeColor(s.groundColor),
        'intensity': s.intensity,
        'up': _encodeVec3(s.up),
      };
    }
    if (type == DirectionalLight) {
      final s = source as DirectionalLight;
      return <String, Object?>{
        'kind': 'directional',
        'color': _encodeColor(s.color),
        'intensity': s.intensity,
        if (s.direction case final d?) 'direction': _encodeVec3(d),
        'specular': s.specular,
        if (s.shadows case final sh?) 'shadows': _encodeShadows(sh),
      };
    }
    if (type == PointLight) {
      final s = source as PointLight;
      return <String, Object?>{
        'kind': 'point',
        'color': _encodeColor(s.color),
        'intensity': s.intensity,
        'range': ?s.range,
        if (s.shadows case final sh?) 'shadows': _encodeShadows(sh),
      };
    }
    if (type == SpotLight) {
      final s = source as SpotLight;
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
    }
    _issue(
      path,
      '${source.runtimeType} has no built-in encoding: a lossy save replaces '
      'it with an AmbientLight of the same color and intensity',
    );
    return <String, Object?>{
      'kind': 'ambient',
      'color': _encodeColor(source.color),
      'intensity': source.intensity,
    };
  }

  Map<String, Object?> _encodeCamera(CameraComponent3D cam, String path) {
    if (cam.runtimeType != CameraComponent3D) {
      _issue(
        path,
        '${cam.runtimeType} is a subclass of CameraComponent3D and has no '
        'SceneNodeCodec3D: a lossy save saves it as a plain CameraComponent3D',
      );
    }
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

  Map<String, Object?> _encodePostProcess(PostProcessSettings p) {
    if (p.colorLut != null) {
      _issue(
        'world.postProcess.colorLut',
        'color lookup tables are not saved',
      );
    }
    return <String, Object?>{
      'toneMap': p.toneMap.name,
      'exposure': p.exposure,
      'contrast': p.contrast,
      'saturation': p.saturation,
      'vignetteIntensity': p.vignetteIntensity,
      'vignetteSmoothness': p.vignetteSmoothness,
      'tint': _encodeColor(p.tint),
      'fxaa': p.fxaa,
      'colorLutIntensity': p.colorLutIntensity,
      'ssaoIntensity': p.ssaoIntensity,
      'ssaoRadius': p.ssaoRadius,
      'dofFocusDepth': p.dofFocusDepth,
      'dofFocusRange': p.dofFocusRange,
      'dofBlurStrength': p.dofBlurStrength,
    };
  }
}

Map<String, Object?> _encodeLightGrid(LightGridSettings grid) => {
  'cellSize': ?grid.cellSize,
  'maxCells': grid.maxCells,
  'maxLights': grid.maxLights,
  'maxPointLightsPerCell': grid.maxPointLightsPerCell,
  'maxSpotLightsPerCell': grid.maxSpotLightsPerCell,
  'beyondLimitsOnly': grid.beyondLimitsOnly,
};

LightGridSettings _decodeLightGrid(Map<String, Object?> data) {
  const defaults = LightGridSettings();
  final size = _asDouble(data['cellSize']);
  return LightGridSettings(
    cellSize: size != null && size > 0 ? size : null,
    maxCells: (_asInt(data['maxCells']) ?? defaults.maxCells).clamp(
      1,
      65536,
    ),
    maxLights: (_asInt(data['maxLights']) ?? defaults.maxLights).clamp(
      1,
      16384,
    ),
    maxPointLightsPerCell:
        (_asInt(data['maxPointLightsPerCell']) ??
                defaults.maxPointLightsPerCell)
            .clamp(1, LightGridSettings.maxPointLightsPerCellLimit),
    maxSpotLightsPerCell:
        (_asInt(data['maxSpotLightsPerCell']) ?? defaults.maxSpotLightsPerCell)
            .clamp(1, LightGridSettings.maxSpotLightsPerCellLimit),
    beyondLimitsOnly: data['beyondLimitsOnly'] != false,
  );
}

List<double> _encodeInstances(InstancedGroup3D group) {
  const stride = VertexLayout.instanceStrideInFloats;
  final out = List<double>.filled(group.length * stride, 0);
  final matrix = Matrix4.zero();
  final data = Vector4.zero();
  for (var i = 0; i < group.length; i++) {
    final base = i * stride;
    group.instanceTransform(i, out: matrix);
    for (var k = 0; k < 16; k++) {
      out[base + k] = matrix.storage[k];
    }
    final color = group.instanceColor(i);
    out[base + 16] = color.r;
    out[base + 17] = color.g;
    out[base + 18] = color.b;
    out[base + 19] = color.a;
    group.instanceDataAt(i, out: data);
    out[base + 20] = data.x;
    out[base + 21] = data.y;
    out[base + 22] = data.z;
    out[base + 23] = data.w;
  }
  return out;
}

LightSource _decodeLightSource(Map<String, Object?> data) {
  final kind = data['kind'] as String? ?? 'ambient';
  ShadowSettings? shadows() => switch (_asMap(data['shadows'])) {
    final sh? => _decodeShadows(sh),
    null => null,
  };
  switch (kind) {
    case 'hemisphere':
      return HemisphereLight(
        skyColor:
            _decodeColorOrNull(data['skyColor']) ?? const Color(0xFFFFFFFF),
        groundColor:
            _decodeColorOrNull(data['groundColor']) ?? const Color(0xFF808080),
        intensity: _asDouble(data['intensity']) ?? 0.5,
        up: _decodeVec3OrNull(data['up']),
      );
    case 'directional':
      return DirectionalLight(
        color: _decodeColorOrNull(data['color']) ?? const Color(0xFFFFFFFF),
        intensity: _asDouble(data['intensity']) ?? 1.0,
        direction: _decodeVec3OrNull(data['direction']),
        specular: _asDouble(data['specular']) ?? 1.0,
        shadows: shadows(),
      );
    case 'point':
      return PointLight(
        color: _decodeColorOrNull(data['color']) ?? const Color(0xFFFFFFFF),
        intensity: _asDouble(data['intensity']) ?? 1.0,
        range: _asDouble(data['range']),
        shadows: shadows(),
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
        shadows: shadows(),
      );
    case 'ambient':
    case _:
      return AmbientLight(
        color: _decodeColorOrNull(data['color']) ?? const Color(0xFFFFFFFF),
        intensity: _asDouble(data['intensity']) ?? 0.2,
      );
  }
}

Map<String, Object?> _encodeShadows(ShadowSettings s) {
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
    if (s.casterBounds case final b?)
      'casterBounds': <double>[
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
    if (s.cacheStillCasters) 'cacheStillCasters': true,
    if (s.stillCasterFrames != 30) 'stillCasterFrames': s.stillCasterFrames,
    'cascades': s.cascades,
    'cascadeSplitRatio': s.cascadeSplitRatio,
    if (s.cascadeSplits case final splits?)
      'cascadeSplits': List<double>.of(splits),
    'cascadeBlendRange': s.cascadeBlendRange,
  };
}

ShadowSettings _decodeShadows(Map<String, Object?> data) {
  Aabb3? bounds;
  if (_asDoubleList(data['bounds']) case final b? when b.length >= 6) {
    bounds = Aabb3.minMax(
      Vector3(b[0], b[1], b[2]),
      Vector3(b[3], b[4], b[5]),
    );
  }
  Aabb3? casterBounds;
  if (_asDoubleList(data['casterBounds']) case final b? when b.length >= 6) {
    casterBounds = Aabb3.minMax(
      Vector3(b[0], b[1], b[2]),
      Vector3(b[3], b[4], b[5]),
    );
  }
  return ShadowSettings(
    resolution: _asInt(data['resolution']) ?? 1024,
    fit: _enumByName(ShadowFit.values, data['fit']) ?? ShadowFit.view,
    bounds: bounds,
    casterBounds: casterBounds,
    maxDistance: _asDouble(data['maxDistance']),
    strength: _asDouble(data['strength']) ?? 1.0,
    color: _decodeColorOrNull(data['color']) ?? const Color(0xFF000000),
    softness: _asInt(data['softness']) ?? 1,
    depthBias: _asDouble(data['depthBias']) ?? 1.0,
    normalBias: _asDouble(data['normalBias']) ?? 0.5,
    encoding:
        _enumByName(ShadowMapEncoding.values, data['encoding']) ??
        ShadowMapEncoding.auto,
    stabilize: data['stabilize'] is! bool || (data['stabilize']! as bool),
    cacheWhenStatic: data['cacheWhenStatic'] == true,
    cacheStillCasters: data['cacheStillCasters'] == true,
    stillCasterFrames: math.max(1, _asInt(data['stillCasterFrames']) ?? 30),
    cascades: _asInt(data['cascades']) ?? 1,
    cascadeSplitRatio: _asDouble(data['cascadeSplitRatio']) ?? 0.28,
    cascadeSplits: _asDoubleList(data['cascadeSplits']),
    cascadeBlendRange: _asDouble(data['cascadeBlendRange']) ?? 0.1,
  );
}

CameraComponent3D _decodeCameraData(Map<String, Object?> data) {
  return CameraComponent3D(
    projection:
        _enumByName(CameraProjection.values, data['projection']) ??
        CameraProjection.perspective,
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

Map<String, Object?> _encodeFog(FogSettings f) {
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

FogSettings _decodeFog(Map<String, Object?> data) {
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

Map<String, Object?> _encodeBloom(BloomSettings b) {
  return <String, Object?>{
    'threshold': b.threshold,
    'softKnee': b.softKnee,
    'intensity': b.intensity,
    'radius': b.radius,
    'passes': b.passes,
  };
}

BloomSettings _decodeBloom(Map<String, Object?> data) {
  return BloomSettings(
    threshold: _asDouble(data['threshold']) ?? 0.8,
    softKnee: _asDouble(data['softKnee']) ?? 0.5,
    intensity: _asDouble(data['intensity']) ?? 0.6,
    radius: _asDouble(data['radius']) ?? 1.0,
    passes: _asInt(data['passes']) ?? 2,
  );
}

PostProcessSettings _decodePostProcess(Map<String, Object?> data) {
  return PostProcessSettings(
    toneMap:
        _enumByName(ToneMapMode.values, data['toneMap']) ?? ToneMapMode.none,
    exposure: _asDouble(data['exposure']) ?? 1.0,
    contrast: _asDouble(data['contrast']) ?? 1.0,
    saturation: _asDouble(data['saturation']) ?? 1.0,
    vignetteIntensity: _asDouble(data['vignetteIntensity']) ?? 0.0,
    vignetteSmoothness: _asDouble(data['vignetteSmoothness']) ?? 0.5,
    tint: _decodeColorOrNull(data['tint']) ?? const Color(0xFFFFFFFF),
    fxaa: data['fxaa'] == true,
    colorLutIntensity: _asDouble(data['colorLutIntensity']) ?? 1.0,
    ssaoIntensity: _asDouble(data['ssaoIntensity']) ?? 0.0,
    ssaoRadius: _asDouble(data['ssaoRadius']) ?? 1.5,
    dofFocusDepth: _asDouble(data['dofFocusDepth']) ?? 0.5,
    dofFocusRange: _asDouble(data['dofFocusRange']) ?? 0.15,
    dofBlurStrength: _asDouble(data['dofBlurStrength']) ?? 0.0,
  );
}
