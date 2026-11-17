import 'dart:collection';
import 'dart:math' as math;

/// Turn scheduling paradigm for [TurnTimelineScheduler].
enum BattleTurnMode() {
  /// Classic Dragon Quest / Pokémon / RPG Maker round-based priority & speed
  /// order (each living combatant acts once per round).
  roundPriority,

  /// Active Time Battle (ATB — Final Fantasy IV–IX / Chrono Trigger):
  /// gauges fill in real time from `0` to `maxAtbGauge`, pausing automatically
  /// when `waitMode` is enabled and a command submenu is open.
  activeTimeBattle,

  /// Conditional Turn-Based (CTB — Final Fantasy X / Trails / Honkai):
  /// continuous `actionValue` timeline where heavy/quick skills shift an
  /// actor's next turn slot and [TurnTimelineScheduler.previewTurnOrder]
  /// predicts future turn sequences without mutating live combat state.
  conditionalTurnBased,
}

/// Runtime timeline state of a single combatant in [TurnTimelineScheduler].
class TurnCombatantState({
  required this.id,
  required double agility,
  this.roundPriorityBonus = 0,
  this.tieBreakOrder = 0,
  this.isAlive = true,
  this.isStunned = false,
  this.atbGauge = 0.0,
  double? initialActionValue,
  double baseActionConstant = 1000.0,
}) {
  /// Unique combatant identifier.
  final String id;

  /// Effective speed/agility (`>= 1.0`).
  double agility = math.max(1.0, agility);

  /// Skill/command priority tier in [BattleTurnMode.roundPriority] (e.g.
  /// Quick Attack `+1` goes before normal `0` regardless of speed).
  int roundPriorityBonus;

  /// Deterministic tie-breaker index when gauges or action values match.
  int tieBreakOrder;

  /// Whether this combatant is conscious (`HP > 0`).
  bool isAlive;

  /// Whether this combatant cannot advance or take turns (e.g. frozen/paralyzed).
  bool isStunned;

  /// Current ATB gauge in `[0.0 .. maxAtbGauge]`.
  double atbGauge;

  /// Remaining CTB action-value ticks until this combatant's next turn.
  double ctbActionValue =
      initialActionValue ?? (baseActionConstant / math.max(1.0, agility));

  /// Updates [agility] (`>= 1.0`).
  void setAgility(double nextAgility) {
    agility = math.max(1.0, nextAgility);
  }
}

/// Turn scheduler supporting Round-Priority, Wait-Mode ATB, and CTB
/// action-value queues with side-effect-free turn order forecasting.
class TurnTimelineScheduler({
  this.mode = BattleTurnMode.conditionalTurnBased,
  this.maxAtbGauge = 100.0,
  this.atbBaseFillRate = 25.0,
  this.ctbBaseActionConstant = 1000.0,
  this.waitMode = true,
}) {
  this
    : assert(maxAtbGauge > 0.0, 'maxAtbGauge must be > 0.'),
      assert(ctbBaseActionConstant > 0.0, 'ctbBaseActionConstant must be > 0.');

  /// Active turn scheduling paradigm.
  BattleTurnMode mode;

  /// ATB readiness threshold.
  final double maxAtbGauge;

  /// Base ATB points per second for `agility == 1.0` (scales with agility).
  final double atbBaseFillRate;

  /// Base CTB action delay numerator (`delay = constant * mult / agility`).
  final double ctbBaseActionConstant;

  /// When `true` in [BattleTurnMode.activeTimeBattle], ATB gauges freeze while
  /// [isCommandMenuOpen] is `true`.
  bool waitMode;

  /// Whether the player is currently browsing a sub-menu (spells/items/target)
  /// during an ATB turn.
  bool isCommandMenuOpen = false;

  final List<TurnCombatantState> _combatants = <TurnCombatantState>[];
  final Queue<String> _readyQueue = Queue<String>();

  String? _activeActorId;
  int _roundIndex = 0;
  double _timelineClock = 0.0;

  /// Read-only view of registered combatants.
  List<TurnCombatantState> get combatants =>
      List<TurnCombatantState>.unmodifiable(_combatants);

  /// Identifier of the actor currently executing a turn, or `null`.
  String? get activeActorId => _activeActorId;

  /// Current round index (incremented each full cycle in
  /// [BattleTurnMode.roundPriority]).
  int get roundIndex => _roundIndex;

  /// Cumulative CTB/ATB timeline clock.
  double get timelineClock => _timelineClock;

  /// Registers [combatant] into the scheduler.
  void addCombatant(TurnCombatantState combatant) {
    _combatants.removeWhere((c) => c.id == combatant.id);
    _combatants.add(combatant);
  }

  /// Removes combatant [id] from the scheduler and any pending turn queues.
  void removeCombatant(String id) {
    _combatants.removeWhere((c) => c.id == id);
    _readyQueue.removeWhere((q) => q == id);
    if (_activeActorId == id) {
      _activeActorId = null;
    }
  }

  /// Looks up a registered combatant by [id].
  TurnCombatantState? findCombatant(String id) {
    for (var i = 0; i < _combatants.length; i++) {
      if (_combatants[i].id == id) {
        return _combatants[i];
      }
    }
    return null;
  }

  bool _canAct(TurnCombatantState c) => c.isAlive && !c.isStunned;

  final List<TurnCombatantState> _filledThisTick = <TurnCombatantState>[];
  final List<double> _fillTimeThisTick = <double>[];

  /// Whether a gauge that fills after [timeA] goes before one that fills
  /// after [timeB]: the earlier one, and for a tie the lower `tieBreakOrder`.
  static bool _fillsBefore(
    double timeA,
    TurnCombatantState a,
    double timeB,
    TurnCombatantState b,
  ) {
    if (timeA < timeB - 1e-9) {
      return true;
    }
    return (timeA - timeB).abs() <= 1e-9 && a.tieBreakOrder < b.tieBreakOrder;
  }

  /// Advances real-time ATB gauges by [dt] seconds (no-op in non-ATB modes or
  /// while frozen in `waitMode && isCommandMenuOpen`).
  void updateAtb(double dt) {
    if (mode != BattleTurnMode.activeTimeBattle || dt <= 0.0) {
      return;
    }
    if (waitMode && isCommandMenuOpen) {
      return;
    }
    _timelineClock += dt;

    _filledThisTick.clear();
    _fillTimeThisTick.clear();
    for (var i = 0; i < _combatants.length; i++) {
      final c = _combatants[i];
      if (!_canAct(c)) {
        continue;
      }
      if (c.id == _activeActorId || _readyQueue.contains(c.id)) {
        continue;
      }
      // Sublinear sqrt scaling keeps high-agility characters fast without
      // starving slower party members.
      final rate = atbBaseFillRate * math.sqrt(c.agility / 10.0);
      final before = c.atbGauge;
      c.atbGauge = math.min(maxAtbGauge, before + rate * dt);
      if (c.atbGauge >= maxAtbGauge - 1e-9) {
        c.atbGauge = maxAtbGauge;
        // Several gauges can fill within one tick. They become ready in the
        // order in which they filled, not in registration order, so that the
        // turn order does not depend on the frame rate and is the one that
        // [previewTurnOrder] forecasts.
        final fillTime = rate > 0.0
            ? math.max(0.0, maxAtbGauge - before) / rate
            : 0.0;
        var at = _filledThisTick.length;
        while (at > 0 &&
            _fillsBefore(
              fillTime,
              c,
              _fillTimeThisTick[at - 1],
              _filledThisTick[at - 1],
            )) {
          at--;
        }
        _filledThisTick.insert(at, c);
        _fillTimeThisTick.insert(at, fillTime);
      }
    }
    for (var i = 0; i < _filledThisTick.length; i++) {
      _readyQueue.addLast(_filledThisTick[i].id);
    }
    _filledThisTick.clear();
    _fillTimeThisTick.clear();

    if (_activeActorId == null) {
      _popValidReadyActor();
    }
  }

  /// Advances the timeline to the next ready actor and makes them
  /// [activeActorId], returning their state (or `null` if no living unstunned
  /// actors exist or ATB gauges are still filling).
  TurnCombatantState? nextTurn() {
    if (_activeActorId != null) {
      final current = findCombatant(_activeActorId!);
      if (current != null && _canAct(current)) {
        return current;
      }
      _activeActorId = null;
    }

    switch (mode) {
      case BattleTurnMode.roundPriority:
        final popped = _popValidReadyActor();
        if (popped != null) {
          return popped;
        }
        final eligible = _combatants.where(_canAct).toList();
        if (eligible.isEmpty) {
          return null;
        }
        _roundIndex++;
        eligible.sort((a, b) {
          final prioCmp = b.roundPriorityBonus.compareTo(a.roundPriorityBonus);
          if (prioCmp != 0) {
            return prioCmp;
          }
          final agiCmp = b.agility.compareTo(a.agility);
          if (agiCmp != 0) {
            return agiCmp;
          }
          return a.tieBreakOrder.compareTo(b.tieBreakOrder);
        });
        for (final c in eligible) {
          _readyQueue.addLast(c.id);
        }
        return _popValidReadyActor();

      case BattleTurnMode.activeTimeBattle:
        return _popValidReadyActor();

      case BattleTurnMode.conditionalTurnBased:
        TurnCombatantState? best;
        for (var i = 0; i < _combatants.length; i++) {
          final c = _combatants[i];
          if (!_canAct(c)) {
            continue;
          }
          if (best == null || _compareCtb(c, best) < 0) {
            best = c;
          }
        }
        if (best == null) {
          return null;
        }
        final dtAv = math.max(0.0, best.ctbActionValue);
        if (dtAv > 0.0) {
          _timelineClock += dtAv;
          for (var i = 0; i < _combatants.length; i++) {
            final c = _combatants[i];
            if (_canAct(c)) {
              c.ctbActionValue = math.max(0.0, c.ctbActionValue - dtAv);
            }
          }
        }
        _activeActorId = best.id;
        return best;
    }
  }

  /// Completes the current [activeActorId]'s turn, applying skill recovery
  /// [delayMultiplier] (`0.5` quick skill, `1.0` standard, `1.8` heavy ult) and
  /// [flatDelay] in CTB mode or resetting their ATB gauge.
  void commitTurn({
    double delayMultiplier = 1.0,
    double flatDelay = 0.0,
  }) {
    final actorId = _activeActorId;
    if (actorId == null) {
      return;
    }
    _activeActorId = null;
    isCommandMenuOpen = false;
    final actor = findCombatant(actorId);
    if (actor == null) {
      return;
    }

    switch (mode) {
      case BattleTurnMode.roundPriority:
        break;
      case BattleTurnMode.activeTimeBattle:
        actor.atbGauge = 0.0;
        _popValidReadyActor();
      case BattleTurnMode.conditionalTurnBased:
        final effMult = math.max(0.05, delayMultiplier);
        actor.ctbActionValue = math.max(
          1.0,
          (ctbBaseActionConstant * effMult) / actor.agility + flatDelay,
        );
    }
  }

  /// Pushes back (or pulls forward if negative) a target's CTB action value
  /// (for example `Delay Buster` or `Quick Step` support skills).
  void shiftActionValue(String targetId, double deltaActionValue) {
    final target = findCombatant(targetId);
    if (target == null) {
      return;
    }
    target.ctbActionValue = math.max(
      0.0,
      target.ctbActionValue + deltaActionValue,
    );
  }

  /// Pure, non-mutating forecast returning the next [count] actor IDs in turn
  /// order.
  ///
  /// When [hypotheticalActorId] is supplied (typically [activeActorId] while
  /// hovering over a quick vs heavy skill in the UI), simulates committing
  /// that actor's current turn with [hypotheticalDelayMultiplier] and
  /// [hypotheticalFlatDelay] **without mutating any live combatant field**.
  List<String> previewTurnOrder(
    int count, {
    String? hypotheticalActorId,
    double hypotheticalDelayMultiplier = 1.0,
    double hypotheticalFlatDelay = 0.0,
  }) {
    if (count <= 0 || _combatants.isEmpty) {
      return const <String>[];
    }

    final eligibleIndices = <int>[];
    for (var i = 0; i < _combatants.length; i++) {
      if (_canAct(_combatants[i])) {
        eligibleIndices.add(i);
      }
    }
    if (eligibleIndices.isEmpty) {
      return const <String>[];
    }

    final result = <String>[];

    if (mode == BattleTurnMode.roundPriority) {
      if (_activeActorId != null && hypotheticalActorId == null) {
        final act = findCombatant(_activeActorId!);
        if (act != null && _canAct(act)) {
          result.add(act.id);
        }
      }
      for (final queuedId in _readyQueue) {
        if (result.length >= count) {
          return result;
        }
        final c = findCombatant(queuedId);
        if (c != null && _canAct(c)) {
          result.add(c.id);
        }
      }
      final sorted = eligibleIndices.map((idx) => _combatants[idx]).toList()
        ..sort((a, b) {
          final p = b.roundPriorityBonus.compareTo(a.roundPriorityBonus);
          if (p != 0) {
            return p;
          }
          final ag = b.agility.compareTo(a.agility);
          if (ag != 0) {
            return ag;
          }
          return a.tieBreakOrder.compareTo(b.tieBreakOrder);
        });
      while (result.length < count) {
        for (final c in sorted) {
          result.add(c.id);
          if (result.length >= count) {
            break;
          }
        }
      }
      return result;
    }

    if (mode == BattleTurnMode.activeTimeBattle) {
      final n = eligibleIndices.length;
      final simGauges = List<double>.generate(
        n,
        (k) => _combatants[eligibleIndices[k]].atbGauge,
      );
      if (_activeActorId != null) {
        if (hypotheticalActorId == _activeActorId) {
          final k = eligibleIndices.indexWhere(
            (idx) => _combatants[idx].id == _activeActorId,
          );
          if (k >= 0) {
            simGauges[k] = 0.0;
          }
        } else {
          result.add(_activeActorId!);
        }
      }
      for (final queuedId in _readyQueue) {
        if (result.length >= count) {
          return result;
        }
        final k = eligibleIndices.indexWhere(
          (idx) => _combatants[idx].id == queuedId,
        );
        if (k >= 0) {
          result.add(queuedId);
          simGauges[k] = 0.0;
        }
      }
      while (result.length < count) {
        var bestK = 0;
        var bestTime = double.infinity;
        for (var k = 0; k < n; k++) {
          final c = _combatants[eligibleIndices[k]];
          final rate = atbBaseFillRate * math.sqrt(c.agility / 10.0);
          final rem = math.max(0.0, maxAtbGauge - simGauges[k]);
          final t = rem / rate;
          if (t < bestTime - 1e-9 ||
              ((t - bestTime).abs() <= 1e-9 &&
                  c.tieBreakOrder <
                      _combatants[eligibleIndices[bestK]].tieBreakOrder)) {
            bestTime = t;
            bestK = k;
          }
        }
        for (var k = 0; k < n; k++) {
          final c = _combatants[eligibleIndices[k]];
          final rate = atbBaseFillRate * math.sqrt(c.agility / 10.0);
          simGauges[k] = math.min(maxAtbGauge, simGauges[k] + rate * bestTime);
        }
        result.add(_combatants[eligibleIndices[bestK]].id);
        simGauges[bestK] = 0.0;
      }
      return result;
    }

    // CTB pure simulation on local scratch list:
    final n = eligibleIndices.length;
    final simAv = List<double>.generate(
      n,
      (k) => _combatants[eligibleIndices[k]].ctbActionValue,
    );

    if (_activeActorId != null) {
      final activeK = eligibleIndices.indexWhere(
        (idx) => _combatants[idx].id == _activeActorId,
      );
      if (activeK >= 0) {
        if (hypotheticalActorId == _activeActorId) {
          final actor = _combatants[eligibleIndices[activeK]];
          final effMult = math.max(0.05, hypotheticalDelayMultiplier);
          simAv[activeK] = math.max(
            1.0,
            (ctbBaseActionConstant * effMult) / actor.agility +
                hypotheticalFlatDelay,
          );
        } else {
          result.add(_activeActorId!);
          final actor = _combatants[eligibleIndices[activeK]];
          simAv[activeK] = math.max(1.0, ctbBaseActionConstant / actor.agility);
        }
      }
    } else if (hypotheticalActorId != null) {
      // Allow hypothetical preview before nextTurn() is popped as well.
      final hypK = eligibleIndices.indexWhere(
        (idx) => _combatants[idx].id == hypotheticalActorId,
      );
      if (hypK >= 0 && simAv[hypK] <= 1e-9) {
        final actor = _combatants[eligibleIndices[hypK]];
        final effMult = math.max(0.05, hypotheticalDelayMultiplier);
        simAv[hypK] = math.max(
          1.0,
          (ctbBaseActionConstant * effMult) / actor.agility +
              hypotheticalFlatDelay,
        );
      }
    }

    while (result.length < count) {
      var bestK = 0;
      for (var k = 1; k < n; k++) {
        final avDiff = simAv[k] - simAv[bestK];
        if (avDiff < -1e-9) {
          bestK = k;
        } else if (avDiff.abs() <= 1e-9) {
          final a = _combatants[eligibleIndices[k]];
          final b = _combatants[eligibleIndices[bestK]];
          final agCmp = b.agility.compareTo(a.agility);
          if (agCmp < 0 || (agCmp == 0 && a.tieBreakOrder < b.tieBreakOrder)) {
            bestK = k;
          }
        }
      }

      final stepAv = math.max(0.0, simAv[bestK]);
      if (stepAv > 0.0) {
        for (var k = 0; k < n; k++) {
          simAv[k] = math.max(0.0, simAv[k] - stepAv);
        }
      }
      final chosen = _combatants[eligibleIndices[bestK]];
      result.add(chosen.id);

      final isHypothetical =
          chosen.id == hypotheticalActorId && result.length == 1;
      final mult = isHypothetical
          ? math.max(0.05, hypotheticalDelayMultiplier)
          : 1.0;
      final flat = isHypothetical ? hypotheticalFlatDelay : 0.0;
      simAv[bestK] = math.max(
        1.0,
        (ctbBaseActionConstant * mult) / chosen.agility + flat,
      );
    }

    return result;
  }

  TurnCombatantState? _popValidReadyActor() {
    while (_readyQueue.isNotEmpty) {
      final candidateId = _readyQueue.removeFirst();
      final c = findCombatant(candidateId);
      if (c != null && _canAct(c)) {
        _activeActorId = c.id;
        return c;
      }
    }
    return null;
  }

  static int _compareCtb(TurnCombatantState a, TurnCombatantState b) {
    final diff = a.ctbActionValue - b.ctbActionValue;
    if (diff < -1e-9) {
      return -1;
    }
    if (diff > 1e-9) {
      return 1;
    }
    final agiCmp = b.agility.compareTo(a.agility);
    if (agiCmp != 0) {
      return agiCmp;
    }
    return a.tieBreakOrder.compareTo(b.tieBreakOrder);
  }
}
