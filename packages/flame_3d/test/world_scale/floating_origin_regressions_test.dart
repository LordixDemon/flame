import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/game.dart';
import 'package:flame_3d/world_scale.dart';
import 'package:flame_test/flame_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_fakes/fake_gpu_backend.dart';

void main() {
  setUp(FakeGpuBackend.new);

  group('FloatingOriginController3D.trackedTarget', () {
    test('an unbound tracked target is moved back once, not every frame', () {
      final target = Group3D(position: Vector3(3000, 0, 0));
      final controller = FloatingOriginController3D(trackedTarget: target);
      for (var i = 0; i < 3; i++) {
        controller.update(1 / 60);
      }
      expect(controller.rebaseCount, 1);
      expect(controller.originX, 3000);
      expect(target.position.x, 0);
    });

    test('a bound tracked target moved through its position keeps its world '
        'position', () {
      final target = Group3D();
      final binding = FloatingOriginTransform3D(
        worldPosition: WorldPosition64.zero(),
        target: target,
      );
      final controller = FloatingOriginController3D(trackedTarget: target)
        ..register(binding);
      final bystander = Group3D();
      final bystanderBinding = FloatingOriginTransform3D(
        worldPosition: WorldPosition64(10),
        target: bystander,
      );
      controller.register(bystanderBinding);

      target.position.x = 3000;
      controller.update(1 / 60);
      expect(controller.rebaseCount, 1);
      expect(controller.originX, 3000);
      expect(target.position.x, 0);
      expect(binding.worldPosition.x, 3000);
      // A binding moved only through its 64-bit position keeps it exactly.
      expect(bystanderBinding.worldPosition.x, 10);
      expect(bystander.position.x, -2990);
      controller.update(1 / 60);
      expect(controller.rebaseCount, 1);
    });
  });

  group('FloatingOriginTransform3D', () {
    final ship = Group3D();
    final binding = FloatingOriginTransform3D(
      worldPosition: WorldPosition64(5000),
    );
    final controller = FloatingOriginController3D(
      initialOrigin: WorldPosition64(4000),
    );
    testWithGame<FlameGame3D>(
      'finds a controller added to the world after it',
      () {
        ship.add(binding);
        final world = World3D()..add(Group3D(children: [ship]));
        return FlameGame3D(world: world, camera: CameraComponent3D());
      },
      (game) async {
        await game.ready();
        expect(binding.isMounted, isTrue);
        expect(binding.controller, isNull);
        await game.world.ensureAdd(controller);
        expect(binding.controller, same(controller));
        expect(controller.registeredCount, 1);
        expect(ship.position.x, 1000);
      },
    );
  });
}
