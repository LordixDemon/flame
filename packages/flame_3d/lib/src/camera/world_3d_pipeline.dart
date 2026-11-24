part of 'world_3d.dart';

class _WorldVisibilityCache() {
  SceneOcclusionCuller3D? _lastRasterizedCuller;
  int _occFrame = -1;
  final Float32List _occVp = Float32List(16);

  final List<Object3D> visibleObjects = [];
  bool collectingVisible = false;
  bool hasVisibleCache = false;
  RenderContext3D? _visibleCtx;
  int _visibleCameraMask = 0;
  int _visibleSceneVersion = -1;
  final Float32List _visibleVp = Float32List(16);

  List<Component3D>? rootComponents3D;
  int nonComponent3DRootCount = 0;
  bool rootHasPrioritizedChild = false;

  PictureRecorder? _fallbackRecorder;
  Canvas? _fallbackCanvas;

  void invalidateOcclusion() {
    _lastRasterizedCuller = null;
  }

  void prepareOcclusionCuller(
    SceneOcclusionCuller3D? culler,
    RenderContext3D ctx,
  ) {
    if (culler == null || ctx.isShadowPass || !culler.hasOccluders) {
      return;
    }
    final frame = ctx.device.frame;
    final vp = ctx.viewProjection.storage;
    if (identical(_lastRasterizedCuller, culler) &&
        _occFrame == frame &&
        sameMatrix16(vp, _occVp)) {
      return;
    }
    _lastRasterizedCuller = culler;
    _occFrame = frame;
    for (var i = 0; i < 16; i++) {
      _occVp[i] = vp[i];
    }
    culler.rasterizeOccluders(ctx.viewProjection);
  }

  void recordVisibleObject(Object3D object) {
    if (collectingVisible) {
      visibleObjects.add(object);
    }
  }

  void storeVisibleCache(RenderContext3D ctx, int sceneVersion) {
    hasVisibleCache = true;
    _visibleCtx = ctx;
    _visibleCameraMask = ctx.cameraMask;
    _visibleSceneVersion = sceneVersion;
    _visibleVp.setAll(0, ctx.viewProjection.storage);
  }

  bool consumeReusableVisible(RenderContext3D ctx, int sceneVersion) {
    final reuse =
        hasVisibleCache &&
        identical(ctx, _visibleCtx) &&
        ctx.cameraMask == _visibleCameraMask &&
        sceneVersion == _visibleSceneVersion &&
        sameMatrix16(ctx.viewProjection.storage, _visibleVp);
    hasVisibleCache = false;
    return reuse;
  }

  void onMount() {
    rootComponents3D?.clear();
    nonComponent3DRootCount = 0;
    rootHasPrioritizedChild = false;
  }

  void onRebalance() {
    rootHasPrioritizedChild = true;
  }

  void onChildAdded(flame.Component child) {
    if (child is Component3D) {
      (rootComponents3D ??= <Component3D>[]).add(child);
      if (child.priority != 0) {
        rootHasPrioritizedChild = true;
      }
    } else {
      nonComponent3DRootCount++;
    }
  }

  void onChildRemoved(flame.Component child) {
    if (child is Component3D) {
      rootComponents3D?.remove(child);
    } else if (nonComponent3DRootCount > 0) {
      nonComponent3DRootCount--;
    }
  }

  bool allRootChildrenComponent3D(World3D world) {
    if (world.isMounted) {
      return nonComponent3DRootCount == 0;
    }
    for (final child in world.children) {
      if (child is! Component3D) {
        return false;
      }
    }
    return true;
  }

  Canvas fallbackDummyCanvas() =>
      _fallbackCanvas ??= Canvas(_fallbackRecorder = PictureRecorder());

  void disposeFallbackDummyCanvas() {
    final recorder = _fallbackRecorder;
    if (recorder != null) {
      _fallbackRecorder = null;
      _fallbackCanvas = null;
      recorder.endRecording().dispose();
    }
  }

  void clearOnRemove() {
    visibleObjects.clear();
    hasVisibleCache = false;
    disposeFallbackDummyCanvas();
  }
}

extension _World3DPipeline on World3D {
  void _traverseWorldChildren(RenderContext3D ctx, Canvas? canvas) {
    _rendering = true;
    _traversingTree = true;
    try {
      final vis = _visibility;
      if (isMounted &&
          vis.nonComponent3DRootCount == 0 &&
          !vis.rootHasPrioritizedChild &&
          !debugMode) {
        final roots = vis.rootComponents3D;
        if (roots != null) {
          for (var i = 0; i < roots.length; i++) {
            roots[i].renderTree3D(this, ctx, canvas);
          }
        }
      } else {
        final allowFast3D = !debugMode;
        for (final child in children) {
          if (allowFast3D && child is Component3D) {
            child.renderTree3D(this, ctx, canvas);
          } else {
            child.renderTree(canvas ?? fallbackDummyCanvas());
          }
        }
      }
    } finally {
      _traversingTree = false;
      _rendering = false;
    }
  }

  bool _renderShadows(Canvas? canvas, RenderContext3D? overrideContext) {
    final lights = _passLights;
    final ctx = overrideContext ?? context;
    if (!identical(ctx.syncedOwner, this) ||
        !identical(ctx.lights, lights) ||
        ctx.worldLightsVersion != lightsVersion) {
      ctx.lights = lights;
    }
    ctx
      ..setWorldLights(lights, lightsVersion)
      ..fog = _fog;
    final group = _shadowState.group;
    if (group != null && overrideContext == null) {
      return group._renderFor(this, ctx, canvas);
    }
    if (!ctx.beginShadowPass(
      projection: _shadowState.projection,
      sceneBounds: sceneBounds,
      castersKey: World3D._shadowCasterKey(this, _shadowKeyVersion, lights),
      stillCastersKey: _prepareStillCasters(this, lights),
    )) {
      return ctx.hasActiveShadows;
    }
    try {
      _recordCasters(canvas);
      while (ctx.advanceShadowAtlasTile()) {
        _recordCasters(canvas);
      }
    } finally {
      ctx.endShadowPass();
    }
    return true;
  }

  /// Renders the half-resolution clip-depth + view-normal prepass when
  /// [depthPrepassEnabled], [PostProcessSettings.needsDepthNormal], or
  /// diagnostic `depth`/`ssao` debug mode is active.
  bool _renderDepthNormalsImpl(
    Canvas? canvas,
    int width,
    int height, {
    RenderContext3D? overrideContext,
  }) {
    final vis = _visibility..hasVisibleCache = false;
    final ctx = overrideContext ?? context;
    final debugNeedsDn =
        _renderDebugMode3D == RenderDebugMode3D.depth ||
        _renderDebugMode3D == RenderDebugMode3D.ssao;
    final needed =
        _depthPrepassEnabled ||
        debugNeedsDn ||
        (_postProcess?.needsDepthNormal ?? false);
    if (!needed) {
      ctx.clearDepthNormalPass();
      return false;
    }
    if (!ctx.beginDepthNormalPass(width, height)) {
      return false;
    }
    prepareOcclusionCuller(ctx);
    vis.visibleObjects.clear();
    vis.collectingVisible = true;
    final onlyComponent3D = _allRootChildrenComponent3D();
    try {
      _traverseWorldChildren(ctx, canvas);
    } finally {
      vis.collectingVisible = false;
      ctx.endDepthNormalPass();
    }
    if (onlyComponent3D) {
      vis.storeVisibleCache(ctx, sceneVersion);
    }
    return true;
  }

  void _recordCasters(Canvas? canvas) {
    final ctx = context;
    if (ctx.isShadowPass &&
        ctx.shadowCasterLayer == ShadowCasterLayer.moving &&
        _versions.shadowCasters.moversComplete &&
        _allRootChildrenComponent3D()) {
      _recordMovingCasters(ctx);
      return;
    }
    _traverseWorldChildren(ctx, canvas);
  }

  void _recordMovingCasters(RenderContext3D ctx) {
    final movers = _versions.shadowCasters.movers;
    if (movers.isEmpty) {
      return;
    }
    final frustum = ctx.frustum;
    final passMask = ctx.cameraMask;
    _rendering = true;
    try {
      for (var i = 0; i < movers.length; i++) {
        final obj = movers[i];
        if (!obj.castsShadows ||
            !obj.isEffectivelyVisible ||
            !World3D._passesCameraMaskHierarchy(obj, passMask)) {
          continue;
        }
        final cull = obj.aabb.frustumCullTest(frustum);
        if (cull == CullResult.outside) {
          continue;
        }
        if (cull == CullResult.inside ||
            obj.usesDefaultFrustumVisibility ||
            obj.isVisible(frustum)) {
          if (obj.shadowMotion == ShadowCasterMotion.auto) {
            _versions.shadowCasters.drawnMoving(obj);
          }
          obj.draw(ctx);
        }
      }
    } finally {
      _rendering = false;
    }
  }

  void _renderSceneImpl(Canvas? canvas, {RenderContext3D? overrideContext}) {
    final ctx = overrideContext ?? context;
    syncContextOptions(ctx);
    prepareOcclusionCuller(ctx);
    if (!ctx.trackDynamicSubtrees &&
        _visibility.consumeReusableVisible(ctx, sceneVersion)) {
      _rendering = true;
      final prevLayer = ctx.activeDepthLayer;
      try {
        final visible = _visibility.visibleObjects;
        for (var i = 0; i < visible.length; i++) {
          final obj = visible[i];
          if (ctx.skipStaticDraws && !obj.mayHaveDynamicDescendant) {
            continue;
          }
          ctx.activeDepthLayer = obj.resolvedDepthLayer;
          obj.draw(ctx);
        }
      } finally {
        ctx.activeDepthLayer = prevLayer;
        _rendering = false;
      }
    } else {
      _traverseWorldChildren(ctx, canvas);
    }
  }

  Image _executeWorldRenderPipeline({
    required GraphicsDevice device,
    required RenderContext3D renderContext,
    required int width,
    required int height,
    required int msaaSampleCount,
    required Color clearValue,
    required void Function() recordDraws,
    GpuRenderTarget? ownedOutputTarget,
    Rect? visibleFrame,
  }) {
    final usePost = needsPostCompositePass(device);
    final nextHdr = _hdrEnabled && usePost;
    syncContextOptions(renderContext, hdrEnabled: nextHdr);
    renderContext.clearActiveSceneColorTarget();

    for (final custom in customPasses) {
      if (custom.enabled &&
          custom.stage == CustomRenderPassStage3D.beforeScene) {
        custom.execute(
          CustomRenderPassContext3D(
            device: device,
            renderContext: renderContext,
            width: width,
            height: height,
            depthNormalTexture: renderContext.activeDepthNormalTexture,
          ),
        );
      }
    }

    final supportsTexTargets = device.backend.supportsTextureTargets;
    final sceneFormat =
        _hdrEnabled &&
            device.backend.supportsPixelFormat(GpuPixelFormat.rgbaFloat16)
        ? GpuPixelFormat.rgbaFloat16
        : GpuPixelFormat.rgba8888;
    final cacheSettings = _staticSceneCache;
    final hasBeforeCustom = customPasses.any(
      (c) => c.enabled && c.stage == CustomRenderPassStage3D.beforeScene,
    );
    final hasAfterCustom = customPasses.any(
      (c) => c.enabled && c.stage == CustomRenderPassStage3D.afterScene,
    );
    final staticCacheCandidate =
        cacheSettings != null &&
        cacheSettings.enabled &&
        supportsTexTargets &&
        renderContext.staticCacheShadersAvailable &&
        !_grabSceneColorEnabled &&
        !hasBeforeCustom &&
        !hasAfterCustom;

    var useStaticRestore = false;
    var projectMovingShadows = false;
    var layer0Near = 0.0;
    var layer0Far = 1.0;

    if (staticCacheCandidate) {
      final layers = _depthLayers;
      if (layers != null && layers.isNotEmpty) {
        for (var i = 0; i < layers.length; i++) {
          if (layers[i].index == 0) {
            layer0Near = layers[i].zNear;
            layer0Far = layers[i].zFar;
            break;
          }
        }
      }
      final staticKey =
          _versions.ownStaticVersion +
          _versions.staticSettingsOffset +
          _staticSettingsVersion +
          Material.castsShadowsRevision +
          Material.assignmentRevision +
          GpuBackend.renderEpoch +
          lightsVersion +
          (_lighting.lightsFrom?._lighting.lightsVersion ?? 0);
      final stillShadowVer =
          cacheSettings.projectMovingShadows &&
              renderContext.stillShadowTexture != null
          ? renderContext.stillShadowVersion
          : renderContext.shadowMapVersion;
      final vpStorage = renderContext.viewProjection.storage;
      final depthLayersSig = _depthLayersSignature(layers);

      if (_staticCache.matchesHit(
        deviceGeneration: GpuBackend.deviceGeneration,
        width: width,
        height: height,
        msaaSampleCount: msaaSampleCount,
        sceneFormat: sceneFormat,
        clearArgb: clearValue.toARGB32(),
        hdrEnabled: nextHdr,
        renderDebugMode: _renderDebugMode3D,
        cameraMask: renderContext.cameraMask,
        depthLayersSig: depthLayersSig,
        projectMovingShadows: cacheSettings.projectMovingShadows,
        staticKey: staticKey,
        stillShadowVersion: stillShadowVer,
        vp: vpStorage,
      )) {
        device.stats.staticCacheHits++;
        useStaticRestore = true;
        final prevHdr = _pipelineHdrOverride;
        _pipelineHdrOverride = nextHdr;
        renderContext.skipStaticDraws = true;
        try {
          recordDraws();
        } finally {
          renderContext.skipStaticDraws = false;
          _pipelineHdrOverride = prevHdr;
        }
      } else {
        device.stats.staticCacheMisses++;
        final unsettledShadows =
            cacheSettings.projectMovingShadows &&
            renderContext.stillShadowTexture != null &&
            _hasUnsettledStaticCasters();
        final shouldPopulate =
            _staticCache.advanceWarmup(
              deviceGeneration: GpuBackend.deviceGeneration,
              width: width,
              height: height,
              msaaSampleCount: msaaSampleCount,
              sceneFormat: sceneFormat,
              clearArgb: clearValue.toARGB32(),
              hdrEnabled: nextHdr,
              renderDebugMode: _renderDebugMode3D,
              cameraMask: renderContext.cameraMask,
              depthLayersSig: depthLayersSig,
              projectMovingShadows: cacheSettings.projectMovingShadows,
              staticKey: staticKey,
              stillShadowVersion: stillShadowVer,
              vp: vpStorage,
              stillFrames: cacheSettings.stillFrames,
            ) &&
            !unsettledShadows;
        final prevHdr = _pipelineHdrOverride;
        _pipelineHdrOverride = nextHdr;
        renderContext.trackDynamicSubtrees = shouldPopulate;
        try {
          recordDraws();
        } finally {
          renderContext.trackDynamicSubtrees = false;
          _pipelineHdrOverride = prevHdr;
        }
        final needsGrab =
            _grabSceneColorEnabled || renderContext.hasRefractiveDraws;
        final needsWboit =
            _oitMode == OitMode3D.weightedBlended &&
            device.backend.supportsPixelFormat(GpuPixelFormat.rgbaFloat16) &&
            renderContext.hasTranslucentDraws;
        if (shouldPopulate && !needsGrab && !needsWboit) {
          if (renderContext.hdrEnabled != nextHdr) {
            renderContext
              ..hdrEnabled = nextHdr
              ..bumpPassOptionsUniforms();
          }
          renderContext.collectStaticMaterials(
            _staticCache.staticMaterials,
            _staticCache.staticMaterialVersions,
          );
          final hasStatic = renderContext.hasStaticDraws;
          _staticCache.hasStaticDraws = hasStatic;
          if (hasStatic) {
            final targets = _staticCache.ensureTargets(
              device: device,
              width: width,
              height: height,
              sceneFormat: sceneFormat,
              clearValue: clearValue,
              msaaSampleCount: msaaSampleCount,
            );
            final stillTex = cacheSettings.projectMovingShadows
                ? renderContext.stillShadowTexture
                : null;
            if (stillTex != null) {
              renderContext.setStaticShadowOverride(stillTex);
            }
            try {
              device.beginTexturePass(
                targets.colorTarget,
                frontFace: renderContext.frontFace,
              );
              renderContext.flushStaticColorOnly(releaseAfter: false);
              device.endTexturePass();
            } finally {
              if (stillTex != null) {
                renderContext.setStaticShadowOverride(null);
              }
            }
            device.beginTexturePass(
              targets.depthTarget,
              frontFace: renderContext.frontFace,
            );
            renderContext.flushStaticDepthOnly();
            device.endTexturePass();
            _staticCache.populated = true;
            useStaticRestore = true;
          } else {
            _staticCache.populated = true;
          }
        }
      }
    } else {
      _staticCache.resetWarmup();
      final prevHdr = _pipelineHdrOverride;
      _pipelineHdrOverride = nextHdr;
      try {
        recordDraws();
      } finally {
        _pipelineHdrOverride = prevHdr;
      }
    }
    if (renderContext.hdrEnabled != nextHdr) {
      renderContext
        ..hdrEnabled = nextHdr
        ..bumpPassOptionsUniforms();
    }
    if (useStaticRestore) {
      projectMovingShadows =
          cacheSettings!.projectMovingShadows &&
          renderContext.isSingleDirectionalShadowActive &&
          renderContext.stillShadowTexture != null &&
          !identical(
            renderContext.stillShadowTexture,
            renderContext.activeShadowMapTexture,
          );
      if (projectMovingShadows) {
        _computeMovingShadowBounds(
          renderContext,
          _staticCache.movingBounds,
        );
      }
    }
    final runGrab =
        !useStaticRestore &&
        supportsTexTargets &&
        (_grabSceneColorEnabled || renderContext.hasRefractiveDraws);
    final runWboit =
        !useStaticRestore &&
        supportsTexTargets &&
        _oitMode == OitMode3D.weightedBlended &&
        device.backend.supportsPixelFormat(GpuPixelFormat.rgbaFloat16) &&
        renderContext.hasTranslucentDraws;

    // 1. Optional Scene Color Grab-Pass for screen-space water & IOR glass
    //    refraction.
    GpuTextureTarget? grabTarget;
    if (runGrab) {
      grabTarget = device.textureTarget(
        width,
        height,
        sceneFormat,
        clearValue: clearValue,
        role: _SceneTarget.grab,
      );
      device.beginTexturePass(grabTarget, frontFace: renderContext.frontFace);
      renderContext.flushOpaquePreview();
      device.endTexturePass();
      renderContext.setActiveSceneColorTarget(grabTarget);
    }

    // 2. Order-independent transparency (`OitMode3D.weightedBlended`).
    if (runWboit) {
      final GpuTextureTarget opaqueTarget;
      if (grabTarget != null && msaaSampleCount == 1) {
        opaqueTarget = grabTarget;
      } else {
        opaqueTarget = device.textureTarget(
          width,
          height,
          sceneFormat,
          clearValue: clearValue,
          role: _SceneTarget.oitOpaque,
          msaaSampleCount: msaaSampleCount,
        );
        device.beginTexturePass(
          opaqueTarget,
          frontFace: renderContext.frontFace,
        );
        renderContext.flushOpaquePreview();
        device.endTexturePass();
      }

      final accumTarget = device.textureTarget(
        width,
        height,
        GpuPixelFormat.rgbaFloat16,
        clearValue: const Color(0x00000000),
        role: _SceneTarget.oitAccumulation,
      );
      device.beginTexturePass(accumTarget, frontFace: renderContext.frontFace);
      renderContext.flushWboitSubpass(revealPass: false, releaseAfter: false);
      device.endTexturePass();

      final revealTarget = device.textureTarget(
        width,
        height,
        GpuPixelFormat.rgba8888,
        role: _SceneTarget.oitRevealage,
      );
      device.beginTexturePass(revealTarget, frontFace: renderContext.frontFace);
      renderContext.flushWboitSubpass(revealPass: true, releaseAfter: false);
      device.endTexturePass();

      if (usePost) {
        final wboitSceneTarget = device.textureTarget(
          width,
          height,
          sceneFormat,
          clearValue: clearValue,
          role: _SceneTarget.scene,
          msaaSampleCount: msaaSampleCount,
        );
        device.beginTexturePass(
          wboitSceneTarget,
          frontFace: renderContext.frontFace,
        );
        renderContext.drawWboitComposite(
          opaqueTarget: opaqueTarget,
          accumTarget: accumTarget,
          revealTarget: revealTarget,
        );
        device.endTexturePass();
        _runAfterSceneCustomPasses(
          device,
          renderContext,
          width,
          height,
          wboitSceneTarget,
        );
        renderContext.clearActiveSceneColorTarget();
        return device.applyBloomFromTarget(
          wboitSceneTarget,
          _bloom,
          postProcess: _postProcess,
          depthNormalTexture: renderContext.activeDepthNormalTexture,
          outputTarget: ownedOutputTarget,
          hdrEnabled: _hdrEnabled,
          renderDebugMode: _renderDebugMode3D,
          visibleFrame: visibleFrame,
        );
      }

      if (ownedOutputTarget != null) {
        device.beginOwnedPass(
          ownedOutputTarget,
          frontFace: renderContext.frontFace,
        );
      } else {
        device.beginPass(
          Size(width.toDouble(), height.toDouble()),
          frontFace: renderContext.frontFace,
        );
      }
      renderContext.drawWboitComposite(
        opaqueTarget: opaqueTarget,
        accumTarget: accumTarget,
        revealTarget: revealTarget,
      );
      renderContext.clearActiveSceneColorTarget();
      return device.endPass();
    }

    // 3. Standard opaque + sorted translucent path (with optional HDR / Bloom /
    //    PostProcess / ColorLut3D / Debug composite).
    if (usePost) {
      final texTarget = device.textureTarget(
        width,
        height,
        sceneFormat,
        clearValue: clearValue,
        role: _SceneTarget.scene,
        msaaSampleCount: msaaSampleCount,
      );
      device.beginTexturePass(texTarget, frontFace: renderContext.frontFace);
      if (useStaticRestore) {
        if (_staticCache.hasStaticDraws) {
          renderContext.drawStaticRestore(
            staticColor: _staticCache.colorTexture!,
            staticDepth: _staticCache.depthTexture!,
            zNear: layer0Near,
            zFar: layer0Far,
            projectMovingShadows: projectMovingShadows,
            movingBounds: _staticCache.movingBounds,
          );
        }
        renderContext.flushDynamicOnly(releaseAfter: true);
      } else {
        renderContext.flush();
      }
      device.endTexturePass();

      _runAfterSceneCustomPasses(
        device,
        renderContext,
        width,
        height,
        texTarget,
      );
      renderContext.clearActiveSceneColorTarget();
      return device.applyBloomFromTarget(
        texTarget,
        _bloom,
        postProcess: _postProcess,
        depthNormalTexture: renderContext.activeDepthNormalTexture,
        outputTarget: ownedOutputTarget,
        hdrEnabled: _hdrEnabled,
        renderDebugMode: _renderDebugMode3D,
        visibleFrame: visibleFrame,
      );
    }

    if (ownedOutputTarget != null) {
      device.beginOwnedPass(
        ownedOutputTarget,
        frontFace: renderContext.frontFace,
      );
    } else {
      device.beginPass(
        Size(width.toDouble(), height.toDouble()),
        msaaSampleCount: msaaSampleCount,
        frontFace: renderContext.frontFace,
      );
    }
    if (useStaticRestore) {
      if (_staticCache.hasStaticDraws) {
        renderContext.drawStaticRestore(
          staticColor: _staticCache.colorTexture!,
          staticDepth: _staticCache.depthTexture!,
          zNear: layer0Near,
          zFar: layer0Far,
          projectMovingShadows: projectMovingShadows,
          movingBounds: _staticCache.movingBounds,
        );
      }
      renderContext.flushDynamicOnly(releaseAfter: true);
    } else {
      renderContext.flush();
    }
    renderContext.clearActiveSceneColorTarget();
    return device.endPass();
  }

  void _runAfterSceneCustomPasses(
    GraphicsDevice device,
    RenderContext3D renderContext,
    int width,
    int height,
    GpuTextureTarget sceneTarget,
  ) {
    for (final custom in customPasses) {
      if (custom.enabled &&
          custom.stage == CustomRenderPassStage3D.afterScene) {
        custom.execute(
          CustomRenderPassContext3D(
            device: device,
            renderContext: renderContext,
            width: width,
            height: height,
            sceneTarget: sceneTarget,
            depthNormalTexture: renderContext.activeDepthNormalTexture,
          ),
        );
      }
    }
  }

  Image _renderToImageIntoImpl(
    Size size, {
    required Matrix4 view,
    required Matrix4 projection,
    Msaa msaa = Msaa.off,
    Color clearValue = const Color(0x00000000),
    GraphicsDevice? device,
    RenderContext3D? context,
    GpuRenderTarget? target,
  }) {
    final width = math.max(1, size.width.round());
    final height = math.max(1, size.height.round());

    final hostRef = _contextOrNull != null ? host : null;
    final game3d = hostRef is Game3D ? hostRef : null;
    final session = DeviceFrameSession.acquire(
      fallbackKey: _resolveGame() ?? this,
      device: device,
      context: context,
      hostDevice: game3d?.device,
      hostContext: game3d?.context,
      isHostRenderingFrame: game3d?.isRenderingFrame ?? false,
    );
    final resolvedDevice = session.device;
    final resolvedContext = session.context;

    try {
      return renderWithHost(resolvedDevice, resolvedContext, msaa: msaa, () {
        resolvedContext.setCamera(view, projection);
        syncContextOptions(
          resolvedContext,
          hdrEnabled: effectiveHdrEnabled(resolvedDevice),
        );
        renderShadowsNoCanvas(overrideContext: resolvedContext);
        _renderDepthNormalsImpl(
          null,
          width,
          height,
          overrideContext: resolvedContext,
        );

        final usePost = needsPostCompositePass(resolvedDevice);
        final ownedTarget =
            target ??
            resolvedDevice.backend.createRenderTarget(
              width: width,
              height: height,
              clearValue: usePost ? const Color(0x00000000) : clearValue,
              msaaSampleCount: usePost ? 1 : msaa.sampleCount,
            );

        return executeWorldRenderPipeline(
          device: resolvedDevice,
          renderContext: resolvedContext,
          width: width,
          height: height,
          msaaSampleCount: msaa.sampleCount,
          clearValue: clearValue,
          ownedOutputTarget: ownedTarget,
          recordDraws: () => _renderSceneImpl(
            null,
            overrideContext: resolvedContext,
          ),
        );
      });
    } finally {
      disposeFallbackDummyCanvas();
      session.end();
    }
  }

  void _renderChainedIntoTextureTargetImpl({
    required Size size,
    required Matrix4 view,
    required Matrix4 projection,
    required GraphicsDevice device,
    required RenderContext3D context,
    required GpuTextureTarget target,
    required bool keepContents,
    Msaa msaa = Msaa.off,
  }) {
    final width = math.max(1, size.width.round());
    final height = math.max(1, size.height.round());
    try {
      renderWithHost(device, context, msaa: msaa, () {
        context.setCamera(view, projection);
        syncContextOptions(context, hdrEnabled: false);
        renderShadowsNoCanvas(overrideContext: context);
        _renderDepthNormalsImpl(
          null,
          width,
          height,
          overrideContext: context,
        );
        _renderSceneImpl(null, overrideContext: context);
        device.beginTexturePass(
          target,
          frontFace: context.frontFace,
          keepContents: keepContents,
        );
        context.flush();
        device.endTexturePass();
        context.clearActiveSceneColorTarget();
      });
    } finally {
      disposeFallbackDummyCanvas();
    }
  }
}

class _SnapshotHost() implements Scene3DHost {
  @override
  GraphicsDevice get device => _device!;
  GraphicsDevice? _device;
  set device(GraphicsDevice? value) => _device = value;

  @override
  RenderContext3D get context => _context!;
  RenderContext3D? _context;
  set context(RenderContext3D? value) => _context = value;

  Msaa msaa = Msaa.off;

  @override
  int get msaaSampleCount => msaa.sampleCount;

  @override
  double get pixelRatio => 1.0;
}

/// The texture targets of the passes of one frame of a [World3D], so that
/// no two of them share a target (see [GraphicsDevice.textureTarget]).
enum _SceneTarget() {
  /// The scene before the post-processing composite.
  scene,

  /// The opaque scene sampled by refractive materials.
  grab,

  /// The opaque draws of order-independent transparency.
  oitOpaque,

  /// The accumulated colors of order-independent transparency.
  oitAccumulation,

  /// The revealage of order-independent transparency.
  oitRevealage,
}

int _depthLayersSignature(List<DepthLayer3D>? layers) {
  if (layers == null || layers.isEmpty) {
    return 0;
  }
  var sig = layers.length;
  for (var i = 0; i < layers.length; i++) {
    final l = layers[i];
    sig = Object.hash(sig, l.index, l.zNear, l.zFar, l.applyWaterVolume);
  }
  return sig;
}

class _StaticSceneCacheState() {
  int _deviceGeneration = -1;
  int _width = 0;
  int _height = 0;
  int _msaaSampleCount = 0;
  GpuPixelFormat _sceneFormat = GpuPixelFormat.rgba8888;
  int _clearArgb = 0;
  bool _hdrEnabled = false;
  RenderDebugMode3D _renderDebugMode = RenderDebugMode3D.none;
  int _cameraMask = 0;
  int _depthLayersSig = 0;
  bool _projectMovingShadows = true;
  int _staticKey = -1;
  int _stillShadowVersion = -1;
  final Float32List _vp = Float32List(16);

  int _candDeviceGeneration = -1;
  int _candWidth = 0;
  int _candHeight = 0;
  int _candMsaaSampleCount = 0;
  GpuPixelFormat _candSceneFormat = GpuPixelFormat.rgba8888;
  int _candClearArgb = 0;
  bool _candHdrEnabled = false;
  RenderDebugMode3D _candRenderDebugMode = RenderDebugMode3D.none;
  int _candCameraMask = 0;
  int _candDepthLayersSig = 0;
  bool _candProjectMovingShadows = true;
  int _candStaticKey = -1;
  int _candStillShadowVersion = -1;
  final Float32List _candVp = Float32List(16);
  int _stillCount = 0;

  bool populated = false;
  bool hasStaticDraws = false;

  final List<Material> staticMaterials = [];
  final List<int> staticMaterialVersions = [];
  final Vector4 movingBounds = Vector4(2, 2, -1, -1);

  GpuTextureTarget? colorTarget;
  GpuTextureTarget? depthTarget;
  Texture? colorTexture;
  Texture? depthTexture;
  int _targetGen = -1;
  int _targetW = 0;
  int _targetH = 0;
  int _targetMsaa = 0;
  GpuPixelFormat _targetFormat = GpuPixelFormat.rgba8888;
  int _targetClearArgb = 0;

  void invalidate() {
    populated = false;
    _stillCount = 0;
    staticMaterials.clear();
    staticMaterialVersions.clear();
  }

  void resetWarmup() {
    populated = false;
    _stillCount = 0;
  }

  void dispose() {
    invalidate();
    colorTarget = null;
    depthTarget = null;
    colorTexture = null;
    depthTexture = null;
    _targetW = 0;
    _targetH = 0;
  }

  bool matchesHit({
    required int deviceGeneration,
    required int width,
    required int height,
    required int msaaSampleCount,
    required GpuPixelFormat sceneFormat,
    required int clearArgb,
    required bool hdrEnabled,
    required RenderDebugMode3D renderDebugMode,
    required int cameraMask,
    required int depthLayersSig,
    required bool projectMovingShadows,
    required int staticKey,
    required int stillShadowVersion,
    required Float32List vp,
  }) {
    if (!populated) {
      return false;
    }
    if (_deviceGeneration != deviceGeneration ||
        _width != width ||
        _height != height ||
        _msaaSampleCount != msaaSampleCount ||
        _sceneFormat != sceneFormat ||
        _clearArgb != clearArgb ||
        _hdrEnabled != hdrEnabled ||
        _renderDebugMode != renderDebugMode ||
        _cameraMask != cameraMask ||
        _depthLayersSig != depthLayersSig ||
        _projectMovingShadows != projectMovingShadows ||
        _staticKey != staticKey ||
        _stillShadowVersion != stillShadowVersion ||
        !sameMatrix16(vp, _vp)) {
      return false;
    }
    for (var i = 0; i < staticMaterials.length; i++) {
      final mat = staticMaterials[i];
      if (mat.isStaticCacheDynamic ||
          (mat.version - mat.animationVersion) != staticMaterialVersions[i]) {
        return false;
      }
    }
    return true;
  }

  bool advanceWarmup({
    required int deviceGeneration,
    required int width,
    required int height,
    required int msaaSampleCount,
    required GpuPixelFormat sceneFormat,
    required int clearArgb,
    required bool hdrEnabled,
    required RenderDebugMode3D renderDebugMode,
    required int cameraMask,
    required int depthLayersSig,
    required bool projectMovingShadows,
    required int staticKey,
    required int stillShadowVersion,
    required Float32List vp,
    required int stillFrames,
  }) {
    populated = false;
    final sameCandidate =
        _stillCount > 0 &&
        _candDeviceGeneration == deviceGeneration &&
        _candWidth == width &&
        _candHeight == height &&
        _candMsaaSampleCount == msaaSampleCount &&
        _candSceneFormat == sceneFormat &&
        _candClearArgb == clearArgb &&
        _candHdrEnabled == hdrEnabled &&
        _candRenderDebugMode == renderDebugMode &&
        _candCameraMask == cameraMask &&
        _candDepthLayersSig == depthLayersSig &&
        _candProjectMovingShadows == projectMovingShadows &&
        _candStaticKey == staticKey &&
        _candStillShadowVersion == stillShadowVersion &&
        sameMatrix16(vp, _candVp);

    if (sameCandidate) {
      _stillCount++;
    } else {
      _stillCount = 1;
      _candDeviceGeneration = deviceGeneration;
      _candWidth = width;
      _candHeight = height;
      _candMsaaSampleCount = msaaSampleCount;
      _candSceneFormat = sceneFormat;
      _candClearArgb = clearArgb;
      _candHdrEnabled = hdrEnabled;
      _candRenderDebugMode = renderDebugMode;
      _candCameraMask = cameraMask;
      _candDepthLayersSig = depthLayersSig;
      _candProjectMovingShadows = projectMovingShadows;
      _candStaticKey = staticKey;
      _candStillShadowVersion = stillShadowVersion;
      _candVp.setAll(0, vp);
    }

    if (_stillCount < stillFrames) {
      return false;
    }

    _deviceGeneration = deviceGeneration;
    _width = width;
    _height = height;
    _msaaSampleCount = msaaSampleCount;
    _sceneFormat = sceneFormat;
    _clearArgb = clearArgb;
    _hdrEnabled = hdrEnabled;
    _renderDebugMode = renderDebugMode;
    _cameraMask = cameraMask;
    _depthLayersSig = depthLayersSig;
    _projectMovingShadows = projectMovingShadows;
    _staticKey = staticKey;
    _stillShadowVersion = stillShadowVersion;
    _vp.setAll(0, vp);
    return true;
  }

  ({GpuTextureTarget colorTarget, GpuTextureTarget depthTarget}) ensureTargets({
    required GraphicsDevice device,
    required int width,
    required int height,
    required GpuPixelFormat sceneFormat,
    required Color clearValue,
    required int msaaSampleCount,
  }) {
    final gen = GpuBackend.deviceGeneration;
    final clearArgb = clearValue.toARGB32();
    if (colorTarget != null &&
        depthTarget != null &&
        _targetGen == gen &&
        _targetW == width &&
        _targetH == height &&
        _targetMsaa == msaaSampleCount &&
        _targetFormat == sceneFormat &&
        _targetClearArgb == clearArgb) {
      return (colorTarget: colorTarget!, depthTarget: depthTarget!);
    }
    final ct = colorTarget = device.backend.createTextureTarget(
      width: width,
      height: height,
      format: sceneFormat,
      clearValue: clearValue,
      msaaSampleCount: msaaSampleCount,
    );
    final dt = depthTarget = device.backend.createTextureTarget(
      width: width,
      height: height,
      format: GpuPixelFormat.rgba8888,
      clearValue: const Color(0x00FFFFFF),
    );
    colorTexture = Texture(
      null,
      width: width,
      height: height,
      gpuTexture: ct.texture,
    );
    depthTexture = Texture(
      null,
      width: width,
      height: height,
      gpuTexture: dt.texture,
    );
    _targetGen = gen;
    _targetW = width;
    _targetH = height;
    _targetMsaa = msaaSampleCount;
    _targetFormat = sceneFormat;
    _targetClearArgb = clearArgb;
    return (colorTarget: ct, depthTarget: dt);
  }
}

extension _WorldStaticCacheBounds on World3D {
  bool _hasUnsettledStaticCasters() {
    if (_versions.shadowCasters.hasUnsettledStaticCasters) {
      return true;
    }
    final group = shadowGroup;
    if (group == null) {
      return false;
    }
    final worlds = group.worlds;
    for (var i = 0; i < worlds.length; i++) {
      final member = worlds[i];
      if (!identical(member, this) &&
          member._versions.shadowCasters.hasUnsettledStaticCasters) {
        return true;
      }
    }
    return false;
  }

  void _computeMovingShadowBounds(RenderContext3D ctx, Vector4 out) {
    final casters = _versions.shadowCasters;
    if (!casters.moversComplete) {
      out.setValues(0.0, 0.0, 1.0, 1.0);
      return;
    }
    final movers = casters.movers;
    if (movers.isEmpty) {
      out.setValues(2.0, 2.0, -1.0, -1.0);
      return;
    }
    final lp = ctx.shadowLightViewProjection.storage;
    final passMask = ctx.cameraMask;
    var minU = double.infinity;
    var minV = double.infinity;
    var maxU = double.negativeInfinity;
    var maxV = double.negativeInfinity;
    for (var i = 0; i < movers.length; i++) {
      final obj = movers[i];
      if (!obj.castsShadows ||
          !obj.isEffectivelyVisible ||
          !World3D._passesCameraMaskHierarchy(obj, passMask)) {
        continue;
      }
      final b = obj.aabb;
      final bMin = b.min;
      final bMax = b.max;
      for (var c = 0; c < 8; c++) {
        final x = (c & 1) == 0 ? bMin.x : bMax.x;
        final y = (c & 2) == 0 ? bMin.y : bMax.y;
        final z = (c & 4) == 0 ? bMin.z : bMax.z;
        final cx = lp[0] * x + lp[4] * y + lp[8] * z + lp[12];
        final cy = lp[1] * x + lp[5] * y + lp[9] * z + lp[13];
        final cw = lp[3] * x + lp[7] * y + lp[11] * z + lp[15];
        final invW = cw.abs() > 1e-6 ? 1.0 / cw : 1.0;
        final u = 0.5 + 0.5 * (cx * invW);
        final v = 0.5 - 0.5 * (cy * invW);
        if (u < minU) {
          minU = u;
        }
        if (v < minV) {
          minV = v;
        }
        if (u > maxU) {
          maxU = u;
        }
        if (v > maxV) {
          maxV = v;
        }
      }
    }
    if (!minU.isFinite) {
      out.setValues(2.0, 2.0, -1.0, -1.0);
      return;
    }
    final pad =
        (ctx.shadowFilterRadius.clamp(0.0, 3.0) + 1.5) * ctx.shadowMapInvSize;
    out.setValues(
      (minU - pad).clamp(0.0, 1.0),
      (minV - pad).clamp(0.0, 1.0),
      (maxU + pad).clamp(0.0, 1.0),
      (maxV + pad).clamp(0.0, 1.0),
    );
  }
}
