# Particles and Ribbons

`package:flame_3d/particles.dart` holds two kinds of effects for the 3D world:

- `ParticleSystem3D`, a particle system: it spawns particles, simulates them on the CPU and draws
  all of them with one instanced draw, depth tested against the rest of the scene. Sparks, coins,
  smoke and dust pass behind and in front of models as they should, in a `FlameGame3D` as in a
  `Scene3DComponent` layer of a 2D game.
- Ribbons: `StrokeBatch3D` draws 3D polylines (beams, arcs, paths) and `RibbonTrail3D` a trail
  behind a moving object, as camera-facing strips drawn with `RibbonMaterial3D`, one instanced draw
  each.


## A first system

A system draws billboards with a `ParticleMaterial`, or small meshes (see
[Mesh particles](#mesh-particles)). Its emitters say when, where and how particles spawn; the system
says how they move and change over their life:

```dart
final sparks = ParticleSystem3D(
  capacity: 512,
  material: ParticleMaterial(
    billboard: ParticleBillboard.velocity,
    renderState: RenderState.additive,
  ),
  emitters: [
    ParticleEmitter3D(
      shape: const ConeEmitterShape3D(angle: 0.6),
      speed: (3, 6),
      lifespan: (0.4, 0.8),
      size: (0.04, 0.06),
      colors: const [Color(0xFFFFC870)],
    ),
  ],
  gravity: Vector3(0, -9.8, 0),
  ground: ParticleGround3D(restitution: 0.35),
  velocityStretch: 0.05,
  sizeOverLife: ParticleCurve(1, 0.4),
  opacityOverLife: ParticleCurve(1, 0),
);
world.add(sparks);

// Where something hits:
sparks.burst(40, at: hitPoint);
```

All the state lives in struct-of-arrays typed lists allocated with the system, for `capacity`
particles (1024 by default, about 200 bytes each), so simulating and drawing allocate nothing.
Particles spawned while the system is full are dropped, or replace live ones in turn with
`overflow: ParticleOverflow.recycle`. The system's `random` generator is seeded (`seed`), so a
system fed the same time steps produces the same particles.

The curves over a particle's life (`ParticleCurve`, `ColorRamp`), the ranges of per-particle values
(`(min, max)` records) and the bursts (`EmitterBurst`) are the ones of Flame's 2D particles.


## Emitters

A `ParticleEmitter3D` is an immutable description that any number of systems can share:

- when: a continuous `rate` (particles per second), `bursts` at times on its timeline, a
  `duration` and `loop`, and `ratePerDistance`, particles per unit of distance the system travels,
  spread along the way, for trails behind moving objects;
- where: its `shape` and `offset`. The shapes are `PointEmitterShape3D`, `SphereEmitterShape3D`
  (volume or surface, optionally the upper half), `BoxEmitterShape3D`, `DiscEmitterShape3D` (a disc,
  a ring with `innerRadius`, moving up or `radial` along the ground) and `ConeEmitterShape3D` (from
  its apex, or from a base disc). Shapes are described around the local `+y` axis and oriented by
  the system's transform; subclass `EmitterShape3D` for custom ones;
- how: `speed` along the shape's direction, randomized within a cone of `spread`, plus a constant
  `velocity` and a fraction of the system's own velocity (`inheritVelocity`); `lifespan`, `size`
  and `aspect` (height over width), `rotation` and `spin`, `gravityScale`, and the `colors` each
  particle picks from.

Besides the emitters' timelines (paused with `stop`, resumed with `start`), particles can be
spawned on demand:

```dart
// With the spawn rules of the first emitter, or of another one:
smoke.burst(12, at: chimneyTop);
dust.burst(6, at: footPosition, color: groundColor);

// One particle with explicit values:
system.spawn(
  position: Vector3(0, 1, 0),
  velocity: Vector3(0, 2, 0),
  lifespan: 0.8,
  size: 0.1,
  color: const Color(0xFFFFFFFF),
);
```

`density` scales the number of particles the emitters and `burst` spawn, for graphics quality
settings.


## Simulation

Particles live in the world (`ParticleSpace.world`): once spawned they no longer follow the system,
so a moving system leaves a trail. With `ParticleSpace.local` they move, turn and scale with it.
Forces and the ground are in that same space.

Each step, particles are pulled by `gravity` (scaled per particle by the emitter's
`gravityScale`) and `wind`, swirled by `turbulence`, drawn to `attractors`, and slowed by `drag`.
Long frames are simulated in steps of at most `maxStep` seconds (1/30 by default, eight steps at
most, and frames longer than 0.25 seconds are cut to 0.25).

- `ParticleTurbulence3D` is curl noise: a smooth, divergence-free flow that swirls particles about
  without gathering them in clumps, changing over time at its `speed`.
- `ParticleGround3D` is a plane particles bounce off (`restitution`, `friction`), slide on and come
  to rest on (`slideDrag`, `restSpeed`). `sizeOffset` keeps them above the plane by a fraction of
  their size, `killOnHit` kills them when they hit it (rain), and `settleRotation` turns resting
  particles back to a rotation of zero, so that a coin modelled lying flat comes to rest lying flat.
  Each bounce calls the system's `onGroundHit` with the point and the speed of the hit, after the
  simulation step, so the callback can spawn particles (splashes) or play sounds.
- `ParticleAttractor3D` pulls particles to a `target` (that can move); particles that come within
  its `arrivalRadius` arrive, are removed when `consumeOnArrival`, and are counted to `onArrived`:
  coins flying into a purse. A system takes 32 attractors at most.

Over its life, a particle's size follows `sizeOverLife`, its color `colorOverLife` (multiplying its
spawn color) and `opacityOverLife`, its spin `spinOverLife`, and `rotationOverLife` adds to its
rotation. `flipbook` picks the frame of a textured material over the life, at a frame rate or at
random.

`paused` freezes a system (its particles are still drawn), `clear` removes its particles, `reset`
also restarts its timelines, and `prewarm` simulates some seconds at once, so that a fire is already
burning when it appears. `isFinished` tells when every emitter finished its timeline and no particle
is left; with `removeOnFinish` the system then removes itself.

Particles collide with their ground plane only, not with meshes.


## Billboards

A `ParticleMaterial` draws each particle as a quad built in the vertex shader. Its `billboard`
decides how the quad faces the camera:

- `spherical`: parallel to the screen, upright on screen, turned by the particle's rotation;
- `cylindrical`: upright along the material's `axis`, turning about it only (flames, beams);
- `velocity`: stretched along the particle's velocity as seen on screen, by
  `1 + speed * velocityStretch` (at most `maxStretch`) times its height, the leading edge half a
  size ahead of the particle (sparks, rain, streaks);
- `flat`: in the plane perpendicular to the `axis`, whatever the camera (ripples, shock rings).

Quads stay upright and unmirrored on screen even when the projection mirrors the scene, as the
projections of 2D art often do.

A quad shows its `sprite`, multiplied by the material's `texture`, its `color` and the particle's
color: `ParticleSprite.softCircle` (a disc with a soft edge, `softness`) and
`ParticleSprite.softBlob` (a lumpy puff whose outline and inside vary from particle to particle,
`lumpiness`, for smoke and dust) need no texture; `ParticleSprite.texture` shows the texture alone.
A texture can be a flipbook of `flipbookColumns` by `flipbookRows` frames (`frameCount` of them),
read left to right and top to bottom, with `frameBlending` between frames. Textures hold
premultiplied alpha, as the images Flutter decodes do; give them a `TextureSampler.linear` sampler.

The material's `renderState` decides how particles blend:

- `RenderState.premultipliedAlphaBlend` (the default) and `RenderState.alphaBlend`: blended, depth
  tested, without depth writes; the system sorts its particles back to front;
- `RenderState.additive`: added to what is behind, depth tested, without depth writes and without
  sorting. Added light covers nothing, so in a `Scene3DComponent` glowing particles over an empty
  part of the scene add their color to the 2D art behind the layer;
- an opaque state with an `alphaCutoff`: cut-out particles that write depth. Like every billboard,
  they cast no shadows (see [Shadows](#shadows)).

`ParticleSystem3D.sort` overrides the sorting. The whole system is ordered among the other
translucent draws of the scene by the center of its bounds.


## Soft particles

A billboard that crosses a wall or the ground shows a hard line where it enters it. With
`ParticleMaterial.softDepthFade` above zero, the opacity of a fragment fades to zero as it comes
near the opaque surface behind it, which hides the line.

The fade needs the depth of the scene, which the world renders in its depth-normal prepass (see
[Post-Processing](post_processing.md#depth-normal-prepass)): turn it on with
`World3D.depthPrepassEnabled` (ambient occlusion and depth of field turn it on too). Without the
prepass, `softDepthFade` does nothing.

```dart
final layer = Scene3DComponent(projection: boardProjection);
layer.world.depthPrepassEnabled = true;
layer.world.add(
  ParticleSystem3D(
    material: ParticleMaterial(
      sprite: ParticleSprite.softBlob,
      // Fades over 1 unit when the projection's depth runs from
      // near -100 to far 100 (200 units).
      softDepthFade: 0.005,
    ),
    emitters: [ParticleEmitter3D(rate: 6, lifespan: (2, 3))],
  ),
);
```

`softDepthFade` is a span of normalized depth, the depth of the camera's projection from 0 at its
near plane to 1 at its far plane, not a distance:

- with an orthographic projection, or the affine projections of `Scene3DComponent`, the fade spans
  `softDepthFade * (far - near)` units, everywhere; a layer whose projection reaches from -100 to
  100 fades over 1 unit with `0.005`;
- with a perspective projection, depth is not linear: the fade spans about
  `softDepthFade * z² * (far - near) / (near * far)` units at a distance `z` from the camera. With
  a near plane at 0.1 and a far plane at 100, `0.0005` fades over 0.5 units at 10 units from the
  camera, 0.005 units at 1 unit, and 12.5 units at 50.

The prepass computes the depth per vertex and interpolates it across each triangle, which is exact
for orthographic and affine projections. Under a perspective camera it is wrong inside large
triangles, and inside triangles that reach behind the camera: behind a ground plane made of two
triangles, particles in front of the ground fade out as if they were inside it (seen in a test with
a 40 by 40 unit plane 5 to 45 units from the camera, where more than half of a billboard standing
on the ground faded out). Tessellate large opaque surfaces that soft particles show against, or
keep `softDepthFade` at `0` with perspective cameras.

The prepass texture has half the width and half the height of the scene, and its 16-bit depth is
filtered, so the fade is coarse along the edges of opaque objects. Each faded fragment reads it
once; the prepass itself (one more render pass and one more traversal of the world, in which
particle systems write their instance data too) runs whenever it is turned on, whether a material
uses it or not.

Soft particles work in a `FlameGame3D` and in a `Scene3DComponent` layer (the layer renders the
prepass of its own world). They apply to billboards only, not to mesh particles.


## Mesh particles

With a `mesh` instead of a material, each particle is a copy of the mesh, scaled by its size and
turned about its spin axis (one of its own chosen at random, or the system's `spinAxis`), drawn with
the materials of the mesh's surfaces: any material drawn instanced, such as `StylizedMaterial`,
`SpatialMaterial` or `UnlitMaterial`. The particle's color is the per-instance color, and the
system's `instanceData` is copied into the per-instance data of every particle (a
`StylizedMaterial` reads a glow, a highlight, a wind strength and a fade from it). The system's
rotation is the base orientation of every particle.

```dart
final coins = ParticleSystem3D(
  capacity: 128,
  mesh: coinMesh, // a coin modelled lying flat in its xz plane
  emitters: [
    ParticleEmitter3D(
      shape: const ConeEmitterShape3D(angle: 0.5),
      speed: (3, 5),
      lifespan: (2.2, 2.8),
      size: (0.1, 0.12),
      rotation: (0, 2 * pi),
      spin: (-16, 16),
    ),
  ],
  gravity: Vector3(0, -9.8, 0),
  ground: ParticleGround3D(restitution: 0.45, settleRotation: true),
);
```

All the particles of a system are one instanced draw per surface of the mesh, so coins tumble
behind buildings and in front of them, lit like the rest of the scene.


## Presets

`ParticlePresets3D` builds ready-made systems. Each has one emitter that spawns nothing on its own
unless given a `rate`; `burst` releases particles where the effect happens. Sizes, speeds and
accelerations are in meters for a `scale` of 1 (pass the number of scene units per meter
otherwise), `up` is the scene's up direction (`+y` by default), and `groundHeight` places the ground
plane of the presets that have one along `up` (`null` for none):

- `sparks`: additive billboards stretched along their velocity, falling and bouncing on the ground
  (512 particles);
- `smoke`: soft blobs that rise, swell, swirl in turbulence and fade, sorted (256 particles);
- `dustPuff`: soft blobs thrown sideways along the ground that swell and settle (256 particles);
- `confetti`: mesh particles, small two-sided cards of an opaque `UnlitMaterial` in six colors that
  flutter down and settle lying flat (512 particles);
- `coinBurst`: mesh particles, gold coins (a `CylinderMesh` of radius 1 with a `SpatialMaterial`)
  that bounce and settle lying flat (128 particles).

`confetti` and `coinBurst` take a `mesh` of your own, `sparks`, `smoke` and `dustPuff` a `color`,
and all of them a `capacity` and a `seed`.

```dart
// A scene measured in cells, with z up.
final coins = ParticlePresets3D.coinBurst(up: Vector3(0, 0, 1), scale: 0.5);
layer.world.add(coins);
coins.burst(14, at: Vector3(3.5, 4.5, 0.2));
```


## Shadows

Only mesh particles are drawn into a shadow map (see [Shadows](shadows.md)): when one of their
mesh's materials casts shadows, and the system's `castsShadows` is `true`, they cast the shadows of
their meshes.

Billboards cast no shadows, whatever their `renderState`: the shadow pass draws every instance with
a model matrix, and the instance data of a billboard is not one. `ParticleMaterial.castsShadows` is
always `false` (setting it to `true` fails an assertion), and a system of billboards skips the
shadow pass, sorting nothing. For the same reason billboards are not drawn into the depth-normal
prepass, even cut-out ones (an opaque `renderState`), so SSAO and depth of field do not see them;
mesh particles with an opaque material are drawn into it.

A system with mesh particles counts as a moving caster on every frame it has live particles, so it
keeps `ShadowSettings.cacheWhenStatic` from reusing the shadow map. The system writes its instance
data again for each map it casts into: once per tile of the shadow atlas.


## Bounds and statistics

The world-space `aabb` of a system covers its particles and their size, and is kept up to date as
they move. The system is culled with it like any `Object3D`, and it is part of the bounds of the
world, so a `Scene3DComponent` renders the part of the screen its particles cover.

`RenderStats.particles` (in `FlameGame3D.renderStats` and `Scene3DComponent.renderStats`) adds the
particles of a system once per frame, when it records its draw for the main pass; the shadow maps
and the depth-normal prepass do not count them again. The draws themselves are counted in
`drawCalls` and `instances`, in every pass.


## Ribbons and strokes

Ribbons are flat strips that always face the camera, built from a polyline in the vertex shader:
each segment of the polyline is an instance, a quad that the shader turns about the segment so that
its face looks at the camera, as wide as the polyline's width at either end. Consecutive segments
share the tangent of the point between them, so they meet without gaps; the width is measured
across that tangent, so sharp turns look thinner. Nothing is rebuilt on the CPU when the camera
moves.


### RibbonMaterial3D

The material of every ribbon:

- `renderState`: `RenderState.additive` by default (glowing beams and trails); any other state
  works, with premultiplied output unless it is `RenderState.alphaBlend`;
- `albedoColor`: a tint multiplied by each stroke's color (white by default);
- `texture`: an optional strip texture, `u` running from 0 at the first point of a stroke to 1 at
  its last and `v` from one edge to the other;
- `edgeSoftness`: the share of each half-width that fades to transparent towards the edges (0.35 by
  default; 0 for hard edges);
- `alphaCutoff`: fragments whose alpha is lower are discarded (0 by default);
- `depthBias`: pulls the ribbon towards the camera by this much normalized depth (0 by default),
  for ribbons drawn on a surface.

It casts no shadows, and is not available on the web: creating one there throws an
`UnsupportedError`.


### StrokeBatch3D

A `StrokeBatch3D` collects polylines and draws all their segments with one instanced draw: laser
beams, trajectory arcs, lightning, paths on a map.

```dart
final strokes = StrokeBatch3D(
  material: RibbonMaterial3D(edgeSoftness: 0.2),
)..addPolyline(
  [Vector3(0, 0.1, 0), Vector3(1, 0.6, 0), Vector3(2, 0.1, 0)],
  width: 0.3,
  endWidth: 0.1,
  color: const Color(0xFF30D0FF),
  endOpacity: 0.8,
);
world.add(strokes);

// The same, point by point, with a half-width and an opacity for each:
strokes
  ..beginStroke(color: const Color(0xFFFFE070))
  ..addPoint(0, 0, 1, halfWidth: 0.05)
  ..addPoint(1, 0.5, 1, halfWidth: 0.08, opacity: 0.6)
  ..addPoint(2, 0, 1, halfWidth: 0.02, opacity: 0)
  ..endStroke();
```

- `addPolyline` takes full widths and interpolates the width and the opacity linearly from the first
  point to the last. Its defaults taper the stroke: `width` 0.1 to `endWidth` 0, opacity 1 to 0.
- A stroke has one color; strokes of fewer than two points are dropped. The strokes of a batch are
  not joined to each other.
- The points are in the batch's local space and move with it; widths scale with the cube root of
  the volume its world transform scales by.
- The strokes stay until `clear()`, which keeps the memory. To animate a stroke, clear the batch and
  add it again in `update`: that costs one pass over its points on the CPU.

Storage starts at `initialSegmentCapacity` segments (64) and doubles when it fills, which
allocates. Each segment takes 24 floats; when the batch's world transform is not the identity, a
second buffer of world-space segments is rebuilt whenever the segments or the transform change. The
batch is ordered among the translucent draws by the center of its bounds, and is not drawn into
shadow maps.


### RibbonTrail3D

A `RibbonTrail3D` records the positions an object goes through and draws them as a ribbon that
tapers and fades with their age:

```dart
final trail = RibbonTrail3D(
  target: projectile, // any Component3D
  lifetime: 0.4,
  width: 0.18,
  color: const Color(0xFF40E0FF),
  material: RibbonMaterial3D(edgeSoftness: 0.35),
);
world.add(trail);
```

Each `update`, the trail ages its points and drops those older than `lifetime` (0.45 seconds by
default), then reads the world position of what it tracks and adds a point when it moved
`minVertexDistance` (0.04) or more from the newest one. It keeps at most `maxPoints` (64) points in
a ring buffer allocated with the trail, dropping the oldest. The width (`width`, 0.16 by default,
the full width) and the opacity of `color` follow `widthOverLife` and `opacityOverLife` over the age
of each point, from 0 (the newest) to 1 (the oldest); both go from 1 to 0 by default.

What it tracks is `target` when set, otherwise its own world position, which follows its parent: a
trail added as a child of a moving object at an offset `position`, such as the tip of a sword,
trails that point. A `target` trails another component wherever the trail itself is:

```dart
sword.add(RibbonTrail3D(position: Vector3(0, 1.2, 0), width: 0.1)); // the tip
world.add(RibbonTrail3D(target: comet, width: 0.3)); // follows the comet
```

The points are in world space and drawn as they are. `emitting` stops and resumes adding points,
`addSample` adds one by hand, and `reset` clears the trail at once, for an object that teleports.
The newest point lags up to `minVertexDistance` behind the object. Every frame with at least two
points, the trail rebuilds its segments on the CPU (one pass over its points) and marks the world
as changed, which keeps a retained `Scene3DComponent` from reusing its image.


## Drawing instances of your own

The systems and the ribbons record their draws with `RenderContext3D.drawInstances`, which other
objects that build their own instance data can use too: one instanced draw of a surface whose
instances are read from a `Float32List`, 24 floats each (`VertexLayout.instanceStrideInFloats`),
laid out as the per-instance inputs of `flame_3d/instancing.glsl`: the four `instanceModel`
columns, `instanceColor` and `instanceData`.

```dart
class Swarm extends Object3D {
  Swarm(this.surface, this.material) : super(castsShadows: false);

  final Surface surface;
  final Material material;
  final Float32List instances = Float32List(
    256 * VertexLayout.instanceStrideInFloats,
  );
  int count = 0;
  final Vector3 center = Vector3.zero();

  @override
  void draw(RenderContext context) {
    (context as RenderContext3D).drawInstances(
      surface,
      material: material,
      instances: instances,
      count: count,
      center: center,
    );
  }
}
```

- The material's vertex shader must declare the four `instanceModel` columns, or `drawInstances`
  throws a `StateError`; what they mean is up to it.
- Each call is one draw call, never batched with other draws. The context keeps the list and uploads
  it when the pass is flushed: do not change it before the end of the pass.
- `center` (in world space) orders a translucent draw among the others; without it, the draw is
  ordered as if it stood at the world origin.
- In a shadow pass, the draw is skipped when the material casts no shadows. The shadow pass and the
  depth-normal prepass draw the surface with their own shaders, which read the four columns as a
  model matrix: a material whose instances hold something else returns `false` from
  `Material.instancesHoldModelMatrices`, and both passes leave its draws out. Particle systems of
  billboards and stroke batches also skip the call when `context.isShadowPass` or
  `context.isDepthNormalPass` is `true`, which spares writing their instances.

The vertex shader of `ParticleMaterial` reads the columns as: the center and the width
(`instanceModel0`), the velocity and the height (`instanceModel1`), the rotation, the flipbook
frame, a random seed and the stretch (`instanceModel2`), the life progress (`instanceModel3.x`) and
the color (`instanceColor`). Mesh particles write a model matrix. Ribbons write the start point and
half-width (`instanceModel0`), the end point and half-width (`instanceModel1`), the tangent and the
opacity at the start (`instanceModel2`) and at the end (`instanceModel3`), the color
(`instanceColor`), and the `u` texture coordinate at both ends (`instanceData.xy`).


## Costs

- CPU, each frame: the simulation of every live particle (once per step, up to eight steps), a
  radix sort of the particles of blended billboards, and the writing of 24 floats per particle for
  each pass the system is drawn in (the main pass, and for mesh particles each shadow map they cast
  into and the depth-normal prepass). A trail rebuilds its segments; a stroke batch only when it
  changes.
- GPU: one draw call per system (per surface of the mesh for mesh particles), per stroke batch and
  per trail, with 96 bytes of instance data uploaded per particle or segment. Billboards are two
  triangles each, drawn without depth writes when blended, so overlapping large particles cost fill
  rate.
- A system, a batch or a trail with live content marks its world as changed every frame.


## Platform support

`ParticleMaterial` has no WebGPU build, and `RibbonMaterial3D` refuses the web although a WGSL
bundle of its shader ships: creating either on the web throws an `UnsupportedError`. Mesh particles
use the materials of their mesh; no test covers them on the web. Everything above is available on
the native backends (Metal, Vulkan and OpenGL ES); the GPU tests run on the backend of the headless
tests, not on an OpenGL ES device.


## Limitations

- Particles collide with their ground plane only, not with meshes.
- Soft particles fade wrongly behind large triangles under a perspective camera, and their fade is
  given in normalized depth rather than in scene units (see [Soft particles](#soft-particles)).
- Billboards cast no shadows and are not in the depth-normal prepass, cut-out ones included.
- Ribbons do not widen at sharp turns.
- `ParticleMaterial` and `RibbonMaterial3D` are not available on the web.
