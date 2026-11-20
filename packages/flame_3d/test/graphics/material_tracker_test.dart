import 'dart:ui';

import 'package:flame/game.dart' show Game;
import 'package:flame_3d/camera.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_fakes/fake_gpu_backend.dart';

const _red = Color(0xFFFF0000);
const _green = Color(0xFF00FF00);

void main() {
  group('A world follows the materials of its last render', () {
    late GraphicsDevice device;
    late RenderContext3D context;

    setUp(() {
      device = GraphicsDevice(backend: FakeGpuBackend());
      context = RenderContext3D(device)
        ..setCamera(Matrix4.identity(), Matrix4.identity());
    });

    Mesh box(Material material) =>
        CuboidMesh(size: Vector3.all(1), material: material);

    /// Renders [world] drawing [meshes]; returns the device's statistics of
    /// the frame.
    RenderStats render(World3D world, List<Mesh> meshes) {
      device.begin();
      world
          .executeWorldRenderPipeline(
            device: device,
            renderContext: context,
            width: 16,
            height: 16,
            msaaSampleCount: 1,
            clearValue: const Color(0x00000000),
            recordDraws: () {
              for (final mesh in meshes) {
                context.drawMesh(mesh);
              }
            },
          )
          .dispose();
      device.end();
      return device.lastFrameStats;
    }

    UnlitMaterial opaque() => UnlitMaterial()..renderState = RenderState.opaque;

    test('a change of a drawn material changes the scene version', () {
      final world = World3D();
      final drawn = opaque();
      final other = opaque();
      final mesh = box(drawn);
      render(world, [mesh]);

      var version = world.sceneVersion;
      final casters = world.castersVersion;
      other.albedoColor = _red;
      expect(world.sceneVersion, version, reason: 'not drawn by this world');
      drawn.albedoColor = _red;
      expect(world.sceneVersion, greaterThan(version));
      expect(world.castersVersion, casters, reason: 'no shadow moves');
      version = world.sceneVersion;
      drawn.albedoColor = _red;
      expect(world.sceneVersion, version);

      // The next render shows the change and counts it.
      final stats = render(world, [mesh]);
      expect(stats.updatedMaterials, 1);
      expect(stats.animatedMaterials, 0);
      expect(world.sceneVersion, version, reason: 'a render changes nothing');
      expect(render(world, [mesh]).updatedMaterials, 0);
    });

    test('the version never goes back when other materials are drawn', () {
      final world = World3D();
      final old = opaque();
      for (var i = 0; i < 10; i++) {
        old.albedoColor = Color(0xFF000000 + i);
      }
      render(world, [box(old)]);
      final version = world.sceneVersion;

      // A material of a lower version replaces it.
      final fresh = opaque();
      expect(fresh.version, lessThan(old.version));
      render(world, [box(fresh)]);
      expect(world.sceneVersion, version);
      old.albedoColor = _green;
      expect(world.sceneVersion, version, reason: 'no longer drawn');
      fresh.albedoColor = _green;
      expect(world.sceneVersion, greaterThan(version));
    });

    test('a material drawn several times is noted once', () {
      final world = World3D();
      final material = opaque();
      final meshes = [box(material), box(material), box(material)];
      render(world, meshes);
      final version = world.sceneVersion;
      material.albedoColor = _red;
      expect(world.sceneVersion, version + 1);
      expect(render(world, meshes).updatedMaterials, 1);
    });

    test('the time of an animation counts as an animation', () {
      final world = World3D();
      final water = WaterMaterial();
      final unlit = opaque();
      final meshes = [box(water), box(unlit)];
      render(world, meshes);

      water.time += 0.1;
      var stats = render(world, meshes);
      expect(stats.animatedMaterials, 1);
      expect(stats.updatedMaterials, 0);

      water
        ..time += 0.1
        ..shallowColor = _red;
      unlit.albedoColor = _green;
      stats = render(world, meshes);
      expect(stats.animatedMaterials, 0);
      expect(stats.updatedMaterials, 2);
    });

    test('a material marked animated changes the scene on every update', () {
      final world = World3D();
      final material = opaque()..animated = true;
      final mesh = box(material);
      final stats = render(world, [mesh]);
      expect(stats.animatedMaterials, 1);

      for (var i = 0; i < 3; i++) {
        final version = world.sceneVersion;
        final mutations = Game.visualMutationCount;
        world.update(1 / 60);
        expect(world.sceneVersion, greaterThan(version));
        expect(Game.visualMutationCount, greaterThan(mutations));
        expect(render(world, [mesh]).animatedMaterials, 1);
      }

      // Once the world no longer draws it, the updates change nothing.
      render(world, const []);
      final version = world.sceneVersion;
      world.update(1 / 60);
      expect(world.sceneVersion, version);
    });

    test('a render that fails keeps the materials of the last one', () {
      final world = World3D();
      final kept = opaque();
      render(world, [box(kept)]);
      final version = world.sceneVersion;
      device.begin();
      expect(
        () => world.executeWorldRenderPipeline(
          device: device,
          renderContext: context,
          width: 16,
          height: 16,
          msaaSampleCount: 1,
          clearValue: const Color(0x00000000),
          recordDraws: () => throw StateError('failed'),
        ),
        throwsStateError,
      );
      device.end();
      expect(context.materialTracker, isNull);
      expect(world.sceneVersion, version);
      kept.albedoColor = _red;
      expect(world.sceneVersion, greaterThan(version));
    });

    test('the spatial index is not rebuilt for a material change', () {
      final world = World3D();
      final material = opaque();
      render(world, [box(material)]);
      final components = world.componentsVersion;
      material.albedoColor = _red;
      world.fog = FogSettings();
      final afterFog = world.componentsVersion;
      world.fog!.start = 3;
      expect(world.componentsVersion, afterFog);
      expect(afterFog, greaterThan(components), reason: 'a new setting');
    });
  });
}
