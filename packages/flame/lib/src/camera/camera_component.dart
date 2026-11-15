import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flame/components.dart';
import 'package:flame/extensions.dart';
import 'package:flame/post_process.dart';
import 'package:flame/src/camera/behaviors/bounded_position_behavior.dart';
import 'package:flame/src/camera/behaviors/follow_behavior.dart';
import 'package:flame/src/camera/behaviors/viewport_aware_bounds_behavior.dart';
import 'package:flame/src/camera/scene_transition.dart';
import 'package:flame/src/camera/viewfinder.dart';
import 'package:flame/src/camera/viewport.dart';
import 'package:flame/src/camera/viewports/fixed_resolution_viewport.dart';
import 'package:flame/src/camera/viewports/max_viewport.dart';
import 'package:flame/src/canvas3d/primitives_3d.dart';
import 'package:flame/src/canvas3d/raycast_3d.dart';
import 'package:flame/src/canvas3d/spatial_hit_testing_3d.dart';
import 'package:flame/src/components/core/component.dart';
import 'package:flame/src/effects/controllers/effect_controller.dart';
import 'package:flame/src/effects/move_by_effect.dart';
import 'package:flame/src/effects/move_effect.dart';
import 'package:flame/src/effects/move_to_effect.dart';
import 'package:flame/src/effects/provider_interfaces.dart';
import 'package:flame/src/experimental/geometry/shapes/circle.dart';
import 'package:flame/src/experimental/geometry/shapes/rectangle.dart';
import 'package:flame/src/experimental/geometry/shapes/rounded_rectangle.dart';
import 'package:flame/src/experimental/geometry/shapes/shape.dart';
import 'package:flame/src/game/flame_game.dart';
import 'package:flame/src/game/telemetry_canvas.dart';
import 'package:meta/meta.dart';

/// Sub-pixel camera translation stabilization modes for [CameraComponent].
enum PixelSnapMode() {
  /// Leaves floating-point sub-pixel camera translations untouched (default).
  none,

  /// Snaps rendered camera translation to whole logical viewport pixels
  /// (`1.0`).
  logicalPixel,

  /// Snaps rendered camera translation to physical device pixels
  /// (`1.0 / effectiveDevicePixelRatio`) for shimmer-free Retina rendering.
  physicalPixel,
}

/// Retained GPU `ui.Picture` layer caching policy for [CameraComponent].
enum CameraLayerCacheMode() {
  /// Re-records `backdrop`, `world`, and `viewport` trees every frame
  /// (default).
  none,

  /// Retains independent GPU-ready `ui.Picture` layers for `backdrop`, `world`
  /// (when `postProcess == null` and no [SceneTransition] is active), and
  /// `viewport` HUD, re-recording ONLY layers whose `Component.subtreeVersion`
  /// or camera transform changed since the previous paint.
  splitRetained,
}

/// [CameraComponent] is a component through which a [World] is observed.
///
/// A camera consists of two parts: a [Viewport], and a [Viewfinder]. It also
/// references a [World] component, which is not mounted to the camera, but the
/// camera still knows about it. The world must be mounted somewhere else in
/// the game tree.
///
/// A camera is a regular component that can be placed anywhere in the game
/// tree. Most games will have at least one "main" camera for displaying the
/// main game world. However, additional cameras may also be used for some
/// special effects. These extra cameras may be placed either in parallel with
/// the main camera, or within the world. It is even possible to create a camera
/// that looks at itself. [FlameGame] has one [CameraComponent] added by default
/// which is called just [FlameGame.camera].
///
/// Since [CameraComponent] is a [Component], it is possible to attach other
/// components to it. In particular, adding components directly to the camera is
/// equivalent to adding them to the camera's parent. Components added to the
/// viewport will be affected by the viewport's position, but not by its clip
/// mask. Such components will be rendered on top of the viewport. Components
/// added to the viewfinder will be rendered as if they were part of the world.
/// That is, they will be affected both by the viewport and the viewfinder.
///
///
/// A [PostProcess] can be applied to the camera, which will affect the
/// rendering of the world. This is useful for applying effects such as bloom,
/// blur, or other fragment shader effects to the world. See [postProcess] for
/// more information.
class CameraComponent({
  /// Special component that is designed to be the root of a game world.
  ///
  /// Multiple cameras can observe the same [world] simultaneously, and the
  /// world may itself contain cameras that look into other worlds, or even into
  /// itself.
  ///
  /// The [world] component is generally mounted externally to the camera, and
  /// this variable is a mere reference to it.
  var World? world,
  Viewport? viewport,
  Viewfinder? viewfinder,
  Component? backdrop,
  List<Component>? hudComponents,
  CameraLayerCacheMode layerCacheMode = CameraLayerCacheMode.none,
  super.cameraMask,
  super.children,
  super.key,
}) extends Component {
  this : super(priority: 0x7fffffff) {
    children.register<PostProcessComponent>();
    addAll([_backdrop, _viewport, _viewfinder]);
  }

  /// Create a camera that shows a portion of the game world of fixed size
  /// [width] x [height].
  ///
  /// The viewport will be centered within the canvas, expanding as much as
  /// possible on all sides while maintaining the [width]:[height] aspect ratio.
  /// The zoom level will be set such in such a way that exactly [width] x
  /// [height] pixels are visible within the viewport. The viewfinder will be
  /// initially set up to show world coordinates (0, 0) at the center of the
  /// viewport.
  CameraComponent.withFixedResolution({
    required double width,
    required double height,
    World? world,
    Viewfinder? viewfinder,
    Component? backdrop,
    List<Component>? hudComponents,
    CameraLayerCacheMode layerCacheMode = CameraLayerCacheMode.none,
    int? cameraMask,
    Iterable<Component>? children,
    ComponentKey? key,
  }) : this(
         world: world,
         viewport: FixedResolutionViewport(resolution: Vector2(width, height)),
         viewfinder: viewfinder ?? Viewfinder(),
         backdrop: backdrop,
         hudComponents: hudComponents,
         layerCacheMode: layerCacheMode,
         cameraMask: cameraMask,
         children: children,
         key: key,
       );

  /// The [viewport] is the "window" through which the game world is observed.
  ///
  /// Imagine that the world is covered with an infinite sheet of paper, but
  /// there is a hole in it. That hole is the viewport: through that aperture
  /// the world can be observed. The viewport's size is equal to or smaller
  /// than the size of the game canvas. If it is smaller, then the viewport's
  /// position specifies where exactly it is placed on the canvas.
  Viewport get viewport => _viewport;

  set viewport(Viewport newViewport) {
    _viewport.removeFromParent();
    _viewport = newViewport;
    add(_viewport);
    _viewfinder.updateTransform();
  }

  Viewport _viewport = (viewport ?? MaxViewport())..addAll(hudComponents ?? []);

  /// The [viewfinder] controls which part of the world is seen through the
  /// viewport.
  ///
  /// Thus, viewfinder's `position` is the world point which is seen at the
  /// center of the viewport. In addition, viewfinder controls the zoom level
  /// (i.e. how much of the world is seen through the viewport), and,
  /// optionally, rotation.
  Viewfinder get viewfinder => _viewfinder;

  set viewfinder(Viewfinder newViewfinder) {
    _viewfinder.removeFromParent();
    _viewfinder = newViewfinder;
    add(_viewfinder);
  }

  Viewfinder _viewfinder = viewfinder ?? Viewfinder();

  /// The [backdrop] component is rendered statically behind the world.
  ///
  /// Here you can add things like the parallax component which should be static
  /// when the camera moves around.
  Component get backdrop => _backdrop;
  Component _backdrop = backdrop ?? Component();
  set backdrop(Component newBackdrop) {
    _backdrop.removeFromParent();
    add(newBackdrop);
    _backdrop = newBackdrop;
  }

  /// The axis-aligned bounding rectangle of a [world] region which is currently
  /// visible through the viewport.
  ///
  /// This property can be useful in order to determine which components within
  /// the game's world are currently visible to the player, and which aren't.
  ///
  /// If the viewport is non-rectangular, or if the world's view is rotated,
  /// then the [visibleWorldRect] will be larger than the actual viewing area.
  /// Thus, this property is "conservative": everything outside of this rect
  /// is definitely not visible, while the points inside may or may not be
  /// visible.
  ///
  /// This property is cached, and is recalculated whenever the camera moves
  /// or the viewport is resized. At the same time, it may only be accessed
  /// after the camera was fully mounted.
  Rect get visibleWorldRect {
    assert(
      parent != null,
      "This property can't be accessed before the camera is added to the game. "
      'If you are using visibleWorldRect from another component (for example '
      'the World), make sure that the CameraComponent is added before that '
      'Component.',
    );
    return viewfinder.visibleWorldRect;
  }

  /// Renders the [world] as seen through this camera.
  ///
  /// If the world is not mounted yet, only the viewport and viewfinder elements
  /// will be rendered.
  @override
  void renderTree(Canvas canvas) {
    _lastFrameCulledCount = 0;
    _lastFrameVisibleCount = 0;
    syncAutoDevicePixelRatio();
    canvas.save();
    canvas.translate(
      viewport.position.x - viewport.anchor.x * viewport.size.x,
      viewport.position.y - viewport.anchor.y * viewport.size.y,
    );
    // Render the world through the viewport
    if ((world?.isMounted ?? false) &&
        currentCameras.length < maxCamerasDepth) {
      final useRetained = _layerCacheMode == CameraLayerCacheMode.splitRetained;
      final vSize = viewport.virtualSize;
      canvas.save();
      viewport.clip(canvas);
      viewport.transformCanvas(canvas);
      if (useRetained && vSize.x > 0 && vSize.y > 0) {
        _renderRetainedBackdrop(canvas, vSize.x, vSize.y);
      } else {
        backdrop.renderTree(canvas);
      }
      canvas.save();
      try {
        currentCameras.add(this);
        final postProcessors = children.query<PostProcessComponent>();
        final game = findGame();
        final allowPostProcess =
            game is! FlameGame || game.graphics.effectivePostProcessEnabled;
        if (postProcessors.isNotEmpty) {
          assert(
            postProcessors.length == 1,
            'Only one post process component is allowed per camera.',
          );
          final postProcessor = postProcessors.first.postProcess;
          if (allowPostProcess || postProcessor is PostProcessPipeline) {
            postProcessor.render(
              canvas,
              vSize,
              _renderWorld,
              _updatePostProcessContext,
            );
          } else {
            _renderScaledOrDirectWorld(canvas);
          }
        } else if (useRetained &&
            vSize.x > 0 &&
            vSize.y > 0 &&
            !hasActiveSceneTransition &&
            !viewfinder.hasActiveShake) {
          _renderRetainedWorld(canvas, vSize.x, vSize.y, game);
        } else {
          _renderScaledOrDirectWorld(canvas);
        }
      } finally {
        currentCameras.removeLast();
      }
      canvas.restore();
      if (_activeTransition != null &&
          _transitionSnapshot != null &&
          !_activeTransition!.aboveViewportHud) {
        _renderActiveTransition(canvas);
      }
      // Render the viewport elements, which will be in front of the world.
      if (useRetained && vSize.x > 0 && vSize.y > 0) {
        _renderRetainedViewport(canvas, vSize.x, vSize.y);
      } else {
        viewport.renderTree(canvas);
      }
      if (_activeTransition != null &&
          _transitionSnapshot != null &&
          _activeTransition!.aboveViewportHud) {
        _renderActiveTransition(canvas);
      }
      canvas.restore();
    }
    canvas.restore();
  }

  CameraLayerCacheMode _layerCacheMode = layerCacheMode;

  /// Retained GPU `ui.Picture` layer compositing mode (`none` or
  /// `splitRetained`).
  CameraLayerCacheMode get layerCacheMode => _layerCacheMode;
  set layerCacheMode(CameraLayerCacheMode value) {
    if (_layerCacheMode == value) {
      return;
    }
    _layerCacheMode = value;
    if (value == CameraLayerCacheMode.none) {
      invalidateLayerCaches();
    } else {
      findGame()?.markSceneDirty();
    }
  }

  ui.Picture? _cachedBackdropPicture;
  int _cachedBackdropVersion = -1;
  double _cachedBackdropW = -1.0;
  double _cachedBackdropH = -1.0;
  int _backdropCacheHitCount = 0;
  int _backdropCacheRebuildCount = 0;

  ui.Picture? _cachedWorldPicture;
  World? _cachedWorldRef;
  int _cachedWorldSubtreeVersion = -1;
  int _cachedViewfinderSubtreeVersion = -1;
  int _cachedViewfinderTxVersion = -1;
  double _cachedWorldScale = -1.0;
  int _cachedWorldCamMask = 0;
  int _cachedWorldLayerMask = 0;
  int _cachedWorldGraphicsVersion = -1;
  double _cachedWorldInterpAlpha = -1.0;
  PixelSnapMode _cachedWorldSnapMode = PixelSnapMode.none;
  double _cachedWorldDpr = -1.0;
  double _cachedWorldW = -1.0;
  double _cachedWorldH = -1.0;
  int _worldCacheHitCount = 0;
  int _worldCacheRebuildCount = 0;

  ui.Picture? _cachedViewportPicture;
  int _cachedViewportVersion = -1;
  double _cachedViewportW = -1.0;
  double _cachedViewportH = -1.0;
  int _viewportCacheHitCount = 0;
  int _viewportCacheRebuildCount = 0;

  /// Number of frames where `backdrop` reused its retained `ui.Picture`.
  int get backdropCacheHitCount => _backdropCacheHitCount;

  /// Number of frames where `backdrop` recorded a fresh `ui.Picture`.
  int get backdropCacheRebuildCount => _backdropCacheRebuildCount;

  /// Number of frames where `world` reused its retained `ui.Picture` (`0`
  /// `world.renderTree` work).
  int get worldCacheHitCount => _worldCacheHitCount;

  /// Number of frames where `world` recorded a fresh `ui.Picture`.
  int get worldCacheRebuildCount => _worldCacheRebuildCount;

  /// Number of frames where `viewport` HUD reused its retained `ui.Picture`.
  int get viewportCacheHitCount => _viewportCacheHitCount;

  /// Number of frames where `viewport` HUD recorded a fresh `ui.Picture`.
  int get viewportCacheRebuildCount => _viewportCacheRebuildCount;

  /// Disposes any retained `backdrop`, `world`, and `viewport` `ui.Picture`s
  /// and resets their version keys (preserving hit/rebuild telemetry counters
  /// unless [resetCounters] is `true`).
  void invalidateLayerCaches({bool resetCounters = false}) {
    _cachedBackdropPicture?.dispose();
    _cachedBackdropPicture = null;
    _cachedBackdropVersion = -1;

    _cachedWorldPicture?.dispose();
    _cachedWorldPicture = null;
    _cachedWorldRef = null;
    _cachedWorldSubtreeVersion = -1;

    _cachedViewportPicture?.dispose();
    _cachedViewportPicture = null;
    _cachedViewportVersion = -1;

    if (resetCounters) {
      _backdropCacheHitCount = 0;
      _backdropCacheRebuildCount = 0;
      _worldCacheHitCount = 0;
      _worldCacheRebuildCount = 0;
      _viewportCacheHitCount = 0;
      _viewportCacheRebuildCount = 0;
    }
  }

  void _renderRetainedBackdrop(ui.Canvas canvas, double w, double h) {
    final ver = backdrop.subtreeVersion;
    if (_cachedBackdropPicture != null &&
        _cachedBackdropVersion == ver &&
        _cachedBackdropW == w &&
        _cachedBackdropH == h) {
      _backdropCacheHitCount++;
      canvas.drawPicture(_cachedBackdropPicture!);
      return;
    }
    _cachedBackdropPicture?.dispose();
    final recorder = ui.PictureRecorder();
    final recCanvas = TelemetryCanvas.wrapOffscreenIfActive(
      ui.Canvas(recorder, ui.Rect.fromLTWH(0, 0, w, h)),
    );
    backdrop.renderTree(recCanvas);
    final pic = recorder.endRecording();
    _cachedBackdropPicture = pic;
    _cachedBackdropVersion = ver;
    _cachedBackdropW = w;
    _cachedBackdropH = h;
    _backdropCacheRebuildCount++;
    canvas.drawPicture(pic);
  }

  void _renderRetainedWorld(
    ui.Canvas canvas,
    double w,
    double h,
    FlameGame? game,
  ) {
    final activeWorld = world!;
    final worldVer = activeWorld.subtreeVersion;
    final vfSubVer = viewfinder.subtreeVersion;
    final vfTxVer = viewfinder.transform.version;
    final scale = effectiveWorldRenderScale;
    final cMask = cameraMask;
    final lMask = layerMask;
    final gfxVer = game?.graphics.version ?? 0;
    final interpAlpha =
        (game != null &&
            game.fixedTimeStep != null &&
            game.hasMovingFixedInterpolation)
        ? game.renderInterpolationAlpha
        : 1.0;
    final snapMode = pixelSnapMode;
    final dpr = effectiveDevicePixelRatio;

    if (_cachedWorldPicture != null &&
        identical(_cachedWorldRef, activeWorld) &&
        _cachedWorldSubtreeVersion == worldVer &&
        _cachedViewfinderSubtreeVersion == vfSubVer &&
        _cachedViewfinderTxVersion == vfTxVer &&
        _cachedWorldScale == scale &&
        _cachedWorldCamMask == cMask &&
        _cachedWorldLayerMask == lMask &&
        _cachedWorldGraphicsVersion == gfxVer &&
        (_cachedWorldInterpAlpha - interpAlpha).abs() <= 1e-6 &&
        _cachedWorldSnapMode == snapMode &&
        _cachedWorldDpr == dpr &&
        _cachedWorldW == w &&
        _cachedWorldH == h) {
      _worldCacheHitCount++;
      canvas.drawPicture(_cachedWorldPicture!);
      return;
    }

    _cachedWorldPicture?.dispose();
    final recorder = ui.PictureRecorder();
    final recCanvas = TelemetryCanvas.wrapOffscreenIfActive(
      ui.Canvas(recorder, ui.Rect.fromLTWH(0, 0, w, h)),
    );
    _renderScaledOrDirectWorld(recCanvas);
    final pic = recorder.endRecording();
    _cachedWorldPicture = pic;
    _cachedWorldRef = activeWorld;
    _cachedWorldSubtreeVersion = worldVer;
    _cachedViewfinderSubtreeVersion = vfSubVer;
    _cachedViewfinderTxVersion = vfTxVer;
    _cachedWorldScale = scale;
    _cachedWorldCamMask = cMask;
    _cachedWorldLayerMask = lMask;
    _cachedWorldGraphicsVersion = gfxVer;
    _cachedWorldInterpAlpha = interpAlpha;
    _cachedWorldSnapMode = snapMode;
    _cachedWorldDpr = dpr;
    _cachedWorldW = w;
    _cachedWorldH = h;
    _worldCacheRebuildCount++;
    canvas.drawPicture(pic);
  }

  void _renderRetainedViewport(ui.Canvas canvas, double w, double h) {
    final ver = viewport.subtreeVersion;
    if (_cachedViewportPicture != null &&
        _cachedViewportVersion == ver &&
        _cachedViewportW == w &&
        _cachedViewportH == h) {
      _viewportCacheHitCount++;
      canvas.drawPicture(_cachedViewportPicture!);
      return;
    }
    _cachedViewportPicture?.dispose();
    final recorder = ui.PictureRecorder();
    final recCanvas = TelemetryCanvas.wrapOffscreenIfActive(
      ui.Canvas(recorder, ui.Rect.fromLTWH(0, 0, w, h)),
    );
    viewport.renderTree(recCanvas);
    final pic = recorder.endRecording();
    _cachedViewportPicture = pic;
    _cachedViewportVersion = ver;
    _cachedViewportW = w;
    _cachedViewportH = h;
    _viewportCacheRebuildCount++;
    canvas.drawPicture(pic);
  }

  /// Bitmask of `SceneLayerComponent.layerBit` flags visible to this camera
  /// (defaults to all 31 positive bits `0x7fffffff`).
  int layerMask = 0x7fffffff;

  /// Controls sub-pixel stabilization of the rendered viewfinder translation
  /// without mutating logical `viewfinder.position`.
  PixelSnapMode pixelSnapMode = PixelSnapMode.none;

  /// Whether [effectiveWorldRenderScale] multiplies [worldRenderScale] by
  /// `FlameGame.effectiveRenderScale`.
  bool respectGraphicsRenderScale = true;

  double _worldRenderScale = 1.0;

  /// Texture filtering quality used when blitting an offscreen-scaled world
  /// (`worldRenderScale != 1.0`).
  ui.FilterQuality upscaleFilterQuality = ui.FilterQuality.medium;

  /// Optional crisp contrast enhancement (`0.0 .. 1.0`) applied when upscaling
  /// `effectiveWorldRenderScale < 1.0` to counteract bilinear softness.
  double upscaleSharpness = 0.0;

  /// Optional custom [ui.FragmentShader] used when blitting a scaled world
  /// surface (`uSize` at floats `0, 1`, `uSharpness` at float `2`, image at
  /// sampler `0`).
  ui.FragmentShader? upscaleShader;

  /// Safety upper bound (in physical pixels) on scaled world surfaces.
  int maxRenderTextureDimension = 8192;

  final ui.Paint _upscalePaint = ui.Paint();
  int _lastWorldSurfaceWidth = 0;
  int _lastWorldSurfaceHeight = 0;
  int _offscreenWorldRenderCount = 0;
  ui.Offset _lastPixelSnapDelta = ui.Offset.zero;
  int _lastHighResTileCount = 0;

  /// Internal world render resolution scale (`0.25 .. 2.5`) applied
  /// independently of `camera.viewport` HUD elements (`< 1.0` dynamic upscale,
  /// `> 1.0` SSAA supersampling).
  double get worldRenderScale => _worldRenderScale;
  set worldRenderScale(double value) {
    final clamped = value.clamp(0.25, 2.5);
    if ((_worldRenderScale - clamped).abs() > 1e-5) {
      _worldRenderScale = clamped;
      syncAutoDevicePixelRatio();
      findGame()?.markSceneDirty();
    }
  }

  /// Effective world resolution scale combining [worldRenderScale] and
  /// `FlameGame.effectiveRenderScale` (when [respectGraphicsRenderScale] is
  /// `true`).
  double get effectiveWorldRenderScale {
    final game = findGame();
    final graphicsScale = (respectGraphicsRenderScale && game is FlameGame)
        ? game.effectiveRenderScale
        : 1.0;
    return (_worldRenderScale * graphicsScale).clamp(0.25, 2.5);
  }

  /// Effective hardware/capped `devicePixelRatio` of the owning `Game`.
  double get effectiveDevicePixelRatio => findGame()?.devicePixelRatio ?? 1.0;

  /// Width in physical pixels of the most recent scaled world offscreen buffer
  /// (`0` when rendered directly at `1:1`).
  @visibleForTesting
  int get lastWorldSurfaceWidth => _lastWorldSurfaceWidth;

  /// Height in physical pixels of the most recent scaled world offscreen buffer
  /// (`0` when rendered directly at `1:1`).
  @visibleForTesting
  int get lastWorldSurfaceHeight => _lastWorldSurfaceHeight;

  /// Total number of scaled offscreen world passes executed by this camera.
  @visibleForTesting
  int get offscreenWorldRenderCount => _offscreenWorldRenderCount;

  /// Most recent sub-pixel stabilization offset (in viewport logical pixels)
  /// applied by [pixelSnapMode].
  @visibleForTesting
  ui.Offset get lastPixelSnapDelta => _lastPixelSnapDelta;

  /// Number of tiles rendered during the most recent [renderHighResImageSync]
  /// or [renderHighResImage] call.
  @visibleForTesting
  int get lastHighResTileCount => _lastHighResTileCount;

  /// Synchronizes auto-DPR [PostProcess] attachments with live
  /// [effectiveDevicePixelRatio] and [effectiveWorldRenderScale].
  @internal
  void syncAutoDevicePixelRatio() {
    if (!hasChildren) {
      return;
    }
    final postProcessors = children.query<PostProcessComponent>();
    if (postProcessors.isEmpty) {
      return;
    }
    final targetRatio = (effectiveDevicePixelRatio * effectiveWorldRenderScale)
        .clamp(0.25, 4.0);
    for (final comp in postProcessors) {
      comp.postProcess.syncDevicePixelRatio(targetRatio);
    }
  }

  void _renderScaledOrDirectWorld(ui.Canvas canvas) {
    final scale = effectiveWorldRenderScale;
    final vSize = viewport.virtualSize;
    if ((scale - 1.0).abs() <= 1e-3 || vSize.x <= 0.0 || vSize.y <= 0.0) {
      _lastWorldSurfaceWidth = 0;
      _lastWorldSurfaceHeight = 0;
      _renderWorld(canvas);
      return;
    }

    final dpr = effectiveDevicePixelRatio;
    final maxDim = math.max(16, maxRenderTextureDimension);
    final surfW = math.min(maxDim, math.max(1, (vSize.x * dpr * scale).ceil()));
    final surfH = math.min(maxDim, math.max(1, (vSize.y * dpr * scale).ceil()));
    _lastWorldSurfaceWidth = surfW;
    _lastWorldSurfaceHeight = surfH;
    _offscreenWorldRenderCount++;

    final recorder = ui.PictureRecorder();
    final innerCanvas = TelemetryCanvas.wrapOffscreenIfActive(
      ui.Canvas(
        recorder,
        ui.Rect.fromLTWH(0, 0, surfW.toDouble(), surfH.toDouble()),
      ),
    )..scale(surfW / vSize.x, surfH / vSize.y);

    _renderWorld(innerCanvas);
    final picture = recorder.endRecording();
    ui.Image? image;
    try {
      image = picture.toImageSync(surfW, surfH);
      final dstRect = ui.Rect.fromLTWH(0.0, 0.0, vSize.x, vSize.y);
      final customShader = upscaleShader;
      if (customShader != null) {
        customShader
          ..setFloat(0, vSize.x)
          ..setFloat(1, vSize.y)
          ..setFloat(2, upscaleSharpness.clamp(0.0, 1.0))
          ..setImageSampler(0, image);
        _upscalePaint
          ..shader = customShader
          ..colorFilter = null;
        canvas.drawRect(dstRect, _upscalePaint);
        _upscalePaint.shader = null;
      } else {
        final srcRect = ui.Rect.fromLTWH(
          0.0,
          0.0,
          surfW.toDouble(),
          surfH.toDouble(),
        );
        final sharp = upscaleSharpness.clamp(0.0, 1.0);
        if (sharp > 1e-3) {
          ContrastAdaptiveSharpenHelper.drawSharpenedImageRect(
            canvas,
            image,
            srcRect,
            dstRect,
            strength: sharp,
            filterQuality: upscaleFilterQuality,
          );
        } else {
          _upscalePaint
            ..shader = null
            ..colorFilter = null
            ..filterQuality = upscaleFilterQuality;
          canvas.drawImageRect(image, srcRect, dstRect, _upscalePaint);
        }
      }
    } finally {
      image?.dispose();
      picture.dispose();
    }
  }

  /// Optional ordered list of [RenderPass]es executed each time this camera
  /// renders its [world]. When `null` or empty, the world is rendered in a
  /// single standard pass.
  List<RenderPass>? renderPasses;

  /// Optional 3D ray projector enabling [SpatialHitbox3D] components inside
  /// [world] to be picked and sorted by camera ray distance `t` during
  /// [componentsAtLocation].
  CameraRayProjector3D? rayProjector3D;

  int _lastFrameCulledCount = 0;
  int _lastFrameVisibleCount = 0;

  /// Number of `CullWhenOffscreen` components skipped by this camera on its
  /// most recent [renderTree] pass.
  int get lastFrameCulledCount => _lastFrameCulledCount;

  /// Number of `CullWhenOffscreen` components accepted as visible by this
  /// camera on its most recent [renderTree] pass.
  int get lastFrameVisibleCount => _lastFrameVisibleCount;

  /// Internal telemetry hook invoked by `CullWhenOffscreen`.
  @internal
  void recordCullDecision({required bool culled}) {
    if (culled) {
      _lastFrameCulledCount++;
    } else {
      _lastFrameVisibleCount++;
    }
  }

  /// Internal bulk telemetry hook invoked by `WorldSpatialIndex`.
  @internal
  void recordCullDecisionsBulk({required int visible, required int culled}) {
    if (visible > 0) {
      _lastFrameVisibleCount += visible;
    }
    if (culled > 0) {
      _lastFrameCulledCount += culled;
    }
  }

  static final List<RenderPass?> _renderPassStack = [];

  /// Currently executing [RenderPass], or `null` during single-pass rendering.
  static RenderPass? get currentRenderPass =>
      _renderPassStack.isEmpty ? null : _renderPassStack.last;

  /// Pushes a [RenderPass] onto the active pass stack (used by multi-pass
  /// cameras and auxiliary post-process passes).
  @internal
  static void pushRenderPass(RenderPass? pass) => _renderPassStack.add(pass);

  /// Pops the most recently pushed [RenderPass] from the active pass stack.
  @internal
  static void popRenderPass() => _renderPassStack.removeLast();

  /// Renders the world and the viewfinder elements through the camera
  /// transform. An instance method rather than a local function, so that the
  /// render pass does not allocate a closure per camera per frame.
  void _renderWorld(Canvas canvas) {
    final hasShake = viewfinder.hasActiveShake;
    var hasPixelSnap = false;
    if (pixelSnapMode != PixelSnapMode.none && viewfinder.angle == 0.0) {
      final step = pixelSnapMode == PixelSnapMode.physicalPixel
          ? 1.0 / math.max(0.25, effectiveDevicePixelRatio)
          : 1.0;
      final z = viewfinder.zoom;
      final tx =
          viewfinder.transform.position.x + viewfinder.transform.offset.x * z;
      final ty =
          viewfinder.transform.position.y + viewfinder.transform.offset.y * z;
      final snapX = (tx / step).roundToDouble() * step - tx;
      final snapY = (ty / step).roundToDouble() * step - ty;
      _lastPixelSnapDelta = ui.Offset(snapX, snapY);
      if (snapX.abs() > 1e-6 || snapY.abs() > 1e-6) {
        hasPixelSnap = true;
      }
    } else {
      _lastPixelSnapDelta = ui.Offset.zero;
    }

    if (hasShake || hasPixelSnap) {
      canvas.save();
      if (hasPixelSnap) {
        canvas.translate(_lastPixelSnapDelta.dx, _lastPixelSnapDelta.dy);
      }
      if (hasShake) {
        final pivX = viewfinder.transform.position.x;
        final pivY = viewfinder.transform.position.y;
        canvas.translate(
          pivX + viewfinder.shakeOffset.x,
          pivY + viewfinder.shakeOffset.y,
        );
        if (viewfinder.shakeRoll != 0.0) {
          canvas.rotate(viewfinder.shakeRoll);
        }
        canvas.translate(-pivX, -pivY);
      }
    }
    try {
      canvas.transform2D(viewfinder.transform);
      final activeWorld = world!;
      final overridePass = currentRenderPass;
      final passes = renderPasses;
      if (overridePass != null) {
        activeWorld.onBeforeRenderPass(canvas, overridePass);
        activeWorld.beforePassCallback?.call(canvas, overridePass);
        activeWorld.renderFromCamera(canvas);
        activeWorld.afterPassCallback?.call(canvas, overridePass);
        activeWorld.onAfterRenderPass(canvas, overridePass);
      } else if (passes == null || passes.isEmpty) {
        activeWorld.renderFromCamera(canvas);
      } else {
        for (final pass in passes) {
          pushRenderPass(pass);
          try {
            activeWorld.onBeforeRenderPass(canvas, pass);
            activeWorld.beforePassCallback?.call(canvas, pass);
            activeWorld.renderFromCamera(canvas);
            activeWorld.afterPassCallback?.call(canvas, pass);
            activeWorld.onAfterRenderPass(canvas, pass);
          } finally {
            popRenderPass();
          }
        }
      }
      // Render the viewfinder elements, which will be in front of the world,
      // but with the same transforms applied to them.
      if (overridePass == null || !overridePass.exclusiveToMultiPass) {
        viewfinder.renderTree(canvas);
      }
    } finally {
      if (hasShake || hasPixelSnap) {
        canvas.restore();
      }
    }
  }

  static final Vector2 _zoomBeforeScratch = Vector2.zero();
  static final Vector2 _zoomAfterScratch = Vector2.zero();

  /// Zooms the [viewfinder] to [newZoom] (clamped to `[minZoom..maxZoom]`)
  /// while keeping the world point currently underneath [viewportPoint]
  /// (expressed in viewport virtual coordinates, or converted from canvas
  /// coordinates via `viewport.globalToLocal`) anchored at the exact same
  /// screen pixel.
  void zoomAtViewportPoint(
    Vector2 viewportPoint,
    double newZoom, {
    double minZoom = 0.05,
    double maxZoom = 64.0,
  }) {
    final clampedZoom = newZoom.clamp(minZoom, maxZoom);
    if ((viewfinder.zoom - clampedZoom).abs() < 1e-9) {
      return;
    }
    viewfinder.globalToLocal(viewportPoint, output: _zoomBeforeScratch);
    viewfinder.zoom = clampedZoom;
    viewfinder.globalToLocal(viewportPoint, output: _zoomAfterScratch);
    viewfinder.setPositionValues(
      viewfinder.position.x + (_zoomBeforeScratch.x - _zoomAfterScratch.x),
      viewfinder.position.y + (_zoomBeforeScratch.y - _zoomAfterScratch.y),
    );
  }

  /// Convenience wrapper around [zoomAtViewportPoint] taking [canvasPoint] in
  /// root game canvas coordinates.
  void zoomAtCanvasPoint(
    Vector2 canvasPoint,
    double newZoom, {
    double minZoom = 0.05,
    double maxZoom = 64.0,
  }) {
    final vp = Vector2(
      canvasPoint.x -
          (viewport.position.x - viewport.anchor.x * viewport.size.x),
      canvasPoint.y -
          (viewport.position.y - viewport.anchor.y * viewport.size.y),
    );
    viewport.globalToLocal(vp, output: vp);
    zoomAtViewportPoint(vp, newZoom, minZoom: minZoom, maxZoom: maxZoom);
  }

  // Not a setter: this is passed as a `ValueSetter` tear-off to
  // `PostProcess.render`.
  // ignore: use_setters_to_change_properties
  void _updatePostProcessContext(PostProcess? context) {
    renderContext.currentPostProcess = context;
  }

  /// Converts from the global (canvas) coordinate space to
  /// local (camera = viewport + viewfinder).
  ///
  /// Opposite of [localToGlobal].
  Vector2 globalToLocal(Vector2 point, {Vector2? output}) {
    final viewportPosition = viewport.globalToLocal(point, output: output);
    return viewfinder.globalToLocal(viewportPosition, output: output);
  }

  /// Converts from the local (camera = viewport + viewfinder) coordinate space
  /// to global (canvas).
  ///
  /// Opposite of [globalToLocal].
  Vector2 localToGlobal(Vector2 position, {Vector2? output}) {
    final viewfinderPosition = viewfinder.localToGlobal(
      position,
      output: output,
    );
    return viewport.localToGlobal(viewfinderPosition, output: output);
  }

  @override
  Iterable<Component> componentsAtLocation<T>(
    T locationContext,
    List<T>? nestedContexts,
    T? Function(CoordinateTransform, T) transformContext,
    bool Function(Component, T) checkContains,
  ) sync* {
    final viewportPoint = transformContext(viewport, locationContext);
    if (viewportPoint == null) {
      return;
    }

    yield* viewport.componentsAtLocation(
      viewportPoint,
      nestedContexts,
      transformContext,
      checkContains,
    );
    if ((world?.isMounted ?? false) &&
        currentCameras.length < maxCamerasDepth) {
      if (checkContains(viewport, viewportPoint)) {
        final worldPoint = transformContext(viewfinder, viewportPoint);
        if (worldPoint == null) {
          return;
        }
        yield* _onCameraStack(
          viewfinder.componentsAtLocation(
            worldPoint,
            nestedContexts,
            transformContext,
            checkContains,
          ),
        );
        final projector = rayProjector3D;
        if (projector != null) {
          Vector2? vpPt;
          Vector2? wdPt;
          if (viewportPoint is Vector2 && worldPoint is Vector2) {
            vpPt = viewportPoint;
            wdPt = worldPoint;
          } else if (viewportPoint is ({Vector2 start, Vector2 end}) &&
              worldPoint is ({Vector2 start, Vector2 end})) {
            vpPt = viewportPoint.end;
            wdPt = worldPoint.end;
          }
          if (vpPt != null && wdPt != null) {
            final ray = projector(vpPt, wdPt);
            if (ray != null) {
              yield* _onCameraStack(
                _worldComponentsWithSpatialRay(
                  ray,
                  worldPoint,
                  nestedContexts,
                  transformContext,
                  checkContains,
                ),
              );
              return;
            }
          }
        }
        yield* _onCameraStack(
          world!.componentsAtLocation(
            worldPoint,
            nestedContexts,
            transformContext,
            checkContains,
          ),
        );
      }
    }
  }

  int _lastSpatialRayCandidatesTested = 0;
  int _lastSpatialRayNarrowphaseTests = 0;

  /// Number of registered [SpatialHitbox3D] candidates inspected during the
  /// most recent 3D camera ray pick (`O(k)` instead of walking all non-3D world
  /// components).
  int get lastSpatialRayCandidatesTested => _lastSpatialRayCandidatesTested;

  /// Number of [SpatialHitbox3D.intersectRay3D] narrowphase calls executed
  /// during the most recent 3D camera ray pick after bounding-sphere pruning.
  int get lastSpatialRayNarrowphaseTests => _lastSpatialRayNarrowphaseTests;

  static int _compareTreeRenderOrder(
    Component a,
    Component b,
    World root,
  ) {
    if (identical(a, b)) {
      return 0;
    }
    final chainA = <Component>[];
    Component? curA = a;
    while (curA != null && !identical(curA, root)) {
      chainA.add(curA);
      curA = curA.parent;
    }
    final chainB = <Component>[];
    Component? curB = b;
    while (curB != null && !identical(curB, root)) {
      chainB.add(curB);
      curB = curB.parent;
    }
    var idxA = chainA.length - 1;
    var idxB = chainB.length - 1;
    while (idxA >= 0 && idxB >= 0 && identical(chainA[idxA], chainB[idxB])) {
      idxA--;
      idxB--;
    }
    if (idxA < 0) {
      return -1;
    }
    if (idxB < 0) {
      return 1;
    }
    final branchA = chainA[idxA];
    final branchB = chainB[idxB];
    final priCmp = branchA.priority.compareTo(branchB.priority);
    if (priCmp != 0) {
      return priCmp;
    }
    final sortCmp = branchA.sortKey.compareTo(branchB.sortKey);
    if (sortCmp != 0) {
      return sortCmp;
    }
    final parent = branchA.parent;
    if (parent != null) {
      var posA = -1;
      var posB = -1;
      var k = 0;
      for (final c in parent.children) {
        if (identical(c, branchA)) {
          posA = k;
        } else if (identical(c, branchB)) {
          posB = k;
        }
        if (posA >= 0 && posB >= 0) {
          break;
        }
        k++;
      }
      return posA.compareTo(posB);
    }
    return 0;
  }

  Iterable<Component> _worldComponentsWithSpatialRay<T>(
    Ray3D ray,
    T worldPoint,
    List<T>? nestedContexts,
    T? Function(CoordinateTransform, T) transformContext,
    bool Function(Component, T) checkContains,
  ) sync* {
    final activeWorld = world!;
    if (activeWorld is IgnoreEvents &&
        (activeWorld as IgnoreEvents).ignoreEvents) {
      _lastSpatialRayCandidatesTested = 0;
      _lastSpatialRayNarrowphaseTests = 0;
      return;
    }

    final spatialHits =
        <({SpatialHitbox3D component, double distance, int order})>[];
    final registered = activeWorld.spatialHitboxes3D;
    var candidatesTested = 0;
    var narrowphaseTests = 0;

    for (var i = 0; i < registered.length; i++) {
      final child = registered[i];
      if (!child.spatialHitEnabled ||
          !child.isMounted ||
          child.isRemoving ||
          !child.isActiveForCurrentGraphicsTier) {
        continue;
      }

      var blockedByAncestor = false;
      Component? cursor = child;
      while (cursor != null && !identical(cursor, activeWorld)) {
        if ((cursor.cameraMask & cameraMask) == 0 ||
            (cursor is IgnoreEvents && cursor.ignoreEvents) ||
            !cursor.isActiveForCurrentGraphicsTier ||
            (cursor is HasVisibility && !cursor.isVisible)) {
          blockedByAncestor = true;
          break;
        }
        cursor = cursor.parent;
      }
      if (blockedByAncestor || !identical(cursor, activeWorld)) {
        continue;
      }

      candidatesTested++;
      final sphere = child.boundingSphere3D;
      if (sphere != null) {
        final (cx, cy, cz, radius) = sphere;
        if (Raycaster3D.intersectSphereDistance(
              ray,
              cx: cx,
              cy: cy,
              cz: cz,
              radius: radius,
            ) ==
            null) {
          continue;
        }
      }

      narrowphaseTests++;
      final hitT = child.intersectRay3D(ray);
      if (hitT != null && hitT.isFinite && hitT >= 0.0) {
        child.recordSpatialHit3D(ray, hitT);
        spatialHits.add((
          component: child,
          distance: hitT,
          order: i,
        ));
      }
    }

    _lastSpatialRayCandidatesTested = candidatesTested;
    _lastSpatialRayNarrowphaseTests = narrowphaseTests;

    final yieldedSpatial = <Component>{};
    if (spatialHits.isNotEmpty) {
      spatialHits.sort((a, b) {
        final cmp = a.distance.compareTo(b.distance);
        if (cmp != 0) {
          return cmp;
        }
        final treeCmp = _compareTreeRenderOrder(
          b.component,
          a.component,
          activeWorld,
        );
        return treeCmp != 0 ? treeCmp : b.order.compareTo(a.order);
      });

      final chain = <Component>[];
      for (final hit in spatialHits) {
        chain.clear();
        Component? cursor = hit.component;
        while (cursor != null && !identical(cursor, activeWorld)) {
          chain.add(cursor);
          cursor = cursor.parent;
        }
        if (!identical(cursor, activeWorld)) {
          continue;
        }

        final savedLength = nestedContexts?.length ?? 0;
        nestedContexts?.add(worldPoint);
        var currentCtx = worldPoint;
        var validTransform = true;
        for (var i = chain.length - 1; i >= 0; i--) {
          final node = chain[i];
          if (node is CoordinateTransform) {
            final next = transformContext(
              node as CoordinateTransform,
              currentCtx,
            );
            if (next == null) {
              validTransform = false;
              break;
            }
            currentCtx = next;
          }
          nestedContexts?.add(currentCtx);
        }

        if (validTransform) {
          yieldedSpatial.add(hit.component);
          hit.component.isActiveSpatialRayHit = true;
          try {
            yield hit.component;
          } finally {
            hit.component.isActiveSpatialRayHit = false;
          }
        }
        if (nestedContexts != null && nestedContexts.length > savedLength) {
          nestedContexts.removeRange(savedLength, nestedContexts.length);
        }
      }
    }

    for (final comp in activeWorld.componentsAtLocation(
      worldPoint,
      nestedContexts,
      transformContext,
      checkContains,
    )) {
      if (!yieldedSpatial.contains(comp)) {
        yield comp;
      }
    }
  }

  /// Iterates [components] with this camera pushed onto [currentCameras], so
  /// that a camera nested within the world still sees the correct depth.
  ///
  /// The camera is pushed and popped around every step rather than around the
  /// whole iteration. This is a lazy iterable, so the caller is free to stop
  /// early, for example by breaking out of a loop over [componentsAtPoint] as
  /// soon as the tapped component is found. That leaves the generator
  /// suspended at a `yield`, and the code after it never runs. Popping there
  /// would therefore be skipped, and since [currentCameras] is static the
  /// entry would be leaked for the rest of the process; after
  /// [maxCamerasDepth] such leaks no camera renders its world any more.
  Iterable<Component> _onCameraStack(Iterable<Component> components) sync* {
    final iterator = components.iterator;
    while (true) {
      currentCameras.add(this);
      final bool hasNext;
      try {
        hasNext = iterator.moveNext();
      } finally {
        currentCameras.removeLast();
      }
      if (!hasNext) {
        return;
      }
      yield iterator.current;
    }
  }

  /// A camera that currently performs rendering.
  ///
  /// This variable is set to `this` when we begin rendering the world through
  /// this particular camera, and reset back to `null` at the end. This variable
  /// is not set when rendering components that are attached to the viewport.
  static CameraComponent? get currentCamera {
    return currentCameras.isEmpty ? null : currentCameras.last;
  }

  /// Stack of all current cameras in the render tree.
  static final List<CameraComponent> currentCameras = [];

  /// Maximum number of nested cameras that will be rendered.
  ///
  /// This variable helps prevent infinite recursion when a camera is set to
  /// look at the world that contains that camera.
  static int maxCamerasDepth = 4;

  /// Makes the [viewfinder] follow the given [target].
  ///
  /// The [target] here can be any read-only [PositionProvider]. For example, a
  /// [PositionComponent] is the most common choice of target. Alternatively,
  /// you can use [PositionProviderImpl] to construct the target dynamically.
  ///
  /// This method adds a [FollowBehavior] to the viewfinder. If there is another
  /// [FollowBehavior] currently applied to the viewfinder, it will be removed
  /// first.
  ///
  /// Parameters [maxSpeed], [horizontalOnly] and [verticalOnly] have the same
  /// meaning as in the [FollowBehavior.new] constructor.
  ///
  /// If [snap] is true, then the viewfinder's starting position will be set to
  /// the target's current location. If [snap] is false, then the viewfinder
  /// will move from its current position to the target's position at the given
  /// speed.
  void follow(
    ReadOnlyPositionProvider target, {
    double maxSpeed = double.infinity,
    double? smoothing,
    Rect? deadzone,
    double leadFactor = 0.0,
    double maxLeadDistance = 240.0,
    bool horizontalOnly = false,
    bool verticalOnly = false,
    bool snap = false,
  }) {
    stop();
    viewfinder.add(
      FollowBehavior(
        target: target,
        owner: viewfinder,
        maxSpeed: maxSpeed,
        smoothing: smoothing,
        deadzone: deadzone,
        leadFactor: leadFactor,
        maxLeadDistance: maxLeadDistance,
        horizontalOnly: horizontalOnly,
        verticalOnly: verticalOnly,
      ),
    );
    if (snap) {
      viewfinder.position = target.position;
    }
  }

  /// Removes all movement effects or behaviors from the viewfinder.
  void stop() {
    viewfinder.children.toList().forEach((child) {
      if (child is FollowBehavior || child is MoveEffect) {
        child.removeFromParent();
      }
    });
  }

  /// Moves the camera towards the specified world [point].
  void moveTo(Vector2 point, {double speed = double.infinity}) {
    stop();
    viewfinder.add(
      MoveToEffect(point, EffectController(speed: speed)),
    );
  }

  /// Move the camera by the given [offset].
  void moveBy(Vector2 offset, {double speed = double.infinity}) {
    stop();
    viewfinder.add(MoveByEffect(offset, EffectController(speed: speed)));
  }

  /// Sets or clears the world bounds for the camera's viewfinder.
  ///
  /// The bound is a [Shape], given in the world coordinates. The viewfinder's
  /// position will be restricted to always remain inside this region.
  ///
  /// When [considerViewport] is true none of the viewport can go outside
  /// of the bounds, when it is false only the viewfinder anchor is considered.
  /// Note that this option only works with [Rectangle], [RoundedRectangle] and
  /// [Circle] shapes.
  void setBounds(Shape? bounds, {bool considerViewport = false}) {
    final boundedBehavior = viewfinder.firstChild<BoundedPositionBehavior>();
    final viewPortAwareBoundsBehavior = viewfinder
        .firstChild<ViewportAwareBoundsBehavior>();

    if (bounds == null) {
      // When bounds is null, all bounds-related components need to be dropped.
      boundedBehavior?.removeFromParent();
      viewPortAwareBoundsBehavior?.removeFromParent();
      return;
    }

    Future<void>? boundedBehaviorFuture;
    if (boundedBehavior == null) {
      final BoundedPositionBehavior ref;
      viewfinder.add(
        ref = BoundedPositionBehavior(
          bounds: bounds,
          priority: 1000,
        ),
      );

      boundedBehaviorFuture = ref.mounted;
    } else {
      boundedBehavior.bounds = bounds;
    }

    if (!considerViewport) {
      // Edge case: remove pre-existing viewport aware components.
      viewPortAwareBoundsBehavior?.removeFromParent();
      return;
    }

    // Param `considerViewPort` was true and we have a bounds.
    // Add a ViewportAwareBoundsBehavior component with
    // our desired bounds shape or update the boundsShape if the
    // component already exists.
    if (viewPortAwareBoundsBehavior == null) {
      switch (boundedBehaviorFuture) {
        case null:
          // This represents the case when BoundedPositionBehavior was mounted
          // earlier in another cycle. This allows us to immediately add the
          // ViewportAwareBoundsBehavior component which will subsequently adapt
          // the camera to the virtual resolution this frame.
          _addViewPortAwareBoundsBehavior(bounds);
        case _:
          // This represents the case when BoundedPositionBehavior was added
          // in this exact cycle but did not mount into the tree.
          // We must wait for that component to mount first in order for
          // ViewportAwareBoundsBehavior to correctly affect the camera.
          boundedBehaviorFuture.whenComplete(
            () => _addViewPortAwareBoundsBehavior(bounds),
          );
      }
    } else {
      viewPortAwareBoundsBehavior.boundsShape = bounds;
    }
  }

  void _addViewPortAwareBoundsBehavior(Shape bounds) {
    viewfinder.add(
      ViewportAwareBoundsBehavior(
        boundsShape: bounds,
      ),
    );
  }

  /// Returns true if this camera is able to see the [component].
  /// Will always return false if
  /// - [world] is null or
  /// - [world] is not mounted or
  /// - [component] is not mounted or
  /// - [componentWorld] is non-null and does not match with [world]
  ///
  /// If [componentWorld] is null, this method does not take into consideration
  /// the world to which the given [component] belongs (if any). This means, in
  /// such cases, any component overlapping the [visibleWorldRect] will be
  /// reported as visible, even if it is not part of the [world] this camera is
  /// currently looking at. This can be changed by passing the component's
  /// world as [componentWorld].
  bool canSee(PositionComponent component, {World? componentWorld}) {
    if (!(world?.isMounted ?? false) ||
        !component.isMounted ||
        (componentWorld != null && componentWorld != world)) {
      return false;
    }

    return visibleWorldRect.overlaps(component.toAbsoluteRect());
  }

  @override
  final CameraRenderContext renderContext = CameraRenderContext();

  /// A [PostProcess] that is applied to the world of a camera.
  ///
  /// Do note that only one [postProcess] can be active on the camera at once.
  /// If the [postProcess] is set to null, the previous post process will
  /// be removed.
  /// If the [postProcess] is set to not null, it will be added to the camera,
  /// and any previously active post process will be removed.
  ///
  /// See also:
  /// - [PostProcess] for the base class for post processes and more information
  /// about how to create them.
  /// - [PostProcessComponent] for a component that can be used to apply a
  /// post process to a specific component.
  PostProcess? get postProcess =>
      children.query<PostProcessComponent>().firstOrNull?.postProcess;
  set postProcess(PostProcess? postProcess) {
    final postProcessComponents = children
        .query<PostProcessComponent>()
        .toList();
    final queuedPostProcessAdds = findGame()?.queue
        .where(
          (event) =>
              event.kind == LifecycleEventKind.add &&
              event.child is PostProcessComponent,
        )
        .map((event) => event.child!);
    removeAll([...postProcessComponents, ...?queuedPostProcessAdds]);
    if (postProcess != null) {
      add(PostProcessComponent(postProcess: postProcess));
    }
  }

  ({ui.Picture picture, int width, int height}) _recordViewToPicture({
    int? width,
    int? height,
    double pixelRatio = 1.0,
    bool includePostProcess = true,
    bool includeBackdrop = true,
    bool includeViewport = false,
    List<RenderPass>? passes,
    ui.Color? backgroundColor,
  }) {
    assert(pixelRatio > 0, 'pixelRatio must be positive: $pixelRatio');
    final vSize = viewport.virtualSize;
    final fallbackSize = viewport.size;
    final baseW = vSize.x > 0
        ? vSize.x
        : (fallbackSize.x > 0 ? fallbackSize.x : (width?.toDouble() ?? 1.0));
    final baseH = vSize.y > 0
        ? vSize.y
        : (fallbackSize.y > 0 ? fallbackSize.y : (height?.toDouble() ?? 1.0));
    final outW = math.max(1, width ?? (baseW * pixelRatio).round());
    final outH = math.max(1, height ?? (baseH * pixelRatio).round());

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(
      recorder,
      ui.Rect.fromLTWH(0, 0, outW.toDouble(), outH.toDouble()),
    );
    final logicalBounds = ui.Rect.fromLTWH(0, 0, baseW, baseH);
    canvas.scale(outW / baseW, outH / baseH);
    canvas.clipRect(logicalBounds);
    if (backgroundColor != null) {
      canvas.drawRect(logicalBounds, ui.Paint()..color = backgroundColor);
    }

    if ((world?.isMounted ?? false) &&
        currentCameras.length < maxCamerasDepth) {
      if (includeBackdrop) {
        backdrop.renderTree(canvas);
      }
      final prevPasses = renderPasses;
      if (passes != null) {
        renderPasses = passes;
      }
      currentCameras.add(this);
      try {
        final postProcessors = includePostProcess
            ? children.query<PostProcessComponent>()
            : const <PostProcessComponent>[];
        if (postProcessors.isNotEmpty) {
          postProcessors.first.postProcess.render(
            canvas,
            Vector2(baseW, baseH),
            _renderWorld,
            _updatePostProcessContext,
          );
        } else {
          canvas.save();
          _renderWorld(canvas);
          canvas.restore();
        }
      } finally {
        currentCameras.removeLast();
        renderPasses = prevPasses;
      }
      if (includeViewport) {
        viewport.renderTree(canvas);
      }
    }

    return (
      picture: recorder.endRecording(),
      width: outW,
      height: outH,
    );
  }

  /// Renders this camera's current view into an offscreen [ui.Image]
  /// synchronously without modifying the live screen canvas.
  ///
  /// When [width] or [height] are omitted, `viewport.virtualSize` (falling back
  /// to `viewport.size`) scaled by [pixelRatio] is used. Callers own the
  /// returned [ui.Image] and must call `dispose()` on it when finished.
  ui.Image renderToImageSync({
    int? width,
    int? height,
    double pixelRatio = 1.0,
    bool includePostProcess = true,
    bool includeBackdrop = true,
    bool includeViewport = false,
    List<RenderPass>? passes,
    ui.Color? backgroundColor,
  }) {
    final recorded = _recordViewToPicture(
      width: width,
      height: height,
      pixelRatio: pixelRatio,
      includePostProcess: includePostProcess,
      includeBackdrop: includeBackdrop,
      includeViewport: includeViewport,
      passes: passes,
      backgroundColor: backgroundColor,
    );
    try {
      return recorded.picture.toImageSync(recorded.width, recorded.height);
    } finally {
      recorded.picture.dispose();
    }
  }

  /// Asynchronously rasterizes this camera's current view into an offscreen
  /// [ui.Image] without modifying the live screen canvas.
  ///
  /// Callers own the returned [ui.Image] and must call `dispose()` on it when
  /// finished.
  Future<ui.Image> renderToImage({
    int? width,
    int? height,
    double pixelRatio = 1.0,
    bool includePostProcess = true,
    bool includeBackdrop = true,
    bool includeViewport = false,
    List<RenderPass>? passes,
    ui.Color? backgroundColor,
  }) async {
    final recorded = _recordViewToPicture(
      width: width,
      height: height,
      pixelRatio: pixelRatio,
      includePostProcess: includePostProcess,
      includeBackdrop: includeBackdrop,
      includeViewport: includeViewport,
      passes: passes,
      backgroundColor: backgroundColor,
    );
    try {
      return await recorded.picture.toImage(recorded.width, recorded.height);
    } finally {
      recorded.picture.dispose();
    }
  }

  ({ui.Picture picture, List<ui.Image> tiles}) _recordTiledHighResComposite({
    required int width,
    required int height,
    int tileSize = 2048,
    double supersample = 1.0,
    bool includeBackdrop = true,
    bool includeViewport = false,
    List<RenderPass>? passes,
    ui.Color? backgroundColor,
  }) {
    assert(width > 0 && height > 0, 'Dimensions must be positive');
    assert(tileSize >= 64, 'tileSize must be >= 64: $tileSize');
    final ssaa = supersample.clamp(1.0, 4.0);
    final vSize = viewport.virtualSize;
    final fallbackSize = viewport.size;
    final baseW = vSize.x > 0
        ? vSize.x
        : (fallbackSize.x > 0 ? fallbackSize.x : width.toDouble());
    final baseH = vSize.y > 0
        ? vSize.y
        : (fallbackSize.y > 0 ? fallbackSize.y : height.toDouble());

    final masterRecorder = ui.PictureRecorder();
    final masterCanvas = ui.Canvas(
      masterRecorder,
      ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    );
    final tilePaint = ui.Paint()..filterQuality = ui.FilterQuality.medium;
    final tileImages = <ui.Image>[];

    final prevPasses = renderPasses;
    if (passes != null) {
      renderPasses = passes;
    }

    try {
      var tilesRendered = 0;
      for (var outY = 0; outY < height; outY += tileSize) {
        final tileOutH = math.min(tileSize, height - outY);
        final logY = outY * (baseH / height);
        final logH = tileOutH * (baseH / height);

        for (var outX = 0; outX < width; outX += tileSize) {
          final tileOutW = math.min(tileSize, width - outX);
          final logX = outX * (baseW / width);
          final logW = tileOutW * (baseW / width);

          final tileRenW = math.max(1, (tileOutW * ssaa).round());
          final tileRenH = math.max(1, (tileOutH * ssaa).round());

          final tileRec = ui.PictureRecorder();
          final tileCanvas = ui.Canvas(
            tileRec,
            ui.Rect.fromLTWH(0, 0, tileRenW.toDouble(), tileRenH.toDouble()),
          );
          final tileLogBounds = ui.Rect.fromLTWH(logX, logY, logW, logH);
          tileCanvas
            ..scale(tileRenW / logW, tileRenH / logH)
            ..translate(-logX, -logY)
            ..clipRect(tileLogBounds);

          if (backgroundColor != null) {
            tileCanvas.drawRect(
              tileLogBounds,
              ui.Paint()..color = backgroundColor,
            );
          }

          if ((world?.isMounted ?? false) &&
              currentCameras.length < maxCamerasDepth) {
            if (includeBackdrop) {
              backdrop.renderTree(tileCanvas);
            }
            currentCameras.add(this);
            try {
              tileCanvas.save();
              _renderWorld(tileCanvas);
              tileCanvas.restore();
            } finally {
              currentCameras.removeLast();
            }
            if (includeViewport) {
              viewport.renderTree(tileCanvas);
            }
          }

          final tilePic = tileRec.endRecording();
          final ui.Image tileImg;
          try {
            tileImg = tilePic.toImageSync(tileRenW, tileRenH);
          } finally {
            tilePic.dispose();
          }
          tileImages.add(tileImg);
          tilesRendered++;

          masterCanvas.drawImageRect(
            tileImg,
            ui.Rect.fromLTWH(
              0,
              0,
              tileRenW.toDouble(),
              tileRenH.toDouble(),
            ),
            ui.Rect.fromLTWH(
              outX.toDouble(),
              outY.toDouble(),
              tileOutW.toDouble(),
              tileOutH.toDouble(),
            ),
            tilePaint,
          );
        }
      }
      _lastHighResTileCount = tilesRendered;
    } catch (_) {
      for (final img in tileImages) {
        img.dispose();
      }
      rethrow;
    } finally {
      renderPasses = prevPasses;
    }

    return (picture: masterRecorder.endRecording(), tiles: tileImages);
  }

  /// Synchronously exports an ultra-high-resolution (`4K / 8K`) [ui.Image] in
  /// [tileSize] × [tileSize] sub-frustum tiles with optional [supersample]
  /// (`1.0 .. 4.0` SSAA), avoiding monolithic intermediate textures.
  ///
  /// Callers own the returned [ui.Image] and must call `dispose()` when done.
  ui.Image renderHighResImageSync({
    required int width,
    required int height,
    int tileSize = 2048,
    double supersample = 1.0,
    bool includeBackdrop = true,
    bool includeViewport = false,
    List<RenderPass>? passes,
    ui.Color? backgroundColor,
  }) {
    final composite = _recordTiledHighResComposite(
      width: width,
      height: height,
      tileSize: tileSize,
      supersample: supersample,
      includeBackdrop: includeBackdrop,
      includeViewport: includeViewport,
      passes: passes,
      backgroundColor: backgroundColor,
    );
    try {
      return composite.picture.toImageSync(width, height);
    } finally {
      composite.picture.dispose();
      for (final tile in composite.tiles) {
        tile.dispose();
      }
    }
  }

  /// Asynchronously exports an ultra-high-resolution (`4K / 8K`) [ui.Image] in
  /// [tileSize] × [tileSize] sub-frustum tiles with optional [supersample]
  /// (`1.0 .. 4.0` SSAA).
  ///
  /// Callers own the returned [ui.Image] and must call `dispose()` when done.
  Future<ui.Image> renderHighResImage({
    required int width,
    required int height,
    int tileSize = 2048,
    double supersample = 1.0,
    bool includeBackdrop = true,
    bool includeViewport = false,
    List<RenderPass>? passes,
    ui.Color? backgroundColor,
  }) async {
    final composite = _recordTiledHighResComposite(
      width: width,
      height: height,
      tileSize: tileSize,
      supersample: supersample,
      includeBackdrop: includeBackdrop,
      includeViewport: includeViewport,
      passes: passes,
      backgroundColor: backgroundColor,
    );
    try {
      return await composite.picture.toImage(width, height);
    } finally {
      composite.picture.dispose();
      for (final tile in composite.tiles) {
        tile.dispose();
      }
    }
  }

  SceneTransition? _activeTransition;
  ui.Image? _transitionSnapshot;
  double _transitionElapsed = 0.0;
  Completer<void>? _transitionCompleter;

  /// Whether a visual [SceneTransition] is currently active on this camera.
  bool get hasActiveSceneTransition => _activeTransition != null;

  /// Normalized `[0.0 .. 1.0]` curved progress of the active [SceneTransition],
  /// or `1.0` when no transition is running.
  double get sceneTransitionProgress {
    final active = _activeTransition;
    if (active == null || active.duration <= 0) {
      return 1.0;
    }
    final raw = (_transitionElapsed / active.duration).clamp(0.0, 1.0);
    return active.curve.transform(raw).clamp(0.0, 1.0);
  }

  /// Captures the camera's current view synchronously into an offscreen
  /// [ui.Image] and plays [transition] over the live incoming scene for
  /// `transition.duration` seconds, deterministically disposing the GPU image
  /// when finished or cancelled.
  ///
  /// Call this immediately *before* mutating world state (e.g. changing biomes,
  /// swapping levels, or teleporting the camera) to get a seamless visual
  /// cross-fade/iris/shader transition without `saveLayer` overhead.
  Future<void> startSceneTransition(
    SceneTransition transition,
  ) {
    cancelSceneTransition();
    if (transition.duration <= 0 || !(world?.isMounted ?? false)) {
      return Future<void>.value();
    }
    final vSize = viewport.virtualSize;
    final fSize = viewport.size;
    if (vSize.x <= 0 && fSize.x <= 0) {
      return Future<void>.value();
    }
    _transitionSnapshot = renderToImageSync(
      pixelRatio: transition.capturePixelRatio,
      includeViewport: transition.aboveViewportHud,
    );
    _activeTransition = transition;
    _transitionElapsed = 0.0;
    final completer = Completer<void>();
    _transitionCompleter = completer;
    findGame()?.notifyActivity();
    return completer.future;
  }

  /// Captures the outgoing world view, switches to [nextWorld], and plays
  /// [transition] smoothly across `transition.duration` seconds.
  Future<void> transitionToWorld(
    World nextWorld, {
    SceneTransition transition = const CrossFadeSceneTransition(),
  }) {
    final future = startSceneTransition(transition);
    final game = findGame();
    if (game is FlameGame && identical(game.camera, this)) {
      game.world = nextWorld;
    } else {
      world?.removeFromParent();
      world = nextWorld;
      if (nextWorld.parent == null && parent != null) {
        parent!.add(nextWorld);
      }
    }
    return future;
  }

  /// Cancels any active [SceneTransition] and immediately disposes its retained
  /// snapshot [ui.Image].
  void cancelSceneTransition() {
    _transitionSnapshot?.dispose();
    _transitionSnapshot = null;
    _activeTransition = null;
    _transitionElapsed = 0.0;
    final c = _transitionCompleter;
    _transitionCompleter = null;
    if (c != null && !c.isCompleted) {
      c.complete();
    }
  }

  void _renderActiveTransition(ui.Canvas canvas) {
    final transition = _activeTransition;
    final snapshot = _transitionSnapshot;
    if (transition == null || snapshot == null) {
      return;
    }
    final vSize = viewport.virtualSize;
    final fSize = viewport.size;
    final w = vSize.x > 0 ? vSize.x : fSize.x;
    final h = vSize.y > 0 ? vSize.y : fSize.y;
    if (w <= 0 || h <= 0) {
      return;
    }
    transition.renderTransition(
      canvas,
      snapshot,
      ui.Rect.fromLTWH(0, 0, w, h),
      sceneTransitionProgress,
    );
  }

  @override
  void update(double dt) {
    super.update(dt);
    final active = _activeTransition;
    if (active != null) {
      _transitionElapsed += dt;
      findGame()?.notifyActivity();
      if (_transitionElapsed >= active.duration) {
        cancelSceneTransition();
      }
    }
  }

  @override
  void onGameResize(Vector2 size) {
    invalidateLayerCaches();
    super.onGameResize(size);
  }

  @override
  void onRemove() {
    cancelSceneTransition();
    invalidateLayerCaches();
    super.onRemove();
  }
}

class CameraRenderContext() extends ComponentRenderContext {
  PostProcess? currentPostProcess;
}
