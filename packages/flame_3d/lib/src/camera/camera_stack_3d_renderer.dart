part of 'camera_stack_3d.dart';

extension _CameraStack3DRenderer on CameraStack3D {
  int _renderImpl(
    Canvas canvas,
    Size canvasSize, {
    required World3D? defaultWorld,
    required GraphicsDevice? device,
    required RenderContext3D? context,
    required bool manageDeviceFrame,
    required double pixelRatio,
    required Msaa msaa,
    required bool keepTargets,
  }) {
    _lastRenderedSlotCount = 0;
    if (canvasSize.width <= 0 || canvasSize.height <= 0 || _entries.isEmpty) {
      return 0;
    }

    _ensureSorted();
    final resolvedDevice = device;
    var resolvedContext = context;
    var openedDevice = false;
    EmbeddedRenderer? embedded;
    var openedEmbedded = false;
    Game3D? openedGame3D;

    if (resolvedDevice != null) {
      resolvedContext ??= RenderContext3D(resolvedDevice);
      if (manageDeviceFrame) {
        resolvedDevice.begin();
        openedDevice = true;
      }
    }

    GraphicsDevice? resolveDeviceFor(World3D w) {
      if (resolvedDevice != null && resolvedContext != null) {
        return resolvedDevice;
      }
      final sg = _gameFor(w);
      if (sg case final Game3D game3d) {
        return game3d.device;
      }
      return embedded?.device;
    }

    try {
      var rendered = 0;
      var chainAnchorIdx = -1;
      var chainAnchorClear = const Color(0x00000000);
      var chainClearMode = CameraClearMode3D.colorAndDepth;
      Color? chainClearColor;
      var chainRenderedBefore = 0;
      for (var entryIdx = 0; entryIdx < _entries.length; entryIdx++) {
        final entry = _entries[entryIdx];
        final slot = entry.slot;
        if (!slot.enabled) {
          continue;
        }
        final slotWorld = slot.world ?? slot.camera.world ?? defaultWorld;
        if (slotWorld == null) {
          continue;
        }
        final pixelRect = slot.syncCameraViewport(canvasSize);
        if (pixelRect.width <= 0 || pixelRect.height <= 0) {
          continue;
        }

        GraphicsDevice activeDevice;
        RenderContext3D activeContext;
        if (resolvedDevice != null && resolvedContext != null) {
          activeDevice = resolvedDevice;
          activeContext = resolvedContext;
        } else {
          final slotGame = _gameFor(slotWorld);
          if (slotGame case final Game3D game3d) {
            if (openedGame3D != null && !identical(openedGame3D, game3d)) {
              openedGame3D.device.end();
              openedGame3D = null;
            }
            activeDevice = game3d.device;
            activeContext = game3d.context;
            if (openedGame3D == null && !game3d.isRenderingFrame) {
              activeDevice.begin();
              openedGame3D = game3d;
            }
          } else {
            if (openedGame3D != null) {
              openedGame3D.device.end();
              openedGame3D = null;
            }
            final fallbackHost = slotGame ?? _cachedFallbackGame ?? this;
            _cachedFallbackGame = slotGame;
            embedded ??= EmbeddedRenderer.of(fallbackHost);
            if (!openedEmbedded) {
              openedEmbedded = embedded.open();
            }
            activeDevice = embedded.device;
            activeContext = embedded.context;
          }
        }

        final scale = pixelRatio * slotWorld.renderScale;
        final passSize = Size(
          math.max(1.0, pixelRect.width * scale),
          math.max(1.0, pixelRect.height * scale),
        );

        final gpuClear = switch (slot.clearMode) {
          CameraClearMode3D.colorAndDepth =>
            slot.clearColor ?? activeDevice.clearValue,
          CameraClearMode3D.depthOnly ||
          CameraClearMode3D.none => const Color(0x00000000),
        };

        final chained = chainAnchorIdx >= 0;
        final anchorIdx = chained ? chainAnchorIdx : entryIdx;
        final anchorClear = chained ? chainAnchorClear : gpuClear;
        final chainNext = _canChainNextSlot(
          entryIdx: entryIdx,
          anchorIdx: anchorIdx,
          anchorClear: anchorClear,
          slot: slot,
          slotWorld: slotWorld,
          activeDevice: activeDevice,
          pixelRect: pixelRect,
          passSize: passSize,
          canvasSize: canvasSize,
          pixelRatio: pixelRatio,
          keepTargets: keepTargets,
          defaultWorld: defaultWorld,
          resolveDeviceFor: resolveDeviceFor,
        );

        final prevMask = activeContext.cameraMask;
        activeContext.cameraMask = slot.camera.cameraMask;
        Image? image;
        var effectiveClearMode = slot.clearMode;
        var effectiveClearColor = slot.clearColor;
        var effectiveRenderedBefore = rendered;
        try {
          if (chained || chainNext) {
            final sharedTarget = _entries[anchorIdx].chainTextureTargetFor(
              activeDevice,
              passSize,
              anchorClear,
            );
            if (!chained && chainNext) {
              chainAnchorIdx = entryIdx;
              chainAnchorClear = gpuClear;
              chainClearMode = slot.clearMode;
              chainClearColor = slot.clearColor;
              chainRenderedBefore = rendered;
            }
            slotWorld.renderChainedIntoTextureTarget(
              size: passSize,
              view: slot.camera.viewMatrix,
              projection: slot.camera.projectionMatrix,
              msaa: msaa,
              device: activeDevice,
              context: activeContext,
              target: sharedTarget,
              keepContents: chained,
            );
            if (!chainNext) {
              image = sharedTarget.texture.asImage();
              effectiveClearMode = chainClearMode;
              effectiveClearColor = chainClearColor;
              effectiveRenderedBefore = chainRenderedBefore;
              chainAnchorIdx = -1;
            }
          } else {
            image = slotWorld.renderToImageInto(
              passSize,
              view: slot.camera.viewMatrix,
              projection: slot.camera.projectionMatrix,
              msaa: msaa,
              clearValue: gpuClear,
              device: activeDevice,
              context: activeContext,
              target: keepTargets
                  ? entry.targetFor(
                      activeDevice,
                      slotWorld,
                      passSize,
                      gpuClear,
                      msaa,
                    )
                  : null,
            );
          }
        } finally {
          activeContext.cameraMask = prevMask;
        }

        if (image != null) {
          _compositeSlotImage(
            canvas: canvas,
            image: image,
            pixelRect: pixelRect,
            slotWorld: slotWorld,
            clearMode: effectiveClearMode,
            clearColor: effectiveClearColor,
            renderedBefore: effectiveRenderedBefore,
          );
        }

        _drawSlotBorder(canvas, slot, pixelRect);
        rendered++;
      }
      _lastRenderedSlotCount = rendered;
      return rendered;
    } finally {
      if (openedGame3D != null) {
        openedGame3D.device.end();
      }
      if (openedEmbedded) {
        embedded?.close();
      }
      if (openedDevice) {
        resolvedDevice?.end();
      }
    }
  }

  bool _canChainNextSlot({
    required int entryIdx,
    required int anchorIdx,
    required Color anchorClear,
    required CameraViewportSlot3D slot,
    required World3D slotWorld,
    required GraphicsDevice activeDevice,
    required Rect pixelRect,
    required Size passSize,
    required Size canvasSize,
    required double pixelRatio,
    required bool keepTargets,
    required World3D? defaultWorld,
    required GraphicsDevice? Function(World3D) resolveDeviceFor,
  }) {
    final canChain =
        keepTargets &&
        activeDevice.backend.supportsTextureTargets &&
        !slotWorld.needsPostCompositePass(activeDevice) &&
        slotWorld.oitMode == OitMode3D.none &&
        !slotWorld.grabSceneColorEnabled &&
        (slot.borderColor == null || slot.borderWidth <= 0);
    if (!canChain) {
      return false;
    }
    for (var nextIdx = entryIdx + 1; nextIdx < _entries.length; nextIdx++) {
      final nextSlot = _entries[nextIdx].slot;
      if (!nextSlot.enabled) {
        continue;
      }
      final nextWorld = nextSlot.world ?? nextSlot.camera.world ?? defaultWorld;
      if (nextWorld == null) {
        continue;
      }
      final nextRect = nextSlot.syncCameraViewport(canvasSize);
      if (nextRect.width <= 0 || nextRect.height <= 0) {
        continue;
      }
      final nextScale = pixelRatio * nextWorld.renderScale;
      final nextPassSize = Size(
        math.max(1.0, nextRect.width * nextScale),
        math.max(1.0, nextRect.height * nextScale),
      );
      final nextDevice = resolveDeviceFor(nextWorld);
      if (nextSlot.clearMode == CameraClearMode3D.depthOnly &&
          identical(nextDevice, activeDevice) &&
          nextRect == pixelRect &&
          nextPassSize == passSize &&
          !nextWorld.needsPostCompositePass(activeDevice) &&
          nextWorld.oitMode == OitMode3D.none &&
          !nextWorld.grabSceneColorEnabled) {
        final sharedTarget = _entries[anchorIdx].chainTextureTargetFor(
          activeDevice,
          passSize,
          anchorClear,
        );
        return activeDevice.backend.supportsNativeKeepContents(sharedTarget);
      }
      return false;
    }
    return false;
  }

  void _compositeSlotImage({
    required Canvas canvas,
    required Image image,
    required Rect pixelRect,
    required World3D slotWorld,
    required CameraClearMode3D clearMode,
    required Color? clearColor,
    required int renderedBefore,
  }) {
    canvas
      ..save()
      ..clipRect(pixelRect);
    if (clearMode == CameraClearMode3D.colorAndDepth) {
      if (clearColor != null) {
        _clearPaint
          ..color = clearColor
          ..blendMode = BlendMode.src;
        canvas.drawRect(pixelRect, _clearPaint);
      } else if (renderedBefore > 0) {
        _clearPaint
          ..color = const Color(0x00000000)
          ..blendMode = BlendMode.clear;
        canvas.drawRect(pixelRect, _clearPaint);
      }
    }

    _compositePaint
      ..blendMode = BlendMode.srcOver
      ..filterQuality = slotWorld.renderScale == 1.0
          ? FilterQuality.none
          : slotWorld.scaledFilterQuality;
    int? imgWidth;
    int? imgHeight;
    try {
      imgWidth = image.width;
      imgHeight = image.height;
    } on Object {
      imgWidth = null;
      imgHeight = null;
    }
    if (imgWidth != null && imgHeight != null) {
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, imgWidth.toDouble(), imgHeight.toDouble()),
        pixelRect,
        _compositePaint,
      );
    }
    canvas.restore();
    image.dispose();
  }

  void _drawSlotBorder(
    Canvas canvas,
    CameraViewportSlot3D slot,
    Rect pixelRect,
  ) {
    if (slot.borderColor case final border? when slot.borderWidth > 0) {
      _borderPaint
        ..color = border
        ..strokeWidth = slot.borderWidth;
      canvas.drawRect(
        pixelRect.deflate(slot.borderWidth * 0.5),
        _borderPaint,
      );
    }
  }
}

class _IndexedSlot(this.slot, this.order) {
  final CameraViewportSlot3D slot;
  final int order;

  /// The version of the slot's camera at the last [CameraStack3D.update].
  int cameraVersion = -1;

  GpuRenderTarget? _target;
  GpuBackend? _targetBackend;
  int _targetWidth = 0;
  int _targetHeight = 0;
  int _targetSamples = 0;
  int _targetClear = 0;

  /// The render target the slot renders into, as `World3D.renderToImage`
  /// would create it for these arguments, kept while they do not change.
  GpuRenderTarget targetFor(
    GraphicsDevice device,
    World3D world,
    Size size,
    Color clearValue,
    Msaa msaa,
  ) {
    final width = math.max(1, size.width.round());
    final height = math.max(1, size.height.round());
    final usePost = world.needsPostCompositePass(device);
    final clear = usePost ? 0 : clearValue.toARGB32();
    final samples = usePost ? 1 : msaa.sampleCount;
    final backend = device.backend;
    final target = _target;
    if (target != null &&
        identical(backend, _targetBackend) &&
        width == _targetWidth &&
        height == _targetHeight &&
        samples == _targetSamples &&
        clear == _targetClear) {
      return target;
    }
    _targetBackend = backend;
    _targetWidth = width;
    _targetHeight = height;
    _targetSamples = samples;
    _targetClear = clear;
    return _target = backend.createRenderTarget(
      width: width,
      height: height,
      clearValue: Color(clear),
      msaaSampleCount: samples,
    );
  }

  GpuTextureTarget? _chainTexTarget;
  GpuBackend? _chainTexBackend;
  int _chainTexW = 0;
  int _chainTexH = 0;
  int _chainTexClear = 0;

  GpuTextureTarget chainTextureTargetFor(
    GraphicsDevice device,
    Size size,
    Color clearValue,
  ) {
    final width = math.max(1, size.width.round());
    final height = math.max(1, size.height.round());
    final clear = clearValue.toARGB32();
    final backend = device.backend;
    final target = _chainTexTarget;
    if (target != null &&
        identical(backend, _chainTexBackend) &&
        width == _chainTexW &&
        height == _chainTexH &&
        clear == _chainTexClear) {
      return target;
    }
    _chainTexBackend = backend;
    _chainTexW = width;
    _chainTexH = height;
    _chainTexClear = clear;
    return _chainTexTarget = backend.createTextureTarget(
      width: width,
      height: height,
      format: GpuPixelFormat.rgba8888,
      clearValue: clearValue,
    );
  }
}
