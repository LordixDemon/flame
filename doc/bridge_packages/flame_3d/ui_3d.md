# 3D UI and Text

Four components put flat pictures, text and controls into a 3D scene, depth tested against it so
that walls and characters hide them:

| Need                                                   | Use                |
| ------------------------------------------------------ | ------------------ |
| sprites, foliage cards, HD-2D standees, icons          | `BillboardBatch3D` |
| a few labels in any font or script                     | `Text3DComponent`  |
| hundreds of short ASCII strings (damage numbers, tags) | `MsdfTextBatch3D`  |
| a panel with buttons and sliders in the world          | `WidgetSurface3D`  |

`BillboardBatch3D` and `Text3DComponent` are exported by `package:flame_3d/components.dart`
(their material, `BillboardMaterial3D`, by `resources.dart`); `MsdfTextBatch3D` and
`WidgetSurface3D` by `package:flame_3d/ui3d.dart`. None of them casts or receives shadows.


## Billboards and standees

A `BillboardBatch3D` draws any number of textured quads that turn towards the camera, in one
instanced draw call. Each quad is built in the vertex shader of `BillboardMaterial3D` from 24
floats of instance data.

```dart
final atlas = await ImageTexture.create(
  image,
  sampler: TextureSampler.linear,
);
final trees = BillboardBatch3D(
  material: BillboardMaterial3D(albedoTexture: atlas, alphaCutoff: 0.5),
);
for (final p in positions) {
  trees.addBillboard(
    position: p, // in the batch's space
    width: 1.2,
    height: 2,
    uvRect: const Rect.fromLTWH(0, 0, 0.25, 1),
  );
}
world.add(trees);

// z-up scene, an HD-2D standee leaning back by 20 degrees:
trees.addBillboard(
  position: Vector3(1, 1, 0),
  width: 1,
  height: 1.6,
  upAxis: Vector3(0, 0, 1),
  tiltRadians: 0.35,
);
```

`addBillboard` returns the slot index; `setBillboard(index, ...)` rewrites a slot with the same
parameters, `clear()` empties the batch, `length` counts the slots.

| Parameter         | Default       | Meaning                                                |
| ----------------- | ------------- | ------------------------------------------------------ |
| `position`        | required      | pivot point, in the batch's local space                |
| `width`, `height` | required      | size in world units                                    |
| `orientation`     | `cylindrical` | turn about `upAxis`, `spherical` or `fixed`            |
| `upAxis`          | `(0, 1, 0)`   | upright axis of cylindrical and fixed sprites          |
| `rightAxis`       | `(1, 0, 0)`   | right axis of fixed sprites                            |
| `anchorY`         | `-0.5`        | vertical pivot: `-0.5` bottom edge at `position`       |
| `anchorX`         | `0`           | horizontal pivot: `-0.5` left edge at `position`       |
| `tiltRadians`     | `0`           | leans a cylindrical sprite back (HD-2D standee)        |
| `rollRadians`     | `0`           | turns the sprite about its pivot, in the sprite plane  |
| `uvRect`          | whole texture | normalized atlas rectangle                             |
| `color`           | white         | tint multiplied with the texture                       |
| `emissiveBoost`   | `0`           | brightens: color times `1 + emissiveBoost`             |
| `unlit`           | `0`           | `0..1`, removes the lighting of this sprite            |
| `fade`            | `0`           | `0..1`, scales the alpha down                          |

A `spherical` sprite faces the camera's image plane; a `cylindrical` one stays upright along
`upAxis` and only turns about it, which suits trees, characters and signs; a `fixed` one does not
turn at all and lies in the plane of `upAxis` and `rightAxis` (made perpendicular to `upAxis`;
`tiltRadians` does not apply), like a decal on a wall. The anchors are in
sprite sizes and apply along the sprite's own right and up directions, so values beyond `±0.5`
move the sprite away from `position` in the camera plane (`MsdfTextBatch3D` places the glyphs of
a string this way); the roll turns the sprite as a rigid quad about that pivot.

The batch's transform, and its parents', place the sprites: `position` is transformed, `upAxis`
turned, and the sizes scaled by the largest axis scale of the transform (each sprite still faces
the camera on its own). `test/gpu/debug_and_ui_3d_gpu_test.dart` draws a moved and scaled batch.


### The material

`BillboardMaterial3D` options:

- `albedoTexture` (a white texture by default) and `albedoColor`;
- `alphaCutoff` (`0.4`): texels whose alpha (texture × color × `1 - fade`) is below it are
  discarded, the rest is drawn opaque and writes depth;
- `shadeWeight` (`0.65`): how much lighting applies, from `0` (flat color) to `1`. The lighting is
  ambient, hemisphere, directional, point and spot light with a wrapped diffuse term
  (`0.35 + 0.65 * N·L`, so the back side is not black), clamped to `1.6`; there is no specular
  term and no shadow is received. The normal is the sprite's facing direction;
- `ditherFade`: discards with a 4×4 ordered dither where the alpha is low, for fading opaque
  sprites without sorting;
- `translucent: true`: premultiplied alpha blending without a cutoff and without depth writes, see
  the depth section below;
- `premultipliedTexture` (`true`): whether the texture's colors are premultiplied by its alpha, as
  those of textures made from a `dart:ui` `Image` are (`ImageTexture.create`, decoded assets,
  rasterized pictures). Set it to `false` for a texture built from straight-alpha bytes. The shader
  turns premultiplied texels back into straight colors before tinting and lighting them, so
  translucent texels and the edges of cut-out sprites keep their color. In
  `debug_and_ui_3d_gpu_test.dart`, a 50 % white texel over a transparent target renders as
  `(128, 128, 128, 128)` from either kind of texture, and a half transparent red texel above the
  cutoff renders full red.

Fog applies to billboards.


### Billboard costs

One batch is one instanced draw call per pass, whatever the number of sprites; it is skipped in
shadow passes. The instance data (96 bytes per sprite) is uploaded with the pass. The bounds used
for culling are recomputed when a slot changes. A batch whose transform is not the identity keeps
a second copy of the instance data placed in world space, rebuilt (one pass over the sprites) when
a slot or the transform changes.


### Billboard limitations

- A non-uniform scale scales the sprite sizes by its largest axis: a sprite has no fixed axis to
  stretch along. The bounds are grown to match.
- Sprites inside one batch are not sorted against each other; a translucent batch is sorted
  against other translucent draws as one piece, by the center of its bounds.


## Text labels

`Text3DComponent` lays its text out with Flutter's `TextPainter`, so any font, weight and script
that Flutter renders works (accented Latin, Cyrillic, CJK, emoji). It draws the text, an optional
rounded background and a border into a picture, rasterizes it with `Picture.toImageSync` and uses
the image as the texture of one billboard, without copying it on Flutter GPU.

```dart
final label = Text3DComponent(
  text: 'Harbour',
  style: const TextStyle(color: Color(0xFFFFFFFF), fontSize: 48),
  worldHeight: 0.6,
  position: Vector3(0, 2.5, 0),
);
world.add(label);
label.text = 'Harbour (2)'; // rasterizes the texture again
```

- `style` (white, 28 logical pixels, bold) and `text` rebuild the texture when set.
- `worldHeight` (`0.55`) is the label's height in world units; its width follows the aspect ratio
  of the texture (`worldWidth`).
- `backgroundColor` (`0xB30F172A`, `null` for none), `borderColor` (`0xFF38BDF8`, `null` for none),
  `cornerRadius` (`10`) and `padding` (14 by 6 logical pixels) shape the badge. They are read only
  when the texture is rebuilt: after changing them, set `text` or `style` again.
- `orientation` (`spherical`) and `upAxis` (`+Y`) as for billboards.

Only the label's world position is used: `rotation` and `scale` do not apply. The texture is as
many pixels as the laid-out text in logical pixels plus the padding, whatever the size on screen
or the device pixel ratio: a label that is large on screen looks soft. Use a larger `fontSize` for
the same `worldHeight` to sharpen it, at the cost of texture memory (4 bytes per texel).

A label is drawn translucent (premultiplied alpha, depth tested, no depth writes) in one draw call
of its own, after the opaque draws. Changing the text costs a text layout, a picture rasterization
and a new GPU texture; do not change it every frame.


### Text label limitations

- On the web, Flutter GPU's zero-copy texture wrapping is not available and the label falls back
  to a plain white texture: it draws as a white rectangle. Without a GPU (plain `flutter test`) it
  uses the same white texture.
- The previous texture is not disposed when the text changes; it is freed when garbage collected.


## Many strings with the built-in font

`MsdfTextBatch3D` draws many short strings with one glyph atlas, for labels that change often or
come by the hundred (hit points, damage numbers, tags).

```dart
final font = MsdfFontAtlas3D.generateDefault();
final labels = MsdfTextBatch3D(atlas: font);
labels.addText(
  'HP 120',
  position: Vector3(0, 2, 0),
  fontSize: 0.4,
  color: const Color(0xFFFFD54F),
  align: TextAlign3D.center,
);
final sign = labels.addText(
  'GATE 7\nNORTH',
  position: Vector3(4, 1.5, -2),
  mode: TextBillboardMode3D.fixed,
  rotation: Quaternion.axisAngle(Vector3(0, 1, 0), 0.5),
  align: TextAlign3D.center,
);
world.add(labels);
labels.setText(sign, 'GATE 8\nNORTH');
```


### The font

There is no font loading: `MsdfFontAtlas3D.generateDefault` builds the only available font on the
CPU when called. It is a single-weight stroke font (letters drawn as straight line segments)
covering the 95 printable ASCII characters, `0x20` to `0x7E`, plus a fallback glyph (a crossed
box). Every other character, including accented Latin letters, Cyrillic, CJK and emoji, draws the
fallback box. Strings are read as UTF-16 code units, so a character outside the Basic
Multilingual Plane (most emoji) draws two boxes. Kerning is limited to 13 built-in pairs
(`AV`, `To`, `F.`, ...); `measureLineWidth` gives a line's width in world units.

The atlas has 16 by 6 cells of `cellSize` pixels (`32`, so 512 by 192 texels, 384 KB). Generating
it took about 26 ms in a JIT test run. Batches created without an `atlas` share one default atlas,
generated by the first of them.

The glyphs come from a table of hand-drawn strokes for those 95 characters, so the generator
cannot take other characters: there is no way to add a character set. For other scripts use
`Text3DComponent`, which lays text out with Flutter's text engine.

Despite its name, the GPU texture holds a single distance value per texel, in the alpha channel
(the larger of the three-channel median and the exact distance to the strokes); the three-channel
distances stay on the CPU, for `sampleMedianDistance`. Glyphs are cut out at `alphaCutoff`
(`0.5`): edges are hard (not anti-aliased) and the texture has no mipmaps, so small or distant
text shimmers. An `alphaCutoff` below `1 / 255` is drawn as `1 / 255`, since the glyphs are opaque
quads: without a cutoff each would be a solid box.


### Strings

`addText` options:

- `position`, in the batch's local space: the batch's transform and its parents' place the text;
- `fontSize` (`0.5`): world units per em, which is also the glyph height;
- `color` (white);
- `mode`: `spherical` (default) or `cylindrical` strings face the camera, `fixed` lays the text on
  the plane of the local X and Y axes turned by `rotation` (and then by the batch's transform),
  like a sign: seen edge-on it disappears. Camera-facing strings are laid out in the camera plane
  (for `cylindrical`, along the horizontal side of the upright cylinder), so a string keeps its
  width seen from any side; `rotation` adds a roll of the whole string about `position` (and a
  tilt for `cylindrical`);
- `align` (`left`), `letterSpacing` (ems, `0`) and `lineHeight` (ems, `1.2`); `\n` starts a new
  line.

`addText` returns the string's index; `setText(index, ...)` replaces a string, the options left
out keeping their values, `clear()` removes all. `textCount` counts the strings and `glyphCount` the
glyph quads (spaces and tabs make none).


### Rendering and costs

Changes are collected and the glyph quads rebuilt on the next draw (or the next `glyphCount` or
bounds query). Every glyph, camera-facing or fixed, is a sprite of one internal `BillboardBatch3D`
(opaque cutout, unlit; fixed glyphs use `BillboardOrientation3D.fixed`), so a batch costs one
instanced draw call whatever the number and kind of strings. Text is not lit: it keeps its color
whatever the lights. The test `msdf_text_and_widget_surface_3d_test.dart` checks on a recording
fake backend that 150 two-line strings (more than 1,200 glyphs) make a single draw call, and
`debug_and_ui_3d_gpu_test.dart` renders a camera-facing string from the front, the side and
behind and checks that it keeps its width and its place, also after the batch moves, a fixed
plaque from the front and the side before and after the batch turns, and white text at full
brightness under lights. A rebuild rewrites the batch's sprites; strings that change every frame
rebuild the whole batch every frame, so keep frequently changing strings in a batch of their own.


### Font text limitations

- Printable ASCII only, see [The font](#the-font).
- A non-uniform scale of the batch scales the glyphs by its largest axis, as for billboards.


## Interactive panels

`WidgetSurface3D` is a rectangle in the world showing a 2D canvas, with simple controls that react
to taps, hovers and drags. It does not host Flutter widgets: there is no widget tree, layout, text
field, scrolling or focus. What it shows is painted with `dart:ui` by a `paintSurface` callback and
by its controls.

```dart
var volume = 0.5;
final panel = WidgetSurface3D(
  position: Vector3(0, 1.5, -3),
  paintSurface: (canvas, size) {
    canvas.drawRect(
      Rect.fromLTWH(16, 16, size.width - 32, 48),
      Paint()..color = const Color(0xFF334155),
    );
  },
  controls: [
    SurfaceButton2D(
      bounds: const Rect.fromLTWH(32, 100, 200, 64),
      label: 'Start',
      onPressed: () => print('start'),
    ),
    SurfaceSlider2D(
      bounds: const Rect.fromLTWH(32, 200, 440, 40),
      value: volume,
      onChanged: (v) => volume = v,
    ),
  ],
);
world.add(panel);
game.add(PointerRouter3D.forCamera(world: world, camera: camera));
```

- `width` and `height` (`2` by `1.2` world units): the panel lies in its local XY plane, centered on
  its origin, facing `+Z`.
- `pixelWidth` and `pixelHeight` (`512` by `300`): the canvas size in pixels; control `bounds` and
  all event offsets are in these pixels, `(0, 0)` at the top left.
- `backgroundColor` (`0xE60F172A`) fills the canvas before `paintSurface` and the controls paint.
- `doubleSided` (`true`): the back is visible too, showing the canvas mirrored.
- `minUploadInterval` (`0` s): the shortest time between two rasterizations.


### How the canvas is rasterized

A panel is rasterized once when created, then only when it is dirty: after `markDirty()`, a
control's `invalidate()`, or a hover or press that changes a control's look. On the next update or
draw (not sooner than `minUploadInterval` after the previous one), it records the background,
`paintSurface` and the controls into a picture, rasterizes it with `Picture.toImageSync`, wraps the
image as a GPU texture without copying, and disposes the previous texture. `flushDirty()` does it
at once; `uploadCount` counts the rasterizations, so a test can check that a static panel is not
rasterized again. Each rasterization allocates a new texture of `pixelWidth × pixelHeight × 4`
bytes (600 KB at the default size): throttle animated panels with `minUploadInterval`.

The panel is drawn with an `UnlitMaterial` in premultiplied alpha: one draw call per panel, drawn
with the translucent draws (after the opaque ones, back to front) but writing depth. It is not lit
and fog does not apply to it.


### How input reaches it

The panel mixes in `TapCallbacks3D`, `HoverCallbacks3D` and `DragCallbacks3D`, so it needs a
`PointerRouter3D` in the game (`forCamera` for a `FlameGame3D`, `forScene` for a
`Scene3DComponent`, see [Input and Effects](input_and_effects.md)). The router casts a ray from the
pointer into the world; when the panel is the nearest hit:

- the hit point is converted into the panel's local space (rotation and scale included) and then
  into canvas pixels, `u = x / width + 0.5`, `v = 0.5 - y / height`, times the pixel size. During a
  drag the pointer ray is intersected with the panel's plane instead, so dragging past the edge
  keeps working, clamped to the edge;
- controls are hit-tested from the last added (painted on top) to the first; disabled controls are
  skipped;
- a tap presses the control under the pointer; releasing inside it calls `handlePointerUp` with
  `inside: true` (a button's `onPressed`). When the pointer moves far enough, Flame's gesture arena
  turns the tap into a drag: the tap is cancelled, the drag presses the control again, and
  releasing inside still counts. A slider follows the pointer from the press on;
- hover is reported only for a mouse (`onMouseMove` of the router); touch screens have no hover;
- `onSurfaceTap`, `onSurfaceHover` and `onSurfaceDrag` receive canvas pixel offsets for custom
  hit-testing in `paintSurface` content;
- the panel marks its tap, hover and drag events handled, so components above it in the tree do
  not receive them.

The mapping is checked by `msdf_text_and_widget_surface_3d_test.dart` on a rotated panel: hover,
tap and slider drag land within half a pixel of the expected canvas positions.

Custom controls extend `SurfaceControl2D`: implement `paint`, override `handlePointerDown`,
`handlePointerDrag` and `handlePointerUp` as needed, read `hovered` and `pressed`, and call
`invalidate()` when their look changes.

```dart
class Badge extends SurfaceControl2D {
  Badge({required super.bounds});

  int count = 0;

  @override
  void paint(Canvas canvas) {
    canvas.drawCircle(
      bounds.center,
      bounds.shortestSide / 2,
      Paint()
        ..color = pressed ? const Color(0xFFF59E0B) : const Color(0xFFEF4444),
    );
  }

  @override
  void handlePointerUp(Offset panelOffset, {required bool inside}) {
    if (inside) {
      count++;
      invalidate();
    }
  }
}
```


### Panel limitations

- On the web the panel cannot wrap the rasterized image as a texture and shows a transparent
  placeholder: nothing of it is visible. Without a GPU (plain `flutter test`) the same placeholder
  is used; the input mapping still works.
- No keyboard input, text entry or focus traversal.
- `update` allocates one `Vector3` per panel per frame (the drag plane normal).
- The panel's last texture is not disposed when the panel is removed; it is freed when garbage
  collected.


## Depth and sorting

| Component                        | Blending            | Depth           | Lit                 |
| -------------------------------- | ------------------- | --------------- | ------------------- |
| `BillboardBatch3D` (default)     | opaque cutout       | tested, written | yes (`shadeWeight`) |
| `BillboardBatch3D` (translucent) | premultiplied alpha | tested          | yes                 |
| `Text3DComponent`                | premultiplied alpha | tested          | no                  |
| `MsdfTextBatch3D` camera-facing  | opaque cutout       | tested, written | no                  |
| `MsdfTextBatch3D` fixed          | opaque cutout       | tested, written | no                  |
| `WidgetSurface3D`                | premultiplied alpha | tested, written | no                  |

Opaque cutout draws write depth and are sorted with the other opaque draws, so they intersect the
scene correctly and need no sorting among themselves. Translucent draws come after all opaque
draws and are sorted back to front by the center of each component's bounds; one component is
never split, so two translucent labels that overlap in depth can sort the wrong way. Every
component here is skipped in the shadow pass and draws once per main pass.

The depth-normal prepass (`World3D.depthPrepassEnabled`, used by SSAO, depth of field, soft
particles and shoreline foam, see [Post-Processing](post_processing.md)) holds opaque billboards
and camera-facing font text: `BillboardMaterial3D.depthNormalMaterial` draws them there placed as
in the main pass and cut out at the same `alphaCutoff` (and dither), so the effects see the
sprite's shape. `debug_and_ui_3d_gpu_test.dart` checks in the `depth` debug view that a billboard
covers what a quad of the same size covers, and that the transparent half of a sprite is left out.
Font text, fixed or camera-facing, is billboards and is cut out there too. Translucent components
are left out of the prepass by design.
