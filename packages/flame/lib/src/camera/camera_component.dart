import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flame/components.dart';
import 'package:flame/extensions.dart';
import 'package:flame/post_process.dart';
import 'package:flame/src/camera/behaviors/bounded_position_behavior.dart';
import 'package:flame/src/camera/behaviors/follow_behavior.dart';
import 'package:flame/src/camera/behaviors/viewport_aware_bounds_behavior.dart';
import 'package:flame/src/camera/viewfinder.dart';
import 'package:flame/src/camera/viewport.dart';
import 'package:flame/src/camera/viewports/fixed_resolution_viewport.dart';
import 'package:flame/src/camera/viewports/max_viewport.dart';
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
import 'package:meta/meta.dart';

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
    Iterable<Component>? children,
    ComponentKey? key,
  }) : this(
         world: world,
         viewport: FixedResolutionViewport(resolution: Vector2(width, height)),
         viewfinder: viewfinder ?? Viewfinder(),
         backdrop: backdrop,
         hudComponents: hudComponents,
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
    canvas.save();
    canvas.translate(
      viewport.position.x - viewport.anchor.x * viewport.size.x,
      viewport.position.y - viewport.anchor.y * viewport.size.y,
    );
    // Render the world through the viewport
    if ((world?.isMounted ?? false) &&
        currentCameras.length < maxCamerasDepth) {
      canvas.save();
      viewport.clip(canvas);
      viewport.transformCanvas(canvas);
      backdrop.renderTree(canvas);
      canvas.save();
      try {
        currentCameras.add(this);
        final postProcessors = children.query<PostProcessComponent>();
        if (postProcessors.isNotEmpty) {
          assert(
            postProcessors.length == 1,
            'Only one post process component is allowed per camera.',
          );
          final postProcessor = postProcessors.first.postProcess;
          postProcessor.render(
            canvas,
            viewport.virtualSize,
            _renderWorld,
            _updatePostProcessContext,
          );
        } else {
          _renderWorld(canvas);
        }
      } finally {
        currentCameras.removeLast();
      }
      canvas.restore();
      // Render the viewport elements, which will be in front of the world.
      viewport.renderTree(canvas);
      canvas.restore();
    }
    canvas.restore();
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
    if (hasShake) {
      canvas.save();
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
      if (hasShake) {
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

  Iterable<Component> _worldComponentsWithSpatialRay<T>(
    Ray3D ray,
    T worldPoint,
    List<T>? nestedContexts,
    T? Function(CoordinateTransform, T) transformContext,
    bool Function(Component, T) checkContains,
  ) sync* {
    final activeWorld = world!;
    final spatialHits =
        <({SpatialHitbox3D component, double distance, int order})>[];
    var traversalOrder = 0;

    void collectSpatial(Component parent) {
      if (parent is IgnoreEvents && parent.ignoreEvents) {
        return;
      }
      if (!parent.hasChildren) {
        return;
      }
      for (final child in parent.children) {
        if (child is IgnoreEvents && child.ignoreEvents) {
          continue;
        }
        if (child is SpatialHitbox3D && child.spatialHitEnabled) {
          final hitT = child.intersectRay3D(ray);
          if (hitT != null && hitT.isFinite && hitT >= 0.0) {
            child.recordSpatialHit3D(ray, hitT);
            spatialHits.add((
              component: child,
              distance: hitT,
              order: traversalOrder++,
            ));
          }
        }
        collectSpatial(child);
      }
    }

    collectSpatial(activeWorld);

    final yieldedSpatial = <Component>{};
    if (spatialHits.isNotEmpty) {
      spatialHits.sort((a, b) {
        final cmp = a.distance.compareTo(b.distance);
        return cmp != 0 ? cmp : b.order.compareTo(a.order);
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
    return currentCameras.isEmpty ? null : currentCameras[0];
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
}

class CameraRenderContext() extends ComponentRenderContext {
  PostProcess? currentPostProcess;
}
