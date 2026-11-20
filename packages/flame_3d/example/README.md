# flame_3d example

A Flutter app (`flame_3d_example`) with scenarios for the features of `package:flame_3d`. It ships
without platform folders: create the ones you need in this directory with
`flutter create --platforms=macos .` (or `android`, `ios`), then switch Flutter GPU on as described
in the package's [Getting Started](../../../doc/bridge_packages/flame_3d/getting_started.md).


## Scenarios

The app starts on `boxes`. The backquote key opens a console where `setup <name>` switches
scenario; `H` opens `houses` and `T` the showcase directly, `R` resets the camera, `M` switches its
mode and `O` toggles 4x MSAA.

- `boxes`, `colors`, `culling`, `models`, `particles`: small scenes for one feature each
  (`particles` includes the splash presets).
- `houses`: an ordinary 2D game whose houses are one `Scene3DComponent` layer between a 2D grid
  and 2D labels, under a 2D camera that pans and zooms; a tap picks a house with a 3D ray.
- `shadows`: 3D buildings casting tinted shadows onto a 2D board through a `ShadowCatcherMaterial`,
  under a sun that circles around it.
- `barrier` (`BarrierGame`): a stone platform in a pool, in a layer over 2D water. It rises with
  water running off its edges (`ParticlePresets3D.runoffDrips`), a `BarrierMaterial` wall rises
  from its rim, is hit three times in different colors and sinks back, and a block drops into the
  water (`splashCrown`, `foamBurst`, `mistPuff`). A tap switches the barrier's pattern.
- `pool` (`PoolGame`, `PoolScene`): a clear, shallow pool in a walled quay, seen through a mirrored
  isometric-like `Scene3DComponent` projection: the water is one `WaterMaterial` draw (caustics,
  sparkles, a swell of the normals, a depth ramp, foam along the walls, ripples and
  `WaterFoamSources` collars around the slabs and the crate), plus a strip along the far wall
  whose band of foam stands still (`edgeFoamMotion: 0`), and a `World3D.waterVolume` submerges
  the floor, the stepping stones and a grid of slabs on columns that rise out of the water and
  sink back. Pebbles drop in; a tap switches between noon and dusk, where the foam keeps its white
  under the warm sun (`foamLightTint`, `waterlineLightTint`).
- `showcase` (`ShowcaseGame`, `ShowcaseView`): one scene with 20 feature labs (`ShowcasePreset`),
  from materials, lights and shadows to physics, navigation, animation, 3D UI and the inspector,
  and switches for most rendering options.
- `camera_lab` (`PureCameraLabGame`): a pure 3D game with 10 camera setups (`PureCameraMode`),
  among them the orbit, spring arm and dolly rigs, split screen, and a `VirtualCameraBrain3D` with a
  `Timeline3D`.

The labs show what each feature looks like and what it costs in the scene; the platform support
and the limits of each feature are on its documentation page.


## Self-test

The showcase's Self-Test button runs `ShowcaseDiagnostics.runAllChecks`: 64 checks that switch
through all 20 labs. They are smoke checks: most assert counters and state (draw calls above a
threshold, objects mounted, a body that moved), two read pixels. The pixel-exact checks of the
rendering are the package's own GPU tests. The same checks, and a run through the `barrier` scene,
run headless, from this directory:

```sh
flutter test --enable-impeller --enable-flutter-gpu
```

Without the flags the test skips. See
[Debugging, Profiling and Testing](../../../doc/bridge_packages/flame_3d/debugging_and_testing.md)
for what each check covers.
