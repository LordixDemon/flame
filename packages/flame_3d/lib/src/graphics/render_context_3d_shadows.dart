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

  /// Whether the map of the last [begin] depends on the cameras it is fitted
  /// to: a directional light with [ShadowFit.view] casts in it. See
  /// [RenderContext3D.shadowMapFollowsViews].
  bool followsViews = false;

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

  // The projections of the cascades of each projection given to [begin] (of
  // each world, or each shadow group), so that each keeps the sizes of its
  // own last fit.
  final Expando<List<DirectionalShadowProjection>> _cascadeProjections =
      Expando();

  List<DirectionalShadowProjection> _cascadesOf(
    DirectionalShadowProjection owner,
  ) {
    return _cascadeProjections[owner] ??= List.generate(
      ShadowSettings.maxCascades,
      (_) => DirectionalShadowProjection(),
    );
  }

  // The cameras a directional map is fitted to with ShadowFit.view, during
  // [begin]: those given to RenderContext3D.beginShadowPass, or `null` for
  // the camera of the pass.
  List<Matrix4>? _fitViewProjections;
  List<Matrix4>? _fitViews;
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
  int _paraboloidTileEpoch = 0;

  // The spot lights (two at most) and the point light that cast shadows in
  // the pass, with their indices in their blocks, found by [begin].
  final List<Light?> _spotCasters = List<Light?>.filled(2, null);
  final Int32List _spotCasterIndices = Int32List(2);
  int _spotCasterCount = 0;
  Light? _pointCaster;
  int _pointCasterIndex = -1;

  // Spot light helpers.
  final Matrix4 _spotView = Matrix4.identity();
  final Matrix4 _spotProj = Matrix4.identity();
  final Matrix4 _spotVp = Matrix4.identity();
  final Vector3 _spotTarget = Vector3.zero();
  final Vector3 _spotUp = Vector3(0, 1, 0);

  bool get hasPendingAtlasTiles =>
      recording && atlasActive && _currentTileIndex + 1 < atlas.tiles.length;

  /// The casters being recorded, see [RenderContext3D.shadowCasterLayer].
  ShadowCasterLayer layer = ShadowCasterLayer.all;

  // ShadowSettings.cacheStillCasters: the kept layers of still casters of
  // each projection given to [begin], and those of the frame being recorded
  // (`null` when it does not keep them).
  final Expando<_StillLayers> _stillLayers = Expando();
  _StillLayers? _split;
  // Whether the frame being recorded with [_split] is the atlas.
  bool _splitAtlas = false;
  // The view of a single map kept with [_split].
  Matrix4? _singleView;
  Matrix4? _singleProjection;
  int _singleSize = 0;
  // The steps of the frame: first the layers to render again, one pass each,
  // then the map, one step per view (a copy of its layer with the moving
  // casters over it, or every caster).
  static const int _stepStill = 0;
  static const int _stepOver = 1;
  static const int _stepWhole = 2;
  final Int32List _stepTiles = Int32List(2 * _maxViews);
  final Int32List _stepKinds = Int32List(2 * _maxViews);
  final Int32List _viewKinds = Int32List(_maxViews);
  int _stepCount = 0;
  int _step = 0;
  bool _stepsDone = false;
  bool _passOpen = false;
  int _stepDrawCalls = 0;
  int _stepTriangles = 0;
  // Whether the moving casters are being recorded, over [_stillTexture].
  bool _recordingMovers = false;
  Texture? _stillTexture;
  final Float64List _tileSignature = Float64List(_tileSignatureLength);

  /// The most views of a frame: the tiles of the atlas.
  static const int _maxViews = 8;

  /// The values a view's signature holds: its kind, light and size, and its
  /// view-projection (or light position and range).
  static const int _tileSignatureLength = 19;

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
  final _CameraSnapshot _mainCamera = _CameraSnapshot();

  // The view the casters of a point light's tile are culled with: a box
  // around the hemisphere the tile covers.
  final Matrix4 _pointCullView = Matrix4.identity();
  final Matrix4 _pointCullProjection = Matrix4.identity();
  int _drawCallsBefore = 0;
  int _trianglesBefore = 0;

  static final Vector3 _direction = Vector3.zero();
  static final Vector3 _spotDirScratch = Vector3.zero();
  static final Vector4 _noShadows = Vector4(0, 0, 0, -1);
  static final Matrix4 _identityMat = Matrix4.identity();
  static final Float64List _splits = Float64List(ShadowSettings.maxCascades);
  static final Int32List _selection = Int32List(RenderContext3D.maxPointLights);
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

  static const _movingBundle =
      'packages/flame_3d/assets/shaders/shadow_caster_moving.shaderbundle';
  static const _movingSkinnedBundle =
      'packages/flame_3d/assets/shaders/'
      'shadow_caster_moving_skinned.shaderbundle';
  static const _paraboloidMovingBundle =
      'packages/flame_3d/assets/shaders/'
      'shadow_caster_paraboloid_moving.shaderbundle';
  static const _paraboloidMovingSkinnedBundle =
      'packages/flame_3d/assets/shaders/'
      'shadow_caster_paraboloid_moving_skinned.shaderbundle';
  late final Shader _movingVertexShader = VertexShader.fromAsset(
    _movingBundle,
    slots: [RenderContext3D.cameraMatricesBlock],
  );
  late final Shader _movingSkinnedVertexShader = VertexShader.fromAsset(
    _movingSkinnedBundle,
    slots: [
      RenderContext3D.cameraMatricesBlock,
      RenderContext3D.jointMatricesBlock,
    ],
  );
  late final Shader _movingFragmentShader = FragmentShader.fromAsset(
    _movingBundle,
    slots: [
      RenderContext3D.shadowCasterBlock,
      RenderContext3D.shadowStillCastersSampler,
    ],
  );
  late final Shader _paraboloidMovingVertexShader = VertexShader.fromAsset(
    _paraboloidMovingBundle,
    slots: const ['ParaboloidLight'],
  );
  late final Shader _paraboloidMovingSkinnedVertexShader =
      VertexShader.fromAsset(
        _paraboloidMovingSkinnedBundle,
        slots: [
          'ParaboloidLight',
          RenderContext3D.jointMatricesBlock,
        ],
      );
  late final Shader _paraboloidMovingFragmentShader = FragmentShader.fromAsset(
    _paraboloidMovingBundle,
    slots: [
      RenderContext3D.shadowCasterBlock,
      RenderContext3D.shadowStillCastersSampler,
    ],
  );

  static const _renderState = RenderState.opaque;

  final Map<VertexLayout, _CasterPipeline> _pipelines = Map.identity();
  final Map<VertexLayout, _CasterPipeline> _paraboloidPipelines =
      Map.identity();
  final Map<VertexLayout, _CasterPipeline> _movingPipelines = Map.identity();
  final Map<VertexLayout, _CasterPipeline> _paraboloidMovingPipelines =
      Map.identity();

  bool begin(
    DirectionalShadowProjection projection,
    Aabb3? sceneBounds, {
    Object? castersKey,
    Object? stillCastersKey,
  }) {
    if (recording) {
      throw StateError('A shadow pass is already being recorded');
    }
    final context = _context;
    final device = context.device;
    active = false;
    atlasActive = false;
    _recordingParaboloidTile = false;
    _recordingMovers = false;
    _split = null;
    layer = ShadowCasterLayer.all;
    followsViews = false;
    RenderProfile.switchPass(RenderPhase.setup, shadow: true);
    if (sceneBounds == null || !device.backend.supportsTextureTargets) {
      return _none();
    }

    // The lights that cast shadows, and their indices in their blocks: the
    // first directional light with settings among the directional lights
    // the pass holds, the first two such spot lights and the first such point
    // light, among the lights the blocks hold, in their order (see
    // RenderContext3D._selectSpotLights and _selectPointLights).
    final lights = context.lights;
    Light? dirLight;
    ShadowSettings? dirSettings;
    var dirIndex = 0;
    var foundDirIndex = -1;
    for (var i = 0; i < lights.length; i++) {
      final l = lights[i];
      if ((l.lightMask & context.cameraMask) == 0) {
        continue;
      }
      final source = l.source;
      if (source is DirectionalLight &&
          dirIndex < RenderContext3D.maxDirectionalLights) {
        if (dirLight == null && source.shadows != null) {
          dirLight = l;
          dirSettings = source.shadows;
          foundDirIndex = dirIndex;
        }
        dirIndex++;
      }
    }

    _spotCasterCount = 0;
    final spots = RenderContext3D._selectSpotLights(context, _selection);
    for (var k = 0; k < spots && _spotCasterCount < 2; k++) {
      final l = lights[_selection[k]];
      if ((l.source as SpotLight).shadows != null) {
        _spotCasters[_spotCasterCount] = l;
        _spotCasterIndices[_spotCasterCount++] = k;
      }
    }

    _pointCaster = null;
    final points = RenderContext3D._selectPointLights(context, _selection);
    for (var k = 0; k < points; k++) {
      final l = lights[_selection[k]];
      if ((l.source as PointLight).shadows != null) {
        _pointCaster = l;
        _pointCasterIndex = k;
        break;
      }
    }

    final pointCaster = _pointCaster;
    if (dirLight == null && _spotCasterCount == 0 && pointCaster == null) {
      return _none();
    }
    followsViews = dirSettings != null && dirSettings.fit == ShadowFit.view;
    if (!_shadersAvailable()) {
      return _none();
    }

    // The atlas holds several tiles: cascades of the directional light, the
    // two hemispheres of a point light, or the maps of several lights.
    final totalShadowLights =
        (dirLight != null ? 1 : 0) +
        _spotCasterCount +
        (pointCaster != null ? 1 : 0);
    final useUnifiedAtlas =
        (dirSettings != null && dirSettings.cascades >= 2) ||
        pointCaster != null ||
        totalShadowLights > 1;

    if (useUnifiedAtlas) {
      return _beginUnifiedAtlas(
        projection: projection,
        castersKey: castersKey,
        stillCastersKey: stillCastersKey,
        sceneBounds: sceneBounds,
        dirLight: dirLight,
        dirIndex: foundDirIndex,
        dirSettings: dirSettings,
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
      light = _spotCasters[0]!;
      settings = (light.source as SpotLight).shadows!;
      index = 100 + _spotCasterIndices[0];
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
    } else if (settings.fit == ShadowFit.fixed) {
      projection.fitBounds(
        direction: direction,
        receivers: _fixedBounds(settings),
        casters: settings.casterBounds ?? settings.bounds!,
        resolution: resolution,
      );
      _lightViewProjection.setFrom(projection.viewProjection);
      activeLightView = projection.view;
      activeLightProj = projection.projection;
      texelWorldSize = math.max(projection.texelWidth, projection.texelHeight);
    } else {
      final fitView = settings.fit == ShadowFit.view;
      final views = _fitViewProjections;
      if (!projection.update(
        direction: direction,
        casters: sceneBounds,
        receivers: settings.bounds,
        cameraViewProjection: fitView && views == null
            ? context._viewProjectionMatrix
            : null,
        cameraView: context._viewMatrix,
        cameraViewProjections: fitView ? views : null,
        cameraViews: _fitViews,
        maxDistance: settings.maxDistance,
        resolution: resolution,
        stabilize: settings.stabilize,
        holdNear: stillCastersKey != null && settings.cacheStillCasters,
        holdWindow: stillCastersKey != null && settings.cacheStillCasters,
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
    final vpStorage = _lightViewProjection.storage;

    if (stillCastersKey != null && settings.cacheStillCasters) {
      _writeSingleMap(direction, index, settings, texelWorldSize, float);
      _singleView = activeLightView;
      _singleProjection = activeLightProj;
      _singleSize = resolution;
      return _beginSplit(
        owner: projection,
        atlasPath: false,
        castersKey: castersKey,
        stillKey: stillCastersKey,
        width: resolution,
        height: resolution,
        float: float,
        format: format,
      );
    }
    _stillLayers[projection] = null;

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
        _writeSingleMap(direction, index, settings, texelWorldSize, float);
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
    _writeSingleMap(direction, index, settings, texelWorldSize, float);

    context._saveCameraSnapshot(_mainCamera);
    context.setCamera(activeLightView, activeLightProj);
    recording = true;
    _drawCallsBefore = device.stats.drawCalls;
    _trianglesBefore = device.stats.triangles;
    device.beginTexturePass(target, frontFace: context.frontFace);
    device.stats.shadowPasses++;
    RenderProfile.lap(RenderPhase.passBegin);
    return true;
  }

  /// Sets the values of the `Shadows` block that describe a single map of
  /// the light that travels along [direction], of index [index] (100 plus
  /// the index of a spot light), with [settings].
  void _writeSingleMap(
    Vector3 direction,
    int index,
    ShadowSettings settings,
    double texelWorldSize,
    bool float,
  ) {
    final size = settings.resolution.toDouble();
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
  }

  bool _beginUnifiedAtlas({
    required DirectionalShadowProjection projection,
    required Object? castersKey,
    required Object? stillCastersKey,
    required Aabb3 sceneBounds,
    required Light? dirLight,
    required int dirIndex,
    required ShadowSettings? dirSettings,
  }) {
    final spotCount = _spotCasterCount;
    final pointCaster = _pointCaster;
    final pointSettings = (pointCaster?.source as PointLight?)?.shadows;
    final firstSpotSettings = spotCount > 0
        ? (_spotCasters[0]!.source as SpotLight).shadows
        : null;
    final context = _context;
    final device = context.device;
    _csmTiles.clear();
    _spotTiles.clear();
    _pointFrontTile = null;
    _pointBackTile = null;

    final csmCount = dirSettings?.cascades ?? 0;
    final totalRequestedTiles =
        csmCount + spotCount + (pointCaster != null ? 2 : 0);
    final preferredRes =
        dirSettings?.resolution ??
        firstSpotSettings?.resolution ??
        pointSettings?.resolution ??
        512;
    final tileSize = atlas.recommendedTileSize(
      totalRequestedTiles,
      preferred: preferredRes,
    );

    _atlasDirLightIndex = -1;
    _atlasCascadeCount = 0;

    final primarySettings = dirSettings ?? firstSpotSettings ?? pointSettings!;

    // ShadowSettings.cacheStillCasters, when every light that casts shadows
    // sets it.
    final split =
        stillCastersKey != null &&
        (dirSettings?.cacheStillCasters ?? true) &&
        _spotCastersKeepStill(spotCount) &&
        (pointSettings?.cacheStillCasters ?? true);

    _cascadeMask = 0;
    final cascades = _cascadesOf(projection);
    if (dirLight != null && dirSettings != null && csmCount > 0) {
      _fitCascades(
        cascades,
        dirLight.direction(_direction),
        sceneBounds,
        dirSettings,
        csmCount,
        tileSize,
        hold: split,
      );
    }
    // The atlas holds the cascades kept and the tiles of the other lights, in
    // a grid of tiles as square as it can be.
    var tileCount = spotCount + (pointCaster != null ? 2 : 0);
    for (var c = 0; c < csmCount; c++) {
      if (_cascadeMask & (1 << c) != 0) {
        tileCount++;
      }
    }
    atlas.reset(
      width: ShadowAtlas3D.columnsFor(tileCount) * tileSize,
      height: ShadowAtlas3D.rowsFor(tileCount) * tileSize,
    );

    if (dirLight != null && dirSettings != null && csmCount > 0) {
      final dir = dirLight.direction(_direction);
      for (var c = 0; c < csmCount; c++) {
        if (_cascadeMask & (1 << c) == 0) {
          continue;
        }
        final proj = cascades[c];
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

    for (var k = 0; k < spotCount; k++) {
      final spotLight = _spotCasters[k]!;
      final spotSource = spotLight.source as SpotLight;
      final sSettings = spotSource.shadows!;
      final sIdx = _spotCasterIndices[k];
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
      final ptLight = pointCaster;
      final ptSource = pointCaster.source as PointLight;
      final ptSettings = pointSettings!;
      final ptIdx = _pointCasterIndex;
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

    final atlasWidth = atlas.width;
    final atlasHeight = atlas.height;
    _staticMaps[projection] = null;
    if (split) {
      _writeAtlasMap(atlasWidth, atlasHeight, primarySettings);
      return _beginSplit(
        owner: projection,
        atlasPath: true,
        castersKey: castersKey,
        stillKey: stillCastersKey,
        width: atlasWidth,
        height: atlasHeight,
        float: float,
        format: format,
      );
    }
    _stillLayers[projection] = null;
    final cache =
        castersKey != null &&
        (dirSettings?.cacheWhenStatic ?? true) &&
        _spotCastersCache(spotCount) &&
        (pointSettings?.cacheWhenStatic ?? true);
    final GpuTextureTarget target;
    if (cache) {
      _writeAtlasSignature(atlasWidth, atlasHeight, float);
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
          _writeAtlasMap(atlasWidth, atlasHeight, primarySettings);
          active = true;
          atlasActive = true;
          _mapIsAtlas = true;
          RenderProfile.switchPass(RenderPhase.shadowSetup, shadow: false);
          return false;
        }
      }
      if (entry == null ||
          entry.width != atlasWidth ||
          entry.height != atlasHeight ||
          entry.packDepth != !float) {
        final owned = device.backend.createTextureTarget(
          width: atlasWidth,
          height: atlasHeight,
          format: format,
          clearValue: const Color(0xFFFFFFFF),
        );
        entry = _StaticShadowAtlas(
          width: atlasWidth,
          height: atlasHeight,
          packDepth: !float,
          target: owned,
          texture: Texture(
            null,
            width: atlasWidth,
            height: atlasHeight,
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
      target = device.textureTarget(atlasWidth, atlasHeight, format);
      if (!identical(target, _target)) {
        _target = target;
        _texture = Texture(
          null,
          width: atlasWidth,
          height: atlasHeight,
          gpuTexture: target.texture,
        );
      }
    }
    _unifiedAtlasTarget = target;

    _writeAtlasMap(atlasWidth, atlasHeight, primarySettings);

    version++;
    _mapIsAtlas = true;
    context._saveCameraSnapshot(_mainCamera);
    atlasActive = true;
    recording = true;
    _currentTileIndex = 0;
    _drawCallsBefore = device.stats.drawCalls;
    _trianglesBefore = device.stats.triangles;

    device.beginTexturePass(_unifiedAtlasTarget!, frontFace: context.frontFace);
    device.stats.shadowPasses++;
    _configureAtlasTile(atlas.tiles[0]);
    RenderProfile.lap(RenderPhase.passBegin);
    return true;
  }

  /// Whether the first [count] spot lights that cast shadows all set
  /// [ShadowSettings.cacheWhenStatic].
  bool _spotCastersCache(int count) {
    for (var k = 0; k < count; k++) {
      if (!(_spotCasters[k]!.source as SpotLight).shadows!.cacheWhenStatic) {
        return false;
      }
    }
    return true;
  }

  /// Whether the first [count] spot lights that cast shadows all set
  /// [ShadowSettings.cacheStillCasters].
  bool _spotCastersKeepStill(int count) {
    for (var k = 0; k < count; k++) {
      if (!(_spotCasters[k]!.source as SpotLight).shadows!.cacheStillCasters) {
        return false;
      }
    }
    return true;
  }

  /// Starts a frame that keeps the depths of the still casters
  /// ([ShadowSettings.cacheStillCasters]) of [owner] in a layer per view:
  /// the single map of [width] by [height] texels whose view is
  /// [_singleView], or the tiles of the [atlas] of that size.
  ///
  /// The map is reused whole when it holds the casters of [castersKey] in
  /// the same views. Otherwise each view reuses its layer when it holds the
  /// still casters of [stillKey] in the same view; a view whose projection
  /// changed since the previous frame is rendered whole (its layer would not
  /// last), and the layers of the other views are rendered again first.
  bool _beginSplit({
    required DirectionalShadowProjection owner,
    required bool atlasPath,
    required Object? castersKey,
    required Object stillKey,
    required int width,
    required int height,
    required bool float,
    required GpuPixelFormat format,
  }) {
    final context = _context;
    final device = context.device;
    final stats = device.stats;
    _staticMaps[owner] = null;
    _staticAtlases[owner] = null;
    final layers = _stillLayers[owner] ??= _StillLayers();
    _splitAtlas = atlasPath;
    final viewCount = atlasPath ? atlas.tiles.length : 1;

    // The map the receivers sample, kept with the layers.
    var live = layers.live;
    if (live == null ||
        layers.liveWidth != width ||
        layers.liveHeight != height ||
        layers.livePacked != !float) {
      live = layers.live = device.backend.createTextureTarget(
        width: width,
        height: height,
        format: format,
        clearValue: const Color(0xFFFFFFFF),
      );
      layers
        ..liveTexture = Texture(
          null,
          width: width,
          height: height,
          gpuTexture: live.texture,
        )
        ..liveWidth = width
        ..liveHeight = height
        ..livePacked = !float
        ..liveKey = null;
    }
    if (atlasPath) {
      _writeAtlasSignature(width, height, float);
    } else {
      _writeSingleSignature(width, float);
    }
    final reuseWhole =
        castersKey != null &&
        layers.liveKey == castersKey &&
        layers.liveSignatureLength == _atlasSignatureLength &&
        _sameValues(
          layers.liveSignature,
          _atlasSignature,
          _atlasSignatureLength,
        );

    layers.ensureViews(viewCount);
    for (var i = 0; i < viewCount; i++) {
      final view = layers.views[i];
      _writeViewSignature(_tileSignature, i);
      if (reuseWhole) {
        view.storeLast(_tileSignature);
        continue;
      }
      final size = atlasPath ? atlas.tiles[i].width : width;
      view.ensureTarget(device, size, format: format, float: float);
      if (view.valid &&
          view.key == stillKey &&
          _sameValues(view.signature, _tileSignature, _tileSignatureLength)) {
        _viewKinds[i] = _stepOver;
      } else if (!view.hasLast ||
          !_sameValues(view.last, _tileSignature, _tileSignatureLength)) {
        _viewKinds[i] = _stepWhole;
        view.valid = false;
      } else {
        _viewKinds[i] = _stepStill;
        view
          ..key = stillKey
          ..valid = true
          ..storeSignature(_tileSignature);
      }
      view.storeLast(_tileSignature);
    }

    if (reuseWhole) {
      // The map of an earlier frame holds the same casters in the same
      // views: receive it again, without rendering.
      stats
        ..shadowLayersReused += viewCount
        ..shadowReusedDrawCalls += layers.liveDrawCalls
        ..shadowReusedTriangles += layers.liveTriangles;
      if (!identical(_texture, layers.liveTexture)) {
        version++;
        _target = live;
        _texture = layers.liveTexture;
      }
      active = true;
      atlasActive = atlasPath;
      _mapIsAtlas = atlasPath;
      RenderProfile.switchPass(RenderPhase.shadowSetup, shadow: false);
      return false;
    }

    // The layers to render again, then the map.
    _stepCount = 0;
    for (var i = 0; i < viewCount; i++) {
      if (_viewKinds[i] == _stepStill) {
        _stepTiles[_stepCount] = i;
        _stepKinds[_stepCount++] = _stepStill;
      }
    }
    for (var i = 0; i < viewCount; i++) {
      final kind = _viewKinds[i];
      if (kind == _stepOver) {
        final view = layers.views[i];
        stats
          ..shadowLayersReused += 1
          ..shadowReusedDrawCalls += view.drawCalls
          ..shadowReusedTriangles += view.triangles;
      }
      _stepTiles[_stepCount] = i;
      _stepKinds[_stepCount++] = kind == _stepWhole ? _stepWhole : _stepOver;
    }
    layers
      ..liveKey = castersKey
      ..storeLiveSignature(_atlasSignature, _atlasSignatureLength);

    version++;
    _target = live;
    _texture = layers.liveTexture;
    _mapIsAtlas = atlasPath;
    context._saveCameraSnapshot(_mainCamera);
    _split = layers;
    recording = true;
    _drawCallsBefore = stats.drawCalls;
    _trianglesBefore = stats.triangles;
    _step = 0;
    _stepsDone = false;
    _startStep(0);
    RenderProfile.lap(RenderPhase.passBegin);
    return true;
  }

  /// Starts step [step] of the frame begun by [_beginSplit].
  void _startStep(int step) {
    final context = _context;
    final device = context.device;
    final layers = _split!;
    final kind = _stepKinds[step];
    final index = _stepTiles[step];
    final view = layers.views[index];
    if (kind == _stepStill) {
      device.beginTexturePass(view.target!, frontFace: context.frontFace);
      RenderProfile.lap(RenderPhase.passBegin);
      _passOpen = true;
      final stats = device.stats;
      stats.shadowPasses++;
      stats.shadowLayersRendered++;
      _configureView(index, inMap: false);
      layer = ShadowCasterLayer.still;
      _recordingMovers = false;
      _stillTexture = null;
    } else {
      if (step == 0 || _stepKinds[step - 1] == _stepStill) {
        device.beginTexturePass(layers.live!, frontFace: context.frontFace);
        RenderProfile.lap(RenderPhase.passBegin);
        _passOpen = true;
        device.stats.shadowPasses++;
      }
      _configureView(index, inMap: true);
      if (kind == _stepOver) {
        device.drawTextureCopy(view.texture!);
        RenderProfile.lap(RenderPhase.draw);
        layer = ShadowCasterLayer.moving;
        _recordingMovers = true;
        _stillTexture = view.texture;
      } else {
        layer = ShadowCasterLayer.all;
        _recordingMovers = false;
        _stillTexture = null;
      }
    }
    _stepDrawCalls = device.stats.drawCalls;
    _stepTriangles = device.stats.triangles;
  }

  /// Draws the casters recorded for the current step of the frame begun by
  /// [_beginSplit], and ends its pass when it is that of a layer.
  void _finishStep() {
    final device = _context.device;
    flushCasters();
    final drawCalls = device.stats.drawCalls - _stepDrawCalls;
    final triangles = device.stats.triangles - _stepTriangles;
    final view = _split!.views[_stepTiles[_step]];
    switch (_stepKinds[_step]) {
      case _stepStill:
        view
          ..drawCalls = drawCalls
          ..triangles = triangles;
        device.endTexturePass();
        _passOpen = false;
      case _stepOver:
        view
          ..mapDrawCalls = view.drawCalls + drawCalls
          ..mapTriangles = view.triangles + triangles;
      default:
        view
          ..mapDrawCalls = drawCalls
          ..mapTriangles = triangles;
    }
  }

  /// Sets the camera (and the viewport of an atlas tile) of view [index] of
  /// the frame begun by [_beginSplit]: in the map when [inMap], else at the
  /// origin of the view's own layer.
  void _configureView(int index, {required bool inMap}) {
    if (_splitAtlas) {
      _configureAtlasTile(atlas.tiles[index], atOrigin: !inMap);
    } else {
      _recordingParaboloidTile = false;
      _context.setCamera(_singleView!, _singleProjection!);
    }
  }

  /// Writes what view [index] of the frame begun by [_beginSplit] renders
  /// into [out]: its kind, light and size, and its view-projection (or the
  /// position and range of a point light).
  void _writeViewSignature(Float64List out, int index) {
    if (!_splitAtlas) {
      out[0] = -1;
      out[1] = 0;
      out[2] = _singleSize.toDouble();
      final m = _lightViewProjection.storage;
      for (var k = 0; k < 16; k++) {
        out[3 + k] = m[k];
      }
      return;
    }
    final tile = atlas.tiles[index];
    out[0] = tile.kind.index.toDouble();
    out[1] = tile.lightIndex.toDouble();
    out[2] = tile.width.toDouble();
    final viewProjection = tile.viewProjection;
    if (viewProjection != null) {
      final m = viewProjection.storage;
      for (var k = 0; k < 16; k++) {
        out[3 + k] = m[k];
      }
    } else {
      final position = tile.lightPosition;
      out[3] = position?.x ?? 0;
      out[4] = position?.y ?? 0;
      out[5] = position?.z ?? 0;
      out[6] = tile.lightRange;
      for (var k = 7; k < _tileSignatureLength; k++) {
        out[k] = 0;
      }
    }
  }

  /// Writes what a single map of [size] texels renders into
  /// [_atlasSignature].
  void _writeSingleSignature(int size, bool float) {
    final out = _atlasSignature;
    out[0] = size.toDouble();
    out[1] = float ? 1 : 0;
    final m = _lightViewProjection.storage;
    for (var k = 0; k < 16; k++) {
      out[2 + k] = m[k];
    }
    _atlasSignatureLength = 18;
  }

  static bool _sameValues(Float64List a, Float64List b, int length) {
    for (var i = 0; i < length; i++) {
      if ((a[i] - b[i]).abs() > 1e-9) {
        return false;
      }
    }
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

  /// The receiving region of [settings] with [ShadowFit.fixed], which needs
  /// one.
  static Aabb3 _fixedBounds(ShadowSettings settings) {
    final bounds = settings.bounds;
    if (bounds == null) {
      throw StateError(
        'ShadowFit.fixed needs ShadowSettings.bounds: the region that '
        'receives shadows',
      );
    }
    return bounds;
  }

  /// Fits the [count] cascades of a directional light travelling along
  /// [direction] into [cascades], setting a bit of [_cascadeMask] for each
  /// cascade kept.
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
    List<DirectionalShadowProjection> cascades,
    Vector3 direction,
    Aabb3 sceneBounds,
    ShadowSettings settings,
    int count,
    int tileSize, {
    required bool hold,
  }) {
    final context = _context;
    _cascadeSplits(settings, count);
    final perspective = context._projectionMatrix.storage[15].abs() < 0.5;
    final fixed = settings.fit == ShadowFit.fixed;
    final fitView = settings.fit == ShadowFit.view;
    final views = _fitViewProjections;
    final region = fixed
        ? _fixedBounds(settings)
        : settings.bounds ?? sceneBounds;
    final fixedCasters = settings.casterBounds ?? region;
    final far = settings.maxDistance ?? _viewDepthExtent(region);
    _cascadeMask = 0;
    var outerTexel = double.infinity;
    for (var c = count - 1; c >= 0; c--) {
      final proj = cascades[c];
      final bool fitted;
      if (fixed && c == count - 1) {
        proj.fitBounds(
          direction: direction,
          receivers: region,
          casters: fixedCasters,
          resolution: tileSize,
        );
        fitted = true;
      } else if (c == count - 1) {
        fitted = proj.update(
          direction: direction,
          casters: sceneBounds,
          receivers: settings.bounds,
          cameraViewProjection: fitView && views == null
              ? context._viewProjectionMatrix
              : null,
          cameraView: context._viewMatrix,
          cameraViewProjections: fitView ? views : null,
          cameraViews: _fitViews,
          maxDistance: settings.maxDistance,
          resolution: tileSize,
          stabilize: settings.stabilize,
          holdNear: hold,
          holdWindow: hold,
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
          cameraViewProjections: views,
          cameraViews: _fitViews,
          maxDistance: far * _splits[c],
          resolution: tileSize,
          stabilize: settings.stabilize,
          holdNear: hold,
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
        if (fixed) {
          proj.fitBounds(
            direction: direction,
            receivers: _subBox,
            casters: fixedCasters,
            resolution: tileSize,
          );
          fitted = true;
        } else {
          fitted = proj.update(
            direction: direction,
            casters: sceneBounds,
            receivers: _subBox,
            resolution: tileSize,
            stabilize: settings.stabilize,
            holdNear: hold,
          );
        }
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
  /// in, of a corner of [box]: from the farthest of the cameras the map is
  /// fitted to, when it is fitted to several.
  double _viewDepthExtent(Aabb3 box) {
    final views = _fitViews;
    if (views == null) {
      return _viewDepthExtentFrom(_context._viewMatrix, box);
    }
    var far = 1e-3;
    for (var i = 0; i < views.length; i++) {
      far = math.max(far, _viewDepthExtentFrom(views[i], box));
    }
    return far;
  }

  static double _viewDepthExtentFrom(Matrix4 view, Aabb3 box) {
    final m = view.storage;
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

  /// Sets the viewport and the camera of [tile]: the viewport of its own
  /// texture, where it starts at the origin, when [atOrigin].
  void _configureAtlasTile(ShadowAtlasTile3D tile, {bool atOrigin = false}) {
    final context = _context;
    final device = context.device;
    if (!atOrigin) {
      device
        ..setViewport(tile.x, tile.y, tile.width, tile.height)
        ..setScissor(tile.x, tile.y, tile.width, tile.height);
    }

    if (tile.kind == ShadowAtlasTileKind3D.pointParaboloidFront ||
        tile.kind == ShadowAtlasTileKind3D.pointParaboloidBack) {
      _recordingParaboloidTile = true;
      _paraboloidTileEpoch++;
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
    if (recording && _split != null) {
      if (_stepsDone) {
        return false;
      }
      _finishStep();
      if (++_step >= _stepCount) {
        _stepsDone = true;
        return false;
      }
      _startStep(_step);
      return true;
    }
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

  // Whether the shaders of shadow maps load on this backend, `null` until
  // tried: the WebGPU backend has no build of them.
  bool? _shadersLoad;

  bool _shadersAvailable() {
    final known = _shadersLoad;
    if (known != null) {
      return known;
    }
    try {
      _vertexShader.resource;
      _fragmentShader.resource;
      return _shadersLoad = true;
    } on UnsupportedError catch (error) {
      return _noShaders(error);
    } on StateError catch (error) {
      return _noShaders(error);
    }
  }

  bool _noShaders(Error error) {
    debugPrint(
      'flame_3d: no shadows on this backend, the shaders of shadow maps do '
      'not load: $error',
    );
    return _shadersLoad = false;
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
    if (_split != null) {
      _endSplit();
      return;
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
      device.stats.shadowTriangles += device.stats.triangles - _trianglesBefore;
      recording = false;
      _recordingParaboloidTile = false;
      RenderProfile.switchPass(RenderPhase.passEnd, shadow: false);
      context._restoreCameraSnapshot(
        _mainCamera,
        active: true,
        atlasActive: wasAtlas,
      );
      RenderProfile.lap(RenderPhase.setup);
    }
  }

  /// Ends the frame begun by [_beginSplit]: the steps not recorded yet are
  /// rendered without casters (their layers are still copied).
  void _endSplit() {
    final context = _context;
    final device = context.device;
    final layers = _split!;
    try {
      RenderProfile.lap(RenderPhase.traversal);
      if (!_stepsDone) {
        _finishStep();
        while (++_step < _stepCount) {
          _startStep(_step);
          _finishStep();
        }
        _stepsDone = true;
      }
    } finally {
      if (_passOpen) {
        device.endTexturePass();
        _passOpen = false;
      }
      device.stats
        ..shadowDrawCalls += device.stats.drawCalls - _drawCallsBefore
        ..shadowTriangles += device.stats.triangles - _trianglesBefore;
      var drawCalls = 0;
      var triangles = 0;
      final viewCount = _splitAtlas ? atlas.tiles.length : 1;
      for (var i = 0; i < viewCount; i++) {
        drawCalls += layers.views[i].mapDrawCalls;
        triangles += layers.views[i].mapTriangles;
      }
      layers
        ..liveDrawCalls = drawCalls
        ..liveTriangles = triangles;
      recording = false;
      _split = null;
      _recordingParaboloidTile = false;
      _recordingMovers = false;
      _stillTexture = null;
      layer = ShadowCasterLayer.all;
      RenderProfile.switchPass(RenderPhase.passEnd, shadow: false);
      context._restoreCameraSnapshot(
        _mainCamera,
        active: true,
        atlasActive: _splitAtlas,
      );
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
      // The caster shaders read every instance as a model matrix: draws
      // whose instances hold something else (billboards, ribbons) cannot
      // cast where they are, so they cast nothing.
      final material = context._materials[i]!;
      if (!material.castsShadows || !material.instancesHoldModelMatrices) {
        continue;
      }
      final surface = context._surfaces[i]!;
      final layout = surface.layout;
      if (!identical(layout, lastLayout)) {
        lastLayout = layout;
        caster = _activeCasterFor(layout);
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
    final caster = _activeCasters[surface.layout]!;
    final vertexShader = caster.vertexShader!;
    final fragmentShader = caster.fragmentShader!;
    UniformBlock? paraboloidBlock;
    if (_recordingParaboloidTile) {
      final pb = paraboloidBlock = vertexShader.block('ParaboloidLight');
      final pOff =
          (pb.cachedWriterOffsets as _ParaboloidOffsets?) ??
          (pb.cachedWriterOffsets = _ParaboloidOffsets(pb));
      if (pOff.tileEpoch != _paraboloidTileEpoch) {
        pOff.tileEpoch = _paraboloidTileEpoch;
        if (pOff.posInvRange >= 0) {
          pb.writeVec4ValuesAt(
            pOff.posInvRange,
            _paraboloidPosInvRange.x,
            _paraboloidPosInvRange.y,
            _paraboloidPosInvRange.z,
            _paraboloidPosInvRange.w,
          );
        }
        if (pOff.params >= 0) {
          pb.writeVec4ValuesAt(
            pOff.params,
            _paraboloidParams.x,
            _paraboloidParams.y,
            _paraboloidParams.z,
            _paraboloidParams.w,
          );
        }
      }
    }
    RenderProfile.lap(RenderPhase.batch);

    final joints = context._joints[first];
    device.bindPipeline(context._pipelines[first]!);
    if (device.bindingEpoch != context._bindingEpoch) {
      context
        .._bindingEpoch = device.bindingEpoch
        .._bindPassPlan(
          context._planFor(vertexShader),
          skipJoints: joints != null,
        )
        .._bindPassPlan(context._planFor(fragmentShader), skipJoints: true);
    }
    if (paraboloidBlock != null) {
      device.bindUniformBlock(paraboloidBlock);
    }
    device
      ..setRenderState(_renderState)
      ..setFrontFace(WindingOrder.counterClockwise);
    RenderProfile.lap(RenderPhase.state);
    context._bindJoints(vertexShader, joints);
    device.bindSurface(surface);
    final external = context._external[first];
    if (external != null) {
      final instanceCount = context._externalCounts[first];
      device
        ..bindInstances(
          external,
          instanceCount,
          startFloat: context._externalOffsets[first],
        )
        ..drawSurface(surface, instanceCount: instanceCount);
      RenderProfile.lap(RenderPhase.draw);
      return;
    }
    device
      ..bindInstancesOf(context._instances, order, start, count)
      ..drawSurface(surface, instanceCount: count);
    RenderProfile.lap(RenderPhase.draw);
  }

  /// The pipelines of the casters being recorded: of a paraboloid tile or
  /// not, of moving casters (over the kept layer of the still ones) or not.
  Map<VertexLayout, _CasterPipeline> get _activeCasters => _recordingMovers
      ? (_recordingParaboloidTile
            ? _paraboloidMovingPipelines
            : _movingPipelines)
      : (_recordingParaboloidTile ? _paraboloidPipelines : _pipelines);

  /// The pipeline that draws the casters of [layout] being recorded, see
  /// [_activeCasters], or `null` when they cannot be drawn.
  _CasterPipeline? _activeCasterFor(VertexLayout layout) {
    if (_recordingMovers) {
      return _recordingParaboloidTile
          ? _casterIn(
              _paraboloidMovingPipelines,
              layout,
              _paraboloidMovingVertexShader,
              _paraboloidMovingSkinnedVertexShader,
              _paraboloidMovingFragmentShader,
            )
          : _casterIn(
              _movingPipelines,
              layout,
              _movingVertexShader,
              _movingSkinnedVertexShader,
              _movingFragmentShader,
            );
    }
    return _recordingParaboloidTile
        ? _casterIn(
            _paraboloidPipelines,
            layout,
            _paraboloidVertexShader,
            _paraboloidSkinnedVertexShader,
            _paraboloidFragmentShader,
          )
        : _casterIn(
            _pipelines,
            layout,
            _vertexShader,
            _skinnedVertexShader,
            _fragmentShader,
          );
  }

  /// The pipeline of [pipelines] that draws surfaces of [layout] with
  /// [vertex] (or [skinnedVertex] when its vertices have joints and joint
  /// weights) and [fragment], created on first use, or `null` when the
  /// layout has no position to draw.
  _CasterPipeline? _casterIn(
    Map<VertexLayout, _CasterPipeline> pipelines,
    VertexLayout layout,
    Shader vertex,
    Shader skinnedVertex,
    Shader fragment,
  ) {
    var caster = pipelines[layout];
    if (caster == null) {
      final position = layout.attribute(VertexLayout.positionAttribute);
      final skinned =
          layout.attribute('vertexJoints')?.components == 4 &&
          layout.attribute('vertexWeights')?.components == 4;
      caster = pipelines[layout] = _CasterPipeline(
        drawable: position != null && position.components == 3,
        skinned: skinned,
      );
    }
    if (!caster.drawable) {
      return null;
    }
    final vertexShader = caster.skinned ? skinnedVertex : vertex;
    final fragmentShader = fragment;
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
        .._fragmentGeneration = fragmentShader.generation
        ..vertexShader = vertexShader
        ..fragmentShader = fragmentShader;
    }
    return caster;
  }

  void writeShadows(UniformBlock block) {
    final off =
        (block.cachedWriterOffsets as _ShadowsOffsets?) ??
        (block.cachedWriterOffsets = _ShadowsOffsets(block));
    if (!active) {
      if (off.toLight >= 0) {
        block.writeVec4ValuesAt(off.toLight, 0, 0, 0, -1);
      }
      if (off.atlas >= 0) {
        block.writeVec4ValuesAt(off.atlas, 0, 0, 0, -1);
      }
      return;
    }
    if (off.lightViewProjection >= 0) {
      block.writeMatrix4At(off.lightViewProjection, _lightViewProjection);
    }
    if (off.cascadeViewProjection >= 0) {
      block.writeMatrix4At(off.cascadeViewProjection, _identityMat);
    }
    if (off.toLight >= 0) {
      block.writeVec4ValuesAt(
        off.toLight,
        _toLight.x,
        _toLight.y,
        _toLight.z,
        _toLight.w,
      );
    }
    if (off.color >= 0) {
      block.writeVec4ValuesAt(
        off.color,
        _color.x,
        _color.y,
        _color.z,
        _color.w,
      );
    }
    if (off.map >= 0) {
      block.writeVec4ValuesAt(off.map, _map.x, _map.y, _map.z, _map.w);
    }
    if (off.bias >= 0) {
      block.writeVec4ValuesAt(off.bias, _bias.x, _bias.y, _bias.z, _bias.w);
    }
    if (off.decode >= 0) {
      block.writeVec4ValuesAt(
        off.decode,
        _decode.x,
        _decode.y,
        _decode.z,
        _decode.w,
      );
    }
    if (off.cascadeParams >= 0) {
      block.writeVec4ValuesAt(off.cascadeParams, 1, 0, 0, 0);
    }
    if (!atlasActive) {
      if (off.atlas >= 0) {
        block.writeVec4ValuesAt(off.atlas, 0, 0, 0, -1);
      }
      return;
    }
    final dataLen = block.data.length;
    for (var c = 0; c < _csmTiles.length; c++) {
      final t = _csmTiles[c];
      if (off.atlasCascadeViewProjections >= 0 &&
          off.atlasCascadeViewProjections + c * 16 + 16 <= dataLen) {
        block.writeMatrix4At(
          off.atlasCascadeViewProjections + c * 16,
          t.viewProjection!,
        );
      }
      if (off.atlasCascadeRects >= 0 &&
          off.atlasCascadeRects + c * 4 + 4 <= dataLen) {
        final r = t.uvRect;
        block.writeVec4ValuesAt(
          off.atlasCascadeRects + c * 4,
          r.x,
          r.y,
          r.z,
          r.w,
        );
      }
      if (off.atlasCascadeParams >= 0 &&
          off.atlasCascadeParams + c * 4 + 4 <= dataLen) {
        block.writeVec4ValuesAt(
          off.atlasCascadeParams + c * 4,
          t.texelWorldSize,
          t.blendRange,
          0,
          0,
        );
      }
    }
    for (var s = 0; s < _spotTiles.length; s++) {
      final t = _spotTiles[s];
      final position = t.lightPosition!;
      final color = t.color;
      if (off.atlasSpotViewProjections >= 0 &&
          off.atlasSpotViewProjections + s * 16 + 16 <= dataLen) {
        block.writeMatrix4At(
          off.atlasSpotViewProjections + s * 16,
          t.viewProjection!,
        );
      }
      if (off.atlasSpotRects >= 0 &&
          off.atlasSpotRects + s * 4 + 4 <= dataLen) {
        final r = t.uvRect;
        block.writeVec4ValuesAt(off.atlasSpotRects + s * 4, r.x, r.y, r.z, r.w);
      }
      if (off.atlasSpotParams >= 0 &&
          off.atlasSpotParams + s * 4 + 4 <= dataLen) {
        block.writeVec4ValuesAt(
          off.atlasSpotParams + s * 4,
          t.lightIndex.toDouble(),
          t.texelWorldSize,
          t.depthBias,
          t.strength,
        );
      }
      if (off.atlasSpotPositions >= 0 &&
          off.atlasSpotPositions + s * 4 + 4 <= dataLen) {
        block.writeVec4ValuesAt(
          off.atlasSpotPositions + s * 4,
          position.x,
          position.y,
          position.z,
          t.softness,
        );
      }
      if (off.atlasSpotColors >= 0 &&
          off.atlasSpotColors + s * 4 + 4 <= dataLen) {
        block.writeVec4ValuesAt(
          off.atlasSpotColors + s * 4,
          color.r,
          color.g,
          color.b,
          1,
        );
      }
    }
    final front = _pointFrontTile;
    final back = _pointBackTile;
    var pointIndex = -1.0;
    if (front != null && back != null) {
      pointIndex = front.lightIndex.toDouble();
      final position = front.lightPosition!;
      final color = front.color;
      if (off.atlasPointPosition >= 0) {
        block.writeVec4ValuesAt(
          off.atlasPointPosition,
          position.x,
          position.y,
          position.z,
          1.0 / math.max(1e-3, front.lightRange),
        );
      }
      if (off.atlasPointRects >= 0 && off.atlasPointRects + 8 <= dataLen) {
        final fr = front.uvRect;
        final br = back.uvRect;
        block
          ..writeVec4ValuesAt(
            off.atlasPointRects,
            fr.x,
            fr.y,
            fr.z,
            fr.w,
          )
          ..writeVec4ValuesAt(
            off.atlasPointRects + 4,
            br.x,
            br.y,
            br.z,
            br.w,
          );
      }
      if (off.atlasPointParams >= 0) {
        block.writeVec4ValuesAt(
          off.atlasPointParams,
          front.depthBias,
          front.softness,
          front.strength,
          0,
        );
      }
      if (off.atlasPointColor >= 0) {
        block.writeVec4ValuesAt(
          off.atlasPointColor,
          color.r,
          color.g,
          color.b,
          1,
        );
      }
    }
    if (off.atlas >= 0) {
      block.writeVec4ValuesAt(
        off.atlas,
        1,
        _csmTiles.length.toDouble(),
        _spotTiles.length.toDouble(),
        pointIndex,
      );
    }
  }

  void writeShadowAtlas(UniformBlock block) {
    final off =
        (block.cachedWriterOffsets as _ShadowAtlasOffsets?) ??
        (block.cachedWriterOffsets = _ShadowAtlasOffsets(block));
    if (!active || !atlasActive) {
      if (off.header >= 0) {
        block.writeVec4ValuesAt(off.header, 0, 0, -1, 0);
      }
      return;
    }

    final dataLen = block.data.length;
    for (var c = 0; c < 4; c++) {
      if (c < _csmTiles.length) {
        final t = _csmTiles[c];
        if (off.csmViewProj >= 0 && off.csmViewProj + c * 16 + 16 <= dataLen) {
          block.writeMatrix4At(off.csmViewProj + c * 16, t.viewProjection!);
        }
        if (off.csmUvRect >= 0 && off.csmUvRect + c * 4 + 4 <= dataLen) {
          final r = t.uvRect;
          block.writeVec4ValuesAt(off.csmUvRect + c * 4, r.x, r.y, r.z, r.w);
        }
        if (off.csmMeta >= 0 && off.csmMeta + c * 4 + 4 <= dataLen) {
          block.writeVec4ValuesAt(
            off.csmMeta + c * 4,
            t.texelWorldSize,
            0,
            t.blendRange,
            1.0,
          );
        }
      } else {
        if (off.csmViewProj >= 0 && off.csmViewProj + c * 16 + 16 <= dataLen) {
          block.writeMatrix4At(off.csmViewProj + c * 16, _identityMat);
        }
        if (off.csmUvRect >= 0 && off.csmUvRect + c * 4 + 4 <= dataLen) {
          block.writeVec4ValuesAt(off.csmUvRect + c * 4, 0, 0, 0, 0);
        }
        if (off.csmMeta >= 0 && off.csmMeta + c * 4 + 4 <= dataLen) {
          block.writeVec4ValuesAt(off.csmMeta + c * 4, 0, 0, 0, 0);
        }
      }
    }

    for (var s = 0; s < 2; s++) {
      if (s < _spotTiles.length) {
        final t = _spotTiles[s];
        final col = t.color;
        if (off.spotViewProj >= 0 &&
            off.spotViewProj + s * 16 + 16 <= dataLen) {
          block.writeMatrix4At(off.spotViewProj + s * 16, t.viewProjection!);
        }
        if (off.spotUvRect >= 0 && off.spotUvRect + s * 4 + 4 <= dataLen) {
          final r = t.uvRect;
          block.writeVec4ValuesAt(off.spotUvRect + s * 4, r.x, r.y, r.z, r.w);
        }
        if (off.spotMeta >= 0 && off.spotMeta + s * 4 + 4 <= dataLen) {
          block.writeVec4ValuesAt(
            off.spotMeta + s * 4,
            t.lightIndex.toDouble(),
            t.texelWorldSize,
            t.depthBias,
            t.strength,
          );
        }
        if (off.spotColor >= 0 && off.spotColor + s * 4 + 4 <= dataLen) {
          block.writeVec4ValuesAt(
            off.spotColor + s * 4,
            col.r,
            col.g,
            col.b,
            1.0,
          );
        }
      } else {
        if (off.spotViewProj >= 0 &&
            off.spotViewProj + s * 16 + 16 <= dataLen) {
          block.writeMatrix4At(off.spotViewProj + s * 16, _identityMat);
        }
        if (off.spotUvRect >= 0 && off.spotUvRect + s * 4 + 4 <= dataLen) {
          block.writeVec4ValuesAt(off.spotUvRect + s * 4, 0, 0, 0, 0);
        }
        if (off.spotMeta >= 0 && off.spotMeta + s * 4 + 4 <= dataLen) {
          block.writeVec4ValuesAt(off.spotMeta + s * 4, -1, 0, 0, 0);
        }
        if (off.spotColor >= 0 && off.spotColor + s * 4 + 4 <= dataLen) {
          block.writeVec4ValuesAt(off.spotColor + s * 4, 0, 0, 0, 0);
        }
      }
    }

    final ptFront = _pointFrontTile;
    final ptBack = _pointBackTile;
    if (ptFront != null && ptBack != null) {
      final pos = ptFront.lightPosition!;
      final col = ptFront.color;
      if (off.pointPosRange >= 0) {
        block.writeVec4ValuesAt(
          off.pointPosRange,
          pos.x,
          pos.y,
          pos.z,
          1.0 / math.max(1e-3, ptFront.lightRange),
        );
      }
      if (off.pointFrontUvRect >= 0) {
        final fr = ptFront.uvRect;
        block.writeVec4ValuesAt(off.pointFrontUvRect, fr.x, fr.y, fr.z, fr.w);
      }
      if (off.pointBackUvRect >= 0) {
        final br = ptBack.uvRect;
        block.writeVec4ValuesAt(off.pointBackUvRect, br.x, br.y, br.z, br.w);
      }
      if (off.pointMeta >= 0) {
        block.writeVec4ValuesAt(
          off.pointMeta,
          ptFront.lightIndex.toDouble(),
          ptFront.depthBias,
          ptFront.softness,
          ptFront.strength,
        );
      }
      if (off.pointColor >= 0) {
        block.writeVec4ValuesAt(off.pointColor, col.r, col.g, col.b, 1.0);
      }
    } else if (off.pointMeta >= 0) {
      block.writeVec4ValuesAt(off.pointMeta, -1, 0, 0, 0);
    }

    if (off.header >= 0) {
      block.writeVec4ValuesAt(
        off.header,
        1.0,
        _atlasCascadeCount.toDouble(),
        _atlasDirLightIndex.toDouble(),
        _atlasSpotShadowCount.toDouble(),
      );
    }
  }

  static void writeCasterUniforms(
    RenderContext3D context,
    UniformBlock block,
  ) {
    final off =
        (block.cachedWriterOffsets as int?) ??
        (block.cachedWriterOffsets = block.resolveOffset('packDepth'));
    if (off >= 0) {
      block.writeFloatAt(off, context._shadows._packDepth ? 1 : 0);
    }
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

  /// The kept depths of the still casters the moving casters being recorded
  /// are drawn over, or a white texture (the farthest depth).
  static Texture stillCastersTexture(RenderContext3D context) {
    return context._shadows._stillTexture ?? Texture.standard;
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

  // The shaders of [pipeline].
  Shader? vertexShader;
  Shader? fragmentShader;

  DevicePipeline get pipeline => _pipeline!;
}

/// The kept layers of still casters of one projection
/// ([ShadowSettings.cacheStillCasters]): one per view (the single map, or
/// each tile of the atlas), and the map the receivers sample, kept to be
/// reused whole while nothing changes.
class _StillLayers() {
  final List<_StillView> views = [];

  GpuTextureTarget? live;
  Texture? liveTexture;
  int liveWidth = 0;
  int liveHeight = 0;
  bool livePacked = false;
  Object? liveKey;
  final Float64List liveSignature = Float64List(
    _StaticShadowAtlas.signatureCapacity,
  );
  int liveSignatureLength = 0;

  // What rendering the map whole would draw, for RenderStats.
  int liveDrawCalls = 0;
  int liveTriangles = 0;

  void ensureViews(int count) {
    while (views.length < count) {
      views.add(_StillView());
    }
  }

  void storeLiveSignature(Float64List signature, int length) {
    liveSignature.setRange(0, length, signature);
    liveSignatureLength = length;
  }
}

/// The kept layer of still casters of one view, see [_StillLayers].
class _StillView() {
  GpuTextureTarget? target;
  Texture? texture;
  int size = 0;
  bool packed = false;

  // The key of the still casters it holds, and the view it holds them in.
  Object? key;
  bool valid = false;
  final Float64List signature = Float64List(_ShadowPass._tileSignatureLength);

  // The view of the previous frame.
  final Float64List last = Float64List(_ShadowPass._tileSignatureLength);
  bool hasLast = false;

  // What the layer holds, and what the view of the map held in the last
  // frame that rendered it, for RenderStats.
  int drawCalls = 0;
  int triangles = 0;
  int mapDrawCalls = 0;
  int mapTriangles = 0;

  /// Makes [target] a texture of [size] texels of [format]; a new one holds
  /// nothing yet.
  void ensureTarget(
    GraphicsDevice device,
    int size, {
    required GpuPixelFormat format,
    required bool float,
  }) {
    if (target != null && this.size == size && packed == !float) {
      return;
    }
    final created = target = device.backend.createTextureTarget(
      width: size,
      height: size,
      format: format,
      clearValue: const Color(0xFFFFFFFF),
    );
    texture = Texture(
      null,
      width: size,
      height: size,
      gpuTexture: created.texture,
    );
    this.size = size;
    packed = !float;
    valid = false;
  }

  void storeSignature(Float64List values) {
    signature.setRange(0, values.length, values);
  }

  void storeLast(Float64List values) {
    last.setRange(0, values.length, values);
    hasLast = true;
  }
}

class _ShadowsOffsets(final UniformBlock _b) {
  late final int lightViewProjection = _b.resolveOffset('lightViewProjection');
  late final int cascadeViewProjection = _b.resolveOffset(
    'cascadeViewProjection',
  );
  late final int toLight = _b.resolveOffset('toLight');
  late final int color = _b.resolveOffset('color');
  late final int map = _b.resolveOffset('map');
  late final int bias = _b.resolveOffset('bias');
  late final int decode = _b.resolveOffset('decode');
  late final int cascadeParams = _b.resolveOffset('cascadeParams');
  late final int atlasCascadeViewProjections = _b.resolveOffset(
    'atlasCascadeViewProjections',
  );
  late final int atlasCascadeRects = _b.resolveOffset('atlasCascadeRects');
  late final int atlasCascadeParams = _b.resolveOffset('atlasCascadeParams');
  late final int atlasSpotViewProjections = _b.resolveOffset(
    'atlasSpotViewProjections',
  );
  late final int atlasSpotRects = _b.resolveOffset('atlasSpotRects');
  late final int atlasSpotParams = _b.resolveOffset('atlasSpotParams');
  late final int atlasSpotPositions = _b.resolveOffset('atlasSpotPositions');
  late final int atlasSpotColors = _b.resolveOffset('atlasSpotColors');
  late final int atlasPointPosition = _b.resolveOffset('atlasPointPosition');
  late final int atlasPointRects = _b.resolveOffset('atlasPointRects');
  late final int atlasPointParams = _b.resolveOffset('atlasPointParams');
  late final int atlasPointColor = _b.resolveOffset('atlasPointColor');
  late final int atlas = _b.resolveOffset('atlas');
}

class _ShadowAtlasOffsets(final UniformBlock _b) {
  late final int header = _b.resolveOffset('header');
  late final int csmViewProj = _b.resolveOffset('csmViewProj');
  late final int csmUvRect = _b.resolveOffset('csmUvRect');
  late final int csmMeta = _b.resolveOffset('csmMeta');
  late final int spotViewProj = _b.resolveOffset('spotViewProj');
  late final int spotUvRect = _b.resolveOffset('spotUvRect');
  late final int spotMeta = _b.resolveOffset('spotMeta');
  late final int spotColor = _b.resolveOffset('spotColor');
  late final int pointPosRange = _b.resolveOffset('pointPosRange');
  late final int pointFrontUvRect = _b.resolveOffset('pointFrontUvRect');
  late final int pointBackUvRect = _b.resolveOffset('pointBackUvRect');
  late final int pointMeta = _b.resolveOffset('pointMeta');
  late final int pointColor = _b.resolveOffset('pointColor');
}

class _ParaboloidOffsets(final UniformBlock _b) {
  late final int posInvRange = _b.resolveOffset('posInvRange');
  late final int params = _b.resolveOffset('params');
  int tileEpoch = -1;
}
