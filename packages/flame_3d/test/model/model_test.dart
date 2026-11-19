import 'package:flame_3d/core.dart';
import 'package:flame_3d/model.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter_test/flutter_test.dart';

ModelNode _node(int index, int? parent, Matrix4 transform) => ModelNode(
  name: null,
  nodeIndex: index,
  parentNodeIndex: parent,
  transform: transform,
  mesh: null,
  joints: {},
);

void main() {
  group('Model', () {
    group('processNodes', () {
      Model hierarchy() => Model(
        nodes: {
          2: _node(2, 1, Matrix4.translationValues(0, 0, 3)),
          0: _node(0, null, Matrix4.translationValues(1, 0, 0)),
          1: _node(1, 0, Matrix4.translationValues(0, 2, 0)),
        },
        animations: [],
      );

      test('combines each node with its parents in any map order', () {
        final processed = hierarchy().processNodes(AnimationState());

        expect(processed.keys, unorderedEquals([0, 1, 2]));
        expect(
          processed[2]!.combinedTransform.getTranslation(),
          Vector3(1, 2, 3),
        );
      });

      test('returns the same transforms on every call', () {
        final model = hierarchy();
        final animation = AnimationState();
        final first = model.processNodes(animation);
        final second = model.processNodes(animation);

        for (final index in first.keys) {
          expect(
            second[index]!.combinedTransform.storage,
            orderedEquals(first[index]!.combinedTransform.storage),
          );
        }
      });

      test('throws when the nodes form a cycle', () {
        final model = Model(
          nodes: {
            0: _node(0, 1, Matrix4.identity()),
            1: _node(1, 0, Matrix4.identity()),
          },
          animations: [],
        );

        expect(
          () => model.processNodes(AnimationState()),
          throwsA(isA<StateError>()),
        );
      });
    });

    test('animatedAabb includes the pose at every keyframe', () {
      // A short peak at t = 0.05 that evenly spaced samples would miss.
      final dash = ModelAnimation(
        name: 'dash',
        nodes: {
          0: NodeAnimation(
            channels: [
              AnimationController(
                animation: TranslationAnimationSpline.from(
                  interpolation: AnimationInterpolation.linear,
                  times: [0, 0.05, 1],
                  values: [Vector3.zero(), Vector3(10, 0, 0), Vector3.zero()],
                ),
              ),
            ],
          ),
        },
      );
      final model = Model(
        nodes: {
          0: ModelNode(
            name: 'Body',
            nodeIndex: 0,
            parentNodeIndex: null,
            transform: Matrix4.identity(),
            mesh: CuboidMesh(size: Vector3.all(1)),
            joints: {},
          ),
        },
        animations: [dash],
      );
      expect(model.animatedAabb.max.x, closeTo(10.5, 1e-5));
    });
  });
}
