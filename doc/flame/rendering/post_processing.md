# Post Processing and Shaders

Post processing is a technique used in game development to apply visual effects to a component tree
after it has been rendered. Once a frame is rendered, either directly or rasterized into an
image, post processing can modify or enhance the visuals.

Post processing leverages fragment shaders to create dynamic visual effects such as blur, bloom,
color grading, distortion, and lighting adjustments.

In Flame, the post processing system is modular and flexible, allowing developers to:

- Define custom post processes by sub-classing the abstract class `PostProcess`.
- Apply a single post process effect or chain multiple effects using groups.
- Manage effects globally with the `CameraComponent` or locally with `PostProcessComponent`.


## Key Components of the Post Processing System

- **`PostProcess`**: Abstract base class for defining custom post-processing effects. Implement
  your effect logic in its `postProcess` method.

- **`ShaderPostProcess`**: A post process that draws a fragment shader, and takes care of loading
  it, rasterizing the subtree and setting the common uniforms.

- **`PostProcessComponent`**: Applies a post process specifically to its children, enabling
  localized effects.

- **`CameraComponent`**: Applies post processes globally to the entire scene or world.

- **`PostProcessGroup`**: Applies multiple post processes in parallel, useful when effects can be
  applied independently.

- **`PostProcessSequentialGroup`**: Applies post processes sequentially, where each process uses
  the output of the previous one.


## PostProcessComponent

```{dartdoc}
:package: flame
:symbol: PostProcessComponent
:file: src/post_process/post_process_component.dart
```


## ShaderPostProcess

Most post processes draw a fragment shader over the subtree. `ShaderPostProcess` does that for
you: it loads the shader, keeps track of the time, rasterizes the subtree when the shader samples
it, and draws the shader over the size of the post process. A shader that only needs the uniforms
that `ShaderPostProcess` sets doesn't need a subclass:

```dart
PostProcessComponent(
  postProcess: ShaderPostProcess('assets/shaders/grayscale.frag'),
  children: [player],
);
```

To use a `FragmentProgram` that is already loaded, for example one shared by several post
processes, use `ShaderPostProcess.fromProgram`.


### Uniforms set by ShaderPostProcess

Every frame, `ShaderPostProcess` sets these uniforms, if the shader declares them:

| Uniform                      | Value                                                 |
| ---------------------------- | ----------------------------------------------------- |
| `uniform vec2 uSize`         | The size of the post process, in logical pixels.      |
| `uniform float uTime`        | The seconds passed since the post process was loaded. |
| `uniform sampler2D uTexture` | The subtree, rasterized with `rasterizeSubtree`.      |

`uTexture` has to be the first sampler of the shader. Sample it with coordinates going from 0 to 1
across the size of the post process, for example `texture(uTexture, FlutterFragCoord().xy / uSize)`.


### Placement

The `placement` decides where the shader is drawn relative to the subtree:

| `ShaderPlacement` | What is drawn                              | For example                 |
| ----------------- | ------------------------------------------ | --------------------------- |
| `replace`         | Only the shader. This is the default.      | Pixelation, grayscale       |
| `over`            | The subtree, then the shader on top of it. | Fog, vignette, a glow       |
| `under`           | The shader, then the subtree on top of it. | A background, a drop shadow |

Whether the shader samples the subtree is independent of its placement. For example, a glow placed
`over` the subtree can sample `uTexture` to find its edges:

```dart
PostProcessComponent(
  postProcess: ShaderPostProcess(
    'assets/shaders/glow.frag',
    placement: ShaderPlacement.over,
  ),
  children: [player],
);
```


### Rendering the subtree

A shader that samples the subtree costs a `rasterizeSubtree` every frame, which is the expensive
part of a post process. A shader that doesn't sample it only costs rendering the subtree as usual,
when it's placed `over` or `under` the subtree.

When a shader that samples the subtree is placed `over` or `under` it, the image rasterized for
`uTexture` is also drawn as the subtree by default, so that the subtree is only rendered once per
frame. The image is rasterized at the `pixelRatio` of the post process, which is the pixel ratio of
the screen by default, so it's as sharp as rendering the subtree again. If you lower `pixelRatio`,
for example to make a glow cheaper, set `reuseRasterizedSubtree` to false, so that the subtree is
rendered again at the full resolution of the screen:

```dart
ShaderPostProcess(
  'assets/shaders/glow.frag',
  placement: ShaderPlacement.over,
  pixelRatio: 0.5,
  reuseRasterizedSubtree: false,
);
```

The `filterQuality` decides how the rasterized subtree is sampled, both by the shader through
`uTexture` and when it's drawn as the subtree. It only makes a difference when the pixels of the
image don't line up with the pixels of the screen, for example when the post process is rotated or
zoomed, or when `pixelRatio` is lowered. In those cases, the default, `FilterQuality.low`, keeps
edges smooth at no noticeable cost. Use `FilterQuality.none` to keep the pixels sharp instead, for
example for pixel art.


### Setting other uniforms

Set any other uniforms in `updateUniforms`, using the name of each uniform in the shader instead
of its position. Look each uniform up once, in `onLoad`, and set it every frame. The slot types,
like `UniformFloatSlot`, come from `dart:ui`:

```dart
class OutlinePostProcess() extends ShaderPostProcess {
  this : super('assets/shaders/outline.frag');

  double outlineWidth = 4;
  Color outlineColor = Colors.purpleAccent;

  late final UniformFloatSlot _outlineWidth;
  late final UniformVec4Slot _outlineColor;

  @override
  Future<void> onLoad() async {
    await super.onLoad();
    _outlineWidth = shader.getUniformFloat('uOutlineWidth');
    _outlineColor = shader.getUniformVec4('uOutlineColor');
  }

  @override
  void updateUniforms(Vector2 size) {
    _outlineWidth.set(outlineWidth);
    _outlineColor.setColor(outlineColor);
  }
}
```

Looking a uniform up by a name that the shader doesn't declare throws an `ArgumentError`, so a
typo is reported right away. Uniforms that the shader compiler removed because they're unused
can't be looked up either.

Flame adds methods to the uniform slots of `dart:ui` to set them from its own types:

- `UniformVec2Slot`: `setVector(Vector2)`, `setSize(Size)` and `setOffset(Offset)`.
- `UniformVec3Slot`: `setVector(Vector3)`.
- `UniformVec4Slot`: `setVector(Vector4)` and `setColor(Color, premultiply: false)`.
- `UniformMat2Slot`, `UniformMat3Slot` and `UniformMat4Slot`: `setMatrix` with a `Matrix2`,
  `Matrix3` or `Matrix4`.

These work on any `FragmentShader`, not only in a `ShaderPostProcess`.


### Shaders on the web

`ShaderPostProcess` detects whether the shader samples the subtree by looking up `uTexture` by name.
Flutter can't look up the samplers of a shader by name on the web yet, so if your game runs on the
web, pass `sampleSubtree` to say whether the shader samples the subtree:

```dart
ShaderPostProcess('assets/shaders/grayscale.frag', sampleSubtree: true);
ShaderPostProcess('assets/shaders/vignette.frag', sampleSubtree: false);
```

On the web, `sampleSubtree` is required, and loading the post process without it throws an error.

On the other platforms, `sampleSubtree` is optional, because the shader is checked directly. If you
pass it anyway and it's wrong, for example `true` for a shader without `uTexture`, loading the post
process throws an error. So running your game once on another platform checks the values you pass
for the web.


### Example: pixelation

Here’s an example of a pixelation effect made with `ShaderPostProcess`:

```dart
class PostProcessGame extends FlameGame {
  @override
  Future<void> onLoad() async {
    await super.onLoad();

    world.add(
      PostProcessComponent(
        postProcess: PixelationPostProcess(),
        position: Vector2(0, 0),
        anchor: Anchor.center,
        children: [
          EmberPlayer(size: Vector2(100, 100)),
        ],
      ),
    );
  }
}

class PixelationPostProcess() extends ShaderPostProcess {
  this
    : super(
        'packages/flutter_shaders/shaders/pixelation.frag',
        sampleSubtree: true,
      );

  late final UniformVec2Slot _pixels;

  @override
  Future<void> onLoad() async {
    await super.onLoad();
    _pixels = shader.getUniformVec2('uPixels');
  }

  @override
  void updateUniforms(Vector2 size) {
    _pixels.setVector(size / (20 * sin(time)));
  }
}
```

In this example:

- A fragment shader (`pixelation.frag`) is loaded and used to apply a pixelation effect.

- The shader declares `uTexture` and `sampleSubtree` is true, so `ShaderPostProcess` captures the
  component tree with `rasterizeSubtree` and passes it to the shader. The texture is rendered at the
  post process's `pixelRatio` and covers the whole subtree, so the shader can sample it with
  coordinates from 0 to 1 across `uSize`, which is also set by `ShaderPostProcess`.

- The only other uniform, `uPixels`, is looked up by name in `onLoad` and set from `time` in
  `updateUniforms`, creating an animated pixelation effect.

This example demonstrates how straightforward it is to add visual effects to your Flame game using
the post-processing system.

```{flutter-app}
:sources: ../flame/examples
:page: post_process
:show: widget code infobox
:width: 180
:height: 180
```

The pixelation shader file:

```glsl
#version 460 core

precision highp float;

#include <flutter/runtime_effect.glsl>

uniform vec2 uPixels;
uniform vec2 uSize;
uniform sampler2D uTexture;

out vec4 fragColor;

void main() {
  vec2 uv = FlutterFragCoord().xy / uSize;
  vec2 puv = round(uv * uPixels) / uPixels;
  fragColor = texture(uTexture, puv);
}
```


## Creating a Custom Post Process

For effects that need more control, for example rendering the subtree several times, implement a
post process yourself:

1. Subclass `PostProcess`.
2. Override the `postProcess` method, implementing your rendering logic with `renderSubtree` or
   `rasterizeSubtree`.
3. Optionally, implement `onLoad` and `update` methods for managing resources and updating effects
   each frame.

This system makes it easy to add creative and useful visual effects to your Flame game.


### The raster scale of offscreen pictures

On screen, components draw on a canvas in logical pixels: Flutter applies the device pixel ratio
after the picture is recorded, so `canvas.getTransform()` does not include it. `rasterizeSubtree`
scales the canvas of its picture by `pixelRatio` instead, and the components of the subtree see that
scale in the transform: the canvas units are already the pixels of the image. A component that
renders an image of its own at the resolution of the pixels it covers (a 3D layer, for example)
needs to know which of the two it draws on, and reads `RasterScale` (from
`package:flame/rendering.dart`):

```dart
@override
void render(Canvas canvas) {
  // Pixels per canvas unit: the canvas transform alone in an offscreen
  // picture, times the device pixel ratio on screen.
  final pixelRatio = RasterScale.isActive ? 1.0 : devicePixelRatio;
  // ...
}
```

`RasterScale.current` is the scale of the innermost offscreen picture, in its pixels per logical
pixel, or `null` on screen. These pictures also clip their canvas to the image, so
`canvas.getDestinationClipBounds()` gives the part of the canvas that reaches it. `rasterizeSubtree` and `rasterizePass` push it while the subtree
renders, and so do the offscreen world of a camera whose `effectiveWorldRenderScale` is not `1`,
`CameraComponent.renderToImageSync` (with `renderToImage` and `RenderTextureComponent`) and the
tiles of `renderHighResImageSync`. A post process of your own that records `renderSubtree` into a
picture of its own and scales its canvas pushes the scale with `RasterScale.push` and pops it with
`RasterScale.pop` (in a `finally`) around the call.


## Advanced Example: Crystal Ball

For a more advanced use case of post processing, check out the
[Crystal Ball example](https://examples.flame-engine.org/), which demonstrates camera-level post
processing and chaining multiple effects using `PostProcessSequentialGroup`.

![Crystal Ball Example](../../images/crystal_ball.png)

Here's how multiple post-processing effects are combined on a camera:

```dart
class CrystalBallGame extends FlameGame<CrystalBallGameWorld> {

  CrystalBallGame() : super(
          camera: CameraComponent.withFixedResolution(
            width: kCameraSize.x,
            height: kCameraSize.y,
          ),
          world: CrystalBallGameWorld(),
        ) {
    camera.postProcess = PostProcessGroup(
      postProcesses: [
        PostProcessSequentialGroup(
          postProcesses: [
            FireflyPostProcess(),
            WaterPostProcess(),
          ],
        ),
        ForegroundFogPostProcess(),
      ],
    );
  }
}
```


## Single-Pass & Dual-Pass Cached Shader Pipelines (`ShaderPostProcess`, `UniformSlotBuffer`, `DualPassShaderPostProcess`)

- **`ShaderPostProcess` & `UniformSlotBuffer`**: Base class for single-pass GPU `FragmentShader`
  post-processes that caches a single `FragmentShader` instance across frames, disposes transient
  subtree `ui.Image` textures without leaks, and pairs with `UniformSlotBuffer`, a thin writer for
  float uniforms (`setFloat`, `setVec2`, `setVec3`, `setVec4`). `FragmentShader.setFloat` only
  stores into a Dart-side array, so these calls pass every value straight through; only
  `setFloatCustom`, for an arbitrary uploader, is dirty-checked (`skippedCount`). While the effect
  is switched off (`enabled == false` or no program) the subtree is drawn untouched and the stage
  holds no frame image or shader.
- **`DualPassShaderPostProcess`**: For multi-pass effects such as separable bloom + ACES
  tone-mapping + vignette/bokeh. It rasterizes the subtree and the auxiliary pass into new images
  every frame and keeps the latest ones until the next frame replaces them; they are released
  when the effect is switched off, when its pipeline stage turns inactive, and in `onRemove()`
  (`releaseFrameResources()`). `dispose()` additionally frees the cached `FragmentShader`.
- **`PostProcessPipeline` & `PostProcessStage`**: Declarative quality-aware post-processing chain
  supporting per-stage `minQualityTier`, `activePredicate(GraphicsProfile)`, `resolutionScale` (e.g.
  `0.5` half-res bloom), automatic `DisplayMetrics.devicePixelRatio` propagation to the stages and pipelines built
  without an explicit `pixelRatio` (a ratio given at construction, or assigned by hand, is kept),
  and a zero-`toImageSync` fast bypass (`bypassedLastFrame`) when all stages are inactive. The
  bypass still draws the world at the camera's render scale.
- **`ContrastAdaptiveSharpenPostProcess`**: Single-pass 5-tap GPU sharpening stage (plus reusable
  GLSL helper `ContrastAdaptiveSharpenHelper.glslFunction`) to restore crisp detail when
  `camera.worldRenderScale < 1.0`.

Similarly, when applying `PaintDecorator.tint(...)`, `PaintDecorator.grayscale(...)`, or
`PaintDecorator.blur(...)` to a `PositionComponent`, set `component.decoratorBounds` to a tight
local `Rect` so `Canvas.saveLayer` allocates only the component's bounding box rather than a
full-screen target.

In this code:

- The camera applies a `PostProcessGroup` containing multiple effects.
- `PostProcessSequentialGroup` chains two effects (`FireflyPostProcess` and `WaterPostProcess`)
  sequentially.
- An additional parallel effect (`ForegroundFogPostProcess`) is applied alongside the sequential
  group.

You can explore the source code [on GitHub](https://github.com/flame-engine/flame/tree/main/examples/games/crystal_ball).


## Live HiDPI Pixel Ratio Sync, Contrast-Adaptive Sharpening, and `PostProcessPipeline`

- **Live HiDPI `pixelRatio` Sync (`autoSyncDevicePixelRatio`)**: Whenever `pixelRatio` is omitted at
  construction, `PostProcess` automatically synchronizes its offscreen target density with live
  `Game.devicePixelRatio * CameraComponent.effectiveWorldRenderScale` changes across display moves.
- **`ContrastAdaptiveSharpenPostProcess` (`ContrastAdaptiveSharpenHelper`)**: Restores crisp edges
  and typography when rendering below native resolution (`worldRenderScale < 1.0` or DRS step-down)
  using either a custom fragment shader or a zero-shader Impeller-safe unsharp luminance composite.
- **Declarative Quality-Aware `PostProcessPipeline` (`PostProcessStage`)**: Chains named
  `PostProcessStage`s (`minQualityTier`, `resolutionScale`, `enabled`, `activePredicate`). Stages
  below `FlameGame.graphics.tier` are skipped automatically, and when **zero** stages are active
  (`bypassedLastFrame == true`), the pipeline renders the subtree directly onto the canvas with
  **zero** offscreen `Picture.toImageSync` allocations.
- **HD-2D `TiltShiftPostProcess`, `DayNightWeatherController` & `WeatherPrecipitationLayer`**:
  - `TiltShiftPostProcess` renders a miniature diorama depth-of-field lens (`focusCenterY`,
    `focusBandHalfHeight`, `featherFalloff`, `farSigma`, `nearSigma`, `strength`) with a sharp focus
    band that preserves crisp pixel-art sprites at the focal plane; it auto-bypasses when it is
    disabled, `strength` is `0`, or both sigmas are negligible.
  - `DayNightWeatherController` interpolates `DayNightKeyframe` stops across cyclic `0..24h` world
    time in perceptual `OklabColor` space, driving a `5x4` `ColorFilter.matrix` and matching 3D sun
    direction/ambient colors.
  - `WeatherPrecipitationLayer` simulates zero-allocation SoA `WeatherKind.rain`, `snow`, `embers`, `hail`
    and `ash`. The drops live in world space on a repeating tile (`wrapPeriod`, by default the size
    of `fallbackBounds`) and are integrated every frame, so panning, camera cuts, zooming and
    changing wind or fall speed never move a drop abruptly. `onDropImpact` receives impact points
    inside the area the camera sees.
