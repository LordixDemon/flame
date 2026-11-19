# Geometry and Scene Queries

Everything `flame_3d` draws is made of triangles. A **surface** is an indexed list of triangles
drawn with one material: its vertices are interleaved floats on the GPU, followed by 16-bit or
32-bit indices. A **mesh** groups surfaces (one per material) and has bounds; a `MeshComponent`
places a mesh in the world. This page covers how to build surfaces and meshes, the built-in shapes,
bounds, and how to cast rays against surfaces and whole scenes. Models loaded from files are
described in [Models and Animation](models_and_animation.md).

Conventions used throughout:

- Coordinates are right-handed. The built-in meshes are modelled with `+y` up, except where a
  parameter says otherwise (`TerrainMesh3D.upAxis`).
- A triangle's front face is the one from which its vertices `(v0, v1, v2)` appear
  counter-clockwise, so its geometric normal is `(v1 - v0) x (v2 - v0)`. Back-face culling and
  culled ray casts use this rule. Objects with a mirroring transform keep their front faces: the
  renderer flips the winding for them.
- Units are whatever your game uses; nothing in this part of the package assumes meters.


## Surfaces


### From `Vertex` objects

The simplest way to make a surface is a list of `Vertex` objects and a list of indices, three per
triangle:

```dart
final triangle = Surface(
  vertices: [
    Vertex(position: Vector3(0, 0, 0), texCoord: Vector2(0, 1)),
    Vertex(position: Vector3(1, 0, 0), texCoord: Vector2(1, 1)),
    Vertex(position: Vector3(0, 1, 0), texCoord: Vector2(0, 0)),
  ],
  indices: [0, 1, 2],
  material: SpatialMaterial(albedoColor: const Color(0xFF4080FF)),
);
world.add(MeshComponent(mesh: Mesh()..addSurface(triangle)));
```

A `Vertex` has a `position` and `texCoord` (both required), a `color` (opaque white by default),
and optionally a `normal`, `joints` and `weights` (skinning), a `tangent` (`xyz` and the bitangent
sign in `w`) and a second UV set `texCoord1`. When some vertex has no normal and
`calculateNormals` is `true` (the default), the missing normals are averaged from the faces that
use the vertex: vertices shared by several triangles get smooth normals, duplicated vertices get
hard edges.

Without a `material`, a surface uses `Material.defaultMaterial`, a magenta `SpatialMaterial` that
makes missing materials easy to spot. The built-in meshes use it too when you pass no material.

Each `Vertex` allocates several objects, so this constructor suits small, hand-made shapes. For
anything generated at runtime or large, build from typed arrays.


### From typed arrays

`Surface.fromBuffers` takes the interleaved vertex data as a `Float32List` and the indices as a
`Uint16List` or a `Uint32List`, without creating an object per vertex. The data is used as is (it
is not copied), so keep a reference if you want to change it later with `updateVertices`:

```dart
// Two triangles in the standard 20-float layout:
// position(3) uv(2) color(4) normal(3) joints(4) weights(4).
Float32List quadVertices(double size) {
  final data = Float32List(4 * 20);
  const corners = [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)];
  for (final (i, (u, v)) in corners.indexed) {
    data.setAll(i * 20, [
      u * size, 0, -v * size, // position, in the xz plane
      u, v, // uv
      1, 1, 1, 1, // color
      0, 1, 0, // normal, +y
    ]);
  }
  return data;
}

final quad = Surface.fromBuffers(
  vertices: quadVertices(2),
  indices: Uint16List.fromList([0, 1, 2, 2, 3, 0]),
  material: SpatialMaterial(),
);
```

It throws an `ArgumentError` when the vertex data does not hold a whole number of vertices for the
layout, or when the indices are not a `Uint16List` or `Uint32List`. The bounds are computed from
the positions unless you pass `aabb`.


### Vertex layouts and attribute names

A `VertexLayout` lists the float attributes of one vertex, in storage order, packed without
padding. Each attribute feeds the vertex shader input with the same name; Flutter GPU binds
attributes by name, so the order in the layout does not have to match the order in the shader.
Layouts compare by value, and surfaces with equal layouts share pipelines.

| Attribute         | Floats | `standard` offset | `pbrStandard` offset |
|-------------------|--------|-------------------|----------------------|
| `vertexPosition`  | 3      | 0                 | 0                    |
| `vertexTexCoord`  | 2      | 3                 | 3                    |
| `vertexColor`     | 4      | 5                 | 5                    |
| `vertexNormal`    | 3      | 9                 | 9                    |
| `vertexJoints`    | 4      | 12                | 12                   |
| `vertexWeights`   | 4      | 16                | 16                   |
| `vertexTangent`   | 4      |                   | 20                   |
| `vertexTexCoord1` | 2      |                   | 24                   |
| Stride            |        | 20                | 26                   |

`Surface(vertices: ...)` packs into `standard`, or into `pbrStandard` when some vertex has a
`tangent` or a `texCoord1` (vertices without a tangent then get `(1, 0, 0, 1)`, and vertices
without `texCoord1` repeat `texCoord`). `Surface.fromBuffers` uses `standard` unless you pass a
`layout`:

```dart
final pointCloud = Surface.fromBuffers(
  vertices: data, // 7 floats per vertex
  indices: Uint16List.fromList(indices),
  layout: VertexLayout(const [
    VertexAttribute(VertexLayout.positionAttribute, 3),
    VertexAttribute('vertexColor', 4),
  ]),
  material: vertexColorMaterial,
);
```

Rules for custom layouts:

- An attribute has 1 to 4 floats; names must be unique.
- The names of the per-instance inputs (`instanceModel0` to `instanceModel3`, `instanceColor`,
  `instanceData`) are reserved: the renderer feeds them from its instance buffer.
- The bounds, the BVH used for ray casts and the morph targets read the attribute named
  `vertexPosition` (`VertexLayout.positionAttribute`). A layout without it gets empty bounds and
  cannot be hit by rays.
- The surface must provide every input the material's vertex shader declares (besides the
  instance inputs), or the pipeline cannot be created. A material may pick a different vertex
  shader per layout (`Material.vertexShaderFor`): `SpatialMaterial` uses its tangent-space variant
  for layouts with both `vertexTangent` and `vertexTexCoord1` (not on the web), and
  `StylizedMaterial` has variants for the standard layout and for its own layouts (see
  [Materials and Textures](materials.md)).


### Indices and vertex limits

Index data is 16-bit (`GpuIndexType.uint16`) or 32-bit (`uint32`); `Surface.indexType` tells
which. `Surface(vertices: ...)` picks 32-bit indices when the surface has more than 65,535
vertices or uses the index 65,535, and 16-bit ones otherwise. `Surface.fromBuffers` keeps the type
of the list you pass. The built-in generators choose 32-bit indices above 65,535 vertices. There is
no other vertex limit than memory.

`Surface.topology` (a `PrimitiveTopology`) is `triangles` by default; the renderer also draws
`triangleStrip`, `lines`, `lineStrip` and `points`. Normals are only computed for triangle lists,
while `computeTangents`, the BVH and ray casts read the indices as a triangle list whatever the
topology, so do not ray cast against surfaces of other topologies.


### Updating vertices

`updateVertices(newVertices)` copies a list of the same length into the surface (pass the
surface's own `vertexData` after editing it in place to skip the copy), recomputes its bounds
unless you pass `aabb`, forgets the cached BVH and, when the GPU buffer already exists, writes the
whole vertex range into it again:

```dart
final data = surface.vertexData;
for (var v = 0; v < surface.vertexCount; v++) {
  data[v * 20 + 1] = math.sin(time + v * 0.3) * 0.1; // y of each vertex
}
surface.updateVertices(data);
mesh.updateBounds(); // the mesh caches the union of its surfaces' bounds
waterComponent.markAabbDirty(); // so does the component, in world space
```

The vertex count and layout cannot change; build a new surface for that. Every call uploads the
full vertex buffer (`vertexCount * layout.strideInBytes` bytes) and costs a pass over the vertices
for the bounds.

The GPU buffer of a surface is created the first time it is drawn: one host-visible buffer holding
the vertices followed by the indices, padded to 4 bytes (`verticesBytes`, `indicesBytes`).
`dispose()` releases it; it is created again if the surface is drawn later.


### Tangents and the second UV set

Normal maps need a tangent frame per vertex. `Surface.computeTangents()` computes one from the
positions, normals and first UV set, and by default stores it in the surface:

```dart
final surface = mesh.surfaces.first;
surface.computeTangents(); // layout becomes VertexLayout.pbrStandard
```

The tangents are accumulated per triangle from the UV gradients and orthogonalized against the
normal (Gram-Schmidt); the fourth component is the bitangent sign, `-1` or `+1`. Vertices whose
triangles have degenerate UVs get an arbitrary tangent perpendicular to the normal. This is not the
MikkTSpace algorithm that baking tools use, so normal maps baked against MikkTSpace can show slight
shading differences, mostly along UV seams.

If the layout has no `vertexTangent` or `vertexTexCoord1` yet, the surface is repacked into a wider
layout (`pbrStandard` when it was `standard`): the second UV set is taken from the `texCoord1` you
pass, or copied from `vertexTexCoord`. Repacking replaces `vertexData` and drops the GPU buffer, so
call it once at load time, not every frame. `computeTangents(storeInSurface: false)` only returns
the tangents (4 floats per vertex), and `Surface.calculateTangents(...)` does the same from raw
arrays.


### Morph targets

A surface can carry morph targets (blend shapes): `MorphTargetData` holds a position delta per
vertex (`positionDeltas`, 3 floats per vertex) and optionally normal deltas. `applyMorphWeights`
rebuilds the vertices from the rest pose plus the weighted deltas, renormalizes the normals and
uploads the result:

```dart
final face = Surface.fromBuffers(
  vertices: restVertices,
  indices: indices,
  morphTargets: [
    MorphTargetData(name: 'smile', positionDeltas: smileDeltas),
    MorphTargetData(name: 'blink', positionDeltas: blinkDeltas),
  ],
);
face.applyMorphWeights([0.8, 0.0]);
```

Morphing runs on the CPU: each call costs `vertexCount` operations per target with a non-zero
weight, a pass for the bounds and a full upload of the vertex buffer. Targets whose weight is below
`1e-6` are skipped. Tangents are not morphed. The rest pose is kept in a copy made when the surface
is built. For models, `ModelComponent` applies animated weights for you, see
[Models and Animation](models_and_animation.md#morph-targets).


## Meshes

A `Mesh` is a list of surfaces with cached bounds. Use one surface per material; a
`MeshComponent` records one draw per surface:

```dart
final house = Mesh()
  ..addSurface(wallsSurface) // drawn with the walls' material
  ..addSurface(roofSurface); // drawn with the roof's material
final houses = [
  for (var i = 0; i < 20; i++)
    MeshComponent(mesh: house, position: Vector3(i * 4.0, 0, 0)),
];
```

Share meshes and materials between components: draws of the same surface with the same material
instance are batched into instanced draws, so twenty houses above cost two draw calls (see
[Rendering](rendering.md)). `addSurface`, `updateSurface`, `removeSurface` and `updateSurfaces`
reset the cached bounds; after changing a surface's vertices yourself, call `updateBounds()`.


### Built-in meshes

All built-in meshes are `Mesh` subclasses with one surface (`ConeMesh` has two), built once in the
constructor; all take an optional `material`. Their normals point out of the shape. Parameters
without a default are required.

- `PlaneMesh(size)`: a quad in the xz plane facing `+y`, `size.x` by `size.y` (along z), centered
  on the origin; 4 vertices.
- `CuboidMesh(size, useFaceNormals: true)`: a box centered on the origin; 24 vertices, hard edges.
- `SphereMesh(radius, segments: 64)`: a UV sphere centered on the origin; `(segments + 1)^2`
  vertices.
- `CylinderMesh(radius, height, segments: 16)`: along y, centered, with caps.
- `ConeMesh(radius, height, material, segments: 32)`: base disc on y = 0, tip at y = `height`; the
  material is required.
- `CapsuleMesh(radius, height, segments: 16, hemisphereRings: 6)`: along y, centered.
- `TorusMesh(majorRadius: 0.7, minorRadius: 0.22, majorSegments: 28, minorSegments: 14)`: a ring
  in the xz plane around the y axis.
- `TubeSplineMesh(spline, radius: 0.18, tubularSegments: 48, radialSegments: 10,
  crossSectionAspect: 1, uvLengthScale: 1, color: white)`: a tube along a `CatmullRomSpline3D`.
- `TerrainMesh3D`: a heightfield grid, see below.

Notes on individual shapes:

- `SphereMesh` defaults to 64 segments: 4,225 vertices and 8,192 triangles. Use 16 to 24 segments
  for small objects. Its normals are averaged from the faces, which leaves a faint crease along the
  UV seam and at the poles at low segment counts.
- `CuboidMesh` gives each face its own four vertices, so `useFaceNormals: false` (normals computed
  from the faces) gives the same hard-edged result.
- `ConeMesh` has a separate surface for the base disc and the side; it requires a material. The side
  has one tip vertex per segment, with the slanted side's normal, and repeats its first ring vertex
  with `u = 1`, so the texture runs from `u = 0` to `1` around the cone without wrapping back.
- `CapsuleMesh.height` is the full height including the caps; the cylindrical part is
  `max(0, height - 2 * radius)`.
- `TubeSplineMesh` frames its cross-section with parallel transport along the spline, so it does
  not twist. `crossSectionAspect` widens the cross-section along the frame's normal (a flattened
  ribbon, a road). `u` goes around the tube from 0 to 1, `v` is the arc length times
  `uvLengthScale`. The ends are not capped.
- `CatmullRomSpline3D(points, closed: false)` needs at least two points. `samplePoint(t)` and
  `sampleTangent(t)` take `t` in `[0, 1]`, split evenly between the segments (not by arc length).

Every built-in mesh is wound counter-clockwise seen from outside, matching its normals, so
back-face culling (`CullMode.backFace`) and culled ray casts work with all of them. A
`TubeSplineMesh` bent tighter than its radius folds over itself on the inner side of the bend;
keep the bend radius above the tube's radius.


### Terrain heightfields

`TerrainMesh3D` builds a grid of `columns x rows` vertices (both at least 2) spanning `width` by
`depth`, centered on the origin, from a `Float32List` of heights in row-major order
(`heights[row * columns + column]`). Columns run along x, rows along z (or along y when
`upAxis` is `TerrainUpAxis.z`, for boards and other z-up scenes); the height goes along the up
axis. Normals come from central differences of the heights; UVs run from 0 to `uvScale` across the
grid; `colorRamp(height, slope)` may color each vertex, with `slope` from 0 (flat) to 1 (vertical).
Grids above 65,535 vertices use 32-bit indices.

```dart
final terrain = TerrainMesh3D.procedural(
  columns: 96,
  rows: 96,
  width: 40,
  depth: 40,
  amplitude: 3,
  colorRamp: (height, slope) =>
      slope > 0.4 ? const Color(0xFF7A6A58) : const Color(0xFF5E8C3A),
  material: SpatialMaterial(),
);
world.add(MeshComponent(mesh: terrain));

// Stand a tree on the ground (local coordinates of the terrain mesh).
final y = terrain.sampleHeight(12, -7);
world.add(MeshComponent(mesh: treeMesh, position: Vector3(12, y, -7)));
```

`TerrainMesh3D.procedural` sums three sine waves (`amplitude` `1.4`, `frequency` `0.45`), fades
them to zero at the edges when `islandFalloff` is `true`, and defaults to a 64 x 64 grid of
12 x 12 units with `uvScale` `4`. `sampleHeight(u, v)` interpolates the heights bilinearly and
clamps outside the grid; `sampleNormal(u, v)` uses finite differences. Both work in the mesh's local
space. The mesh itself is triangulated, so inside a cell the rendered surface can differ slightly
from the bilinear height; cast a ray when you need the exact surface point. For large, streamed
terrain with levels of detail, see `ChunkedTerrain3D` in [Large Worlds](world_scale.md).


## Bounds

Bounds are axis-aligned boxes (`Aabb3`):

- `Surface.aabb`, in the surface's space, computed from the `vertexPosition` attribute when the
  surface is built (or given to `Surface.fromBuffers`) and recomputed by `updateVertices`.
- `Mesh.aabb`, the union of its surfaces' bounds, cached until `updateBounds()`.
- `Component3D.aabb`, in world space, covering the component's own geometry and all its
  `Component3D` children. It is cached and recomputed when the component or an ancestor moves, or
  after `markAabbDirty()`.

Frustum culling, shadow fitting and the broad phase of ray casts use the component bounds. A
`ModelComponent` uses `Model.animatedAabb`, see
[Models and Animation](models_and_animation.md#models-and-nodes).


## Ray casting

Rays are vector_math `Ray`s (exported by `package:flame_3d/camera.dart`), built with
`Ray.originDirection(origin, direction)`. Every surface has a bounding volume hierarchy (BVH) over
its triangles, built the first time a ray is cast against it; a scene query first tests component
bounds, then the BVHs of the candidates.


### Against one surface

`surface.bvh` is a `SurfaceBvh`; its `raycast` takes a ray in the surface's own space and returns
the nearest `SurfaceRayHit` within `maxDistance`, or `null`:

```dart
final hit = surface.bvh.raycast(
  Ray.originDirection(Vector3(0, 10, 0), Vector3(0, -1, 0)),
  cullMode: CullMode.backFace, // ignore triangles seen from behind
);
if (hit != null) {
  // Interpolate the UV of the hit from the triangle's vertices.
  final first = hit.triangleIndex * 3;
  final stride = surface.layout.strideInFloats;
  final uvOffset = surface.layout.offsetOf('vertexTexCoord')!;
  Vector2 uvOf(int corner) {
    final base = surface.indices[first + corner] * stride + uvOffset;
    return Vector2(surface.vertexData[base], surface.vertexData[base + 1]);
  }

  final w0 = 1 - hit.barycentricU - hit.barycentricV;
  final uv = uvOf(0) * w0 +
      uvOf(1) * hit.barycentricU +
      uvOf(2) * hit.barycentricV;
}
```

A `SurfaceRayHit` has the `distance` along the ray (in units of the ray direction's length), the
`point` and the geometric `normal` of the triangle (unit length, following the counter-clockwise
rule), the `triangleIndex` and the barycentric coordinates `barycentricU` (weight of `v1`) and
`barycentricV` (weight of `v2`). `raycastAll(ray, out)` appends every hit, unsorted.

`cullMode` is `CullMode.none` by default (both sides hit); `backFace` keeps only triangles facing
the ray's origin, `frontFace` only those facing away. Hits closer than `1e-7` are ignored, so a ray
starting on a surface does not hit it.

The BVH is built on first access, on the calling isolate. A hierarchy built elsewhere, for example
by `AsyncModelLoader3D.buildSurfaceBvhsInIsolate` (see
[Models and Animation](models_and_animation.md#loading-off-the-main-isolate)), is handed to the
surface with `surface.adoptBvh(SurfaceBvh.fromPrepared(...))`.

To cast against a surface placed in the world, use
`RayHit3D.intersectSurface(owner:, surface:, modelMatrix:, worldRay:)` or
`RayHit3D.intersectMesh(...)`: they bring the ray into the surface's space with the inverse of the
model matrix (any affine transform, mirrored or not), and return the hit in world space.

To test a collision shape instead of a ray against a surface's triangles, use
`Narrowphase3D.intersectShapeWithSurfaceBvh`, which returns the deepest contact (see
[Collision shapes](physics.md#collision-shapes)).


### Against a scene

`World3D.raycast` returns the nearest hit among all the `Object3D`s of the world, or `null`;
`raycastAll` returns every hit, nearest first:

```dart
final hit = world.raycast(
  Ray.originDirection(Vector3(0, 20, 0), Vector3(0, -1, 0)),
  maxDistance: 50,
  filter: (object) => object != player, // skip some objects
);
if (hit != null) {
  marker.position.setFrom(hit.worldPoint);
}
```

The ray direction does not need to be unit length; the world normalizes it, so `distance` and
`maxDistance` are in world units. A `RayHit3D` has the `object` hit, the `surface` and its
`surfaceIndex` in the mesh, the `distance`, `worldPoint` and `worldNormal`, the same point and the
triangle's normal in the surface's space (`localPoint`, `localNormal`) and the `triangleIndex`. For
barycentric coordinates, cast against `hit.surface.bvh` with the ray in local space. A hit on an
object that draws instances has the index of the instance hit in `instanceIndex`: the instance of
an `InstancedGroup3D`, the agent of a `SkinnedCrowdBatch3D` (`null` for other objects). For
compatibility, a hit on an `InstancedGroup3D` also carries the index of the instance in
`surfaceIndex` instead of the surface's index; `hit.surface` tells which surface was hit.

When `cullMode` is `null` (the default), each surface is tested with the cull mode of its material's
render state: a back-face culled material cannot be hit from behind, a double-sided one can. Pass a
`cullMode` to override it for all surfaces.

Without the spatial index (see below), the world walks its component tree and skips any subtree
whose bounds the ray misses within the current nearest distance, then tests each remaining
`Object3D`. These components can be hit:

| Component             | What the ray is tested against                                     |
|-----------------------|--------------------------------------------------------------------|
| `MeshComponent`       | its mesh, with its world transform                                 |
| `LodMeshComponent`    | the level it drew last                                             |
| `InstancedGroup3D`    | every instance; `instanceIndex` (and `surfaceIndex`) is the index  |
| `ModelComponent`      | the meshes of its nodes in the current node transforms, rest pose  |
|                       | for skinned surfaces                                               |
| `SkinnedCrowdBatch3D` | every agent, in its baked node transforms, rest pose for skinned   |
|                       | surfaces; `instanceIndex` is the index of the agent                |

Other components document their own ray casts (`ChunkedTerrain3D` and `StaticMeshBatcher3D` in
[Large Worlds](world_scale.md), `WidgetSurface3D` in [3D UI and Text](ui_3d.md)). Only what a
render pass could draw is hit: a component with `visible = false`, or whose `cameraMask` shares no
bit with the query's `cameraMask` (every bit by default), is skipped with its whole subtree. Pass a
camera's mask to hit only what that camera shows, `includeHidden: true` to test everything (for
probes against invisible collision geometry), and `filter` to exclude more:

```dart
final hit = world.raycast(
  ray,
  cameraMask: camera.cameraMask, // only what this camera draws
  filter: (object) => object != player,
);
```


### Picking with the mouse or a finger

In a full 3D game, `CameraComponent3D.viewportPointToRay` turns a point of the viewport into a ray
that starts on the near plane and has a unit direction, for both perspective and orthographic
cameras:

```dart
// For example from the onTapDown of a game with TapCallbacks.
RayHit3D? pick(FlameGame3D game, Vector2 canvasPosition) {
  final ray = game.camera.viewportPointToRay(canvasPosition);
  return game.world.raycast(ray);
}
```

For a viewport that does not fill the game, convert the position with
`camera.viewport.globalToLocal(event.canvasPosition)` first. A 3D layer embedded in a 2D game picks
in its own local 2D coordinates: `Scene3DComponent.raycastLocal(localPoint)` and
`raycastAllLocal(localPoint)` build the ray with `localPointToRay` and cast it into the layer's
world (see [Embedding 3D in a 2D Game](embedding.md)). For tap, hover and drag callbacks on 3D
objects, see `PointerRouter3D` in [Input and Effects](input_and_effects.md).


### The spatial index

For worlds with hundreds of objects, `World3D(spatialIndex3DEnabled: true)` (or setting the field
later) makes `raycast` and `raycastAll` go through `world.spatialIndex3D`, a BVH over the world
bounds of every `Object3D` in the world. The nearest-hit query visits nodes front to back and stops
descending once the nearest hit is closer than a node; `lastRaycastCandidatesTested` reports how
many objects were tested in the last query. The index also answers box and frustum queries:

```dart
final world = World3D(spatialIndex3DEnabled: true);
// ...
final nearby = world.spatialIndex3D.queryAabb(
  world,
  Aabb3.minMax(Vector3(-5, -1, -5), Vector3(5, 3, 5)),
);
final inView = world.spatialIndex3D.queryFrustum(world, frustum);
```

The index is rebuilt lazily, on the next query after `World3D.sceneVersion` changes, which happens
whenever any component is added, removed or moved, or an animation, particle system, light, fog or
bloom changes. In a scene where something moves every frame, each query frame therefore pays a
full rebuild (collecting every object's bounds and building the tree, `O(n log n)`), and the index
only pays off when you cast many rays per frame or the scene is mostly still.
`spatialIndex3DEnabled` only affects these queries: the renderer's frustum culling walks the
component tree and never uses the index.


### Costs

- The first ray against a surface builds its BVH on the calling thread: `O(t log t)` for `t`
  triangles, keeping about 76 bytes per triangle. Later rays cost `O(log t)` on average. Changing a
  surface's vertices (`updateVertices`, `applyMorphWeights`, morph animation) drops the BVH, so the
  next ray rebuilds it.
- For each candidate object, the world inverts the object's model matrix (one per surface for
  meshes, one per instance for `InstancedGroup3D` and `SkinnedCrowdBatch3D`).
- `raycastAll` and `SurfaceRayHit` allocate their results; `raycast` allocates only the hit it
  returns.
- All of this is CPU work in Dart and behaves the same on every platform.


## Limitations

- Skinned surfaces of `ModelComponent` and `SkinnedCrowdBatch3D` are tested in their rest pose,
  placed by their node transforms: the ray does not follow the skinned, animated shape. Use
  `SkinnedHitboxRig3D` (see [Collisions and Physics](physics.md)) to hit animated characters.
- The BVH traversal uses a fixed stack of 128 entries; extremely unbalanced triangle distributions
  (thousands of triangles at exponentially growing distances) could exceed it.
- Computed normals, tangents and the BVH read the indices as a triangle list whatever
  `Surface.topology` says.
- Mesh bounds are not updated automatically after `updateVertices`; call `Mesh.updateBounds()` and
  `Component3D.markAabbDirty()`.
