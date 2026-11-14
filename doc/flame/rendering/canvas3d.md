# Canvas3D (Impeller-Native 3D Rendering & Raycasting)

`package:flame/canvas3d.dart` provides a zero-allocation 3D camera, mesh, lighting, particle, and
spatial raycast-picking pipeline built directly on Flutter's standard `Canvas.drawVertices` and
`Canvas.drawRawAtlas` APIs — running at 60–120 Hz on Impeller, Skia, desktop, mobile, and web
without requiring experimental `--enable-flutter-gpu` flags.


## Importing Canvas3D

```dart
import 'package:flame/canvas3d.dart';
```


## CameraRig3D and DirectionalLight3D

`CameraRig3D` projects 3D world coordinates `(x, y, z)` (with `Z` up) onto Flame's 2D world canvas
via orthographic/axonometric tilt (`pitchDeg`, `yawDeg`, `pixelsPerUnit`) with optional perspective
foreshortening (`perspective`), and unprojects 2D canvas coordinates back into `Ray3D` world rays.

`CameraRig3D.basisVersion` increments only when camera orientation, scale, or perspective changes
(never on pure 2D camera pans `camWorldX` / `camWorldY`), while `DirectionalLight3D.version`
increments whenever light direction, intensity, ambient, or hemisphere parameters change.

```dart
final camera3d = CameraRig3D(
  pitchDeg: 55.0,
  yawDeg: -45.0,
  pixelsPerUnit: 32.0,
  perspective: 0.0012,
);

final sunLight = DirectionalLight3D(
  dirX: -0.45,
  dirY: -0.60,
  dirZ: 0.66,
  intensity: 1.15,
  ambient: 0.35,
);
```


## Mesh3D and Procedural / Binary `.dmesh` Geometry

`Mesh3D` stores indexed 3D triangle geometry in flat `Float32List` / `Uint16List` buffers with
automatic smooth or flat face normals and precomputed local `Aabb3D` bounds:

- Built-in generators: `Mesh3D.box(...)`, `Mesh3D.cylinder(...)`, `Mesh3D.cone(...)`,
  `Mesh3D.uvSphere(...)`, `Mesh3D.torus(...)`, and `Mesh3D.extrudePolygon(...)`.
- Binary loader: `Mesh3D.fromDMeshBytes(Uint8List bytes)` parses compact `.dmesh` binary assets.

```dart
final towerMesh = Mesh3D.cylinder(
  radiusTop: 0.55,
  radiusBottom: 0.72,
  height: 2.4,
  segments: 16,
);
```


## MatCapShader3D and BatchMeshRenderer3D

`MatCapShader3D` generates a procedural sphere-mapped metallic/ceramic/toon lookup texture once on
the GPU (`ensureInitialized()` / `dispose()`), mapping view-space surface normals to `(u, v)`
coordinates.

`BatchMeshRenderer3D` transforms, back-face culls, shades (Lambertian + Blinn-Phong + hemisphere
fill + view-angle Fresnel rim highlight), depth-sorts by painter centroid across *all* enqueued
meshes in a pass, and issues **a single `Canvas.drawVertices(Vertices.raw(...))` draw call**:

```dart
final matCap = MatCapShader3D.gold()..ensureInitialized();
final batcher = BatchMeshRenderer3D();

// Inside render(Canvas canvas):
batcher.beginFrame(camera: camera3d, light: sunLight);

batcher.enqueueMesh(
  mesh: towerMesh,
  worldX: 4.0,
  worldY: -2.0,
  worldZ: 0.0,
  yawRad: 0.35,
  baseColor: const Color(0xFFE8EEF5),
  rimColor: const Color(0xFFFFD54F),
  rimHighlightIntensity: isHovered ? 0.65 : 0.0,
  rimPower: 2.4,
);

batcher.flush(
  canvas,
  shader: matCap.shader,
  blendMode: BlendMode.modulate,
);
```

Telemetry counters (`lastFlushedTriangleCount`, `lastFlushedMeshCount`, `lastDrawCallCount`) are
updated on every `flush()` with zero per-frame heap allocations.


## StaticMeshChunk3D (Cached World Chunks)

For static or semi-static 3D scenery (board tiles, walls, pillars, trees, beacons),
`StaticMeshChunk3D` caches back-face culling, normal transformation, Lambert/rim vertex colors,
and camera-space depth centroids across frames:

- **Stationary camera & light**: `0` lighting computations and `0` projections per frame (`O(1)`
  memcpy into the active `BatchMeshRenderer3D` buffers).
- **Pure 2D camera pan (`camWorldX` / `camWorldY` changed, `basisVersion` & `light.version`
  unchanged)**: cached lighting colors and normals are preserved; only the 2D screen offset is
  shifted!

```dart
final chunk = StaticMeshChunk3D()
  ..addInstance(
    mesh: pillarMesh,
    worldX: -6.0,
    worldY: -6.0,
    worldZ: 0.0,
    baseColor: const Color(0xFFCFD8DC),
  )
  ..addInstance(
    mesh: pillarMesh,
    worldX: 6.0,
    worldY: -6.0,
    worldZ: 0.0,
    baseColor: const Color(0xFFCFD8DC),
  );

// Inside render(Canvas canvas):
batcher.beginFrame(camera: camera3d, light: sunLight);
batcher.enqueueStaticChunk(chunk);
batcher.flush(canvas, shader: matCap.shader);
```


## 3D Spatial Raycast Picking (`SpatialHitbox3D`)

Attach `CameraComponent.rayProjector3D` to unproject 2D pointer locations into `Ray3D` rays, and mix
`SpatialHitbox3D` into 3D components alongside Flame's standard `TapCallbacks`, `DragCallbacks`, or
`HoverCallbacks`. Flame automatically sorts overlapping 3D components by ray entry distance `t`
(closest 3D surface wins, independent of 2D tree order) and Supports Möller–Trumbore triangle
tests via `Mesh3D.intersectRay`:

```dart
camera.rayProjector3D = (cam, worldPoint) =>
    camera3d.unprojectWorldRay(Offset(worldPoint.x, worldPoint.y));

class InteractiveTower extends PositionComponent
    with SpatialHitbox3D, HoverCallbacks, TapCallbacks {
  InteractiveTower(this.mesh);
  final Mesh3D mesh;

  @override
  bool get stopHoverPropagation => true;

  @override
  Aabb3D get worldBounds3D => Aabb3D.fromCenterExtents(
    centerX: worldX,
    centerY: worldY,
    centerZ: 1.2,
    halfX: 0.8,
    halfY: 0.8,
    halfZ: 1.2,
  );

  @override
  double? intersectRay3D(Ray3D ray) =>
      mesh.intersectRay(ray, translateX: worldX, translateY: worldY);
}
```


## ParticlePool3D

`ParticlePool3D` simulates up to thousands of 3D particles with gravity, floor bounce, drag, and
camera-depth sorting in contiguous Struct-of-Arrays `Float32List` columns, rendering the entire
cloud in a single `Canvas.drawRawAtlas` call.
