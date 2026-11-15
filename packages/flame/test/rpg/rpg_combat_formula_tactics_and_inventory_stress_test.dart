import 'dart:math' as math;

import 'package:flame/math.dart';
import 'package:flame/navigation.dart';
import 'package:flame/rpg.dart';
import 'package:flutter_test/flutter_test.dart';

String _randomValidExpr(SeededRng rng, int depth) {
  if (depth <= 0 || rng.nextDouble() < 0.25) {
    return switch (rng.nextInt(6)) {
      0 => '${rng.nextInt(200) - 50}',
      1 => 'a.atk',
      2 => 'b.def',
      3 => 'v[${rng.nextInt(4)}]',
      4 => '-a.atk',
      _ => (rng.nextDouble() * 10).toStringAsFixed(2),
    };
  }
  final a = _randomValidExpr(rng, depth - 1);
  final b = _randomValidExpr(rng, depth - 1);
  return switch (rng.nextInt(9)) {
    0 => '($a + $b)',
    1 => '($a - $b)',
    2 => '($a * $b)',
    3 => '($a / $b)',
    4 => '($a % $b)',
    5 => 'max($a, $b)',
    6 => 'min($a, $b)',
    7 => 'sqrt(abs($a) - 5)',
    _ => 'if($a >= $b, clamp($a, -1000, 1000), lerp($a, $b, 0.5))',
  };
}

/// Independent Bellman-Ford reference oracle for [TacticalRangeSolver]
/// (without ZOC/ally-only rules on pure weighted elevation grids).
List<double> _bellmanFordOracle({
  required int w,
  required int h,
  required int startCol,
  required int startRow,
  required List<double> terrainCost,
  required List<int> elevation,
  required int maxClimb,
  required int maxDrop,
}) {
  final dist = List<double>.filled(w * h, double.infinity);
  dist[startRow * w + startCol] = 0.0;
  const dx = <int>[0, 1, 0, -1];
  const dy = <int>[-1, 0, 1, 0];

  for (var iter = 0; iter < w * h; iter++) {
    var changed = false;
    for (var r = 0; r < h; r++) {
      for (var c = 0; c < w; c++) {
        final u = r * w + c;
        final du = dist[u];
        if (du.isInfinite) {
          continue;
        }
        for (var d = 0; d < 4; d++) {
          final nc = c + dx[d];
          final nr = r + dy[d];
          if (nc < 0 || nc >= w || nr < 0 || nr >= h) {
            continue;
          }
          final v = nr * w + nc;
          final step = terrainCost[v];
          if (step <= 0 || step.isInfinite) {
            continue;
          }
          final dh = elevation[v] - elevation[u];
          if (dh > maxClimb || -dh > maxDrop) {
            continue;
          }
          if (du + step < dist[v] - 1e-9) {
            dist[v] = du + step;
            changed = true;
          }
        }
      }
    }
    if (!changed) {
      break;
    }
  }
  return dist;
}

void main() {
  group('AttributeSet churn, FormulaVM AST fuzz & 50-unit CTB stress', () {
    test(
      'AttributeSet incremental cache matches fresh recomputation across '
      '1,000 random modifier mutations, and FormulaVM survives 400 random ASTs',
      () {
        final rng = SeededRng(0xA7741B);
        final live = AttributeSet()
          ..setBase('atk', 80)
          ..setBase('def', 65)
          ..setBounds('atk', min: -500, max: 50000);
        final activeMods = <String, StatModifier>{};

        for (var step = 0; step < 1000; step++) {
          final id = 'mod_${rng.nextInt(40)}';
          if (rng.nextDouble() < 0.35 && activeMods.containsKey(id)) {
            live.removeModifierById(id);
            activeMods.remove(id);
          } else {
            final op =
                StatModifierOp.values[rng.nextInt(
                  StatModifierOp.values.length,
                )];
            final val = switch (op) {
              StatModifierOp.flatAdd => (rng.nextDouble() - 0.3) * 100.0,
              StatModifierOp.percentAdd => (rng.nextDouble() - 0.2) * 1.5,
              StatModifierOp.percentMul => 0.5 + rng.nextDouble() * 1.5,
              StatModifierOp.finalOverride => rng.nextDouble() * 500.0,
            };
            final mod = StatModifier(
              id: id,
              statId: 'atk',
              op: op,
              value: val,
              priority: rng.nextInt(10),
            );
            live.addModifier(mod);
            activeMods[id] = mod;
          }

          if (step % 50 == 0) {
            final fresh = AttributeSet()
              ..setBase('atk', 80)
              ..setBounds('atk', min: -500, max: 50000);
            for (final m in activeMods.values) {
              fresh.addModifier(m);
            }
            expect(live.get('atk'), closeTo(fresh.get('atk'), 1e-7));
          }
        }

        // Fuzz 400 random nested FormulaVM expressions: ZERO NaN / Infinity!
        final vm = FormulaVM();
        final defender = AttributeSet()..setBase('def', 40);
        for (var i = 0; i < 400; i++) {
          final expr = _randomValidExpr(rng, 4);
          final compiled = FormulaVM.compile(expr);
          final out = vm.evaluate(
            compiled,
            attacker: live,
            defender: defender,
            worldVariableLookup: (v) => (v - 1.5) * 10.0,
            variance: 0.15,
            rng: rng,
          );
          expect(
            out.isFinite && !out.isNaN,
            isTrue,
            reason: 'Non-finite result $out for expression: $expr',
          );
        }
      },
    );

    test(
      '50-combatant 600-turn CTB battle with extreme agility (1 vs 5,000), '
      'stuns/deaths/revives, and bit-exact previewTurnOrder(20) every turn',
      () {
        final rng = SeededRng(0xC7B500);
        final sched = TurnTimelineScheduler();

        for (var i = 0; i < 50; i++) {
          final agi = i == 0
              ? 5000.0
              : (i == 49 ? 1.0 : 10.0 + rng.nextDouble() * 250.0);
          sched.addCombatant(
            TurnCombatantState(
              id: 'unit_$i',
              agility: agi,
              tieBreakOrder: i,
            ),
          );
        }

        for (var turn = 0; turn < 600; turn++) {
          final actor = sched.nextTurn();
          expect(actor, isNotNull);
          expect(actor!.isAlive, isTrue);
          expect(actor.isStunned, isFalse);

          // Snapshot every combatant's exact ctbActionValue + clock BEFORE
          // previewing 20 turns ahead!
          final clockBefore = sched.timelineClock;
          final avSnapshot = <double>[
            for (final c in sched.combatants) c.ctbActionValue,
          ];

          final preview = sched.previewTurnOrder(
            20,
            hypotheticalActorId: actor.id,
            hypotheticalDelayMultiplier: 0.3 + rng.nextDouble() * 2.5,
          );
          expect(preview.length, 20);
          for (final pid in preview) {
            final pc = sched.findCombatant(pid)!;
            expect(pc.isAlive && !pc.isStunned, isTrue);
          }

          expect(sched.timelineClock, equals(clockBefore));
          for (var i = 0; i < sched.combatants.length; i++) {
            expect(sched.combatants[i].ctbActionValue, equals(avSnapshot[i]));
          }

          // Randomly stun/kill/revive/knockback non-active units mid-battle
          // (keeping at least 5 units alive & unstunned!).
          if (turn % 7 == 0) {
            final idx = 1 + rng.nextInt(48);
            final target = sched.combatants[idx];
            if (idx > 5) {
              target
                ..isAlive = rng.nextDouble() > 0.25
                ..isStunned = rng.nextDouble() < 0.20;
            }
            sched.shiftActionValue(target.id, (rng.nextDouble() - 0.3) * 40.0);
          }

          sched.commitTurn(delayMultiplier: 0.5 + rng.nextDouble() * 1.8);
        }
      },
    );
  });

  group('TacticalRangeSolver Bellman-Ford oracle & Inventory conservation', () {
    test(
      'TacticalRangeSolver matches Bellman-Ford shortest path costs & '
      'validates reconstructed paths across 15 random 24x24 elevation maps',
      () {
        final rng = SeededRng(0xD14C57);
        const w = 24;
        const h = 24;
        final solver = TacticalRangeSolver(width: w, height: h);
        final packedPath = <int>[];

        for (var mapIdx = 0; mapIdx < 15; mapIdx++) {
          final costs = List<double>.generate(w * h, (_) {
            final r = rng.nextDouble();
            if (r < 0.18) {
              return double.infinity; // wall/chasm
            }
            return (1 + rng.nextInt(4)).toDouble();
          });
          final elev = List<int>.generate(w * h, (_) => rng.nextInt(5));
          const sc = 12;
          const sr = 12;
          costs[sr * w + sc] = 1.0;

          const budget = 14.0;
          solver.solve(
            startCol: sc,
            startRow: sr,
            moveBudget: budget,
            stepCost: (c, r) => costs[r * w + c],
            elevationAt: (c, r) => elev[r * w + c],
            maxClimb: 1,
            maxDrop: 2,
            enableZoneOfControl: false,
          );

          final oracle = _bellmanFordOracle(
            w: w,
            h: h,
            startCol: sc,
            startRow: sr,
            terrainCost: costs,
            elevation: elev,
            maxClimb: 1,
            maxDrop: 2,
          );

          for (var r = 0; r < h; r++) {
            for (var c = 0; c < w; c++) {
              final truth = oracle[r * w + c];
              if (truth <= budget + 1e-9) {
                expect(solver.canStandAt(c, r), isTrue);
                expect(solver.costTo(c, r), closeTo(truth, 1e-6));
                expect(solver.reconstructPath(c, r, packedPath), isTrue);
                // Sum step costs along reconstructed path == solver.costTo!
                var pathSum = 0.0;
                for (var s = 1; s < packedPath.length; s++) {
                  final pc = solver.unpackCol(packedPath[s - 1]);
                  final pr = solver.unpackRow(packedPath[s - 1]);
                  final nc = solver.unpackCol(packedPath[s]);
                  final nr = solver.unpackRow(packedPath[s]);
                  expect((nc - pc).abs() + (nr - pr).abs(), 1);
                  pathSum += costs[nr * w + nc];
                }
                expect(pathSum, closeTo(truth, 1e-6));
              } else {
                expect(solver.canStandAt(c, r), isFalse);
              }
            }
          }
        }
      },
    );

    test(
      'conserves exact item counts and respects weight/slot caps across '
      '1,000 random InventoryContainer + EquipmentLoadout operations',
      () {
        final catalog = <InventoryItemDef>[
          const InventoryItemDef(
            id: 'sword_1h',
            name: 'Sword',
            maxStack: 1,
            unitWeight: 3.0,
            equipSlot: EquipSlot.mainHand,
          ),
          const InventoryItemDef(
            id: 'shield_off',
            name: 'Shield',
            maxStack: 1,
            unitWeight: 4.0,
            equipSlot: EquipSlot.offHand,
          ),
          const InventoryItemDef(
            id: 'halberd_2h',
            name: 'Halberd',
            maxStack: 1,
            unitWeight: 6.0,
            equipSlot: EquipSlot.mainHand,
            twoHanded: true,
          ),
          const InventoryItemDef(
            id: 'ring',
            name: 'Ring',
            maxStack: 1,
            unitWeight: 0.5,
            equipSlot: EquipSlot.accessory1,
          ),
          const InventoryItemDef(
            id: 'potion',
            name: 'Potion',
            maxStack: 5,
            unitWeight: 0.8,
            sortCategory: 2,
          ),
        ];

        final attrs = AttributeSet();
        final bag = InventoryContainer(maxSlots: 6, maxWeight: 18.0);
        final loadout = EquipmentLoadout(attrs);
        final expectedOwned = <String, int>{
          for (final item in catalog) item.id: 0,
        };

        int actualTotalOf(String itemId) {
          var total = bag.countOf(itemId);
          for (final slot in EquipSlot.values) {
            if (loadout.equippedIn(slot)?.id == itemId) {
              total++;
            }
          }
          return total;
        }

        final rng = SeededRng(0xBA6F00D);
        for (var op = 0; op < 1000; op++) {
          final def = catalog[rng.nextInt(catalog.length)];
          switch (rng.nextInt(5)) {
            case 0: // addItem
              final qty = 1 + rng.nextInt(4);
              final leftover = bag.addItem(def, qty);
              expectedOwned[def.id] = expectedOwned[def.id]! + (qty - leftover);
            case 1: // removeItem
              final qty = 1 + rng.nextInt(3);
              final removed = bag.removeItem(def.id, qty);
              expectedOwned[def.id] = math.max(
                0,
                expectedOwned[def.id]! - removed,
              );
            case 2: // equip from bag (only if at least 1 is in bag!)
              if (def.equipSlot != null && bag.countOf(def.id) > 0) {
                final slot =
                    def.equipSlot == EquipSlot.accessory1 && rng.nextBool()
                    ? EquipSlot.accessory2
                    : def.equipSlot!;
                loadout.equip(slot, def, bag: bag);
              }
            case 3: // unequip random slot into bag
              final slot =
                  EquipSlot.values[rng.nextInt(EquipSlot.values.length)];
              loadout.unequip(slot, bag: bag);
            default: // compactAndSort
              bag.compactAndSort();
          }

          // Invariants AFTER EVERY SINGLE OPERATION:
          expect(bag.usedSlots, lessThanOrEqualTo(bag.maxSlots));
          expect(bag.totalWeight, lessThanOrEqualTo(bag.maxWeight + 1e-7));
          if (loadout.isTwoHandedEquipped) {
            expect(loadout.equippedIn(EquipSlot.offHand), isNull);
          }
          for (final item in catalog) {
            expect(
              actualTotalOf(item.id),
              expectedOwned[item.id],
              reason: 'Conservation violated at op $op for ${item.id}',
            );
          }
        }
      },
    );
  });
}
