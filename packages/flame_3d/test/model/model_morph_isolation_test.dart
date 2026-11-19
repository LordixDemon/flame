import 'dart:typed_data';

import 'package:flame_3d/camera.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/model.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_fakes/fake_gpu_backend.dart';

/// A model with one node whose quad (at y = 0) has one morph target lifting
/// every vertex by 5.
Model _morphModel({List<ModelAnimation> animations = const []}) {
  final lift = Float32List(4 * 3);
  for (var v = 0; v < 4; v++) {
    lift[v * 3 + 1] = 5;
  }
  final surface = Surface(
    vertices: [
      for (final p in [
        Vector3(-1, 0, -1),
        Vector3(-1, 0, 1),
        Vector3(1, 0, 1),
        Vector3(1, 0, -1),
      ])
        Vertex(position: p, texCoord: Vector2.zero(), normal: Vector3(0, 1, 0)),
    ],
    indices: [0, 1, 2, 0, 2, 3],
    morphTargets: [MorphTargetData(positionDeltas: lift)],
  );
  return Model(
    nodes: {
      0: ModelNode(
        name: 'Face',
        nodeIndex: 0,
        parentNodeIndex: null,
        transform: Matrix4.identity(),
        mesh: Mesh()..addSurface(surface),
        joints: {},
      ),
    },
    animations: animations,
  );
}

/// The height at which a ray cast straight down hits [component].
double? _surfaceHeight(ModelComponent component) {
  final hit = component.raycast(
    Ray.originDirection(Vector3(0.2, 10, 0.2), Vector3(0, -1, 0)),
  );
  return hit?.worldPoint.y;
}

double _sharedHeight(Model model) {
  final surface = model.nodes[0]!.mesh!.surfaces.first;
  return surface.vertexData[1];
}

void main() {
  setUp(FakeGpuBackend.new);

  group('ModelComponent morph targets', () {
    test('components of one model keep their own morph weights', () {
      final model = _morphModel();
      final a = ModelComponent(model: model)..setMorphWeights([1]);
      final b = ModelComponent(model: model)..setMorphWeights([0]);

      expect(_surfaceHeight(a), closeTo(5, 1e-5));
      expect(_surfaceHeight(b), closeTo(0, 1e-5));
      expect(_sharedHeight(model), 0);

      a.setMorphWeights([0.5]);
      expect(_surfaceHeight(a), closeTo(2.5, 1e-5));
      expect(_surfaceHeight(b), closeTo(0, 1e-5));

      // A component that never morphs draws the model's own surfaces.
      final c = ModelComponent(model: model);
      expect(_surfaceHeight(c), closeTo(0, 1e-5));
    });

    test('animated weights reach only the component that plays them', () {
      final open = ModelAnimation(
        name: 'open',
        nodes: {
          0: NodeAnimation(
            channels: const [],
            morphWeights: MorphWeightsChannel(
              interpolation: AnimationInterpolation.linear,
              times: [0, 1],
              weights: [1, 1],
              targetCount: 1,
            ),
          ),
        },
      );
      final model = _morphModel(animations: [open]);
      final a = ModelComponent(model: model)..playAnimationByName('open');
      final b = ModelComponent(model: model);
      a.update(0.1);
      b.update(0.1);

      expect(_surfaceHeight(a), closeTo(5, 1e-5));
      expect(_surfaceHeight(b), closeTo(0, 1e-5));
      expect(_sharedHeight(model), 0);
    });
  });
}
