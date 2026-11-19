import 'dart:math' as math;

import 'package:flame/game.dart';
import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/model.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'root motion moves a component under a rotated parent forwards',
    () async {
      // The hips walk 2 units along the model's +z in one second.
      final walk = ModelAnimation(
        name: 'walk',
        nodes: {
          0: NodeAnimation(
            channels: [
              AnimationController(
                animation: TranslationAnimationSpline.from(
                  interpolation: AnimationInterpolation.linear,
                  times: [0, 1],
                  values: [Vector3.zero(), Vector3(0, 0, 2)],
                ),
              ),
            ],
          ),
        },
      );
      final model = Model(
        nodes: {
          0: ModelNode(
            name: 'Hips',
            nodeIndex: 0,
            parentNodeIndex: null,
            transform: Matrix4.identity(),
            mesh: CuboidMesh(size: Vector3.all(0.2)),
            joints: {},
          ),
        },
        animations: [walk],
      );
      final hero = ModelComponent(
        model: model,
        rootMotion: RootMotionExtractor3D(
          rootNodeName: 'Hips',
          applyToComponentTransform: true,
        ),
      )..playAnimationByName('walk');
      // A parent turned a quarter around +y and scaled by 3.
      final parent = Group3D(
        rotation: Quaternion.axisAngle(Vector3(0, 1, 0), math.pi / 2),
        scale: Vector3.all(3),
        children: [hero],
      );
      final game = FlameGame(world: World3D(children: [parent]));
      await game.onLoad();
      game.update(0);
      game.update(0.5);

      // One unit along the model's +z, in the parent's space.
      expect(hero.position.x, closeTo(0, 1e-4));
      expect(hero.position.z, closeTo(1, 1e-4));
      // In the world: turned and scaled by the parent once.
      final world = hero.worldTransformMatrix.getTranslation();
      expect(world.x, closeTo(3, 1e-4));
      expect(world.z, closeTo(0, 1e-4));
    },
  );
}
