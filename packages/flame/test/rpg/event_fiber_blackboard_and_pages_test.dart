import 'package:flame/game.dart';
import 'package:flame/rpg.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WorldStateBlackboard bit-packed switches, deltas & snapshots', () {
    test(
      'packs high-index switches across 30-bit words, isolates self-switches, '
      'and roundtrips JSON',
      () {
        final bb = WorldStateBlackboard(initialSwitchCapacity: 16);
        var sw95Notifications = 0;
        var sw0Notifications = 0;
        bb.watchSwitch(95, () => sw95Notifications++);
        bb.watchSwitch(0, () => sw0Notifications++);

        // Flip switches across multiple 30-bit word boundaries (0, 29, 30, 60,
        // 95):
        for (final id in <int>[0, 29, 30, 60, 95]) {
          bb.setSwitch(id, value: true);
        }
        expect(sw95Notifications, 1);
        expect(sw0Notifications, 1);

        // Idempotent set does not re-fire watchers:
        bb.setSwitch(95, value: true);
        expect(sw95Notifications, 1);

        // Self-switches isolate cleanly across (mapId, eventId, channel):
        bb.setSelfSwitch('town', 'chest_1', 'A', value: true);
        expect(bb.getSelfSwitch('town', 'chest_1', 'A'), isTrue);
        expect(bb.getSelfSwitch('town', 'chest_2', 'A'), isFalse);
        expect(bb.getSelfSwitch('dungeon', 'chest_1', 'A'), isFalse);
        expect(bb.getSelfSwitch('town', 'chest_1', 'B'), isFalse);

        bb.setVariable(1, 42);
        bb.setVariable(2, 3.5);
        bb.setVariable(3, 'Aria');
        bb.upsertEntityDelta('town', 'boulder_1')
          ..col = 8
          ..row = 12
          ..erased = false
          ..extra['pushed'] = true;

        final snap = bb.toJson();
        final restored = WorldStateBlackboard()..loadFromJson(snap);

        for (final id in <int>[0, 29, 30, 60, 95]) {
          expect(restored.getSwitch(id), isTrue);
        }
        expect(restored.getSwitch(31), isFalse);
        expect(restored.getInt(1), 42);
        expect(restored.getDouble(2), closeTo(3.5, 1e-6));
        expect(restored.getString(3), 'Aria');
        expect(restored.getSelfSwitch('town', 'chest_1', 'A'), isTrue);
        expect(restored.getSelfSwitch('town', 'chest_2', 'A'), isFalse);

        final delta = restored.getEntityDelta('town', 'boulder_1')!;
        expect(delta.col, 8);
        expect(delta.row, 12);
        expect(delta.extra['pushed'], isTrue);

        restored.clearMapDeltas('town');
        expect(restored.getEntityDelta('town', 'boulder_1'), isNull);
      },
    );
  });

  group('EventScriptBuilder validation & EventFiber safety/serialization', () {
    test('rejects malformed branches and loops at compile time', () {
      final unclosedIf = EventScriptBuilder('bad_if')
        ..branchIf(
          EventPageCondition(requiredSwitches: const <int, bool>{1: true}),
        );
      expect(unclosedIf.build, throwsStateError);

      final unclosedLoop = EventScriptBuilder('bad_loop')..beginLoop();
      expect(unclosedLoop.build, throwsStateError);

      final orphanElse = EventScriptBuilder('orphan_else');
      expect(orphanElse.elseBranch, throwsStateError);

      final orphanBreak = EventScriptBuilder('orphan_break');
      expect(orphanBreak.breakLoop, throwsStateError);

      final emptyChoice = EventScriptBuilder('empty_choice');
      expect(
        () => emptyChoice.promptChoice(const <String>[]),
        throwsArgumentError,
      );
    });

    test(
      'halts runaway yield-free loops at maxInstructionsPerTick without '
      'freezing frame',
      () {
        final bb = WorldStateBlackboard();
        final infinite =
            (EventScriptBuilder('runaway')
                  ..beginLoop()
                  ..addVariable(1, 1)
                  ..endLoop())
                .build();

        final fiber = EventFiber(
          blackboard: bb,
          rootScript: infinite,
          maxInstructionsPerTick: 100,
        )..tick(0.016);

        expect(fiber.hitInstructionBudgetThisTick, isTrue);
        expect(fiber.isFinished, isFalse);
        // Loop body executes addVariable + jump (2 ops per iteration) -> 50
        // iterations:
        expect(bb.getInt(1), 50);

        // Next frame gets another bounded slice rather than deadlocking:
        fiber.tick(0.016);
        expect(fiber.hitInstructionBudgetThisTick, isTrue);
        expect(bb.getInt(1), 100);
      },
    );

    test(
      'guards against unbounded recursive CommonEvent call stacks',
      () {
        final bb = WorldStateBlackboard();
        final recurse = (EventScriptBuilder(
          'recurse',
        )..callCommonEvent('recurse')).build();
        final fiber = EventFiber(
          blackboard: bb,
          rootScript: recurse,
          commonEvents: <String, EventScript>{'recurse': recurse},
          maxCallStackDepth: 8,
        );
        expect(() => fiber.tick(0.016), throwsStateError);
      },
    );

    test(
      'saves and restores mid-fiber inside nested CommonEvent choice and '
      'resumes exact branch',
      () {
        final merchantCommon =
            (EventScriptBuilder('merchant_common')
                  ..showDialogue(
                    'Welcome! What would you like?',
                    speaker: 'Merchant',
                    portraitId: 'merchant_smile',
                  )
                  ..promptChoice(
                    const <String>['Buy', 'Sell Gem', 'Leave'],
                    storeInVariableId: 5,
                  )
                  ..branchIfChoiceEquals(1, choiceVariableId: 5)
                  ..addVariable(10, 250) // +250 gold
                  ..setSelfSwitch('A', value: true)
                  ..elseBranch()
                  ..addVariable(10, -10)
                  ..endBranch())
                .build();

        final rootCutscene =
            (EventScriptBuilder('cutscene_root')
                  ..setSwitch(3, value: true)
                  ..callCommonEvent('merchant_common')
                  ..awaitSignal('gate_unlocked')
                  ..waitSeconds(0.5)
                  ..addVariable(10, 50)
                  ..emitAction('quest_toast', const <String, Object?>{
                    'id': 'sold_gem',
                  }))
                .build();

        final bb1 = WorldStateBlackboard();
        final fiber1 = EventFiber(
          blackboard: bb1,
          rootScript: rootCutscene,
          mapId: 'market',
          eventId: 'npc_merchant',
          commonEvents: <String, EventScript>{
            'merchant_common': merchantCommon,
          },
        )..tick(0.016);

        // Suspended on showDialogue inside merchant_common (callStackDepth ==
        // 2):
        expect(fiber1.waitKind, EventFiberWaitKind.dialogue);
        expect(fiber1.callStackDepth, 2);
        expect(fiber1.pendingDialogue?.speaker, 'Merchant');

        fiber1
          ..completeDialogue()
          ..tick(0.016);
        expect(fiber1.waitKind, EventFiberWaitKind.choice);
        expect(fiber1.pendingChoices, const <String>[
          'Buy',
          'Sell Gem',
          'Leave',
        ]);

        // Snapshot BOTH blackboard and mid-cutscene fiber right at the choice
        // prompt!
        final savedBb = bb1.toJson();
        final savedFiber = fiber1.saveState();

        // Restore into completely fresh instances (simulating cold app
        // restart):
        final emittedActions = <String>[];
        final bb2 = WorldStateBlackboard()..loadFromJson(savedBb);
        final fiber2 = EventFiber(
          blackboard: bb2,
          rootScript: rootCutscene,
          mapId: 'market',
          eventId: 'npc_merchant',
          commonEvents: <String, EventScript>{
            'merchant_common': merchantCommon,
          },
          onEmitAction: (name, _) => emittedActions.add(name),
        )..restoreState(savedFiber, rootScript: rootCutscene);

        expect(fiber2.waitKind, EventFiberWaitKind.choice);
        expect(fiber2.callStackDepth, 2);

        // Select option 1 ('Sell Gem'):
        fiber2
          ..submitChoice(1)
          ..tick(0.016);

        // CommonEvent finished its branch (+250 gold, SelfSwitch A = true) and
        // returned to rootCutscene, which is now waiting on 'gate_unlocked':
        expect(bb2.getInt(10), 250);
        expect(bb2.getSelfSwitch('market', 'npc_merchant', 'A'), isTrue);
        expect(fiber2.waitKind, EventFiberWaitKind.signal);
        expect(fiber2.awaitedSignalId, 'gate_unlocked');

        fiber2
          ..resolveSignal('gate_unlocked')
          ..tick(0.016);
        expect(fiber2.waitKind, EventFiberWaitKind.timer);

        // Advance timer past 0.5s:
        fiber2.tick(0.6);
        expect(fiber2.isFinished, isTrue);
        expect(bb2.getInt(10), 300);
        expect(emittedActions, const <String>['quest_toast']);
      },
    );
  });

  group('EventPageComponent reactive O(affected) pages & autorun lock', () {
    test(
      'selects highest-index page without polling on unrelated switches and '
      'manages autorun lock',
      () async {
        final game = FlameGame()..onGameResize(Vector2(640, 480));
        await game.onLoad();
        game.mount();
        await game.ready();

        final bb = WorldStateBlackboard();
        final lockHistory = <bool>[];

        final page0Autorun = EventPage(
          condition: EventPageCondition(
            requiredSwitches: const <int, bool>{10: true},
          ),
          trigger: EventTriggerMode.autorun,
          graphicId: 'boss_intro',
          script:
              (EventScriptBuilder('intro')
                    ..waitSeconds(0.2)
                    ..setSelfSwitch('A', value: true))
                  .build(),
        );

        final page1AfterIntro = EventPage(
          condition: EventPageCondition(
            requiredSwitches: const <int, bool>{10: true},
            requiredSelfSwitches: const <String, bool>{'A': true},
          ),
          trigger: EventTriggerMode.actionButton,
          graphicId: 'boss_idle',
          script: (EventScriptBuilder('talk')..addVariable(99, 1)).build(),
        );

        final page2Defeated = EventPage(
          condition: EventPageCondition(
            requiredSwitches: const <int, bool>{20: true},
          ),
          trigger: EventTriggerMode.parallel,
          graphicId: 'boss_spirit',
          script:
              (EventScriptBuilder('aura')
                    ..addVariable(50, 1)
                    ..yieldTick())
                  .build(),
        );

        final npc = EventPageComponent(
          mapId: 'throne',
          eventId: 'boss',
          blackboard: bb,
          pages: <EventPage>[page0Autorun, page1AfterIntro, page2Defeated],
          onAutorunLockChanged: ({required locked}) => lockHistory.add(locked),
        );

        game.world.add(npc);
        await game.ready();
        game.update(0.0);

        // Initially no page matches (all switches false), evaluated exactly
        // once on mount:
        expect(npc.activePageIndex, isNull);
        final evalBaseline = npc.pageEvaluationCount;
        expect(evalBaseline, 1);

        // Mutate 50 UNRELATED switches & variables -> 0 page re-evaluations!
        for (var s = 100; s < 150; s++) {
          bb.setSwitch(s, value: true);
        }
        bb.setVariable(77, 999);
        game.update(0.016);
        expect(npc.pageEvaluationCount, evalBaseline);

        // Turn on Switch 10 -> activates Page 0 (autorun) and locks input on
        // next update:
        bb.setSwitch(10, value: true);
        expect(npc.activePageIndex, 0);
        game.update(0.05);
        expect(npc.isAutorunLockingInput, isTrue);
        expect(lockHistory, const <bool>[true]);

        // Advance past 0.2s -> autorun sets SelfSwitch 'A', which promotes Page
        // 1
        // (highest matching index) and automatically releases the autorun lock!
        game.update(0.25);
        expect(npc.activePageIndex, 1);
        expect(npc.activePage?.graphicId, 'boss_idle');
        expect(npc.isAutorunLockingInput, isFalse);
        expect(lockHistory, const <bool>[true, false]);

        // Interactive actionButton trigger works on Page 1:
        expect(npc.triggerInteraction(EventTriggerMode.actionButton), isTrue);
        game.update(0.016);
        expect(bb.getInt(99), 1);

        // Turn on Switch 20 -> highest-index Page 2 (parallel) overrides Page
        // 1:
        bb.setSwitch(20, value: true);
        expect(npc.activePageIndex, 2);
        game.update(0.016);
        game.update(0.016);
        expect(bb.getInt(50), greaterThanOrEqualTo(2));
      },
    );
  });
}
