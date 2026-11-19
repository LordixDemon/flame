# Collisions and Physics

`flame_3d` has two separate systems that are easy to mix up:

- **Collision detection** (`package:flame_3d/collisions.dart`): `Collider3D` volumes registered in a
  `CollisionSystem3D` report when they overlap and answer queries (raycasts, overlap tests, shape
  casts). Nothing is pushed apart. The `KinematicCharacterController3D` uses these queries to move
  a character through a level, and `SkinnedHitboxRig3D` raycasts against the bones of an animated
  model.
- **Rigid-body dynamics** (`package:flame_3d/physics.dart`): a `PhysicsWorld3D` steps
  `RigidBody3D` bodies under gravity, contacts, friction and joints. Dice, falling crates, ragdolls,
  floating boats and raycast vehicles live here. `XpbdCloth3D` and `XpbdRope3D` are separate
  position-based simulations in the same library.

Rigid bodies collide only with other rigid bodies. A `Collider3D` floor does not hold up a
`RigidBody3D` (see [Rigid bodies and colliders](#rigid-bodies-and-colliders)). The only places
where the two systems meet are continuous collision detection and vehicle wheel rays, which also
test the colliders of a `CollisionSystem3D`, and cloth, which can be pushed out of sphere and
capsule colliders.

Everything on this page runs on the CPU in Dart. Nothing needs a GPU backend, so it behaves the
same on Android, iOS, macOS, the web and in `flutter test` (with or without
`--enable-flutter-gpu`).


## Units and conventions

- Lengths are in meters, masses in kilograms, time in seconds, angles in radians. Velocities are
  `m/s` and `rad/s`, forces `N`, impulses `N*s`.
- The default gravity is `(0, -9.81, 0)`: Y is up. A Z-up world passes
  `gravity: Vector3(0, 0, -9.81)` to `PhysicsWorld3D` and `upAxis: Axis3D.z` to the character
  controller. Buoyancy assumes Y-up, see [Buoyancy](#buoyancy).
- A `CollisionManifold3D` describes the overlap of shape `A` and shape `B`: its `normal` is a unit
  vector **from `A` toward `B`**, so moving `A` by `-normal * penetrationDepth` separates them. Its
  `contacts` hold one to four `ContactPoint3D` pairs.
- Shapes are defined in the local space of their owner, centered on its origin. The owner's scale
  scales the collision shape, but not the mass properties of a rigid body.
- The solver tolerances are absolute: a resting body sinks about 1.4 mm into what it rests on (the
  allowed penetration, the slop, is 4 mm), and the sleep thresholds are in `m/s` and `rad/s`. They
  suit objects from about 0.1 m to a few meters. A box with a 1.6 cm side sinks by 9 % of its size,
  so model small objects at a larger scale (the dice in the tests are 0.5 m cubes).


## Collision shapes

| Shape                | Contacts generated            | Mass properties       |
| -------------------- | ----------------------------- | --------------------- |
| `SphereShape3D`      | exact, 1 point                | exact                 |
| `CapsuleShape3D`     | exact, 1 point                | exact                 |
| `BoxShape3D`         | against a box: up to 4 points | exact                 |
| `ConvexHullShape3D`  | GJK and EPA, 1 point          | from the bounding box |
| `CompoundShape3D`    | per child, merged             | from the children     |
| `HeightfieldShape3D` | per grid cell, merged         | none, for static use  |

- `SphereShape3D(radius: r)`.
- `CapsuleShape3D(radius: r, height: h, axis: Axis3D.y)`: `height` is the total length from tip
  to tip, at least `2 * radius`.
- `BoxShape3D(halfExtents: v)`.
- `ConvexHullShape3D(vertices: points)`.
- `CompoundShape3D([CompoundChildShape3D(shape: s, position: p, rotation: q, massWeight: 1)])`.
- `HeightfieldShape3D(heights: h, columns: c, rows: r, width: w, depth: d, heightScale: 1)`.

Sphere, capsule and box pairs are solved analytically. A box against a box uses the 15 axes of the
separating axis test and clips the incident face against the reference face, which gives a stable
manifold of up to four points: a box rests flat and comes to sleep. Every other pair that involves a
hull goes through GJK and EPA and yields a single contact point per step; see the hull notes below.

`ConvexHullShape3D` takes any point cloud; the hull is implicit (each support query scans all
points, so keep hulls to a few dozen points). Its mass properties are taken from the bounding box
of the points, not from the hull:

- the center of mass is the local origin, so center the vertices on the center of mass;
- the volume is half the volume of the bounding box (a cube hull reports half its volume, a
  regular tetrahedron 1.5 times its volume);
- the inertia is that of a solid box filling the bounding box;
- `inscribedSphereRadius` is the smallest half-extent of the bounding box, which is larger than the
  real inradius of most polyhedra (an octahedron reports its circumradius). This radius is the
  default sphere of continuous collision detection, see [Continuous collision
  detection](#continuous-collision-detection).

For the regular polyhedra used as dice (centered, in their usual orientation) the bounding box is a
cube, so the inertia is isotropic and the result is fair, but the hull still rocks on its single
contact point, see [Contact quality](#contact-quality).

`CompoundShape3D` builds a concave shape from convex children, each with a `position`, a
`rotation` and a `massWeight` (default `1`). The mass is split between children in proportion to
their volume times `massWeight`, the center of mass is the weighted mean of the children's centers
(`centerOfMass`), and the inertia tensor is summed with the parallel-axis theorem
(`computeLocalInertiaTensor`), including the off-diagonal terms. A rigid body integrates around
that center of mass. Contacts are generated per child and merged when their normals agree.

`HeightfieldShape3D` is a `columns x rows` grid of heights (row-major, `heights[row * columns +
col]`) spanning `width` along X and `depth` along Z, centered on its local origin. It triangulates
each cell like `TerrainMesh3D` (diagonal from `(col, row)` to `(col + 1, row + 1)`), so a terrain
mesh and its heightfield agree; `sampleHeight(x, z)` and `sampleNormal(x, z)` read the surface. It
has no inertia: use it for static bodies and colliders.

There is no triangle-mesh shape for colliders or bodies. Shape casts and the character controller
can test against the triangles of `MeshComponent` and `ModelComponent` surfaces through their
bounding volume hierarchy, and `Narrowphase3D.intersectShapeWithSurfaceBvh` does the same for a
single shape. Two shapes can also be tested directly:

```dart
// A manifold, or null when the shapes are apart.
final manifold = Narrowphase3D.test(sphere, sphereAt, box, boxAt);
// Every manifold of a concave pair (compounds, heightfields).
final all = Narrowphase3D.testAll(compound, compoundAt, terrain, terrainAt);
// (distance, normal), or null.
final hit = box.raycast(ray, boxAt, maxDistance: 10);
```


## Collision detection


### Colliders and callbacks

Add one `CollisionSystem3D` to the world. Every frame it finds all `Collider3D` components under
its parent (plus any registered with `register`), updates a dynamic AABB tree, tests the
overlapping pairs and calls back:

```dart
class Coin extends Component3D with CollisionCallbacks3D {
  Coin({super.position})
    : super(
        children: [Collider3D(shape: SphereShape3D(radius: 0.3))],
      );

  @override
  void onCollisionStart3D(Collider3D other, CollisionManifold3D manifold) {
    removeFromParent();
  }
}

void setUpCollisions(World3D world, Component3D player) {
  world.add(CollisionSystem3D());
  player.add(
    Collider3D(
      shape: CapsuleShape3D(radius: 0.4, height: 1.8),
      collisionLayer: 0x2,
      collisionMask: 0x1 | 0x4,
    ),
  );
}
```

A collider sits at its world transform (it may be a child of any `Component3D`, or stand alone)
plus its `localOffset`. `onCollisionStart3D`, `onCollision3D` (on every later step while the pair
overlaps) and `onCollisionEnd3D` are called on the collider when it mixes in
`CollisionCallbacks3D`, and on its parent when the parent does. The manifold's normal points from
the receiving collider toward `other`. A pair that disappears because a collider was removed ends
on the next step, or at once with `unregister`.

Two colliders are tested when each one's `collisionLayer` has a bit in the other's
`collisionMask` (defaults: layer `1`, mask `0xFFFFFFFF`), when they have different host components,
and when at least one is not `isStatic`. Static colliders are still re-synchronized every step;
`isStatic` only skips static pairs.

With `autoStep: true` (the default) the system steps in its `update`; with `autoStep: false`, call
`step()` yourself, for example after moving things.


### Triggers

`TriggerVolume3D` is a collider with `isTrigger: true` and three optional callbacks:

```dart
world.add(
  TriggerVolume3D(
    shape: BoxShape3D(halfExtents: Vector3(2, 1, 2)),
    position: Vector3(10, 1, 0),
    collisionLayer: 0x4,
    onEnter3D: (other, manifold) => print('entered'),
    onExit3D: (other) => print('left'),
  ),
);
```

`onStay3D` runs every step while a collider stays inside. A trigger takes part in pair detection
like any collider (both sides get their callbacks); `isTrigger` only matters to queries, shape
casts and the character controller, which skip triggers unless asked (`includeTriggers`).

A rigid body is not a collider. To let a die enter a trigger, give its mesh a `Collider3D` as well
as its `RigidBody3D`.


### Queries

```dart
final hit = system.raycastColliders(
  Ray.originDirection(eye, forward),
  maxDistance: 50,
  collisionMask: 0x2,
  includeTriggers: false,
);
if (hit != null) {
  print('${hit.collider} at ${hit.distance} m, normal ${hit.normal}');
}
final nearby = system.overlapSphere(eye, 3, mask: 0x4);
```

`raycastColliders` returns the nearest `ColliderRayHit3D` (`collider`, `distance`, `point`,
`normal`), `raycastAllColliders` all hits sorted by distance. `overlapSphere`, `overlapBox`,
`overlapCapsule` (a segment and a radius) and `overlapFrustum` return the colliders confirmed by
the narrowphase; `overlapShape` returns each collider with its manifold. All take a layer mask, an
`includeTriggers` flag and an optional `filter`. Each query first re-synchronizes the tree with the
scene (a walk over the system's parent subtree), so many queries per frame cost more than one
step.

`DynamicAabbTree3D<T>` is the tree behind both systems and can be used on its own: `insert(item,
bounds)` returns a proxy id, `update(proxyId, bounds)` returns `false` without touching the tree
while the bounds stay inside the proxy's enlarged box (`fatMargin`, default `0.12`), and
`queryAabb`, `queryAabbCallback`, `querySphere`, `queryFrustum`, `raycast` and `raycastAll` search
it. `leafCount`, `height` and `reinsertCount` tell how it is doing, and `validateStructure()`
checks its invariants in tests.


## Shape casts

`ShapeCast3D` sweeps a shape along a displacement and returns the first hit:

```dart
final hit = ShapeCast3D.sphereCast(
  origin: Vector3(0, 1, 0),
  radius: 0.25,
  delta: Vector3(5, 0, 0),
  collisionSystem: system,
  world: world, // also every MeshComponent / ModelComponent
);
if (hit != null) {
  final stop = Vector3(0, 1, 0) + Vector3(5, 0, 0) * hit.toi;
}
```

`sphereCast`, `capsuleCast` and `convexCast` (any convex or compound shape at a start transform)
test against up to three sources: the colliders of a `CollisionSystem3D`, the `staticGeometry`
objects passed in, and, when `world` is given, every `MeshComponent` and `ModelComponent` of that
world whose bounds the sweep crosses (their triangles at their current pose, so moving meshes count
too). The hit has `toi` (`0..1` along `delta`), `distance`, `point`, `normal` (pointing away from
the obstacle) and the `component` and `collider` hit. A shape that starts inside an obstacle is
reported at `toi == 0` only when it moves deeper into it; sliding along or leaving a surface it
touches is not a hit. `castShapeAgainstShape` sweeps one shape against another without any scene.

The rotation of the shape is not swept: only its translation is. Colliders are tested one by one,
not through the tree, so a cast costs time in proportion to the number of colliders.


## Kinematic character controller

`KinematicCharacterController3D` moves a capsule through a level: it slides along walls, climbs
steps up to `stepOffset`, stops at slopes steeper than `maxSlopeAngleRad`, and snaps to the ground
when walking down. It does not apply gravity: the game gives it a velocity every frame.

```dart
class Player extends MeshComponent {
  Player({required super.mesh, required this.collisions})
    : super(children: [KinematicCharacterController3D()]);

  final CollisionSystem3D collisions;
  final Vector3 velocity = Vector3.zero();
  final Vector3 input = Vector3.zero(); // from the joystick, in m/s

  KinematicCharacterController3D get controller =>
      children.whereType<KinematicCharacterController3D>().first;

  @override
  void update(double dt) {
    super.update(dt);
    velocity
      ..x = input.x
      ..z = input.z;
    velocity.y = controller.isGrounded ? -1.0 : velocity.y - 9.81 * dt;
    controller.moveAndSlide(velocity, dt, collisionSystem: collisions);
    velocity.y = controller.resolvedVelocity.y;
  }
}
```

`moveAndSlide` moves the controller's `target`, or else its parent, and sets `isGrounded`,
`groundNormal` and `resolvedVelocity` (the velocity actually achieved). The defaults are
`radius: 0.4`, `height: 1.8` (tip to tip), `upAxis: Axis3D.y`, `maxSlopeAngleRad: 0.803`
(46 degrees), `stepOffset: 0.35`, `skinWidth: 0.02`, `snapToGroundDistance: 0.2` and
`maxSlideIterations: 4`; `capsuleOffset` moves the capsule relative to the position (for a
position at the feet, use `Vector3(0, 0.9, 0)`).

The controller collides with the colliders of the `collisionSystem` passed in and with mesh
geometry: the `staticGeometry` passed in and, because it finds the `World3D` it lives in, every
`MeshComponent` and `ModelComponent` of that world (its own host and the host's children
excepted). It does not see rigid bodies and does not push them; a moving die is a wall at its
current pose. Initial overlaps are pushed out only against the collision system and
`staticGeometry`. One `moveAndSlide` makes from two to more than a dozen shape casts (slide
iterations, step-up probes, the ground probe), each of which scans all colliders and walks the
world, so measure it in large scenes.


## Bone hitboxes

`SkinnedHitboxRig3D` raycasts against the posed skeleton of a `ModelComponent`, which mesh
raycasts cannot do (they see the rest pose, see [Against a scene](geometry.md#against-a-scene)):

```dart
final rig = SkinnedHitboxRig3D(
  hitboxes: [
    BoneHitbox3D.byName(
      'head',
      shape: SphereShape3D(radius: 0.12),
      damageMultiplier: 2,
    ),
    BoneHitbox3D.byName(
      'spine',
      shape: CapsuleShape3D(radius: 0.18, height: 0.7),
    ),
  ],
);
model.add(rig);
final hit = rig.raycast(ray, maxDistance: 100);
if (hit != null) {
  print('${hit.boneName} x${hit.hitbox.damageMultiplier}');
}
```

Each hitbox follows its bone (by name or node index) with an optional `localOffset` and
`localRotation`. The rig evaluates the pose and updates every hitbox in its `update`, and again in
`raycast` unless `syncPose: false`. `raycastAll` returns every hit sorted by distance. The hitboxes
are not colliders: they take no part in `CollisionSystem3D` overlaps or callbacks.


## Rigid bodies


### Setting up a world

```dart
void addDice(World3D world) {
  final physics = PhysicsWorld3D();

  // A static floor: a body without a mesh, directly in the world.
  final floor = RigidBody3D(
    bodyType: BodyType3D.static,
    shape: BoxShape3D(halfExtents: Vector3(5, 0.5, 5)),
    position: Vector3(0, -0.5, 0),
  );

  // A die: the body is a child of the mesh and moves it.
  final body = RigidBody3D(
    shape: BoxShape3D(halfExtents: Vector3.all(0.25)),
    friction: 0.6,
    restitution: 0.35,
  );
  final die = MeshComponent(
    mesh: CuboidMesh(size: Vector3.all(0.5)),
    position: Vector3(0, 2, 0),
    children: [body],
  );

  world.addAll([physics, floor, die]);
}
```

Every step the `PhysicsWorld3D` collects the `RigidBody3D` components found anywhere under its
parent, plus those registered with `addBody`, sorted by creation order. Without a parent, or with
`autoStep: false`, nothing steps on its own: call `step(dt)`. A world used outside a scene (a
headless simulation, a test, a preview of a dice throw) is built with `autoStep: false` and
`addBody`.


### How bodies drive Object3D transforms

A body moves its **host**: its parent when that parent is a `Component3D` and `syncParent` is
`true` (the default), otherwise the body itself. Physics reads and writes the host's `position`
and `rotation`, and scales the shape by the host's `scale`.

- These are the host's own, parent-relative values, used as if they were world coordinates. All
  bodies of one physics world must therefore share a frame: put their hosts directly into the
  `World3D`, or under parents that are not transformed.
- A body without a mesh placed under a grouping `Component3D` would move the group: create it with
  `syncParent: false`.
- Setting the host's `position` or `rotation` yourself teleports the body. Clear its velocities and
  call `wakeUp()`:

  ```dart
  body.bodyPosition.setValues(0, 3, 0);
  body.bodyRotation.setValues(0, 0, 0, 1);
  body.linearVelocity.setZero();
  body.angularVelocity.setZero();
  body.wakeUp();
  ```

- Effects that move the host of a dynamic body fight the solver. Scripted motion belongs to a
  kinematic body, moved through its `linearVelocity` and `angularVelocity`.


### Bodies

| Parameter              | Default   | Meaning                                                  |
| ---------------------- | --------- | -------------------------------------------------------- |
| `shape`                | required  | collision and inertia shape                              |
| `bodyType`             | `dynamic` | `dynamic`, `kinematic` (moved by its velocity), `static` |
| `mass`                 | `1.0`     | kilograms; the inertia follows from the shape            |
| `friction`             | `0.5`     | ignored when `material` is set                           |
| `restitution`          | `0.0`     | bounciness, ignored when `material` is set               |
| `material`             | `null`    | a `PhysicsMaterial3D`                                    |
| `linearDamping`        | `0.01`    | per second, implicit: `v /= 1 + dt * linearDamping`      |
| `angularDamping`       | `0.05`    | per second, the same for the angular velocity            |
| `linearVelocity`       | zero      | initial velocity, world space                            |
| `angularVelocity`      | zero      | initial angular velocity, world space                    |
| `canSleep`             | `true`    | see [Sleeping](#sleeping)                                |
| `ccdEnabled`           | `false`   | continuous collision detection                           |
| `ccdSweptSphereRadius` | inscribed | radius of the swept sphere                               |
| `collisionLayer`       | `1`       | contact filtering, both ways, as for colliders           |
| `collisionMask`        | all bits  | contact filtering, both ways, as for colliders           |
| `syncParent`           | `true`    | whether the body drives its parent                       |

Kinematic and static bodies have infinite mass. Static and kinematic bodies never touch each other,
and two bodies with the same host never touch. `applyImpulse` (`N*s`) and `applyForce` (`N`, for
the next step only) take an optional `worldPoint` that adds the matching torque; `applyTorque` and
`applyTorqueImpulse` turn the body. All four wake a sleeping body.

```dart
final body = RigidBody3D(
  shape: SphereShape3D(radius: 0.2),
  mass: 2,
  material: const PhysicsMaterial3D(
    friction: 0.05,
    restitution: 0.1,
    frictionCombine: PhysicsCombineMode3D.minimum, // ice stays slippery
  ),
);
body.applyImpulse(Vector3(0, 5, 0)); // at the center of mass
body.applyImpulse(Vector3(1, 0, 0), worldPoint: Vector3(0, 0.2, 0));
body.applyForce(Vector3(0, 0, -3));
body.applyTorqueImpulse(Vector3(0, 0.5, 0));
```

Without materials, a contact uses the larger restitution of the two bodies and the geometric mean
of their frictions, `sqrt(fA * fB)`. When either body has a `PhysicsMaterial3D` (defaults:
`friction: 0.5`, `restitution: 0.2`, friction averaged, restitution by maximum), the other body's
`friction` and `restitution` are wrapped in a default material and the two are combined with the
combine mode of higher priority: `average` < `minimum` < `multiply` < `maximum`. Restitution is
clamped to `[0, 1]`. Contacts closing slower than `restitutionVelocityThreshold` (default
`0.5 m/s`) do not bounce. `surfaceTag` is free for the game (footstep sounds, for example); the
engine does not read it.


### The step

`PhysicsWorld3D` advances in fixed steps of `fixedTimeStep` (default `1/60` s). Its `update` adds
the frame time to an accumulator and runs up to `maxSubSteps` (default `4`) steps; time beyond
that is dropped, so a slow device sees slow motion rather than a spiral of ever longer frames. The
result depends only on the number of steps, not on the frame rate. Each `step(dt)`:

1. applies registered buoyancy volumes;
2. adds gravity and the accumulated forces to the velocities of awake dynamic bodies, then damping;
3. applies registered vehicles;
4. updates the broadphase tree and builds a contact constraint for every touching pair with at
   least one awake dynamic body;
5. prepares joints and warm-starts resting contacts with 85 % of last step's impulses;
6. runs `velocityIterations` (default `8`) sequential-impulse passes over joints and contacts:
   normal impulses, then two-direction Coulomb friction within `friction * normal impulse`;
7. moves the bodies (with continuous collision detection where enabled);
8. runs `positionIterations` (default `3`) passes that push penetrating contacts and drifting
   joints apart directly, without adding velocity;
9. updates the sleep timers.

All of these settings (`gravity`, `fixedTimeStep`, `maxSubSteps`, `velocityIterations`,
`positionIterations`, the sleep thresholds, `restitutionVelocityThreshold`, `autoStep`) can be
changed between steps. `tick` counts the steps.


### Sleeping

A dynamic body whose speed stays below `sleepLinearThreshold` (`0.08 m/s`) and whose angular speed
stays below `sleepAngularThreshold` (`0.12 rad/s`) for `sleepTimeThreshold` (`0.5 s`) falls
asleep: its velocities are zeroed and it costs almost nothing until woken. Each body sleeps on its
own; there are no islands. A body wakes when a force or impulse is applied, when a joint partner is
awake, or when an awake dynamic body hits it faster than twice `sleepLinearThreshold` or more than
1 cm deep. `canSleep: false` keeps a body awake, `putToSleep()` and `wakeUp()` force the state.

Kinematic bodies do not wake sleeping bodies: a moving platform passes through a sleeping crate.
Wake the bodies in its path yourself, or give them `canSleep: false`.


### Rigid bodies and colliders

The solver only builds contacts between `RigidBody3D` bodies. Level geometry that dynamic bodies
must stand on is a static `RigidBody3D` (a box, a compound, or a `HeightfieldShape3D`), even when
the same geometry also has a `Collider3D` for queries and the character controller. A
`PhysicsWorld3D` given a `collisionSystem` (or finding one among its siblings) uses its colliders
only for continuous collision detection and vehicle wheel rays; a body falling at normal speed
passes through a collider floor.


### Contact quality

Measured with the default settings, on boxes of `0.5 m`, friction `0.6`:

- A box resting on a box sinks about 1.4 mm and falls asleep after 0.5 to 1 s.
- Columns of up to four boxes stand and sleep. A column of five collapses after about a second
  with the default iterations; `velocityIterations: 20` and `positionIterations: 10` keep five
  standing, but columns of eight (20 iterations) and ten (30 iterations) still collapse. A four-row
  pyramid with small gaps stands. Do not build tall stacks.
- Bodies that touch through GJK and EPA (a hull against anything) get one contact point per step,
  which moves between the hull's corners. A hull dropped flat comes to rest, but a tumbling hull
  keeps rocking on the floor (measured on 0.5 m hulls: 0.07 to 0.15 m/s and 0.25 to 0.6 rad/s,
  above the default sleep thresholds) and never sleeps; it also rests 5 to 15 mm deep in a box
  floor. Raise `sleepLinearThreshold` and `sleepAngularThreshold` when hull bodies must settle:
  with `0.2` and `0.8`, thrown hull cubes and octahedra all slept, after 3.5 to 4 s.
- There is no gyroscopic term: a free body keeps its angular velocity rather than its angular
  momentum, so an asymmetric body spinning about its intermediate axis does not flip over.


### Smooth motion on fast displays

With `fixedTimeStep: 1/60` on a 120 Hz display, physics moves the bodies on every other frame. Step
the world yourself and interpolate the hosts with `FixedTransformInterpolation3D`:

```dart
class Die extends MeshComponent with FixedTransformInterpolation3D {
  Die({required super.mesh, super.children});
}

class SmoothPhysics extends Component3D {
  SmoothPhysics(this.physics, this.dice);

  final PhysicsWorld3D physics; // created with autoStep: false
  final List<Die> dice;
  double _accumulator = 0;

  @override
  void update(double dt) {
    super.update(dt);
    for (final d in dice) {
      d.restoreSimulatedState();
    }
    _accumulator += math.min(dt, 0.1);
    while (_accumulator >= physics.fixedTimeStep) {
      for (final d in dice) {
        d.captureFixedState();
      }
      physics.step(physics.fixedTimeStep);
      for (final d in dice) {
        d.commitFixedState();
      }
      _accumulator -= physics.fixedTimeStep;
    }
    final alpha = _accumulator / physics.fixedTimeStep;
    for (final d in dice) {
      d.applyInterpolationAlpha(alpha);
    }
  }
}
```

The interpolated pose must be restored before the next step, as above, or physics would continue
from it. A smaller `fixedTimeStep` (`1/120`) is the other option, at twice the CPU cost.


## Continuous collision detection

A small body moving fast can pass through a thin obstacle between two steps. Measured: a sphere of
radius 2 cm against a 1 cm wall goes through in 12 of 20 trials at `5 m/s` and in all trials at
`200 m/s`. With `ccdEnabled: true` it went through in none, from `5` to `200 m/s`, against static
walls and against a dynamic plate.

```dart
final bullet = RigidBody3D(
  shape: SphereShape3D(radius: 0.02),
  mass: 0.01,
  ccdEnabled: true,
  linearVelocity: Vector3(0, 0, -120),
);
```

What it does: when a CCD body would move more than half its `ccdSweptSphereRadius` in a step, a
sphere of that radius centered on its center of mass is swept along the step's displacement
against the other rigid bodies near the path and against the colliders of the collision system.
The body is moved to just before the first hit, the impact is resolved with the contact's
restitution and friction, and the rest of the step is swept again, up to three times.

- Only the inscribed sphere is protected. Rotation is not swept, so the corners of a long, fast
  spinning body can still cut into things; the discrete contacts of the next step push them out.
- The default radius is the shape's `inscribedSphereRadius`. For hulls that is the smallest
  half-extent of the bounding box, often larger than the hull: a face-down octahedron die with
  CCD stopped its fall with its center 0.30 m above the floor instead of 0.17 m, bouncing off an
  invisible sphere. Give hull bodies their true inradius:

  ```dart
  final d8 = RigidBody3D(
    shape: ConvexHullShape3D(vertices: octahedronVertices), // r = 0.3
    ccdEnabled: true,
    ccdSweptSphereRadius: 0.3 / math.sqrt(3), // inradius
  );
  ```

- Against colliders it only stops fast bodies, see
  [Rigid bodies and colliders](#rigid-bodies-and-colliders).
- Cost: for each CCD body above the speed threshold, up to three sweeps per step, each testing the
  rigid bodies near the path with a GJK sweep and every collider of the collision system one by
  one. Enable it on the few bodies that need it (projectiles, thrown dice that are boxes), not on
  everything.


## Joints

A joint connects two bodies (one may be static) and is registered with `addJoint`:

```dart
final hinge = HingeJoint3D(
  bodyA: frame, // a static body at the top of the door
  bodyB: door,
  localAnchorA: Vector3.zero(),
  localAnchorB: Vector3(-0.5, 1, 0),
  localAxisA: Vector3(0, 1, 0),
  minAngle: -math.pi / 2,
  maxAngle: math.pi / 2,
);
physics.addJoint(hinge);
print(hinge.jointAngle);
```

- `DistanceJoint3D` keeps two anchors at `length` (default: their distance at creation). With
  `frequencyHz` above `0` (default `0`, a rigid rod) it is a spring with `dampingRatio` (`0.7`).
- `BallSocketJoint3D` makes two anchors coincide.
- `HingeJoint3D` makes two anchors coincide and aligns `localAxisA` (default `+Z`) with
  `localAxisB` (default: A's axis as B sees it at creation); `minAngle` and `maxAngle` (default
  `null`, free) limit `jointAngle`, which is `0` at creation.
- `FixedJoint3D` locks the relative pose (by default the one at creation, about the midpoint of
  the two bodies).
- `SliderJoint3D` allows translation along `localAxisA` or `worldAxis` (default `+X` of A) only,
  between `minDistance` and `maxDistance`, with an optional motor (`motorSpeed`, `maxMotorForce`,
  both `0` by default). It reads `currentDistance` and `currentSpeed`.
- `ConeTwistJoint3D` makes two anchors coincide and keeps B's axis inside a cone around
  `localAxisA` (default `+X`) of half-angle `swingLimitRad` (`pi / 4`), with a twist between
  `minTwistRad` and `maxTwistRad` (`-pi / 6` and `pi / 6`). It reads `swingAngle` and
  `twistAngle`.
- `Generic6DofJoint3D` handles each of its three linear and three angular axes separately, with
  `linearLowerLimit`, `linearUpperLimit`, `angularLowerLimit`, `angularUpperLimit`, spring
  stiffnesses, dampings and equilibrium positions. It reads `currentLinearOffset` and
  `currentAngularOffset`.

For all joints:

- Anchors are in each body's local space. `collideConnected` (default `false`) decides whether the
  two bodies also collide.
- In `Generic6DofJoint3D`, an axis whose lower and upper limits are equal (the default, zero) is
  locked, one whose lower limit is above its upper limit is free, and anything else is limited.
  Springs act on the axes with a stiffness above zero; angular offsets are intrinsic XYZ angles in
  the frame of body A.
- Only the slider has a motor.
- Joints keep no impulses from one step to the next, and are corrected both by a velocity bias and
  by the position passes. Long chains need more iterations (the tests use `12` velocity and `5` or
  `6` position iterations).
- Two dynamic bodies joined by a joint wake up together.
- `DistanceJoint3D`, `BallSocketJoint3D` and `HingeJoint3D` measure their lever arms from the body
  origin instead of its center of mass, which only differs for compound bodies with an off-center
  center of mass; the other joints use the center of mass.

The ragdoll controller of the animation system builds on these joints, see
[Models and Animation](models_and_animation.md).


## Buoyancy

`BuoyancyVolume3D` pushes submerged dynamic bodies up, drags them and tilts them with the waves.
It is applied only when registered with `addBuoyancyVolume`; adding it to the scene does nothing
by itself.

```dart
final sea = BuoyancyVolume3D(
  fluidDensity: 1000, // kg/m^3 when masses are in kg
  waterSurfaceHeight: (x, z, t) => 0.2 * math.sin(x * 0.5 + t),
);
sea.setBodyPontoons(boat, [
  BuoyancyPontoon3D(localPosition: Vector3(-0.8, -0.2, 1.4), radius: 0.3),
  BuoyancyPontoon3D(localPosition: Vector3(0.8, -0.2, 1.4), radius: 0.3),
  BuoyancyPontoon3D(localPosition: Vector3(-0.8, -0.2, -1.4), radius: 0.3),
  BuoyancyPontoon3D(localPosition: Vector3(0.8, -0.2, -1.4), radius: 0.3),
]);
physics.addBuoyancyVolume(sea);
```

Each body is sampled at pontoons: the ones given with `setBodyPontoons`, else `defaultPontoons`,
else four generated from the shape's bounding box. A pontoon that dips below the surface lifts the
body by `fluidDensity * g * (its share of the shape's volume) * (submerged fraction)`, at the
pontoon, so a tilted boat rights itself. The force leans a quarter of the way toward the wave
normal, is capped at `mass * max(40, 6 g)` per body, and comes with drag (`linearDrag`, default
`2.2`, relative to `flowVelocity`), angular drag (`angularDrag`, `1.8`) and a torque that turns the
body's local +Y toward the wave normal (`waveTorqueStrength`, `1.5`).

- `fluidDensity` (default `2.5`) is a density in the units of the body masses: a body floats when
  `mass / volume` is below it. With real masses in kilograms, water is `1000`.
- The volume is `shape.estimateLocalVolume()`, which for hulls is half the bounding box.
- The water surface is horizontal in Y: `waterSurfaceHeight(x, z, time)` returns the height Y at
  world `(x, z)`, or `baseWaterLevel` (`0`) without a function. `bounds` (an `Aabb3`, `null` for an
  endless sea) limits the volume. The volume's own transform is not used.
- Floating bodies receive forces every step and do not fall asleep.


## Vehicles

`RaycastVehicle3D` turns a dynamic body into a car whose wheels are suspension rays:

```dart
final chassis = RigidBody3D(
  shape: BoxShape3D(halfExtents: Vector3(0.9, 0.3, 1.6)),
  mass: 120,
  position: Vector3(0, 1, 0),
  canSleep: false,
);
final car = RaycastVehicle3D.fourWheel(
  chassis: chassis,
  connectionHeight: -0.1,
  restLength: 0.45,
);
physics
  ..addBody(chassis)
  ..addVehicle(car);

car
  ..throttle = 1.0 // -1..1
  ..steering = -0.3 // -1..1, scaled by maxSteerAngleRad
  ..brake = 0.0; // 0..1
```

Every step each wheel casts a ray down its suspension direction (chassis-local `(0, -1, 0)` by
default) over `restLength + wheelRadius`, against the other rigid bodies and the colliders of the
collision system. A grounded wheel pushes the chassis with a spring-damper force, then drive,
braking and sideways grip are applied as impulses at the contact, limited by
`frictionSlip * suspension load`.

- `fourWheel` places the wheels at `+-halfTrackWidth` (`0.85`) along X and `+-halfWheelbase`
  (`1.25`) along Z, front wheels steering, all wheels driven unless `allWheelDrive: false`; it
  assumes the car faces along local `+Z` or `-Z` (`forwardAxisLocal`).
- With `massNormalizedSuspension: true` (the default), `springStiffness` (`35`), the dampers,
  `engineForce` (`14` in `fourWheel`) and `maxBrakeForce` are per kilogram of chassis, so the same
  numbers suit a light and a heavy car: `engineForce` is then the acceleration in `m/s^2`.
- `rollInfluence` (`0.25`) lowers the point where the tire forces act, to keep a high car from
  rolling over.
- `wheelStates` give each wheel's `isGrounded`, `suspensionLength`, `compression`, `contactPoint`,
  `contactNormal`, `wheelWorldPosition`, `steerAngleRad`, `rotationRad` (for spinning wheel meshes)
  and `skidInfo` (`1` = full grip). `groundedWheelCount` and `forwardSpeed` summarize them.
- `WheelSpec3D.axleDirectionLocal` is stored but not used.


## Cloth and rope

`XpbdCloth3D` and `XpbdRope3D` are `Object3D` components that simulate particles with extended
position-based dynamics and draw themselves as one surface each. They are not stepped by the
`PhysicsWorld3D`: each steps in its own `update`, with the frame time capped at `1/30` s, unless
created with `autoStep: false`, in which case `step(dt)` is yours to call (do that, with a fixed
`dt`, when the result must be reproducible).

```dart
final flag = XpbdCloth3D(
  columns: 12,
  rows: 8,
  width: 1.5,
  height: 1.0,
  pinTopEdge: true,
  pinTopCorners: false,
  windVelocity: Vector3(4, 0, 1),
  position: Vector3(0, 4, 0),
);
final rope = XpbdRope3D(
  startPoint: Vector3(0, 5, 0),
  endPoint: Vector3(0, 3.5, 0),
  segmentCount: 12,
  attachedBody: lantern, // pulled by the rope, and pulls it back
);
world.addAll([flag, rope]);
```

The cloth is a `columns x rows` grid (defaults `16 x 16`, `2 x 2` m) hanging down from row 0 in
its local XY plane, or lying in XZ with `startHorizontal: true`. Structural, shear and bending
distance constraints have compliances `0`, `0.0001` and `0.01` (higher is softer); `substeps`
(`4`) and `solverIterations` (`4`) set the stiffness and the cost. Vertices are pinned with
`pinTopCorners` (default), `pinTopEdge`, `pinnedVertices` or `setVertexPinned`. Wind pushes each
triangle along its normal (`windVelocity`, `windDragCoefficient`). It is pushed out of the
`sphereColliders` and `capsuleColliders` given to it and of the sphere and capsule `Collider3D`s
in `worldColliders` (other collider shapes are ignored), with `particleThickness` (`0.03`) of
clearance. It does not collide with itself and does not push rigid bodies.

The rope is a chain of `segmentCount` segments (`16`) from `startPoint` to `endPoint` (local
coordinates), pinned at the start by default, drawn as a tube of `radius` (`0.04`). With an
`attachedBody`, its end (or start, `attachAtEnd: false`) is tied to `bodyLocalAnchor` on that body:
a static or kinematic body drags the rope, a dynamic one is pulled by it as well. It is pushed out
of its own sphere and capsule colliders only.

Both read their particles with `getVertexPosition` / `getParticlePosition` and move them with
`setVertexPosition` / `setParticlePosition`. Their cost is proportional to particles times
constraints times `substeps * solverIterations`, plus a vertex upload of the surface every step.


## Snapshots and determinism

`saveSnapshot()` encodes the state of a physics world into bytes (`'P3DS'`, format version `1`,
CRC32 at the end) and `restoreSnapshot(bytes)` puts it back, throwing a `FormatException` when the
header, version or checksum is wrong. A ring buffer keeps the last snapshots for rollback:

```dart
final history = PhysicsSnapshotRingBuffer3D(capacity: 240);
// After every step:
history.capture(physics);
// On a late input for tick 1200:
if (history.rollbackToTick(physics, 1200)) {
  // apply the input, then step forward again to the present tick
}
final old = history.snapshotForTick(1190); // Uint8List?
```

A snapshot holds the tick, the accumulator, gravity, each body's type, sleep and CCD flags, pose,
velocities, sleep timer and pending forces, the warm-start impulses of the contacts, the elapsed
time of buoyancy volumes and the inputs and wheel states of vehicles, and optionally the state of
a `SeededRng3D` (`PhysicsSnapshot3D.encodeWorld(world, rng: rng)`). It is 69 bytes plus 168 per
body and 28 per warm-started contact point. It does not hold shapes, masses or materials, cloth or
rope, collision-system pairs, or the joints (which carry no state from one step to the next).
Bodies are matched by their creation id, else by position in the creation order; restore into a
world with the same bodies.

What is reproducible, as measured and tested:

- The same world, stepped the same way from the same state, gives bit-identical results; so does
  restoring a snapshot into the world it came from and stepping again (both are covered by tests).
- A fresh world built with the same bodies in the same order and thrown with the same seed
  reproduces a throw bit for bit (measured on the Dart VM).
- Restoring a snapshot into a **different** world instance, even one built identically, does not
  reproduce: the warm-start impulses are keyed by the bodies' process-wide creation ids, which
  differ, and the trajectories diverge (by meters after two seconds in the measurement).
  Rollback works within one world.
- Across platforms nothing is guaranteed and nothing was tested. The arithmetic is IEEE double
  precision with values stored as 32-bit floats everywhere, but body rotation calls `sin` and
  `cos`, which come from the platform's math library on native targets and from the JavaScript
  engine on the web, and may differ in the last bit. Only `SeededRng3D` (integer arithmetic) is
  portable. A networked game should send results or poses from one authority rather than expect
  every client to compute the same throw from a seed, unless all clients run the same build on
  the same platform.


## Throwing dice

A six-sided die is a `BoxShape3D`: its contacts are exact, it settles flat and falls asleep.
Measured over 3,000 seeded throws of a 0.5 m die on a box floor (friction `0.6`, restitution
`0.35`, defaults otherwise): every die slept within 350 steps (5.8 s, 3.3 s on average), one ended
tilted by more than 8 degrees, and the faces came up uniformly (chi-square `5.85`, five degrees of
freedom).

Other dice are `ConvexHullShape3D`s. A 20-sided die thrown 1,500 times came up uniformly too
(chi-square `21.0`, 19 degrees of freedom), but with the default thresholds none fell asleep: hull
dice keep rocking, see [Contact quality](#contact-quality). With `sleepLinearThreshold: 0.15` and
`sleepAngularThreshold: 0.6` they all slept, after 4.9 s on average; hull cubes need `0.2` and
`0.8`. Leave CCD off on hull dice, or set their `ccdSweptSphereRadius` to the inradius.

`throwDice3D` places, orients and launches a list of bodies from a seed:

```dart
physics.throwDice3D(
  dice,
  seed: seed,
  origin: Vector3(0, 3, 2.5),
  throwVelocity: Vector3(0, -1.5, -4.5),
);
```

The bodies are lined up along X, `spacing` (`0.85`) apart around `origin` (default
`(0, 3, 2.5)`), each moved by up to `0.05` in every direction, given a uniformly random
orientation, the velocity `throwVelocity` (default `(0, -1.5, -4.5)`) plus up to
`velocityJitter` (`0.6`; half of it vertically), and a spin of `minSpinSpeed` to `maxSpinSpeed`
(`10` to `22 rad/s`) about a random axis. The throw does not step the world. For a die thrown by
hand from where it is, `RigidBody3D.applySeededSpinImpulse(seed: ...)` sets only a velocity and a
spin.

Read the result once the dice sleep, by finding the face whose normal points up:

```dart
const _d6Faces = <(int, double, double, double)>[
  (1, 0, 1, 0), // the face whose outward normal is local +Y shows a 1
  (6, 0, -1, 0),
  (2, 1, 0, 0),
  (5, -1, 0, 0),
  (3, 0, 0, 1),
  (4, 0, 0, -1),
];

/// The value on top of a d6 in a Y-up world.
int topFace(RigidBody3D die) {
  final r = die.bodyRotation.asRotationMatrix();
  var best = 0;
  var bestUp = -2.0;
  for (final (value, x, y, z) in _d6Faces) {
    final up = r.transform(Vector3(x, y, z)).y;
    if (up > bestUp) {
      bestUp = up;
      best = value;
    }
  }
  return best;
}

bool allSettled(List<RigidBody3D> dice) => dice.every((d) => d.isSleeping);
```

```{note}
`Quaternion.rotate` and `Quaternion.rotated` of `vector_math` rotate by the
*inverse* of the quaternion. Rotate face normals with `asRotationMatrix()` (as
above) or with a `Matrix4` built from the rotation: these agree with the
physics.
```

For other dice, list the outward normals of their faces with their values. Give the settle check a
timeout as well (a die can come to rest leaning on a wall).

Since a throw is deterministic, its result can be known before it is shown: play it headless
first.

```dart
List<int> preview(int seed) {
  final physics = PhysicsWorld3D(autoStep: false);
  physics.addBody(
    RigidBody3D(
      bodyType: BodyType3D.static,
      shape: BoxShape3D(halfExtents: Vector3(5, 0.5, 5)),
      position: Vector3(0, -0.5, 0),
    ),
  );
  final dice = [
    for (var i = 0; i < 2; i++)
      RigidBody3D(shape: BoxShape3D(halfExtents: Vector3.all(0.25))),
  ];
  dice.forEach(physics.addBody);
  physics.throwDice3D(dice, seed: seed);
  for (var i = 0; i < 900 && !allSettled(dice); i++) {
    physics.step(physics.fixedTimeStep);
  }
  return [for (final d in dice) topFace(d)];
}
```

The visible throw then gives the same result when its world is built the same way (same bodies,
created in the same order, same settings) and stepped with the same fixed step. When a result is
decided elsewhere (by a server, for example), the shape of a cube is the same under each of its 24
rotations, so the die's mesh can be drawn with a fixed extra rotation, as a child of the body's
host, that puts the decided value on the face that will end on top; the simulation is unchanged.


## Debugging

There is no built-in drawing of physics shapes. A `DebugRenderer3D` in the world can draw them
from the bodies; its custom segments stay until cleared, so clear and redraw them every frame:

```dart
class PhysicsDebugDraw extends Component3D {
  PhysicsDebugDraw(this.physics, this.renderer);

  final PhysicsWorld3D physics;
  final DebugRenderer3D renderer;

  @override
  void update(double dt) {
    super.update(dt);
    renderer.clearCustomSegments();
    for (final body in physics.collectBodies()) {
      final shape = body.shape;
      if (shape is BoxShape3D) {
        renderer.drawObb(shape.halfExtents, body.bodyWorldMatrix);
      } else {
        renderer.drawAabb(body.bodyWorldAabb);
      }
    }
  }
}
```

`drawSphere` and `drawCapsule` suit the other shapes. `isSleeping` and `sleepTimer` show why a body
does or does not settle; `broadphaseTree.leafCount`, `height` and `reinsertCount` show the tree;
the vehicle's `wheelStates` show its rays. For reproducibility problems, compare `saveSnapshot()`
bytes step by step between two runs: the first differing step points at the cause.


## Performance

Measured on a desktop computer under `flutter test` (JIT compilation), for 0.5 m box dice thrown
into a walled box, average and worst step over four seconds:

| Dice | Average step | Worst step | Asleep after 4 s |
| ---- | ------------ | ---------- | ---------------- |
| 1    | 8 us         | 21 us      | 0 of 1           |
| 5    | 25 us        | 139 us     | 5 of 5           |
| 20   | 85 us        | 459 us     | 19 of 20         |
| 50   | 125 us       | 729 us     | 27 of 50         |
| 100  | 147 us       | 392 us     | 26 of 100        |

These numbers show how the cost grows, not what a phone does: measure on the target device in a
release build.

Where the time goes, per step:

- The `PhysicsWorld3D` walks its parent's whole component subtree to find the bodies, then
  recomputes the bounds of every body (static and sleeping ones included) and updates the tree.
  A `CollisionSystem3D` does the same for colliders, and again for every query. Give each system a
  small parent: put the physics bodies and the `PhysicsWorld3D` under one untransformed
  `Component3D` instead of the root of a large world (bodies without a mesh in that group need
  `syncParent: false`).
- A contact pair costs one narrowphase test and its constraint, solved `velocityIterations` plus
  `positionIterations` times. Pairs of sleeping bodies (or a sleeping body and a static one) cost
  nothing; let dice fall asleep.
- The narrowphase and the number of contact points set the cost of a pair. Twenty awake bodies
  resting on a box floor (no other contacts) cost per step, in the same setting as the table
  above: spheres `25 us`, capsules `27 us`, 12-point hulls `60 us`, 8-point hulls `70 us`, boxes
  `85 us` (four contact points each) and two-box compounds `92 us`.
- Continuous collision detection, vehicles (every wheel ray tests every body's bounds) and the
  character controller add their own scans, see their sections.

The step allocates: each touching pair creates its manifold, its constraint, per-point state and
temporary vectors every step (about 100 to 150 short-lived objects for a resting box on a box,
several hundred for a pair solved with GJK and EPA, more for compounds), plus closures and a new
warm-start map. Sleeping pairs allocate nothing. The garbage is short-lived, but on a phone keep
the number of awake touching pairs to a few dozen and check for collection pauses with the
profiler.


## Limitations

- Rigid bodies collide only with rigid bodies: not with `Collider3D`s, meshes or models. Colliders
  report overlaps and never push anything apart.
- Contacts that go through GJK and EPA (hulls, and hulls against boxes) have one point: hull bodies
  rock, do not fall asleep with the default thresholds, and rest 5 to 15 mm deep.
- `ConvexHullShape3D` takes its center of mass (the local origin), volume, inertia and inscribed
  radius from its bounding box.
- Columns of more than four boxes collapse with the default iterations; columns of eight and ten
  boxes collapsed even with 20 to 30 velocity iterations.
- Kinematic bodies pass through sleeping bodies without waking them. Sleeping is per body, without
  islands.
- No gyroscopic term in the integration of rotations.
- Continuous collision detection sweeps a sphere and ignores rotation; its default radius is too
  large for most hulls; against colliders it only stops fast bodies.
- Snapshots restore into the world they came from; nothing is guaranteed across platforms.
- Every step allocates per contact and walks the subtree of the physics world; every collision
  query walks the subtree of the collision system.
- `DistanceJoint3D`, `BallSocketJoint3D` and `HingeJoint3D` take lever arms from the body origin
  rather than the center of mass. The center of mass of a nested `CompoundShape3D` whose child is
  rotated is mirrored (it uses the inverse rotation).
- Buoyancy is horizontal in Y and must be registered with `addBuoyancyVolume`. Vehicles ignore
  `axleDirectionLocal` and compute the minimum tire load with a gravity of `9.81` whatever the
  world's gravity.
- Cloth does not collide with itself, only with sphere and capsule colliders, and does not affect
  rigid bodies. The tube of a rope that bends out of a plane is drawn with tilted rings (its
  frame is rotated the wrong way).
- Solver tolerances are absolute, tuned for objects of 0.1 m and more.
