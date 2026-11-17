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
point, starting on the near plane and pointing away from the viewer. A tap becomes a ray like this:

```dart
@override
void onTapUp(TapUpEvent event) {
  final local = layer.absoluteToLocal(
    camera.globalToLocal(event.canvasPosition),
  );
  final ray = layer.localPointToRay(local);
  // The object whose box the ray enters first is the one under the finger.
  final distance = ray.intersectsWithAabb3(house.aabb);
}
```

`Scene3DProjection` also has `depthOf` and `localPointToScene`, which returns the scene point at a
given depth on a local point.


## How a layer renders

Each time the layer renders, it renders the part of the screen it covers in one render pass: the
canvas's clip (the game's area when nothing clips the canvas), intersected with the picture of the
bounding box of the scene's components (lights do not count) and, when the component has a
non-zero `size`, with the rectangle from `(0, 0)` to `size`. Objects outside that part are culled. Nothing is rendered when
the part is empty, for example when the scene is off screen.

The pass runs at the resolution of the screen: the device pixel ratio times `renderScale` pixels
per logical pixel, with the image aligned to the device's pixel grid. The camera of the pass is
built from the canvas transform, so a scene point lands exactly where the projection puts it. With
`renderScale` at `1` the image is drawn back unfiltered, one image pixel per device pixel; a lower
`renderScale` saves fill rate and the image is scaled up with `scaledFilterQuality`. `msaa`
switches multisample anti-aliasing on.

The render target is rounded up to a multiple of 64 pixels in both directions, and the target of the
last render is kept while the part fits in it and covers at least half of it, so that panning,
zooming and moving objects keep using the same target. It is at most `maxTextureSize` pixels wide
and high (4096 by default); a larger part is rendered at a lower resolution. The image of the pass
is drawn by Flutter straight from one of the color textures of the target, which are created once
(see [Rendering](rendering.md#frame-output-and-statistics)): after the first frames, a pass
allocates nothing on the GPU.

The draws are recorded, sorted and batched as in any `World3D` (see [Rendering](rendering.md)):
components sharing a mesh cost one instanced draw call per surface. `layer.renderStats` holds the
statistics of the layer's last pass and `layer.lastRenderTime` the time it took on the CPU.


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
- A layer drawn into an offscreen picture whose transform already includes the device pixel ratio
  (for example by a camera with a `worldRenderScale` other than `1`) renders at a higher
  resolution than needed; lower its `renderScale`.
- Retained camera caches and idle rendering only know about changes to the 2D component tree: a
  3D scene that animates on its own needs the game to render every frame.
- The image is aligned to the device's pixel grid when the game is painted in its own layer at a
  whole number of physical pixels, as a full-screen `GameWidget` is.
