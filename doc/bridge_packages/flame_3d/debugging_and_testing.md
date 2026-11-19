# Debugging, Profiling and Testing

This page covers the tools for seeing what a 3D scene does (debug lines, an inspector with a
transform gizmo, render debug views, statistics), the example app and its self-test, the
benchmark, and how to test code that uses `flame_3d`.


## Debug drawing

`DebugRenderer3D` (`package:flame_3d/debug.dart`) is an `Object3D` that draws colored line
segments into its world. Add one to the world; on every main pass it draws:

- the world bounding box of every `Object3D` in the world, the skybox excepted
  (`showObjectBounds`);
- a line from each node of every `ModelComponent` to its parent node, posed (`showSkeletons`);
- a sphere of `range` (or `1.2` without a range) around each point light, and a cone of `range`
  (or `4`) and the outer cone angle for each spot light (`showLightVolumes`);
- the lines added with its drawing methods.

It does not draw physics shapes by itself; [Collisions and Physics](physics.md#debugging) shows how
to draw the bodies of a `PhysicsWorld3D` with it.

```dart
class DebugOverlay extends Component {
  DebugOverlay(this.debug, this.inspector, this.camera);

  final DebugRenderer3D debug;
  final SceneInspector3D inspector;
  final CameraComponent3D camera;

  @override
  void update(double dt) {
    debug
      ..clearCustomSegments()
      ..drawAxes(Matrix4.identity(), size: 2)
      ..drawSphere(Vector3(0, 1, 0), 0.5);
    inspector.render(debug, cameraPosition: camera.position);
  }
}
```

The drawing methods are `drawLine`, `drawAabb` (a world-space box), `drawObb` (half extents and a
transform), `drawSphere` (three rings), `drawCapsule` (two spheres joined by the axis), `drawCone`,
`drawAxes` (red, green and blue axes of a transform) and `drawPolyline`. The lines they add stay
until `clearCustomSegments()` is called: to draw something that changes, clear and add again on
every update, as above, or the list grows every frame.

Each segment is a thin box `lineThickness` world units thick (`0.022`, or the `thickness` of the
call), so lines get thinner on screen with distance. All segments are drawn with an
`UnlitMaterial` in one instanced draw call. `xray: true` turns the depth test off so that lines
show through geometry; `enabled: false` hides everything; `lastSegmentCount` tells how many
segments the last pass drew.


### Costs and limitations

- The automatic overlays walk the whole world tree on every main pass, allocate several vectors
  per object and evaluate the pose of every model. It is a tool for debugging, not for release
  builds. Shadow and depth-normal passes skip it.
- Its bounds are a fixed box of ±100,000 units, so that it is never culled. It sets
  `includeInSceneBounds` to `false`, so those bounds stay out of `World3D.sceneBounds`, which
  fits the sun's shadow map: adding the renderer leaves the shadows as they are
  (`test/gpu/debug_and_ui_3d_gpu_test.dart` compares the pixels of a shadowed scene with and
  without it). While it is in a world, a `Scene3DComponent` renders its whole visible area instead
  of only the part the scene's bounds cover, so that lines outside the scene still show.
- With `xray`, the lines are still drawn among the opaque draws, ordered by pipeline and material:
  objects whose material comes later in that order draw over the lines anyway. In a check, a quad
  in front of an x-ray line covered it when the quad's material was created after the renderer,
  and did not when it was created before.
- It does not draw the bounds of a `SceneSpatialIndex3D`: draw them with `drawAabb` if you need
  them.


## Inspector and transform gizmo

`SceneInspector3D` keeps a selection, draws it, and binds a `TransformGizmo3D` to it. Neither is a
component: the game feeds them rays and asks them to draw into a `DebugRenderer3D`.

```dart
final debug = DebugRenderer3D(showObjectBounds: false);
final inspector = SceneInspector3D(
  gizmo: TransformGizmo3D(translateSnap: 0.25),
  onSelectionChanged: (c) => print('selected $c'),
);
world.add(debug);
game.add(DebugOverlay(debug, inspector, camera));
```

- `pickInWorld(world, ray)` selects the nearest visible object hit by the ray (never a
  `DebugRenderer3D`), or clears the selection on a miss; a ray that hits a handle of the gizmo
  keeps the selection. `select` and `clearSelection` set it directly.
- `render(renderer, cameraPosition: ...)` draws the selection's bounding box, its axes and the
  gizmo (`drawSelectionBounds`, `drawSelectionBasis`, `selectionBoundsColor`, `basisAxisSize`).
- `summarize(world)` walks the world and returns a `SceneHierarchySummary3D`: node counts
  (visible, hidden, meshes, lights, groups), the depth of the tree, and estimated instances and
  triangles. The triangle estimate counts `MeshComponent`, the current level of
  `LodMeshComponent`, `InstancedGroup3D`, and 2 per skybox or text label; models, particles and
  batches count no triangles.

`TransformGizmo3D` edits the local position, rotation or scale of its `target`:

- `mode`: `translate` (axis arrows, plane squares), `rotate` (three rings) or `scale` (axis handles
  and a center cube for uniform scale); `space`: `world` or `local` axes;
- size: `fixedWorldSize`, or the distance to the camera times `screenScaleFactor` (`0.18`), clamped
  to `minWorldSize` (`0.15`) and `maxWorldSize` (`50`), which keeps a constant size on screen with a
  perspective camera. With an orthographic camera use `fixedWorldSize`;
- snapping: `translateSnap` (world units), `rotateSnapRadians`, `scaleSnap`;
- `pickHandle(ray)`, `updateHover(ray)`, then `beginDrag(ray)`, `updateDrag(ray)` and `endDrag()`
  (or `cancelDrag()`, which restores the start). Drags are solved in world space and converted
  through the parent's transform, so nested targets move as expected;
- `history` records every finished drag that changed something; `undo()` and `redo()` restore a
  stored transform (up to `maxEntries`, 128, commands).

Nothing routes pointer events to the gizmo. Turn the pointer position into a ray
(`CameraComponent3D.viewportPointToRay` or `Scene3DComponent.localPointToRay`) in your own input
handling:

```dart
void pointerDown(Vector2 viewportPoint) {
  final ray = camera.viewportPointToRay(viewportPoint);
  final gizmo = inspector.gizmo;
  if (!gizmo.beginDrag(ray, cameraPosition: camera.position)) {
    inspector.pickInWorld(world, ray, cameraPosition: camera.position);
  }
}

void pointerMove(Vector2 viewportPoint) {
  final ray = camera.viewportPointToRay(viewportPoint);
  final gizmo = inspector.gizmo;
  if (gizmo.isDragging) {
    gizmo.updateDrag(ray);
  } else {
    gizmo.updateHover(ray, cameraPosition: camera.position);
  }
}

void pointerUp() => inspector.gizmo.endDrag();
```

Picking, snapping, parent transforms and undo/redo are covered by
`test/debug/transform_gizmo_and_inspector_3d_test.dart`. The drawing (`render`) is exercised there
but not checked.


## Render debug views

`World3D.renderDebugMode3D` (also `Scene3DComponent.renderDebugMode3D`) replaces the shaded image
with a diagnostic view: depth, ambient occlusion, normals, shadow cascades, wireframe, overdraw,
roughness and metallic, or albedo. [Post-Processing](post_processing.md#debug-views) describes
each view, what it turns on and where it works.

```dart
world.renderDebugMode3D = RenderDebugMode3D.normals;
layer.renderDebugMode3D = RenderDebugMode3D.wireframe;
```

When using them to debug a scene, keep in mind that:

- `normals`, `cascadeSplits`, `roughnessMetallic`, `albedo` and the overdraw color are written by
  the native `SpatialMaterial` shader only: a scene of `StylizedMaterial`, unlit, billboard,
  particle or water draws looks unchanged in them, and so does `SpatialMaterial` on the web;
- opaque billboards and camera-facing font text are missing from the depth-normal prepass, so
  `depth` and `ssao` do not show them (see [3D UI and Text](ui_3d.md#depth-and-sorting)).

`test/gpu/hdr_ibl_4csm_multi_shadow_stencil_wboit_gpu_test.dart` renders each view and checks only
that it is not blank.


## Statistics and the phase profiler

`FlameGame3D.renderStats` and `Scene3DComponent.renderStats` hold the counters of the last frame:
render passes, draw calls, instances, triangles, pipeline, state and material changes, uniform
uploads and bytes, particles, shadow passes and their draw calls.

```dart
final stats = game.renderStats;
print('${stats.drawCalls} draws, ${stats.triangles} triangles');
print('layer: ${layer.renderStats.renderPasses} passes');
```

Built with `--dart-define=FLAME_3D_PROFILE=true`, the renderer also times its CPU phases into
`RenderProfile.active`; without the define that code is compiled out. See
[Rendering](rendering.md) for the fields of `RenderStats` and the phases of `RenderProfile`.


## The example app

`packages/flame_3d/example` is a Flutter app (`flame_3d_example`). It ships without platform
folders: create the ones you need with `flutter create --platforms=macos .` (or `android`, `ios`)
in that directory and enable Impeller and Flutter GPU as described in
[Getting Started](getting_started.md).

The app starts on the `boxes` scenario. The backquote key opens a console where `setup <name>`
switches to `boxes`, `colors`, `culling`, `houses`, `models`, `particles`, `shadows`, `showcase` or
`camera_lab`; `H` opens `houses` and `T` the showcase directly, `R` resets the camera, `M` switches
its mode and `O` toggles 4x MSAA.

The showcase (`ShowcaseGame`, `ShowcaseView`) is one scene with 20 feature labs (`ShowcasePreset`)
and switches for most rendering options. `camera_lab` (`PureCameraLabGame`) is a pure 3D game with
10 camera setups (`PureCameraMode`), among them the orbit, spring arm and dolly rigs, split screen,
and a `VirtualCameraBrain3D` with a `Timeline3D`.


### The self-test

The showcase's Self-Test button runs `ShowcaseDiagnostics.runAllChecks`: 64 checks that switch
through all 20 labs and report each result. Under `flutter test` the same checks run headless:

```sh
cd packages/flame_3d/example
flutter test --enable-impeller --enable-flutter-gpu
```

That test (`example/test/showcase_gpu_test.dart`) expects all 64 checks to pass, the stress lab to
draw at least 2,048 instances, and the final frame to have more than 5,000 pixels that are not
dark. Without the flags it skips.

Read the results for what they are: most checks assert counters and state (draw calls above a
threshold, objects mounted, textures of the right size, a physics body that moved, an undo that
restored a value), and many would pass with wrong pictures. One check reads pixels: it renders a
64 by 64 snapshot and asks for more than 20 pixels that differ from the background. The render
debug views, for example, pass when each view records at least one draw call. Pixel-exact checks
of the rendering live in the package's GPU tests, not in the self-test.


## The benchmark

`packages/flame_3d/benchmark` measures what a `Scene3DComponent` over a 2D world costs: about 200
instanced objects with `StylizedMaterial`s, translucent and additive parts, 8 skinned characters,
a sun with soft shadows on a shadow catcher, 3 particle systems, point lights and 4x MSAA, under a
2D camera that keeps moving. It reports the CPU time of the update and the render (median, mean,
p90, minimum), with the profiler the time per `RenderPhase`, with the VM service the objects
allocated per frame by class, the `RenderStats`, and whole frames at a phone's resolution:

```sh
cd packages/flame_3d
flutter test --enable-impeller --enable-flutter-gpu --enable-vmservice \
  --dart-define=FLAME_3D_PROFILE=true \
  benchmark/scene_benchmark_test.dart
```

`--dart-define`s choose what to measure (`BENCH_MODE`), the number of frames, the size of the scene
(`BENCH_OBJECTS`, `BENCH_TRIANGLES`, `BENCH_SHADOWS`) and a JSON output file (`BENCH_OUT`). Under
`flutter test` the Dart code runs in JIT with assertions on a software GPU, so compare its numbers
with each other only; `benchmark/README.md` describes an AOT profile build on a real device. The
benchmark lives outside `test/`, so a plain `flutter test` does not run it.


## Testing 3D code


### Without a GPU

A plain `flutter test` has no Flutter GPU: `GpuBackend.isAvailable` is `false`. Everything that
does not draw still works and is fast to test: transforms and bounds, timelines and the camera
brain, picking with `World3D.raycast`, the input routing of `PointerRouter3D` (through
`dispatchTapDown`, `dispatchDragStart`, ...), physics, navigation and animation.

```dart
test('the door is half open at 1.75 s', () {
  final door = MeshComponent(mesh: CuboidMesh(size: Vector3.all(1)));
  final timeline = Timeline3D(
    tracks: [
      TransformTrack3D(
        target: door,
        positionKeys: [
          TransformKeyframe3D(time: 1, value: Vector3.zero()),
          TransformKeyframe3D(time: 2.5, value: Vector3(0, 3, 0)),
        ],
      ),
    ],
  );
  timeline.seek(1.75);
  expect(door.position.y, closeTo(1.5, 1e-9));
});
```

What is recorded for drawing can be tested too: `GraphicsDevice(backend: ...)` takes any
`GpuBackend`, and a `RenderContext3D` on that device reports `drawCount` and the device
`lastFrameStats`. The package's own tests use a recording fake for this
(`test/_fakes/fake_gpu_backend.dart`); it is not part of the public API, copy it if you need it.
`Text3DComponent` and `WidgetSurface3D` use placeholder textures without a GPU.


### With the GPU

Tests that render run under `flutter test --enable-impeller --enable-flutter-gpu`, which renders
with a software GPU inside the test process. Initialize the binding, load the shaders once, and
skip when Flutter GPU is not available:

```dart
TestWidgetsFlutterBinding.ensureInitialized();
final gpu = GpuBackend.isAvailable;

setUpAll(() async {
  if (gpu) {
    await GpuBackend.initialize();
  }
});

test(
  'a red quad covers the center',
  () async {
    final device = GraphicsDevice();
    final context = RenderContext3D(device);
    final quad = PlaneMesh(
      size: Vector2.all(1),
      material: UnlitMaterial(albedoColor: const Color(0xFFFF0000)),
    );

    device.begin();
    context.setCamera(
      Matrix4.identity()
        ..setAsViewMatrix(Vector3(0, 3, 0), Vector3.zero(), Vector3(0, 0, -1)),
      Matrix4.identity()..setAsPerspective(60, 1, 0.1, 10),
    );
    device.beginPass(const Size(64, 64), frontFace: context.frontFace);
    context
      ..drawMesh(quad)
      ..flush();
    final image = device.endPass();
    device.end();

    final bytes = (await image.toByteData())!.buffer.asUint8List();
    image.dispose();
    final center = (32 * 64 + 32) * 4;
    expect(bytes[center], greaterThan(200)); // red
    expect(bytes[center + 1], lessThan(50)); // no green
  },
  skip: gpu ? false : 'needs --enable-impeller --enable-flutter-gpu',
);
```

Three ways to get pixels:

- a raw pass through a `GraphicsDevice`, as above, for materials and draws;
- `World3D.renderToImage(size, view: ..., projection: ...)` for a whole world, with its lights,
  shadows and post-processing. Mount the world in a game first, as the package's tests do: lights
  register with their world when they are mounted;
- a `GameWidget` in a `RepaintBoundary`, pumped with `testWidgets` and read with
  `RenderRepaintBoundary.toImage`, for the complete game including 2D and `Scene3DComponent`
  layers.

`GpuBackend.initialize()` loads every `.shaderbundle` asset of the app, so a material's shaders
must be declared as assets. Shaders compiled in the test itself can be registered with
`GpuBackend.instance.registerShaderLibrary(name, bytes)`.


### Comparing pixels

Rendering the same scene twice in one run gives identical pixels, but the software GPU of
`flutter test` is not a phone GPU, and drivers differ. Prefer assertions that survive small
changes: a color range at a known pixel, a count of pixels matching a predicate, a difference
between two renders that should (or should not) differ. The package's reference images
(`test/gpu/goldens`) are compared with a tolerance of 2 per channel and accept up to 0.2 % of
differing pixels. The GPU flags also change how Flutter renders 2D, so keep 3D GPU tests apart
from 2D golden tests.


### What runs where

Without the flags, every GPU test of the package skips: a plain run of `packages/flame_3d`
reports 791 tests, 602 passed and 189 skipped. The repository's CI runs `flutter test` without the
flags, so the GPU tests run only when someone runs them locally with the flags.

`test/shaders/shader_compilation_test.dart` recompiles every shader with
`dart run bin/build_shaders.dart`, which rewrites the bundles in `assets/shaders/` in place, and
then compares them with what was there before. GPU tests that load the bundles while it runs can
fail with `Shader library ... has not been loaded`, so do not run it in the same invocation as the
GPU tests. Run it on its own, then the rest:

```sh
cd packages/flame_3d
flutter test test/shaders
flutter test --enable-impeller --enable-flutter-gpu \
  $(ls -d test/*/ | grep -v -e '^test/shaders/' -e '^test/_') \
  test/*_test.dart
```

The same failure appears when two `flutter test` processes run at the same time in the same
package: they share its `build/unit_test_assets` folder, and one rebuilds it while the other loads
from it. Run a failing GPU test again alone before suspecting the code.
