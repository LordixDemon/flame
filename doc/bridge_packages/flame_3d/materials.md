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
| `StylizedMaterial`      | vertex-colored low-poly art            | yes | yes     | yes | no  |
| `UnlitMaterial`         | self-lit surfaces, pictures, UI        | no  | no      | no  | yes |
| `WaterMaterial`         | animated water                         | yes | yes     | yes | no  |
| `OutlineMaterial`       | silhouette contours                    | no  | no      | no  | no  |
| `DecalMaterial`         | rings, markers, blob shadows           | no  | no      | no  | no  |
| `SkyboxMaterial3D`      | the sky behind everything              | no  | no      | no  | yes |
| `BillboardMaterial3D`   | sprites and standees                   | yes | no      | yes | yes |
| `ShadowCatcherMaterial` | shadows on 2D art                      | no  | yes     | no  | no  |
| `BarrierMaterial`       | energy walls around a play area        | no  | no      | no  | no  |

`BillboardMaterial3D` is described in [3D UI and Text](ui_3d.md#the-material),
`ShadowCatcherMaterial` in
[Shadows](shadows.md#shadows-on-2d-art), `ParticleMaterial` and `RibbonMaterial3D` in
[Particles and Ribbons](particles.md).

- Use `SpatialMaterial` for anything that has textures or comes from a glTF file, and for metals,
  car paint and glass. It is the only material that uses image-based lighting, reflection probes,
  light probe grids and lightmaps, and that keeps light brighter than white under HDR (see
  [Lighting](lighting.md)).
- Use `StylizedMaterial` for flat-shaded or vertex-colored low-poly art: it has no textures, a soft
  look by default, per-vertex masks for tints, accents, glow and gloss, and wind. It is cheaper to
  bind than `SpatialMaterial` and does not depend on physically based light intensities.
- Use `UnlitMaterial` where lighting would get in the way: pictures, labels, emissive signs,
  debug geometry.

"Shadows" says whether the material receives shadows: the materials marked "yes" read every
shadow the pass renders (the sun and its cascades, and spot and point lights with shadows) through
`flame_3d/shadows.glsl`, also when they are packed into the shadow atlas (see
[Shadows](shadows.md#receiving-shadows)). "Web" says whether the material has WebGPU shaders and
runs in a browser; see [Web](#web).

Every material works with `World3D.hdrEnabled`: the HDR scene target holds sRGB-encoded colors
with the range extended above `1`. The native `SpatialMaterial` shader writes its lighting there
without its tone curve, so light brighter than white survives for bloom and the tone map; every
other material (`StylizedMaterial`, `UnlitMaterial`, `WaterMaterial`, `SkyboxMaterial3D`,
`DecalMaterial`, `OutlineMaterial`, `BillboardMaterial3D`, `BarrierMaterial`, and the particle and
ribbon materials)
writes the display colors it writes without HDR, which look the same until the composite's tone
map changes them (with `ToneMapMode.none` and an exposure of `1`, exactly the same). See
[Post-Processing](post_processing.md#hdr).

With `World3D.oitMode` set to `OitMode3D.weightedBlended`, every alpha-blended translucent draw is
drawn with its own material, unsorted, and blended with the others by a weighted average (see
[Rendering](rendering.md#order-independent-transparency)): lighting, fog, skinning, accents, rims
and fades look as they do when sorted.

Vertices built from `Vertex` objects, the built-in meshes and parsed models have white vertex
colors, so the vertex color only changes the look of meshes that set it. Every built-in material
multiplies its base color by the per-instance color (`MeshComponent.color`).


## What a draw binds

When a batch is submitted, the `RenderContext3D` binds the material (calling its `apply` once for
the whole instanced batch), then the blocks and textures the shaders list in their slots. Blocks
filled per render pass (camera, lights, fog, shadows) are written once per pass and rebound when the
pipeline changes; joint matrices are written for every skinned draw.

- `SpatialMaterial` (native): vertex `CameraMatrices`, `JointMatrices`; fragment `Material`,
  `PassOptions`, `Shadows`, `Camera`, `Fog`, `AmbientLight`, `Lights`, `DirectionalLights`,
  `SpotLights`, `HemisphereLight` (10 blocks) and 11 textures: the six maps
  (albedo, normal, metallic-roughness, occlusion, emissive, environment), the lightmap,
  `brdfLutTexture`, `probeGridTexture`, `sceneColorTexture` and `shadowMap`. Maps that are not set
  are bound to a 1x1 white texture.
- `StylizedMaterial`: vertex `CameraMatrices`, `Wind` (and `JointMatrices` for skinned surfaces);
  fragment `Material`, `StylizedPass` (the camera, lights, shadows, fog and water volume of the
  pass in one block), `matCapTexture`, `gemMatCapTexture`, `shadowMap`: 7 bindings.
- `WaterMaterial`: vertex `CameraMatrices`, `WaterVertex`; fragment `WaterMaterial`,
  `StylizedPass`, `DepthNormal`, `SceneColor`, `shadowMap`, `depthNormalTexture`,
  `sceneColorTexture`. Surfaces in `WaterMaterial.vertexLayout` draw with a vertex stage of their
  own that binds the same blocks; the options of [Clear water](#clear-water-without-extra-passes)
  and [Ripples](#ripples) bind nothing more.
- `UnlitMaterial`: vertex `CameraMatrices`, `JointMatrices`; fragment `Material`, `albedoTexture`.
- `OutlineMaterial`: vertex `CameraMatrices`, `Outline` (and `JointMatrices` when skinned).
- `DecalMaterial`: vertex `CameraMatrices`, `Decal`; fragment `Decal`, `albedoTexture`.
- `SkyboxMaterial3D`: fragment `Skybox`, `panoramaTexture`.
- `BarrierMaterial`: vertex `CameraMatrices`, `BarrierShape`; fragment `BarrierLook`: 3 blocks, no
  texture, for both of its shader pairs (see [Barriers](#costs)).

`RenderStats` (see [Rendering](rendering.md#frame-output-and-statistics)) counts the material
changes of a frame.

Material values are read when the material is bound, so changing them shows on the next frame.


## Changes and versions

A material reports its own changes, so that retained layers, cached shadow maps and a game's idle
rendering follow them without marks from the game: every setter of a material raises its
`version` (and calls `Game.notifyVisualMutation()`) when it writes a value that differs from the
one held, and writing the value already held costs nothing. A world keeps the versions of the
materials its last render drew: a `Scene3DComponent` with `Scene3DCacheMode.retained` renders again
when one of them changed, and reuses its image while none did (see
[Embedding](embedding.md#retained-layer-caching) and
[Basic Concepts](basic_concepts.md#materials-report-their-changes)).

- Every field of every built-in material counts: colors, numbers, textures, enums, and the base
  fields `renderState`, `translucentOrder`, `depthPrepassGroup` and the shaders.
- What a material reads counts as its own: a `StylizedMaterial`'s `accentPalette` and `rimPalette`
  (lists that report their writes), a `WaterMaterial`'s `ripples` and `foamSources` (adding a
  ripple, moving a collar), a `BarrierMaterial`'s impacts, pulses and near points (`impact`,
  `pulse`, `setNearPoint`, writing the same near point again counts nothing), and the looks
  applied to it (`applyLook`, `applyLookLerp`, which change nothing when the look is already
  applied).
- The vectors of a material (`SpatialMaterial.uvScale` and `uvOffset`, `WaterMaterial.upAxis`, the
  wind vectors of `StylizedMaterial`, `ParticleMaterial.axis`, the sun and up of
  `SkyboxMaterial3D`) report changes made in place (`material.uvOffset.x += dt` scrolls the
  texture in a retained layer too); assigning a vector copies it into the material, so the
  vector given is not shared.
- The time of an animation (`WaterMaterial.time`, `StylizedMaterial.windTime`,
  `BarrierMaterial.time`) is a field like the others: writing it every frame is how a material
  says it animates, and the layers that draw it render every frame; leaving it alone holds it
  still and lets them keep their image. `RenderStats.animatedMaterials` counts the materials a
  render drew whose time advanced, `RenderStats.updatedMaterials` those whose other values
  changed, since the world drew them last.
- `Material.animated = true` declares a material that changes on every frame in ways its setters
  do not report, such as a subclass whose `apply` reads a clock of its own: while the last render
  of a world drew it, the world counts a change on every update, its layers render every frame
  and the game loop keeps rendering.
- `Material.markChanged()` reports a change the setters cannot see: new content in a texture the
  material shows, an `EnvironmentProbe3D` changed in place.

Material values move no shadow (the shadow passes draw positions with their own shaders): they
leave the cached shadow maps alone. `castsShadows` does move them, and so does a `renderState`
that changes whether a material casts while its `castsShadows` follows the render state (once a
pass has drawn the material), and a surface given a material that casts differently.

The cost: a setter compares its value; a render notes each material once when it binds it (never
per draw or per instance); reading `World3D.sceneVersion` adds the versions of the materials of the
last render (and of the palettes, ripples or foam sources they hold), one addition each. A material
being created changes no world: constructors set their render state with `setInitialState`.


## SpatialMaterial

`SpatialMaterial` is a metallic-roughness physically based material: Cook-Torrance specular (GGX
distribution, Smith-Schlick geometry, Schlick Fresnel) over a Lambert diffuse, the glTF 2.0 maps,
a clear-coat layer, refraction for glass, and image-based lighting. On native backends it uses the
`spatial_material_pbr` shaders; on the web an older shader without the extensions described below
(see [Web](#web)). On OpenGL ES devices where the full shader cannot run (it samples at explicit mip
levels, which needs `GL_EXT_shader_texture_lod`; the Android emulator lacks it) a new material uses
that older shader too, as on the web but with shadows, and prints that once; `usesSimpleShader`
tells which one a material uses (see
[What the device offers](getting_started.md#what-the-device-offers)).

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
  vertex tangents, through a second vertex shader variant; other surfaces use a tangent frame
  derived per pixel from screen-space derivatives, which works without tangents but shows seams on
  mirrored UVs. `Surface.computeTangents` adds tangents (and optionally the second UV channel) and
  switches the surface to `pbrStandard`; its tangents are not MikkTSpace ones (see
  [Geometry](geometry.md)):

```dart
// Adds tangents and a second UV channel to the surface: it now
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
- In a pass into the HDR scene target of a world with `World3D.hdrEnabled`, the shader skips its
  tone curve and writes the color sRGB-encoded with its range extended above `1`, then fogs it;
  the post-processing composite decodes it to linear light, adds bloom, tone-maps it (ACES by
  default) and encodes it to sRGB, see [Post-Processing](post_processing.md#hdr). Refraction
  decodes the grabbed scene color back to linear light first.

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
| `w`       | fade: the object's opacity is `1 - w`; or packed accent and rim indices       |

From `0` to `1`, the emissive boost also moves the color of the glowing vertices from their glow
color (`emissiveColor`, or a color of their instance, see [Glow colors](#glow-colors)) towards
`emissiveBoostColor` (by default the glow color itself).

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
                  * shadow
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
                 mix(glowColor, emissiveBoostColor ?? glowColor,
                     clamp(boost, 0, 1)),
                 glow), 0, 1)
out  = fog(mix(mix(luminosity(lit), lit, saturation), overlayColor.rgb,
               overlayColor.a))
alpha = albedoColor.a * vertex alpha * instance color alpha * (1 - fade)
```

Below the level of the world's water volume (`World3D.waterVolume`), the graded color is
submerged before it is fogged: tinted and darkened with its depth, lit by caustics, and foamed
where the surface crosses the level, see [Water volumes](#water-volumes).

`glowColor` is `emissiveColor`, or the color of the instance that `emissiveColorSource` picks (see
[Glow colors](#glow-colors)). `falloff` and `cone` are those of the point and spot lights (see
[Lighting](lighting.md#point-light)). `shadow` is `1`, except for each light that casts shadows,
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
render pass, chosen as [Lighting](lighting.md#how-many-lights-reach-a-shader) describes. It does not
use environment probes, reflection probes, light probe grids or lightmaps. It receives the shadows
of every light that casts them (the sun with its cascades, and spot and point lights), on the single
shadow map and on the shadow atlas alike (see [Shadows](shadows.md)). Without a `HemisphereLight` in
the scene, `ambientBase`, `skyFill` and `groundBounce` have no effect and only the ambient light
lights the shadowed side.

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
| `emissiveColorSource`                         | `emissiveColor`           | glow color source    |
| `emissiveBoostColor`                          | the glow color            | glow at boost 1      |
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
windows at dusk (both report themselves to a retained `Scene3DComponent`, see
[Changes and versions](#changes-and-versions)):

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
`0..15`. A `w` below `2` is a plain fade, as before; a `w` of `2` or more is decoded into the
palette index and the fade (values from `2` to `4`, which `packAccentAndFade` does not produce,
decode as a full fade). The vertex shader decodes it, where `w` is the exact value of the instance,
and hands the fragment shader the fade as a plain fade and the index as a whole number, so the
decoding is exact on every pixel (MSAA edges included), for every index and every packed fade, `0`
and `1` included: an instance drawn with a palette entry looks exactly like the same instance
drawn with a material of that one color and the packed fade. Packing rounds the fade to a multiple
of `1/16384` at most (finer for low indices): fades such as `0`, `0.25` or `1` are kept as they
are, others such as `0.3` can end up one step of 8-bit alpha away from the same plain fade, at
most. An index beyond the palette's length falls back to `accentColor`. The palette replaces
`accentColor` only on the vertices of the accent mask, so it does nothing on surfaces in the
standard layout (which have no accent mask: vary those with the instance color, which tints them
whole). It works the same for skinned surfaces in the stylized layout (each skinned draw picks its
own accent) and for translucent materials, where instances with different accents and fades still
share one draw call. The shadow pass and the depth-normal prepass do not read the instance data: a
packed accent leaves the shadow unchanged, and an object faded with `w` still casts its full
shadow if its material casts shadows.

`StylizedMaterial(translucent: true)` blends its premultiplied output over what is behind it
(`StylizedMaterial.translucentRenderState`: depth tested, without depth writes), and its draws are
sorted back to front after the opaque ones; objects then fade with the `w` of their instance data.
Consecutive translucent draws of one surface are still batched. Back-face culling
(`renderState = StylizedMaterial.translucentRenderState.copyWith(cullMode: CullMode.backFace)`)
keeps the inner faces of a closed mesh from showing through; `singlePieceTranslucent: true` writes
the depth of the whole object first instead, so that only its nearest surface is blended (see
[Rendering](rendering.md#render-state)). `ditherFade: true` fades opaque objects with a 4x4 Bayer
screen-door pattern instead, without sorting.

With `World3D.oitMode` set to `OitMode3D.weightedBlended`, translucent stylized draws are drawn
with this material too, unsorted (see [Rendering](rendering.md#order-independent-transparency)):
packed accents, rims and fades decode as when sorted, and their instances batch like opaque ones.
`singlePieceTranslucent` does not apply there.


### Rim highlight palette

Objects that differ only in a highlight state (hovered, selected, the color of their owner) can
keep one material and one instanced draw: give the material a `rimPalette` (up to
`StylizedMaterial.maxRimPaletteSize`, 8 colors; more are ignored) and pick an entry per instance
with `StylizedMaterial.packPaletteAndFade`, which packs it into `instanceData.w` together with an
accent index and a fade:

```dart
final pieces = StylizedMaterial(
  accentPalette: const [Color(0xFFE53935), Color(0xFF1E88E5)],
  rimPalette: const [
    Color(0xFFFFFFFF), // hovered: white
    Color(0xFFFFC107), // selected: amber
  ],
);
// A red piece, selected:
piece.instanceData.w = StylizedMaterial.packPaletteAndFade(accent: 0, rim: 1);
// The same piece, no longer selected:
piece.instanceData.w = StylizedMaterial.packPaletteAndFade(accent: 0);
```

The chosen entry adds `pow(1 - n·v, rimPalettePower) * color.rgb * color.a * rimPaletteStrength`
to the shaded color, on top of the material's own rim light (`rimStrength`, `rimColor`), before
the emissive glow and the color grade; the alpha of each color is its strength, and
`rimPaletteStrength` (`1`) scales them all past `1` when needed. `rimPalettePower` (`2`) is broader
than the default `rimPower` (`3`). The rim needs no mask: it shows on every vertex, also on
surfaces in the standard layout (glTF models), skinned or not, and it fades with the object.

`packPaletteAndFade(accent: a, rim: r, fade: f)` returns `(a' + 17 * r') * 4 + f`, with `a'` and
`r'` the indices plus one, or `0` for none; without a rim it equals
`packAccentAndFade(a, fade: f)`, without either it is `f`. It throws for indices outside the
palettes' ranges, and an index beyond the length of a palette selects nothing (the `accentColor`,
no rim). The rim index is decoded with the accent index, as exactly, and the fade is rounded the
same way (see [above](#batching-accent-palettes-and-translucency)). The shadow pass does not read
the instance data, so rims do not change shadows.


### Glow colors

The vertices of the emissive mask glow in `emissiveColor`, the same for every object of the
material. With `emissiveColorSource` they glow in a color of their own instance instead, so that
the instances of one mesh glow in different colors and still share one material and one instanced
draw:

| `emissiveColorSource`               | The glow color of an instance                      |
| ----------------------------------- | -------------------------------------------------- |
| `EmissiveColorSource.emissiveColor` | `emissiveColor` (the default)                      |
| `EmissiveColorSource.instanceColor` | its color, the tint of its tint mask               |
| `EmissiveColorSource.accent`        | its `accentPalette` entry, or `accentColor`        |
| `EmissiveColorSource.rim`           | its `rimPalette` entry's color, or `emissiveColor` |

The instance color is `MeshComponent.color`. An instance that picks no palette entry, or an index
beyond the palette's length, glows in the color after "or". The alpha of the instance color and of
a rim palette entry is not used: a rim entry's alpha is the strength of its rim, so an entry of
alpha `0` gives a glow color without a rim.

```dart
// Each piece's inlay (tint and emissive masks) glows in the piece's tint:
final pieces = StylizedMaterial(
  emissiveColorSource: EmissiveColorSource.instanceColor,
  emissiveStrength: 0.8,
);
final piece = MeshComponent(mesh: pieceMesh, color: ownerColor);

// A state color per instance, without rims, its strength per instance:
final fields = StylizedMaterial(
  emissiveColorSource: EmissiveColorSource.rim,
  emissiveStrength: 0, // the boost alone sets the strength
  rimPalette: const [
    Color(0x0040FF60), // reachable: green, alpha 0, no rim
    Color(0x00FF4040), // blocked: red
  ],
);
field.instanceData
  ..x = 0.35 // a pool of light: 35 % of the state color
  ..w = StylizedMaterial.packPaletteAndFade(rim: 0);
```

Only the color changes; the strength and the boost work as in [Shading](#shading). The glow mixes
the shaded color towards the glow color rather than adding light: where `glow` is `0.35` the
surface keeps 65 % of its lit color and takes 35 % of the glow color, a tinted pool of light rather
than a wash towards white, and where it is `1` the surface shows the glow color alone. With
`emissiveBoostColor` left `null`, each instance keeps its own glow color as its boost grows; set,
it is the color every instance moves towards.

An instance looks exactly like the same instance drawn with a material whose `emissiveColor` is its
glow color, on every pixel and MSAA sample: palette entries are picked by the exactly decoded
palette slot (see [above](#batching-accent-palettes-and-translucency)), and the vertex stage hands
the fragment stage the instance color in two parts that interpolation cannot blur, so that it gets
back the instance's exact color rather than one a few float steps off. It works in the stylized
layout, skinned or not, with every render state (opaque, `translucent`, `singlePieceTranslucent`,
`ditherFade`) and under weighted blended order-independent transparency. Surfaces in the standard
layout have no emissive mask, so they glow with no source. The accent source needs no accent mask:
a mesh without accent-masked vertices can use the accent palette as a palette of glow colors.

- The glow color is clamped to `[0, 1]` with the rest of the output (the material is
  display-referred, also under HDR): it blooms where the bloom threshold is below its brightness,
  exactly as the same `emissiveColor` would.
- The shadow pass and the depth-normal prepass do not read it: the glow does not change shadows,
  SSAO, soft particles or shore foam.
- Cost: three more floats passed from the vertex stage to the fragment stage for every stylized
  draw, whatever the source, and a few instructions per pixel with the instance color as source.
  The source is per material, so it batches like any other value of the material.


### Depth bias

`StylizedMaterial.depthBias` (`0` by default) draws its objects slightly in front of their
neighbours without moving them: every vertex's depth, in the `0..1` depth range of the picture, is
lowered by the bias (a clip-space bias: `z - depthBias * w`), so an object wins the depth test
against surfaces up to that much depth nearer the camera, and still covers the same pixels.
Negative values push objects behind. Use it to keep a marker, a highlighted piece or a decal-like
mesh from fighting with a coplanar or slightly nearer surface:

```dart
final selected = StylizedMaterial(depthBias: 0.002);
```

- The depth range is not linear in distance with a perspective camera: the same bias covers more
  distance far from the camera than near it. With an orthographic camera it is a fixed distance,
  the bias times the depth span of the projection (`far - near`).
- The shadow pass and the depth-normal prepass draw with their own shaders and ignore the bias:
  the object casts its shadow from where it is, and SSAO, soft particles and shore foam see its
  real depth. A translucent object's single-piece depth prepass uses the material's shader and is
  biased with it.
- It is per material: the four floats of the instance data are all taken (emissive boost,
  highlight, wind, fade and palettes), so objects that need a bias share a second material with
  it. It works for the stylized layout, skinned or not, and for the standard layout.
- An object biased in front of the camera's near plane is clipped there.

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

// Every frame (a retained layer renders again, see Changes and versions):
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
  skybox or an environment probe. It receives the shadows of every light that casts them (the sun
  and its cascades, spot lights and the point light), on the single map and on the atlas.
- Ripples perturb the normal in the plane perpendicular to `upAxis`, in the same frame as the
  waves, so the water looks the same in `+Y`-up and `+Z`-up worlds.
- Refraction: with `World3D.grabSceneColorEnabled`, the water shows the opaque scene below it,
  offset by the ripples (`refractionStrength`), and is written opaque. The grab pass and its cost
  are described in [Rendering](rendering.md#scene-color-grab-pass).
- Shore foam: with `shoreFoamDepth` above `0` and `World3D.depthPrepassEnabled`, the water foams
  and fades where the depth of the opaque scene behind it is within `shoreFoamDepth` (in clip-space
  depth, not world units) of its own, see
  [Post-Processing](post_processing.md#shoreline-foam) for the depth prepass.
- Crest foam: where the height of the waves, relative to their amplitude (`0` in the troughs, `1`
  on the highest crests) plus the micro-ripples, passes `foamThreshold`, whatever the amplitude. A
  `foamThreshold` of `1` or more turns it off.
- `opacity` below `1` draws the water blended (straight alpha, back faces culled) after the opaque
  draws; `1` or more draws it opaque. Setting `opacity` updates the render state, unless you set
  `renderState` yourself. Water never casts shadows.

It does not run on the web: there is no WebGPU version of its shaders.


### Clear water without extra passes

Shoreline foam needs the depth prepass and refraction the scene color grab, two passes a phone
pays for on every frame. The options below draw clear, shallow, living water with the surface as
one translucent draw and neither pass. All of them are off by default, and a material that leaves
them off draws exactly the pixels it drew before they existed.

```dart
final ripples = WaterRipples();
final water = WaterMaterial(
  shallowColor: const Color(0xFF86E3F0),
  deepColor: const Color(0xFF1B78B0),
  waveAmplitude: 0.012, // a calm basin
  rippleStrength: 0, // the swell below replaces the micro-ripples
  foamThreshold: 1, // no crest foam
  specularPower: 220,
  opacity: 0.8, // the opacity of deep water
  depthRange: 0.75, // shallow to deep over about 0.75 units
  shallowOpacity: 0.1,
  causticStrength: 0.25,
  causticScale: 0.62, // world units per cell
  sparkleStrength: 1.2,
  detailStrength: 0.6,
  detailScale: 1.1,
  animationPeriod: 4, // everything below loops every 4 s
  ripples: ripples,
);
```

| Parameter                      | Default      | Meaning                                  |
| ------------------------------ | ------------ | ---------------------------------------- |
| `causticStrength`              | `0` (off)    | the light network on the surface         |
| `causticScale`, `causticColor` | `0.6`, white | its cells' size (world units), color     |
| `sparkleStrength`              | `0` (off)    | tiny points flashing in the light        |
| `sparkleScale`                 | `0.35`       | one point per cell of this size          |
| `detailStrength`               | `0` (off)    | a swell of the normals                   |
| `detailScale`                  | `1.6`        | its longest wave, in world units         |
| `depthRange`                   | `0` (off)    | depth from shallow to deep (world units) |
| `shallowOpacity`               | `0.2`        | the opacity where there is no depth      |
| `defaultDepth`                 | `1`          | the depth under standard-layout vertices |
| `edgeFoamScale`                | `0.6`        | the patches of the foam mask's foam      |
| `edgeFoamMotion`               | `1`          | the pace of that foam, `0` still         |
| `foamLightTint`                | `1`          | how much of the light's color foam takes |
| `foamLightFloor`               | `0.5`        | the least light that foam takes          |
| `animationPeriod`              | `8`          | seconds over which the options loop      |
| `ripples`                      | none         | a shared `WaterRipples`, see below       |
| `foamSources`                  | none         | a shared `WaterFoamSources`, see below   |

- **Caustics**: the network of bright, wavy lines of light that a rippled surface focuses, added in
  `causticColor` times the light reaching the water (the directional, point and spot lights after
  their shadows, and a third of the sky). The lines are the borders of a Voronoi diagram of one
  swaying point per cell, in a domain warped by slow waves, so the cells keep changing shape; they
  repeat only every 64 cells, and are brighter where the cells are small. The network is computed
  from the world position of the rest surface, so it does not swim when the camera or a
  `Scene3DComponent`'s projection moves (mirrored projections included), nor with the waves. With
  `depthRange`, it shows at a quarter of its strength where the water has no depth, fully where it
  is deep, since the floor of shallow water shows its own caustics (see
  [Water volumes](#water-volumes)).
- **Sparkles**: one point per cell of `sparkleScale`, at its own place in the cell, flashes twice
  per period at its own moment, in the light reaching the water, brighter where the highlights of
  the lights are. Without light, no sparkle.
- **Swell**: six small waves of different directions and lengths, the longest `detailScale`
  long, tilt the normal (by up to about `0.3 * detailStrength` radians), so the highlights of the
  sun and of the lamps break up and move over the water. It moves the light only, not the
  vertices.
- **Depth ramp**: with `depthRange` above `0`, the water under each vertex is `depth` deep (see
  the layout below) and, with `k = 1 - exp(-depth / depthRange)`, its color is
  `mix(shallowColor, deepColor, k)` (lightened towards `shallowColor` on the crests) and its
  opacity `mix(shallowOpacity, opacity, k)`, raised towards `1` at grazing angles by the Fresnel
  term (`(1 - n·v)^fresnelPower` of the rest) and to the foam's opacity where it foams. Without
  `depthRange`, the color follows the height of the waves and the opacity is `opacity`, as before.
- **Foam mask**: vertices with a foam mask above `0` foam: a band whose inner edge, where the mask
  passes about `0.7`, laps in and out twice per period, with lacy holes and loose flecks in front
  of it, broken up into patches of about `edgeFoamScale` world units. Paint `1` against a wall or
  around a rock that breaks the surface, falling to `0` over a few tenths of a unit. It is lit by
  the light reaching the water, as the foam of the ripples and of the foam sources is (the crest
  and shore foam keep the plain `foamColor`).
- **Foam pace**: `edgeFoamMotion` multiplies the pace of the foam of the foam mask and of the foam
  sources: `1` laps twice per period, `0.5` half as fast, `0` holds the band still, broken up as
  before but not moving, for a rim of ice along a wall, dried salt or a painted edge. Its phase is
  `2π * fract(time * edgeFoamMotion / animationPeriod)`, so a slower band still loops without a
  jump (over `animationPeriod / edgeFoamMotion` seconds). The caustics, the sparkles, the swell
  and the ripples keep their pace. It belongs to the material: every foam of its surfaces moves
  alike, so a still band on one wall and lapping foam elsewhere take two surfaces with a material
  each (two draws).
- **Foam light**: the lit foam (of the foam mask, of the foam sources and of the ripples) is
  `foamColor` times `clamp(0.6 * sky + 0.75 * incoming, 0.5, 1.15)`, `incoming` being the light
  reaching the water. Under a low, colored sun that light takes the sun's color, and white foam
  turns orange or pink against blue water. Foam scatters every color alike, so `foamLightTint`
  says how much of the light's color it takes: before the clamp, the light is moved towards its
  luminance (Rec. 709 weights), `mix(vec3(luminance), light, foamLightTint)`: `1` (the default)
  keeps the light's color, `0` keeps only its brightness. About `0.25` suits a low, warm sun: the
  foam stays white with a trace of warmth, about as bright. The water volume's waterline has the
  same control, `WaterVolumeSettings.waterlineLightTint` (see [Water volumes](#water-volumes)).
- **Foam in low light**: `foamLightFloor` is the lower end of that clamp, the least light the lit
  foam takes as a multiple of `foamColor`: `clamp(light, foamLightFloor, max(1.15,
  foamLightFloor))`. The default, `0.5`, lets the foam fall to half its color when the light is
  low, so at dusk white foam turns grey and weak against lighter water. For dusk, raise it to about
  `0.85` with `foamLightTint` about `0.25` (and the waterline's `waterlineLightFloor` to about
  `0.7`): the foam stays bright and white, a little warm where the sun reaches it. Under brighter
  light (noon), the light is above the floor and nothing changes. Above about `1` the foam no longer
  darkens in shadow either. It costs one `max` per pixel where the foam is.
- **Light added over the water**: the caustics, the sparkles and the highlights of the ripples are
  added over the translucent surface with an opacity of their own (their luminosity), so they keep
  their brightness however clear the water is.

The caustics, the sparkles, the swell and the foam (at its own pace, `edgeFoamMotion`) move with
whole multiples of `2π * fract(time / animationPeriod)`: they loop exactly over the period, and
the time is wrapped on the CPU, so the shader's arguments stay small however long the game runs.
The Gerstner waves keep their own, endless time.

The depth and the foam mask come from the vertices. Surfaces in `WaterMaterial.vertexLayout`, 10
floats per vertex, give them:

| Attribute        | Floats | Meaning                                                       |
| ---------------- | ------ | ------------------------------------------------------------- |
| `vertexPosition` | 3      | the position                                                  |
| `vertexColor`    | 4      | multiplies the color and the opacity                          |
| `vertexWater`    | 3      | the depth (world units), the foam mask, the calm (`0` to `1`) |

The calm scales the waves down, from `0` (the full waves) to `1` (still), so the water stays flat
against a wall. Surfaces in the standard layout (`TerrainMesh3D`, the built-in meshes) are
`defaultDepth` deep everywhere, with no foam mask and the full waves. Build a surface in the water
layout with `WaterMaterial.buildSurface`, giving each vertex the depth of the floor under it:

```dart
final surface = WaterMaterial.buildSurface(
  positions: positions, // 3 floats per vertex, on the rest surface
  depths: depths, // the depth of the floor under each vertex
  foam: foam, // 1 along the walls, falling to 0 over 0.45 units
  calm: calm, // 0.85 at the walls
  indices: indices,
  material: water,
);
```

Advance `time` every frame (and the water volume's, see [Water volumes](#water-volumes)). Splashes,
mist and other translucent effects above the water should be drawn over it, whatever their
distance: give the water `translucentOrder = -1` (see
[Rendering](rendering.md#draws-are-recorded-then-sorted)), or a large surface, sorted by the middle
of its bounds, is drawn over the effects behind that middle.


### Ripples

A `WaterRipples` holds up to `WaterRipples.capacity` (8) ripple sources: the rings that something
landing on, rising out of, sinking into or moving through the water raises. Give one set to every
`WaterMaterial` of a body of water: each draws the rings over its own surfaces, so a ring crosses
from one surface to the next. A ripple starts at a time of the materials' clock, so the materials
sharing a set share their `time`:

```dart
// A pebble lands at `point`:
ripples.add(point, time: water.time, strength: 1.1, wavelength: 0.2);

// A slab rises out of the water: a ring that starts at its edge.
ripples.add(slab, time: water.time, radius: 0.42, lifetime: 1.6);
```

| Argument     | Default | Meaning                                               |
| ------------ | ------- | ----------------------------------------------------- |
| `strength`   | `1`     | the height of its waves                               |
| `speed`      | `0.9`   | how fast its front travels, world units per second    |
| `wavelength` | `0.22`  | the distance between its waves                        |
| `trail`      | `3`     | how many wavelengths its waves trail behind the front |
| `lifetime`   | `2.4`   | seconds until it is gone                              |
| `radius`     | `0`     | where its front starts (the size of the object)       |

A ripple's front is `radius + speed * age` from its center (the position projected onto the
surface along `upAxis`). Its waves rise sharply at the front, die out over `trail` wavelengths
behind it, and fade with the square of the fraction of `lifetime` left; for its first third of a
second, a splash of foam fills it. The rings tilt the normals (moving highlights), lighten the
water they raise towards `shallowColor`, add a highlight on their crests in the light reaching the
water, and foam where their crests are highest. They do not move the vertices.

Adding a ripple when the set is full replaces the weakest when it starts: one that is over, else
the one whose waves are the lowest (its strength times the square of the fraction of its life
left), so the faint rings of falling drops replace each other rather than the large ring of what
made the splash. `remove`, `clear`, `aliveAt` and `frontRadius` manage and query them. Adding,
clearing and drawing allocate nothing, and only the ripples alive at the material's `time` are
sent to the shader, packed first, so the cost per pixel follows the number of living ripples. The
rings are computed from the plane coordinates of the rest surface, like the caustics.

The splash presets of [Particles](particles.md#water-splashes) report each drop that falls back:
give that to the ripples, a faint, short ring per drop (at most one every few hundredths of a
second, so that the drops of one splash share the slots), and a splash leaves rings where its
drops land:

```dart
void dropRing(Vector3 position, double speed) => ripples.add(
  position,
  time: water.time,
  strength: 0.18,
  speed: 0.32,
  wavelength: 0.07,
  lifetime: 0.7,
);

final crown = ParticlePresets3D.splashCrown(up: up, onGroundHit: dropRing);
crown.burst(52, at: point); // where the pebble lands, with a ring of its own
```


### Foam sources

The foam mask is fixed when a surface is built: a wall gets its band, but a stone rising out of
the water, a slab sinking back or a crate drifting by gets none. A `WaterFoamSources` holds up to
its `capacity` of foam sources (8 by default, up to `WaterFoamSources.maxCapacity`, 16), collars
of the same foam (lapping and broken up at the pace of `edgeFoamMotion`, lit as `foamLightTint`
says) around a circle or a rectangle with rounded corners lying in the plane of the water, set and
moved at run time without rebuilding any surface. Give one set to every `WaterMaterial` of a body
of water, as the ripples:

```dart
final collars = WaterFoamSources(); // 8 sources, or WaterFoamSources(capacity: 16)
final water = WaterMaterial(foamSources: collars, ripples: ripples);

// A slab, 0.95 units square, under the water for now:
final slot = collars.addRectangle(
  slab.position,
  halfLength: 0.475,
  halfWidth: 0.475,
  cornerRadius: 0.04,
  width: 0.3,
  strength: 0,
);

// Every frame, while it rises through the surface:
collars
  ..move(slot, slab.position)
  ..setStrength(slot, wetness); // 0 under the water, 1 out of it
```

| Argument       | Default  | Meaning                                                        |
| -------------- | -------- | -------------------------------------------------------------- |
| `radius`       | required | `addCircle`: the circle's radius (`0` for a point)             |
| `halfLength`   | required | `addRectangle`: half its length along `axis`, corners included |
| `halfWidth`    | required | `addRectangle`: half its width across `axis`, corners included |
| `cornerRadius` | `0`      | the radius of its corners, at most the smaller half            |
| `axis`         | world x  | the world direction of its length, projected onto the plane    |
| `width`        | `0.3`    | how far from its outline its foam reaches, in world units      |
| `strength`     | `1`      | how solid that foam is, `0` hides the source                   |
| `carryPattern` | `false`  | whether the pattern of its foam moves and turns with it        |

The center is projected onto the plane of each material along its `upAxis`; an `axis` along the
up axis falls back to the first axis of the plane. Per pixel, a source's foam mask is `strength`
inside and against its outline, falling to `0` at `width` from it as
`1 - smoothstep(0, width, distance)`, and the surface draws the band of the largest of the masks of
its vertices and of the sources, so a collar merges with the band of a wall it comes close to. At
strength `1` the foam is solid against the outline, the band reaches about a third of the width
out and its flecks the whole width; below about `0.7` only flecks are left. Fade a collar in as
its object rises out of the water and out as it sinks, with `setStrength`; the ring of
`WaterRipples` and the volume's waterline on the object's own sides go well with it.

The pattern of a collar's foam, its patches, holes and flecks, stays in the world by default, as
the foam mask's does: a source that moves slides through it, and its foam seems to stream through
the collar. With `carryPattern: true` (or `setCarryPattern(slot, carry: true)`), the source draws
its foam in its own frame, along and across its `axis`, so the collar moves and turns with it, a
crate drifting by or a boat, still lapping at the pace of `edgeFoamMotion`. Each slot starts its
pattern at a place of its own, so two collars of one shape do not show the same foam (a source
keeps its slot in the shader). Where such a collar meets other foam, the band of a wall or another
collar, the larger of the two foams shows, without the two bands merging into one. A collar that
carries its pattern computes it per pixel where it reaches (13 sines), on top of the mask's own
pattern where both foam, and while one does the material draws with its full fragment stage (see
[What the options cost](#what-the-options-cost)).

`addCircle` and `addRectangle` take the first free slot and throw a `StateError` when all are
taken (a collar must not take the place of another one while its object is still there);
`setCircle` and `setRectangle` fill a given slot, `move` moves a source (and turns it with `axis`),
`setStrength`, `strengthOf`, `setCarryPattern`, `carriesPattern`, `isUsed`, `remove` and `clear`
manage them, and `version` changes with every change. Adding, moving and drawing allocate nothing;
the slots are sent to the shader up to the last source whose strength is above `0`, a free or
hidden slot before it costing the pixels within reach a comparison.

The cost follows where the collars are, not only how many there are: each vertex of the surface
finds, from the circles beyond which the sources have no foam, whether one may reach it, and the
pixels between vertices that say none does skip the sources altogether. The vertex stage passes
on `|q - c|² - r² - |q|²` minimised over the sources (`q` the vertex in the plane, `c` and `r` a
source's circle), which is linear in `q` for each source; interpolated across a triangle, that
minimum is never above its value at the pixel (it is concave), so the test `|q|² + it < 0` that
each pixel makes is conservative whatever the size of the triangles: the collars are drawn
exactly as without it, and a surface of a few large triangles only skips less. Within reach, a
pixel tests each source against the box around its foam before computing its outline.


### What the options cost

The options are arithmetic in the fragment shader of the surface: no pass, no texture, no
binding, and the surface stays one draw (instanced with the other draws of its mesh). Their CPU
cost is `Material.apply` writing a few more values: about 0.5 µs for the legacy material and 1 µs
with every option and 8 ripples (in `flutter test`, JIT).

Per pixel of the surface, roughly: the caustics 22 sines, cosines or square roots and 170
arithmetic instructions (the 9 cells of the Voronoi diagram), the sparkles 3 sines, the swell 6
cosines, each living ripple 3 transcendentals and 25 instructions, the foam mask (only where it or
a foam source is above `0`) 13 sines, the foam sources a dot product and a comparison where none
reaches and, where one may, about 10 instructions per source above `0` (its box) plus a square root
and about 15 more for those whose box the pixel is in (and 13 sines for each such source that
carries its pattern), `foamLightTint` below `1` a dot product and a mix where the foam is,
`foamLightFloor` nothing more than the clamp of before, and `edgeFoamMotion` nothing (its phase is
computed on the CPU). Per vertex, the foam sources add 3 instructions each. On the software
rasterizer of `flutter test`, a full-screen 2532 x 1170 surface with the caustics, sparkles,
swell and depth ramp costs about as much as the legacy material (within the noise, a few percent),
8 living ripples add about 30 %, foam mask over the whole surface about 4 %, and the foam sources
what the pixels they reach pay: 1 to 4 small collars stay within the noise, 4 large ones over a
fifth of the screen add about 4 %, 16 small ones over a fifth of it about 7 % (about 30 % before
the vertices told the pixels where none reaches) and 16 large ones over four fifths of it about
27 %. The full fragment stage costs about 3 % more over the whole surface, and 16 small collars
that carry their pattern about 15 %. Compare on your target device, where transcendentals cost
relatively more.

The shaders compile to GLSL ES 1.00 for OpenGL ES: they use no `flat` input, no derivative, no
explicit level of detail, no texture, and their loops have constant bounds (the ripples' loop runs
to 8 and stops at the number of living ripples). They need high precision in the fragment stage,
as every built-in material does (the compiled shaders declare their values `highp`); their
arguments stay small (the time is wrapped, the cells' values come from coordinates wrapped to 64),
so they also hold in 16-bit floats near the origin, except the patterns that collars carry, offset
by up to 35 units for their slot. The options add 36 uniform vectors to the lean fragment stage
(181 in all: 16 for the ripples, 16 for 8 slots of foam sources), within the 224 that OpenGL ES 3.0
guarantees. While the material's `foamSources` hold more than 8 sources (`capacity` above 8) or
one of them carries its pattern, it draws with its full stage: 16 slots that can carry their
pattern, 16 vectors more (197 in all) and a little more per pixel over the whole surface, collars
or not. It switches by itself when the set changes (the bundle of the masked vertex stage carries
the full stage, so no bundle is added). The sources' loops run to the number of slots and stop
after the last source above `0`. Their circles add 16 vectors to the vertex stage (19 in its
block, of the 256 guaranteed) and one `vec3` output. Like the rest of `WaterMaterial`, they do not
run on the web.


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
transformed by the inverse transpose of the model matrix (and of the skinning blend), so
non-uniformly scaled objects get outlines as thick on every side. The alpha of `color` darkens the
outline rather than making it see-through, since the material draws opaque; give it
`RenderState.premultipliedAlphaBlend` for a translucent one.


### Outlines for materials that move their vertices

`OutlineMaterial` extrudes the mesh as it is stored: an object whose own material moves its
vertices in the vertex shader (wind, waves, morphs) gets an outline of its rest shape. A custom
outline material can draw the matching hull with the chunk `flame_3d/outline.glsl`, the vertex
step `OutlineMaterial` itself uses:

- `vec3 outlineWorldNormal(mat4 model, vec3 normal)` turns a model-space normal into a unit
  world-space one with the inverse transpose of `model` (computed as its cofactor, so without an
  inverse, and turned outwards for mirroring transforms).
- `vec4 outlineExtrude(mat4 viewProjection, vec3 worldPos, vec3 worldNormal, float thickness, bool
  screenSpace, float aspect, float depthBias)` returns the clip position of `worldPos` pushed along
  `worldNormal` by `thickness` (world units, or with `screenSpace` a fraction of the viewport height
  with `aspect` the viewport's height over width), moved away from the camera by `depthBias` in
  clip depth.

Displace the vertex and its normal exactly as the object's material does (the normal by the
inverse transpose of the displacement's Jacobian), then extrude the result:

```glsl
#include <flame_3d/instancing.glsl>
#include <flame_3d/camera.glsl>
#include <flame_3d/outline.glsl>

void main() {
  vec3 p = vertexPosition + displacement(vertexPosition);
  vec3 n = displacedNormal(vertexPosition, vertexNormal);
  mat4 model = instanceModelMatrix();
  gl_Position = outlineExtrude(
    camera.viewProjection,
    (model * vec4(p, 1.0)).xyz,
    outlineWorldNormal(model, n),
    thickness, false, 1.0, 0.0005);
  fragColor = outlineColor;
}
```

Give the material `RenderState(cullMode: CullMode.frontFace)` and `castsShadows = false`, as
`OutlineMaterial` has.


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

| Parameter              | Default           | Meaning                                            |
| ---------------------- | ----------------- | -------------------------------------------------- |
| `texture`              | none              | atlas; without one, a procedural disc or ring      |
| `albedoColor`          | white             | times each decal's color                           |
| `depthBias`            | `0.0005`          | clip-space push towards the camera                 |
| `softness`             | `0.15`            | disc edge feather, also a round vignette on images |
| `innerRadius`          | `0` (filled disc) | inner radius of a ring, `0..1`                     |
| `alphaCutoff`          | `0.001`           | fragments below are discarded                      |
| `renderState`          | premultiplied     | constructor parameter (premultiplied alpha blend)  |
| `premultipliedTexture` | `false`           | the texture holds premultiplied colors             |

Set `softness: 0` for textured decals: with the default, every texture is cut to a feathered disc.
A decal is a flat quad, not a projection: it does not wrap over uneven ground, and `depthBias`
must be large enough for the distance and depth precision of the camera. Decals are unlit and not
fogged, never cast shadows, do not batch with other batches, and are not available on the web
(creating a `DecalMaterial` throws an `UnsupportedError`). For decals projected onto terrain, see
`VolumeDecalBatch3D` in [Large Worlds](world_scale.md).


### Atlases of premultiplied images

By default a decal takes its texture as straight colors and multiplies them by their alpha. The
images Flutter decodes, and atlases built by drawing them into a picture, hold premultiplied
colors: their translucent texels, and the texels that filtering and mipmaps blend between an opaque
and a transparent one, are then darkened a second time (a half transparent red texel,
`(128, 0, 0, 128)`, draws as `(64, 0, 0, 128)`). Set `premultipliedTexture: true` for such a
texture: the texel is scaled as a whole by the edge softness and the tint's alpha, then tinted by
its color, and keeps its color.

```dart
final marks = DecalBatch3D(
  material: DecalMaterial(
    texture: atlas, // built by drawing images into a picture
    premultipliedTexture: true,
    softness: 0,
  ),
);
```


### Overlapping decals

The decals of a batch are drawn in the order they were added, in one draw. Overlapping
translucent decals at different depths (soft shadow layers under marks, splats on top of each
other) blend correctly only when the farther ones come first. Set `sortByDepth` to draw them back
to front for the camera of each pass, whatever order they were added in:

```dart
final floor = DecalBatch3D(material: marksMaterial, sortByDepth: true);
```

The batch sorts the decals by the depth of their centers (the depth the render context sorts
translucent draws by), keeping the order of decals at the same depth, into a second instance buffer
of the batch's capacity. It sorts again only when the camera of the pass, a decal or the batch's
transform changed, in `O(n log n)` without allocating after the first sort; `sortCount` counts the
sorts. Without `sortByDepth` (the default), nothing is sorted and the decals keep their order.


## Barriers

`BarrierMaterial` draws a translucent energy wall that stands around an area while something is in
play inside it and lights up where it is hit: brightest at its foot and thin above by default, so
that it never hides what stands inside, with a slow pattern of motifs travelling along it, a glint
where it is seen edge-on, and impacts, each rings spreading over the wall from a point and a flash
around that point. Its height, its density and its reaction are each settings, and a
`BarrierLook` holds all of them as one value. `BarrierMesh` builds the walls it draws:

```dart
final barrier = BarrierMaterial.fromLook(BarrierLook.solidWall, appear: 0);
final wall = BarrierMesh.roundedRectangle(
  width: 5.4,
  depth: 5.4,
  height: 0.75,
  cornerRadius: 0.16,
  heightSegments: 8, // rows and columns for the wobble
  maxSegmentLength: 0.15,
  material: barrier,
);
barrier.fitPatternTo(wall.length, motifLength: 0.45);
final wallComponent = MeshComponent(mesh: wall, visible: false);
layer.world.add(wallComponent);

// Every frame (a retained layer renders again, see Changes and versions):
barrier.time += dt;

// When play starts: animate appear from 0 to 1 over about 0.35 s.
wallComponent.visible = true;
barrier.appear = raised; // 0..1

// While a ball flies towards the wall, it glows where the ball comes close:
barrier.setNearPoint(0, ballPosition);

// Where something hits it (a world position, from the physics contact):
barrier.impact(contactPoint, color: const Color(0xFF7FD4FF));

// When it lands, or on each beat of a countdown:
barrier.pulse();

// When play ends: animate appear back to 0, then hide the component.
```

Every setting added to the original material is off or neutral by default: a `BarrierMaterial()`
draws exactly the pixels it drew before they existed (a GPU test compares them with the shaders of
that time at a tolerance of 0).


### Wall meshes

The material draws any mesh whose vertices carry the distance along the wall in
`vertexTexCoord.x` (in scene units), the height up the wall in `vertexTexCoord.y` (`0` at its foot,
`1` at its top) and the wall's normal in `vertexNormal`, pointing out of the enclosed area. A
surface in the standard layout with such texture coordinates works too.

`BarrierMesh` builds one surface in its own 8-float layout (`BarrierMesh.layout`: position, those
texture coordinates and the normal), standing on the xz plane with its foot at `y = 0`, around the
origin:

- `BarrierMesh.roundedRectangle(width, depth, height, cornerRadius: 0, cornerSegments: 8,
  heightSegments: 1, maxSegmentLength: null)`: a band around a rectangle (along x and z) with
  rounded corners (sharp ones at a radius of `0`);
- `BarrierMesh.ring(radius, height, segments: 64, heightSegments: 1)`: a band around a circle;
- `BarrierMesh.dome(radius, segments: 64, rings: 16)`: the upper half of a sphere, the height
  running by elevation from its rim to its pole.

The distance along the foot runs counter-clockwise seen from above (from `+x` towards `-z`), from
`0` to `length`, starting at the middle of the `+x` side (the rectangle) or at `(radius, 0, 0)`;
the first and last columns of vertices are at the same place. Faces face outwards. By default a
rectangle with rounded corners is `2 * (5 + 4 * cornerSegments)` triangles, a ring `2 * segments`,
a dome `segments * (2 * rings - 1)`. The material shades every pixel from its interpolated
coordinates, so the walls need no more rows than these, except for the wobble: it moves vertices,
so a wall that wobbles needs `heightSegments` rows and columns `maxSegmentLength` apart (a fraction
of `wobbleWavelength`, say a fifth); neither changes `length`, the wall coordinates or
`pointOnWall`. Each band has at most 65,535 vertices.

Rotate the component to stand a wall in a scene whose up is not `+y` (a quarter turn about x for
`+z`). `pointOnWall(along, heightFraction, [out])` gives a point of the wall in the mesh's space,
by distance along its foot and height; transform it by the component's `worldTransformMatrix` for
`impact`. With a `heightScale` other than `1`, multiply the point's `y` by it.


### Height

| Parameter         | Default      | Meaning                                                |
| ----------------- | ------------ | ------------------------------------------------------ |
| `heightScale`     | `1`          | how tall the wall stands, a scale of the mesh's height |
| `heightFalloff`   | `1.8`        | the light is multiplied by `(1 - u) ^ heightFalloff`   |
| `fadeStart`       | `0`          | where the light starts to fade (`u = 0`), a fraction   |
| `fadeEnd`         | `1`          | where the light has faded out (`u = 1`), a fraction    |
| `footGlow`        | `0.7`        | a thin bright line along the foot                      |
| `topEdgeStrength` | `0` (none)   | a glowing line along the top, the upper boundary       |
| `topEdgeWidth`    | `0.04`       | its width, a fraction of the height                    |
| `topEdgeColor`    | `0xFFFFFFFF` | its color; the alpha scales it                         |
| `appear`          | `1`          | how far the wall has risen, `0` to `1`                 |
| `appearSoftness`  | `0.15`       | softness of the rising front, a fraction               |

- `heightScale` sets how tall the wall stands at run time, without rebuilding the mesh and
  independently of `appear`: the vertex stage scales the mesh along its own y axis about `y = 0`
  (the foot of a `BarrierMesh`), so `0.5` stands half as tall, `1.4` taller than built, and a game
  can raise, lower or breathe the wall every frame. The profile, the top edge and the motifs follow
  the wall's height (the motifs stretch with it); the impacts are world points and stay where they
  are.
- The light fades over `u`, running from `0` at `fadeStart` to `1` at `fadeEnd`: by default from
  the foot to the top, which with the falloff of `1.8` reads as a low glowing fence. A
  `heightFalloff` below `1` holds the light and drops it near the end of the fade, above `1` drops
  it soon and tails off. Past `fadeEnd` the light and the motifs are gone; the fill, the top edge
  and the reaction still show. A tall shield takes a late fade (`fadeStart: 0.4`, `fadeEnd: 1`,
  `heightFalloff: 0.8`), a fill and a top edge; a fence an early one (`fadeEnd: 0.5`).
- The top edge is a line of light at the top of the wall whatever the fade below it, thinned half
  as much as the rest of the wall on the near side, so that a closed wall keeps its outline.
- `appear` raises the wall from its foot: everything below a soft front at that fraction of the
  height is drawn, and the front glows while the wall rises or sinks (`0 < appear < 1`). At `0`, as
  at a `heightScale` of `0`, every vertex is moved out of view, so the wall costs its draw call but
  no pixels; set the component's `visible` to `false` as well to skip the draw.


### Density

| Parameter          | Default      | Meaning                                                     |
| ------------------ | ------------ | ----------------------------------------------------------- |
| `footColor`        | `0xFFFFB45A` | color at the foot; its alpha scales the light there         |
| `topColor`         | `0x4DFFF2D6` | color at the top; its alpha scales the light there          |
| `intensity`        | `0.8`        | multiplies all the light; above `1` goes above white        |
| `fillOpacity`      | `0` (none)   | a body covering what is behind the wall, `0` to `1`         |
| `fillColor`        | `0xFFFFB45A` | its color; the alpha scales the opacity                     |
| `fillFade`         | `0`          | how much the fill follows the fade, `0` even, `1` fully     |
| `noiseStrength`    | `0` (none)   | value noise breaking up the light, `1` from dark to double  |
| `noiseScale`       | `3`          | noise cells per scene unit                                  |
| `noiseSpeed`       | `0.3`        | how fast the noise rises, scene units per second            |
| `flickerStrength`  | `0` (none)   | how deep the whole wall's light flickers, `0` to `1`        |
| `flickerSpeed`     | `6`          | changes per second                                          |
| `nearSideFade`     | `0.7`        | how much the side whose outside faces the viewer is thinned |
| `farSideFade`      | `0`          | how much the side whose inside faces the viewer is thinned  |
| `sideFadeSoftness` | `0.45`       | the facing (a cosine) over which the sides thin             |
| `glintStrength`    | `0.35`       | glint where the wall is seen edge-on                        |
| `glintPower`       | `4`          | how close to the edges the glint stays                      |
| `preserveHue`      | `false`      | scale bright colors down instead of clipping them to white  |

- The foot color blends into the top color up the wall, both multiplied by the instance color
  (`MeshComponent.color`), whose alpha scales the light.
- The fill is a body of its own color whatever the pattern, from a faint veil to nearly opaque.
  With `RenderState.premultipliedAlphaBlend` or `alphaBlend` it covers what is behind the wall in
  proportion to its opacity (the output's alpha is the larger of the brightest channel and the
  fill's cover); with the default additive blending, which keeps what is behind, its color is only
  added. It is thinned on the near side like the rest of the wall, and the pulse raises it.
- The noise (two octaves of value noise along the wall and up it, in world units, rising at
  `noiseSpeed`) breaks up the light so that a dense wall is not flat; it leaves the fill alone, so
  that it opens no holes onto what is behind. On a closed loop (`fitPatternTo`) it repeats a whole
  number of times around it, like the pattern. The flicker multiplies the wall's light by `1 -
  flickerStrength * n`, `n` a smooth random value changing `flickerSpeed` times a second, computed
  on the CPU; the reaction does not flicker.
- `nearSideFade` thins the side of a closed wall whose outside faces the viewer, by up to
  `nearSideFade` where it faces the viewer squarely, so that it does not veil what stands inside,
  while the far side shows fully behind it. `farSideFade` thins the side whose inside faces the
  viewer: for a viewer inside the wall (a dome around the camera) set it instead of
  `nearSideFade`; with both, less of the far side shows through the near side. Both read the
  normals, which must point out of the enclosed area (as those of `BarrierMesh` do); the reaction
  is not thinned.
- `preserveHue` scales the wall's own light and fill down where their brightest channel passes
  `0.8`, so that they reach `1` smoothly instead of clipping channel by channel, which turns a
  bright warm or cold wall white. The reaction is added after it and may go above white. It keeps
  the wall at or below white in an HDR scene target too, so the wall does not bloom there.


### Pattern

| Parameter             | Default    | Meaning                                                  |
| --------------------- | ---------- | -------------------------------------------------------- |
| `pattern`             | `chevrons` | the motif, a `BarrierPattern`                            |
| `patternScale`        | `2.5`      | motifs per scene unit along the wall                     |
| `patternRows`         | `1`        | rows of motifs in the band, every other shifted by half  |
| `patternLineWidth`    | `1`        | thickness of the motifs' lines, a multiplier             |
| `patternHeight`       | `0.45`     | the top of the band the motifs fill, a fraction          |
| `patternStrength`     | `0.55`     | brightness of the motifs                                 |
| `patternColor`        | `null`     | their color; `null` for the foot color lightened a third |
| `patternSpeed`        | `0.3`      | scene units per second, negative the other way           |
| `patternRiseSpeed`    | `0`        | rows per second up the band, negative down               |
| `patternTwinkle`      | `0.25`     | how deeply the motifs twinkle, `0` steady to `1`         |
| `patternTwinkleSpeed` | `1.7`      | radians per second                                       |
| `patternLoopLength`   | `0` (open) | length of a closed loop, see below                       |

`BarrierPattern.plain` has no motif; `chevrons` point the way the pattern travels; `diamonds` are
outlines with a dot at their center; `dashes` are rune-like stems of varying length with a dot, a
caret or a bar, different from one motif to the next; `hexagons` are the outlines of a honeycomb,
one hexagon per motif and per row; `grid` is a cage, a bar up each motif and a rung across each
row's boundary. The motifs fill a band of the wall above the foot (`patternHeight`), in
`patternRows` rows, twinkle, and travel along the wall at `patternSpeed` and up it at
`patternRiseSpeed` (rising motifs fade in at the foot of the band and out at its top). They are
drawn in the cells of the wall's coordinates, `1 / patternScale` long and `patternHeight /
patternRows` of the wall's height tall, so their proportions follow those lengths. The density of
the pattern is how many motifs (`patternScale`, `patternRows`), how thick their lines
(`patternLineWidth`), how much of the wall they cover (`patternHeight`) and how bright they are
(`patternStrength`); the near points brighten the motifs around them.

On a closed loop the pattern has a seam where the loop closes unless a whole number of motifs fits
the loop: `fitPatternTo(loopLength, motifLength: 0.4)` sets `patternScale` to the nearest such
count and `patternLoopLength` to the loop's length (`BarrierMesh.length`), which also keeps the
motifs of `dashes` the same as they travel across the seam. On a wall that is not closed the motifs
repeat every 256 (`BarrierMaterial.openWallPeriod`).


### Impacts

| Parameter             | Default      | Meaning                                           |
| --------------------- | ------------ | ------------------------------------------------- |
| `impactColor`         | `0xFFFFFFFF` | the color of an impact given none                 |
| `impactSlots`         | `4`          | impacts shown at once, `1` to `8`                 |
| `impactDuration`      | `0.9`        | how long an impact lasts, seconds                 |
| `impactRingCount`     | `1`          | rings per impact, `1` to `4`, each `0.7` the last |
| `impactRingInterval`  | `0.15`       | seconds between an impact's rings                 |
| `impactRingSpeed`     | `2.5`        | scene units per second                            |
| `impactRingWidth`     | `0.07`       | scene units                                       |
| `impactRingStrength`  | `1`          | brightness of the rings                           |
| `impactRingReach`     | `0` (none)   | where the rings have faded out (from 60 % of it)  |
| `impactFlashRadius`   | `0.3`        | scene units                                       |
| `impactFlashStrength` | `0.8`        | brightness of the flash around the point          |
| `impactFlashDuration` | `1 / 3`      | the flash's length, a fraction of the duration    |
| `wobbleAmplitude`     | `0` (none)   | how far the surface moves, scene units            |
| `wobbleFrequency`     | `5`          | swings per second                                 |
| `wobbleWavelength`    | `0.6`        | distance between crests, scene units              |
| `wobbleDecay`         | `3`          | per second: amplitude times `exp(-decay * age)`   |
| `wobbleRadius`        | `1.5`        | distance where the wobble has fallen to `1 / e`   |
| `wobbleShading`       | `0.5`        | how much the wobble shades the light              |

`impact(position, color: impactColor, strength: 1)` starts an impact at the current `time`, at a
world position: rings of `color` spreading from it over the wall and a flash around it, both scaled
by `strength` (and by the color's alpha) and fading out over `impactDuration`. The distance is
measured in world space from the point, so the rings wrap around corners and over a dome. A
material shows `impactSlots` impacts at once (`maxImpacts`, 4, by default, up to
`maxImpactSlots`, 8): a new one takes a free slot, or replaces the oldest. It allocates nothing;
`activeImpactCount`, `isImpactActive` and `clearImpacts` read and reset them. Impacts are not moved
with the wall: a wall that moves while a ring spreads leaves it where it started.

The wobble moves the surface along its normal around each impact: a damped wave leaves the point
at `wobbleFrequency * wobbleWavelength` units per second, oscillates behind its front and dies out
with time (`wobbleDecay`), distance (`wobbleRadius`) and the impact's duration, so the wall stands
straight again when the impact is over. The vertex stage moves the vertices (the wall needs rows
and columns, see [Wall meshes](#wall-meshes)), tilts the normals so that the glint and the
near-side fade follow the waves, and passes the wobble on to shade the light. Raise
`impactRingStrength` and `impactFlashStrength` well above `1` for a reaction that reads on a small
screen.


### Pulse and near points

| Parameter               | Default      | Meaning                                               |
| ----------------------- | ------------ | ----------------------------------------------------- |
| `pulseColor`            | `0xFFFFFFFF` | the color of a pulse given none                       |
| `pulseStrength`         | `1`          | the strength of a pulse given none                    |
| `pulseDuration`         | `0.6`        | the length of a pulse given none, seconds             |
| `pulseAttack`           | `0.15`       | the share of a pulse spent lighting up                |
| `proximityColor`        | `0xFFFFFFFF` | the color of a near point given none                  |
| `proximityRadius`       | `0.6`        | distance at which a near point starts to light, units |
| `proximityStrength`     | `1`          | brightness of the near points' glow                   |
| `proximityPatternBoost` | `1.5`        | how much near points brighten the motifs around them  |

- `pulse(strength:, duration:, color:)` lights the whole wall up and lets it fall back: the value
  rises over the first `pulseAttack` of the duration and falls back as `(1 - t)²` over the rest;
  a pulse started while another shows rises from where that one is. It adds `color * value` to the
  wall's light, more at the foot than at the top, and raises the fill's cover; `pulseValue` reads
  it and `clearPulse` ends it. For a landing, or each beat of a countdown.
- `setNearPoint(index, position, strength:, color:)` makes the wall glow where a world point comes
  close, without a hit: the glow grows as `(1 - distance / proximityRadius)²` towards the point and
  brightens the motifs around it. There are `maxNearPoints` (4) slots; call it every frame the
  point moves, `clearNearPoint` and `clearNearPoints` remove them.


### Reaction in front

`reactionInFront` (`0` by default, up to `1`) draws the reaction, the impacts and the glow of the
near points, over what stands in front of the wall: a ball that hits the far side of a wall hides
its own rings otherwise. While it is above `0` and a reaction shows (`drawsReactionInFront`), a
`BarrierMesh` draws its surface a second time with `reactionInFrontMaterial`: the same shaders and
values, drawing the reaction only and scaled by `reactionInFront`, with the wall's blending but the
depth test `CompareFunction.greater` and no depth writes. It lands only on the pixels where
something in front of the wall hid it, so where nothing does, the picture is the same as without it,
and the second draw shades only those pixels. A mesh of another class draws that second surface
itself:

```dart
if (barrier.drawsReactionInFront) {
  context.drawSurface(
    surface,
    transform: transform,
    material: barrier.reactionInFrontMaterial,
  );
}
```

It costs one more draw call (outside the shadow and depth-normal passes) and the uniforms of a
second material, while a reaction shows: an impact during its duration, or a near point set.


### Looks as data

A `BarrierLook` is an immutable value holding every setting of a barrier's look and reaction (65:
the colors, the height profile, the density, the pattern, the impacts, the wobble, the pulse and
near-point defaults, `reactionInFront`, `preserveHue` and the blend). It holds no state: the
appear factor, the time, the impacts, the near points, the pulse and `patternLoopLength` stay on
the material.

```dart
final barrier = BarrierMaterial.fromLook(BarrierLook.softVeil);
barrier.look = BarrierLook.lowFence; // applyLook
final dusk = noon.copyWith(footColor: const Color(0xFFFF8040), intensity: 1.2);

// Every frame, without allocating:
barrier.applyLookLerp(noon, dusk, duskAmount);
```

- `applyLook` (and the `look` setter) takes every setting and the blend (the render state keeps its
  other fields, and switches between the standard additive, premultiplied and alpha states without
  making new ones); on a closed loop the look's `patternScale` is rounded to a whole number of
  motifs, as `fitPatternTo` does. `look` reads the material's settings back as a value.
- `BarrierLook.lerp(a, b, t)` and `applyLookLerp(a, b, t)` interpolate numbers and colors linearly
  (whole numbers rounded) and switch the pattern, the blend and `preserveHue` at `t = 0.5`;
  `applyLookLerp` writes into the material without allocating, to animate a look every frame.
  Each end gives its look exactly.
- `copyWith` replaces some settings (`clearPatternColor: true` sets `patternColor` back to
  `null`); `toJson` and `BarrierLook.fromJson` read and write a look as plain data (colors as
  `0xAARRGGBB` integers, enums by name; missing keys keep their defaults).
- The presets (`BarrierLook.presets` by name): `standard` (the defaults), `softVeil` (a faint even
  veil up the whole height with a soft edge and a quiet lattice, premultiplied), `solidWall` (a tall
  dense amber shield with a honeycomb, a fill hiding much of the far side, a thin near side, a
  bright top edge, three rings, a wobble and the reaction in front), `lowFence` (a warm band fading
  out by half the height, chevrons, premultiplied) and `electricCage` (a cold lattice of bars and
  rungs with crackling noise and a flicker, additive).


### Blending over bright and coloured backgrounds

The background behind a wall decides which blend reads best. Added light (the default
`RenderState.additive`) only brightens: over light water or pale stone a warm or cold wall turns
white where it is bright, since every channel of the background is raised, and its rings vanish in
the white. Laid over (`RenderState.premultipliedAlphaBlend`), the wall replaces what is behind it in
proportion to its alpha, the brightest channel of its light, so its bright parts keep their hue;
its faint parts still mix with the background (an orange veil over turquoise water goes grey-green
where it thins out).

| Background                    | Blend                                                        |
| ----------------------------- | ------------------------------------------------------------ |
| Light water, pale stone, sand | premultiplied, `preserveHue: true`, `fillOpacity` 0.2 to 0.4 |
| Dark water, dark ground       | additive (premultiplied where it stands over pale slabs)     |
| HDR scene with bloom          | additive, `preserveHue: false`, `intensity` above `1`        |

- With `preserveHue`, a wall at the `intensity` a game needs to read (`1` to `1.4`) keeps its
  color instead of clipping to yellow-white or cyan-white, and the reaction, added after it, still
  goes white where it is bright.
- A fill gives the background less of a say: its cover replaces the background by the fill color,
  so a warm wall over cold water stays warm where its light thins out. Keep it under `0.5` on a wall
  whose inside must stay readable, and thin the near side (`nearSideFade` `0.7` to `0.85`).
- The same wall stands over several backgrounds at once: in a `Scene3DComponent` the far side of a
  wall around a platform is seen over the platform's pale slabs, the rest over the water around it.
  Choose for the brightest of them.

The example's `barrier_gallery` scene shows the presets and sweeps of each setting over light
water, dark water and pale stone.


### Blending, depth and passes

- The default `RenderState.additive` adds the wall's light to what is behind it and keeps the
  target's alpha (see [Rendering](rendering.md#render-state)): in a `Scene3DComponent` the wall adds
  onto the 2D art drawn below the layer without darkening it.
- `RenderState.premultipliedAlphaBlend` and `RenderState.alphaBlend` lay it over the scene as a
  veil whose alpha is its brightest channel, or the fill's cover where larger.
- The wall is depth tested against the scene without writing depth, both faces are drawn, and it
  is translucent: ordered among the translucent draws by the center of its bounds. It is left out
  of the shadow passes (`castsShadows` is `false`) and of the depth-normal prepass, which draws
  only opaque materials that write depth. With `OitMode3D.weightedBlended` the additive wall is
  drawn sorted after the composite, as every additive draw is.
- It writes display colors, unclamped: in an HDR scene target (`World3D.hdrEnabled`) an
  `intensity` above `1` and stacked impacts go above white and bloom (unless `preserveHue`); in an
  8-bit target they clip.
- The view direction comes from the inverse of the view-projection matrix, so the glint and the
  near side are right under perspective, orthographic, oblique and mirroring projections, such as
  the affine projections of 2D art.


### Costs

One draw call per barrier mesh (one surface), one more while the reaction in front shows, and
three uniform blocks, no texture: `BarrierShape` (13 vectors: the appear factor, the height scale,
the wobble and the packed impacts) and `BarrierLook` (46 vectors: the look, 8 impacts and 4 near
points), about 950 bytes besides the camera's, against 320 before the controls.

The material has two pairs of shaders and picks one each time it is drawn (`usesFullShader`):

- the lean pair (`barrier_material`) draws what the barrier drew before its controls existed (one
  row of the first four patterns, at most 4 impacts with one ring each, the near side thinned) plus
  the pulse and the near points, with only constants turned into uniforms (the ring and flash
  strengths, the flash's length, the twinkle, the line width, the motif color, the softness of the
  near-side fade). It costs what the barrier cost: a gradient, one motif (a few segment distances),
  a glint and four impacts, unrolled.
- the full pair (`barrier_material_full`) is drawn while any option the lean one leaves out is on
  (hexagons or a grid, rows, rising motifs, a fade off its ends, a top edge, a fill, noise, a
  flicker, `farSideFade`, `preserveHue`, more rings or a reach, more than 4 slots, a wobble), and
  for the reaction in front. Every option is behind a branch on a uniform, but the larger shader
  holds more registers: on a desktop GPU (12 overlapping full-screen walls) it shaded at about 1.5
  to 2.5 times the cost of the lean one, whichever options were on. The first frame that needs it
  creates its pipeline. Its vertex stage evaluates the wobble of up to 8 impacts per vertex while
  the wobble is on.

All the values that grow with time (the pattern's offsets, the twinkle's phase, the noise offset,
the flicker, the pulse, the age of each impact) are computed and wrapped on the CPU in `apply`, so
the shaders never see a large time, and `apply` computes the inverse of the view-projection matrix
once per batch. It allocates nothing per frame, and neither do `impact`, `pulse`, `setNearPoint`,
`applyLook` and `applyLookLerp`. In the `barrier` scene of the example, the wall (74 triangles
around a 5 by 5 platform) adds one draw call to the layer's 13, and about 10 µs of `Material.apply`
per frame under `flutter test` (a debug build, measured with `FLAME_3D_PROFILE`, see
[Rendering](rendering.md#profiling)).

The shaders are written for GLSL ES 1.00 too: no flat inputs, no explicit texture level of detail,
no derivatives, no `switch`, no integer operations, and no loops besides the one-pass loops the
compiler adds; the OpenGL ES output of both pairs passes `glslangValidator` as GLSL ES 1.00.

Not available on the web: there is no WebGPU build of its shaders, and creating one there throws an
`UnsupportedError`.


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
apply it. Setting `World3D.fog` to a new object marks the scene changed, and so does changing the
fields of the current `FogSettings` (or its `up` in place), so a `Scene3DComponent` with
`Scene3DCacheMode.retained` follows both (see
[Lighting](lighting.md#changing-lights-at-run-time)). How fog combines with lighting and HDR is
described in [Lighting](lighting.md#fog-and-lighting).


## Water volumes

Assigning `World3D.waterVolume` fills the world with water up to a level: the parts of
`StylizedMaterial` surfaces below it look submerged, tinted and darkened with their depth and lit
by the caustics of the surface above them, and the surfaces foam in a narrow band where they cross
the level. No depth buffer is involved: each fragment knows its own depth below the level, so it
costs no pass, and a slab rising through the surface gets its foam ring and its wet look for free.

```dart
world.waterVolume = WaterVolumeSettings(
  level: 0, // along up
  up: Vector3(0, 0, 1), // a z-up world
  deepColor: const Color(0xFF17669A),
  absorption: 1.05,
  causticStrength: 0.85,
  causticScale: 0.62, // as the water's WaterMaterial
  animationPeriod: 4, // as the water's WaterMaterial
  waterlineWidth: 0.045,
  bounds: poolBox, // only inside the pool
);

// Every frame, on the water's clock:
water.time += dt;
world.waterVolume!.time = water.time;
```

| Parameter            | Default      | Meaning                                                   |
| -------------------- | ------------ | --------------------------------------------------------- |
| `level`, `up`        | `0`, +Y      | the surface's height along `up` (normalized, copied)      |
| `shallowColor`       | `0xFFC8F2EA` | filters the color of shallow surfaces                     |
| `deepColor`          | `0xFF155E75` | the color deep surfaces fade into                         |
| `absorption`         | `0.8`        | how fast they fade, per world unit                        |
| `causticStrength`    | `0` (off)    | the caustics on submerged surfaces                        |
| `causticScale`       | `0.6`        | their cells' size, in world units                         |
| `causticColor`       | white        | their color, times the direct sunlight                    |
| `animationPeriod`    | `8`          | seconds over which the caustics and the waterline loop    |
| `time`               | `0`          | advance it every frame, with the water's                  |
| `waterlineWidth`     | `0` (off)    | the width of the foam band around the level               |
| `waterlineColor`     | `0xE6FFFFFF` | its color (lit like the surface); its alpha, how much     |
| `waterlineLightTint` | `1`          | how much of the light's color the waterline foam takes    |
| `waterlineLightFloor`| `0`          | the least light the waterline foam takes                  |
| `waterlineMotion`    | `1`          | the pace of the waterline foam, `0` still                 |
| `bounds`             | none         | the box the water fills; outside it, nothing is submerged |

Where a fragment is `depth = level - dot(position, up)` below the level (and inside `bounds`, when
given), its color, after its shading and color grade and before the fog, becomes

```text
color    += albedo * sun * causticColor * causticStrength * fadeIn
            * caustics(where its sunlight entered the water)
absorbed  = 1 - exp(-absorption * depth)
filter    = mix(1, shallowColor, 1 - exp(-4 * absorption * depth))
color     = clamp(mix(color * filter, deepColor, absorbed), 0, 1)
```

- `albedo` is the surface's base color (vertex color, instance tint and accent), `sun` the direct
  light its directional lights give it, after their shadows and its `n·l`: a submerged surface
  keeps the sun's shadow, which fades with the rest of its color as it deepens, and has no
  caustics where it is shadowed. `fadeIn` grows from `0` at the level to `1` an eighth of a unit
  below it, so the waterline stays clean.
- The caustics are the network `WaterMaterial.causticStrength` draws, sampled where the
  surface's sunlight entered the water: from the fragment, back along the sunlight refracted by
  the surface (its slope towards the horizon divided by about 1.33), up to the level. With the same
  `causticScale`, `animationPeriod` and `time` as the water's material (and the same up axis), the
  floor shows the network of the surface above it, shifted by the slant of the sun. They come from
  the directional light that casts shadows, or the first one; a world without one has none.
- Above the level, surfaces are unchanged, except in the waterline band: where `|depth|` is
  within about `waterlineWidth` (the band laps up and down and is broken up along the outline of
  the surface), the color moves towards `waterlineColor` times the surface's light (at most
  `1.25`), by up to the color's alpha. Surfaces lying flat in the band, the top of a slab as it
  passes through the level, foam more sparsely than walls and columns.
- `waterlineLightTint` says how much of the color of that light the foam takes, as
  `WaterMaterial.foamLightTint` does on the water: the light is moved towards its luminance,
  `mix(vec3(luminance), light, waterlineLightTint)`, so `1` (the default) keeps its color and `0`
  only its brightness. Under a low, warm sun, about `0.25` keeps the band white, matching the foam
  of the water beside it.
- `waterlineLightFloor` is the least light the band takes, as a multiple of `waterlineColor`:
  the light is clamped to `[waterlineLightFloor, max(1.25, waterlineLightFloor)]`. The default,
  `0`, lets the band darken with the light; at dusk about `0.7` keeps it bright, as
  `WaterMaterial.foamLightFloor` does for the foam on the water.
- `waterlineMotion` multiplies the pace at which the band laps and drifts, as
  `WaterMaterial.edgeFoamMotion` does for the foam on the water: `1` (the default) moves with the
  caustics, `0.5` half as fast, `0` holds it still, broken up as before but not moving (rime or a
  crust of ice or salt on the stones of a winter pond, to go with a still band on the water). Its
  phase is `2π * fract(time * waterlineMotion / animationPeriod)`, computed on the CPU, so a slower
  band still loops without a jump; the caustics keep their pace. It costs nothing per pixel.

The volume works with every vertex stage of `StylizedMaterial` (its own layout, skinned or not,
and the standard layout), instancing, palettes, translucency, dither fades, shadows and HDR. The
shadow pass and the depth-normal prepass draw with their own shaders and ignore it: submerged
objects cast the shadows they cast in the air. `SpatialMaterial`, `WaterMaterial` and the other
materials do not read it, nor do custom shaders unless they declare the `WaterVolume` block and
call `applyWaterVolume` from `#include <flame_3d/water_volume.glsl>`. Setting
`World3D.waterVolume` to a new object marks the scene changed, and so does changing the fields of
the current one: a retained `Scene3DComponent` renders again on every frame its `time` advances
(see [Lighting](lighting.md#changing-lights-at-run-time)); a change of its `bounds` in place is
reported with `volume.markChanged()`.

Cost: the volume adds 9 vectors to the pass block `StylizedMaterial` reads (written once per pass,
about 0.2 µs) and no binding. Per pixel, surfaces above the level and its band test one plane and
stop; submerged pixels pay two exponentials and, with caustics, the 22 transcendentals of the
network; pixels in the band pay two noise lookups (13 sines), with `waterlineLightTint` below
`1` a dot product and a mix, and with `waterlineLightFloor` above `0` a `max`; `waterlineMotion`
costs nothing (its phase is computed on the CPU). On the software rasterizer of `flutter test`, a
full-screen submerged stylized surface costs about 25 % more without caustics and 40 % more with
them than a dry one. Like `StylizedMaterial`, it does not run on the web.


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

  Color get tint => _tint;
  set tint(Color value) => _tint = noteChange(_tint, value);
  Color _tint = const Color(0xFFFFFFFF);

  @override
  void apply(RenderContext context) {
    fragmentShader.setColor('Tint.color', tint);
  }
}
```

Give every value a setter that reports its changes with `noteChange` (`noteTime` for the time of
an animation), so that retained layers follow it (see
[Changes and versions](#changes-and-versions)); a public field written without a setter is a
change the engine cannot see. In the constructor, set
the render state and `castsShadows` with `setInitialState`, which reports nothing.

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
| `Shadows`, `shadowMap` | `shadows.glsl`  | the shadow map or atlas and its tiles      |
| `ShadowAtlas`          |                 | the atlas tiles (no built-in shader reads) |
| `JointMatrices`        | `skinning.glsl` | 64 joint matrices (3 rows), per draw       |
| `brdfLutTexture`       |                 | the split-sum BRDF table                   |
| `probeGridTexture`     |                 | the light probe grid                       |
| `DepthNormal`          |                 | the depth and normal prepass               |
| `depthNormalTexture`   |                 | its texture                                |
| `SceneColor`           |                 | the grab pass of the opaque scene          |
| `sceneColorTexture`    |                 | its texture                                |

Slots without a chunk must be declared by the shader itself, with the layout of the built-in
shaders (`spatial_material_pbr_fragment.glsl`, `water_material.frag`).

`JointMatrices` holds the top three rows of each joint matrix (`vec4 jointRows[192]`, row `r` of
joint `j` at `j * 3 + r`, `RenderContext3D.jointRowsMember`): `computeSkinMatrix()` of
`skinning.glsl` rebuilds the matrix with a bottom row of `(0, 0, 0, 1)`, as every affine transform
has, so a joint matrix that is not affine (a projection) is not drawn as given. A shader that
declares `mat4 joints[64]` in the block instead, as the built-in ones did, gets whole matrices.

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
`GpuBackend.initialize()`. On OpenGL ES a material checks its shaders when it is created and
throws an `UnsupportedError` when the device cannot run them: a custom shader's uniform blocks and
loose uniforms must fit the device's uniform vectors (`GpuBackend.instance.capabilities`), and the
extensions its OpenGL ES build requires must be accepted (see
[What the device offers](getting_started.md#what-the-device-offers)).


## Web

On the web, the materials run on WebGPU through hand-written WGSL versions of their shaders
(`.wgslbundle` assets):

- `SpatialMaterial` uses a WGSL version of the older spatial shader: the maps (with the per-pixel
  tangent frame), environment texture and probe SH9, every kind of light, fog, alpha cutoff and
  dither fade. Clearcoat, transmission, lightmaps, the split-sum BRDF table, reflection probe
  volumes, light probe grids, vertex tangents and HDR output are native only. Shadows are not
  rendered on the web (the shadow caster shaders have no WebGPU build, so the shadow pass is
  skipped).
- `UnlitMaterial`, `SkyboxMaterial3D` and `BillboardMaterial3D` have WGSL shaders.
- `StylizedMaterial`, `OutlineMaterial`, `DecalMaterial`, `ShadowCatcherMaterial` and
  `BarrierMaterial` throw an `UnsupportedError` when created there (WGSL files exist for the outline
  and decal shaders but are not used). `WaterMaterial` (its options and ripples included) has no
  WGSL shaders and fails when first drawn. `World3D.waterVolume` only changes `StylizedMaterial`,
  so it has no effect there.
- Compressed KTX2 textures are always decoded on the CPU, so BC7, ETC2 and ASTC files throw.

The texture sampler options, including anisotropy up to 16, work on the web.


## Limitations

- Only `SpatialMaterial` (native) keeps light brighter than white under HDR; the other materials
  write display colors (see [Choosing a material](#choosing-a-material)), so they bloom only where
  additive draws stack above white.
- Shadow casters ignore alpha: `alphaCutoff` cutouts cast the shadow of their whole quad, and
  objects faded with `instanceData.w` or `ditherFade` cast their full shadow.
- `SpatialMaterial`: the default `metallic` is `0.8`; `uvScale` and `uvOffset` are applied to every
  map but not to the lightmap, and there is no UV rotation.
- `StylizedMaterial` is display-referred and clamped to `[0, 1]`; it has no textures besides its
  MatCaps, and no image-based lighting.
- `WaterMaterial` reflects a flat sky color and needs a subdivided mesh. Its ripples tilt the
  normals but do not move the vertices, and its depth ramp and foam mask come from the vertices, so
  they do not follow objects that move under or through the water (a slab rising under the
  surface): foam sources (`WaterFoamSources`) follow them, but only as circles or rectangles with
  rounded corners lying in the plane of the water, 16 at most per set (8 by default; more than 8,
  or carried patterns, take the full fragment stage), and each one costs every pixel it may reach
  (as far as the vertices of the surface can tell: a surface of a few large triangles pays them
  over most of its pixels). A collar that carries its pattern keeps its band apart from the foam
  it meets (the larger of the two shows) instead of merging with it. `edgeFoamMotion` and
  `foamLightTint` belong to the material, not to the vertices: a still band on part of a surface
  takes a surface and a material of its own. The volume's `waterlineMotion` holds for every
  waterline of the world alike.
- A water volume has a flat level: it ignores the waves of the surface, so its waterline band does
  not follow them (keep the waves small, as in a basin). It submerges `StylizedMaterial` surfaces
  only, takes its caustics from one directional light, and has no fog of its own: the distance
  through the water, from the surface to the eye, is not counted, only the depth.
- A `DecalBatch3D` is one draw: it is sorted among the translucent draws at the center of its
  decals' bounds, so decals spread far apart can still be drawn in the wrong order against
  translucent objects between them. Textured decals are multiplied by their alpha a second time,
  which darkens the soft edges of premultiplied images.
- Straight-alpha blending of premultiplied textures: translucent `SpatialMaterial` blends with
  straight alpha while textures made from Flutter images are premultiplied, which darkens their
  soft edges. (`BillboardMaterial3D`, and so `Text3DComponent`, blends premultiplied colors and
  takes a `premultipliedTexture` flag, see [3D UI and Text](ui_3d.md#the-material).) The package
  has no single alpha convention for textures yet.
- `BarrierMaterial`: its appear factor, pattern, impacts, pulse and near points belong to the
  material, so barriers that rise and are hit separately need a material each; eight impacts and
  four near points at once; its motifs are drawn without derivatives, so a pattern much finer than
  a few pixels per motif aliases; additive light over light or saturated colors turns towards
  white (lay it over with `preserveHue` and a fill instead); no fog. `heightScale` scales the mesh
  about its own `y = 0` and stretches the motifs; the wobble moves vertices, so it needs a
  subdivided wall, and it moves the surface only along its normal; the noise measures the height
  along the mesh's y axis. The reaction in front shows over anything in front of the wall, not only
  over what caused it, and a near point keeps its second draw alive while it is set. Any option of
  the full shaders costs the full shaders' price, however little of it is used.
- Change tracking sees the setters, the vectors, palettes and state objects listed in
  [Changes and versions](#changes-and-versions); a texture whose contents change, an
  `EnvironmentProbe3D` changed in place, or values a custom material computes from state of its
  own are reported with `markChanged()` (or `animated`). A world follows the materials of its last
  render only: with several cameras, the version follows the camera that rendered last.
- KTX2: no supercompression, and no CPU decoder for BC7, ETC2, ASTC and RGBA32F.
- `ImageTexture` has no color space option: images cannot be sampled as sRGB.
