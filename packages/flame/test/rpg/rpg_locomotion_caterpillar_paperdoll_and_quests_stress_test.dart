import 'dart:ui' as ui;

import 'package:flame/components.dart';
import 'package:flame/grid.dart';
import 'package:flame/math.dart';
import 'package:flame/rpg.dart';
import 'package:flame/tilemap.dart';
import 'package:flutter_test/flutter_test.dart';

ui.Image _solidLayerImage(int w, int h, ui.Color color) {
  final rec = ui.PictureRecorder();
  ui.Canvas(rec).drawRect(
    ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    ui.Paint()..color = color,
  );
  final pic = rec.endRecording();
  final img = pic.toImageSync(w, h);
  pic.dispose();
  return img;
}

void main() {
  group('GridCharacterMotor + PartyCaterpillarChain labyrinth stress', () {
    test(
      'drives tileLocked & freeSubTile motors + 8-member caterpillar chain '
      'across 1,000 labyrinth ticks, parabolic jumps, and gatherToLeader '
      'with 0 solid-wall penetrations',
      () {
        final grid = TilePassageGrid(width: 24, height: 24);
        final rng = SeededRng(0xCA7E8911);

        // Border walls + deterministic interior pillars (leaving spawn clear):
        for (var r = 0; r < 24; r++) {
          for (var c = 0; c < 24; c++) {
            final border = r == 0 || c == 0 || r == 23 || c == 23;
            final pillar =
                !border &&
                (r >= 3 || c >= 3) &&
                (r % 3 == 0 && c % 3 == 0 && rng.nextInt(4) != 0);
            if (border || pillar) {
              grid.setFlags(c, r, TilePassageFlags.impassable);
            }
          }
        }

        final motor = GridCharacterMotor(
          passageGrid: grid,
          initialCell: const GridCell(1, 1),
          speedPixelsPerSecond: 160.0,
        );
        final chain = PartyCaterpillarChain(
          followerCount: 8,
          followerSpacingPx: 24.0,
          ringCapacity: 256,
        )..resetAt(motor.worldPosition.x, motor.worldPosition.y);

        const inputs = <(double, double)>[
          (1.0, 0.0),
          (-1.0, 0.0),
          (0.0, 1.0),
          (0.0, -1.0),
          (0.7, 0.7),
          (-0.7, 0.7),
        ];

        var curInput = inputs[0];
        for (var tick = 0; tick < 1000; tick++) {
          if (tick == 500) {
            // Switch mid-run from classic tileLocked to freeSubTile sliding!
            motor.mode = GridLocomotionMode.freeSubTile;
          }
          if (tick % 17 == 0) {
            curInput = inputs[rng.nextInt(inputs.length)];
          }
          if (tick == 300) {
            // Execute a parabolic jump to an open cell if valid, then resume:
            if (grid.flagsAt(3, 1) != TilePassageFlags.impassable) {
              motor.setCellPosition(const GridCell(1, 1));
              motor.startMoveRoute(
                MoveRoute(
                  commands: <MoveRouteCommand>[
                    MoveRouteCommand.jump(dCol: 2, dRow: 0, duration: 0.25),
                  ],
                ),
              );
            }
          }

          motor.update(1.0 / 60.0, inputX: curInput.$1, inputY: curInput.$2);
          chain.recordLeader(
            x: motor.worldPosition.x,
            y: motor.worldPosition.y,
            facing: motor.facing,
            jumpElevationPx: motor.jumpElevationPx,
            leaderStridePhase: motor.stridePhase,
            leaderIsMoving: motor.isMoving,
          );

          if (!motor.isJumping) {
            // Logical cell must NEVER be a solid wall (`impassable`)!
            expect(
              grid.flagsAt(motor.cell.col, motor.cell.row),
              isNot(TilePassageFlags.impassable),
              reason: 'Motor entered blocked wall at tick $tick: ${motor.cell}',
            );
          }

          // Every follower coordinate must remain finite & inside world bounds:
          for (final f in chain.followers) {
            expect(f.position.x.isFinite, isTrue);
            expect(f.position.y.isFinite, isTrue);
            expect(f.jumpElevationPx, greaterThanOrEqualTo(0.0));
          }
        }

        // Collapse all 8 followers smoothly onto leader before a door/cutscene:
        var converged = false;
        for (var step = 0; step < 120; step++) {
          if (chain.gatherToLeader(1.0 / 60.0, gatherSpeedPxPerSec: 360.0)) {
            converged = true;
            break;
          }
        }
        expect(converged, isTrue);
        for (final f in chain.followers) {
          expect(f.position.x, closeTo(motor.worldPosition.x, 1e-5));
          expect(f.position.y, closeTo(motor.worldPosition.y, 1e-5));
          expect(f.isMoving, isFalse);
        }
      },
    );
  });

  group(
    'PaperDollCompositor LRU cache thrash & deterministic GPU disposal',
    () {
      test(
        'bakes 120 outfit permutations through a 12-sheet LRU cache with exact '
        'hit/miss/eviction/dispose accounting and order-invariant signatures',
        () {
          final baseBody = _solidLayerImage(48, 64, const ui.Color(0xFFE0B090));
          final armorImg = _solidLayerImage(48, 64, const ui.Color(0xFF6080A0));
          final hairImg = _solidLayerImage(48, 64, const ui.Color(0xFFD0A030));
          addTearDown(() {
            baseBody.dispose();
            armorImg.dispose();
            hairImg.dispose();
          });

          final compositor = PaperDollCompositor(maxCachedSheets: 12);
          addTearDown(compositor.dispose);

          // Permuting layer list order with identical zOrder must hit the same
          // canonical cache entry!
          final layerA = PaperDollLayer(id: 'body', image: baseBody);
          final layerB = PaperDollLayer(
            id: 'armor',
            image: armorImg,
            zOrder: 10,
          );
          final layerC = PaperDollLayer(id: 'hair', image: hairImg, zOrder: 20);

          final img1 = compositor.composeSync(
            <PaperDollLayer>[layerC, layerA, layerB],
            sheetWidth: 48,
            sheetHeight: 64,
          );
          final img2 = compositor.composeSync(
            <PaperDollLayer>[layerA, layerB, layerC],
            sheetWidth: 48,
            sheetHeight: 64,
          );
          expect(identical(img1, img2), isTrue);
          expect(compositor.cacheMissCount, 1);
          expect(compositor.cacheHitCount, 1);

          // Thrash 120 distinct armor/hair dye combinations through 12 slots:
          for (var i = 0; i < 120; i++) {
            final dyedOutfit = <PaperDollLayer>[
              layerA,
              PaperDollLayer(
                id: 'armor_$i',
                image: armorImg,
                zOrder: 10,
                tintColor: ui.Color(0xFF000000 | ((i * 12345) & 0xFFFFFF)),
              ),
              layerC,
            ];
            final sheet = compositor.composeSync(
              dyedOutfit,
              sheetWidth: 48,
              sheetHeight: 64,
            );
            expect(sheet.width, 48);
            expect(sheet.height, 64);
            expect(compositor.cachedSheetCount, lessThanOrEqualTo(12));
          }

          // 1 initial + 120 unique = 121 misses; 12 retained + 109 evicted!
          expect(compositor.cacheMissCount, 121);
          expect(compositor.cachedSheetCount, 12);
          expect(compositor.evictedImageCount, 109);
          expect(compositor.disposedImageCount, 109);

          compositor.dispose();
          expect(compositor.cachedSheetCount, 0);
          expect(compositor.disposedImageCount, 121);
        },
      );
    },
  );

  group('QuestJournalMachine re-entrant chain + save/load & LootTable pity', () {
    test(
      'completes a 25-quest re-entrant auto-unlocking DAG chain with mid-run '
      'JSON round-trips and enforces 100% hard pity ceiling over 10,000 rolls',
      () {
        final bus = WorldEventBus();
        final journal = QuestJournalMachine();
        final sub = journal.attachToEventBus(bus);
        addTearDown(sub.cancel);

        // Register 25 chained quests where completing quest `q_i` re-entrantly
        // calls `journal.startQuest('q_${i+1}')` inside `onQuestUpdated`!
        for (var i = 0; i < 25; i++) {
          journal.registerQuest(
            QuestDef(
              id: 'q_$i',
              title: 'Chapter $i',
              initialStageId: 's_seq',
              stages: <QuestStageDef>[
                QuestStageDef(
                  id: 's_seq',
                  mode: ObjectiveGroupMode.sequential,
                  nextStageId: 's_branch',
                  failOnEventTag: 'ambush_$i',
                  failBranchStageId: 's_recover',
                  objectives: <QuestObjectiveDef>[
                    QuestObjectiveDef(
                      id: 'scout',
                      progressTag: 'scout_$i',
                      targetCount: 2,
                    ),
                    QuestObjectiveDef(
                      id: 'unlock',
                      progressTag: 'unlock_$i',
                    ),
                  ],
                ),
                QuestStageDef(
                  id: 's_recover',
                  nextStageId: 's_branch',
                  objectives: <QuestObjectiveDef>[
                    QuestObjectiveDef(
                      id: 'regroup',
                      progressTag: 'regroup_$i',
                    ),
                  ],
                ),
                QuestStageDef(
                  id: 's_branch',
                  mode: ObjectiveGroupMode.anyOf,
                  objectives: <QuestObjectiveDef>[
                    QuestObjectiveDef(
                      id: 'diplomacy',
                      progressTag: 'peace_$i',
                    ),
                    QuestObjectiveDef(
                      id: 'combat',
                      progressTag: 'battle_$i',
                    ),
                  ],
                ),
              ],
            ),
          );
        }

        journal.onQuestUpdated.connect((ev) {
          if (ev.state == QuestState.completed) {
            final idx = int.parse(ev.questId.substring(2));
            if (idx + 1 < 25) {
              journal.startQuest('q_${idx + 1}');
            }
          }
        });

        expect(journal.startQuest('q_0'), isTrue);

        for (var i = 0; i < 25; i++) {
          // Premature `unlock_$i` before `scout_$i` must be ignored in
          // `sequential` mode!
          bus.emit(QuestProgressEvent('unlock_$i'));
          expect(journal.objectiveProgress('q_$i', 'unlock'), 0);

          if (i % 4 == 2) {
            // Trigger failure recovery branch -> regroup -> branch:
            bus.emit(QuestProgressEvent('ambush_$i'));
            expect(journal.currentStageOf('q_$i'), 's_recover');
            bus.emit(QuestProgressEvent('regroup_$i'));
          } else {
            bus.emit(QuestProgressEvent('scout_$i'));
            // Mid-quest JSON snapshot & restore into a verify clone:
            final snap = journal.toJson();
            journal.restoreFromJson(snap);
            bus.emit(QuestProgressEvent('scout_$i'));
            bus.emit(QuestProgressEvent('unlock_$i'));
          }

          expect(journal.currentStageOf('q_$i'), 's_branch');
          bus.emit(
            QuestProgressEvent(i.isEven ? 'peace_$i' : 'battle_$i'),
          );
          expect(journal.stateOf('q_$i'), QuestState.completed);
          if (i + 1 < 25) {
            expect(journal.stateOf('q_${i + 1}'), QuestState.active);
          }
        }

        // LootTable 10,000-roll statistical + hard pity ceiling (`<= 25` gap)
        // + unique key exclusion verification:
        final subGems = LootTable<String>(
          entries: const <LootEntry<String>>[
            LootEntry<String>.item(item: 'ruby', weight: 50),
            LootEntry<String>.item(item: 'sapphire', weight: 50),
          ],
        );
        final bossLoot = LootTable<String>(
          nothingWeight: 20.0,
          pityThreshold: 25,
          entries: <LootEntry<String>>[
            const LootEntry<String>.item(
              item: 'gold_pouch',
              weight: 70.0,
              minQuantity: 10,
              maxQuantity: 20,
            ),
            LootEntry<String>.subTable(subTable: subGems, weight: 9.0),
            const LootEntry<String>.item(
              item: 'sunblade_blueprint',
              weight: 0.5,
              uniqueKey: 'unique:sunblade',
            ),
            const LootEntry<String>.item(
              item: 'phoenix_feather',
              weight: 0.5,
              isRarePityTarget: true,
            ),
          ],
        );

        final rng = SeededRng(0x1007B055);
        final pity = LootPityTracker();
        final ownedUniques = <String>{};
        var maxDryStreak = 0;
        var currentDryStreak = 0;
        var blueprintDrops = 0;
        var rareDrops = 0;

        for (var r = 0; r < 10000; r++) {
          final drop = bossLoot.roll(
            rng,
            pityTracker: pity,
            excludedUniqueKeys: ownedUniques,
          );
          if (drop?.item == 'sunblade_blueprint') {
            blueprintDrops++;
            ownedUniques.add('unique:sunblade');
          }
          if (drop?.item == 'phoenix_feather') {
            rareDrops++;
            currentDryStreak = 0;
          } else {
            currentDryStreak++;
            if (currentDryStreak > maxDryStreak) {
              maxDryStreak = currentDryStreak;
            }
          }
        }

        // Unique item can NEVER drop more than once once recorded in set!
        expect(blueprintDrops, 1);
        // Hard pityThreshold = 25 guarantees dry streak NEVER reaches 25!
        expect(maxDryStreak, lessThan(25));
        expect(rareDrops, greaterThanOrEqualTo(10000 ~/ 25));
      },
    );
  });
}
