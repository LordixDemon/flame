# Roadmap

In the interest of transparency, we provide a high-level detail of the roadmap for adding 3D
support to Flame. We hope this roadmap will help others in making plans and priorities based on the
work we are doing and potentially contribute back to the project itself.

The goal of the package can be split up into two sections, the primary goal is to provide an API for
Flame developers so they can create 3D environments without having to learn new Flame concepts. This
means the package will tie into the existing [FCS](https://docs.flame-engine.org/latest/flame/components.html#component)
and provide the tools needed, like a [`CameraComponent`](https://docs.flame-engine.org/latest/flame/camera_component.html),
`World` and similar components.

In a perfect world this API does not depend or even know about the Flutter GPU, which brings us
to our secondary goal: to abstract the Flutter GPU into an API that is user-friendly for 3D
development. That includes simplifying things like creating render targets, setting up the color
and depth textures and configuring depth stencils. But it also includes higher level APIs like
geometric shapes, texture/material rendering and creating Meshes that can use those shapes and
materials.

What each feature does today, what it costs and what it lacks is described in the documentation
(`doc/bridge_packages/flame_3d/`), under a "Limitations" heading on every page. The open items
below are collected from those sections.


## Goals


### Abstracting the Flutter GPU into a user-friendly API for 3D

- [x] Abstract the GPU setup into a class that represents the graphics device
  - [x] Setup binding logic for meshes, geometry and materials.
  - [x] Bind pipelines, render state and resources only when they change.
  - [x] Upload data shared by a render pass (camera, lights) once per pass.
  - [x] Report frame statistics (draw calls, instances, triangles, state changes).
- [x] Batch draws of the same surface and material into instanced draws.
  - [x] Sort opaque draws to batch and limit state changes, translucent draws back to front.
- [x] Give materials their own render state (blending, depth test and writes, culling, stencil).
  - [x] Keep back-face culling right for mirroring cameras and mirrored objects.
- [x] Real-time shadows.
  - [x] Fit the shadow map to what the camera sees, aligned with its texels.
  - [x] Soft edges, tinted shadows, and a shadow catcher for 2D ground.
  - [x] Cascaded shadow maps (up to 4), spot-light shadows (up to 2) and one point light with
    dual-paraboloid shadows, packed into one atlas pass and read by every built-in receiver.
- [x] Provide a `Mesh` API
  - [x] Provide `Surface`s that can hold geometric shapes.
  - [x] Build `Surface`s straight from typed arrays, with custom vertex layouts.
  - [x] Support 32-bit indices for large surfaces.
  - [x] Provide a `Material` API
    - [x] Define a `Texture` API to be used with the `Material` API
      - [x] Support images as textures
      - [x] Support single color textures
      - [x] Support generated textures
    - [x] Provide a standard `Material`
  - [x] Support custom shaders (`build_shaders`, shared `#include` chunks, per-pass blocks)
    - [ ] Add a more dev friendly way to set uniforms
  - [x] Support multiple `Material`s by defining surfaces on a mesh.


### Providing a familiar API for developers to use 3D with Flame

- [x] Use the existing `CameraComponent` API for 3D rendering
  - [x] Provide a custom `World`
  - [x] Support existing and custom viewports
  - [ ] Support existing and custom viewfinders (the 3D camera ignores the viewfinder)
- [x] Create a new core component for 3D rendering (`Component3D`)
  - [x] Implement a `Transform3D` for 3D transformations
    - [x] Implement a notifying `Vector3` and `Quaternion` for 3D positioning and rotation
  - [x] Add support for gesture event callbacks (`PointerRouter3D`)
- [x] Create a component that can show meshes (`MeshComponent`)
  - [x] Ensure materials can be set outside of construction (in the `onLoad` for instance)
- [x] Show 3D scenes as layers of a 2D game (`Scene3DComponent`), lined up with the 2D camera.


### Beyond the original goals

These exist, partly, and are described with their limits in the documentation:

- [x] Post-processing: HDR targets, tone mapping, color grading, bloom, FXAA, and a depth-normal
  prepass for SSAO, depth of field, soft particles and shoreline foam.
- [x] Image-based lighting, reflection probe volumes, light probe grids and lightmaps
  (`SpatialMaterial`, native backends).
- [x] Order-independent transparency, a scene-color grab pass, custom render passes.
- [x] Particles and ribbons, billboards, 3D text and canvas panels.
- [x] glTF / GLB and OBJ models, skinning, morph targets, animation blending, a state machine,
  retargeting, inverse kinematics, ragdolls and crowds.
- [x] Collision detection, rigid bodies with joints, vehicles, buoyancy, cloth and rope (CPU).
- [x] Voxel navigation meshes, path finding and crowd steering (CPU).
- [x] Spatial audio parameters for an audio engine you connect.
- [x] Large-world helpers (static batching, occlusion helpers, floating origin, terrain, foliage,
  decals, streaming), prefabs, scene serialization, asset lifetimes, cinematics and debug tools.


## Open items


### Platforms and testing

- [ ] WebGPU (WGSL) builds of the shaders that have none: `StylizedMaterial`, particles, ribbons
  (the material still refuses the web), water, the shadow casters and the shadow catcher, decals
  and outlines (their materials still refuse the web), the post-processing composite and bloom,
  the depth-normal prepass, order-independent transparency and the texture copy.
- [ ] Rebuild the shipped WGSL bundles with `naga`: `billboard_material.wgslbundle` was edited by
  hand after the billboard changes, and the outline bundles predate the outline normal fix.
- [ ] `Text3DComponent` and `WidgetSurface3D` on the web (images as textures on WebGPU).
- [ ] Detect float render targets on OpenGL ES instead of assuming none.
- [ ] Detect a lost GPU device and recover without the app's help.
- [ ] Run the GPU tests in CI, and on Android, iOS and browser devices.


### Rendering

- [ ] Per-object light lists or clustered shading in the renderer, beyond 4 directional, 8 point
  and 4 spot lights per pass (`LightClusterGrid3D` is a CPU helper only).
- [ ] Per-instance culling and sorting in `InstancedGroup3D`.
- [ ] Hysteresis in `LodMeshComponent`.
- [x] `RayHit3D.instanceIndex` for hits on instanced groups and crowd agents (`surfaceIndex` still
  holds the instance index on an `InstancedGroup3D`, for compatibility).
- [ ] Ray casts against the animated pose of skinned surfaces.
- [x] `Scene3DComponent` layers detect a pre-scaled canvas (`RasterScale` in Flame, pushed by
  `PostProcess.rasterizeSubtree` and by a camera with a `worldRenderScale`) and pick their
  resolution themselves. `FlameGame3D` does not read it yet.
- [ ] A depth buffer shared between `CameraStack3D` slots (`CameraClearMode3D.depthOnly`).
- [ ] `RenderGraph3D` used by `World3D`, with a `compile` that does not allocate.


### Materials, lighting and post-processing

- [ ] A single alpha convention for premultiplied textures: translucent `SpatialMaterial` blends
  straight alpha, and textured decals multiply by alpha twice unless
  `DecalMaterial.premultipliedTexture` is set; `ImageTexture` has no sRGB option.
- [ ] Light brighter than white under HDR from materials other than `SpatialMaterial`.
- [ ] KTX2 supercompression, and CPU decoders for BC7, ETC2, ASTC and RGBA32F.
- [ ] HDR (float) environment probes, GGX prefiltering, and blending between reflection volumes.
- [ ] The mixed band-2 terms of light probe grids on the GPU, and baked occlusion.
- [ ] UV rotation, and the UV transform on lightmaps.
- [ ] Water that reflects the skybox or an environment probe.
- [ ] SSAO and depth of field in scene units rather than normalized depth.
- [ ] Tone mapping of the composite on unpremultiplied colors at layer edges.


### Shadows

- [x] Shared lights for a `ShadowGroup`: `World3D.lightsFrom` lets the other layers borrow the
  lights of one world.
- [ ] Casters that honor alpha cutouts and fades.
- [ ] More than one shadowed point light; `fit`, `bounds` and `normalBias` for spot lights.
- [ ] One traversal for all the tiles of the shadow atlas.
- [ ] Inner cascades that follow the camera with orthographic cameras and `ShadowFit.scene`.


### Particles

- [ ] Particle collisions with meshes.
- [x] Opaque billboard particles in the depth-normal prepass.
- [ ] Billboard particles in shadow maps.
- [ ] Mitred ribbon joins at sharp turns.
- [ ] Soft-particle fades in scene units.


### Models and animation

- [ ] glTF `TANGENT`, `TEXCOORD_1`, `COLOR_1`, points and lines, `KHR_meshopt_compression` and the
  `KHR_materials_*` extensions beyond unlit and emissive strength.
- [ ] OBJ: concave polygons and more of the MTL format.
- [ ] Additive animation layers, removing the root's rotation in root motion, and foot placement
  and retargeting for other up axes than `+y`.
- [ ] Crowds of skinned agents in fewer draw calls (one per agent and surface now).


### Physics

- [ ] No per-pair allocations in the narrowphase (manifolds, GJK and EPA working sets).
- [ ] A gyroscopic term in the integration of rotations.
- [ ] Continuous collision detection that sweeps rotation, and contacts with moving colliders,
  meshes and a triangle-mesh shape.
- [ ] Determinism across platforms.
- [ ] Cloth self-collision and cloth acting on rigid bodies; buoyancy along other axes than Y.


### Navigation and audio

- [ ] Regions, contours and polygon merging (simplification) in `NavMeshBuilder3D`, and a builder
  for other up axes than `+y`.
- [ ] Obstacles that carve the mesh and grow by the agent radius; area types and query filters;
  re-entrant queries.
- [ ] Crowd steering that avoids walls and re-plans.
- [ ] An audio backend shipped with the package, panning that tells front from back, and partial
  built-in occlusion.


### Large worlds, scenes and assets

- [ ] Geomorphing, texture splatting and chunk eviction in `ChunkedTerrain3D`.
- [ ] Occlusion culling applied by the renderer, and one rectangle per portal.
- [ ] `SceneSerializer3D` encodings for `ModelComponent`, particle systems and the large-world
  components; encoders that stream instead of building the whole tree.
- [ ] `AssetScope3D` tracking every material texture.


### 3D UI, text, cinematics and debugging

- [ ] Fonts for `MsdfTextBatch3D` (non-Latin glyphs, real multi-channel distance fields,
  anti-aliased edges and mipmaps).
- [ ] Keyboard input and focus for `WidgetSurface3D`.
- [ ] Blending between overlapping clip spans in timelines, and saving timelines.
- [ ] Self-test checks of the example that assert pixels; pointer wiring for `TransformGizmo3D`.
