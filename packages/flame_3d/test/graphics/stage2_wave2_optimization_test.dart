import 'dart:ui' show Canvas, Color, PictureRecorder, Size;

import 'package:flame/components.dart' show Component;
import 'package:flame/game.dart' show FlameGame;
import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/debug.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/particles.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/world_scale.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart'
    show Frustum, makePerspectiveMatrix, makeViewMatrix;

import '../_fakes/fake_gpu_backend.dart';

class _CustomCullMesh({required super.mesh}) extends MeshComponent {
  bool allowVisible = false;

  @override
  bool isVisible(Frustum frustum) => allowVisible && super.isVisible(frustum);
}

class _CountingNon3DComponent() extends Component {
  int renders = 0;

  @override
  void render(Canvas canvas) {
    renders++;
  }
}

class _TestSkinnedMaterial() extends Material {
  this
    : super(
        vertexShader: VertexShader.fromAsset(
          'test',
          slots: [
            RenderContext3D.cameraMatricesBlock,
            RenderContext3D.jointMatricesBlock,
          ],
        ),
        fragmentShader: FragmentShader.fromAsset(
          'test',
          slots: ['Material'],
        ),
      );

  @override
  void apply(RenderContext context) {}
}

void main() {
  group('Stage 2 Wave 2 optimizations', () {
    test(
      'Component3D keeps children container lazy on leaves and updates AABB',
      () async {
        final mesh = CuboidMesh(
          size: Vector3.all(1),
          material: UnlitMaterial(),
        );
        final leaf = MeshComponent(mesh: mesh, position: Vector3(3, 0, 0));
        final emptyGroup = Group3D();
        // ignore: invalid_use_of_internal_member
        expect(leaf.hasChildrenContainer, isFalse);
        // ignore: invalid_use_of_internal_member
        expect(emptyGroup.hasChildrenContainer, isFalse);
        // ignore: invalid_use_of_internal_member
        expect(leaf.clone().hasChildrenContainer, isFalse);

        final unmounted = Group3D(
          children: [MeshComponent(mesh: mesh, position: Vector3(4, 0, 0))],
        );
        expect(unmounted.aabb.center.x, closeTo(4.0, 1e-4));

        // Mount, remove, and re-mount to verify no duplicate child entries.
        final child = MeshComponent(mesh: mesh, position: Vector3(2, 0, 0));
        final group = Group3D(children: [child]);
        final world = World3D(children: [group]);
        final camera = CameraComponent3D(
          world: world,
          position: Vector3(2, 0, 8),
          target: Vector3(2, 0, 0),
        );
        final game = FlameGame(world: world, camera: camera);
        await game.onLoad();
        world.add(camera);
        game.onGameResize(Vector2(64, 64));
        await game.ready();

        world.remove(group);
        await game.ready();
        world.add(group);
        await game.ready();

        final backend = FakeGpuBackend();
        final device = GraphicsDevice(backend: backend);
        final context = RenderContext3D(device);
        device.begin();
        context.setCamera(camera.viewMatrix, camera.projectionMatrix);
        device.beginPass(const Size(64, 64));
        final recorder = PictureRecorder();
        final canvas = Canvas(recorder);
        world.renderWithHost(device, context, () {
          world.renderScene(canvas, overrideContext: context);
        });
        recorder.endRecording().dispose();
        context.flush();
        device
          ..endPass()
          ..end();

        expect(backend.countCommands('drawIndexed'), 1);
      },
    );

    test(
      'Object3D respects custom isVisible, DebugRenderer3D.enabled, and '
      'hidden ancestor',
      () async {
        final mesh = CuboidMesh(
          size: Vector3.all(1),
          material: UnlitMaterial(),
        );
        final straddlingMesh = CuboidMesh(
          size: Vector3.all(20),
          material: UnlitMaterial(),
        );
        final custom = _CustomCullMesh(mesh: straddlingMesh);
        expect(custom.usesDefaultFrustumVisibility, isFalse);

        final debug = DebugRenderer3D(enabled: false);
        final hiddenChild = MeshComponent(
          mesh: mesh,
          position: Vector3(1, 0, 0),
        );
        final hiddenGroup = Group3D(visible: false, children: [hiddenChild]);
        final world = World3D(children: [custom, debug, hiddenGroup]);
        final camera = CameraComponent3D(
          world: world,
          position: Vector3(0, 0, 6),
          target: Vector3.zero(),
        );
        final game = FlameGame(world: world, camera: camera);
        await game.onLoad();
        world.add(camera);
        game.onGameResize(Vector2(64, 64));
        await game.ready();

        final backend = FakeGpuBackend();
        final device = GraphicsDevice(backend: backend);
        final context = RenderContext3D(device);
        final recorder = PictureRecorder();
        final canvas = Canvas(recorder);

        int drawOnce() {
          backend.commands.clear();
          device.begin();
          context.setCamera(camera.viewMatrix, camera.projectionMatrix);
          device.beginPass(const Size(64, 64));
          world.renderWithHost(device, context, () {
            world.renderScene(canvas, overrideContext: context);
          });
          context.flush();
          device
            ..endPass()
            ..end();
          return backend.countCommands('drawIndexed');
        }

        expect(drawOnce(), 0);
        custom.allowVisible = true;
        expect(drawOnce(), 1);
        hiddenGroup.visible = true;
        expect(drawOnce(), 2);

        recorder.endRecording().dispose();
      },
    );

    test(
      'OcclusionCuller3D culls occluded AABBs, rejects offscreen boxes, and '
      'caches per frame/VP in World3D',
      () {
        final culler = OcclusionCuller3D(width: 64, height: 32);
        final view = makeViewMatrix(
          Vector3(0, 0, 10),
          Vector3.zero(),
          Vector3(0, 1, 0),
        );
        final proj = makePerspectiveMatrix(1.0, 2.0, 0.5, 100.0);
        final vp = proj.multiplied(view);

        // Large wall near z = 0 plus an off-screen box that must not pollute.
        culler
          ..addQuad(
            OccluderQuad3D.wall(
              bottomStart: Vector3(-4, -4, 0),
              bottomEnd: Vector3(4, -4, 0),
              height: 8,
            ),
          )
          ..addBox(
            OccluderBox3D(
              center: Vector3(500, 0, 0),
              halfExtents: Vector3.all(2),
            ),
          );

        final world = World3D(occlusionCuller: culler);
        final backend = FakeGpuBackend();
        final device = GraphicsDevice(backend: backend);
        final context = RenderContext3D(device)..setCamera(view, proj);

        device.begin();
        world.prepareOcclusionCuller(context);
        expect(culler.rasterizedOccluderCount, 2);

        final behind = Aabb3.minMax(
          Vector3(-1, -1, -8),
          Vector3(1, 1, -4),
        );
        final inFront = Aabb3.minMax(
          Vector3(-1, -1, 2),
          Vector3(1, 1, 4),
        );
        expect(culler.isAabbVisible(behind, vp), isFalse);
        expect(culler.isAabbVisible(inFront, vp), isTrue);
        expect(culler.testedCount, 2);

        // Same frame & VP: prepareOcclusionCuller must be a cache hit.
        world.prepareOcclusionCuller(context);
        expect(culler.testedCount, 2);
        device.end();

        // New frame: prepareOcclusionCuller re-rasterizes cleanly.
        device.begin();
        world.prepareOcclusionCuller(context);
        expect(culler.testedCount, 0);
        device.end();

        // Empty culler reports hasOccluders == false and skips rasterizing.
        final empty = OcclusionCuller3D(width: 64, height: 32);
        expect(empty.hasOccluders, isFalse);
        final worldEmpty = World3D(occlusionCuller: empty);
        device.begin();
        worldEmpty.prepareOcclusionCuller(context);
        expect(empty.rasterizedOccluderCount, 0);
        device.end();
      },
    );

    test(
      'Depth-normal prepass skips translucent draws and batches '
      'depthNormalMaterial',
      () {
        final backend = FakeGpuBackend(textureTargets: true);
        final device = GraphicsDevice(backend: backend);
        final context = RenderContext3D(device)
          ..setCamera(Matrix4.identity(), Matrix4.identity());
        final opaqueCube = CuboidMesh(
          size: Vector3.all(1),
          material: UnlitMaterial()..renderState = RenderState.opaque,
        );
        final translucentCube = CuboidMesh(
          size: Vector3.all(1),
          material: UnlitMaterial(albedoColor: const Color(0x80FFFFFF)),
        );
        final particleMat = ParticleMaterial(renderState: RenderState.opaque);
        final p1 = ParticleSystem3D(capacity: 2, material: particleMat)
          ..spawn(position: Vector3.zero(), size: 1);
        final p2 = ParticleSystem3D(capacity: 2, material: particleMat)
          ..spawn(position: Vector3(0.5, 0, 0), size: 1);

        device.begin();
        expect(context.beginDepthNormalPass(64, 64), isTrue);
        context
          ..drawMesh(opaqueCube)
          ..drawMesh(translucentCube);
        p1.draw(context);
        p2.draw(context);
        context.endDepthNormalPass();
        device.end();

        // 1 opaque cube + 2 opaque particles = 3 draws (translucent skipped).
        expect(backend.countCommands('drawIndexed'), 3);
      },
    );

    test(
      'flushOpaquePreview -> flush cache + invalidation, and grab+WBOIT '
      'target reuse',
      () {
        final backend = FakeGpuBackend(textureTargets: true);
        final device = GraphicsDevice(backend: backend);
        final context = RenderContext3D(device)
          ..setCamera(Matrix4.identity(), Matrix4.identity());
        final opaqueCube = CuboidMesh(
          size: Vector3.all(1),
          material: UnlitMaterial()..renderState = RenderState.opaque,
        );
        final transCube = CuboidMesh(
          size: Vector3.all(1),
          material: UnlitMaterial(albedoColor: const Color(0x80FF0000))
            ..renderState = RenderState.alphaBlend,
        );

        // 1. grab + WBOIT at 1x MSAA reuses grabTarget as oitOpaqueTarget.
        final world = World3D(
          hdrEnabled: true,
          grabSceneColorEnabled: true,
          oitMode: OitMode3D.weightedBlended,
        );
        device.begin();
        world
            .executeWorldRenderPipeline(
              device: device,
              renderContext: context,
              width: 64,
              height: 64,
              msaaSampleCount: 1,
              clearValue: const Color(0xFF000000),
              recordDraws: () {
                context
                  ..drawMesh(opaqueCube)
                  ..drawMesh(transCube);
              },
            )
            .dispose();
        device.end();

        // Float targets: grab/oitOpaque + accum + composite scene = 3 (not 4).
        final floatTargets = backend.textureTargetsCreated
            .where((t) => t == (64, 64, GpuPixelFormat.rgbaFloat16))
            .length;
        expect(floatTargets, 3);

        // 2. Adding a draw after flushOpaquePreview invalidates opaque sort.
        backend.commands.clear();
        device.begin();
        final target = device.textureTarget(
          64,
          64,
          GpuPixelFormat.rgba8888,
          role: 'test',
        );
        device.beginTexturePass(target);
        context.drawMesh(opaqueCube);
        context.flushOpaquePreview();
        expect(backend.countCommands('drawIndexed'), 1);
        context.drawMesh(
          opaqueCube,
          transform: Matrix4.translationValues(1, 0, 0),
        );
        context.flush();
        device.endTexturePass();
        device.end();
        expect(
          backend.commands.where((c) => c.startsWith('drawIndexed')).last,
          endsWith('x2'),
        );
      },
    );

    test(
      'World3D.renderToImage & RenderTexture3D work with and without '
      'non-Component3D children',
      () {
        final backend = FakeGpuBackend(textureTargets: true);
        final device = GraphicsDevice(backend: backend);
        final context = RenderContext3D(device);
        final mesh = CuboidMesh(
          size: Vector3.all(1),
          material: UnlitMaterial(),
        );
        final world = World3D(
          children: [
            Group3D(children: [MeshComponent(mesh: mesh)]),
          ],
        );
        final rtt = RenderTexture3D(width: 16, height: 16);

        device.begin();
        final ok1 = rtt.renderWorld(
          world,
          view: Matrix4.identity(),
          projection: Matrix4.identity(),
          device: device,
          context: context,
        );
        backend.commands.clear();
        final img1 = world.renderToImage(
          const Size(16, 16),
          view: Matrix4.identity(),
          projection: Matrix4.identity(),
          device: device,
          context: context,
        );
        device.end();
        img1.dispose();
        expect(ok1, isTrue);
        expect(backend.countCommands('drawIndexed'), greaterThanOrEqualTo(1));

        // Now add a non-Component3D child: triggers fallback canvas cleanly.
        final non3d = _CountingNon3DComponent();
        world.add(non3d);
        device.begin();
        final ok2 = rtt.renderWorld(
          world,
          view: Matrix4.identity(),
          projection: Matrix4.identity(),
          device: device,
          context: context,
        );
        final img2 = world.renderToImage(
          const Size(16, 16),
          view: Matrix4.identity(),
          projection: Matrix4.identity(),
          device: device,
          context: context,
        );
        device.end();
        img2.dispose();
        expect(ok2, isTrue);
        expect(non3d.renders, 2);
      },
    );

    test(
      'RenderGraph3D.execute pools and evicts unused targets cleanly',
      () {
        final backend = FakeGpuBackend(textureTargets: true);
        final device = GraphicsDevice(backend: backend);
        final context = RenderContext3D(device);
        final graph = RenderGraph3D();

        void runSize(int size) {
          final handle = graph.createTexture(
            'color',
            RenderGraphTextureDesc3D(width: size, height: size),
          );
          GpuTextureTarget? seenTarget;
          graph.addRenderPass(
            name: 'pass',
            writes: [handle],
            hasSideEffects: true,
            execute: (ctx) {
              seenTarget = ctx.targetOf(handle);
            },
          );
          device.begin();
          graph.execute(device, context);
          device.end();
          expect(seenTarget, isNotNull);
          graph.clear();
        }

        runSize(32);
        runSize(32);
        expect(backend.textureTargetsCreated, hasLength(1));

        for (var i = 0; i < RenderGraph3D.targetRetainExecutions; i++) {
          runSize(48);
        }
        expect(backend.textureTargetsCreated, hasLength(2));

        // 32x32 pool entry was evicted and must allocate a fresh target.
        runSize(32);
        expect(backend.textureTargetsCreated, hasLength(3));
      },
    );

    test(
      'Joint hash O(1) handles -0.0 and middle-joint mutations without '
      'aliasing stale GPU buffers',
      () {
        final backend = FakeGpuBackend(blockSize: 64 * 1024);
        final device = GraphicsDevice(backend: backend);
        final context = RenderContext3D(device)
          ..setCamera(Matrix4.identity(), Matrix4.identity());
        final mat = _TestSkinnedMaterial();
        final surface = Surface(
          vertices: [
            Vertex(position: Vector3.zero(), texCoord: Vector2.zero()),
            Vertex(position: Vector3(1, 0, 0), texCoord: Vector2.zero()),
            Vertex(position: Vector3(0, 1, 0), texCoord: Vector2.zero()),
          ],
          indices: [0, 1, 2],
          material: mat,
        );

        final j1 = List.generate(5, (_) => Matrix4.identity());
        final j2 = List.generate(5, (_) => Matrix4.identity());
        j2[0].storage[12] = -0.0;
        final j3 = List.generate(5, (_) => Matrix4.identity());
        // Mutate unsampled middle joint index 1 (sampled are 0, 2, 4).
        j3[1].storage[12] = 7.0;

        device.begin();
        device.beginPass(const Size(64, 64));
        context
          ..drawSurface(surface, jointTransforms: j1)
          ..flush();
        final afterFirst = device.stats.uniformUploads;

        // -0.0 matches +0.0 and reuses the slice without another upload.
        context
          ..drawSurface(surface, jointTransforms: j2)
          ..flush();
        expect(device.stats.uniformUploads, afterFirst);

        // Mutated unsampled joint 1 must miss snapshot check and upload j3.
        context
          ..drawSurface(surface, jointTransforms: j3)
          ..flush();
        expect(device.stats.uniformUploads, greaterThan(afterFirst));
        device.endPass();
        device.end();

        final uploaded = backend.uniforms[RenderContext3D.jointMatricesBlock]!;
        final base =
            mat.vertexShader
                .slot(RenderContext3D.jointMatricesBlock)
                .getMemberOffsetInBytes(RenderContext3D.jointRowsMember)! ~/
            4;
        expect(uploaded[base + 12 + 3], closeTo(7.0, 1e-5));
      },
    );

    test(
      'StylizedMaterial windTime advance updates Wind without rewriting '
      'fragment Material block',
      () {
        final backend = FakeGpuBackend();
        final device = GraphicsDevice(backend: backend);
        final context = RenderContext3D(device)
          ..setCamera(Matrix4.identity(), Matrix4.identity());
        final mat = StylizedMaterial(windAmplitude: 0.05);
        final surface = StylizedMaterial.buildSurface(
          positions: [0, 0, 0, 1, 0, 0, 0, 1, 0],
          normals: [0, 0, 1, 0, 0, 1, 0, 0, 1],
          indices: [0, 1, 2],
          material: mat,
        );
        final fragBlock = mat.fragmentShader.block('Material');
        final windBlock = mat.vertexShader.block('Wind');

        device.begin();
        device.beginPass(const Size(16, 16));
        context
          ..drawSurface(surface)
          ..flush();
        expect(fragBlock.isDirty, isFalse);
        expect(windBlock.isDirty, isFalse);
        final uploadsAfterInitial = device.stats.uniformUploads;

        // Advancing only windTime inside the same frame dirties only Wind,
        // leaving the fragment Material block untouched (1 upload, not 2).
        mat.windTime = 2.5;
        context
          ..drawSurface(surface)
          ..flush();
        expect(device.stats.uniformUploads, uploadsAfterInitial + 1);
        expect(fragBlock.isDirty, isFalse);
        final timeOff = windBlock.resolveOffset('time');
        expect(windBlock.data[timeOff], closeTo(2.5, 1e-5));

        // Mutating a fragment property re-writes and uploads Material too.
        final uploadsBeforeAlbedo = device.stats.uniformUploads;
        mat.albedoColor = const Color(0xFF336699);
        context
          ..drawSurface(surface)
          ..flush();
        expect(
          device.stats.uniformUploads,
          greaterThan(uploadsBeforeAlbedo + 1),
        );
        final albedoOff = fragBlock.resolveOffset('albedoColor');
        expect(fragBlock.data[albedoOff], closeTo(0x33 / 255.0, 1e-4));

        device
          ..endPass()
          ..end();
      },
    );
  });
}
