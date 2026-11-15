import 'dart:ui' as ui;

import 'package:flame/audio.dart';
import 'package:flame/components.dart';
import 'package:flame/layout.dart';
import 'package:flame/math.dart';
import 'package:flame/rpg.dart';
import 'package:flame/text.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BgmTransportStack, RPG Windows, Popups, Loot & Quest DAG', () {
    test(
      'BgmTransportStack wraps [loopStart..loopEnd) without replaying intro, '
      'survives huge dt spikes, freezes for ME fanfares, and pops saved cursor',
      () {
        final seekEvents = <({String assetId, double cursor})>[];
        final mixer = AudioMixer();
        final bgm = BgmTransportStack(
          mixer: mixer,
          onSeekVoice: (assetId, _, targetCursor) {
            seekEvents.add((assetId: assetId, cursor: targetCursor));
          },
        );

        const overworldTrack = LoopRegionTrack(
          assetId: 'bgm_overworld.ogg',
          durationSeconds: 60.0,
          loopStartSeconds: 12.0,
          loopEndSeconds: 52.0, // 40s loop body
        );
        const battleTrack = LoopRegionTrack(
          assetId: 'bgm_battle.ogg',
          durationSeconds: 45.0,
          loopStartSeconds: 5.0,
          loopEndSeconds: 45.0,
        );

        bgm.playBgm(overworldTrack);
        expect(bgm.cursorSeconds, 0.0);

        // Advance past 12s intro into body (15s), then wrap once (+40s -> 15s).
        bgm.update(15.0);
        expect(bgm.cursorSeconds, closeTo(15.0, 1e-9));
        expect(bgm.loopWrapCount, 0);

        bgm.update(40.0);
        expect(bgm.cursorSeconds, closeTo(15.0, 1e-9)); // never back to 0.0!
        expect(bgm.loopWrapCount, 1);
        expect(seekEvents.last.cursor, closeTo(15.0, 1e-9));

        // Huge 418.5s lag spike wraps 10 full 40s cycles + 18.5s -> 33.5s!
        bgm.update(418.5);
        expect(bgm.cursorSeconds, closeTo(33.5, 1e-9));
        expect(bgm.loopWrapCount, 11);

        // Enter battle -> pushes Overworld @ 33.5s onto stack!
        bgm.pushBgm(battleTrack, fadeInSeconds: 0.0);
        expect(bgm.savedStackDepth, 1);
        expect(bgm.activeTrack?.assetId, 'bgm_battle.ogg');
        bgm.update(18.0);
        expect(bgm.cursorSeconds, closeTo(18.0, 1e-9));

        // Victory Musical Effect (bgmDuckGain: 0.0) freezes BGM cursor while
        // fanfare plays, then resumes with remaining dt!
        bgm.playMusicalEffect(
          'me_victory.ogg',
          durationSeconds: 4.0,
        );
        expect(bgm.isMusicalEffectPlaying, isTrue);
        expect(bgm.effectiveBgmVolume, closeTo(0.0, 1e-9));

        bgm.update(2.5); // still inside 4.0s fanfare
        expect(bgm.isMusicalEffectPlaying, isTrue);
        expect(bgm.cursorSeconds, closeTo(18.0, 1e-9));

        bgm.update(2.0); // 1.5s finishes fanfare, 0.5s advances battle BGM!
        expect(bgm.isMusicalEffectPlaying, isFalse);
        expect(bgm.cursorSeconds, closeTo(18.5, 1e-9));

        // Pop battle -> restores Overworld at exact saved 33.5s!
        seekEvents.clear();
        expect(bgm.popAndResumeBgm(), isTrue);
        expect(bgm.activeTrack?.assetId, 'bgm_overworld.ogg');
        expect(bgm.cursorSeconds, closeTo(33.5, 1e-9));
        expect(seekEvents.single.assetId, 'bgm_overworld.ogg');
        expect(seekEvents.single.cursor, closeTo(33.5, 1e-9));
      },
    );

    test(
      'CommandListWindow virtualizes 10,000 rows, skips disabled items, '
      'fires buzzer on disabled confirm, and PagedGridWindow navigates 2D',
      () {
        final atlas = RasterFontAtlas.bake(
          style: const TextStyle(fontSize: 14),
        );
        addTearDown(atlas.dispose);

        var buzzerCount = 0;
        String? confirmedId;

        final items = List<WindowCommandItem>.generate(
          10000,
          (i) => WindowCommandItem(
            id: 'cmd_$i',
            label: 'Skill #$i',
            rightBadge: '${i % 99} MP',
            enabled: i != 1, // item #1 is disabled
          ),
        );

        final cmdWin = CommandListWindow(
          items: items,
          fontAtlas: atlas,
          initialOpenness: 0.0,
          size: Vector2(260, 164), // inner height 140 -> 5 visible rows
          onConfirmed: (_, item) => confirmedId = item.id,
          onDisabledBuzzer: (_, _) => buzzerCount++,
        );

        expect(cmdWin.visibleRowCapacity, 5);
        expect(cmdWin.isFullyClosed, isTrue);
        cmdWin.open(durationSeconds: 0.2);
        cmdWin.update(0.1);
        expect(cmdWin.openness, closeTo(0.5, 1e-6));
        cmdWin.update(0.2);
        expect(cmdWin.isFullyOpen, isTrue);

        // Render onto a recording canvas: ONLY 5 of 10,000 rows are drawn!
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder);
        cmdWin.render(canvas);
        recorder.endRecording().dispose();
        expect(cmdWin.renderedRowCountLastFrame, 5);

        // Disabled item #1 triggers buzzer when selected directly, and is
        // hopped over when skipDisabled: true!
        cmdWin.selectIndex(1);
        expect(cmdWin.confirmSelection(), isFalse);
        expect(buzzerCount, 1);

        cmdWin
          ..selectIndex(0)
          ..moveSelection(1, skipDisabled: true);
        expect(cmdWin.selectedIndex, 2);
        expect(cmdWin.confirmSelection(), isTrue);
        expect(confirmedId, 'cmd_2');

        // Jump to row 9,999 -> scrolls cleanly to bottom, then wraps to 0!
        cmdWin.selectIndex(9999);
        expect(cmdWin.scrollTopIndex, 9995);
        expect(cmdWin.showScrollUpIndicator, isTrue);
        expect(cmdWin.showScrollDownIndicator, isFalse);
        cmdWin.moveSelection(1);
        expect(cmdWin.selectedIndex, 0);
        expect(cmdWin.scrollTopIndex, 0);

        // 2D PagedGridWindow navigation.
        final grid = PagedGridWindow(
          columns: 3,
          rowHeight: 28.0,
          fontAtlas: atlas,
          size: Vector2(300, 116),
          items: List<WindowCommandItem>.generate(
            8,
            (i) => WindowCommandItem(id: 'item_$i', label: 'Item $i'),
          ),
        );
        grid.moveCursor(2, 2); // col 2, row 2 -> idx 8 clamped to last item 7!
        expect(grid.selectedIndex, 7);
      },
    );

    test(
      'FloatingCombatTextPool staggers simultaneous multi-hit popups into '
      'distinct coordinates and flushes in 1 drawRawAtlas call',
      () {
        final atlas = RasterFontAtlas.bake(
          style: const TextStyle(fontSize: 16),
        );
        addTearDown(atlas.dispose);

        final pool = FloatingCombatTextPool(
          fontAtlas: atlas,
          maxPopups: 6,
        );

        final slots = <int>[
          for (var i = 0; i < 5; i++)
            pool.spawn(
              text: '${(i + 1) * 125}',
              worldX: 200.0,
              worldY: 160.0,
              kind: i == 4
                  ? CombatPopupKind.criticalDamage
                  : CombatPopupKind.damage,
            ),
        ];

        expect(pool.activeCount, 5);
        final coords = <({double x, double y})>{
          for (final s in slots)
            (x: pool.inspectSlot(s).x, y: pool.inspectSlot(s).y),
        };
        // All 5 simultaneous hits at (200, 160) staggered into 5 distinct
        // spots!
        expect(coords.length, 5);

        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder);
        pool.render(canvas);
        recorder.endRecording().dispose();
        expect(pool.lastFlushDrawCalls, 1);

        // Pool saturation steals oldest slot cleanly without exceeding
        // capacity.
        pool.update(0.2);
        pool.spawn(text: 'MISS', worldX: 50, worldY: 50);
        pool.spawn(text: '+99', worldX: 60, worldY: 50);
        expect(pool.activeCount, 6);

        // Expiry clears all slots.
        pool.update(2.0);
        expect(pool.activeCount, 0);
      },
    );

    test(
      'LootTable pity & unique filter, InventoryContainer limits, and '
      'EquipmentLoadout atomic two-handed swap rollback when bag is full',
      () {
        final pity = LootPityTracker();
        final subRelics = LootTable<String>(
          entries: <LootEntry<String>>[
            const LootEntry.item(
              item: 'sun_blade',
              weight: 10,
              uniqueKey: 'relic:sun_blade',
            ),
            const LootEntry.item(item: 'gold_pouch', weight: 10),
          ],
        );
        final chestTable = LootTable<String>(
          pityThreshold: 3,
          entries: <LootEntry<String>>[
            const LootEntry.item(item: 'herb', weight: 1000),
            const LootEntry.item(
              item: 'mythic_gem',
              weight: 0.0001,
              isRarePityTarget: true,
            ),
            LootEntry.subTable(subTable: subRelics, weight: 0),
          ],
        );

        final rng = SeededRng(12345);
        // Rolls 1 and 2 hit common herb; roll 3 hits pityThreshold == 3 -> gem!
        final r1 = chestTable.roll(rng, pityTracker: pity);
        final r2 = chestTable.roll(rng, pityTracker: pity);
        final r3 = chestTable.roll(rng, pityTracker: pity);
        expect(r1?.item, 'herb');
        expect(r2?.item, 'herb');
        expect(r3?.item, 'mythic_gem');
        expect(pity.rollsSinceRare, 0);

        // Unique key filter excludes already-owned 'relic:sun_blade'.
        final owned = <String>{'relic:sun_blade'};
        for (var i = 0; i < 10; i++) {
          expect(
            subRelics.roll(rng, excludedUniqueKeys: owned)?.item,
            'gold_pouch',
          );
        }

        // Inventory weight & slot limits + atomic 2H weapon swap rollback!
        const sword1H = InventoryItemDef(
          id: 'iron_sword',
          name: 'Iron Sword',
          maxStack: 1,
          unitWeight: 3.0,
          equipSlot: EquipSlot.mainHand,
          statModifiers: <StatModifier>[
            StatModifier(
              id: 'sw_atk',
              statId: 'atk',
              op: StatModifierOp.flatAdd,
              value: 15,
            ),
          ],
        );
        const shield = InventoryItemDef(
          id: 'oak_shield',
          name: 'Oak Shield',
          maxStack: 1,
          unitWeight: 4.0,
          equipSlot: EquipSlot.offHand,
          statModifiers: <StatModifier>[
            StatModifier(
              id: 'sh_def',
              statId: 'def',
              op: StatModifierOp.flatAdd,
              value: 20,
            ),
          ],
        );
        const greatsword2H = InventoryItemDef(
          id: 'titan_claymore',
          name: 'Titan Claymore',
          maxStack: 1,
          unitWeight: 5.0,
          equipSlot: EquipSlot.mainHand,
          twoHanded: true,
          statModifiers: <StatModifier>[
            StatModifier(
              id: 'gs_atk',
              statId: 'atk',
              op: StatModifierOp.flatAdd,
              value: 45,
            ),
          ],
        );
        const rock = InventoryItemDef(
          id: 'heavy_rock',
          name: 'Heavy Rock',
          unitWeight: 2.0,
        );

        final attrs = AttributeSet()
          ..setBase('atk', 10)
          ..setBase('def', 10);
        final loadout = EquipmentLoadout(attrs);
        // Bag has only 2 slots and 12.0 maxWeight.
        final bag = InventoryContainer(maxSlots: 2, maxWeight: 12.0);
        expect(bag.addItem(sword1H), 0);
        expect(bag.addItem(shield), 0);

        expect(loadout.equip(EquipSlot.mainHand, sword1H, bag: bag), isTrue);
        expect(loadout.equip(EquipSlot.offHand, shield, bag: bag), isTrue);
        expect(bag.usedSlots, 0);
        expect(attrs.get('atk'), closeTo(25.0, 1e-9));
        expect(attrs.get('def'), closeTo(30.0, 1e-9));

        // Side-effect-free stat preview of equipping 2H claymore: +30 atk,
        // -20 def (because offhand shield must come off!).
        final preview = loadout.previewEquipStatDiff(
          EquipSlot.mainHand,
          greatsword2H,
        );
        expect(preview['atk'], closeTo(30.0, 1e-9));
        expect(preview['def'], closeTo(-20.0, 1e-9));
        expect(attrs.get('atk'), closeTo(25.0, 1e-9)); // untouched!

        // Put claymore + 3 rocks (weight 5 + 6 = 11 / 12, occupying BOTH slots)
        // into the bag: swapping claymore removes claymore (freeing 1 slot &
        // 5 weight -> 1 free slot, 6 free weight), which CANNOT fit BOTH
        // displaced sword1H + shield (needs 2 slots and 7 weight) -> MUST
        // rollback atomically!
        expect(bag.addItem(greatsword2H), 0);
        expect(bag.addItem(rock, 3), 0);
        expect(bag.addItem(rock, 2), 2); // weight cap 12 rejects extra rocks

        expect(
          loadout.equip(EquipSlot.mainHand, greatsword2H, bag: bag),
          isFalse,
        );
        // Atomic rollback preserved sword + shield AND bag contents!
        expect(loadout.equippedIn(EquipSlot.mainHand)?.id, 'iron_sword');
        expect(loadout.equippedIn(EquipSlot.offHand)?.id, 'oak_shield');
        expect(bag.countOf('titan_claymore'), 1);
        expect(bag.countOf('heavy_rock'), 3);

        // Drop the rocks -> now bag has room & weight for both displaced items!
        expect(bag.removeItem('heavy_rock', 3), 3);
        expect(
          loadout.equip(EquipSlot.mainHand, greatsword2H, bag: bag),
          isTrue,
        );
        expect(loadout.isTwoHandedEquipped, isTrue);
        expect(loadout.equippedIn(EquipSlot.offHand), isNull);
        expect(bag.countOf('iron_sword'), 1);
        expect(bag.countOf('oak_shield'), 1);
        expect(attrs.get('atk'), closeTo(55.0, 1e-9));
        expect(attrs.get('def'), closeTo(10.0, 1e-9));
      },
    );

    test(
      'QuestJournalMachine enforces sequential gates, anyOf branching, '
      'failure recovery stages, WorldEventBus binding, and JSON roundtrip',
      () {
        final bus = WorldEventBus();
        final journal = QuestJournalMachine();
        final sub = journal.attachToEventBus(bus);
        addTearDown(sub.cancel);

        final quest = QuestDef(
          id: 'q_merchant_escort',
          title: 'The Moonlight Caravan',
          initialStageId: 'prep_seq',
          stages: const <QuestStageDef>[
            QuestStageDef(
              id: 'prep_seq',
              mode: ObjectiveGroupMode.sequential,
              nextStageId: 'wagon_escort',
              objectives: <QuestObjectiveDef>[
                QuestObjectiveDef(
                  id: 'buy_rations',
                  progressTag: 'item:rations',
                  targetCount: 2,
                ),
                QuestObjectiveDef(
                  id: 'talk_guard',
                  progressTag: 'npc:captain',
                ),
              ],
            ),
            QuestStageDef(
              id: 'wagon_escort',
              nextStageId: 'bandit_choice',
              failOnEventTag: 'wagon_destroyed',
              failBranchStageId: 'salvage_cargo',
              objectives: <QuestObjectiveDef>[
                QuestObjectiveDef(
                  id: 'reach_bridge',
                  progressTag: 'zone:bridge',
                ),
              ],
            ),
            QuestStageDef(
              id: 'salvage_cargo',
              nextStageId: 'bandit_choice',
              failOnEventTag: 'cargo_burned',
              objectives: <QuestObjectiveDef>[
                QuestObjectiveDef(
                  id: 'crates',
                  progressTag: 'pickup:crate',
                  targetCount: 3,
                ),
              ],
            ),
            QuestStageDef(
              id: 'bandit_choice',
              mode: ObjectiveGroupMode.anyOf,
              objectives: <QuestObjectiveDef>[
                QuestObjectiveDef(
                  id: 'bribe',
                  progressTag: 'choice:bribe',
                  nextStageOverride: 'peaceful_epilogue',
                ),
                QuestObjectiveDef(
                  id: 'duel',
                  progressTag: 'choice:duel',
                ),
              ],
            ),
            QuestStageDef(
              id: 'peaceful_epilogue',
              objectives: <QuestObjectiveDef>[
                QuestObjectiveDef(
                  id: 'report_guild',
                  progressTag: 'npc:guild_master',
                ),
              ],
            ),
          ],
        );

        journal.registerQuest(quest);
        expect(journal.startQuest('q_merchant_escort'), isTrue);

        // Sequential gate: talking to captain BEFORE buying 2 rations is
        // ignored!
        bus.emit(const QuestProgressEvent('npc:captain'));
        expect(journal.objectiveProgress('q_merchant_escort', 'talk_guard'), 0);

        bus
          ..emit(const QuestProgressEvent('item:rations', amount: 2))
          ..emit(const QuestProgressEvent('npc:captain'));
        expect(journal.currentStageOf('q_merchant_escort'), 'wagon_escort');

        // Wagon destroyed -> routes into 'salvage_cargo' recovery branch
        // instead
        // of failing the quest!
        bus
          ..emit(const QuestProgressEvent('wagon_destroyed'))
          ..emit(const QuestProgressEvent('pickup:crate', amount: 2));
        expect(journal.stateOf('q_merchant_escort'), QuestState.active);
        expect(journal.currentStageOf('q_merchant_escort'), 'salvage_cargo');

        // JSON snapshot mid-recovery stage & restore into fresh journal!
        final snap = journal.toJson();
        final restored = QuestJournalMachine()
          ..registerQuest(quest)
          ..restoreFromJson(snap);
        expect(restored.currentStageOf('q_merchant_escort'), 'salvage_cargo');
        expect(restored.objectiveProgress('q_merchant_escort', 'crates'), 2);

        // Finish 3rd crate -> enters 'bandit_choice', pick 'choice:bribe' ->
        // routes via nextStageOverride to 'peaceful_epilogue' -> complete!
        restored
          ..recordEvent('pickup:crate')
          ..recordEvent('choice:bribe');
        expect(
          restored.currentStageOf('q_merchant_escort'),
          'peaceful_epilogue',
        );
        restored.recordEvent('npc:guild_master');
        expect(restored.stateOf('q_merchant_escort'), QuestState.completed);
      },
    );
  });
}
