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
    if (_visibility.consumeReusableVisible(ctx, sceneVersion)) {
      _rendering = true;
      final prevLayer = ctx.activeDepthLayer;
      try {
        final visible = _visibility.visibleObjects;
        for (var i = 0; i < visible.length; i++) {
          final obj = visible[i];
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

    final prevHdr = _pipelineHdrOverride;
    _pipelineHdrOverride = nextHdr;
    try {
      recordDraws();
    } finally {
      _pipelineHdrOverride = prevHdr;
    }

    final supportsTexTargets = device.backend.supportsTextureTargets;
    final sceneFormat =
        _hdrEnabled &&
            device.backend.supportsPixelFormat(GpuPixelFormat.rgbaFloat16)
        ? GpuPixelFormat.rgbaFloat16
        : GpuPixelFormat.rgba8888;
    if (renderContext.hdrEnabled != nextHdr) {
      renderContext
        ..hdrEnabled = nextHdr
        ..bumpPassOptionsUniforms();
    }
    final runGrab =
        supportsTexTargets &&
        (_grabSceneColorEnabled || renderContext.hasRefractiveDraws);
    final runWboit =
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
      renderContext.flush();
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
    renderContext.flush();
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
