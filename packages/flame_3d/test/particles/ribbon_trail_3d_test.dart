import 'package:flame/game.dart' show FlameGame;
import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/particles.dart';
import 'package:flame_test/flame_test.dart';
import 'package:flutter_test/flutter_test.dart';

FlameGame _game() => FlameGame(world: World3D());

void main() {
  group('RibbonTrail3D', () {
    testWithGame('follows its own position under a 3D parent', _game, (
      game,
    ) async {
      final world = game.world as World3D;
      // A trail one unit to the right of its parent, which moves up.
      final trail = RibbonTrail3D(
        position: Vector3(1, 0, 0),
        width: 0.1,
        lifetime: 10,
        minVertexDistance: 0.01,
      );
      final parent = Group3D(children: [trail]);
      await world.ensureAdd(parent);
      for (var step = 0; step < 4; step++) {
        parent.position.setValues(0, step * 0.5, 0);
        game.update(0.016);
      }
      expect(trail.pointCount, 4);
      final box = trail.aabb;
      // Along x = 1, from y = 0 to 1.5, not along the parent's x = 0.
      expect(box.min.x, closeTo(0.95, 0.06));
      expect(box.max.x, closeTo(1.05, 0.06));
      expect(box.min.y, closeTo(0, 0.06));
      expect(box.max.y, closeTo(1.5, 0.06));
    });

    testWithGame('follows its target when it has one', _game, (game) async {
      final world = game.world as World3D;
      final target = Group3D(position: Vector3(-2, 0, 0));
      final trail = RibbonTrail3D(
        target: target,
        width: 0.1,
        lifetime: 10,
        minVertexDistance: 0.01,
      );
      await world.ensureAddAll([target, trail]);
      for (var step = 0; step < 3; step++) {
        target.position.setValues(-2, step * 0.5, 0);
        game.update(0.016);
      }
      expect(trail.pointCount, 3);
      expect(trail.aabb.center.x, closeTo(-2, 0.06));
    });
  });
}
