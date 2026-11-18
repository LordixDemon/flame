# flame_3d example & showcase testbed

Interactive examples and an all-in-one engine showcase for `package:flame_3d`:

- **`showcase`** (`ShowcaseGame` / `ShowcaseView` — press `T` or run `setup showcase` in the console):
  - Two layered `Scene3DComponent`s (`Scene3DCacheMode.retained` + `ShadowSettings.cacheWhenStatic`, optional shared `ShadowGroup`, `ShadowCatcherMaterial` over 2D ground);
  - `InstancedGroup3D` (144 or 1,024 stress instances in 1 draw call using 16-color `StylizedMaterial.accentPalette` + `packAccentAndFade`), two-tier metallic/gem MatCaps, `WindSpace.worldScaled` trees with flutter and gusts, and `SpatialMaterial` PBR spheres;
  - `LodMeshComponent` 3-tier crystal towers + `shadowMesh`;
  - Zero-alloc skinned `ModelComponent` with `Idle` / `Swing` / `Spin` crossfades, `BoneSocket3D`, and static + skinned `OutlineMaterial`;
  - `DecalBatch3D` (procedural rings + 2x2 UV atlas), `StrokeBatch3D` 3D polylines, `RibbonTrail3D` motion ribbons, and `ParticleSystem3D` (billboards + 3D coin meshes);
  - `FogSettings`, Kawase `BloomSettings`, tap `Surface.bvh` raycasting, `World3D.renderToImage` thumbnail preview, and a 12-check automated **Self-Test**.
- **`boxes`**, **`colors`**, **`culling`**, **`models`**, **`particles`**, **`houses`** (`H`), and **`shadows`**.

## Headless GPU verification

From `packages/flame_3d/example`:

```sh
flutter test --enable-impeller --enable-flutter-gpu
```
