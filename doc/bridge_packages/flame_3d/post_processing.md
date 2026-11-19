# Post-Processing

`flame_3d` can process the image of a `World3D` before it reaches the screen: render it in HDR and
tone-map it, grade its colors, add bloom, a vignette or FXAA, and use a depth-normal prepass for
ambient occlusion, depth of field, soft particles and shoreline foam. This page describes each
effect, what it costs on the GPU and the CPU, and how it behaves in a `FlameGame3D` and in a
`Scene3DComponent` layer.


## Turning it on

The settings live on the `World3D`; a `Scene3DComponent` forwards them to its world:

```dart
final world = World3D(
  hdrEnabled: true,
  bloom: BloomSettings(threshold: 1.2, intensity: 0.5),
  postProcess: PostProcessSettings(
    toneMap: ToneMapMode.acesFilmic,
    exposure: 1.1,
    vignetteIntensity: 0.25,
    fxaa: true,
  ),
);
final game = FlameGame3D(world: world);

final layer = Scene3DComponent(
  projection: projection,
  bloom: BloomSettings(),
  postProcess: PostProcessSettings(saturation: 1.15, fxaa: true),
);
```

`World3D.bloom`, `postProcess`, `hdrEnabled`, `renderDebugMode3D` and `depthPrepassEnabled` can be
changed at any time. Assign a new `BloomSettings` or `PostProcessSettings` object to change the
settings: their fields can be changed in place too and are read every frame, but changing a field
(or `depthPrepassEnabled`) does not mark the scene as changed, so a game loop that idles until
something changes does not render again. A retained `Scene3DComponent` compares the bloom and color
settings by value and does render again, but not for the SSAO and depth-of-field fields or
`depthPrepassEnabled` (see [Embedding](embedding.md#what-renders-the-layer-again)).


## The composite pass

Without post-processing, a world renders straight into the image Flutter draws. The world renders
into a full-size texture target instead, followed by one full-screen composite pass that writes the
output image, when any of these holds:

- `hdrEnabled` is `true`;
- `bloom` is set with an `intensity` and a `radius` above zero;
- `postProcess` is set and changes something: a tone map other than `ToneMapMode.none`, an
  exposure, contrast or saturation other than `1`, a vignette, a tint other than white, FXAA, a
  color LUT, SSAO or depth of field;
- `renderDebugMode3D` is `RenderDebugMode3D.depth` or `ssao`;
- an enabled custom pass runs at `CustomRenderPassStage3D.afterScene` (see
  [Rendering](rendering.md#custom-render-passes-and-rendergraph3d)).

Its base cost is one extra full-screen pass and one full-size texture target (4 bytes per pixel,
or 8 with HDR): on a tile-based phone GPU the scene's colors are written to memory once more and
read back by the composite, which is the dominant cost of an otherwise empty post chain. The
texture target has a single sample, so MSAA is off whenever the composite runs; use `fxaa` for
anti-aliasing. On backends without texture targets nothing of this page runs.

Everything in `PostProcessSettings` and the final bloom step happen in that one pass, in this
order, on each pixel:

1. FXAA, when on, replaces the scene sample.
2. Depth of field, then SSAO, when the depth-normal texture is there.
3. Bloom is added.
4. Exposure multiplies the color.
5. Tone mapping.
6. With `hdrEnabled`, linear to sRGB encoding.
7. Contrast, saturation, tint.
8. The color LUT.
9. The vignette.
10. The color is clamped to `[0, 1]`; the alpha of the scene is kept as it is.


## HDR

```dart
final world = World3D(hdrEnabled: true);
```

With `hdrEnabled`, the scene renders into a `GpuPixelFormat.rgbaFloat16` target where the backend
can render into float textures (Metal, Vulkan, WebGPU), so lights brighter than white keep their
value until the composite tone-maps them. The native `SpatialMaterial` shader then outputs linear
light with no tone curve (instead of its own `c / (1 + c)` curve and 2.2 gamma), and the
composite applies the tone map (ACES when `postProcess` is `null`, otherwise `postProcess.toneMap`)
and encodes the result to sRGB. Bloom then extracts what is above its threshold from the
unclamped values, so a threshold above `1` blooms only what is brighter than white.

Cost: the scene target holds 8 bytes per pixel instead of 4, and the scene pass writes twice as
many bytes; with bloom, its two half-size targets are float too. For a 1170 by 2532 phone screen,
the scene target alone is 23.7 MB instead of 11.9 MB.

```{note}
Only the native `SpatialMaterial` shader outputs linear light in HDR mode.
`StylizedMaterial`, `UnlitMaterial`, `WaterMaterial`, particles, the skybox,
billboards and the web's `SpatialMaterial` keep writing display colors, which
the composite then tone-maps and encodes to sRGB a second time: an opaque
`UnlitMaterial` of 50% gray shows at 81% gray. Enable HDR only for scenes
drawn with `SpatialMaterial` (see
[Choosing a material](materials.md#choosing-a-material)).
```

When a `postProcess` is set, its `toneMap` applies, and its default is `ToneMapMode.none`: giving
an HDR world a `PostProcessSettings` for a vignette alone turns tone mapping off, and everything
above white clips. Set `toneMap` explicitly with HDR.

On OpenGL ES, float targets are not used: the scene renders linear light into an 8-bit target
without a warning, values above `1` clip before tone mapping (with ACES nothing gets brighter than
about 91% on screen), dark gradients band, and bloom thresholds above `1` never trigger.


## Tone mapping and exposure

`PostProcessSettings.exposure` (default `1`) multiplies the color before tone mapping.
`toneMap` is one of:

- `ToneMapMode.none`: no curve (the default);
- `ToneMapMode.reinhard`: `c / (1 + c)` per channel;
- `ToneMapMode.acesFilmic`: a common fit of the ACES curve;
- `ToneMapMode.agx`: meant as an AgX-like curve, but broken, see [Limitations](#limitations).

Tone mapping is meant for HDR images. On an 8-bit scene, it reshapes colors that are already
display colors; `SpatialMaterial` has already applied its own `c / (1 + c)` curve to them.


## Contrast, saturation and tint

- `contrast` (default `1`) scales the color around `0.5`.
- `saturation` (default `1`) mixes the color with its luminance (`0.299 R + 0.587 G + 0.114 B`): `0`
  is grayscale, above `1` more saturated.
- `tint` (default white) multiplies the color.

They apply after tone mapping and sRGB encoding, on display colors.


## Color lookup tables

`PostProcessSettings.colorLut` grades the image with a 3D lookup table, blended in by
`colorLutIntensity` (default `1`, clamped to `[0, 1]`):

```dart
final grade = PostProcessSettings(
  colorLut: ColorLut3D.fromFunction(
    (r, g, b) => Vector3(r * 1.05, g, b * 0.92), // warmer
  ),
  colorLutIntensity: 0.8,
);
```

A `ColorLut3D` is a cube of `size` (16 by default, 2 to 64) entries per side, stored as a
`size * size` by `size` RGBA8 strip and sampled with trilinear filtering (two texture reads per
pixel). Build one with `ColorLut3D.fromFunction`, from strip bytes with `ColorLut3D.fromStripBytes`
(for example a LUT exported from an image editor), or use the presets `identity`, `warmCinematic`,
`coolNight` and `sepia`. The LUT maps display colors in `[0, 1]`: it applies after tone mapping and
the color adjustments. Its texture is created once per backend.


## Vignette

`vignetteIntensity` (default `0`, off) darkens the image towards its corners; `vignetteSmoothness`
(default `0.5`, at least `0.05`) is the width of the transition. The distance is measured from the
center of the rendered image, `0` at the center and `1` in the corners.

In a `Scene3DComponent` the rendered image covers only the part of the screen the scene occupies,
rounded up in size, so the vignette is centered on neither the screen nor the scene, and it moves as
the 2D camera pans. Draw a screen vignette in 2D over the whole game instead.


## FXAA

`fxaa: true` smooths edges with a fast approximate anti-aliasing filter: five reads of the scene per
pixel, and four more on pixels whose luminance differs from their diagonal neighbors by more than
`max(0.0312, 0.125 * maximum luminance)`. It runs first, on the scene's colors before tone mapping.
It is the anti-aliasing that remains once the composite pass turns MSAA off.


## Bloom

`World3D.bloom` adds a glow around bright pixels:

```dart
world.bloom = BloomSettings(
  threshold: 0.8, // brightness above which pixels glow
  softKnee: 0.5, // width of the transition around the threshold, 0 to 1
  intensity: 0.6, // strength of the glow added back, 0 turns bloom off
  radius: 1.0, // spread of the blur, in half-size texels
  passes: 2, // blur passes, 1 to 4
);
```

The values shown are the defaults. Bloom renders, before the composite:

1. a bright-pass into a half-size target: four reads of the scene per pixel, averaged, and the
   part of the brightest channel above the threshold kept, with a soft knee;
2. `passes` blur passes, alternating between that target and a second half-size one, each a 5-tap
   filter whose taps spread by `(i + 0.5) * radius` texels in pass `i`.

The composite adds the blurred image times `intensity`, before exposure and tone mapping. The two
targets are half the width and height of the scene, 8-bit (float with HDR). Bloom adds
`1 + passes` passes, each over a quarter of the scene's pixels.

Without HDR the scene is 8-bit and nothing is brighter than `1`, so a `threshold` of `1` or more
gives no bloom. The glow is added to the color and leaves the alpha alone: in a `Scene3DComponent`
the glow over transparent parts of the layer is added to the 2D art behind it. Bloom is skipped
while a debug view is on.


## Depth-normal prepass

Several effects need the depth and the orientation of the opaque surfaces behind each pixel. The
depth-normal prepass renders them, before the main pass, into a half-width, half-height `rgba8888`
texture target: the depth in 16 bits (red and green) and the view-space normal's x and y (blue
and alpha), the normal computed per pixel from the screen-space derivatives of the position (so it
is the faceted normal of the triangle, not the mesh's smooth normal).

It runs when `World3D.depthPrepassEnabled` is `true`, when `postProcess` has SSAO or depth of
field, or when the debug view is `depth` or `ssao`. Soft particles and shoreline foam do not turn it
on by themselves: set `depthPrepassEnabled`.

```dart
final world = World3D(depthPrepassEnabled: true);
```

What it costs:

- the CPU traverses and records the whole world once more (culling, `draw` methods, particle
  sorting), as for a shadow pass;
- the GPU draws every opaque draw that writes depth again, batched as in the main pass, with a
  shader that only writes depth and normal, into a quarter of the scene's pixels;
- one quarter-size 8-bit target (and its transient depth buffer).

Translucent draws and draws without depth writes are left out. Every surface is drawn at its rest
position: vertex animation done in a material's vertex shader (the wind of `StylizedMaterial`) is
not seen, skinning is. Shaders read the texture through the `depthNormalTexture` sampler and the
`DepthNormal` block (`params.x` is `1` when the texture is valid, `params.yz` its texel size); the
depth is decoded as `(r * 255 * 256 + g * 255) / 65535`.

The depth is the normalized device depth `z / w`, in `[0, 1]`. With an orthographic or affine
projection (the projections of `Scene3DComponent`) it is linear in distance. With a perspective
camera it is not: it crowds towards `1` with distance, reaching `0.999` at about 1000 times the
near plane distance, and the thresholds of the effects below then mean different distances at
different depths. See also [Limitations](#limitations) for large triangles under a perspective
camera.


### Ambient occlusion (SSAO)

`PostProcessSettings.ssaoIntensity` (default `0`, off) darkens pixels whose neighbors are closer to
the camera, such as creases and contact areas:

```dart
world.postProcess = PostProcessSettings(ssaoIntensity: 0.8, ssaoRadius: 1.5);
```

In the composite, each pixel reads the depth-normal texture at 8 points along a spiral of
`max(ssaoRadius, 0.5) * 4` pixels (6 pixels with the default `1.5`); a point occludes when it is
closer by between 0.0006 and 0.065 in depth, weighted by how much its normal differs. The result
darkens the whole color of the pixel (direct light and emission included), by at most 88%. Pixels
at depth `0.999` or more (the background, and far surfaces under a perspective camera) get none.

Cost: the prepass, and 9 texture reads per pixel in the composite.


### Depth of field

`dofBlurStrength` (default `0`, off) blurs what is outside a focus band:

```dart
world.postProcess = PostProcessSettings(
  dofFocusDepth: 0.5, // depth in focus, 0 to 1
  dofFocusRange: 0.15, // half-width of the sharp band
  dofBlurStrength: 0.7,
);
```

`dofFocusDepth` and `dofFocusRange` are normalized depths, as stored by the prepass, not distances.
Outside the band, the blur grows over one more `dofFocusRange` (at least 0.02) to its maximum of
`5.5 * dofBlurStrength` pixels: 8 reads of the scene in a spiral, averaged with equal weights. The
blur does not look at the depth of the pixels it reads, so sharp foreground objects bleed into a
blurred background.


### Soft particles

`ParticleMaterial.softDepthFade` (default `0`, off) fades billboard particles where they come close
to the opaque surface behind them, over that span of normalized depth, so smoke does not cut a hard
line where it meets the ground. It needs `depthPrepassEnabled`. See
[Soft particles](particles.md#soft-particles).


### Shoreline foam

`WaterMaterial.shoreFoamDepth` (default `0`, off) adds foam and fades the water where the opaque
ground under it is within that span of normalized depth. It needs `depthPrepassEnabled`. See
[Materials](materials.md).


## Debug views

`World3D.renderDebugMode3D` (also on `Scene3DComponent`) replaces the image with a view of one
part of the renderer:

- `depth` and `ssao` show the depth-normal texture's depth (white near, black far) and the
  ambient occlusion term (with a strength of at least `1`). They turn the prepass and the composite
  on by themselves.
- `wireframe` draws every draw's triangle edges (not on the web or OpenGL ES, see
  [Rendering](rendering.md#wireframe-and-primitive-topology)).
- `RenderDebugMode3D.overdraw` draws every draw additively without depth test; `SpatialMaterial`
  writes a small constant color, so bright areas are drawn over many times. Other materials add
  their normal color.
- `normals`, `roughnessMetallic`, `albedo` and `cascadeSplits` are written by the native
  `SpatialMaterial` shader only: the normal mapped to colors, the roughness and metallic values, the
  base color, and a tint per shadow cascade. Other materials draw as usual.

While a debug view is on, the composite skips bloom and color grading.


## Costs at a glance

For a scene of `W` by `H` pixels:

- Composite (any of the triggers above): +1 full-screen pass, +1 `W x H` target (4 bytes per
  pixel), MSAA off.
- HDR: the scene target and the bloom targets become 8 bytes per pixel.
- Tone mapping, exposure, contrast, saturation, tint, vignette: arithmetic in the composite.
- Color LUT: +2 texture reads per pixel. FXAA: +4 to +8.
- Bloom: +1 bright-pass and +`passes` blur passes at `W/2 x H/2`, +2 half-size targets.
- Depth-normal prepass: +1 world traversal on the CPU, +1 pass at `W/2 x H/2` redrawing the opaque
  geometry, +1 quarter-size 8-bit target.
- SSAO: the prepass, +9 reads per pixel. Depth of field: the prepass, +8 reads per pixel. Soft
  particles and shoreline foam: the prepass, +1 read per fragment of the particle or water.

On a phone, the passes over full-size targets dominate: on tile-based GPUs each one writes its
target to memory and the next one reads it back. Start from the composite pass alone and add effects
one at a time, measuring with `RenderStats` and the frame time (see
[Rendering](rendering.md#frame-output-and-statistics)).


## In a `Scene3DComponent` and in a `FlameGame3D`

The pipeline is the same; what differs is the image it runs on.

- A `FlameGame3D` camera renders its viewport, at `World3D.renderScale` times the device pixels, and
  the composite runs over that image.
- A `Scene3DComponent` renders only the part of the screen its scene covers, into a target whose
  size is rounded up and kept while the visible part shrinks; the composite runs over that whole
  target. Effects measured on the image (the vignette, the edges of bloom and depth of field) follow
  that region, not the screen.
- A layer's background is transparent and is drawn over the 2D components behind it. The composite
  keeps the scene's alpha, so what it adds to transparent pixels is added to the 2D art: the bloom
  glow (intended), but also the lift of a `contrast` below `1`, a LUT that maps black to a color,
  and the gray of `ToneMapMode.agx`.
- Each layer runs its own post chain: two layers with bloom pay for two composites and two blurs.
  Prefer one layer with post-processing.
- A retained layer (`Scene3DCacheMode.retained`) renders again when the bloom and post-processing
  settings change, except SSAO, depth of field and `depthPrepassEnabled`, which are not in its key.


## Platform support

- Metal (iOS, macOS) and Vulkan (Android): everything on this page.
- OpenGL ES: no float targets, so HDR and bloom run in 8 bits (see [HDR](#hdr)); the prepass uses
  screen-space derivatives (`dFdx`, `dFdy`).
- Web: none of it. The bloom, composite and depth-normal shaders have no WebGPU bundle, so enabling
  any of these effects makes the first frame throw a `StateError`.


## Limitations

- `ToneMapMode.agx` is broken: its curve maps black to 0.43 (0.69 after sRGB encoding, 175 of 255)
  and everything above about 5% linear light to white or nearly white, so the image is washed out
  and has no highlights. In a `Scene3DComponent` it adds that gray over the 2D art behind the
  layer. Use `ToneMapMode.acesFilmic`.
- HDR double-encodes every material but the native `SpatialMaterial` (see [HDR](#hdr)), and falls
  back to 8 bits on OpenGL ES without telling. Combined with order-independent transparency, it
  makes translucent surfaces black or invisible (see
  [Rendering](rendering.md#order-independent-transparency)).
- Under a perspective camera, the depth of a triangle that reaches behind the camera is wrong over
  the whole triangle in the depth-normal texture (it reads as `0`, the nearest depth), and large
  triangles in front of the camera get an approximate depth: the prepass interpolates the
  per-vertex `z / w` across the triangle instead of using the depth the GPU computes per pixel. A
  ground plane made of one quad that extends behind the camera breaks SSAO, depth of field, soft
  particles and shoreline foam over all of it. Subdivide large ground surfaces, or use an
  orthographic projection.
- The prepass draws particles of an opaque `ParticleMaterial` (cut-out billboards) as if their
  instance data were model matrices, which leaves stray triangles in the depth-normal texture.
  Opaque billboards and camera-facing font text store other data there too and are missing from
  the texture at their place (see [Depth and sorting](ui_3d.md#depth-and-sorting)).
- SSAO and depth of field work in normalized depth with fixed thresholds and a screen-space radius:
  they do not scale with the world, and under a perspective camera they fade out with distance.
- The composite runs on premultiplied colors: tone mapping and color grading are slightly off at
  anti-aliased and translucent edges.
- Changing fields of the current settings objects does not mark the scene as changed (see
  [Turning it on](#turning-it-on)).
