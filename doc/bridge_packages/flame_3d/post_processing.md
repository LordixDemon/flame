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
read back by the composite, which is the dominant cost of an otherwise empty post chain. With
MSAA (`Game3D.msaa()`, `Scene3DComponent.msaa`), the scene renders into a transient multisampled
texture resolved into that target at the end of the pass, as it would into the output image; the
composite and the bloom passes have one sample. On backends without texture targets nothing of
this page runs.

Everything in `PostProcessSettings` and the final bloom step happen in that one pass, in this
order, on each pixel:

1. FXAA, when on, replaces the scene sample.
2. Depth of field, then SSAO, when the depth-normal texture is there.
3. With `hdrEnabled`, the scene color is decoded to linear light (see [HDR](#hdr)).
4. Bloom is added.
5. Exposure multiplies the color.
6. Tone mapping.
7. With `hdrEnabled`, sRGB encoding (except after `ToneMapMode.agx`, whose output is already
   display-encoded).
8. Contrast, saturation, tint.
9. The color LUT.
10. The vignette.
11. The color is clamped to `[0, 1]`; the alpha of the scene is kept as it is.

The scene's colors are premultiplied by their alpha. Steps 5 to 10 can turn black into another
color (a `contrast` below `1`, a LUT whose black is not black); that change is applied to the
covered part of each pixel only, so a pixel of alpha `a` gets it in proportion `a`, and a
transparent pixel stays transparent.


## HDR

```dart
final world = World3D(hdrEnabled: true);
```

With `hdrEnabled`, the scene renders into a `GpuPixelFormat.rgbaFloat16` target where the backend
can render into float textures (Metal, Vulkan), so lights brighter than white keep their value
until the composite tone-maps them.

Every material writes that target sRGB-encoded, with the range extended above `1`:

- the native `SpatialMaterial` shader encodes its lighting without a tone curve (instead of its
  own `c / (1 + c)` curve and 2.2 gamma), so a light twice as bright as white is stored above `1`;
- `StylizedMaterial`, `UnlitMaterial`, `WaterMaterial`, particles, the skybox, billboards and the
  other materials write the display colors they write without HDR.

Translucent draws therefore blend in the same space as without HDR. The bloom bright-pass and the
composite decode the scene to linear light, add bloom, apply the exposure and the tone map (ACES
when `postProcess` is `null`, otherwise `postProcess.toneMap`) and encode the result to sRGB again.
With `ToneMapMode.none` and an exposure of `1`, a material that writes display colors looks exactly
as it does without HDR, and bloom extracts what is above its threshold from the unclamped values,
so a threshold of `1` or more blooms only what is brighter than white.

Cost: the scene target holds 8 bytes per pixel instead of 4, and the scene pass writes twice as
many bytes; with bloom, its two half-size targets are float too. For a 1170 by 2532 phone screen,
the scene target alone is 23.7 MB instead of 11.9 MB.

When a `postProcess` is set, its `toneMap` applies, and its default is `ToneMapMode.none`: giving
an HDR world a `PostProcessSettings` for a vignette alone turns tone mapping off, and everything
above white clips. Set `toneMap` explicitly with HDR.

On OpenGL ES, float targets are not used: the scene renders into an 8-bit target. The picture is
the same as on other backends, except that values above `1` clip before bloom and tone mapping,
so bloom thresholds of `1` or more never trigger and tone mapping has no highlights to compress.

A `RenderTexture3D` and the passes of a world that does not go through the composite render
without HDR: `SpatialMaterial` applies its own tone curve there.


## Tone mapping and exposure

`PostProcessSettings.exposure` (default `1`) multiplies the color before tone mapping.
`toneMap` is one of:

- `ToneMapMode.none`: no curve (the default);
- `ToneMapMode.reinhard`: `c / (1 + c)` per channel;
- `ToneMapMode.acesFilmic`: a common fit of the ACES curve;
- `ToneMapMode.agx`: the base look of Blender's AgX, in a common polynomial fit: a log2 encoding
  from 12.47 stops below to 4.03 stops above middle gray, a sigmoid, and AgX's inset and outset
  color matrices, which keep hues in bright saturated colors. Its output is display-encoded.

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
It costs less than MSAA, and also smooths edges inside textures and the edges of translucent
draws.


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

Translucent draws, draws without depth writes and draws of materials whose instances do not hold
model matrices (`Material.instancesHoldModelMatrices` is `false`: particles, billboards, ribbons,
camera-facing text) are left out. Every surface is drawn at its rest
position: vertex animation done in a material's vertex shader (the wind of `StylizedMaterial`) is
not seen, skinning is. Shaders read the texture through the `depthNormalTexture` sampler and the
`DepthNormal` block (`params.x` is `1` when the texture is valid, `params.yz` its texel size); the
depth is decoded as `(r * 255 * 256 + g * 255) / 65535`.

The depth is the normalized device depth `z / w` the GPU computes for each pixel, in `[0, 1]`.
With an orthographic or affine projection (the projections of `Scene3DComponent`) it is linear in
distance. With a perspective camera it is not: it crowds towards `1` with distance, reaching
`0.999` at about 1000 times the near plane distance, and the thresholds of the effects below then
mean different distances at different depths.


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
  pixel).
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
  keeps the scene's alpha and applies grading only to the covered part of each pixel, so
  transparent pixels stay transparent; the bloom glow over them is added to the 2D art behind the
  layer.
- Each layer runs its own post chain: two layers with bloom pay for two composites and two blurs.
  Prefer one layer with post-processing.
- A retained layer (`Scene3DCacheMode.retained`) renders again when the bloom and post-processing
  settings change, except SSAO, depth of field and `depthPrepassEnabled`, which are not in its key.


## Platform support

- Metal (iOS, macOS) and Vulkan (Android): everything on this page.
- OpenGL ES: no float targets, so HDR and bloom run in 8 bits and values above `1` clip (see
  [HDR](#hdr)); the prepass uses screen-space derivatives (`dFdx`, `dFdy`).
- Web: none of it. The bloom, composite and depth-normal shaders have no WebGPU bundle, so enabling
  any of these effects makes the first frame throw a `StateError`.


## Limitations

- HDR falls back to 8 bits on OpenGL ES, where colors above `1` clip (see [HDR](#hdr)).
- Opaque particles, billboards and camera-facing text are missing from the depth-normal texture:
  their instances do not hold model matrices, so the prepass leaves them out (see
  [Depth and sorting](ui_3d.md#depth-and-sorting)).
- SSAO and depth of field work in normalized depth with fixed thresholds and a screen-space radius:
  they do not scale with the world, and under a perspective camera they fade out with distance.
- The composite runs on premultiplied colors: tone mapping, which is not linear, is slightly off at
  anti-aliased and translucent edges of a layer over transparent pixels.
- Changing fields of the current settings objects does not mark the scene as changed (see
  [Turning it on](#turning-it-on)).
