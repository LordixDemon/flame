# Large Worlds

This page covers what keeps big scenes affordable: frustum culling, merging static props into few
draws, occlusion culling, a 64-bit floating origin, heightmap terrain, grass and other foliage,
projected decals and streaming the world in chunks.

Only frustum culling is automatic. Everything else is opt-in: components you add to the world
(`StaticMeshBatcher3D`, `ChunkedTerrain3D`, `FoliageSystem3D`, `VolumeDecalBatch3D`,
`FloatingOriginController3D`, `WorldChunkStreamer3D`) or helpers whose answers you apply yourself
(`OcclusionCuller3D`, `PortalOcclusionGraph3D`). They are exported by
`package:flame_3d/world_scale.dart`, except `WorldChunkStreamer3D`, which is in
`package:flame_3d/parser.dart`. All of them run on the CPU and draw through the ordinary materials,
so they behave the same on every backend (Metal, Vulkan, OpenGL ES and WebGPU).

The library also exports `LightClusterGrid3D`, a CPU grid that finds which of many lights reach a
part of the view without raising the per-pass light limits (see
[Clustered light grid](lighting.md#clustered-light-grid)).


## Frustum culling and bounds

Every pass tests each `Object3D` against the frustum of its camera (in a shadow pass, the light's
view) before the object records its draws:

- the test uses the object's world-space `aabb`, the union of its own bounds and the bounds of all
  its descendants;
- an object whose box is outside the frustum is skipped together with all its children;
- an object whose box is entirely inside lets its descendants skip their own tests;
- an object whose box crosses the frustum is drawn when its box intersects it, and its children
  are tested one by one.

Objects whose `cameraMask` does not match the camera's are skipped first, and objects with
`visible == false` (or a hidden ancestor) are skipped in every pass, shadows included.

A component that chooses its own level of detail or thins itself out with distance should measure
the distance from `RenderContext3D.viewerPosition`, not `cameraPosition`: in a shadow pass
`cameraPosition` is the origin of the light's view (the world origin for a directional light),
while `viewerPosition` stays the main camera, so the shadow casters match what the camera shows.
The terrain and the foliage on this page do so.

Only `Object3D`s are tested. A `Group3D` or another plain `Component3D` is never culled itself:
its `Object3D` children are tested one by one, so grouping objects under a `Group3D` does not
save tests. Put them under an `Object3D` if a single test should reject the whole group.

An object's own bounds come from `computeLocalAabb`, in its local space; `MeshComponent`,
`ModelComponent`, `InstancedGroup3D` and the components on this page implement it. A custom
`Object3D` that draws something must return bounds that contain everything it draws, or it is
culled while still visible:

```dart
class Windmill extends Object3D {
  @override
  Aabb3? computeLocalAabb() =>
      Aabb3.minMax(Vector3(-3, 0, -3), Vector3(3, 12, 3));

  @override
  void draw(covariant RenderContext3D context) {
    // Record the draws of the windmill here.
  }
}
```

The bounds are cached and recomputed only after the transform of the object or of an ancestor
changes, or after `markAabbDirty()` is called. Call it when the geometry changes without the
transform changing. Geometry that a vertex shader moves (wind sway, displacement) is not part of
the bounds: return bounds wide enough to hold it.

The test costs six plane checks per tested object and pass. `World3D.spatialIndex3DEnabled` does
not change it: the spatial index speeds up raycasts and other queries, not rendering (see
[Geometry and Scene Queries](geometry.md)). To see what culling saves, compare
`renderStats.drawCalls` with the number of objects, and time the `culling` phase with
`RenderProfile` (see [Rendering](rendering.md)).


## Static mesh batching

Each `MeshComponent` costs at least one draw call per surface. A level made of hundreds of
different props (rocks, crates, fences, pillars) that share a few materials can be merged into a
handful of draws with `StaticMeshBatcher3D`: it bakes the instance transforms into the vertices and
concatenates the surfaces that share a material, a vertex layout and their per-instance values into
one `Surface` per cell of a spatial grid.

```dart
final props = StaticMeshBatcher3D(chunkSize: 48);
for (final t in rockTransforms) {
  props.addStaticInstance(mesh: rockMesh, transform: t);
}
for (final t in treeTransforms) {
  props.addStaticInstance(
    mesh: treeMesh,
    transform: t,
    color: const Color(0xFFD8E8C0),
  );
}
world.add(props);
```

To repeat a single mesh many times, use `InstancedGroup3D` instead: one instanced draw, instances
that can move, and a color and `instanceData` per instance (see [Rendering](rendering.md)). The
batcher is for many different meshes that never move.


### What is merged

- Surfaces are grouped by grid cell, by material (the same `Material` object, not an equal one),
  by vertex layout (equal layouts) and by the instance color and instance data they are drawn with
  (see below). One instance's surfaces all go to the cell that holds the center of the mesh's
  bounds after `transform`; a large mesh is not split between cells.
- Only triangle lists can be merged: `addStaticInstance` throws an `ArgumentError` for a surface
  with another topology.
- `chunkSize` is the edge of the grid cells in the batcher's local units (32 by default). Larger
  cells mean fewer draws but coarser frustum culling: each merged surface is culled as a whole.
- `transform` is relative to the batcher; the batcher's own position, rotation and scale apply to
  everything at draw time.
- Positions are transformed, normals are transformed by the inverse transpose and renormalized,
  tangents are transformed and their handedness (`w`) flipped for mirrored transforms, and the
  triangle winding is reversed when the transform mirrors (negative determinant), so mirrored
  instances keep outward normals and correct back-face culling. All other attributes (texture
  coordinates, the second UV set, joints) are copied unchanged.
- A merged surface uses 16-bit indices up to 65,535 vertices and 32-bit indices beyond.


### Per-instance data

Each merged surface is drawn with the `color` and `instanceData` its instances share, so a merged
instance looks as it would on its own:

- `instanceData` is part of the grouping: instances with different instance data (a fade, a
  highlight, an emissive boost) end up in different merged surfaces, each drawn with its data.
- `color`: for a `SpatialMaterial` or an `UnlitMaterial` on a layout with a `vertexColor` attribute
  (the standard layouts have one), the color is multiplied into the vertex colors, which those
  materials multiply exactly as they multiply the instance color; instances of different colors
  then still merge. For any other material (a `StylizedMaterial`, whose instance color tints only
  the vertices of its tint mask, for instance) the color is drawn as the instance color and is
  part of the grouping.

Lost:

- Per-instance behavior that depends on the instance's own transform: wind in `WindSpace.model` or
  `WindSpace.worldScaled` no longer follows each instance's rotation and scale. Other attributes,
  such as `vertexWind`, are copied untransformed.
- Skinning and morph targets: the current vertex data is baked as it is, without joint matrices.
- Separate sorting: a translucent merged surface is sorted as one draw, by its center.
- Picking a single instance: a raycast hit reports the batcher and the merged surface, not the
  slot that was hit.


### Changing the batch

`addStaticInstance` returns a slot id. The merged surfaces are built lazily, on the first draw,
raycast or bounds query after a change, or when you call `bakeDirtyChunks()` (call it during
loading to avoid building on the first visible frame).

- Adding an instance marks its merged surface for a full bake: all the instances of that cell,
  material and layout are transformed again and its buffers rebuilt.
- `setSlotVisible(slot, visible: false)` and `removeSlot(slot)` do not re-transform anything: they
  overwrite the slot's indices with degenerate triangles, or restore them, and upload only that
  range of indices (`Surface.updateIndices`). The merged surface's ray-cast BVH is rebuilt on the
  next raycast. A merged surface whose instances are all hidden is not drawn and adds nothing to
  the batcher's bounds.
- A removed slot's vertices stay in the buffer until the next full bake of its merged surface;
  removing the last slot of a merged surface frees it.
- `clear()` frees everything.

The counters `activeSlotCount`, `chunkCount`, `surfaceBatchCount`, `lastDrawnBatchCount`,
`fullBakeCount` and `surgicalUpdateCount` tell what the batcher holds and did.


### Memory

For each merged surface the batcher keeps on the CPU the merged vertices (stride times 4 bytes per
vertex: 80 bytes with the standard layout), the merged indices, and a 4-byte copy of each index for
restoring hidden slots, plus one GPU buffer with the vertices and indices. The source meshes stay
referenced by the batcher. The first raycast against a merged surface also builds its BVH.


## Occlusion culling

Frustum culling keeps drawing what is behind a wall. Two helpers find such objects:
`OcclusionCuller3D` for any scene with large blockers, and `PortalOcclusionGraph3D` for interiors
made of rooms and doorways. Neither is connected to the renderer: you run them, usually once per
frame in `update`, and hide what they reject, typically through `Component3D.visible`.

Hiding an object with `visible = false` also removes it from the shadow pass, so an occluded object
stops casting a shadow that may still be in view. Keep occlusion culling for objects whose shadows
do not matter, or accept the missing shadows.


### Software Hi-Z occluders

`OcclusionCuller3D` rasterizes a few occluders that you declare (boxes and quads in world space)
into a small depth buffer on the CPU, then answers whether a box is hidden behind them:

```dart
final culler = OcclusionCuller3D()
  ..addQuad(
    OccluderQuad3D.wall(
      bottomStart: Vector3(-8, 0, -10),
      bottomEnd: Vector3(8, 0, -10),
      height: 6,
    ),
  )
  ..addBox(
    OccluderBox3D(
      center: Vector3(10, 4, -12),
      halfExtents: Vector3(3, 4, 2),
    ),
  );

// Once per frame, after the camera has moved (for example in update):
final viewProjection = camera.viewProjectionMatrix;
culler.rasterizeOccluders(viewProjection);
for (final prop in props) {
  prop.visible = culler.isAabbVisible(prop.aabb, viewProjection);
}
```

- Occluders: `OccluderBox3D(center:, halfExtents:, rotation:)` and `OccluderBox3D.fromAabb`, and
  `OccluderQuad3D(v0:, v1:, v2:, v3:)` (a planar convex quad) or `OccluderQuad3D.wall`, a vertical
  quad rising `height` along +Y. Quads are double-sided by default; with `doubleSided: false` only
  the side whose corners appear counter-clockwise on screen occludes. A quad that looks non-convex
  on screen occludes nothing. Occluders must be solid and inside the objects they stand for: an
  occluder larger than its object hides what is visible.
- Buffer: `width` by `height` pixels (128 by 64 by default, multiples of 4), rasterized at 2 by 2
  subpixels per pixel, plus two coarser levels holding the farthest depth of 2 by 2 pixels. Depth
  is the engine's clip-space depth, 0 at the near plane and 1 at the far plane.
- Conservative: a subpixel takes an occluder's depth only when its whole square lies inside the
  occluder's outline on screen (the quad, or the silhouette of a box), and it takes the farthest
  depth of the occluder over that square. A pixel therefore counts as hidden only when it is
  entirely covered, and a visible object is never reported hidden, however thin the part of it
  that shows. In return an occluder's outline loses up to one subpixel all around, and each
  occluder covers on its own: two occluders that touch leave their common edge uncovered. A box
  that crosses the near plane is rasterized face by face, which leaves its edges uncovered too.
- `isAabbVisible(bounds, viewProjection, depthBias: 0.002)` returns `false` when the box is outside
  the view, or when its nearest depth is farther than the farthest occluder depth over the screen
  rectangle it covers (plus `depthBias`); it returns `true` for boxes that reach in front of the
  near plane.
- `testedCount`, `occludedCount` and `rasterizedOccluderCount` count the work since the last
  `rasterizeOccluders`.

Cost: `rasterizeOccluders` clears about 43,000 floats at the default size, tests every subpixel of
each occluder's screen bounds against its edges (up to 32,768 subpixels per occluder) and rebuilds
the two coarse levels; each query projects 8
corners and reads the covered pixels, usually a few from the coarsest level. It pays off when a few
large occluders (city blocks, walls, terrain ridges) hide many objects that cost real draws, and
the frame is limited by draw recording. It does not in open scenes, for cheap objects, or for
merged geometry that is drawn as a whole anyway.


### Portals

`PortalOcclusionGraph3D` decides which rooms of an interior can be seen through open doorways. Each
room has an id and bounds; each portal is a convex polygon between two rooms. From the camera's
room, the graph narrows a screen rectangle through every open portal it can see:

```dart
final graph = PortalOcclusionGraph3D()
  ..addRoom(
    OcclusionRoom3D(
      id: 0,
      bounds: Aabb3.minMax(Vector3(-10, 0, -10), Vector3(10, 6, 10)),
    ),
  )
  ..addRoom(
    OcclusionRoom3D(
      id: 1,
      bounds: Aabb3.minMax(Vector3(-10, 0, -30), Vector3(10, 6, -10)),
    ),
  )
  ..addPortal(
    OcclusionPortal3D.rect(
      roomA: 0,
      roomB: 1,
      bottomStart: Vector3(-1.2, 0, -10),
      bottomEnd: Vector3(1.2, 0, -10),
      height: 3.5,
    ),
  );

// Once per frame:
graph.evaluateVisibility(
  cameraPosition: camera.eyePosition,
  viewProjection: camera.viewProjectionMatrix,
);
hallContents.visible = graph.isRoomVisible(1);
```

- The traversal starts in `cameraRoomId` when given, otherwise in every room whose bounds contain
  the camera. When the camera is in no room, every room whose bounds are on screen is a start
  room. `maxPortalDepth` (16) limits how many portals deep it goes.
- A portal's `isOpen` can be changed at any time (a door closing hides the rooms behind it from the
  next evaluation). A camera standing inside a doorway (within 0.15 units of the portal polygon's
  bounds) sees through it unclipped.
- After `evaluateVisibility`: `isRoomVisible(id)`, `visibleRoomIds`, `roomScissor(id)` (the union
  of the rectangles through which the room is seen, in `[0, 1]` with y growing upwards from the
  bottom of the screen) and `isAabbVisibleInRoom(id, bounds, viewProjection)` for single objects.
- A room seen through several portals is followed with the union of the rectangles it is seen
  through, again each time that union grows, so the result does not depend on the order in which
  portals were added. The union can include wall between two portals: the graph may report a room
  visible that is hidden, never the reverse.
- Room ids index an array: keep them small and dense.

Cost: proportional to the portals traversed (`traversedPortalCount`); each projects and clips up
to 16 vertices. A room seen through several portals can be traversed again when its rectangle
grows. Evaluations and queries do not allocate.


## Floating origin

GPU coordinates are 32-bit floats: 10 km from the origin their step is about 1 mm, at 1,000 km
about 6 cm, and objects start to jitter. `FloatingOriginController3D` keeps the camera near the
local origin: when the camera (or a tracked object) gets farther than `rebaseThreshold` from it,
the controller moves the origin there, in 64-bit coordinates, and moves the camera and every bound
object back by the same amount.

```dart
final origin = FloatingOriginController3D(
  camera: camera,
  onOriginShifted: (shift) {
    // Move what is not bound to the origin, such as particles or physics
    // bodies, by `shift` (the camera and bound objects are moved already).
  },
);
world.add(origin);

final station = MeshComponent(mesh: stationMesh);
final stationOrigin = FloatingOriginTransform3D(
  worldPosition: WorldPosition64(1250000.5, 40, -730000.25),
  controller: origin,
);
station.add(stationOrigin);
world.add(station);

// Move the station in world coordinates, with full 64-bit precision:
stationOrigin.translateWorld(0.5, 0, 0);
```

- `WorldPosition64` is a 64-bit position (`x`, `y`, `z`, `translate`, `distanceTo`,
  `toCameraRelativeVector3`).
- A `FloatingOriginTransform3D` owns the 64-bit position of its parent `Component3D` (or of
  `target`) and sets the parent's local `position` to `worldPosition - origin` when it is
  registered and after every rebase. Move bound objects with `setWorldValues` or
  `translateWorld` to keep 64-bit precision. Moving one through its `position` works too: at the
  next rebase, a binding whose object is no longer where it put it takes the object's world
  position from its local `position` (with 32-bit precision) before re-applying it.
- Without `controller`, the binding looks for a `FloatingOriginController3D` among the direct
  children of its `World3D` when it mounts, and a controller that mounts later registers every
  binding of its world that has no controller yet, so the order does not matter.
- Options: `rebaseThreshold` (2048 world units), `rebaseY` (`true`; with `false` the origin only
  moves horizontally), `initialOrigin`, `trackedTarget` (watched when `camera` is `null`; it must
  be a direct child of the world, as its `position` is compared with the threshold).
- On a rebase the controller moves `camera.position` and `camera.target`, moves `trackedTarget`
  back by the shift unless a binding places it, re-applies every bound object, calls the listeners
  (`onOriginShifted`, `addOriginShiftListener`) with the local shift, and marks the world dirty.
  `rebaseToWorldOrigin` moves the origin to a given 64-bit position, for teleports.
  `localToWorld64`, `world64ToLocal` and `cameraWorldPosition64` convert.
- Objects that are neither bound nor moved by a listener stay at their local coordinates, so they
  jump by the shift relative to the camera.

With the default threshold, local coordinates stay within about 2,048 units, where a 32-bit float
still resolves a quarter of a millimeter. A frame without rebase costs one distance check; a rebase
costs one update per bound object and listener.


## Terrain

`ChunkedTerrain3D` draws a heightmap as a quadtree of chunks whose resolution falls with distance,
with vertex colors from a four-band palette (sand, grass, rock, snow) chosen by height and slope.

```dart
final terrain = ChunkedTerrain3D(
  heights: heights, // 257 * 257 samples, row by row along +Z
  gridColumns: 257,
  gridRows: 257,
  worldWidth: 512,
  worldDepth: 512,
);
world.add(terrain);

// Heights in terrain-local coordinates (the terrain's center is 0, 0):
final y = terrain.sampleHeight(12.5, -40);
final up = terrain.sampleNormal(12.5, -40);
```

- `heights[r * gridColumns + c]` is the height of column `c` (along +X) and row `r` (along +Z).
  The terrain spans `worldWidth` by `worldDepth`, centered on its local origin; heights are local
  Y values. `ChunkedTerrain3D.procedural(...)` builds a terrain from a sum of sine waves, for tests
  and prototypes.
- LOD: every chunk has about `leafChunkQuads` (8) quads per side; a chunk at level `l` samples
  every `2^l` grid points, with `lodLevels` (4, from 1 to 8) levels. A chunk is replaced by its
  four children while the camera (in terrain-local space) is closer to its bounds than
  `lodSplitFactor` (1.35) times its width. There is no geomorphing: a chunk switches level at
  once, which can pop.
- Cracks between chunks of different levels are hidden by skirts: every chunk edge has a vertical
  strip `skirtDepth` deep (by default `max(0.5, 0.35 * maxHeight)`).
- Colors: `biomePalette` (`TerrainBiomePalette3D`) gives the four colors, the height bands
  (normalized by `maxHeight`, which defaults to the height range) and the slope limit; the result
  is baked into `vertexColor`, which `SpatialMaterial`, `UnlitMaterial` and `StylizedMaterial`
  multiply. `uvScale` (8) sets how many times texture coordinates repeat across the terrain.
  `sampleBiomeWeights(x, z)` returns the weights of the four bands.
- `material` defaults to `SpatialMaterial(metallic: 0.05, roughness: 0.88)`.
- `sampleHeight`, `sampleNormal` and `sampleBiomeWeights` take terrain-local coordinates and
  interpolate the full-resolution grid. `raycast` tests the full-resolution chunks along the ray.
- Editing: `heights` can be changed in place; then call `markHeightsChanged()`, which drops the
  chunks built so far and recomputes the elevation range, the bounds and the quadtree
  (`maxHeight` and `skirtDepth` keep their values). Project decals on it again.

Cost: one draw call per visible chunk. Each pass walks the quadtree with a frustum test per visited
node. A chunk's surface is built the first time it is selected, inside the draw (117 vertices and
192 triangles, 64 of them skirts, with the defaults, and a palette evaluation per vertex), and kept
until the terrain is removed; looking around a new terrain for the first time therefore builds
chunks over several frames, and memory grows to every level of every chunk ever seen (about 10 KB
per chunk on the CPU with the defaults, and as much on the GPU).

Shadows: the terrain casts shadows by default. In a shadow pass it culls chunks against the light's
view but chooses their level from `RenderContext3D.viewerPosition`, the main camera of the frame,
so it casts from the same chunks the camera shows.


## Foliage

`FoliageSystem3D` draws thousands of grass tufts or small plants with one instanced draw. It keeps
them in a grid of cells for culling, thins them out with distance, sways them in the wind, and
bends them away from moving spheres such as the player.

```dart
final hero = FoliageInteractor3D(position: heroPosition, radius: 1.2);
final grass = FoliageSystem3D(
  capacity: 20000,
  maxDrawDistance: 80,
  interactors: [hero],
)..scatterOnTerrain(terrain, count: 20000, minSlopeCos: 0.75);
world.add(grass);

// Every frame, follow the hero (world coordinates):
hero.position.setFrom(heroPosition);
```

- Blades: `scatterOnTerrain` replaces all blades with up to `count` blades spread evenly over a
  `ChunkedTerrain3D`, keeping slopes with `normal.y >= minSlopeCos` (0.72), heights in
  `[minHeight, maxHeight]` and the optional `densityCallback`; `seed`, `minScale`, `maxScale`,
  `baseColor` and `variationColor` vary them. Positions are in the terrain's local space, so give
  the foliage system the terrain's transform. `addBlade` adds one blade (returns `-1` when
  `capacity` is reached); `clear` removes all.
- Mesh and material: the default mesh is two crossed tapered blades one unit high (10 vertices, 6
  triangles); a custom `mesh` must stand on `y = 0`. The default material is a double-sided
  `SpatialMaterial`; a custom one must be drawable instanced, as the standard materials are.
- Distance: cells farther than `maxDrawDistance` (96) are skipped; each blade has its own cut-off
  between `fadeStartFraction * maxDrawDistance` (0.65) and `maxDrawDistance`, and shrinks to
  nothing over the last fifth before it, so density falls off smoothly instead of popping.
- Wind: `windStrength` (0.14 units of tip sway), `windFrequency` (2.2 radians per second),
  `windDirection` (horizontal, normalized). It is computed on the CPU as a shear of each blade's
  matrix, the base staying on the ground.
- Trampling: `FoliageInteractor3D(position:, radius: 1.5, strength: 1)` spheres in world space,
  listed in `interactors`. Blades inside lean away from the center and flatten by up to 65 %, at
  `trampleAttackRate` (28 per second), and spring back at `trampleSpringRate` (6.5 per second).
  The lean is a shear, not a rotation: `maxBendAngle` (1.05) is how far the tip moves sideways per
  unit of blade height (about 45 degrees with the default), despite its name. `bladeBendVector`,
  `bladeCrush` and `bladePosition` read the state of a blade.
- Each instance's `instanceData` holds the wind phase, the wind strength, the crush and the tilt,
  for custom shaders.
- `castsShadows` is `false` by default. With `castsShadows: true`, a shadow pass culls cells
  against the light's view and thins blades by their distance to the main camera
  (`RenderContext3D.viewerPosition`), so the blades that cast are the ones the camera shows.

Cost: memory is about 160 bytes per blade of `capacity`. `update` checks every cell against every
interactor and updates the blades of cells that are touched or still bent. Each pass then walks
the visible cells and, for every blade in range, computes and uploads its 96-byte instance (two
square roots and three sines or cosines each), and records one instanced draw per surface of the
mesh. With wind on, the world is marked dirty every frame, so a `Scene3DComponent` with
`Scene3DCacheMode.retained` redraws every frame. `lastVisibleCellCount` and
`lastVisibleInstanceCount` report the last pass.


## Volume decals

`VolumeDecalBatch3D` projects decals (cracks, footprints, posters, scorch marks) from oriented
boxes onto existing geometry: it clips the triangles of target surfaces, or of a terrain, to each
box and keeps the parts that face the projection, so a decal wraps around stairs, corners and
slopes. All decals of a batch are merged into one surface and drawn in one draw call.

```dart
final decals = VolumeDecalBatch3D(
  material: UnlitMaterial(albedoTexture: decalAtlas)
    ..renderState = RenderState.alphaBlend
    ..castsShadows = false,
);
decals
  ..projectOntoSurfaces(
    [
      ProjectedDecalBox3D(
        center: Vector3(0, 1, -1),
        halfExtents: Vector3(1, 1.5, 1.5),
        uvRect: const Rect.fromLTWH(0, 0, 0.5, 0.5),
      ),
    ],
    VolumeDecalTarget3D.fromMeshComponent(stairs),
  )
  ..projectOntoTerrain(
    [
      ProjectedDecalBox3D(
        center: Vector3(20, terrain.sampleHeight(20, 5), 5),
        halfExtents: Vector3(2, 3, 2),
        uvRect: const Rect.fromLTWH(0.5, 0, 0.5, 0.5),
      ),
    ],
    terrain,
    append: true,
  );
world.add(decals);
```

- `ProjectedDecalBox3D` is in world space: `center`, `halfExtents`, `rotation`, the part of the
  texture to use (`uvRect`, in `[0, 1]`), a `color` that tints it and sets its opacity, and a
  `projectionAxis`: `negativeY` (the default: projects down, onto surfaces facing the box's +Y,
  box X along U and Z along V) or `negativeZ`. `ProjectedDecalBox3D.lookAlong` builds a box that
  projects along a direction.
- Surfaces whose facing differs from the projection fade out: below `normalAngleFadeCos` (0.1)
  they receive nothing, and they fade in over `normalFadeWidth` (0.25) of cosine. Near the two
  ends of the box's depth the decal fades over `boxEdgeFeather` (0.12) of the depth.
- `normalOffset` (0.004 units) lifts the decal off the surface against z-fighting.
- Targets: `VolumeDecalTarget3D(surface:, transform:)`, `VolumeDecalTarget3D.fromMesh` and
  `fromMeshComponent`, which copies the component's current world transform. Targets that move
  later keep the decal where they were.
- Each call replaces the batch's geometry unless `append` is `true`; `clear` empties it.
  `generatedVertexCount`, `generatedTriangleCount` and `projectedDecalCount` describe the result.
- The default material is an alpha-blended `UnlitMaterial` that writes no depth. The decal's
  color and fade are in the vertex colors (premultiplied when the material blends premultiplied
  alpha). Decals are never drawn in shadow passes.

Cost: the work happens when you project, not per frame. For each decal and target the batch finds
the triangles in the box with a BVH of the target surface (built once per surface and cached),
then clips them; on a terrain it clips two triangles per covered grid cell. Each projection call
uploads the merged surface again. Per frame the batch costs one alpha-blended draw call when in
view.


## Chunk streaming

`WorldChunkStreamer3D` (in `package:flame_3d/parser.dart`) loads and unloads the components of a
square grid of chunks around the camera or a target, with your own asynchronous loader:

```dart
final streamer = WorldChunkStreamer3D(
  chunkSize: 64,
  loadRadius: 160,
  camera: camera,
  chunkLoader: loadChunkFromDisk,
  onChunkLoadFailed: (coord, error, stackTrace) {
    // Retried after failedLoadRetryDelay seconds.
  },
  onChunkEvicted: (coord, components) {
    // The chunk left the cache: release what it loaded.
  },
);
world.add(streamer);
```

- The grid lies in XZ; `enableVerticalStreaming` adds Y. `ChunkCoord3D` names a cell;
  `coordForWorldPosition` and `chunkCenterWorld` convert. Distances are measured from the focus to
  chunk centers.
- Focus: `camera.eyePosition`, else the world position of `focusTarget`, else `focusPosition`
  (`updateFocus` sets it and refreshes at once).
- Every `update`: chunks whose center is beyond `unloadRadius` (`1.35 * loadRadius` by default)
  are unmounted, the farthest first; chunks whose center is within `loadRadius` are mounted again
  from the cache or queued; up to `maxConcurrentLoads` (4) loads run at a time, closest first. The
  gap between the two radii keeps chunks at the border from loading and unloading repeatedly.
- Mounting adds the loaded components that have no parent to `chunkContainer` (by default the
  enclosing `World3D`); unmounting removes them and keeps them in a cache of
  `maxCachedUnloadedChunks` (16) chunks. A chunk pushed out of the cache is passed to
  `onChunkEvicted`, the place to release its resources (see
  [Scenes and Assets](scenes_and_assets.md)). `onChunkMounted` and `onChunkUnmounted` report the
  other transitions.
- A loader that throws (or returns a failed future) is caught: the error goes to
  `onChunkLoadFailed`, or to `FlutterError.reportError` without one, and the chunk is requested
  again only after `failedLoadRetryDelay` seconds of updates (5; `double.infinity` never retries
  on its own). `failedChunks` lists the chunks waiting, `retryFailedChunks()` lets them load at
  the next refresh, and `failedLoadCount` counts the failures.
- Removing the streamer stops it for good: its active chunks are unmounted, and every active and
  cached chunk is passed to `onChunkEvicted`, as is a chunk whose load finishes afterwards.
- `activeChunks`, `loadingChunks`, `queuedChunkCount`, `cachedChunkCount`, `cacheHitCount` and
  `totalLoadsCompleted` describe its state; `flushPending()` waits for the loads in flight.

Removing a component from the world does not free its GPU buffers or textures, and neither does
the streamer: do it in `onChunkEvicted`.


## Limitations

- `ChunkedTerrain3D` has no geomorphing (levels pop), builds chunks inside the draw on first use
  (allocating while it does), and never frees built chunks before removal or
  `markHeightsChanged()`. Its colors are per vertex; there is no texture splatting. Decals
  projected onto a terrain follow its full-resolution surface, so where a coarser chunk is drawn
  the terrain can hide them.
- `StaticMeshBatcher3D` merges only instances with the same instance data (and, for materials other
  than `SpatialMaterial` and `UnlitMaterial`, the same color): many distinct values mean many
  draws.
- `PortalOcclusionGraph3D` keeps one rectangle per room, so rooms seen through two separate
  portals may be reported visible through the wall between them.
- Occlusion results applied through `visible` also remove the objects' shadows.
- `FloatingOriginController3D` only moves the camera, the tracked target and bound objects; other
  objects must follow the shift through a listener.
- `VolumeDecalBatch3D` is static: moving targets need a new projection. It caches a surface's BVH
  until its vertex or index count changes, so edits that keep the counts leave a stale BVH.
