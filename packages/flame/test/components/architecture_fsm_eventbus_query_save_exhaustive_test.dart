import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flutter_test/flutter_test.dart';

class const _PingEvent(final int depth);
class const _ScoreEvent(final int points);

class _EventSubscriber(this.externalSignal)
    extends Component
    with HasEventBusSubscriptions {
  final List<int> received = <int>[];
  final List<int> onLoadReceived = <int>[];
  final List<int> onceReceived = <int>[];
  final List<String> signalReceived = <String>[];

  final Signal<String> externalSignal;

  @override
  Future<void> onLoad() async {
    listenEvent<_ScoreEvent>((e) => onLoadReceived.add(e.points));
  }

  @override
  void onMount() {
    super.onMount();
    listenEvent<_ScoreEvent>((e) => received.add(e.points));
    listenEventOnce<_ScoreEvent>((e) => onceReceived.add(e.points));
    autoCancelSignal(externalSignal.connect(signalReceived.add));
  }
}

class _CombatActor({
  required this.hp,
  Iterable<String> initialTags = const <String>[],
}) extends PositionComponent with HasTags {
  int hp;

  this {
    addTags(initialTags);
  }
}

enum _HeroState() {
  root,
  grounded,
  idle,
  running,
  airborne,
  jumping,
  paused,
}

enum _HeroEvent() {
  move,
  jump,
  land,
  pause,
}

void main() {
  group('Signal, WorldEventBus & HasEventBusSubscriptions edge cases', () {
    test('Signal supports mid-emit cancel, connectOnce & nested emit', () {
      final sig = Signal<int>();
      final log = <String>[];
      late SignalSubscription subB;

      sig.connect((v) {
        log.add('A:$v');
        if (v == 1) {
          subB.cancel();
          sig.emit(2);
        }
      });
      subB = sig.connect((v) => log.add('B:$v'));
      sig.connectOnce((v) => log.add('Once:$v'));

      sig.emit(1);
      // Synchronous recursion + active check: during v=1, A cancels B before B
      // runs (so B is skipped!), and nested emit(2) runs A:2 + Once:2 (which
      // cancels Once before outer emit(1) reaches it, guaranteeing Once fires
      // strictly once!).
      expect(log, <String>['A:1', 'A:2', 'Once:2']);
      expect(subB.isCancelled, isTrue);
      expect(sig.listenerCount, 1);

      sig.clear();
      expect(sig.listenerCount, 0);
    });

    test('WorldEventBus caps runaway enqueue cascades per flushQueue', () {
      final bus = WorldEventBus(maxFlushIterations: 5);
      var cascadeCount = 0;
      bus.on<_PingEvent>((e) {
        cascadeCount++;
        bus.enqueue(_PingEvent(e.depth + 1));
      });
      bus.enqueue(const _PingEvent(0));
      bus.flushQueue();
      expect(cascadeCount, 5);
      // Remaining runaway item stays deferred rather than hanging the frame!
      expect(bus.pendingCount, 1);
      bus.clear();
      expect(bus.pendingCount, 0);
    });

    test(
      'HasEventBusSubscriptions survives unmount & remount across Worlds',
      () async {
        final worldA = World();
        final worldB = World();
        final gameA = FlameGame(world: worldA)..onGameResize(Vector2(400, 300));
        final gameB = FlameGame(world: worldB)..onGameResize(Vector2(400, 300));
        await gameA.start();
        await gameA.ready();
        await gameB.start();
        await gameB.ready();

        final extSignal = Signal<String>();
        final sub = _EventSubscriber(extSignal);
        worldA.add(sub);
        await gameA.ready();

        worldA.eventBus.emit(const _ScoreEvent(10));
        worldA.eventBus.emit(const _ScoreEvent(20));
        extSignal.emit('alpha');
        expect(sub.received, <int>[10, 20]);
        expect(sub.onceReceived, <int>[10]);
        expect(sub.signalReceived, <String>['alpha']);

        // Unmount from worldA: listeners must detach immediately.
        sub.removeFromParent();
        await gameA.ready();
        worldA.eventBus.emit(const _ScoreEvent(99));
        extSignal.emit('while_unmounted');
        expect(sub.received, <int>[10, 20]);
        expect(sub.signalReceived, <String>['alpha']);

        // Remount into worldB: fresh subscriptions bind cleanly to worldB!
        worldB.add(sub);
        await gameB.ready();
        worldB.eventBus.enqueue(const _ScoreEvent(50));
        gameB.update(1 / 60);
        extSignal.emit('beta');
        expect(sub.received, <int>[10, 20, 50]);
        expect(sub.onLoadReceived, <int>[10, 20, 50]);
        expect(sub.onceReceived, <int>[10, 50]);
        expect(sub.signalReceived, <String>['alpha', 'beta']);
      },
    );
  });

  group('Hierarchical StateMachine re-entrancy & LCA invariants', () {
    test('4-level LCA ordering, wildcard rules & re-entrant transitions', () {
      final trace = <String>[];
      var autoJumpOnRunEnter = false;
      var autoLandAfterAirUpdate = false;

      late final StateMachine<_HeroState, _HeroEvent> sm;
      sm =
          StateMachine<_HeroState, _HeroEvent>(
              initialState: _HeroState.idle,
            )
            ..registerState(
              StateNode<_HeroState>(
                id: _HeroState.root,
                onEnter: (_) => trace.add('+root'),
                onExit: (_) => trace.add('-root'),
              ),
            )
            ..registerState(
              StateNode<_HeroState>(
                id: _HeroState.grounded,
                parent: _HeroState.root,
                onEnter: (_) => trace.add('+grounded'),
                onExit: (_) => trace.add('-grounded'),
              ),
            )
            ..registerState(
              StateNode<_HeroState>(
                id: _HeroState.idle,
                parent: _HeroState.grounded,
                onEnter: (_) => trace.add('+idle'),
                onExit: (_) => trace.add('-idle'),
              ),
            )
            ..registerState(
              StateNode<_HeroState>(
                id: _HeroState.running,
                parent: _HeroState.grounded,
                onEnter: (_) {
                  trace.add('+running');
                  if (autoJumpOnRunEnter) {
                    sm.transitionTo(_HeroState.jumping);
                  }
                },
                onExit: (_) => trace.add('-running'),
              ),
            )
            ..registerState(
              StateNode<_HeroState>(
                id: _HeroState.airborne,
                parent: _HeroState.root,
                onEnter: (_) => trace.add('+airborne'),
                onExit: (_) => trace.add('-airborne'),
                onUpdate: (dt, _) {
                  trace.add('~airborne');
                  if (autoLandAfterAirUpdate) {
                    sm.dispatch(_HeroEvent.land);
                  }
                },
              ),
            )
            ..registerState(
              StateNode<_HeroState>(
                id: _HeroState.jumping,
                parent: _HeroState.airborne,
                onEnter: (_) => trace.add('+jumping'),
                onExit: (_) => trace.add('-jumping'),
                onUpdate: (dt, _) => trace.add('~jumping'),
              ),
            )
            ..registerState(
              StateNode<_HeroState>(
                id: _HeroState.paused,
                onEnter: (_) => trace.add('+paused'),
                onExit: (_) => trace.add('-paused'),
              ),
            )
            ..addTransition(
              from: _HeroState.idle,
              onEvent: _HeroEvent.move,
              to: _HeroState.running,
            )
            ..addTransition(
              from: _HeroState.grounded,
              onEvent: _HeroEvent.jump,
              to: _HeroState.jumping,
            )
            ..addTransition(
              from: _HeroState.airborne,
              onEvent: _HeroEvent.land,
              to: _HeroState.idle,
            )
            ..addTransition(
              onEvent: _HeroEvent.pause,
              to: _HeroState.paused,
            );

      sm.start();
      expect(trace, <String>['+root', '+grounded', '+idle']);
      expect(sm.isInState(_HeroState.root), isTrue);
      expect(sm.isInState(_HeroState.grounded), isTrue);

      // Re-entrant transition inside onEnter (+running immediately transitions
      // to jumping without corrupting ancestor scratch lists!).
      trace.clear();
      autoJumpOnRunEnter = true;
      expect(sm.dispatch(_HeroEvent.move), isTrue);
      expect(sm.currentState, _HeroState.jumping);
      expect(
        trace,
        <String>[
          '-idle',
          '+running',
          '-running',
          '-grounded',
          '+airborne',
          '+jumping',
        ],
      );

      // Re-entrant transition inside parent onUpdate (~airborne dispatches land
      // and cleanly breaks out without running stale ~jumping!).
      trace.clear();
      autoLandAfterAirUpdate = true;
      sm.update(0.1);
      expect(sm.currentState, _HeroState.idle);
      expect(
        trace,
        <String>['~airborne', '-jumping', '-airborne', '+grounded', '+idle'],
      );

      // Pushdown stack pushState / popState & wildcard dispatch.
      expect(sm.dispatch(_HeroEvent.pause), isTrue);
      expect(sm.currentState, _HeroState.paused);
      sm.transitionTo(_HeroState.idle);
      sm.pushState(_HeroState.paused);
      expect(sm.stackDepth, 1);
      expect(sm.currentState, _HeroState.paused);
      expect(sm.popState(), isTrue);
      expect(sm.currentState, _HeroState.idle);
      expect(sm.popState(), isFalse);

      // Self-transition flag check.
      expect(sm.transitionTo(_HeroState.idle), isFalse);
      trace.clear();
      expect(
        sm.transitionTo(_HeroState.idle, allowSelfTransition: true),
        isTrue,
      );
      expect(trace, <String>['-idle', '+idle']);

      // Cyclic parent graph guard terminates safely without hanging!
      final cyclic = StateMachine<int, int>(initialState: 1)
        ..registerState(StateNode<int>(id: 1, parent: 2))
        ..registerState(StateNode<int>(id: 2, parent: 1))
        ..start();
      expect(cyclic.isInState(2), isTrue);
    });
  });

  group('HasTags, WorldQuery, PrefabRegistry & StateSnapshotStore', () {
    test(
      'live tag mutations & revalidateQueriesFor update O(1) WorldQuery',
      () async {
        final world = World();
        final game = FlameGame(world: world)..onGameResize(Vector2(400, 300));
        await game.start();
        await game.ready();

        final matchedLog = <String>[];
        final unmatchedLog = <String>[];
        final woundedEnemies = world.registerQuery<_CombatActor>(
          WorldQuery<_CombatActor>(
            withTags: const <String>['enemy', 'alive'],
            withoutTags: const <String>['stealthed'],
            filter: (a) => a.hp < 50,
            onMatched: (a) => matchedLog.add('in:${a.hp}'),
            onUnmatched: (a) => unmatchedLog.add('out:${a.hp}'),
          ),
        );

        final orc = _CombatActor(hp: 80, initialTags: const ['enemy', 'alive']);
        world.add(orc);
        await game.ready();
        expect(woundedEnemies.length, 0);

        // Mutate HP and notify World -> enters query!
        orc.hp = 35;
        world.revalidateQueriesFor(orc);
        expect(woundedEnemies.length, 1);
        expect(matchedLog, <String>['in:35']);

        // Live addTag('stealthed') on mounted component auto-removes!
        orc.addTag('stealthed');
        expect(woundedEnemies.length, 0);
        expect(unmatchedLog, <String>['out:35']);

        // Live removeTag('stealthed') re-matches automatically!
        orc.removeTag('stealthed');
        expect(woundedEnemies.length, 1);

        // clearTags evicts cleanly.
        orc.clearTags();
        expect(woundedEnemies.length, 0);

        world.unregisterQuery(woundedEnemies);
        orc.addTags(const ['enemy', 'alive']);
        expect(woundedEnemies.length, 0);
      },
    );

    test(
      'PrefabRegistry & StateSnapshotStore enforce types, migrations & CRC',
      () {
        final prefabs = PrefabRegistry()
          ..register<_CombatActor>(
            'goblin',
            (p) => _CombatActor(
              hp: p['hp']! as int,
              initialTags: <String>[
                'enemy',
                if (p['elite']! as bool) 'elite',
              ],
            ),
            defaultParams: const <String, Object?>{'hp': 30, 'elite': false},
          );

        final normal = prefabs.instantiate<_CombatActor>('goblin');
        final elite = prefabs.instantiate<_CombatActor>(
          'goblin',
          const <String, Object?>{'hp': 95, 'elite': true},
        );
        expect(normal.hp, 30);
        expect(normal.hasTag('elite'), isFalse);
        expect(elite.hp, 95);
        expect(elite.hasTag('elite'), isTrue);
        // Defaults remained unmutated after overrides.
        expect(prefabs.instantiate<_CombatActor>('goblin').hp, 30);

        expect(
          () => prefabs.instantiate<_CombatActor>('dragon'),
          throwsStateError,
        );
        expect(
          () => prefabs.instantiate<SpriteComponent>('goblin'),
          throwsStateError,
        );

        // SaveMigrationChain v1 -> v2 -> v3 -> v4 & error cases.
        final chain = SaveMigrationChain(currentVersion: 4)
          ..addStep(
            1,
            (d) => <String, Object?>{...d, 'coins': (d['gold']! as int) * 10},
          )
          ..addStep(2, (d) => <String, Object?>{...d, 'gems': 5})
          ..addStep(3, (d) => <String, Object?>{...d, 'schemaReady': true});

        expect(() => chain.addStep(0, (d) => d), throwsRangeError);
        expect(() => chain.addStep(4, (d) => d), throwsRangeError);

        final store = StateSnapshotStore(migrations: chain);
        final v1Envelope = StateSnapshotStore(
          migrations: SaveMigrationChain(currentVersion: 1),
        ).encodeJsonEnvelope(const <String, Object?>{'gold': 12});

        final migrated = store.decodeJsonEnvelope(v1Envelope);
        expect(migrated['coins'], 120);
        expect(migrated['gems'], 5);
        expect(migrated['schemaReady'], isTrue);

        // Corrupt payload bit inside body triggers CRC32 FormatException.
        final tampered = v1Envelope.replaceFirst('12', '99');
        expect(() => store.decodeJsonEnvelope(tampered), throwsFormatException);

        // Future version envelope triggers FormatException.
        final futureEnv = StateSnapshotStore(
          migrations: SaveMigrationChain(currentVersion: 9),
        ).encodeJsonEnvelope(const <String, Object?>{'ok': true});
        expect(
          () => store.decodeJsonEnvelope(futureEnv),
          throwsFormatException,
        );

        // Incomplete migration chain throws StateError.
        final brokenStore = StateSnapshotStore(
          migrations: SaveMigrationChain(currentVersion: 3)
            ..addStep(1, (d) => d),
        );
        expect(
          () => brokenStore.decodeJsonEnvelope(v1Envelope),
          throwsStateError,
        );
      },
    );
  });
}
