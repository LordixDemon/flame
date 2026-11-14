import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui show PlatformDispatcher;

import 'package:flame/cache.dart';
import 'package:flame/components.dart';
import 'package:flame/extensions.dart';
import 'package:flame/game.dart';
import 'package:flame/src/flame.dart';
import 'package:flame/src/game/game_render_box.dart';
import 'package:flame/src/game/game_widget/gesture_detector_builder.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
// ignore: unnecessary_import
import 'package:meta/meta.dart';

/// This gives access to a low-level game API, to not build everything from a
/// low level `FlameGame` should be used.
///
/// You can either extend this class, or add it as a mixin.
///
/// Methods [update] and [render] need to be implemented in order to connect
/// your class with the internal game loop.
abstract mixin class Game() {
  /// The cache of all images loaded into the game. This defaults to the global
  /// [Flame.images] cache, but you can replace it with a new cache instance if
  /// needed.
  Images images = Flame.images;

  /// The cache of all (non-image) assets loaded into the game. This defaults to
  /// the global [Flame.assets] cache, but you can replace this with another
  /// instance if needed.
  AssetsCache assets = Flame.assets;

  /// Used internally by various mixins that need to use gesture detection
  /// functionality in Flutter.
  late final GestureDetectorBuilder gestureDetectors = GestureDetectorBuilder(
    refreshWidget,
  );

  /// Set by the MouseMoveDispatcher to receive mouse events from the
  /// game widget.
  void Function(PointerHoverEvent event)? get mouseDetector => _mouseDetector;
  void Function(PointerHoverEvent event)? _mouseDetector;
  set mouseDetector(void Function(PointerHoverEvent event)? newMouseDetector) {
    _mouseDetector = newMouseDetector;
    refreshWidget();
  }

  /// Set by the MouseMoveDispatcher to receive mouse press events from the
  /// game widget so it can fire `onHoverCancel` on hovered `HoverCallbacks`
  /// components when the user presses a button while hovering.
  void Function(PointerDownEvent event)? get mousePressDetector =>
      _mousePressDetector;
  void Function(PointerDownEvent event)? _mousePressDetector;
  set mousePressDetector(
    void Function(PointerDownEvent event)? newMousePressDetector,
  ) {
    _mousePressDetector = newMousePressDetector;
    refreshWidget();
  }

  /// Set by the ScrollDispatcher to receive pointer scroll events from the
  /// game widget.
  void Function(PointerScrollEvent event)? get scrollDetector =>
      _scrollDetector;
  void Function(PointerScrollEvent event)? _scrollDetector;
  set scrollDetector(
    void Function(PointerScrollEvent event)? newScrollDetector,
  ) {
    _scrollDetector = newScrollDetector;
    refreshWidget();
  }

  /// This should update the state of the game.
  void update(double dt);

  /// This should render the game.
  void render(Canvas canvas);

  /// Just a reference back to the render box that is kept up to date by the
  /// engine.
  GameRenderBox get renderBox => _gameRenderBox!;
  GameRenderBox? _gameRenderBox;

  /// Build context set by [GameWidgetState] before the game is fully
  /// attached to the render tree. This allows components to access the
  /// build context during [onLoad] and [onMount].
  @internal
  BuildContext? widgetBuildContext;

  /// Currently attached build context. Can be null if not attached.
  BuildContext? get buildContext =>
      _gameRenderBox?.buildContext ?? widgetBuildContext;

  /// Whether the game widget was attached to the Flutter tree.
  bool get isAttached => _gameRenderBox != null;

  /// Current size of the game as provided by the framework; it will be null if
  /// layout has not been computed yet.
  ///
  /// Use [size] and [hasLayout] for safe access.
  Vector2? _size;

  /// This variable ensures that Game's [onLoad] is called no more than once.
  late final FutureOr<void> _onLoadFuture = onLoad();

  bool _debugOnLoadStarted = false;

  @internal
  FutureOr<void> load() async {
    assert(
      () {
        _debugOnLoadStarted = true;
        return true;
      }(),
    );
    return await _onLoadFuture;
  }

  /// To be used for tests that needs to evaluate the game after it has been
  /// loaded by the game widget.
  @visibleForTesting
  FutureOr<void> toBeLoaded() {
    assert(
      _debugOnLoadStarted,
      'Make sure the game has passed to a mounted '
      'GameWidget before calling toBeLoaded',
    );
    return _onLoadFuture;
  }

  @mustCallSuper
  @internal
  void mount() {
    onMount();
  }

  /// A future that completes when the game is fully ready to start.
  ///
  /// The `GameWidget` awaits this future after the game has been loaded and
  /// mounted, before the game is shown and the first update tick runs. By
  /// default it completes immediately; [FlameGame] overrides this to wait
  /// until the whole initial component tree has been loaded and mounted.
  ///
  /// Since this future is awaited on the startup critical path, an override
  /// that never completes keeps the game on the loading widget forever.
  Future<void> ready() async {}

  /// Incremented on every [start] and every removal, so that a [start] that
  /// was overtaken by either one stops instead of mounting a removed game.
  int _startGeneration = 0;

  /// Loads and mounts the game, waits until it is [ready] and runs the first
  /// update tick.
  ///
  /// This is the same startup sequence that the `GameWidget` runs, so it can
  /// be used to run a game without a widget, for example to render it to an
  /// image. The game needs a size before it starts, so call [onGameResize]
  /// first.
  ///
  /// If the game is removed before startup finishes, the remaining steps are
  /// skipped.
  @mustCallSuper
  Future<void> start() async {
    assertHasLayout();
    final generation = ++_startGeneration;
    await load();
    if (generation != _startGeneration) {
      return;
    }
    mount();
    await ready();
    if (generation != _startGeneration) {
      return;
    }
    if (!isPaused) {
      update(0);
    }
  }

  @mustCallSuper
  @internal
  void finalizeRemoval() {
    _startGeneration++;
    onRemove();
  }

  /// Current game viewport size, updated every resize via the [onGameResize]
  /// method hook.
  Vector2 get size {
    assertHasLayout();
    return _size!;
  }

  Vector2 get canvasSize {
    assertHasLayout();
    return _size!;
  }

  double? _platformDevicePixelRatio;
  double? _platformRefreshRate;
  double? _overrideDevicePixelRatio;
  double? _overrideRefreshRate;

  /// Optional upper bound applied to [devicePixelRatio] (e.g. `2.0` on Retina
  /// mobile devices to cap fillrate).
  double? maxDevicePixelRatio;

  final Vector2 _physicalCanvasSize = Vector2.zero();

  static double _fallbackViewDpr() {
    final views = ui.PlatformDispatcher.instance.views;
    if (views.isNotEmpty) {
      final dpr = views.first.devicePixelRatio;
      if (dpr > 0.0) {
        return dpr;
      }
    }
    return 1.0;
  }

  static double _fallbackViewRefreshRate() {
    final views = ui.PlatformDispatcher.instance.views;
    if (views.isNotEmpty) {
      final hz = views.first.display.refreshRate;
      if (hz > 0.0) {
        return hz;
      }
    }
    return 60.0;
  }

  /// Effective upper cap on [devicePixelRatio] (`null` when uncapped).
  @protected
  double? get effectiveMaxDevicePixelRatio => maxDevicePixelRatio;

  /// Unclamped hardware `FlutterView.devicePixelRatio` of the hosting display
  /// (or explicit override set via [overrideDisplayMetrics]).
  double get rawDevicePixelRatio =>
      _overrideDevicePixelRatio ??
      _platformDevicePixelRatio ??
      _fallbackViewDpr();

  /// Effective `devicePixelRatio` clamped by [effectiveMaxDevicePixelRatio].
  double get devicePixelRatio {
    final raw = rawDevicePixelRatio;
    final cap = effectiveMaxDevicePixelRatio;
    final capped = cap != null ? math.min(raw, cap) : raw;
    return capped.clamp(0.25, 8.0);
  }

  /// Physical backing-store canvas dimensions (`canvasSize * devicePixelRatio`)
  /// updated in-place with zero heap allocations.
  Vector2 get physicalCanvasSize {
    assertHasLayout();
    final dpr = devicePixelRatio;
    return _physicalCanvasSize..setValues(_size!.x * dpr, _size!.y * dpr);
  }

  /// Active monitor refresh rate in Hz (`60`, `90`, `120`, `144`, `240`, etc.).
  double get displayRefreshRate =>
      _overrideRefreshRate ??
      _platformRefreshRate ??
      _fallbackViewRefreshRate();

  /// Overrides [rawDevicePixelRatio] and/or [displayRefreshRate] (pass `null`
  /// to clear overrides and return to live `FlutterView` hardware metrics).
  void overrideDisplayMetrics({
    double? devicePixelRatio,
    double? refreshRate,
  }) {
    final prevDpr = this.devicePixelRatio;
    final prevHz = displayRefreshRate;
    _overrideDevicePixelRatio = devicePixelRatio;
    _overrideRefreshRate = refreshRate;
    final nextDpr = this.devicePixelRatio;
    final nextHz = displayRefreshRate;
    if ((nextDpr - prevDpr).abs() > 1e-4 || (nextHz - prevHz).abs() > 1e-3) {
      onDisplayMetricsChanged(nextDpr, nextHz);
    }
  }

  /// Internal hook invoked by [GameRenderBox] on attach and `didChangeMetrics`.
  @internal
  void updatePlatformDisplayMetrics({
    required double devicePixelRatio,
    required double refreshRate,
  }) {
    final prevDpr = this.devicePixelRatio;
    final prevHz = displayRefreshRate;
    if (devicePixelRatio > 0.0) {
      _platformDevicePixelRatio = devicePixelRatio;
    }
    if (refreshRate > 0.0) {
      _platformRefreshRate = refreshRate;
    }
    final nextDpr = this.devicePixelRatio;
    final nextHz = displayRefreshRate;
    if ((nextDpr - prevDpr).abs() > 1e-4 || (nextHz - prevHz).abs() > 1e-3) {
      onDisplayMetricsChanged(nextDpr, nextHz);
    }
  }

  /// Invoked whenever the hosting window changes `devicePixelRatio` or monitor
  /// `refreshRate` (for example dragging a window from a 60 Hz external monitor
  /// onto a 120 Hz Retina display).
  @mustCallSuper
  void onDisplayMetricsChanged(double devicePixelRatio, double refreshRate) {
    markSceneDirty();
  }

  /// Indicates if this game instance is connected to a GameWidget that is live
  /// in the flutter widget tree.
  /// Once this is true, the game is ready to have its size used or in the case
  /// of a FlameGame, to receive components.
  bool get hasLayout => _size != null;

  /// Whether the game should consume pointer events at the given [position],
  /// rather than letting them through to the Flutter widgets behind it.
  ///
  /// Only consulted when the [GameWidget] is built with
  /// `HitTestBehavior.deferToChild`; the other behaviors decide without asking
  /// the game.
  ///
  /// The default returns `true`, so the game is opaque across its whole
  /// surface. To be transparent wherever no component handles input, add the
  /// `DeferHitTestToComponents` mixin, or override this with your own rule.
  bool containsEventHandlerAt(Vector2 position) => true;

  final _BuildSafeValueNotifier<Color?> _backgroundColorNotifier =
      _BuildSafeValueNotifier<Color?>(null);

  /// Internal listenable updating the `GameWidget`'s background `ColoredBox`
  /// in isolation without rebuilding `GameWidgetState`.
  @internal
  ValueListenable<Color?> get backgroundColorListenable =>
      _backgroundColorNotifier;

  /// Optional live runtime override for the game's background color.
  ///
  /// Updating this property repaints the background immediately with zero
  /// `GameWidgetState` rebuilds; setting it to `null` falls back to
  /// [backgroundColor].
  Color? get backgroundColorValue => _backgroundColorNotifier.currentValue;
  set backgroundColorValue(Color? value) {
    if (_backgroundColorNotifier.currentValue == value) {
      return;
    }
    _backgroundColorNotifier.setBuildSafe(value);
    markSceneDirty();
    _gameRenderBox?.markNeedsPaint();
  }

  /// Resolved background color (`backgroundColorValue ?? backgroundColor()`).
  Color get effectiveBackgroundColor =>
      _backgroundColorNotifier.currentValue ?? backgroundColor();

  /// Returns the default game background color when [backgroundColorValue] is
  /// `null`. To mutate the background color dynamically at runtime without
  /// rebuilding `GameWidget`, set [backgroundColorValue].
  Color backgroundColor() => const Color(0xFF000000);

  /// This is the resize hook; every time the game widget is resized, this hook
  /// is called.
  ///
  /// The default implementation just sets the new size on the size field
  @mustCallSuper
  void onGameResize(Vector2 size) {
    _size = (_size ?? Vector2.zero())..setFrom(size);
    markSceneDirty();
  }

  @protected
  void assertHasLayout() {
    assert(
      hasLayout,
      '"size" is not ready yet. Did you try to access it on the Game '
      'constructor? Use the "onLoad" method instead.',
    );
  }

  /// This is the lifecycle state change hook; every time the game is resumed,
  /// paused or suspended, this is called.
  ///
  /// The default implementation does nothing; override to use the hook.
  /// Check [AppLifecycleState] for details about the events received.
  void lifecycleStateChange(AppLifecycleState state) {}

  /// Method to perform late initialization of the [Game] class.
  ///
  /// Usually, this method is the main place where you initialize your [Game]
  /// class. This has several advantages over the traditional constructor:
  ///   - this method can be `async`;
  ///   - it is invoked when the size of the game widget is already known.
  ///
  /// The default implementation returns `null`, indicating that there is no
  /// need to await anything. When overriding this method, you have a choice
  /// whether to create a regular or async function.
  ///
  /// If you need an async [onLoad], then make your override return non-nullable
  /// `Future<void>`:
  /// ```dart
  /// @override
  /// Future<void> onLoad() async {
  ///   // your code here
  /// }
  /// ```
  ///
  /// Alternatively, if your [onLoad] function doesn't use any `await`ing, then
  /// you can declare it as a regular method and then return `null`:
  /// ```dart
  /// @override
  /// Future<void>? onLoad() {
  ///   // your code here
  ///   return null;
  /// }
  /// ```
  ///
  /// The engine ensures that this method will be called exactly once during
  /// the lifetime of the [Game] instance. Do not call this method manually.
  FutureOr<void> onLoad() => null;

  void onMount() {}

  /// Marks game as attached to any Flutter widget tree.
  ///
  /// Should not be called manually.
  void attach(PipelineOwner owner, GameRenderBox gameRenderBox) {
    if (isAttached) {
      throw UnsupportedError(
        '''
      Game attachment error:
      A game instance can only be attached to one widget at a time.
      ''',
      );
    }
    _gameRenderBox = gameRenderBox;
    if (!_isInternalRefresh) {
      onAttach();
    }
    _isInternalRefresh = false;
  }

  /// Called when the game has been attached. This can be overridden
  /// to add logic that requires the game to already be attached
  /// to the widget tree.
  void onAttach() {}

  /// Marks game as no longer attached to any Flutter widget tree.
  ///
  /// Should not be called manually.
  void detach() {
    if (!_isInternalRefresh) {
      onDetach();
    }
    _gameRenderBox = null;
  }

  /// Called when the game is about to be removed from the Flutter widget tree,
  /// but before it is actually removed. See the docs for an example on how to
  /// do cleanups to avoid memory leaks.
  void onRemove() {}

  /// Called when Flutter's hot reload is triggered.
  ///
  /// [FlameGame] overrides this to propagate the notification
  /// to all components in the component tree.
  void onHotReload() {}

  /// Called when the GameWidget is disposed by Flutter.
  void onDispose() {}

  /// Called after the game has left the widget tree.
  /// This can be overridden to add logic that requires the game
  /// not be on the flutter widget tree anymore.
  void onDetach() {}

  /// Converts a global coordinate (i.e. w.r.t. the app itself) to a local
  /// coordinate (i.e. w.r.t. he game widget).
  /// If the widget occupies the whole app ("full screen" games), or is not
  /// attached to Flutter, this operation is the identity.
  Vector2 convertGlobalToLocalCoordinate(Vector2 point) {
    if (!isAttached) {
      return point.clone();
    }
    return _gameRenderBox!.globalToLocal(point.toOffset()).toVector2();
  }

  /// Converts a local coordinate (i.e. w.r.t. the game widget) to a global
  /// coordinate (i.e. w.r.t. the app itself).
  /// If the widget occupies the whole app ("full screen" games), or is not
  /// attached to Flutter, this operation is the identity.
  Vector2 convertLocalToGlobalCoordinate(Vector2 point) {
    if (!isAttached) {
      return point.clone();
    }
    return _gameRenderBox!.localToGlobal(point.toOffset()).toVector2();
  }

  /// Utility method to load and cache the image for a sprite based on its
  /// options.
  ///
  /// The [path] is the full path of the asset, as declared in the
  /// `pubspec.yaml`, for example `assets/images/player.png`.
  Future<Sprite> loadSprite(
    String path, {
    Vector2? srcSize,
    Vector2? srcPosition,
  }) {
    return Sprite.load(
      path,
      srcPosition: srcPosition,
      srcSize: srcSize,
      images: images,
    );
  }

  /// Utility method to load and cache the image for a sprite animation based on
  /// its options.
  ///
  /// The [path] is the full path of the asset, as declared in the
  /// `pubspec.yaml`, for example `assets/images/player.png`.
  Future<SpriteAnimation> loadSpriteAnimation(
    String path,
    SpriteAnimationData data,
  ) {
    return SpriteAnimation.load(
      path,
      data,
      images: images,
    );
  }

  bool _isPaused = false;

  /// Whether the engine is currently paused or running.
  bool get isPaused => _isPaused;

  /// Pauses or resumes the engine.
  set isPaused(bool value) {
    _isPaused = value;

    final gameLoop = _gameRenderBox?.gameLoop;
    if (gameLoop != null) {
      if (value) {
        gameLoop.stop();
      } else {
        gameLoop.start();
      }
    }
  }

  /// Pauses the engine game loop execution.
  void pauseEngine() {
    _isPaused = true;
    _gameRenderBox?.gameLoop?.stop();
  }

  /// Resumes the engine game loop execution.
  void resumeEngine() {
    _isPaused = false;
    _gameRenderBox?.gameLoop?.start();
  }

  /// Steps the engine game loop by one frame. Works only if the engine is in
  /// paused state. By default step time is assumed to be 1/60th of a second.
  void stepEngine({double stepTime = 1 / 60}) {
    if (_isPaused) {
      _isPaused = false;
      _gameRenderBox?.gameLoop?.step(stepTime);
      _isPaused = true;
    }
  }

  /// Optional display-aware harmonic VSync framerate policy (`powerSave30`,
  /// `locked60`, `harmonicHalf`, `nativeDisplay`, `uncapped`, `custom`).
  ///
  /// When non-null, takes precedence over [targetFps] for active pacing while
  /// still honoring [idleFps] when [isIdleThrottled] is `true`.
  FpsPolicy? fpsPolicy;

  /// Optional upper simulation framerate cap in Hz (e.g. `60` or `120`) used
  /// when [fpsPolicy] is `null`. When both are `null`, frames run uncapped at
  /// the display's native VSync rate.
  double? targetFps;

  /// Optional independent render framerate cap in Hz (for example `30` while
  /// simulation [targetFps] runs at `60` or `120`). When `null`, every executed
  /// simulation tick is eligible to render (subject to [idleRenderMode]).
  double? renderTargetFps;

  /// Controls whether clean (visually unchanged) frames skip GPU repaints while
  /// keeping `update(dt)` simulation ticks active.
  IdleRenderMode idleRenderMode = IdleRenderMode.always;

  /// Monotonic global counter incremented whenever a visual-only mutation
  /// occurs outside `Transform2D` (such as particle simulation, sprite
  /// animation frame advances, `HasPaint` color/opacity mutations, animated
  /// rich text, ribbon trails, Verlet ropes, or `Node3D` 3D transforms) so
  /// [IdleRenderMode.onDemand] and [IdleRenderMode.onDemandWhenIdle] wake up
  /// automatically with zero per-frame allocations.
  static int visualMutationCount = 0;

  /// Notifies the engine that visual-only state changed and the next tick
  /// should repaint even when [IdleRenderMode.onDemand] is active.
  static void notifyVisualMutation() {
    visualMutationCount++;
  }

  bool _sceneDirty = true;
  double _renderAccumulator = 0.0;
  int _executedUpdateTicks = 0;
  int _executedRenderFrames = 0;
  int _skippedRenderFrames = 0;
  int _skippedCleanPaints = 0;

  /// Whether the scene has pending visual changes requiring a paint pass.
  bool get isSceneDirty => _sceneDirty;

  /// Total `GameRenderBox` update ticks executed since creation or reset.
  int get executedUpdateTicks => _executedUpdateTicks;

  /// Total `GameRenderBox` paint frames executed since creation or reset.
  int get executedRenderFrames => _executedRenderFrames;

  /// Number of simulation ticks whose `paint` was skipped due to
  /// [renderTargetFps] decimation.
  int get skippedRenderFrames => _skippedRenderFrames;

  /// Number of simulation ticks whose `paint` was skipped because
  /// [idleRenderMode] detected a clean scene (`isSceneDirty == false`).
  int get skippedCleanPaints => _skippedCleanPaints;

  /// Marks the visual scene dirty so [IdleRenderMode.onDemand] /
  /// [IdleRenderMode.onDemandWhenIdle] schedules a repaint on the next tick.
  void markSceneDirty() {
    _sceneDirty = true;
  }

  /// Resets update/render execution and skip counters.
  void resetRenderSkipCounters() {
    _executedUpdateTicks = 0;
    _executedRenderFrames = 0;
    _skippedRenderFrames = 0;
    _skippedCleanPaints = 0;
    _renderAccumulator = 0.0;
  }

  /// Subclass hook checked before skipping a paint in on-demand modes.
  @protected
  @internal
  bool pollSceneDirtyForRender() => _sceneDirty;

  /// Internal callback invoked by `GameRenderBox.paint` once a frame renders.
  @mustCallSuper
  @internal
  void onFrameRendered() {
    _executedRenderFrames++;
    _sceneDirty = false;
  }

  /// Evaluates decoupled [renderTargetFps] and [idleRenderMode] after `update`
  /// to decide whether `GameRenderBox` should call `markNeedsPaint()`.
  @internal
  bool shouldRenderThisTick(double dt) {
    _executedUpdateTicks++;
    final rFps = renderTargetFps;
    if (rFps != null) {
      if (rFps <= 0.0) {
        _skippedRenderFrames++;
        return false;
      }
      _renderAccumulator += dt;
      final minRenderInterval = 1.0 / rFps;
      if (dt > 0.0 && _renderAccumulator < minRenderInterval * 0.92) {
        _skippedRenderFrames++;
        return false;
      }
      _renderAccumulator = 0.0;
    }

    final checkDirty =
        idleRenderMode == IdleRenderMode.onDemand ||
        (idleRenderMode == IdleRenderMode.onDemandWhenIdle && isIdleThrottled);
    if (checkDirty && !pollSceneDirtyForRender()) {
      _skippedCleanPaints++;
      return false;
    }
    return true;
  }

  /// Optional reduced framerate in Hz (e.g. `30`, or `0` to suspend frames
  /// completely) applied automatically after [idleTimeoutSeconds] without user
  /// input or [notifyActivity] boosts.
  double? idleFps;

  /// Seconds of inactivity before [idleFps] throttling engages.
  double idleTimeoutSeconds = 2.5;

  double _idleElapsedSeconds = 0.0;
  double _boostRemainingSeconds = 0.0;

  /// Seconds elapsed since the last input or [notifyActivity] call.
  double get idleElapsedSeconds => _idleElapsedSeconds;

  /// Remaining duration (in seconds) of an explicit high-FPS activity boost.
  double get activityBoostRemainingSeconds => _boostRemainingSeconds;

  /// Whether the game loop is currently throttled to [idleFps].
  bool get isIdleThrottled =>
      idleFps != null &&
      _boostRemainingSeconds <= 0.0 &&
      _idleElapsedSeconds >= idleTimeoutSeconds;

  /// Currently active framerate cap in Hz combining [fpsPolicy], [targetFps],
  /// and [idleFps], or `null` if running at uncapped native vsync.
  double? get effectiveTargetFps {
    final activeBase = fpsPolicy != null
        ? fpsPolicy!.resolveTargetFps(displayRefreshRate)
        : targetFps;
    if (isIdleThrottled) {
      final idle = idleFps!;
      if (idle <= 0.0) {
        return 0.0;
      }
      return activeBase != null ? math.min(activeBase, idle) : idle;
    }
    return activeBase;
  }

  /// Exact integer VSync beat divisor (`1`, `2`, `3`, `4`, ...) when the active
  /// framerate divides [displayRefreshRate] harmonically, or `null` when
  /// non-harmonic accumulator pacing is required.
  @internal
  int? get effectiveVsyncDivisor {
    final hz = displayRefreshRate;
    if (isIdleThrottled) {
      final eff = effectiveTargetFps;
      if (eff == null || eff <= 0.0) {
        return null;
      }
      return FpsPolicy.custom(eff).resolveVsyncDivisor(hz);
    }
    final policy = fpsPolicy;
    if (policy != null) {
      return policy.resolveVsyncDivisor(hz);
    }
    final target = targetFps;
    if (target != null && target > 0.0) {
      return FpsPolicy.custom(target).resolveVsyncDivisor(hz);
    }
    return null;
  }

  /// Minimum frame interval in seconds used by `GameLoop`, `null` when
  /// uncapped, or [double.infinity] when suspended in `idleFps == 0` mode.
  @internal
  double? get minFrameIntervalSeconds {
    final fps = effectiveTargetFps;
    if (fps == null) {
      return null;
    }
    if (fps <= 0.0) {
      return double.infinity;
    }
    return 1.0 / fps;
  }

  /// Resets the idle timer, marks the scene dirty, and optionally holds full
  /// framerate for at least [boostSeconds].
  void notifyActivity({double boostSeconds = 0.0}) {
    _idleElapsedSeconds = 0.0;
    _sceneDirty = true;
    if (boostSeconds > _boostRemainingSeconds) {
      _boostRemainingSeconds = boostSeconds;
    }
  }

  /// Whether low-overhead CPU/GPU canvas draw-call and timing telemetry is
  /// collected into [renderTelemetry] each frame.
  ///
  /// Defaults to `false` (zero overhead). Automatically enabled when mixing in
  /// `HasFrameTelemetry`.
  bool collectRenderTelemetry = false;

  /// Per-frame draw-call (`drawCalls`, `atlasCalls`, `verticesCalls`,
  /// `saveLayerCalls`) and CPU timing (`updateMicros`, `renderMicros`)
  /// counters populated when [collectRenderTelemetry] is `true`.
  final RenderFrameTelemetry renderTelemetry = RenderFrameTelemetry();

  final TelemetryCanvas _rootTelemetryCanvas = TelemetryCanvas();

  /// Reusable root [TelemetryCanvas] wrapper owned by this game instance.
  @internal
  TelemetryCanvas get rootTelemetryCanvas => _rootTelemetryCanvas;

  /// Advances the internal activity/idle timers by [dt] seconds.
  @internal
  void advanceAdaptivePacing(double dt) {
    if (dt <= 0.0) {
      return;
    }
    if (_boostRemainingSeconds > 0.0) {
      _boostRemainingSeconds = math.max(0.0, _boostRemainingSeconds - dt);
      _idleElapsedSeconds = 0.0;
    } else {
      _idleElapsedSeconds += dt;
    }
  }

  /// A property that stores an [OverlayManager]
  ///
  /// This is useful to render widgets on top of a game, such as a pause menu.
  /// Overlays can be made visible via [overlays].add or hidden via
  /// [overlays].remove.
  ///
  /// For example:
  /// ```dart
  /// final pauseOverlayIdentifier = 'PauseMenu';
  /// overlays.add(pauseOverlayIdentifier); // marks 'PauseMenu' to be rendered.
  /// overlays.remove(pauseOverlayIdentifier); // hides 'PauseMenu'.
  /// ```
  late final overlays = OverlayManager(this);

  final List<WidgetComponent> _widgetComponents = [];

  /// The [WidgetComponent]s that are currently mounted in this game, in the
  /// order they were mounted. The `GameWidget` builds the widget of each of
  /// them as a child of the game's render box.
  @internal
  List<WidgetComponent> get widgetComponents => _widgetComponents;

  /// Registers a mounted [WidgetComponent] so that its widget is built into
  /// the widget tree. Called by the component itself when it is mounted.
  @internal
  void registerWidgetComponent(WidgetComponent component) {
    if (_widgetComponents.contains(component)) {
      return;
    }
    _widgetComponents.add(component);
    refreshWidget(isInternalRefresh: false);
  }

  /// Removes a [WidgetComponent] that is no longer mounted. Called by the
  /// component itself when it is removed.
  @internal
  void unregisterWidgetComponent(WidgetComponent component) {
    if (_widgetComponents.remove(component)) {
      refreshWidget(isInternalRefresh: false);
    }
  }

  final _BuildSafeValueNotifier<MouseCursor> _mouseCursorNotifier =
      _BuildSafeValueNotifier<MouseCursor>(MouseCursor.defer);

  /// Listenable updating the `GameWidget`'s `MouseRegion` cursor in isolation
  /// without rebuilding `GameWidgetState` (`0` widget tree rebuilds).
  ValueListenable<MouseCursor> get mouseCursorListenable =>
      _mouseCursorNotifier;

  /// Used to change the mouse cursor of the GameWidget running this game.
  ///
  /// Updating this property notifies [mouseCursorListenable] in isolation
  /// without rebuilding `GameWidgetState`.
  MouseCursor get mouseCursor => _mouseCursorNotifier.currentValue;

  set mouseCursor(MouseCursor value) {
    _mouseCursorNotifier.setBuildSafe(value);
  }

  @visibleForTesting
  final List<VoidCallback> gameStateListeners = [];

  void addGameStateListener(VoidCallback callback) {
    gameStateListeners.add(callback);
  }

  void removeGameStateListener(VoidCallback callback) {
    gameStateListeners.remove(callback);
  }

  bool _isInternalRefresh = false;

  /// When a Game is attached to a `GameWidget`, this method will force that
  /// widget to be rebuilt. This can be used when updating any property which is
  /// implemented within the Flutter tree.
  ///
  /// When [isInternalRefresh] is passed as false it will trigger the `onAttach`
  /// and `onDetach` events; otherwise, those events will not be called.
  @internal
  void refreshWidget({bool isInternalRefresh = true}) {
    _isInternalRefresh = isInternalRefresh;
    gameStateListeners.forEach((callback) => callback());
  }
}

class _BuildSafeValueNotifier<T>(super._value) extends ValueNotifier<T> {
  late T _currentValue = value;
  bool _microtaskScheduled = false;

  T get currentValue => _currentValue;

  void setBuildSafe(T next) {
    if (_currentValue == next) {
      return;
    }
    _currentValue = next;
    if (!hasListeners) {
      super.value = next;
      return;
    }
    SchedulerPhase? phase;
    try {
      phase = SchedulerBinding.instance.schedulerPhase;
    } on Object {
      phase = null;
    }
    if (phase == SchedulerPhase.persistentCallbacks) {
      if (!_microtaskScheduled) {
        _microtaskScheduled = true;
        Future.microtask(() {
          _microtaskScheduled = false;
          super.value = _currentValue;
        });
      }
    } else {
      super.value = next;
    }
  }
}
