import 'dart:typed_data';
import 'dart:ui';

import 'package:flame_3d/camera.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/particles.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_fakes/fake_gpu_backend.dart';

void main() {
  group('World3D render pipeline', () {
    late FakeGpuBackend backend;
    late GraphicsDevice device;
    late RenderContext3D context;

    setUp(() {
      backend = FakeGpuBackend(textureTargets: true);
      device = GraphicsDevice(backend: backend);
      context = RenderContext3D(device)
        ..setCamera(Matrix4.identity(), Matrix4.identity());
    });

    int fullSizeTargets(GpuPixelFormat format) => backend.textureTargetsCreated
        .where((t) => t == (64, 64, format))
        .length;

    void render(World3D world, {required Color clearValue, Mesh? mesh}) {
      device.begin();
      world
          .executeWorldRenderPipeline(
            device: device,
            renderContext: context,
            width: 64,
            height: 64,
            msaaSampleCount: 1,
            clearValue: clearValue,
            recordDraws: () {
              if (mesh != null) {
                context.drawMesh(mesh);
              }
            },
          )
          .dispose();
      device.end();
    }

    test('gives the grab pass and the scene target different targets', () {
      final world = World3D(
        grabSceneColorEnabled: true,
        postProcess: PostProcessSettings(exposure: 1.2),
      );
      render(world, clearValue: const Color(0xFF102030));

      expect(fullSizeTargets(GpuPixelFormat.rgba8888), 2);
    });

    test('gives every order-independent transparency pass its own target '
        'with HDR', () {
      final world = World3D(
        hdrEnabled: true,
        oitMode: OitMode3D.weightedBlended,
      );
      render(
        world,
        clearValue: const Color(0x00000000),
        mesh: CuboidMesh(
          size: Vector3.all(1),
          material: UnlitMaterial(albedoColor: const Color(0x80800000)),
        ),
      );

      // The opaque draws, the accumulation and the composited scene.
      expect(fullSizeTargets(GpuPixelFormat.rgbaFloat16), 3);
      // The revealage.
      expect(fullSizeTargets(GpuPixelFormat.rgba8888), 1);
    });

    test('sorts translucent draws without float targets', () {
      backend = FakeGpuBackend(
        textureTargets: true,
        floatTextureTargets: false,
      );
      device = GraphicsDevice(backend: backend);
      context = RenderContext3D(device)
        ..setCamera(Matrix4.identity(), Matrix4.identity());
      final world = World3D(oitMode: OitMode3D.weightedBlended);
      render(
        world,
        clearValue: const Color(0x00000000),
        mesh: CuboidMesh(
          size: Vector3.all(1),
          material: UnlitMaterial(albedoColor: const Color(0x80800000)),
        ),
      );

      expect(backend.textureTargetsCreated, isEmpty);
      expect(backend.countCommands('setBlendState wboit'), 0);
    });
  });

  group('depth-normal prepass', () {
    test('leaves out draws whose instances are not model matrices', () {
      final backend = FakeGpuBackend(textureTargets: true);
      final device = GraphicsDevice(backend: backend);
      final context = RenderContext3D(device)
        ..setCamera(Matrix4.identity(), Matrix4.identity());
      // An opaque particle material without a depth-normal material: soft
      // particles stay out of the prepass.
      final material = ParticleMaterial(
        renderState: RenderState.opaque,
        softDepthFade: 0.1,
      );
      expect(material.depthNormalMaterial, isNull);
      final particles = ParticleSystem3D(capacity: 2, material: material)
        ..spawn(position: Vector3.zero(), size: 1);
      final instances = Float32List(VertexLayout.instanceStrideInFloats);
      Matrix4.identity().copyIntoArray(instances);
      final cube = CuboidMesh(
        size: Vector3.all(1),
        material: SpatialMaterial(),
      );

      device.begin();
      expect(context.beginDepthNormalPass(64, 64), isTrue);
      particles.draw(context);
      context.drawInstances(
        cube.surfaces.first,
        instances: instances,
        count: 1,
      );
      context.endDepthNormalPass();
      device.end();

      // The cube, not the particle billboard.
      expect(backend.countCommands('drawIndexed'), 1);
    });

    test('draws them with the depth-normal material of their material', () {
      final backend = FakeGpuBackend(textureTargets: true);
      final device = GraphicsDevice(backend: backend);
      final context = RenderContext3D(device)
        ..setCamera(Matrix4.identity(), Matrix4.identity());
      final material = ParticleMaterial(renderState: RenderState.opaque);
      expect(material.depthNormalMaterial, isNotNull);
      final particles = ParticleSystem3D(capacity: 2, material: material)
        ..spawn(position: Vector3.zero(), size: 1);

      device.begin();
      expect(context.beginDepthNormalPass(64, 64), isTrue);
      particles.draw(context);
      context.endDepthNormalPass();
      device.end();

      expect(backend.countCommands('drawIndexed'), 1);
    });
  });

  test('RenderGraph3D releases the pooled targets of sizes it stops using', () {
    final backend = FakeGpuBackend(textureTargets: true);
    final device = GraphicsDevice(backend: backend);
    final context = RenderContext3D(device);
    final graph = RenderGraph3D();

    void execute(int size) {
      final texture = graph.createTexture(
        'target',
        RenderGraphTextureDesc3D(width: size, height: size),
      );
      graph.addRenderPass(
        name: 'draw',
        writes: [texture],
        hasSideEffects: true,
        execute: (_) {},
      );
      device.begin();
      graph.execute(device, context);
      device.end();
      graph.clear();
    }

    execute(64);
    execute(64);
    expect(backend.textureTargetsCreated, hasLength(1));
    for (var i = 0; i < RenderGraph3D.targetRetainExecutions; i++) {
      execute(128);
    }
    execute(64);
    // The 64 x 64 target was released while unused, then created again.
    expect(backend.textureTargetsCreated, hasLength(3));
  });
}
