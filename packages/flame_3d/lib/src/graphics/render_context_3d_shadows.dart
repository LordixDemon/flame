part of 'render_context_3d.dart';

/// The shadow pass of a [RenderContext3D]: one map for a lone light (a
/// directional light with one cascade, or a spot light), or the shared
/// [ShadowAtlas3D] (`2..4` directional cascades, up to `2` spot lights and the
/// two hemispheres of one point light, rendered in one pass through
/// `setViewport` + `setScissor`). Every receiver reads both through the
/// `Shadows` block (see `flame_3d/shadows.glsl`).
class _ShadowPass(final RenderContext3D _context) {
  /// Whether the draws being recorded are those of a shadow map.
  bool recording = false;

  /// Whether the pass whose camera is set receives shadows.
  bool active = false;

  /// Whether the unified multi-tile `ShadowAtlas` uniform block is active for
  /// the current pass.
  bool atlasActive = false;

  /// Incremented every time a shadow pass renders a map, see
  /// [RenderContext3D.shadowMapVersion].
  int version = 0;

  // The values of the `Shadows` block common to both kinds of map: with the
  // atlas, `_toLight`, `_color` and `_bias` are those of the directional
  // light (and `_lightViewProjection` is unused).
  final Matrix4 _lightViewProjection = Matrix4.identity();
  final Vector4 _toLight = Vector4(0, 0, 0, -1);
  final Vector4 _color = Vector4.zero();
  final Vector4 _map = Vector4.zero();
  final Vector4 _bias = Vector4.zero();
  final Vector4 _decode = Vector4.zero();
  bool _packDepth = false;

  // Whether the last map rendered (or reused from the cache) is the atlas.
  bool _mapIsAtlas = false;

  // Unified multi-tile ShadowAtlas3D state.
  final ShadowAtlas3D atlas = ShadowAtlas3D();
  final List<DirectionalShadowProjection> _csmProjections = List.generate(
    4,
    (_) => DirectionalShadowProjection(),
  );
  int _currentTileIndex = 0;
  int _atlasDirLightIndex = -1;
  int _atlasCascadeCount = 0;
  int _atlasSpotShadowCount = 0;
  final List<ShadowAtlasTile3D> _csmTiles = [];
  final List<ShadowAtlasTile3D> _spotTiles = [];
  ShadowAtlasTile3D? _pointFrontTile;
  ShadowAtlasTile3D? _pointBackTile;
  GpuTextureTarget? _unifiedAtlasTarget;

  // Paraboloid caster uniform values for active tile.
  final Vector4 _paraboloidPosInvRange = Vector4.zero();
  final Vector4 _paraboloidParams = Vector4(1, 0, 0, 0);
  bool _recordingParaboloidTile = false;

  // Spot light helpers.
  final Matrix4 _spotView = Matrix4.identity();
  final Matrix4 _spotProj = Matrix4.identity();
  final Matrix4 _spotVp = Matrix4.identity();
  final Vector3 _spotTarget = Vector3.zero();
  final Vector3 _spotUp = Vector3(0, 1, 0);

  bool get hasPendingAtlasTiles =>
      recording && atlasActive && _currentTileIndex + 1 < atlas.tiles.length;

  // The shadow map, as the texture bound to the receivers.
  GpuTextureTarget? _target;
  Texture? _texture;
  final Expando<_StaticShadowMap> _staticMaps = Expando();
  final Expando<_StaticShadowAtlas> _staticAtlases = Expando();

  // What the atlas of the frame holds, compared with that of a cached one:
  // its size and encoding, then each tile's kind, light, rectangle and
  // projection (or light position and range).
  final Float64List _atlasSignature = Float64List(
    _StaticShadowAtlas.signatureCapacity,
  );
  int _atlasSignatureLength = 0;

  // The camera of the main pass, set back when the shadow pass ends.
  final Matrix4 _mainView = Matrix4.identity();
  final Matrix4 _mainProjection = Matrix4.identity();

  // The view the casters of a point light's tile are culled with: a box
  // around the hemisphere the tile covers.
  final Matrix4 _pointCullView = Matrix4.identity();
  final Matrix4 _pointCullProjection = Matrix4.identity();
  int _drawCallsBefore = 0;

  static final Vector3 _direction = Vector3.zero();
  static final Vector3 _spotDirScratch = Vector3.zero();
  static final Vector4 _noShadows = Vector4(0, 0, 0, -1);
  static final Vector4 _noAtlas = Vector4(0, 0, 0, -1);
  static final Vector4 _oneCascade = Vector4(1, 0, 0, 0);
  static final Vector4 _vec4Scratch = Vector4.zero();
  static final Matrix4 _identityMat = Matrix4.identity();
  static final Float64List _splits = Float64List(ShadowSettings.maxCascades);
  static final Aabb3 _subBox = Aabb3();

  static final Vector4 _packedDecode = Vector4(
    65536 * 255 / 16777215,
    256 * 255 / 16777215,
    255 / 16777215,
    0,
  );

  static const _bundle =
      'packages/flame_3d/assets/shaders/shadow_caster.shaderbundle';
  static const _skinnedBundle =
      'packages/flame_3d/assets/shaders/shadow_caster_skinned.shaderbundle';
  static const _paraboloidBundle =
      'packages/flame_3d/assets/shaders/shadow_caster_paraboloid.shaderbundle';
  static const _paraboloidSkinnedBundle =
      'packages/flame_3d/assets/shaders/'
      'shadow_caster_paraboloid_skinned.shaderbundle';
  late final Shader _vertexShader = VertexShader.fromAsset(
    _bundle,
    slots: [RenderContext3D.cameraMatricesBlock],
  );
  late final Shader _skinnedVertexShader = VertexShader.fromAsset(
    _skinnedBundle,
    slots: [
      RenderContext3D.cameraMatricesBlock,
      RenderContext3D.jointMatricesBlock,
    ],
  );
  late final Shader _fragmentShader = FragmentShader.fromAsset(
    _bundle,
    slots: [RenderContext3D.shadowCasterBlock],
  );

  late final Shader _paraboloidVertexShader = VertexShader.fromAsset(
    _paraboloidBundle,
    slots: const ['ParaboloidLight'],
  );
  late final Shader _paraboloidSkinnedVertexShader = VertexShader.fromAsset(
    _paraboloidSkinnedBundle,
    slots: [
      'ParaboloidLight',
      RenderContext3D.jointMatricesBlock,
    ],
  );
  late final Shader _paraboloidFragmentShader = FragmentShader.fromAsset(
    _paraboloidBundle,
    slots: [RenderContext3D.shadowCasterBlock],
  );

  static const _renderState = RenderState.opaque;

  final Map<VertexLayout, _CasterPipeline> _pipelines = Map.identity();
  final Map<VertexLayout, _CasterPipeline> _paraboloidPipelines =
      Map.identity();

  bool begin(
    DirectionalShadowProjection projection,
    Aabb3? sceneBounds, {
    Object? castersKey,
  }) {
    if (recording) {
      throw StateError('A shadow pass is already being recorded');
    }
    final context = _context;
    final device = context.device;
    active = false;
    atlasActive = false;
    _recordingParaboloidTile = false;
    RenderProfile.switchPass(RenderPhase.setup, shadow: true);
    if (sceneBounds == null || !device.backend.supportsTextureTargets) {
      return _none();
    }

    // Discover shadow-casting directional, spot, and point lights.
    final lights = context.lights;
    Light? dirLight;
    ShadowSettings? dirSettings;
    var dirIndex = 0;
    var foundDirIndex = -1;

    final spotCasters = <(Light, SpotLight, int, ShadowSettings)>[];
    var spotIdx = 0;

    (Light, PointLight, int, ShadowSettings)? pointCaster;
    var pointIdx = 0;

    for (var i = 0; i < lights.length; i++) {
      final l = lights[i];
      if ((l.lightMask & context.cameraMask) == 0) {
        continue;
      }
      final source = l.source;
      if (source is DirectionalLight) {
        if (dirIndex < RenderContext3D.maxDirectionalLights) {
          if (dirLight == null && source.shadows != null) {
            dirLight = l;
            dirSettings = source.shadows;
            foundDirIndex = dirIndex;
          }
          dirIndex++;
        }
      } else if (source is SpotLight) {
        if (source.intensity > 0 && spotIdx < RenderContext3D.maxSpotLights) {
          if (source.shadows != null && spotCasters.length < 2) {
            spotCasters.add((l, source, spotIdx, source.shadows!));
          }
          spotIdx++;
        }
      } else if (source is PointLight) {
        if (pointIdx < RenderContext3D.maxPointLights) {
          if (source.intensity > 0 &&
              source.shadows != null &&
              pointCaster == null) {
            pointCaster = (l, source, pointIdx, source.shadows!);
          }
          pointIdx++;
        }
      }
    }

    if (dirLight == null && spotCasters.isEmpty && pointCaster == null) {
      return _none();
    }

    // The atlas holds several tiles: cascades of the directional light, the
    // two hemispheres of a point light, or the maps of several lights.
    final totalShadowLights =
        (dirLight != null ? 1 : 0) +
        spotCasters.length +
        (pointCaster != null ? 1 : 0);
    final useUnifiedAtlas =
        (dirSettings != null && dirSettings.cascades >= 2) ||
        pointCaster != null ||
        totalShadowLights > 1;

    if (useUnifiedAtlas) {
      return _beginUnifiedAtlas(
        projection: projection,
        castersKey: castersKey,
        sceneBounds: sceneBounds,
        dirLight: dirLight,
        dirIndex: foundDirIndex,
        dirSettings: dirSettings,
        spotCasters: spotCasters,
        pointCaster: pointCaster,
      );
    }

    // One map: a directional light with one cascade, or a lone spot light.
    final bool isSpotShadow;
    final Light light;
    final ShadowSettings settings;
    final int index;
    if (dirLight != null && dirSettings != null) {
      isSpotShadow = false;
      light = dirLight;
      settings = dirSettings;
      index = foundDirIndex;
    } else {
      isSpotShadow = true;
      final s = spotCasters.first;
      light = s.$1;
      settings = s.$4;
      index = 100 + s.$3;
    }

    final direction = light.direction(_direction);
    final resolution = settings.resolution;
    final Matrix4 activeLightView;
    final Matrix4 activeLightProj;
    final double texelWorldSize;

    if (isSpotShadow) {
      final spot = light.source as SpotLight;
      final eye = light.position;
      _spotTarget
        ..setFrom(eye)
        ..add(direction);
      _spotUp.setValues(0, 1, 0);
      if (direction.y.abs() > 0.92) {
        _spotUp.setValues(0, 0, 1);
      }
      _spotView.setAsViewMatrix(eye, _spotTarget, _spotUp);
      final fovDeg = (spot.outerConeAngle * 2.0 * 180.0 / math.pi).clamp(
        10.0,
        165.0,
      );
      final zFar = math.max(1.0, spot.range ?? 32.0);
      _spotProj.setAsPerspective(fovDeg, 1.0, 0.12, zFar);
      _lightViewProjection
        ..setFrom(_spotProj)
        ..multiply(_spotView);
      activeLightView = _spotView;
      activeLightProj = _spotProj;
      texelWorldSize =
          (2.0 * math.tan(spot.outerConeAngle.clamp(0.05, 1.4)) * zFar * 0.35) /
          resolution;
    } else {
      if (!projection.update(
        direction: direction,
        casters: sceneBounds,
        receivers: settings.bounds,
        cameraViewProjection: settings.fit == ShadowFit.view
            ? context._viewProjectionMatrix
            : null,
        cameraView: context._viewMatrix,
        maxDistance: settings.maxDistance,
        resolution: resolution,
        stabilize: settings.stabilize,
      )) {
        return _none();
      }
      _lightViewProjection.setFrom(projection.viewProjection);
      activeLightView = projection.view;
      activeLightProj = projection.projection;
      texelWorldSize = math.max(projection.texelWidth, projection.texelHeight);
    }
    RenderProfile.lap(RenderPhase.shadowSetup);

    final float = switch (settings.encoding) {
      ShadowMapEncoding.auto => device.backend.supportsFloatTextureTargets,
      ShadowMapEncoding.float32 => true,
      ShadowMapEncoding.rgba8 => false,
    };

    final format = float ? GpuPixelFormat.r32Float : GpuPixelFormat.rgba8888;
    final size = resolution.toDouble();
    final vpStorage = _lightViewProjection.storage;

    if (settings.cacheWhenStatic && castersKey != null) {
      final cached = _staticMaps[projection];
      if (cached != null &&
          cached.resolution == resolution &&
          cached.packDepth == !float &&
          cached.castersKey == castersKey &&
          _sameMatrix(vpStorage, cached.lightVp)) {
        if (!identical(_texture, cached.texture)) {
          version++;
          _target = cached.target;
          _texture = cached.texture;
        }
        _packDepth = !float;
        if (float) {
          _decode.setValues(1, 0, 0, 0);
        } else {
          _decode.setFrom(_packedDecode);
        }
        _toLight.setValues(
          -direction.x,
          -direction.y,
          -direction.z,
          index.toDouble(),
        );
        final color = settings.color;
        _color.setValues(
          color.r,
          color.g,
          color.b,
          settings.strength.clamp(0, 1).toDouble(),
        );
        _map.setValues(size, size, 1 / size, 1 / size);
        _bias.setValues(
          texelWorldSize,
          settings.depthBias,
          settings.normalBias,
          settings.softness.toDouble(),
        );
        active = true;
        _mapIsAtlas = false;
        RenderProfile.switchPass(RenderPhase.shadowSetup, shadow: false);
        return false;
      }
    }

    version++;
    _mapIsAtlas = false;
    _staticAtlases[projection] = null;
    final GpuTextureTarget target;
    if (settings.cacheWhenStatic && castersKey != null) {
      var entry = _staticMaps[projection];
      if (entry == null ||
          entry.resolution != resolution ||
          entry.packDepth != !float) {
        final ownedTarget = device.backend.createTextureTarget(
          width: resolution,
          height: resolution,
          format: format,
          clearValue: const Color(0xFFFFFFFF),
        );
        entry = _StaticShadowMap(
          resolution: resolution,
          packDepth: !float,
          target: ownedTarget,
          texture: Texture(
            null,
            width: resolution,
            height: resolution,
            gpuTexture: ownedTarget.texture,
          ),
        );
        _staticMaps[projection] = entry;
      }
      entry.castersKey = castersKey;
      for (var i = 0; i < 16; i++) {
        entry.lightVp[i] = vpStorage[i];
      }
      target = entry.target;
      _target = target;
      _texture = entry.texture;
    } else {
      _staticMaps[projection] = null;
      target = device.textureTarget(resolution, resolution, format);
      if (!identical(target, _target)) {
        _target = target;
        _texture = Texture(
          null,
          width: resolution,
          height: resolution,
          gpuTexture: target.texture,
        );
      }
    }
    _packDepth = !float;
    if (float) {
      _decode.setValues(1, 0, 0, 0);
    } else {
      _decode.setFrom(_packedDecode);
    }
    _toLight.setValues(
      -direction.x,
      -direction.y,
      -direction.z,
      index.toDouble(),
    );
    final color = settings.color;
    _color.setValues(
      color.r,
      color.g,
      color.b,
      settings.strength.clamp(0, 1).toDouble(),
    );
    _map.setValues(size, size, 1 / size, 1 / size);
    _bias.setValues(
      texelWorldSize,
      settings.depthBias,
      settings.normalBias,
      settings.softness.toDouble(),
    );

    _mainView.setFrom(context._viewMatrix);
    _mainProjection.setFrom(context._projectionMatrix);
    context.setCamera(activeLightView, activeLightProj);
    recording = true;
    _drawCallsBefore = device.stats.drawCalls;
    device.beginTexturePass(target, frontFace: context.frontFace);
    device.stats.shadowPasses++;
    RenderProfile.lap(RenderPhase.passBegin);
    return true;
  }

  bool _beginUnifiedAtlas({
    required DirectionalShadowProjection projection,
    required Object? castersKey,
    required Aabb3 sceneBounds,
    required Light? dirLight,
    required int dirIndex,
    required ShadowSettings? dirSettings,
    required List<(Light, SpotLight, int, ShadowSettings)> spotCasters,
    required (Light, PointLight, int, ShadowSettings)? pointCaster,
  }) {
    final context = _context;
    final device = context.device;
    atlas.reset();
    _csmTiles.clear();
    _spotTiles.clear();
    _pointFrontTile = null;
    _pointBackTile = null;

    final csmCount = dirSettings?.cascades ?? 0;
    final totalRequestedTiles =
        csmCount + spotCasters.length + (pointCaster != null ? 2 : 0);
    final preferredRes =
        dirSettings?.resolution ??
        (spotCasters.isNotEmpty
            ? spotCasters.first.$4.resolution
            : (pointCaster?.$4.resolution ?? 512));
    final tileSize = atlas.recommendedTileSize(
      totalRequestedTiles,
      preferred: preferredRes,
    );

    _atlasDirLightIndex = -1;
    _atlasCascadeCount = 0;

    final primarySettings =
        dirSettings ??
        (spotCasters.isNotEmpty ? spotCasters.first.$4 : pointCaster!.$4);

    if (dirLight != null && dirSettings != null && csmCount > 0) {
      final dir = dirLight.direction(_direction);
      _fitCascades(dir, sceneBounds, dirSettings, csmCount, tileSize);
      for (var c = 0; c < csmCount; c++) {
        if (_cascadeMask & (1 << c) == 0) {
          continue;
        }
        final proj = _csmProjections[c];
        final tile = atlas.allocateTile(
          kind: ShadowAtlasTileKind3D.directionalCascade,
          lightIndex: dirIndex,
          subIndex: c,
          tileSize: tileSize,
          view: proj.view,
          projection: proj.projection,
          viewProjection: proj.viewProjection,
          texelWorldSize: math.max(proj.texelWidth, proj.texelHeight),
          depthBias: dirSettings.depthBias,
          softness: dirSettings.softness.toDouble(),
          strength: dirSettings.strength.clamp(0.0, 1.0),
          blendRange: dirSettings.cascadeBlendRange.clamp(0.0, 0.35),
          color: dirSettings.color,
        );
        if (tile != null) {
          _csmTiles.add(tile);
        }
      }
      if (_csmTiles.isNotEmpty) {
        _atlasDirLightIndex = dirIndex;
        _atlasCascadeCount = _csmTiles.length;
        _toLight.setValues(-dir.x, -dir.y, -dir.z, dirIndex.toDouble());
      } else {
        _toLight.setFrom(_noShadows);
      }
    } else {
      _toLight.setFrom(_noShadows);
    }

    for (final (spotLight, spotSource, sIdx, sSettings) in spotCasters) {
      final dir = spotLight.direction(_spotDirScratch);
      final eye = spotLight.position;
      _spotTarget
        ..setFrom(eye)
        ..add(dir);
      _spotUp.setValues(0, 1, 0);
      if (dir.y.abs() > 0.92) {
        _spotUp.setValues(0, 0, 1);
      }
      _spotView.setAsViewMatrix(eye, _spotTarget, _spotUp);
      final fovDeg = (spotSource.outerConeAngle * 2.0 * 180.0 / math.pi).clamp(
        10.0,
        165.0,
      );
      final zFar = math.max(1.0, spotSource.range ?? 32.0);
      _spotProj.setAsPerspective(fovDeg, 1.0, 0.12, zFar);
      _spotVp
        ..setFrom(_spotProj)
        ..multiply(_spotView);
      final texelWorld =
          (2.0 *
              math.tan(spotSource.outerConeAngle.clamp(0.05, 1.4)) *
              zFar *
              0.35) /
          tileSize;
      final tile = atlas.allocateTile(
        kind: ShadowAtlasTileKind3D.spotLight,
        lightIndex: sIdx,
        tileSize: tileSize,
        lightPosition: eye,
        lightRange: zFar,
        view: _spotView,
        projection: _spotProj,
        viewProjection: _spotVp,
        texelWorldSize: texelWorld,
        depthBias: sSettings.depthBias,
        softness: sSettings.softness.toDouble(),
        strength: sSettings.strength.clamp(0.0, 1.0),
        color: sSettings.color,
      );
      if (tile != null) {
        _spotTiles.add(tile);
      }
    }
    _atlasSpotShadowCount = _spotTiles.length;

    if (pointCaster != null) {
      final (ptLight, ptSource, ptIdx, ptSettings) = pointCaster;
      final ptRange = math.max(1.0, ptSource.range ?? 24.0);
      _pointFrontTile = atlas.allocateTile(
        kind: ShadowAtlasTileKind3D.pointParaboloidFront,
        lightIndex: ptIdx,
        tileSize: tileSize,
        lightPosition: ptLight.position,
        lightRange: ptRange,
        depthBias: ptSettings.depthBias,
        softness: ptSettings.softness.toDouble(),
        strength: ptSettings.strength.clamp(0.0, 1.0),
        color: ptSettings.color,
      );
      _pointBackTile = atlas.allocateTile(
        kind: ShadowAtlasTileKind3D.pointParaboloidBack,
        lightIndex: ptIdx,
        subIndex: 1,
        tileSize: tileSize,
        lightPosition: ptLight.position,
        lightRange: ptRange,
        depthBias: ptSettings.depthBias,
        softness: ptSettings.softness.toDouble(),
        strength: ptSettings.strength.clamp(0.0, 1.0),
        color: ptSettings.color,
      );
    }

    if (atlas.tiles.isEmpty) {
      return _none();
    }

    final float = switch (primarySettings.encoding) {
      ShadowMapEncoding.auto => device.backend.supportsFloatTextureTargets,
      ShadowMapEncoding.float32 => true,
      ShadowMapEncoding.rgba8 => false,
    };
    final format = float ? GpuPixelFormat.r32Float : GpuPixelFormat.rgba8888;
    _packDepth = !float;
    if (float) {
      _decode.setValues(1, 0, 0, 0);
    } else {
      _decode.setFrom(_packedDecode);
    }

    final atlasDim = atlas.atlasSize;
    _staticMaps[projection] = null;
    final cache =
        castersKey != null &&
        (dirSettings?.cacheWhenStatic ?? true) &&
        spotCasters.every((spot) => spot.$4.cacheWhenStatic) &&
        (pointCaster?.$4.cacheWhenStatic ?? true);
    final GpuTextureTarget target;
    if (cache) {
      _writeAtlasSignature(atlasDim, atlasDim, float);
      var entry = _staticAtlases[projection];
      if (entry != null && entry.castersKey == castersKey) {
        if (entry.matches(_atlasSignature, _atlasSignatureLength)) {
          // The atlas of an earlier frame holds the same tiles of the same
          // casters: receive it again, without rendering.
          if (!identical(_texture, entry.texture)) {
            version++;
            _target = entry.target;
            _texture = entry.texture;
          }
          _writeAtlasMap(atlasDim, atlasDim, primarySettings);
          active = true;
          atlasActive = true;
          _mapIsAtlas = true;
          RenderProfile.switchPass(RenderPhase.shadowSetup, shadow: false);
          return false;
        }
      }
      if (entry == null ||
          entry.width != atlasDim ||
          entry.height != atlasDim ||
          entry.packDepth != !float) {
        final owned = device.backend.createTextureTarget(
          width: atlasDim,
          height: atlasDim,
          format: format,
          clearValue: const Color(0xFFFFFFFF),
        );
        entry = _StaticShadowAtlas(
          width: atlasDim,
          height: atlasDim,
          packDepth: !float,
          target: owned,
          texture: Texture(
            null,
            width: atlasDim,
            height: atlasDim,
            gpuTexture: owned.texture,
          ),
        );
        _staticAtlases[projection] = entry;
      }
      entry
        ..castersKey = castersKey
        ..store(_atlasSignature, _atlasSignatureLength);
      target = entry.target;
      _target = target;
      _texture = entry.texture;
    } else {
      _staticAtlases[projection] = null;
      target = device.textureTarget(atlasDim, atlasDim, format);
      if (!identical(target, _target)) {
        _target = target;
        _texture = Texture(
          null,
          width: atlasDim,
          height: atlasDim,
          gpuTexture: target.texture,
        );
      }
    }
    _unifiedAtlasTarget = target;

    _writeAtlasMap(atlasDim, atlasDim, primarySettings);

    version++;
    _mapIsAtlas = true;
    _mainView.setFrom(context._viewMatrix);
    _mainProjection.setFrom(context._projectionMatrix);
    atlasActive = true;
    recording = true;
    _currentTileIndex = 0;
    _drawCallsBefore = device.stats.drawCalls;

    device.beginTexturePass(_unifiedAtlasTarget!, frontFace: context.frontFace);
    device.stats.shadowPasses++;
    _configureAtlasTile(atlas.tiles[0]);
    RenderProfile.lap(RenderPhase.passBegin);
    return true;
  }

  /// Sets the values of the `Shadows` block that describe the atlas of
  /// [width] by [height] texels and its directional light, of [settings].
  void _writeAtlasMap(int width, int height, ShadowSettings settings) {
    _map.setValues(
      width.toDouble(),
      height.toDouble(),
      1.0 / width,
      1.0 / height,
    );
    final c = settings.color;
    _color.setValues(c.r, c.g, c.b, settings.strength.clamp(0.0, 1.0));
    _bias.setValues(
      _csmTiles.isNotEmpty ? _csmTiles.first.texelWorldSize : 0.02,
      settings.depthBias,
      settings.normalBias,
      settings.softness.toDouble(),
    );
  }

  /// Writes what the tiles of the [atlas] render into
  /// [_atlasSignature].
  void _writeAtlasSignature(int width, int height, bool float) {
    final out = _atlasSignature;
    var n = 0;
    out[n++] = width.toDouble();
    out[n++] = height.toDouble();
    out[n++] = float ? 1 : 0;
    final tiles = atlas.tiles;
    out[n++] = tiles.length.toDouble();
    for (var i = 0; i < tiles.length; i++) {
      final tile = tiles[i];
      out[n++] = tile.kind.index.toDouble();
      out[n++] = tile.lightIndex.toDouble();
      out[n++] = tile.x.toDouble();
      out[n++] = tile.y.toDouble();
      out[n++] = tile.width.toDouble();
      final viewProjection = tile.viewProjection;
      if (viewProjection != null) {
        final m = viewProjection.storage;
        for (var k = 0; k < 16; k++) {
          out[n++] = m[k];
        }
      } else {
        final position = tile.lightPosition;
        out[n++] = position?.x ?? 0;
        out[n++] = position?.y ?? 0;
        out[n++] = position?.z ?? 0;
        out[n++] = tile.lightRange;
      }
    }
    _atlasSignatureLength = n;
  }

  // The cascades of the directional light that got a projection fitted in
  // [_fitCascades], one bit per cascade.
  int _cascadeMask = 0;

  /// Fits the [count] cascades of a directional light travelling along
  /// [direction] into [_csmProjections], setting a bit of [_cascadeMask] for
  /// each cascade kept.
  ///
  /// The last cascade covers what one map would (see [ShadowSettings.fit]
  /// and [ShadowSettings.maxDistance]). With a perspective camera and
  /// [ShadowFit.view], cascade `c` covers what the camera sees up to
  /// `split[c]` of the farthest distance that receives shadows (the
  /// [ShadowSettings.maxDistance], or the farthest point of the receiving
  /// region); otherwise the central `split[c]` of the receiving region. A
  /// cascade that is not sharper than the next one is dropped: it would only
  /// lower the resolution where it is used.
  void _fitCascades(
    Vector3 direction,
    Aabb3 sceneBounds,
    ShadowSettings settings,
    int count,
    int tileSize,
  ) {
    final context = _context;
    _cascadeSplits(settings, count);
    final perspective = context._projectionMatrix.storage[15].abs() < 0.5;
    final fitView = settings.fit == ShadowFit.view;
    final region = settings.bounds ?? sceneBounds;
    final far = settings.maxDistance ?? _viewDepthExtent(region);
    _cascadeMask = 0;
    var outerTexel = double.infinity;
    for (var c = count - 1; c >= 0; c--) {
      final proj = _csmProjections[c];
      final bool fitted;
      if (c == count - 1) {
        fitted = proj.update(
          direction: direction,
          casters: sceneBounds,
          receivers: settings.bounds,
          cameraViewProjection: fitView ? context._viewProjectionMatrix : null,
          cameraView: context._viewMatrix,
          maxDistance: settings.maxDistance,
          resolution: tileSize,
          stabilize: settings.stabilize,
        );
        if (!fitted) {
          return;
        }
      } else if (perspective && fitView) {
        fitted = proj.update(
          direction: direction,
          casters: sceneBounds,
          receivers: settings.bounds,
          cameraViewProjection: context._viewProjectionMatrix,
          cameraView: context._viewMatrix,
          maxDistance: far * _splits[c],
          resolution: tileSize,
          stabilize: settings.stabilize,
        );
      } else {
        final scale = 0.5 * _splits[c];
        final min = region.min;
        final max = region.max;
        final cx = (min.x + max.x) * 0.5;
        final cy = (min.y + max.y) * 0.5;
        final cz = (min.z + max.z) * 0.5;
        final hx = (max.x - min.x) * scale;
        final hy = (max.y - min.y) * scale;
        final hz = (max.z - min.z) * scale;
        _subBox.min.setValues(cx - hx, cy - hy, cz - hz);
        _subBox.max.setValues(cx + hx, cy + hy, cz + hz);
        fitted = proj.update(
          direction: direction,
          casters: sceneBounds,
          receivers: _subBox,
          resolution: tileSize,
          stabilize: settings.stabilize,
        );
      }
      if (!fitted) {
        continue;
      }
      final texel = math.max(proj.texelWidth, proj.texelHeight);
      if (texel < outerTexel * 0.999) {
        _cascadeMask |= 1 << c;
        outerTexel = texel;
      }
    }
  }

  /// The farthest distance from the camera, along the direction it looks
  /// in, of a corner of [box].
  double _viewDepthExtent(Aabb3 box) {
    final m = _context._viewMatrix.storage;
    final min = box.min;
    final max = box.max;
    var far = 1e-3;
    for (var corner = 0; corner < 8; corner++) {
      final x = corner & 1 == 0 ? min.x : max.x;
      final y = corner & 2 == 0 ? min.y : max.y;
      final z = corner & 4 == 0 ? min.z : max.z;
      final depth = -(m[2] * x + m[6] * y + m[10] * z + m[14]);
      if (depth > far) {
        far = depth;
      }
    }
    return far;
  }

  /// Fills [_splits] with the fractions of the distance (or of the region)
  /// the [count] cascades of [settings] cover: its
  /// [ShadowSettings.cascadeSplits], or splits derived from its
  /// [ShadowSettings.cascadeSplitRatio].
  static void _cascadeSplits(ShadowSettings settings, int count) {
    final explicit = settings.cascadeSplits;
    if (explicit != null) {
      if (explicit.length != count && explicit.length != count - 1) {
        throw StateError(
          'ShadowSettings.cascadeSplits has ${explicit.length} splits for '
          '$count cascades',
        );
      }
      for (var c = 0; c < count - 1; c++) {
        _splits[c] = explicit[c];
      }
      _splits[count - 1] = 1.0;
      return;
    }
    _splits[count - 1] = 1.0;
    if (count == 1) {
      return;
    }
    final first = settings.cascadeSplitRatio.clamp(0.06, 0.5);
    if (count == 2) {
      _splits[0] = first;
      return;
    }
    if (count == 3) {
      _splits[0] = first;
      _splits[1] = (first + (1.0 - first) * 0.45).clamp(first + 0.05, 0.92);
      return;
    }
    // 4 cascades: logarithmic progression from `first * 0.55` to `1.0`.
    final s0 = (first * 0.55).clamp(0.06, 0.25);
    final s1 = (s0 * 2.3).clamp(s0 + 0.06, 0.52);
    _splits[0] = s0;
    _splits[1] = s1;
    _splits[2] = (s1 + (1.0 - s1) * 0.5).clamp(s1 + 0.08, 0.85);
  }

  void _configureAtlasTile(ShadowAtlasTile3D tile) {
    final context = _context;
    final device = context.device;
    device
      ..setViewport(tile.x, tile.y, tile.width, tile.height)
      ..setScissor(tile.x, tile.y, tile.width, tile.height);

    if (tile.kind == ShadowAtlasTileKind3D.pointParaboloidFront ||
        tile.kind == ShadowAtlasTileKind3D.pointParaboloidBack) {
      _recordingParaboloidTile = true;
      final pos = tile.lightPosition!;
      _paraboloidPosInvRange.setValues(
        pos.x,
        pos.y,
        pos.z,
        1.0 / math.max(1e-3, tile.lightRange),
      );
      final side = tile.kind == ShadowAtlasTileKind3D.pointParaboloidFront
          ? 1.0
          : -1.0;
      _paraboloidParams.setValues(side, 0, 0, 0);
      // The casters are culled with a box around the hemisphere of the light
      // the tile covers (its shaders do not use the camera's matrices).
      final range = tile.lightRange;
      writeLookAt(
        _pointCullView.storage,
        pos.x,
        pos.y,
        pos.z,
        pos.x,
        pos.y,
        pos.z + side,
        0,
        1,
        0,
      );
      writeOrthographic(
        _pointCullProjection.storage,
        -range,
        range,
        -range,
        range,
        -0.05 * range,
        range,
      );
      context.setCamera(_pointCullView, _pointCullProjection);
    } else {
      _recordingParaboloidTile = false;
      context.setCamera(tile.view!, tile.projection!);
    }
    atlasActive = true;
  }

  /// Flushes the casters recorded for the current `ShadowAtlas3D` tile and
  /// advances to the next tile in the same open render pass, returning `false`
  /// once all tiles have been recorded.
  bool advanceAtlasTile() {
    if (!recording || !atlasActive) {
      return false;
    }
    flushCasters();
    _currentTileIndex++;
    if (_currentTileIndex >= atlas.tiles.length) {
      return false;
    }
    _configureAtlasTile(atlas.tiles[_currentTileIndex]);
    return true;
  }

  bool _none() {
    RenderProfile.switchPass(RenderPhase.shadowSetup, shadow: false);
    return false;
  }

  bool reuse(int mapVersion) {
    if (recording) {
      throw StateError('A shadow pass is being recorded');
    }
    if (mapVersion != version || _texture == null) {
      return false;
    }
    active = true;
    atlasActive = _mapIsAtlas;
    return true;
  }

  void end() {
    if (!recording) {
      throw StateError('No shadow pass is being recorded');
    }
    final context = _context;
    final device = context.device;
    final wasAtlas = atlasActive;
    try {
      RenderProfile.lap(RenderPhase.traversal);
      if (!wasAtlas || _currentTileIndex < atlas.tiles.length) {
        flushCasters();
      }
    } finally {
      device.endTexturePass();
      device.stats.shadowDrawCalls += device.stats.drawCalls - _drawCallsBefore;
      recording = false;
      _recordingParaboloidTile = false;
      RenderProfile.switchPass(RenderPhase.passEnd, shadow: false);
      context.setCamera(_mainView, _mainProjection);
      active = true;
      atlasActive = wasAtlas;
      RenderProfile.lap(RenderPhase.setup);
    }
  }

  void flushCasters() {
    final context = _context;
    final count = context._count;
    final order = context._opaque;
    final groupKeys = context._groupKeys;
    final surfaceKeys = context._surfaceKeys;
    final sortDepths = context._sortDepths;
    var casters = 0;
    VertexLayout? lastLayout;
    _CasterPipeline? caster;
    for (var i = 0; i < count; i++) {
      if (!context._materials[i]!.castsShadows) {
        continue;
      }
      final surface = context._surfaces[i]!;
      final layout = surface.layout;
      if (!identical(layout, lastLayout)) {
        lastLayout = layout;
        caster = _recordingParaboloidTile
            ? _paraboloidCasterFor(layout)
            : _casterFor(layout);
      }
      if (caster == null) {
        continue;
      }
      final pipeline = caster.pipeline;
      context._pipelines[i] = pipeline;
      groupKeys[i] = pipeline.id.toDouble();
      surfaceKeys[i] = surface.id * 2 + (context._joints[i] == null ? 0 : 1);
      sortDepths[i] = context._depths[i];
      order[casters++] = i;
    }
    context._sort(order, casters);
    RenderProfile.lap(RenderPhase.sort);

    context._boundMaterial = null;
    context._bindingEpoch = -1;
    var start = 0;
    while (start < casters) {
      final first = order[start];
      var end = start + 1;
      if (context._joints[first] == null && context._external[first] == null) {
        while (end < casters && _batchesWith(first, order[end])) {
          end++;
        }
      }
      _submit(order, start, end - start);
      start = end;
    }

    context
      .._releaseDraws(count)
      .._jointTransforms = null;
    context._lastDrawCount = count;
    context._count = 0;
    RenderProfile.lap(RenderPhase.release);
  }

  bool _batchesWith(int first, int other) {
    final context = _context;
    return identical(context._surfaces[first], context._surfaces[other]) &&
        identical(context._pipelines[first], context._pipelines[other]) &&
        context._joints[other] == null &&
        context._external[other] == null;
  }

  void _submit(Int32List order, int start, int count) {
    final context = _context;
    final device = context.device;
    final first = order[start];
    final surface = context._surfaces[first]!;
    final Shader vertexShader;
    final Shader fragmentShader;
    if (_recordingParaboloidTile) {
      final skinned = _paraboloidPipelines[surface.layout]!.skinned;
      vertexShader = skinned
          ? _paraboloidSkinnedVertexShader
          : _paraboloidVertexShader;
      fragmentShader = _paraboloidFragmentShader;
      vertexShader
        ..setVector4('ParaboloidLight.posInvRange', _paraboloidPosInvRange)
        ..setVector4('ParaboloidLight.params', _paraboloidParams);
    } else {
      vertexShader = _pipelines[surface.layout]!.skinned
          ? _skinnedVertexShader
          : _vertexShader;
      fragmentShader = _fragmentShader;
    }
    RenderProfile.lap(RenderPhase.batch);

    device.bindPipeline(context._pipelines[first]!);
    if (device.bindingEpoch != context._bindingEpoch) {
      context
        .._bindingEpoch = device.bindingEpoch
        .._bindSlots(vertexShader, RenderContext3D._passScope)
        .._bindSlots(fragmentShader, RenderContext3D._passScope);
    }
    if (_recordingParaboloidTile) {
      device.bindUniformBlock(vertexShader.block('ParaboloidLight'));
    }
    device
      ..setRenderState(_renderState)
      ..setFrontFace(WindingOrder.counterClockwise);
    RenderProfile.lap(RenderPhase.state);
    context._bindJoints(vertexShader, context._joints[first]);
    device.bindSurface(surface);
    final external = context._external[first];
    if (external != null) {
      final instanceCount = context._externalCounts[first];
      device
        ..bindInstances(external, instanceCount)
        ..drawSurface(surface, instanceCount: instanceCount);
      RenderProfile.lap(RenderPhase.draw);
      return;
    }
    device
      ..bindInstancesOf(context._instances, order, start, count)
      ..drawSurface(surface, instanceCount: count);
    RenderProfile.lap(RenderPhase.draw);
  }

  _CasterPipeline? _casterFor(VertexLayout layout) {
    var caster = _pipelines[layout];
    if (caster == null) {
      final position = layout.attribute(VertexLayout.positionAttribute);
      final skinned =
          layout.attribute('vertexJoints')?.components == 4 &&
          layout.attribute('vertexWeights')?.components == 4;
      caster = _pipelines[layout] = _CasterPipeline(
        drawable: position != null && position.components == 3,
        skinned: skinned,
      );
    }
    if (!caster.drawable) {
      return null;
    }
    final vertexShader = caster.skinned ? _skinnedVertexShader : _vertexShader;
    final fragmentShader = _fragmentShader;
    vertexShader.resource;
    fragmentShader.resource;
    if (caster._pipeline == null ||
        caster._vertexGeneration != vertexShader.generation ||
        caster._fragmentGeneration != fragmentShader.generation) {
      caster
        .._pipeline = _context.device.pipelineFor(
          vertexShader,
          fragmentShader,
          layout,
        )
        .._vertexGeneration = vertexShader.generation
        .._fragmentGeneration = fragmentShader.generation;
    }
    return caster;
  }

  _CasterPipeline? _paraboloidCasterFor(VertexLayout layout) {
    var caster = _paraboloidPipelines[layout];
    if (caster == null) {
      final position = layout.attribute(VertexLayout.positionAttribute);
      final skinned =
          layout.attribute('vertexJoints')?.components == 4 &&
          layout.attribute('vertexWeights')?.components == 4;
      caster = _paraboloidPipelines[layout] = _CasterPipeline(
        drawable: position != null && position.components == 3,
        skinned: skinned,
      );
    }
    if (!caster.drawable) {
      return null;
    }
    final vertexShader = caster.skinned
        ? _paraboloidSkinnedVertexShader
        : _paraboloidVertexShader;
    final fragmentShader = _paraboloidFragmentShader;
    vertexShader.resource;
    fragmentShader.resource;
    if (caster._pipeline == null ||
        caster._vertexGeneration != vertexShader.generation ||
        caster._fragmentGeneration != fragmentShader.generation) {
      caster
        .._pipeline = _context.device.pipelineFor(
          vertexShader,
          fragmentShader,
          layout,
        )
        .._vertexGeneration = vertexShader.generation
        .._fragmentGeneration = fragmentShader.generation;
    }
    return caster;
  }

  void writeShadows(UniformBlock block) {
    if (!active) {
      block
        ..setVector4('toLight', _noShadows)
        ..setVector4('atlas', _noAtlas);
      return;
    }
    block
      ..setMatrix4('lightViewProjection', _lightViewProjection)
      ..setMatrix4('cascadeViewProjection', _identityMat)
      ..setVector4('toLight', _toLight)
      ..setVector4('color', _color)
      ..setVector4('map', _map)
      ..setVector4('bias', _bias)
      ..setVector4('decode', _decode)
      ..setVector4('cascadeParams', _oneCascade);
    if (!atlasActive) {
      block.setVector4('atlas', _noAtlas);
      return;
    }
    final scratch = _vec4Scratch;
    for (var c = 0; c < _csmTiles.length; c++) {
      final t = _csmTiles[c];
      block
        ..setMatrix4('atlasCascadeViewProjections', t.viewProjection!, index: c)
        ..setVector4('atlasCascadeRects', t.uvRect, index: c)
        ..setVector4(
          'atlasCascadeParams',
          scratch..setValues(t.texelWorldSize, t.blendRange, 0, 0),
          index: c,
        );
    }
    for (var s = 0; s < _spotTiles.length; s++) {
      final t = _spotTiles[s];
      final position = t.lightPosition!;
      final color = t.color;
      block
        ..setMatrix4('atlasSpotViewProjections', t.viewProjection!, index: s)
        ..setVector4('atlasSpotRects', t.uvRect, index: s)
        ..setVector4(
          'atlasSpotParams',
          scratch..setValues(
            t.lightIndex.toDouble(),
            t.texelWorldSize,
            t.depthBias,
            t.strength,
          ),
          index: s,
        )
        ..setVector4(
          'atlasSpotPositions',
          scratch..setValues(position.x, position.y, position.z, t.softness),
          index: s,
        )
        ..setVector4(
          'atlasSpotColors',
          scratch..setValues(color.r, color.g, color.b, 1),
          index: s,
        );
    }
    final front = _pointFrontTile;
    final back = _pointBackTile;
    var pointIndex = -1.0;
    if (front != null && back != null) {
      pointIndex = front.lightIndex.toDouble();
      final position = front.lightPosition!;
      final color = front.color;
      block
        ..setVector4(
          'atlasPointPosition',
          scratch..setValues(
            position.x,
            position.y,
            position.z,
            1.0 / math.max(1e-3, front.lightRange),
          ),
        )
        ..setVector4('atlasPointRects', front.uvRect, index: 0)
        ..setVector4('atlasPointRects', back.uvRect, index: 1)
        ..setVector4(
          'atlasPointParams',
          scratch
            ..setValues(front.depthBias, front.softness, front.strength, 0),
        )
        ..setVector4(
          'atlasPointColor',
          scratch..setValues(color.r, color.g, color.b, 1),
        );
    }
    block.setVector4(
      'atlas',
      scratch..setValues(
        1,
        _csmTiles.length.toDouble(),
        _spotTiles.length.toDouble(),
        pointIndex,
      ),
    );
  }

  void writeShadowAtlas(UniformBlock block) {
    if (!active || !atlasActive) {
      block.setVector4(
        'header',
        _vec4Scratch..setValues(0, 0, -1, 0),
      );
      return;
    }

    for (var c = 0; c < 4; c++) {
      if (c < _csmTiles.length) {
        final t = _csmTiles[c];
        block
          ..setMatrix4('csmViewProj', t.viewProjection!, index: c)
          ..setVector4('csmUvRect', t.uvRect, index: c)
          ..setVector4(
            'csmMeta',
            _vec4Scratch..setValues(t.texelWorldSize, 0, t.blendRange, 1.0),
            index: c,
          );
      } else {
        block
          ..setMatrix4('csmViewProj', _identityMat, index: c)
          ..setVector4('csmUvRect', _vec4Scratch..setZero(), index: c)
          ..setVector4('csmMeta', _vec4Scratch, index: c);
      }
    }

    for (var s = 0; s < 2; s++) {
      if (s < _spotTiles.length) {
        final t = _spotTiles[s];
        final col = t.color;
        block
          ..setMatrix4('spotViewProj', t.viewProjection!, index: s)
          ..setVector4('spotUvRect', t.uvRect, index: s)
          ..setVector4(
            'spotMeta',
            _vec4Scratch..setValues(
              t.lightIndex.toDouble(),
              t.texelWorldSize,
              t.depthBias,
              t.strength,
            ),
            index: s,
          )
          ..setVector4(
            'spotColor',
            _vec4Scratch..setValues(col.r, col.g, col.b, 1.0),
            index: s,
          );
      } else {
        block
          ..setMatrix4('spotViewProj', _identityMat, index: s)
          ..setVector4('spotUvRect', _vec4Scratch..setZero(), index: s)
          ..setVector4(
            'spotMeta',
            _vec4Scratch..setValues(-1, 0, 0, 0),
            index: s,
          )
          ..setVector4('spotColor', _vec4Scratch..setZero(), index: s);
      }
    }

    final ptFront = _pointFrontTile;
    final ptBack = _pointBackTile;
    if (ptFront != null && ptBack != null) {
      final pos = ptFront.lightPosition!;
      final col = ptFront.color;
      block
        ..setVector4(
          'pointPosRange',
          _vec4Scratch..setValues(
            pos.x,
            pos.y,
            pos.z,
            1.0 / math.max(1e-3, ptFront.lightRange),
          ),
        )
        ..setVector4('pointFrontUvRect', ptFront.uvRect)
        ..setVector4('pointBackUvRect', ptBack.uvRect)
        ..setVector4(
          'pointMeta',
          _vec4Scratch..setValues(
            ptFront.lightIndex.toDouble(),
            ptFront.depthBias,
            ptFront.softness,
            ptFront.strength,
          ),
        )
        ..setVector4(
          'pointColor',
          _vec4Scratch..setValues(col.r, col.g, col.b, 1.0),
        );
    } else {
      block.setVector4(
        'pointMeta',
        _vec4Scratch..setValues(-1, 0, 0, 0),
      );
    }

    block.setVector4(
      'header',
      _vec4Scratch..setValues(
        1.0,
        _atlasCascadeCount.toDouble(),
        _atlasDirLightIndex.toDouble(),
        _atlasSpotShadowCount.toDouble(),
      ),
    );
  }

  static void writeCasterUniforms(
    RenderContext3D context,
    UniformBlock block,
  ) {
    block.setFloat('packDepth', context._shadows._packDepth ? 1 : 0);
  }

  static void writeAtlasUniforms(
    RenderContext3D context,
    UniformBlock block,
  ) {
    context._shadows.writeShadowAtlas(block);
  }

  static Texture shadowMapTexture(RenderContext3D context) {
    final shadows = context._shadows;
    return shadows.active ? shadows._texture! : Texture.standard;
  }

  static bool _sameMatrix(Float32List a, Float32List b) {
    for (var i = 0; i < 16; i++) {
      if ((a[i] - b[i]).abs() > 1e-9) {
        return false;
      }
    }
    return true;
  }
}

class _StaticShadowMap({
  required final int resolution,
  required final bool packDepth,
  required final GpuTextureTarget target,
  required final Texture texture,
}) {
  Object? castersKey;
  final Float32List lightVp = Float32List(16);
}

class _StaticShadowAtlas({
  required final int width,
  required final int height,
  required final bool packDepth,
  required final GpuTextureTarget target,
  required final Texture texture,
}) {
  /// The most floats a signature of the atlas takes: a header of 4, and 21
  /// per tile for at most 8 tiles.
  static const int signatureCapacity = 4 + 21 * 8;

  Object? castersKey;
  final Float64List _signature = Float64List(signatureCapacity);
  int _length = 0;

  bool matches(Float64List signature, int length) {
    if (length != _length) {
      return false;
    }
    for (var i = 0; i < length; i++) {
      if ((signature[i] - _signature[i]).abs() > 1e-9) {
        return false;
      }
    }
    return true;
  }

  void store(Float64List signature, int length) {
    _signature.setRange(0, length, signature);
    _length = length;
  }
}

class _CasterPipeline({
  required final bool drawable,
  required final bool skinned,
}) {
  DevicePipeline? _pipeline;
  int _vertexGeneration = -1;
  int _fragmentGeneration = -1;

  DevicePipeline get pipeline => _pipeline!;
}
