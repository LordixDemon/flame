# Models and Animation

A **model** is a hierarchy of nodes loaded from a file: each node has a local transform, may carry a
mesh, and may skin that mesh to other nodes (its joints). A model also holds keyframed animation
clips. `ModelComponent` puts a model in the world and plays its clips; on top of plain playback
`flame_3d` has crossfades, blend spaces, a state machine, masked layers, retargeting between
humanoid rigs, root motion, procedural bone modifiers (inverse kinematics, look-at, spring bones,
ragdolls), crowds and attachment sockets. This page describes all of them, what they cost, and what
they do not do. Surfaces, meshes and ray casting are described in
[Geometry and Scene Queries](geometry.md).


## Loading models


### Formats and loaders

| Call                                             | Formats      | Notes                         |
|--------------------------------------------------|--------------|-------------------------------|
| `ModelParser.parse(path)`                        | `.gltf`,     | picks the parser by extension |
|                                                  | `.glb`,      |                               |
|                                                  | `.obj`       |                               |
| `ModelParser.glb.parseModelBytes(bytes)`         | GLB bytes    | from memory                   |
| `ModelParser.gltf.parseGltfJson(json)`           | glTF JSON    | from memory, `data:` buffers  |
|                                                  |              | or `chunks`                   |
| `AsyncModelLoader3D.loadGlbAssetAsync(path)`     | `.glb`       | parses on a background        |
|                                                  |              | isolate                       |
| `AsyncModelLoader3D.parseObjBytesAsync(bytes)`   | `.obj`       | parses on a background        |
|                                                  |              | isolate                       |
| `SceneLoader3D.loadAsset(path)`                  | glTF, GLB    | a whole scene as components,  |
|                                                  |              | see below                     |

Paths are full asset paths, as declared in `pubspec.yaml`, read through `Flame.assets`:

```dart
final model = await ModelParser.parse('assets/models/knight.glb');
final knight = ModelComponent(model: model, position: Vector3(0, 0, 2))
  ..playAnimationByName('Idle');
world.add(knight);
```

`Flame.assets` caches every file it reads, so the bytes of a `.glb` stay in memory after parsing;
call `Flame.assets.clear(path)` once the model is built if you do not need them again. Parsing
creates the textures and the materials; the GPU buffers of the surfaces are created when they are
first drawn.

`SceneLoader3D` loads a glTF scene as ready-made components (meshes, models, lights from
`KHR_lights_punctual`, instanced groups from `EXT_mesh_gpu_instancing`, callbacks for node
`extras`); it is described in [Scenes and Assets](scenes_and_assets.md). The rest of this page
uses `Model` and `ModelComponent`.


### What the glTF reader reads

`ModelParser` (and `GltfParser` / `GlbParser`) builds the model from the default scene
(`scene`, or the first one) and reads:

- the node hierarchy, with `matrix` or `translation` / `rotation` / `scale`;
- triangle primitives (lists, and strips and fans converted to lists) with `POSITION`, `NORMAL`
  (computed, smooth, when absent), `TEXCOORD_0`, `COLOR_0` (`VEC3` or `VEC4`), `JOINTS_0` /
  `WEIGHTS_0` and `JOINTS_1` / `WEIGHTS_1`, indexed or not, into `VertexLayout.standard`
  surfaces; 16-bit or 32-bit indices as needed. A vertex keeps its 4 largest joint influences,
  with the weights renormalized to a sum of 1;
- every accessor component type, including normalized integers, so quantized data
  (`KHR_mesh_quantization`) is read; interleaved buffer views (`byteStride`); sparse accessors
  (applied over their buffer view, or over zeros for accessors without one, as Blender writes
  shape keys);
- skins: joints and inverse bind matrices; primitives skinned by more than 64 joints are split into
  surfaces of at most 64 joints each (see [Skinning](#skinning));
- morph targets with `POSITION` and `NORMAL` deltas, and the initial `weights` of the node (or of
  the mesh when the node has none);
- animations of `translation`, `rotation`, `scale` and `weights`, with `LINEAR`, `STEP` and
  `CUBICSPLINE` interpolation (with the file's tangents); channels with other targets (the
  `pointer` of `KHR_animation_pointer`) are skipped;
- materials as `SpatialMaterial`: base color factor and texture, metallic and roughness factors and
  texture, normal texture and scale, occlusion texture and strength, emissive factor and texture,
  `alphaMode` (`MASK` sets `alphaCutoff`, `BLEND` makes it translucent), `doubleSided` (otherwise
  back faces are culled), `KHR_materials_emissive_strength`, the offset and scale of
  `KHR_texture_transform` on the base color texture (applied to every texture), and
  `KHR_materials_unlit` (an `UnlitMaterial` with the base color and texture; `doubleSided` decides
  the culling, and `MASK` is drawn blended because `UnlitMaterial` has no alpha cutoff);
- samplers (filters and wrap modes); images from the GLB binary chunk, `data:` URIs or files next to
  a `.gltf`, decoded with Flutter's image codecs (PNG, JPEG, and WebP where the platform decodes
  it);
- `EXT_meshopt_compression` buffer views (files written by gltfpack or other meshoptimizer-based
  tools), through `MeshoptDecoder3D`, see [Meshopt compression](#meshopt-compression).

A primitive without a material gets a magenta `SpatialMaterial`. Each primitive gets its own
material instance, even when several primitives use the same glTF material, so they do not batch
together; and a mesh used by several nodes is built once per node.


### What it ignores or rejects

Ignored, and reported once per message in debug builds through `GltfWarnings` (to `debugPrint`, or
to `GltfWarnings.onWarning` when set; `AsyncModelLoader3D` reports the same messages):

- primitive attributes other than those above, such as `TANGENT` (call `Surface.computeTangents()`
  on the surfaces, see [Geometry and Scene Queries](geometry.md#tangents-and-the-second-uv-set)),
  `TEXCOORD_1` and `COLOR_1`; attributes starting with `_` (application data) are ignored without
  a message;
- primitives of mode points, lines, line loop and line strip (skipped);
- the `texCoord` index of texture slots (every texture reads the first UV set), the rotation and
  `texCoord` of `KHR_texture_transform`, and transforms that differ between the textures of one
  material;
- the cutoff of unlit `MASK` materials (drawn blended);
- extensions listed in `extensionsUsed` other than those read (`EXT_meshopt_compression`,
  `KHR_mesh_quantization`, `KHR_materials_unlit`, `KHR_materials_emissive_strength`,
  `KHR_texture_transform`, and `KHR_lights_punctual` and `EXT_mesh_gpu_instancing`, which
  `SceneLoader3D` reads), whether or not they are in `extensionsRequired`;
- animation channels that do not target node transforms or weights.

Ignored without a message: cameras (read by `SceneLoader3D`), the skin's `skeleton`, and nodes that
are not in the loaded scene.

Rejected with an exception: textures without a `source` (for example images given only through
`KHR_texture_basisu` or `EXT_texture_webp` without a fallback).

`GltfRoot.meshes[i].toFlameMesh(transform)` bakes a transform into the surfaces: positions by the
transform, normals by its inverse transpose, morph deltas by its linear part.

External files of a `.gltf` (`.bin` buffers, images) are read through `Flame.assets` from the
directory of the `.gltf`: the `uri` is percent-decoded and `.` and `..` segments are resolved, so
`textures/wood%20grain.png` next to `assets/models/house.gltf` is read as
`assets/models/textures/wood grain.png`. Declare those files as assets too.
`GltfRoot.resolveUri(directory, uri)` gives the key that is read.


### Meshopt compression

`MeshoptDecoder3D` decodes the bitstreams of `EXT_meshopt_compression` the way meshoptimizer does,
and is tested against meshoptimizer's reference streams:

- `ATTRIBUTES`: vertex codec version 0 (`0xA0`, the version the extension requires) and version 1
  (`0xA1`, which newer meshoptimizer releases write on request);
- `TRIANGLES`: index codec versions 0 and 1 (`0xE0`, `0xE1`); `INDICES` (`0xD1`);
- the `OCTAHEDRAL`, `QUATERNION` and `EXPONENTIAL` filters, computed in 32-bit floats like the
  reference.

A truncated or malformed stream, a stream with bytes left over, a codec version newer than these,
or a buffer view that breaks the extension's rules (a filter on index data, a stride a filter does
not allow) throws a `FormatException` instead of producing wrong geometry. `ModelParser` decodes
on the main isolate while the model is parsed; `AsyncModelLoader3D` decodes on its isolate.

The class also has encoders (`encodeVertexStream`, `encodeIndexStream`, `encodeFilterOct`,
`encodeFilterQuat`, `encodeFilterExp`) that write streams meshoptimizer decodes; they are handy in
tests and for small procedural assets, but do not optimize vertex order or quantize like gltfpack.


### OBJ files

`ModelParser.parse('...obj')` reads positions, normals and texture coordinates, faces of any
number of corners (triangulated as fans, so convex polygons only), positive and negative
(relative) indices, `mtllib` / `usemtl` with the diffuse color `Kd` of each material, and builds
one surface per material; tokens may be separated by any whitespace. Normals missing from the file
are computed. `ObjParser.parseObjString(source, directory: ...)` reads OBJ text from memory. Texture
coordinates are taken as they are written: OBJ puts `v = 0` at the bottom of the image, so flip
them in the exporter if your textures come out upside down. Other OBJ statements (groups, smoothing
groups, lines, points) are ignored.

`AsyncModelLoader3D.parseObjBytesAsync` and `parseObjStringInIsolate` use their own reader, with
the same rules, on a background isolate; it takes the contents of material libraries in
`mtlSources` (by file name).


### Loading off the main isolate

`AsyncModelLoader3D` parses `.glb` and `.obj` data inside `Isolate.run` and transfers the packed
vertex and index buffers back without copying (`TransferableTypedData`); images are decoded and
uploaded on the main isolate afterwards:

```dart
final scope = AssetScope3D();
final model = await AsyncModelLoader3D.loadGlbAssetAsync(
  'assets/models/knight.glb',
  buildBvhs: false, // see below
  scope: scope,
);
world.add(ModelComponent(model: model));

// Later, when the level is unloaded:
scope.release(model); // disposes its surfaces and textures
```

Its GLB reader is separate from `ModelParser`'s: buffers and images must be inside the GLB or in
`data:` URIs (external URIs throw `UnsupportedError`; a buffer without URI is only allowed as the
data-less fallback of `EXT_meshopt_compression`). It decodes `EXT_meshopt_compression` and sparse
accessors like `ModelParser`, shares one material per glTF material (so primitives with the same
material batch), and builds the same surfaces, skins, morph targets and animations.

With `buildBvhs: true` (the default) every surface's ray-casting BVH is built on a second
background isolate before the model is returned; the vertex and index data are copied to it. Pass
`false` when you do not ray cast against the model. `buildSurfaceBvhsInIsolate(model)` does the same
for any model: each surface adopts the hierarchy built on the isolate (`Surface.adoptBvh`,
`SurfaceBvh.fromPrepared`), and the payloads are also returned as `PreparedSurfaceBvh3D`s. A surface
whose vertices change later (morph targets) drops its BVH, and the next ray rebuilds it on the main
isolate.

What stays on the main isolate: decoding images and creating textures and materials, creating the
`Surface` objects from the transferred buffers, and the GPU uploads on first draw.

`AssetScope3D` reference-counts models, meshes, surfaces and textures: `retain` increments,
`release` decrements and, at zero, disposes the surfaces and the textures of their
`SpatialMaterial`s and `UnlitMaterial`s that no other retained asset uses; `disposeAll` disposes
everything it tracks. Asset lifetimes and streaming are described in
[Scenes and Assets](scenes_and_assets.md).


### Models and nodes

A `Model` has `nodes` (a map from node index to `ModelNode`) and `animations` (a list of
`ModelAnimation`). A `ModelNode` has a `name`, its `parentNodeIndex`, its rest `transform`, an
optional `mesh` and the `joints` that skin it. `Model.simple(mesh: mesh)` wraps a single mesh. You
can also build models in code from `ModelNode`s, which is how procedural rigs are made.

`Model.aabb` is the rest pose bounds; `Model.animatedAabb`, which `ModelComponent` uses for culling,
adds the poses of every clip sampled at 9 evenly spaced times (start, end and 7 in between), with
skinned surfaces expanded through each joint matrix. It is computed the first time it is needed,
which evaluates every clip 9 times: a one-time cost for models with many clips. Poses between the
samples, morph targets, layers and bone modifiers are not included, so an object can be culled a
little early in extreme poses.


## ModelComponent

`ModelComponent(model: ...)` evaluates the model's pose from its `animationState` and draws each
node's mesh with the node's transform. Besides the usual `position`, `rotation`, `scale`,
`children` and `castsShadows`, it takes:

- `color` and `instanceData`, per-instance values passed to the materials of every surface, see
  [Rendering](rendering.md);
- `offscreenPolicy`, see below;
- `rootMotion`, `stateMachine` and `onAnimationEvent`, described further down.

`hideNodeByName(name)` stops drawing one node (a weapon, a helmet); `hideNodeByName(name,
hidden: false)` shows it again. `nodeTransformByName(name)` and `nodeTransform(index)` return a
node's transform in the model's space for the current pose (evaluating it if needed).

Components that share a `Model` share its meshes and surfaces. Each component has its own pose,
skinning matrices and morph weights: the first time morph weights reach a node, the component makes
its own copy of that node's morphed surfaces (vertices and GPU buffer; indices, materials and the
morph targets stay shared) and draws and ray casts that copy from then on. `nodeMesh(index)`
returns the mesh a component draws for a node.


### Offscreen policy

`offscreenPolicy` (an `OffscreenAnimationPolicy`) decides what an animated component does while it
is not drawn:

- `always` (the default) evaluates the pose in `update` whenever the animation changed.
- `tickOnlyEvaluateWhenVisible` advances clocks and fires events in `update`, but evaluates the pose
  only when something needs it: `draw`, `nodeTransform`, a `BoneSocket3D` child or a ray cast.
- `pauseWhenOffscreen` does not advance the clocks unless the component was drawn since the last
  update. A shadow pass counts as a draw.

A `BoneSocket3D` child asks for its bone every update, so with `tickOnlyEvaluateWhenVisible` it
makes the pose evaluate every frame anyway.


## Skinning


### Joint limits

- Each vertex is influenced by at most 4 joints (`vertexJoints`, `vertexWeights`).
- Each draw (each surface) can use at most 64 joint matrices. The renderer throws a `StateError`
  when a draw is given more.
- A model's skeleton may have any number of joints: `ModelParser` and `AsyncModelLoader3D` split
  every primitive whose vertices use more than 64 joints into several surfaces, each with at most 64
  joints and its own joint palette (`Surface.jointMap`, from the skin's joint index to the
  surface's).

All built-in skinned shaders (`SpatialMaterial`, `UnlitMaterial`, `StylizedMaterial` for both the
standard layout and its own skinned layout, the outline, shadow-caster and depth-prepass shaders,
and the WebGPU bundles of `SpatialMaterial` and `UnlitMaterial`) declare the same 64-matrix block
from `flame_3d/skinning.glsl`.


### How joints reach the shader

For each node with a skinned mesh, `ModelComponent` computes, for every joint of each surface, the
joint node's transform in the model's space times its inverse bind matrix, and passes the lists to
`RenderContext3D.drawMesh` by surface index. The context uploads them into the `JointMatrices`
uniform block of that draw. In the vertex shader, `computeSkinMatrix()` blends the four matrices of
the vertex by its weights (a vertex whose weights are all zero is not moved), the result is applied
to the position and the normal, and then the instance's model matrix.

As glTF requires, the transform of the node that carries a skinned mesh does not move the mesh:
only the joints do. The mesh is drawn with the node's transform like any other node, so the joint
matrices in `ProcessedNode.jointTransforms` are stored relative to that node
(`inverse(nodeTransform) * jointTransform * inverseBindMatrix`); multiplied by the node's transform
they give the joint's skinning matrix in the model's space. A skinned mesh under a scaled or
rotated armature node (common in Blender and Mixamo exports) therefore lands where other glTF
viewers put it. Only when the node's own transform is singular (a zero scale) do the matrices stay
in the model's space, and the mesh collapses with the node.

Your own skinned surfaces use the same path: give a `Surface` joint indices and weights (in the
standard layout, or `StylizedMaterial.buildSurface` for its skinned layout) and pass the matrices to
`MeshComponent.jointTransforms` (a map from surface index to matrices) or to
`RenderContext3D.drawSurface(jointTransforms: ...)` in a custom component. Joint indices are indices
into the list you pass.

Skinned draws are never batched: every skinned surface of every component costs one draw call and
one upload of `64 * joints` bytes in each pass it is drawn in (the shadow pass, the depth prepass
when enabled, and the main pass). Shadows of skinned surfaces follow the animation.


## Morph targets

The glTF reader stores morph targets in the surfaces (`Surface.morphTargets`) and applies the mesh's
default weights once. Animated `weights` channels are applied by `ModelComponent` whenever it
evaluates the pose, across crossfades, blend spaces and layers. To set weights yourself:

```dart
face.setMorphWeights([0.7, 0.0, 0.2]); // every morphed surface of the model
face.setMorphWeights([1.0], nodeName: 'Eyes'); // only the surfaces of one node
```

Morphing runs on the CPU and re-uploads the vertex buffer of each morphed surface, see
[Geometry and Scene Queries](geometry.md#morph-targets) for the cost; it is skipped when a node's
weights did not change. Each component morphs its own copy of the surfaces (see above), so
components of one model animate their faces independently, at the memory cost of one vertex buffer
per morphed surface and component. Weights are not reset when an animation stops. Removing the
component releases the GPU buffers of its copies.


## Playing clips


### Play, stop and speed

```dart
knight.playAnimationByName(
  'Attack',
  mode: AnimationPlayMode.once,
  onComplete: () => knight.crossFadeToByName('Idle'),
);
knight.animationState.speed = 1.5; // 0 pauses, negative plays backwards
```

`playAnimationByName` and `playAnimationByIndex` start a clip at once (`resetClock: false` keeps the
current clock); an unknown name throws an `ArgumentError`. `stopAnimation()` returns to the rest
pose. `animationNames` lists the clips. `AnimationPlayMode` is `loop` (the default), `once`
(stops on the last frame, sets `animationState.isCompleted` and calls `onComplete`) or `pingPong`.

Each channel is sampled by binary search over its keyframes: linear interpolation for translations
and scales, shortest-arc spherical interpolation for rotations, `STEP` holds the previous key, and
`CUBICSPLINE` uses the Hermite tangents of the file (or a smoothstep between keys when a spline has
no tangents). Before its first key and after its last, a channel holds the nearest key. A clip's
length is the time of its last key or event.


### Crossfades

`crossFadeToByName(name, duration: 0.25)` (and `crossFadeToByIndex`) blends from the current clip to
the new one: during `duration` seconds both clips advance, and each node's translation, rotation and
scale are interpolated from the outgoing pose to the incoming one by the fade's progress
(`animationState.crossFadeProgress`). It is a real blend, not a switch. The fade's progress uses
real time, not the playback speed. Crossfading to the clip that is already playing starts it
without a fade unless `allowSelfTransition` is passed to `AnimationState.crossFadeTo`.

The outgoing side of a crossfade is whatever was playing when it started: a clip, a blend space
with all its samples (at the blend values it had then), or a crossfade still running, which keeps
advancing and blending underneath the new one. Starting a crossfade therefore never moves the pose,
however quickly transitions follow each other (`crossFadeToBlendSpace1D` and
`crossFadeToBlendSpace2D` behave the same). Up to `AnimationState.maxNestedCrossFades` (4) running
fades are nested; a fifth interruption completes the oldest at once, which moves the pose by that
fade's remaining weight, usually small. Morph weights fade the same way. The outgoing side fires no
events and calls no `onComplete`.


### Animation events

A `ModelAnimation` can carry timed `AnimationEvent3D`s (a `name`, a `time` in seconds and an
optional `payload`). The glTF reader does not create any; add them by wrapping a loaded clip:

```dart
final walk = model.animations.firstWhere((clip) => clip.name == 'Walk');
final walkWithSteps = ModelAnimation(
  name: walk.name,
  nodes: walk.nodes,
  events: [
    AnimationEvent3D(name: 'step', time: 0.12, payload: 'left'),
    AnimationEvent3D(name: 'step', time: 0.62, payload: 'right'),
  ],
);
final hero = ModelComponent(
  model: model,
  onAnimationEvent: (event) => playFootstep(event.payload),
)..animationState.startAnimation(walkWithSteps);
```

Every event crossed during an update fires once, in order, including across loop wraps, ping-pong
turns and several wraps in one long update (up to 64 per update). Events of masked layers fire too.
In a blend space, the events of the dominant clip (the one with the largest weight) fire, with or
without `syncNormalizedPhase`.


## Blend spaces

A `BlendSpace1D` places clips along one parameter, such as speed, and blends the two neighbours of
the current value; a `BlendSpace2D` places clips at 2D points, such as a strafe direction, and
blends up to four of them with gradient-band weights that sum to 1:

```dart
ModelAnimation clip(String name) =>
    model.animations.firstWhere((c) => c.name == name);

final locomotion = BlendSpace1D(samples: [
  BlendSample1D(animation: clip('Idle'), position: 0),
  BlendSample1D(animation: clip('Walk'), position: 1.5),
  BlendSample1D(animation: clip('Run'), position: 5),
]);
hero.playBlendSpace1D(locomotion);

// Every frame:
hero.blendParameter1D = velocity.length;
```

With `syncNormalizedPhase: true` (the default), all clips share one normalized cycle whose length is
interpolated between the blended clips, so footfalls stay aligned while walking blends into
running; the playback rate of each sample can be tuned with `speed`. With `false`, each clip runs on
its own clock, and the dominant clip gives the state's clock, normalized phase and loop count. The
blend interpolates translations and scales linearly and rotations spherically,
and blends morph weights too. Values outside the range of the samples clamp to the first or last
sample. `playBlendSpace2D(space)` and `blendParameter2D` work the same way with `BlendSample2D`
(`point`).


## State machine

`AnimationStateMachine3D` drives an `AnimationState` from named parameters, like the animator
controllers of other engines. Its states are clips (`ClipAnimState3D`), blend spaces
(`Blend1DAnimState3D` reading a float parameter, `Blend2DAnimState3D` reading two) and nested
machines (`SubStateMachine3D`); transitions fire on conditions and an optional exit time and
crossfade into the target:

```dart
final machine = AnimationStateMachine3D(
  initialState: 'move',
  states: [
    Blend1DAnimState3D(name: 'move', space: locomotion, parameter: 'speed'),
    ClipAnimState3D(
      name: 'jump',
      animation: clip('Jump'),
      playMode: AnimationPlayMode.once,
    ),
  ],
  transitions: [
    AnimTransition3D(
      fromState: AnimTransition3D.anyState,
      toState: 'jump',
      conditions: const [AnimCondition3D.onTrigger('jump')],
      crossFadeDuration: 0.1,
    ),
    AnimTransition3D(fromState: 'jump', toState: 'move', exitTime: 1.0),
  ],
);
final hero = ModelComponent(model: model, stateMachine: machine);

// From game code:
machine.setFloat('speed', velocity.length);
if (jumpPressed) {
  machine.setTrigger('jump');
}
```

How it evaluates, every `update`:

1. Continuous parameters (blend values, speeds) are copied into the animation state, and its clocks
   advance.
2. Transitions are checked: `anyState` transitions of the root, then of the active nested machines,
   then the transitions from the active state, from the innermost machine outwards. The first one
   whose conditions all hold and whose `exitTime` has passed fires; up to 8 transitions can chain in
   one update, unless a transition has an exit time or allows self-transitions.
3. Firing crossfades into the target state over `crossFadeDuration` (`0.2` seconds by default) and
   consumes the `onTrigger` conditions it used. Entering a `SubStateMachine3D` enters its
   `initialState`; a target can also be a path such as `'combat/slash'`.

Conditions are `greater`, `less`, `equals`, `notEquals` (on float or int parameters, `1e-6`
tolerance), `ifTrue`, `ifFalse` (bool parameters) and `onTrigger`. Unset parameters read as 0 or
false. A transition with neither conditions nor `exitTime` never fires. `exitTime` is in normalized
time of the current state: `1.0` is the end of the first cycle, `2.5` halfway through the third.
In blend-space states whose space has `syncNormalizedPhase: false`, the normalized time is that of
the dominant clip.
`syncNormalizedPhase: true` on a transition, or the same `syncGroup` on both states, carries the
normalized phase into the next state, so a walk cycle continues in the run cycle. `forceState(name)`
jumps to a state from code. `currentStateName`, `activeStatePath`, `stateElapsed` and
`transitionCount` help debugging.

Transitions crossfade as described in [Crossfades](#crossfades), so quick consecutive transitions
blend without popping.


## Layers and masks

`addOverlayLayer(boneNames: {...})` adds an `AnimationLayer3D` that plays its own clip on a subset
of nodes, over the base animation: an upper-body wave over a walk. The mask is the named nodes and,
by default, all their descendants:

```dart
final upperBody = hero.addOverlayLayer(boneNames: {'Spine'});
upperBody.state.startAnimation(clip('Wave'), mode: AnimationPlayMode.once);
// Fade it out later:
upperBody.weight = 0;
```

A layer replaces the base pose of its nodes by its own, interpolated by `weight` (`0` to `1`);
layers apply in the order they were added. Layers are override layers only: there is no additive
mode. Their `state` is a full `AnimationState`, so a layer can crossfade or play blend spaces, and
its events reach `onAnimationEvent`. A layer whose state has nothing playing leaves its nodes alone.


## Retargeting

`AnimationRetargeter3D.retargetClip` converts a clip made for one humanoid rig so it plays on
another, through `HumanoidProfile3D`s that map 22 standard bones (`HumanoidBone3D`: hips, spine,
chest, upper chest, neck, head, and shoulder, upper arm, lower arm, hand, upper leg, lower leg, foot
and toes on each side) to nodes:

```dart
final source = HumanoidProfile3D.autoDetect(animationLibrary);
final target = HumanoidProfile3D.autoDetect(model);
final run = AnimationRetargeter3D.retargetClip(
  animationLibrary.animations.firstWhere((c) => c.name == 'Run'),
  sourceProfile: source,
  targetProfile: target,
);
hero.animationState.startAnimation(run);
```

`autoDetect` recognizes Mixamo (`mixamorig:`), VRM (`J_Bip_`), Rigify (`DEF-`) and common
Unity/Unreal/glTF names; `HumanoidProfile3D.fromBoneNames` maps the bones explicitly. Each mapped
bone's rotation is converted as a change from its rest pose, expressed in the rig's space, and
re-expressed against the target bone's rest orientation. Translation channels are converted the same
way and scaled by the ratio of the rigs' hip heights (`hipsRestHeight`, measured along `+y` in the
rest pose, or given). The rest pose is the node transforms of the file.

The result is a new `ModelAnimation`, made once; playing it costs the same as any clip. Bones that
are not among the 22 (fingers, twist bones, tails) are not animated by the converted clip. Because
rotations are applied as changes from the rest pose, both rigs need the same kind of rest pose (both
T-pose or both A-pose); otherwise the difference stays in every frame.


## Root motion

A `RootMotionExtractor3D` measures how a root node (by `rootNodeName` or `rootNodeIndex`; the first
node otherwise) moves and turns each update, and by default keeps it in place on the visible
skeleton, so the clip's own travel can move the component instead:

```dart
final hero = ModelComponent(
  model: model,
  rootMotion: RootMotionExtractor3D(
    rootNodeName: 'Hips',
    applyToComponentTransform: true, // move and turn the component
  ),
);
```

After each update, `deltaPositionLocal` (model space), `deltaPositionWorld` (rotated and scaled by
the component's world transform) and `deltaYawRad` (around `+y`, or `+z` with
`horizontalPlane: RootMotionPlane3D.xy`) hold that update's motion; loop wraps are accounted for, so
the motion does not jump back at the end of a cycle. With `applyToComponentTransform: false` (the
default) read the deltas and move the character yourself, for example through a kinematic character
controller. `lockHorizontalInPlace` (default `true`) and `lockVerticalInPlace` (default `false`)
choose which translation axes are removed from the visible pose; the root's rotation is never
removed, so applying `deltaYawRad` to the component as well turns the character twice for clips that
turn.

`applyToComponentTransform` adds the world-space delta to `position`, which is only right when the
component's parent does not rotate or scale it.


## Procedural bone modifiers

`ModelComponent.boneModifiers` holds `BoneModifier3D`s that change the pose after the animation is
evaluated and before the joint matrices are computed. They run in list order, in the model's space
(world-space targets are converted with the component's inverse world transform), and each modifier
rotates bones and carries the change down to their descendants. Every modifier has a `weight` (`0`
disables it, values between blend it).

While at least one modifier has a weight above zero, the pose is evaluated every update, even when
no animation plays. All modifiers work on bone positions (the translations of the node transforms),
so they need the chain's nodes to be actual joints with distinct positions.


### Two-bone IK

`TwoBoneIkConstraint3D` places the tip of a three-node chain (shoulder, elbow, hand; hip, knee,
foot) on a world-space target, solving the middle joint with the law of cosines; the bend happens in
the plane towards `poleWorld`. The bones keep their lengths: for a target out of reach the chain
straightens and points at it.

```dart
final reach = TwoBoneIkConstraint3D(
  rootNodeName: 'UpperArm.R',
  midNodeName: 'LowerArm.R',
  tipNodeName: 'Hand.R',
  poleWorld: Vector3(0, 0, -1), // elbow bends backwards
);
hero.boneModifiers.add(reach);

// Every frame:
reach.targetWorld.setFrom(doorHandle.position);
```

The hand keeps its animated orientation relative to the forearm; only positions are solved.


### FABRIK chains

`FabrikIkConstraint3D` solves chains of any length (tails, tentacles, spines, cranes) toward
`targetPosition` (world space) with forward-and-backward reaching, up to `maxIterations` (`12`) or
until within `tolerance` (`1e-3`). `maxConeAngleRad`, or `jointMaxConeAnglesRad` per joint, limits
how far each joint bends from its parent segment. `FabrikIkConstraint3D.byNames(model:,
chainNodeNames: [...])` resolves names, root first.


### Look-at

`LookAtConstraint3D(nodeName:, targetWorld:)` turns one bone so its `forwardAxis` (bone-local,
`+z` by default) points at the target, by at most `maxAngle` radians (`1.25`) from its animated
direction. Use it for heads, eyes and turrets.


### Spring bones

`SpringBone3D(nodeName:)` gives one bone secondary motion: a tip at `localTipOffset` (bone-local,
`(0, 0.5, 0)` by default) is pulled back to its animated position by a spring of `stiffness` (`180`)
with `damping` (`14`) and a constant world `gravity` (zero by default), keeps its distance to the
bone, and the bone swings towards it by at most `maxAngle` radians (`0.85`). The step is clamped to
0.05 seconds. Each spring bone is independent: for a chain (a ponytail) add one per bone, parent
first. `reset()` snaps the tip back to rest, which you need after teleporting the character.


### Foot placement

`FootPlacementIk3D` adapts both legs of a biped to uneven ground: it casts a ray down from above
each animated foot through your `groundQuery`, lowers the hips (smoothly, by at most `maxHipsDrop`,
`0.5`) so the lower foot can reach, solves both knees with two-bone IK towards `kneeForwardModel`,
and tilts each foot to the ground normal by at most `maxFootTiltRad` (`0.75`):

```dart
final feet = FootPlacementIk3D.fromHumanoid(
  HumanoidProfile3D.autoDetect(model),
  groundQuery: (origin, maxDistance) {
    final hit = world.raycast(
      Ray.originDirection(origin, Vector3(0, -1, 0)),
      maxDistance: maxDistance,
      filter: (object) => object != hero, // do not hit the character
    );
    return hit == null
        ? null
        : GroundHit3D(point: hit.worldPoint, normal: hit.worldNormal);
  },
);
hero.boneModifiers.add(feet);
```

It assumes world `+y` is up. Feet the clip lifts above the component's origin keep their lift
(steps of a walk). `rayOriginHeight` (`0.6`) and `rayMaxDistance` (`1.5`) bound the rays,
`footHeightOffset` (`0`) is the ankle height above the ground, `pelvisSmoothing` (`14`) the rate
of the hip motion. Two rays per update, through whatever `groundQuery` does.


## Ragdolls

`RagdollController3D` builds a ragdoll for a `ModelComponent` in a `PhysicsWorld3D` (see
[Collisions and Physics](physics.md)): a capsule rigid body per bone, connected to the nearest
parent bone's body by a ball-socket joint, or a hinge for bones whose names contain `calf`, `shin`,
`lowerleg`, `forearm`, `lowerarm`, `knee` or `elbow`. It adds itself to the component's
`boneModifiers`:

```dart
final ragdoll = RagdollController3D(
  modelComponent: hero,
  physicsWorld: physics,
  boneConfigs: [
    RagdollBoneConfig3D(nodeIndex: hips, mass: 6, radius: 0.15),
    RagdollBoneConfig3D(nodeIndex: spine, mass: 5, radius: 0.14),
    RagdollBoneConfig3D(
      nodeIndex: leftCalf,
      jointType: RagdollJointType3D.hinge,
      minAngle: 0,
      maxAngle: 2.4,
    ),
    // ...
  ],
);

// On a hit:
ragdoll.activateRagdoll(impulse: Vector3(0, 2, -6), hitBoneNodeIndex: spine);
// When getting up:
ragdoll.recoverToAnimation(blendDuration: 0.8);
```

The controller has three modes (`RagdollMode3D`):

- `kinematicFollow`: the bodies are kinematic and follow the animated bones every update, with
  velocities taken from their motion, so they push other bodies and carry momentum into the fall.
- `ragdoll` (after `activateRagdoll`): the bodies are dynamic and the bones follow them; an optional
  impulse goes to the hit bone's body (or the first body).
- `recoveringToAnimation` (after `recoverToAnimation`): the bodies become kinematic again and every
  bone blends from its last ragdoll pose to the animated pose with a smoothstep over
  `blendDuration` (`0.45` seconds by default), then the controller returns to `kinematicFollow`.

Without `boneConfigs`, nearly every node of the model gets a body (all but childless root nodes and
childless skinned-mesh nodes), which for a full rig with fingers and twist bones means dozens of
capsules: list the bones you want. The bodies use `collisionLayer` `2` and collide with everything
(`collisionMask`). The component itself does not move: after a fall, recovery blends the character
back to where the component is. Move the component to the ragdoll's hips yourself before recovering
if it should get up where it fell. `dispose()` removes the bodies, the joints and the modifier.


## Crowds

`SkinnedCrowdBatch3D` draws many copies of one animated model with little CPU work. When it is
created, it samples every clip at `bakedFps` (`30`) and stores, for every frame, the transform of
each node with a mesh and the joint matrices of each skinned surface. At run time each agent is a
clock, a speed, a play mode, a clip index, a transform and a color:

```dart
final crowd = SkinnedCrowdBatch3D(model: villager);
world.add(crowd);
for (var i = 0; i < 80; i++) {
  crowd.addAgent(
    position: Vector3(i % 10 * 1.5, 0, i ~/ 10 * 1.5),
    clipName: 'Walk',
    initialClock: i * 0.13,
    speed: 0.9 + (i % 5) * 0.05,
  );
}
crowd.setAgent(3, clipName: 'Wave', clock: 0);
```

- The update advances each agent's clock and picks the baked frame: `O(agents)` arithmetic, no pose
  evaluation. Frames are not interpolated, so motion steps at `bakedFps`.
- Nodes without skinning are drawn as one instanced draw per surface for all agents.
- Skinned surfaces are drawn once per agent, each with its baked joint matrices: 80 skinned agents
  cost 80 draw calls per skinned surface and pass. The savings are on the CPU, not in draw calls.
- Memory: one 4x4 matrix (16 doubles) per node with a mesh and per joint, for every baked frame of
  every clip.

Agents are removed with `removeAgentAtSwapLast` (the last agent takes the removed one's index) or
`clear`. Morph targets, crossfades, layers and bone modifiers are not supported in crowds.


## Bone sockets

A `BoneSocket3D` is a `Component3D` that copies the transform of a node of its parent
`ModelComponent` every update; its children follow the bone:

```dart
hero.add(
  BoneSocket3D.byName('Hand.R', children: [
    MeshComponent(mesh: swordMesh, position: Vector3(0, 0.1, 0)),
  ]),
);
```

Add sockets as direct children of the `ModelComponent`: the socket takes the bone's transform in the
model's space, which is only right when the socket's parent is the model component. The node's
transform includes its scale.


## Costs

Per animated `ModelComponent` and frame:

- Pose evaluation, when the animation changed: every node is sampled (a binary search per channel)
  and composed with its parent, then every joint matrix is computed. For a 2D blend space the
  sample weights are recomputed for every node (`O(samples^2)` each). Evaluation, the bone
  modifiers and ragdolls use preallocated scratch objects. Starting a crossfade from a running one
  or from a blend space takes a pooled state (no allocation once the pool is warm).
- Morph targets: CPU morphing and a vertex buffer upload per morphed surface (see
  [Geometry and Scene Queries](geometry.md#morph-targets)).
- Draws: one draw call per surface; skinned surfaces are never batched, unskinned ones batch with
  other draws of the same surface and material.
- Scene invalidation: every update in which the pose changes marks the world's scene as changed,
  which defeats retained caching (see [Rendering](rendering.md)) while anything animates.

Loading: `ModelParser` decodes accessors into intermediate lists of vectors and decodes images on
the main isolate; `AsyncModelLoader3D` moves the geometry work to an isolate.


## Limitations

- **Meshopt**: `KHR_meshopt_compression` and its `COLOR` filter are not read.
- **Crossfades**: at most 4 nested interrupted fades; a fifth interruption completes the oldest.
- **Layers** override only; no additive layers.
- **glTF**: no second UV set, no tangents, at most 4 joint influences per vertex (the largest
  are kept), no points or lines, only `KHR_materials_unlit`, `KHR_materials_emissive_strength`,
  `KHR_texture_transform` (offset and scale) and `KHR_mesh_quantization` among material and mesh
  extensions; what is dropped is reported in debug builds (`GltfWarnings`).
- **OBJ**: fan triangulation (concave polygons come out wrong), only the diffuse color of
  materials.
- **Ray casts** hit skinned surfaces in their rest pose (see
  [Geometry and Scene Queries](geometry.md#limitations)).
- **Foot placement** assumes world `+y` up; **retargeting** measures the hip height along `+y`.
- **Root motion** does not remove the root's rotation from the pose.
