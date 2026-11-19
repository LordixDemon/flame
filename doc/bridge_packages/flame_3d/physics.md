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

The two systems meet in a few places. The static, non-trigger colliders of a `CollisionSystem3D`
are solid for rigid bodies: they hold them up and stop them, continuous collision detection
included (see [Rigid bodies and colliders](#rigid-bodies-and-colliders)). Vehicle wheel rays hit
colliders, and cloth can be pushed out of sphere and capsule colliders. Other colliders (triggers
and colliders that are not static) only report overlaps.

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
- The solver tolerances are absolute. Penetration up to `linearSlop` (a `PhysicsWorld3D`
  parameter, default `0.004`) is left alone, so a resting body sinks up to 4 mm into what it rests
  on (1.4 mm on average for thrown 0.5 m dice), and the sleep thresholds are in `m/s` and `rad/s`.
  The defaults suit objects from about 0.1 m to a few meters. For small objects, lower
  `linearSlop` and the sleep thresholds in proportion, or model them at a larger scale (the dice in
  the tests are 0.5 m).


## Collision shapes

| Shape                | Contacts generated                           | Mass properties      |
| -------------------- | -------------------------------------------- | -------------------- |
| `SphereShape3D`      | exact, 1 point                               | exact                |
| `CapsuleShape3D`     | exact, 1 point                               | exact                |
| `BoxShape3D`         | face on a box or hull face: up to 4 points   | exact                |
| `ConvexHullShape3D`  | face on a face: up to 4 points, else 1 point | exact, from the hull |
| `CompoundShape3D`    | per child, merged                            | from the children    |
| `HeightfieldShape3D` | per grid cell, merged                        | none, for static use |

- `SphereShape3D(radius: r)`.
- `CapsuleShape3D(radius: r, height: h, axis: Axis3D.y)`: `height` is the total length from tip
  to tip, at least `2 * radius`.
- `BoxShape3D(halfExtents: v)`.
- `ConvexHullShape3D(vertices: points)`.
- `CompoundShape3D([CompoundChildShape3D(shape: s, position: p, rotation: q, massWeight: 1)])`.
- `HeightfieldShape3D(heights: h, columns: c, rows: r, width: w, depth: d, heightScale: 1)`.

Sphere, capsule and box pairs are solved analytically. A box against a box uses the 15 axes of the
separating axis test; the faces of the first box are preferred to those of the second and face axes
to edge axes unless clearly worse, so two nearly parallel boxes keep the same reference face from
step to step. Pairs that involve a hull find their normal and depth with GJK and EPA. When both
shapes have faces (boxes and hulls) and the normal is within about 5.7 degrees of a face of either
one, the incident face (the other shape's face most opposed to the normal) is clipped against the
side planes of that reference face, as for two boxes. Such a manifold has up to four points: a box
or hull lying on a face rests on its corners and comes to sleep. An edge across an edge, and a hull
against a sphere or a capsule, give one point. Face points up to 2 mm apart are kept, with a depth
of `0`, so a face settling onto another does not flicker in and out of contact.

Each `ContactPoint3D` has a `featureId` that names the faces, edges and vertices that produced it.
It stays the same from one step to the next while the same features touch, and the solver uses it
to carry each point's impulse over (single-point manifolds use `0`).

`ConvexHullShape3D` takes any point cloud and builds the hull when it is created (a quickhull,
roughly quadratic in the number of points, so keep hulls to a few hundred points). Coplanar
triangles are merged into polygon faces, which `faceCount`, `faceNormal(i)` and
`faceVertexIndices(i)` read (indices into `vertices`, counter-clockwise around the outward normal);
points inside the hull are ignored. Its mass properties are those of the solid hull of uniform
density:

- `estimateLocalVolume()` is its exact volume;
- `localCenterOfMass` is its centroid, around which a rigid body integrates, so the vertices need
  not be centered;
- `computeLocalInertiaTensor` is its full inertia tensor about that center, products of inertia
  included (`computeLocalInertiaDiagonal` is its diagonal);
- `inscribedSphereRadius` is the distance from the center of mass to the nearest face plane, the
  default sphere of [continuous collision detection](#continuous-collision-detection).

Fewer than four points, or points that all lie on one line or one plane, make a degenerate hull:
it has no faces, still collides (with one contact point per step) and takes its mass properties
from its bounding box.

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

The `PhysicsWorld3D` simulates the bodies registered with `addBody` and every `RigidBody3D` mounted
anywhere under its parent, in creation order. Mounted bodies register themselves when they mount
and leave when they are removed, so the world does not search its parent's subtree on every step
(a world whose parent is not mounted, in a component tree built without a game, does). Without a
parent, or with `autoStep: false`, nothing steps on its own: call `step(dt)`. A world used outside
a scene (a headless simulation, a test, a preview of a dice throw) is built with `autoStep: false`
and `addBody`.


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
4. updates the broadphase tree (for the bodies that moved) and builds a contact constraint for
   every touching pair with an awake dynamic body or a moving kinematic body, and for every awake
   dynamic body touching a solid collider;
5. prepares joints and warm-starts resting contacts: each contact point starts from last step's
   impulse of the point with the same `featureId`, else of the nearest point within
   `2 * linearSlop`;
6. runs `velocityIterations` (default `8`) sequential-impulse passes over joints and contacts: for
   each contact, two-direction Coulomb friction within `friction * normal impulse`, then the
   normal impulses (a point that is still apart may close its gap during the step, no more);
7. moves the bodies (with continuous collision detection where enabled);
8. runs `positionIterations` (default `3`) passes that push contacts deeper than `linearSlop` and
   drifting joints apart directly, without adding velocity;
9. updates the sleep timers and puts islands to sleep, see [Sleeping](#sleeping).

All of these settings (`gravity`, `fixedTimeStep`, `maxSubSteps`, `velocityIterations`,
`positionIterations`, the sleep thresholds, `restitutionVelocityThreshold`, `linearSlop`,
`autoStep`) can be changed between steps. `tick` counts the steps.


### Sleeping

A dynamic body counts its time below `sleepLinearThreshold` (`0.08 m/s`) and
`sleepAngularThreshold` (`0.12 rad/s`). Bodies that touch through contacts or joints form an
island, which falls asleep when every body in it has been that slow for `sleepTimeThreshold`
(`0.5 s`): their velocities are zeroed and they cost almost nothing until woken. A body with
`canSleep: false` keeps its island awake; `putToSleep()` and `wakeUp()` force the state.

A sleeping body is immovable for the bodies still awake around it. It wakes when a force or
impulse is applied, when a joint partner is awake, when a moving kinematic body touches it, and
when an awake dynamic body touches it while moving (its timer was reset by the last step), faster
than twice `sleepLinearThreshold`, or more than 1 cm deep. Pushing the bottom box of a sleeping
pile therefore wakes the pile, and a moving platform carries or pushes the crates it meets.


### Rigid bodies and colliders

A `PhysicsWorld3D` given a `collisionSystem` (or finding one among its siblings) treats that
system's static, non-trigger colliders (`Collider3D(isStatic: true)`) as solid: an awake dynamic
body gets contacts against them as against a static body, with the collider's `material` (friction
`0.5` and restitution `0` without one), and continuous collision detection stops at them. Layers
and masks apply both ways, and a body never touches a collider of its own host (such as the
collider a die carries to enter triggers).

```dart
final level = CollisionSystem3D();
final floor = Collider3D(
  shape: BoxShape3D(halfExtents: Vector3(10, 0.5, 10)),
  position: Vector3(0, -0.5, 0),
  isStatic: true, // solid for rigid bodies
);
world.addAll([level, floor, PhysicsWorld3D(collisionSystem: level)]);
```

Triggers and colliders that are not static (characters, the colliders of moving things) are
ignored by the solver: an obstacle that moves is a kinematic `RigidBody3D`. Level geometry can
equally be a static `RigidBody3D` (a box, a compound or a `HeightfieldShape3D`). Every physics step
re-synchronizes the collision system's tree, a walk over its parent's subtree, so keep that parent
small too.


### Contact quality

Measured with the default settings, on boxes and dice of `0.5 m`, friction `0.6`:

- A box resting on a box sinks 1.4 mm on average (never more than `linearSlop`) and falls asleep
  after 0.5 s.
- Columns of up to six boxes, placed touching, stand and fall asleep within a second. A column of
  eight stands but sways by up to about 15 cm for several seconds before it sleeps; ten and more
  collapse. With `velocityIterations: 20`, columns of ten and twelve stand (swaying by up to 8 and
  16 cm) and fall asleep; sixteen still collapse. The solver is sequential impulses: tall stacks
  need more iterations, and the cost grows with them.
- Hulls rest on their faces like boxes. Over 2,000 seeded throws of a hull d6 with bevelled edges,
  every die fell asleep, after 3.4 s on average and 6.4 s at most (a box d6: 3.2 and 5.4 s), and
  sank 1.3 mm on average, never more than 4 mm.
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
against the other rigid bodies near the path and against the solid colliders of the collision
system (both found through their trees; equal times of impact are resolved in creation order).
The body is moved to just before the first hit and the impact is resolved like a contact, with
its restitution, friction and the effective mass at the contact point. The rest of the step is
swept again; after three impacts in one step the body stops at the next obstacle for what is left
of the step.

- Only the inscribed sphere is protected. Rotation is not swept, so the corners of a long, fast
  spinning body can still cut into things; the discrete contacts of the next step push them out.
- The default radius is the shape's `inscribedSphereRadius`, for hulls the distance from the
  center of mass to the nearest face: a face-down octahedron die falling at 15 m/s with CCD stops
  on its face, its center 0.173 m (its inradius) above the floor.
- Cost: for each CCD body above the speed threshold, up to four sweeps per step, each testing the
  rigid bodies and colliders near the path with a GJK sweep. Enable it on the bodies that need it
  (projectiles, fast thrown dice), not on everything.


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
- Two dynamic bodies joined by a joint wake up together, and fall asleep together.
- Anchors are points of the body; lever arms are measured from its center of mass, so joints work
  on compound and hull bodies whose center of mass is not at their origin.

The ragdoll controller of the animation system builds on these joints, see
[Models and Animation](models_and_animation.md).


## Buoyancy

`BuoyancyVolume3D` pushes submerged dynamic bodies up, drags them and tilts them with the waves.
It is applied when registered with `addBuoyancyVolume`, or when it is mounted anywhere under the
physics world's parent (it registers itself when it mounts and leaves when it is removed).

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
- The volume is `shape.estimateLocalVolume()`, exact for every convex shape.
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

- `fourWheel` places the wheels at `+-halfWheelbase` (`1.25`) along `forwardAxisLocal` (default
  local `+Z`) and `+-halfTrackWidth` (`0.85`) across it (along local `up x forward`, turned toward
  `+X`), front wheels steering, all wheels driven unless `allWheelDrive: false`.
- With `massNormalizedSuspension: true` (the default), `springStiffness` (`35`), the dampers,
  `engineForce` (`14` in `fourWheel`) and `maxBrakeForce` are per kilogram of chassis, so the same
  numbers suit a light and a heavy car: `engineForce` is then the acceleration in `m/s^2`.
- `rollInfluence` (`0.25`) lowers the point where the tire forces act, to keep a high car from
  rolling over.
- `wheelStates` give each wheel's `isGrounded`, `suspensionLength`, `compression`, `contactPoint`,
  `contactNormal`, `wheelWorldPosition`, `steerAngleRad`, `rotationRad` (for spinning wheel meshes)
  and `skidInfo` (`1` = full grip). `groundedWheelCount` and `forwardSpeed` summarize them.
- A wheel rolls along `forwardAxisLocal`, or, when its `WheelSpec3D` is given an
  `axleDirectionLocal`, perpendicular to that axle (`axle x up`, reversed if it points away from
  `forwardAxisLocal`).
- The minimum tire load, which keeps a little grip on a wheel that barely touches, is a share of the
  chassis weight under the world's gravity.


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

`saveSnapshot()` encodes the state of a physics world into bytes (`'P3DS'`, format version `2`,
CRC32 at the end) and `restoreSnapshot(bytes)` puts it back, throwing a `FormatException` when the
header, version or checksum is wrong. Version `1` snapshots are still read, without their
warm-start impulses. A ring buffer keeps the last snapshots for rollback:

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
a `SeededRng3D` (`PhysicsSnapshot3D.encodeWorld(world, rng: rng)`). The warm-start impulses are
stored per contact point, with the two bodies given by their position among the snapshot's bodies
(a static collider by its position in the collision system's `collectColliders()`) and the point
by its `featureId`. It is 69 bytes plus 168 per body and 72 per warm-started contact point. It
does not hold shapes, masses or materials, cloth or rope, collision-system pairs, the colliders
themselves, or the joints (which carry no state from one step to the next).

Body records are matched to the world's bodies by creation id when the world holds every recorded
body (the world the snapshot came from), by position in creation order when it holds none of them
and as many bodies (a world built again), and otherwise by creation id only: records of removed
bodies are skipped and bodies added since keep their state. Creation ids restart with each
process, so a world rebuilt in another process restores with `restoreSnapshot(bytes,
matchByOrder: true)`.

What is reproducible, as measured and tested:

- The same world, stepped the same way from the same state, gives bit-identical results; so does
  restoring a snapshot into the world it came from and stepping again.
- Restoring a snapshot into another world built the same way (the same bodies, colliders, joints
  and settings, created in the same order) and stepping it gives bit-identical results too.
- A fresh world built the same way and thrown with the same seed reproduces a throw bit for bit.
- These hold on one platform and build (tested on the Dart VM).
- Across platforms nothing is guaranteed and nothing was tested. The arithmetic is IEEE double
  precision with values stored as 32-bit floats everywhere, but body rotation calls `sin` and
  `cos`, which come from the platform's math library on native targets and from the JavaScript
  engine on the web, and may differ in the last bit. Only `SeededRng3D` (integer arithmetic) is
  portable. A networked game should send results or poses from one authority rather than expect
  every client to compute the same throw from a seed, unless all clients run the same build on
  the same platform.


## Throwing dice

A six-sided die with sharp edges is a `BoxShape3D`: its contacts are exact, it settles flat and
falls asleep. Measured over 2,000 seeded throws of a 0.5 m die onto a large box floor (friction
`0.6`, restitution `0.35`, defaults otherwise): every die slept, within 5.4 s (3.2 s on average),
two ended tilted by more than 8 degrees, and the faces came up uniformly (chi-square `6.9`, five
degrees of freedom). A fast-spinning die can hop a long way: on a floor 16 m across, about 1 in
16 throws left it, so give the dice walls or a tray.

Other dice, and dice with bevelled or rounded edges, are `ConvexHullShape3D`s. They rest on their
faces like boxes and settle with the default settings. Measured on 0.5 m dice in the same setting:

| Die                               | Throws | All asleep | Mean / longest | Chi-square (df) |
| --------------------------------- | ------ | ---------- | -------------- | --------------- |
| box d6                            | 2,000  | yes        | 3.2 s / 5.4 s  | 6.9 (5)         |
| hull d6, edges bevelled by 8 %    | 2,000  | yes        | 3.4 s / 6.4 s  | 4.5 (5)         |
| hull d8 (octahedron)              | 300    | yes        | 2.8 s / 4.9 s  | 2.7 (7)         |
| hull d20 (icosahedron)            | 300    | yes        | 3.7 s / 6.2 s  | 25.1 (19)       |

A bevel strip is a narrow face of its own, and a die can come to rest on it: 10 of the 2,000
bevelled d6 did (59 of 2,000 with bevels of 16 %). Count such a throw as cocked and throw again.
Continuous collision detection may stay on, as its default sphere is the hull's inradius.

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

For a hull die, its own faces give the normals; map each face index to the value printed on it:

```dart
/// The index of the hull face pointing up (Y-up world).
int topHullFace(RigidBody3D die) {
  final hull = die.shape as ConvexHullShape3D;
  final r = die.bodyRotation.asRotationMatrix();
  var best = 0;
  var bestUp = -2.0;
  for (var f = 0; f < hull.faceCount; f++) {
    final up = r.transformed(hull.faceNormal(f)).y;
    if (up > bestUp) {
      bestUp = up;
      best = f;
    }
  }
  return best;
}
```

Give the settle check a timeout as well (a die can come to rest leaning on a wall), and treat a
top face tilted by more than a few degrees as cocked.

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

Measured on a desktop computer under `flutter test` (JIT compilation, after a warm-up), for 0.5 m
dice thrown in rows of ten into a walled 12 m tray, average step over four seconds:

| Dice | Box d6 | Bevelled hull d6 | Asleep after 4.5 s (boxes) |
| ---- | ------ | ---------------- | -------------------------- |
| 1    | 1 us   | 2 us             | 1 of 1                     |
| 5    | 5 us   | 10 us            | 5 of 5                     |
| 20   | 29 us  | 40 us            | 20 of 20                   |
| 50   | 127 us |                  | 48 of 50                   |
| 100  | 283 us |                  | 94 of 100                  |

Single steps take from tens of microseconds to a few milliseconds when many bodies land at once or
a garbage collection runs. These numbers show how the cost grows, not what a phone does: measure on
the target device in a release build.

Where the time goes, per step:

- The bodies are registered when they mount; the world updates the bounds and the tree entry of
  the bodies that moved since the last step only. An attached `CollisionSystem3D` is
  re-synchronized once per step (a walk over its parent's subtree), and again by every collision
  query, so give it a small parent.
- A contact pair costs one narrowphase test and its constraint, solved `velocityIterations` plus
  `positionIterations` times. Pairs of sleeping bodies (or a sleeping body and a static one) cost
  nothing; let dice fall asleep.
- The narrowphase and the number of contact points set the cost of a pair. A hull pair runs GJK
  and EPA, then clips two faces; a box pair runs the separating axis test.
- Continuous collision detection, vehicles (every wheel ray tests every body's bounds) and the
  character controller add their own scans, see their sections.

Contact constraints, their points and their warm-start history are kept per touching pair and
reused, and the step creates no closures. What still allocates, per touching pair and step, is the
narrowphase result: a `CollisionManifold3D` with its contact points (about ten small objects for
four points) and, for pairs that involve a hull, the working sets of GJK and EPA (a few dozen).
Sleeping pairs allocate nothing. On a phone keep the number of awake touching pairs to a few dozen
and check for collection pauses with the profiler.


## Limitations

- Rigid bodies collide with rigid bodies and with static, non-trigger colliders; not with moving
  colliders, meshes or models.
- Tall stacks need more iterations than the default: columns of more than six boxes sway or
  collapse with `velocityIterations: 8` (ten and twelve stand with 20).
- No gyroscopic term in the integration of rotations.
- Continuous collision detection sweeps a sphere and ignores rotation.
- Snapshots reproduce on one platform and build; nothing is guaranteed across platforms.
- Every step allocates the narrowphase manifolds of touching pairs; an attached collision system
  is re-synchronized (a walk over its parent's subtree) every step, and every collision query
  walks it again.
- Buoyancy is horizontal in Y.
- Cloth does not collide with itself, only with sphere and capsule colliders, and does not affect
  rigid bodies. Cloth and rope step with the frame time (capped at `1/30` s) unless created with
  `autoStep: false`.
- Solver tolerances are absolute (`linearSlop`, the sleep thresholds, the 2 mm within which face
  points are kept), tuned for objects of 0.1 m and more.
