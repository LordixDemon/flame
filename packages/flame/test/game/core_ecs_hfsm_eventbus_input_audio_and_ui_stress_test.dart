import 'dart:ui' as ui;

import 'package:flame/audio.dart';
import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flame/layout.dart';
import 'package:flame/math.dart';
import 'package:flame/text.dart';
import 'package:flutter_test/flutter_test.dart';

class _DeepTaggedEntity({
  required this.id,
  required this.hp,
  Iterable<String> tags = const <String>[],
}) extends PositionComponent with HasTags {
  final int id;
  int hp;

  this {
    addTags(tags);
  }
}

class const _CascadeBurstEvent(final int remaining);

void main() {
  group('5,000-entity deep WorldQuery + HasTags vs brute-force oracle', () {
    test(
      'maintains exact O(1) WorldQuery membership across 5,000 nested '
      'components during 500 random tag, filter, mount, and unmount mutations',
      () async {
        final world = World();
        final game = FlameGame(world: world)..onGameResize(Vector2(400, 300));
        await game.start();
        addTearDown(game.onRemove);

        final query = world.registerQuery<_DeepTaggedEntity>(
          WorldQuery<_DeepTaggedEntity>(
            withTags: const <String>['unit', 'active'],
            withoutTags: const <String>['banished'],
            filter: (e) => e.hp > 25,
          ),
        );

        final rng = SeededRng(0xEC55000);
        final squads = List<PositionComponent>.generate(
          25,
          (_) => PositionComponent(),
        );
        world.addAll(squads);

        final entities = <_DeepTaggedEntity>[];
        for (var i = 0; i < 5000; i++) {
          final ent = _DeepTaggedEntity(
            id: i,
            hp: rng.nextInt(100),
            tags: <String>[
              if (rng.nextBool()) 'unit',
              if (rng.nextBool()) 'active',
              if (rng.nextInt(5) == 0) 'banished',
            ],
          );
          entities.add(ent);
          squads[i % squads.length].add(ent);
        }
        await game.ready();

        Set<int> bruteForceExpectedIds() {
          final out = <int>{};
          void walk(Component c) {
            if (c is _DeepTaggedEntity &&
                c.hasTag('unit') &&
                c.hasTag('active') &&
                !c.hasTag('banished') &&
                c.hp > 25) {
              out.add(c.id);
            }
            for (final child in c.children) {
              walk(child);
            }
          }

          walk(world);
          return out;
        }

        expect(
          query.items.map((e) => e.id).toSet(),
          bruteForceExpectedIds(),
        );

        final directQuery = world.registerQuery<_DeepTaggedEntity>(
          WorldQuery<_DeepTaggedEntity>(
            withTags: const <String>['unit', 'active'],
            withoutTags: const <String>['banished'],
            includeSubtree: false,
            filter: (e) => e.hp > 25,
          ),
        );

        const tagPool = <String>['unit', 'active', 'banished', 'buffed'];
        for (var step = 0; step < 500; step++) {
          final ent = entities[rng.nextInt(entities.length)];
          final op = rng.nextInt(5);
          if (op == 0) {
            ent.addTag(tagPool[rng.nextInt(tagPool.length)]);
          } else if (op == 1) {
            ent.removeTag(tagPool[rng.nextInt(tagPool.length)]);
          } else if (op == 2) {
            ent.hp = rng.nextInt(100);
            if (ent.isMounted) {
              world.revalidateQueriesFor(ent);
            }
          } else if (op == 3 && ent.isMounted) {
            ent.removeFromParent();
          } else if (op == 4 && !ent.isMounted) {
            squads[rng.nextInt(squads.length)].add(ent);
          }

          if (step % 50 == 49) {
            await game.ready();
            expect(
              query.items.map((e) => e.id).toSet(),
              bruteForceExpectedIds(),
              reason: 'WorldQuery desynced at step $step',
            );
            // Direct-only query must never include nested squad members.
            expect(directQuery.items, isEmpty);
          }
        }

        // Unmounted add -> addTag -> cancel before mount must not leak into
        // WorldQuery.items!
        final ephemeral = _DeepTaggedEntity(id: 99999, hp: 99);
        squads.first.add(ephemeral);
        ephemeral.addTags(const <String>['unit', 'active']);
        squads.first.remove(ephemeral);
        await game.ready();
        expect(query.items.any((e) => e.id == 99999), isFalse);
      },
    );
  });

  group('HFSM re-entrant stack, EventBus cap & CRC32 bit-flip fuzz', () {
    test(
      'proves strict ancestor enter/exit balance across 1,000 random HFSM '
      'transitions + 32-deep pushdown stack, caps 10,000-event cascades, and '
      'rejects 100 single-char CRC32 save corruptions across 12 migrations',
      () {
        final activeAncestors = <int>[];
        late final StateMachine<int, int> sm;
        sm = StateMachine<int, int>(initialState: 3);

        // 3-tier hierarchy: 0 -> {1 -> {3, 4}, 2 -> {5, 6}}, plus overlay 7..9.
        const parents = <int, int?>{
          0: null,
          1: 0,
          2: 0,
          3: 1,
          4: 1,
          5: 2,
          6: 2,
          7: null,
          8: 7,
          9: 8,
        };
        var reentrantTriggerArmed = false;

        for (final entry in parents.entries) {
          final id = entry.key;
          sm.registerState(
            StateNode<int>(
              id: id,
              parent: entry.value,
              onEnter: (_) {
                expect(activeAncestors.contains(id), isFalse);
                activeAncestors.add(id);
                if (id == 4 && reentrantTriggerArmed) {
                  reentrantTriggerArmed = false;
                  sm.transitionTo(6);
                }
              },
              onExit: (_) {
                expect(
                  activeAncestors.last,
                  id,
                  reason: 'LIFO ancestor exit violated when exiting state $id',
                );
                activeAncestors.removeLast();
              },
            ),
          );
        }

        sm.start();
        expect(activeAncestors, <int>[0, 1, 3]);

        final rng = SeededRng(0x4F531234);
        for (var i = 0; i < 1000; i++) {
          final roll = rng.nextInt(5);
          if (roll <= 2) {
            reentrantTriggerArmed = i % 11 == 0;
            sm.transitionTo(3 + rng.nextInt(7));
          } else if (roll == 3 && sm.stackDepth < 32) {
            sm.pushState(7 + rng.nextInt(3));
          } else if (roll == 4) {
            sm.popState();
          }
          sm.update(0.016);
          expect(activeAncestors.last, sm.currentState);
        }

        // WorldEventBus 10,000-event cascade cap + mid-emit unsubscription!
        final bus = WorldEventBus(maxFlushIterations: 250);
        var processed = 0;
        bus.on<_CascadeBurstEvent>((e) {
          processed++;
          if (e.remaining > 0) {
            bus.enqueue(_CascadeBurstEvent(e.remaining - 1));
          }
        });
        bus
          ..enqueue(const _CascadeBurstEvent(10000))
          ..flushQueue();
        expect(processed, 250);
        expect(bus.pendingCount, 1);

        // 12-version SaveMigrationChain + 100 single-character CRC32 tampering
        // probes!
        final chain = SaveMigrationChain(currentVersion: 12);
        for (var v = 1; v < 12; v++) {
          final stepNum = v;
          chain.addStep(
            stepNum,
            (d) => <String, Object?>{
              ...d,
              'hops': ((d['hops'] as int?) ?? 0) + stepNum,
            },
          );
        }
        final v1Raw =
            StateSnapshotStore(
              migrations: SaveMigrationChain(currentVersion: 1),
            ).encodeJsonEnvelope(const <String, Object?>{
              'hero': 'Arthas',
              'gold': 987654,
              'hops': 0,
            });

        final v12Store = StateSnapshotStore(migrations: chain);
        final migrated = v12Store.decodeJsonEnvelope(v1Raw);
        expect(migrated['hops'], 66); // 1 + 2 + ... + 11 = 66!

        // Flip 100 distinct positions inside the serialized JSON envelope:
        // EVERY SINGLE corruption must throw FormatException!
        for (var p = 0; p < 100; p++) {
          final idx = p % v1Raw.length;
          final orig = v1Raw.codeUnitAt(idx);
          final replacement = orig == 0x58 ? 'Y' : 'X';
          final prefix = v1Raw.substring(0, idx);
          final suffix = v1Raw.substring(idx + 1);
          final corrupted = '$prefix$replacement$suffix';
          expect(
            () => v12Store.decodeJsonEnvelope(corrupted),
            throwsFormatException,
            reason: 'Corrupted char at $idx must fail CRC32 / JSON check',
          );
        }
      },
    );
  });

  group('AudioMixer 200-voice flood, 16-deep BGM stack & 100k UI stress', () {
    test(
      'handles 200-voice AudioMixer saturation, 16-deep BgmTransportStack '
      'push/pop cursor conservation, 100,000-row CommandListWindow O(visible) '
      'virtualization, and 1,000-popup FloatingCombatTextPool ring wraparound',
      () {
        final backend = InMemoryAudioBackend();
        final mixer = AudioMixer(backend: backend);
        for (var i = 0; i < 200; i++) {
          mixer.playClip(
            'sfx_$i.wav',
            busId: i % 5 == 0 ? AudioBusId.voice : AudioBusId.sfx,
            volume: 0.7,
            durationSeconds: 0.05 + (i % 10) * 0.05,
          );
        }
        mixer.bus(AudioBusId.sfx).fadeTo(0.3, durationSeconds: 0.2);
        for (var step = 0; step < 15; step++) {
          mixer.update(0.05);
        }
        expect(mixer.activeVoices, isEmpty);

        // Push 16 nested BGM tracks (field -> dungeon -> sub-boss -> ...), each
        // advanced to a unique timestamp, plus a Musical Effect fanfare, then
        // pop all 16 and verify every single saved cursor restores bit-exact!
        final bgm = BgmTransportStack(mixer: mixer);
        final expectedCursors = <double>[];
        for (var d = 0; d < 16; d++) {
          final track = LoopRegionTrack(
            assetId: 'layer_$d.ogg',
            durationSeconds: 100.0,
            loopStartSeconds: 10.0,
            loopEndSeconds: 90.0,
          );
          if (d == 0) {
            bgm.playBgm(track);
          } else {
            bgm.pushBgm(track, fadeInSeconds: 0.0);
          }
          final advance = 12.25 + d * 3.5;
          bgm.update(advance);
          expectedCursors.add(advance);
        }
        bgm
          ..playMusicalEffect('fanfare.ogg', durationSeconds: 2.0)
          ..update(2.0);
        expect(bgm.isMusicalEffectPlaying, isFalse);

        for (var d = 15; d >= 1; d--) {
          expect(bgm.activeTrack?.assetId, 'layer_$d.ogg');
          expect(bgm.cursorSeconds, closeTo(expectedCursors[d], 1e-6));
          expect(bgm.popAndResumeBgm(), isTrue);
        }
        expect(bgm.activeTrack?.assetId, 'layer_0.ogg');
        expect(bgm.cursorSeconds, closeTo(expectedCursors[0], 1e-6));

        // 100,000-row virtualized CommandListWindow + 1,000-popup combat pool!
        final atlas = RasterFontAtlas.bake(
          style: const TextStyle(fontSize: 14),
        );
        addTearDown(atlas.dispose);

        final hugeMenu = CommandListWindow(
          fontAtlas: atlas,
          size: Vector2(280, 164),
          items: List<WindowCommandItem>.generate(
            100000,
            (i) => WindowCommandItem(
              id: 'entry_$i',
              label: 'Archive #$i',
              enabled: i % 3 != 1,
            ),
          ),
        );

        final rec = ui.PictureRecorder();
        final canvas = ui.Canvas(rec);
        for (final jump in <int>[0, 49999, 99999, 12345]) {
          hugeMenu
            ..selectIndex(jump)
            ..moveSelection(1, skipDisabled: true)
            ..render(canvas);
          expect(hugeMenu.renderedRowCountLastFrame, lessThanOrEqualTo(6));
        }

        final popupPool = FloatingCombatTextPool(
          fontAtlas: atlas,
          maxPopups: 64,
        );
        for (var h = 0; h < 1000; h++) {
          popupPool.spawn(
            text: '${h * 7}',
            worldX: 160.0 + (h % 5) * 4.0,
            worldY: 120.0,
            kind: CombatPopupKind.values[h % CombatPopupKind.values.length],
          );
          if (h % 100 == 99) {
            popupPool
              ..update(0.05)
              ..render(canvas);
          }
        }
        expect(popupPool.activeCount, 64);
        rec.endRecording().dispose();
      },
    );
  });
}
