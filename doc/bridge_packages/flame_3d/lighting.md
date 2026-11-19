# Lighting

The lights of a `World3D` are `LightComponent`s. Once per render pass, the `RenderContext3D` writes
them into uniform blocks that every material of the pass reads: every object drawn in a pass sees
the same set of lights. This page describes the kinds of light, how many reach a shader, light
masks, image-based lighting with environment probes, reflection probe volumes, light probe grids
and lightmaps, and how fog relates to lighting. Shadows are described in [Shadows](shadows.md), the
materials in [Materials and Textures](materials.md).


## Lights in a scene

```dart
world.addAll([
  LightComponent.hemisphere(
    skyColor: const Color(0xFF9CC2F0),
    groundColor: const Color(0xFF7A6A50),
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
  LightComponent.spot(
    position: Vector3(2, 3, 0),
    direction: Vector3(0, -1, 0), // straight down
    innerConeAngle: 0.3, // radians, half-angles
    outerConeAngle: 0.5,
    intensity: 6,
    range: 8,
  ),
]);
```

| Light              | Component                    | Defaults                              |
| ------------------ | ---------------------------- | ------------------------------------- |
| `AmbientLight`     | `LightComponent.ambient`     | white, intensity `0.2`                |
| `HemisphereLight`  | `LightComponent.hemisphere`  | white sky, `0xFF808080` ground, `0.5` |
| `DirectionalLight` | `LightComponent.directional` | white, `1`, along `-Z`, specular `1`  |
| `PointLight`       | `LightComponent.point`       | white, `1`, no range (inverse square) |
| `SpotLight`        | `LightComponent.spot`        | white, `1`, cone `π/8..π/4`, no range |

A `LightComponent` holds a `LightSource` (its `source`) and follows its world transform: a point or
spot light shines from the component's world position, and a directional or spot light without a
`direction` points along the `-Z` axis of the component's world rotation, so rotating the component
or one of its ancestors turns it. A light with neither a direction nor a transform points straight
down (`-Y`). The values of the source may be changed at any time: they are read once per render
pass.

The `directional`, `point` and `spot` constructors take `shadows` (see [Shadows](shadows.md)), and
a `LightComponent` can also be built around a source of your own:

```dart
final lamp = LightComponent(
  source: PointLight(
    color: const Color(0xFFFFE0B0),
    intensity: 4,
    range: 6,
    shadows: ShadowSettings(), // see shadows.md
  ),
  position: Vector3(0, 2, 0),
);
final sun = LightComponent.directional(
  rotation: Quaternion.axisAngle(Vector3(1, 0, 0), -math.pi / 3),
);
world.addAll([lamp, sun]);

// Any time, for instance every frame:
(lamp.source as PointLight).intensity = 4 + math.sin(time * 9);
sun.rotation.setAxisAngle(Vector3(1, 0, 0), -math.pi / 4);
```

Colors are used as they are (their alpha is ignored), intensities multiply them, distances are in
world units and cone angles are half-angles in radians. What an intensity means depends on the
material, see below. The world keeps its lights in the order in which their components were
mounted; that order decides which lights are used when there are too many.


## Light types


### Ambient light

The first `AmbientLight` of the scene lights every surface equally. A scene with neither an ambient
light nor a hemisphere light gets a white ambient light of intensity `0.2`; a hemisphere light
replaces that default, so a scene with only a hemisphere light has no ambient light.

- `SpatialMaterial` adds `kD * base * color * intensity` (see
  [Materials](materials.md#shading-and-output)).
- `StylizedMaterial` adds `occlusion * color * intensity` before its hemisphere terms.
- `WaterMaterial` uses `color * max(intensity, 0.35)` as its sky color when there is no hemisphere
  light.


### Hemisphere light

The first `HemisphereLight` of the scene adds light from the sky above (`skyColor`, towards `up`)
and from the ground below (`groundColor`); `up` is `+Y` by default and need not be normalized.
With `hemi = 0.5 + 0.5 * n·up`:

- `SpatialMaterial` and `BillboardMaterial3D` add `intensity * mix(groundColor, skyColor, hemi)`.
- `StylizedMaterial` uses it its own way: `ambientBase`, a sky fill and a ground bounce, all scaled
  by the hemisphere intensity (see [Materials](materials.md#shading)).
- `WaterMaterial` reflects `skyColor * intensity` at grazing angles, and lays its ripples in the
  plane perpendicular to `up`.


### Directional light

A `DirectionalLight` is a light infinitely far away, like the sun: `direction` (need not be
normalized) is the way its light travels. Its `specular` factor, from `0` to `1`, scales the
highlights it makes. With `shadows`, a `ShadowSettings`, it casts shadows, see
[Shadows](shadows.md).

How bright a given intensity looks differs between the materials:

- `SpatialMaterial` is physically based: a white dielectric surface facing a light of intensity `I`
  reflects about `0.96 * I / π` of diffuse light, so it needs an intensity of about `π` to reach a
  radiance of `1` before its tone curve (186 of 255 without HDR).
- `StylizedMaterial` adds `max(0, n·l) * intensity * color`: an intensity of `1` lights a white
  vertex fully. Its highlights do not scale with the intensity.
- `WaterMaterial` lights its body by `color * intensity * (0.35 + 0.65 n·l)`, and so does
  `BillboardMaterial3D` (mixed by its `shadeWeight`).


### Point light

A `PointLight` shines in every direction from the world position of its component. Without a
`range` (or with a range that is not above zero), its light falls off with the inverse square of
the distance `d`: `intensity / d²`. With one, it fades out smoothly and reaches no further:
`intensity * (1 - d / range)²`. `StylizedMaterial` wraps it around the object,
`max(pointLightWrap, n·l)`, so it also reaches the side turned away from it. With `shadows`, it
casts omnidirectional (dual-paraboloid) shadows, which every shadow receiver receives, see
[Shadows](shadows.md#point-light-shadows).


### Spot light

A `SpotLight` shines from the world position of its component along `direction`, or along the
`-Z` axis of the component's world rotation when `direction` is `null`. With `θ` the angle between
that direction and the direction to the surface, `SpatialMaterial` and `StylizedMaterial` scale it
by

```text
cone = clamp((cos θ - cos outer) / (cos inner - cos outer), 0, 1)²
```

(`BillboardMaterial3D` uses a smoothstep instead of the square), and by the same distance falloff
as a point light. `outerConeAngle` is clamped to `0.001..0.999π` and `innerConeAngle` to below it.
`StylizedMaterial` wraps spot lights by half its `pointLightWrap` and gives them highlights that
scale with their intensity. With `shadows` a spot light casts perspective shadows, see
[Shadows](shadows.md). `WaterMaterial` lights its body and its glints with spot lights too, with
the same cone and falloff.


## How many lights reach a shader

| Light       | Per pass | When there are more                                                  |
| ----------- | -------- | -------------------------------------------------------------------- |
| ambient     | 1        | the first one; the others are ignored                                |
| hemisphere  | 1        | the first one; the others are ignored                                |
| directional | 4        | the first four; the others are ignored                               |
| point       | 8        | the first eight, or with `prioritizeNearestLights` the eight nearest |
| spot        | 4        | always the four nearest (see below)                                  |

The limits are `RenderContext3D.maxDirectionalLights`, `maxPointLights` and `maxSpotLights`, and the
sizes of the arrays in `flame_3d/lights.glsl` and in the `StylizedPass` block. "First" is the order
of the world's lights. Lights that a light mask excludes from the pass are skipped before counting.
Point lights of zero intensity are not written, but without prioritization they still take one of
the eight places; spot lights of zero intensity are skipped.

The limits are per render pass, not per object: there are no per-object light lists. A scene with
ten street lamps along a road lights the whole road with the same eight; with
`prioritizeNearestLights`, the eight nearest the camera, so a lamp far from the camera may stop
lighting the object next to it. The lighting work of every fragment grows with the number of lights
of the pass, since every material loops over all of them (a light's range zeroes its contribution
outside it but does not skip the work).


### Selection beyond the limits

With `World3D.prioritizeNearestLights` (`false` by default), a scene with more than eight point
lights uses the eight with the highest score; scenes with more than four spot lights always use
the four with the highest score. The score is

```text
perspective camera:    intensity / (1 + distance to the camera²)
orthographic, affine:  intensity / (1 + x² + y²)
```

where `x` and `y` are the light's position in normalized device coordinates (its distance from the
middle of the view). The range of a light is not part of the score. The selection runs on the CPU
once per pass, without allocating, in time proportional to the number of lights.

```dart
World3D manyLights() => World3D(prioritizeNearestLights: true);
```

The shadow pass takes its spot and point casters among the lights the pass selected, at their
places in the arrays, so a shadow follows its light whatever the order. A shadow-casting light that
the selection leaves out casts no shadow in that pass (see
[Spot-light shadows](shadows.md#spot-light-shadows)).


### Which materials use which lights

| Material              | Ambient | Hemisphere | Directional | Point | Spot | Probes, lightmaps |
| --------------------- | ------- | ---------- | ----------- | ----- | ---- | ----------------- |
| `SpatialMaterial`     | yes     | yes        | 4           | 8     | 4    | native only       |
| `StylizedMaterial`    | yes     | own model  | 4           | 8     | 4    | no                |
| `WaterMaterial`       | as sky  | as sky     | 4           | 8     | 4    | no                |
| `BillboardMaterial3D` | yes     | yes        | 4           | 8     | 4    | no                |

`UnlitMaterial`, `DecalMaterial`, `OutlineMaterial`, `SkyboxMaterial3D`, `ShadowCatcherMaterial`,
`ParticleMaterial` and `RibbonMaterial3D` are not lit. Which lights' shadows each material receives
is described in [Shadows](shadows.md#receiving-shadows): `SpatialMaterial`, `StylizedMaterial` and
`WaterMaterial` receive those of every light that casts them.


## Light masks

Every light has a 32-bit `lightMask` (all bits by default), and every render pass a camera mask:
`Scene3DComponent.cameraMask`, `CameraComponent3D.cameraMask`, the camera of a `CameraStack3D`
slot or a `RenderTexture3D`. A light lights a pass only when the two masks share a bit, so two
views of one world can be lit differently:

```dart
const interiorLayer = 1 << 1;
world.add(
  LightComponent.point(
    position: Vector3(0, 2, 0),
    intensity: 3,
    range: 5,
    lightMask: interiorLayer,
  ),
);
final interiorView = Scene3DComponent(
  projection: projection,
  world: world,
  cameraMask: interiorLayer,
);
```

The mask selects lights per pass, like the limits above, not per object (see also
[Basic Concepts](basic_concepts.md#camera-masks-light-masks-and-visibility)). Changing
`LightComponent.lightMask` marks the scene changed. Objects have a `cameraMask` of their own that
decides in which passes they are drawn (see [Cameras](cameras.md)).


## Clustered light grid

`LightClusterGrid3D` (in `package:flame_3d/world_scale.dart`) is a CPU helper, not a clustered
renderer. It assigns point and spot lights to the cells of a camera frustum divided into
`clustersX * clustersY * clustersZ` clusters (`16 x 8 x 16` by default), with depth slices growing
exponentially from `near` to `far`. No built-in material or render pass reads it, and lights added
to it light nothing: whatever it holds, every pass shades at most 8 point and 4 spot lights, chosen
once per pass as [Selection beyond the limits](#selection-beyond-the-limits) describes, and leaves
the others out. Use it to find, among many lights, those that reach a region of the screen or of
the world, for instance to decide which lights to add to the world or which to bake into a light
probe grid:

```dart
final grid = LightClusterGrid3D();
for (final lamp in lamps) {
  final entry = ClusterLightEntry3D.fromSceneLight(lamp);
  if (entry != null) {
    grid.addLight(entry);
  }
}
grid.assignLights(view, projection, near: 0.5, far: 200);
final selection = grid.gatherTopLightsForAabb(
  Aabb3.minMax(Vector3(-2, 0, -2), Vector3(2, 3, 2)),
  view,
);
for (final index in selection.pointLightIndices) {
  final light = grid.lightAt(index);
}
```

- `LightClusterGrid3D(clustersX: 16, clustersY: 8, clustersZ: 16, maxLights: 512,
  maxLightsPerCluster: 64)`. Lights beyond `maxLights` are not added; a cluster keeps its first
  `maxLightsPerCluster` lights.
- `ClusterLightEntry3D.point` and `.spot` describe a light by its position, range (`12` and `16`
  by default), cone, color, intensity and light mask; `fromSceneLight` converts a scene `Light`,
  using `fallbackRange` (`20`) for lights without a range.
- `assignLights(view, projection, near:, far:, cameraMask:)` bins the lights: each light is tested
  (sphere against cluster box, plus a cone test for spot lights) against the clusters its depth
  range covers. Its buffers are allocated once in the constructor; the cost grows with the number
  of lights times the clusters they cover.
- `lightsForCluster`, `clusterIndexForScreenDepth` and `zSliceForViewDepth` read the result;
  `gatherTopLightsForAabb(worldAabb, view, maxPointLights: 8, maxSpotLights: 4)` returns the
  strongest lights reaching a box (scored by intensity and distance to its center), allocating the
  result lists.
- `packClusterDataRgba8` and `createClusterLookupTexture` pack the cluster table into 8-bit texels
  for a shader of your own: an offset above 65,535, a count above 255 or a first light index above
  255 does not fit, and they throw a `StateError` rather than wrap it. No index list texture is
  provided.


## Image-based lighting

Image-based lighting lights `SpatialMaterial` surfaces with a picture of their surroundings: a
diffuse term from spherical harmonics and reflections from an equirectangular panorama. Only
`SpatialMaterial` uses it, and only on native backends for the parts below marked so.


### Environment probes

An `EnvironmentProbe3D` holds 9 spherical-harmonic coefficients (`shCoefficients`, bands `L0..L2`,
RGB) of the light around a point, and a `reflectionTexture`, an equirectangular panorama with
mip levels blurred for rough surfaces. Give it to a material's `environmentProbe`:

```dart
final sky = EnvironmentProbe3D.skyDome(
  zenithColor: const Color(0xFF0F2952),
  horizonColor: const Color(0xFF5BA4CF),
  groundColor: const Color(0xFF1E293B),
  sunDirection: Vector3(-0.45, -0.65, -0.6),
);
final chrome = SpatialMaterial(
  metallic: 1,
  roughness: 0.15,
  environmentProbe: sky,
);
```

- `EnvironmentProbe3D.fromEquirectangular(pixels, width:, height:, intensity: 1, srgb: true)` reads
  an RGBA8 panorama of aspect 2:1 (for example the bytes of `Image.toByteData()`). It projects the
  pixels onto the spherical harmonics on the CPU, synchronously, in time proportional to the pixel
  count. With `srgb: true` (the default, right for images) the pixels are decoded with the sRGB
  curve first, and the panorama becomes the reflection texture as an sRGB texture that the GPU
  decodes when sampling, so reflections and diffuse light see the same linear values; on devices
  without sRGB textures it is decoded on the CPU into a linear 8-bit texture, which loses precision
  in dark areas. With `srgb: false` the bytes are linear values, used as they are. The texture is
  uploaded on first use with up to 6 mip levels, each a Gaussian blur of the previous one computed
  in linear light (an approximation of prefiltering for rough reflections) that wraps
  horizontally.
- `EnvironmentProbe3D.skyDome(...)` paints a 128 x 64 panorama of a sky gradient with a sun glow
  (defaults: zenith `0xFF0A2463`, horizon `0xFF60A5FA`, ground `0xFF334155`, sun direction
  `(-0.4, -0.8, -0.3)`, `sunIntensity: 1.2`) and bakes it the same way. Its defaults differ from
  `SkyboxMaterial3D`'s: pass the colors of your skybox to make reflections match it.
- `EnvironmentProbe3D(shCoefficients:, reflectionTexture:, intensity:)` takes coefficients and a
  texture made elsewhere; `evaluateIrradiance(normal)` evaluates the diffuse term on the CPU.
- Panoramas are mapped with `+Y` up: `u = atan2(z, x) / 2π + 0.5`, `v = 0.5 - asin(y) / π`.

What `SpatialMaterial` does with it:

- Diffuse: it adds `kD * base * E(n) / π * intensity` to the ambient term, where `E` is the
  irradiance the coefficients give for the normal (the Ramamoorthi-Hanrahan cosine convolution),
  divided by `π` like the light of the direct lights: a uniform panorama of value `v` lights a
  surface as an ambient or hemisphere light of value `v` does. `intensity` scales this diffuse term
  only.
- Reflections: it samples `environmentTexture` when set, else the probe's reflection texture, along
  the reflected view direction at the mip level `roughness * (mip levels - 1)`, scaled by
  `environmentIntensity`. On native backends the reflection is weighted by the split-sum BRDF
  below; on the web by a Fresnel term and `1 - 0.75 roughness`, without picking a mip level by
  roughness.
- An `environmentTexture` alone gives reflections without the diffuse term. It should be a 2:1
  panorama with `wrapU: TextureWrap.repeat`, linear filtering and mipmaps; without mipmaps every
  roughness reflects sharply.
- The occlusion map darkens both; shadows do not.

Probes are LDR: the panorama is stored in 8 bits, so a sun brighter than white cannot be
represented. Devices that cannot sample mip levels uploaded by hand (some OpenGL ES devices) get
the full-size level only, and rough surfaces then reflect as sharply as smooth ones.


### Split-sum specular and the BRDF lookup table

On native backends, reflections use the split-sum approximation: the environment sample is
multiplied by `F0 * A + B`, where `A` and `B` come from a 64 x 64 lookup table indexed by `n·v` and
roughness, plus a multiple-scattering term (Kulla-Conty style energy compensation) that keeps rough
metals from getting too dark. A clear-coat layer makes a second lookup. `BrdfLut3D.sharedTexture()`
generates the table on the CPU the first time a pass binds it (4,096 texels of 64 importance
samples each, a one-time cost on the first frame that draws a `SpatialMaterial`) and shares it; it
is bound automatically to every shader that declares `brdfLutTexture`. `BrdfLut3D.integrateBrdf`
and `generateRgba8` compute it for tools and tests.


### Reflection probe volumes

A `ReflectionProbeVolume3D` is a component that holds an `EnvironmentProbe3D` for a box of the
world, for indoor reflections:

```dart
final hall = EnvironmentProbe3D.fromEquirectangular(
  (await panorama.toByteData())!, // RGBA8888, 2:1
  width: panorama.width,
  height: panorama.height,
);
world.add(
  ReflectionProbeVolume3D(
    probe: hall,
    position: Vector3(0, 2, 0),
    extents: Vector3(6, 2, 4), // half-sizes of the room
  ),
);
```

| Parameter       | Default     | Meaning                                                      |
| --------------- | ----------- | ------------------------------------------------------------ |
| `probe`         | required    | the environment of the box                                   |
| `extents`       | `(5, 5, 5)` | half-sizes of the box, times the component's scale           |
| `blendDistance` | `1`         | the weight fades from `1` to `0` this far outside the box    |
| `boxProjection` | `true`      | re-aims reflections from the box walls (parallax correction) |
| `priority`      | `0`         | higher wins; it is also the component's `Component.priority` |

The box is axis-aligned in world space: the component's rotation is ignored. With box projection,
the reflected ray is intersected with the box and the direction from the box center to the hit is
used, so reflections of a room line up with its walls (`parallaxCorrectRay` does the same on the
CPU).

How the volumes are used, per object:

- Only a `SpatialMaterial` without its own `environmentTexture` or `environmentProbe` uses volumes
  (`Material.usesReflectionProbes`); a material with an environment of its own is not affected by
  them.
- Each draw of such a material gets the volume around it, chosen when the draw is recorded at the
  center of the drawn surface's bounds in world space: the volume with the highest `priority`
  whose weight there is above zero, then the one with the highest weight. An instanced draw of
  your own (`RenderContext3D.drawInstances`, `InstancedGroup3D`) gets one volume for all its
  instances, chosen at its `center`, or at the camera position when it has none.
- The drawn object then takes the volume's reflection texture, its diffuse coefficients and its
  box for box projection, all scaled by the volume's weight at the object: an object crossing the
  `blendDistance` band at the edge of a box fades out its reflections and diffuse light, and an
  object outside every volume gets none.
- Objects of one surface and material are batched only with those that got the same volume and
  the same weight: objects deep inside one volume (weight `1`) still share a batch, objects in
  different rooms or in a blend band are drawn apart. The volumes' boxes are read once per pass;
  choosing a volume costs a pass over the volumes per recorded draw and allocates nothing.
- Volumes do not blend with each other: in the overlap of two volumes the object takes one of
  them.

`RenderContext3D.reflectionProbe` and `reflectionProbeWeight` give the chosen volume to the `apply`
of a material of your own that overrides `usesReflectionProbes`.


### Light probe grids

A `LightProbeGrid3D` stores spherical-harmonic probes on a lattice over a box of the world and adds
their light to the ambient term of `SpatialMaterial` surfaces inside it (native only):

```dart
world.lightProbeGrid = LightProbeGrid3D.bakeFromLights(
  bounds: Aabb3.minMax(Vector3(-20, 0, -20), Vector3(20, 6, 20)),
  lights: torches, // not added to the world
  resolutionX: 8, // 8 x 2 x 8 probes
  resolutionZ: 8,
  ambientIntensity: 0,
);
```

- `LightProbeGrid3D(bounds:, resolutionX: 4, resolutionY: 2, resolutionZ: 4, intensity: 1)` makes
  an empty grid; `setProbeSh9(ix, iy, iz, coefficients)` fills a probe; `sampleSh9At` and
  `sampleIrradiance(position, normal)` read it on the CPU with trilinear interpolation and the full
  spherical harmonics. The coefficients hold radiance projected onto the spherical harmonics, and
  `sampleIrradiance` gives irradiance: a surface of albedo `a` reflects `a * E / π` of it, which is
  what `SpatialMaterial` adds (times `kD` and `intensity`).
- `bakeFromLights(bounds:, lights:, ..., ambientColor: white, ambientIntensity: 0.02)` evaluates
  every light at every lattice point analytically: no occlusion, no bounced light. It stores direct
  light, not global illumination, scaled so that a baked light lights a surface as it does as a
  world light (exactly for ambient and hemisphere lights; directional, point and spot lights are
  approximated by band 2 of the harmonics, which softens their falloff around the surface). Lights
  baked into the grid and also left in the world light twice.
- On the GPU every probe is stored as the irradiance its spherical harmonics give along
  `+X`, `-X`, `+Y`, `-Y`, `+Z` and `-Z`, packed into a strip texture (`volumeTextureFor`) as
  `sqrt(E / range)` in 8 bits, where `range` (`volumeTextureRange`) is the grid's largest value, so
  bright probes do not clip and dim ones keep their precision. Each fragment reads the six values
  trilinearly and rebuilds the irradiance for its normal `n` as the sum over the axes of
  `n² (E₊ + E₋) / 2 + n (E₊ - E₋) / 2`. This is what `sampleIrradiance` gives without the three
  mixed terms of band 2 (`xy`, `yz`, `zx`): exact for surfaces facing an axis and for smooth light
  such as an ambient or hemisphere light, close for light from oblique directions. A probe lit from
  one side leaves the other side dark.
- The texture is uploaded again on the next pass after a probe changes. Changing probes does not
  mark the scene changed (see [Changing lights at run time](#changing-lights-at-run-time)).

The grid is useful as a cheap stand-in for many static local lights: bake them into it instead of
adding them, and areas take their color and brightness, and the side the light comes from, without
the per-pass light limits.


### Lightmaps

`SpatialMaterial.lightmapTexture` adds baked light, `kD * base * lightmap * lightmapIntensity`, to
the ambient term (darkened by the occlusion map, not by shadows). It is sampled with the second
texture coordinates (`vertexTexCoord1`), or the first ones on surfaces without a second set, without
`uvScale` and `uvOffset`. The engine does not bake lightmaps: bake them in a modeling tool into a
second UV set. The glTF loader reads only the first UV set, so give the second one with
`Surface.computeTangents(texCoord1: ...)` or `Vertex(texCoord1: ...)`, which switch the surface to
`VertexLayout.pbrStandard` (see [Materials](materials.md#maps-and-texture-coordinates)). Lightmaps
are native only.


## Fog and lighting

Fog (`World3D.fog`, see [Materials](materials.md#atmospheric-fog)) is applied by each material at
the end of its fragment shader, after lighting:

- `SpatialMaterial` without HDR fogs the tone-mapped, gamma-encoded color, so the fog color appears
  as given. With `World3D.hdrEnabled` it fogs its extended-range sRGB color (not tone-mapped), which
  the composite then decodes and tone-maps: the fog color is changed by the tone map, as every
  material's colors are.
- `StylizedMaterial` fogs its graded color before multiplying it by its alpha; `WaterMaterial` and
  `BillboardMaterial3D` fog their final color.
- Fog does not change the light: lights are not dimmed by it, and it adds no light scattering or
  glow around lights. Unlit materials, decals, particles, ribbons and the skybox are not fogged.


## Changing lights at run time

Every pass writes the current values of the lights, the fog and the probes, so changing them takes
effect on the next frame. Adding or removing a light, changing its component's transform or its
`lightMask`, assigning a field of a light source (`color`, `intensity`, `range`, `direction`, the
cone, `shadows`, a hemisphere light's colors and `up`), setting `World3D.fog`,
`World3D.lightProbeGrid` or adding a reflection probe volume also marks the scene changed
(`World3D.sceneVersion`), which wakes an idle-throttled game loop and invalidates a
`Scene3DComponent` that caches its image (`Scene3DCacheMode.retained`). Changes that cannot move a
shadow (a color, an intensity) keep a static shadow map cached with
`ShadowSettings.cacheWhenStatic`; those that can (a direction, a range, a cone, shadow settings)
render it again.

A light source cannot see a change made in place, inside one of its objects: a direction vector
changed with `setValues`, or a field of its `ShadowSettings`. Call `source.markChanged()` after such
a change (`markChanged(shadows: false)` when it cannot move a shadow).

The engine cannot see changes to the fields of the current `FogSettings`, of a probe
(`LightProbeGrid3D.setProbeSh9`, an `EnvironmentProbe3D`'s `intensity`) or of a material: a
retained `Scene3DComponent` keeps showing the old image until something else changes. Call
`world.markSceneDirty(shadows: false)` (or `Scene3DComponent.markDirty()`) after such changes, see
[Embedding](embedding.md#retained-layer-caching) and
[Basic Concepts](basic_concepts.md#scene-versions-and-dirty-marking).


## Costs

- Light uniforms are written once per pass per block; selecting lights costs a pass over the light
  list. The cost that matters is per fragment: `SpatialMaterial` evaluates a full GGX term for every
  light of the pass on every covered pixel, `StylizedMaterial` a cheaper term.
- Image-based lighting on native backends: 1 to 2 reflection reads and 1 to 2 lookup-table reads
  per fragment, the spherical harmonics in a few multiply-adds, and 12 reads for a light probe
  grid.
- Baking: `EnvironmentProbe3D.fromEquirectangular` and `bakeFromLights` run on the calling isolate,
  synchronously; the probe's blurred mip levels and the BRDF table are computed on the first frame
  that uses them. Keep panoramas small (the 128 x 64 of `skyDome` is enough for diffuse light and
  rough reflections), or bake them during loading.
- Reflection probe volumes cost a pass over the volumes per recorded draw of a material that uses
  them, and can split batches (see [Reflection probe volumes](#reflection-probe-volumes)). Light
  masks cost nothing beyond the selection.


## Light uniform blocks

Custom shaders read the lights by including `flame_3d/lights.glsl` and listing its blocks in their
material's slots (see [Materials](materials.md#custom-shaders)):

| Block               | Members                                                                 |
| ------------------- | ----------------------------------------------------------------------- |
| `AmbientLight`      | `color`, `intensity`                                                    |
| `HemisphereLight`   | `skyColor`, `groundColor`, `up`, `intensity`                            |
| `DirectionalLights` | `numLights`, `directions[4]`, `colors[4]`                               |
| `Lights`            | `numLights`, `positions[8]`, `colors[8]`, `intensities[8]`, `ranges[8]` |
| `SpotLights`        | `numLights`, `positions[4]`, `directions[4]`, `colors[4]`, `cones[4]`   |

- `numLights` is a float (some OpenGL ES drivers fail with integer uniforms).
- A directional light's `directions[i].xyz` is the unit vector from a surface towards the light and
  `.w` its specular factor; `colors[i].rgb` is its color and `.a` its intensity.
- A point light's intensity is `intensities[i].x` and its range `ranges[i].x`, `0` for an
  inverse-square falloff.
- A spot light's `directions[i].xyz` is the opposite of the way its light travels (the unit vector
  from a lit surface on its axis towards the light), `.w` is its specular factor, `colors[i]` is
  `(rgb, intensity)` and `cones[i]` is `(cos outer, 1 / (cos inner - cos outer), range, 0)`.
- The ambient intensity is `0` when a hemisphere light replaces the default ambient light, and the
  hemisphere intensity is `0` when the scene has none.


## Limitations

- At most 4 directional, 8 point and 4 spot lights light a pass, chosen per pass from the camera's
  point of view. There are no per-object light lists and no clustered or tiled shading: the
  `LightClusterGrid3D` is not used by the renderer.
- A shadow-casting spot or point light that the per-pass selection leaves out casts no shadow in
  that pass.
- Reflections: one volume per object (one per instanced draw of your own), no blending between
  overlapping volumes; boxes are axis-aligned; `priority` is the component's ordering priority as
  well.
- Probes are 8-bit (LDR): a panorama brighter than white cannot be represented. The blurred mip
  levels are a Gaussian approximation of prefiltering and are missing on devices without manually
  uploaded mip levels.
- Light probe grids are baked without occlusion, and on the GPU they drop the mixed terms of band 2
  of each probe's spherical harmonics (see [Light probe grids](#light-probe-grids)).
- Changing the fields of the current `FogSettings` or of a probe in place does not invalidate a
  retained `Scene3DComponent` image (see
  [Changing lights at run time](#changing-lights-at-run-time)).
