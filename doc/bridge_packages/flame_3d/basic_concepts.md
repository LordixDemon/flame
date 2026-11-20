# Basic Concepts

This page explains how a `flame_3d` scene is organized and how it gets onto the screen: the world
and its components, transforms and coordinates, what happens in a frame, how the engine knows that
a scene changed, the masks that hide things from cameras, GPU resources, and hosts.


## The world and its components

A `World3D` is the root of a 3D scene. It is a Flame `World`, so it lives in the component tree
like any other, and it holds the scene-wide settings: `fog`, `bloom`, `postProcess`, `hdrEnabled`,
`renderScale`, `oitMode`, `depthPrepassEnabled` and the others described on the
[Rendering](rendering.md), [Lighting](lighting.md) and [Post-Processing](post_processing.md) pages.
A world is shown in one of two ways:

- as the world of a `FlameGame3D` (or any `FlameGame` with the `Game3D` mixin), seen through a
  `CameraComponent3D` (see [Cameras](cameras.md));
- inside a `Scene3DComponent`, as one layer of a 2D game (see
  [Embedding 3D in a 2D Game](embedding.md)).

```{include} ../../flame/diagrams/flame_3d_components.md
```

Its content is made of `Component3D`s:

- `Object3D` is the base of everything that draws: `MeshComponent`, `ModelComponent`,
  `InstancedGroup3D`, `LodMeshComponent`, particle systems and the other batches. Its `draw` method
  records draws into the render context of the pass (see [Rendering](rendering.md)), and its
  `castsShadows` flag (default `true`) keeps it out of shadow passes when `false`.
- `LightComponent` registers a light with its world when it is mounted (see
  [Lighting](lighting.md)). Lights may be nested anywhere in the world: a light follows the world
  transform of its parents, so a lamp can be a child of a moving cart.
- `Group3D` is a component without geometry, to move, hide, tag or clone a subtree together.

```dart
final cart = Group3D(
  position: Vector3(2, 0, 0),
  children: [
    MeshComponent(mesh: cartMesh),
    LightComponent.point(
      position: Vector3(0, 1.2, 0),
      intensity: 3,
      range: 6,
    ),
  ],
);
world.add(cart);
```

Every `Component3D` has `aabb`, its world-space bounding box including its children, recomputed
only when it or a descendant moved. `World3D.sceneBounds` is the union of the bounds of the world's
components, lights and reflection probe volumes excepted, or `null` for an empty world; it is kept
up to date incrementally (reading it after `k` of `n` components moved costs about `k * log2(n)`
box unions). The sun's shadow map is fitted to it (see [Shadows](shadows.md)), and a
`Scene3DComponent` uses it to render only the part of the screen its scene covers.

A direct child of the world whose `includeInSceneBounds` is `false` is left out of `sceneBounds`;
it is still drawn and culled with its own `aabb`. Use it for a component whose bounds are far larger
than what the shadows should cover, such as an overlay that may draw anywhere (`DebugRenderer3D`
sets it), so that adding it does not spread the shadow map thin. While a world holds such a
component, `World3D.hasUnboundedComponents` is `true` and a `Scene3DComponent` renders its whole
visible area. Only direct children of the world count: a nested component is counted through the
bounds of its parent.

A world can also hold ordinary Flame components for their logic: camera rigs, timers, behaviors.
Do not use it for components that paint on the canvas: the world's children are traversed once per
pass (the shadow pass and the depth prepass included), so such a component would paint several
times per frame, under the 3D image.


## Transforms and coordinates

A `Component3D` has a `position` (`NotifyingVector3`), a `rotation` (`NotifyingQuaternion`) and a
`scale` (`NotifyingVector3`, `(1, 1, 1)` by default; negative values mirror). Its local matrix is
translation, then rotation, then scale (`T * R * S`), and `worldTransformMatrix` multiplies it by
the parents' world matrices. Both are cached and recomputed only after a change; changes made in
place (`cube.position.x += 1`) count as changes.

```dart
final crate = MeshComponent(
  mesh: crateMesh,
  position: Vector3(1, 0, 3),
  rotation: Quaternion.axisAngle(Vector3(0, 1, 0), pi / 4),
  scale: Vector3.all(0.5),
);
```

Conventions:

- World space is right-handed, in world units of your choice. The engine has no fixed up axis: the
  procedural meshes and the default camera assume +y up (`PlaneMesh` faces +y), but z-up scenes
  work as well, and the APIs that care take an up axis (`CameraComponent3D.up`, the camera rigs'
  `upAxis`, `WaterMaterial`'s up axis).
- Rotations are quaternions; `Quaternion.axisAngle` takes radians. The camera's `fovY` is in degrees.
- A camera looks down its -z axis, with +x to the right and +y up on screen. Clip-space depth runs
  from 0 at the near plane to 1 at the far plane (see [Cameras](cameras.md)).
- Front faces are counter-clockwise on screen. The winding flips automatically for mirroring cameras,
  projections and transforms (an odd number of negative scales), so back-face culling stays right.

The vector, matrix and quaternion types are those of `vector_math`, exported by
`package:flame_3d/core.dart` with the extensions of `flame_3d` (`Matrix4.setAsViewMatrix`,
`setAsPerspective`, `Ray.intersectsWithPlane`, `Aabb3.frustumCullTest`, `QuaternionUtils.slerp`
and others). Flame uses the same `vector_math` types, so a `Vector2` or `Vector3` passes between
the 2D and the 3D APIs as is.


## The frame

A frame has two halves, as in any Flame game:

1. **Update.** `update(dt)` runs on every component: game logic, camera rigs, animations, particle
   simulation. Components move by changing their transforms.
2. **Render.** For each world that is shown (once per `Scene3DComponent`, once per camera or
   camera slot):
   - the camera of the pass is set: the view and projection of the `CameraComponent3D`, or, for a
     layer, matrices built from the 2D canvas transform and the layer's projection;
   - when a light casts shadows, the world is traversed and its casters are drawn into the shadow
     map (see [Shadows](shadows.md)); with a depth prepass enabled, it is traversed again for it;
   - the world is traversed to **record** draws: each visible `Object3D` inside the camera's frustum
     calls `draw`, which records its meshes into the `RenderContext3D`; nothing reaches the GPU yet;
   - the recorded draws are sorted, batched into instanced draws and submitted in one render pass,
     followed by the post-processing passes, if any;
   - the resulting image is drawn on the Flutter canvas.

The device frame (`GraphicsDevice.begin` and `end`) spans the whole `render` call of a `Game3D`
game, so `renderStats` counts every pass of the frame. Hidden components (`visible == false`) are
skipped in every traversal; components outside the frustum are skipped in the main pass, whole
subtrees at once when a parent's bounds are outside.


## Scene versions and dirty marking

A world counts its changes in two numbers:

- `sceneVersion` increases whenever something that changes the picture is reported: a component is
  added, removed, moved, shown or hidden, or gets another `cameraMask`; a drawing property is
  assigned (`castsShadows` of an object, `color`, `instanceData` (in place too) and
  `jointTransforms` of a `MeshComponent`, `ModelComponent` or `LodMeshComponent`, the `shadowMesh`
  of a `LodMeshComponent`); a light is added, removed or moved, changes its `lightMask`, or a field
  of its `source` is assigned (`color`, `intensity`, `direction`, `shadows`, `range`, ...); a
  material's `castsShadows` changes; a world setting (`fog`, `bloom`, `postProcess`,
  `hdrEnabled`, `renderScale`, `oitMode`, `grabSceneColorEnabled`, `renderDebugMode3D`,
  `lightProbeGrid`, `depthPrepassEnabled`, `prioritizeNearestLights`) is assigned a new value; an
  animation advances a model's pose, a particle system or ribbon has live particles, particles are
  spawned or removed outside the system's `update` (`burst`, `spawn`, `clear`, `reset`,
  `prewarm`, at any point of the frame, also on a paused system), an effect runs, a batch
  (instances, billboards, decals, strokes, foliage) changes, or a `Text3DComponent` gets another
  text, look, `worldHeight` or `orientation`;
- `castersVersion` increases with the subset of these changes that can move shadows: all of them
  except colors, `instanceData`, intensities and other light fields that move no shadow, the world
  settings, `lightMask`, showing or hiding a light, reflection probes, and the changes of
  components that cast no shadows. A move counts only when it can move a shadow: when the
  component has 3D children, is an `Object3D` that casts shadows, or is a light whose source has
  `shadows`. A moving point light without shadows, collider or sound leaves a cached static shadow
  map alone.

A world that borrows the lights of another (`World3D.lightsFrom`, see
[Lighting](lighting.md#lights-shared-by-several-worlds)) counts their changes too: the lender
counts the changes of its lights in a third number, `lightsVersion`, which the borrowing worlds add
to their `sceneVersion`, the part of it that can move shadows to their `castersVersion`.

Assigning a value equal to the current one is not a change: writing an unchanged position,
rotation or scale (the transform's vectors notify only when their value changes), color or light
field marks nothing, so a component whose transform is set to the same value every frame does not
keep its world dirty.

`markSceneDirty()` raises both (pass `shadows: false` to raise only `sceneVersion`), and
`markShadowsDirty()` is the same as `markSceneDirty()`. Every increase also calls
`Game.notifyVisualMutation()`, which wakes a game whose `idleRenderMode` skips unchanged frames. A
mounted `CameraComponent3D` is polled by its game before such a frame is skipped, so moving it, in
place too (`camera.position.x += 1`), renders the next frame; the unmounted cameras of a
`CameraStack3D` notify from `stack.update`.

The versions drive three caches: a retained `Scene3DComponent` reuses its image while nothing
changed (see [Embedding 3D in a 2D Game](embedding.md)), `ShadowSettings.cacheWhenStatic` reuses a
shadow map while the casters did not change (see [Shadows](shadows.md)), and `SceneSpatialIndex3D`
rebuilds itself when `sceneVersion` changed. `ShadowSettings.cacheStillCasters` also tracks which
objects changed, to draw only those in the shadow pass (see
[Still casters](shadows.md#still-casters)).

Changes made in place, to data the engine only reads when it draws, are not seen. Report them,
with `shadows: false` when no shadow can move:

- the matrices of `jointTransforms` written into the existing lists, or what a custom `Object3D`
  draws without moving (its own buffers, a mesh it swaps in `draw`): call
  `component.markDrawDirty()` on the component; it costs two integer increments, so a custom object
  can call it on every frame it changes;
- a vector of a light source changed in place (`sun.direction!.setValues(...)`,
  `HemisphereLight.up`), or a field of its `ShadowSettings`: call `source.markChanged()`;
- a material's fields, including animated ones such as `StylizedMaterial.windTime` and
  `WaterMaterial.time`, a new texture, or new content in a texture: call
  `world.markSceneDirty(shadows: false)` on every world that draws the material (or
  `markDrawDirty(shadows: false)` on a component that draws it);
- a field of `fog`, of the `bloom` or `postProcess` settings, or `customPasses`: call
  `world.markSceneDirty(shadows: false)` (a retained layer also compares the `bloom` and
  `postProcess` values on every frame, see [Embedding 3D in a 2D Game](embedding.md)).

```dart
// A custom object that draws points it collects itself.
class Trail() extends Object3D {
  final List<Vector3> _points = [];

  void push(Vector3 point) {
    _points.add(point.clone());
    markDrawDirty(shadows: castsShadows);
  }

  @override
  void draw(RenderContext context) {
    // Record the draws of _points here.
  }
}
```


## Camera masks, light masks and visibility

Every component has a 32-bit `cameraMask` (default `0xFFFFFFFF`), and every render pass has the mask
of what renders it: the `cameraMask` of the `CameraComponent3D`, of the camera of a stack slot, of
the `Scene3DComponent`, or the mask passed to `RenderTexture3D.renderWorld`.

- A component and its subtree are drawn only when `component.cameraMask & pass mask != 0`, in every
  pass, shadow passes included. This holds for a `Group3D` (or another `Component3D` that draws
  nothing) as for an `Object3D`: a group's mask hides its whole subtree.
- A light is used by a pass only when `light.lightMask & pass mask != 0`. `lightMask` selects the
  cameras that see a light, not the objects it lights.
- `visible = false` hides a component and its subtree from every pass without unmounting it;
  `isEffectivelyVisible` also checks the ancestors. A hidden `LightComponent` still lights the
  scene: remove it, or set its `intensity` to `0`.

```dart
// Seen by the main camera (bit 0) only, not by the minimap (bit 1).
final label = MeshComponent(mesh: labelMesh, cameraMask: 0x01);
final minimapCamera = CameraComponent3D(cameraMask: 0x02);
```

A `Scene3DComponent`'s `cameraMask` is also the 2D component mask that Flame's 2D cameras test, so
a layer with mask `0x01` is only drawn by 2D cameras whose mask has bit 0 set.

Ray casts follow the same rules: `World3D.raycast` and `raycastAll` skip a hidden component and its
subtree, and a component (with its subtree) whose `cameraMask` shares no bit with the `cameraMask`
argument (default `0xFFFFFFFF`, so only components no camera draws are skipped by default).
`Scene3DComponent.raycastLocal` uses the layer's mask and `CameraStack3D.raycastAt` the slot
camera's. Pass `includeHidden: true` to test every component, for example for a probe against
invisible collision geometry (see [Geometry and Scene Queries](geometry.md)).


## Resources and disposal

Meshes, surfaces, textures and shaders are `Resource`s: they keep their data on the CPU and create
their GPU object (a buffer, a texture, a shader) the first time a pass uses them. A component can
therefore be built before the GPU backend is ready, and many components can share one mesh, which
also lets them share instanced draws.

`Resource.dispose()` drops the GPU object; it is created again if the resource is used afterwards.
Flutter GPU has no call that frees GPU memory at once: the memory is released when the dropped
object is garbage collected. Dispose the resources of a level you leave, and do not dispose
resources that are still drawn. `GpuResourceManager3D` adds reference counting and a memory budget
on top (see [Scenes and Assets](scenes_and_assets.md)).

Images returned by `renderToImage` belong to the caller, who must `dispose()` them. A
`RenderTexture3D` is disposed with `dispose()`. A `Scene3DComponent` releases its retained image
and render targets when it is removed. Render targets and post-processing textures used by passes
are pooled by the device and released after `GraphicsDevice.targetRetainFrames` (30) frames without
use.


## Hosts

A `World3D` renders with the device and render context of its host, the nearest ancestor that
implements `Scene3DHost`: a `Scene3DComponent`, or the `Game3D` game whose camera looks at it. A
host provides:

- `device`, the `GraphicsDevice` that records and submits GPU commands;
- `context`, the `RenderContext3D` that records, sorts and batches the draws;
- `msaaSampleCount` (`1` or `4`) and `pixelRatio`, the device pixels per logical pixel.

`World3D.host` returns it, and throws a `StateError` for a world with no host (one that is not in a
game, or a `World3D` added directly to a 2D world without a `Scene3DComponent`).

In a `Game3D` game, the world and all its `Scene3DComponent`s share the game's device and context.
In other games, the layers of a game share a device of their own, created on first use; its device
frame opens with the first pass of a Flutter frame and closes after the frame is painted.
`World3D.renderToImage` and `RenderTexture3D.renderWorld` render with a temporary host, so they also
work for a world that is not in a game; the `LightComponent`s of such a world, which only register
when mounted, are gathered from its tree for the render (see
[Embedding 3D in a 2D Game](embedding.md)).
