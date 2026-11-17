import 'package:flame/components.dart';
import 'package:flame_test/flame_test.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

class _SubscribesInOnMount(
  final ValueNotifier<int> coins,
) extends Component with HasListenableSubscriptions {
  final List<int> seen = <int>[];

  @override
  void onMount() {
    super.onMount();
    listenTo<int>(coins, seen.add);
  }
}

class _SubscribesBeforeSuperOnMount(
  final ValueNotifier<int> coins,
) extends Component with HasListenableSubscriptions {
  final List<int> seen = <int>[];

  @override
  void onMount() {
    listenTo<int>(coins, seen.add, fireImmediately: true);
    super.onMount();
  }
}

class _SubscribesInOnLoad(
  final ValueNotifier<int> coins,
) extends Component with HasListenableSubscriptions {
  final List<int> seen = <int>[];

  @override
  void onLoad() {
    listenTo<int>(coins, seen.add);
  }
}

class _Probe() extends Component with HasListenableSubscriptions;

void main() {
  group('HasListenableSubscriptions', () {
    testWithFlameGame(
      'attaches a subscription registered in onLoad when mounting',
      (game) async {
        final coins = ValueNotifier<int>(0);
        final hud = _SubscribesInOnLoad(coins);
        game.add(hud);
        await game.ready();

        coins.value = 5;

        expect(hud.seen, [5]);
      },
    );

    testWithFlameGame(
      'attaches a subscription registered in onMount after super.onMount',
      (game) async {
        final coins = ValueNotifier<int>(0);
        final hud = _SubscribesInOnMount(coins);
        game.add(hud);
        await game.ready();

        coins.value = 5;

        expect(hud.activeSubscriptionCount, 1);
        expect(hud.seen, [5]);
      },
    );

    testWithFlameGame(
      'attaches and fires once a subscription registered before '
      'super.onMount',
      (game) async {
        final coins = ValueNotifier<int>(3);
        final hud = _SubscribesBeforeSuperOnMount(coins);
        game.add(hud);
        await game.ready();
        expect(hud.seen, [3], reason: 'fireImmediately ran exactly once');

        coins.value = 4;

        expect(hud.activeSubscriptionCount, 1);
        expect(hud.seen, [3, 4]);
      },
    );

    testWithFlameGame(
      'a subscription registered in onMount is not duplicated by a remount',
      (game) async {
        final coins = ValueNotifier<int>(0);
        final hud = _SubscribesInOnMount(coins);
        game.add(hud);
        await game.ready();

        hud.removeFromParent();
        game.update(0);
        expect(hud.activeSubscriptionCount, 0);
        coins.value = 1;
        expect(hud.seen, isEmpty, reason: 'detached while removed');

        game.add(hud);
        await game.ready();
        coins.value = 2;

        expect(hud.activeSubscriptionCount, 1);
        expect(hud.seen, [2]);
      },
    );

    testWithFlameGame(
      'a subscription registered in onLoad is attached again by a remount',
      (game) async {
        final coins = ValueNotifier<int>(0);
        final hud = _SubscribesInOnLoad(coins);
        game.add(hud);
        await game.ready();
        hud.removeFromParent();
        game.update(0);

        game.add(hud);
        await game.ready();
        coins.value = 7;

        expect(hud.activeSubscriptionCount, 1);
        expect(hud.seen, [7]);
      },
    );

    testWithFlameGame(
      'a coalesced callback may clear the subscriptions while they are '
      'being flushed',
      (game) async {
        final a = ValueNotifier<int>(0);
        final b = ValueNotifier<int>(0);
        final probe = _Probe();
        final seen = <String>[];
        probe
          ..listenTo<int>(
            a,
            (value) {
              seen.add('a$value');
              probe.clearSubscriptions();
            },
            coalescePerFrame: true,
          )
          ..listenTo<int>(
            b,
            (value) => seen.add('b$value'),
            coalescePerFrame: true,
          );
        game.add(probe);
        await game.ready();

        a.value = 1;
        b.value = 1;
        expect(seen, isEmpty, reason: 'coalesced until the next flush');

        expect(probe.flushCoalescedSubscriptions, returnsNormally);
        expect(seen, ['a1']);
        expect(probe.activeSubscriptionCount, 0);
      },
    );

    testWithFlameGame(
      'a notification raised during a flush is delivered by the next one',
      (game) async {
        final a = ValueNotifier<int>(0);
        final probe = _Probe();
        final seen = <int>[];
        probe.listenTo<int>(
          a,
          (value) {
            seen.add(value);
            if (value < 2) {
              a.value = value + 1;
            }
          },
          coalescePerFrame: true,
        );
        game.add(probe);
        await game.ready();

        a.value = 1;
        probe.flushCoalescedSubscriptions();
        expect(seen, [1]);

        probe.flushCoalescedSubscriptions();
        expect(seen, [1, 2]);
      },
    );
  });
}
