part of 'render_context_3d.dart';

/// The shadow pass of a [RenderContext3D]: supports both the fast single-light
/// 1/2-cascade path AND the unified multi-tile `2048x2048` [ShadowAtlas3D]
/// (`1..4` directional cascades + up to `2` simultaneous `SpotLight`s +
/// Dual-Paraboloid `+Z`/`-Z` omnidirectional `PointLight` shadows rendered in a
/// single pass via `setViewport` + `setScissor`).
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

  // Legacy 1/2-cascade Shadows block values (also populated with Cascade 0
  // when `atlasActive` is true so non-PBR shaders still receive shadows).
  final Matrix4 _lightViewProjection = Matrix4.identity();
  final Matrix4 _cascadeViewProjection = Matrix4.identity();
  final Vector4 _toLight = Vector4(0, 0, 0, -1);
  final Vector4 _color = Vector4.zero();
  final Vector4 _map = Vector4.zero();
  final Vector4 _bias = Vector4.zero();
  final Vector4 _decode = Vector4.zero();
  final Vector4 _cascadeParams = Vector4(1, 0, 0, 0);
  bool _packDepth = false;

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

  // Legacy 2-cascade CSM & single SpotLight helpers.
  final DirectionalShadowProjection _farProjection =
      DirectionalShadowProjection();
  bool _pendingCascade1 = false;
  int _csmResolution = 1024;
  GpuTextureTarget? _csmTarget0;
  GpuTextureTarget? _csmTarget1;
  GpuTextureTarget? _csmAtlasTarget;
  final Matrix4 _spotView = Matrix4.identity();
  final Matrix4 _spotProj = Matrix4.identity();
  final Matrix4 _spotVp = Matrix4.identity();
  final Vector3 _spotTarget = Vector3.zero();
  final Vector3 _spotUp = Vector3(0, 1, 0);

  bool get needsCascade1 => _pendingCascade1;

  bool get hasPendingAtlasTiles =>
      recording && atlasActive && _currentTileIndex + 1 < atlas.tiles.length;

  // The shadow map, as the texture bound to the receivers.
  GpuTextureTarget? _target;
  Texture? _texture;
  final Expando<_StaticShadowMap> _staticMaps = Expando();

  // The camera of the main pass, set back when the shadow pass ends.
  final Matrix4 _mainView = Matrix4.identity();
  final Matrix4 _mainProjection = Matrix4.identity();
  int _drawCallsBefore = 0;

  static final Vector3 _direction = Vector3.zero();
  static final Vector3 _spotDirScratch = Vector3.zero();
  static final Vector4 _noShadows = Vector4(0, 0, 0, -1);
  static final Vector4 _vec4Scratch = Vector4.zero();
  static final Matrix4 _identityMat = Matrix4.identity();

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
  static const _atlasPackBundle =
      'packages/flame_3d/assets/shaders/shadow_atlas_pack.shaderbundle';

  static final Surface _atlasQuad = Surface.fromBuffers(
    vertices: Float32List.fromList(const [
      -1.0, -1.0, 0.0, //
      1.0, -1.0, 0.0, //
      1.0, 1.0, 0.0, //
      -1.0, 1.0, 0.0, //
    ]),
    indices: Uint16List.fromList(const [0, 1, 2, 0, 2, 3]),
    layout: VertexLayout(const [
      VertexAttribute(VertexLayout.positionAttribute, 3),
    ]),
  );

  late final Shader _atlasVert = VertexShader.fromAsset(_atlasPackBundle);
  late final Shader _atlasFrag = FragmentShader.fromAsset(
    _atlasPackBundle,
    slots: const ['cascade0Texture', 'cascade1Texture'],
  );

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

    // Decide whether we need the Unified Multi-Tile ShadowAtlas3D:
    // - 3 or 4 directional cascades, OR
    // - PointLight Dual-Paraboloid shadows, OR
    // - More than 1 shadow-casting light active simultaneously!
    final totalShadowLights =
        (dirLight != null ? 1 : 0) +
        spotCasters.length +
        (pointCaster != null ? 1 : 0);
    final useUnifiedAtlas =
        (dirSettings != null && dirSettings.cascades >= 3) ||
        pointCaster != null ||
        totalShadowLights > 1;

    if (useUnifiedAtlas) {
      return _beginUnifiedAtlas(
        sceneBounds: sceneBounds,
        dirLight: dirLight,
        dirIndex: foundDirIndex,
        dirSettings: dirSettings,
        spotCasters: spotCasters,
        pointCaster: pointCaster,
      );
    }

    // Fast legacy single-light 1/2-cascade path (100% backward-compatible).
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

    _pendingCascade1 = false;
    _cascadeParams.setValues(1, 0, 0, 0);

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
    } else if (settings.cascades == 2) {
      final farDist = settings.maxDistance;
      final split = settings.cascadeSplitRatio.clamp(0.08, 0.85);
      if (!_farProjection.update(
        direction: direction,
        casters: sceneBounds,
        receivers: settings.bounds,
        cameraViewProjection: settings.fit == ShadowFit.view
            ? context._viewProjectionMatrix
            : null,
        cameraView: context._viewMatrix,
        maxDistance: farDist,
        resolution: resolution,
        stabilize: settings.stabilize,
      )) {
        return _none();
      }
      final isPerspectiveCam =
          context._projectionMatrix.storage[15].abs() < 0.5;
      var nearFitted = false;
      if (isPerspectiveCam) {
        final nearDist = (farDist ?? 40.0) * split;
        nearFitted = projection.update(
          direction: direction,
          casters: sceneBounds,
          receivers: settings.bounds,
          cameraViewProjection: context._viewProjectionMatrix,
          cameraView: context._viewMatrix,
          maxDistance: nearDist,
          resolution: resolution,
          stabilize: settings.stabilize,
        );
      }
      if (!nearFitted) {
        final fullBox = settings.bounds ?? sceneBounds;
        final c = fullBox.center;
        final half = (fullBox.max - fullBox.min)..scale(0.5 * split);
        final innerBox = Aabb3.minMax(c - half, c + half);
        nearFitted = projection.update(
          direction: direction,
          casters: sceneBounds,
          receivers: innerBox,
          resolution: resolution,
          stabilize: settings.stabilize,
        );
      }
      if (!nearFitted) {
        return _none();
      }
      _lightViewProjection.setFrom(projection.viewProjection);
      _cascadeViewProjection.setFrom(_farProjection.viewProjection);
      _cascadeParams.setValues(
        2.0,
        math.max(_farProjection.texelWidth, _farProjection.texelHeight),
        0,
        0,
      );
      activeLightView = projection.view;
      activeLightProj = projection.projection;
      texelWorldSize = math.max(projection.texelWidth, projection.texelHeight);
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
    final isTwoCascade = !isSpotShadow && settings.cascades == 2;

    if (!isTwoCascade && settings.cacheWhenStatic && castersKey != null) {
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
        RenderProfile.switchPass(RenderPhase.shadowSetup, shadow: false);
        return false;
      }
    }

    version++;
    final GpuTextureTarget target;
    if (isTwoCascade) {
      _staticMaps[projection] = null;
      _csmResolution = resolution;
      _csmTarget0 = device.textureTarget(
        resolution,
        resolution,
        format,
        clearValue: const Color(0xFFFFFFFE),
      );
      _csmTarget1 = device.textureTarget(
        resolution,
        resolution,
        format,
        clearValue: const Color(0xFFFFFFFD),
      );
      _csmAtlasTarget = device.textureTarget(
        resolution * 2,
        resolution,
        format,
      );
      target = _csmTarget0!;
      _target = _csmAtlasTarget;
      _texture = Texture(
        null,
        width: resolution * 2,
        height: resolution,
        gpuTexture: _csmAtlasTarget!.texture,
      );
      _pendingCascade1 = true;
    } else if (settings.cacheWhenStatic && castersKey != null) {
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
    if (isTwoCascade) {
      final atlasW = size * 2.0;
      _map.setValues(atlasW, size, 1.0 / atlasW, 1.0 / size);
    } else {
      _map.setValues(size, size, 1 / size, 1 / size);
    }
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
      final splits = _computeCascadeSplits(dirSettings, csmCount);
      final isPerspectiveCam =
          context._projectionMatrix.storage[15].abs() < 0.5;
      final fullBox = dirSettings.bounds ?? sceneBounds;
      final boxCenter = fullBox.center;
      final boxSpan = fullBox.max - fullBox.min;

      for (var c = 0; c < csmCount; c++) {
        final splitFrac = splits[c];
        final proj = _csmProjections[c];
        var fitted = false;
        if (isPerspectiveCam && dirSettings.fit == ShadowFit.view) {
          final dist = (dirSettings.maxDistance ?? 48.0) * splitFrac;
          fitted = proj.update(
            direction: dir,
            casters: sceneBounds,
            receivers: dirSettings.bounds,
            cameraViewProjection: context._viewProjectionMatrix,
            cameraView: context._viewMatrix,
            maxDistance: dist,
            resolution: tileSize,
            stabilize: dirSettings.stabilize,
          );
        }
        if (!fitted) {
          final half = boxSpan.clone()..scale(0.5 * splitFrac);
          final subBox = Aabb3.minMax(boxCenter - half, boxCenter + half);
          fitted = proj.update(
            direction: dir,
            casters: sceneBounds,
            receivers: subBox,
            resolution: tileSize,
            stabilize: dirSettings.stabilize,
          );
        }
        if (fitted) {
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
      }
      if (_csmTiles.isNotEmpty) {
        _atlasDirLightIndex = dirIndex;
        _atlasCascadeCount = _csmTiles.length;
        final lastTile = _csmTiles.last;
        _lightViewProjection.setFrom(lastTile.viewProjection!);
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
    _unifiedAtlasTarget = device.textureTarget(
      atlasDim,
      atlasDim,
      format,
    );
    _target = _unifiedAtlasTarget;
    _texture = Texture(
      null,
      width: atlasDim,
      height: atlasDim,
      gpuTexture: _unifiedAtlasTarget!.texture,
    );

    final atlasSizeF = atlasDim.toDouble();
    _map.setValues(atlasSizeF, atlasSizeF, 1.0 / atlasSizeF, 1.0 / atlasSizeF);
    final c = primarySettings.color;
    _color.setValues(
      c.r,
      c.g,
      c.b,
      primarySettings.strength.clamp(0.0, 1.0),
    );
    _bias.setValues(
      _csmTiles.isNotEmpty ? _csmTiles.first.texelWorldSize : 0.02,
      primarySettings.depthBias,
      primarySettings.normalBias,
      primarySettings.softness.toDouble(),
    );
    _cascadeParams.setValues(1, 0, 0, 0);

    version++;
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

  static List<double> _computeCascadeSplits(
    ShadowSettings settings,
    int count,
  ) {
    final explicit = settings.cascadeSplits;
    if (explicit != null && explicit.length == count) {
      return explicit;
    }
    if (count == 1) {
      return const [1.0];
    }
    final first = settings.cascadeSplitRatio.clamp(0.06, 0.5);
    if (count == 2) {
      return [first, 1.0];
    }
    if (count == 3) {
      final second = (first + (1.0 - first) * 0.45).clamp(first + 0.05, 0.92);
      return [first, second, 1.0];
    }
    // 4 cascades: logarithmic progression from `first * 0.55` to `1.0`.
    final s0 = (first * 0.55).clamp(0.06, 0.25);
    final s1 = (s0 * 2.3).clamp(s0 + 0.06, 0.52);
    final s2 = (s1 + (1.0 - s1) * 0.5).clamp(s1 + 0.08, 0.85);
    return [s0, s1, s2, 1.0];
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
      _paraboloidParams.setValues(
        tile.kind == ShadowAtlasTileKind3D.pointParaboloidFront ? 1.0 : -1.0,
        0,
        0,
        0,
      );
      // Keep main view/projection active so component culling doesn't discard
      // casters behind a single perspective cone while `recording` is true.
      context
        .._viewMatrix.setFrom(_mainView)
        .._projectionMatrix.setFrom(_mainProjection)
        .._viewProjectionMatrix.setFrom(_mainProjection)
        .._viewProjectionMatrix.multiply(_mainView);
    } else {
      _recordingParaboloidTile = false;
      final preserveAtlasFlag = atlasActive;
      context.setCamera(tile.view!, tile.projection!);
      atlasActive = preserveAtlasFlag;
    }
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

  void beginCascade1() {
    if (!_pendingCascade1) {
      return;
    }
    final context = _context;
    final device = context.device;
    context.setCamera(_farProjection.view, _farProjection.projection);
    recording = true;
    _drawCallsBefore = device.stats.drawCalls;
    device.beginTexturePass(_csmTarget1!, frontFace: context.frontFace);
    device.stats.shadowPasses++;
  }

  void endCascade1() {
    if (!recording || !_pendingCascade1) {
      return;
    }
    _pendingCascade1 = false;
    final context = _context;
    final device = context.device;
    try {
      flushCasters();
    } finally {
      device.endTexturePass();
      device.stats.shadowDrawCalls += device.stats.drawCalls - _drawCallsBefore;
      recording = false;
    }

    final res = _csmResolution;
    final tex0 = Texture(
      null,
      width: res,
      height: res,
      gpuTexture: _csmTarget0!.texture,
    );
    final tex1 = Texture(
      null,
      width: res,
      height: res,
      gpuTexture: _csmTarget1!.texture,
    );
    _atlasVert.resource;
    _atlasFrag
      ..resource
      ..setTexture('cascade0Texture', tex0)
      ..setTexture('cascade1Texture', tex1);
    final pipeline = device.pipelineFor(
      _atlasVert,
      _atlasFrag,
      _atlasQuad.layout,
    );
    device
      ..beginTexturePass(_csmAtlasTarget!)
      ..bindPipeline(pipeline)
      ..setRenderState(
        const RenderState(depthTest: false, depthWrite: false),
      )
      ..bindTexture(_atlasFrag.slot('cascade0Texture'), tex0)
      ..bindTexture(_atlasFrag.slot('cascade1Texture'), tex1)
      ..bindSurface(_atlasQuad)
      ..drawSurface(_atlasQuad)
      ..endTexturePass();

    context.setCamera(_mainView, _mainProjection);
    active = true;
  }

  void writeShadows(UniformBlock block) {
    if (!active) {
      block.setVector4('toLight', _noShadows);
      return;
    }
    block
      ..setMatrix4('lightViewProjection', _lightViewProjection)
      ..setMatrix4('cascadeViewProjection', _cascadeViewProjection)
      ..setVector4('toLight', _toLight)
      ..setVector4('color', _color)
      ..setVector4('map', _map)
      ..setVector4('bias', _bias)
      ..setVector4('decode', _decode)
      ..setVector4('cascadeParams', _cascadeParams);
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

class _CasterPipeline({
  required final bool drawable,
  required final bool skinned,
}) {
  DevicePipeline? _pipeline;
  int _vertexGeneration = -1;
  int _fragmentGeneration = -1;

  DevicePipeline get pipeline => _pipeline!;
}
