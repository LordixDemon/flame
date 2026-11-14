# Move Effects

Move Effects are a special type of effects that modify the position of a component over time, if
you want to for example move your character from one point to another, make it jump, or follow a
path, then you can use one of the predefined move effects.


## `MoveByEffect`

This effect applies to a `PositionComponent` and shifts it by a prescribed `offset` amount. This
offset is relative to the current position of the target:

```{flutter-app}
:sources: ../flame/examples
:page: move_by_effect
:show: widget code infobox
:width: 180
:height: 160
```

```dart
final effect = MoveByEffect(
  Vector2(0, -10),
  EffectController(duration: 0.5),
);
```

If the component is currently at `Vector2(250, 200)`, then at the end of the effect its position
will be `Vector2(250, 190)`.

Multiple move effects can be applied to a component at the same time. The result will be the
superposition of all the individual effects.


## `MoveToEffect`

This effect moves a `PositionComponent` from its current position to the specified destination
point in a straight line.

```{flutter-app}
:sources: ../flame/examples
:page: move_to_effect
:show: widget code infobox
:width: 180
:height: 160
```

```dart
final effect = MoveToEffect(
  Vector2(100, 500),
  EffectController(duration: 3),
);
```

It is possible, but not recommended to attach multiple such effects to the same component.


## `MoveAlongPathEffect`

This effect moves a `PositionComponent` along the specified path relative to the component's
current position. The path can have non-linear segments, but must be singly connected. It is
recommended to start a path at `Vector2.zero()` in order to avoid sudden jumps in the component's
position.

```{flutter-app}
:sources: ../flame/examples
:page: move_along_path_effect
:show: widget code infobox
:width: 180
:height: 160
```

```dart
final effect = MoveAlongPathEffect(
  Path()..quadraticBezierTo(100, 0, 50, -50),
  EffectController(duration: 1.5),
);
```

An optional flag `absolute: true` will declare the path within the effect as absolute. That is, the
target will "jump" to the beginning of the path at start, and then follow that path as if it was a
curve drawn on the canvas.

Another flag `oriented: true` instructs the target not only move along the curve, but also rotate
itself in the direction the curve is facing at each point. With this flag the effect becomes both
the move- and the rotate- effect at the same time.

`MoveAlongPathEffect` pre-samples its `PathMetric` into a dense lookup table once on creation, so
evaluating points and tangents during `apply(progress)` performs zero per-frame `Tangent`
allocations.


## `ArcMoveEffect` and `ElevationTarget`

`ArcMoveEffect` moves a component linearly along its ground trajectory (`position`) while computing
a parabolic jump height $4h \cdot t(1 - t)$ at zero per-frame allocation cost:

- If the target implements `ElevationTarget` (`setElevation(double elevation)`), its base `position`
  stays strictly on the ground plane (keeping ground shadows planted!) while its visual body rises by
  `elevation`.
- Otherwise, `ArcMoveEffect` offsets `position` along `upVector` (default `Vector2(0, -1)`).

```dart
class HeroPawn extends PositionComponent implements ElevationTarget {
  final PositionComponent body = PositionComponent();

  @override
  void setElevation(double elevation) {
    body.position.y = -elevation;
  }
}

pawn.add(
  ArcMoveEffect(
    destinationCell,
    EffectController(duration: 0.22, curve: Curves.easeInOut),
    arcHeight: 20.0,
  ),
);
```


## `WaypointPathEffect` (Catmull-Rom Spline Traversal)

`WaypointPathEffect` smoothly interpolates a component across a sequence of `Vector2` waypoints
using a configurable Catmull-Rom spline (`tension` in `[0.0 .. 1.0]`), parameterized by uniform arc
length (`samplesPerSegment`), with optional `oriented: true` tangent rotation and deterministic
`onWaypointReached(int index)` callbacks as each waypoint is crossed:

```dart
pawn.add(
  WaypointPathEffect(
    [cellA, bridgeMid, cellB, cellC],
    EffectController(duration: 0.65, curve: Curves.easeInOutCubic),
    tension: 0.25,
    onWaypointReached: (index) => playStepSound(index),
  ),
);
```
