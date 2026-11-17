# High-Resolution Rendering, Graphics Quality & FPS Management

Flame 2.0 includes an integrated scene resolution, graphics quality tiering, dynamic resolution
scaling (DRS), GPU surface memory budgeting, and harmonic VSync / dirty-scene frame pacing pipeline
designed for 60–240 Hz mobile, desktop, and web displays.


## Live HiDPI `DisplayMetrics`

`Game.displayMetrics` returns a `DisplayMetrics` snapshot (`devicePixelRatio`, `physicalSize`,
`logicalSize`, `refreshRate`) of the values below, which `GameRenderBox` synchronizes automatically
when it is attached, when the `GameWidget` is rebuilt, and on
`WidgetsBindingObserver.didChangeMetrics` (including dragging a window between a 1x external monitor
and a 2x/3x Retina display):

- `Game.rawDevicePixelRatio` (`double`) — physical pixels per logical pixel (`FlutterView.devicePixelRatio`).
- `Game.devicePixelRatio` (`double`) — effective pixel ratio capped by `maxDevicePixelRatio` and
  `GraphicsProfile.maxDevicePixelRatio`.
- `Game.physicalCanvasSize` (`Vector2`) — current canvas dimensions in physical pixels
  (`DisplayMetrics.physicalSize`).
- `Game.displayRefreshRate` (`double`) — detected display refresh rate in Hz (`Display.refreshRate`,
  e.g. `60`, `120`, `144`, `240`).

`Game.onDisplayMetricsChanged(double devicePixelRatio, double refreshRate)` fires whenever display
metrics change, re-propagating live DPR across `PostProcess` / `PostProcessPipeline` stages and
`Snapshot` surfaces configured with `SnapshotResolutionPolicy.autoHiDpi` or
`SnapshotResolutionPolicy.autoHiDpiAndZoom`.


## Dynamic `worldRenderScale` (SSAA / Sub-Native Scaling) & `ContrastAdaptiveSharpenPostProcess`

`CameraComponent.worldRenderScale` (`0.25 .. 2.5`) controls the offscreen rasterization resolution
of the camera's `World` while keeping `camera.viewport` HUD children crisp at `1:1` native display
resolution:

- `1.0` *(default)*: direct zero-copy canvas rendering with `0` intermediate `Picture.toImageSync`
  allocations.
- `< 1.0` *(e.g. `0.5`–`0.95`)*: rasterizes the world at reduced pixel density for GPU fill-rate
  relief and upscales via `upscaleFilterQuality`, `upscaleSharpness`, or a custom `upscaleShader`.
- `> 1.0` *(e.g. `1.25`–`2.5`)*: supersamples (SSAA) fine diagonal geometry, thin strokes, and 3D
  edges, downsampling cleanly onto the viewport.

Pair sub-native scaling (`0.65`–`0.90`) with `ContrastAdaptiveSharpenPostProcess`
(`ContrastAdaptiveSharpenHelper`) to restore crisp edge contrast:

```dart
camera.worldRenderScale = 0.85;
camera.postProcess = ContrastAdaptiveSharpenPostProcess(
  strength: 0.5,
  shader: optionalCasFragmentShader,
);
```


## HiDPI `Snapshot` Caching, Subpixel `PixelSnapMode`, and Tiled 4K/8K Export

- **`SnapshotResolutionPolicy`**: Set `snapshotResolutionPolicy` on `Snapshot` components to
  `SnapshotResolutionPolicy.autoHiDpi` or `SnapshotResolutionPolicy.autoHiDpiAndZoom` to bake
  cached `ui.Image` surfaces at physical pixel density across quantized zoom buckets
  (`[0.5, 1.0, 1.5, 2.0, 3.0, 4.0]`) with hysteresis (`zoomBucketHysteresis = 0.12`) and a GPU
  dimension safety ceiling (`maxSnapshotTextureDimension = 4096`).
- **`PixelSnapMode`**: Set `camera.pixelSnapMode = PixelSnapMode.physicalPixel` (or `logicalPixel`)
  to quantize camera viewfinder translations to exact pixel boundaries during rendering without
  mutating logical `viewfinder.position`.
- **Tiled High-Resolution Export**: Call
  `camera.renderHighResImageSync(width: 3840, height: 2160, tileSize: 2048)` (or async
  `renderHighResImage`) to export crisp 4K/8K captures safely within GPU texture limits.


## `GraphicsSettingsController`, `GraphicsProfile` & Dynamic Resolution Governor (DRS)

`FlameGame.graphics` (`GraphicsSettingsController`) manages presets (`GraphicsQualityTier.low`,
`medium`, `high`, `ultra`, `custom`) and immutable `GraphicsProfile` snapshots:

| Field | `low` | `medium` | `high` | `ultra` |
| --- | --- | --- | --- | --- |
| `renderScale` | `0.65` | `0.85` | `1.0` | `1.25` |
| `maxDevicePixelRatio` | `1.5` | `2.0` | `2.5` | `3.5` |
| `shadowsEnabled` | `false` | `true` | `true` | `true` |
| `shadowOpacityScale` | `0.0` | `0.75` | `1.0` | `1.0` |
| `postProcessEnabled` | `false` | `true` | `true` | `true` |
| `auxiliaryPassScale` | `0.25` | `0.5` | `0.75` | `1.0` |
| `particleDensity` | `0.35` | `0.65` | `1.0` | `1.35` |
| `lodBias` | `-0.45` | `-0.15` | `0.0` | `0.35` |
| `ambientMotionEnabled` | `false` | `true` | `true` | `true` |
| `antiAliasing` | `false` | `true` | `true` | `true` |

```dart
// Switch preset or customize individual parameters:
game.graphics.setTier(GraphicsQualityTier.high);

// Enable hysteresis-guarded Dynamic Resolution & Particle Scaling (DRS):
game.qualityGovernor
  ..enabled = true
  ..minRenderScale = 0.55
  ..maxRenderScale = 1.0
  ..scaleStepDown = 0.10
  ..scaleStepUp = 0.05
  ..cooldownSeconds = 1.0;
```

The governor takes one sample per rendered frame: the smoothed hardware `FrameTiming` span when
the platform reports it, otherwise the CPU time of `update` plus `render`. It compares the sample
with the frame budget of the active framerate (`Game.activeTargetFps`, or the display refresh rate
when uncapped). The idle throttle (`idleFps`) does not enlarge that budget, and ticks that do not
render are not sampled, so the render scale holds still while the game is idle.

Components automatically adapt to `GraphicsProfile`:
- Every `Component` and `PositionComponent` exposes `GraphicsQualityTier? minQualityTier` — when
  `game.graphics.tier` is below `minQualityTier`, both `updateTree` and `renderTree` skip it.
- `ParticleEmitterComponent` scales emission rates and burst counts by
  `graphics.effectiveParticleDensity` (`respectGraphicsParticleDensity`).
- `Shadow3DDecorator` (`respectGraphicsShadows`) and `BatchMeshRenderer3D.applyGraphicsProfile`
  gate shadow passes automatically on low tiers.
- Custom components can mix in `HasGraphicsAdaptation` and override
  `onGraphicsProfileChanged(GraphicsProfile profile, GraphicsQualityTier tier)`.


## Declarative `PostProcessPipeline`

`PostProcessPipeline` chains named `PostProcessStage`s with automatic `minQualityTier`,
`activePredicate`, and per-stage `resolutionScale` (e.g. `0.5` half-res bloom):

```dart
camera.postProcess = PostProcessPipeline(
  stages: [
    PostProcessStage(
      name: 'bloom',
      postProcess: bloomPostProcess,
      minQualityTier: GraphicsQualityTier.high,
      resolutionScale: 0.5,
    ),
    PostProcessStage(
      name: 'cas',
      postProcess: ContrastAdaptiveSharpenPostProcess(strength: 0.45),
      minQualityTier: GraphicsQualityTier.medium,
    ),
  ],
);
```

When all stages are filtered out (or `postProcessEnabled == false`), `PostProcessPipeline` executes
a **zero-`toImageSync` direct bypass** (`bypassedLastFrame == true`) onto the canvas.


## GPU Surface Budget (`SceneResourceBudget`) & Reactive `backgroundColorValue`

- **`FlameGame.resourceBudget` (`SceneResourceBudget`)**: Tracks offscreen RGBA8 GPU `ui.Image` byte
  footprints (`width * height * 4`), automatically evicting least-recently-used `Snapshot` caches
  via `trimToBudget()` when `totalEstimatedBytes > maxBudgetBytes` (default `96 MiB`).
- **`Game.backgroundColorValue` (`backgroundColorListenable`)**: Dynamically updates `GameWidget`'s
  backdrop via an isolated `ValueListenableBuilder<Color?>` + `ColoredBox`, causing **`0`
  `GameWidgetState` rebuilds**.


## Harmonic `FpsPolicy`, Decoupled `renderTargetFps` & `IdleRenderMode`

- **`FpsPolicy` & Exact VSync Divisors**: Set `game.fpsPolicy` to `FpsPolicy.powerSave30()`,
  `FpsPolicy.locked60()`, `FpsPolicy.harmonicHalf()`, `FpsPolicy.nativeDisplay()`,
  `FpsPolicy.uncapped()`, or `FpsPolicy.custom(fps)`. A cap is always measured in elapsed time, so
  it keeps its rate when frames arrive slower or faster than the reported `displayRefreshRate`.
  When the target FPS divides `displayRefreshRate` evenly (e.g. `60` FPS on `120 Hz` -> divisor
  `2`; `72` FPS on `144 Hz` via `harmonicHalf()` -> divisor `2`; `60` FPS on `240 Hz` -> divisor
  `4`; see `FpsPolicy.harmonicDivisor`), the frame interval is snapped to that whole number of
  display periods and `GameLoop` locks onto every Nth refresh without drift, tolerating a quarter
  of a display period of timestamp jitter. A cap that does not divide the refresh rate (`60` FPS
  on `90` or `144 Hz`, `120` FPS on `144 Hz`) is met on average: the time by which a frame
  overshoots its interval is carried over to the next one.
- **Decoupled `renderTargetFps` & `renderInterpolationAlpha`**: Run `updateTree` at full rate (or
  deterministic `fixedTimeStep`) while capping GPU rasterization via `game.renderTargetFps = 30.0`,
  exposing `renderInterpolationAlpha` (`0.0..1.0`), `executedUpdateTicks`, `executedRenderFrames`,
  and `skippedRenderFrames`. A render rate that does not divide the update rate is met on average.
- **Dirty-Scene Rendering (`IdleRenderMode`)**: Set
  `game.idleRenderMode = IdleRenderMode.onDemandWhenIdle` (or `IdleRenderMode.onDemand`) to skip
  `RenderBox.markNeedsPaint` (`skippedCleanPaints`) whenever transforms, structure, camera, effects,
  and particles are stationary. `onDemandWhenIdle` only does so while the idle throttle is engaged,
  which requires `idleFps` to be set. Stock components report the changes of their picture that do
  not move them (`sprite`, the `current` sprite or animation, animation frames, parallax scrolling,
  typed text, `paint`) through `Component.markSubtreeDirty()` and `Game.notifyVisualMutation()`;
  a component that draws by itself does the same, or calls `game.markSceneDirty()`.


## Hardware `FrameTiming` Telemetry & `FrameBudgetScheduler`

- **Hardware CPU vs GPU Telemetry (`HasFrameTelemetry` / `RenderFrameTelemetry`)**: Captures
  `SchedulerBinding` `FrameTiming` samples in a zero-allocation 120-frame ring buffer, exposing
  `smoothedBuildMs`, `smoothedRasterMs`, `smoothedTotalSpanMs`, `p95FrameMs`, `p99FrameMs`,
  `jankFrameCount`, and `isGpuBound`.
- **Amortized `FrameBudgetScheduler` (`game.frameBudgetScheduler` / `game.scheduleFrameTask`)**:
  Queue scene preparation tasks (`scheduleFrameTask(() => ..., priority: 10)` or
  `scheduleFrameTaskSync`) to drain within remaining intra-frame microsecond budgets with an
  anti-starvation guarantee (`maxStarvationFrames`).
