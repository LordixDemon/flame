# Engine Fundamentals & Core Subsystems

Flame 2.0 includes a battery of zero-allocation foundational subsystems spanning asset lifecycles,
action-mapped input, deterministic gameplay architecture, kinematic physics, grid topologies,
pathfinding, 2D/3D procedural rendering, audio mixing, responsive scene layout, and CI benchmarks.

---

## 1. Asset Pipeline, Dynamic Atlases & Streaming (`package:flame/cache.dart`)

- **`AssetScope` & `Images.clearIfUnretained`**: Reference-counted scene/route asset bundles with
  weighted loading progress (`0.0..1.0`) and deterministic GPU `ui.Image` eviction on `dispose()`
  that preserves textures still retained by other active scopes.
- **`MaxRectsBinPacker`, `DynamicSpriteAtlas` & `DynamicSpriteAtlasBuilder`**: Runtime MaxRects
  (Best-Short-Side-Fit) bin packing with a **1 px extruded border gutter** around every packed
  sprite to eliminate bilinear/scale bleeding across tiles and sprites.
- **`MipChainImage` & `ResolutionVariantResolver`**: Box-filtered GPU mipmap pyramids (`levelCount`,
  `imageForScale(effectiveScale)`) that prevent shimmering when zoomed out, plus automatic `@3x` /
  `@2x` / `1x` asset path candidate resolution for HiDPI displays.
- **`AsyncAssetStreamer` & `StreamCancellationToken`**: Concurrency-bounded background asset queue
  paired with `FlameGame.frameBudgetScheduler` so texture uploads never stall active gameplay VSync
  ticks.

---

## 2. Unified Input, Context Stack, Focus & Haptics (`package:flame/input.dart`)

- **`InputMap`, `ActionBinding` & `InputAxis2D`**: Semantic action bindings (`isPressed`,
  `justPressed`, `justReleased`, `actionValue`, `axis2D`) unifying keyboard keys, mouse buttons, and
  virtual/gamepad axes with radial deadzones and runtime JSON key-rebinding (`toJson` /
  `applyBindingsJson`).
- **`InputContext`, `InputContextStack` & `InputBuffer`**: Modal input routing (`gameplay` ->
  `hudPopup` -> `cutscene` with `blocksLowerContexts`) plus frame-accurate **coyote time** and
  pre-landing action buffering (`recordAction`, `consumeBuffered`, `isCoyoteActive`).
- **`FocusableComponent` & `FocusNavigationGroup`**: Spatial D-pad / arrow-key / Tab focus
  traversal (`FocusDirection` cone scoring + explicit neighbor overrides) for menus, inventories,
  and board tiles without Flutter widget focus overhead.
- **`HapticEngine`, `HapticPattern` & `HapticBackend`**: Semantic tactile patterns (`lightTap`,
  `heavyImpact`, `selectionTick`, `doublePulse`, `rumbleBurst`) with global intensity, cooldown
  throttling, and deterministic `RecordingHapticBackend` test verification.

---

## 3. Gameplay Architecture, Determinism & Persistence (`package:flame/components.dart`, `package:flame/math.dart`)

- **`Signal<T>`, `WorldEventBus` & `HasEventBusSubscriptions`**: Typed zero-string synchronous
  signals (`connect`, `connectOnce`) and `World.eventBus` (`emit` immediate + `enqueue` deferred
  end-of-`World.updateTree` flush) with automatic subscription cleanup on component removal.
- **`StateMachine<S, E>` & `StateMachineComponent<S, E>`**: Hierarchical Finite State Machine
  (HFSM) with Lowest Common Ancestor (LCA) `onExit`/`onEnter` traversal, guarded event transitions,
  `elapsedInState`, and pushdown state stack (`pushState` / `popState`).
- **`SeededRng` & `CommandRecorder<C>`**: Deterministic 32-bit safe Xoshiro128** PRNG
  (`saveState` / `restoreState`, non-mutating `fork(label)`, weighted choice, Fisher-Yates shuffle,
  unit-circle/annulus sampling) plus tick-indexed deterministic command recording and replay.
- **`HasTags` & `WorldQuery<T>`**: Incremental `O(1)` cached component queries registered on
  `World.registerQuery` filtering by component type `T`, `withTags`, `withoutTags`, and predicate
  callbacks.
- **`PrefabRegistry`, `SaveMigrationChain` & `StateSnapshotStore`**: Data-driven component
  blueprints with parameter overrides and versioned JSON save envelopes protected by IEEE 802.3
  CRC32 checksums and sequential `v1 -> v2 -> vN` schema migrations.

---

## 4. Collision Layers, Manifolds, ShapeCasts & Kinematics (`package:flame/collisions.dart`)

- **32-bit `collisionLayer` & `collisionMask`**: O(1) bitmask filtering (`canCollideWithMask`) on
  `Hitbox` / `ShapeHitbox` integrated directly into both `Sweep` and `QuadTreeBroadphase`.
- **`CollisionManifold2D` & `ShapeCast2D`**: Zero-allocation Minimum Translation Vector (MTV)
  contact normals, penetration depth, and contact points (`circleVsCircle`, `aabbVsAabb`,
  `circleVsRect`), plus swept time-of-impact (`toi` in `[0, 1]`) ray/circle/AABB casts that prevent
  fast-projectile thin-wall tunneling.
- **`KinematicBodyComponent`**: Arcade character & token controller with iterative `moveAndSlide`,
  configurable `maxSlides`, `floorMaxAngle`, `bounciness`, and `isOnFloor` / `isOnWall` /
  `isOnCeiling` contact flags.
- **`TriggerZoneComponent`**: Spatial sensor regions (`circle` / `rect`) powered by
  `WorldSpatialIndex` with `onEntityEntered`, `onEntityStay`, and `onEntityExited` callbacks.

---

## 5. Grids, Pathfinding & Crowd Steering (`package:flame/grid.dart`, `package:flame/navigation.dart`)

- **`SquareGridTopology`, `IsometricGridTopology`, `HexGridTopology` & `AutoTileBitmask`**:
  Bidirectional `cellToWorld` / `worldToCell` projection, cube-coordinate hex rounding, axial ring &
  spiral iterators, Bresenham line-of-sight, and 4-bit / 8-bit Wang corner-gated auto-tile masks.
- **`AStarGridPathfinder`, `GraphPathfinder<N>` & `FlowField2D`**: Zero-allocation binary-heap A*
  on weighted/blocked grids (with optional corner-cutting prevention) and arbitrary waypoint graphs
  (board loops, branching forks), plus Dijkstra integration + normalized flow fields for steering
  hundreds of units simultaneously.
- **`FormationSlots` & `SeparationSteering2D`**: Multi-unit tile/party slot offsets (`ring`, `grid`,
  `wedge`, `line`) so co-located tokens never overlap, plus `SpatialGrid2D`-accelerated zero-alloc
  crowd separation impulses.

---

## 6. 2D/3D Procedural Rendering, Lighting & Post-FX (`package:flame/rendering.dart`, `package:flame/post_process.dart`, `package:flame/canvas3d.dart`)

- **`RibbonTrailComponent`, `SplineStripMesh2D` & `VerletRope2D`**: Smooth width/color-tapered
  motion trails, Catmull-Rom curved 2D triangle strips, and Verlet + Jakobsen distance-constrained
  ropes, chains, and banners rendered in a single `Canvas.drawVertices` call.
- **`SpriteAnimationTicker` Frame Events, `AttachmentSocket2D`, `SpringBone2D`/`3D` &
  `AnimationStateTree<S>`**: Deterministic keyframe callbacks (even across large `dt` spikes),
  named weapon/hat/VFX sockets, analytical spring-damper secondary motion, and state-driven sprite
  animation trees with automatic one-shot return transitions.
- **`Light2DLayer`, `PointLight2D`, `SpotLight2D` & `ShadowOccluder2D`**: Dynamic 2D multiply +
  additive lighting layer with CPU-extruded 2D shadow volumes.
- **`BloomPostProcess`, `VignettePostProcess`, `ChromaticAberrationPostProcess`,
  `ColorGradingPostProcess` & `OutlineDecorator`**: Ready-to-use `PostProcessStage` implementations
  and selection silhouette decorator requiring zero external `.frag` shader asset files.
- **`Mesh3D` UV Coordinates, `Node3D` & `Decal3D`**: Textured `Mesh3D` UV channels (`plane`, `box`,
  `fromDMeshBytes` `DM3D` v1/v2) batched through `BatchMeshRenderer3D` (`textureShader` +
  `uvRectPx`), hierarchical TRS `Node3D` scene transforms, and projected ground `Decal3D` quads.

---

## 7. Audio Mixer, Ducking & Spatial Sound Cues (`package:flame/audio.dart`)

- **`AudioMixer`, `AudioBus`, `DuckingRule` & `AdaptiveMusicController`**: Hierarchical buses
  (`master` -> `music`, `sfx`, `ui`, `voice`, `ambient`), automatic sidechain-style ducking (e.g.
  lowering `music` while `voice` is active), synchronized multi-stem adaptive music crossfades, and
  pluggable `AudioBackend` (`InMemoryAudioBackend` for headless tests).
- **`SoundCue`, `SoundCueMixerPlayer` & `SpatialAudioListener2D`**: Randomized clip pools (no
  immediate repeat), pitch/volume jitter, per-cue cooldowns, polyphony limits (`VoiceStealPolicy`),
  and 2D listener distance attenuation + stereo panner.

---

## 8. Responsive World/HUD Layout, Rich Batched Text & Profiling (`package:flame/layout.dart`, `package:flame/text.dart`, `package:flame/debug.dart`)

- **`RowLayoutComponent`, `ColumnLayoutComponent`, `GridLayoutComponent` &
  `NineSlicePanelComponent`**: Lightweight zero-Widget Flex/Grid layout containers and GPU 9-slice
  scalable UI panels (`Canvas.drawImageNine` with procedural fallback).
- **`RichBatchedTextComponent` & `RichTextIconSpan`**: Inline markup (`<color=#HEX>`, `<scale=x>`,
  `<wave>`, `<shake>`, `[icon:key]`) + `startTypewriter` reveal rendered via `RasterFontAtlas` into
  batched `Canvas.drawRawAtlas` calls per texture.
- **`EngineDebugOverlay` & `SceneBenchmarkRunner`**: Live in-engine FPS / frame-time sparkline /
  draw-call / VRAM / spatial-picker HUD (`EngineDebugOverlay`) and deterministic headless benchmark
  runner (`SceneBenchmarkRunner.run` + `SceneBenchmarkBudget`) for automated CI performance gates.
