part of 'scene_3d_component.dart';

/// Retained GPU target and key-comparison state owned by [Scene3DComponent].
class _Scene3DRetainedCacheState() {
  int cacheHitCount = 0;
  int manualVersion = 0;

  GpuRenderTarget? sceneTarget;
  int sceneTargetWidth = 0;
  int sceneTargetHeight = 0;
  int sceneTargetMsaa = 0;

  GpuRenderTarget? bloomTarget;
  int bloomTargetWidth = 0;
  int bloomTargetHeight = 0;

  GpuRenderTarget? imageTarget;
  Image? image;

  Float64List _retainedNumbers = Float64List(Scene3DComponent._keyNumberCount);
  Float64List _nextNumbers = Float64List(Scene3DComponent._keyNumberCount);
  List<Object?> _retainedObjects = List.filled(
    Scene3DComponent._keyObjectCount,
    null,
  );
  List<Object?> _nextObjects = List.filled(
    Scene3DComponent._keyObjectCount,
    null,
  );
  final Float32List retainedView = Float32List(16);
  final Float32List retainedProj = Float32List(16);

  void dispose() {
    image?.dispose();
    image = null;
    imageTarget = null;
    sceneTarget = null;
    bloomTarget = null;
    sceneTargetWidth = 0;
    sceneTargetHeight = 0;
    sceneTargetMsaa = 0;
    bloomTargetWidth = 0;
    bloomTargetHeight = 0;
  }

  /// Checks if the cached image still matches the current frame, and always
  /// populates [_nextNumbers] / [_nextObjects] on miss so [storeRendered] can
  /// swap them into the kept key.
  bool checkHit({
    required Scene3DComponent owner,
    required ShadowGroup? group,
    required int left,
    required int top,
    required int pixelWidth,
    required int pixelHeight,
    required int targetWidth,
    required int targetHeight,
    required double pixelScale,
    required Rect visibleFrame,
    required Matrix4 viewMatrix,
    required Matrix4 projectionMatrix,
  }) {
    final retainedImage = image;
    final retainedTarget = imageTarget;
    final world = owner.world;
    if (retainedImage != null && retainedTarget != null) {
      final kept = _retainedNumbers;
      final sceneMatch =
          world.sceneVersion.toDouble() == kept[0] &&
          manualVersion.toDouble() == kept[1] &&
          (group?.castersVersion ?? world.castersVersion).toDouble() ==
              kept[2] &&
          (group?.viewsVersion ?? 0).toDouble() == kept[38] &&
          left.toDouble() == kept[3] &&
          top.toDouble() == kept[4] &&
          pixelWidth.toDouble() == kept[5] &&
          pixelHeight.toDouble() == kept[6] &&
          targetWidth.toDouble() == kept[7] &&
          targetHeight.toDouble() == kept[8] &&
          pixelScale == kept[9] &&
          owner.msaa.sampleCount.toDouble() == kept[10] &&
          owner.cameraMask.toDouble() == kept[11];
      if (sceneMatch &&
          sameMatrix16Approx(viewMatrix.storage, retainedView, 1e-9) &&
          sameMatrix16Approx(projectionMatrix.storage, retainedProj, 1e-9)) {
        final vignette = (world.postProcess?.vignetteIntensity ?? 0) > 0;
        if (!vignette ||
            (visibleFrame.left == kept[34] &&
                visibleFrame.top == kept[35] &&
                visibleFrame.right == kept[36] &&
                visibleFrame.bottom == kept[37])) {
          return true;
        }
      }
    }
    _writeKey(
      owner,
      left,
      top,
      pixelWidth,
      pixelHeight,
      targetWidth,
      targetHeight,
      pixelScale,
      visibleFrame,
    );
    return retainedImage != null &&
        retainedTarget != null &&
        _keyMatches() &&
        sameMatrix16Approx(viewMatrix.storage, retainedView, 1e-9) &&
        sameMatrix16Approx(projectionMatrix.storage, retainedProj, 1e-9);
  }

  GpuRenderTarget acquireTarget({
    required GraphicsDevice device,
    required bool usePost,
    required int targetWidth,
    required int targetHeight,
    required int msaaSampleCount,
  }) {
    if (usePost) {
      if (bloomTarget == null ||
          bloomTargetWidth != targetWidth ||
          bloomTargetHeight != targetHeight) {
        bloomTargetWidth = targetWidth;
        bloomTargetHeight = targetHeight;
        bloomTarget = device.backend.createRenderTarget(
          width: targetWidth,
          height: targetHeight,
          clearValue: device.clearValue,
        );
      }
      return bloomTarget!;
    }
    if (sceneTarget == null ||
        sceneTargetWidth != targetWidth ||
        sceneTargetHeight != targetHeight ||
        sceneTargetMsaa != msaaSampleCount) {
      sceneTargetWidth = targetWidth;
      sceneTargetHeight = targetHeight;
      sceneTargetMsaa = msaaSampleCount;
      sceneTarget = device.backend.createRenderTarget(
        width: targetWidth,
        height: targetHeight,
        clearValue: device.clearValue,
        msaaSampleCount: msaaSampleCount,
      );
    }
    return sceneTarget!;
  }

  void storeRendered({
    required Image renderedImage,
    required GpuRenderTarget? ownedTarget,
    required Matrix4 viewMatrix,
    required Matrix4 projectionMatrix,
  }) {
    image?.dispose();
    image = renderedImage;
    imageTarget = ownedTarget;
    _keepKey();
    retainedView.setAll(0, viewMatrix.storage);
    retainedProj.setAll(0, projectionMatrix.storage);
  }

  void _writeKey(
    Scene3DComponent owner,
    int left,
    int top,
    int pixelWidth,
    int pixelHeight,
    int targetWidth,
    int targetHeight,
    double pixelScale,
    Rect visibleFrame,
  ) {
    final world = owner.world;
    final bloom = world.bloom;
    final post = world.postProcess;
    final group = world.shadowGroup;
    // The frame only changes the image through the vignette.
    final vignette = (post?.vignetteIntensity ?? 0) > 0;
    _nextNumbers
      ..[0] = world.sceneVersion.toDouble()
      ..[1] = manualVersion.toDouble()
      ..[2] = (group?.castersVersion ?? world.castersVersion).toDouble()
      ..[3] = left.toDouble()
      ..[4] = top.toDouble()
      ..[5] = pixelWidth.toDouble()
      ..[6] = pixelHeight.toDouble()
      ..[7] = targetWidth.toDouble()
      ..[8] = targetHeight.toDouble()
      ..[9] = pixelScale
      ..[10] = owner.msaa.sampleCount.toDouble()
      ..[11] = owner.cameraMask.toDouble()
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

  void _keepKey() {
    final numbers = _retainedNumbers;
    _retainedNumbers = _nextNumbers;
    _nextNumbers = numbers;
    final objects = _retainedObjects;
    _retainedObjects = _nextObjects;
    _nextObjects = objects;
  }
}
