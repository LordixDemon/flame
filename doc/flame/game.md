# FlameGame

Every game needs a central object that owns the game loop, the continuous cycle of updating state
and rendering frames that drives all real-time games. In Flame, `FlameGame` fills that role while
also serving as the root of the component tree. If you are familiar with Flutter, think of
`FlameGame` as the equivalent of `MaterialApp`: the top-level entry point that everything else
hangs off of.

The base of almost all Flame games is the `FlameGame` class. It is the root of your component
tree. We refer to this component-based system as the Flame Component System (FCS). Throughout the
documentation, FCS is used to reference this system.

The `FlameGame` class implements a `Component` based `Game`. It has a tree of components
and calls the `update` and `render` methods of all components that have been added to the game.

Components can be added to the `FlameGame` directly in the constructor with the named `children`
argument, or from anywhere else with the `add`/`addAll` methods. Most of the time however, you want
to add your children to a `World`, the default world exists under `FlameGame.world` and you add
components to it just like you would to any other component.

A simple `FlameGame` implementation that adds two components, one in `onLoad` and one directly in
the constructor can look like this:

```dart
import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flutter/widgets.dart';

/// A component that renders the crate sprite, with a 16 x 16 size.
class MyCrate extends SpriteComponent {
  MyCrate() : super(size: Vector2.all(16));

  @override
  Future<void> onLoad() async {
    sprite = await Sprite.load('assets/images/crate.png');
  }
}

class MyWorld extends World {
  @override
  Future<void> onLoad() async {
    await super.onLoad();
    add(MyCrate());
  }
}

void main() {
  final myGame = FlameGame(world: MyWorld());
  runApp(
    GameWidget(game: myGame),
  );
}
```


## Custom World type

`FlameGame` has a generic type parameter `W` that defaults to `World`. By specifying a custom world
type, the `world` getter on your game will return your specific world type directly, without needing
to cast it.

This is useful when you have a custom `World` subclass and want to access its properties or methods
from within your game class:

```dart
class MyWorld extends World {
  int score = 0;
}

class MyGame extends FlameGame<MyWorld> {
  MyGame() : super(world: MyWorld());

  void incrementScore() {
    // No cast needed, `world` is already typed as `MyWorld`.
    world.score++;
  }
}
```

When using this generic parameter, you **must** pass a matching world instance to the `super`
constructor. If the generic type is specified but no world is provided, a runtime assertion error
will be thrown.

```{note}
If you instantiate your game in a build method your game will be rebuilt every
time the Flutter tree gets rebuilt, which usually is more often than you'd like.
To avoid this, you can either create an instance of your game first and
reference it within your widget structure or use the `GameWidget.managed`
constructor.
```

To remove components from the list on a `FlameGame` the `remove` or `removeAll` methods can be used.
The first can be used if you just want to remove one component, and the second can be used when you
want to remove a list of components. These methods exist on all `Component`s, including the `World`.

The `FlameGame` has a built-in `World` called `world` and a `CameraComponent` instance called
`camera`, you can read more about those in the [Camera section](camera.md).


## Game Loop

The `GameLoop` module is a simple abstraction of the game loop concept. Basically, most games are
built upon two methods:

- The render method takes the canvas for drawing the current state of the game.
- The update method receives the delta time in seconds since the last update and allows you to
  move to the next state.

The `GameLoop` is used by all of Flame's `Game` implementations.


## Resizing

Every time the game needs to be resized, for example when the orientation is changed, `FlameGame`
will call all of the `Component`'s `onGameResize` methods and it will also pass this information to
the camera and viewport.

The `FlameGame.camera` controls which point in the coordinate space that should be at the anchor of
your viewfinder, [0,0] is in the center (`Anchor.center`) of the viewport by default.


## Lifecycle

The `FlameGame` lifecycle callbacks, `onLoad`, `render`, etc. are called in the following sequence:

```{include} diagrams/flame_game_life_cycle.md
```

When a `FlameGame` is first added to a `GameWidget` the lifecycle methods `onGameResize`, `onLoad`
and `onMount` will be called in that order. After that, the `GameWidget` waits for the whole initial
component tree to be loaded and mounted, so the game does not start (and the `loadingBuilder`
widget, if one is set, stays visible) until every component added during `onLoad` is ready. Then
`update` and `render` are called in sequence for every game tick. If the `FlameGame` is removed
from the `GameWidget` then `onRemove` is called. If the `FlameGame` is added to a new `GameWidget`
the sequence repeats from `onGameResize`.

```{note}
The order of `onGameResize` and `onLoad` are reversed from that of other
`Component`s. This is to allow game element sizes to be calculated before
resources are loaded or generated.
```

The `onRemove` callback can be used to clean up children and cached data:

```dart
  @override
  void onRemove() {
    // Optional based on your game needs.
    removeAll(children);
    processLifecycleEvents();
    Flame.images.clearCache();
    Flame.assets.clearCache();
    // Any other code that you want to run when the game is removed.
  }
```

```{note}
Clean-up of children and resources in a `FlameGame` is not done automatically
and must be explicitly added to the `onRemove` call.
```


### onHotReload

When Flutter's hot reload is triggered (debug mode only), the `GameWidget` calls `onHotReload` on
the `FlameGame`, which automatically propagates the notification to every component in the tree that
is loading or loaded. Override this method on any component to reload assets, refresh cached values,
or react to source code changes during development:

```dart
class MyGame extends FlameGame {
  @override
  void onHotReload() {
    // Refresh game-level state affected by code changes.
    super.onHotReload();
  }
}
```

```{note}
`onHotReload` is only called in debug mode. Components that are still in the
lifecycle queue (loading but not yet mounted) also receive the notification.
Always call `super.onHotReload()` so the event continues to propagate to
children.
```


### dispose()

As a convenience, `FlameGame` provides a `dispose()` method that handles all of the common cleanup
in a single call:

```dart
  game.dispose();
```

This removes all children from the game (triggering `onRemove` on every component in the tree),
processes all pending lifecycle events, and clears the `images` and `assets` caches.

The difference between `dispose()` and `onRemove` is that `dispose()` is a method you call
explicitly to perform cleanup, while `onRemove` is a lifecycle callback that is invoked
automatically when the game is removed from a `GameWidget`. You can use `dispose()` from within
`onRemove`, or call it independently whenever you need to reset the game state.


## Debug mode

Flame's `FlameGame` class provides a variable called `debugMode`, which by default is `false`. It
can, however, be set to `true` to enable debug features for the components of the game. **Be aware**
that the value of this variable is passed through to its components when they are added to the
game, so if you change the `debugMode` at runtime, it will not affect already added components by
default.

To read more about the `debugMode` on Flame, please refer to the [Debug Docs](other/debug.md)


## Change background color

To change the background color of your `FlameGame` you have to override `backgroundColor()`.

In the following example, the background color is set to be fully transparent, so that you can see
the widgets that are behind the `GameWidget`. The default is opaque black.

```dart
class MyGame extends FlameGame {
  @override
  Color backgroundColor() => const Color(0x00000000);
}
```

To change the background color dynamically at runtime with **`0` `GameWidget` rebuilds**, assign a
new color to `game.backgroundColorValue` (backed by an isolated `ValueListenableBuilder` +
`ColoredBox` inside `GameWidget`); assigning `null` returns to `backgroundColor()`:

```dart
game.backgroundColorValue = const Color(0xFF0B1020);
```


## SingleGameInstance mixin

An optional mixin `SingleGameInstance` can be applied to your game if you are making a single-game
application. This is a common scenario when building games: there is a single full-screen
`GameWidget` that hosts a single `Game` instance.

Adding this mixin provides performance advantages in certain scenarios. In particular, a component's
`onLoad` method is guaranteed to start when that component is added to its parent, even if the
parent is not yet mounted itself. Consequently, awaiting `component.loaded` after
`parent.add(component)` is guaranteed to finish loading the component.

Using this mixin is simple:

```dart
class MyGame extends FlameGame with SingleGameInstance {
  // ...
}
```


## Low-level Game API

```{include} diagrams/low_level_game_api.md
```

The abstract `Game` class is a low-level API that can be used when you want to implement the
functionality of how the game engine should be structured. `Game` does not implement any `update` or
`render` function for example.

The class also has the lifecycle methods `onLoad`, `onMount` and `onRemove` in it, which are
called from the `GameWidget` (or another parent) when the game is loaded + mounted, or removed.
`onLoad` is only called the first time the class is added to a parent, but `onMount` (which is
called after `onLoad`) is called every time it is added to a new parent. `onRemove` is called when
the class is removed from a parent.

```{note}
The `Game` class allows for more freedom of how to implement things, but you
are also missing out on all of the built-in features in Flame if you use it.
```

An example of what a `Game` implementation could look like:

```dart
class MyGameSubClass extends Game {
  @override
  void render(Canvas canvas) {
    // ...
  }

  @override
  void update(double dt) {
    // ...
  }
}

void main() {
  final myGame = MyGameSubClass();
  runApp(
    GameWidget(
      game: myGame,
    )
  );
}
```


## Pause/Resuming/Stepping game execution

A Flame `Game` can be paused and resumed in two ways:

- With the use of the `pauseEngine` and `resumeEngine` methods.
- By changing the `isPaused` attribute.

When pausing a `Game`, the `GameLoop` is effectively paused, meaning that no updates or new renders
will happen until it is resumed.

While the game is paused, it is possible to advance it frame by frame using the `stepEngine`
method. It might not be very useful in the final game, but it can be very helpful for inspecting
game state step by step during the development cycle.


### Backgrounding

The game will be automatically paused when the app is sent to the background,
and resumed when it comes back to the foreground. This behavior can be disabled by setting
`pauseWhenBackgrounded` to `false`.

```dart
class MyGame extends FlameGame {
  MyGame() {
    pauseWhenBackgrounded = false;
  }
}
```

This flag currently only works on Android and iOS.


## HasPerformanceTracker mixin

While optimizing a game, it can be useful to track the time it took for the game to update and
render each frame. This data can help in detecting areas of the code that are running hot. It can
also help
in detecting visual areas of the game that are taking the most time to render.

To get the update and render times, just add the `HasPerformanceTracker` mixin to the game class.

```dart
class MyGame extends FlameGame with HasPerformanceTracker {
  // access `updateTime` and `renderTime` getters.
}
```


## Adaptive Idle Pacing, Delta Spike Clamping, Telemetry, and GPU Warmup

- **Adaptive Idle Frame Pacing (`idleFps` & `notifyActivity`)**: Set `idleFps` (e.g. `30.0`) and
  `idleTimeoutSeconds` (e.g. `3.0`) on `FlameGame` to automatically throttle calm board/menu scenes
  while snapping back to native 60/120 Hz immediately on pointer/keyboard input or
  `notifyActivity(boostSeconds: 1.5)`. Input is every pointer event that reaches the game (touch,
  mouse movement and hover, scroll, trackpad gestures) and every key press the `GameWidget`
  receives; it does not matter when `idleFps` is assigned. Pointer events that a widget on top of
  the game consumes, such as an overlay, do not reach the game: call `notifyActivity()` from those
  widgets if they should keep the game at full rate. With `idleFps = 0` the loop does not run at
  all while idle, so only input or `notifyActivity()` wakes it.
- **Background Spike Clamping (`maxDeltaTime` & `clampedDeltaTime`)**: Set `maxDeltaTime` and
  `clampedDeltaTime` on `FlameGame` so large frame hitches after tab switches or OS backgrounding
  are replaced by `clampedDeltaTime` (counted in `clampedDeltaSpikes`) instead of tunneling physics
  or skipping animations.
- **Draw-Call & CPU Telemetry (`HasFrameTelemetry`)**: Mix `HasFrameTelemetry` into `FlameGame` (or
  enable `collectRenderTelemetry = true`) to inspect `renderTelemetry` (`drawCalls`, `atlasCalls`,
  `verticesCalls`, `saveLayerCalls`, `updateMicros`, `renderMicros`) with zero per-frame wrapper
  allocations.
- **GPU Shader & Pipeline Pre-Warming (`RenderWarmupQueue`)**: Eliminate first-frame shader/PSO
  compilation hitches by registering `FragmentShader`s, `Image` atlases, and `Vertices` blend modes
  into a `RenderWarmupQueue` and awaiting `warmupRenderPipelines(queue)` during `onLoad`
  (automatically skipped on hot-reload shadow instances via `isHotReloadShadow`):

```dart
final queue = RenderWarmupQueue()
  ..addShader(oceanShader)
  ..addTexture(particleAtlas, blendMode: BlendMode.plus)
  ..addVertices(blendMode: BlendMode.modulate, shader: matCapShader);

await warmupRenderPipelines(queue, tasksPerYield: 8);
```

  By default the passes are only queued for the raster thread, and the engine may drop a queued
  pass before it is drawn, so the warm-up is best effort. Pass `awaitRasterization: true` to wait
  until the GPU has drawn every chunk. That needs real asynchronous work to finish: in a widget
  test it only completes inside `WidgetTester.runAsync`.


## High-Resolution `DisplayMetrics`, `GraphicsSettingsController`, `FpsPolicy` & `FrameBudgetScheduler`

`FlameGame` also integrates:

- **`game.displayMetrics` (`DisplayMetrics`)**: A snapshot of the effective `devicePixelRatio`,
  the canvas size in physical pixels (`physicalSize`) and the display `refreshRate`, which are
  synchronized automatically from `FlutterView` on metric changes.
- **`game.graphics` (`GraphicsSettingsController` & `DynamicQualityGovernor`)**: Preset quality
  tiers (`low`, `medium`, `high`, `ultra`), custom `GraphicsProfile` overrides, and hysteresis-driven
  Dynamic Resolution Scaling (DRS).
- **`game.fpsPolicy` (`FpsPolicy`), `renderTargetFps`, and `idleRenderMode` (`IdleRenderMode`)**:
  Framerate caps that lock onto every Nth display refresh when they divide the refresh rate (`60`
  FPS on `120`/`240 Hz`, `72` FPS on `144 Hz`) and are met on average when they do not, decoupled
  simulation vs render rates with `renderInterpolationAlpha`, and zero-raster dirty-scene rendering
  (`skippedCleanPaints`).
- **`game.resourceBudget` (`SceneResourceBudget`) & `game.frameBudgetScheduler`
  (`FrameBudgetScheduler`)**: Bounded LRU eviction for cached GPU `Snapshot` surfaces and
  frame-budgeted background task execution with anti-starvation guarantees.

For full API details and examples, see
[High-Resolution Rendering, Graphics Quality & FPS Management](rendering/graphics_and_fps.md).


## HiDPI Display Metrics, Graphics Quality Tiers, DRS, and Harmonic FPS Control

- **Live HiDPI Display Metrics (`DisplayMetrics`, `devicePixelRatio`, `maxDevicePixelRatio`)**:
  `GameRenderBox` automatically tracks the hosting `FlutterView`'s `devicePixelRatio` and
  `display.refreshRate` across multi-monitor moves and browser zoom changes, invoking
  `onDisplayMetricsChanged(double devicePixelRatio, double refreshRate)`. Set
  `game.maxDevicePixelRatio` (or configure `GraphicsProfile.maxDevicePixelRatio`) to cap internal
  render density on ultra-high-DPI 3x–4x panels, inspect `physicalCanvasSize`, or override metrics
  deterministically in headless tests via `overrideDisplayMetrics(...)`.
- **Reactive Graphics Quality Management (`GraphicsSettingsController`, `GraphicsQualityTier`,
  `GraphicsProfile`)**: `FlameGame.graphics` exposes `low`, `medium`, `high`, `ultra`, and `custom`
  quality tiers controlling `renderScale`, `maxDevicePixelRatio`, `shadowsEnabled`,
  `shadowOpacityScale`, `postProcessEnabled`, `auxiliaryPassScale`, `particleDensity`, `lodBias`,
  `ambientMotionEnabled`, and `antiAliasing`. Changing `game.graphics.setTier(...)` updates cameras,
  post-process pipelines,
  particle emitters, 3D batchers, and `minQualityTier`-gated components without rebuilding widgets.
- **Dynamic Resolution & Particle Governor (`DynamicQualityGovernor`)**: Enable
  `game.qualityGovernor.enabled = true` to compare the cost of every rendered frame with the frame
  budget, with hysteresis and cooldowns (`overBudgetFramesThreshold`, `underBudgetFramesThreshold`,
  `cooldownSeconds`), stepping `effectiveRenderScale` and `effectiveParticleDensity` down during
  GPU spikes and recovering smoothly when headroom returns. The cost is the smoothed hardware
  `FrameTiming` span when the platform reports it, otherwise the CPU time of `update` plus
  `render`. The budget is that of the active framerate (`activeTargetFps`, or the display refresh
  rate when uncapped), also while the game is idle-throttled, and no sample is taken for ticks that
  do not render.
- **Zero-Rebuild `backgroundColorValue` & `SceneResourceBudget`**: Mutate
  `game.backgroundColorValue` (`backgroundColorListenable`) to update `GameWidget`'s backdrop color
  via an isolated `ValueListenableBuilder` without rebuilding `GameWidgetState`. Configure
  `game.resourceBudget.maxBudgetBytes` (`SceneResourceBudget`) to track offscreen RGBA8 VRAM usage
  and automatically evict least-recently-used `Snapshot` raster surfaces via `trimToBudget()`.
- **Harmonic VSync Divisor & `FpsPolicy`**: Configure `game.fpsPolicy` (`FpsPolicy.powerSave30()`,
  `FpsPolicy.locked60()`, `FpsPolicy.harmonicHalf()`, `FpsPolicy.nativeDisplay()`,
  `FpsPolicy.uncapped()`) or `game.targetFps`. A cap is always measured in elapsed time. When it
  divides the display refresh rate (e.g. 60 FPS on 120 Hz or 72 FPS on 144 Hz -> every 2nd refresh,
  60 FPS on 240 Hz -> every 4th), the frame interval is snapped to that whole number of display
  periods and the loop locks onto the beat without drifting. When it does not (60 FPS on 90 Hz or
  144 Hz, 120 FPS on 144 Hz), the cap is met on average: frames start on a refresh, so their
  spacing alternates. Because time is measured, a cap keeps its rate when the display delivers
  frames slower or faster than the refresh rate the platform reports.
- **Decoupled Simulation vs Render Rate (`renderTargetFps` & `renderInterpolationAlpha`)**: Cap GPU
  rasterization rate via `game.renderTargetFps` independently of `targetFps` / `fixedTimeStep`,
  inspecting `executedUpdateTicks`, `executedRenderFrames`, `skippedRenderFrames`, and
  `renderInterpolationAlpha`.
- **Dirty-Scene On-Demand Rendering (`IdleRenderMode`)**: Set
  `game.idleRenderMode = IdleRenderMode.onDemandWhenIdle` (or `IdleRenderMode.onDemand`) to skip
  `markNeedsPaint()` (`skippedCleanPaints`) whenever transforms, component structure, camera,
  effects, and particles are stationary, while keeping `update(dt)` timers active. The stock
  components report the changes of their picture that do not move them: a new `sprite`, another
  `current` sprite or animation, an animation frame, a scrolling parallax, typed text, a new
  `paint`. Call `game.markSceneDirty()` for custom procedural canvas changes, and for changes that
  cannot be observed, such as `paint.color = ...` on an existing `Paint`, decorator properties,
  `debugMode`, or the position of a viewport.
- **Hardware `FrameTiming` Percentiles & `FrameBudgetScheduler`**: `RenderFrameTelemetry` and
  `HasFrameTelemetry` capture `SchedulerBinding` UI/raster durations into zero-allocation ring
  buffers (`smoothedBuildMs`, `smoothedRasterMs`, `p95FrameMs`, `p99FrameMs`, `jankFrameCount`,
  `isGpuBound`), while `game.scheduleFrameTask(...)` (`FrameBudgetScheduler`) amortizes scene
  preparation callbacks across frames within remaining microsecond budgets with anti-starvation
  guarantees (`maxStarvationFrames`).
