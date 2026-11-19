# Input and Effects

This page covers two things that make 3D objects interactive and alive: pointer input on 3D objects
(`package:flame_3d/input.dart`) and effects that animate their transforms and materials
(`package:flame_3d/effects.dart`), including smoothing objects simulated at a fixed time step.


## Pointer input on 3D objects

Flame's 2D event system delivers taps, drags and mouse moves to 2D components. A
`PointerRouter3D` is a 2D component that takes part in that system and turns the pointer events it
receives into rays through the 3D scene: the object a ray hits first receives 3D events, through
three mixins for `Object3D`s (meshes, models, instanced groups):

- `TapCallbacks3D`: `onTapDown3D`, `onTapUp3D`, `onTapCancel3D`;
- `HoverCallbacks3D`: `onHoverEnter3D`, `onHoverMove3D`, `onHoverExit3D` (mouse and trackpad);
- `DragCallbacks3D`: `onDragStart3D`, `onDragUpdate3D`, `onDragEnd3D`, with the pointer's motion
  projected onto a plane or an axis in the world.

```dart
class Piece extends MeshComponent with TapCallbacks3D, DragCallbacks3D {
  Piece({required super.mesh, super.position});

  @override
  void onTapUp3D(TapUpEvent3D event) {
    color = const Color(0xFFFFD166);
  }

  @override
  void onDragUpdate3D(DragUpdateEvent3D event) {
    position.add(event.worldDelta);
  }
}
```

The interactive panels of `WidgetSurface3D` receive their input through the same router (see
[How input reaches it](ui_3d.md#how-input-reaches-it)).


### In a 3D game

In a `FlameGame3D`, create the router with `PointerRouter3D.forCamera` and add it to the game
itself, so its local coordinates are the canvas coordinates that the camera's viewport covers:

```dart
class Board extends FlameGame3D {
  @override
  Future<void> onLoad() async {
    camera.position.setValues(0, 10, 10);
    world.add(Piece(mesh: CuboidMesh(size: Vector3.all(1))));
    add(PointerRouter3D.forCamera(world: world, camera: camera));
  }
}
```

The router covers its `size` when it has one, otherwise the camera viewport's `virtualSize`. Rays
are made with `CameraComponent3D.viewportPointToRay`, for perspective and orthographic cameras.


### In a 3D layer of a 2D game

For a `Scene3DComponent` (see [Embedding](embedding.md)), create the router with `PointerRouter3D.forScene`
and add it as a child of the layer, or anywhere else in the same 2D world, for example as the
layer's sibling:

```dart
final router = PointerRouter3D.forScene(layer);
layer.add(router);
```

The router converts each point from its own coordinates to the layer's (through the router's and
the layer's transforms) and passes it to `layer.localPointToRay`, so a router and a layer that are
moved, scaled or rotated independently still pick exactly. Flame converts the event positions
through the 2D camera, so picking stays exact while the 2D camera pans and zooms. Both must be
under the same 2D camera (a router in the camera's viewport for a layer in its world does not get
matching coordinates). Without a `size`, the router covers the layer's `size` when the layer has
one, and everything otherwise.


### How the hit is found

On a tap down, a tap up, a drag start and every mouse move, the router casts one ray with
`World3D.raycast` (see [Against a scene](geometry.md#against-a-scene)): every `Object3D` whose
bounds the ray crosses is tested against the triangles of its meshes, through their bounding volume
hierarchies, and the nearest hit wins. Hits are therefore ordered by depth, whatever the order of
the components.

Only what the router's view draws is picked. The ray cast gets the camera mask of the `forCamera`
camera or of the `forScene` layer (`pickCameraMask`), so an object whose `cameraMask` (or an
ancestor's) shares no bit with it is skipped with its subtree, and so is an object hidden with
`visible = false`; neither receives events.

The nearest hit wins even when the object hit does not listen to events: a wall, a decoration or
an effect mesh in front of a piece takes the tap, and the piece behind it gets nothing. Exclude
such objects with the router's `filter`. `cullMode` (default: each material's own) can make
back faces hittable, and `filter` and `cullMode` can be changed at any time:

```dart
final router = PointerRouter3D.forScene(
  layer,
  filter: (object) => object is Piece,
);
```

An invisible catcher mesh that still draws (for example one with a `ShadowCatcherMaterial`) is
visible as far as the ray cast goes; exclude it with the `filter`.

When the object hit is an `InstancedGroup3D`, `event.instanceIndex` is the index of the instance
hit. `event.hit` is the `RayHit3D` with the world point, normal, triangle and surface.


### Order against 2D components

The router is an ordinary 2D component for Flame's hit testing: components in front of it (for
siblings, those with a higher `priority`) receive events before it, and components behind it
after it, if it lets them.

- A tap down or drag start that hits an object with a matching listener is consumed: the event
  stops at the router.
- One that hits nothing, or hits an object without listeners, continues to the components behind
  the router, so a 2D camera pan or a click on the 2D ground behind the 3D layer still works.
- Tap up and cancel events follow their tap down, and drag updates and ends follow their drag
  start, as everywhere in Flame.

Give HUD components a higher priority than the router (or put them in front of it) so they are
served first. The router's `isDropPayload` is `false`: its drags skip the drop-target hit tests and
are never offered to a `DropTargetCallbacks` component as a drop.


### Taps

`onTapDown3D` goes to the hit object if it has `TapCallbacks3D`, then to each ancestor that has
it, bottom-up, until one sets `event.handled = true`. When the pointer is released, every object
that received the tap down gets exactly one of `onTapUp3D` and `onTapCancel3D`: the up, in the
same order, if the ray at the release point still hits it or one of its descendants and no object
before it set `handled` on the up event; the cancel otherwise. When Flame cancels the tap, the
objects that received the tap down get `onTapCancel3D`.

```dart
class Card3D extends MeshComponent with TapCallbacks3D {
  Card3D({required super.mesh});

  @override
  void onTapDown3D(TapDownEvent3D event) {
    scale.setValues(0.95, 0.95, 0.95);
    event.handled = true; // ancestors (the table) do not get it
  }

  @override
  void onTapUp3D(TapUpEvent3D event) {
    scale.setValues(1, 1, 1);
    flip();
  }

  @override
  void onTapCancel3D(TapCancelEvent3D event) {
    scale.setValues(1, 1, 1);
  }

  void flip() {}
}
```

Every event carries `pointerId`, `localPosition` (the 2D point in the router's coordinates),
`worldRay` and `target` (the object hit), plus `hit` (the `RayHit3D`, when there is one) on tap,
hover and drag-start events.


### Hover

On every mouse move inside its area, the router casts a ray. Objects that start being hit get
`onHoverEnter3D` (after the `onHoverExit3D` of those that stop being hit), objects still hit get
`onHoverMove3D`, and when the pointer leaves the router's area, a button is pressed or the mouse
stops being tracked, every hovered object gets `onHoverExit3D`. The hit object and its ancestors
with `HoverCallbacks3D` are hovered together; `event.handled = true` in one of them ends the hover
of the ancestors above it. Each pointer (`pointerId`) has its own hovered objects, so two mice or a
mouse and a stylus do not end each other's hover. Touch screens do not hover.


### Drags

`onDragStart3D` reaches the hit object and its ancestors with `DragCallbacks3D` like a tap. From
then on, each of them gets `onDragUpdate3D` (in the same order, until one sets `handled`) with the
pointer projected onto its own drag geometry:

- with `dragAxisConstraint` set, onto the line through the grab point along that axis: the point
  of the line closest to the pointer's ray (for gizmo arrows and sliders);
- otherwise onto the plane through the grab point with normal `dragPlaneNormal`, or the router's
  `defaultDragNormal`, or, without either, a plane facing the camera (`forCamera`) or the viewer
  (`forScene`).

`worldPlanePoint` is the projected point and `worldDelta` its change since the previous event, so
`position.add(event.worldDelta)` moves an object with the pointer, which it follows exactly (the
router uses the pointer's current position from each Flame drag update). A ray parallel to the
plane, or meeting it behind the eye of a perspective camera or perspective layer, repeats the last
point. `onDragEnd3D` has `wasCancelled` set when the gesture was cancelled.

```dart
class Token extends MeshComponent with DragCallbacks3D {
  Token({required super.mesh, super.position}) {
    dragPlaneNormal = Vector3(0, 1, 0); // slide on the ground
  }

  @override
  void onDragUpdate3D(DragUpdateEvent3D event) {
    position.add(event.worldDelta);
  }

  @override
  void onDragEnd3D(DragEndEvent3D event) {
    position.x = position.x.roundToDouble(); // snap to the grid
    position.z = position.z.roundToDouble();
  }
}
```


### Dispatching events yourself

The router's work is also available as methods taking a point in its coordinates:
`dispatchTapDown`, `dispatchTapUp`, `dispatchTapCancel`, `dispatchHover`, `dispatchHoverExit`,
`dispatchDragStart`, `dispatchDragUpdate` and `dispatchDragEnd` (tap down and drag start return
whether a listener took the event; `dispatchHoverExit(pointerId: null)` ends the hover of every
pointer). They drive tests without a widget tree and custom input such
as a gamepad cursor; `pointToWorldRay` gives the ray of a point.

```dart
final router = PointerRouter3D.forCamera(world: world, camera: camera);
final screenPoint = camera.worldToViewportPoint(piece.position);
router
  ..dispatchTapDown(screenPoint)
  ..dispatchTapUp(screenPoint);
```


### Cost of input

Input costs nothing per frame. Each tap down, tap up, drag start and mouse move costs one
`World3D.raycast`: a walk over the world's components with a bounds test each, and a triangle test
for the candidates. Turn on `World3D.spatialIndex3DEnabled` for worlds with many objects (see
[Geometry](geometry.md)). Drag updates do not raycast. Each event allocates a few small objects (the
event, copies of the ray and point).


## Effects on 3D components

The 3D effects are Flame effects (`Effect3D` extends Flame's `ComponentEffect`): add one as a child
of a `Component3D`, drive it with any `EffectController`, and it runs and removes itself when done.
`package:flame_3d/effects.dart` exports `package:flame/effects.dart`, so the controllers,
`SequenceEffect`, `onComplete` and `removeOnFinish` are at hand:

```dart
piece.add(
  ArcMoveEffect3D(
    Vector3(4, 0, 2),
    EffectController(duration: 0.6, curve: Curves.easeInOut),
    arcHeight: 1.2,
    onComplete: () => piece.add(
      SquashStretchEffect3D(
        controller: EffectController(duration: 0.25),
        intensity: -0.3, // squash on landing
      ),
    ),
  ),
);
```


### Transform effects

| Effect                  | Applies  | What it does                                       |
|-------------------------|----------|----------------------------------------------------|
| `MoveToEffect3D`        | additive | Moves to a point.                                  |
| `MoveByEffect3D`        | additive | Moves by an offset.                                |
| `ArcMoveEffect3D`       | additive | Moves to a point along a parabolic arc.            |
| `SplinePathEffect3D`    | absolute | Follows a `CatmullRomSpline3D`; can face along it. |
| `RotateToEffect3D`      | absolute | Turns to a quaternion along the shortest arc.      |
| `RotateAroundEffect3D`  | absolute | Spins around an axis, optionally orbiting a pivot. |
| `ScaleToEffect3D`       | additive | Scales to a target scale.                          |
| `SquashStretchEffect3D` | absolute | Stretches and squashes, keeping the volume.        |

Additive effects add the change since their previous step, as Flame's 2D move and scale effects
do, so they combine: two `MoveByEffect3D`s at once add up, and code that moves the object at the
same time is not undone. Absolute effects set the property from values captured when they started,
so they override other changes to that property while they run.

- `MoveToEffect3D` computes its offset when it starts; `ArcMoveEffect3D` adds a lift of
  `4 * p * (1 - p) * arcHeight` (default `1.5`) along `upAxis` (default +Y) to the straight move,
  which peaks at the middle and is zero at both ends.
- `SplinePathEffect3D` sets the position from the spline at the effect's progress. The spline's
  parameter is spread evenly over its segments, not by length, so the speed changes where control
  points are unevenly spaced. With `orientToTangent: true` it also turns the object's -Z axis
  along the curve, keeping `upAxis` (default +Y) up.
- `RotateAroundEffect3D(axis:, radians:, controller:)` turns the object by `radians` around `axis`
  in its parent's space. With a `pivot`, the position orbits around it too, and `alignRotation`
  (default `true`) chooses whether the object also turns.
- `SquashStretchEffect3D` scales by `1 + intensity * sin(pi * p)` along `upAxis` and by the
  inverse square root of that across it, so the volume stays the same and the scale is back to
  its starting value at the end. `intensity` defaults to `0.28`; a negative one squashes first.
  The scaling is exact for the X, Y and Z axes; a slanted `upAxis` gives a blend of the three.


### Material effects

- `ColorTintEffect3D(targetColor, controller)` blends a `MeshComponent`'s `color`, the per-instance
  tint that the built-in materials multiply their base color by, from its value at the start to
  `targetColor`, alpha included.
- `InstanceDataEffect3D(targetData, controller)` blends the `instanceData` vector of a
  `MeshComponent` or a `ModelComponent` (four floats that custom shaders read, see
  [Materials](materials.md)); added to another kind of `Object3D` it throws an `UnsupportedError` when
  mounted.

Both are absolute and mark the enclosing world as changed on every step, so retained layers
(`Scene3DCacheMode.retained`) render again while they run.

```dart
mesh.add(
  ColorTintEffect3D(
    const Color(0xFFFF4D4D),
    EffectController(duration: 0.15, alternate: true, repeatCount: 2),
  ),
);
```


### Controllers, sequences and springs

Flame's controllers work: curves, `alternate`, `repeatCount` and `infinite`, delays,
`SequenceEffect` and the spring controllers (`SpringEffectController`), whose overshoot carries
through to additive effects. Speed-based controllers (`EffectController(speed: ...)`) need a
`MeasurableEffect`, which the move, rotate and scale effects are; the duration is the effect's
measure divided by the speed, computed when the effect starts:

| Effect                  | Measure                                                     |
|-------------------------|-------------------------------------------------------------|
| `MoveToEffect3D`        | Distance from the start to the destination.                 |
| `MoveByEffect3D`        | Length of the offset.                                       |
| `ArcMoveEffect3D`       | Length of the arc (the speed is the average along it).      |
| `SplinePathEffect3D`    | Length of the curve (the speed is the average along it).    |
| `RotateToEffect3D`      | Rotation angle in radians (radians per second).             |
| `RotateAroundEffect3D`  | `radians`, as an absolute value.                            |
| `ScaleToEffect3D`       | Length of the change of the scale vector.                   |

`SquashStretchEffect3D` and the material effects have no measure; a speed-based controller on them
fails with Flame's assertion. For example, `MoveToEffect3D(target, EffectController(speed: 2))`
moves a piece at 2 units per second whatever the distance. A sequence of 3D effects:

```dart
piece.add(
  SequenceEffect([
    MoveByEffect3D(Vector3(0, 1, 0), EffectController(duration: 0.2)),
    RotateAroundEffect3D(
      axis: Vector3(0, 1, 0),
      radians: math.pi,
      controller: EffectController(duration: 0.4),
    ),
    MoveByEffect3D(Vector3(0, -1, 0), EffectController(duration: 0.2)),
  ]),
);
```


### Cost of effects

Effects run in the update, on the CPU. The transform effects allocate nothing per step: they write
the component's position, rotation or scale in place, which marks its transform and the world as
changed. `ColorTintEffect3D` allocates one `Color` per step (`MeshComponent.color` takes an
immutable `Color`); both material effects mark the world they are mounted in as changed directly.


## Fixed-step interpolation

When a game simulates at a fixed rate (`FlameGame.fixedTimeStep` with `HasFixedUpdate`), objects
move in steps that do not match the display's frames and seem to stutter.
`FixedTransformInterpolation3D` keeps the transform of the last two simulation steps and shows a
blend of them between frames. With `HasFixedUpdate` (from `package:flame/components.dart`) it
needs one call, `captureFixedState()` at the start of `fixedUpdate`:

```dart
class Ball extends MeshComponent
    with HasFixedUpdate, FixedTransformInterpolation3D {
  Ball({required super.mesh});

  final Vector3 velocity = Vector3(2, 0, 0);

  @override
  void fixedUpdate(double fixedDt) {
    captureFixedState(); // restores the simulated pose, keeps it
    position.addScaled(velocity, fixedDt);
  }
}
```

The mixin's `update` then writes the blend for the game's `renderInterpolationAlpha` into the
transform, every frame, while `autoInterpolate` is `true` (the default) and the game has a
`fixedTimeStep`. When fixed steps ran in a frame but the component did not call
`captureFixedState` (a paused time scale, ticks turned off, a body at rest that returns early),
its simulated transform is shown instead, so it does not slide between two old states.

- `captureFixedState` puts the simulated transform back if an interpolated one is shown, and
  keeps it as the previous step;
- `commitFixedState` keeps the transform after the step as the current one (the blend does this
  itself for the transform the step left);
- `applyInterpolationAlpha(alpha)` writes the blend of the two into `position`, `scale` (linear)
  and `rotation` (shortest-arc slerp), for `alpha` from `0` (previous) to `1` (current);
- `restoreSimulatedState` puts the simulated transform back, for code that must read it between
  frames;
- `teleportFixedState` makes both steps equal to the current transform, so a teleport or a spawn
  does not slide across the screen. It is called when the component mounts.

A component without `HasFixedUpdate` is not blended by itself: whatever steps it calls
`captureFixedState` before each step, `commitFixedState` after it and `applyInterpolationAlpha`
with its own alpha, as for bodies of a `PhysicsWorld3D` stepped at a fixed rate (see
[Smooth motion on fast displays](physics.md#smooth-motion-on-fast-displays)).

Between a blend and the next `captureFixedState`, other code that reads the transform (raycasts,
audio, input) sees the blended pose. The mixin does not combine with effects on the same
component: an effect that moves the object would be undone by the next blend.


## Limitations

- The nearest hit wins, listener or not; there is no pass-through to objects behind a
  non-interactive one other than the `filter`.
- A `forScene` router must be under the same 2D camera as its layer.
- `PointerRouter3D` works with one camera or layer; for split screens with a `CameraStack3D`, pick
  with `CameraStack3D.raycastAt` (see [Cameras](cameras.md)), which uses the mask of the slot's camera.
- `SplinePathEffect3D` does not move at constant speed (a speed-based controller sets its average
  speed); `SquashStretchEffect3D` is exact only for the principal axes and has no measure for a
  speed-based controller.
- `FixedTransformInterpolation3D` blends by itself only for `HasFixedUpdate` components in a game
  with a `fixedTimeStep`, and does not mix with effects on the same component.
