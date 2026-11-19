# Shadows

`flame_3d` renders real-time shadows with shadow maps. Before the main pass of a scene, the objects
that cast shadows are rendered from the light into a texture that holds the depth they have as the
light sees them; the materials that receive shadows then compare the depth of their fragments with
it.

Three kinds of light cast shadows when they are given `ShadowSettings`:

- the first `DirectionalLight` (a sun) with settings, with one shadow map or two to four cascades;
- up to two `SpotLight`s, each with a perspective map;
- the first `PointLight` with settings, with a dual-paraboloid map.

How a frame renders them depends on which of these lights cast shadows in the pass:

| Lights with `ShadowSettings`         | Path       |
| ------------------------------------ | ---------- |
| One sun, `cascades: 1`               | Single map |
| One spot light and nothing else      | Single map |
| One sun, `cascades: 2` to `4`        | Atlas      |
| A point light                        | Atlas      |
| Two or more of these lights          | Atlas      |

Every receiver reads both paths: `StylizedMaterial`, `SpatialMaterial`, `ShadowCatcherMaterial`,
`WaterMaterial` (the sun and point lights; it has no spot lights) and custom shaders that include
`flame_3d/shadows.glsl`.


## Casting shadows

Give a `DirectionalLight` its `ShadowSettings`:

```dart
world.addAll([
  LightComponent.hemisphere(
    skyColor: const Color(0xFF9CC2F0),
    groundColor: const Color(0xFF7A6A50),
  ),
  LightComponent.directional(
    direction: Vector3(-0.4, -1, -0.3),
    shadows: ShadowSettings(
      strength: 0.85,
      color: const Color(0xFF2E3A66), // cool shadows rather than black ones
    ),
  ),
  ...buildings,
]);
```

Only the first directional light of a pass with settings casts shadows (among the first four
directional lights whose `lightMask` the pass renders). The settings are read every frame and may be
changed at any time.

Every `Object3D` casts shadows unless its `castsShadows` is `false`, and every material does unless
its `castsShadows` says otherwise: opaque materials cast by default, translucent ones (glass,
additive glows) do not.

```dart
// An opaque glow that should not cast.
final glow = StylizedMaterial(emissiveStrength: 1)..castsShadows = false;

// A marker that receives shadows but casts none.
final marker = MeshComponent(mesh: markerMesh, castsShadows: false);
```

A caster's shadow is rendered from the positions of its vertices alone, skinned when its vertices
have joints and joint weights (`vertexJoints`, `vertexWeights`) and its draw has joint matrices.
Vertices that a material's own vertex shader moves, such as the wind sway of `StylizedMaterial`,
cast the shadow of their rest position. Draws of one surface are drawn as one instanced draw in the
shadow pass, whatever their materials. The shadow pass draws every surface with its own depth-only
shaders, which read the four per-instance model columns as a model matrix: a draw whose instances
mean something else must skip the shadow pass, as billboard particles and ribbons do (see
[Particles and Ribbons](particles.md#shadows)).


## Receiving shadows

`StylizedMaterial` and `SpatialMaterial` (on native backends) receive shadows: where a surface is in
shadow, the direct light of the light that casts them is multiplied by `mix(white, color,
strength)`, and its highlights by the mean of that. Ambient and hemisphere light, the other lights
and the other directional lights stay, so with the default black `color` a surface in the sun's
shadow is lit by the ambient light alone, and with a colored one the shadows are tinted with it: a
cartoon look tints shadows rather than blackening them.

`ShadowCatcherMaterial` is for invisible surfaces that show only the shadows falling on them, see
[Shadows on 2D art](#shadows-on-2d-art). `WaterMaterial` receives the sun's shadow (see
[Materials and Textures](materials.md)). `UnlitMaterial` does not receive shadows.

Custom shaders receive shadows by including `flame_3d/shadows.glsl` and listing its `Shadows`
block and `shadowMap` sampler (`RenderContext3D.shadowsBlock` and
`RenderContext3D.shadowMapSampler`) in their material's slots; the render context fills them once
per pass, for the single map and the atlas alike:

```glsl
#include <flame_3d/shadows.glsl>

// ...
float visibility = shadowVisibility(fragPosition, normal); // 0 in shadow, 1 lit
for (int i = 0; i < int(directionalLights.numLights); i++) {
  vec3 shadow = castsShadows(i) ? shadowFactor(visibility) : vec3(1.0);
  // ... multiply the light of sun i by shadow
}
for (int i = 0; i < int(spotLights.numLights); i++) {
  vec3 shadow = spotShadowFactor(i, fragPosition, normal);
  // ... multiply the light of spot light i by shadow
}
for (int i = 0; i < int(lights.numLights); i++) {
  vec3 shadow = pointShadowFactor(i, fragPosition, normal);
  // ... multiply the light of point light i by shadow
}
```

Without shadows, `shadowVisibility` returns `1`, and `spotShadowFactor` and `pointShadowFactor`
return white for lights that cast none. `shadowCascadeVisibility` also gives the cascade it used,
`spotCastsShadows(i)` and `pointCastsShadows(i)` tell whether a light casts shadows in the pass, and
`shadowOcclusion` gives the largest `strength × (1 - visibility)` of all the lights that cast
shadows (what `ShadowCatcherMaterial` shows). `shadowAtlasActive()` tells the atlas apart, as
`RenderContext3D.hasShadowAtlas` does in a material's `apply`.

A shader that holds the values of the `Shadows` block in a block of its own, to bind fewer blocks
per draw (see [Rendering](rendering.md#shaders)), defines `FLAME_SHADOWS(member)` to the expression
that reads the member of `Shadows` named `member` before including the chunk, which then declares
no `Shadows` block; `StylizedMaterial` and `WaterMaterial` do so, with every member of the block,
the atlas ones included. A shader that defines `FLAME_SHADOWS_SINGLE_MAP` first gets a block
without the atlas members and receives no shadows on frames that use the atlas (the WebGPU build of
`SpatialMaterial`, which has no atlas, does so). The `ShadowAtlas` block
(`RenderContext3D.shadowAtlasBlock`) is still filled for shaders that declare it, but no built-in
shader does any more.


## The shadow map

The shadow map is a square texture of `resolution` by `resolution` texels (1024 by default, which
suits phones, from 16 to 8192), created once and reused from frame to frame. The light renders it
through an orthographic projection, `DirectionalShadowProjection`, fitted to the region that
receives shadows:

- With `ShadowFit.view` (the default), the part of the bounds of the scene (`World3D.sceneBounds`,
  or the settings' `bounds`) that the camera sees: the shadows are as sharp as the map allows, and
  the map follows the camera. `maxDistance` limits how far from the camera shadows reach, which
  sharpens them for a perspective camera that sees far.
- With `ShadowFit.scene`, the whole region, whatever the camera sees: the map only changes when the
  region does.

Either way, the map reaches from the receivers back towards the light over the whole scene, so that
every object between the light and the visible receivers casts its shadow, even when it is not on
screen itself.

The light's view looks along its direction from the world origin, and does not move with the
camera. With `stabilize` (the default), the width and height of the map only take sizes on a ladder
(steps of `2^(1/8)`, about 9 %, kept while they still fit) and its edges are snapped to whole texels
of the light's view: as the camera pans, a point of the world keeps landing on the same spot of a
texel, and the edges of the shadows stay still instead of shimmering.


### How depths are stored

Flutter GPU cannot sample the depth attachment of a render pass on every backend (on Vulkan,
Impeller's views of depth-stencil textures cover both aspects, which a sampler may not read), so the
shadow pass writes the depth into a color texture instead, through its own shaders:

- `ShadowMapEncoding.float32`: one 32-bit float per texel (`r32Float`), where the GPU can render
  into 32-bit float textures. Flutter GPU has no query for that: `flame_3d` uses it on Metal and
  Vulkan, which render into them, and not on OpenGL ES, which needs an extension.
- `ShadowMapEncoding.rgba8`: 24 bits of depth packed into the red, green and blue channels of an
  8-bit texel, which every GPU renders into.

`ShadowMapEncoding.auto` (the default) picks the first where it can. Both take 4 bytes per texel and
give the same shadows, on both paths: the single map and the atlas. The texture is
sampled with nearest filtering, and the receivers filter the comparisons themselves.


### Soft edges and biases

A receiver compares its depth with the map over a box of `2 * softness + 1` texels, blended
bilinearly: `(2 * softness + 2)²` samples, 16 with the default `softness` of `1`, 4 with `0`, 64
with the largest, `3`.

Two biases keep surfaces from shadowing themselves (shadow acne) without detaching shadows from
their casters (peter-panning). Both are in texels of the map, so they follow its resolution and the
size of the region it covers:

- `depthBias` (`1` by default) pushes the receiving point towards the light.
- The point is also pushed along its normal, in proportion to the sine of the angle between the
  normal and the light: by what the filter needs (`sqrt(2) * (softness + 1)` texels), plus
  `normalBias` (`0.5` by default). This keeps surfaces lit at grazing angles free of acne.

With the defaults, a 1024 texel map over a board of ten units moves shadows by at most a few
hundredths of a unit.


## Shadows on 2D art

In a `Scene3DComponent`, the 3D layer is drawn over the 2D components below it. A ground of
`ShadowCatcherMaterial` under the 3D objects draws the shadows falling on it, with soft edges, as
`color` blended over the 2D art (its alpha the opacity at full strength), and is fully transparent
elsewhere: 3D objects cast shadows onto pre-rendered 2D ground.

```dart
final layer = Scene3DComponent(projection: boardProjection, priority: 1);
world.addAll([GroundArt(), layer]); // the 2D ground is drawn below the layer

layer.world.addAll([
  LightComponent.directional(
    direction: Vector3(-0.3, -0.5, -1), // z is up in this scene
    shadows: ShadowSettings(),
  ),
  MeshComponent(
    mesh: PlaneMesh(
      size: Vector2(12, 12),
      material: ShadowCatcherMaterial(color: const Color(0x8C1B2440)),
    ),
    position: Vector3(6, 6, 0),
    // The PlaneMesh faces +y: turned to face +z.
    rotation: Quaternion.axisAngle(Vector3(1, 0, 0), pi / 2),
  ),
  ...houses,
]);
```

The catcher needs a position and a normal on its vertices, as the standard layout and the layout of
`StylizedMaterial` have. It is translucent, writes no depth and casts no shadows; the 3D objects
drawn in front of it hide it as they hide the ground. It shows the shadows of every light that casts
them, on both paths: where several fall on it, the darkest (`color` alpha times the largest
`strength × (1 - visibility)`), without the reach or the cone of the spot and point lights. The
`shadows` scenario of the example shows 3D buildings casting tinted shadows onto a 2D board under a
sun that circles around it. `ShadowCatcherMaterial` is not available on the web: creating one there
throws an `UnsupportedError`.

Where catchers overlap on screen (a ground, walls, slabs at different heights), each darkens the art
behind it, so a pixel in the shadow on two of them is darkened twice. With `nearestOnly`, only the
nearest catcher surface darkens a pixel, among the catchers that set it:

```dart
final ground = ShadowCatcherMaterial(nearestOnly: true);
final slabs = ShadowCatcherMaterial(nearestOnly: true);
```

Their draws share one depth prepass (`Material.depthPrepassGroup`, with
`RenderState.singlePiecePremultipliedAlphaBlend`): all of them write their depth first, then each is
shaded where it is the nearest. A slab over the ground darkens the art once where both are in
shadow, and hides the ground's shadow under it where it is lit itself, as a real slab would. It
costs one depth-only draw more per catcher, and the depth the catchers write hides the translucent
draws after them in the pass that are behind them.


## One shadow map for several layers

Each `Scene3DComponent` is a scene of its own, rendered in its own pass at its own priority among
the 2D components: buildings below some 2D labels and characters above them, for instance. Its
objects only shadow each other. To let the objects of several layers shadow one another, as if they
were one scene, put their worlds in one `ShadowGroup`:

```dart
final shadows = ShadowGroup();
buildings.world.shadowGroup = shadows;
characters.world.shadowGroup = shadows;
```

The group has one shadow map, rendered once per frame by the first of its worlds that renders, with
the objects of every world of the group: a character's shadow falls on a building of the other
layer, and a building's on the character. The worlds that render after it in the frame reuse the
map (`RenderContext3D.reuseShadowMap`), so the group costs one shadow pass, not one per layer; a
world renders the group's map again only when another shadow map was rendered in between.

The light, the `ShadowSettings` and, with `ShadowFit.view`, the camera the map is fitted to are
those of the world that renders first:

- give the worlds of a group the same lights, in the same order: a shader tells the light that
  casts the shadows by its index among the directional lights;
- render first the layer that covers the most of the screen (the one whose shadow catchers cover
  the ground), or fit the map to `ShadowSettings.bounds` that cover what every layer shows, with
  `ShadowFit.scene`: receivers outside the map are lit.

A ground of `ShadowCatcherMaterial` belongs in the lowest layer of the group, below the objects of
every layer.

A group shares whichever map its first world's lights need: the single map, or the atlas (cascades,
spot lights, a point light), each tile of which gets the casters of every world.


## Static shadows

When the casters and the light do not move, the shadow map does not need to be rendered again every
frame. With `cacheWhenStatic`, a world keeps its map and skips both the traversal of its components
for the shadow pass and the shadow pass itself (`RenderStats.shadowPasses` is `0`) while nothing
changed:

```dart
LightComponent.directional(
  direction: Vector3(-0.3, -0.5, -1),
  shadows: ShadowSettings(cacheWhenStatic: true, fit: ShadowFit.scene),
);
```

The cache is used on both paths. On the atlas, every light that casts shadows in the pass must set
`cacheWhenStatic`; otherwise the atlas renders every frame.

The map is reused when all of these match the frame that rendered it:

- the key of the world's casters: the world (or the group), its `World3D.castersVersion` (for a
  group, a hash of the versions of its worlds), and, for the first directional light with settings,
  its index among the lights, its direction, and the `resolution`, `fit`, `maxDistance`,
  `stabilize` and `cascades` of its settings;
- the resolution and the encoding of the map (for the atlas, its size);
- the fitted light view-projection, compared element by element: the bounds of the scene, the
  settings' `bounds`, the position and direction of a spot light, and, with `ShadowFit.view`, the
  camera are all part of it. On the atlas, every tile is compared: its light, its rectangle, and its
  view-projection (the position and range of a point light).

`strength`, `color`, `softness` and the biases are not part of the key: they are applied by the
receivers, and changing them shows on the next frame without rendering the map again.

`castersVersion` increases when a component of the world is added, removed, shown or hidden; when
it moves, if it is an `Object3D` that casts shadows, a component with 3D children, or a light whose
source has `ShadowSettings` (a move of anything else, such as a `Collider3D` or an object with
`castsShadows: false`, leaves the cached map alone); when `Object3D.castsShadows` or
`Material.castsShadows` is set; when the `jointTransforms` of a caster (`MeshComponent`,
`ModelComponent`, `LodMeshComponent`) are assigned; when a field of a light source that can move
its shadows is set (a direction, a range or cone, the `shadows` settings; not a color or an
intensity); when a `ModelComponent` that casts shadows poses its nodes, an `InstancedGroup3D` or a
`SkinnedCrowdBatch3D` that casts shadows changes, or a particle system with mesh particles has live
particles; and when `World3D.markShadowsDirty()` (or `markSceneDirty()`) is called. A color, the
`instanceData` of a mesh or the color or intensity of a light change `World3D.sceneVersion` only.

The engine cannot see changes made in place; the cached map then shows the old shadows until the
next change it sees. Report them:

- joint matrices written into the list already given to `jointTransforms` (GPU skinning driven by
  your own code; `ModelComponent` animations are counted): call `component.markDrawDirty()`;
- a field of a light's `ShadowSettings`, or a vector of a light source, changed in place: call
  `source.markChanged()` (`LightSource.markChanged`, `shadows: false` when the change cannot reach
  the map);
- what a custom `Object3D` draws (another mesh, another level of detail) changed without moving it,
  writes into the vertex buffers of a surface or into an instance buffer given to
  `RenderContext3D.drawInstances`, or draws from a component that is not an `Object3D`: call
  `component.markDrawDirty()` or `world.markShadowsDirty()`.

A renderer that calls `RenderContext3D.beginShadowPass` itself passes its own `castersKey`, an
object that compares equal while its casters did not change; without one (`null`, the default) the
map is never cached.

The cached map is kept per render context and per `DirectionalShadowProjection`: one for each world
(`World3D.shadowProjection`) and one for each `ShadowGroup` (`ShadowGroup.projection`), each
`resolution² × 4` bytes (4 MiB at the default 1024; for the atlas, the size of the atlas) besides
the maps of the frame. It is created outside the device's pool of render targets, and released the
next time the world renders without the cache, or switches between the single map and the atlas.

With `ShadowFit.view`, every move of the camera refits the map and renders it again: the cache only
helps a still camera. With `ShadowFit.scene`, the map depends on the bounds of the scene alone, and
the cache holds while the camera pans.


## Cascades

A single map spreads its texels over everything it covers. Seen by a perspective camera, the ground
near the camera gets few texels per pixel, and its shadows look blocky, while far away the map is
finer than needed. Cascades split the region into maps of decreasing sharpness: `cascades` takes 1
(the default) to 4. Two to four cascades are tiles of the [shadow atlas](#the-shadow-atlas), each
of the same size, and every receiver reads them.

```dart
LightComponent.directional(
  direction: Vector3(-0.4, -1, -0.3),
  shadows: ShadowSettings(cascades: 3, maxDistance: 40),
);
```

- The last cascade is fitted exactly like a single map: `fit`, `bounds` and `maxDistance` apply.
- With a perspective camera and `ShadowFit.view`, cascade `c` covers the view from the camera up
  to `splits[c]` of the farthest distance that receives shadows: `maxDistance`, or without one the
  farthest corner of the region (`bounds`, or the bounds of the scene) along the camera's
  direction. Each cascade starts at the camera, so the nearer ones are inside the farther ones.
- With an orthographic camera or `ShadowFit.scene`, cascade `c` covers the middle of the region
  scaled by `splits[c]` about its center.
- A cascade that sees nothing, or is not sharper than the next one, is dropped (no tile, no
  traversal): a near cascade of a perspective camera that looks down on a scene from far away, for
  instance, or one of an orthographic camera that sees a small part of a large region.

The splits are `cascadeSplits` (one increasing value in `(0, 1]` per cascade, or per cascade but the
last, which always covers it all; another length, or values that do not increase, throw an
`ArgumentError`, and a `StateError` in the shadow pass when the list was changed afterwards),
otherwise derived from `cascadeSplitRatio`:

- 2 cascades: `r` and `1`, with `r` the ratio clamped to `0.06` to `0.5`: `0.28` by default;
- 3 cascades: `r`, `r + 0.45 * (1 - r)` and `1`: `0.28`, `0.604` and `1` by default;
- 4 cascades: `0.154`, `0.354`, `0.677` and `1` by default (the first is `0.55 * r`, clamped to
  `0.06` to `0.25`).

A receiver uses the first cascade that holds it (keeping a margin of 2 % of its width, except for
the last one), and within `cascadeBlendRange` (a fraction of the cascade's width, `0.1` by default,
clamped to `0.35`) of the cascade's edge it cross-fades to the next one, which samples the map twice
as many times there. `RenderDebugMode3D.cascadeSplits` tints `SpatialMaterial` surfaces by the
cascade they use.


## The shadow atlas

The frame renders the atlas instead of a single map when a sun has two to four cascades, when a
point light casts shadows, or when more than one light casts shadows (a sun and a spot light, two
spot lights). All its maps are square tiles of one texture, rendered in one render pass: each tile
sets the viewport and the scissor to its rectangle, and the components are traversed once more for
each tile.

- All tiles have the same size: the `resolution` of the sun's settings (or of the first spot
  light's, or of the point light's), made smaller only where the tiles would not fit in 4096 by
  4096 texels (`ShadowAtlas3D.atlasSize`).
- The tiles are, in order: the sun's cascades, the spot lights (two at most), and the point light's
  two hemispheres; eight at most. They sit in a grid as square as it can be, and the texture is the
  size of that grid: one cascade and a spot light at 1024 take 2048 by 1024 texels (8 MiB), three
  or four tiles 2048 by 2048 (16 MiB), five to eight 3072 by 3072 at most.
- The encoding is that of the sun's settings (or of the first light's), and so are the `softness`,
  `color` and `strength` of the sun's cascades. Each spot light and the point light use their own
  `color`, `strength`, `depthBias` and `softness`.

`RenderContext3D.hasShadowAtlas` tells whether the current pass receives the atlas, and
`RenderContext3D.shadowAtlas` holds the tiles of the last one (`ShadowAtlas3D.tiles`, with their
rectangles in `uvRect`).


## Spot-light shadows

A `SpotLight` casts shadows when it has `ShadowSettings` and an `intensity` above zero:

```dart
world.add(
  LightComponent.spot(
    position: Vector3(0, 4, 0),
    direction: Vector3(0.3, -1, 0),
    intensity: 6,
    range: 12,
    outerConeAngle: 0.6,
    shadows: ShadowSettings(resolution: 1024),
  ),
);
```

The light renders through a perspective projection that covers its cone: a field of view of twice
`outerConeAngle` (clamped to 10° to 165°), from 0.12 units to `range` (32 units when `range` is
`null`). Casters closer than 0.12 units to the light, or beyond its range, cast nothing. `fit`,
`bounds`, `maxDistance`, `stabilize` and `cascades` do not apply.

A spot light that is the only light casting shadows uses the single map at its `resolution`, with
its `depthBias`, `normalBias` and `softness`, and is cached with `cacheWhenStatic`. The biases are
in texels of the map at about a third of the range, so they are coarse near the light. Two spot
lights, or a spot light and a sun or a point light, use the atlas; there, each spot light's tile is
filtered with its `softness` and pushed along the normal by 1.2 texels, whatever its `normalBias`.
Every receiver but `WaterMaterial` (which has no spot lights) receives them on both paths. The map
stores the depth of every pixel of the casters, so large triangles do not shadow themselves.

Only the first two spot lights with settings among the four spot lights the pass lights with cast
shadows: the first four lit ones, or with more than four the four picked by their distance to the
camera (see [Selection beyond the limits](lighting.md#selection-beyond-the-limits)). A spot light
the pass leaves out casts no shadow, and the shadows follow the lights they belong to whatever
order the pass holds them in.


## Point-light shadows

A `PointLight` with `ShadowSettings` casts shadows in every direction:

```dart
world.add(
  LightComponent.point(
    position: Vector3(0, 2, 0),
    color: const Color(0xFFFFD8A0),
    intensity: 20,
    range: 10,
    shadows: ShadowSettings(),
  ),
);
```

The light renders two tiles of the atlas, one for each half of the space around it along the world
z axis (a dual-paraboloid map): each vertex of a caster is projected onto a paraboloid, and the
depth is the distance to the light divided by `range` (24 units when `range` is `null`). Only the
first point light with settings, among the point lights the pass lights with (the lit ones among
the first eight, or the eight picked with `prioritizeNearestLights`), casts shadows, and every
receiver receives them. The receivers push their point by 0.03 units along the normal, use a
depth bias of `depthBias * 0.004` of the range, and filter over a radius of `softness` clamped to 2.

The projection is applied to the vertices only, and the triangles between them are rasterized as
straight: large triangles close to the light cast a distorted shadow, so tessellate casters that
come near point lights.

The casters of each tile are culled with a box around the half of the light's reach the tile covers
(`range` on every side of the light, along its half of the z axis): casters out of the camera's
view still cast into it.


## Rendering the shadow pass yourself

`World3D`, `Scene3DComponent` and `RenderTexture3D` render the shadows of their scene themselves. A
renderer that drives a `RenderContext3D` directly records its casters once per map, in this order,
before it sets up its main pass:

```dart
void renderShadows(
  RenderContext3D context,
  DirectionalShadowProjection projection,
  Aabb3 sceneBounds,
  void Function(RenderContext3D context) recordCasters,
) {
  if (context.beginShadowPass(
    projection: projection,
    sceneBounds: sceneBounds,
  )) {
    recordCasters(context);
    // One more recording for each further tile of the atlas.
    while (context.advanceShadowAtlasTile()) {
      recordCasters(context);
    }
    context.endShadowPass();
  }
}
```

`RenderContext3D.isShadowPass` is `true` while casters are recorded; `view`, `projection`,
`frustum` and `cameraPosition` are then the light's (for a point light's tile, a box around the half
of its reach the tile covers), and `viewerPosition` stays the main camera's. Leaving out the tile
loop leaves the other tiles of the atlas empty (lit). `needsShadowCascade1`, `beginShadowCascade1` and
`endShadowCascade1` are deprecated and do nothing: two cascades are atlas tiles.


## Costs

| Path               | Render passes | Traversals of the scene | Shadow textures                   |
| ------------------ | ------------- | ----------------------- | --------------------------------- |
| Single map         | 1             | 1                       | `resolution² × 4` B (4 MiB)       |
| Cached map/atlas   | 0             | 0                       | the cached map, kept              |
| Atlas              | 1             | 1 per tile, up to 8     | its grid of tiles × 4 B (8-36 MiB)|

The sizes in parentheses are for the default `resolution` of 1024. Each map also has a depth
attachment, transient: it lives in tile memory where the GPU has it. The texture of a frame comes
from the device's pool of render targets and is shared by the worlds rendered one after the other
with the same size.

- A traversal records the draws of every component a second time (and `ModelComponent`s pose their
  nodes again); the shadow pass draws one draw call per caster surface, objects sharing a surface
  in one instanced draw, with depth-only shaders. Draws whose material casts no shadows are not
  recorded, and particle systems that cast none skip the shadow pass altogether.
- The receivers sample a map `(2 * softness + 2)²` times per fragment, where the shadow can show:
  not outside of the map, and, for `StylizedMaterial`, not where the surface faces away from the
  sun and has no highlights. On the atlas, the receivers sample the sun's cascades in the same way
  (twice within the blend band), each shadowed spot light and the point light with their own
  `softness` (the point light's clamped to 2).
- The CPU fits the projections every frame, cached or not, without allocating: the tiles of the
  atlas (`ShadowAtlas3D.tiles`) are reused from frame to frame, so a tile read in one frame holds
  the values of the next one after it.

`RenderStats.shadowPasses` and `RenderStats.shadowDrawCalls` count the shadow passes and their draw
calls, which are also counted in `renderPasses` and `drawCalls`. The layers of a `ShadowGroup` that
reuse its map count no shadow pass. In a headless test, a hundred cubes sharing a mesh on a ground
in a `Scene3DComponent` render with 2 draw calls in 1 pass without shadows, and 4 draw calls in 2
passes with them (2 of them in the shadow pass).


## Measuring and debugging

- `RenderStats` (in `FlameGame3D.renderStats` and `Scene3DComponent.renderStats`) shows the passes
  above: `shadowPasses` is 1 for a single map and for the atlas, and 0 on a cached frame or in a
  layer that reuses its group's map.
- `RenderContext3D.hasActiveShadows` and `hasShadowAtlas` tell what the current pass receives, and
  `shadowMapVersion` changes every time a map is rendered.
- `RenderDebugMode3D.cascadeSplits` colors `SpatialMaterial` surfaces by cascade.
- A whole ground in shadow means a map that was never rendered (see
  [Rendering the shadow pass yourself](#rendering-the-shadow-pass-yourself)); shadows that stay
  where an object was mean a cached map (see [Static shadows](#static-shadows)).


## Platform support

- iOS and macOS (Metal), Android with Vulkan: shadows render into 32-bit float maps.
- Android with OpenGL ES: shadows render into packed RGBA8 maps. Packing was checked on both paths
  (single map, atlas) by forcing `ShadowMapEncoding.rgba8` on the backend of the
  headless tests, not on an OpenGL ES device; the placement of the atlas tiles there is not covered
  by a test.
- The web: no shadows. The shadow caster shaders have no WebGPU build: the first shadow pass that
  needs them finds they do not load, prints it once (`debugPrint`), and from then on the context
  renders no shadow pass and its receivers no shadows, as if no light had settings.
  `ShadowCatcherMaterial` throws an `UnsupportedError`, and the WebGPU build of `SpatialMaterial`
  reads only the single map. The same holds for any backend whose caster shaders do not load.


## Limitations

These are the parts of shadows that are not finished at this point:

- `WaterMaterial` has no spot lights, so it receives the shadows of the sun and of the point light
  only.
- The key of `cacheWhenStatic` does not see changes that do not change `World3D.castersVersion`
  (see [Static shadows](#static-shadows)).
- With an orthographic camera, or `ShadowFit.scene`, the inner cascades are fixed in the middle of
  the region and do not follow the camera.
- Every tile of the atlas traverses the scene again (eight traversals at most), unless the atlas
  is cached.
- Only one point light casts shadows, split along the world z axis.
- In a `ShadowGroup`, a layer that reuses the map applies its shadows to the lights by the indices
  the first layer's pass gave them: when the pass picks its lights by distance (more than four spot
  lights, or `prioritizeNearestLights` with more than eight point lights), another camera can pick
  them in another order.
- Spot-light shadows ignore `fit`, `bounds`, `maxDistance` and `stabilize`, and on the atlas their
  `normalBias`.
- In a shadow pass, `RenderContext3D.cameraPosition` is the position of the light's view: the
  world origin for a sun, the light itself for a spot light or the tiles of a point light.
  Components that pick their level of detail should use `RenderContext3D.viewerPosition` and
  `viewerViewProjection`, which stay those of the main camera while a shadow pass records:
  `ChunkedTerrain3D`, `FoliageSystem3D` and `LodMeshComponent` (when it has no `shadowMesh` and
  `lowestLodInShadowPass` is off) cast from the detail the camera of the frame selects (see
  [Large Worlds](world_scale.md#frustum-culling-and-bounds)).
- The sun's map is fitted to `World3D.sceneBounds`, the union of the bounds of every component of
  the world, whether it casts shadows or not. A component with huge bounds spreads the map over
  them until the shadows vanish: a `DebugRenderer3D`, whose bounds reach ±100000 units, removes
  the sun's shadows from its world (see
  [Debugging, Profiling and Testing](debugging_and_testing.md#costs-and-limitations)). Keep such
  components out of worlds whose sun casts shadows.
- Shadows are not available on the web.
- `UnlitMaterial` receives no shadows.
