import 'package:flame/sprite.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockSprite() extends Mock implements Sprite;

SpriteAnimationTicker _ticker() {
  return SpriteAnimation.variableSpriteList(
    List<Sprite>.generate(4, (_) => _MockSprite()),
    stepTimes: [0.1, 0.2, 0.3, 0.4],
    loop: false,
  ).createTicker();
}

void main() {
  group('SpriteAnimationTicker.jumpToFrame', () {
    test('moves elapsed to the start of the target frame', () {
      final ticker = _ticker()..update(0.05);

      ticker.jumpToFrame(2);
      expect(ticker.currentIndex, 2);
      expect(ticker.clock, 0);
      expect(ticker.elapsed, closeTo(0.3, 1e-9));

      ticker.jumpToFrame(0);
      expect(ticker.elapsed, 0);
    });

    test('does not report the same frame twice to a ticker that has not '
        'started', () {
      final frames = <int>[];
      final events = <String>[];
      var starts = 0;
      final ticker = _ticker()
        ..onStart = (() => starts++)
        ..onFrame = frames.add
        ..onEvent = ((index, name) => events.add('$index:$name'))
        ..registerFrameEvent(2, 'hit');

      ticker.jumpToFrame(2, emitEvents: true);
      expect(frames, [2]);
      expect(events, ['2:hit']);

      ticker.update(0.01);
      expect(starts, 1);
      expect(frames, [2]);
      expect(events, ['2:hit']);

      ticker.update(0.3);
      expect(frames, [2, 3]);
    });

    test('a jump without events still lets the first update report the '
        'frame', () {
      final frames = <int>[];
      final ticker = _ticker()..onFrame = frames.add;

      ticker
        ..jumpToFrame(1)
        ..update(0.01);

      expect(frames, [1]);
    });

    test('reset forgets a frame that was reported before the start', () {
      final frames = <int>[];
      final ticker = _ticker()..onFrame = frames.add;

      ticker
        ..jumpToFrame(2, emitEvents: true)
        ..reset()
        ..update(0.01);

      expect(frames, [2, 0]);
    });
  });
}
