import 'dart:async';

import 'package:flame/components.dart';
import 'package:flame/effects.dart';
import 'package:flame/game.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

class _ReactiveProbe() extends Component with HasListenableSubscriptions {
  final List<int> seenValues = <int>[];
  int pulseCount = 0;
}

void main() {
  group('TimelineComponent (#4)', () {
    test(
      'executes sequential, parallel, stagger, and effect steps precisely',
      () {
        final events = <String>[];
        var idleCount = 0;
        final actor = PositionComponent(position: Vector2.zero());
        final timeline = TimelineComponent(onIdle: () => idleCount++);

        expect(timeline.ticksEnabled, isFalse);

        timeline.enqueue((b) {
          b.doSync(() => events.add('start'));
          b.wait(0.2);
          b.animate(
            actor,
            MoveToEffect(Vector2(100, 0), EffectController(duration: 0.3)),
          );
          b.parallel([
            (p) {
              p.wait(0.1);
              p.doSync(() => events.add('p1'));
            },
            (p) {
              p.wait(0.2);
              p.doSync(() => events.add('p2'));
            },
          ]);
          b.stagger<String>(['a', 'b', 'c'], 0.05, (s, item, _) {
            s.doSync(() => events.add('stagger:$item'));
          });
          b.doSync(() => events.add('done'));
        });

        expect(events, ['start']);
        expect(timeline.isBusy, isTrue);
        expect(timeline.ticksEnabled, isTrue);

        timeline.update(0.25);
        expect(actor.position.x, closeTo(100 * (0.05 / 0.3), 1e-3));

        timeline.update(0.30);
        expect(actor.position.x, closeTo(100, 1e-3));
        expect(events, ['start']);

        timeline.update(0.10);
        expect(events, ['start', 'p1']);

        timeline.update(0.20);
        expect(events, [
          'start',
          'p1',
          'p2',
          'stagger:a',
          'stagger:b',
          'stagger:c',
          'done',
        ]);
        expect(timeline.isBusy, isFalse);
        expect(timeline.ticksEnabled, isFalse);
        expect(idleCount, 1);
      },
    );

    test('playbackRate scales speed and skipToEnd snaps state immediately', () {
      var progressValue = 0.0;
      final actor = PositionComponent(position: Vector2.zero());
      final timeline = TimelineComponent(playbackRate: 2.0)
        ..enqueue((b) {
          b.tween(0.4, (p) => progressValue = p);
          b.animate(
            actor,
            MoveToEffect(Vector2(50, 25), EffectController(duration: 0.6)),
          );
        })
        ..update(0.1);
      expect(progressValue, closeTo(0.5, 1e-5));

      timeline.skipToEnd();
      expect(progressValue, closeTo(1.0, 1e-5));
      expect(actor.position.x, closeTo(50, 1e-4));
      expect(actor.position.y, closeTo(25, 1e-4));
      expect(timeline.isBusy, isFalse);
    });

    test(
      'cancel increments generation and invalidates suspended async beats',
      () async {
        final completer = Completer<void>();
        var cancelledSeen = false;
        var postCancelExecuted = false;
        final timeline = TimelineComponent();

        unawaited(
          timeline.enqueue((b) {
            b.runBeat((isCancelled) async {
              await completer.future;
              cancelledSeen = isCancelled();
              if (!isCancelled()) {
                postCancelExecuted = true;
              }
            });
            b.doSync(() => postCancelExecuted = true);
          }),
        );

        timeline.update(0.016);
        final genBefore = timeline.generation;
        timeline.cancel();
        expect(timeline.generation, greaterThan(genBefore));
        expect(timeline.isBusy, isFalse);

        completer.complete();
        await Future<void>.delayed(Duration.zero);

        expect(cancelledSeen, isTrue);
        expect(postCancelExecuted, isFalse);
      },
    );
  });

  group('HasListenableSubscriptions (#8)', () {
    testWidgets(
      'attaches on mount, coalesces mutations, and detaches on remove',
      (tester) async {
        final counter = ValueNotifier<int>(10);
        final pulse = ChangeNotifier();
        addTearDown(() {
          counter.dispose();
          pulse.dispose();
        });

        final game = FlameGame();
        final probe = _ReactiveProbe();
        probe
          ..listenTo<int>(
            counter,
            probe.seenValues.add,
            fireImmediately: true,
            coalescePerFrame: true,
          )
          ..listenToListenable(pulse, () => probe.pulseCount++);

        expect(probe.activeSubscriptionCount, 0);
        counter.value = 11;
        expect(probe.seenValues, isEmpty);

        game.world.add(probe);
        await tester.pumpWidget(GameWidget(game: game));
        await tester.pump();

        expect(probe.activeSubscriptionCount, 2);
        expect(probe.seenValues, [11]);

        counter
          ..value = 12
          ..value = 13
          ..value = 14;
        expect(probe.seenValues, [11]);

        game.update(1 / 60);
        expect(probe.seenValues, [11, 14]);

        pulse.notifyListeners();
        expect(probe.pulseCount, 1);

        probe.removeFromParent();
        game.processLifecycleEvents();
        expect(probe.activeSubscriptionCount, 0);

        counter.value = 99;
        pulse.notifyListeners();
        game.update(1 / 60);
        expect(probe.seenValues, [11, 14]);
        expect(probe.pulseCount, 1);

        game.world.add(probe);
        game.processLifecycleEvents();
        expect(probe.activeSubscriptionCount, 2);
        expect(probe.seenValues, [11, 14, 99]);
      },
    );
  });
}
