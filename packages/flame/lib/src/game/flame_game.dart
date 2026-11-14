import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flame/src/components/core/component.dart';
import 'package:flame/src/devtools/connectors/hot_reload_connector.dart';
import 'package:flame/src/devtools/dev_tools_service.dart';
import 'package:flame/src/effects/provider_interfaces.dart';
import 'package:flame/src/game/frame_budget_scheduler.dart';
import 'package:flame/src/game/game.dart';
import 'package:flame/src/game/graphics_settings.dart';
import 'package:flame/src/game/render_warmup_queue.dart';
import 'package:flame/src/game/scene_resource_budget.dart';
import 'package:flame/src/game/telemetry_canvas.dart';
import 'package:flame/src/game/transform2d.dart';
import 'package:flutter/foundation.dart';
// TODO(spydon): Remove this import when flutter version is updated to 3.35.0
// ignore: unnecessary_import
import 'package:meta/meta.dart';

/// This is a more complete and opinionated implementation of [Game].
///
/// [FlameGame] can be extended to add your game logic, or you can keep the
/// logic in child [Component]s.
///
/// This is the recommended base class to use for most games made with Flame.
/// It is based on the Flame Component System (also known as FCS).
///
/// The type parameter [W] allows you to specify a custom [World] subclass so
/// that the [world] getter returns your specific type without casting. For
/// example:
///
/// ```dart
/// class MyWorld extends World {
///   int score = 0;
/// }
///
/// class MyGame extends FlameGame<MyWorld> {
///   MyGame() : super(world: MyWorld());
/// }
/// ```
///
/// When [W] is specified, a matching world instance **must** be passed to the
/// constructor; otherwise, a runtime assertion error is thrown.
class FlameGame<W extends World>({
  super.children,
  W? world,
  CameraComponent? camera,
}) extends ComponentTreeRoot
    with Game, CustomTraversal
    implements ReadOnlySizeProvider {
  this
    : assert(
        world != null || W == World,
        'The generics type $W does not conform to the type of '
        '${world?.runtimeType ?? 'World'}.',
      ) {
    assert(
      Component.staticGameInstance == null,
      '$this instantiated, while another game ${Component.staticGameInstance} '
      'declares itself to be a singleton',
    );

    if (kDebugMode && !HotReloadConnector.isBuildingShadow) {
      DevToolsService.initWithGame(this);
    }

    _camera.world = _world;
    add(_camera);
    add(_world);
  }

  /// Whether this game is a copy that `flame reload --merge` builds, to find
  /// out which components and values the code declares.
  ///
  /// Such a copy is loaded and mounted, but it is never shown and never
  /// updated. Check this in [onLoad] and [onMount] to skip side effects that
  /// should only happen in the real game, such as playing music.
  bool get isHotReloadShadow =>
      _isHotReloadShadow || HotReloadConnector.isBuildingShadow;
  bool _isHotReloadShadow = false;

  @internal
  void markAsHotReloadShadow() => _isHotReloadShadow = true;

  /// The [World] that the [camera] is rendering.
  /// Inside of this world is where most of your components should be added.
  ///
  /// You don't have to add the world to the tree after setting it here, it is
  /// done automatically.
  W get world => _world;
  set world(W newWorld) {
    if (newWorld == _world) {
      return;
    }
    _world.removeFromParent();
    camera.world = newWorld;
    _world = newWorld;
    if (_world.parent == null) {
      add(_world);
    }
  }

  W _world = world ?? World() as W;

  /// The component that is responsible for rendering your [world].
  ///
  /// In this component you can set different viewports, viewfinders, follow
  /// components, set bounds for where the camera can move etc.
  ///
  /// You don't have to add the CameraComponent to the tree after setting it
  /// here, it is done automatically.
  ///
  /// When setting the camera, if it doesn't already have a world it will be
  /// set to match the game's world.
  CameraComponent get camera => _camera;
  set camera(CameraComponent newCameraComponent) {
    _camera.removeFromParent();
    _camera = newCameraComponent;
    if (_camera.parent == null) {
      add(_camera);
    }
    _camera.world ??= world;
  }

  CameraComponent _camera = camera ?? CameraComponent();

  /// Declarative graphics preset, resolution scaling, shadow, particle-density,
  /// and LOD controller for this game.
  late final GraphicsSettingsController graphics = GraphicsSettingsController()
    ..addListener(_handleGraphicsControllerChange);

  /// Dynamic Resolution & Particle Scaling (DRS) governor shorthand
  /// (`graphics.governor`).
  DynamicQualityGovernor get qualityGovernor => graphics.governor;

  /// GPU byte budget tracker and LRU cache evictor for offscreen `Snapshot`
  /// and static layer surfaces.
  final SceneResourceBudget resourceBudget = SceneResourceBudget();

  /// Frame-budgeted micro-task scheduler amortizing heavy scene preparation
  /// callbacks across VSync ticks.
  final FrameBudgetScheduler frameBudgetScheduler = FrameBudgetScheduler();

  /// Effective world resolution scale from [graphics] (`profile.renderScale`
  /// multiplied by [qualityGovernor] when enabled).
  double get effectiveRenderScale => graphics.effectiveRenderScale;

  /// Enqueues [task] on [frameBudgetScheduler] ordered by descending
  /// [priority].
  Future<T> scheduleFrameTask<T>(T Function() task, {int priority = 0}) =>
      frameBudgetScheduler.schedule(task, priority: priority);

  /// Enqueues a fire-and-forget synchronous [task] on [frameBudgetScheduler].
  void scheduleFrameTaskSync(void Function() task, {int priority = 0}) =>
      frameBudgetScheduler.scheduleSync(task, priority: priority);

  void _handleGraphicsControllerChange() {
    Component.invalidateFlatTraversalLists();
    _camera.syncAutoDevicePixelRatio();
    markSceneDirty();
  }

  @override
  double? get effectiveMaxDevicePixelRatio {
    final explicitCap = maxDevicePixelRatio;
    final profileCap = graphics.effectiveMaxDevicePixelRatio;
    if (explicitCap == null) {
      return profileCap;
    }
    return math.min(explicitCap, profileCap);
  }

  @override
  void onDisplayMetricsChanged(double devicePixelRatio, double refreshRate) {
    super.onDisplayMetricsChanged(devicePixelRatio, refreshRate);
    _camera.syncAutoDevicePixelRatio();
  }

  int _lastRenderedCamTxVersion = -1;
  int _lastRenderedGraphicsVersion = -1;
  int _lastRenderedGlobalTxCount = -1;
  int _lastRenderedStructureCount = -1;
  int _lastRenderedSortKeyCount = -1;
  World? _lastRenderedWorld;

  @override
  @internal
  bool pollSceneDirtyForRender() {
    if (super.pollSceneDirtyForRender()) {
      return true;
    }
    if (hasLifecycleEvents ||
        _camera.hasActiveSceneTransition ||
        _camera.viewfinder.hasActiveShake ||
        !identical(_world, _lastRenderedWorld) ||
        _camera.viewfinder.transform.version != _lastRenderedCamTxVersion ||
        graphics.version != _lastRenderedGraphicsVersion ||
        Transform2D.globalMutationCount != _lastRenderedGlobalTxCount ||
        Component.structureMutationCount != _lastRenderedStructureCount ||
        Component.sortKeyMutationCount != _lastRenderedSortKeyCount) {
      return true;
    }
    return false;
  }

  @override
  @internal
  void onFrameRendered() {
    super.onFrameRendered();
    _lastRenderedCamTxVersion = _camera.viewfinder.transform.version;
    _lastRenderedGraphicsVersion = graphics.version;
    _lastRenderedGlobalTxCount = Transform2D.globalMutationCount;
    _lastRenderedStructureCount = Component.structureMutationCount;
    _lastRenderedSortKeyCount = Component.sortKeyMutationCount;
    _lastRenderedWorld = _world;
  }

  @internal
  late final List<ComponentsNotifier> notifiers = [];

  /// This is overwritten to consider the viewport transformation.
  ///
  /// Which means that this is the logical size of the game screen area as
  /// exposed to the canvas after viewport transformations.
  ///
  /// This does not match the Flutter widget size; for that see [canvasSize].
  @override
  Vector2 get size => camera.viewport.virtualSize;

  @override
  @internal
  FutureOr<void> load() async {
    await super.load();
    setLoaded();
  }

  @override
  @internal
  void mount() {
    super.mount();
    if (_pausedBecauseBackgrounded) {
      resumeEngine();
    }
    setMounted();
  }

  @override
  @internal
  void finalizeRemoval() {
    super.finalizeRemoval();
    setRemoved();
  }

  /// This implementation of render renders each component, making sure the
  /// canvas is reset for each one.
  ///
  /// You can override it further to add more custom behavior.
  /// Beware of that if you are rendering components without using this method;
  /// you must be careful to save and restore the canvas to avoid components
  /// interfering with each others rendering.
  final Stopwatch _telemetryStopwatch = Stopwatch();

  /// Whether desktop/macOS trackpad `PointerPanZoom` gestures bypass the
  /// default 5% scale and pan-slop deadzones on [MultiDragScaleDispatcher],
  /// enabling immediate zero-deadzone two-finger pan, pinch, and rotation.
  bool get trackpadImmediateScale => _trackpadImmediateScale;
  bool _trackpadImmediateScale = false;
  set trackpadImmediateScale(bool value) {
    _trackpadImmediateScale = value;
    final dispatcher = findByKey(
      const MultiDragScaleDispatcherKey(),
    ) as MultiDragScaleDispatcher?;
    if (dispatcher != null) {
      dispatcher.zeroTrackpadDeadzone = value;
    }
  }

  @override
  @mustCallSuper
  void render(Canvas canvas) {
    if (parent == null) {
      if (collectRenderTelemetry && TelemetryCanvas.activeTelemetry == null) {
        renderTelemetry.beginRenderFrame();
        TelemetryCanvas.pushActiveTelemetry(renderTelemetry);
        final wrapped = canvas is TelemetryCanvas
            ? canvas
            : (rootTelemetryCanvas..bind(canvas, renderTelemetry));
        _telemetryStopwatch
          ..reset()
          ..start();
        try {
          renderTree(wrapped);
        } finally {
          _telemetryStopwatch.stop();
          if (identical(wrapped, rootTelemetryCanvas)) {
            rootTelemetryCanvas.unbind();
          }
          TelemetryCanvas.popActiveTelemetry();
          renderTelemetry.endRenderFrame(
            renderMicros: _telemetryStopwatch.elapsedMicroseconds,
          );
        }
        return;
      }
      renderTree(canvas);
    }
  }

  @override
  void renderTree(Canvas canvas) {
    if (parent != null) {
      render(canvas);
    }
    for (final component in children) {
      component.renderTree(canvas);
    }
  }

  /// Whether incoming high-frequency OS `PointerHoverEvent`s (such as
  /// 500–1000 Hz desktop gaming mice) are coalesced into a single scene hover
  /// raycast per frame at the start of [update] instead of running
  /// synchronously per OS pointer packet.
  bool coalesceMouseHover = false;

  /// Immediately dispatches any coalesced mouse hover event queued since the
  /// previous tick.
  void flushPendingMouseHover() {
    findByKey<MouseMoveDispatcher>(
      const MouseMoveDispatcherKey(),
    )?.flushPendingHover();
  }

  @override
  @mustCallSuper
  void update(double dt) {
    if (parent == null) {
      final needsTiming =
          collectRenderTelemetry ||
          frameBudgetScheduler.hasPendingTasks ||
          qualityGovernor.enabled;
      if (needsTiming) {
        _telemetryStopwatch
          ..reset()
          ..start();
        var elapsedUs = 0;
        try {
          processLifecycleEvents();
          if (coalesceMouseHover) {
            flushPendingMouseHover();
          }
          updateTree(dt);
        } finally {
          _telemetryStopwatch.stop();
          elapsedUs = _telemetryStopwatch.elapsedMicroseconds;
          if (collectRenderTelemetry) {
            renderTelemetry.recordUpdateMicros(elapsedUs);
          }
        }
        _postRootUpdateMaintenance(elapsedUs);
        return;
      }
      // Lifecycle events are processed before the traversal so that they
      // complete even while the traversal is paused through a time scale.
      processLifecycleEvents();
      if (coalesceMouseHover) {
        flushPendingMouseHover();
      }
      updateTree(dt);
    }
  }

  void _postRootUpdateMaintenance(int updateElapsedMicros) {
    final targetHz = math.max(1.0, effectiveTargetFps ?? displayRefreshRate);
    final budgetMs = 1000.0 / targetHz;

    if (qualityGovernor.enabled && _lastEffectiveDt > 0.0) {
      final double observedMs;
      if (renderTelemetry.platformTimingSampleCount > 0) {
        observedMs = renderTelemetry.smoothedTotalSpanMs;
      } else if (collectRenderTelemetry &&
          (renderTelemetry.updateMicros > 0 ||
              renderTelemetry.renderMicros > 0)) {
        observedMs =
            (renderTelemetry.updateMicros + renderTelemetry.renderMicros) /
            1000.0;
      } else {
        observedMs = _lastEffectiveDt * 1000.0;
      }
      graphics.recordFrameSample(
        frameTimeMs: observedMs,
        targetBudgetMs: budgetMs,
        dtSeconds: _lastEffectiveDt,
      );
    }

    if (frameBudgetScheduler.hasPendingTasks) {
      final ran = frameBudgetScheduler.drainWithinBudget(
        elapsedUpdateMicros: updateElapsedMicros,
        frameBudgetMicros: (budgetMs * 1000.0).round(),
      );
      if (ran > 0) {
        markSceneDirty();
      }
    }
  }

  /// Optional upper bound (in seconds) above which incoming frame deltas
  /// (for example after OS App Nap or tab suspension) are clamped to
  /// [clampedDeltaTime]. When null, frame deltas are passed through unchanged.
  double? maxDeltaTime;

  /// Replacement delta (in seconds) applied whenever `dt > maxDeltaTime`.
  double clampedDeltaTime = 0.05;

  int _clampedDeltaSpikes = 0;
  double _lastEffectiveDt = 0.0;

  /// Number of oversized frame deltas clamped by [maxDeltaTime].
  int get clampedDeltaSpikes => _clampedDeltaSpikes;

  /// Most recent effective delta time (in seconds) propagated to children.
  double get lastEffectiveDt => _lastEffectiveDt;

  /// Optional fixed simulation timestep in seconds (e.g. `1 / 120`) used to
  /// drive [HasFixedUpdate] components deterministically before variable
  /// [update] ticks. When `null`, fixed updates are disabled.
  double? fixedTimeStep;

  /// Maximum number of [HasFixedUpdate.fixedUpdate] substeps executed in a
  /// single frame to prevent spiral-of-death stalls after frame drops.
  int maxFixedSubSteps = 8;

  double _fixedAccumulator = 0.0;
  double _renderInterpolationAlpha = 1.0;
  int _lastFrameFixedSteps = 0;

  /// Fractional remainder `(_fixedAccumulator / fixedTimeStep)` in `[0..1]`
  /// available during [render] to smoothly interpolate between the previous
  /// and current fixed-step states (`1.0` when [fixedTimeStep] is `null`).
  double get renderInterpolationAlpha => _renderInterpolationAlpha;

  /// Number of fixed simulation substeps executed during the most recent frame.
  int get lastFrameFixedSteps => _lastFrameFixedSteps;

  /// Clears any accumulated fractional fixed-step remainder.
  void resetFixedUpdateAccumulator() {
    _fixedAccumulator = 0.0;
    _renderInterpolationAlpha = 1.0;
    _lastFrameFixedSteps = 0;
  }

  @override
  void updateSubtree(double dt) {
    final limit = maxDeltaTime;
    final double effectiveDt;
    if (limit != null && dt > limit) {
      effectiveDt = clampedDeltaTime;
      _clampedDeltaSpikes++;
    } else {
      effectiveDt = dt;
    }
    _lastEffectiveDt = effectiveDt;
    if (parent != null) {
      processLifecycleEvents();
      if (ticksEnabled) {
        update(effectiveDt);
      }
    }

    final step = fixedTimeStep;
    if (step != null && step > 0.0) {
      _fixedAccumulator += effectiveDt;
      var subSteps = 0;
      while (_fixedAccumulator >= step && subSteps < maxFixedSubSteps) {
        _fixedAccumulator -= step;
        subSteps++;
        runFixedUpdatePass(step);
      }
      if (_fixedAccumulator >= step) {
        _fixedAccumulator %= step;
      }
      _lastFrameFixedSteps = subSteps;
      _renderInterpolationAlpha = (_fixedAccumulator / step).clamp(0.0, 1.0);
    } else {
      _lastFrameFixedSteps = 0;
      _renderInterpolationAlpha = 1.0;
    }

    updateChildrenFlat(effectiveDt);
  }

  /// This passes the new size along to every component in the tree via their
  /// [Component.onGameResize] method, enabling each one to make their decision
  /// of how to handle the resize event.
  ///
  /// It also updates the [size] field of the class to be used by later added
  /// components and other methods.
  /// You can override it further to add more custom behavior, but you should
  /// seriously consider calling the super implementation as well.
  @override
  @mustCallSuper
  void onGameResize(Vector2 size) {
    super.onGameResize(size);
    // This work-around is needed since the camera has the highest priority and
    // [size] uses [viewport.virtualSize], so the viewport needs to be updated
    // first since users will be using `game.size` in their [onGameResize]
    // methods.
    camera.viewport.onGameResize(size);
    // [onGameResize] is declared both in [Component] and in [Game]. Since
    // there is no way to explicitly call the [Component]'s implementation,
    // we propagate the event to [FlameGame]'s children manually.
    handleResize(size);
    for (final child in children) {
      child.onParentResize(size);
    }
  }

  /// Ensure that all pending tree operations finish.
  ///
  /// Awaiting on this future ensures that all pending operations of adding
  /// components into the tree are fully materialized, waiting for any
  /// components that are still loading.
  ///
  /// The `GameWidget` awaits this future when the game is first shown, so
  /// that the game only starts, and the loading widget is only removed, once
  /// the whole initial component tree has been loaded and mounted.
  ///
  /// A component that fails to load does not block this future; its error is
  /// reported through its [Component.loaded] future, or the current [Zone] if
  /// nothing is awaiting that future.
  ///
  /// Warning: since every pending component has to finish loading and
  /// mounting first, this future never completes if the tree can never
  /// settle. That happens when a component in the tree has an [onLoad] that
  /// never completes, for example one that awaits something which only
  /// happens once the game is running. Such a component keeps the
  /// `GameWidget` on the loading widget until it is removed from the tree.
  /// The same happens when a component is added to a parent that is not
  /// itself part of the game tree: it never starts loading, since loading
  /// only begins once its parent is mounted, so it blocks this future in
  /// the same way until either the parent is added to the game or the
  /// orphaned component is removed.
  @override
  Future<void> ready() async {
    while (isProcessingLifecycleEvents) {
      // This call came from inside a lifecycle callback, which runs while
      // [processLifecycleEvents] is iterating over the event queue. Since
      // the queue only supports one iteration at a time, wait until the
      // current processing pass has finished.
      await null;
    }
    var wake = Completer<void>();
    void wakeUp() {
      if (!wake.isCompleted) {
        wake.complete();
      }
    }

    final watchedChildren = <Component>{};
    while (hasLifecycleEvents) {
      processLifecycleEvents();
      if (!hasLifecycleEvents) {
        break;
      }
      if (wake.isCompleted) {
        wake = Completer<void>();
      }
      var hasLoadingChildren = false;
      // Safe to iterate plainly: this always runs after
      // [processLifecycleEvents] has returned, so it is never nested inside
      // its own iteration over the same queue.
      for (final event in queue) {
        final child = event.child;
        if (child == null || !child.isLoading) {
          continue;
        }
        hasLoadingChildren = true;
        if (watchedChildren.add(child)) {
          child.loadSettled.then((_) => wakeUp());
        }
      }
      if (hasLoadingChildren) {
        // Sleep until a load settles, or until the event queue is changed
        // from the outside, for example by a component being removed while
        // it is still loading.
        await Future.any([wake.future, nextLifecycleEventMutation]);
      } else {
        // The queue is stuck on a component added to a parent that is not
        // part of the game tree, so it will never start loading on its own.
        // Wait for the queue to change, for example because that parent, or
        // the stuck component itself, is added to or removed from the tree.
        await nextLifecycleEventMutation;
      }
    }
  }

  /// Whether a point is within the boundaries of the visible part of the game.
  @override
  bool containsLocalPoint(Vector2 point) {
    return point.x >= 0 &&
        point.y >= 0 &&
        point.x < canvasSize.x &&
        point.y < canvasSize.y;
  }

  /// Returns the current time in seconds with microseconds precision.
  ///
  /// This is compatible with the `dt` value used in the [update] method.
  double currentTime() {
    return DateTime.now().microsecondsSinceEpoch.toDouble() /
        Duration.microsecondsPerSecond;
  }

  /// Returns a [ComponentsNotifier] for the given type [W].
  ///
  /// This method handles duplications, so there will never be
  /// more than one [ComponentsNotifier] for a given type, meaning
  /// that this method can be called as many times as needed for a type.
  ComponentsNotifier<T> componentsNotifier<T extends Component>() {
    for (final notifier in notifiers) {
      if (notifier is ComponentsNotifier<T>) {
        return notifier;
      }
    }
    final notifier = ComponentsNotifier<T>(
      descendants().whereType<T>().toList(),
    );
    notifiers.add(notifier);
    return notifier;
  }

  @internal
  void propagateToApplicableNotifiers(
    Component component,
    void Function(ComponentsNotifier) callback,
  ) {
    for (final notifier in notifiers) {
      if (notifier.applicable(component)) {
        callback(notifier);
      }
    }
  }

  /// Whether the game should pause when the app is backgrounded.
  ///
  /// On the latest Flutter stable at the time of writing (3.13),
  /// this is only working on Android and iOS.
  ///
  /// Defaults to true.
  bool pauseWhenBackgrounded = true;
  bool _pausedBecauseBackgrounded = false;

  @visibleForTesting
  bool get isPausedOnBackground => _pausedBecauseBackgrounded;

  @override
  @mustCallSuper
  void lifecycleStateChange(AppLifecycleState state) {
    super.lifecycleStateChange(state);
    switch (state) {
      case AppLifecycleState.resumed:
      case AppLifecycleState.inactive:
        if (_pausedBecauseBackgrounded) {
          resumeEngine();
        }
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        if (pauseWhenBackgrounded && !isPaused) {
          pauseEngine();
          _pausedBecauseBackgrounded = true;
        }
    }
  }

  @override
  void pauseEngine() {
    _pausedBecauseBackgrounded = false;
    super.pauseEngine();
  }

  @override
  void resumeEngine() {
    _pausedBecauseBackgrounded = false;
    super.resumeEngine();
  }

  @override
  @mustCallSuper
  void onHotReload() {
    super.onHotReload();
    handleHotReload();
  }

  /// Removes all children from the game and clears all caches.
  ///
  /// This will call [onRemove] on all components in the tree, clear
  /// the [images] and [assets] caches, and process all pending
  /// lifecycle events.
  ///
  /// After calling this method, the game is in a clean state with no
  /// components or cached resources.
  void dispose() {
    frameBudgetScheduler.clear();
    resourceBudget.evictAll();
    graphics.removeListener(_handleGraphicsControllerChange);
    removeAll(children);
    processLifecycleEvents();
    images.clearCache();
    assets.clearCache();
  }

  /// Incrementally pre-warms all GPU shaders, textures, and vertex pipelines
  /// registered in [queue] before gameplay begins (skipped automatically when
  /// [isHotReloadShadow] is `true`).
  Future<void> warmupRenderPipelines(
    RenderWarmupQueue queue, {
    int surfaceSize = 16,
    int tasksPerYield = 4,
    void Function(double progress)? onProgress,
  }) {
    if (isHotReloadShadow) {
      return Future<void>.value();
    }
    return queue.warmupAll(
      surfaceSize: surfaceSize,
      tasksPerYield: tasksPerYield,
      onProgress: onProgress,
    );
  }

  /// Synchronously pre-warms all GPU pipelines registered in [queue].
  void warmupRenderPipelinesSync(
    RenderWarmupQueue queue, {
    int surfaceSize = 16,
  }) {
    if (isHotReloadShadow) {
      return;
    }
    queue.warmupAllSync(surfaceSize: surfaceSize);
  }
}
