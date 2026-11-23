part of 'render_context_3d.dart';

final Float64List _topLightScores = Float64List(RenderContext3D.maxPointLights);
const int _pickAll = 0;
const int _pickFixed = 1;
const int _pickBinnable = 2;
final Int32List _gridScratch = Int32List(RenderContext3D.maxPointLights);
final _scratchDirection = Vector3.zero();
final _defaultAmbientLight = AmbientLight();

class _LightPassState() {
  List<Light> lights = const [];
  int? worldLightsVersion;
  Object? syncedOwner;
  LightGridSettings? lightGrid;
  Aabb3? lightGridBounds;
  bool prioritizeNearestLights = false;

  final LightGrid3D lightGridBuilder = LightGrid3D();

  int _lightSelPass = -1;
  List<Light>? _lightSelList;
  int _lightSelLength = -1;
  int _lightSelMask = 0;
  AmbientLight? selAmbient;
  bool selHasHemisphere = false;
  HemisphereLight? selHemisphere;
  final List<Light> selDirectionals = [];

  int _selPointPass = -1;
  List<Light>? _selPointList;
  int _selPointLength = -1;
  int _selPointMask = 0;
  bool _selPointPrioritize = false;
  LightGridSettings? _selPointGrid;
  int _selPointCount = 0;
  final Int32List selPointIndices = Int32List(
    RenderContext3D.maxPointLights,
  );

  int _selSpotPass = -1;
  List<Light>? _selSpotList;
  int _selSpotLength = -1;
  int _selSpotMask = 0;
  LightGridSettings? _selSpotGrid;
  int _selSpotCount = 0;
  final Int32List selSpotIndices = Int32List(
    RenderContext3D.maxSpotLights,
  );

  int _gridPlanPass = -1;
  List<Light>? _gridPlanLights;
  int _gridPlanMask = 0;
  LightGridSettings? _gridPlanSettings;
  bool _gridPlanPrioritize = false;
  bool gridPoints = false;
  bool gridSpots = false;
  int gridUniformPoints = RenderContext3D.maxPointLights;
  int gridUniformSpots = RenderContext3D.maxSpotLights;
  int _gridBuiltPass = -1;

  int _syncedLightRev = -1;
  int _syncedFogVer = -1;
  int _syncedWaterVer = -1;
  double _syncedProbeIntensity = -1.0;

  bool needsSyncOptions({
    required RenderContext3D context,
    required List<Light> lights,
    required int lightsVersion,
    required FogSettings? fog,
    required WaterVolumeSettings? waterVolume,
    required RenderDebugMode3D renderDebugMode,
    required LightProbeGrid3D? lightProbeGrid,
    required List<ReflectionProbeSource3D> reflectionProbes,
    required bool prioritizeNearestLights,
    required LightGridSettings? lightGrid,
    required Aabb3? lightGridBounds,
    required bool hdrEnabled,
    Object? owner,
  }) {
    final fogVer = fog?.version ?? -1;
    final waterVer = waterVolume?.version ?? -1;
    final probeIntensity = lightProbeGrid?.intensity ?? -1.0;
    if (_syncedLightRev == lightsVersion &&
        identical(syncedOwner, owner) &&
        identical(this.lights, lights) &&
        identical(context.fog, fog) &&
        _syncedFogVer == fogVer &&
        identical(context.waterVolume, waterVolume) &&
        _syncedWaterVer == waterVer &&
        context.renderDebugMode == renderDebugMode &&
        identical(context.lightProbeGrid, lightProbeGrid) &&
        _syncedProbeIntensity == probeIntensity &&
        identical(context.reflectionProbes, reflectionProbes) &&
        this.prioritizeNearestLights == prioritizeNearestLights &&
        identical(this.lightGrid, lightGrid) &&
        this.lightGridBounds == lightGridBounds &&
        context.hdrEnabled == hdrEnabled) {
      return false;
    }
    syncedOwner = owner;
    _syncedLightRev = lightsVersion;
    _syncedFogVer = fogVer;
    _syncedWaterVer = waterVer;
    _syncedProbeIntensity = probeIntensity;
    return true;
  }

  void ensureLightSelection(int pass, int cameraMask) {
    final list = lights;
    if (_lightSelPass == pass &&
        identical(_lightSelList, list) &&
        _lightSelLength == list.length &&
        _lightSelMask == cameraMask) {
      return;
    }
    _lightSelPass = pass;
    _lightSelList = list;
    _lightSelLength = list.length;
    _lightSelMask = cameraMask;
    selAmbient = null;
    selHasHemisphere = false;
    selHemisphere = null;
    selDirectionals.clear();
    for (var i = 0; i < list.length; i++) {
      final l = list[i];
      if ((l.lightMask & cameraMask) == 0) {
        continue;
      }
      final source = l.source;
      if (source is AmbientLight) {
        selAmbient ??= source;
      } else if (source is HemisphereLight) {
        selHasHemisphere = true;
        selHemisphere ??= source;
      } else if (source is DirectionalLight &&
          selDirectionals.length < RenderContext3D.maxDirectionalLights) {
        selDirectionals.add(l);
      }
    }
  }

  void planLightGrid(RenderContext3D context) {
    final pass = context._pass;
    final cameraMask = context.cameraMask;
    if (_gridPlanPass == pass &&
        identical(_gridPlanLights, lights) &&
        _gridPlanMask == cameraMask &&
        identical(_gridPlanSettings, lightGrid) &&
        _gridPlanPrioritize == prioritizeNearestLights) {
      return;
    }
    _gridPlanPass = pass;
    _gridPlanLights = lights;
    _gridPlanMask = cameraMask;
    _gridPlanSettings = lightGrid;
    _gridPlanPrioritize = prioritizeNearestLights;
    gridPoints = false;
    gridSpots = false;
    gridUniformPoints = RenderContext3D.maxPointLights;
    gridUniformSpots = RenderContext3D.maxSpotLights;
    final settings = lightGrid;
    if (settings == null) {
      return;
    }
    var points = 0;
    var spots = 0;
    var binnablePoints = 0;
    var binnableSpots = 0;
    for (var i = 0; i < lights.length; i++) {
      final light = lights[i];
      if ((light.lightMask & cameraMask) == 0) {
        continue;
      }
      final source = light.source;
      if (source is PointLight) {
        points++;
        if (LightGrid3D.binnable(light)) {
          binnablePoints++;
        }
      } else if (source is SpotLight) {
        spots++;
        if (LightGrid3D.binnable(light)) {
          binnableSpots++;
        }
      }
    }
    final always = !settings.beyondLimitsOnly;
    gridPoints =
        binnablePoints > 0 &&
        (always || points > RenderContext3D.maxPointLights);
    gridSpots =
        binnableSpots > 0 && (always || spots > RenderContext3D.maxSpotLights);
    if (gridPoints) {
      gridUniformPoints = _pickPointLights(
        context,
        _gridScratch,
        0,
        RenderContext3D.maxPointLights,
        _pickFixed,
      );
    }
    if (gridSpots) {
      gridUniformSpots = _pickSpotLights(
        context,
        _gridScratch,
        0,
        RenderContext3D.maxSpotLights,
        _pickFixed,
      );
    }
  }

  /// Builds the light grid of the pass, once per pass, when its lights need
  /// one; returns whether it holds any light.
  bool buildLightGrid(RenderContext3D context) {
    planLightGrid(context);
    if (!gridPoints && !gridSpots) {
      lightGridBuilder.stats.active = false;
      return false;
    }
    if (_gridBuiltPass != context._pass) {
      _gridBuiltPass = context._pass;
      lightGridBuilder.build(
        lights: lights,
        cameraMask: context.cameraMask,
        settings: lightGrid!,
        points: gridPoints,
        spots: gridSpots,
        bounds: lightGridBounds,
        viewProjection: context.viewProjection,
        lightsVersion: worldLightsVersion,
      );
    }
    return lightGridBuilder.hasLights;
  }

  int ensurePointLightSelection(RenderContext3D context) {
    final pass = context._pass;
    final list = lights;
    if (_selPointPass == pass &&
        identical(_selPointList, list) &&
        _selPointLength == list.length &&
        _selPointMask == context.cameraMask &&
        _selPointPrioritize == prioritizeNearestLights &&
        identical(_selPointGrid, lightGrid)) {
      return _selPointCount;
    }
    _selPointPass = pass;
    _selPointList = list;
    _selPointLength = list.length;
    _selPointMask = context.cameraMask;
    _selPointPrioritize = prioritizeNearestLights;
    _selPointGrid = lightGrid;
    planLightGrid(context);
    final out = selPointIndices;
    final int count;
    if (!gridPoints) {
      count = _pickPointLights(
        context,
        out,
        0,
        RenderContext3D.maxPointLights,
        _pickAll,
      );
    } else {
      final fixed = _pickPointLights(
        context,
        out,
        0,
        RenderContext3D.maxPointLights,
        _pickFixed,
      );
      count =
          fixed +
          _pickPointLights(
            context,
            out,
            fixed,
            RenderContext3D.maxPointLights - fixed,
            _pickBinnable,
          );
    }
    return _selPointCount = count;
  }

  int ensureSpotLightSelection(RenderContext3D context) {
    final pass = context._pass;
    final list = lights;
    if (_selSpotPass == pass &&
        identical(_selSpotList, list) &&
        _selSpotLength == list.length &&
        _selSpotMask == context.cameraMask &&
        identical(_selSpotGrid, lightGrid)) {
      return _selSpotCount;
    }
    _selSpotPass = pass;
    _selSpotList = list;
    _selSpotLength = list.length;
    _selSpotMask = context.cameraMask;
    _selSpotGrid = lightGrid;
    planLightGrid(context);
    final out = selSpotIndices;
    final int count;
    if (!gridSpots) {
      count = _pickSpotLights(
        context,
        out,
        0,
        RenderContext3D.maxSpotLights,
        _pickAll,
      );
    } else {
      final fixed = _pickSpotLights(
        context,
        out,
        0,
        RenderContext3D.maxSpotLights,
        _pickFixed,
      );
      count =
          fixed +
          _pickSpotLights(
            context,
            out,
            fixed,
            RenderContext3D.maxSpotLights - fixed,
            _pickBinnable,
          );
    }
    return _selSpotCount = count;
  }
}

extension _RenderContext3DUniforms on RenderContext3D {
  void _saveCameraSnapshot(_CameraSnapshot out) => _camera.saveSnapshot(out);

  void _restoreCameraSnapshot(
    _CameraSnapshot snap, {
    required bool active,
    required bool atlasActive,
  }) {
    _bumpAllPassKinds();
    _cameraPass++;
    _shadows
      ..active = active
      ..atlasActive = atlasActive;
    _camera.restoreSnapshot(snap);
  }
}

void _writePrefixedPass(
  RenderContext3D context,
  UniformBlock block,
  List<String> parts,
  Map<UniformBlock, List<UniformBlock>> viewsMap,
) {
  final views = viewsMap[block] ??= [
    for (final part in parts) PrefixedUniformBlock(block, '${part}_'),
  ];
  for (var i = 0; i < views.length; i++) {
    context._passRegistry.writers[parts[i]]?.call(context, views[i]);
  }
}

void _writeStylizedPass(RenderContext3D context, UniformBlock block) {
  _writePrefixedPass(
    context,
    block,
    RenderContext3D._stylizedPassParts,
    context._passRegistry.stylizedPassViews,
  );
}

void _writeSpatialPass(RenderContext3D context, UniformBlock block) {
  _writePrefixedPass(
    context,
    block,
    RenderContext3D._spatialPassParts,
    context._passRegistry.spatialPassViews,
  );
}

void _writeCameraUniforms(
  RenderContext3D context,
  UniformBlock block,
) {
  final off =
      (block.cachedWriterOffsets as _CameraOffsets?) ??
      (block.cachedWriterOffsets = _CameraOffsets(block));
  if (off.view >= 0) {
    block.writeMatrix4At(off.view, context.view);
  }
  if (off.projection >= 0) {
    block.writeMatrix4At(off.projection, context.projection);
  }
  if (off.viewProjection >= 0) {
    block.writeMatrix4At(off.viewProjection, context.viewProjection);
  }
  if (off.position >= 0) {
    final p = context.cameraPosition;
    block.writeVec3ValuesAt(off.position, p.x, p.y, p.z);
  }
}

void _writeAmbientLightUniforms(
  RenderContext3D context,
  UniformBlock block,
) {
  final lightState = context._lightState
    ..ensureLightSelection(context._pass, context.cameraMask);
  final off =
      (block.cachedWriterOffsets as _AmbientOffsets?) ??
      (block.cachedWriterOffsets = _AmbientOffsets(block));
  final ambient = lightState.selAmbient;
  if (ambient == null && lightState.selHasHemisphere) {
    if (off.color >= 0) {
      block.writeVec4ValuesAt(off.color, 0, 0, 0, 0);
    }
    if (off.intensity >= 0) {
      block.writeFloatAt(off.intensity, 0);
    }
    return;
  }
  final resolved = ambient ?? _defaultAmbientLight;
  if (off.color >= 0) {
    block.writeColorAt(off.color, resolved.color);
  }
  if (off.intensity >= 0) {
    block.writeFloatAt(off.intensity, resolved.intensity);
  }
}

double _lightPriorityScore(
  RenderContext3D context,
  Vector3 pos,
  double intensity,
) {
  final proj = context.projection.storage;
  if (proj[15].abs() < 0.5) {
    final cam = context.cameraPosition;
    final dx = pos.x - cam.x;
    final dy = pos.y - cam.y;
    final dz = pos.z - cam.z;
    return intensity / (1.0 + dx * dx + dy * dy + dz * dz);
  }
  final vp = context.viewProjection.storage;
  final cx = vp[0] * pos.x + vp[4] * pos.y + vp[8] * pos.z + vp[12];
  final cy = vp[1] * pos.x + vp[5] * pos.y + vp[9] * pos.z + vp[13];
  final cw = vp[3] * pos.x + vp[7] * pos.y + vp[11] * pos.z + vp[15];
  final invW = cw.abs() > 1e-6 ? 1.0 / cw : 1.0;
  final nx = cx * invW;
  final ny = cy * invW;
  return intensity / (1.0 + nx * nx + ny * ny);
}

/// Fills [out] with the indices in [RenderContext3D.lights] of point lights
/// in [RenderContext3D.lightsBlock] order (filtered by `lightMask` and
/// [RenderContext3D.prioritizeNearestLights] up to
/// [RenderContext3D.maxPointLights]).
///
/// When [RenderContext3D.lightGrid] holds point lights, unbinned lights precede
/// binned lights (see [RenderContext3D.lightGridBlock]).
///
/// The shadow pass matches its lights to the block with it.
int _selectPointLights(RenderContext3D context, Int32List out) {
  final lightState = context._lightState;
  final n = lightState.ensurePointLightSelection(context);
  final src = lightState.selPointIndices;
  for (var i = 0; i < n; i++) {
    out[i] = src[i];
  }
  return n;
}

@pragma('vm:prefer-inline')
bool _picks(Light light, int pick) =>
    pick == _pickAll || LightGrid3D.binnable(light) == (pick == _pickBinnable);

/// Writes into [out] from [offset] the indices of at most [capacity]
/// point lights among those [pick] says, as [_selectPointLights] chooses
/// them, and returns how many.
int _pickPointLights(
  RenderContext3D context,
  Int32List out,
  int offset,
  int capacity,
  int pick,
) {
  if (capacity <= 0) {
    return 0;
  }
  final lights = context.lights;
  final mask = context.cameraMask;
  var count = 0;
  if (!context.prioritizeNearestLights) {
    var slots = 0;
    for (var i = 0; i < lights.length && slots < capacity; i++) {
      final light = lights[i];
      if ((light.lightMask & mask) == 0) {
        continue;
      }
      final source = light.source;
      if (source is! PointLight || !_picks(light, pick)) {
        continue;
      }
      // Beside a light grid, a light of zero intensity takes no place.
      if (source.intensity == 0 && pick != _pickAll) {
        continue;
      }
      slots++;
      if (source.intensity == 0) {
        continue;
      }
      out[offset + count++] = i;
    }
    return count;
  }

  var totalMatching = 0;
  var prioritized = false;
  for (var i = 0; i < lights.length; i++) {
    final light = lights[i];
    if ((light.lightMask & mask) == 0) {
      continue;
    }
    final source = light.source;
    if (source is! PointLight || !_picks(light, pick)) {
      continue;
    }
    if (!prioritized) {
      totalMatching++;
      if (totalMatching <= capacity) {
        if (source.intensity != 0) {
          out[offset + count++] = i;
        }
        continue;
      }
      prioritized = true;
      final collected = count;
      count = 0;
      for (var j = 0; j < collected; j++) {
        final idx = out[offset + j];
        final l = lights[idx];
        final s = l.source as PointLight;
        if (s.intensity <= 0) {
          continue;
        }
        count = _insertByScore(
          out,
          count,
          capacity,
          idx,
          _lightPriorityScore(context, l.position, s.intensity),
          offset: offset,
        );
      }
    }
    if (source.intensity <= 0) {
      continue;
    }
    count = _insertByScore(
      out,
      count,
      capacity,
      i,
      _lightPriorityScore(context, light.position, source.intensity),
      offset: offset,
    );
  }
  return count;
}

/// Fills [out] with the indices in [RenderContext3D.lights] of spot lights
/// in [RenderContext3D.spotLightsBlock] order up to
/// [RenderContext3D.maxSpotLights].
///
/// When [RenderContext3D.lightGrid] holds spot lights, unbinned lights precede
/// binned lights (see [_selectPointLights]).
///
/// The shadow pass matches its lights to the block with it.
int _selectSpotLights(RenderContext3D context, Int32List out) {
  final lightState = context._lightState;
  final n = lightState.ensureSpotLightSelection(context);
  final src = lightState.selSpotIndices;
  for (var i = 0; i < n; i++) {
    out[i] = src[i];
  }
  return n;
}

/// Writes into [out] from [offset] the indices of at most [capacity] spot
/// lights among those [pick] says, as [_selectSpotLights] chooses them,
/// and returns how many.
int _pickSpotLights(
  RenderContext3D context,
  Int32List out,
  int offset,
  int capacity,
  int pick,
) {
  if (capacity <= 0) {
    return 0;
  }
  final lights = context.lights;
  final mask = context.cameraMask;
  var count = 0;
  var totalMatching = 0;
  var prioritized = false;
  for (var i = 0; i < lights.length; i++) {
    final light = lights[i];
    if ((light.lightMask & mask) == 0) {
      continue;
    }
    final source = light.source;
    if (source is! SpotLight || !_picks(light, pick)) {
      continue;
    }
    if (!prioritized) {
      totalMatching++;
      if (totalMatching <= capacity) {
        if (source.intensity > 0) {
          out[offset + count++] = i;
        }
        continue;
      }
      prioritized = true;
      final collected = count;
      count = 0;
      for (var j = 0; j < collected; j++) {
        final idx = out[offset + j];
        final l = lights[idx];
        final s = l.source as SpotLight;
        count = _insertByScore(
          out,
          count,
          capacity,
          idx,
          _lightPriorityScore(context, l.position, s.intensity),
          offset: offset,
        );
      }
    }
    if (source.intensity <= 0) {
      continue;
    }
    count = _insertByScore(
      out,
      count,
      capacity,
      i,
      _lightPriorityScore(context, light.position, source.intensity),
      offset: offset,
    );
  }
  return count;
}

/// Inserts light [index] of [score] into the [count] first entries of
/// [out] from [offset], kept by decreasing score in [_topLightScores], at
/// most [capacity] of them; returns the new count.
int _insertByScore(
  Int32List out,
  int count,
  int capacity,
  int index,
  double score, {
  int offset = 0,
}) {
  if (capacity <= 0) {
    return count;
  }
  int pos;
  if (count < capacity) {
    pos = count++;
  } else if (score > _topLightScores[capacity - 1]) {
    pos = capacity - 1;
  } else {
    return count;
  }
  while (pos > 0 && _topLightScores[pos - 1] < score) {
    _topLightScores[pos] = _topLightScores[pos - 1];
    out[offset + pos] = out[offset + pos - 1];
    pos--;
  }
  _topLightScores[pos] = score;
  out[offset + pos] = index;
  return count;
}

Texture _lightGridTexture(RenderContext3D context) =>
    context._lightState.buildLightGrid(context)
    ? context._lightState.lightGridBuilder.texture(context.device.backend)
    : Texture.standard;

/// Writes the [RenderContext3D.lightGridBlock] of the pass (grid origin,
/// cell counts, texture metadata, and unbinned light counts for
/// [RenderContext3D.lightsBlock] and [RenderContext3D.spotLightsBlock]).
void _writeLightGridUniforms(
  RenderContext3D context,
  UniformBlock block,
) {
  final off =
      (block.cachedWriterOffsets as _LightGridOffsets?) ??
      (block.cachedWriterOffsets = _LightGridOffsets(block));
  final lightState = context._lightState;
  if (lightState.buildLightGrid(context)) {
    final grid = lightState.lightGridBuilder;
    final s = grid.stats;
    if (off.origin >= 0) {
      block.writeVec4ValuesAt(
        off.origin,
        grid.origin.x,
        grid.origin.y,
        grid.origin.z,
        1 / s.cellSize,
      );
    }
    if (off.cells >= 0) {
      block.writeVec4ValuesAt(
        off.cells,
        s.cellsX.toDouble(),
        s.cellsY.toDouble(),
        s.cellsZ.toDouble(),
        (s.cellsX * s.cellsY).toDouble(),
      );
    }
    if (off.data >= 0) {
      block.writeVec4ValuesAt(
        off.data,
        LightGrid3D.textureWidth.toDouble(),
        1 / LightGrid3D.textureWidth,
        1 / s.textureHeight,
        1,
      );
    }
  } else {
    if (off.origin >= 0) {
      block.writeVec4ValuesAt(off.origin, 0, 0, 0, 0);
    }
    if (off.cells >= 0) {
      block.writeVec4ValuesAt(off.cells, 0, 0, 0, 0);
    }
    if (off.data >= 0) {
      block.writeVec4ValuesAt(off.data, 0, 0, 0, 0);
    }
  }
  if (off.counts >= 0) {
    block.writeVec4ValuesAt(
      off.counts,
      lightState.gridUniformPoints.toDouble(),
      lightState.gridUniformSpots.toDouble(),
      0,
      0,
    );
  }
}

void _writeLightsUniforms(RenderContext3D context, UniformBlock block) {
  final off =
      (block.cachedWriterOffsets as _LightsOffsets?) ??
      (block.cachedWriterOffsets = _LightsOffsets(block));
  final lightState = context._lightState;
  final lights = lightState.lights;
  final count = lightState.ensurePointLightSelection(context);
  final indices = lightState.selPointIndices;
  final dataLen = block.data.length;
  for (var k = 0; k < count; k++) {
    final light = lights[indices[k]];
    final source = light.source as PointLight;
    final range = source.range;
    final p = light.position;
    if (off.positions >= 0 && off.positions + k * 4 + 3 <= dataLen) {
      block.writeVec3ValuesAt(off.positions + k * 4, p.x, p.y, p.z);
    }
    if (off.colors >= 0 && off.colors + k * 4 + 4 <= dataLen) {
      block.writeColorAt(off.colors + k * 4, source.color);
    }
    if (off.intensities >= 0 && off.intensities + k * 4 < dataLen) {
      block.writeFloatAt(off.intensities + k * 4, source.intensity);
    }
    if (off.ranges >= 0 && off.ranges + k * 4 < dataLen) {
      block.writeFloatAt(
        off.ranges + k * 4,
        range != null && range > 0 ? range : 0,
      );
    }
  }
  if (off.numLights >= 0) {
    block.writeFloatAt(off.numLights, count.toDouble());
  }
}

void _writeSpotLightsUniforms(
  RenderContext3D context,
  UniformBlock block,
) {
  final off =
      (block.cachedWriterOffsets as _SpotLightsOffsets?) ??
      (block.cachedWriterOffsets = _SpotLightsOffsets(block));
  final lightState = context._lightState;
  final lights = lightState.lights;
  final count = lightState.ensureSpotLightSelection(context);
  final indices = lightState.selSpotIndices;
  final dataLen = block.data.length;

  final dir = _scratchDirection;
  for (var k = 0; k < count; k++) {
    final light = lights[indices[k]];
    final source = light.source as SpotLight;
    light.direction(dir);
    final outer = source.outerConeAngle.clamp(0.001, math.pi * 0.999);
    final inner = source.innerConeAngle.clamp(0.0, outer - 1e-4);
    final cosOuter = math.cos(outer);
    final invSpan = 1.0 / math.max(math.cos(inner) - cosOuter, 1e-4);
    final range = source.range;
    final c = source.color;
    final p = light.position;
    if (off.positions >= 0 && off.positions + k * 4 + 3 <= dataLen) {
      block.writeVec3ValuesAt(off.positions + k * 4, p.x, p.y, p.z);
    }
    if (off.directions >= 0 && off.directions + k * 4 + 4 <= dataLen) {
      block.writeVec4ValuesAt(
        off.directions + k * 4,
        -dir.x,
        -dir.y,
        -dir.z,
        source.specular,
      );
    }
    if (off.colors >= 0 && off.colors + k * 4 + 4 <= dataLen) {
      block.writeVec4ValuesAt(
        off.colors + k * 4,
        c.r,
        c.g,
        c.b,
        source.intensity,
      );
    }
    if (off.cones >= 0 && off.cones + k * 4 + 4 <= dataLen) {
      block.writeVec4ValuesAt(
        off.cones + k * 4,
        cosOuter,
        invSpan,
        range != null && range > 0 ? range : 0,
        0,
      );
    }
  }
  if (off.numLights >= 0) {
    block.writeFloatAt(off.numLights, count.toDouble());
  }
}

void _writeDirectionalLightsUniforms(
  RenderContext3D context,
  UniformBlock block,
) {
  final lightState = context._lightState
    ..ensureLightSelection(context._pass, context.cameraMask);
  final off =
      (block.cachedWriterOffsets as _DirLightsOffsets?) ??
      (block.cachedWriterOffsets = _DirLightsOffsets(block));
  final dirs = lightState.selDirectionals;
  final count = dirs.length;
  final direction = _scratchDirection;
  final dataLen = block.data.length;
  for (var k = 0; k < count; k++) {
    final light = dirs[k];
    final source = light.source as DirectionalLight;
    light.direction(direction);
    final color = source.color;
    if (off.directions >= 0 && off.directions + k * 4 + 4 <= dataLen) {
      block.writeVec4ValuesAt(
        off.directions + k * 4,
        -direction.x,
        -direction.y,
        -direction.z,
        source.specular,
      );
    }
    if (off.colors >= 0 && off.colors + k * 4 + 4 <= dataLen) {
      block.writeVec4ValuesAt(
        off.colors + k * 4,
        color.r,
        color.g,
        color.b,
        source.intensity,
      );
    }
  }
  if (off.numLights >= 0) {
    block.writeFloatAt(off.numLights, count.toDouble());
  }
}

void _writeHemisphereLightUniforms(
  RenderContext3D context,
  UniformBlock block,
) {
  final lightState = context._lightState
    ..ensureLightSelection(context._pass, context.cameraMask);
  final off =
      (block.cachedWriterOffsets as _HemiOffsets?) ??
      (block.cachedWriterOffsets = _HemiOffsets(block));
  final hemisphere = lightState.selHemisphere;
  final up = _scratchDirection;
  if (hemisphere == null) {
    if (off.skyColor >= 0) {
      block.writeVec4ValuesAt(off.skyColor, 0, 0, 0, 0);
    }
    if (off.groundColor >= 0) {
      block.writeVec4ValuesAt(off.groundColor, 0, 0, 0, 0);
    }
    if (off.up >= 0) {
      block.writeVec3ValuesAt(off.up, 0, 1, 0);
    }
    if (off.intensity >= 0) {
      block.writeFloatAt(off.intensity, 0);
    }
    return;
  }
  up.setFrom(hemisphere.up);
  if (up.length2 > 0) {
    up.normalize();
  } else {
    up.setValues(0, 1, 0);
  }
  if (off.skyColor >= 0) {
    block.writeColorAt(off.skyColor, hemisphere.skyColor);
  }
  if (off.groundColor >= 0) {
    block.writeColorAt(off.groundColor, hemisphere.groundColor);
  }
  if (off.up >= 0) {
    block.writeVec3ValuesAt(off.up, up.x, up.y, up.z);
  }
  if (off.intensity >= 0) {
    block.writeFloatAt(off.intensity, hemisphere.intensity);
  }
}

void _writeFogUniforms(RenderContext3D context, UniformBlock block) {
  final off =
      (block.cachedWriterOffsets as _FogOffsets?) ??
      (block.cachedWriterOffsets = _FogOffsets(block));
  final fog = context.fog;
  if (fog == null || fog.maxOpacity <= 0) {
    if (off.color >= 0) {
      block.writeVec4ValuesAt(off.color, 0, 0, 0, 0);
    }
    if (off.params >= 0) {
      block.writeVec4ValuesAt(off.params, 0, 0, 0, 0);
    }
    if (off.height >= 0) {
      block.writeVec4ValuesAt(off.height, 0, 1, 0, 0);
    }
    return;
  }
  final up = _scratchDirection..setFrom(fog.up);
  if (up.length2 > 0) {
    up.normalize();
  } else {
    up.setValues(0, 1, 0);
  }
  final span = math.max(fog.end - fog.start, 1e-4);
  final c = fog.color;
  if (off.color >= 0) {
    block.writeVec4ValuesAt(
      off.color,
      c.r,
      c.g,
      c.b,
      c.a * fog.maxOpacity.clamp(0.0, 1.0),
    );
  }
  if (off.params >= 0) {
    block.writeVec4ValuesAt(
      off.params,
      math.max(0.0, fog.start),
      1.0 / span,
      math.max(0.0, fog.density),
      math.max(0.0, fog.heightFalloff),
    );
  }
  if (off.height >= 0) {
    block.writeVec4ValuesAt(
      off.height,
      up.x,
      up.y,
      up.z,
      fog.baseHeight,
    );
  }
}

/// Fills [RenderContext3D.waterVolumeBlock] from
/// [RenderContext3D.waterVolume], see `flame_3d/water_volume.glsl`.
void _writeWaterVolumeUniforms(
  RenderContext3D context,
  UniformBlock block,
) {
  final off =
      (block.cachedWriterOffsets as _WaterVolOffsets?) ??
      (block.cachedWriterOffsets = _WaterVolOffsets(block));
  final water = context.waterVolume;
  if (water == null || !water.isActive) {
    if (off.plane >= 0) {
      block.writeVec4ValuesAt(off.plane, 0, 1, 0, 0);
    }
    if (off.deep >= 0) {
      block.writeVec4ValuesAt(off.deep, 0, 0, 0, 0);
    }
    if (off.caustics >= 0) {
      block.writeVec4ValuesAt(off.caustics, 0, 0, 0, 0);
    }
    if (off.boundsMin >= 0) {
      block.writeVec4ValuesAt(off.boundsMin, 0, 0, 0, 0);
    }
    return;
  }
  final up = _scratchDirection..setFrom(water.up);
  if (up.length2 > 0) {
    up.normalize();
  } else {
    up.setValues(0, 1, 0);
  }
  final shallow = water.shallowColor;
  final deep = water.deepColor;
  final caustic = water.causticColor;
  final line = water.waterlineColor;
  final scale = water.causticScale;
  if (off.plane >= 0) {
    block.writeVec4ValuesAt(off.plane, up.x, up.y, up.z, water.level);
  }
  if (off.shallow >= 0) {
    block.writeVec4ValuesAt(
      off.shallow,
      shallow.r,
      shallow.g,
      shallow.b,
      math.max(0.0, water.absorption),
    );
  }
  if (off.deep >= 0) {
    block.writeVec4ValuesAt(off.deep, deep.r, deep.g, deep.b, 1);
  }
  if (off.caustics >= 0) {
    block.writeVec4ValuesAt(
      off.caustics,
      math.max(0.0, water.causticStrength),
      scale > 0 ? 1 / scale : 0,
      water.phase,
      math.max(0.0, water.waterlineWidth),
    );
  }
  if (off.causticColor >= 0) {
    block.writeVec4ValuesAt(
      off.causticColor,
      caustic.r,
      caustic.g,
      caustic.b,
      water.waterlineLightTint.clamp(0.0, 1.0),
    );
  }
  if (off.waterline >= 0) {
    block.writeVec4ValuesAt(
      off.waterline,
      line.r,
      line.g,
      line.b,
      line.a,
    );
  }
  if (off.waterlineFoam >= 0) {
    block.writeVec4ValuesAt(
      off.waterlineFoam,
      water.waterlinePhase,
      water.waterlineLightFloor > 0 ? water.waterlineLightFloor : 0,
      0,
      0,
    );
  }
  final bounds = water.bounds;
  if (bounds == null) {
    if (off.boundsMin >= 0) {
      block.writeVec4ValuesAt(off.boundsMin, 0, 0, 0, 0);
    }
  } else {
    final lo = bounds.min;
    final hi = bounds.max;
    if (off.boundsMin >= 0) {
      block.writeVec4ValuesAt(off.boundsMin, lo.x, lo.y, lo.z, 1);
    }
    if (off.boundsMax >= 0) {
      block.writeVec4ValuesAt(off.boundsMax, hi.x, hi.y, hi.z, 0);
    }
  }
}

class _CameraOffsets(final UniformBlock _b) {
  late final int view = _b.resolveOffset('view');
  late final int projection = _b.resolveOffset('projection');
  late final int viewProjection = _b.resolveOffset('viewProjection');
  late final int position = _b.resolveOffset('position');
}

class _AmbientOffsets(final UniformBlock _b) {
  late final int color = _b.resolveOffset('color');
  late final int intensity = _b.resolveOffset('intensity');
}

class _LightsOffsets(final UniformBlock _b) {
  late final int positions = _b.resolveOffset('positions');
  late final int colors = _b.resolveOffset('colors');
  late final int intensities = _b.resolveOffset('intensities');
  late final int ranges = _b.resolveOffset('ranges');
  late final int numLights = _b.resolveOffset('numLights');
}

class _SpotLightsOffsets(final UniformBlock _b) {
  late final int positions = _b.resolveOffset('positions');
  late final int directions = _b.resolveOffset('directions');
  late final int colors = _b.resolveOffset('colors');
  late final int cones = _b.resolveOffset('cones');
  late final int numLights = _b.resolveOffset('numLights');
}

class _DirLightsOffsets(final UniformBlock _b) {
  late final int directions = _b.resolveOffset('directions');
  late final int colors = _b.resolveOffset('colors');
  late final int numLights = _b.resolveOffset('numLights');
}

class _HemiOffsets(final UniformBlock _b) {
  late final int skyColor = _b.resolveOffset('skyColor');
  late final int groundColor = _b.resolveOffset('groundColor');
  late final int up = _b.resolveOffset('up');
  late final int intensity = _b.resolveOffset('intensity');
}

class _LightGridOffsets(final UniformBlock _b) {
  late final int origin = _b.resolveOffset('origin');
  late final int cells = _b.resolveOffset('cells');
  late final int data = _b.resolveOffset('data');
  late final int counts = _b.resolveOffset('counts');
}

class _FogOffsets(final UniformBlock _b) {
  late final int color = _b.resolveOffset('color');
  late final int params = _b.resolveOffset('params');
  late final int height = _b.resolveOffset('height');
}

class _WaterVolOffsets(final UniformBlock _b) {
  late final int plane = _b.resolveOffset('plane');
  late final int shallow = _b.resolveOffset('shallow');
  late final int deep = _b.resolveOffset('deep');
  late final int caustics = _b.resolveOffset('caustics');
  late final int causticColor = _b.resolveOffset('causticColor');
  late final int waterline = _b.resolveOffset('waterline');
  late final int waterlineFoam = _b.resolveOffset('waterlineFoam');
  late final int boundsMin = _b.resolveOffset('boundsMin');
  late final int boundsMax = _b.resolveOffset('boundsMax');
}

class _PassOptionsOffsets(final UniformBlock _b) {
  late final int flags = _b.resolveOffset('flags');
  late final int gridBoundsMin = _b.resolveOffset('gridBoundsMin');
  late final int gridInvSpan = _b.resolveOffset('gridInvSpan');
  late final int gridRes = _b.resolveOffset('gridRes');
}
