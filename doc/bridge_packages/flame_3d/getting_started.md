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
what has been run on Android, and how to repeat it on a phone, is in
[Running on a device](debugging_and_testing.md#running-on-a-device).

Flutter chooses the backend when the app starts: Vulkan where the device's Vulkan driver is usable,
OpenGL ES otherwise. The Android emulator (with `-gpu host` on a Mac) gets OpenGL ES; its Vulkan,
forced with the manifest meta-data `io.flutter.embedding.android.ImpellerBackend` set to `vulkan`,
showed no 3D at all and crashed in Flutter's raster thread, so treat the emulator as an OpenGL ES
device. Flutter's log names the backend it uses ("Using the Impeller rendering backend
(OpenGLES)"), and `GpuBackend.instance.capabilities.api` tells the app. An emulator draws with the
Mac's GPU through a translator: it is not a phone.


### What the device offers

`GpuBackend.initialize()` detects what the device offers, in `GpuBackend.instance.capabilities`
(a `GpuDeviceCapabilities`, also printable as JSON with `toJson()`):

- `api`: `vulkan` or `openGLES` on Android (Flutter GPU does not say; rendering into mip levels,
  which it reports as supported on Vulkan only, tells them apart), `metal` on iOS and macOS,
  `unknown` under `flutter test`;
- `offscreenMsaa` and `manualMipmaps` (from Flutter GPU): a device without offscreen multisampling
  renders without MSAA, one that cannot sample mip levels uploaded by hand gets textures without
  mipmaps;
- on OpenGL ES, what the driver reports, asked through EGL in a private context: `renderer`,
  `vendor`, `version`, the uniform vectors a vertex and a fragment shader may use
  (`maxVertexUniformVectors`, `maxFragmentUniformVectors`), the textures each may sample, the
  largest texture, its `extensions`, and `shaderExtensions`: the extensions the loaded shaders
  require that the driver really accepts, checked by compiling a small shader that requires each
  one (drivers accept some extensions they do not list, and the reverse).

On OpenGL ES the shaders are GLSL ES 1.00 programs whose uniform blocks become plain uniforms,
limited by those vector counts (OpenGL ES 3.0 guarantees 256 per vertex shader and 224 per fragment
shader). The backend reads from each shader bundle what every shader needs (`shaderRequirements`:
uniform vectors, textures, required extensions) and `GpuBackend.instance.shaderSupport(asset,
entryPoint)` compares it with the device. Every material checks its shaders when it is created:
one the device cannot run throws an `UnsupportedError` that names the shader, what it needs and
what the device allows, instead of drawing nothing; a shader is checked again when it is first
resolved. Watch for:

- the vertex stages that read joint matrices: the skinned layouts and the standard vertex stages of
  `SpatialMaterial`, `UnlitMaterial` and `StylizedMaterial` (`stylized_material_standard`) declare
  64 joint matrices, 269 to 275 vectors in all, more than the 256 an OpenGL ES 3.0 driver may
  offer: such a driver cannot run them (the emulator offers 1,024);
- `WaterMaterial`'s fragment stage uses 197 vectors, `StylizedMaterial`'s 183;
- `SpatialMaterial`'s full shader samples 11 textures and needs `GL_EXT_shader_texture_lod`. On a
  device without it (the emulator) a new `SpatialMaterial` draws with the simpler shader the web
  uses, without the IBL, lightmap, clearcoat, transmission and reflection probe inputs, and prints
  that once (`usesSimpleShader` tells); create materials after `GpuBackend.initialize()` for the
  choice to see the device.

Float render targets: Metal and Vulkan render into 16- and 32-bit float textures (Vulkan requires
it of every device). On OpenGL ES they are not used unless `GpuBackend.probeFloatTargets` is set
before `initialize()`: the backend then checks by rendering, once the app shows its first frame,
whether a 16-bit float target keeps a value above 1 and whether a 32-bit one renders and is
sampled (`floatTextureTargets`, `halfFloatTextureTargets`, and `notes` with what each check read
back; wait for `capabilitiesSettled`). The check runs only when the driver lists
`GL_EXT_color_buffer_half_float` or `GL_EXT_color_buffer_float`, and never on the Android
emulator: there, rendering into a float texture stopped the emulator's GPU (and with it the whole
emulated system). Without float targets `World3D.hdrEnabled` falls back to an 8-bit target and
shadow depths are packed into 8-bit channels.

Impeller's OpenGL ES backend runs the commands of a submitted command buffer when it next renders
a frame, and reports the command buffer complete before: reading a rendered image back at once
(`Image.toByteData`) gives transparent pixels there, a frame or two later the right ones.


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
