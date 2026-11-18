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
- Translucent draws come after all the opaque ones, ordered back to front. Consecutive translucent
  draws of the same `Surface` with the same `Material` instance also become a single instanced draw,
  whose instances are drawn in that back to front order.
- Skinned draws are never batched.

Because materials are applied when the draws are submitted, a material must not change its values
between the draws of one frame to make objects look different: use distinct materials, or the
per-instance color and data.

When a directional light casts shadows (see [Shadows](shadows.md)), the world is traversed twice
per frame: first with the light's view as the camera (`RenderContext3D.isShadowPass` is `true`),
to render the shadow map from the draws of the objects and materials that cast shadows, then for
the main pass. In the shadow pass, draws of one surface become a single instanced draw whatever
their materials, drawn with depth-only shaders.


## Per-instance color and data

Each draw carries a color besides its model matrix, `MeshComponent.color` (white by default). The
built-in materials multiply their base color by it (`StylizedMaterial` only on the vertices of its
tint mask), so many tinted copies of a mesh still batch:

```dart
for (final (i, color) in playerColors.indexed) {
  world.add(
    MeshComponent(mesh: pawn, position: Vector3(i * 2.0, 0, 0), color: color),
  );
}
```

Each draw also carries four floats of per-instance data, `MeshComponent.instanceData` (zero by
default), that materials are free to interpret: a highlight, an emissive strength, an opacity, a
wind strength... Objects that differ only in their color and data still batch.
`SpatialMaterial` and `UnlitMaterial` ignore the data; `StylizedMaterial` reads it as described in
[Materials and Lighting](materials.md#per-instance-data).

```dart
final house = MeshComponent(mesh: houseMesh, instanceData: Vector4.zero());

// Later, when the pointer is over it:
house.instanceData.x = 0.5;
```

Custom objects pass them to `RenderContext3D.drawSurface` and `drawMesh` with `color` and
`instanceData`; both are copied when the draw is recorded.

Objects that build their own instance data, such as particle systems, record it whole with
`RenderContext3D.drawInstances`: one instanced draw of a surface, whatever the number of instances,
read from a `Float32List` of 24 floats per instance (the model matrix columns, the color and the
data, or whatever the material's vertex shader makes of them) when the draws are flushed. Such a
draw is never batched with others; a translucent one is ordered by the `center` it is given. See
[Particles](particles.md).


## Render state

A material declares how it is drawn with its `renderState`: the blend mode (`BlendState.opaque`,
`alpha`, `premultipliedAlpha`, `additive` or `depthOnly`), whether the depth test is on and with
which `CompareFunction`, whether depth is written, the `CullMode`, and whether the material is
translucent (by default, every blend mode other than opaque is). Additive draws add their color and
keep the alpha of the target: added light covers nothing, so in a `Scene3DComponent` a glow over an
empty part of the scene adds its color to the 2D components drawn behind the layer.

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

A translucent object drawn with a single translucent material shows its own hidden parts through
its near ones: an arm in front of a body lets the body show through it. To fade the object as one
piece, draw it first with a depth prepass, `RenderState.depthOnly` (`BlendState.depthOnly` writes no
color, only depth, and draws among the translucent draws), then with a translucent material whose
depth test passes on equal depths: only its nearest surfaces blend, over whatever is behind it.

```dart
final prepass = StylizedMaterial()..renderState = RenderState.depthOnly;
final ghost = StylizedMaterial(translucent: true)
  ..renderState = StylizedMaterial.translucentRenderState.copyWith(
    depthCompare: CompareFunction.lessEqual,
  );

// Recorded in this order, the prepass is drawn right before the ghost:
// both have the same depth in the back to front order.
context
  ..drawSurface(surface, transform: model, material: prepass)
  ..drawSurface(surface, transform: model, material: ghost);
```

Front faces are counter-clockwise on screen. The winding flips automatically when the camera mirrors
the scene, and for objects whose transform mirrors them (an odd number of negative scales), so
back-face culling keeps culling the faces that point away from the camera.

`SpatialMaterial` and `StylizedMaterial` are opaque by default. `UnlitMaterial` may output
translucent colors, so by default it blends with premultiplied alpha and draws as translucent; set
its `renderState` to `RenderState.opaque` for opaque content so that it batches. The built-in
materials and the lights are described in [Materials and Lighting](materials.md).


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
texture coordinates, a color, a normal, joints and joint weights. A material can draw several
layouts with a vertex shader variant per layout, see `Material.vertexShaderFor`.


## Shaders

Custom shaders can include the chunks `flame_3d` ships:

- `flame_3d/instancing.glsl` declares the per-instance inputs: the columns of the model matrix
  (`instanceModel0` to `instanceModel3`), `instanceColor` and `instanceData`, and
  `instanceModelMatrix()`. A vertex shader that declares the model columns is drawn instanced. One
  that does not gets its model matrix from uniforms its material sets in `apply`, from
  `RenderContext3D.model`, and draws each object on its own. `instanceModelMatrix()` also reads
  `instanceColor` and `instanceData` (without changing the matrix): `impellerc` cannot compile a
  vertex shader whose inputs leave a gap, which reading `instanceData` but not `instanceColor` would
  otherwise do.
- `flame_3d/camera.glsl` declares the `CameraMatrices` block (`view`, `projection`,
  `viewProjection`).
- `flame_3d/skinning.glsl` handles vertex skinning: it declares the `vertexJoints` and
  `vertexWeights` inputs and the `JointMatrices` block (16 matrices), and `computeSkinMatrix()`.
- `flame_3d/lights.glsl` declares the light blocks: `AmbientLight`, `Lights` (point lights),
  `DirectionalLights` and `HemisphereLight`, see
  [Materials and Lighting](materials.md#custom-shaders).
- `flame_3d/shadows.glsl` declares the `Shadows` block and the `shadowMap` sampler, and
  `shadowVisibility()`, `shadowFactor()` and `castsShadows()` to receive shadows, see
  [Shadows](shadows.md#receiving-shadows).

Blocks named `CameraMatrices`, `Camera` (`position`, and any of the `CameraMatrices` members),
`AmbientLight`, `Lights`, `DirectionalLights` and `HemisphereLight` are filled once per render pass
by the `RenderContext3D`, for every shader that declares them; the joint matrices of skinned draws
are filled for each draw, from the `jointTransforms` given to `RenderContext3D.drawSurface` (or to
`drawMesh`, by surface index, which `MeshComponent.jointTransforms` feeds), whatever the surface:
a parsed model's or one built with `Surface.fromBuffers`. The `Shadows` block and the `shadowMap`
sampler are filled once per pass too. Register your own per-pass blocks with
`RenderContext3D.registerPassUniform`, and per-pass textures with
`RenderContext3D.registerPassTexture`.


## Frame output and statistics

Each camera renders the world into an image of its viewport size in physical pixels, rounded to
whole pixels. `World3D.renderScale` renders it at a fraction of that size (or above `1` to
render more pixels than the viewport covers); the image is scaled to the viewport when drawn.

The render targets of a `GraphicsDevice` are pooled by size: a size that is not used in a frame
stays pooled for `GraphicsDevice.targetRetainFrames` frames. A render target owns up to three color
textures, created once, which its passes take turns rendering into; the image of a pass is drawn by
Flutter straight from its texture. A texture is rendered into again only once Flutter can no longer
draw its previous image: Flutter rasterizes at most the frame it is building and the one before, so
two frames later the image has been drawn, and the draws that read it were submitted to the GPU
before the new pass is. A scene rendered every frame therefore uses two textures; when Flutter draws
no frames (passes rendered outside of frames), the texture rendered the longest ago of the three is
reused.

Shadow maps render into textures that later passes sample (`GraphicsDevice.textureTarget`), created
once for each size and format and kept while they are used.

`FlameGame3D.renderStats` holds the statistics of the last rendered frame: render passes, draw
calls, instances, triangles, pipeline changes, render state changes, material changes, uniform
uploads, uploaded bytes, the particles drawn by particle systems, and how many of the passes and
draw calls rendered shadow maps (`shadowPasses` and `shadowDrawCalls`).


### Profiling

Built with `--dart-define=FLAME_3D_PROFILE=true`, the renderer times its phases on the CPU into
`RenderProfile.active`: walking the components, culling, recording draws, particles, sorting,
batching, render state, `Material.apply`, the uniform blocks of the pass, uploads, bindings,
gathering instances, draw calls, and beginning and ending passes, the shadow pass apart. Without
the define, the timing is compiled out.

```dart
final profile = RenderProfile.active = RenderProfile();
// ... render some frames ...
for (final phase in RenderPhase.values) {
  print('${phase.name}: ${profile.microseconds(phase)} us, '
      'shadow pass ${profile.microseconds(phase, shadow: true)} us');
}
```

Timing every draw costs a little, so compare its totals with a build without the define. The
package's `benchmark/` renders a board-like scene (a few hundred instanced objects, skinned
characters, shadows, particles) and reports these phases, the objects allocated per frame and the
`RenderStats`, under `flutter test` or in a profile build: see its README.
