part of 'scene_3d_component.dart';

extension _Scene3DRetainedCache on Scene3DComponent {
  Game? _resolveGame() {
    if (!isMounted) {
      return findGame();
    }
    return _cachedGame ??= findGame();
  }

  double _pixelRatioOfGame(Game? game) {
    final buildContext = game?.buildContext;
    if (buildContext == null) {
      return 1.0;
    }
    if (!isMounted) {
      return MediaQuery.devicePixelRatioOf(buildContext);
    }
    if (!_pixelRatioDirty && identical(buildContext, _cachedDprContext)) {
      return _cachedPixelRatio;
    }
    _cachedDprContext = buildContext;
    _pixelRatioDirty = false;
    return _cachedPixelRatio = MediaQuery.devicePixelRatioOf(buildContext);
  }

  void _disposeRetained() {
    _retainedImage?.dispose();
    _retainedImage = null;
    _retainedImageTarget = null;
    _retainedSceneTarget = null;
    _retainedBloomTarget = null;
    _sceneTargetWidth = 0;
    _sceneTargetHeight = 0;
    _sceneTargetMsaa = 0;
    _bloomTargetWidth = 0;
    _bloomTargetHeight = 0;
  }

  /// Writes the values a retained image depends on, besides the camera
  /// matrices, into [_nextNumbers] and [_nextObjects], without allocating.
  void _writeKey(
    int left,
    int top,
    int pixelWidth,
    int pixelHeight,
    int targetWidth,
    int targetHeight,
    double pixelScale,
    Rect visibleFrame,
  ) {
    final world = this.world;
    final bloom = world.bloom;
    final post = world.postProcess;
    final group = world.shadowGroup;
    // The frame only changes the image through the vignette.
    final vignette = (post?.vignetteIntensity ?? 0) > 0;
    _nextNumbers
      ..[0] = world.sceneVersion.toDouble()
      ..[1] = _manualVersion.toDouble()
      ..[2] = (group?.castersVersion ?? world.castersVersion).toDouble()
      ..[3] = left.toDouble()
      ..[4] = top.toDouble()
      ..[5] = pixelWidth.toDouble()
      ..[6] = pixelHeight.toDouble()
      ..[7] = targetWidth.toDouble()
      ..[8] = targetHeight.toDouble()
      ..[9] = pixelScale
      ..[10] = msaa.sampleCount.toDouble()
      ..[11] = cameraMask.toDouble()
      ..[12] = world.hdrEnabled ? 1 : 0
      ..[13] = world.grabSceneColorEnabled ? 1 : 0
      ..[14] = bloom == null ? 0 : 1
      ..[15] = bloom?.threshold ?? 0
      ..[16] = bloom?.softKnee ?? 0
      ..[17] = bloom?.intensity ?? 0
      ..[18] = bloom?.radius ?? 0
      ..[19] = (bloom?.passes ?? 0).toDouble()
      ..[20] = post == null ? 0 : 1
      ..[21] = post?.exposure ?? 0
      ..[22] = post?.contrast ?? 0
      ..[23] = post?.saturation ?? 0
      ..[24] = post?.vignetteIntensity ?? 0
      ..[25] = post?.vignetteSmoothness ?? 0
      ..[26] = (post?.tint.toARGB32() ?? 0).toDouble()
      ..[27] = (post?.fxaa ?? false) ? 1 : 0
      ..[28] = post?.colorLutIntensity ?? 0
      ..[29] = post?.ssaoIntensity ?? 0
      ..[30] = post?.ssaoRadius ?? 0
      ..[31] = post?.dofFocusDepth ?? 0
      ..[32] = post?.dofFocusRange ?? 0
      ..[33] = post?.dofBlurStrength ?? 0
      ..[34] = vignette ? visibleFrame.left : 0
      ..[35] = vignette ? visibleFrame.top : 0
      ..[36] = vignette ? visibleFrame.right : 0
      ..[37] = vignette ? visibleFrame.bottom : 0
      ..[38] = (group?.viewsVersion ?? 0).toDouble();
    _nextObjects
      ..[0] = world.oitMode
      ..[1] = world.renderDebugMode3D
      ..[2] = post?.toneMap
      ..[3] = post?.colorLut;
  }

  /// Whether the values written by [_writeKey] equal those of the retained
  /// image.
  bool _keyMatches() {
    final next = _nextNumbers;
    final kept = _retainedNumbers;
    for (var i = 0; i < Scene3DComponent._keyNumberCount; i++) {
      if (next[i] != kept[i]) {
        return false;
      }
    }
    for (var i = 0; i < Scene3DComponent._keyObjectCount; i++) {
      if (!identical(_nextObjects[i], _retainedObjects[i])) {
        return false;
      }
    }
    return true;
  }

  /// Keeps the values written by [_writeKey] as those of the retained image.
  void _keepKey() {
    final numbers = _retainedNumbers;
    _retainedNumbers = _nextNumbers;
    _nextNumbers = numbers;
    final objects = _retainedObjects;
    _retainedObjects = _nextObjects;
    _nextObjects = objects;
  }
}
