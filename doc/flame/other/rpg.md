# RPG Systems, Event Fibers, Dialogue, Tactics & Inventory (`package:flame/rpg.dart`)

Flame includes a modular, opt-in suite of RPG, Tactical RPG, and Visual Novel primitives spanning
`package:flame/rpg.dart`, `package:flame/text.dart`, `package:flame/navigation.dart`,
`package:flame/audio.dart`, `package:flame/layout.dart`, and `package:flame/rendering.dart`.

## 1. World State Blackboard, Cooperative `EventFiber` & `EventPageComponent` (`package:flame/rpg.dart`)

- **`WorldStateBlackboard`**: Bit-packed switches, numeric/string variables, `(mapId, eventId, channel)`
  self-switches, persistent `MapEntityDelta` ledger (opened chests, pushed boulders, defeated bosses),
  `O(affected)` targeted key watchers, and JSON save/restore snapshots.
- **`EventScriptBuilder`, `EventFiber` & `EventPageComponent`**:
  - Zero-GC cooperative event command VM supporting `waitSeconds`, `waitPredicate`, dialogue/choice
    awaits, `MoveRoute` awaits, nested `CommonEvent` `call`/`return` stacks, `loop`/`breakLoop`,
    mid-cutscene `saveState()` / `restoreState()`, and infinite-loop watchdog protection
    (`maxInstructionsPerTick`).
  - Reactive highest-index `EventPage` selector (`actionButton`, `playerTouch`, `eventTouch`,
    `autorun` player-input lock, and 1-pass-per-frame `parallel` background tickers).

## 2. Dynamic Unicode Font Atlases, CLDR Localization & `DialogueBoxComponent` (`package:flame/text.dart`)

- **`DynamicFontAtlas`**: On-demand shelf-packed multi-page GPU glyph atlas rasterizing arbitrary
  Latin, Cyrillic, CJK, and symbol runes at first encounter without invalidating previously baked
  `(pageIndex, atlasRect)` coordinates.
- **`LocalizationTable`**: Keyed locale dictionary with `{param}` interpolation, CLDR plural rules
  (`one` / `few` / `many` / `other` for Slavic, Germanic, Romance, and East Asian languages),
  `{gender:...}` inflection, fallback locale chains, and live `localeSignal` hot-swapping.
- **`DialogueBoxComponent`**:
  - Upfront lookahead word-wrapping so words never jump to the next line mid-typewriter reveal.
  - Inline control tags: `[color=#RRGGBB]`, `[/color]`, `[shake]`, `[wave]`, `[speed=x]`, `[wait=s]`,
    `[instant]`, `[/instant]`, `[sfx=id]`, `[portrait=id:emotion]`, `[shakeCam=trauma]`, `[page]`,
    and `{var:id}` / `{actor:id}`.
  - Per-character `VoiceBlipConfig` pitch-jittered voice synth (automatically skipping whitespace and
    punctuation), two-stage `advanceOrSkip()`, and integrated branching choice prompt.

## 3. Grid/Sub-Tile Locomotion, Caterpillar Followers, Paper-Doll & Symmetric Fog of War

- **`GridCharacterMotor` & `PartyCaterpillarChain` (`package:flame/rpg.dart`)**:
  - Dual `CharacterMovementMode.tileLocked` (buffered input queue, zero-lag step start, continuous
    `stridePhase`) and `freeSubTile` (8-way normalized AABB slide with doorway corner-rounding assist),
    plus `MoveRoute` scripting with parabolic jump arcs and bridge elevation transitions.
  - Ring-buffer breadcrumb follower chain collapsing smoothly onto the leader's tile on teleport or
    doorway entry.
- **`CharacterSpriteSheet` & `PaperDollCompositor` (`package:flame/rpg.dart`)**: 4/8-direction
  `0-1-2-1` stride sheet helper + LRU-cached single-`ui.Image` composite baker for multi-layer
  character equipment (`body + eyes + hair + armor + cloak + weapon`) with deterministic GPU disposal.
- **`ShadowcastFogOfWar` (`package:flame/navigation.dart`)**: Zero-allocation 8-octant recursive
  shadowcasting (`unexplored` / `exploredShroud` / `visible`) using exact integer rational slopes for
  strict mathematical floor-to-floor LOS symmetry (`hasLineOfSight(A, B) == hasLineOfSight(B, A)`).

## 4. GAS Attributes, `FormulaVM`, Turn Timeline & Tactical Range/AoE

- **`AttributeSet`, `StatusEffectContainer` & `FormulaVM` (`package:flame/rpg.dart`)**:
  - Gameplay Ability System modifier pipeline (`flatAdd`, `percentAdd`, `percentMul`, `finalOverride`,
    `StatCurve` level tables/polynomials, dirty-flag lazy caching).
  - Stacking/immunity/dispel status container ticking on both combat turns and overworld map steps.
  - AOT RPN bytecode `FormulaVM` (`a.atk * 4 - b.def * 2`, `if`, `clamp`, `pow`, `lerp`, deterministic
    `SeededRng` variance, critical multiplier, and `NaN`/`/0` guards).
- **`TurnTimelineScheduler` (`package:flame/rpg.dart`)**: Supports `roundPriority`, `activeTimeBattle`
  (with sub-menu `waitMode` freeze), and `conditionalTurnBased` (`CTB`) with non-destructive
  `previewTurnOrder` for hypothetical quick vs heavy skill previews.
- **`TacticalRangeSolver` & `GridAreaTemplate` (`package:flame/navigation.dart`)**: Zero-allocation
  binary-heap Dijkstra solver with enemy Zone-of-Control (`ZOC`) pinning, ally pass-through without
  stacking, asymmetric `maxClimb`/`maxDrop` cliffs, and red attack-threat fringes, paired with wall-aware
  `diamond`, `square`, `cross`, `cone`, `rayLine`, `ring`, and `hexRadius` AoE templates.

## 5. Sample-Loop BGM Stack, Window Skins, Combat Popups, Loot & Quest DAG

- **`BgmTransportStack` (`package:flame/audio.dart`)**: Sample-accurate `[loopStartSeconds..loopEndSeconds)`
  looping (playing `[0..loopStart)` intros once), Overworld -> Battle push/pop cursor restoration, and
  `playMusicalEffect` fanfares with automatic BGM pause/duck and fade-in resume.
- **`WindowSkinComponent`, `CommandListWindow`, `PagedGridWindow` & `FloatingCombatTextPool` (`package:flame/layout.dart`)**:
  9-slice framed RPG windows (`openness` `0..1` fold animation, gliding cursor, scroll arrows,
  `O(visible_rows)` `10,000+`-row virtualization) and SoA multi-hit staggered combat number popups
  rendered in `1` `Canvas.drawRawAtlas` call.
- **`LootTable<T>`, `InventoryContainer`, `EquipmentLoadout` & `QuestJournalMachine` (`package:flame/rpg.dart`)**:
  Weighted hierarchical loot with `LootPityTracker` bad-luck protection and unique-drop filtering;
  slot/weight-capped inventory with atomic two-handed/offhand equipment swaps and side-effect-free
  `previewEquipStatDiff`; and event-driven DAG quests (`allOf`, `anyOf`, `sequential`, failure
  recovery branches, `WorldEventBus` binding, and JSON serialization).
- **`NormalMappedSpriteBatch` & `WaterSurface2DComponent` (`package:flame/rendering.dart`)**:
  Per-quad 2D dynamic point-light shading for pixel-art props (`dot(N, L)` evaluated at the four
  corners of each sprite from a face normal plus bevel curvature and interpolated across it) and
  animated 2D water surfaces with shoreline foam, wave-rippled reflections, and sun specular
  glints.
