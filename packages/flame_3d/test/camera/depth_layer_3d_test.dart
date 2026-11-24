import 'dart:ui';

import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_fakes/fake_gpu_backend.dart';

class _DepthLayerGroup({super.children, super.depthLayer}) extends Object3D {
  @override
  void draw(RenderContext context) {}
}

void main() {
  group('DepthLayer3D', () {
    late FakeGpuBackend backend;
    late GraphicsDevice device;
    late RenderContext3D context;

    setUp(() {
      backend = FakeGpuBackend();
      device = GraphicsDevice(backend: backend);
      context = RenderContext3D(device);
    });

    List<String> viewportCommands(List<String> commands) =>
        commands.where((c) => c.startsWith('setViewport ')).toList();

    test(
      'Object3D defaults to depthLayer 0 and validates non-negative values',
      () {
        final mesh = MeshComponent(mesh: CuboidMesh(size: Vector3.all(1)));
        expect(mesh.depthLayer, 0);

        mesh.depthLayer = 2;
        expect(mesh.depthLayer, 2);

        expect(() => mesh.depthLayer = -1, throwsArgumentError);
        expect(() => _DepthLayerGroup(depthLayer: -1), throwsArgumentError);
      },
    );

    test(
      'multi-layer flush emits per-layer zNear/zFar viewports in ascending order',
      () {
        final mesh0 = MeshComponent(
          mesh: CuboidMesh(size: Vector3.all(1)),
          depthLayer: 0,
        );
        final mesh1 = MeshComponent(
          mesh: CuboidMesh(size: Vector3.all(1)),
          depthLayer: 1,
        );
        final world = World3D(
          depthLayers: const [
            DepthLayer3D(1, zNear: 0.1, zFar: 0.5, applyWaterVolume: false),
            DepthLayer3D(0, zNear: 0.5),
          ],
          children: [mesh1, mesh0],
        );

        device.begin();
        world
            .renderToImage(
              const Size(64, 48),
              view: Matrix4.identity(),
              projection: Matrix4.identity(),
              device: device,
              context: context,
            )
            .dispose();
        device.end();

        final viewports = viewportCommands(backend.commands);
        expect(viewports, [
          'setViewport 0 0 64x48 0.5..1.0',
          'setViewport 0 0 64x48 0.1..0.5',
          'setViewport 0 0 64x48 0.0..1.0',
        ]);
        expect(context.drawCount, 2);
      },
    );

    test('children inherit parent depthLayer unless overridden', () {
      final inherited = MeshComponent(mesh: CuboidMesh(size: Vector3.all(1)));
      final overridden = MeshComponent(
        mesh: CuboidMesh(size: Vector3.all(1)),
        depthLayer: 2,
      );
      final parent = _DepthLayerGroup(
        depthLayer: 1,
        children: [inherited, overridden],
      );
      final world = World3D(
        depthLayers: const [
          DepthLayer3D(0, zNear: 0.7),
          DepthLayer3D(1, zNear: 0.3, zFar: 0.7),
          DepthLayer3D(2, zFar: 0.3),
        ],
        children: [parent],
      );

      device.begin();
      world
          .renderToImage(
            const Size(32, 32),
            view: Matrix4.identity(),
            projection: Matrix4.identity(),
            device: device,
            context: context,
          )
          .dispose();
      device.end();

      expect(inherited.resolvedDepthLayer, 1);
      expect(overridden.resolvedDepthLayer, 2);
      expect(viewportCommands(backend.commands), [
        'setViewport 0 0 32x32 0.3..0.7',
        'setViewport 0 0 32x32 0.0..0.3',
        'setViewport 0 0 32x32 0.0..1.0',
      ]);
    });

    test('restores world waterVolume and viewport after multi-layer flush', () {
      final water = WaterVolumeSettings();
      final layer0Mesh = MeshComponent(
        mesh: CuboidMesh(size: Vector3.all(1), material: StylizedMaterial()),
        depthLayer: 0,
      );
      final layer1Mesh = MeshComponent(
        mesh: CuboidMesh(size: Vector3.all(1), material: StylizedMaterial()),
        depthLayer: 1,
      );
      final multiWorld = World3D(
        waterVolume: water,
        depthLayers: const [
          DepthLayer3D(0, zNear: 0.5),
          DepthLayer3D(1, zNear: 0.1, zFar: 0.5, applyWaterVolume: false),
        ],
        children: [layer0Mesh, layer1Mesh],
      );
      final plainWorld = World3D(
        children: [MeshComponent(mesh: CuboidMesh(size: Vector3.all(1)))],
      );

      device.begin();
      multiWorld
          .renderToImage(
            const Size(32, 32),
            view: Matrix4.identity(),
            projection: Matrix4.identity(),
            device: device,
            context: context,
          )
          .dispose();
      expect(context.waterVolume, same(water));
      expect(context.depthLayers, hasLength(2));

      // Subsequent single-layer world resets context.depthLayers & viewport.
      plainWorld
          .renderToImage(
            const Size(32, 32),
            view: Matrix4.identity(),
            projection: Matrix4.identity(),
            device: device,
            context: context,
          )
          .dispose();
      device.end();

      expect(context.depthLayers, isNull);
      expect(context.waterVolume, isNull);
      expect(viewportCommands(backend.commands), [
        'setViewport 0 0 32x32 0.5..1.0',
        'setViewport 0 0 32x32 0.1..0.5',
        'setViewport 0 0 32x32 0.0..1.0',
      ]);
    });

    test(
      'skips applyWaterVolume toggle without crash when waterVolume is active',
      () {
        final water = WaterVolumeSettings(level: -0.2);
        final m0 = MeshComponent(
          mesh: CuboidMesh(size: Vector3.all(1), material: StylizedMaterial()),
          depthLayer: 0,
        );
        final m1 = MeshComponent(
          mesh: CuboidMesh(size: Vector3.all(1), material: StylizedMaterial()),
          depthLayer: 1,
        );
        final world = World3D(
          waterVolume: water,
          depthLayers: const [
            DepthLayer3D(0, zNear: 0.5),
            DepthLayer3D(1, zNear: 0.1, zFar: 0.5, applyWaterVolume: false),
          ],
          children: [m0, m1],
        );

        device.begin();
        world
            .renderToImage(
              const Size(32, 32),
              view: Matrix4.identity(),
              projection: Matrix4.identity(),
              device: device,
              context: context,
            )
            .dispose();
        device.end();

        expect(context.waterVolume, same(water));
        expect(context.drawCount, 2);
        expect(device.lastFrameStats.drawCalls, 2);
      },
    );
  });
}
