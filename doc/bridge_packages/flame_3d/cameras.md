# Cameras

How a 3D scene is seen depends on where it is shown:

- a `FlameGame3D` (or any `Game3D` game) looks at its `World3D` through a `CameraComponent3D`, the
  subject of this page;
- a `Scene3DComponent` embedded in a 2D game has no 3D camera: its `Scene3DProjection` and the 2D
  camera of the game decide where the scene lands (see [Embedding 3D in a 2D Game](embedding.md));
- offscreen renders (`World3D.renderToImage`, `RenderTexture3D.renderWorld`) take a view and a
  projection matrix, which a `CameraComponent3D` can provide.


## CameraComponent3D

`CameraComponent3D` is a Flame `CameraComponent` (it has a `viewport`, a `viewfinder`, a `backdrop`
and HUD components) whose world is a `World3D`. By default it is a look-at camera: it sits at
`position`, looks at `target`, and keeps `up` pointing up on screen.

| Property             | Default          | Meaning                                              |
| -------------------- | ---------------- | ---------------------------------------------------- |
| `position`           | `(0, 0, 0)`      | The eye of the look-at view.                         |
| `target`             | `(0, 0, -1)`     | The point looked at.                                 |
| `up`                 | `(0, 1, 0)`      | Up on screen; the setter stores a normalized copy.   |
| `projection`         | `perspective`    | `CameraProjection.perspective` or `.orthographic`.   |
| `fovY`               | `60`             | Vertical field of view in degrees (perspective).     |
| `orthographicHeight` | `null`           | Height of the view volume in world units.            |
| `near`, `far`        | `0.01`, `1000`   | Clip distances from the eye along the view.          |
| `cameraMask`         | `0xFFFFFFFF`     | Which components and lights this camera sees.        |

```dart
class MyGame extends FlameGame3D {
  MyGame()
    : super(
        camera: CameraComponent3D(
          position: Vector3(6, 4, 6),
          target: Vector3.zero(),
          fovY: 50,
          near: 0.1,
          far: 200,
        ),
      );
}
```

The scene is drawn as one image covering the viewport: the world renders at the viewport's
`virtualSize` times the device pixel ratio times `World3D.renderScale`, and the image is drawn
centered on the viewfinder. Leave the viewfinder at its defaults (center anchor at the origin,
zoom 1, no rotation): zooming or rotating it scales or turns the finished image as a 2D picture.
Move the 3D camera instead.

`rotation` is not an input of the view. `FirstPersonCamera` and `ThirdPersonCamera` use it to place
`position` and `target`, and `rotate(yawDelta, pitchDelta)` (radians) turns it. The `forward`
(`target - position`) and `right` getters allocate a new vector on each call.


## Projections

`CameraProjection.perspective` is a pinhole camera with a vertical field of view of `fovY` degrees;
`0 < near < far` is required. `CameraProjection.orthographic` is a parallel projection of a view
volume `orthographicHeight` world units tall and `orthographicHeight * aspect` wide, so one world
unit covers `viewport.virtualSize.y / orthographicHeight` logical pixels. An orthographic camera also
accepts a zero or negative `near`, which keeps geometry behind the eye. While `orthographicHeight` is
`null` the orthographic projection uses `fovY` as its height, as earlier versions did; set
`orthographicHeight` instead, this fallback is deprecated.

```dart
final camera = CameraComponent3D(
  projection: CameraProjection.orthographic,
  orthographicHeight: 12,
  near: -50,
  far: 50,
  position: Vector3(10, 10, 10),
  target: Vector3.zero(),
  up: Vector3(0, 0, 1),
);
```

The projections target the clip space of Impeller and WebGPU: x and y in `[-w, w]` with +y up, and
the near plane at depth 0, the far plane at depth 1. View space is right-handed: the camera looks
down -z with +x to the right. The `Matrix4` extensions of `package:flame_3d/core.dart`
(`setAsViewMatrix`, `setAsPerspective`, `setAsOrthographic`, `setAsOrthographicOffCenter`) build
such matrices, for offscreen renders for instance; `setAsPerspective` takes degrees.
vector_math's `setPerspectiveMatrix` and `setOrthographicMatrix` follow OpenGL's -1 to 1 depth range
instead, and Impeller would clip the nearer half of it away. `Frustum.setFromViewProjection` is the
matching replacement for vector_math's `setFromMatrix`.


## Custom matrices

A `customViewMatrix` or `customProjectionMatrix` replaces the look-at view or the built-in projection
with any matrix, for example an oblique or a mirrored dimetric projection that no look-at camera
produces. A custom view must be an invertible affine matrix; a custom projection must target the
clip space above, and `fovY`, `orthographicHeight`, `near`, `far` and the aspect ratio do not apply
to it. Everything the camera derives follows them: the `frustum` used for culling, the
`eyePosition`, and the conversions between viewport points and world space.

```dart
// Swaps world x and y: a mirrored view.
final swapXY = Matrix4.identity()
  ..setEntry(0, 0, 0)
  ..setEntry(0, 1, 1)
  ..setEntry(1, 0, 1)
  ..setEntry(1, 1, 0);
camera.customViewMatrix = Matrix4.zero()
  ..setAsViewMatrix(Vector3(12, 12, 10), Vector3.zero(), Vector3(0, 0, 1))
  ..multiply(swapXY);
camera.customProjectionMatrix = Matrix4.zero()
  ..setAsOrthographicOffCenter(-8, 8, -6, 6, -50, 50);
```

The camera keeps a reference to a custom matrix and follows changes made to it in place. A
mirroring matrix reverses the winding of the triangles on screen: the determinant of
`projectionMatrix * viewMatrix` is negative for an ordinary camera and positive for a mirrored one.
The renderer flips the front-face winding for mirrored cameras, so back-face culling keeps culling
the faces that point away from the viewer.


## Caching and the version

`viewMatrix`, `projectionMatrix`, `viewProjectionMatrix`, `inverseViewMatrix`, `eyePosition` and
`frustum` are computed when first read after one of their inputs changed and cached until the next
change; reading them allocates nothing. The camera compares its inputs by value on each read, so
changes made in place (`camera.position.x += 1`, `camera.target.setFrom(...)`, editing a custom
matrix) are picked up as well as assignments, and so is a change of the viewport size.

The returned matrices, vector and frustum are the camera's own objects, updated in place: copy them
to keep a value, and never modify the frustum. `version` increases whenever an input that the
current matrices use changes (not `position` while a `customViewMatrix` is set, for example), so
data derived from the camera can be kept until the version differs. `matrixUpdateCount` counts the
recomputations, for profiling and tests.


## Rays and screen points

`viewportPointToRay` turns a point of the viewport into the world-space ray through it. The point is
in the viewport's own coordinates, with `(0, 0)` at its top-left corner and `viewport.virtualSize`
at its bottom-right; for a viewport that fills the game it is the `canvasPosition` of a Flame
pointer event, otherwise convert it with `viewport.globalToLocal(event.canvasPosition)`. The ray
starts on the near plane and its direction is unit length. It works for both projections and for
custom matrices, and writes into `output` when given.

```dart
final ground = Plane.normalconstant(Vector3(0, 0, 1), 0);

@override
void onTapUp(TapUpEvent event) {
  final ray = camera.viewportPointToRay(event.canvasPosition);
  final t = ray.intersectsWithPlane(ground);
  if (t != null) {
    final groundPoint = ray.at(t);
    // ...
  }
}
```

`worldToViewportPoint` goes the other way: it tells where a world-space point is drawn, in the same
coordinates, for example to place a 2D label over a 3D object. A point behind the eye of a
perspective camera gives a meaningless (mirrored) result. To find which object is under the
pointer, pass the ray to `World3D.raycast` (see [Geometry and Scene Queries](geometry.md)).


## Several cameras: CameraStack3D

A `CameraStack3D` renders several cameras into rectangles of the screen: split screen,
picture-in-picture minimaps, or an overlay drawn on top of another camera's picture. Give it to a
`FlameGame3D`; the game then renders the stack instead of its world through its own camera, whose
HUD components are still drawn on top.

```dart
final player1 = CameraComponent3D(
  position: Vector3(-10, 0, 6),
  target: Vector3(-10, 0, 0),
);
final player2 = CameraComponent3D(
  position: Vector3(10, 0, 6),
  target: Vector3(10, 0, 0),
);
final minimap = CameraComponent3D(
  projection: CameraProjection.orthographic,
  orthographicHeight: 40,
  position: Vector3(0, 0, 30),
  target: Vector3.zero(),
  cameraMask: 0x02,
);

final stack = CameraStack3D.splitHorizontal(player1, player2)
  ..addSlot(
    CameraViewportSlot3D(
      camera: minimap,
      normalizedViewport: const Rect.fromLTWH(0.72, 0.04, 0.25, 0.25),
      priority: 10,
      clearColor: const Color(0xFF0F172A),
      borderColor: const Color(0xFFFFFFFF),
    ),
  );
final game = FlameGame3D(cameraStack: stack);
```

Each `CameraViewportSlot3D` has:

- `camera`, and optionally its own `world` (otherwise the camera's world, otherwise the game's);
- `normalizedViewport`, the rectangle in `[0, 1]` screen coordinates (default: the whole screen);
  the camera's viewport is resized to the slot's size in logical pixels, so its aspect ratio and its
  rays match the slot;
- `priority`: slots are drawn from the lowest to the highest priority, in insertion order for ties;
- `clearMode` and `clearColor`, see below;
- `enabled`, `borderColor`, `borderWidth` (default `1.5`) and a `label` for debugging.

`CameraStack3D.splitHorizontal`, `splitVertical` and `quad` build the usual layouts.
`renderOffscreen` renders the whole stack into an `Image` that the caller disposes.

To find what is under a pointer, `pickSlotAndRay(screenPoint, canvasSize)` returns the topmost
enabled slot whose rectangle contains the point (or `null`), with the point in the slot's viewport
coordinates and the world ray of the slot's camera. `raycastAt` goes on and raycasts that ray into
the slot's world (the slot's `world`, else the camera's, else `defaultWorld`) and returns the pick
with the nearest `RayHit3D`, or `null` when no slot is under the point. It hits only what the
slot's camera draws: it passes the camera's `cameraMask` to `World3D.raycast`, which skips hidden
components and components (or their ancestors) whose `cameraMask` the camera does not share. It
takes `maxDistance`, `cullMode` and a `filter` of its own:

```dart
@override
void onTapUp(TapUpEvent event) {
  final result = stack.raycastAt(
    event.canvasPosition,
    Size(size.x, size.y),
    defaultWorld: world,
  );
  if (result case (final pick, final hit?)) {
    // pick.slot, pick.camera, hit.object, hit.worldPoint
  }
}
```

Every slot is rendered into an image of its own, cleared to transparent (or to `clearColor`), and
the image is drawn over the previous slots:

- `CameraClearMode3D.colorAndDepth` (the default) fills the slot with `clearColor`, or clears it to
  transparent when an earlier slot was drawn and no `clearColor` is set;
- `CameraClearMode3D.depthOnly` and `CameraClearMode3D.none` draw the slot's picture over what the
  earlier slots drew. Since every slot has its own depth buffer, the two behave the same way: an
  overlay camera (first-person hands, a gizmo) is never hidden by the geometry of the slots below.
  Use the `cameraMask` of the overlay's objects to keep them out of the other cameras.

Unmounted slot cameras are updated by the stack (`FlameGame3D.update` calls `stack.update`), but
only their own `update`, not their children's: add camera rigs to the game or the world and pass
them the camera explicitly.


### Costs of a stack

Each enabled slot costs a full render of its world: its own shadow pass when a light casts shadows
(a `ShadowGroup` is not shared across slots), its own post-processing passes, and a traversal of the
world's components. Each slot also creates a new render target (a color and a depth texture of the
slot's size) on every frame, see Limitations. `lastRenderedSlotCount` tells how many slots the last
frame drew.


## Camera rigs

The rigs are plain components that move a `CameraComponent3D` in their `update`. Add them as a
child of a mounted camera, or anywhere in the game with `camera:` passed to the constructor. Angles
are in radians and distances in world units.

For shots that blend from one to another and for scripted camera moves, see the virtual cameras
and timelines of [Cinematics](cinematics.md).


### FirstPersonCamera and ThirdPersonCamera

`FirstPersonCamera` puts its eye on the `following` point and looks one unit along its `rotation`
(the -Z axis of the rotation). `ThirdPersonCamera` stays `distance` (default `5`, at least `0.1`
through the setter) behind the `following` point along its `rotation` and always looks at it; each
update moves the eye `followDamping * dt` of the way to the desired position (default
`followDamping` `1`). Both are `CameraComponent3D` subclasses and accept the usual projection
settings.

```dart
final camera = ThirdPersonCamera(
  following: player.position,
  distance: 6,
  followDamping: 4,
);
```

The third-person damping is linear in `dt`: with `followDamping * dt` above `1` the camera
overshoots, and above `2` it diverges. Keep `followDamping` below `1 / dt` of the slowest frame, or
use `OrbitCameraController3D`, whose damping is exponential.


### OrbitCameraController3D

Orbits, zooms and pans a camera around a `target`, with exponential smoothing:

```dart
final orbit = OrbitCameraController3D(
  camera: game.camera,
  target: Vector3.zero(),
  upAxis: Vector3(0, 0, 1),
  distance: 12,
);
game.add(orbit);

// In drag and scale handlers:
orbit.orbitBy(-delta.x * 0.01, delta.y * 0.01);
orbit.zoomByFactor(scaleFactor);
orbit.panScreenDelta(delta);
orbit.fitAabb(layerBounds);
```

| Option                       | Default         | Meaning                                       |
| ---------------------------- | --------------- | --------------------------------------------- |
| `yaw`, `pitch`               | `0`, `0.35`     | Desired angles; pitch clamped to the limits.  |
| `minPitch`, `maxPitch`       | `-1.55`, `1.55` | Pitch limits, just short of straight up/down. |
| `distance`                   | `8`             | Desired orbit radius.                         |
| `minDistance`, `maxDistance` | `0.2`, `1000`   | Radius limits.                                |
| `damping` (or `smoothing`)   | `12`            | Exponential rate per second; `0` snaps.       |
| `upAxis`                     | `(0, 1, 0)`     | The world's up axis, `(0, 0, 1)` for z-up.    |

`orbitBy(dYaw, dPitch)` turns the desired angles, `zoomByFactor(f)` divides the distance by `f`,
`panScreenDelta(delta)` moves the target parallel to the image plane by `delta` viewport pixels (the
scene follows the finger), and `fitAabb(bounds, padding: 1.15)` frames a box (for an orthographic
camera it sets `orthographicHeight`) and snaps unless `immediate` is `false`. `snap()` jumps to the
desired state. Each update sets the camera's `position`, `target` and `up`.


### SpringArmCamera3D

A follow camera on a boom of `armLength` (default `5`) from a pivot: `targetComponent`'s world
position, or the `target` point, plus `socketOffset`. Each update casts one ray from the pivot
towards the desired eye through `World3D.raycast`; when it hits, the boom is shortened at once to
the hit distance minus `probeRadius` (default `0.25`), but not below `minArmLength` (default
`0.15`), and it grows back exponentially at `recoverySpeed` (default `8` per second) once the line
of sight is clear. The followed component and its descendants are ignored, and `collisionFilter`
can ignore more. `yaw` (default `0`) and `pitch` (default `0.25`) place the boom around `upAxis`
(default `(0, 1, 0)`); `isOccluded` and `currentArmLength` report the last update.

```dart
final arm = SpringArmCamera3D(
  camera: game.camera,
  targetComponent: hero,
  socketOffset: Vector3(0, 1.5, 0),
  armLength: 6,
  collisionFilter: (object) => !object.hasTag3D('foliage'),
);
game.add(arm);
```

It is a single ray, not a swept sphere: the camera can still clip a wall it grazes. The ray tests
the visible components of the world, whatever their `cameraMask` (see
[Geometry and Scene Queries](geometry.md)): a hidden wall does not block the boom, and
`collisionFilter` can drop what should not block it either.


### CameraDollyTrack3D

Moves a camera along `eyeSpline` (a `CatmullRomSpline3D`) in `duration` seconds (default `5`),
looking along `lookAtSpline`, at a fixed `lookAtTarget`, or, without either, along the track's
tangent. `cubicEasing` (default `true`) applies smoothstep easing to the progress; `loop` restarts
at the end, and `onComplete` is called when a non-looping track ends. `progress` (0 to 1) can be
set to scrub, `playing` pauses, and `reset()` starts over.

```dart
final dolly = CameraDollyTrack3D(
  camera: game.camera,
  eyeSpline: CatmullRomSpline3D([
    Vector3(-10, 3, 10),
    Vector3(0, 5, 12),
    Vector3(10, 3, 10),
  ]),
  lookAtTarget: Vector3.zero(),
  duration: 8,
  onComplete: () => game.startPlaying(),
);
game.add(dolly);
```

With `loop` and `cubicEasing` both on, the easing applies to each lap, so the camera slows to a
stop at every loop point; turn `cubicEasing` off for a steady loop.


### CameraShake3D

A trauma-based shake: `addTrauma(amount)` raises `trauma` (0 to 1), which decays by `traumaDecay`
per second (default `1.2`). The shake strength is `trauma²`: the eye moves by up to
`maxPositionOffset` (default `0.35`) and the view turns by up to `maxAngleRad` (default `0.06`)
around its three axes, following a smooth deterministic noise of `frequency` (default `18`) seeded
by `seed`.

```dart
final shake = CameraShake3D(camera: game.camera);
game.add(shake);
// On an impact:
shake.addTrauma(0.5);
```

The shake is added on top of the camera's pose in the shake's `update`, and taken off again at the
start of the next one if nothing else moved the camera in between. It must therefore update after
any rig that sets the camera every frame: add it after the rig, or give it a higher `priority`.
`reset()` clears the trauma and restores the unshaken pose.


## Limitations

- The 3D camera ignores the viewfinder: zooming, rotating or moving the viewfinder transforms the
  rendered image as a 2D picture.
- Moving a `CameraComponent3D` (or a rig moving it) does not mark the game as visually changed. With
  `IdleRenderMode.onDemand` or `onDemandWhenIdle`, call `Game.notifyVisualMutation()` after moving
  the camera, or the frame is not repainted until something else changes.
- `CameraStack3D` renders each slot with `World3D.renderToImage`, which creates a new render target
  for every slot on every frame instead of reusing pooled ones, and it sorts its slots into new
  lists on every `render` and `pickSlotAndRay` call.
- `CameraClearMode3D.depthOnly` and `CameraClearMode3D.none` produce the same result; there is no
  depth buffer shared between slots.
- `ThirdPersonCamera` damping is not stable for `followDamping * dt > 2`.
- `SpringArmCamera3D` uses one ray, and the camera rigs allocate a small vector on every update.
