# flame_3d example & showcase testbed

Interactive examples and an all-in-one 20-lab engine showcase for `package:flame_3d`:

- **`showcase`** (`ShowcaseGame` / `ShowcaseView` — press `T` or run `setup showcase` in the
  console):
  - **20 feature labs (`ShowcasePreset`)** exercising retained `Scene3DComponent` layers,
    `ShadowSettings.cacheWhenStatic`, Float16 HDR (`hdrEnabled`), `ColorLut3D`, `RenderDebugMode3D`,
    split-sum `BrdfLut3D`, box-projected `ReflectionProbeVolume3D`, 3D `LightProbeGrid3D`, PBR
    `SpatialMaterial` (Clearcoat, Transmission/IOR, `Surface.computeTangents`, `anisotropic16x`,
    `Ktx2TextureLoader` BC1), unified `ShadowAtlas3D` (`4`-CSM + `SpotLight` + Dual-Paraboloid
    `PointLight` shadows), Weighted Blended OIT (`OitMode3D.weightedBlended`), Grab-Pass refraction,
    `StencilState`, `RenderGraph3D`, `LightClusterGrid3D` (`128+` lights), Hi-Z `OcclusionCuller3D`
    and `PortalOcclusionGraph3D`, `StaticMeshBatcher3D`, 64-bit `FloatingOriginController3D`, CDLOD
    `ChunkedTerrain3D` with `10,000+` `FoliageSystem3D` & `VolumeDecalBatch3D`, `DynamicAabbTree3D`,
    `120 m/s` CCD `RigidBody3D`, `CompoundShape3D` & `HeightfieldShape3D`, 6-DOF joints,
    `BuoyancyVolume3D`, `RaycastVehicle3D`, `XpbdCloth3D` / `XpbdRope3D`, Recast `NavMeshBuilder3D`,
    `NavMeshObstacle3D` & `OffMeshLink3D`, CRC32 `PhysicsSnapshot3D` rollback,
    `AnimationStateMachine3D` HFSM, `AnimationRetargeter3D`, `FabrikIkConstraint3D`,
    `FootPlacementIk3D`, `RagdollController3D`, `PrefabRegistry3D` + `'F3DS'` `SceneSerializer3D`,
    `GpuResourceManager3D`, `CameraStack3D`, `Timeline3D` + `VirtualCameraBrain3D`,
    `MsdfTextBatch3D`, `WidgetSurface3D`, `MeshoptDecoder3D` + `WorldChunkStreamer3D`,
    `SpatialAudioMixer3D`, `TransformGizmo3D` + `SceneInspector3D`, and a **64-check** automated
    **Self-Test** (`ShowcaseDiagnostics`).
- **`boxes`**, **`colors`**, **`culling`**, **`models`**, **`particles`**, **`houses`** (`H`), and
  **`shadows`**.


## Headless GPU verification

From `packages/flame_3d/example`:

```sh
flutter test --enable-impeller --enable-flutter-gpu
```
