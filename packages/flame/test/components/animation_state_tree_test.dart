import 'package:flame/components.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockSprite() extends Mock implements Sprite;

SpriteAnimation _animation({required bool loop, int frames = 2}) {
  return SpriteAnimation.spriteList(
    List<Sprite>.generate(frames, (_) => _MockSprite()),
    stepTime: 0.1,
    loop: loop,
  );
}

AnimationStateTree<String> _tree() {
  return AnimationStateTree<String>(initialState: 'idle')
    ..registerState('idle', _animation(loop: true))
    ..registerState('attack', _animation(loop: false))
    ..registerState('hit', _animation(loop: false));
}

void main() {
  group('AnimationStateTree.playOneShot', () {
    test('returns to the previous state when the one-shot completes', () {
      final tree = _tree()..playOneShot('attack');
      expect(tree.currentState, 'attack');

      tree.update(0.5);

      expect(tree.currentState, 'idle');
    });

    test('a one-shot that interrupts another one returns to the state the '
        'first one was going back to', () {
      final tree = _tree()
        ..playOneShot('attack')
        ..update(0.05)
        ..playOneShot('hit');
      expect(tree.currentState, 'hit');

      tree.update(0.5);
      expect(tree.currentState, 'idle');

      tree.update(0.5);
      expect(tree.currentState, 'idle');
    });

    test('an explicit returnTo wins over the pending return state', () {
      final tree = _tree()
        ..playOneShot('attack')
        ..playOneShot('hit', returnTo: 'attack');

      tree.update(0.5);

      expect(tree.currentState, 'attack');
    });

    test('transitionTo cancels the pending return', () {
      final tree = _tree()
        ..playOneShot('attack')
        ..transitionTo('hit');

      tree.update(0.5);

      expect(tree.currentState, 'hit');
    });
  });
}
