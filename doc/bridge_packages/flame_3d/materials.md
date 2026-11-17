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


### Shading

With `n` the normal, `v` the direction to the viewer, `up`, `sky` and `ground` those of the
hemisphere light, `hemi = 0.5 + 0.5 * n·up` and `bounce = max(0, -n·up)`:

```text
base = albedoColor * vertexColor * mix(1, instance color, tint mask)
       * mix(1, accentColor, accent mask)
lit  = occlusion * (ambient light
         + hemisphere intensity * (ambientBase + skyFill * sky * hemi
                                   + groundBounce * ground * bounce))
       + Σ directional: max(0, n·l) * intensity * color
       + Σ point: intensity * color * falloff * max(pointLightWrap, n·l)
spec = only where gloss > specularThreshold:
       Σ directional: (n·h)^specularPower * specular factor
         * gloss * specularStrength
rim  = (1 - n·v)^rimPower * rimStrength * (sky + rimColor)
cap  = matCapTexture(view-space normal) * gloss * matCapStrength
out  = mix(base * lit + spec + rim + cap, emissiveColor,
           emissive mask * emissiveStrength)
```

`falloff` is the point light's (see [Lights](#lights)). Highlights are white and follow the
direction of the directional lights, not their intensity, so they keep their strength when a sun
dims. The result is clamped to `[0, 1]`, with no tone mapping. For orthographic cameras, `v` is the
camera's direction.

| Parameter                                | Default                     | Meaning              |
| ---------------------------------------- | --------------------------- | -------------------- |
| `albedoColor`                            | white                       | times vertex color   |
| `accentColor`                            | white                       | the accent color     |
| `ambientBase`                            | `0.65` gray                 | ambient for all      |
| `skyFill`, `groundBounce`                | `0.35`, `0.10`              | sky and ground share |
| `pointLightWrap`                         | `0.18`                      | least point light    |
| `specularStrength`, `specularPower`      | `0.28`, `8`                 | highlights           |
| `specularThreshold`                      | `0.12`                      | least gloss to shine |
| `rimStrength`, `rimPower`, `rimColor`    | `0.14`, `3`, black          | rim light            |
| `emissiveColor`, `emissiveStrength`      | white, `1`                  | glowing vertices     |
| `matCapTexture`, `matCapStrength`        | none, `1`                   | MatCap sheen         |
| `windDirection`, `windAmplitude`         | `(1, 0, 0)`, `0.032`        | sway way and reach   |
| `windFrequency`, `windPhase`, `windTime` | `2.3`, `(0.7, 0, 0.5)`, `0` | sway timing          |

A vertex with a sway weight `w` moves by
`windDirection * windAmplitude * sin(windTime * windFrequency + dot(origin, windPhase)) * w`, where
`origin` is the world position of its object. Advance `windTime` every frame, and drive
`emissiveStrength` from the time of day to light windows at dusk:

```dart
@override
void update(double dt) {
  material
    ..windTime += dt
    ..emissiveStrength = dusk;
}
```

Like the other built-in materials, it is drawn instanced: components sharing a mesh with a
`StylizedMaterial` cost one draw call per surface, whatever their tints. The accent color belongs
to the material, so use one material per accent color.

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
