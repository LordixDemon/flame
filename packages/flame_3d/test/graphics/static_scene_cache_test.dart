import 'dart:typed_data';
import 'dart:ui' show Color, Rect;

import 'package:flame/game.dart' show FlameGame;
import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/game.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/particles.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_test/flame_test.dart';
import 'package:flutter/painting.dart' show Canvas;
import 'package:flutter_test/flutter_test.dart';

import '../_fakes/fake_gpu_backend.dart';

void main() {
  group('World3D static scene cache', () {
    late FakeGpuBackend backend;
    late GraphicsDevice device;
    late RenderContext3D context;
    late Matrix4 perspective;

    setUp(() {
      backend = FakeGpuBackend(textureTargets: true);
      device = GraphicsDevice(backend: backend);
      perspective = Matrix4.identity()..setAsPerspective(60.0, 1.0, 0.5, 50.0);
      context = RenderContext3D(device)
        ..setCamera(Matrix4.identity(), perspective);
    });

    RenderStats renderPass(
      World3D world, {
      required void Function() record,
    }) {
      context.setCamera(Matrix4.identity(), perspective);
      device.begin();
      world
          .executeWorldRenderPipeline(
            device: device,
            renderContext: context,
            width: 64,
            height: 64,
            msaaSampleCount: 1,
            clearValue: const Color(0x00000000),
            recordDraws: record,
          )
          .dispose();
      device.end();
      return RenderStats()..setFrom(device.lastFrameStats);
    }

    test('warms up for stillFrames, populates, and hits thereafter', () {
      final staticMat = StylizedMaterial(
        albedoColor: const Color(0xFFCC4444),
        windAmplitude: 0,
      );
      final staticMesh = CuboidMesh(size: Vector3.all(1), material: staticMat);
      final dynamicMat = StylizedMaterial(
        albedoColor: const Color(0xFF44CC44),
        windAmplitude: 0,
      );
      final dynamicMesh = CuboidMesh(
        size: Vector3.all(0.5),
        material: dynamicMat,
      );

      final world = World3D(staticSceneCache: StaticSceneCacheSettings());

      void record() {
        context.currentObjectDynamic = false;
        context.drawMesh(
          staticMesh,
          transform: Matrix4.translationValues(0, 0, -5),
        );
        context.currentObjectDynamic = true;
        context.drawMesh(
          dynamicMesh,
          transform: Matrix4.translationValues(1, 0, -5),
        );
        context.currentObjectDynamic = false;
      }

      // Frame 1: warm-up miss (stillCount = 1 < 2), direct draw.
      final f1 = renderPass(world, record: record);
      expect(f1.staticCacheHits, 0);
      expect(f1.staticCacheMisses, 1);

      // Frame 2: populate miss (stillCount = 2), creates static color + depth
      // targets and composites static_restore + dynamic mesh.
      final f2 = renderPass(world, record: record);
      expect(f2.staticCacheHits, 0);
      expect(f2.staticCacheMisses, 1);

      // Frame 3+: cache hit; static draw skipped, 1 static_restore + 1 dynamic.
      final f3 = renderPass(world, record: record);
      expect(f3.staticCacheHits, 1);
      expect(f3.staticCacheMisses, 0);
      expect(f3.drawCalls, 2);

      // Changing a static material invalidates static cache on next frame.
      staticMat.emissiveStrength = 1.5;
      final f4 = renderPass(world, record: record);
      expect(f4.staticCacheHits, 0);
      expect(f4.staticCacheMisses, 1);
    });

    test(
      'dynamic objects, particles, and water time preserve staticSceneVersion',
      () {
        final staticObj = MeshComponent(
          mesh: CuboidMesh(
            size: Vector3.all(1),
            material: StylizedMaterial(),
          ),
        );
        final dynObj = MeshComponent(
          mesh: CuboidMesh(
            size: Vector3.all(1),
            material: StylizedMaterial(),
          ),
        )..sceneCacheMotion = SceneCacheMotion.dynamic;
        final waterVol = WaterVolumeSettings();
        final particles = ParticleSystem3D(
          capacity: 16,
          material: ParticleMaterial(),
        );

        final world = World3D(waterVolume: waterVol)
          ..addAll([staticObj, dynObj, particles]);
        world.onMount();
        for (final c in [staticObj, dynObj, particles]) {
          c.onMount();
        }

        final v0 = world.staticSceneVersion;
        final s0 = world.sceneVersion;

        // Dynamic transform, visibility, water time, and particle mutation must
        // bump sceneVersion without changing staticSceneVersion.
        dynObj.position.setValues(2, 0, -4);
        dynObj.markDrawDirty();
        waterVol.time += 0.25;
        particles.markDrawDirty(shadows: false);
        world.markDynamicSceneDirty();

        expect(world.sceneVersion, greaterThan(s0));
        expect(world.staticSceneVersion, v0);

        // Water volume level change & static object move MUST bump
        // staticSceneVersion.
        waterVol.level = 0.5;
        expect(world.staticSceneVersion, greaterThan(v0));
        final v1 = world.staticSceneVersion;

        staticObj.position.setValues(1, 0, -4);
        expect(world.staticSceneVersion, greaterThan(v1));
      },
    );

    test(
      'Object3D.sceneCacheMotion skips static subtrees via '
      'mayHaveDynamicDescendant',
      () {
        final world = World3D(
          staticSceneCache: StaticSceneCacheSettings(stillFrames: 1),
        );
        var staticDraws = 0;
        var dynDraws = 0;

        final staticRoot = _CountingBox(onDraw: () => staticDraws++);
        final dynChild = _CountingBox(
          onDraw: () => dynDraws++,
          sceneCacheMotion: SceneCacheMotion.dynamic,
        );
        final mixedParent = Group3D(children: [dynChild]);

        world.addAll([staticRoot, mixedParent]);
        world.onMount();
        staticRoot.onMount();
        mixedParent.onMount();
        dynChild.onMount();
        world.update(0.016);

        world.renderWithHost(device, context, () {
          context
            ..trackDynamicSubtrees = true
            ..skipStaticDraws = false;
          world.renderSceneNoCanvas(overrideContext: context);
          context.trackDynamicSubtrees = false;
          expect(staticRoot.mayHaveDynamicDescendant, isFalse);
          expect(mixedParent.mayHaveDynamicDescendant, isTrue);
          expect(staticDraws, 1);
          expect(dynDraws, 1);

          // On hit frame (`skipStaticDraws == true`), staticRoot is skipped
          // while mixedParent -> dynChild still executes.
          context.skipStaticDraws = true;
          world.renderSceneNoCanvas(overrideContext: context);
          context.skipStaticDraws = false;
          expect(staticDraws, 1);
          expect(dynDraws, 2);
        });
      },
    );

    test(
      'keeps non-wind surfaces cached across windTime ticks while keeping '
      'wind-vertex surfaces dynamic',
      () {
        final windMat = StylizedMaterial(
          albedoColor: const Color(0xFF4488CC),
          windAmplitude: 0.05,
        );
        final staticSurface = StylizedMaterial.buildSurface(
          positions: const [0, 0, 0, 1, 0, 0, 0, 1, 0],
          normals: const [0, 0, 1, 0, 0, 1, 0, 0, 1],
          indices: const [0, 1, 2],
          material: windMat,
        );
        final windSurface = StylizedMaterial.buildSurface(
          positions: const [0, 0, 0, 1, 0, 0, 0, 1, 0],
          normals: const [0, 0, 1, 0, 0, 1, 0, 0, 1],
          indices: const [0, 1, 2],
          sway: const [0, 0.5, 0.5],
          material: windMat,
        );
        expect(staticSurface.hasVertexAnimation, isFalse);
        expect(windSurface.hasVertexAnimation, isTrue);

        var staticDraws = 0;
        var windDraws = 0;
        final staticBox = _CountingSurfaceBox(
          surface: staticSurface,
          onDraw: () => staticDraws++,
        );
        final windBox = _CountingSurfaceBox(
          surface: windSurface,
          onDraw: () => windDraws++,
        );
        final world = World3D(
          staticSceneCache: StaticSceneCacheSettings(stillFrames: 1),
          children: [staticBox, windBox],
        );
        world.onMount();
        staticBox.onMount();
        windBox.onMount();
        world.update(0.016);

        world.renderWithHost(device, context, () {
          void recordScene() => world.renderSceneNoCanvas(
            overrideContext: context,
          );

          // Frame 1: warms staticSurface while windSurface stays dynamic.
          final f1 = renderPass(world, record: recordScene);
          expect(f1.staticCacheMisses, 1);
          expect(f1.staticCacheHits, 0);
          expect(staticBox.mayHaveDynamicDescendant, isFalse);
          expect(windBox.mayHaveDynamicDescendant, isTrue);
          expect(staticDraws, 1);
          expect(windDraws, 1);
          final staticVerAfterF1 = world.staticSceneVersion;

          // Advance windTime only: static cache stays hot and skips staticBox.
          windMat.windTime = 1.5;
          expect(world.staticSceneVersion, staticVerAfterF1);
          final f2 = renderPass(world, record: recordScene);
          expect(world.staticSceneCacheMissReason, isNull);
          expect(f2.staticCacheHits, 1);
          expect(world.staticSceneVersion, staticVerAfterF1);
          expect(staticDraws, 1);
          expect(windDraws, 2);

          // Non-animation material change invalidates static cache.
          windMat.albedoColor = const Color(0xFF223344);
          final f3 = renderPass(world, record: recordScene);
          expect(f3.staticCacheHits, 0);
          expect(f3.staticCacheMisses, 1);
        });
      },
    );

    test(
      'hasUnsettledStaticCasters ignores SceneCacheMotion.dynamic movers and '
      'tracks auto static casters until settled',
      () {
        final dynamicCaster = _CountingBox(
          onDraw: () {},
          sceneCacheMotion: SceneCacheMotion.dynamic,
        );
        final staticCaster = _CountingBox(onDraw: () {});
        final world = World3D(children: [dynamicCaster, staticCaster]);
        world.onMount();
        dynamicCaster.onMount();
        staticCaster.onMount();

        final casters = world.shadowCasters;
        expect(casters.hasUnsettledStaticCasters, isTrue);

        // Advance and prepare across 2 frames: staticCaster settles, while a
        // freshly moved dynamicCaster stays in movers without blocking.
        casters
          ..prepare(2)
          ..advance()
          ..prepare(2)
          ..advance()
          ..prepare(2);
        expect(casters.hasUnsettledStaticCasters, isFalse);

        dynamicCaster.position.setValues(1, 0, 0);
        expect(casters.hasUnsettledStaticCasters, isFalse);

        staticCaster.position.setValues(0, 1, 0);
        expect(casters.hasUnsettledStaticCasters, isTrue);
      },
    );

    test(
      'bypasses static scene cache when backend.supportsFragDepth is false',
      () {
        final noFragDepthBackend = FakeGpuBackend(
          textureTargets: true,
          fragDepth: false,
        );
        final noDepthDevice = GraphicsDevice(backend: noFragDepthBackend);
        final noDepthContext = RenderContext3D(noDepthDevice)
          ..setCamera(Matrix4.identity(), perspective);
        final staticMesh = CuboidMesh(
          size: Vector3.all(1),
          material: StylizedMaterial(
            albedoColor: const Color(0xFFCC4444),
            windAmplitude: 0,
          ),
        );
        final world = World3D(
          staticSceneCache: StaticSceneCacheSettings(stillFrames: 1),
        );

        void record() {
          noDepthContext.drawMesh(
            staticMesh,
            transform: Matrix4.translationValues(0, 0, -5),
          );
        }

        for (var i = 0; i < 3; i++) {
          noDepthContext.setCamera(Matrix4.identity(), perspective);
          noDepthDevice.begin();
          world
              .executeWorldRenderPipeline(
                device: noDepthDevice,
                renderContext: noDepthContext,
                width: 64,
                height: 64,
                msaaSampleCount: 1,
                clearValue: const Color(0x00000000),
                recordDraws: record,
              )
              .dispose();
          noDepthDevice.end();
          final stats = noDepthDevice.lastFrameStats;
          expect(stats.staticCacheHits, 0);
          expect(stats.staticCacheMisses, 0);
          expect(stats.drawCalls, 1);
        }
      },
    );

    test(
      'GpuDeviceCapabilities.supportsOpenGlEs3 parses GL_VERSION safely',
      () {
        expect(
          const GpuDeviceCapabilities(
            api: GpuGraphicsApi.openGLES,
            version: 'OpenGL ES 3.1 (4.5.0 NVIDIA 616.56)',
          ).supportsOpenGlEs3,
          isTrue,
        );
        expect(
          const GpuDeviceCapabilities(
            api: GpuGraphicsApi.openGLES,
            version: 'OpenGL ES 3.2 v1.r32p1',
          ).supportsOpenGlEs3,
          isTrue,
        );
        expect(
          const GpuDeviceCapabilities(
            api: GpuGraphicsApi.openGLES,
            version: 'OpenGL ES 2.0 build 1.10',
          ).supportsOpenGlEs3,
          isFalse,
        );
        expect(
          const GpuDeviceCapabilities(
            api: GpuGraphicsApi.openGLES,
          ).supportsOpenGlEs3,
          isFalse,
        );
        expect(
          const GpuDeviceCapabilities(
            api: GpuGraphicsApi.vulkan,
            version: 'OpenGL ES 3.1',
          ).supportsOpenGlEs3,
          isFalse,
        );
      },
    );

    test(
      'Object3D.shadowAabb tightens movingBounds and skips inverted boxes',
      () {
        final sun = LightComponent.directional(
          direction: Vector3(0.3, -0.4, -0.85)..normalize(),
          shadows: ShadowSettings(
            resolution: 256,
            fit: ShadowFit.fixed,
            bounds: Aabb3.minMax(Vector3(-10, -10, -2), Vector3(10, 10, 2)),
            casterBounds: Aabb3.minMax(
              Vector3(-12, -12, -4),
              Vector3(12, 12, 4),
            ),
            cacheStillCasters: true,
          ),
        );
        final staticBox = _CountingBox(onDraw: () {});
        final tightMover = _ShadowAabbBox(
          bounds: Aabb3.minMax(Vector3(-9, -9, -1), Vector3(9, 9, 1)),
          shadowBounds: Aabb3.minMax(
            Vector3(-0.5, -0.5, 0),
            Vector3(0.5, 0.5, 1),
          ),
        )..sceneCacheMotion = SceneCacheMotion.dynamic;
        final nonCastingMover = _ShadowAabbBox(
          bounds: Aabb3.minMax(Vector3(-9, -9, -1), Vector3(9, 9, 1)),
          shadowBounds: Aabb3.minMax(Vector3(1, 1, 1), Vector3(-1, -1, -1)),
        )..sceneCacheMotion = SceneCacheMotion.dynamic;

        final world = World3D(
          staticSceneCache: StaticSceneCacheSettings(stillFrames: 1),
          children: [sun, staticBox, tightMover, nonCastingMover],
        );
        world.onMount();
        for (final c in [sun, staticBox, tightMover, nonCastingMover]) {
          c.onMount();
        }
        world.update(0.016);

        void runFrame() {
          context.setCamera(Matrix4.identity(), perspective);
          device.begin();
          world.renderShadowsNoCanvas(overrideContext: context);
          world
              .executeWorldRenderPipeline(
                device: device,
                renderContext: context,
                width: 64,
                height: 64,
                msaaSampleCount: 1,
                clearValue: const Color(0x00000000),
                recordDraws: () =>
                    world.renderSceneNoCanvas(overrideContext: context),
              )
              .dispose();
          device.end();
        }

        // Frame 1: settles static casters; frame 2: populates static cache &
        // uses still+moving shadow maps -> computes tight movingBounds.
        world.renderWithHost(device, context, () {
          runFrame();
          runFrame();
          final bTight = world.staticSceneCacheMovingBounds.clone();
          expect(bTight.z - bTight.x, lessThan(0.25));
          expect(bTight.w - bTight.y, lessThan(0.25));

          // Expanding only the inverted caster does not widen movingBounds.
          nonCastingMover.position.setValues(5, 5, 0);
          runFrame();
          final bAfterSkipped = world.staticSceneCacheMovingBounds;
          expect(bAfterSkipped.x, closeTo(bTight.x, 1e-6));
          expect(bAfterSkipped.z, closeTo(bTight.z, 1e-6));
        });
      },
    );

    testWithGame<_FakeGame3D>(
      'Scene3DComponent.measureRenderTime = false skips timing',
      () => _FakeGame3D(device, context),
      (game) async {
        var draws = 0;
        final layer = Scene3DComponent(
          projection: Scene3DProjection.affine(
            origin: Vector2(64, 64),
            xAxis: Vector2(20, 10),
            yAxis: Vector2(-20, 10),
            zAxis: Vector2(0, -20),
            towardsViewer: Vector3(1, 1, 1),
            near: -20,
            far: 20,
          ),
        )..measureRenderTime = false;
        await game.ensureAdd(layer);
        await layer.world.ensureAdd(_CountingBox(onDraw: () => draws++));
        await game.ready();
        game.update(0.016);

        game.render(_FakeCanvas());

        expect(draws, greaterThan(0));
        expect(layer.measureRenderTime, isFalse);
        expect(layer.lastRenderTime, Duration.zero);
      },
    );
  });
}

class _CountingSurfaceBox({
  required Surface surface,
  required this.onDraw,
}) extends Object3D {
  final void Function() onDraw;
  final Mesh _mesh = Mesh()..addSurface(surface);

  @override
  Aabb3 computeLocalAabb() =>
      Aabb3.minMax(Vector3(-1, -1, -6), Vector3(2, 2, -4));

  @override
  void draw(RenderContext context) {
    onDraw();
    (context as RenderContext3D).drawMesh(
      _mesh,
      transform: Matrix4.translationValues(0, 0, -5),
    );
  }
}

class _CountingBox({
  required this.onDraw,
  super.sceneCacheMotion,
}) extends Object3D {
  final void Function() onDraw;
  final Mesh _mesh = CuboidMesh(
    size: Vector3.all(1),
    material: StylizedMaterial(windAmplitude: 0),
  );

  @override
  Aabb3 computeLocalAabb() => Aabb3.minMax(Vector3.all(-1), Vector3.all(1));

  @override
  void draw(RenderContext context) {
    onDraw();
    (context as RenderContext3D).drawMesh(
      _mesh,
      transform: worldTransformMatrix,
    );
  }
}

class _ShadowAabbBox({
  required this.bounds,
  required this.shadowBounds,
}) extends Object3D {
  final Aabb3 bounds;
  final Aabb3 shadowBounds;
  final Mesh _mesh = CuboidMesh(
    size: Vector3.all(1),
    material: StylizedMaterial(windAmplitude: 0),
  );

  @override
  Aabb3 computeLocalAabb() => bounds;

  @override
  Aabb3? get shadowAabb => shadowBounds;

  @override
  void draw(RenderContext context) {
    (context as RenderContext3D).drawMesh(
      _mesh,
      transform: worldTransformMatrix,
    );
  }
}

class _FakeGame3D(this.fakeDevice, this.fakeContext)
    extends FlameGame
    with Game3D {
  final GraphicsDevice fakeDevice;
  final RenderContext3D fakeContext;

  @override
  GraphicsDevice get device => fakeDevice;

  @override
  RenderContext3D get context => fakeContext;
}

class _FakeCanvas() implements Canvas {
  final Float64List _identity = Float64List.fromList([
    1,
    0,
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    0,
    1,
  ]);

  @override
  Float64List getTransform() => _identity;

  @override
  Rect getDestinationClipBounds() => const Rect.fromLTWH(0, 0, 128, 128);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
