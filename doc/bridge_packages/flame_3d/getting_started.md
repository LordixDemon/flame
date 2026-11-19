# Getting Started

`flame_3d` renders real-time 3D with the GPU, through
[Flutter GPU](https://github.com/flutter/flutter/wiki/Flutter-GPU) on Impeller (and WebGPU in the
browser), with a depth buffer. It can be used in two ways:

- a whole 3D game: a `FlameGame3D` whose world is a `World3D` seen through a `CameraComponent3D`;
- 3D layers in a 2D game: `Scene3DComponent`s that show 3D scenes among ordinary 2D components,
  lined up with the 2D camera (see [Embedding 3D in a 2D Game](embedding.md)).


## Requirements

- Flutter 3.47 or newer and Dart 3.13 or newer.
- Impeller, which is the default renderer on iOS, macOS and Android, and Flutter GPU, which has to
  be switched on (see below).
- A call to `GpuBackend.initialize()` before anything renders.

Flutter GPU and Impeller are experimental, and so is this package: its API may change at any time.


## Platform support

| Platform            | Backend                     | Status                                      |
| ------------------- | --------------------------- | ------------------------------------------- |
| iOS, macOS          | Flutter GPU on Metal        | Supported                                   |
| Android             | Flutter GPU on Vulkan       | Supported                                   |
| Android, older GPUs | Flutter GPU on OpenGL ES    | Supported, with the limits below            |
| Web                 | WebGPU                      | Partial, see below                          |
| Windows, Linux      | none (no Flutter GPU)       | Only `Canvas3DFallbackComponent`            |

The package's GPU tests run headless with `flutter test --enable-impeller --enable-flutter-gpu`;
behavior on Android and iOS devices is not covered by them.

On OpenGL ES, `flame_3d` does not render into floating-point textures (Flutter GPU cannot tell
whether the device supports it), so `World3D.hdrEnabled` falls back to an 8-bit target and shadow
depths are packed into 8-bit channels. A device without offscreen multisampling silently renders
without MSAA.

`GpuBackend.isAvailable` tells whether the GPU backend can run in this process: it is `false` when
Flutter GPU is not enabled, when Impeller is off, on Windows and Linux, and in browsers without
WebGPU. Without it, constructing a `FlameGame3D` (or anything else with the `Game3D` mixin) throws,
and so does the first render of a `Scene3DComponent`.


### The web

On the web, `flame_3d` renders through the browser's WebGPU API with WGSL versions of a few shaders.
The package ships WGSL bundles for `SpatialMaterial` (a simpler shader than the native one, without
the native-only inputs), `UnlitMaterial`, `SkyboxComponent3D` and the billboard material. The decal,
outline and ribbon materials have WGSL bundles too, but their constructors still refuse the web.
Everything else fails:

- these constructors throw an `UnsupportedError` on the web: `StylizedMaterial`,
  `ShadowCatcherMaterial`, `ParticleMaterial`, `DecalMaterial`, `OutlineMaterial` and
  `RibbonMaterial3D`, and `Text3DComponent` and `WidgetSurface3D`, which need a `dart:ui` image as a
  texture (see [3D UI and Text](ui_3d.md));
- these features have no WGSL shaders and throw an `UnsupportedError` naming the missing shader the
  first time they render: bloom, `postProcess` and `hdrEnabled` (their composite pass), the depth
  prepass, weighted blended transparency, `keepContents` texture passes and `WaterMaterial` (see
  also [Post-Processing](post_processing.md#platform-support));
- shadows do not render: the shadow caster shaders have no WGSL build, so the first shadow pass
  prints that once and the scene renders without shadows from then on (see
  [Shadows](shadows.md#platform-support));
- `Texture.toImage()` throws, and the wireframe debug mode draws filled triangles.

Rendered images reach Flutter through a copy into an image bitmap after each pass. Multisampling
(`Msaa.sample4`) works on the web. The package's tests do not run in a browser: this list comes from
the code.


### Without a GPU backend

`Canvas3DFallbackComponent` draws a `World3D` with `Canvas.drawVertices` on the CPU, for platforms
where `GpuBackend.isAvailable` is `false`. It is a plain 2D component: add it to an ordinary
`FlameGame`, give it a `size` (it assumes 320 by 200 when its size is zero) and a
`CameraComponent3D` to project with.

```dart
final fallback = Canvas3DFallbackComponent(
  world: world,
  size: Vector2(800, 600),
  camera: CameraComponent3D(
    position: Vector3(6, 5, 6),
    target: Vector3.zero(),
  ),
);
```

It draws the `MeshComponent`s, the instances of `InstancedGroup3D`s and the nodes of
`ModelComponent`s that a pass of its camera would draw (visible ones whose `cameraMask` shares a bit
with the camera's), as flat triangles sorted back to front by their average depth. Each vertex gets
the base color of its material (`albedoColor` of `SpatialMaterial`, `StylizedMaterial` or
`UnlitMaterial`, white for other materials) times its vertex color times the component's `color`,
shaded by the last `DirectionalLight` of the world (its `direction`, or its component's rotation)
and the last ambient light. Surfaces of `ShadowCatcherMaterial` and `OutlineMaterial` are skipped.
The projection is the camera's: its view (custom or not), and its custom projection or the one built
from `fovY` or `orthographicHeight`, `near` and `far` for the component's aspect ratio, keeping what
lies between the near and the far plane. It does not draw:

- textures, specular light, shadows, fog, light colors, point, spot and hemisphere lights;
- particles, billboards, text, decals, the skybox, `LodMeshComponent`s and custom `Object3D`s;
- skinning and morph targets (models are drawn in their bind pose);
- post-processing, MSAA or a depth buffer: triangles that intersect are sorted as wholes, and a
  triangle that crosses the near plane is dropped.

Its buffers grow with the triangle count and are kept from frame to frame; a frame allocates only
the `Vertices` it draws. It suits previews and simple scenes, not a full game.


## Project setup

Add the package to `pubspec.yaml`. Its shaders are assets of the package and need no declaration
in the app.

```yaml
dependencies:
  flame: ^2.0.0-dev.1
  flame_3d: ^0.4.0-dev.1
```

Switch Flutter GPU on for each platform:

- iOS and macOS, in `ios/Runner/Info.plist` and `macos/Runner/Info.plist`:

  ```xml
  <key>FLTEnableFlutterGPU</key>
  <true/>
  ```

  Impeller is on by default there; add `FLTEnableImpeller` set to `true` if your project turned it
  off.

- Android, in the `<application>` element of `android/app/src/main/AndroidManifest.xml`:

  ```xml
  <meta-data
      android:name="io.flutter.embedding.android.EnableFlutterGPU"
      android:value="true" />
  ```

- For a quick try without changing the project files, `flutter run --enable-flutter-gpu` (add
  `--enable-impeller` where Impeller is not the default).

Then initialize the backend before running the app. `initialize()` loads every shader bundle of the
app and its packages (on native platforms) or acquires the WebGPU device (on the web); without it,
the first draw fails because its shader is not loaded. It throws when the backend is unavailable,
so check `isAvailable` first:

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
```


## A first scene

A `FlameGame3D` creates a `World3D` and a `CameraComponent3D` unless you pass your own. Add lights
and meshes to the world:

```dart
class MyGame extends FlameGame3D {
  MyGame()
    : super(
        camera: CameraComponent3D(
          position: Vector3(4, 3, 5),
          target: Vector3(0, 0.5, 0),
        ),
      );

  late final MeshComponent cube;
  double _angle = 0;

  @override
  Future<void> onLoad() async {
    cube = MeshComponent(
      mesh: CuboidMesh(
        size: Vector3.all(1),
        material: SpatialMaterial(albedoColor: const Color(0xFF3FA7D6)),
      ),
      position: Vector3(0, 0.5, 0),
    );
    world.addAll([
      LightComponent.ambient(intensity: 0.4),
      LightComponent.directional(direction: Vector3(-0.5, -1, -0.3)),
      MeshComponent(
        mesh: PlaneMesh(
          size: Vector2.all(8),
          material: SpatialMaterial(albedoColor: const Color(0xFF7A8B5C)),
        ),
      ),
      cube,
    ]);
  }

  @override
  void update(double dt) {
    super.update(dt);
    _angle += dt;
    cube.rotation.setAxisAngle(Vector3(0, 1, 0), _angle);
  }
}
```

The scene is y-up here: the default camera `up` is +y and `PlaneMesh` faces +y. Run it with the
platform flags above. The imports are `package:flame_3d/camera.dart`, `components.dart`,
`core.dart`, `game.dart`, `graphics.dart` (for `GpuBackend`) and `resources.dart`,
`package:flame/game.dart` for `Game` and `GameWidget`, and `package:flutter/widgets.dart` for
`runApp` and `WidgetsFlutterBinding`. Import only those two from the widgets library (with `show`):
it also exports the 64-bit `vector_math` types, whose names clash with the ones `flame_3d` uses.

To test GPU code, run `flutter test --enable-impeller --enable-flutter-gpu`: Flutter GPU then renders
headless inside the test runner, deterministically. The flags also change how 2D content renders, so
run 3D tests apart from 2D golden tests.


## Where to go next

- [Basic Concepts](basic_concepts.md): the world, components, transforms, the frame, dirty marking,
  masks and resources.
- [Cameras](cameras.md): projections, rays, split screen and camera rigs.
- [Rendering](rendering.md), [Geometry and Scene Queries](geometry.md),
  [Materials and Textures](materials.md), [Lighting](lighting.md) and [Shadows](shadows.md).
- [Embedding 3D in a 2D Game](embedding.md) for 3D layers in a 2D game.
- The `example` directory of the package has a playground with several scenarios, switched from its
  built-in console (see [The example app](debugging_and_testing.md#the-example-app)).
- Larger examples: [Defend the Donut][defend], a first-person game, and
  [Collect the Donut][collect], a third-person one.

[defend]: https://github.com/flame-engine/defend_the_donut/
[collect]: https://github.com/luanpotter/collect_the_donut
