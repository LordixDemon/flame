<!-- markdownlint-disable MD013 -->
<p align="center">
  <a href="https://flame-engine.org">
    <img alt="flame" width="200px" src="https://user-images.githubusercontent.com/6718144/101553774-3bc7b000-39ad-11eb-8a6a-de2daa31bd64.png">
  </a>
</p>

<p align="center">
Adds 3D support for <a href="https://github.com/flame-engine/flame">Flame</a> using the <a href="https://github.com/flutter/flutter/wiki/Flutter-GPU">Flutter GPU</a>.
</p>

<p align="center">
  <a title="Pub" href="https://pub.dev/packages/flame_3d" ><img src="https://img.shields.io/pub/v/flame_3d.svg?style=popout" /></a>
  <a title="Test" href="https://github.com/flame-engine/flame/actions?query=workflow%3Acicd+branch%3Amain"><img src="https://github.com/flame-engine/flame/actions/workflows/cicd.yml/badge.svg?branch=main&event=push"/></a>
  <a title="Discord" href="https://discord.gg/pxrBmy4"><img src="https://img.shields.io/discord/509714518008528896.svg"/></a>
  <a title="Melos" href="https://github.com/invertase/melos"><img src="https://img.shields.io/badge/maintained%20with-melos-f700ff.svg"/></a>
</p>

---

<!-- markdownlint-enable MD013 -->

<!-- markdownlint-disable-next-line MD002 -->

# flame_3d

`flame_3d` renders real-time 3D with the GPU, through
[Flutter GPU](https://github.com/flutter/flutter/wiki/Flutter-GPU) on Impeller (and WebGPU in the
browser), with a depth buffer, and gives it a Flame API: components, a world, cameras. It can be
used in two ways:

- a whole 3D game: a `FlameGame3D` whose world is a `World3D` seen through a `CameraComponent3D`;
- 3D layers in a 2D game: `Scene3DComponent`s that show 3D scenes among ordinary 2D components,
  lined up with the 2D camera at every zoom and pan.

The documentation lives in [`doc/bridge_packages/flame_3d`][docs]: 21 pages, each with the costs,
the platform support and a "Limitations" section of its feature. This README is an overview.


## Status

This package is **experimental**. It depends on Flutter GPU and Impeller, which are experimental
themselves, its API may change at any time without following semver, and many of its modules are
recent. Behavior is covered by the package's tests (1,200 of them; the GPU tests render headless
on Flutter GPU, see [Testing](#testing)), not by runs on Android or iOS devices. Read the
"Limitations" section of a page before you rely on a feature, and expect to work around gaps.


## Platform support

| Platform            | Backend                  | Status                           |
| ------------------- | ------------------------ | -------------------------------- |
| iOS, macOS          | Flutter GPU on Metal     | Supported                        |
| Android             | Flutter GPU on Vulkan    | Supported                        |
| Android, older GPUs | Flutter GPU on OpenGL ES | Supported, with limits           |
| Web                 | WebGPU                   | Partial                          |
| Windows, Linux      | none (no Flutter GPU)    | Only `Canvas3DFallbackComponent` |

- **OpenGL ES**: no floating-point render targets, so HDR renders in 8 bits, order-independent
  transparency falls back to sorting and shadow depths are packed into 8-bit channels; no
  wireframe; some devices have no offscreen MSAA.
- **Web**: 8 of the package's 28 shaders have a WGSL build (`SpatialMaterial` in a simpler
  variant, `UnlitMaterial`, the skybox and billboards, plus decal, outline and ribbon shaders whose
  materials still refuse the web). `StylizedMaterial`, `ShadowCatcherMaterial`, `ParticleMaterial`,
  `DecalMaterial`, `OutlineMaterial`, `RibbonMaterial3D`, `Text3DComponent` and `WidgetSurface3D`
  throw an `UnsupportedError` when created; HDR, bloom and post-processing, the depth-normal
  prepass, order-independent transparency and `WaterMaterial` throw when they first render;
  shadows are skipped. The package's tests do not run in a browser.
- **Windows, Linux**: `Canvas3DFallbackComponent` draws a `World3D` on the CPU with
  `Canvas.drawVertices`: flat triangles sorted by depth, one directional light, no textures, no
  depth buffer. It suits previews, not a game.

See [Getting Started][getting-started] for the details.


## Getting started

```yaml
dependencies:
  flame: ^2.0.0-dev.1
  flame_3d: ^0.4.0-dev.1
```

Switch Flutter GPU on: `FLTEnableFlutterGPU` set to `true` in `ios/Runner/Info.plist` and
`macos/Runner/Info.plist` (and `FLTEnableImpeller` where Impeller is off), and
`<meta-data android:name="io.flutter.embedding.android.EnableFlutterGPU" android:value="true" />`
in the `<application>` element of `android/app/src/main/AndroidManifest.xml`. For a quick try,
`flutter run --enable-flutter-gpu` does the same without changing the project.

Then initialize the backend before anything renders, on every platform: `initialize()` loads the
shader bundles (or acquires the WebGPU device), and the first draw fails without it. It throws
where the backend is unavailable, so check `isAvailable` first:

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final gpu = GpuBackend.isAvailable;
  if (gpu) {
    await GpuBackend.initialize();
  }
  final Game game = gpu ? MyGame() : FallbackGame();
  runApp(GameWidget(game: game));
}

class MyGame extends FlameGame3D {
  MyGame()
    : super(
        camera: CameraComponent3D(
          position: Vector3(4, 3, 5),
          target: Vector3(0, 0.5, 0),
        ),
      );

  @override
  Future<void> onLoad() async {
    world.addAll([
      LightComponent.ambient(intensity: 0.4),
      LightComponent.directional(direction: Vector3(-0.5, -1, -0.3)),
      MeshComponent(
        mesh: CuboidMesh(
          size: Vector3.all(1),
          material: SpatialMaterial(albedoColor: const Color(0xFF3FA7D6)),
        ),
        position: Vector3(0, 0.5, 0),
      ),
    ]);
  }
}
```

The [example app][example] has scenarios for most features, switched from its built-in console.


## What it has

Each item links to the page that describes it, its costs and its limits.

- **Scenes and embedding** ([Basic Concepts][basic-concepts], [Cameras][cameras],
  [Embedding 3D in a 2D Game][embedding]): `World3D`, `Component3D`, `Object3D`, nested lights,
  camera and light masks, scene versions and dirty marking; perspective, orthographic and custom
  cameras, `CameraStack3D` split screens and camera rigs; `Scene3DComponent` layers with affine,
  camera or perspective projections, retained caching, shadows on 2D art and picking in local 2D
  coordinates.
- **Rendering** ([Rendering][rendering]): draws recorded, sorted and batched into instanced draws
  (one draw call per surface for components sharing a mesh), `InstancedGroup3D`,
  `LodMeshComponent`, render states with stencil and wireframe, custom vertex layouts and 32-bit
  indices, custom render passes (`RenderGraph3D` is a separate scheduling tool the world does not
  use), weighted blended order-independent transparency (float targets only), a scene-color grab
  pass for refraction, HDR targets and MSAA.
- **Materials** ([Materials and Textures][materials]): `SpatialMaterial` (metallic-roughness PBR
  with clear coat, transmission and image-based lighting; a simpler shader on the web),
  `StylizedMaterial` (vertex-colored low-poly art with masks, wind, MatCaps, accent and rim
  palettes), `UnlitMaterial`, `WaterMaterial`, `OutlineMaterial`, `DecalMaterial`, a skybox, fog,
  textures with samplers and CPU-built mipmaps, and KTX2 loading (BC7, ETC2 and ASTC only on GPUs
  that support them).
- **Lighting** ([Lighting][lighting]): ambient, hemisphere, up to 4 directional, 8 point and 4 spot
  lights per render pass, chosen per pass (no per-object light lists); environment probes,
  reflection probe volumes, light probe grids and lightmaps for `SpatialMaterial` on native
  backends. `LightClusterGrid3D` is a CPU helper that finds lights for a region; the renderer does
  not use it.
- **Shadows** ([Shadows][shadows]): a sun with one map or 2 to 4 cascades, up to two spot lights
  and one point light (dual-paraboloid), packed into one atlas pass when several cast; every
  built-in receiver reads them; `ShadowCatcherMaterial` for shadows on 2D art, `ShadowGroup` to
  share one map between layers, `cacheWhenStatic`. Not on the web.
- **Post-processing** ([Post-Processing][post-processing]): tone mapping (Reinhard, ACES, AgX),
  exposure, contrast, saturation, tint, 3D color lookup tables, vignette, FXAA, bloom, and a
  depth-normal prepass for SSAO, depth of field, soft particles and shoreline foam. Native only.
- **Particles and ribbons** ([Particles and Ribbons][particles]): `ParticleSystem3D`, simulated on
  the CPU without allocating and drawn in one instanced draw (billboards or mesh particles), soft
  particles, presets; `StrokeBatch3D` and `RibbonTrail3D` camera-facing strips. Native only.
- **Models and animation** ([Models and Animation][models]): glTF 2.0 and GLB (including
  `EXT_meshopt_compression`, sparse accessors and quantized data) and simple OBJ files, loading on
  a background isolate; up to 64 joints per surface and 4 influences per vertex; crossfades, blend
  spaces, an animation state machine, override layers, humanoid retargeting, root motion,
  two-bone and FABRIK IK, look-at, spring bones, foot placement, ragdolls, baked crowds and bone
  sockets.
- **Geometry and queries** ([Geometry and Scene Queries][geometry]): surfaces from typed arrays,
  built-in meshes and heightfields, tangents (computed per triangle, not MikkTSpace), CPU morph
  targets, BVH ray casts against surfaces and whole worlds (hidden and masked-out components are
  skipped), and an optional spatial index for queries.
- **Input and effects** ([Input and Effects][input]): `PointerRouter3D` with tap, hover and drag
  callbacks on 3D objects, transform and material effects for Flame's effect controllers, and
  fixed-step transform interpolation.
- **Collisions and physics** ([Collisions and Physics][physics], CPU, in Dart): `CollisionSystem3D`
  (detection, overlap queries, triggers; nothing is pushed apart), shape casts, a kinematic
  character controller, bone hitboxes; `PhysicsWorld3D` with sequential impulses, persistent
  multi-point contacts, island sleeping, convex hulls, compound shapes, heightfields, seven joint
  types, continuous collision detection (a swept sphere), buoyancy, raycast vehicles, XPBD cloth
  and rope, and snapshots that reproduce bit for bit on one platform and build.
- **Navigation** ([Navigation][navigation], CPU): `NavMeshBuilder3D` runs the first stages of the
  Recast pipeline (voxelize, filter, erode) and outputs a grid of small squares (no regions,
  contours or simplification); `NavMesh3D` paths with A* and string pulling, off-mesh links, area
  costs and box obstacles that block whole polygons (nothing is carved); `CrowdSteering3D` avoids
  other agents, not walls.
- **Spatial audio** ([Spatial Audio][audio]): listeners, emitters and a voice-limiting mixer that
  compute volume, pan, Doppler pitch, an occlusion low-pass cutoff and reverb parameters. It plays
  nothing: you connect an audio engine through an `AudioVoiceBackend3D`.
- **Large worlds** ([Large Worlds][world-scale]): `StaticMeshBatcher3D` (one draw per grid cell,
  material, layout and instance values), CPU occlusion helpers that the renderer does not call
  (`OcclusionCuller3D`, `PortalOcclusionGraph3D`), a 64-bit floating origin, `ChunkedTerrain3D`
  (quadtree levels of detail with skirts, no geomorphing), `FoliageSystem3D`, projected volume
  decals and chunk streaming.
- **Scenes and assets** ([Scenes and Assets][scenes]): prefabs, `SceneSerializer3D` (JSON and a
  CRC-checked binary format, for meshes, instanced groups, LOD meshes, lights, cameras, groups,
  prefab references and your own codecs; it refuses what it cannot save), `AssetScope3D` and
  `GpuResourceManager3D` (reference counts and an estimated memory budget; a lost GPU device is not
  detected, recovery is manual), and `SceneLoader3D` for whole glTF scenes.
- **Cinematics** ([Cinematics][cinematics]): virtual cameras with a blending brain, and
  `Timeline3D` tracks for camera shots, transforms, skeletal clips, morph weights and events.
- **3D UI and text** ([3D UI and Text][ui-3d]): `BillboardBatch3D` sprites and standees,
  `Text3DComponent` labels in any font Flutter renders, `MsdfTextBatch3D` for many strings in a
  built-in ASCII stroke font, and `WidgetSurface3D`, a canvas panel with simple controls (it does
  not host Flutter widgets). Labels and panels do not work on the web.
- **Debugging** ([Debugging, Profiling and Testing][debugging]): `DebugRenderer3D` lines,
  `SceneInspector3D` with a `TransformGizmo3D` (you feed it rays), render debug views,
  `RenderStats`, the `RenderProfile` phase profiler and a benchmark.


## Building shaders

The built-in materials ship compiled shader bundles. For your own materials, put a `.vert` and a
`.frag` with the same base name in a directory of your project and run, from the project root:

```sh
dart run flame_3d:build_shaders --src shaders/3d --out assets/shaders
```

Declare the output directory as an asset: `GpuBackend.initialize()` loads every `.shaderbundle`
the app declares. Shaders can `#include <flame_3d/camera.glsl>` and the other chunks the package
ships (instancing, skinning, lights, shadows, fog, dither, outline). `--with-web-gpu` also builds
WebGPU bundles through the `naga` CLI (`cargo install naga-cli`). Writing a material around custom
shaders, and the uniform blocks the render context fills, are described in
[Rendering][rendering-shaders] and [Materials and Textures][materials-custom].


## Testing

```sh
cd packages/flame_3d
flutter test --enable-impeller --enable-flutter-gpu
```

With the flags, Flutter GPU renders headless inside the test runner and the GPU tests run; without
them they skip. The flags also change how 2D content renders, so run 3D tests apart from 2D golden
tests. See [Debugging, Profiling and Testing][debugging].


## Contributing

Have you found a bug or have a suggestion of how to enhance the 3D APIs? Open an issue and we will
take a look at it as soon as possible.

Do you want to contribute with a PR? PRs are always welcome, just make sure to create it from the
correct branch (main) and follow the [checklist](../../.github/pull_request_template.md) which will
appear when you open the PR.

For bigger changes, or if in doubt, make sure to talk about your contribution to the team. Either
via an issue, GitHub discussion, or reach out to the team using the
[Discord server](https://discord.gg/pxrBmy4). The [roadmap](ROADMAP.md) lists what is done and
what is open.

[docs]: ../../doc/bridge_packages/flame_3d/flame_3d.md
[getting-started]: ../../doc/bridge_packages/flame_3d/getting_started.md
[basic-concepts]: ../../doc/bridge_packages/flame_3d/basic_concepts.md
[cameras]: ../../doc/bridge_packages/flame_3d/cameras.md
[embedding]: ../../doc/bridge_packages/flame_3d/embedding.md
[rendering]: ../../doc/bridge_packages/flame_3d/rendering.md
[rendering-shaders]: ../../doc/bridge_packages/flame_3d/rendering.md#building-shader-bundles
[materials]: ../../doc/bridge_packages/flame_3d/materials.md
[materials-custom]: ../../doc/bridge_packages/flame_3d/materials.md#custom-shaders
[lighting]: ../../doc/bridge_packages/flame_3d/lighting.md
[shadows]: ../../doc/bridge_packages/flame_3d/shadows.md
[post-processing]: ../../doc/bridge_packages/flame_3d/post_processing.md
[particles]: ../../doc/bridge_packages/flame_3d/particles.md
[models]: ../../doc/bridge_packages/flame_3d/models_and_animation.md
[geometry]: ../../doc/bridge_packages/flame_3d/geometry.md
[input]: ../../doc/bridge_packages/flame_3d/input_and_effects.md
[physics]: ../../doc/bridge_packages/flame_3d/physics.md
[navigation]: ../../doc/bridge_packages/flame_3d/navigation.md
[audio]: ../../doc/bridge_packages/flame_3d/audio.md
[world-scale]: ../../doc/bridge_packages/flame_3d/world_scale.md
[scenes]: ../../doc/bridge_packages/flame_3d/scenes_and_assets.md
[cinematics]: ../../doc/bridge_packages/flame_3d/cinematics.md
[ui-3d]: ../../doc/bridge_packages/flame_3d/ui_3d.md
[debugging]: ../../doc/bridge_packages/flame_3d/debugging_and_testing.md
[example]: example/README.md
