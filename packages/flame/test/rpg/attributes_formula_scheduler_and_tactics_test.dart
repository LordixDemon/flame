import 'package:flame/math.dart';
import 'package:flame/navigation.dart';
import 'package:flame/rpg.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AttributeSet, StatusEffectContainer, and FormulaVM', () {
    test(
      'AttributeSet applies GAS modifier stages in order, honors override '
      'priority and bounds, and caches clean reads',
      () {
        final attrs = AttributeSet()
          ..setCurve(
            'atk',
            StatCurve.polynomial(
              level1Value: 10,
              maxLevelValue: 110,
              maxLevel: 11,
              exponent: 2.0,
            ),
          )
          ..setCurve('crit', StatCurve.table(const <double>[5, 10, 20]))
          ..setBounds('atk', min: 1, max: 500)
          ..setLevel(6);

        // At level 6 of 1..11: t = (6-1)/(11-1) = 0.5 -> 10 + 100 * 0.25 = 35.
        expect(attrs.getBase('atk'), closeTo(35.0, 1e-9));
        expect(attrs.get('crit'), closeTo(20.0, 1e-9)); // clamped to table end

        attrs
          ..addModifier(
            const StatModifier(
              id: 'ring_flat',
              statId: 'atk',
              op: StatModifierOp.flatAdd,
              value: 15, // 35 + 15 = 50
              sourceId: 'gear:ring',
            ),
          )
          ..addModifier(
            const StatModifier(
              id: 'aura_pct_a',
              statId: 'atk',
              op: StatModifierOp.percentAdd,
              value: 0.20,
              sourceId: 'buff:aura',
            ),
          )
          ..addModifier(
            const StatModifier(
              id: 'aura_pct_b',
              statId: 'atk',
              op: StatModifierOp.percentAdd,
              value: 0.30, // 50 * (1 + 0.50) = 75
              sourceId: 'buff:aura',
            ),
          )
          ..addModifier(
            const StatModifier(
              id: 'berserk_mul',
              statId: 'atk',
              op: StatModifierOp.percentMul,
              value: 2.0, // 75 * 2.0 = 150
              sourceId: 'state:berserk',
            ),
          );

        attrs.resetDiagnostics();
        for (var i = 0; i < 50; i++) {
          expect(attrs.get('atk'), closeTo(150.0, 1e-9));
        }
        // 50 consecutive reads only recomputed once!
        expect(attrs.recalculationCount, 1);

        // Final overrides compete by priority, then clamp to [min, max].
        attrs
          ..addModifier(
            const StatModifier(
              id: 'hex_weak',
              statId: 'atk',
              op: StatModifierOp.finalOverride,
              value: 12.0,
              priority: 5,
            ),
          )
          ..addModifier(
            const StatModifier(
              id: 'god_mode',
              statId: 'atk',
              op: StatModifierOp.finalOverride,
              value: 9999.0,
              priority: 10,
            ),
          );
        expect(attrs.get('atk'), closeTo(500.0, 1e-9)); // clamped to max 500

        attrs.removeModifierById('god_mode');
        expect(attrs.get('atk'), closeTo(12.0, 1e-9));

        attrs
          ..removeModifierById('hex_weak')
          ..removeModifiersBySource('buff:aura');
        // Without percentAdd: (35 + 15) * 2.0 = 100.
        expect(attrs.get('atk'), closeTo(100.0, 1e-9));
      },
    );

    test(
      'StatusEffectContainer handles all 4 stack policies, purges active '
      'debuffs when immunity is granted, and ticks combat + map steps',
      () {
        const catPoison = 1 << 0;
        const catCurse = 1 << 1;
        const catBuff = 1 << 2;

        final attrs = AttributeSet()..setBase('def', 100);
        final statuses = StatusEffectContainer(attrs);

        const poisonDef = StatusEffectDef(
          id: 'poison',
          stackPolicy: StatusStackPolicy.stackIntensity,
          maxStacks: 3,
          durationTurns: 2,
          durationSteps: 6,
          categoryMask: catPoison,
          modifiers: <StatModifier>[
            StatModifier(
              id: 'poison_def_down',
              statId: 'def',
              op: StatModifierOp.flatAdd,
              value: -10,
            ),
          ],
          tickTrigger: StatusTickTrigger.onMapStep,
          stepsPerTick: 2,
          periodicDeltaPerStack: -5,
        );

        expect(statuses.apply(poisonDef, stacks: 2), isTrue);
        expect(statuses.apply(poisonDef, stacks: 5), isTrue); // clamps to 3
        expect(statuses.stackCountOf('poison'), 3);
        expect(attrs.get('def'), closeTo(70.0, 1e-9)); // 100 - 10 * 3

        // Map-step periodic DoT: 5 steps with stepsPerTick=2 fires 2 ticks
        // (-15 each at 3 stacks) and leaves 1 step remaining on
        // durationSteps=6.
        final stepTicks = statuses.advanceMapSteps(5);
        expect(stepTicks.length, 2);
        expect(stepTicks[0].delta, closeTo(-15.0, 1e-9));
        expect(stepTicks[1].delta, closeTo(-15.0, 1e-9));
        expect(statuses.hasStatus('poison'), isTrue);

        // Granting poison immunity while poisoned MUST purge active poison
        // immediately AND block new applications!
        const antidoteWard = StatusEffectDef(
          id: 'antidote_ward',
          stackPolicy: StatusStackPolicy.highestOnly,
          durationTurns: 3,
          categoryMask: catBuff,
          grantedImmunityMask: catPoison,
        );
        expect(statuses.apply(antidoteWard), isTrue);
        expect(statuses.hasStatus('poison'), isFalse);
        expect(attrs.get('def'), closeTo(100.0, 1e-9));
        expect(statuses.apply(poisonDef), isFalse);

        // Independent instances + dispelByMask(maxRemoved: 1).
        const bleedDef = StatusEffectDef(
          id: 'bleed',
          stackPolicy: StatusStackPolicy.independentTimers,
          maxStacks: 3,
          durationTurns: 2,
          categoryMask: catCurse,
          tickTrigger: StatusTickTrigger.onTurnEnd,
          periodicDeltaPerStack: -8,
        );
        expect(statuses.apply(bleedDef), isTrue);
        expect(statuses.advanceTurn(startOfTurn: false).single.delta, -8.0);
        // Second bleed applied 1 turn later has full 2 turns left, while first
        // has 1 turn left.
        expect(statuses.apply(bleedDef), isTrue);
        expect(statuses.stackCountOf('bleed'), 2);

        final turn2Ticks = statuses.advanceTurn(startOfTurn: false);
        expect(turn2Ticks.length, 2);
        // First bleed expired at end of turn 2; second still has 1 turn!
        expect(statuses.stackCountOf('bleed'), 1);

        final dispelled = statuses.dispelByMask(catCurse, maxRemoved: 1);
        expect(dispelled, 1);
        expect(statuses.hasStatus('bleed'), isFalse);
        expect(statuses.hasStatus('antidote_ward'), isTrue);
      },
    );

    test(
      'FormulaVM compiles to RPN, handles unary minus & precedence, guards '
      'NaN/div-by-zero, and applies deterministic variance',
      () {
        final vm = FormulaVM();
        final attacker = AttributeSet()
          ..setBase('atk', 50)
          ..setBase('luk', 20);
        final defender = AttributeSet()..setBase('def', 30);

        // Precedence + unary minus + conditional + world variable lookup.
        final dmgFormula = FormulaVM.compile(
          'if(a.atk > b.def && v[3] >= 10, '
          'max(1, -(b.def * 2 - a.atk * 4) + -a.luk * -0.5), 0)',
        );
        // -(60 - 200) + (-20 * -0.5) = 140 + 10 = 150.
        final baseVal = vm.evaluate(
          dmgFormula,
          attacker: attacker,
          defender: defender,
          worldVariableLookup: (id) => id == 3 ? 12.0 : 0.0,
        );
        expect(baseVal, closeTo(150.0, 1e-9));

        // Deterministic variance & critical multiplier.
        final critA = vm.evaluate(
          dmgFormula,
          attacker: attacker,
          defender: defender,
          worldVariableLookup: (_) => 12.0,
          variance: 0.20,
          rng: SeededRng(777),
          isCritical: true,
        );
        final critB = vm.evaluate(
          dmgFormula,
          attacker: attacker,
          defender: defender,
          worldVariableLookup: (_) => 12.0,
          variance: 0.20,
          rng: SeededRng(777),
          isCritical: true,
        );
        expect(critA, equals(critB));
        expect(critA, inInclusiveRange(240.0, 360.0)); // 150 * [0.8..1.2] * 2

        // NaN / Infinity safety on division by zero, mod zero, negative sqrt.
        final hazardFormula = FormulaVM.compile(
          '(100 / 0) + (55 % 0) + sqrt(-16) + clamp(lerp(10, 20, 0.25), 0, 99)',
        );
        final safeVal = vm.evaluate(hazardFormula);
        expect(safeVal.isFinite, isTrue);
        expect(safeVal.isNaN, isFalse);
        expect(safeVal, closeTo(12.5, 1e-9));

        // Malformed syntax throws FormatException at compile time.
        expect(() => FormulaVM.compile('a.atk + * 2'), throwsFormatException);
        expect(() => FormulaVM.compile('max(1)'), throwsFormatException);
        expect(() => FormulaVM.compile('((1 + 2)'), throwsFormatException);
        expect(() => FormulaVM.compile('nope(5)'), throwsFormatException);
      },
    );
  });

  group('TurnTimelineScheduler and TacticalRangeSolver', () {
    test(
      'TurnTimelineScheduler supports roundPriority, ATB wait-mode freeze, '
      'and non-destructive CTB previewTurnOrder',
      () {
        // 1. Round-priority mode: Quick Attack (+1 priority) beats 999 agility.
        final roundSched =
            TurnTimelineScheduler(
                mode: BattleTurnMode.roundPriority,
              )
              ..addCombatant(
                TurnCombatantState(
                  id: 'boss_fast',
                  agility: 999,
                ),
              )
              ..addCombatant(
                TurnCombatantState(
                  id: 'rogue_quick',
                  agility: 12,
                  roundPriorityBonus: 1,
                  tieBreakOrder: 1,
                ),
              )
              ..addCombatant(
                TurnCombatantState(
                  id: 'mage_stunned',
                  agility: 500,
                  isStunned: true,
                ),
              );

        expect(roundSched.nextTurn()?.id, 'rogue_quick');
        roundSched.commitTurn();
        expect(roundSched.nextTurn()?.id, 'boss_fast');
        roundSched.commitTurn();
        expect(roundSched.roundIndex, 1);
        expect(roundSched.nextTurn()?.id, 'rogue_quick');
        expect(roundSched.roundIndex, 2);

        // 2. ATB waitMode: gauges freeze while a command menu is open!
        final atbSched =
            TurnTimelineScheduler(
                mode: BattleTurnMode.activeTimeBattle,
              )
              ..addCombatant(TurnCombatantState(id: 'hero', agility: 100))
              ..addCombatant(TurnCombatantState(id: 'slime', agility: 50));

        atbSched.updateAtb(2.0);
        expect(atbSched.activeActorId, 'hero');
        atbSched.isCommandMenuOpen = true;
        final slimeGaugeWhenPaused = atbSched.findCombatant('slime')!.atbGauge;
        // 10 seconds pass while player browses spell menu -> 0 enemy fill!
        atbSched.updateAtb(10.0);
        expect(atbSched.activeActorId, 'hero');
        expect(
          atbSched.findCombatant('slime')!.atbGauge,
          equals(slimeGaugeWhenPaused),
        );
        // Committing the turn automatically clears isCommandMenuOpen & resumes!
        atbSched.commitTurn();
        expect(atbSched.isCommandMenuOpen, isFalse);
        atbSched.updateAtb(2.0);
        expect(atbSched.activeActorId, 'slime');

        // 3. CTB mode: previewTurnOrder simulates quick vs heavy skills without
        // mutating live action values or timeline clock!
        final ctbSched = TurnTimelineScheduler()
          ..addCombatant(
            TurnCombatantState(
              id: 'hero',
              agility: 100,
            ),
          )
          ..addCombatant(
            TurnCombatantState(
              id: 'boss',
              agility: 80,
              tieBreakOrder: 1,
            ),
          );

        expect(ctbSched.nextTurn()?.id, 'hero');
        final clockBefore = ctbSched.timelineClock;
        final heroAvBefore = ctbSched.findCombatant('hero')!.ctbActionValue;
        final bossAvBefore = ctbSched.findCombatant('boss')!.ctbActionValue;

        // Quick skill (0.4x delay -> +4 AV vs boss remaining 2.5 -> boss acts
        // once, then hero gets consecutive turns before boss recovers!).
        final quickPreview = ctbSched.previewTurnOrder(
          5,
          hypotheticalActorId: 'hero',
          hypotheticalDelayMultiplier: 0.4,
        );
        // Heavy skill (2.5x delay -> +25 AV -> boss gets TWO turns at +2.5 and
        // +15.0 before hero acts again at +25.0!).
        final heavyPreview = ctbSched.previewTurnOrder(
          5,
          hypotheticalActorId: 'hero',
          hypotheticalDelayMultiplier: 2.5,
        );

        expect(
          quickPreview.sublist(0, 3),
          equals(const <String>['boss', 'hero', 'hero']),
        );
        expect(
          heavyPreview.sublist(0, 3),
          equals(const <String>['boss', 'boss', 'hero']),
        );

        // Live state MUST remain 100% bit-identical!
        expect(ctbSched.timelineClock, equals(clockBefore));
        expect(
          ctbSched.findCombatant('hero')!.ctbActionValue,
          equals(heroAvBefore),
        );
        expect(
          ctbSched.findCombatant('boss')!.ctbActionValue,
          equals(bossAvBefore),
        );
        expect(ctbSched.activeActorId, 'hero');
      },
    );

    test(
      'TacticalRangeSolver enforces ZOC, ally pass-through without stacking, '
      'cliff climb/drop limits, attack fringe, and AoE wall occlusion',
      () {
        final solver = TacticalRangeSolver(width: 8, height: 8);
        // Enemy at (3, 1) exerts ZOC onto (3, 2); ally stands at (1, 2).
        // Cliff shelf at col=0, row=4 has height 3 (too high to climb from 0,
        // reachable only if dropping).
        solver.solve(
          startCol: 1,
          startRow: 2,
          moveBudget: 4.0,
          maxClimb: 1,
          maxDrop: 3,
          minAttackRange: 1,
          maxAttackRange: 2,
          occupantAt: (c, r) {
            if (c == 2 && r == 2) {
              return TacticalOccupant.ally;
            }
            if (c == 4 && r == 1) {
              return TacticalOccupant.enemy;
            }
            return TacticalOccupant.none;
          },
          elevationAt: (c, r) {
            if (c == 1 && r == 3) {
              return 2; // +2 cliff directly south: unclimbable (maxClimb=1)!
            }
            return 0;
          },
        );

        // Ally at (2, 2): traversable, CANNOT stand on (2, 2), CAN stand on
        // (3, 2) beyond the ally!
        expect(solver.canTraverse(2, 2), isTrue);
        expect(solver.canStandAt(2, 2), isFalse);
        expect(solver.canStandAt(3, 2), isTrue);

        // Stepping into (4, 2) enters enemy (4, 1)'s Zone of Control -> budget
        // is zeroed, so (5, 2) cannot be reached through (4, 2) on budget 4!
        expect(solver.canStandAt(4, 2), isTrue);
        expect(solver.canStandAt(5, 2), isFalse);

        // Unclimbable +2 cliff directly south at (1, 3) is blocked from (1, 2).
        expect(solver.canStandAt(1, 3), isFalse);

        // Attack fringe extends 2 Manhattan steps past furthest standable
        // tiles.
        expect(solver.isInAttackRange(6, 2), isTrue);
        expect(solver.isAttackFringeOnly(6, 2), isTrue);

        final path = <int>[];
        expect(solver.reconstructPath(4, 2, path), isTrue);
        expect(solver.unpackCol(path.first), 1);
        expect(solver.unpackRow(path.first), 2);
        expect(solver.unpackCol(path.last), 4);
        expect(solver.unpackRow(path.last), 2);

        // GridAreaTemplate: rayLine halted by wall vs piercing ray.
        const blockedRay = GridAreaTemplate(
          kind: AoEShapeKind.rayLine,
          radius: 5,
          stopsAtWalls: true,
        );
        const piercingRay = GridAreaTemplate(
          kind: AoEShapeKind.rayLine,
          radius: 5,
        );
        final outBlocked = <({int col, int row})>[];
        final outPiercing = <({int col, int row})>[];
        blockedRay.collectCells(
          originCol: 1,
          originRow: 1,
          targetCol: 5,
          targetRow: 1,
          gridWidth: 8,
          gridHeight: 8,
          outCells: outBlocked,
          isWallBlocked: (c, r) => c == 4 && r == 1,
        );
        piercingRay.collectCells(
          originCol: 1,
          originRow: 1,
          targetCol: 5,
          targetRow: 1,
          gridWidth: 8,
          gridHeight: 8,
          outCells: outPiercing,
          isWallBlocked: (c, r) => c == 4 && r == 1,
        );
        expect(outBlocked.length, 2); // (2,1), (3,1) -> stops at wall (4,1)!
        expect(outPiercing.length, 5); // (2,1)..(6,1)

        // Hollow ring excludes inner radius < 2.
        const ring = GridAreaTemplate(
          kind: AoEShapeKind.ring,
          minRadius: 2,
          radius: 2,
        );
        final ringCells = <({int col, int row})>[];
        ring.collectCells(
          originCol: 4,
          originRow: 4,
          targetCol: 4,
          targetRow: 4,
          gridWidth: 9,
          gridHeight: 9,
          outCells: ringCells,
        );
        expect(ringCells, isNot(contains((col: 4, row: 4))));
        expect(ringCells, isNot(contains((col: 5, row: 4))));
        expect(ringCells.length, 8); // Manhattan circle of radius 2 has 8 cells
      },
    );
  });
}
