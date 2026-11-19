import 'dart:ui' show Size;

import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../_fakes/fake_gpu_backend.dart';

/// Records the texture its material binds while drawn, through
/// [RenderContext3D.drawMesh].
class _Probe(final Mesh mesh) extends Object3D {
  int draws = 0;

  @override
  void draw(covariant RenderContext3D context) {
    draws++;
    context.drawMesh(mesh, transform: worldTransformMatrix);
  }
}

void main() {
  late FakeGpuBackend backend;
  late GraphicsDevice device;
  late RenderContext3D context;

  setUp(() {
    backend = FakeGpuBackend(textureTargets: true);
    device = GraphicsDevice(backend: backend);
    context = RenderContext3D(device);
  });

  bool render(RenderTexture3D target, World3D world, {RenderContext3D? into}) {
    device.begin();
    try {
      return target.renderWorld(
        world,
        view: Matrix4.identity(),
        projection: Matrix4.identity(),
        device: device,
        context: into ?? context,
      );
    } finally {
      device.end();
    }
  }

  group('RenderTexture3D', () {
    test('texture is one object from construction, through resizes', () {
      final target = RenderTexture3D(width: 32, height: 16);
      final texture = target.texture;
      expect(texture.width, 32);
      expect(texture.height, 16);
      // Before the first render it is a white pixel.
      expect(texture.resource, same(Texture.standard.resource));

      expect(render(target, World3D()), isTrue);
      expect(target.texture, same(texture));
      final first = backend.textures.last;
      expect(texture.resource, same(first));

      target.resize(64, 8);
      expect(target.texture, same(texture));
      expect(texture.width, 64);
      expect(texture.height, 8);
      render(target, World3D());
      expect(texture.resource, isNot(same(first)));
      expect(texture.resource, same(backend.textures.last));
      expect(backend.textureTargetsCreated.last.$1, 64);
    });

    test('dispose leaves the shared white texture alone', () {
      final standard = Texture.standard.resource;
      RenderTexture3D().dispose();
      expect(Texture.standard.resource, same(standard));
      expect(Texture.standard.hasResource, isTrue);
    });

    test('records into the given context, for an unmounted world too', () {
      final probe = _Probe(CuboidMesh(size: Vector3.all(1)));
      final world = World3D(children: [probe]);
      final target = RenderTexture3D(width: 8, height: 8);

      expect(render(target, world), isTrue);
      expect(probe.draws, 1);
      expect(target.renderCount, 1);
      expect(backend.countCommands('drawIndexed'), greaterThan(0));
    });

    test(
      'a mesh showing the texture samples a white pixel in its own pass',
      () {
        final target = RenderTexture3D(width: 8, height: 8);
        final screen = MeshComponent(
          mesh: CuboidMesh(
            size: Vector3.all(1),
            material: UnlitMaterial(albedoTexture: target.texture),
          ),
        );
        final world = World3D(children: [screen]);
        render(target, world);
        backend.textureBindings.clear();
        render(target, world);
        final own = target.texture.resource;
        expect(own, same(backend.textures.last));
        final bound = backend.textureBindings.values.map((b) => b.$1).toList();
        expect(bound, isNotEmpty);
        expect(bound, isNot(contains(own)));
        expect(bound, contains(Texture.standard.resource));
      },
    );
  });

  group('World3D.renderToImage', () {
    test('uses the lights of an unmounted world', () {
      final lights = <List<Light>>[];
      final world = World3D(
        children: [
          LightComponent.directional(
            direction: Vector3(0, -1, 0),
          ),
          LightComponent.ambient(),
        ],
      );
      // The context's lights are read while the world renders.
      final recording = _LightsProbe(lights);
      world.add(recording);

      device.begin();
      world
          .renderToImage(
            const Size(8, 8),
            view: Matrix4.identity(),
            projection: Matrix4.identity(),
            device: device,
            context: context,
          )
          .dispose();
      device.end();

      expect(lights, isNotEmpty);
      expect(lights.first, hasLength(2));
      // They are only lent for the render.
      expect(world.isMounted, isFalse);
    });
  });
}

/// Records the lights of the context it is drawn with.
class _LightsProbe(final List<List<Light>> out) extends Object3D {
  @override
  void draw(covariant RenderContext3D context) {
    out.add(List.of(context.lights));
  }
}
