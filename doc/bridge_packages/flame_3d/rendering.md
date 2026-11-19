# Rendering

This page describes how `flame_3d` turns the components of a `World3D` into GPU work: how a frame
is recorded, sorted and batched, the render state a material draws with, shaders, the optional
passes (custom passes, order-independent transparency, the scene-color grab pass, HDR targets) and
how to measure what a frame costs. Tone mapping, bloom, SSAO and the other full-screen effects are
on [Post-Processing](post_processing.md).


## How a frame is rendered

A `FlameGame3D` camera and a `Scene3DComponent` layer (see [Embedding](embedding.md)) both render
their `World3D` the same way, once per frame, in this order:

1. The shadow passes, when a light casts shadows (see [Shadows](shadows.md)).
2. The depth-normal prepass, when something needs it (see
   [Post-Processing](post_processing.md#depth-normal-prepass)).
3. The `beforeScene` [custom passes](#custom-render-passes-and-rendergraph3d).
4. The world is traversed once and every visible object records its draws.
5. The [grab pass](#scene-color-grab-pass), when a material refracts the scene.
6. The main pass, or the [order-independent transparency](#order-independent-transparency)
   passes.
7. The `afterScene` custom passes and the post-processing composite, when enabled.

With none of the options on, a frame is one traversal and one render pass per camera or layer
(plus the shadow passes), drawn straight into the image Flutter shows. Each option adds passes,
listed in its section. `RenderStats.renderPasses` counts them (see
[Frame output and statistics](#frame-output-and-statistics)).

The shadow passes and the depth-normal prepass traverse the world again: their CPU cost (culling,
recording, particle sorting) is paid once more per pass.

A layer with retained caching skips all of this and reuses its image on frames where nothing
changed (see [Retained layer caching](embedding.md#retained-layer-caching) and
[Scene versions and dirty marking](basic_concepts.md#scene-versions-and-dirty-marking)).


## Draws are recorded, then sorted

While the world is traversed, every visible `Object3D` records its draws into the
`RenderContext3D` (a `MeshComponent` records one draw per surface of its mesh). Nothing reaches the
GPU until the end of the render pass, when the recorded draws are submitted:

- Opaque draws are grouped by pipeline, material and surface, then ordered front to back within a
  group. Consecutive draws of the same `Surface` with the same `Material` instance become a single
  instanced draw. Components that share a `Mesh` therefore cost one draw call per surface, however
  many of them there are.
- Translucent draws come after all the opaque ones, ordered back to front by the center of each
  surface's bounding box. Consecutive translucent draws of the same `Surface` with the same
  `Material` instance also become a single instanced draw, whose instances are drawn in that back
  to front order.
- Skinned draws are never batched, and neither are draws recorded with `drawInstances`.
- Objects whose transform mirrors them (an odd number of negative scales) batch only with other
  mirrored objects, since they are drawn with the opposite winding.

Because materials are applied when the draws are submitted, a material must not change its values
between the draws of one frame to make objects look different: use distinct materials, or the
per-instance color and data.

The only ordering guarantee between materials is that opaque draws come before translucent ones.
Among opaque draws, groups follow the order in which the device created their pipelines, then the
order in which their materials were created. Rely on it only when you must (a stencil mask, for
example, see [Stencil](#stencil)).

When a light casts shadows, the world is traversed first with the light's view as the camera
(`RenderContext3D.isShadowPass` is `true`) to render the shadow map from the objects and materials
that cast shadows, then for the main pass. In the shadow pass, draws of one surface become a single
instanced draw whatever their materials, drawn with depth-only shaders.

The recording buffers start with room for 64 draws and double when full; they are reused from
frame to frame, so recording allocates nothing once the scene has reached its size.


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
[Materials](materials.md#per-instance-data).

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
draw is never batched with others; a translucent one is ordered by the `center` it is given (the
world origin when it is given none). Pass `mirrored: true` when the instances' matrices mirror the
surface (an odd number of negative scales), so that it is drawn with the opposite winding; the
instances of one draw must agree. Its material's vertex shader must read the four `instanceModel`
columns, or `drawInstances` throws a `StateError`. See [Particles](particles.md).


### Many copies of a mesh: `InstancedGroup3D`

`InstancedGroup3D` keeps the instances of one `Mesh` in a single `Float32List` instead of one
component per copy: tiles, props, trees, fence posts. It records one `drawInstances` call per
surface of the mesh, flagged as mirrored when its world transform and instance transforms mirror;
when some instances mirror and others do not, it records two calls per surface from a copy that
holds each kind together.

```dart
final trees = InstancedGroup3D(mesh: treeMesh, initialCapacity: 256);
for (var i = 0; i < 200; i++) {
  trees.addInstance(
    transform: Matrix4.translationValues(i * 1.5, 0, 0),
    color: const Color(0xFF7FBF5F),
  );
}
world.add(trees);

// Later: move one tree, recolor another, remove a third.
trees.setInstance(3, transform: Matrix4.translationValues(4, 0, 2));
trees.setInstance(4, color: const Color(0xFFBF9F5F));
trees.removeAtSwapLast(5); // the last instance takes index 5
```

- `addInstance` returns the index of the new instance; `setInstance` changes its transform, color
  or data in place; `removeAtSwapLast` removes one in constant time by moving the last instance
  into its slot, so indices are not stable across removals; `clear` removes them all;
  `instanceTransform` reads one back. The capacity doubles when full.
- The instance transforms are relative to the group, which can itself be moved, rotated and scaled
  like any `Object3D`. When the group's world transform is not the identity, the instances are
  transformed on the CPU into a second buffer whenever the group or an instance changes.
- `World3D.raycast` hits the instances one by one; for a hit on a group, `RayHit3D.surfaceIndex`
  holds the index of the instance, not of the surface (see [Geometry](geometry.md)).

Cost: one draw call per surface per pass, and the whole instance buffer (96 bytes per instance) is
uploaded for each surface in every pass that draws it, the shadow passes and the depth-normal
prepass included. Changing an instance's transform recomputes the group's bounds over all its
instances.


### Levels of detail: `LodMeshComponent`

`LodMeshComponent` draws one of several meshes depending on how far it is from the camera and how
much of the screen it covers, and can cast its shadow from a cheaper mesh:

```dart
final rock = LodMeshComponent(
  levels: [
    MeshLodLevel(mesh: rockHigh, maxDistance: 12),
    MeshLodLevel(
      mesh: rockMedium,
      maxDistance: 30,
      minScreenHeightRatio: 0.05,
    ),
    MeshLodLevel(mesh: rockLow),
  ],
  shadowMesh: rockLow,
);
```

- Levels are ordered from the most detailed. In each main pass the first level whose
  `maxDistance` (default: infinite) is at least the distance from the camera to the center of the
  component's bounding box, and whose `minScreenHeightRatio` (default `0`) is at most the fraction
  of the viewport height the bounding box covers, is drawn; the last level is the fallback whatever
  its thresholds.
- In a shadow pass it draws `shadowMesh` when set, otherwise the last level when
  `lowestLodInShadowPass` is `true`, otherwise the level the main camera of the frame selects
  (from `RenderContext3D.viewerPosition` and `viewerViewProjection`).
- `lastSelectedLevel` tells which level the last main pass drew. Raycasts test that level.
- `color` and `instanceData` work as on `MeshComponent`; it has no joint matrices, so it does not
  draw skinned meshes.


## Render state

A material declares how it is drawn with its `renderState`, a `RenderState`:

- `blend`: `BlendState.opaque`, `alpha` (straight alpha), `premultipliedAlpha`, `additive` or
  `depthOnly` (no color written). Three more blend modes exist for the internal use of the
  [order-independent transparency](#order-independent-transparency) passes.
- `depthTest` and `depthCompare` (a `CompareFunction`, `less` by default), and `depthWrite`.
- `cullMode` (`CullMode.none` by default, `backFace` or `frontFace`).
- `stencil`, a [`StencilState`](#stencil), `null` (off) by default.
- `polygonMode`, `PolygonFillMode.fill` or [`wireframe`](#wireframe-and-primitive-topology).
- `translucent`: whether the draws go to the translucent, back-to-front part of the pass. By
  default every blend mode other than opaque is translucent.
- `depthPrepass`: see [Single-piece translucency](#single-piece-translucency).

Additive draws add their color and keep the alpha of the target: added light covers nothing, so in
a `Scene3DComponent` a glow over an empty part of the scene adds its color to the 2D components
drawn behind the layer.

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
back-face culling keeps culling the faces that point away from the camera. Draws recorded with
`drawInstances` flip it when recorded with `mirrored: true`, as `InstancedGroup3D` does.

`SpatialMaterial` and `StylizedMaterial` are opaque by default. `UnlitMaterial` may output
translucent colors, so by default it blends with premultiplied alpha and draws as translucent; set
its `renderState` to `RenderState.opaque` for opaque content so that it batches. The built-in
materials are described in [Materials](materials.md).


### Single-piece translucency

A translucent object drawn with a single translucent material shows its own hidden parts through
its near ones: an arm in front of a body lets the body show through it. A render state with
`depthPrepass: true` (`RenderState.singlePieceAlphaBlend` and
`RenderState.singlePiecePremultipliedAlphaBlend`) draws each such draw twice: first depth only,
then shaded with `CompareFunction.lessEqual`, so only the nearest surfaces blend.
`singlePieceTranslucent: true` on `StylizedMaterial` and `SpatialMaterial` selects it. The draws of
one `drawMesh` call (every surface of a mesh), and of the nodes of a `ModelComponent`, form one
group: all of them write depth before any of them blends. Custom objects group their own draws with
`RenderContext3D.beginDepthPrepassGroup()` and `endDepthPrepassGroup()`.

For fades without blending, `ditherFade: true` on `StylizedMaterial` and `SpatialMaterial` discards
fragments in a 4x4 ordered dither pattern instead (`flame_3d/dither.glsl`), which keeps the object
opaque and batched.


### Stencil

Every render pass has a stencil buffer, cleared to `0` when the pass begins and discarded when it
ends. A `StencilState` tests each fragment against it and updates it:

```dart
// Writes 1 wherever the portal frame is drawn.
final portalMask = UnlitMaterial()
  ..renderState = const RenderState(
    blend: BlendState.depthOnly,
    depthWrite: false,
    translucent: false,
    stencil: StencilState.writeReference(1),
  );

// Drawn only where the mask wrote 1.
final insidePortal = UnlitMaterial(albedoColor: const Color(0xFF2040C0))
  ..renderState = const RenderState(
    stencil: StencilState.testEqual(1),
    blend: BlendState.premultipliedAlpha,
  );
```

`StencilState` takes a `compare` function (`always` by default), the operations applied when the
stencil test fails (`stencilFail`), when the depth test fails (`depthFail`) and when both pass
(`pass`), all `StencilOp.keep` by default, a `readMask` and a `writeMask` (`0xFF`) and a
`referenceValue` (`0`). `StencilState.writeReference`, `testEqual` and `testNotEqual` cover the
usual cases.

A mask must be drawn before the draws that test it. The example makes the mask opaque
(`translucent: false`) and the masked material translucent, so the mask comes first whatever the
creation order of the materials (see
[Draws are recorded, then sorted](#draws-are-recorded-then-sorted)).
The stencil does not survive from one pass to the next: a mask drawn in the main pass does not
affect the shadow passes or the grab pass. The passes of
[order-independent transparency](#order-independent-transparency) draw the opaque draws again,
depth only but with their stencil state, so an opaque mask still masks the translucent draws.


### Wireframe and primitive topology

`RenderState(polygonMode: PolygonFillMode.wireframe)` rasterizes the edges of the triangles only;
`RenderDebugMode3D.wireframe` applies it to every draw of a world (see
[Post-Processing](post_processing.md#debug-views)). It works on Metal and Vulkan; the WebGPU
backend ignores it, and OpenGL ES has no line polygon mode.

A surface can hold other primitives than triangles: `Surface.topology` is a `PrimitiveTopology`,
`triangles` by default, or `triangleStrip`, `lines`, `lineStrip` or `points`.

```dart
final grid = Surface.fromBuffers(
  vertices: gridLinePositions, // 3 floats per vertex
  indices: gridLineIndices, // 2 indices per segment
  layout: VertexLayout(const [VertexAttribute('vertexPosition', 3)]),
  topology: PrimitiveTopology.lines,
  material: lineMaterial,
);
```

Lines are one pixel wide. The material's vertex shader must declare only the inputs the layout
provides, see [Surfaces and vertex layouts](#surfaces-and-vertex-layouts). `RenderStats.triangles`
counts no triangles for lines and points. For thick lines and trails use `StrokeBatch3D` or
`RibbonTrail3D` (see [Particles](particles.md)); `Line3D` draws a thin cylinder between two points,
as a mesh of its own (one draw call per line).


### Viewport and scissor

`GraphicsDevice.setViewport(x, y, width, height, zNear:, zFar:)` and
`setScissor(x, y, width, height)` restrict the following draws of the current pass to a rectangle
of the target, in pixels. They are not part of `RenderState`: the render context never sets them,
and they last until the end of the pass. They are meant for
[custom passes](#custom-render-passes-and-rendergraph3d) that draw with the device directly; split
screens are handled by `CameraStack3D` (see [Cameras](cameras.md)).


## Surfaces and vertex layouts

Besides a list of `Vertex` objects, a `Surface` can be built straight from an interleaved
`Float32List` and a list of 16- or 32-bit indices (surfaces with more than 65,535 vertices use
32-bit indices), with a `VertexLayout` of its own. Each attribute feeds the vertex shader input with
the same name, and a material's pipeline is created for the layout of each surface it draws:

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
inputs, which `flame_3d` feeds itself. `VertexLayout.standard` has a position, texture coordinates,
a color, a normal, joints and joint weights (20 floats); `VertexLayout.pbrStandard` adds a tangent
and a second set of texture coordinates (26 floats). A material can draw several layouts with a
vertex shader variant per layout, see `Material.vertexShaderFor`. Building surfaces, tangents,
morph targets and the procedural meshes is described in [Geometry](geometry.md).


## Shaders

Shaders are GLSL, compiled ahead of time into shader bundles (see
[Building shader bundles](#building-shader-bundles)). Custom shaders can include the chunks
`flame_3d` ships:

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
  `vertexWeights` inputs and the `JointMatrices` block (64 matrices), and `computeSkinMatrix()`.
- `flame_3d/lights.glsl` declares the light blocks: `AmbientLight`, `Lights` (up to 8 point
  lights), `DirectionalLights` (4), `SpotLights` (4) and `HemisphereLight`, see
  [Lighting](lighting.md).
- `flame_3d/shadows.glsl` declares the `Shadows` block and the `shadowMap` sampler, and
  `shadowVisibility()`, `shadowFactor()` and `castsShadows()` to receive shadows, see
  [Shadows](shadows.md#receiving-shadows).
- `flame_3d/fog.glsl` declares the `Fog` block (driven by `World3D.fog`) and
  `applyFog(color, worldPosition, view, projection, cameraPosition)` for distance and height fog.
- `flame_3d/dither.glsl` declares `bayerDither4x4(gl_FragCoord.xy)`, a threshold for dithered
  fades.

Blocks named `CameraMatrices`, `Camera` (`position`, and any of the `CameraMatrices` members),
`AmbientLight`, `Lights`, `DirectionalLights`, `SpotLights`, `HemisphereLight`, `Shadows`,
`ShadowAtlas`, `Fog`, `DepthNormal`, `SceneColor` and `PassOptions`, and the samplers `shadowMap`,
`depthNormalTexture`, `sceneColorTexture`, `brdfLutTexture` and `probeGridTexture`, are filled once
per render pass by the `RenderContext3D`, for every shader that declares them. The joint matrices
of skinned draws are filled for each draw, from the `jointTransforms` given to
`RenderContext3D.drawSurface` (or to `drawMesh`, by surface index, which
`MeshComponent.jointTransforms` feeds), whatever the surface: a parsed model's or one built with
`Surface.fromBuffers`. Register your own per-pass blocks with `RenderContext3D.registerPassUniform`,
and per-pass textures with `RenderContext3D.registerPassTexture`. Writing a material around custom
shaders is described in [Materials](materials.md#custom-shaders).

Flutter GPU binds every uniform block and texture of a pipeline again for each draw call, so each
resource a shader declares costs CPU time on every draw. `StylizedMaterial`'s fragment shader
therefore reads the camera, the lights, the shadows and the fog of the pass from one internal
block, which the writers registered for those eight blocks fill, rather than from the eight blocks:
a draw of it binds seven resources (the camera matrices, its wind, its material values, that block,
its two MatCap textures and the shadow map).


### Building shader bundles

The built-in materials ship compiled bundles. For your own shaders, put a `.vert` and a `.frag`
with the same base name in a `shaders/` directory of your package and run, from the package root:

```sh
dart run flame_3d:build_shaders
```

Each pair becomes `assets/shaders/<name>.shaderbundle`, compiled by the `impellerc` of your Flutter
SDK (or the one the `IMPELLERC` define points to); every existing `.shaderbundle` of that directory
is deleted first. `#include <package/file.glsl>` resolves against the `shaders/` directory of any
package in your dependency graph. Add `watch` to rebuild when a source changes. Declare the
directory as an asset: `GpuBackend.initialize()` loads every `.shaderbundle` the app declares.

`--with-web-gpu` also builds `.wgslbundle` files for the WebGPU backend, through the `naga` CLI
(`cargo install naga-cli`). Only 8 of the package's 28 shaders have a web bundle (`spatial_material`
in its non-PBR variant, `unlit_material`, `skybox_material`, `billboard_material`,
`decal_material`, `outline_material`, `outline_material_skinned` and `ribbon_material`): on the web,
anything that needs another shader (`StylizedMaterial`, particles, water, shadows, the depth-normal
prepass, order-independent transparency, bloom, HDR, post-processing, `keepContents` texture
passes) throws an `UnsupportedError` naming the shader when it first draws.


## Custom render passes and `RenderGraph3D`

`World3D.customPasses` holds `CustomRenderPass3D`s, functions run during the frame with a
`CustomRenderPassContext3D` (the device, the render context, the size of the scene in pixels, the
depth-normal texture when the prepass ran, and for `afterScene` passes the scene's texture target):

```dart
final world = World3D(
  customPasses: [
    CustomRenderPass3D(
      name: 'minimap',
      stage: CustomRenderPassStage3D.beforeScene,
      execute: (pass) {
        final target = pass.device.textureTarget(
          128,
          128,
          GpuPixelFormat.rgba8888,
          clearValue: const Color(0xFF101820),
        );
        pass.device.beginTexturePass(target);
        // ... bind a pipeline and draw with pass.device ...
        pass.device.endTexturePass();
      },
    ),
  ],
);
```

- `beforeScene` passes run after the shadow passes and the depth-normal prepass, before the scene's
  draws are recorded. They have no scene target: they render into textures of their own, which the
  scene's materials can sample (through `RenderContext3D.registerPassTexture`, for example).
- `afterScene` passes run after the main pass, before the post-processing composite, and get the
  scene's texture target in `sceneTarget`. They can sample it, or draw over it: begin the pass with
  `pass.device.beginTexturePass(pass.sceneTarget!, keepContents: true)` (a pass begun without
  `keepContents` clears the scene). Keeping the contents copies the scene out to a scratch target
  and back in, two full-size passes, as Flutter GPU cannot start a pass from what a texture holds.
  Any enabled `afterScene` pass makes the world render through a texture target and a composite
  pass, as post-processing does (see [Post-Processing](post_processing.md#the-composite-pass)).
- `enabled` switches a pass off without removing it.

A pass draws with the device directly: `beginTexturePass`, `bindPipeline`, `setRenderState`,
`bindSurface`, `drawSurface`, `endTexturePass`. Texture targets from `GraphicsDevice.textureTarget`
are shared by every pass of the frame that asks for the same size, format, clear color and `role`,
and are released 30 frames after their last use; give a target a `role` of its own (any object with
value equality, such as a value of your own enum), or create one with
`device.backend.createTextureTarget`, when it must not be shared.

`RenderGraph3D` is a separate tool for passes you schedule yourself: you declare transient textures
(`createTexture`) and imported ones (`importTextureTarget`), and passes that read and write them
(`addRenderPass`). `compile` orders the passes by their dependencies, throws a `StateError` on a
cycle, drops the passes whose output nothing uses (unless `hasSideEffects`), and lets transient
textures with the same descriptor and lifetimes that do not overlap share one target. `execute`
runs the live passes, each with a `RenderGraphPassContext3D` that resolves handles to targets
(`targetOf`, `textureOf`); a pass still begins and ends its own render pass:

```dart
final graph = RenderGraph3D();
final blurred = graph.createTexture(
  'blurred',
  const RenderGraphTextureDesc3D(width: 256, height: 256),
);
graph.addRenderPass(
  name: 'blur',
  writes: [blurred],
  hasSideEffects: true,
  execute: (pass) {
    pass.device.beginTexturePass(pass.targetOf(blurred));
    // ... draw ...
    pass.device.endTexturePass();
  },
);
graph.execute(device, renderContext); // inside an open device frame
graph.clear(); // before declaring the next frame's passes
```

`World3D` does not use `RenderGraph3D`: its own passes are fixed. `compile` allocates its plan on
every call, and the targets a graph creates are pooled by descriptor and never released (a graph
rebuilt at every new screen size keeps the targets of every size it saw).


## Order-independent transparency

`World3D(oitMode: OitMode3D.weightedBlended)` blends the alpha-blended translucent draws of a frame
(`BlendState.alpha` and `BlendState.premultipliedAlpha`) without sorting them, so intersecting
translucent surfaces blend the same whatever their order. It runs in frames that have translucent
draws, on backends with float texture targets (Metal, Vulkan); elsewhere (OpenGL ES) the
translucent draws are sorted as usual. A frame then renders:

1. the opaque draws into a full-size target of the scene's format, cleared to the clear color;
2. an accumulation pass into a full-size `rgbaFloat16` target: the opaque draws again, depth only,
   then every alpha-blended translucent draw, adding up its premultiplied color and its alpha;
3. a revealage pass into a full-size `rgba8888` target: the opaque draws depth only and the
   translucent draws once more, multiplying `1 - alpha`;
4. into the output (or into one more target, when post-processing follows): the composite of the
   three, then the other translucent draws (additive, depth-only), sorted back to front and depth
   tested against the opaque draws, drawn once more depth only.

Every translucent draw is drawn with its own material, in both passes: lighting, fog, skinning,
particles and every vertex layout look as they do when sorted. The composite lays the average color
of the translucent layers over the opaque image, with the coverage of all of them: a weighted
blended transparency whose weight is constant. One layer comes out exactly as when sorted;
where layers overlap, they mix by their alphas instead of the nearest one dominating, which suits
glass and overlays better than stacks of nearly opaque surfaces. As the order does not matter, the
translucent draws are batched as opaque draws are.

The opaque geometry is drawn three times (four with additive draws), the translucent geometry
twice. [Single-piece translucency](#single-piece-translucency) does not apply: an object's hidden
surfaces blend too.


## Scene-color grab pass

A refractive material needs the color of the scene behind it. With
`World3D.grabSceneColorEnabled` set, or whenever a `SpatialMaterial` with `transmission` above zero
is drawn, the opaque draws are first drawn into a full-size texture target of the scene's format;
the main pass then binds that texture as `sceneColorTexture` (and sets `SceneColor.params.x` to
`1`) for every shader that declares it. `SpatialMaterial.transmission` and `WaterMaterial` (only
with `grabSceneColorEnabled`) offset their lookup by the surface normal to refract what is behind
them (see [Materials](materials.md)).

The grab pass is not a copy: every opaque draw is drawn a second time, with its full shading.
Translucent draws are not in the grabbed image, so glass behind glass does not show.


## HDR render targets

`World3D.hdrEnabled` (also on `Scene3DComponent`) renders the scene into a 64-bit
`GpuPixelFormat.rgbaFloat16` texture target where the backend can render into float textures (Metal
and Vulkan; not OpenGL ES, where it falls back to `rgba8888` and colors above `1` clip), and adds
the composite pass that decodes the image to linear light, tone-maps it and encodes it to sRGB.

Materials write that target sRGB-encoded with an extended range. `RenderContext3D.hdrEnabled` is
`true` during the passes into it (the main pass, and the grab and transparency passes composited
into it), and shaders read it as `PassOptions.flags.x`: the native `SpatialMaterial` shader then
encodes its lighting without its tone curve, so values above `1` survive. The other built-in
materials write their usual display colors either way, so they look the same with and without HDR
until the tone map changes them. A custom material that computes linear light should do as
`SpatialMaterial` does; see [Post-Processing](post_processing.md#hdr) for the details and costs.


## Frame output and statistics

Each camera renders the world into an image of its viewport size in physical pixels, rounded to
whole pixels. `World3D.renderScale` renders it at a fraction of that size (or above `1` to
render more pixels than the viewport covers); the image is scaled to the viewport when drawn.

The render targets of a `GraphicsDevice` are pooled by size and sample count: a size that is not
used in a frame stays pooled for `GraphicsDevice.targetRetainFrames` (30) frames. A render target
owns up to three color textures, created once, which its passes take turns rendering into; the image
of a pass is drawn by Flutter straight from its texture. A texture is rendered into again only once
Flutter can no longer draw its previous image: Flutter rasterizes at most the frame it is building
and the one before, so two frames later the image has been drawn, and the draws that read it were
submitted to the GPU before the new pass is. A scene rendered every frame therefore uses two
textures; when Flutter draws no frames (passes rendered outside of frames), the texture rendered the
longest ago of the three is reused. The depth buffer of a pass is transient: it is cleared when the
pass begins and never written back to memory.

Passes whose image later passes sample (shadow maps, the depth-normal prepass, the scene target of
post-processing) render into texture targets (`GraphicsDevice.textureTarget`), created once for
each size, format, clear color and role and kept while they are used. Each pass of a frame that
samples another one has a role of its own, so no pass samples the texture it renders into.

MSAA (`Game3D.msaa()`, `Scene3DComponent.msaa`) applies to the main pass, whether it renders
straight into the output image or into the scene's texture target (post-processing, HDR, an
`afterScene` custom pass): a multisampled texture target renders into a transient multisampled
texture resolved into its sampled texture at the end of each pass
(`GraphicsDevice.textureTarget(msaaSampleCount: ...)`). With order-independent transparency the
opaque target is multisampled, the accumulation and revealage passes are not. The grab pass, the
depth-normal prepass, shadow maps and the bloom passes have one sample. Where the device has no
offscreen MSAA (some OpenGL ES devices), `Msaa.sample4` falls back to one sample, and WebGPU texture
targets always have one.

`World3D.renderToImage(size, view: ..., projection: ...)` renders a standalone snapshot, even when
the world is not mounted in a game. Lights register with their world only when they mount,
however, so an unmounted world renders lit materials without any light. It creates a new render
target on each call: use it for occasional snapshots, and `RenderTexture3D` for a view rendered
every frame (see [Materials](materials.md)).

`FlameGame3D.renderStats` holds the statistics of the last rendered frame, and
`Scene3DComponent.renderStats` those of the layer's last render: render passes, draw calls,
instances, triangles, pipeline changes, render state changes, material changes, uniform uploads,
uploaded bytes, the particles drawn by particle systems, and how many of the passes and draw calls
rendered shadow maps (`shadowPasses` and `shadowDrawCalls`). `GraphicsDevice.cachedPipelineCount`
counts the pipelines created so far, and `estimatedTargetVramBytes` estimates the memory of the
pooled render and texture targets.

A pipeline is created the first time a material draws a layout, which can make that frame late.
`GraphicsDevice.warmupMaterial(material, layout: ...)` creates it ahead of time, for one layout
(`VertexLayout.standard` by default); call it once per layout the material draws. It does not warm
the shadow, depth-normal or transparency pipelines.


### Profiling

Built with `--dart-define=FLAME_3D_PROFILE=true`, the renderer times its phases on the CPU into
`RenderProfile.active`: the host's setup, fitting the shadow map, walking the components, culling,
recording draws, particles, sorting, batching, render state, `Material.apply`, the uniform blocks of
the pass, uploads, bindings, gathering instances, draw calls, beginning and ending passes, and
drawing the image into the canvas, the shadow passes apart. Without the define, the timing is
compiled out.

```dart
final profile = RenderProfile.active = RenderProfile();
// ... render some frames ...
for (final phase in RenderPhase.values) {
  print('${phase.name}: ${profile.microseconds(phase)} us, '
      'shadow pass ${profile.microseconds(phase, shadow: true)} us');
}
```

Timing every draw costs a little, so compare its totals with a build without the define. The
package's `benchmark/` renders a board-like `Scene3DComponent` scene (about 200 instanced objects,
skinned characters, translucent and additive parts, shadows, particles, 4x MSAA) and reports these
phases, the objects allocated per frame and the `RenderStats`, under `flutter test` or in a profile
build: see its README. It does not enable HDR, bloom, post-processing, the depth-normal prepass or
order-independent transparency, so measure those in your own scene.


## Platform support

- Metal (iOS, macOS) and Vulkan (Android): everything on this page.
- OpenGL ES (Android devices without Vulkan): no float texture targets, so HDR falls back to
  8 bits per channel (colors above `1` clip) and order-independent transparency to sorted
  translucency; no wireframe; some devices have no offscreen MSAA.
- Web (WebGPU): the main pass, render states and stencil; MSAA renders with 4 samples. Wireframe
  is ignored, `SpatialMaterial` draws with its non-PBR shader (no transmission, so the grab pass
  has no use there), and the features that need a shader without a web bundle throw (see
  [Building shader bundles](#building-shader-bundles)). Texture targets have one sample. The
  backend also creates a bind group for every draw call, which costs CPU time per draw that the
  native backends do not have.


## Limitations

- `InstancedGroup3D` culls and sorts as one object: the group is drawn whenever its bounding box
  (the union of all instances) is in view, and its translucent instances are neither sorted among
  themselves nor against other draws by their own position. Split large groups into several
  spatially compact groups.
- `LodMeshComponent` switches levels at the thresholds without hysteresis, so an object that stays
  near a threshold can change level every frame.
- `Line3D.generate` draws a line that points straight down (`end` directly below `start`) upwards
  from `start`.
- The stencil buffer is per pass and not stored: it cannot carry a mask from one pass to another.


## Related pages

- BVH raycasting and `SceneSpatialIndex3D`: [Geometry and Scene Queries](geometry.md).
- Models, skinning, morph targets and animation: [Models and Animation](models_and_animation.md).
- 3D input, effects, physics, navigation, audio and debug gizmos:
  [Input and Effects](input_and_effects.md), [Collisions and Physics](physics.md),
  [Navigation](navigation.md), [Spatial Audio](audio.md) and
  [Debugging, Profiling and Testing](debugging_and_testing.md).
- Large worlds (static batching, occlusion culling, floating origin, terrain, foliage, volume
  decals, streaming): [Large Worlds](world_scale.md).
- Prefabs, scene serialization and the GPU resource manager:
  [Scenes and Assets](scenes_and_assets.md).
