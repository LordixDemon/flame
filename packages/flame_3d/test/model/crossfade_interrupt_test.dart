import 'package:flame_3d/core.dart';
import 'package:flame_3d/model.dart';
import 'package:flutter_test/flutter_test.dart';

/// A one-second clip holding node 0 at `x` (and its morph weight at `x / 20`).
ModelAnimation _holdClip(String name, double x) {
  return ModelAnimation(
    name: name,
    nodes: {
      0: NodeAnimation(
        channels: [
          AnimationController(
            animation: TranslationAnimationSpline.from(
              interpolation: AnimationInterpolation.linear,
              times: [0, 1],
              values: [Vector3(x, 0, 0), Vector3(x, 0, 0)],
            ),
          ),
        ],
        morphWeights: MorphWeightsChannel(
          interpolation: AnimationInterpolation.linear,
          times: [0, 1],
          weights: [x / 20, x / 20],
          targetCount: 1,
        ),
      ),
    },
  );
}

final _a = _holdClip('a', 0);
final _b = _holdClip('b', 10);
final _c = _holdClip('c', 20);

final _model = Model(
  nodes: {
    0: ModelNode(
      name: 'Root',
      nodeIndex: 0,
      parentNodeIndex: null,
      transform: Matrix4.identity(),
      mesh: null,
      joints: {},
    ),
  },
  animations: [_a, _b, _c],
);

double _x(AnimationState state) {
  final workspace = ModelPoseWorkspace.forModel(_model);
  _model.evaluateInto(state, workspace);
  return workspace.nodesByIndex[0]!.combinedTransform.getTranslation().x;
}

double _morph(AnimationState state) {
  final weights = <double>[];
  final count = state.sampleNodeMorphWeights(0, weights);
  expect(count, 1);
  return weights[0];
}

void main() {
  group('AnimationState crossfades', () {
    test('a crossfade started during another one does not pop', () {
      final state = AnimationState()
        ..startAnimation(_a)
        ..crossFadeTo(_b, duration: 1);
      state.update(0.5);
      expect(_x(state), closeTo(5, 1e-4));
      expect(_morph(state), closeTo(0.25, 1e-6));

      state.crossFadeTo(_c, duration: 1);
      expect(_x(state), closeTo(5, 1e-4));
      expect(_morph(state), closeTo(0.25, 1e-6));

      // The interrupted fade finishes (A -> B is at 100 %) while the new one
      // is half way: 10 + (20 - 10) * 0.5.
      state.update(0.5);
      expect(_x(state), closeTo(15, 1e-4));
      expect(_morph(state), closeTo(0.75, 1e-6));

      state.update(0.5);
      expect(state.isCrossFading, isFalse);
      expect(_x(state), closeTo(20, 1e-4));
    });

    test('a crossfade out of a blend space starts from the blended pose', () {
      final space = BlendSpace1D(
        samples: [
          BlendSample1D(animation: _a, position: 0),
          BlendSample1D(animation: _b, position: 1),
        ],
      );
      final state = AnimationState()
        ..playBlendSpace1D(space, initialValue: 0.3);
      state.update(0.1);
      expect(_x(state), closeTo(3, 1e-4));

      state.crossFadeTo(_c, duration: 1);
      expect(_x(state), closeTo(3, 1e-4));
      expect(_morph(state), closeTo(0.15, 1e-6));

      state.update(0.5);
      expect(_x(state), closeTo(3 + (20 - 3) * 0.5, 1e-4));
    });

    test('a crossfade into a blend space starts from a running fade', () {
      final space = BlendSpace1D(
        samples: [
          BlendSample1D(animation: _b, position: 0),
          BlendSample1D(animation: _c, position: 1),
        ],
      );
      final state = AnimationState()
        ..startAnimation(_a)
        ..crossFadeTo(_c, duration: 1);
      state.update(0.25);
      expect(_x(state), closeTo(5, 1e-4));

      state.crossFadeToBlendSpace1D(space, duration: 1, initialValue: 0.5);
      expect(_x(state), closeTo(5, 1e-4));
    });

    test('nests up to maxNestedCrossFades interrupted fades', () {
      final clips = [_a, _b, _c];
      final state = AnimationState()..startAnimation(_a);
      for (var i = 1; i < 40; i++) {
        final before = _x(state);
        state.crossFadeTo(clips[i % 3], allowSelfTransition: true);
        // Starting a fade does not move the pose until the nesting limit
        // completes the oldest running fade.
        if (i <= AnimationState.maxNestedCrossFades) {
          expect(_x(state), closeTo(before, 1e-4), reason: 'fade $i');
        }
        state.update(0.06);
      }
      state.update(1);
      expect(state.isCrossFading, isFalse);
      expect(state.animationRef, same(clips[39 % 3]));
      expect(_x(state), closeTo(0, 1e-4));
    });
  });

  group('blend spaces without phase sync', () {
    final stepClip = ModelAnimation(
      name: 'step',
      nodes: _a.nodes,
      events: [AnimationEvent3D(name: 'foot', time: 0.5)],
    );
    final slowClip = ModelAnimation(
      name: 'slow',
      nodes: _b.nodes,
      events: [AnimationEvent3D(name: 'slow', time: 0.25)],
    );
    BlendSpace1D space() => BlendSpace1D(
      samples: [
        BlendSample1D(animation: stepClip, position: 0),
        BlendSample1D(animation: slowClip, position: 1, speed: 0.5),
      ],
      syncNormalizedPhase: false,
    );

    test('fire the events and advance the phase of the dominant clip', () {
      final fired = <String>[];
      final state = AnimationState()
        ..addEventListener((event) => fired.add(event.name))
        ..playBlendSpace1D(space(), initialValue: 0.2);
      state.update(0.6);
      expect(fired, ['foot']);
      expect(state.normalizedPhase, closeTo(0.6, 1e-9));
      state.update(0.6);
      expect(state.lastLoopWrapCount, 1);
      expect(state.normalizedPhase, closeTo(0.2, 1e-9));
    });

    test('let state machine exit times pass', () {
      final machine = AnimationStateMachine3D(
        initialState: 'move',
        states: [
          Blend1DAnimState3D(name: 'move', space: space(), parameter: 'speed'),
          ClipAnimState3D(name: 'rest', animation: _c),
        ],
        transitions: [
          AnimTransition3D(fromState: 'move', toState: 'rest', exitTime: 1),
        ],
      );
      final state = AnimationState();
      machine.bind(state);
      for (var i = 0; i < 6; i++) {
        machine.update(0.25, targetState: state);
      }
      expect(machine.currentStateName, 'rest');
    });
  });
}
