# Materials and Textures

A `Material` decides how the surfaces drawn with it look: its shaders, the values it gives them and
its render state (see [Rendering](rendering.md)). This page describes the built-in materials, fog,
the skybox, textures, and how to write a material of your own. The lights the materials respond
to, image-based lighting and probes are described in [Lighting](lighting.md), shadows in
[Shadows](shadows.md).


## Choosing a material

| Material                | Use it for                             | Lit | Shadows | Fog | Web |
| ----------------------- | -------------------------------------- | --- | ------- | --- | --- |
| `SpatialMaterial`       | textured and glTF models, metal, glass | yes | yes     | yes | yes |
| `StylizedMaterial`      | vertex-colored low-poly art            | yes | 1 light | yes | no  |
| `UnlitMaterial`         | self-lit surfaces, pictures, UI        | no  | no      | no  | yes |
| `WaterMaterial`         | animated water                         | yes | 1 sun   | yes | no  |
| `OutlineMaterial`       | silhouette contours                    | no  | no      | no  | no  |
| `DecalMaterial`         | rings, markers, blob shadows           | no  | no      | no  | no  |
| `SkyboxMaterial3D`      | the sky behind everything              | no  | no      | no  | yes |
| `BillboardMaterial3D`   | sprites and standees                   | yes | no      | yes | yes |
| `ShadowCatcherMaterial` | shadows on 2D art                      | no  | yes     | no  | no  |

`BillboardMaterial3D` is described in [3D UI and Text](ui_3d.md#the-material),
`ShadowCatcherMaterial` in
[Shadows](shadows.md#shadows-on-2d-art), `ParticleMaterial` and `RibbonMaterial3D` in
[Particles and Ribbons](particles.md).

- Use `SpatialMaterial` for anything that has textures or comes from a glTF file, and for metals,
  car paint and glass. It is the only material that uses image-based lighting, reflection probes,
  light probe grids, lightmaps and linear HDR output (see [Lighting](lighting.md)).
- Use `StylizedMaterial` for flat-shaded or vertex-colored low-poly art: it has no textures, a soft
  look by default, per-vertex masks for tints, accents, glow and gloss, and wind. It is cheaper to
  bind than `SpatialMaterial` and does not depend on physically based light intensities.
- Use `UnlitMaterial` where lighting would get in the way: pictures, labels, emissive signs,
  debug geometry.

"1 light" means that the material receives the shadows of one light only, on the single-light
shadow path, and wrong shadows when the scene uses the multi-light shadow atlas (see the
[Limitations](#limitations)). "Web" says whether the material has WebGPU shaders and runs in a
browser; see [Web](#web).

Only `SpatialMaterial` (on native backends) is correct with `World3D.hdrEnabled` at this version:
it writes linear light, which the post-processing composite tone-maps and encodes to sRGB. Every
other material (`StylizedMaterial`, `UnlitMaterial`, `WaterMaterial`, `SkyboxMaterial3D`,
`DecalMaterial`, `OutlineMaterial`, `BillboardMaterial3D`, and the particle and ribbon materials)
writes display colors that the composite tone-maps and encodes a second time, so they look lighter
and washed out under HDR: a 50 % gray `UnlitMaterial` or `StylizedMaterial` shows as 81 % (206 of
255 instead of 128). Keep HDR off in scenes that use these materials.

Vertices built from `Vertex` objects, the built-in meshes and parsed models have white vertex
colors, so the vertex color only changes the look of meshes that set it. Every built-in material
multiplies its base color by the per-instance color (`MeshComponent.color`).


## What a draw binds

When a batch is submitted, the `RenderContext3D` binds the material (calling its `apply` once for
the whole instanced batch), then the blocks and textures the shaders list in their slots. Blocks
filled per render pass (camera, lights, fog, shadows) are written once per pass and rebound when the
pipeline changes; joint matrices are written for every skinned draw.

- `SpatialMaterial` (native): vertex `CameraMatrices`, `JointMatrices`; fragment `Material`,
  `PassOptions`, `ShadowAtlas`, `Shadows`, `Camera`, `Fog`, `AmbientLight`, `Lights`,
  `DirectionalLights`, `SpotLights`, `HemisphereLight` (11 blocks) and 11 textures: the six maps
  (albedo, normal, metallic-roughness, occlusion, emissive, environment), the lightmap,
  `brdfLutTexture`, `probeGridTexture`, `sceneColorTexture` and `shadowMap`. Maps that are not set
  are bound to a 1x1 white texture.
- `StylizedMaterial`: vertex `CameraMatrices`, `Wind` (and `JointMatrices` for skinned surfaces);
  fragment `Material`, `StylizedPass` (the camera, lights, shadows and fog of the pass in one
  block), `matCapTexture`, `gemMatCapTexture`, `shadowMap`: 7 bindings.
- `WaterMaterial`: vertex `CameraMatrices`, `WaterVertex`; fragment `WaterMaterial`,
  `StylizedPass`, `DepthNormal`, `SceneColor`, `shadowMap`, `depthNormalTexture`,
  `sceneColorTexture`.
- `UnlitMaterial`: vertex `CameraMatrices`, `JointMatrices`; fragment `Material`, `albedoTexture`.
- `OutlineMaterial`: vertex `CameraMatrices`, `Outline` (and `JointMatrices` when skinned).
- `DecalMaterial`: vertex `CameraMatrices`, `Decal`; fragment `Decal`, `albedoTexture`.
- `SkyboxMaterial3D`: fragment `Skybox`, `panoramaTexture`.

`RenderStats` (see [Rendering](rendering.md#frame-output-and-statistics)) counts the material
changes of a frame.

Material values are read when the material is bound, so changing them (or a component's `color`,
`instanceData` or `jointTransforms`) shows on the next frame. The engine cannot see such changes,
though: a `Scene3DComponent` with `Scene3DCacheMode.retained` keeps showing its cached image until
something it tracks changes. After animating a material or instance value in such a layer, call
`world.markSceneDirty(shadows: false)` or `layer.markDirty()`, see
[Embedding](embedding.md#retained-layer-caching) and
[Basic Concepts](basic_concepts.md#scene-versions-and-dirty-marking).


## SpatialMaterial

`SpatialMaterial` is a metallic-roughness physically based material: Cook-Torrance specular (GGX
distribution, Smith-Schlick geometry, Schlick Fresnel) over a Lambert diffuse, the glTF 2.0 maps,
a clear-coat layer, refraction for glass, and image-based lighting. On native backends it uses the
`spatial_material_pbr` shaders; on the web an older shader without the extensions described below
(see [Web](#web)).

```dart
final brick = SpatialMaterial(
  albedoTexture: albedo,
  normalTexture: normals,
  metallicRoughnessTexture: orm, // G = roughness, B = metallic
  occlusionTexture: orm, // R = ambient occlusion
  metallic: 1, // multiplies the B channel
  roughness: 1, // multiplies the G channel
  uvScale: Vector2.all(4), // the maps repeat 4 times
);
```


### Parameters

| Parameter                               | Default        | Meaning                             |
| --------------------------------------- | -------------- | ----------------------------------- |
| `albedoColor`, `albedoTexture`          | white, white   | base color, multiplied together     |
| `metallic`, `roughness`                 | `0.8`, `0.6`   | roughness is clamped to `0.04..1`   |
| `normalTexture`, `normalScale`          | none, `1`      | tangent-space normal map            |
| `metallicRoughnessTexture`              | none           | G times roughness, B times metallic |
| `occlusionTexture`, `occlusionStrength` | none, `1`      | R channel, darkens indirect light   |
| `emissiveColor`, `emissiveStrength`     | black, `1`     | added light                         |
| `emissiveTexture`                       | none           | times `emissiveColor`               |
| `environmentTexture`                    | none           | equirectangular reflections         |
| `environmentIntensity`                  | `1`            | strength of the reflections         |
| `environmentProbe`                      | none           | SH9 diffuse and reflections         |
| `lightmapTexture`, `lightmapIntensity`  | none, `1`      | baked indirect light, second UVs    |
| `clearcoat`, `clearcoatRoughness`       | `0`, `0.1`     | clear-coat layer                    |
| `transmission`, `ior`                   | `0`, `1.5`     | refraction; `ior` clamped to `1..3` |
| `uvScale`, `uvOffset`                   | `(1, 1)`, zero | `uv * uvScale + uvOffset`           |
| `alphaCutoff`                           | `0` (off)      | discards fragments below it         |
| `doubleSided`                           | `false`        | back faces lit as front faces       |
| `ditherFade`                            | `false`        | screen-door fade, stays opaque      |
| `translucent`, `singlePieceTranslucent` | `false`        | constructor only, see below         |

The default `metallic` of `0.8` makes surfaces mostly metallic and dark where no reflection reaches
them: set `metallic: 0` for wood, stone, plastic, skin and other dielectrics. All values may be
changed at any time; they are read when the material is bound.

`Material.defaultMaterial`, used for surfaces without a material, is a magenta `SpatialMaterial`.


### Maps and texture coordinates

- Every map is sampled at `uv * uvScale + uvOffset` of the first texture coordinates, except the
  lightmap, which reads the second ones (`vertexTexCoord1`) without the transform. Surfaces without
  a second channel use the first one for the lightmap.
- The normal map perturbs the normal in tangent space, its `x` and `y` scaled by `normalScale`.
  Surfaces in `VertexLayout.pbrStandard` (with `vertexTangent` and `vertexTexCoord1`) use their
  MikkTSpace tangents, through a second vertex shader variant; other surfaces use a tangent frame
  derived per pixel from screen-space derivatives, which works without tangents but shows seams on
  mirrored UVs. `Surface.computeTangents` adds tangents (and optionally the second UV channel) and
  switches the surface to `pbrStandard`:

```dart
// Adds MikkTSpace tangents and a second UV channel to the surface: it now
// uses VertexLayout.pbrStandard and the tangent-space shader variant.
surface.computeTangents(texCoord1: uv1);
final material = SpatialMaterial(
  metallic: 0,
  lightmapTexture: baked, // sampled with vertexTexCoord1
);
```

- With a metallic-roughness map, `metallic` and `roughness` multiply its blue and green channels,
  so set both to `1` to use the map as it is.
- The occlusion map darkens the ambient, hemisphere, probe, lightmap and reflected light (by
  `mix(1, occlusion, occlusionStrength)`), not the direct light.
- The emissive color is `emissiveColor * emissiveStrength`, times the emissive map when there is
  one, times `1 + instanceData.x`.

Textures are sampled as they are stored: see [Color space](#color-space) for sRGB.


### Shading and output

With `base` the albedo color times the albedo map, the vertex color and the instance color, `n` the
(mapped) normal and `v` the direction to the viewer:

```text
f0      = mix(((ior - 1) / (ior + 1))², base, metallic)   // 0.04 for ior 1.5
kD      = (1 - F(n·v)) * (1 - metallic) * (1 - transmission)
ambient = kD * base * (ambient light + hemisphere light
                       + (probe SH9 + probe grid) / π
                       + lightmap * lightmapIntensity)
          + reflections (see Lighting)
ambient = ambient * occlusion
direct  = Σ lights: (kD * base / π + D * G * F / (4 n·v n·l) * specular)
                    * radiance * n·l
color   = ambient + direct + emissive * (1 + instanceData.x)
          + instanceData.y   // highlight, white
alpha   = albedoColor.a * albedo map a * vertex a * instance a
          * (1 - instanceData.w)
```

`radiance` and `specular` are those of each light, see [Lighting](lighting.md#light-types). How
the color reaches the screen depends on `World3D.hdrEnabled`:

- Without HDR (the default), the color is compressed with `c / (c + 1)` and encoded with a gamma of
  2.2 in the shader, then fogged. A radiance of `0.25` gives 123 of 255, `0.5` gives 155, `1` gives
  186, `2` gives 212 and `4` gives 230: a white surface never reaches white. A white dielectric
  surface facing a directional light of intensity `3` with the default ambient light shows about
  190 of 255.
- With `World3D.hdrEnabled`, the shader writes the linear color unclamped into a 16-bit float
  target; the post-processing composite tone-maps it (ACES by default) and encodes it to sRGB, see
  [Post-Processing](post_processing.md). Only `SpatialMaterial` switches to linear output: see the
  [Limitations](#limitations).

`World3D.renderDebugMode3D` shows the normals (`normals`), the roughness and metallic values
(`roughnessMetallic`) or the unlit albedo (`albedo`) of `SpatialMaterial` surfaces; other materials
ignore these modes.


### Clearcoat

`clearcoat` (`0..1`) adds a second, colorless specular layer (`F0 = 0.04`) on top of the surface,
like varnish or car paint, with its own `clearcoatRoughness`. It uses the geometric normal, not the
normal map, and dims the layer below it by its Fresnel term. It reflects the environment too when
the material has one.

```dart
final paint = SpatialMaterial(
  albedoColor: const Color(0xFFB0222A),
  metallic: 0.3,
  roughness: 0.5,
  clearcoat: 1,
  clearcoatRoughness: 0.08,
);
```


### Transmission and refraction

A material with `transmission` above `0` is glass: it is drawn translucent (straight alpha, sorted
back to front, back faces culled unless `doubleSided`), its diffuse light is scaled by
`1 - transmission`, and it adds the light behind it, tinted 85 % towards its base color:

- When the frame has a scene-color grab pass, the light behind it is read from a copy of the opaque
  scene, offset by the view-space normal and `ior`. The grab pass runs automatically when any
  transmissive `SpatialMaterial` is drawn (or when `World3D.grabSceneColorEnabled` is set) on
  backends that render into textures: it draws the opaque scene a second time into a texture of the
  size of the frame (see [Rendering](rendering.md#scene-color-grab-pass)). The glass is then
  written with an alpha of at least `transmission`.
- Otherwise the refracted ray samples the environment texture or probe, and without either the
  glass shows half its base color.

```dart
final glass = SpatialMaterial(
  albedoColor: const Color(0xFFE8F4FF),
  metallic: 0,
  roughness: 0.05,
  transmission: 0.95, // ior: 1.5 by default
);
```

The refraction is a screen-space offset, not a ray trace: what is outside the frame or in front of
the glass cannot be refracted, and the offset does not depend on the thickness of the object.


### Transparency, cutout and fades

- `alphaCutoff` above `0` discards fragments whose alpha is below it: foliage, fences, cut-out
  sprites. The material stays opaque and batches.
- `ditherFade: true` discards fragments in a 4x4 Bayer pattern where the alpha is below the pattern
  threshold and writes the others opaque: an object fades out (with `instanceData.w`) without being
  sorted, at the cost of a screen-door look.
- `translucent: true` blends with straight alpha (`RenderState.alphaBlend`). Textures made from
  Flutter images are premultiplied, so their semi-transparent texels are multiplied by their alpha
  twice and darken; for clean soft edges, build the texture from straight-alpha pixels
  (`Image.toByteData(format: ImageByteFormat.rawStraightRgba)`). `singlePieceTranslucent: true`,
  together with `translucent`, uses
  `RenderState.singlePieceAlphaBlend`, which writes the
  depth of the whole object before shading it, so overlapping parts of one mesh do not show through
  each other (see [Rendering](rendering.md#render-state)).

```dart
final foliage = SpatialMaterial(
  albedoTexture: leaves,
  metallic: 0,
  roughness: 0.8,
  alphaCutoff: 0.5, // discards fragments with alpha below 0.5
  doubleSided: true, // lights the back faces as front faces
);
```

The per-instance data (see [Rendering](rendering.md#per-instance-color-and-data)) of a
`SpatialMaterial` draw is: `x`, an emissive boost (the emissive light times `1 + x`); `y`, a white
highlight added to the color (`0..1`); `w`, the fade (opacity `1 - w`). `z` is unused.

```dart
final door = MeshComponent(
  mesh: doorMesh, // its surfaces use SpatialMaterial(translucent: true)
  instanceData: Vector4(0, 0, 0, 0.5), // w: fade, half transparent
);
// On hover: glow (x) and lighten (y).
door.instanceData
  ..x = 0.5
  ..y = 0.1;
```

`SpatialMaterial` does not cull back faces by default. `doubleSided` does not change culling: it
flips the normal of back faces so that they are lit like front faces.


## StylizedMaterial

`StylizedMaterial` lights low-poly meshes whose vertices carry a color, a baked ambient occlusion
and a few masks that pick per-vertex effects: which vertices take the per-instance tint or the
material's accent color, which ones glow, how glossy they are, and how they move in the wind.


### Vertex layout

It reads `StylizedMaterial.vertexLayout`, 18 floats per vertex:

| Attribute         | Floats | Meaning                                                   |
| ----------------- | ------ | --------------------------------------------------------- |
| `vertexPosition`  | 3      | the position                                              |
| `vertexNormal`    | 3      | the normal                                                |
| `vertexColor`     | 4      | the color (rgb) and alpha                                 |
| `vertexMasks`     | 4      | the tint, accent and emissive masks, and the gloss        |
| `vertexOcclusion` | 1      | the ambient occlusion: `1` unoccluded, `0` fully occluded |
| `vertexWind`      | 3      | the sway weight, the phase (in turns), the flutter weight |

The masks blend from `0` (none) to `1` (fully). The gloss is the strength of the vertex's
highlights; it may exceed `1` for extra bright ones (gems, for instance). The wind of a vertex is
how much it sways, the phase of its sway and flutter in turns (`0` to `1` is a full turn, so that
the vertices of one object need not move in step) and how much it flutters, see [Wind](#wind).

`StylizedMaterial.buildSurface` packs per-vertex arrays into this layout; arrays left out take
their defaults (white, unoccluded, no mask, no sway, phase `0`, no flutter):

```dart
final material = StylizedMaterial(
  accentColor: const Color(0xFF3FA796),
);

final surface = StylizedMaterial.buildSurface(
  positions: positions, // 3 floats per vertex
  normals: normals, // 3 floats per vertex
  colors: colors, // 4 floats per vertex (RGBA)
  occlusion: occlusion, // 1 float per vertex
  tint: tintMask,
  accent: accentMask,
  emissive: emissiveMask,
  gloss: gloss,
  sway: sway, // the sway weight
  windPhase: phase, // in turns, 0 by default
  windFlutter: flutter, // the flutter weight, 0 by default
  indices: indices,
  material: material,
);

world.add(
  MeshComponent(
    mesh: Mesh()..addSurface(surface),
    color: playerColor, // the tint of the tint-masked vertices
  ),
);
```

It also draws surfaces in the standard layout, such as the built-in meshes, parsed models and
skinned meshes: their vertex color is used, and they are unoccluded, tinted by the per-instance
color everywhere, with no accent, emission, gloss nor wind.


### Skinning

Surfaces in `StylizedMaterial.skinnedVertexLayout`, 26 floats per vertex, are skinned: the 18
floats above followed by `vertexJoints` (up to four joint indices) and `vertexWeights` (their
weights), 4 floats each. Each vertex is moved by the weighted sum of the joint matrices of its draw,
`sum(weight * joint) * position` (and its normal by the same matrix), then shaded like any other
vertex; its wind is added in model space after the skinning. A vertex whose weights are all
`0` keeps its position, and weights need not add up to `1` when the joints are built for it (for
example two joints that differ only in a translation, weighted `1 - w` and `w`, move a vertex by
`w` times the difference).

`buildSurface` lays the surface out this way when given `joints` and `weights`, both together; the
indices must be whole numbers below `StylizedMaterial.maxJoints` (64). Every draw of a skinned
surface gives its joint matrices, which can be updated in place every frame:

```dart
final surface = StylizedMaterial.buildSurface(
  positions: positions,
  normals: normals,
  colors: colors,
  joints: joints, // 4 joint indices per vertex
  weights: weights, // 4 weights per vertex
  indices: indices,
  material: material,
  // Culling uses the bounds of the rest pose unless given wider ones.
  aabb: boundsOfEveryPose,
);

final arm = Matrix4.identity();
final figure = MeshComponent(
  mesh: Mesh()..addSurface(surface),
  jointTransforms: {
    0: [Matrix4.identity(), arm], // the joint matrices of surface 0
  },
);

// Every frame: swing the arm about its shoulder.
arm
  ..setIdentity()
  ..translateByVector3(shoulder)
  ..rotateY(swing)
  ..translateByVector3(-shoulder);
```

A custom `Object3D` gives them to `RenderContext3D.drawSurface(jointTransforms: ...)` instead. A
skinned draw is never batched with another: each costs one draw call, whatever its material.


### Per-instance data

Besides the per-instance color, which tints the vertices of the tint mask, each object can vary
through the four floats of its per-instance data (`MeshComponent.instanceData`, zero by default,
see [Rendering](rendering.md#per-instance-color-and-data)):

| Component | Meaning                                                                       |
| --------- | ----------------------------------------------------------------------------- |
| `x`       | emissive boost: added to `emissiveStrength`, moves the glow color (see below) |
| `y`       | highlight: `highlightColor` times it is added to every vertex                 |
| `z`       | wind strength, added to 1: `-1` stills the object's wind, `1` doubles it      |
| `w`       | fade: the object's opacity is `1 - w`; or an accent index, see below          |

From `0` to `1`, the emissive boost also moves the color of the glowing vertices from
`emissiveColor` towards `emissiveBoostColor` (by default the same color).

Objects that differ only in these values still cost one draw call per surface, so a hovered building
can glow more, or a tree sway less, without a material of its own:

```dart
final ghost = StylizedMaterial(translucent: true);

final house = MeshComponent(mesh: houseMesh); // drawn with an opaque material
final preview = MeshComponent(
  mesh: nextStageMesh, // its surfaces drawn with `ghost`
  instanceData: Vector4(0, 0, 0, 0.6), // 40 % opaque
);

// When the pointer is over the house, it glows and lightens:
house.instanceData
  ..x = 0.4
  ..y = 0.15;
```


### Shading

With `n` the normal, `v` the direction to the viewer, `up`, `sky` and `ground` those of the
hemisphere light, `hemi = 0.5 + 0.5 * n·up`, `bounce = max(0, -n·up)` and `boost`, `highlight` and
`fade` from the instance data:

```text
base = albedoColor * vertexColor * mix(1, instance color, tint mask)
       * mix(1, accentColor, accent mask)
lit  = occlusion * (ambient light
         + hemisphere intensity * (ambientBase
                                   + skyFill * skyFillWeight * sky * hemi
                                   + groundBounce * ground * bounce))
       + Σ directional: max(0, n·l) * intensity * color * shadow
       + Σ point: intensity * color * falloff * max(pointLightWrap, n·l)
       + Σ spot: intensity * color * falloff * cone
                 * max(pointLightWrap / 2, n·l) * shadow
spec = only where gloss > specularThreshold:
       (Σ directional: (n·h)^specularPower * specular factor * mean(shadow)
        + Σ spot where n·l > 0: (n·h)^specularPower * specular factor
                                * intensity * falloff * cone * mean(shadow))
       * gloss * specularStrength
rim  = (1 - n·v)^rimPower * rimStrength * (sky + rimColor)
cap  = where gloss > gemThreshold (with a gemMatCapTexture):
         gemMatCapTexture(view-space normal) * gemMatCapStrength
       elsewhere, where gloss > matCapThreshold:
         matCapTexture(view-space normal) * matCapStrength
         * mix(1, gloss, matCapGlossWeight)
surface = base * lit + rim
shaded  = mix(surface + cap, min(surface, 1) * reflected, matCapMetallic)
          + spec + highlight * highlightColor
glow = clamp(emissive mask * (emissiveStrength + boost), 0, 1)
lit  = clamp(mix(shaded,
                 mix(emissiveColor, emissiveBoostColor, clamp(boost, 0, 1)),
                 glow), 0, 1)
out  = fog(mix(mix(luminosity(lit), lit, saturation), overlayColor.rgb,
               overlayColor.a))
alpha = albedoColor.a * vertex alpha * instance color alpha * (1 - fade)
```

`falloff` and `cone` are those of the point and spot lights (see
[Lighting](lighting.md#point-light)). `shadow` is `1`, except for the light that casts shadows,
where it is `mix(white, color, strength * (1 - visibility))` with the light's shadow `color` and
`strength` and `visibility` from `0` (in its shadow) to `1` (see
[Shadows](shadows.md#receiving-shadows)). MatCap textures are sampled at
`(0.5 + 0.5 x, 0.5 - 0.5 y)` of the view-space normal, `x` pointing right and `y` up in the
picture, also when the projection mirrors the picture (as some `Scene3DProjection`s do).
`reflected` is `cap` on the vertices that get a MatCap texture and `1` on the others (see
[Metals](#metals)). Highlights of directional lights are white and follow the direction of the
lights, not their intensity, so they keep their strength when a sun dims; those of spot lights
scale with their light. The result is clamped to `[0, 1]`, with no tone mapping, graded (see
[Color grade](#color-grade)), fogged (see [Atmospheric fog](#atmospheric-fog)) and output
premultiplied by its alpha. For orthographic cameras, `v` is the camera's direction.
`skyFillWeight` weighs the sky fill per channel, for example `Vector3(1, 1, 0.914)` with the
default `skyFill` for a fill of `(0.35, 0.35, 0.32)` times the sky color.

It reads the same lights as the other materials: up to 4 directional, 8 point and 4 spot lights per
render pass, chosen as [Lighting](lighting.md#how-many-lights-reach-a-shader) describes. It does
not use environment probes, reflection probes, light probe grids or lightmaps. It receives the
shadows of one light, through the `Shadows` block: a directional light with 1 or 2 cascades, or a
spot light. When the scene needs the multi-light shadow atlas (3 or 4 cascades, a point light with
shadows, or more than one light with shadows, see [Shadows](shadows.md)), its shadows are wrong.
Without a `HemisphereLight` in the scene, `ambientBase`, `skyFill` and `groundBounce` have no
effect and only the ambient light lights the shadowed side.

| Parameter                                     | Default                   | Meaning              |
| --------------------------------------------- | ------------------------- | -------------------- |
| `albedoColor`                                 | white                     | times vertex color   |
| `accentColor`, `accentPalette`                | white, empty              | the accent color(s)  |
| `ambientBase`                                 | `0.65` gray               | ambient for all      |
| `skyFill`, `skyFillWeight`                    | `0.35`, `(1, 1, 1)`       | sky share            |
| `groundBounce`                                | `0.10`                    | ground share         |
| `pointLightWrap`                              | `0.18`                    | least point light    |
| `specularStrength`, `specularPower`           | `0.28`, `8`               | highlights           |
| `specularThreshold`                           | `0.12`                    | least gloss to shine |
| `rimStrength`, `rimPower`, `rimColor`         | `0.14`, `3`, black        | rim light            |
| `emissiveColor`, `emissiveStrength`           | white, `1`                | glowing vertices     |
| `emissiveBoostColor`                          | `emissiveColor`           | glow at boost 1      |
| `highlightColor`                              | white                     | instance highlight   |
| `matCapTexture`, `matCapStrength`             | none, `1`                 | MatCap sheen         |
| `matCapThreshold`, `matCapGlossWeight`        | `0`, `1`                  | least gloss, weight  |
| `gemMatCapTexture`, `gemMatCapStrength`       | none, `1`                 | MatCap of gems       |
| `gemThreshold`                                | `1`                       | least gloss of gems  |
| `matCapMetallic`                              | `0`                       | MatCap reflection    |
| `windDirection`, `windAmplitude`, `windSpace` | `(1,0,0)`, `0.032`, world | sway way and reach   |
| `windFrequency`, `windPhase`, `windTime`      | `2.3`, `(0.7,0,0.5)`, `0` | sway timing          |
| `windUpAxis`                                  | `(0, 1, 0)`               | up for `worldScaled` |
| `windFlutterAmplitude`                        | `0` (off)                 | flutter reach        |
| `windFlutterFrequency`                        | `12`                      | flutter timing       |
| `windGustAmplitude`, `windGustFrequency`      | `0` (off), `0.8`          | gusts                |
| `windGustDirection`, `windGustPhaseScale`     | `(1, 0, 0)`, `0.5`        | gusts' travel        |
| `saturation`, `overlayColor`                  | `1`, transparent          | color grade          |
| `ditherFade`                                  | `false`                   | screen-door fade     |
| `translucent`, `singlePieceTranslucent`       | `false`                   | constructor only     |

With the defaults, the MatCap texture is added in proportion to the gloss of every vertex. For a
clear-coat sheen on the glossy vertices only and a separate sheen on gems, at full strength:

```dart
final material = StylizedMaterial(
  matCapTexture: clearCoat,
  matCapStrength: 0.6,
  matCapThreshold: 0.36,
  matCapGlossWeight: 0, // the same strength whatever the gloss
  gemMatCapTexture: gemSheen,
  gemThreshold: 1.5, // vertices with more gloss are gems
);
```


### Metals

An added MatCap is a sheen over the surface: a clear coat, the glint of a gem. On metals it washes
the color out, a gold tint plus a bright gold sheen reading as pale yellow. With
`matCapMetallic: 1` the MatCap is the surface's own reflection instead: the lit surface, at most `1`
per channel, multiplies it, so that a gold MatCap on a gold tint gives a deep, saturated gold, dark
where the MatCap is dark. A fully lit white vertex shows the MatCap as painted; vertices without a
MatCap (below `matCapThreshold`) keep their lit color, and values between `0` and `1` blend the
sheen and the reflection. Both tiers reflect, so one material can hold two metals picked by gloss:

```dart
final metals = StylizedMaterial(
  matCapTexture: goldMatCap, // every vertex up to the gem threshold
  matCapThreshold: -1,
  matCapGlossWeight: 0,
  gemMatCapTexture: steelMatCap, // vertices with more gloss than 1.5
  gemThreshold: 1.5,
  matCapMetallic: 1,
  specularStrength: 0, // the MatCaps paint the highlights
);
```


### Color grade

Last, the clamped color is graded. `saturation` moves it towards its luminosity,
`0.3 r + 0.59 g + 0.11 b` (the luminosity of the non-separable blend modes): `1`, the default,
leaves it as it is and `0` turns it grey. Then `overlayColor` covers it as far as its alpha goes:
transparent, the default, leaves it as it is. One material per grade greys out or tints whole
objects whatever their vertex colors, for a disabled or petrified look, or the glint of a shield:

```dart
final stunned = StylizedMaterial(saturation: 0); // grey
final shielded = StylizedMaterial(
  overlayColor: const Color(0x3864FFDA), // 22 % of a cyan glint
);
```

Graded objects still batch with each other, as long as they share their material.


### Wind

A vertex moves along `windDirection` by

```text
offset  = (sway + flutter) * gust * (1 + instanceData.z)
sway    = windAmplitude * sway weight
          * sin(windTime * windFrequency + dot(origin, windPhase) + phase)
flutter = windFlutterAmplitude * flutter weight
          * sin(windTime * windFlutterFrequency + dot(origin, windPhase)
                + phase)
gust    = 1 + windGustAmplitude
              * sin(windTime * windGustFrequency
                    - dot(origin, windGustDirection) * windGustPhaseScale)
```

where `origin` is the world position of its object, `phase` the phase of the vertex in radians
(its phase in turns times `2π`) and `1 + instanceData.z` the wind strength of its object.

- The sway is the slow swing of the whole object, more at the vertices of higher sway weight
  (the tip of a tree more than its trunk). The phase of the vertices delays some of them, so that
  branches or blades of one mesh do not swing in step.
- The flutter is a fast, small sway of the vertices with a flutter weight: leaves, a flag, grass
  tips. It takes the same phases.
- The gust is a slow wave that crosses the scene along `windGustDirection` (normalized, in world
  space), at `windGustFrequency / windGustPhaseScale` world units per second: the wind of the
  objects it reaches strengthens up to `1 + windGustAmplitude` times, and weakens down to
  `1 - windGustAmplitude` times, between its crests. A phase scale of `0` gusts the whole scene in
  unison.

The flutter and the gusts are off by default (their amplitudes are `0`), and vertices built
without a phase have a phase of `0`: a material that does not set them renders as it did before
they existed.

`windSpace` is the space of the direction and of the amplitudes:

| `windSpace`             | Direction    | Amplitudes                                  |
| ----------------------- | ------------ | ------------------------------------------- |
| `WindSpace.world`       | world        | in world units                              |
| `WindSpace.model`       | each model's | in model units: they scale with each object |
| `WindSpace.worldScaled` | world        | times each object's scale along its up axis |

With `WindSpace.world` (the default), every object sways the same way by the same distance. With
`WindSpace.model`, the sway is part of each object, as if it were in its mesh: it turns with the
object's rotation and scales with its scale, so one material serves objects of every orientation
and size, each swaying along its own axes. With `WindSpace.worldScaled`, every object sways the
same world way, whatever its rotation, by a distance scaled by its size along its up axis,
`windUpAxis` (in model space, normalized): a field of trees of every yaw and height bends as one
wind, a tree scaled twice as tall swaying twice as far. Its scale along its up axis is the length
its transform gives `windUpAxis`.

```dart
final trees = StylizedMaterial(
  windSpace: WindSpace.worldScaled,
  windDirection: Vector3(1, 0, 0.3), // the world way of the wind
  windUpAxis: Vector3(0, 1, 0), // the up axis of the tree meshes
  windAmplitude: 0.032, // for a tree of scale 1
  windPhase: Vector3(0.7, 0, 0.5), // from the world position of each tree
  windFlutterAmplitude: 0.006, // the leaves
  windFlutterFrequency: 13,
  windGustAmplitude: 0.5, // gusts from 0.5 to 1.5 times the wind
  windGustDirection: Vector3(1, 0, 0.3),
);
```

The wind moves the vertices only where they are drawn: the shadows are cast from the rest
positions, so the wind does not move them (see [Shadows](shadows.md)).

Advance `windTime` every frame, and drive `emissiveStrength` from the time of day to light
windows at dusk (in a retained `Scene3DComponent`, also mark the scene dirty, see
[What a draw binds](#what-a-draw-binds)):

```dart
@override
void update(double dt) {
  material
    ..windTime += dt
    ..emissiveStrength = dusk;
}
```


### Batching, accent palettes, and translucency

Like the other built-in materials, it is drawn instanced: components sharing a mesh with a
`StylizedMaterial` cost one draw call per surface, whatever their tints and instance data. To vary
the accent color per instance without splitting draw calls, give the material an `accentPalette`
(up to `StylizedMaterial.maxAccentPaletteSize`, 16 colors; more are ignored) and pack a palette
index, with an optional fade, into `instanceData.w` with `StylizedMaterial.packAccentAndFade`:

```dart
final material = StylizedMaterial(
  accentPalette: const [
    Color(0xFFE53935),
    Color(0xFF1E88E5),
    Color(0xFF43A047),
  ],
);
final unit = MeshComponent(
  mesh: unitMesh,
  instanceData: Vector4(
    0,
    0,
    0,
    StylizedMaterial.packAccentAndFade(1), // the blue accent
  ),
);
```

`packAccentAndFade(index, fade: f)` returns `(index + 1) * 4 + f`, and throws for an index outside
`0..15`. A `w` below `2` is a plain fade, as before; a `w` of `2` or more is decoded in the fragment
shader into the palette index and the fade. An index beyond the palette's length falls back to
`accentColor`. The palette replaces `accentColor` only on the vertices of the accent mask, so it
does nothing on surfaces in the standard layout (which have no accent mask), and it works the same
for skinned surfaces, translucent materials and every vertex shader variant. The shadow pass does
not read the instance data: an object faded with `w` still casts its full shadow if its material
casts shadows.

`StylizedMaterial(translucent: true)` blends its premultiplied output over what is behind it
(`StylizedMaterial.translucentRenderState`: depth tested, without depth writes), and its draws are
sorted back to front after the opaque ones; objects then fade with the `w` of their instance data.
Consecutive translucent draws of one surface are still batched. Back-face culling
(`renderState = StylizedMaterial.translucentRenderState.copyWith(cullMode: CullMode.backFace)`)
keeps the inner faces of a closed mesh from showing through; `singlePieceTranslucent: true` writes
the depth of the whole object first instead, so that only its nearest surface is blended (see
[Rendering](rendering.md#render-state)). `ditherFade: true` fades opaque objects with a 4x4 Bayer
screen-door pattern instead, without sorting.

With `World3D.oitMode` set to `OitMode3D.weightedBlended`, translucent draws are not drawn with
their own material: translucent `StylizedMaterial` surfaces in its own layout disappear, see the
[Limitations](#limitations).

```{note}
`StylizedMaterial` is not available on the web yet: creating one there throws an
`UnsupportedError`.
```


## WaterMaterial

`WaterMaterial` draws an animated water surface. Its vertex shader displaces the vertices with four
Gerstner waves computed from their world position, so the mesh must be subdivided and lie
perpendicular to `upAxis`; its fragment shader adds scrolling ripples, a deep-to-shallow color
gradient by wave height, crest foam, a Fresnel blend towards the sky color, specular glints and
fog.

```dart
final water = WaterMaterial(
  deepColor: const Color(0xFF0B2545),
  waveAmplitude: 0.1,
  shoreFoamDepth: 0.02, // needs World3D.depthPrepassEnabled
);
final grid = TerrainMesh3D(
  columns: 64,
  rows: 64,
  width: 20,
  depth: 20,
  heights: Float32List(64 * 64), // flat: the waves move the vertices
  material: water,
);
world.add(MeshComponent(mesh: grid));

// Every frame (and mark a retained layer dirty, see What a draw binds):
water.time += dt;
```

| Parameter                       | Default        | Meaning                          |
| ------------------------------- | -------------- | -------------------------------- |
| `shallowColor`                  | `0xFF38BDF8`   | color of the crests              |
| `deepColor`                     | `0xFF0F3460`   | color of the troughs             |
| `foamColor`                     | `0xE6F8FAFC`   | foam color, its alpha the amount |
| `time`                          | `0`            | advance it every frame           |
| `waveAmplitude`                 | `0.08`         | height of the largest wave       |
| `waveFrequency`, `waveSpeed`    | `1.6`, `1.8`   | of the largest wave              |
| `steepness`                     | `0.45`         | horizontal pinch of the crests   |
| `upAxis`                        | `(0, 1, 0)`    | the rest surface's normal        |
| `rippleStrength`, `rippleScale` | `0.08`, `0.85` | per-pixel ripples                |
| `foamThreshold`                 | `0.68`         | crest height where foam starts   |
| `fresnelPower`                  | `3.2`          | sky reflection at grazing angles |
| `specularStrength`              | `0.85`         | glints                           |
| `specularPower`                 | `48`           | glint sharpness                  |
| `opacity`                       | `0.86`         | below `1`: blended               |
| `shoreFoamDepth`                | `0` (off)      | depth span of shore foam         |
| `refractionStrength`            | `0.04`         | screen offset of the refraction  |

- The four waves travel in fixed directions, the smaller ones at `0.62`, `0.38` and `0.24` times
  the amplitude and `1.65`, `2.7` and `4.1` times the frequency. Waves are continuous across
  objects, since they depend on the world position only.
- Light: the directional lights (diffuse wrapped as `0.35 + 0.65 n·l`, and glints), the point
  lights and the spot lights (diffuse `n·l` and glints, inside their cone and range, glints scaled
  by the spot light's `specular`). The sky color is the hemisphere light's sky color times its
  intensity, or the ambient light without a hemisphere light: the water does not reflect the
  skybox or an environment probe. It receives the shadow of the sun that casts shadows on the
  single-light shadow path only, like `StylizedMaterial`.
- Ripples perturb the normal in the plane perpendicular to `upAxis`, in the same frame as the
  waves, so the water looks the same in `+Y`-up and `+Z`-up worlds.
- Refraction: with `World3D.grabSceneColorEnabled`, the water shows the opaque scene below it,
  offset by the ripples (`refractionStrength`), and is written opaque. The grab pass and its cost
  are described in [Rendering](rendering.md#scene-color-grab-pass).
- Shore foam: with `shoreFoamDepth` above `0` and `World3D.depthPrepassEnabled`, the water foams
  and fades where the depth of the opaque scene behind it is within `shoreFoamDepth` (in clip-space
  depth, not world units) of its own, see
  [Post-Processing](post_processing.md#shoreline-foam) for the depth prepass.
- `opacity` below `1` draws the water blended (straight alpha, back faces culled) after the opaque
  draws; `1` or more draws it opaque. Setting `opacity` updates the render state, unless you set
  `renderState` yourself. Water never casts shadows.

It does not run on the web: there is no WebGPU version of its shaders.


## UnlitMaterial

`UnlitMaterial` outputs `albedoTexture * albedoColor * vertex color * instance color`, without
lighting, fog, shadows, tone mapping or gamma. By default it blends with premultiplied alpha
(`RenderState(blend: BlendState.premultipliedAlpha)`, which writes depth) and is drawn as a
translucent draw: sorted back to front after the opaque draws, batched only with consecutive draws
of the same surface. Set its `renderState` to `RenderState.opaque` for opaque content so that it
batches with the opaque draws:

```dart
final label = UnlitMaterial(albedoTexture: picture)
  ..renderState = RenderState.opaque;
final ghost = UnlitMaterial(albedoColor: const Color(0x80FFFFFF))
  ..renderState = RenderState.alphaBlend; // straight alpha
```

The material multiplies the colors; it does not premultiply them. Textures made from Flutter
images are premultiplied, which suits the default blending, but a translucent `albedoColor`,
vertex or instance color must be premultiplied (its red, green and blue at most its alpha), or the
material should blend with straight alpha (`RenderState.alphaBlend`) as `ghost` does above.


## Silhouette outlines

`OutlineMaterial` draws the inverted hull of a mesh: it pushes the vertices out along their normals
and culls front faces, so only a rim around the silhouette shows behind the object. Draw the mesh
twice, once with its own material and once with the outline:

```dart
final outline = OutlineMaterial(
  color: const Color(0xFF1A1423),
  thickness: 0.01, // 0.5 % of the viewport height on each side
  screenSpace: true,
);
final body = SphereMesh(radius: 0.7, material: SpatialMaterial());
final hull = SphereMesh(radius: 0.7, material: outline);
world.addAll([
  MeshComponent(mesh: body),
  MeshComponent(mesh: hull),
]);
```

A custom `Object3D` can draw the same surfaces with the outline as a material override, without a
second mesh:

```dart
class OutlinedMesh extends Object3D {
  OutlinedMesh(this.mesh, this.outline);

  final Mesh mesh;
  final OutlineMaterial outline;

  @override
  Aabb3? computeLocalAabb() => mesh.aabb;

  @override
  void draw(covariant RenderContext3D context) {
    context.drawMesh(mesh, transform: worldTransformMatrix);
    if (context.isShadowPass) {
      return;
    }
    for (final surface in mesh.surfaces) {
      context.drawSurface(
        surface,
        transform: worldTransformMatrix,
        material: outline,
      );
    }
  }
}
```

| Parameter     | Default      | Meaning                                                          |
| ------------- | ------------ | ---------------------------------------------------------------- |
| `color`       | `0xFF1A1614` | times the instance color                                         |
| `thickness`   | `0.03`       | world units, or with `screenSpace` a fraction of the clip height |
| `screenSpace` | `false`      | constant width in pixels, whatever the distance and zoom         |
| `depthBias`   | `0.0005`     | clip-space push away from the camera, hides inner creases        |

Per instance, `instanceData.x` scales the thickness by `1 + x` (`-1` hides the outline) and
`instanceData.y` is added to `depthBias`, so outlines of different widths still batch. Skinned
surfaces (with joints and weights) use a skinned variant, with the joint matrices of their draw.
The material is opaque, never casts shadows, and is not available on the web (creating one throws
an `UnsupportedError`).

The hull follows the mesh's normals: a mesh with split normals at hard edges (a cube with flat
faces) opens gaps at its corners, so give outlined meshes smooth normals. The normals are
transformed by the model matrix, not its inverse transpose, so non-uniformly scaled objects get
uneven outlines. The alpha of `color` darkens the outline rather than making it see-through, since
the material draws opaque; give it `RenderState.premultipliedAlphaBlend` for a translucent one.


## Surface decals

`DecalBatch3D` draws many flat quads (rings, selection markers, footprints, scorch marks, blob
shadows) in one instanced draw with a `DecalMaterial`. Without a texture the material draws a soft
disc, or a ring with `innerRadius`; with an atlas texture each decal can show its own `uvRect`.
Decals are drawn translucent (premultiplied alpha, no depth writes) and pushed towards the camera
in clip space (`depthBias`) so that they do not fight with the floor they lie on:

```dart
final decals = DecalBatch3D(
  material: DecalMaterial(innerRadius: 0.72, softness: 0.08),
)
  ..addFlatDecal(
    center: Vector3(3, 0, 4),
    width: 1.4,
    height: 1.4,
    color: const Color(0xFFFFD54F),
  )
  ..addBlobShadow(
    groundPoint: Vector3(0, 0, 0),
    radius: 0.5,
    elevation: 0.8, // the higher, the wider and fainter
  );
world.add(decals);
```

- `addFlatDecal(center, width, height, angle, normal, color, uvRect)` lays a decal in the plane
  whose `normal` is given (`(0, 1, 0)` by default; pass `(0, 0, 1)` for a Z-up board), turned by
  `angle` radians in that plane. `addDecal(transform: ...)` takes any matrix that maps the unit
  quad `[-0.5, 0.5]²` in the XY plane. Both return the index of the decal.
- `addBlobShadow(groundPoint, radius, elevation, maxElevation: 4, baseOpacity: 0.55, ...)` adds a
  dark disc that widens up to 1.45 times and fades out as `elevation` grows to `maxElevation`; it
  returns `null` (adds nothing) when the shadow would be invisible.
- `setDecal(index, ...)` changes a decal in place, `removeAtSwapLast(index)` removes one in
  constant time (the last decal takes its index), `clear()` removes all. The batch's own transform
  moves all its decals.

```dart
final marks = DecalBatch3D(
  material: DecalMaterial(texture: atlas, softness: 0),
);
final index = marks.addFlatDecal(
  center: Vector3(1, 0, 1),
  angle: math.pi / 4,
  uvRect: const Rect.fromLTWH(0.5, 0, 0.5, 0.5), // a quarter of the atlas
);
marks.setDecal(index, color: const Color(0x80FFFFFF));
```

| Parameter     | Default             | Meaning                                                   |
| ------------- | ------------------- | --------------------------------------------------------- |
| `texture`     | none                | atlas; without one, a procedural disc or ring             |
| `albedoColor` | white               | times each decal's color                                  |
| `depthBias`   | `0.0005`            | clip-space push towards the camera                        |
| `softness`    | `0.15`              | feather of the disc edge, also a round vignette on images |
| `innerRadius` | `0` (filled disc)   | inner radius of a ring, `0..1`                            |
| `alphaCutoff` | `0.001`             | fragments below are discarded                             |
| `renderState` | premultiplied blend | constructor parameter                                     |

Set `softness: 0` for textured decals: with the default, every texture is cut to a feathered disc.
A decal is a flat quad, not a projection: it does not wrap over uneven ground, and `depthBias`
must be large enough for the distance and depth precision of the camera. Decals are unlit and not
fogged, never cast shadows, do not batch with other batches, and are not available on the web
(creating a `DecalMaterial` throws an `UnsupportedError`). For decals projected onto terrain, see
`VolumeDecalBatch3D` in [Large Worlds](world_scale.md).


## Skybox

`SkyboxComponent3D` fills the background of a `World3D` with a sky: a gradient from `zenithColor`
through `horizonColor` to `groundColor` with a sun disc and halo, or an equirectangular
panorama. It draws one full-screen quad at the far plane, depth tested (`lessEqual`) without depth
writes, so it shows only where nothing else was drawn:

```dart
world.add(
  SkyboxComponent3D(
    material: SkyboxMaterial3D(
      zenithColor: const Color(0xFF14365E),
      sunDirection: Vector3(-0.5, -0.8, -0.3), // as the sun light's
    ),
  ),
);
final night = SkyboxMaterial3D(panoramaTexture: panorama, exposure: 0.6);
```

| Parameter                  | Default                | Meaning                           |
| -------------------------- | ---------------------- | --------------------------------- |
| `zenithColor`              | `0xFF0F2952`           | sky above                         |
| `horizonColor`             | `0xFF5BA4CF`           | sky at the horizon                |
| `groundColor`              | `0xFF1E293B`           | below the horizon                 |
| `horizonExponent`          | `0.55`                 | how fast the horizon color fades  |
| `sunColor`, `sunIntensity` | `0xFFFFF3C4`, `1.25`   | sun disc and halo                 |
| `sunDirection`             | `(-0.45, -0.65, -0.6)` | the way sunlight travels          |
| `sunAngularRadius`         | `0.045`                | disc radius in radians            |
| `sunHaloStrength`          | `0.35`                 | halo around the disc              |
| `exposure`                 | `1`                    | multiplies the color              |
| `upAxis`                   | `(0, 1, 0)`            | up of the gradient                |
| `panoramaTexture`          | none                   | 2:1 equirectangular, replaces all |

The sky does not light the scene: for reflections that match it, give `SpatialMaterial`s an
`EnvironmentProbe3D.skyDome` with the same colors (see
[Lighting](lighting.md#environment-probes)). The sky is not fogged, and its output is clamped to
`[0, 1]`, so a bright sun does not bloom with `World3D.hdrEnabled`. A panorama is always mapped
with `+Y` up, whatever `upAxis`. In a `Scene3DComponent` the sky covers the whole layer, hiding the
2D content below it.


## Atmospheric fog

Assigning `World3D.fog` blends surfaces towards `FogSettings.color` with their distance from the
camera, optionally thinned with their height:

```dart
world.fog = FogSettings(
  color: const Color(0xFF9AB4D2),
  start: 12,
  end: 48,
  heightFalloff: 0.6, // thinner above baseHeight (0 by default)
);
```

| Parameter       | Default      | Meaning                                                |
| --------------- | ------------ | ------------------------------------------------------ |
| `color`         | `0xFFB8C8DC` | fog color; its alpha scales the amount                 |
| `start`, `end`  | `10`, `60`   | linear fog from `0` at `start` to full at `end`        |
| `density`       | `0`          | above `0`: exponential fog from `start`, `end` ignored |
| `heightFalloff` | `0` (off)    | thinning rate above `baseHeight`                       |
| `baseHeight`    | `0`          | height along `up` below which the height factor is `1` |
| `maxOpacity`    | `1`          | the largest amount of fog                              |
| `up`            | `(0, 1, 0)`  | up axis for the height, copied in the constructor      |

The amount of fog at a fragment is

```text
d        = distance to the camera (perspective)
           or eye-space depth (orthographic and affine projections)
distance = density > 0 ? 1 - exp(-density * max(0, d - start))
                       : clamp((d - start) / (end - start), 0, 1)
height   = heightFalloff > 0
           ? exp(-heightFalloff * max(0, dot(position, up) - baseHeight))
           : 1
amount   = clamp(distance * height, 0, 1) * maxOpacity * color.a
```

The height factor multiplies the distance factor: low areas are as foggy as their distance allows,
higher ones less, but nothing near the camera is fogged. `World3D.fog = null` (the default)
disables fog.

```dart
world.fog = FogSettings(
  color: const Color(0xFFC8D8E8),
  start: 5,
  density: 0.04, // 1 - exp(-0.04 * (distance - 5)); end is ignored
  maxOpacity: 0.85, // distant shapes stay faintly visible
);
```

`SpatialMaterial`, `StylizedMaterial`, `WaterMaterial` and `BillboardMaterial3D` apply the fog;
`UnlitMaterial`, decals, outlines, particles, ribbons and the skybox do not, so they stand out in
distant fog. Fog costs no extra pass: it is a few instructions per fragment of the materials that
apply it. Setting `World3D.fog` to a new object marks the scene changed; changing the fields of the
current `FogSettings` does not, which matters for a `Scene3DComponent` with
`Scene3DCacheMode.retained` (see [Lighting](lighting.md#changing-lights-at-run-time)). How fog
combines with lighting and HDR is described in [Lighting](lighting.md#fog-and-lighting).


## Textures


### Creating textures

A `Texture` is uploaded from its pixels the first time it is used:

- `Texture(pixels, width:, height:, format:, colorSpace:, sampler:, mipmaps:)` takes tightly packed
  rows of pixels in `PixelFormat.rgba8888` (the default), `bgra8888` or `rgbaFloat32`.
- `ColorTexture(color)` is a single color (1x1 by default). `Texture.standard` (white) and
  `Texture.empty` (transparent) are shared ones.
- `ImageTexture.create(image)` and `Images.loadTexture(path)` make a texture of a `dart:ui` image.
  On Flutter GPU, an image backed by a GPU texture (decoded images, those of `Picture.toImage`)
  is shared without copying; otherwise, and when mipmaps are asked for, its pixels are read back
  with `Image.toByteData` and uploaded.
- `Ktx2TextureLoader.load(bytes)` loads a KTX 2.0 file, see
  [Compressed textures](#compressed-textures-ktx2).
- `Texture(null, width:, height:, gpuTexture: ...)` wraps a texture already on the GPU, for
  example to sample one texture with two samplers.

```dart
final tiles = Texture(
  pixels,
  width: 256,
  height: 256,
  colorSpace: TextureColorSpace.srgb, // decoded to linear when sampled
  mipmaps: true,
  sampler: TextureSampler.anisotropic8x.copyWith(
    wrapU: TextureWrap.repeat,
    wrapV: TextureWrap.repeat,
  ),
);

final fromImage = await ImageTexture.create(
  image,
  sampler: TextureSampler.linear,
);
final loaded = await images.loadTexture('crate.png');

final compressed = Ktx2TextureLoader.load(ktx2Bytes);

// Two samplers for one GPU texture.
final crisp = Texture(
  null,
  width: tiles.width,
  height: tiles.height,
  gpuTexture: tiles.resource, // with the default, nearest sampler
);
```

Textures created from pixels live in host-visible GPU memory: `width * height * 4` bytes for
8-bit formats, 16 bytes per pixel for `rgbaFloat32`, plus a third for mipmaps.


### Sampling and anisotropy

How a texture is sampled is its `sampler`, a `TextureSampler` value that may be changed at any
time:

- `minFilter`, `magFilter` and `mipFilter`: `TextureFilter.nearest` (the default) or
  `TextureFilter.linear`, where the texture is drawn smaller, larger, and between mip levels.
- `wrapU` and `wrapV`: `TextureWrap.clamp` (the default), `TextureWrap.repeat` or
  `TextureWrap.mirror`, for coordinates outside `[0, 1]`.
- `maxAnisotropy`: `1` (off, the default) to `16`, the number of samples taken along the direction
  in which a texture seen at a grazing angle is squeezed. It is clamped to
  `GpuBackend.instance.maxSamplerAnisotropy` (what the device supports, `1` without anisotropic
  filtering), and above `1` it forces every filter to linear.

`TextureSampler.linear` filters linearly (trilinear with mipmaps), `TextureSampler.anisotropic4x`,
`anisotropic8x` and `anisotropic16x` add anisotropy, all with clamped coordinates;
`TextureSampler.all(filter: ..., wrap: ..., maxAnisotropy: ...)` sets every option at once, and
`copyWith` changes some. The backends create one sampler object per distinct value. Anisotropy
sharpens floors and roads seen at a low angle, at the price of more texture reads per pixel.


### Mipmaps

With `mipmaps: true`, a texture builds its mip levels on the CPU when it is uploaded (each level
averages 2x2 pixels of the previous one, channel by channel, which is right for premultiplied
alpha) and uploads them, so that it does not shimmer when drawn small. Use a sampler with linear
`minFilter` and `mipFilter` to blend them. Flutter GPU cannot generate mip levels itself, and
devices that cannot sample mip levels uploaded by hand (some OpenGL ES devices, where they would
sample black) get the full-size level only. Building them costs CPU time once, about a third more
memory, and for `ImageTexture` a read-back of the image instead of sharing it.


### Color space

The engine uses colors and texels as it reads them: it does not decode sRGB, except for textures
whose GPU format is an sRGB one, which the GPU decodes to linear when sampling. Such textures are:

- `Texture(..., colorSpace: TextureColorSpace.srgb)` with `rgba8888` or `bgra8888` pixels, when
  the device supports the sRGB format;
- KTX2 files in an sRGB format, compressed or not, whether uploaded as they are or decoded on the
  CPU (see below);
- the reflection texture of an `EnvironmentProbe3D` made from an sRGB panorama (see
  [Lighting](lighting.md#environment-probes)).

`ImageTexture`, `Images.loadTexture`, glTF textures and `Color` values (`albedoColor`, vertex and
instance colors) are not decoded. `SpatialMaterial` encodes its output with a gamma of 2.2 when
HDR is off, so sRGB pictures used as plain textures look lighter and flatter than in a physically
correct renderer; data maps (normal, metallic-roughness, occlusion) must stay linear.
`StylizedMaterial` and `UnlitMaterial` output the colors they compute without encoding, so for them
undecoded sRGB colors are what you want.


### Compressed textures (KTX2)

`Ktx2TextureLoader.load(bytes, sampler: TextureSampler.linear)` parses a KTX 2.0 container and
returns a texture that is uploaded on first use:

- Formats: RGBA8 and BGRA8 (linear and sRGB), RGBA16F, RGBA32F, BC1, BC3, BC7, ETC2 RGB8 and RGBA8,
  ASTC 4x4 and 8x8 (each linear or sRGB). Other formats throw a `FormatException`.
- Supercompressed containers (Basis Universal, Zstandard) throw an `UnsupportedError`: only
  `supercompressionScheme` 0 is read.
- When the GPU supports the format and the size is a multiple of the block size, the blocks are
  uploaded as they are, with the file's mip levels (no more than the device can sample).
- Otherwise the texture is decoded on the CPU to RGBA8: BC1, BC3 and BGRA8 decode, RGBA16F is
  clamped to `[0, 1]` (losing its HDR range). BC7, ETC2, ASTC and RGBA32F have no CPU decoder and
  throw an `UnsupportedError` on devices that do not support them, which on the web is always the
  case for the compressed formats.
- `Ktx2TextureLoader.encodeUncompressedRgba8` and `encodeBc1` write KTX2 files (`encodeBc1`
  compresses on the CPU), and `parse` reads the header and levels without uploading.

Which compressed formats a device supports depends on its GPU (BC on desktop GPUs, ETC2 and ASTC on
most phones); `GpuBackend.instance.supportsPixelFormat` tells. sRGB files keep their color space on
both paths: their blocks are uploaded in the sRGB variant of their format
(`GpuPixelFormat.bc1RgbaSrgb`, `bc3RgbaSrgb`, `bc7RgbaSrgb`, `etc2Rgb8Srgb`, `etc2Rgba8Srgb`,
`astc4x4Srgb`, `astc8x8Srgb`), and decoded files go to an `rgba8888Srgb` texture, so a file looks
the same on every device.


### Color lookup tables

`ColorLut3D` is a 3D color-grading table stored as a `(size * size) x size` RGBA8 strip texture
(`textureFor(backend)`, linearly filtered), made with `ColorLut3D.identity`, `fromFunction`,
`fromStripBytes` or the `warmCinematic`, `coolNight` and `sepia` presets. It is used by
`PostProcessSettings.colorLut`, see [Post-Processing](post_processing.md).


## Custom shaders

A material is a vertex shader, a fragment shader, the slots they read and an `apply` that writes the
material's values:

```dart
class TintMaterial extends Material {
  TintMaterial()
    : super(
        vertexShader: VertexShader.fromAsset(
          'assets/shaders/tint.shaderbundle',
          slots: [RenderContext3D.cameraMatricesBlock],
        ),
        fragmentShader: FragmentShader.fromAsset(
          'assets/shaders/tint.shaderbundle',
          slots: [
            'Tint',
            RenderContext3D.ambientLightBlock,
            RenderContext3D.directionalLightsBlock,
            RenderContext3D.fogBlock,
          ],
        ),
      );

  Color tint = const Color(0xFFFFFFFF);

  @override
  void apply(RenderContext context) {
    fragmentShader.setColor('Tint.color', tint);
  }
}
```

The `RenderContext3D` fills these blocks and textures once per render pass for every shader that
lists them; everything else in the slots is the material's to write in `apply`:

| Slot                   | Chunk           | Holds                                      |
| ---------------------- | --------------- | ------------------------------------------ |
| `CameraMatrices`       | `camera.glsl`   | `view`, `projection`, `viewProjection`     |
| `Camera`               |                 | `position` and any `CameraMatrices` member |
| `AmbientLight`         | `lights.glsl`   | `color`, `intensity`                       |
| `HemisphereLight`      | `lights.glsl`   | sky and ground colors, `up`, `intensity`   |
| `DirectionalLights`    | `lights.glsl`   | up to 4 directional lights                 |
| `Lights`               | `lights.glsl`   | up to 8 point lights                       |
| `SpotLights`           | `lights.glsl`   | up to 4 spot lights                        |
| `Fog`                  | `fog.glsl`      | the fog of the pass, read by `applyFog`    |
| `Shadows`, `shadowMap` | `shadows.glsl`  | the shadow map, read by `shadowVisibility` |
| `ShadowAtlas`          |                 | the multi-light shadow atlas               |
| `JointMatrices`        | `skinning.glsl` | 64 joint matrices, per skinned draw        |
| `brdfLutTexture`       |                 | the split-sum BRDF table                   |
| `probeGridTexture`     |                 | the light probe grid                       |
| `DepthNormal`          |                 | the depth and normal prepass               |
| `depthNormalTexture`   |                 | its texture                                |
| `SceneColor`           |                 | the grab pass of the opaque scene          |
| `sceneColorTexture`    |                 | its texture                                |

Slots without a chunk must be declared by the shader itself, with the layout of the built-in
shaders (`spatial_material_pbr_fragment.glsl`, `water_material.frag`).

The members of the light blocks are listed in [Lighting](lighting.md#light-uniform-blocks); shadows
in [Shadows](shadows.md#receiving-shadows). Register blocks and textures of your own that every
shader of a pass shares with `RenderContext3D.registerPassUniform` and `registerPassTexture`.

- A vertex shader that includes `flame_3d/instancing.glsl` and calls `instanceModelMatrix()` is
  drawn instanced: `apply` runs once per batch, not per object, so a material cannot set per-object
  values in `apply`; use the instance color and data instead (see
  [Rendering](rendering.md#per-instance-color-and-data)).
- A material can draw several vertex layouts by overriding `Material.vertexShaderFor` to return a
  vertex shader variant per layout, all feeding the same fragment shader; `StylizedMaterial` does so
  for its skinned layout and the standard layout, `SpatialMaterial` for surfaces with tangents.
- `castsShadows` decides whether its surfaces are drawn into shadow maps (opaque materials by
  default); the shadow casters use their own shaders, so a custom vertex shader's displacement does
  not move the shadow.

Shaders are compiled into `.shaderbundle` files with `impellerc` (see
[Rendering](rendering.md#shaders)); bundles declared as assets are loaded by
`GpuBackend.initialize()`.


## Web

On the web, the materials run on WebGPU through hand-written WGSL versions of their shaders
(`.wgslbundle` assets):

- `SpatialMaterial` uses a WGSL version of the older spatial shader: the maps (with the per-pixel
  tangent frame), environment texture and probe SH9, every kind of light, fog, alpha cutoff and
  dither fade. Clearcoat, transmission, lightmaps, the split-sum BRDF table, reflection probe
  volumes, light probe grids, MikkTSpace tangents and HDR output are native only. Shadows are not
  rendered on the web.
- `UnlitMaterial`, `SkyboxMaterial3D` and `BillboardMaterial3D` have WGSL shaders.
- `StylizedMaterial`, `OutlineMaterial`, `DecalMaterial` and `ShadowCatcherMaterial` throw an
  `UnsupportedError` when created there (WGSL files exist for the outline and decal shaders but
  are not used). `WaterMaterial` has no WGSL shaders and fails when first drawn.
- Compressed KTX2 textures are always decoded on the CPU, so BC7, ETC2 and ASTC files throw.

The texture sampler options, including anisotropy up to 16, work on the web.


## Limitations

- HDR is only right for `SpatialMaterial` on native backends (see
  [Choosing a material](#choosing-a-material)): with `World3D.hdrEnabled`, every other material is
  tone-mapped and sRGB-encoded twice, a `0x80` gray showing 206 of 255 instead of 128.
- Translucent draws with `OitMode3D.weightedBlended` are drawn with a generic shader that keeps
  only the albedo color and texture of `SpatialMaterial` and `UnlitMaterial` and the shallow color
  of `WaterMaterial`; every other material is drawn as white at 50 % opacity, and surfaces without
  `vertexTexCoord` or `vertexColor` (`StylizedMaterial`'s own layout, decals) are not drawn at
  all. A packed accent index in `instanceData.w` is read there as a full fade.
- `StylizedMaterial` and `WaterMaterial` read only the single-light `Shadows` block. When the
  multi-light shadow atlas is in use (3 or 4 cascades, a shadowed point light, or two or more
  lights with shadows), that block describes the last cascade while the bound shadow map is the
  whole atlas, and their shadows land in the wrong places: in a test scene, a cube's shadow on a
  stylized floor covered 59 pixels with 1 or 2 cascades and 2,397 with 4, and 1,297 when a second
  light had shadows, where `SpatialMaterial` showed 59 in every case. Keep to one shadow-casting
  directional light with at most 2 cascades in scenes with these materials.
- Shadow casters ignore alpha: `alphaCutoff` cutouts cast the shadow of their whole quad, and
  objects faded with `instanceData.w` or `ditherFade` cast their full shadow.
- `SpatialMaterial`: the default `metallic` is `0.8`; `uvScale` and `uvOffset` are applied to every
  map but not to the lightmap, and there is no UV rotation.
- `StylizedMaterial` is display-referred and clamped to `[0, 1]`; it has no textures besides its
  MatCaps, and no image-based lighting.
- `WaterMaterial` reflects a flat sky color and needs a subdivided mesh.
- `DecalBatch3D` is sorted among the translucent draws as if it were at the world origin, so it
  can be drawn in the wrong order against other translucent objects. Textured decals are
  multiplied by their alpha a second time, which darkens the soft edges of premultiplied images.
- Straight-alpha blending of premultiplied textures: translucent `SpatialMaterial` and
  `BillboardMaterial3D` (and so `Text3DComponent`) blend with straight alpha while textures made
  from Flutter images are premultiplied, which darkens their soft edges.
- `UnlitMaterial`'s dartdoc says its translucent draws are never batched; consecutive translucent
  draws of one surface are batched, like every material's.
- KTX2: no supercompression, and no CPU decoder for BC7, ETC2, ASTC and RGBA32F.
- `ImageTexture` has no color space option: images cannot be sampled as sRGB.
