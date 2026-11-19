import 'package:flame_3d/camera.dart';
import 'package:flame_3d/game.dart';
import 'package:flame_3d/world_scale.dart';
import 'package:flame_test/flame_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart'
    show Frustum, makeOrthographicMatrix;

import '../_fakes/fake_gpu_backend.dart';

void main() {
  setUp(FakeGpuBackend.new);

  test('a trampled blade stays inside the bounds of its cell', () {
    final foliage = FoliageSystem3D(
      capacity: 1,
      windStrength: 0,
      interactors: [FoliageInteractor3D(position: Vector3(-0.4, 0, 0))],
    )..addBlade(position: Vector3.zero(), densityRank: 0);
    for (var i = 0; i < 60; i++) {
      foliage.update(1 / 30);
    }
    final bend = foliage.bladeBendVector(0);
    expect(bend.x, greaterThan(0.5));
    // A view that sees only where the bent tip is, right of the base.
    final frustum = Frustum.matrix(
      makeOrthographicMatrix(0.5, 3, -1, 3, -5, 5),
    );
    expect(
      foliage.buildVisibleInstances(
        cameraPosition: Vector3.zero(),
        frustum: frustum,
      ),
      1,
    );
  });

  testWithGame<FlameGame3D>(
    'addBlade marks the world dirty',
    () => FlameGame3D(camera: CameraComponent3D()),
    (game) async {
      final foliage = FoliageSystem3D(capacity: 4, windStrength: 0);
      await game.world.ensureAdd(foliage);
      final before = game.world.sceneVersion;
      foliage.addBlade(position: Vector3(1, 0, 1));
      expect(game.world.sceneVersion, greaterThan(before));
    },
  );
}
