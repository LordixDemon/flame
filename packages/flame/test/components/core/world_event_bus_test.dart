import 'package:flame/components.dart';
import 'package:flame_test/flame_test.dart';
import 'package:flutter_test/flutter_test.dart';

class const _Ping(final int id);

sealed class const _GameEvent();

class const _CoinPicked() extends _GameEvent;

class const _DoorOpened() extends _GameEvent;

class _Tagged() extends Component with HasTags;

class _PausableLayer() extends Component with CustomTraversal, HasTimeScale;

void main() {
  group('World.eventBus delivery', () {
    testWithFlameGame(
      'events queued on the primary world are delivered at the end of the tick',
      (game) async {
        final received = <int>[];
        game.world.eventBus.on<_Ping>((e) => received.add(e.id));
        game.world.eventBus.enqueue(const _Ping(1));
        expect(received, isEmpty);

        game.update(0.016);

        expect(received, [1]);
      },
    );

    testWithFlameGame(
      'events queued on an additional mounted world are delivered as well',
      (game) async {
        final secondWorld = World();
        final secondCamera = CameraComponent(world: secondWorld);
        game.addAll([secondWorld, secondCamera]);
        await game.ready();

        final received = <int>[];
        secondWorld.eventBus.on<_Ping>((e) => received.add(e.id));
        secondWorld.eventBus.enqueue(const _Ping(7));

        game.update(0.016);

        expect(received, [7]);
        expect(secondWorld.eventBus.pendingCount, 0);
      },
    );

    testWithFlameGame(
      'events are delivered after every component of the tick has updated',
      (game) async {
        final secondWorld = World();
        game.add(secondWorld);
        final log = <String>[];
        secondWorld.add(_UpdateLogger('early', log, priority: -1));
        secondWorld.add(_UpdateLogger('late', log, priority: 1));
        await game.ready();
        secondWorld.eventBus.on<_Ping>((e) => log.add('event ${e.id}'));
        secondWorld.eventBus.enqueue(const _Ping(3));

        game.update(0.016);

        expect(log, ['early', 'late', 'event 3']);
      },
    );

    testWithFlameGame(
      'a world below a CustomTraversal component delivers at the end of its '
      'own update',
      (game) async {
        final layer = _PausableLayer();
        final nested = World();
        layer.add(nested);
        game.add(layer);
        await game.ready();
        final received = <int>[];
        nested.eventBus.on<_Ping>((e) => received.add(e.id));

        nested.eventBus.enqueue(const _Ping(1));
        game.update(0.016);
        expect(received, [1]);

        // While the layer is paused the world is not updated, so its events
        // wait.
        layer.pause();
        nested.eventBus.enqueue(const _Ping(2));
        game.update(0.016);
        expect(received, [1]);

        layer.resume();
        game.update(0.016);
        expect(received, [1, 2]);
      },
    );

    testWithFlameGame(
      'a world that joins the game later is picked up',
      (game) async {
        game.update(0.016);
        final lateWorld = World();
        game.add(lateWorld);
        await game.ready();
        final received = <int>[];
        lateWorld.eventBus.on<_Ping>((e) => received.add(e.id));
        lateWorld.eventBus.enqueue(const _Ping(9));

        game.update(0.016);

        expect(received, [9]);
      },
    );
  });

  group('WorldEventBus routing', () {
    test('an event reaches the listeners of its type', () {
      final bus = WorldEventBus();
      var coins = 0;
      bus.on<_CoinPicked>((_) => coins++);
      bus.emit(const _CoinPicked());
      expect(coins, 1);
    });

    test('an event passed around as a supertype reaches the listeners of its '
        'runtime type', () {
      final bus = WorldEventBus();
      var coins = 0;
      var doors = 0;
      bus.on<_CoinPicked>((_) => coins++);
      bus.on<_DoorOpened>((_) => doors++);

      void post(_GameEvent event) => bus.enqueue(event);

      const decoded = <_GameEvent>[
        _CoinPicked(),
        _DoorOpened(),
        _CoinPicked(),
      ];
      decoded.forEach(post);
      final dispatched = bus.flushQueue();

      expect(dispatched, 3);
      expect([coins, doors], [2, 1]);
    });

    test('the listeners of the static type receive the event too, once', () {
      final bus = WorldEventBus();
      final log = <String>[];
      bus.on<_GameEvent>((_) => log.add('any'));
      bus.on<_CoinPicked>((_) => log.add('coin'));

      const _GameEvent event = _CoinPicked();
      bus.emit(event);
      expect(log, ['coin', 'any']);

      // Emitted with its own type, only the concrete listeners are notified.
      log.clear();
      bus.emit(const _CoinPicked());
      expect(log, ['coin']);
    });

    test('once() listeners are routed by the runtime type as well', () {
      final bus = WorldEventBus();
      var doors = 0;
      bus.once<_DoorOpened>((_) => doors++);

      const _GameEvent event = _DoorOpened();
      bus
        ..emit(event)
        ..emit(event);

      expect(doors, 1);
    });

    test('a flush requested by a listener does not lose queued events', () {
      final bus = WorldEventBus();
      final received = <int>[];
      bus.on<_Ping>((e) {
        received.add(e.id);
        if (e.id == 1) {
          bus.enqueue(const _Ping(4));
          expect(bus.flushQueue(), 0, reason: 'a flush is already running');
        }
      });
      bus
        ..enqueue(const _Ping(1))
        ..enqueue(const _Ping(2))
        ..enqueue(const _Ping(3));

      final dispatched = bus.flushQueue();

      expect(received, [1, 2, 3, 4]);
      expect(dispatched, 4);
      expect(bus.pendingCount, 0);
    });
  });

  group('WorldQuery of a world that leaves the tree', () {
    testWithFlameGame(
      'drops its members and matches them again when the world returns',
      (game) async {
        final world = World();
        game.add(world);
        final tagged = _Tagged()..addTag('enemy');
        world.add(tagged);
        await game.ready();
        final events = <String>[];
        final query = world.registerQuery(
          WorldQuery<_Tagged>(
            withTags: ['enemy'],
            onMatched: (_) => events.add('matched'),
            onUnmatched: (_) => events.add('unmatched'),
          ),
        );
        expect(query.items, [tagged]);
        events.clear();

        world.removeFromParent();
        game.update(0);

        expect(tagged.isMounted, isFalse);
        expect(query.items, isEmpty);
        expect(events, ['unmatched']);

        game.add(world);
        await game.ready();

        expect(query.items, [tagged]);
        expect(events, ['unmatched', 'matched']);
      },
    );
  });
}

class _UpdateLogger(
  final String name,
  final List<String> log, {
  super.priority,
}) extends Component {
  @override
  void update(double dt) => log.add(name);
}
