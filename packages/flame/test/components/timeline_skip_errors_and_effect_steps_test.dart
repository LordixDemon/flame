import 'dart:async';
import 'dart:ui';

import 'package:flame/components.dart';
import 'package:flame/effects.dart';
import 'package:flutter_test/flutter_test.dart';

/// A timeline that also counts work of its own as "busy", the way a subclass
/// that runs extra timers from its `update` would.
class _TimelineWithOwnWork({super.onIdle}) extends TimelineComponent {
  int ownWork = 0;

  @override
  bool get isBusy => super.isBusy || ownWork > 0;
}

/// Runs [body] and returns the errors that reached the zone as uncaught.
Future<List<Object>> _collectUncaughtErrors(
  FutureOr<void> Function() body,
) async {
  final uncaught = <Object>[];
  await runZonedGuarded(
    () async {
      await body();
    },
    (error, stackTrace) => uncaught.add(error),
  );
  return uncaught;
}

void main() {
  group('TimelineComponent.skipToEnd', () {
    test('does not start the async beat of a block that is only queued', () {
      final timeline = TimelineComponent();
      var taskStarts = 0;
      var skips = 0;

      timeline.enqueue((b) => b.wait(1.0));
      timeline.enqueue((b) {
        b.runBeat(
          (isCancelled) async {
            taskStarts++;
          },
          onSkip: () => skips++,
        );
      });
      expect(timeline.queuedBlockCount, 1);

      timeline.skipToEnd();

      expect(timeline.isBusy, isFalse);
      expect(skips, 1);
      expect(taskStarts, 0);
    });

    test('only skips an async beat of the active block that has not begun', () {
      final timeline = TimelineComponent();
      var taskStarts = 0;
      var skips = 0;
      timeline.enqueue((b) {
        b.wait(1.0);
        b.runBeat(
          (isCancelled) async {
            taskStarts++;
          },
          onSkip: () => skips++,
        );
      });

      timeline.skipToEnd();

      expect(skips, 1);
      expect(taskStarts, 0);
    });

    test('calls onSkip of a beat that is already running', () {
      final timeline = TimelineComponent();
      var taskStarts = 0;
      var skips = 0;
      final gate = Completer<void>();
      timeline.enqueue((b) {
        b.runBeat(
          (isCancelled) {
            taskStarts++;
            return gate.future;
          },
          onSkip: () => skips++,
        );
      });
      expect(taskStarts, 1);

      timeline.skipToEnd();

      expect(skips, 1);
      expect(taskStarts, 1);
      expect(timeline.isBusy, isFalse);
    });

    test('reports onIdle exactly once', () {
      var idleCount = 0;
      final log = <String>[];
      final timeline = TimelineComponent(onIdle: () => idleCount++);

      timeline.enqueue((b) => b.wait(1.0));
      // A queued block that would finish at once if it were started.
      timeline.enqueue((b) => b.doSync(() => log.add('queued action')));

      timeline.skipToEnd();

      expect(log, ['queued action']);
      expect(timeline.isBusy, isFalse);
      expect(idleCount, 1);
    });

    test('completes the futures of every skipped block', () async {
      final timeline = TimelineComponent();
      final first = timeline.enqueue((b) => b.wait(1.0));
      final second = timeline.enqueue((b) => b.wait(1.0));

      timeline.skipToEnd();

      await expectLater(Future.wait([first, second]), completes);
    });

    test('also skips a block that a skipped callback enqueues', () {
      var idleCount = 0;
      final log = <String>[];
      late final TimelineComponent timeline;
      timeline = TimelineComponent(onIdle: () => idleCount++);
      timeline.enqueue((b) {
        b.wait(1.0);
        b.doSync(() {
          log.add('first');
          timeline.enqueue((b) {
            b.wait(5.0);
            b.doSync(() => log.add('second'));
          });
        });
      });

      timeline.skipToEnd();

      expect(log, ['first', 'second']);
      expect(timeline.isBusy, isFalse);
      expect(idleCount, 1);
    });

    test('an action that skips its own timeline runs once', () {
      var runs = 0;
      var idleCount = 0;
      final log = <String>[];
      late final TimelineComponent timeline;
      timeline = TimelineComponent(onIdle: () => idleCount++);
      timeline.enqueue((b) {
        b.wait(0.1);
        b.doSync(() {
          runs++;
          timeline.skipToEnd();
        });
        b.doSync(() => log.add('after'));
      });

      timeline.update(0.2);

      expect(runs, 1);
      expect(log, ['after']);
      expect(timeline.isBusy, isFalse);
      expect(idleCount, 1);
    });

    test('a skipped callback that cancels leaves a consistent timeline', () {
      var idleCount = 0;
      final log = <String>[];
      late final TimelineComponent timeline;
      timeline = TimelineComponent(onIdle: () => idleCount++);
      timeline.enqueue((b) {
        b.wait(1.0);
        b.doSync(() {
          timeline.cancel();
          log.add('cancelled');
        });
        b.doSync(() => log.add('never'));
      });
      timeline.enqueue((b) => b.doSync(() => log.add('never either')));

      timeline.skipToEnd();

      expect(log, ['cancelled']);
      expect(timeline.isBusy, isFalse);
      expect(timeline.queuedBlockCount, 0);
      expect(idleCount, 1);
    });
  });

  group('TimelineComponent with a failing step', () {
    test('moves on when the future of a beat fails', () async {
      var idle = 0;
      final log = <String>[];
      late final TimelineComponent timeline;

      final uncaught = await _collectUncaughtErrors(() async {
        timeline = TimelineComponent(onIdle: () => idle++);
        timeline.enqueue((b) {
          b.runBeat((isCancelled) async {
            throw StateError('asset missing');
          });
          b.doSync(() => log.add('after failed beat'));
        });
        timeline.enqueue((b) => b.doSync(() => log.add('next block')));

        for (var i = 0; i < 5; i++) {
          await Future<void>.delayed(Duration.zero);
          timeline.update(0.016);
        }
      });

      expect(log, ['after failed beat', 'next block']);
      expect(timeline.isBusy, isFalse);
      expect(idle, 1);
      expect(uncaught, hasLength(1));
      expect(uncaught.single, isStateError);
    });

    test('moves on when the task of a beat throws', () async {
      var idle = 0;
      final log = <String>[];
      late final TimelineComponent timeline;
      late final Future<void> blockDone;

      final uncaught = await _collectUncaughtErrors(() {
        timeline = TimelineComponent(onIdle: () => idle++);
        blockDone = timeline.enqueue((b) {
          b.wait(0.01);
          b.runBeat((isCancelled) {
            throw StateError('target not mounted');
          });
          b.doSync(() => log.add('after failed beat'));
        });
        timeline.enqueue((b) => b.doSync(() => log.add('next block')));
        timeline.update(0.016);
      });

      expect(log, ['after failed beat', 'next block']);
      expect(timeline.isBusy, isFalse);
      expect(idle, 1);
      expect(uncaught, hasLength(1));
      await expectLater(blockDone, completes);
    });

    test('runs a throwing action once and continues', () async {
      var runs = 0;
      final log = <String>[];
      late final TimelineComponent timeline;

      final uncaught = await _collectUncaughtErrors(() {
        timeline = TimelineComponent();
        timeline.enqueue((b) {
          b.wait(0.1);
          b.doSync(() {
            runs++;
            throw StateError('boom');
          });
          b.doSync(() => log.add('after'));
        });
        for (var i = 0; i < 5; i++) {
          timeline.update(0.1);
        }
      });

      expect(runs, 1);
      expect(log, ['after']);
      expect(timeline.isBusy, isFalse);
      expect(uncaught, hasLength(1));
    });

    test('skipToEnd survives throwing callbacks', () async {
      var idle = 0;
      final log = <String>[];
      late final TimelineComponent timeline;

      final uncaught = await _collectUncaughtErrors(() {
        timeline = TimelineComponent(onIdle: () => idle++);
        timeline.enqueue((b) {
          b.wait(1.0, onSkip: () => throw StateError('skip failed'));
          b.doSync(() => throw StateError('action failed'));
          b.doSync(() => log.add('last'));
        });
        timeline.skipToEnd();
      });

      expect(log, ['last']);
      expect(timeline.isBusy, isFalse);
      expect(idle, 1);
      expect(uncaught, hasLength(2));
    });
  });

  group('TimelineComponent subclass that widens isBusy', () {
    test('keeps ticking and reports onIdle only when a block finishes', () {
      var idle = 0;
      final timeline = _TimelineWithOwnWork(onIdle: () => idle++)..ownWork = 1;

      // No block at all: the base class must neither fall asleep nor report
      // an idle state that no block produced.
      timeline
        ..ticksEnabled = true
        ..update(0.1)
        ..update(0.1);
      expect(timeline.ticksEnabled, isTrue);
      expect(idle, 0);

      timeline.enqueue((b) => b.wait(0.05));
      timeline.update(0.1);
      expect(idle, 1);
      expect(timeline.ticksEnabled, isTrue, reason: 'own work is pending');

      timeline
        ..ownWork = 0
        ..update(0.1);
      expect(timeline.ticksEnabled, isFalse);
      expect(idle, 1);
    });

    test('skipToEnd without blocks does not report onIdle', () {
      var idle = 0;
      final timeline = _TimelineWithOwnWork(onIdle: () => idle++)..ownWork = 1;
      final generation = timeline.generation;

      timeline.skipToEnd();

      expect(idle, 0);
      expect(timeline.generation, generation);
    });
  });

  group('TimelineBuilder.animate', () {
    test('drives a provider-targeted effect without mounting it', () {
      final target = RectangleComponent(size: Vector2.all(10));
      final timeline = TimelineComponent();
      timeline.enqueue((b) {
        b.animate(
          target,
          MoveToEffect(Vector2(10, 0), EffectController(duration: 0.2)),
        );
      });
      timeline.update(0.1);
      expect(target.position.x, closeTo(5, 1e-6));
    });

    test('drives a ColorEffect', () {
      final target = RectangleComponent(size: Vector2.all(10));
      final timeline = TimelineComponent();
      timeline.enqueue((b) {
        b.animate(
          target,
          ColorEffect(
            const Color(0xFFFF0000),
            EffectController(duration: 0.2),
          ),
        );
      });
      timeline.update(0.3);

      expect(timeline.isBusy, isFalse);
      expect(target.paint.colorFilter, isNotNull);
    });

    test('drives the effects of a SequenceEffect', () {
      final target = RectangleComponent(size: Vector2.all(10));
      final timeline = TimelineComponent();
      timeline.enqueue((b) {
        b.animate(
          target,
          SequenceEffect([
            MoveByEffect(Vector2(10, 0), EffectController(duration: 0.1)),
            MoveByEffect(Vector2(0, 10), EffectController(duration: 0.1)),
          ]),
        );
      });
      timeline.update(0.3);

      expect(timeline.isBusy, isFalse);
      expect(target.position, Vector2(10, 10));
    });

    test('skipToEnd snaps a ColorEffect and a SequenceEffect to their end', () {
      final target = RectangleComponent(size: Vector2.all(10));
      final timeline = TimelineComponent();
      timeline.enqueue((b) {
        b.wait(1.0);
        b.animate(
          target,
          SequenceEffect([
            MoveByEffect(Vector2(10, 0), EffectController(duration: 0.1)),
            MoveByEffect(Vector2(0, 10), EffectController(duration: 0.1)),
          ]),
        );
        b.animate(
          target,
          ColorEffect(
            const Color(0xFF00FF00),
            EffectController(duration: 0.2),
          ),
        );
      });

      timeline.skipToEnd();

      expect(target.position, Vector2(10, 10));
      expect(target.paint.colorFilter, isNotNull);
    });

    test('drops an effect that cannot be applied to its target', () async {
      final log = <String>[];
      late final TimelineComponent timeline;

      final uncaught = await _collectUncaughtErrors(() {
        timeline = TimelineComponent();
        timeline.enqueue((b) {
          // A plain Component has no paint to tint.
          b.animate(
            Component(),
            ColorEffect(
              const Color(0xFFFF0000),
              EffectController(duration: 0.2),
            ),
          );
          b.doSync(() => log.add('after'));
        });
        timeline.update(0.1);
      });

      expect(log, ['after']);
      expect(timeline.isBusy, isFalse);
      expect(uncaught, hasLength(1));
    });
  });
}
