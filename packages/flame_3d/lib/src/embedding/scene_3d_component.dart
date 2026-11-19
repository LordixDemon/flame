import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flame/components.dart';
import 'package:flame/game.dart' show Game;
import 'package:flame/rendering.dart' show RasterScale;
import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/game.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/src/embedding/embedded_renderer.dart';
import 'package:flutter/widgets.dart' show MediaQuery;
import 'package:meta/meta.dart' show visibleForTesting;

/// Caching strategy for a [Scene3DComponent]'s GPU render pass.
enum Scene3DCacheMode() {
  /// Renders the 3D scene pass every frame.
  none,

  /// Retains the rendered GPU [Image] in a dedicated target and reuses it with
  /// `0` GPU passes on subsequent frames whenever the scene, shadow casters,
  /// camera projection, canvas transform, and visible clip have not changed.
  retained,
}

/// {@template scene_3d_component}
/// A 2D component that shows a 3D scene as one layer of a 2D game.
/// {@endtemplate}
class Scene3DComponent({
  required Scene3DProjection projection,
  World3D? world,
  Msaa msaa = Msaa.off,
  double? renderScale,
  int maxTextureSize = 4096,
  Scene3DCacheMode cacheMode = Scene3DCacheMode.none,
  BloomSettings? bloom,
  PostProcessSettings? postProcess,
  bool? hdrEnabled,
  RenderDebugMode3D? renderDebugMode3D,
  super.cameraMask,
  super.position,
  super.size,
  super.scale,
  super.angle,
  super.anchor,
  super.children,
  super.priority,
  super.key,
}) extends PositionComponent implements Scene3DHost {
  /// {@macro scene_3d_component}
  this {
    if (renderScale != null) {
      this.world.renderScale = renderScale;
    }
    if (bloom != null) {
      this.world.bloom = bloom;
    }
    if (postProcess != null) {
      this.world.postProcess = postProcess;
    }
    if (hdrEnabled != null) {
      this.world.hdrEnabled = hdrEnabled;
    }
    if (renderDebugMode3D != null) {
      this.world.renderDebugMode3D = renderDebugMode3D;
    }
    this.maxTextureSize = maxTextureSize;
    add(this.world);
  }

  /// The 3D scene shown by this component, one of its children.
  final World3D world = world ?? World3D();

  /// How the scene maps to the local coordinates of this component.
  Scene3DProjection projection = projection;

  /// The multisample anti-aliasing of the render pass.
  Msaa msaa = msaa;

  /// Caching policy for this layer's GPU output.
  Scene3DCacheMode get cacheMode => _cacheMode;
  Scene3DCacheMode _cacheMode = cacheMode;
  set cacheMode(Scene3DCacheMode value) {
    if (value == _cacheMode) {
      return;
    }
    _cacheMode = value;
    if (value == Scene3DCacheMode.none) {
      _disposeRetained();
    }
  }

  /// Optional GPU bloom post-processing applied to this layer (forwards to
  /// `world.bloom`).
  BloomSettings? get bloom => world.bloom;
  set bloom(BloomSettings? value) => world.bloom = value;

  /// Optional GPU tone-mapping, color-grading, 3D LUT, vignette, and FXAA
  /// applied to this layer (forwards to `world.postProcess`).
  PostProcessSettings? get postProcess => world.postProcess;
  set postProcess(PostProcessSettings? value) => world.postProcess = value;

  /// Whether this layer renders HDR (extended-range sRGB in `rgbaFloat16`
  /// where the backend renders into float textures) before post-processing
  /// (forwards to `world.hdrEnabled`).
  bool get hdrEnabled => world.hdrEnabled;
  set hdrEnabled(bool value) => world.hdrEnabled = value;

  /// Diagnostic buffer visualization mode (forwards to
  /// `world.renderDebugMode3D`).
  RenderDebugMode3D get renderDebugMode3D => world.renderDebugMode3D;
  set renderDebugMode3D(RenderDebugMode3D value) =>
      world.renderDebugMode3D = value;

  /// Number of frames satisfied directly from the [Scene3DCacheMode.retained]
  /// image cache without opening a GPU pass.
  int get cacheHitCount => _cacheHitCount;
  int _cacheHitCount = 0;

  int _manualVersion = 0;

  /// Marks this layer's retained image cache (if any) as out of date, forcing a
  /// fresh GPU pass on the next frame.
  void markDirty() {
    _manualVersion++;
    Game.notifyVisualMutation();
  }

  /// A rectangle in this component's local coordinates outside which the
  /// layer renders nothing, or `null` (the default) for no such bound.
  ///
  /// It bounds the render pass the way clipping the canvas to it would: the
  /// pass covers only the part of the screen inside it (and inside the
  /// canvas clip, the component's [size] when it has one, and the picture of
  /// the scene's bounds), and nothing is drawn outside it.
  Rect? visibleRect;

  /// A box in scene coordinates that bounds the render pass, or `null` (the
  /// default) for no such bound.
  ///
  /// The pass covers at most the part of the screen that the box's picture
  /// covers, as it covers at most the picture of `world.sceneBounds`: what the
  /// scene draws outside that rectangle is cut off, what it draws inside it
  /// is kept, also where it lies outside the box itself.
  Aabb3? visibleSceneBounds;

  /// The largest width and height in pixels of the render target, at least 64.
  int get maxTextureSize => _maxTextureSize;
  set maxTextureSize(int value) {
    if (value < _bucket) {
      throw ArgumentError.value(value, 'maxTextureSize', 'Must be at least 64');
    }
    _maxTextureSize = value;
  }

  int _maxTextureSize = 4096;

  /// The fraction of the device pixels the scene is rendered at.
  ///
  /// The pass renders `devicePixelRatio * renderScale` pixels per unit of
  /// the canvas, or `renderScale` pixels per unit while the layer draws into
  /// an offscreen picture that rasterizes at a scale of its own
  /// (`RasterScale.isActive`: under a post process that rasterizes its
  /// subtree, or a camera whose `worldRenderScale` is not `1`), whose canvas
  /// units are already pixels.
  double get renderScale => world.renderScale;
  set renderScale(double value) => world.renderScale = value;

  /// The filter used to draw the image when it is not rendered at the
  /// device's resolution.
  FilterQuality get scaledFilterQuality => world.scaledFilterQuality;
  set scaledFilterQuality(FilterQuality value) {
    world.scaledFilterQuality = value;
  }

  /// The statistics of the last render pass of this component.
  RenderStats get renderStats => _stats;
  final RenderStats _stats = RenderStats();

  /// The part of the canvas, in the canvas's device coordinates (logical
  /// pixels, without the canvas transform), that the last render covered.
  Rect get renderedRect => _renderedRect;
  Rect _renderedRect = Rect.zero;

  /// The time the last render took on the CPU.
  Duration get lastRenderTime => Duration(microseconds: _renderMicroseconds);
  int _renderMicroseconds = 0;

  /// The local 2D point that [scenePoint] lands on.
  Vector2 scenePointToLocal(Vector3 scenePoint, {Vector2? output}) {
    return projection.scenePointToLocal(scenePoint, output: output);
  }

  /// The ray of the scene points that land on the local 2D point [localPoint].
  Ray localPointToRay(Vector2 localPoint, {Ray? output}) {
    return projection.localPointToRay(localPoint, output: output);
  }

  /// Casts a ray from [localPoint] against the [Object3D]s of [world], see
  /// [World3D.raycast].
  ///
  /// Only what this layer draws is hit: [cameraMask] defaults to the layer's
  /// own [cameraMask], and hidden objects are skipped unless [includeHidden].
  RayHit3D? raycastLocal(
    Vector2 localPoint, {
    double maxDistance = double.infinity,
    CullMode? cullMode,
    bool Function(Object3D object)? filter,
    int? cameraMask,
    bool includeHidden = false,
  }) {
    localPointToRay(localPoint, output: _pickRay);
    return world.raycast(
      _pickRay,
      maxDistance: maxDistance,
      cullMode: cullMode,
      filter: filter,
      cameraMask: cameraMask ?? this.cameraMask,
      includeHidden: includeHidden,
    );
  }

  /// Casts a ray from [localPoint] against the [Object3D]s of [world],
  /// returning all hits sorted from nearest to farthest; objects are selected
  /// as in [raycastLocal].
  List<RayHit3D> raycastAllLocal(
    Vector2 localPoint, {
    double maxDistance = double.infinity,
    CullMode? cullMode,
    bool Function(Object3D object)? filter,
    int? cameraMask,
    bool includeHidden = false,
  }) {
    localPointToRay(localPoint, output: _pickRay);
    return world.raycastAll(
      _pickRay,
      maxDistance: maxDistance,
      cullMode: cullMode,
      filter: filter,
      cameraMask: cameraMask ?? this.cameraMask,
      includeHidden: includeHidden,
    );
  }

  /// Renders this layer once into an independent [Image] of [size] logical
  /// pixels.
  Image renderToImage(
    Size size, {
    Offset origin = Offset.zero,
    double zoom = 1.0,
    double pixelRatio = 1.0,
    Color clearValue = const Color(0x00000000),
  }) {
    final pScale = pixelRatio * world.renderScale;
    final targetW = math.max(1, (size.width * pScale).round());
    final targetH = math.max(1, (size.height * pScale).round());
    _writeCamera(
      zoom,
      0.0,
      0.0,
      zoom,
      origin.dx,
      origin.dy,
      pScale,
      0,
      0,
      targetW,
      targetH,
    );
    return world.renderToImage(
      Size(targetW.toDouble(), targetH.toDouble()),
      view: _viewMatrix,
      projection: _projectionMatrix,
      msaa: msaa,
      clearValue: clearValue,
    );
  }

  static final Ray _pickRay = Ray();

  @override
  GraphicsDevice get device {
    _resolveRenderer();
    return _device!;
  }

  @override
  RenderContext3D get context {
    _resolveRenderer();
    return _context!;
  }

  @override
  int get msaaSampleCount => msaa.sampleCount;

  @override
  double get pixelRatio => _pixelRatioOf(findGame());

  static double _pixelRatioOf(Game? game) {
    final buildContext = game?.buildContext;
    return buildContext == null
        ? 1.0
        : MediaQuery.devicePixelRatioOf(buildContext);
  }

  GraphicsDevice? _device;
  RenderContext3D? _context;
  Game3D? _game3D;
  EmbeddedRenderer? _renderer;

  // Retained GPU cache state. The scene target (rendered into directly) and
  // the bloom target (the output of the post-processing composite) each
  // remember the size they were created at.
  GpuRenderTarget? _retainedSceneTarget;
  int _sceneTargetWidth = 0;
  int _sceneTargetHeight = 0;
  int _sceneTargetMsaa = 0;
  GpuRenderTarget? _retainedBloomTarget;
  int _bloomTargetWidth = 0;
  int _bloomTargetHeight = 0;
  // The target whose last image is [_retainedImage].
  GpuRenderTarget? _retainedImageTarget;
  Image? _retainedImage;
  // The values the retained image was rendered with, see [_writeKey]; the
  // next frame's values are written into the second pair and compared.
  Float64List _retainedNumbers = Float64List(_keyNumberCount);
  Float64List _nextNumbers = Float64List(_keyNumberCount);
  List<Object?> _retainedObjects = List.filled(_keyObjectCount, null);
  List<Object?> _nextObjects = List.filled(_keyObjectCount, null);
  final Float32List _retainedView = Float32List(16);
  final Float32List _retainedProj = Float32List(16);

  /// The render target whose image a [Scene3DCacheMode.retained] layer
  /// reuses, for tests.
  @visibleForTesting
  GpuRenderTarget? get debugRetainedTarget => _retainedImageTarget;

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

  static const int _keyNumberCount = 38;
  static const int _keyObjectCount = 4;

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
      ..[37] = vignette ? visibleFrame.bottom : 0;
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
    for (var i = 0; i < _keyNumberCount; i++) {
      if (next[i] != kept[i]) {
        return false;
      }
    }
    for (var i = 0; i < _keyObjectCount; i++) {
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

  void _resolveRenderer() {
    if (_context != null) {
      return;
    }
    final game = findGame();
    if (game case final Game3D game3D) {
      _game3D = game3D;
      _device = game3D.device;
      _context = game3D.context;
    } else {
      final renderer = _renderer = EmbeddedRenderer.of(game ?? this);
      _device = renderer.device;
      _context = renderer.context;
    }
  }

  @override
  void onRemove() {
    _disposeRetained();
    super.onRemove();
    _device = null;
    _context = null;
    _game3D = null;
    _renderer = null;
  }

  @override
  void render(Canvas canvas) {
    _stats.reset();
    _renderedRect = Rect.zero;
    _renderMicroseconds = 0;
    if (!world.isMounted || world.children.isEmpty) {
      return;
    }
    final stopwatch = _stopwatch
      ..reset()
      ..start();
    RenderProfile.start();
    _renderScene(canvas);
    stopwatch.stop();
    _renderMicroseconds = stopwatch.elapsedMicroseconds;
  }

  void _renderScene(Canvas canvas) {
    final transform = canvas.getTransform();
    final a = transform[0];
    final b = transform[1];
    final c = transform[4];
    final d = transform[5];
    final tx = transform[12];
    final ty = transform[13];
    final determinant = a * d - b * c;
    if (!(determinant.abs() > 1e-12)) {
      return;
    }

    var visible = canvas.getDestinationClipBounds();
    final game = findGame();
    if (visible.width > _unclipped || visible.height > _unclipped) {
      if (game == null || !game.hasLayout) {
        return;
      }
      // The game's area, in the pixels of an offscreen picture when the
      // layer draws into one.
      final gameSize = game.canvasSize;
      final scale = RasterScale.current ?? 1.0;
      visible = visible.intersect(
        Rect.fromLTWH(0, 0, gameSize.x * scale, gameSize.y * scale),
      );
    }
    final width = size.x;
    final height = size.y;
    final bounded = width != 0 || height != 0;
    var localClip = bounded ? Rect.fromLTWH(0, 0, width, height) : null;
    final rect = visibleRect;
    if (rect != null) {
      localClip = localClip?.intersect(rect) ?? rect;
      if (localClip.isEmpty) {
        return;
      }
    }
    if (localClip != null) {
      visible = visible.intersect(
        _deviceBounds(
          a,
          b,
          c,
          d,
          tx + a * localClip.left + c * localClip.top,
          ty + b * localClip.left + d * localClip.top,
          localClip.width,
          localClip.height,
        ),
      );
    }
    if (visible.isEmpty) {
      return;
    }
    // What is seen of the layer, which the vignette is centered on, whatever
    // part of it the scene covers.
    final frame = visible;
    final scene = _sceneBounds(a, b, c, d, tx, ty);
    if (scene != null) {
      visible = visible.intersect(scene);
    }
    if (visible.isEmpty || !visible.isFinite) {
      return;
    }

    // On screen the canvas is in logical pixels; in an offscreen picture
    // that rasterizes at a scale of its own (a post process, a camera's
    // scaled world), its units are already the picture's pixels.
    final canvasPixelRatio = RasterScale.isActive ? 1.0 : _pixelRatioOf(game);
    final fullScale = canvasPixelRatio * world.renderScale;
    var pixelScale = fullScale;
    var left = (visible.left * pixelScale).floor();
    var top = (visible.top * pixelScale).floor();
    var pixelWidth = (visible.right * pixelScale).ceil() - left;
    var pixelHeight = (visible.bottom * pixelScale).ceil() - top;
    final maxSize = _maxTextureSize;
    if (pixelWidth > maxSize || pixelHeight > maxSize) {
      pixelScale *= (maxSize - 2) / math.max(pixelWidth, pixelHeight);
      left = (visible.left * pixelScale).floor();
      top = (visible.top * pixelScale).floor();
      pixelWidth = (visible.right * pixelScale).ceil() - left;
      pixelHeight = (visible.bottom * pixelScale).ceil() - top;
    }
    if (pixelWidth <= 0 || pixelHeight <= 0) {
      return;
    }

    final neededWidth = math.min(_roundUp(pixelWidth), maxSize);
    final neededHeight = math.min(_roundUp(pixelHeight), maxSize);
    if (_targetWidth < neededWidth ||
        _targetHeight < neededHeight ||
        _targetWidth > maxSize ||
        _targetHeight > maxSize ||
        _targetWidth * _targetHeight > 2 * neededWidth * neededHeight) {
      _targetWidth = neededWidth;
      _targetHeight = neededHeight;
    }
    final targetWidth = _targetWidth;
    final targetHeight = _targetHeight;

    _writeCamera(
      a,
      b,
      c,
      d,
      tx,
      ty,
      pixelScale,
      left,
      top,
      targetWidth,
      targetHeight,
    );

    final destination = Rect.fromLTRB(
      left / pixelScale,
      top / pixelScale,
      (left + pixelWidth) / pixelScale,
      (top + pixelHeight) / pixelScale,
    );
    final visibleFrame = Rect.fromLTRB(
      frame.left * pixelScale - left,
      frame.top * pixelScale - top,
      frame.right * pixelScale - left,
      frame.bottom * pixelScale - top,
    );

    final isRetained = _cacheMode == Scene3DCacheMode.retained;
    if (isRetained) {
      _writeKey(
        left,
        top,
        pixelWidth,
        pixelHeight,
        targetWidth,
        targetHeight,
        pixelScale,
        visibleFrame,
      );
      final retainedImage = _retainedImage;
      final retainedTarget = _retainedImageTarget;
      if (retainedImage != null &&
          retainedTarget != null &&
          _keyMatches() &&
          _sameFloats(_viewMatrix.storage, _retainedView) &&
          _sameFloats(_projectionMatrix.storage, _retainedProj)) {
        _cacheHitCount++;
        // The image is drawn again in this frame: its color texture must not
        // be rendered into before Flutter has finished drawing it.
        _resolveRenderer();
        _device!.backend.representLastImage(retainedTarget);
        _compositeImage(
          canvas,
          retainedImage,
          pixelWidth,
          pixelHeight,
          destination,
          a,
          b,
          c,
          d,
          tx,
          ty,
          determinant,
          localClip,
          pixelScale,
          fullScale,
        );
        return;
      }
    }

    _resolveRenderer();
    final device = _device!;
    final context = _context!;
    final game3D = _game3D;
    final bool closeFrame;
    if (game3D != null) {
      closeFrame = !game3D.isRenderingFrame;
      if (closeFrame) {
        device.begin();
      }
    } else {
      closeFrame = _renderer!.open();
    }

    _statsBefore.setFrom(device.stats);
    context
      ..cameraMask = cameraMask
      ..setCamera(_viewMatrix, _projectionMatrix);
    world.syncContextOptions(context);
    RenderProfile.lap(RenderPhase.setup);
    world
      ..renderShadows(canvas)
      ..renderDepthNormals(canvas, targetWidth, targetHeight);

    final usePost = world.needsPostCompositePass(device);
    GpuRenderTarget? ownedTarget;
    if (isRetained) {
      if (usePost) {
        if (_retainedBloomTarget == null ||
            _bloomTargetWidth != targetWidth ||
            _bloomTargetHeight != targetHeight) {
          _bloomTargetWidth = targetWidth;
          _bloomTargetHeight = targetHeight;
          _retainedBloomTarget = device.backend.createRenderTarget(
            width: targetWidth,
            height: targetHeight,
            clearValue: device.clearValue,
          );
        }
        ownedTarget = _retainedBloomTarget;
      } else {
        if (_retainedSceneTarget == null ||
            _sceneTargetWidth != targetWidth ||
            _sceneTargetHeight != targetHeight ||
            _sceneTargetMsaa != msaa.sampleCount) {
          _sceneTargetWidth = targetWidth;
          _sceneTargetHeight = targetHeight;
          _sceneTargetMsaa = msaa.sampleCount;
          _retainedSceneTarget = device.backend.createRenderTarget(
            width: targetWidth,
            height: targetHeight,
            clearValue: device.clearValue,
            msaaSampleCount: msaa.sampleCount,
          );
        }
        ownedTarget = _retainedSceneTarget;
      }
    }

    final image = world.executeWorldRenderPipeline(
      device: device,
      renderContext: context,
      width: targetWidth,
      height: targetHeight,
      msaaSampleCount: msaa.sampleCount,
      clearValue: device.clearValue,
      ownedOutputTarget: ownedTarget,
      recordDraws: () => world.renderScene(canvas),
      visibleFrame: visibleFrame,
    );

    _subtract(device.stats, _statsBefore, _stats);
    if (closeFrame) {
      if (game3D != null) {
        device.end();
      } else {
        _renderer!.close();
      }
    }
    RenderProfile.lap(RenderPhase.passEnd);

    _compositeImage(
      canvas,
      image,
      pixelWidth,
      pixelHeight,
      destination,
      a,
      b,
      c,
      d,
      tx,
      ty,
      determinant,
      localClip,
      pixelScale,
      fullScale,
    );

    if (isRetained) {
      _retainedImage?.dispose();
      _retainedImage = image;
      _retainedImageTarget = ownedTarget;
      _keepKey();
      _retainedView.setAll(0, _viewMatrix.storage);
      _retainedProj.setAll(0, _projectionMatrix.storage);
    } else {
      image.dispose();
    }
  }

  void _compositeImage(
    Canvas canvas,
    Image image,
    int pixelWidth,
    int pixelHeight,
    Rect destination,
    double a,
    double b,
    double c,
    double d,
    double tx,
    double ty,
    double determinant,
    Rect? localClip,
    double pixelScale,
    double fullScale,
  ) {
    final inverse = _inverseTransform
      ..[0] = d / determinant
      ..[1] = -b / determinant
      ..[4] = -c / determinant
      ..[5] = a / determinant
      ..[12] = (c * ty - d * tx) / determinant
      ..[13] = (b * tx - a * ty) / determinant;
    canvas.save();
    // The destination is axis-aligned on the device; a rotated or sheared
    // local rectangle needs a clip of its own.
    if (localClip != null && (b != 0 || c != 0)) {
      canvas.clipRect(localClip);
    }
    canvas.transform(inverse);
    _paint.filterQuality = pixelScale == fullScale && world.renderScale == 1.0
        ? FilterQuality.none
        : world.scaledFilterQuality;
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, pixelWidth.toDouble(), pixelHeight.toDouble()),
      destination,
      _paint,
    );
    canvas.restore();
    _renderedRect = destination;
    RenderProfile.lap(RenderPhase.composite);
  }

  static bool _sameFloats(Float32List a, Float32List b) {
    for (var i = 0; i < 16; i++) {
      if ((a[i] - b[i]).abs() > 1e-9) {
        return false;
      }
    }
    return true;
  }

  Rect? _sceneBounds(
    double a,
    double b,
    double c,
    double d,
    double tx,
    double ty,
  ) {
    // A component left out of the scene bounds may draw anywhere.
    var box = world.hasUnboundedComponents ? null : world.sceneBounds;
    final bound = visibleSceneBounds;
    if (bound != null) {
      if (box == null) {
        box = bound;
      } else {
        box = _sceneBox
          ..min.setValues(
            math.max(box.min.x, bound.min.x),
            math.max(box.min.y, bound.min.y),
            math.max(box.min.z, bound.min.z),
          )
          ..max.setValues(
            math.min(box.max.x, bound.max.x),
            math.min(box.max.y, bound.max.y),
            math.min(box.max.z, bound.max.z),
          );
        if (box.min.x > box.max.x ||
            box.min.y > box.max.y ||
            box.min.z > box.max.z) {
          return Rect.zero;
        }
      }
    }
    if (box == null) {
      return null;
    }
    final m = projection.sceneToLocalValues;
    final min = box.min;
    final max = box.max;
    var left = double.infinity;
    var top = double.infinity;
    var right = double.negativeInfinity;
    var bottom = double.negativeInfinity;
    for (var corner = 0; corner < 8; corner++) {
      final x = corner & 1 == 0 ? min.x : max.x;
      final y = corner & 2 == 0 ? min.y : max.y;
      final z = corner & 4 == 0 ? min.z : max.z;
      final w = m[3] * x + m[7] * y + m[11] * z + m[15];
      if (!(w > 0)) {
        return null;
      }
      final localX = (m[0] * x + m[4] * y + m[8] * z + m[12]) / w;
      final localY = (m[1] * x + m[5] * y + m[9] * z + m[13]) / w;
      final deviceX = a * localX + c * localY + tx;
      final deviceY = b * localX + d * localY + ty;
      left = math.min(left, deviceX);
      top = math.min(top, deviceY);
      right = math.max(right, deviceX);
      bottom = math.max(bottom, deviceY);
    }
    return Rect.fromLTRB(left, top, right, bottom);
  }

  final Aabb3 _sceneBox = Aabb3();

  int _targetWidth = 0;
  int _targetHeight = 0;

  void _writeCamera(
    double a,
    double b,
    double c,
    double d,
    double tx,
    double ty,
    double pixelScale,
    int left,
    int top,
    int targetWidth,
    int targetHeight,
  ) {
    final sx = 2 * pixelScale / targetWidth;
    final sy = 2 * pixelScale / targetHeight;
    final c00 = sx * a;
    final c01 = sx * c;
    final c03 = 2 * (pixelScale * tx - left) / targetWidth - 1;
    final c10 = -sy * b;
    final c11 = -sy * d;
    final c13 = 1 - 2 * (pixelScale * ty - top) / targetHeight;

    final viewToLocal = projection.viewToLocalValues;
    final p = _projectionMatrix.storage;
    for (var column = 0; column < 4; column++) {
      final i = column * 4;
      final x = viewToLocal[i];
      final y = viewToLocal[i + 1];
      final w = viewToLocal[i + 3];
      p[i] = c00 * x + c01 * y + c03 * w;
      p[i + 1] = c10 * x + c11 * y + c13 * w;
      p[i + 2] = viewToLocal[i + 2];
      p[i + 3] = w;
    }
    _viewMatrix.storage.setAll(0, projection.viewValues);
  }

  final Matrix4 _viewMatrix = Matrix4.identity();
  final Matrix4 _projectionMatrix = Matrix4.identity();
  final Float64List _inverseTransform = Float64List(16)
    ..[10] = 1
    ..[15] = 1;
  final Paint _paint = Paint();
  final RenderStats _statsBefore = RenderStats();
  final Stopwatch _stopwatch = Stopwatch();

  static const int _bucket = 64;
  static const double _unclipped = 1e6;

  static int _roundUp(int pixels) =>
      (pixels + _bucket - 1) ~/ _bucket * _bucket;

  static Rect _deviceBounds(
    double a,
    double b,
    double c,
    double d,
    double tx,
    double ty,
    double width,
    double height,
  ) {
    final x1 = a * width;
    final y1 = b * width;
    final x2 = c * height;
    final y2 = d * height;
    return Rect.fromLTRB(
      tx + math.min(0.0, x1) + math.min(0.0, x2),
      ty + math.min(0.0, y1) + math.min(0.0, y2),
      tx + math.max(0.0, x1) + math.max(0.0, x2),
      ty + math.max(0.0, y1) + math.max(0.0, y2),
    );
  }

  static void _subtract(
    RenderStats after,
    RenderStats before,
    RenderStats out,
  ) {
    out
      ..renderPasses = after.renderPasses - before.renderPasses
      ..drawCalls = after.drawCalls - before.drawCalls
      ..instances = after.instances - before.instances
      ..triangles = after.triangles - before.triangles
      ..pipelineChanges = after.pipelineChanges - before.pipelineChanges
      ..materialChanges = after.materialChanges - before.materialChanges
      ..stateChanges = after.stateChanges - before.stateChanges
      ..uniformUploads = after.uniformUploads - before.uniformUploads
      ..uploadedBytes = after.uploadedBytes - before.uploadedBytes
      ..particles = after.particles - before.particles
      ..shadowPasses = after.shadowPasses - before.shadowPasses
      ..shadowDrawCalls = after.shadowDrawCalls - before.shadowDrawCalls;
  }
}
