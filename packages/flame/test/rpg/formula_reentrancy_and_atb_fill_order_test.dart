import 'package:flame/rpg.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FormulaVM re-entrancy', () {
    test('a world variable that is computed by a formula on the same VM', () {
      final vm = FormulaVM();
      final outer = FormulaVM.compile('100 + v[1]');
      final derived = FormulaVM.compile('3 * 4');

      final result = vm.evaluate(
        outer,
        worldVariableLookup: (id) => vm.evaluate(derived),
      );
      expect(result, 112);
      // And the VM is back in its plain state.
      expect(vm.evaluate(derived), 12);
    });

    test('nested several levels deep, with operands pending at each level', () {
      final vm = FormulaVM();
      final formulas = [
        FormulaVM.compile('1 + 2 * (3 + v[1]) - 4'),
        FormulaVM.compile('10 * (v[2] + 1) + 5'),
        FormulaVM.compile('max(7, v[3]) * 2'),
        FormulaVM.compile('40 / 8'),
      ];
      double lookup(int id) =>
          vm.evaluate(formulas[id], worldVariableLookup: lookup);

      // v[3] = 5, v[2] = max(7, 5) * 2 = 14, v[1] = 10 * 15 + 5 = 155.
      expect(lookup(0), 1 + 2 * (3 + 155) - 4);
    });

    test('a nested evaluation that needs more stack than is allocated', () {
      final vm = FormulaVM(stackCapacity: 16);
      // 40 nested parentheses keep 40 operands pending.
      final deep = FormulaVM.compile(
        '${List.filled(40, '1 + (').join()}1${List.filled(40, ')').join()}',
      );
      final outer = FormulaVM.compile('2 * (3 + v[0])');
      expect(
        vm.evaluate(outer, worldVariableLookup: (_) => vm.evaluate(deep)),
        2 * (3 + 41),
      );
    });

    test('a lookup that throws leaves the VM usable', () {
      final vm = FormulaVM();
      final outer = FormulaVM.compile('5 + v[1]');
      expect(
        () => vm.evaluate(
          outer,
          worldVariableLookup: (_) => throw StateError('no such variable'),
        ),
        throwsStateError,
      );
      expect(vm.evaluate(outer, worldVariableLookup: (_) => 2), 7);
    });
  });

  group('TurnTimelineScheduler active time battle', () {
    TurnTimelineScheduler battle() {
      // Registered slow first: at the same agility `late` needs 0.04 s and
      // `early` 0.004 s to fill up.
      return TurnTimelineScheduler(mode: BattleTurnMode.activeTimeBattle)
        ..addCombatant(
          TurnCombatantState(id: 'late', agility: 10, atbGauge: 99.0),
        )
        ..addCombatant(
          TurnCombatantState(id: 'early', agility: 10, atbGauge: 99.9),
        );
    }

    List<String> playTurns(TurnTimelineScheduler scheduler, double dt) {
      final order = <String>[];
      for (var tick = 0; tick < 2000 && order.length < 6; tick++) {
        scheduler.updateAtb(dt);
        final actor = scheduler.nextTurn();
        if (actor != null) {
          order.add(actor.id);
          scheduler.commitTurn();
        }
      }
      return order;
    }

    test('gauges that fill within one tick act in the order they filled', () {
      final scheduler = battle();
      // One coarse tick fills both gauges.
      scheduler.updateAtb(0.05);
      expect(scheduler.activeActorId, 'early');
      scheduler.commitTurn();
      expect(scheduler.activeActorId, 'late');
    });

    test('the turn order does not depend on the tick length', () {
      final fine = playTurns(battle(), 0.001);
      final coarse = playTurns(battle(), 0.05);
      expect(fine.take(2), ['early', 'late']);
      expect(coarse.take(2), fine.take(2));
    });

    test('the live order is the one previewTurnOrder forecast', () {
      final scheduler = battle();
      final forecast = scheduler.previewTurnOrder(2);
      expect(forecast, ['early', 'late']);
      expect(playTurns(scheduler, 0.05).take(2), forecast);
    });

    test('equal fill times fall back to tieBreakOrder', () {
      final scheduler =
          TurnTimelineScheduler(
              mode: BattleTurnMode.activeTimeBattle,
            )
            ..addCombatant(
              TurnCombatantState(id: 'b', agility: 10, tieBreakOrder: 2),
            )
            ..addCombatant(
              TurnCombatantState(id: 'a', agility: 10, tieBreakOrder: 1),
            );
      final forecast = scheduler.previewTurnOrder(2);
      expect(forecast, ['a', 'b']);
      expect(playTurns(scheduler, 0.5).take(2), forecast);
    });
  });
}
