import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flutter_test/flutter_test.dart';

class const _CoinCollectedEvent(final int amount);

class const _BonusTriggeredEvent(final String reason);

class _BusListenerActor() extends Component with HasEventBusSubscriptions {
  int totalCoins = 0;

  @override
  Future<void> onLoad() async {
    listenEvent<_CoinCollectedEvent>((e) {
      totalCoins += e.amount;
    });
  }
}

class _TaggedActor({
  required final int hp,
  Iterable<String> initialTags = const <String>[],
  super.position,
}) extends PositionComponent with HasTags {
  this {
    addTags(initialTags);
  }
}

void main() {
  group('Signal, WorldEventBus, StateMachine, WorldQuery & Prefab/Save', () {
    test(
      'Signal supports re-entrant disconnect and connectOnce (#9)',
      () {
        final sig = Signal<int>();
        final log = <String>[];
        late SignalSubscription subA;
        subA = sig.connect((v) {
          log.add('A:$v');
          subA.cancel();
        });
        sig.connectOnce((v) => log.add('once:$v'));
        sig.connect((v) => log.add('B:$v'));

        sig.emit(1);
        expect(log, <String>['A:1', 'once:1', 'B:1']);
        expect(sig.listenerCount, 1);

        sig.emit(2);
        expect(log, <String>['A:1', 'once:1', 'B:1', 'B:2']);
      },
    );

    test(
      'WorldEventBus flushes queued events at end of World.updateTree and '
      'detaches HasEventBusSubscriptions on remove (#9)',
      () async {
        final game = FlameGame()..onGameResize(Vector2(400, 300));
        await game.start();
        final actor = _BusListenerActor();
        game.world.add(actor);
        await game.ready();

        // Cascading deferred event: coin -> bonus.
        final bonuses = <String>[];
        game.world.eventBus.on<_BonusTriggeredEvent>(
          (e) => bonuses.add(e.reason),
        );
        game.world.eventBus.on<_CoinCollectedEvent>((e) {
          if (e.amount >= 50) {
            game.world.eventBus.enqueue(
              const _BonusTriggeredEvent('jackpot'),
            );
          }
        });

        game.world.eventBus.enqueue(const _CoinCollectedEvent(60));
        expect(actor.totalCoins, 0);
        expect(game.world.eventBus.pendingCount, 1);

        game.update(1.0 / 60.0);
        expect(actor.totalCoins, 60);
        expect(bonuses, <String>['jackpot']);
        expect(game.world.eventBus.pendingCount, 0);

        // Removing actor cancels its subscription automatically.
        actor.removeFromParent();
        game.update(1.0 / 60.0);
        game.world.eventBus.emit(const _CoinCollectedEvent(25));
        expect(actor.totalCoins, 60);
      },
    );

    test(
      'Hierarchical StateMachine (HFSM) LCA enter/exit, guarded dispatch & '
      'pushState/popState (#10)',
      () {
        final trace = <String>[];
        var stamina = 0;

        final fsm = StateMachine<String, String>(
          initialState: 'patrol',
          states: <StateNode<String>>[
            StateNode<String>(
              id: 'alive',
              onEnter: (_) => trace.add('enter:alive'),
              onExit: (_) => trace.add('exit:alive'),
            ),
            StateNode<String>(
              id: 'combat',
              parent: 'alive',
              onEnter: (_) => trace.add('enter:combat'),
              onExit: (_) => trace.add('exit:combat'),
            ),
            StateNode<String>(
              id: 'patrol',
              parent: 'alive',
              onEnter: (_) => trace.add('enter:patrol'),
              onExit: (_) => trace.add('exit:patrol'),
            ),
            StateNode<String>(
              id: 'melee',
              parent: 'combat',
              onEnter: (_) => trace.add('enter:melee'),
              onExit: (_) => trace.add('exit:melee'),
            ),
            StateNode<String>(
              id: 'ranged',
              parent: 'combat',
              onEnter: (_) => trace.add('enter:ranged'),
              onExit: (_) => trace.add('exit:ranged'),
            ),
            StateNode<String>(
              id: 'stunned',
              parent: 'alive',
              onEnter: (_) => trace.add('enter:stunned'),
              onExit: (_) => trace.add('exit:stunned'),
            ),
          ],
          transitions: <StateTransitionRule<String, String>>[
            StateTransitionRule<String, String>(
              from: 'patrol',
              event: 'spot_target',
              to: 'melee',
              guard: () => stamina >= 10,
            ),
            const StateTransitionRule<String, String>(
              from: 'melee',
              event: 'step_back',
              to: 'ranged',
            ),
          ],
        )..start();

        expect(trace, <String>['enter:alive', 'enter:patrol']);
        expect(fsm.isInState('alive'), isTrue);

        // Guard blocks when stamina < 10.
        expect(fsm.dispatch('spot_target'), isFalse);
        stamina = 20;
        trace.clear();

        // Transition patrol -> melee keeps 'alive' active (LCA = 'alive').
        expect(fsm.dispatch('spot_target'), isTrue);
        expect(
          trace,
          <String>['exit:patrol', 'enter:combat', 'enter:melee'],
        );
        expect(fsm.isInState('combat'), isTrue);

        // Transition melee -> ranged keeps 'alive' AND 'combat' active!
        trace.clear();
        expect(fsm.dispatch('step_back'), isTrue);
        expect(trace, <String>['exit:melee', 'enter:ranged']);

        // Pushdown overlay state: ranged -> stunned -> pop back to ranged.
        fsm.pushState('stunned');
        expect(fsm.currentState, 'stunned');
        expect(fsm.stackDepth, 1);
        expect(fsm.popState(), isTrue);
        expect(fsm.currentState, 'ranged');
        expect(fsm.stackDepth, 0);
      },
    );

    test(
      'WorldQuery maintains incremental O(1) result sets on World add/remove '
      '(#12)',
      () async {
        final world = World();
        final game = FlameGame(world: world)..onGameResize(Vector2(300, 300));
        await game.start();
        await game.ready();

        final matchedCount = <int>[];
        final query = world.registerQuery<_TaggedActor>(
          WorldQuery<_TaggedActor>(
            withTags: const <String>['enemy'],
            withoutTags: const <String>['cloaked'],
            filter: (a) => a.hp > 0,
            onMatched: (_) => matchedCount.add(1),
          ),
        );

        final orc = _TaggedActor(hp: 50, initialTags: const <String>['enemy']);
        final ghost = _TaggedActor(
          hp: 40,
          initialTags: const <String>['enemy', 'cloaked'],
        );
        final corpse = _TaggedActor(
          hp: 0,
          initialTags: const <String>['enemy'],
        );

        world.addAll(<Component>[orc, ghost, corpse]);
        await game.ready();

        expect(query.items, <_TaggedActor>[orc]);
        expect(matchedCount.length, 1);

        orc.removeFromParent();
        game.update(0.016);
        expect(query.isEmpty, isTrue);
      },
    );

    test(
      'PrefabRegistry instantiates merged overrides and StateSnapshotStore '
      'validates CRC32 + runs SaveMigrationChain (#13)',
      () {
        final prefabs = PrefabRegistry()
          ..register<_TaggedActor>(
            'goblin',
            (params) => _TaggedActor(
              hp: params['hp']! as int,
              position: Vector2(
                (params['x']! as num).toDouble(),
                (params['y']! as num).toDouble(),
              ),
            ),
            defaultParams: const <String, Object?>{'hp': 30, 'x': 0, 'y': 0},
          );

        final spawned = prefabs.instantiate<_TaggedActor>(
          'goblin',
          const <String, Object?>{'hp': 75, 'x': 120},
        );
        expect(spawned.hp, 75);
        expect(spawned.position, Vector2(120, 0));

        // Build a v1 snapshot, then decode it under a v3 store!
        final v1Store = StateSnapshotStore(
          migrations: SaveMigrationChain(currentVersion: 1),
        );
        final v1Envelope = v1Store.encodeJsonEnvelope(<String, Object?>{
          'gold': 100,
        });

        final migrationsToV3 = SaveMigrationChain(currentVersion: 3)
          ..addStep(
            1,
            (old) => <String, Object?>{
              ...old,
              'gems': ((old['gold']! as int) ~/ 10),
            },
          )
          ..addStep(
            2,
            (old) => <String, Object?>{
              ...old,
              'rank': 'silver',
            },
          );
        final v3Store = StateSnapshotStore(migrations: migrationsToV3);

        final upgraded = v3Store.decodeJsonEnvelope(v1Envelope);
        expect(upgraded, <String, Object?>{
          'gold': 100,
          'gems': 10,
          'rank': 'silver',
        });

        // Tamper with payload body -> CRC32 mismatch FormatException!
        final corrupted = v1Envelope.replaceFirst('100', '999');
        expect(
          () => v3Store.decodeJsonEnvelope(corrupted),
          throwsFormatException,
        );
      },
    );
  });
}
