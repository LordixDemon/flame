part of 'world_3d.dart';

extension _World3DPipeline on World3D {
  void _traverseWorldChildren(RenderContext3D ctx, Canvas? canvas) {
    _rendering = true;
    _traversingTree = true;
    try {
      if (isMounted &&
          _nonComponent3DRootCount == 0 &&
          !_rootHasPrioritizedChild &&
          !debugMode) {
        final roots = _rootComponents3D;
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
    final group = _shadowGroup;
    if (group != null && overrideContext == null) {
      return group._renderFor(this, ctx, canvas);
    }
    if (!ctx.beginShadowPass(
      projection: _shadowProjection,
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
    _hasVisibleCache = false;
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
    _visibleObjects.clear();
    _collectingVisible = true;
    final onlyComponent3D = _allRootChildrenComponent3D();
    try {
      _traverseWorldChildren(ctx, canvas);
    } finally {
      _collectingVisible = false;
      ctx.endDepthNormalPass();
    }
    if (onlyComponent3D) {
      _hasVisibleCache = true;
      _visibleCtx = ctx;
      _visibleCameraMask = ctx.cameraMask;
      _visibleSceneVersion = sceneVersion;
      _visibleVp.setAll(0, ctx.viewProjection.storage);
    }
    return true;
  }

  void _recordCasters(Canvas? canvas) {
    final ctx = context;
    if (ctx.isShadowPass &&
        ctx.shadowCasterLayer == ShadowCasterLayer.moving &&
        _shadowCasters.moversComplete &&
        _allRootChildrenComponent3D()) {
      _recordMovingCasters(ctx);
      return;
    }
    _traverseWorldChildren(ctx, canvas);
  }

  void _recordMovingCasters(RenderContext3D ctx) {
    final movers = _shadowCasters.movers;
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
            _shadowCasters.drawnMoving(obj);
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
    final reuseVisible =
        _hasVisibleCache &&
        identical(ctx, _visibleCtx) &&
        ctx.cameraMask == _visibleCameraMask &&
        sceneVersion == _visibleSceneVersion &&
        sameMatrix16(ctx.viewProjection.storage, _visibleVp);
    _hasVisibleCache = false;
    if (reuseVisible) {
      _rendering = true;
      try {
        final visible = _visibleObjects;
        for (var i = 0; i < visible.length; i++) {
          visible[i].draw(ctx);
        }
      } finally {
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
    // The scene (and the targets composited into it) is the HDR target only
    // when the composite decodes it.
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

    // Record the 3D scene's draws ONCE up front so we know whether refractive
    // or WBOIT translucent surfaces are present without traversing components
    // twice!
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
    // The accumulation target needs floats: without them (OpenGL ES) the
    // translucent draws are sorted instead.
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

  /// [renderToImage] into [target] when given, a render target the caller
  /// keeps from frame to frame instead of a new one per call; the image is
  /// then only valid until the target renders into its color texture again
  /// (two frames later), so it must be drawn in the current frame.
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

    GraphicsDevice resolvedDevice;
    RenderContext3D resolvedContext;
    var closeFrame = false;
    EmbeddedRenderer? resolvedEmbedded;

    if (device != null && context != null) {
      resolvedDevice = device;
      resolvedContext = context;
    } else {
      final hostRef = _contextOrNull != null ? host : null;
      if (hostRef is Game3D) {
        resolvedDevice = hostRef.device;
        resolvedContext = hostRef.context;
        if (!hostRef.isRenderingFrame) {
          resolvedDevice.begin();
          closeFrame = true;
        }
      } else {
        final embedded = resolvedEmbedded = EmbeddedRenderer.of(
          _resolveGame() ?? this,
        );
        resolvedDevice = embedded.device;
        resolvedContext = embedded.context;
        closeFrame = embedded.open();
      }
    }

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
      if (closeFrame) {
        if (resolvedEmbedded != null) {
          resolvedEmbedded.close();
        } else {
          resolvedDevice.end();
        }
      }
    }
  }

  /// Renders a non-post-processed pass directly into [target], preserving prior
  /// contents when [keepContents] is `true`. Used by `CameraStack3D` to chain
  /// compatible `depthOnly` slots onto a single native-keep texture target.
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
