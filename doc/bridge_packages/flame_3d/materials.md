# Materials and Lighting

A `Material` decides how the surfaces drawn with it look: its shaders, the values it gives them and
its render state (see [Rendering](rendering.md)). This page describes the built-in materials, the
lights they respond to, and textures.


## Built-in materials

- `SpatialMaterial` is physically based (metallic and roughness), lit by every kind of light, tone
  mapped and gamma corrected. Its base color is `albedoColor`, times `albedoTexture`, times the
  vertex color, times the per-instance color. It is opaque by default.
- `UnlitMaterial` outputs `albedoTexture` times `albedoColor`, times the vertex color, times the
  per-instance color, without lighting. It blends with premultiplied alpha and draws as translucent
  by default; set its `renderState` to `RenderState.opaque` for opaque content.
- `StylizedMaterial` is made for stylized, vertex-colored art without textures, see
  [below](#stylizedmaterial).

Vertices built from `Vertex` objects, the built-in meshes and parsed models have white vertex
colors, so the vertex color only changes the look of meshes that set it.


## Lights

The lights of a world come from its `LightComponent`s, and are read once per render pass, so their
values can be animated:

| Light              | Component                    | Lights a surface with                   |
| ------------------ | ---------------------------- | --------------------------------------- |
| `AmbientLight`     | `LightComponent.ambient`     | `color * intensity`, everywhere         |
| `HemisphereLight`  | `LightComponent.hemisphere`  | the sky color above, the ground below   |
| `DirectionalLight` | `LightComponent.directional` | parallel rays along a direction (a sun) |
| `PointLight`       | `LightComponent.point`       | light from a position, fading out       |

- The first `AmbientLight` and the first `HemisphereLight` of a scene are used. A scene with
  neither gets a white ambient light of intensity `0.2`; a hemisphere light replaces that default.
- `SpatialMaterial` receives `intensity * mix(groundColor, skyColor, hemi)` from a hemisphere
  light, with `hemi = 0.5 + 0.5 * n·up`.
- A directional light travels along its `direction` when it has one, otherwise along the -Z axis
  of its component's world rotation, so rotating the component turns it. Its `specular` factor
  (from `0` to `1`) scales the highlights it makes. Up to `RenderContext3D.maxDirectionalLights`
  (4) are used.
- Without a `range`, a point light falls off with the inverse square of the distance `d`:
  `intensity / d²`. With one, it fades out smoothly and reaches no further:
  `intensity * (1 - d / range)²`. Up to `RenderContext3D.maxPointLights` (8) are used.

```dart
world.addAll([
  LightComponent.hemisphere(
    skyColor: const Color(0xFF9CC2F0),
    groundColor: const Color(0xFF7A6A50),
    intensity: 0.5,
  ),
  LightComponent.directional(
    direction: Vector3(-0.5, -0.8, -0.3),
    intensity: 3,
  ),
  LightComponent.point(
    position: Vector3(0, 1.5, 0),
    color: const Color(0xFFFFA040),
    intensity: 2,
    range: 4,
  ),
]);
```

`SpatialMaterial` is physically based: a directional light needs an intensity of about `3` to light
a white surface facing it fully.


## StylizedMaterial

`StylizedMaterial` lights low-poly meshes whose vertices carry a color, a baked ambient occlusion
and a few masks that pick per-vertex effects: which vertices take the per-instance tint or the
material's accent color, which ones glow, how glossy they are, and how much they sway in the wind.


### Vertex layout

It reads `StylizedMaterial.vertexLayout`, 16 floats per vertex:

| Attribute         | Floats | Meaning                                                    |
| ----------------- | ------ | ---------------------------------------------------------- |
| `vertexPosition`  | 3      | the position                                               |
| `vertexNormal`    | 3      | the normal                                                 |
| `vertexColor`     | 4      | the color (rgb) and alpha                                  |
| `vertexMasks`     | 4      | the tint, accent and emissive masks, and the gloss         |
| `vertexOcclusion` | 1      | the ambient occlusion: `1` unoccluded, `0` fully occluded  |
| `vertexSway`      | 1      | the wind sway weight                                       |

The masks blend from `0` (none) to `1` (fully). The gloss is the strength of the vertex's
highlights; it may exceed `1` for extra bright ones (gems, for instance).

`StylizedMaterial.buildSurface` packs per-vertex arrays into this layout; arrays left out take
their defaults (white, unoccluded, no mask, no sway):

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
  sway: sway,
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
color everywhere, with no accent, emission, gloss nor sway.


### Skinning

Surfaces in `StylizedMaterial.skinnedVertexLayout`, 24 floats per vertex, are skinned: the 16
floats above followed by `vertexJoints` (up to four joint indices) and `vertexWeights` (their
weights), 4 floats each. Each vertex is moved by the weighted sum of the joint matrices of its draw,
`sum(weight * joint) * position` (and its normal by the same matrix), then shaded like any other
vertex; its wind sway is added in model space after the skinning. A vertex whose weights are all
`0` keeps its position, and weights need not add up to `1` when the joints are built for it (for
example two joints that differ only in a translation, weighted `1 - w` and `w`, move a vertex by
`w` times the difference).

`buildSurface` lays the surface out this way when given `joints` and `weights`, both together; the
indices must be whole numbers below `StylizedMaterial.maxJoints` (16). Every draw of a skinned
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
  ..translate(shoulder)
  ..rotateY(swing)
  ..translate(-shoulder);
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
| `z`       | wind strength, added to 1: `-1` stills the object's sway, `1` doubles it      |
| `w`       | fade: the object's opacity is `1 - w`, shown by a translucent material        |

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
       + Σ directional: max(0, n·l) * intensity * color
       + Σ point: intensity * color * falloff * max(pointLightWrap, n·l)
spec = only where gloss > specularThreshold:
       Σ directional: (n·h)^specularPower * specular factor
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
out  = mix(mix(luminosity(lit), lit, saturation), overlayColor.rgb,
           overlayColor.a)
alpha = albedoColor.a * vertex alpha * (1 - fade)
```

`falloff` is the point light's (see [Lights](#lights)). MatCap textures are sampled at
`(0.5 + 0.5 x, 0.5 - 0.5 y)` of the view-space normal, `x` pointing right and `y` up in the
picture, also when the projection mirrors the picture (as some `Scene3DProjection`s do).
`reflected` is `cap` on the vertices that get a MatCap texture and `1` on the others (see
[Metals](#metals)). Highlights are white and follow
the direction of the directional lights, not their intensity, so they keep their strength when a sun
dims. The result is clamped to `[0, 1]`, with no tone mapping, graded (see
[Color grade](#color-grade)), and output premultiplied by its alpha. For orthographic cameras, `v`
is the camera's direction. `skyFillWeight` weighs the sky fill per channel, for example
`Vector3(1, 1, 0.914)` with the default `skyFill` for a fill of `(0.35, 0.35, 0.32)` times the sky
color.

| Parameter                                     | Default                     | Meaning                |
| --------------------------------------------- | --------------------------- | ---------------------- |
| `albedoColor`                                 | white                       | times vertex color     |
| `accentColor`                                 | white                       | the accent color       |
| `ambientBase`                                 | `0.65` gray                 | ambient for all        |
| `skyFill`, `skyFillWeight`                    | `0.35`, `(1, 1, 1)`         | sky share, per channel |
| `groundBounce`                                | `0.10`                      | ground share           |
| `pointLightWrap`                              | `0.18`                      | least point light      |
| `specularStrength`, `specularPower`           | `0.28`, `8`                 | highlights             |
| `specularThreshold`                           | `0.12`                      | least gloss to shine   |
| `rimStrength`, `rimPower`, `rimColor`         | `0.14`, `3`, black          | rim light              |
| `emissiveColor`, `emissiveStrength`           | white, `1`                  | glowing vertices       |
| `emissiveBoostColor`                          | `emissiveColor`             | glow at boost 1        |
| `highlightColor`                              | white                       | per-instance highlight |
| `matCapTexture`, `matCapStrength`             | none, `1`                   | MatCap sheen           |
| `matCapThreshold`, `matCapGlossWeight`        | `0`, `1`                    | least gloss, weighting |
| `gemMatCapTexture`, `gemMatCapStrength`       | none, `1`                   | MatCap of gems         |
| `gemThreshold`                                | `1`                         | least gloss of gems    |
| `matCapMetallic`                              | `0`                         | MatCap as reflection   |
| `windDirection`, `windAmplitude`, `windSpace` | `(1, 0, 0)`, `0.032`, world | sway way and reach     |
| `windFrequency`, `windPhase`, `windTime`      | `2.3`, `(0.7, 0, 0.5)`, `0` | sway timing            |
| `saturation`, `overlayColor`                  | `1`, transparent            | color grade            |

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

A vertex with a sway weight `w` moves by
`windDirection * windAmplitude * sin(windTime * windFrequency + dot(origin, windPhase)) * w`, times
the wind strength of its object (`1 + instanceData.z`), where `origin` is the world position of its
object. With `windSpace: WindSpace.world` (the default), the direction and the amplitude are in world
space: every object sways the same way. With `WindSpace.model` they are in the model space of each
object, as if the sway were part of its mesh: it turns with the object's rotation and scales with
its scale, so one material serves objects of every orientation and size:

```dart
final trees = StylizedMaterial(
  windSpace: WindSpace.model,
  windDirection: Vector3(1, -0.55, 0), // along the model's own axes
  windAmplitude: 0.032, // in model units
  windPhase: Vector3(0.7, 0.5, 0), // from the world position of each tree
);
```

Advance `windTime` every frame, and drive `emissiveStrength` from the time of day to light windows at
dusk:

```dart
@override
void update(double dt) {
  material
    ..windTime += dt
    ..emissiveStrength = dusk;
}
```


### Batching and translucency

Like the other built-in materials, it is drawn instanced: components sharing a mesh with a
`StylizedMaterial` cost one draw call per surface, whatever their tints and instance data. The
accent color belongs to the material, so use one material per accent color.

`StylizedMaterial(translucent: true)` blends its premultiplied output over what is behind it
(`StylizedMaterial.translucentRenderState`: depth tested, without depth writes), and its draws are
sorted back to front after the opaque ones; objects then fade with the `w` of their instance data.
Consecutive translucent draws of one surface are still batched. Back-face culling
(`renderState = StylizedMaterial.translucentRenderState.copyWith(cullMode: CullMode.backFace)`)
keeps the inner faces of a closed mesh from showing through.

```{note}
`StylizedMaterial` is not available on the web yet: creating one there throws an
`UnsupportedError`.
```


## Textures

A `Texture` is uploaded from its pixels the first time it is used. How it is sampled is its
`sampler`, a `TextureSampler` value that may be changed at any time:

- `minFilter`, `magFilter` and `mipFilter`: `TextureFilter.nearest` (the default) or
  `TextureFilter.linear`, when the texture is drawn smaller, larger, and between mip levels.
- `wrapU` and `wrapV`: `TextureWrap.clamp` (the default), `TextureWrap.repeat` or
  `TextureWrap.mirror`, for coordinates outside `[0, 1]`.

`TextureSampler.linear` filters linearly, and `TextureSampler.all(filter: ..., wrap: ...)` sets
every option at once.

With `mipmaps: true`, a texture builds its mip levels on the CPU (each level averages 2x2 pixels of
the previous one) and uploads them, so that it does not shimmer when drawn small. Devices that
cannot sample mip levels uploaded by hand get the full-size level only.

```dart
final tiles = Texture(
  pixels,
  width: 256,
  height: 256,
  mipmaps: true,
  sampler: const TextureSampler.all(
    filter: TextureFilter.linear,
    wrap: TextureWrap.repeat,
  ),
);
```

`ImageTexture.create(image)` (and `Images.loadTexture`) shares the GPU memory of the image without
copying it, where the GPU backend can: on Flutter GPU, for images backed by a GPU texture, such as
decoded images and those of `Picture.toImage`. Otherwise, and when mipmaps are asked for, the
pixels are read back with `Image.toByteData` and uploaded.


## Custom shaders

A custom shader can read the lights by including `flame_3d/lights.glsl`, which declares the blocks
the `RenderContext3D` fills once per pass. List the blocks the shader uses in its material's slots:

| Block               | Members                                                     |
| ------------------- | ----------------------------------------------------------- |
| `AmbientLight`      | `color`, `intensity`                                        |
| `Lights`            | `numLights`, `positions`, `colors`, `intensities`, `ranges` |
| `DirectionalLights` | `numLights`, `directions`, `colors`                         |
| `HemisphereLight`   | `skyColor`, `groundColor`, `up`, `intensity`                |

A point light's intensity and range are in the `x` of `intensities` and `ranges`; its range is `0`
when it falls off with the inverse square of the distance. A directional light's `directions` hold
the unit vector from a surface towards the light (`xyz`) and its specular factor (`w`), and its
`colors` hold its color (`rgb`) and intensity (`a`).

A material can draw several vertex layouts by overriding `Material.vertexShaderFor` to return a
vertex shader variant per layout, all feeding the same fragment shader; `StylizedMaterial` does so
for the standard layout.


## Web

On the web, `SpatialMaterial` and `UnlitMaterial` support the vertex color, every kind of light
and the texture sampler options, through hand-written WebGPU shaders. `StylizedMaterial` is native
only for now.
