import 'dart:math' as math;

import 'package:flame/game.dart';
import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/model.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter_test/flutter_test.dart';

/// A model whose hips walk 2 units along the model's +z in one second.
Model _walker() {
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
  return Model(
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
}

void main() {
  group('root motion applied to the component', () {
    for (final heroTurn in [0.0, math.pi / 2, -math.pi / 3]) {
      test('walks forwards under a rotated, scaled parent '
          '(hero turned by $heroTurn rad)', () async {
        final hero = ModelComponent(
          model: _walker(),
          rotation: Quaternion.axisAngle(Vector3(0, 1, 0), heroTurn),
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

        // One unit along the model's +z, turned by the hero's rotation, in
        // the parent's space.
        final expected = Matrix4.compose(
          Vector3.zero(),
          Quaternion.axisAngle(Vector3(0, 1, 0), heroTurn),
          Vector3.all(1),
        ).transform3(Vector3(0, 0, 1));
        expect(hero.position.distanceTo(expected), lessThan(1e-4));
        // In the world: turned and scaled by the parent once.
        final world = hero.worldTransformMatrix.getTranslation();
        final expectedWorld = parent.transformMatrix.transform3(
          expected.clone(),
        );
        expect(world.distanceTo(expectedWorld), lessThan(1e-4));
        expect(world.length, closeTo(3, 1e-4));
      });
    }
  });
}
