# Rendering

This page describes how `flame_3d` turns the components of a `World3D` into GPU work, and what
you can control along the way.


## Draws are recorded, then sorted

While the world is traversed, every visible `Object3D` records its draws into the
`RenderContext3D` (a `MeshComponent` records one draw per surface of its mesh). Nothing reaches the
GPU until the end of the render pass, when the recorded draws are submitted:

- Opaque draws are grouped by pipeline, material and surface, then roughly ordered front to back.
  Consecutive draws of the same `Surface` with the same `Material` instance become a single
  instanced draw. Components that share a `Mesh` therefore cost one draw call per surface, however
  many of them there are.
- Translucent draws come after all the opaque ones, ordered back to front, one draw each.
- Skinned draws are never batched.

Because materials are applied when the draws are submitted, a material must not change its values
between the draws of one frame to make objects look different: use distinct materials, or the
per-instance color.


## Per-instance color

Each draw carries a color besides its model matrix, `MeshComponent.color` (white by default). The
built-in materials multiply their base color by it, so many tinted copies of a mesh still batch:

```dart
for (final (i, color) in playerColors.indexed) {
  world.add(
    MeshComponent(mesh: pawn, position: Vector3(i * 2.0, 0, 0), color: color),
  );
}
```


## Render state

A material declares how it is drawn with its `renderState`: the blend mode (`BlendState.opaque`,
`alpha`, `premultipliedAlpha` or `additive`), whether the depth test is on and with which
`CompareFunction`, whether depth is written, the `CullMode`, and whether the material is
translucent (by default, every blend mode other than opaque is).

```dart
final glow = UnlitMaterial()..renderState = RenderState.additive;

final shadow = UnlitMaterial(albedoColor: const Color(0x80000000))
  ..renderState = const RenderState(
    blend: BlendState.alpha,
    depthWrite: false,
  );

final floor = SpatialMaterial()
  ..renderState = const RenderState(cullMode: CullMode.backFace);
```

Front faces are counter-clockwise on screen. The winding flips automatically when the camera mirrors
the scene, and for objects whose transform mirrors them (an odd number of negative scales), so
back-face culling keeps culling the faces that point away from the camera.

`SpatialMaterial` is opaque by default. `UnlitMaterial` may output translucent colors, so by default
it blends with premultiplied alpha and draws as translucent; set its `renderState` to
`RenderState.opaque` for opaque content so that it batches.


## Surfaces from typed arrays and custom vertex layouts

Besides a list of `Vertex` objects, a `Surface` can be built straight from an interleaved
`Float32List` and a `Uint16List` or `Uint32List` of indices, which avoids creating an object per
vertex. Surfaces with more than 65,535 vertices use 32-bit indices.

A surface may declare its own vertex layout. Each attribute feeds the vertex shader input with the
same name, and a material's pipeline is created for the layout of each surface it draws:

```dart
final surface = Surface.fromBuffers(
  vertices: data, // 7 floats per vertex
  indices: Uint16List.fromList(indices),
  layout: VertexLayout(const [
    VertexAttribute('vertexPosition', 3),
    VertexAttribute('vertexColor', 4),
  ]),
  material: vertexColorMaterial,
);
```

A surface must provide every input the material's vertex shader declares, except the per-instance
inputs, which `flame_3d` feeds itself. The standard layout (`VertexLayout.standard`) has a position,
texture coordinates, a color, a normal, joints and joint weights.


## Shaders

Custom shaders can include the chunks `flame_3d` ships:

- `flame_3d/instancing.glsl` declares the per-instance inputs: the columns of the model matrix
  (`instanceModel0` to `instanceModel3`) and `instanceColor`, and `instanceModelMatrix()`. A vertex
  shader that declares the model columns is drawn instanced. One that does not gets its model matrix
  from uniforms its material sets in `apply`, from `RenderContext3D.model`, and draws each object on
  its own.
- `flame_3d/camera.glsl` declares the `CameraMatrices` block (`view`, `projection`,
  `viewProjection`).
- `flame_3d/skinning.glsl` handles vertex skinning.

Blocks named `CameraMatrices`, `Camera` (`position`), `AmbientLight` and `Lights` are filled once
per render pass by the `RenderContext3D`, for every shader that declares them; the joint matrices of
skinned draws are filled for each draw. Register your own per-pass blocks with
`RenderContext3D.registerPassUniform`.


## Frame output and statistics

Each camera renders the world into an image of its viewport size in physical pixels, rounded to
whole pixels. `World3D.renderScale` renders it at a fraction of that size (or above `1` to
render more pixels than the viewport covers); the image is scaled to the viewport when drawn.

`FlameGame3D.renderStats` holds the statistics of the last rendered frame: render passes, draw
calls, instances, triangles, pipeline changes, render state changes, material changes, uniform
uploads and uploaded bytes.
