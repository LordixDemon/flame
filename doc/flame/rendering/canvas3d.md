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
via orthographic/axonometric tilt (`pitchDeg`, `yawDeg`, `pixelsPerUnit`) with optional perspective
foreshortening (`perspective`), and unprojects 2D canvas coordinates back into `Ray3D` world rays.

`CameraRig3D.basisVersion` increments only when camera orientation, scale, or perspective changes
(never on pure 2D camera pans `camWorldX` / `camWorldY`), while `DirectionalLight3D.version`
increments whenever light direction, intensity, ambient, or hemisphere parameters change.

```dart
final camera3d = CameraRig3D(
  pitchDeg: 55.0,
  yawDeg: -45.0,
  pixelsPerUnit: 32.0,
  perspective: 0.0012,
);

final sunLight = DirectionalLight3D(
  dirX: -0.45,
  dirY: -0.60,
  dirZ: 0.66,
  intensity: 1.15,
  ambient: 0.35,
);
```


## Mesh3D and Procedural / Binary `.dmesh` Geometry

`Mesh3D` stores indexed 3D triangle geometry in flat `Float32List` / `Uint16List` buffers with
automatic smooth or flat face normals and precomputed local `Aabb3D` bounds:

- Built-in generators: `Mesh3D.box(...)`, `Mesh3D.cylinder(...)`, `Mesh3D.cone(...)`,
  `Mesh3D.uvSphere(...)`, `Mesh3D.torus(...)`, and `Mesh3D.extrudePolygon(...)`.
- Binary loader: `Mesh3D.fromDMeshBytes(Uint8List bytes)` parses compact `.dmesh` binary assets.

```dart
final towerMesh = Mesh3D.cylinder(
  radiusTop: 0.55,
  radiusBottom: 0.72,
  height: 2.4,
  segments: 16,
);
```


## MatCapShader3D and BatchMeshRenderer3D

`MatCapShader3D` generates a procedural sphere-mapped metallic/ceramic/toon lookup texture once on
the GPU (`ensureInitialized()` / `dispose()`), mapping view-space surface normals to `(u, v)`
coordinates.

`BatchMeshRenderer3D` transforms, back-face culls, shades (Lambertian + Blinn-Phong + hemisphere
fill + view-angle Fresnel rim highlight), depth-sorts by painter centroid across *all* enqueued
meshes in a pass, and issues **a single `Canvas.drawVertices(Vertices.raw(...))` draw call**:

```dart
final matCap = MatCapShader3D.gold()..ensureInitialized();
final batcher = BatchMeshRenderer3D();

// Inside render(Canvas canvas):
batcher.beginFrame(camera: camera3d, light: sunLight);

batcher.enqueueMesh(
  mesh: towerMesh,
  worldX: 4.0,
  worldY: -2.0,
  worldZ: 0.0,
  yawRad: 0.35,
  baseColor: const Color(0xFFE8EEF5),
  rimColor: const Color(0xFFFFD54F),
  rimHighlightIntensity: isHovered ? 0.65 : 0.0,
  rimPower: 2.4,
);

batcher.flush(
  canvas,
  shader: matCap.shader,
  blendMode: BlendMode.modulate,
);
```

Telemetry counters (`lastFlushedTriangleCount`, `lastFlushedMeshCount`, `lastDrawCallCount`) are
updated on every `flush()` with zero per-frame heap allocations.


## StaticMeshChunk3D (Cached World Chunks)

For static or semi-static 3D scenery (board tiles, walls, pillars, trees, beacons),
`StaticMeshChunk3D` caches back-face culling, normal transformation, Lambert/rim vertex colors,
and camera-space depth centroids across frames:

- **Stationary camera & light**: `0` lighting computations and `0` projections per frame (`O(1)`
  memcpy into the active `BatchMeshRenderer3D` buffers).
- **Pure 2D camera pan (`camWorldX` / `camWorldY` changed, `basisVersion` & `light.version`
  unchanged)**: cached lighting colors and normals are preserved; only the 2D screen offset is
  shifted!

```dart
final chunk = StaticMeshChunk3D()
  ..addInstance(
    mesh: pillarMesh,
    worldX: -6.0,
    worldY: -6.0,
    worldZ: 0.0,
    baseColor: const Color(0xFFCFD8DC),
  )
  ..addInstance(
    mesh: pillarMesh,
    worldX: 6.0,
    worldY: -6.0,
    worldZ: 0.0,
    baseColor: const Color(0xFFCFD8DC),
  );

// Inside render(Canvas canvas):
batcher.beginFrame(camera: camera3d, light: sunLight);
batcher.enqueueStaticChunk(chunk);
batcher.flush(canvas, shader: matCap.shader);
```


## 3D Spatial Raycast Picking (`SpatialHitbox3D`)

Attach `CameraComponent.rayProjector3D` to unproject 2D pointer locations into `Ray3D` rays, and mix
`SpatialHitbox3D` into 3D components alongside Flame's standard `TapCallbacks`, `DragCallbacks`, or
`HoverCallbacks`. Flame automatically sorts overlapping 3D components by ray entry distance `t`
(closest 3D surface wins, independent of 2D tree order) and Supports Möller–Trumbore triangle
tests via `Mesh3D.intersectRay`:

```dart
camera.rayProjector3D = (cam, worldPoint) =>
    camera3d.unprojectWorldRay(Offset(worldPoint.x, worldPoint.y));

class InteractiveTower extends PositionComponent
    with SpatialHitbox3D, HoverCallbacks, TapCallbacks {
  InteractiveTower(this.mesh);
  final Mesh3D mesh;

  @override
  bool get stopHoverPropagation => true;

  @override
  Aabb3D get worldBounds3D => Aabb3D.fromCenterExtents(
    centerX: worldX,
    centerY: worldY,
    centerZ: 1.2,
    halfX: 0.8,
    halfY: 0.8,
    halfZ: 1.2,
  );

  @override
  double? intersectRay3D(Ray3D ray) =>
      mesh.intersectRay(ray, translateX: worldX, translateY: worldY);
}
```


## ParticlePool3D

`ParticlePool3D` simulates up to thousands of 3D particles with gravity, floor bounce, drag, and
camera-depth sorting in contiguous Struct-of-Arrays `Float32List` columns, rendering the entire
cloud in a single `Canvas.drawRawAtlas` call.


## 3D Mesh LOD Chains, Micro-Triangle Culling, and `SceneEnvironment3D` (Point Lights, Fog & Frustum Culling)

- **3D Mesh LOD Chains & Sub-Pixel Triangle Culling (`MeshLodChain3D`, `enqueueLodMesh`,
  `minTrianglePixelArea`)**: Build multi-tier `MeshLodChain3D.progressive(...)` chains and call
  `batcher.enqueueLodMesh(chain, camera: camera3d, worldX: x, worldY: y)` to automatically select
  the optimal `Mesh3D` tier (or cull tiny distant props) based on projected screen pixel diameter
  and `lodBias`. Set `batcher.minTrianglePixelArea` (e.g. `1.5`) to discard sub-pixel micro-triangles
  before vertex lighting.
- **`SceneEnvironment3D` (Zero-Allocation SoA `PointLight3D` Pool, Atmospheric Fog & Frustum
  Culling)**: Attach a `SceneEnvironment3D` to `BatchMeshRenderer3D(environment: env, cullScreenBounds: ...)`:
  - **Dynamic `PointLight3D` Pool**: Contiguous SoA point lights with smooth quadratic distance
    attenuation (`addPointLight`, `updatePointLight`) accumulated alongside directional lighting.
  - **Distance & Height Atmospheric Fog**: Blends vertex colors smoothly toward `fogColor` by view
    depth (`fogStartDepth`..`fogEndDepth`) and elevation (`heightFogBaseZ`, `heightFogDensity`),
    remaining invariant under pure 2D camera pans so `StaticMeshChunk3D` caches stay valid.
  - **3D Bounding-Sphere Frustum Culling & Spatial Light Signatures**: Rejects off-screen dynamic
    meshes and static chunks in `O(1)` before vertex transformation (`lastFrustumCulledMeshes`), and
    hashes only point lights intersecting each `StaticMeshChunk3D`'s world AABB
    (`computeSignatureForBounds`) so distant moving lights never trigger unnecessary chunk rebakes.


## SceneEnvironment3D, PointLight3D, Distance Fog & MeshLodChain3D

- **`SceneEnvironment3D` & `PointLight3D`**: Pass `environment: sceneEnv` to
  `BatchMeshRenderer3D.beginFrame(...)` to combine up to `N` dynamic local point lights (smooth
  quadratic attenuation in a zero-alloc SoA pool, capped automatically by
  `GraphicsProfile.maxPointLights`), ambient hemisphere tint, and linear/exponential distance fog
  (`fogDensity`, `fogStart`, `fogEnd`, `fogColor`). `StaticMeshChunk3D` computes a spatial
  `computeLocalSignature(...)` over overlapping point-light spheres so distant light movement causes
  **`0` chunk rebakes**.
- **`MeshLodChain3D`**: Selects `high` / `medium` / `low` `Mesh3D` levels by projected screen radius
  (or generates decimated chains via `MeshLodChain3D.progressive(...)`), cutting triangle counts
  automatically during zoomed-out overview framing.


## Multi-Material Global Z-Sorting, Quaternions, Deformable Meshes, Surgical Chunks & Decoupled Shadows

- **Multi-Material, Multi-Texture & Multi-BlendMode Global Z-Sorting (`Material3D`)**: Assign
  `Material3D.matCap(...)`, `Material3D.texture(imageShader, width:, height:)`, or
  `Material3D.unshaded(blendMode:)` per `enqueueMesh`, `Node3D`, or `StaticMeshInstance3D`.
  `BatchMeshRenderer3D` globally depth-sorts all triangles across materials first and then emits
  contiguous material runs (`lastFlushMaterialSwitches`), preserving exact 3D occlusion across
  opaque, textured, translucent, and additive surfaces.
- **Gimbal-Lock-Free `Quaternion3D`, Full `3x3` `Node3D` Composition & Zero-Alloc Deformation**:
  - `Quaternion3D` (`normalize`, `fromAxisAngle`, `fromEuler`, `multiply`, shortest-arc `slerp`,
    `writeMatrix3`, `multiplyMatrix3`), `rotationQuat` / `rotationMatrix3` on `enqueueMesh`, and
    true `3x3` parent pitch/roll/quaternion matrix composition across `Node3D` hierarchies
    (`setLocalQuaternion`, `worldPointForLocal`).
  - `MorphTarget3D` & `MorphMeshWorkspace3D` (`enqueueMorphMesh`) for zero-GC blendshape animation
    with automatic normal renormalization, plus `Bone3D` & `SkinnedMeshWorkspace3D`
    (`enqueueSkinnedMesh`) for 2-bone Linear Blend Skinning.
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

- **Explicit Sort Keys, `TriangleDepthMode3D` (`centroid` / `nearest` / `farthest`) & `> 65,535`
  Vertex Meshes**:
  - Pass `sortOrder`, `depthBias`, and `depthMode` (`TriangleDepthMode3D.centroid`, `nearest`, or
    `farthest`) to `BatchMeshRenderer3D.enqueueMesh` / `Node3D` to eliminate painter's-algorithm
    popping where tall walls meet large ground planes.
  - Partition arbitrary 32-bit `Uint32List` high-poly meshes into `Uint16List`-safe submeshes via
    `Mesh3D.partitionByVertexLimit` / `Mesh3D.splitByVertexLimit`, or stream `Uint32List` buffers
    directly into `BatchMeshRenderer3D.enqueueLargeBuffers32` (auto-splitting `Vertices.raw` chunks
    at `65,535` vertices).
- **True Pinhole `CameraProjectionMode3D.perspective` & Sutherland–Hodgman Near-Plane Clipping**:
  - Set `CameraRig3D(projectionMode: CameraProjectionMode3D.perspective, fovYDeg: 45, nearClip: 0.25)`
    for exact pinhole perspective projection (`tan(fovY / 2)` focal scaling) and perspective-aware
    divergent `unprojectWorldRay` rays.
  - `BatchMeshRenderer3D` clips every world-space triangle straddling `z_cam <= nearClip` via exact
    zero-allocation 3D Sutherland–Hodgman polygon clipping (emitting `0`, `1`, or `2` triangles with
    interpolated positions, normals, colors, MatCap/atlas UVs, and fog) — zero `w <= 0` coordinate
    inversion or `NaN` explosions.
- **4-Bone glTF Skeletal Skinning (`SkinnedMeshWorkspace3D`) & Keyframed `AnimationClip3D` /
  `AnimationMixer3D`**:
  - `SkinnedMeshWorkspace3D` supports full 4-influence per-vertex Linear Blend Skinning
    (`boneIndices0..3`, `boneWeights0..3`, defaulting `2`/`3` cleanly when 2-bone rigs are used).
  - `TransformTrack3D`, `MorphWeightTrack3D`, `AnimationClip3D` (`O(log K)` binary-searched keyframe
    sampling with shortest-arc quaternion slerp), and `AnimationMixer3D` (`play`, `crossFadeTo`,
    bone TRS + morph weight driving) animate 3D characters with zero per-frame heap allocations.
- **Flat Zero-Alloc `MeshBvh3D` (`O(log T)` Ray Picking) & Full `3x3` Transform `Raycaster3D`**:
  - `Mesh3D.bvh` lazily builds and caches a flat `Float32List`/`Int32List` median-split Bounding
    Volume Hierarchy (`MeshBvh3D`, `8` floats + `2` ints per node).
  - `Raycaster3D.raycastMeshTransform` transforms world rays by the exact inverse `3x3` rotation
    (`yaw`/`pitch`/`roll`, `Quaternion3D`, or `Matrix3`) and non-uniform/negative `scaleX/Y/Z` (with
    automatic winding-flip compensation when `det < 0`), accelerating `MeshHitbox3D` narrowphase
    raycasts to `O(log T)`.
- **HD-2D `SpriteBillboard3D` Standees & Double-Sided Ground Shadows (`doubleSidedShadow`)**:
  - `SpriteBillboard3D` renders 2D pixel-art character/prop sprites inside a 3D `BatchMeshRenderer3D`
    world with `BillboardOrientationMode3D.cylindricalZ` (upright around `+Z`), `sphericalCameraPlane`,
    or `tiltedStandee` cardboard pitch, `setFlipbookFrame` UV sheet slicing, full directional +
    `PointLight3D` + height-fog shading, and `TriangleDepthMode3D.nearest` depth sorting so standees
    never clip into the 3D ground plane.
  - `BatchMeshRenderer3D.enqueueDeformedBuffers(..., doubleSidedShadow: true)` (enabled by default on
    `SpriteBillboard3D`) projects planar ground shadows regardless of whether the directional sun is in
    front of or behind single-sided sprite quads.


## 3D Volumetric Billowing Fog (`VolumetricFogVolume3D`, `VolumetricFogComponent3D`) & Elemental `ParticlePool3D`

- **`VolumetricFogVolume3D` & `VolumetricFogComponent3D`**: Zero-allocation SoA 3D cloud-parcel
  simulator (`populateCorridor`, `spawnApproachingWavefront`, `setApproachSpeedTowardCamera`) with
  3D Simplex curl-like billowing turbulence, ground-hugging roll vorticity, pinhole perspective `1 / camZ`
  swelling, smooth Beer–Lambert near-lens transmittance fade (`[nearFadeStart .. nearFadeEnd]`, zero
  popping through `nearClip`), directional crest scattering, internal `PointLight3D` torch illumination
  from `SceneEnvironment3D`, and Ciura Shell back-to-front depth sorting drawn in **1
  `Canvas.drawRawAtlas` call**.
- **Elemental `ParticlePool3D` (`flame`, `smoke`, `waterDrop`, `fogWisp`)**: Adds thermal buoyancy,
  3D wind + Simplex turbulence (`windX/Y/Z`, `turbulenceStrength`), ground-impact callbacks
  (`onGroundImpact`), pinhole perspective projection, and helper spawners (`spawnFlamePlume`,
  `spawnWaterSplash3D`).
