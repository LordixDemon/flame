# Scenes and Assets

This page covers building objects from reusable blueprints (prefabs), saving and loading scenes,
deciding when GPU buffers and textures are released, and loading complete glTF scenes. Prefabs,
the scene serializer and `GpuResourceManager3D` are exported by `package:flame_3d/scene.dart`;
`AssetScope3D` and `SceneLoader3D` by `package:flame_3d/parser.dart`.


## Prefabs

A prefab is a named way to build a `Component3D`. `PrefabRegistry3D` holds prefabs by id and
builds instances with optional overrides:

```dart
final prefabs = PrefabRegistry3D()
  ..registerBuilder(
    'crate',
    (overrides) => MeshComponent(
      mesh: crateMesh,
      scale: Vector3.all(overrides.prop<double>('size') ?? 1),
    ),
    defaultProps: const {'size': 1.0},
  )
  ..registerPrototype('lamp_post', lampPost);

world.addAll([
  prefabs.instantiate(
    'crate',
    PrefabOverrides3D(
      position: Vector3(2, 0, -3),
      color: const Color(0xFFC08040),
      tags: const {'loot'},
      customProps: const {'size': 1.5},
    ),
  ),
  prefabs.instantiate(
    'lamp_post',
    PrefabOverrides3D(position: Vector3(-4, 0, 0)),
  ),
]);
```

- `registerBuilder(id, builder, defaultProps:)` registers a function that builds a new instance;
  `registerPrototype(id, component)` registers a component that is cloned for every instance; both
  return the `Prefab3D`, and `register` adds one you built yourself. Registering an id twice throws
  a `StateError` unless `overwrite: true`; `instantiate` with an unknown id throws one too.
  `lookup`, `contains`, `ids`, `unregister` and `clear` manage the registry.
- `PrefabOverrides3D`: the builder receives `customProps` merged over the prefab's `defaultProps`
  (read them with `prop<T>(key)`, which returns `null` for a missing key or another type). After
  the builder runs, the instance gets `prefabId`, then `position`, `rotation`, `scale`, `visible`
  and `cameraMask` when given; `color` is applied only to a `MeshComponent` or a
  `LodMeshComponent`; `tags` are added to the instance's tags, or replace them with
  `replaceTags: true`.
- An instance keeps its `prefabId`, which the scene serializer uses to save a reference to the
  prefab instead of the component's content.


### What cloning copies

`registerPrototype` (and `Prefab3D.fromPrototype`) clone the prototype once when registered and
clone that copy for every instance, with `Component3D.clone()`. A clone copies the transform,
`visible`, `cameraMask`, `priority`, `prefabId`, the tags and, by default, the `Component3D`
children. What else is copied depends on the type:

- `Group3D`: nothing more;
- `MeshComponent`: the same `Mesh` (shared, not copied), its color, instance data, `castsShadows`
  and joint transforms;
- `LightComponent`: a copy of its light, shadow settings included;
- `LodMeshComponent`, `SkyboxComponent3D`, `Text3DComponent`: their settings;
- `InstancedGroup3D`: the mesh and every instance's transform, color and instance data;
- `ModelComponent`: the same `Model`, its color, instance data, `offscreenPolicy`,
  `onAnimationEvent`, `castsShadows` and hidden nodes; the copy starts in the rest pose with no
  animation playing. A model component with a `stateMachine`, `rootMotion` or `boneModifiers`
  cannot be cloned, as those are bound to its pose.

Any other type (`ParticleSystem3D`, the components of [Large Worlds](world_scale.md), custom
components) and any subclass of the types above throws an `UnsupportedError` naming the type,
instead of coming out as a different, emptier object: override `cloneSelf()` to copy the type's
state, or register a builder. Since `registerPrototype` clones the prototype right away, the error
shows when the prefab is registered. Children that are not `Component3D`s are not cloned.


## Saving and loading scenes

`SceneSerializer3D` writes the components of a `World3D` and some of its settings either as JSON
or in a binary format, and restores them into another world:

```dart
final serializer = SceneSerializer3D(prefabRegistry: prefabs)
  ..registerMesh('rock', rockMesh)
  ..registerTexture('grass', grassTexture);

final json = serializer.encodeJson(world, cameras: [camera]);
final bytes = serializer.encodeBinary(world, cameras: [camera]);

final restored = World3D();
final cameras = serializer.decodeBinaryInto(bytes, restored);
// or: serializer.decodeJsonInto(json, restored, clearTarget: true);
```

`toJson` and `fromJsonInto` work with the decoded map instead of a string. The decode methods
return the cameras of the snapshot: those passed in `cameras` when saving, plus the cameras that
were children of the world (those are added to the world as well).


### What is saved

- World settings: `renderScale`, `spatialIndex3DEnabled`, `prioritizeNearestLights`,
  `depthPrepassEnabled`, `hdrEnabled`, `oitMode`, `grabSceneColorEnabled`, `renderDebugMode3D`,
  `scaledFilterQuality`, `fog` and `bloom` (all fields), and `postProcess` (all fields but
  `colorLut`).
- For every `Component3D`: position, rotation, scale, `visible`, `cameraMask`, `priority`,
  `prefabId`, tags, and its children.
- Components with a registered prefab id, whatever their type: a reference to the prefab plus the
  fields above and, for a `MeshComponent` or `LodMeshComponent`, its color; their children are not
  saved (the prefab rebuilds them).
- `MeshComponent`: `castsShadows`, color, instance data and its mesh.
- `LodMeshComponent`: its levels (mesh, `maxDistance`, `minScreenHeightRatio`), `shadowMesh`,
  `lowestLodInShadowPass`, color, instance data and `castsShadows`.
- `InstancedGroup3D`: its mesh, `castsShadows`, and the transform, color and instance data of every
  instance.
- Meshes, as one of:
  - a key, when the mesh was registered with `registerMesh`;
  - the parameters of a built-in primitive (`CuboidMesh`, `SphereMesh`, `CylinderMesh`,
    `ConeMesh`, `PlaneMesh`, `CapsuleMesh`, `TorusMesh`, segment counts included) with its
    material, when rebuilding the primitive from them gives the same vertices and indices; a
    primitive changed after it was built is saved raw;
  - otherwise the raw vertex and index data of every surface, with its vertex layout, topology,
    index type, bounds, joint map and material.
- Materials, with `castsShadows` and the whole render state (stencil and polygon mode included):
  `SpatialMaterial`, `UnlitMaterial`, `StylizedMaterial` (matcaps and wind included) and
  `ShadowCatcherMaterial`, with all their values. Textures are saved as the key they were
  registered under with `registerTexture`.
- `LightComponent`: ambient, hemisphere, directional, point and spot lights, all with their shadow
  settings (cascade splits included), and the light mask.
- `CameraComponent3D`: projection, field of view, orthographic height, near and far planes,
  position, target, up, rotation, camera mask and custom matrices.
- Components handled by a registered codec (see below).

A mesh or a material used by several components (or surfaces) is written once and referenced
afterwards, so after loading they share one object again.


### What cannot be saved

The serializer does not guess. A save of a scene that holds something it cannot represent throws a
`SceneSerializationException3D` whose `issues` list every such item, each with its path in the
snapshot (`nodes[2].children[0]`, `nodes[1].mesh.surfaces[0].material.albedoTexture`) and what
to do about it:

- components of any other type without a codec or a registered prefab id (`ModelComponent`,
  particle systems, terrain, foliage, batches, decals, text, custom components), and children
  that are not `Component3D`s (effects, behaviors);
- subclasses of the built-in types (a `Line3D`, a `ThirdPersonCamera`, a subclass of a material):
  their own state and type would be lost;
- materials of other classes (`WaterMaterial`, `OutlineMaterial`, `DecalMaterial`, custom ones),
  light sources of other classes, unregistered textures, environment probes, the joint transforms
  of a `MeshComponent`, morph targets;
- a world's `lightProbeGrid`, custom passes, shadow group and post-processing `colorLut`.

`findIssues(world)` returns the same list without throwing. A serializer built with
`allowLossy: true` saves anyway: an unknown component becomes a `Group3D` with its transform, tags
and children, a subclass is saved as its built-in type, an unknown material as a default
`SpatialMaterial`, an unknown light as an `AmbientLight` of the same color and intensity, and the
other items are left out; `lastIssues` then lists what was lost.

Not saved in any case: animation state, the viewport of cameras, and anything that is not one of
the fields listed above.


### Assets and custom components

Register the meshes and textures your game loads from its own assets, so the snapshot stores keys
and loading reuses your objects: `registerMesh(key, mesh)`, `registerTexture(key, texture)`,
`lookupMesh`, `lookupTexture`. A snapshot that names a mesh or texture key the serializer does not
know fails to load.

Components of your own types are saved with a `SceneNodeCodec3D`:

```dart
serializer.registerNodeCodec<Beacon>(
  SceneNodeCodec3D<Beacon>(
    typeId: 'beacon',
    encode: (beacon) => {'code': beacon.code},
    decode: (payload) => Beacon(code: payload['code']! as String),
  ),
);
```

Codecs are tried before the built-in types, in registration order (register a subclass's codec
before its superclass's); registering a `typeId` again replaces the codec. For a `Component3D`,
the serializer adds the common fields and the children itself, so the payload holds only the
type's own state. Payloads may contain `null`, booleans, numbers, strings, lists and maps with
string keys.


### Loading, versions and errors

- Snapshots carry `schemaVersion` (`SceneSerializer3D.currentSchemaVersion`, currently 2).
  Loading accepts versions from `oldestSupportedSchemaVersion` (1) up to the current one; a
  version 1 snapshot loads as before (raw meshes in the standard layout).
- A malformed snapshot, an unknown node type or mesh kind, a bad binary header, a length mismatch
  or a checksum mismatch throw a `FormatException`; an unregistered prefab id, codec id, mesh key
  or texture key throws a `StateError`.
- The whole snapshot is decoded before the target is touched: when loading throws, the target
  keeps its children and settings.
- By default the nodes are added next to what the target holds; `clearTarget: true` removes the
  target's children first. The world settings of the snapshot are always applied, and a snapshot
  without fog, bloom or post-processing turns them off in the target.


### Binary format

The binary form holds the same tree as the JSON, little-endian:

| Offset | Size | Content                                                             |
| ------ | ---- | ------------------------------------------------------------------- |
| 0      | 4    | `F3DS` (`SceneSerializer3D.binaryMagic`)                            |
| 4      | 2    | schema version                                                      |
| 6      | 2    | flags (0)                                                           |
| 8      | 4    | payload length in bytes                                             |
| 12     | 4    | CRC-32 (IEEE) of the whole buffer, these 4 bytes skipped            |
| 16     | ...  | payload: a string table, then the tree of tagged values             |

Strings (keys included) are stored once in the table and referenced by index. Values are tagged:
null, false, true, 32-bit signed and unsigned integers, 64-bit floats, strings, lists and maps.
`SceneSerializer3D.computeCrc32` is public, to check a file yourself.

Cost: both encoders build the whole tree in memory first. The binary form is smaller than JSON
mostly through the string table; numbers that are not whole take 9 bytes each, so raw meshes take
more than twice the size of their 32-bit vertex data. There is no compression. Register large
meshes by key instead of saving them raw.


## Resource lifetime

Surfaces, textures and shaders are `Resource`s: each creates its GPU object the first time it is
used. `Resource.dispose()` drops that GPU object; the memory is returned when the object is garbage
collected, not at the call. The resource stays usable: the next use creates a new GPU object from
the data it keeps on the CPU (a `Surface` keeps its vertices and indices, a `Texture` its pixels).
Disposing something that is still drawn therefore costs a new upload, not a crash. A `Texture`
that wraps an existing `gpuTexture` gets the same GPU texture back, so disposing it frees nothing.

Removing a component from the world disposes nothing; nothing in flame_3d disposes your meshes
and textures for you. The two helpers below decide when to call `dispose`.


### Asset scopes

`AssetScope3D` counts references to loaded assets and disposes what they own when the last
reference to them goes away:

```dart
final level = AssetScope3D();
final house = level.retain(await ModelParser.parse('assets/models/house.glb'));
world.add(ModelComponent(model: house));

// When the level closes:
level.disposeAll();
```

- `retain(asset)` accepts a `Model`, `Mesh`, `Surface` or `Texture` and returns it; `release(asset)`
  decrements its count and returns `true` when it reached zero; `refCountOf`, `retainedAssetCount`
  and `trackedResourceCount` report the counts.
- An asset owns its surfaces and the textures of their materials: albedo, normal,
  metallic-roughness, occlusion, emissive and environment textures of a `SpatialMaterial`, the
  albedo texture of an `UnlitMaterial`. A surface or texture shared by several retained assets is
  disposed when the last of them is released. `Texture.standard` and `Texture.empty` are never
  disposed.
- `disposeAll()` disposes everything the scope tracks and resets it.

Ownership is collected when an asset is retained and again when it is released: change an asset's
surfaces or textures in between and the counts no longer match (it can then dispose a texture that
another retained asset still uses). Lightmap textures, `StylizedMaterial` textures and the
textures of other materials are not tracked.


### GPU resource cache

`GpuResourceManager3D` is a cache of resources by key, with reference counts and a memory budget:

```dart
final gpu = GpuResourceManager3D(maxVramBytes: 128 * 1024 * 1024);
final rock = gpu.acquire('rock', buildRock);
final mesh = rock.resource; // share it between components
// When nothing uses it any more:
rock.release();
// When memory is short:
gpu.purgeUnreferenced();
final report = gpu.auditLeaks();
if (report.hasLeaks) {
  print('Unreleased: ${report.leakedKeys}');
}
```

- `acquire(key, create, estimatedBytes:, pinned:)` returns a `ResourceLease3D`, calling `create`
  only when the key is not cached. Releasing a lease more than once is harmless.
- A resource whose count drops to zero stays cached. When the estimated total exceeds
  `maxVramBytes` (256 MiB by default), the least recently released resources with no references
  and not pinned (`setPinned`) are disposed and forgotten. `trimToBudget`, `purgeUnreferenced`
  and `disposeAll` free on demand.
- Sizes are estimates: textures count 4 bytes per pixel (16 for `rgbaFloat32`), a third more with
  mipmaps; surfaces and meshes count their vertex and index bytes; other resources count 0. Pass
  `estimatedBytes` when you know better.
- `refCountOf`, `entryCount`, `lruCount`, `estimatedTotalBytes`, `activeBytes`,
  `unreferencedBytes`, `evictionCount` and `auditLeaks()` (resources still referenced) help find
  leaks.

A lease releases the reference of the cache entry it was acquired from: a lease acquired before
`disposeAll()` and released after the key was acquired again does nothing, instead of taking the
new holder's reference. `release(key)` is deprecated: it decrements the count of whatever is cached
under the key, a reference that may belong to someone else.


### Device loss

`GpuDeviceLossRecovery3D` (the manager's `deviceLossRecovery`) keeps rebuild hooks:
`registerCallback(id, callback)` and `registerResource(id, resource, onRebuild:)`.
`markResourcesLost()` disposes the registered resources; `recoverAll()` disposes them again, runs
the hooks in registration order and creates the GPU objects again; the manager's
`recoverAfterDeviceLoss()` also disposes every cached resource and recreates those in use or
pinned.

flame_3d does not detect a lost device: nothing calls these methods for you. Resources that wrap
an existing GPU object (such as a `Texture` built from a `gpuTexture`) cannot be rebuilt this way;
register a callback that recreates them.


### Which one to use

Use `AssetScope3D` to tie assets to a phase of the game (a level, a menu) and release them
together, for example from `WorldChunkStreamer3D.onChunkEvicted` (see
[Large Worlds](world_scale.md)). Use `GpuResourceManager3D` for assets that many parts of the game
load by name and that may be dropped when memory runs short. Both only call `dispose`, with the
behavior described above.


## Loading glTF scenes

`SceneLoader3D` turns a glTF 2.0 or GLB file into components ready to add to a world:

```dart
final scene = await SceneLoader3D.loadAsset(
  'assets/models/village.glb',
  onNodeExtras: (node) {
    if (node.extrasMap?['spawn'] == 'chest') {
      node.addComponent(Group3D(position: node.worldPosition));
    }
  },
);
scene.mountInto(world);
final firstCamera = scene.cameras.firstOrNull?.toCameraComponent();
```

- `loadAsset(path)` loads `.glb` and `.gltf` files from the assets; any other file is loaded with
  `ModelParser.parse` as one `ModelComponent`. `loadGlbBytes` and `loadGltfJson` take data in
  memory, `fromRoot` an already parsed `GltfRoot`. `sceneIndex` picks a scene other than the
  file's default.
- Static nodes become `MeshComponent`s. Nodes that use the same mesh more than once become one
  `InstancedGroup3D` when `autoBatchStaticMeshes` is `true` (the default), and nodes with
  `EXT_mesh_gpu_instancing` always do. Subtrees with skins, morph targets or animations become
  `ModelComponent`s.
- `KHR_lights_punctual` lights become `LightComponent`s (intensities are passed through
  unchanged); cameras become `LoadedCamera3D`s, which `toCameraComponent()` converts.
- `onNodeExtras` is called for every node with `extras`, with its transforms and the component
  spawned for it; components added with `addComponent` are mounted with the scene.

Loading glTF models and their materials and animations is described in
[Models and Animation](models_and_animation.md).


## Limitations

- `SceneSerializer3D` has no built-in encoding for `ModelComponent`, particle systems and the
  components of [Large Worlds](world_scale.md): save them with codecs or prefabs (otherwise the
  save throws, see [What cannot be saved](#what-cannot-be-saved)). Both encoders build the whole
  tree in memory.
- `Resource.dispose()` frees GPU memory only when the GPU object is garbage collected, and a
  disposed resource that is used again is uploaded again. Budgets and leak reports of
  `GpuResourceManager3D` are estimates.
- `AssetScope3D` does not track lightmap textures or the textures of `StylizedMaterial` and other
  materials, and miscounts assets changed between `retain` and `release`.
- Device-loss recovery is manual and cannot rebuild resources that wrap existing GPU objects.
- `SceneLoader3D` reads files through the model loader and shares its limits (see
  [Models and Animation](models_and_animation.md#limitations)).
