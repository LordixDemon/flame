# Canvas3D (Impeller-Native 3D Rendering & Raycasting)

`package:flame/canvas3d.dart` provides a zero-allocation 3D camera, mesh, lighting, particle, and
spatial raycast-picking pipeline built directly on Flutter's standard `Canvas.drawVertices` and
`Canvas.drawRawAtlas` APIs — running at 60–120 Hz on Impeller, Skia, desktop, mobile, and web
without requiring experimental `--enable-flutter-gpu` flags.


## Importing Canvas3D

```dart
import 'package:flame/canvas3d.dart';
```


## CameraRig3D and DirectionalLight3D

`CameraRig3D` projects 3D world coordinates `(x, y, z)` (with `Z` up) onto Flame's 2D world canvas
and unprojects 2D canvas points back into `Ray3D` world rays. It has two modes
(`CameraProjectionMode3D`):

- `axonometric` (default): the fixed `2:1` isometric lattice of `gridToScreen`. Every drawn object
  has a ground anchor on that lattice; `orbitYawDeltaRad` and `pitchDeltaRad` (set through
  `update(orbitYawDelta:, pitchDelta:)`, clamped to small ranges) tilt each object about its own
  anchor. The ground lattice itself does not move, so these deltas are a sway, not an orbit.
- `perspective`: a true pinhole camera (`fovYRad`, `cameraDistance`, `nearClip`) in which the deltas
  turn the whole scene about the look-at target, and `unprojectWorldRay` is the exact inverse of
  `projectWorldPoint`.

`CameraRig3D.basisVersion` increments only when the projection mode, orientation, field of view,
distance, or near clip changes, never on pure 2D camera pans (`camWorldX` / `camWorldY`) or on
`camZoom`. `StaticMeshChunk3D` tracks pan and zoom separately. `DirectionalLight3D` has no version
counter: `computeSignature()` hashes its direction, colors, and intensities, and changes to it make
`StaticMeshChunk3D` re-bake its lighting.

```dart
final camera3d = CameraRig3D(); // axonometric, 2:1 isometric at rest

final perspectiveCamera = CameraRig3D(
  projectionMode: CameraProjectionMode3D.perspective,
  fovYRad: 45 * math.pi / 180,
  cameraDistance: 18.0,
  nearClip: 0.25,
);

camera3d.update(camX: 0, camY: 0, zoom: 1.0, orbitYawDelta: 0.1, pitchDelta: 0.05);

final sunLight = DirectionalLight3D(
  sunDirX: -0.45,
  sunDirY: -0.35,
  sunDirZ: 0.82,
  ambientIntensity: 0.44,
  diffuseIntensity: 0.66,
  rimIntensity: 0.16,
);
```

The lighting model per vertex is a Lambertian directional term, a sky/ground hemisphere ambient
term, a view-angle Fresnel-style rim term, optional `PointLight3D` contributions and fog. There is
no specular term.


## Mesh3D and Procedural Geometry

`Mesh3D` stores indexed 3D triangle geometry in flat `Float32List` (positions, normals, optional
UVs and ambient occlusion) and `Uint16List` (indices) buffers, with precomputed local bounds
(`minX` .. `maxZ`) and `boundingRadius`. Triangles are counter-clockwise when seen from outside,
so back-face culling keeps the outside. `Mesh3D.fromRaw` computes smooth normals when you omit
them.

- Generators: `Mesh3D.plane`, `box`, `pyramid`, `octahedron`, `prism`, `uvSphere`, `cylinder`,
  `cone`, `torus`, and `extrudePolygon`.
- `box`, `plane`, `uvSphere`, `cylinder`, `cone`, `torus`, and `extrudePolygon` carry UVs
  (`uvs`); `prism` does not.
- Indices are 16-bit, so one mesh holds at most `Mesh3D.maxVertexCount` (`65,535`) vertices. Every
  generator throws an `ArgumentError` rather than wrap when a tessellation would exceed that.
  Build bigger geometry with `Uint32List` indices and split it with
  `Mesh3D.partitionByVertexLimit` (or `mesh.splitByVertexLimit()`), or stream it into
  `BatchMeshRenderer3D.enqueueLargeBuffers32`.
- There is no binary mesh loader: build a `Mesh3D` from your own buffers with `Mesh3D.fromRaw`.

```dart
final towerMesh = Mesh3D.cylinder(
  radiusTop: 0.55,
  radiusBottom: 0.72,
  height: 2.4,
  segments: 16,
);
final ring = Mesh3D.torus(majorRadius: 1.0, minorRadius: 0.2);
final wall = Mesh3D.extrudePolygon(
  outline: const [0, 0, 4, 0, 4, 1, 1, 1, 1, 3, 0, 3], // x, y pairs; may be concave
  height: 2.0,
);
```


## MatCapShader3D and BatchMeshRenderer3D

`MatCapShader3D` bakes two procedural sphere-mapped lookup textures (`MatCapPreset3D.metallicGold`
and `MatCapPreset3D.glossyLacquer`) once (`ensureInitialized()` / `dispose()`). A mesh uses one
through its `Material3D.matCap(preset)`.

`BatchMeshRenderer3D` transforms, back-face culls, lights (see above), and depth-sorts triangles
across *all* meshes enqueued in a pass. It then draws them with `Canvas.drawVertices(Vertices.raw(...))`,
one call for each run of consecutive triangles that share a material (and for each `21,840`
triangles), plus one for the ground shadows. The `depthMode` of the renderer
(`TriangleDepthMode3D.centroid`, `nearestVertex`, or `farthestVertex`) decides which depth
represents a triangle; the sort is stable, so equal-depth triangles keep their submission order.

```dart
final matCap = MatCapShader3D()..ensureInitialized();
final batcher = BatchMeshRenderer3D(light: sunLight);

// Inside render(Canvas canvas):
batcher.enqueueMesh(
  towerMesh,
  camera: camera3d,
  worldX: 4.0,
  worldY: -2.0,
  worldZ: 0.0,
  yawRad: 0.35,
  tint: const Color(0xFFE8EEF5),
  rimColor: const Color(0xFFFFD54F),
  rimHighlightIntensity: isHovered ? 0.65 : 0.0,
  material: const Material3D.matCap(MatCapPreset3D.metallicGold),
  castGroundShadow: true,
);

batcher.flushBatch(canvas, matCapShader: matCap); // shadows, then geometry
```

`flushBatch` is `flushShadows(canvas)` followed by `flushGeometry(canvas, ...)`; call those two
yourself to draw other things between the ground shadows and the geometry. Each flush clears what
it drew unless you pass `clear: false`; `beginBatch()` discards everything queued.

Telemetry getters (`lastFlushTriangles`, `lastFlushShadowTriangles`, `lastFlushDrawCalls`,
`lastFlushMaterialSwitches`, `lastFrustumCulledMeshes`, `lastCulledMicroTriangles`,
`lastNearPlaneClippedTriangles`) are updated on every flush without per-frame heap allocation.


## StaticMeshChunk3D (Cached World Chunks)

For static or semi-static 3D scenery (board tiles, walls, pillars, trees, beacons),
`StaticMeshChunk3D` caches back-face culling, normal transformation, lit vertex colors, projected
shadows, and camera-space depths across frames. The cache is keyed on the camera (identity and
`basisVersion`, plus `camZoom` in perspective mode), the light's `computeSignature()`, the
environment, the shadow settings, and the renderer's `depthMode`:

- **Stationary camera & light**: no lighting and no projection work per frame; the baked arrays are
  copied into the active `BatchMeshRenderer3D` buffers.
- **Pure 2D camera pan (`camWorldX` / `camWorldY` changed, `basisVersion` and the light unchanged)**:
  the lighting and normals stay cached and only the 2D projection is redone
  (`geometryBakeCount` stays, `projectionBakeCount` grows).

```dart
final chunk = StaticMeshChunk3D();
final slot = chunk.addInstance(
  StaticMeshInstance3D(
    mesh: pillarMesh,
    worldX: -6.0,
    worldY: -6.0,
    tint: const Color(0xFFCFD8DC),
  ),
);
chunk.addInstance(
  StaticMeshInstance3D(
    mesh: pillarMesh,
    worldX: 6.0,
    worldY: -6.0,
    tint: const Color(0xFFCFD8DC),
  ),
);

// Later, change one instance without rebuilding the others:
chunk.setInstanceVisible(slot, visible: false);

// Inside render(Canvas canvas):
batcher.enqueueStaticChunk(chunk, camera: camera3d);
batcher.flushBatch(canvas, matCapShader: matCap);
```


## 3D Spatial Raycast Picking (`SpatialHitbox3D`)

Attach `CameraComponent.rayProjector3D` to unproject 2D pointer locations into `Ray3D` rays, and mix
`SpatialHitbox3D` into 3D components alongside Flame's standard `TapCallbacks`, `DragCallbacks`,
`HoverCallbacks`, or `DropTargetCallbacks`. A component implements `intersectRay3D` and returns the
distance `t` along the ray, or `null` on a miss. Flame delivers the event to the components the ray
hits ordered by `t` (closest 3D surface first, independent of 2D tree order), then to whatever the
plain 2D hit test finds. `lastHitDistance3D` and `lastHitPoint3D` hold the most recent hit.

Two protected helpers cover the common volumes: `intersectWorldAabb3D` (slab test against a world
box) and `intersectMesh3D` (exact Möller–Trumbore triangle test through the mesh's `MeshBvh3D`,
under translation, rotation, and non-uniform scale). Override `boundingSphere3D` to give the camera
an `O(1)` broadphase: rays that miss the sphere never reach `intersectRay3D`. Set
`spatialHitEnabled = false` to take a component out of 3D picking.

```dart
camera.rayProjector3D = (viewportPoint, worldPoint) =>
    camera3d.unprojectWorldRay(Offset(worldPoint.x, worldPoint.y));

class InteractiveTower extends PositionComponent
    with SpatialHitbox3D, HoverCallbacks, TapCallbacks {
  InteractiveTower(this.mesh, {required this.worldX, required this.worldY}) {
    stopHoverPropagation = true;
  }

  final Mesh3D mesh;
  final double worldX;
  final double worldY;

  // (centerX, centerY, centerZ, radius) in world units.
  @override
  (double, double, double, double)? get boundingSphere3D =>
      (worldX, worldY, 1.2, 1.6);

  @override
  double? intersectRay3D(Ray3D ray) =>
      intersectMesh3D(ray, mesh, worldX: worldX, worldY: worldY);
}
```

Without a `World`-mounted component, `Raycaster3D` offers the same tests directly:
`intersectAabbDistance`, `intersectSphereDistance`, `raycastMeshTransform`, `raycastNodeHierarchy`
(closest visible mesh in a `Node3D` tree), and `raycastCollider` / `pickClosest` for lists of
`MeshCollider3D` (any `id`, negative ones included).

In axonometric mode a pixel does not identify one world point: pass `anchorWorld` (the
`gridToScreen` position of the object's anchor) to `unprojectWorldRay` to unproject for a particular
object when `orbitYawDeltaRad` or `pitchDeltaRad` is non-zero.


## ParticlePool3D

`ParticlePool3D` simulates up to `capacity` 3D particles (384 by default) with gravity, air drag,
wind, optional Simplex turbulence, and an elastic bounce on the ground plane `z = 0`, in contiguous
Struct-of-Arrays `Float32List` columns. Spawning into a full pool overwrites an existing slot
(round-robin), so a burst is never dropped.

`render(canvas, camera)` draws the whole pool in at most three `Canvas.drawVertices` calls: contact
shadows, alpha-blended kinds, and additive kinds (`lastDrawCalls`). Particles are not depth-sorted
against meshes, so draw the pool as its own layer after the geometry it should cover. Particles and
their shadows are projected exactly like `CameraRig3D.projectWorldPoint`: a burst spawned at a
mesh's world position stays on that mesh for every orbit and pitch delta of the camera, in both
projection modes.

`onGroundImpact(x, y, speed)` fires once per bounce with the speed at the moment of contact. A
particle that touches down slower than `0.18` units per second settles silently, so particles lying
on the ground never fire it, whatever the frame rate.

```dart
final particles = ParticlePool3D(
  capacity: 256,
  onGroundImpact: (x, y, speed) {
    // World-space landing point and contact speed: spawn a ripple, play a
    // sound scaled by `speed`, ...
  },
);

particles.burstCoins(tileX, tileY, count: 14);
particles.spawnWaterSplash3D(tileX, tileY);

// Every frame:
particles.update(dt);
particles.render(canvas, camera3d);
```


## 3D Mesh LOD Chains, Micro-Triangle Culling, and `SceneEnvironment3D` (Point Lights, Fog & Frustum Culling)

- **3D Mesh LOD Chains & Sub-Pixel Triangle Culling (`MeshLodChain3D`, `enqueueLodMesh`,
  `minTrianglePixelArea`)**: Build multi-tier `MeshLodChain3D.progressive(...)` chains and call
  `batcher.enqueueLodMesh(chain, camera: camera3d, worldX: x, worldY: y)` to automatically select
  the optimal `Mesh3D` tier (or cull tiny distant props) based on projected screen pixel diameter
  and `lodBias`. Set `batcher.minTrianglePixelArea` (e.g. `1.5`, in screen pixels at the current
  `camZoom`) to drop sub-pixel micro-triangles after the mesh has been lit and projected. It is
  applied per mesh and only where it cannot open holes: a mesh whose visible area is below the
  threshold, or whose micro-triangles together cover at most 5 % of it. A densely tessellated mesh
  that is still visible keeps all its triangles; thin those out with a `MeshLodChain3D`.
- **`SceneEnvironment3D` (Zero-Allocation SoA `PointLight3D` Pool, Atmospheric Fog & Frustum
  Culling)**: Attach a `SceneEnvironment3D` to `BatchMeshRenderer3D(environment: env, cullScreenBounds: ...)`:
  - **Dynamic `PointLight3D` Pool**: Contiguous SoA point lights with smooth quadratic distance
    attenuation (`addPointLight`, `addPointLightDescriptor`) accumulated alongside directional
    lighting. The pool has no fixed cap and grows on demand; move a light by calling
    `clearPointLights()` and adding the lights again.
  - **Distance & Height Atmospheric Fog**: Blends vertex colors smoothly toward `fogColor` by view
    depth (`fogStartDepth`..`fogEndDepth`) and elevation (`heightFogBaseZ`, `heightFogDensity`),
    remaining invariant under pure 2D camera pans so `StaticMeshChunk3D` caches stay valid.
  - **3D Bounding-Sphere Frustum Culling & Spatial Light Signatures**: Rejects off-screen dynamic
    meshes and static chunks in `O(1)` before vertex transformation (`lastFrustumCulledMeshes`;
    the bounding sphere is conservative under perspective, pitch, and roll), and
    hashes only point lights intersecting each `StaticMeshChunk3D`'s world AABB
    (`computeSignatureForBounds`) so distant moving lights never trigger unnecessary chunk rebakes.


## SceneEnvironment3D, PointLight3D, Distance Fog & MeshLodChain3D

- **`SceneEnvironment3D` & `PointLight3D`**: Pass `environment: sceneEnv` to the
  `BatchMeshRenderer3D` constructor (or set its `environment`) to combine dynamic local point
  lights (smooth quadratic attenuation in a zero-alloc SoA pool) with distance fog
  (`fogEnabled`, `fogStartDepth`, `fogEndDepth`, `fogMaxOpacity`, `fogColor`) and height fog
  (`heightFogBaseZ`, `heightFogFalloff`, `heightFogDensity`). `StaticMeshChunk3D` hashes only the
  point lights that overlap its bounds (`computeSignatureForBounds(...)`) so distant light movement
  causes **`0` chunk rebakes**.
- **`MeshLodChain3D`**: Selects `high` / `medium` / `low` `Mesh3D` levels by projected screen radius
  (or generates decimated chains via `MeshLodChain3D.progressive(...)`), cutting triangle counts
  automatically during zoomed-out overview framing.


## Multi-Material Global Z-Sorting, Quaternions, Deformable Meshes, Surgical Chunks & Decoupled Shadows

- **Multi-Material, Multi-Texture & Multi-BlendMode Global Z-Sorting (`Material3D`)**: Assign
  `Material3D.matCap(preset)`, `Material3D.texture(imageShader, width:, height:)`, or
  `Material3D.unshaded(blendMode:)` per `enqueueMesh`, `Node3D`, or `StaticMeshInstance3D`.
  `BatchMeshRenderer3D` globally depth-sorts all triangles across materials first and then emits
  contiguous material runs (`lastFlushMaterialSwitches`), preserving exact 3D occlusion across
  opaque, textured, translucent, and additive surfaces.
- **Gimbal-Lock-Free `Quaternion3D`, Full `3x3` `Node3D` Composition & Zero-Alloc Deformation**:
  - `Quaternion3D` (`normalize`, `fromAxisAngle`, `fromEuler`, `multiply`, shortest-arc `slerp`,
    `writeMatrix3`, `multiplyMatrix3`), `rotationQuat` / `rotationMatrix3` on `enqueueMesh`, and
    true `3x3` parent pitch/roll/quaternion matrix composition across `Node3D` hierarchies
    (`setLocalQuaternion`, `worldPointForLocal`). A node's world transform is the exact matrix
    product `parent * translation * rotation * scale`, so a rotated child of a non-uniformly scaled
    parent shears (`worldLinearMatrix`). Changing any `Node3D` property notifies
    `Game.notifyVisualMutation`, so on-demand rendering repaints.
  - `MorphTarget3D` & `MorphMeshWorkspace3D` (`enqueueMorphMesh`) for zero-GC blendshape animation
    with automatic normal renormalization, plus `Bone3D` & `SkinnedMeshWorkspace3D`
    (`enqueueSkinnedMesh`) for Linear Blend Skinning with up to 4 bone influences per vertex.
- **Texture UV Preservation & Surgical `O(V_slot)` Partial Updates in `StaticMeshChunk3D`**:
  `StaticMeshChunk3D` preserves both MatCap view-normal UVs and atlas pixel/normalized texture UVs
  (`uvRectPx`), returns a slot index from `addInstance`/`add`, and updates single instances in-place
  via `updateInstance(slot, next)` / `setInstanceVisible(slot, visible:)` (`partialSlotRebakeCount`)
  without rebuilding sibling geometry.
- **Back-Face/Grazing Shadow Culling, Height Penumbra & Split Multi-Pass Flush**:
  `BatchMeshRenderer3D(cullBackfaceShadows: true, shadowHeightFalloff: ...)` eliminates duplicate
  back-face + zero-area grazing shadow triangles (`nDotL <= 1e-6`), attenuates shadow alpha with
  caster height above ground, and exposes `flushShadows(canvas)` + `flushGeometry(canvas)` for
  multi-pass ground-decal pipelines.
- **`O(k)` `World.spatialHitboxes3D` & `boundingSphere3D` Ray Broadphase**: `World` maintains a live
  registry of mounted `SpatialHitbox3D` components and `CameraComponent` prunes non-intersecting 3D
  bounds via `Raycaster3D.intersectSphereDistance` (`lastSpatialRayCandidatesTested`,
  `lastSpatialRayNarrowphaseTests`) without traversing non-3D world props.


## True Pinhole Perspective + Near-Plane Clipping, 65k+ Vertex Partitioning, 4-Bone `AnimationMixer3D` & `MeshBvh3D`

- **Explicit Sort Keys, `TriangleDepthMode3D` (`centroid` / `nearestVertex` / `farthestVertex`) & `> 65,535`
  Vertex Meshes**:
  - Pass `sortOrder` and `depthBias` to `BatchMeshRenderer3D.enqueueMesh` (or set them on a `Node3D`),
    and choose the renderer-wide `depthMode` (`TriangleDepthMode3D.centroid`, `nearestVertex`, or
    `farthestVertex`) in the `BatchMeshRenderer3D` constructor. It applies to every mesh and
    `StaticMeshChunk3D` enqueued while it is set. Together they reduce painter's-algorithm popping
    where tall walls meet large ground planes.
  - Partition arbitrary 32-bit `Uint32List` high-poly meshes into `Uint16List`-safe submeshes via
    `Mesh3D.partitionByVertexLimit` / `Mesh3D.splitByVertexLimit`, or stream `Uint32List` buffers
    directly into `BatchMeshRenderer3D.enqueueLargeBuffers32` (auto-splitting `Vertices.raw` chunks
    at `65,535` vertices).
- **True Pinhole `CameraProjectionMode3D.perspective` & Sutherland–Hodgman Near-Plane Clipping**:
  - Set `CameraRig3D(projectionMode: CameraProjectionMode3D.perspective, fovYRad: 0.785, nearClip: 0.25)`
    for exact pinhole perspective projection (`tan(fovY / 2)` focal scaling) and perspective-aware
    divergent `unprojectWorldRay` rays.
  - `BatchMeshRenderer3D` clips every world-space triangle straddling `z_cam <= nearClip` via exact
    zero-allocation 3D Sutherland–Hodgman polygon clipping (emitting `0`, `1`, or `2` triangles with
    interpolated positions, normals, colors, MatCap/atlas UVs, and fog) — zero `w <= 0` coordinate
    inversion or `NaN` explosions.
- **4-Bone glTF Skeletal Skinning (`SkinnedMeshWorkspace3D`) & Keyframed `AnimationClip3D` /
  `AnimationMixer3D`**:
  - `SkinnedMeshWorkspace3D` supports full 4-influence per-vertex Linear Blend Skinning
    (`boneIndices0..3`, `boneWeights0..3`) with per-bone translation, quaternion rotation, and
    squash/stretch scale (`setBonePose`, `getBoneLocalPose`, `resetToBindPose`). Weights are
    normalised per vertex: a 2-bone rig passes only `boneWeights0` and the second influence gets
    `1 - w0`. The constructor throws a `RangeError` when a weighted influence names a bone that is
    not in the skeleton. `evaluateIfDirty` skins into pre-allocated buffers without allocating.
  - `TransformTrack3D`, `MorphWeightTrack3D`, and `AnimationClip3D` sample keyframes by `O(log K)`
    binary search with linear translation/scale and shortest-arc quaternion slerp; times before the
    first or after the last keyframe hold that keyframe. `AnimationClip3D.toBytes` /
    `AnimationClip3D.fromBytes` round-trip a clip through the binary `DA3D` v1 format (a truncated
    or foreign buffer throws a `FormatException`).
  - `AnimationMixer3D` (`play`, `crossFadeTo`, `setLayerClip` with an optional bone mask) drives
    bone poses, `Node3D` transforms, and morph weights. It owns only what its clips animate: a
    bone, node channel, or morph weight that the previous clip animated and the current one does
    not is blended back to its own rest value during a cross-fade (the bind pose for bones) and
    restored at once on `play`; anything no clip ever animated can be posed by hand.
    `crossFadeTo` with a non-positive duration switches immediately.
  - `AnimationEvent3D` markers call `AnimationMixer3D.onEvent` when forward playback of the primary
    clip crosses them: an event at time `0` fires on the first `update` after the clip starts, and
    every event fires once per loop of a looping clip.
- **Flat Zero-Alloc `MeshBvh3D` (`O(log T)` Ray Picking) & Full `3x3` Transform `Raycaster3D`**:
  - `Mesh3D.bvh` lazily builds and caches a flat `Float32List`/`Int32List` Bounding Volume
    Hierarchy (`MeshBvh3D`, `6` floats + `2` ints per node, up to `4` triangles per leaf). Nodes are
    split at the spatial midpoint of their triangle centroids, falling back to a median split for
    degenerate or very uneven inputs, which bounds the tree depth so the fixed 128-entry traversal
    stack never overflows. `raycastLocal` allocates nothing per ray (`lastNodesVisited`,
    `lastTrianglesTested`).
  - `Raycaster3D.raycastMeshTransform` transforms world rays by the exact inverse `3x3` rotation
    (`yaw`/`pitch`/`roll`, a quaternion, or a row-major `3x3` matrix) and non-uniform or negative
    `scaleX/Y/Z`. A mirrored (negative-determinant) scale mirrors the ray together with the mesh,
    so outward faces stay pickable with back-face culling on and no winding flip is needed. This
    is what `SpatialHitbox3D.intersectMesh3D` uses, bringing narrowphase raycasts to `O(log T)`.
- **HD-2D `SpriteBillboard3D` Standees & Double-Sided Ground Shadows (`doubleSidedShadow`)**:
  - `SpriteBillboard3D` renders 2D pixel-art character/prop sprites inside a 3D
    `BatchMeshRenderer3D` world with `BillboardOrientationMode3D.cylindricalZ` (upright around
    `+Z`), `sphericalCameraPlane`, or `tiltedStandee` cardboard pitch (`standeeTiltFactor`),
    in-plane `rollRad`, `flipH` / `flipV`, `setFlipbookFrame` UV sheet slicing, and the renderer's
    directional + `PointLight3D` + fog shading. `enqueue` reuses the billboard's own vertex buffers
    and allocates nothing. The quad is sorted with the renderer's triangle depth mode: set
    `BatchMeshRenderer3D.depthMode = TriangleDepthMode3D.nearestVertex` (or give the billboard a
    `depthBias` / `sortOrder`) when standees must sort in front of the ground they stand on.
  - `BatchMeshRenderer3D.enqueueDeformedBuffers(..., doubleSidedShadow: true)` (always used by
    `SpriteBillboard3D`) projects planar ground shadows regardless of whether the directional sun
    is in front of or behind single-sided sprite quads.


## 3D Volumetric Billowing Fog (`VolumetricFogVolume3D`, `VolumetricFogComponent3D`) & Elemental `ParticlePool3D`

- **`VolumetricFogVolume3D` & `VolumetricFogComponent3D`**: SoA 3D cloud-parcel simulator
  (`spawnParcel`, `populateCorridor`, `spawnApproachingWavefront`, `setApproachSpeedTowardCamera`)
  with 3D Simplex curl-like billowing turbulence, ground-hugging roll vorticity, pinhole perspective
  `1 / camZ` swelling, a smoothstep near-lens fade over `[nearFadeStart .. nearFadeEnd]` (no
  popping through the lens), a far fade over `[farFadeStart .. farSpawnDepth]`, directional crest
  scattering, internal `PointLight3D` torch illumination from `SceneEnvironment3D`, and Ciura Shell
  back-to-front depth sorting drawn in **1 `Canvas.drawRawAtlas` call**. The simulation allocates
  nothing per parcel.
  - **Projection and zoom**: parcels are drawn in the same canvas pixels as
    `CameraRig3D.projectWorldPoint`, so mount `VolumetricFogComponent3D` inside the `World` (the
    canvas then carries the 2D camera zoom, which scales positions and puff sizes once). Pass the
    on-screen viewport size in logical pixels (`viewportSizeProvider`, or `viewportSize` on
    `render`); it is divided by `camera.camZoom` for the off-screen cull, so a narrow or zoomed-out
    view gets fog up to its edges.
  - **Recycling corridor** (`recycleLoop`, on by default): `update(dt, camera: ...)` keeps parcels
    inside a camera-aligned corridor `corridorHalfWidth` wide. While the bank approaches the
    camera, a parcel that reaches `nearFadeStart` or leaves sideways respawns at `farSpawnDepth`
    and rolls in again. While the bank is ambient (no approach speed), the corridor is also bounded
    in depth by `[corridorMinDepth .. corridorMaxDepth]` (set by `populateCorridor`): a parcel that
    drifts out on any side fades out, respawns inside, and fades back in, so the bank stays where
    it was populated. With `recycleLoop = false` nothing is moved, and parcels the flow has carried
    behind the lens are removed (`activeParcelCount` drops as a one-shot wavefront passes).
  - **Approach**: `spawnApproachingWavefront` replaces all parcels with a wall of fog and rolls it
    toward the lens. `setApproachSpeedTowardCamera` raises `ceilingZ` to give the bank headroom up
    to an elevated lens; calling it again with a speed of `0` puts `ceilingZ` back and the bank
    settles and re-forms in its ambient corridor.

  ```dart
  final fog = VolumetricFogVolume3D(capacity: 96, density: 0.25)
    ..populateCorridor(camera3d, count: 24, minCamDepth: 11, maxCamDepth: 22);

  world.add(
    VolumetricFogComponent3D(
      volume: fog,
      camera: camera3d,
      viewportSizeProvider: () => game.size.toSize(),
    ),
  );

  // A surge that rolls over the scene, then calms down again:
  fog.spawnApproachingWavefront(camera3d, count: 36, approachSpeed: 4.4);
  // ... a few seconds later:
  fog.setApproachSpeedTowardCamera(camera3d, 0);
  ```

- **Elemental `ParticlePool3D` (`flame`, `smoke`, `waterDrop`, `fogWisp`)**: Adds thermal buoyancy
  (negative gravity), 3D wind + Simplex turbulence (`windX/Y/Z`, `turbulenceStrength`,
  `turbulenceScale`), ground-impact callbacks (`onGroundImpact`), pinhole perspective projection,
  and helper spawners (`spawnFlamePlume`, `spawnWaterSplash3D`, `burstCoins`, `burstCelebration`,
  `burstImpact`, `burstDust`).
