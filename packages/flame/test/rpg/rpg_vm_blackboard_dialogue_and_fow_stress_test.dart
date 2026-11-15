import 'dart:ui' as ui;

import 'package:flame/components.dart';
import 'package:flame/math.dart';
import 'package:flame/navigation.dart';
import 'package:flame/rpg.dart';
import 'package:flame/text.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WorldStateBlackboard & EventFiber re-entrancy & save/load stress', () {
    test(
      'handles 10,000 switches across 30-bit word seams and re-entrant '
      'watcher mutations/cancellations without ConcurrentModificationError',
      () {
        final bb = WorldStateBlackboard(initialSwitchCapacity: 4);

        // Flip every 7th switch up to index 9,999 and verify exact bit state!
        for (var i = 0; i < 10000; i++) {
          bb.setSwitch(i, value: i % 7 == 0);
        }
        for (var i = 0; i < 10000; i++) {
          expect(bb.getSwitch(i), i % 7 == 0);
        }

        // Snapshot & restore all 10,000 switches cleanly!
        final restored = WorldStateBlackboard()..loadFromJson(bb.toJson());
        for (final seam in <int>[0, 29, 30, 31, 59, 60, 899, 900, 9996, 9999]) {
          expect(restored.getSwitch(seam), seam % 7 == 0);
        }

        // Re-entrant watcher torture: watcher A unregisters watcher B,
        // registers watcher C, and mutates switch 501 from inside switch 500's
        // callback!
        final events = <String>[];
        void listenerB() => events.add('B');
        bb
          ..watchSwitch(500, () {
            events.add('A');
            bb
              ..unwatchSwitch(500, listenerB)
              ..watchSwitch(500, () => events.add('C_late'))
              ..setSwitch(501, value: true);
          })
          ..watchSwitch(500, listenerB)
          ..watchSwitch(501, () => events.add('501_changed'))
          ..setSwitch(500, value: true);

        expect(events, contains('A'));
        expect(events, contains('501_changed'));
        expect(events, isNot(contains('C_late')));

        // Next toggle on 500 triggers newly registered C_late, and never B!
        events.clear();
        bb.setSwitch(500, value: false);
        expect(events, contains('C_late'));
        expect(events, isNot(contains('B')));
      },
    );

    test(
      'proves tick-by-tick mid-cutscene saveState/restoreState across 28 '
      'nested CommonEvent frames matches uninterrupted execution, and 32+ '
      'infinite recursion triggers clean call-stack overflow guard',
      () {
        // Build a 27-level recursive chain of CommonEvents (`ce_0` -> `ce_26`)
        // on top of `root_chain` (total stack depth = 28 <= 32 max!), each
        // incrementing a variable, yielding/waiting, and unwinding cleanly!
        final commons = <String, EventScript>{};
        for (var depth = 26; depth >= 0; depth--) {
          final b = EventScriptBuilder('ce_$depth')
            ..addVariable(1, depth + 1)
            ..yieldTick();
          if (depth < 26) {
            b.callCommonEvent('ce_${depth + 1}');
          } else {
            b.waitSeconds(0.05);
          }
          b.addVariable(2, (depth + 1) * 3);
          commons['ce_$depth'] = b.build();
        }
        commons['self_recurse'] = (EventScriptBuilder(
          'self_recurse',
        )..callCommonEvent('self_recurse')).build();

        final root =
            (EventScriptBuilder('root_chain')
                  ..setVariable(1, 0)
                  ..setVariable(2, 0)
                  ..callCommonEvent('ce_0')
                  ..setSwitch(42, value: true))
                .build();

        // Run A: uninterrupted reference execution.
        final bbRef = WorldStateBlackboard();
        final fiberRef = EventFiber(
          blackboard: bbRef,
          rootScript: root,
          commonEvents: commons,
        );
        var ticksRef = 0;
        while (!fiberRef.isFinished && ticksRef < 500) {
          fiberRef.tick(0.02);
          ticksRef++;
        }
        expect(fiberRef.isFinished, isTrue);

        // Run B: serialize & cold-restore BOTH blackboard and fiber after EVERY
        // SINGLE TICK!
        var bbLive = WorldStateBlackboard();
        var fiberLive = EventFiber(
          blackboard: bbLive,
          rootScript: root,
          commonEvents: commons,
        );
        var ticksLive = 0;
        while (!fiberLive.isFinished && ticksLive < 500) {
          fiberLive.tick(0.02);
          ticksLive++;
          if (!fiberLive.isFinished) {
            final bbJson = bbLive.toJson();
            final fiberSnap = fiberLive.saveState();
            bbLive = WorldStateBlackboard()..loadFromJson(bbJson);
            fiberLive = EventFiber(
              blackboard: bbLive,
              rootScript: root,
              commonEvents: commons,
            )..restoreState(fiberSnap, rootScript: root);
          }
        }

        expect(fiberLive.isFinished, isTrue);
        expect(ticksLive, ticksRef);
        expect(bbLive.getInt(1), bbRef.getInt(1));
        expect(bbLive.getInt(2), bbRef.getInt(2));
        expect(bbLive.getSwitch(42), isTrue);

        // Verify infinite CommonEvent recursion hits deterministic StateError!
        final runaway = EventFiber(
          blackboard: WorldStateBlackboard(),
          rootScript: commons['self_recurse']!,
          commonEvents: commons,
        );
        expect(() => runaway.tick(0.016), throwsStateError);
      },
    );
  });

  group('DialogueBoxComponent markup & ShadowcastFogOfWar fuzz', () {
    test(
      'DialogueBoxComponent survives malformed/nested tags, ultra-long '
      'unbroken CJK/Cyrillic tokens, tiny viewports, and rapid skip spam',
      () {
        final atlas = DynamicFontAtlas(
          style: const TextStyle(fontSize: 14),
          pageSizePx: 128,
        );
        addTearDown(atlas.dispose);

        final box = DialogueBoxComponent(
          atlas: atlas,
          size: Vector2(96, 72), // intentionally narrow box!
        );

        final adversarialInputs = <String>[
          '',
          '[page][page][page]',
          '[color:#ZZZZZZ]Unclosed color [shake][wave]nested [wait:-99]',
          '[speed:0.0]ZeroSpeed[speed:999999]Fast[/instant][/color][/wave]',
          'СверхдлинноеНепрерывноеКириллическоеСловоБезЕдиногоПробелаДляТеста',
          '龍神の剣を喰らえ超絶必殺技連撃奥義無双乱舞漢字連続文字列検証テスト完了！',
          '{missing_var} [portrait:broken] [sfx:] [shakeCam:not_a_number] End!',
        ];

        final rec = ui.PictureRecorder();
        final canvas = ui.Canvas(rec);

        for (final text in adversarialInputs) {
          box.showPassage(
            text,
            choices: const <DialogueChoiceOption>[
              DialogueChoiceOption(id: 'ok', label: 'Continue'),
            ],
          );
          for (var step = 0; step < 30; step++) {
            box
              ..update(0.05)
              ..render(canvas)
              ..advanceOrSkip();
          }
          if (box.state == DialogueBoxState.awaitingChoice) {
            box.confirmChoice();
          }
          expect(box.state, DialogueBoxState.finished);
        }
        rec.endRecording().dispose();
      },
    );

    test(
      'ShadowcastFogOfWar holds 100% floor-to-floor LOS symmetry and shroud '
      'monotonicity across 20 random 24x24 cave dungeons',
      () {
        final rng = SeededRng(0xF060F060);

        for (var mapIdx = 0; mapIdx < 20; mapIdx++) {
          const w = 24;
          const h = 24;
          final fog = ShadowcastFogOfWar(width: w, height: h);
          final floors = <(int, int)>[];

          for (var r = 0; r < h; r++) {
            for (var c = 0; c < w; c++) {
              final border = c == 0 || r == 0 || c == w - 1 || r == h - 1;
              final wall = border || rng.nextDouble() < 0.28;
              fog.setOpaque(c, r, opaque: wall);
              if (!wall) {
                floors.add((c, r));
              }
            }
          }

          // Sample 300 random floor pairs per map for exact LOS symmetry!
          for (var p = 0; p < 300 && floors.length >= 2; p++) {
            final (ax, ay) = floors[rng.nextInt(floors.length)];
            final (bx, by) = floors[rng.nextInt(floors.length)];
            final r = 3.0 + rng.nextInt(6);
            expect(
              fog.hasLineOfSight(ax, ay, bx, by, radius: r),
              fog.hasLineOfSight(bx, by, ax, ay, radius: r),
              reason: 'Dungeon $mapIdx asymmetric ($ax,$ay)<->($bx,$by) r=$r',
            );
          }

          // Walk 30 random steps: explored count (visible + shroud) MUST be
          // monotonically non-decreasing, and origin is always visible!
          var prevExploredOrVisible = 0;
          for (var step = 0; step < 30 && floors.isNotEmpty; step++) {
            final (vx, vy) = floors[rng.nextInt(floors.length)];
            fog
              ..clearVisibleToShroud()
              ..revealFrom(vx, vy, radius: 5.5);
            expect(fog.stateAt(vx, vy), FogCellState.visible);

            var count = 0;
            for (var r = 0; r < h; r++) {
              for (var c = 0; c < w; c++) {
                if (fog.stateAt(c, r) != FogCellState.unexplored) {
                  count++;
                }
              }
            }
            expect(count, greaterThanOrEqualTo(prevExploredOrVisible));
            prevExploredOrVisible = count;
          }
        }
      },
    );
  });
}
