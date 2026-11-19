# Embedding 3D in a 2D Game

A `FlameGame3D` is a game of its own: its world is a `World3D` seen through a `CameraComponent3D`.
Many games are 2D instead, with pre-rendered 2D art, 2D labels and a 2D camera that pans and zooms,
and only want some of their objects in real-time 3D. `Scene3DComponent` is for them: an ordinary
2D component that shows a 3D scene as one layer of a 2D game, lined up with the 2D art pixel for
pixel at every zoom and pan.


## A 3D layer in a 2D world

A `Scene3DComponent` owns a `World3D`, its `world`. The `Component3D`s and `LightComponent`s added
to that world work as they do in a `FlameGame3D`. A `Scene3DProjection` says where the scene lands
in the component's local 2D coordinates, and the component is drawn at its `priority` like any
other 2D component: below the components with a higher priority, above those with a lower one.

```dart
class Town extends FlameGame {
  late final Scene3DComponent layer;

  @override
  Future<void> onLoad() async {
    layer = Scene3DComponent(
      // Scene points (i, j, z), in cells with z up, land at
      // x = (i - j) * 44, y = (i + j) * 22 - 18 - z * 53.889.
      projection: Scene3DProjection.affine(
        origin: Vector2(0, -18),
        xAxis: Vector2(44, 22),
        yAxis: Vector2(-44, 22),
        zAxis: Vector2(0, -53.889),
        towardsViewer: Vector3(0.6124, 0.6124, 0.5),
        near: -50,
        far: 50,
      ),
      priority: 1,
    );
    world.addAll([GroundArt(), layer]);

    layer.world.addAll([
      LightComponent.ambient(intensity: 0.5),
      LightComponent.point(position: Vector3(40, 10, 30), intensity: 5000),
      MeshComponent(mesh: house, position: Vector3(3.5, 4.5, 0)),
    ]);
  }
}
```

The 2D camera keeps working as usual: zooming, panning or rotating it, or moving, scaling or
rotating the layer itself, moves the 3D scene with the 2D art. The layer does not need a `Game3D`
game; it works in any `FlameGame`, and a game may have several layers.


## Projections

A projection is a 4x4 matrix taking a scene point `(x, y, z, 1)` to `(X, Y, Z, W)`: the point
lands on the local point `(X / W, Y / W)` (y pointing down, as everywhere in 2D Flame) at the depth
`Z / W`, from 0 on the near plane to 1 on the far plane. Nearer points hide farther ones, and
nothing outside the depth range is drawn.

- `Scene3DProjection.affine` is a parallel projection, the projection of isometric, dimetric or
  oblique 2D art. It is given by the 2D images of the scene's unit axes and origin, which is what
  the art's grid tells you. The scene points that land on one local point form a line, the line
  of sight; `towardsViewer` tells which end of it the viewer is at (it only has to point roughly
  along it), and `near` and `far` bound the depth along it, in scene units.
- `Scene3DProjection.camera` maps the picture of a camera (a view matrix and a clip-space
  projection, as `CameraComponent3D` builds them) onto a rectangle of the layer, and
  `Scene3DProjection.perspective` builds such a camera from an eye, a target and a field of view:
  a perspective look inside a 2D game.
- `Scene3DProjection.matrix` takes any matrix of the kind above.

A projection may mirror the scene compared with a standard camera, as the one above does (its
x, y and z axes appear in clockwise order seen from the viewer). The render context then flips the
winding of front faces, so back-face culling keeps culling the faces that point away from the
viewer.

Projections are immutable; assign a new one to `layer.projection` to change it.


## Tying 2D and 3D together

`scenePointToLocal` gives the local point a scene point lands on, so 2D components can follow 3D
objects. Children of the layer are drawn above the scene and use its local coordinates directly:

```dart
final label = TextComponent(text: 'Bakery', anchor: Anchor.bottomCenter)
  ..position = layer.scenePointToLocal(Vector3(4, 5, 1.6));
layer.add(label);
```

Elsewhere, convert further with `layer.positionOf` (to the layer's parent) or
`layer.absolutePositionOf`.

`localPointToRay` goes the other way: it returns the ray of the scene points that land on a local
point, starting on the near plane and pointing away from the viewer. `raycastLocal` (and
`raycastAllLocal`, sorted from nearest to farthest) intersects that ray with the triangles of the
meshes, models, LOD meshes and instanced groups of the layer's world, and returns the nearest
`RayHit3D` with the object, the surface and triangle hit, the distance, and the world and local
hit point and normal:

```dart
@override
void onTapUp(TapUpEvent event) {
  final local = layer.absoluteToLocal(
    camera.globalToLocal(event.canvasPosition),
  );
  final hit = layer.raycastLocal(local);
  if (hit != null) {
    // hit.object, hit.worldPoint, hit.worldNormal, hit.distance
  }
}
```

The raycast is `World3D.raycast` on the ray of the local point with the layer's `cameraMask`, so it
hits what the layer draws: hidden components and components (or their ancestors) whose
`cameraMask` shares no bit with the layer's are skipped. Pass `cameraMask` to pick with another
mask, `includeHidden: true` to test every object, and a `filter` to skip more. Back faces are
skipped where the surface's material culls them; pass `cullMode` to override. See
[Picking with the mouse or a finger](geometry.md#picking-with-the-mouse-or-a-finger) for raycasts
and [Input and Effects](input_and_effects.md) for pointer callbacks on 3D objects.

`Scene3DProjection` also has `depthOf` and `localPointToScene`, which returns the scene point at a
given depth on a local point.


## How a layer renders

Each time the layer renders, it renders the part of the screen it covers in one render pass (plus a
shadow pass, a depth prepass and post-processing passes when those are on): the canvas's clip (the
game's area when nothing clips the canvas), intersected with the picture of the bounding box of the
scene's components (lights do not count, nor components whose `includeInSceneBounds` is `false`)
and, when the component has a non-zero `size`, with the rectangle from `(0, 0)` to `size`. Objects
outside that part are culled. Nothing is rendered when the part is empty, for example when the scene
is off screen.

Two optional bounds narrow the part further, without clipping the canvas: `visibleRect`, a
rectangle in the layer's local coordinates (followed exactly through a rotated or sheared canvas),
and `visibleSceneBounds`, a box in scene coordinates intersected with the scene's bounding box.
Like the scene's bounding box, the box only bounds the rectangle that its picture covers: what the
scene draws inside that rectangle is kept, also where it lies outside the box. Changing either
renders a retained layer again.

```dart
// Only the board area of the screen, whatever the scene holds beyond it.
layer.visibleRect = const Rect.fromLTWH(0, 0, 640, 480);
```

The bounding box of the scene is `World3D.sceneBounds`, which the world keeps up to date as its
components move: reading it only visits the components whose bounds changed since the last frame
(`log2(n)` unions each), and costs next to nothing for a scene that does not move. It is always the
exact union of the bounds of the components it counts. While the world holds a component left out
of it (`includeInSceneBounds` set to `false`, as `DebugRenderer3D` does; see
[Basic Concepts](basic_concepts.md#the-world-and-its-components)), `World3D.hasUnboundedComponents`
is `true` and the layer renders its whole visible area, since such a component may draw anywhere.

The pass runs at the resolution of the screen: the device pixel ratio times `renderScale` pixels
per logical pixel, with the image aligned to the device's pixel grid. The camera of the pass is
built from the canvas transform, so a scene point lands exactly where the projection puts it. With
`renderScale` at `1` the image is drawn back unfiltered, one image pixel per device pixel; a lower
`renderScale` saves fill rate and the image is scaled up with `scaledFilterQuality`. `msaa`
switches multisample anti-aliasing on for the scene pass, also when the scene renders into a texture
for bloom, post-processing or HDR (the composite pass itself has one sample).

A layer drawn into an offscreen picture that is rasterized at a scale of its own renders at the
resolution of that picture instead: under a Flame post process that rasterizes its subtree
(`PostProcess.rasterizeSubtree`, such as a `ShaderPostProcess` that samples it), inside the
offscreen world of a camera whose `worldRenderScale` is not `1`, and in
`CameraComponent.renderToImageSync`. Those pictures scale their canvas to their pixels themselves
and report it with Flame's `RasterScale` (see the post processing page of Flame), so the layer
takes the canvas units as pixels and renders `renderScale` pixels per unit, with the image aligned
to the picture's pixel grid. Leave `renderScale` at the value you would use on screen, and do not
clip the canvas yourself: those pictures clip their canvas to the image, the pass covers what of the
scene lands in it (the game's area in the picture's pixels when a picture does not clip), and
`visibleRect` narrows it as on screen. A post process of your own that records the subtree into a
scaled picture without `rasterizeSubtree` reports its scale with `RasterScale.push` and
`RasterScale.pop`; otherwise the layer renders at the device pixel ratio times the picture's scale,
and, without a clip, only over the game's logical size taken in the picture's pixels.

The render target is rounded up to a multiple of 64 pixels in both directions, and the target of the
last render is kept while the part fits in it and covers at least half of it, so that panning,
zooming and moving objects keep using the same target. It is at most `maxTextureSize` pixels wide
and high (4096 by default); a larger part is rendered at a lower resolution. The image of the pass
is drawn by Flutter straight from one of the color textures of the target, which are created once
(see [Rendering](rendering.md)): after the first frames, a pass allocates nothing on the GPU.

The draws are recorded, sorted and batched as in any `World3D` (see [Rendering](rendering.md)):
components sharing a mesh cost one instanced draw call per surface. `layer.renderStats` holds the
statistics of the layer's last pass (and of its shadow pass) and `layer.lastRenderTime` the time it
took on the CPU.


## Shadows on the 2D art

When a directional light of the scene casts shadows, the layer renders the shadow map first, fitted
to the part of the scene it renders, and its components receive them (see [Shadows](shadows.md)).
The shadow map is aligned with its texels as the 2D camera pans, so the edges of the shadows do not
shimmer. Each layer only shadows itself; to let the objects of several layers shadow one another,
put their worlds in one `ShadowGroup` (see [Shadows](shadows.md)), and keep the lights in one of
the worlds, which the others borrow with `World3D.lightsFrom` (see
[Lighting](lighting.md#lights-shared-by-several-worlds)):

```dart
final shadows = ShadowGroup();
buildings.world.shadowGroup = shadows;
characters.world
  ..shadowGroup = shadows
  ..lightsFrom = buildings.world;
```

To cast shadows onto the 2D art below the layer, give the scene an invisible ground of
`ShadowCatcherMaterial`: it draws only the shadows falling on it, blended over the 2D components
behind the layer, and leaves them untouched elsewhere (see
[Shadows on 2D art](shadows.md#shadows-on-2d-art)).

```dart
layer.world.addAll([
  LightComponent.directional(
    direction: Vector3(-0.3, -0.5, -1),
    shadows: ShadowSettings(),
  ),
  MeshComponent(
    mesh: PlaneMesh(
      size: Vector2.all(boardSize + 2),
      material: ShadowCatcherMaterial(color: const Color(0x8C1B2440)),
    ),
    position: Vector3(boardSize / 2, boardSize / 2, 0),
    // The PlaneMesh faces +y: turned to face +z, up in this scene.
    rotation: Quaternion.axisAngle(Vector3(1, 0, 0), pi / 2),
  ),
]);
```


## Retained layer caching

A layer whose 3D objects sit still on most frames (buildings, terrain, idle props) can skip its GPU
passes while nothing in its scene or its place on screen changes:

```dart
final buildings = Scene3DComponent(
  projection: boardProjection,
  cacheMode: Scene3DCacheMode.retained,
);
```

With `Scene3DCacheMode.retained` the layer renders into a render target of its own and keeps the
image. On the next frames it draws the kept image again, without any GPU pass, as long as nothing
listed below changed: `layer.renderStats.renderPasses` is then `0` and `layer.cacheHitCount`
counts the frames served from the image. The default, `Scene3DCacheMode.none`, renders every frame.


### What renders the layer again

The layer compares, on every frame:

- the world's `sceneVersion`: components added, removed, moved, shown or hidden, drawing
  properties (`color`, `instanceData`, `jointTransforms`, `castsShadows`) and light source fields
  assigned, lights added, removed or moved, animations that advance, particle systems and ribbons
  with live particles, particles spawned or cleared (`burst`, `spawn`, `clear`, from anywhere in
  the frame), running effects, batch changes, world settings assigned a new value, and
  the changes of the lights it borrows with `World3D.lightsFrom` (see
  [Basic Concepts](basic_concepts.md#scene-versions-and-dirty-marking) for the full list);
- the `castersVersion` of the world, or of its `ShadowGroup` (all the worlds of the group);
- `layer.markDirty()` calls;
- the part of the screen the layer covers and where it lands in device pixels: panning, zooming or
  rotating the 2D camera, moving, scaling or rotating the layer or one of its ancestors, resizing
  the game, and changing its `projection`;
- the render target size, the device pixel ratio, `renderScale`, `msaa` and the layer's
  `cameraMask`;
- `hdrEnabled`, `oitMode`, `grabSceneColorEnabled` and `renderDebugMode3D`;
- the values of the `bloom` settings and of every field of `postProcess` (`toneMap`, `exposure`,
  `contrast`, `saturation`, the vignette, `tint`, `fxaa`, the color LUT and its intensity, and the
  SSAO and depth-of-field fields), so changing them in place counts too (the content of a color
  LUT does not).

These do not render it again, because the engine does not see them; report them as described in
[Basic Concepts](basic_concepts.md#scene-versions-and-dirty-marking), or call `layer.markDirty()`:

- material fields, including the animated ones (`StylizedMaterial.windTime`, `WaterMaterial.time`):
  wind and water freeze while the image is reused;
- joint matrices written in place into `jointTransforms` (skinning driven that way freezes until
  `markDrawDirty()` is called on the component, while `ModelComponent` animations do count), and
  vectors or `ShadowSettings` of a light source changed in place (`source.markChanged()`);
- what a custom `Object3D` draws (`markDrawDirty()`), and textures whose content changes, such as a
  `RenderTexture3D` shown in the layer;
- the fields of `fog` and `customPasses`.

`markDirty()` only renders the layer again; `world.markSceneDirty()` does too, and also marks the
shadow casters as changed (use `shadows: false` when none moved).

Anything that changes on every frame keeps the layer rendering every frame, with the cost of the
comparison on top: particle systems with live particles, playing animations, a `FoliageSystem3D`
with a `windStrength` above `0` (it marks the world dirty on every update, see
[Large Worlds](world_scale.md#foliage)), and components whose transform or drawing properties
change every frame (writing an unchanged value is not a change). Put such objects in a layer of
their own without caching, above or below the retained one, and share shadows between the two with
a `ShadowGroup`.


### What it costs

A frame served from the image costs one image draw and the comparison: about forty values compared
one by one with those of the kept image, and the two camera matrices, without allocating. A frame
that renders costs what it costs without caching. The layer's render targets are not taken from the
device's pool: one for the plain path and one for the post-processing path (`bloom`, `postProcess`,
`hdrEnabled`), each created on its first render and again whenever its size changes. Each keeps up
to three color textures of the target size (4 bytes per pixel each, two in steady use: the frame
after a run of reused frames renders into another texture than the one Flutter may still be
drawing) and a depth texture, plus a multisampled color texture with `msaa`. Setting `cacheMode`
back to `none`, or removing the layer, releases them.

While the 2D camera moves, the layer renders on every frame, like a layer without caching.


### Shadow groups and on-demand rendering

The layer compares the `castersVersion` of its world's `ShadowGroup`, so a caster that moves in
another layer of the group renders the retained layer again, with the shadow it now receives; the
other changes of the other layers do not. While the retained layer reuses its image it renders no
shadow map, and the next layer of the group that renders draws the group's map instead (see
[Shadows](shadows.md)): the group still costs one shadow pass per frame while any of its layers
renders.

`markDirty()` and every scene version change call `Game.notifyVisualMutation()`, so a game whose
`idleRenderMode` only paints changed frames wakes up for them. The two mechanisms add up: on-demand
rendering skips whole frames when nothing changed, and a retained layer skips its GPU passes on the
frames that are painted for other reasons, such as a 2D animation. The changes listed above that the
engine does not see neither render the layer nor wake the game; `markDirty()` does both.


## Bloom and post-processing on a layer

A layer's `bloom`, `postProcess`, `hdrEnabled` and `renderDebugMode3D` are those of its world (the
constructor parameters set them on the world):

```dart
final crystals = Scene3DComponent(
  projection: boardProjection,
  bloom: BloomSettings(threshold: 0.75, intensity: 0.6),
  postProcess: PostProcessSettings(
    toneMap: ToneMapMode.acesFilmic,
    vignetteIntensity: 0.18,
    fxaa: true,
  ),
);
```

With `bloom`, an active `postProcess`, `hdrEnabled`, or the `depth` and `ssao` debug modes, the
scene renders into a texture first, and a composite pass draws the layer's image from it. The
composite keeps the scene's alpha, so the 2D art behind the layer shows through where the scene is
empty and the glow is added onto it; the grading applies to the covered part of each pixel only, so
empty pixels stay transparent. `msaa` still applies to the scene pass. Each layer runs its own
chain. The settings, their costs and what differs in a layer are described in
[Post-Processing](post_processing.md#in-a-scene3dcomponent-and-in-a-flamegame3d).

For HD-2D standees and labels that 3D objects hide, use `BillboardBatch3D` and `Text3DComponent`
inside `layer.world` (see [3D UI and Text](ui_3d.md)) rather than 2D components above the layer.


## Snapshots and render textures

`layer.renderToImage(size)` renders the layer once into a new `Image` of `size` logical pixels times
`pixelRatio` (default `1`) times `renderScale`. The local point `(x, y)` of the layer lands at
`origin + zoom * (x, y)` in the image (by default `origin` is `(0, 0)` and `zoom` `1`), and the
image is cleared to `clearValue` (transparent by default). `World3D.renderToImage` renders a world
from any `view` and `projection` matrices, at a size given in pixels.

```dart
final thumbnail = layer.renderToImage(
  const Size(128, 128),
  origin: const Offset(64, 96),
  pixelRatio: 2,
);
// ... draw it, then:
thumbnail.dispose();
```

Each call creates a render target of the image's size and runs the whole pipeline (its own shadow
map, not the group's, and the post-processing of the world), so it suits thumbnails and captures,
not every frame. The image belongs to the caller, who disposes it, and stays valid however long it
is kept. A world that is not in a game renders too, with its lights: the `LightComponent`s of its
tree are gathered for the render, since lights only register with their world when mounted.

A `RenderTexture3D` keeps a render on the GPU instead, as a `Texture` that materials sample: a
monitor, a portal, a mirror.

```dart
final monitor = RenderTexture3D(width: 256, height: 256);
final screen = MeshComponent(
  mesh: PlaneMesh(
    size: Vector2.all(2),
    material: UnlitMaterial(albedoTexture: monitor.texture)
      ..renderState = RenderState.opaque,
  ),
  cameraMask: 0x02, // kept out of the monitor's own view
);

// In update():
monitor.renderWorld(
  layer.world,
  view: monitorView,
  projection: monitorProjection,
  cameraMask: 0x01,
);
layer.markDirty(); // only needed when the layer is retained
```

`renderWorld` renders the world into the texture in one pass (plus a shadow pass with
`renderShadows: true`, a shadow map of its own) with the world's lights and fog, at the texture's
size, in 8-bit color, without multisampling, bloom or post-processing. Notes:

- `texture` is the same `Texture` object for the life of the render texture, so a material can take
  it at setup. Until the first `renderWorld`, and after a `resize` until the next one, it shows a
  single white pixel.
- Inside its own `renderWorld`, `texture` also shows a white pixel, so a mesh that shows the texture
  and is drawn into it never samples the texture being written; keep such a mesh out of the render
  with `cameraMask` anyway, or it appears white in its own picture. A `renderWorld` call made during
  another one returns `false`.
- Call it from `update`, not while the world is being rendered. The draws are recorded into the
  optional `context` on `device` when both are given, otherwise into those of the world's game (or
  of a renderer of its own for a world in no game, whose lights are then gathered from its tree).
- A retained layer that shows the texture does not notice new content: call `markDirty()`.
- `dispose()` drops the GPU texture; `texture` shows white again until the next `renderWorld`.


## Hosts

A `World3D` renders with the device and render context of its host, the nearest ancestor that
implements `Scene3DHost`: the `Scene3DComponent` it belongs to, or the `Game3D` game whose camera
looks at it. `World3D.host` returns it.

In a `Game3D` game (a `FlameGame3D`, or any `FlameGame` with the `Game3D` mixin), the layers use
the game's device, and the game's `renderStats` count their passes. In other games, the layers of a
game share a device of their own, `layer.device`, whose `lastFrameStats` cover all of them.


## Limitations

- Canvas transforms with a perspective part (a 3D rotation of the canvas) are not supported; the
  2D transforms that Flame's cameras and components apply are.
- The image is aligned to the device's pixel grid when the game is painted in its own layer at a
  whole number of physical pixels, as a full-screen `GameWidget` is.
- A retained layer does not see the changes listed under "What renders the layer again" that the
  engine cannot observe; call `markDirty()` after them.
- The composite tone-maps premultiplied colors: at the anti-aliased and translucent edges of a layer
  drawn over 2D art, tone mapping, which is not linear, is slightly off (see
  [Post-Processing](post_processing.md#limitations)).
