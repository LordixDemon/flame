# Chunked Tilemaps, Autotiles, Multi-Elevation Passage & World Streaming (`package:flame/tilemap.dart`)

`package:flame/tilemap.dart` provides a zero-allocation, chunk-cached 2D/HD-2D tilemap, autotile,
collision/elevation passage, interior cutaway, room camera clamping, seamless world streaming, and
relational database loader pipeline.

## 1. `TileGid` & `AutotileComposer` (`A1`–`A4` Quarter-Tile Synthesis)

- **`TileGid`**: Allocation-free bit-packed `int` encoding a 28-bit tile ID plus full dihedral `D4`
  orientation flags (`flipHorizontal`, `flipVertical`, `flipAntiDiagonal`, `compose`, `tileId`,
  `transformFlags`).
- **`AutotileComposer`**: Decomposes logical map tiles into `4` half-tile sub-quads (`TL`, `TR`,
  `BL`, `BR`) with zero-bleed half-texel inset UVs:
  - **`AutotileKind.a1AnimatedLiquid`**: Animated water, waterfalls, lava, and shore foams with
    synchronized `0-1-2-1` ping-pong or linear frame cycles (`resolveFrameBank`).
  - **`AutotileKind.a2GroundBlob`**: Full 47-state cardinal + diagonal inner-corner terrain blob
    synthesis (grass, dirt, carpets, roads, paths).
  - **`AutotileKind.a3BuildingFacade`**: 16-state rectangular building roofs and facades.
  - **`AutotileKind.a4WallCliff`**: Crown tops + vertical cliff wall faces with automatic top/bottom
    cap detection.

## 2. `TilesetAtlas`, `ChunkedTilemapComponent` & `YSortLayerComponent`

- **`ChunkedTilemapComponent`**:
  - Partitions maps of any size (e.g. `512x512+`) into `16x16` spatial chunks culled against the
    live camera frustum (`visibleChunksLastFrame`).
  - Coalesces non-mirrored tiles (`0°`, `90°`, `180°`, `270°`) into a single `Canvas.drawRawAtlas`
    call (`Float32List` `RSTransform` buffers) and mirrored dihedral `D4` tiles into an indexed
    `Vertices.raw` batch with exact pixel-corner placement.
  - Pre-bakes separate `RSTransform` / UV frame banks per `A1` animation frame so animated water
    cycles across the entire map in `O(1)` bank switches with **`0` chunk geometry rebuilds**
    (`chunkRebuildCount == 0`).
  - A map without animated tiles never marks itself dirty or reports a visual mutation while idle;
    only maps with animated tiles in view do, once per animation step. Replaced `ui.Vertices` are
    disposed.
  - `setTileGid(col, row, gid)` rebuilds only the touched chunk (plus neighbor chunk on autotile
    seam boundaries).
- **`YSortLayerComponent`**: Dynamic Y+elevation-sorted scene layer (`ySortKey` + `elevationZ`) with
  deterministic insertion-order tie-breaking (`0` per-frame heap allocations or flicker).

## 3. `TilePassageGrid` & `RoofCutawayController`

- **`TilePassageGrid`**: Compact `Uint16List` per-cell flag grid supporting:
  - Per-edge directional blocking (`passNorth`, `passEast`, `passSouth`, `passWest`) for one-way
    ledges and thin fences (`canStep`),
  - **`bridgeOverpass` (`elevation = 0` underpass vs `elevation = 1` overpass)**: Units walking
    under a bridge stay on `z = 0` and cannot step sideways off the deck, while units entering from
    high ground cross cleanly on `z = 1` (`resolveStep`),
  - **`counter` reach-through**: `probeInteractionTarget` reaches shopkeepers/NPCs across counter
    desks (`1`–`2` tiles ahead),
  - **`starOverhead`**, **`bush`** (lower-body depth translucency), **`ladder`** (facing lock),
    **`damageFloor`**, **`terrainTag`** (`0..7` footsteps/VFX), and **`regionId`** (`0..255`
    encounter/trigger zones).
- **`RoofCutawayController` & `RoofOcclusionZone`**: Smoothly fades roof/canopy layers toward
  `cutawayAlpha` when the player enters an interior room AABB (`opacityOfZone`).

## 4. `RoomCameraBounds` & `ConnectedWorldStreamer`

- **`RoomCameraBounds`**: Clamps camera centers inside rectangular or custom `CameraZone` rooms,
  automatically centering small rooms narrower or shorter than the viewport without oscillation, and
  interpolating cleanly across doorway zone transitions.
- **`ConnectedWorldStreamer` & `WorldPortalLink`**: Preloads 1-hop neighbor maps asynchronously around
  the active map, offsets seamlessly stitched overworld chunks, and evicts distant maps via an LRU
  budget (`maxResidentMaps`) while protecting the active map and its direct neighbors.

## 5. `TileMapDocument` (`JSON` + `DTMP`) & `DataTableRegistry`

- **`TileMapDocument`**: Round-trip `JSON` and compact `DTMP` little-endian binary map codec storing
  tile layers, `TilePassageGrid` flags/regions, `CameraZone`s, `RoofOcclusionZone`s,
  `WorldPortalLink`s, and `TileMapEntitySpawn` blueprints instantiated directly through
  `PrefabRegistry`.
- **`DataTableRegistry` & `ForeignKeyRule`**: Typed relational RPG database loader (`actors`,
  `classes`, `skills`, `items`, `weapons`, `armors`, `enemies`, `troops`, `states`) with cross-table
  foreign-key integrity validation (`validateIntegrity()`).
