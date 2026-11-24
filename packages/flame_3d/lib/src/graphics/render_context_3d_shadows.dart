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
  static const _batchedBundle =
      'packages/flame_3d/assets/shaders/shadow_caster_batched.shaderbundle';
  static const _skinnedBatchedBundle =
      'packages/flame_3d/assets/shaders/'
      'shadow_caster_skinned_batched.shaderbundle';
  static const _paraboloidBundle =
      'packages/flame_3d/assets/shaders/shadow_caster_paraboloid.shaderbundle';
  static const _paraboloidSkinnedBundle =
      'packages/flame_3d/assets/shaders/'
      'shadow_caster_paraboloid_skinned.shaderbundle';
  static const _paraboloidBatchedBundle =
      'packages/flame_3d/assets/shaders/'
      'shadow_caster_paraboloid_batched.shaderbundle';
  static const _paraboloidSkinnedBatchedBundle =
      'packages/flame_3d/assets/shaders/'
      'shadow_caster_paraboloid_skinned_batched.shaderbundle';
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
  late final Shader _batchedVertexShader = VertexShader.fromAsset(
    _batchedBundle,
    slots: [
      RenderContext3D.cameraMatricesBlock,
      RenderContext3D.batchObjectsBlock,
    ],
  );
  late final Shader _skinnedBatchedVertexShader = VertexShader.fromAsset(
    _skinnedBatchedBundle,
    slots: [
      RenderContext3D.cameraMatricesBlock,
      RenderContext3D.batchObjectsBlock,
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
  late final Shader _paraboloidBatchedVertexShader = VertexShader.fromAsset(
    _paraboloidBatchedBundle,
    slots: [
      'ParaboloidLight',
      RenderContext3D.batchObjectsBlock,
    ],
  );
  late final Shader _paraboloidSkinnedBatchedVertexShader =
      VertexShader.fromAsset(
        _paraboloidSkinnedBatchedBundle,
        slots: [
          'ParaboloidLight',
          RenderContext3D.batchObjectsBlock,
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
  static const _movingBatchedBundle =
      'packages/flame_3d/assets/shaders/'
      'shadow_caster_moving_batched.shaderbundle';
  static const _movingSkinnedBatchedBundle =
      'packages/flame_3d/assets/shaders/'
      'shadow_caster_moving_skinned_batched.shaderbundle';
  static const _paraboloidMovingBundle =
      'packages/flame_3d/assets/shaders/'
      'shadow_caster_paraboloid_moving.shaderbundle';
  static const _paraboloidMovingSkinnedBundle =
      'packages/flame_3d/assets/shaders/'
      'shadow_caster_paraboloid_moving_skinned.shaderbundle';
  static const _paraboloidMovingBatchedBundle =
      'packages/flame_3d/assets/shaders/'
      'shadow_caster_paraboloid_moving_batched.shaderbundle';
  static const _paraboloidMovingSkinnedBatchedBundle =
      'packages/flame_3d/assets/shaders/'
      'shadow_caster_paraboloid_moving_skinned_batched.shaderbundle';
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
  late final Shader _movingBatchedVertexShader = VertexShader.fromAsset(
    _movingBatchedBundle,
    slots: [
      RenderContext3D.cameraMatricesBlock,
      RenderContext3D.batchObjectsBlock,
    ],
  );
  late final Shader _movingSkinnedBatchedVertexShader = VertexShader.fromAsset(
    _movingSkinnedBatchedBundle,
    slots: [
      RenderContext3D.cameraMatricesBlock,
      RenderContext3D.batchObjectsBlock,
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
  late final Shader _paraboloidMovingBatchedVertexShader =
      VertexShader.fromAsset(
        _paraboloidMovingBatchedBundle,
        slots: [
          'ParaboloidLight',
          RenderContext3D.batchObjectsBlock,
        ],
      );
  late final Shader _paraboloidMovingSkinnedBatchedVertexShader =
      VertexShader.fromAsset(
        _paraboloidMovingSkinnedBatchedBundle,
        slots: [
          'ParaboloidLight',
          RenderContext3D.batchObjectsBlock,
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
    final spots = _selectSpotLights(context, _selection);
    for (var k = 0; k < spots && _spotCasterCount < 2; k++) {
      final l = lights[_selection[k]];
      if ((l.source as SpotLight).shadows != null) {
        _spotCasters[_spotCasterCount] = l;
        _spotCasterIndices[_spotCasterCount++] = k;
      }
    }

    _pointCaster = null;
    final points = _selectPointLights(context, _selection);
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
            ? context.viewProjection
            : null,
        cameraView: context.view,
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
          cached.deviceGeneration == GpuBackend.deviceGeneration &&
          cached.resolution == resolution &&
          cached.packDepth == !float &&
          cached.castersKey == castersKey &&
          sameMatrix16Approx(vpStorage, cached.lightVp, 1e-9)) {
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
      entry
        ..castersKey = castersKey
        ..deviceGeneration = GpuBackend.deviceGeneration;
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

  static bool _sameValues(Float64List a, Float64List b, int length) {
    for (var i = 0; i < length; i++) {
      if ((a[i] - b[i]).abs() > 1e-9) {
        return false;
      }
    }
    return true;
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
}
