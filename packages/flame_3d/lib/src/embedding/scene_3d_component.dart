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
import 'package:flame_3d/src/extensions/clip_space.dart';
import 'package:flame_3d/src/graphics/embedded_renderer.dart';
import 'package:flutter/widgets.dart' show BuildContext, MediaQuery;
import 'package:meta/meta.dart' show visibleForTesting;

part 'scene_3d_render_pipeline.dart';
part 'scene_3d_retained_cache.dart';

/// Caching strategy for a [Scene3DComponent]'s GPU render pass.
enum Scene3DCacheMode() {
  /// Renders the 3D scene pass every frame.
  none,

  /// Retains the rendered GPU [Image] in a dedicated target and reuses it with
  /// `0` GPU passes on subsequent frames whenever the scene, shadow casters,
  /// camera projection, canvas transform, and visible clip (and, in a
  /// [ShadowGroup], the [ShadowGroup.viewsVersion]) have not changed.
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
  double get pixelRatio => _pixelRatioOfGame(_resolveGame());

  Game? _cachedGame;
  BuildContext? _cachedDprContext;
  double _cachedPixelRatio = 1.0;
  bool _pixelRatioDirty = true;

  @override
  void onMount() {
    super.onMount();
    _cachedGame = findGame();
    _pixelRatioDirty = true;
  }

  @override
  void onGameResize(Vector2 size) {
    super.onGameResize(size);
    _pixelRatioDirty = true;
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

  static const int _keyNumberCount = 39;
  static const int _keyObjectCount = 4;

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
    _cachedGame = null;
    _cachedDprContext = null;
    _pixelRatioDirty = true;
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

  final Aabb3 _sceneBox = Aabb3();

  int _targetWidth = 0;
  int _targetHeight = 0;

  final Matrix4 _viewMatrix = Matrix4.identity();
  final Matrix4 _projectionMatrix = Matrix4.identity();
  // The projection of a camera that sees the part of the screen the layer
  // may draw on, which it reports to its shadow group.
  final Matrix4 _groupProjectionMatrix = Matrix4.identity();
  final Float64List _inverseTransform = Float64List(16)
    ..[10] = 1
    ..[15] = 1;
  final Paint _paint = Paint();
  final RenderStats _statsBefore = RenderStats();
  final Stopwatch _stopwatch = Stopwatch();

  static const int _bucket = 64;
  static const double _unclipped = 1e6;
}
