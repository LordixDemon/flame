import 'dart:typed_data';
import 'dart:ui';

import 'package:flame/game.dart';
import 'package:flame_3d/camera.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../_fakes/fake_gpu_backend.dart';

Light _point(double x, {double? range = 1.5, ShadowSettings? shadows}) => Light(
  position: Vector3(x, 0, 0),
  source: PointLight(
    color: const Color(0xFFFFFFFF),
    intensity: 1,
    range: range,
    shadows: shadows,
  ),
);

Light _spot(double x, {double? range = 3, ShadowSettings? shadows}) => Light(
  position: Vector3(x, 2, 0),
  source: SpotLight(
    range: range,
    direction: Vector3(0, -1, 0),
    shadows: shadows,
  ),
);

void main() {
  group('World3D.lightGrid and the light blocks', () {
    late FakeGpuBackend backend;
    late GraphicsDevice device;
    late RenderContext3D context;
    late SpatialMaterial material;
    late Surface surface;

    setUp(() {
      backend = FakeGpuBackend(
        blockSizes: {
          'JointMatrices': 4096,
          RenderContext3D.spatialPassBlock: 64 * 1024,
        },
      );
      device = GraphicsDevice(backend: backend);
      context = RenderContext3D(device);
      material = SpatialMaterial();
      surface = Surface(
        vertices: [
          Vertex(position: Vector3.zero(), texCoord: Vector2.zero()),
          Vertex(position: Vector3(1, 0, 0), texCoord: Vector2.zero()),
          Vertex(position: Vector3(0, 1, 0), texCoord: Vector2.zero()),
        ],
        indices: const [0, 1, 2],
        material: material,
      );
    });

    Map<String, Float32List> draw(
      List<Light> lights, {
      LightGridSettings? grid,
    }) {
      device.begin();
      context
        ..lights = lights
        ..lightGrid = grid
        ..setCamera(Matrix4.identity(), Matrix4.identity());
      device.beginPass(const Size(16, 16));
      context
        ..drawSurface(surface)
        ..flush();
      device
        ..endPass()
        ..end();
      return backend.uniforms;
    }

    int offsetOf(String block, String member) {
      final shader = material.fragmentShaderFor(context, surface.layout);
      final isSpatial =
          block == 'Lights' || block == 'SpotLights' || block == 'LightGrid';
      final actualBlock = isSpatial ? RenderContext3D.spatialPassBlock : block;
      final actualMember = isSpatial ? '${block}_$member' : member;
      return shader.slot(actualBlock).getMemberOffsetInBytes(actualMember)! ~/
          Float32List.bytesPerElement;
    }

    List<double> vec4(Map<String, Float32List> u, String block, String m) {
      final o = offsetOf(block, m);
      return u[RenderContext3D.spatialPassBlock]!.sublist(o, o + 4);
    }

    List<double> pointXs(Map<String, Float32List> u) {
      final data = u[RenderContext3D.spatialPassBlock]!;
      return [
        for (var k = 0; k < data[offsetOf('Lights', 'numLights')]; k++)
          data[offsetOf('Lights', 'positions') + k * 4],
      ];
    }

    List<double> spotXs(Map<String, Float32List> u) {
      final data = u[RenderContext3D.spatialPassBlock]!;
      return [
        for (var k = 0; k < data[offsetOf('SpotLights', 'numLights')]; k++)
          data[offsetOf('SpotLights', 'positions') + k * 4],
      ];
    }

    FakeTexture? gridTexture() =>
        backend.textureBindings[RenderContext3D.lightGridSampler]?.$1;

    test('a pass within the limits uses no grid', () {
      final lights = [
        for (var i = 0; i < 8; i++) _point(i.toDouble()),
        for (var i = 0; i < 4; i++) _spot(i.toDouble()),
      ];
      final withGrid = draw(lights, grid: const LightGridSettings());
      expect(pointXs(withGrid), [0, 1, 2, 3, 4, 5, 6, 7]);
      expect(spotXs(withGrid), [0, 1, 2, 3]);
      expect(vec4(withGrid, 'LightGrid', 'counts'), [8, 4, 0, 0]);
      expect(vec4(withGrid, 'LightGrid', 'data'), [0, 0, 0, 0]);
      expect(context.lightGridStats.active, isFalse);
      expect(
        backend.textures.where((t) => t.format == GpuPixelFormat.rgbaFloat32),
        isEmpty,
      );

      // The blocks are those of a pass without a grid.
      final without = draw(lights);
      expect(
        without[RenderContext3D.spatialPassBlock],
        withGrid[RenderContext3D.spatialPassBlock],
      );
      expect(vec4(without, 'LightGrid', 'counts'), [8, 4, 0, 0]);
    });

    test('beyond the limits, the lights with a range go into the grid', () {
      final lights = [
        for (var i = 0; i < 6; i++) _point(i.toDouble()),
        _point(100, range: null),
        for (var i = 6; i < 20; i++) _point(i.toDouble()),
        _point(200, shadows: ShadowSettings()),
        for (var i = 0; i < 6; i++) _spot(i * 2.0),
        _spot(300, shadows: ShadowSettings()),
      ];
      final u = draw(lights, grid: const LightGridSettings());

      // The blocks hold the lights the grid cannot hold first, then fill
      // up with the first of the others (for the shaders that read no
      // grid); the shaders that read it shade the first counts.xy.
      expect(pointXs(u), [100, 200, 0, 1, 2, 3, 4, 5]);
      expect(spotXs(u), [300, 0, 2, 4]);
      expect(vec4(u, 'LightGrid', 'counts'), [2, 1, 0, 0]);

      final stats = context.lightGridStats;
      expect(stats.active, isTrue);
      expect(stats.pointLights, 20);
      expect(stats.spotLights, 6);
      final data = vec4(u, 'LightGrid', 'data');
      expect(data[0], LightGrid3D.textureWidth);
      expect(data[2], 1 / stats.textureHeight);
      expect(data[3], 1);
      final origin = vec4(u, 'LightGrid', 'origin');
      expect(origin[3], 1 / stats.cellSize);
      expect(vec4(u, 'LightGrid', 'cells'), [
        stats.cellsX,
        stats.cellsY,
        stats.cellsZ,
        stats.cellsX * stats.cellsY,
      ]);

      final texture = gridTexture()!;
      expect(texture.format, GpuPixelFormat.rgbaFloat32);
      expect(texture.width, LightGrid3D.textureWidth);
      expect(texture.height, stats.textureHeight);
      expect(texture.writes, hasLength(1));
      // The whole texture, 16 bytes a texel.
      expect(
        texture.writes.single.$2,
        hasLength(LightGrid3D.textureWidth * stats.textureHeight * 16),
      );
      expect(stats.usedTexels, greaterThan(stats.cells));
    });

    test('uploads the grid only when it changes', () {
      final lights = [for (var i = 0; i < 12; i++) _point(i.toDouble())];
      const settings = LightGridSettings();
      for (var frame = 0; frame < 4; frame++) {
        draw(lights, grid: settings);
      }
      expect(context.lightGridStats.uploads, 1);
      expect(context.lightGridStats.builds, 1);
      expect(gridTexture()!.writes, hasLength(1));

      lights[5].position.y = 0.5;
      draw(lights, grid: settings);
      expect(context.lightGridStats.uploads, 2);
      // Written into another texture than the one of before, which a frame
      // in flight may still read.
      expect(gridTexture()!.writes, hasLength(1));
      final rgbaFloat = backend.textures.where(
        (t) => t.format == GpuPixelFormat.rgbaFloat32,
      );
      expect(rgbaFloat, hasLength(2));
    });

    test('without settings, the blocks keep the first lights', () {
      final lights = [for (var i = 0; i < 12; i++) _point(i.toDouble())];
      final u = draw(lights);
      expect(pointXs(u), [0, 1, 2, 3, 4, 5, 6, 7]);
      expect(vec4(u, 'LightGrid', 'counts'), [8, 4, 0, 0]);
      expect(vec4(u, 'LightGrid', 'data')[3], 0);
    });

    test('beyondLimitsOnly: false puts the lights in the grid always', () {
      final lights = [_point(0), _point(1), _point(2, range: null)];
      final u = draw(
        lights,
        grid: const LightGridSettings(beyondLimitsOnly: false),
      );
      expect(pointXs(u), [2, 0, 1]);
      expect(vec4(u, 'LightGrid', 'counts')[0], 1);
      expect(context.lightGridStats.pointLights, 2);
    });

    test('the shadow pass finds its casters ahead of the grid lights', () {
      final lights = [
        for (var i = 0; i < 6; i++) _spot(i * 2.0),
        _spot(30, shadows: ShadowSettings()),
      ];
      final u = draw(lights, grid: const LightGridSettings());
      // The caster is the first spot light of the block, where the shadow
      // pass looks for it (index 0, as shadows.glsl reads it).
      expect(spotXs(u).first, 30);
    });

    test('World3D.lightGrid marks the scene changed and reaches the '
        'context', () async {
      final world = World3D();
      final game = FlameGame(world: world);
      game
        ..onGameResize(Vector2.all(100))
        ..start();
      await game.ready();
      final version = world.sceneVersion;
      world.lightGrid = const LightGridSettings(cellSize: 2);
      expect(world.sceneVersion, greaterThan(version));
      final after = world.sceneVersion;
      world.lightGrid = const LightGridSettings(cellSize: 2);
      expect(world.sceneVersion, after);
      world.syncContextOptions(context);
      expect(context.lightGrid, const LightGridSettings(cellSize: 2));
    });
  });
}
