import 'package:flame/camera.dart';
import 'package:flame/canvas3d.dart';
import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flutter_test/flutter_test.dart';

class _Tower() extends Component with SpatialHitbox3D {
  @override
  double? intersectRay3D(Ray3D ray) => 5.0;
}

void main() {
  group('3D ray hit flag', () {
    late FlameGame game;
    late _Tower tower;

    setUp(() async {
      game = FlameGame(
        camera: CameraComponent(viewport: FixedSizeViewport(400, 300)),
      )..onGameResize(Vector2(400, 300));
      await game.start();
      game.camera.rayProjector3D = (_, _) =>
          const Ray3D(ox: 0, oy: 0, oz: 10, dx: 0, dy: 0, dz: -1);
      tower = _Tower();
      game.world.add(tower);
      await game.ready();
    });

    test('is set while a hit is handed out and cleared when the hit list '
        'is exhausted', () {
      final hits = game
          .componentsAtPoint(Vector2(200, 150))
          .whereType<SpatialHitbox3D>();
      var seen = false;
      for (final hit in hits) {
        expect(hit, same(tower));
        expect(tower.isActiveSpatialRayHit, isTrue);
        seen = true;
      }
      expect(seen, isTrue);
      expect(tower.isActiveSpatialRayHit, isFalse);
    });

    test('is cleared by clearActiveSpatialRayHits after a consumer stopped '
        'iterating early', () {
      final first = game
          .componentsAtPoint(Vector2(200, 150))
          .whereType<SpatialHitbox3D>()
          .first;
      expect(first, same(tower));
      // An abandoned sync* generator never resumes, so the consumer ends the
      // hit test explicitly.
      CameraComponent.clearActiveSpatialRayHits();
      expect(tower.isActiveSpatialRayHit, isFalse);
    });
  });
}
