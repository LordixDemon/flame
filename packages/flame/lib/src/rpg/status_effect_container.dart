import 'dart:math' as math;

import 'package:flame/src/rpg/attribute_set.dart';

/// Stacking behavior when re-applying an existing [StatusEffectDef].
enum StatusStackPolicy() {
  /// Keeps `1` stack and resets remaining turn/step timers to maximum.
  refreshDuration,

  /// Increments stack count up to [StatusEffectDef.maxStacks] (scaling
  /// modifiers & periodic ticks) and refreshes duration.
  stackIntensity,

  /// Adds an independent instance with its own timer up to
  /// [StatusEffectDef.maxStacks].
  independentTimers,

  /// Retains only the single instance with the highest `potency` multiplier.
  highestOnly,
}

/// When a periodic status effect (DoT / HoT) emits a [StatusTickEvent].
enum StatusTickTrigger() {
  /// Never ticks periodically.
  none,

  /// Ticks at the beginning of the owner's turn.
  onTurnStart,

  /// Ticks at the end of the owner's turn.
  onTurnEnd,

  /// Ticks every `N` map steps walked outside combat.
  onMapStep,
}

/// Definition of a buff, debuff, ailment, or passive state.
class const StatusEffectDef({
  required this.id,
  this.stackPolicy = StatusStackPolicy.refreshDuration,
  this.maxStacks = 1,
  this.durationTurns = 0,
  this.durationSteps = 0,
  this.categoryMask = 0,
  this.grantedImmunityMask = 0,
  this.modifiers = const <StatModifier>[],
  this.tickTrigger = StatusTickTrigger.none,
  this.stepsPerTick = 1,
  this.periodicDeltaPerStack = 0.0,
}) {
  this
    : assert(maxStacks >= 1, 'maxStacks must be >= 1.'),
      assert(stepsPerTick >= 1, 'stepsPerTick must be >= 1.');

  /// Unique status effect identifier (e.g. `'poison'`, `'haste'`, `'vaccine'`).
  final String id;

  /// Re-application stacking policy.
  final StatusStackPolicy stackPolicy;

  /// Maximum stacks or simultaneous independent instances.
  final int maxStacks;

  /// Turn duration (`0` = does not expire by turns).
  final int durationTurns;

  /// Map-step duration (`0` = does not expire by footsteps).
  final int durationSteps;

  /// Bitmask of category/dispel tags (e.g. `debuff | poison | magic`).
  final int categoryMask;

  /// Bitmask of status categories this status grants immunity against while
  /// active (and purges on application).
  final int grantedImmunityMask;

  /// Attribute modifiers applied per stack / potency.
  final List<StatModifier> modifiers;

  /// Periodic DoT/HoT tick trigger.
  final StatusTickTrigger tickTrigger;

  /// Number of map footsteps per periodic map tick.
  final int stepsPerTick;

  /// Periodic HP/MP delta per stack (`< 0` poison damage, `> 0` regen heal).
  final double periodicDeltaPerStack;
}

/// Periodic DoT / HoT pulse emitted by [StatusEffectContainer].
class const StatusTickEvent({
  required this.statusId,
  required this.stacks,
  required this.delta,
}) {
  /// Identifier of the ticking [StatusEffectDef].
  final String statusId;

  /// Active stack count when the tick fired.
  final int stacks;

  /// Total computed periodic delta
  /// (`periodicDeltaPerStack * stacks * potency`).
  final double delta;
}

/// Live active status instance managed by [StatusEffectContainer].
class StatusEffectInstance({
  required this.instanceKey,
  required this.def,
  required this.stacks,
  required this.remainingTurns,
  required this.remainingSteps,
  this.potency = 1.0,
}) {
  /// Unique runtime key used for [AttributeSet] modifier ownership.
  final String instanceKey;

  /// Backing status definition.
  final StatusEffectDef def;

  /// Current stack count (`1..def.maxStacks`).
  int stacks;

  /// Remaining combat turns (`0` if non-expiring by turns).
  int remainingTurns;

  /// Remaining map footsteps (`0` if non-expiring by steps).
  int remainingSteps;

  /// Potency multiplier (used by [StatusStackPolicy.highestOnly]).
  double potency;

  int _stepAccumulator = 0;
}

/// Manages active buffs, debuffs, immunities, dispels, and turn/footstep ticks
/// bound to an [AttributeSet].
class StatusEffectContainer(this.attributes, {this.baseImmunityMask = 0}) {
  /// Target [AttributeSet] receiving modifiers from active statuses.
  final AttributeSet attributes;

  /// Innate category immunity bitmask (for example undead boss immune to
  /// `poison | instantDeath`).
  int baseImmunityMask;

  final List<StatusEffectInstance> _instances = <StatusEffectInstance>[];
  int _nextInstanceSerial = 1;

  /// Read-only view of active status instances.
  List<StatusEffectInstance> get activeInstances =>
      List<StatusEffectInstance>.unmodifiable(_instances);

  /// Combined innate + buff-granted immunity bitmask.
  int get effectiveImmunityMask {
    var mask = baseImmunityMask;
    for (var i = 0; i < _instances.length; i++) {
      mask |= _instances[i].def.grantedImmunityMask;
    }
    return mask;
  }

  /// Whether this container currently resists [def].
  bool isImmuneTo(StatusEffectDef def) =>
      def.categoryMask != 0 && (effectiveImmunityMask & def.categoryMask) != 0;

  /// Total active stacks of [statusId] across all instances.
  int stackCountOf(String statusId) {
    var sum = 0;
    for (var i = 0; i < _instances.length; i++) {
      if (_instances[i].def.id == statusId) {
        sum += _instances[i].stacks;
      }
    }
    return sum;
  }

  /// Whether at least one instance of [statusId] is active.
  bool hasStatus(String statusId) => stackCountOf(statusId) > 0;

  /// Attempts to apply [def] with optional [potency], returning `false` if
  /// blocked by immunity or a stronger [StatusStackPolicy.highestOnly] aura.
  bool apply(StatusEffectDef def, {double potency = 1.0, int stacks = 1}) {
    if (isImmuneTo(def)) {
      return false;
    }
    final addStacks = math.max(1, stacks);

    switch (def.stackPolicy) {
      case StatusStackPolicy.refreshDuration:
        final existing = _findFirst(def.id);
        if (existing != null) {
          existing
            ..remainingTurns = def.durationTurns
            ..remainingSteps = def.durationSteps
            ..potency = math.max(existing.potency, potency);
          _syncModifiers(existing);
        } else {
          _spawnInstance(def, stacks: 1, potency: potency);
        }

      case StatusStackPolicy.stackIntensity:
        final existing = _findFirst(def.id);
        if (existing != null) {
          existing
            ..stacks = math.min(def.maxStacks, existing.stacks + addStacks)
            ..remainingTurns = def.durationTurns
            ..remainingSteps = def.durationSteps
            ..potency = math.max(existing.potency, potency);
          _syncModifiers(existing);
        } else {
          _spawnInstance(
            def,
            stacks: math.min(def.maxStacks, addStacks),
            potency: potency,
          );
        }

      case StatusStackPolicy.independentTimers:
        final existingSame = _instances
            .where((inst) => inst.def.id == def.id)
            .toList();
        if (existingSame.length >= def.maxStacks) {
          existingSame.sort(
            (a, b) => a.remainingTurns.compareTo(b.remainingTurns),
          );
          _removeInstance(existingSame.first);
        }
        _spawnInstance(def, stacks: 1, potency: potency);

      case StatusStackPolicy.highestOnly:
        final existing = _findFirst(def.id);
        if (existing != null) {
          if (potency < existing.potency) {
            return false;
          }
          existing
            ..potency = potency
            ..remainingTurns = def.durationTurns
            ..remainingSteps = def.durationSteps;
          _syncModifiers(existing);
        } else {
          _spawnInstance(def, stacks: 1, potency: potency);
        }
    }

    if (def.grantedImmunityMask != 0) {
      dispelByMask(def.grantedImmunityMask);
    }
    return true;
  }

  /// Removes all instances of [statusId], returning the number removed.
  int removeById(String statusId) {
    var removed = 0;
    for (var i = _instances.length - 1; i >= 0; i--) {
      if (_instances[i].def.id == statusId) {
        _removeInstanceAt(i);
        removed++;
      }
    }
    return removed;
  }

  /// Dispels statuses matching [categoryMask] (up to optional [maxRemoved]),
  /// returning the number of dispelled status instances.
  int dispelByMask(int categoryMask, {int? maxRemoved}) {
    if (categoryMask == 0) {
      return 0;
    }
    var removed = 0;
    for (var i = _instances.length - 1; i >= 0; i--) {
      if (maxRemoved != null && removed >= maxRemoved) {
        break;
      }
      if ((_instances[i].def.categoryMask & categoryMask) != 0) {
        _removeInstanceAt(i);
        removed++;
      }
    }
    return removed;
  }

  /// Advances combat turn timers (`startOfTurn: true` or `false`) and returns
  /// emitted periodic [StatusTickEvent]s.
  List<StatusTickEvent> advanceTurn({required bool startOfTurn}) {
    final events = <StatusTickEvent>[];
    final targetTrigger = startOfTurn
        ? StatusTickTrigger.onTurnStart
        : StatusTickTrigger.onTurnEnd;

    for (var i = 0; i < _instances.length; i++) {
      final inst = _instances[i];
      if (inst.def.tickTrigger == targetTrigger &&
          inst.def.periodicDeltaPerStack != 0.0) {
        events.add(
          StatusTickEvent(
            statusId: inst.def.id,
            stacks: inst.stacks,
            delta: inst.def.periodicDeltaPerStack * inst.stacks * inst.potency,
          ),
        );
      }
    }

    if (!startOfTurn) {
      for (var i = _instances.length - 1; i >= 0; i--) {
        final inst = _instances[i];
        if (inst.def.durationTurns > 0) {
          inst.remainingTurns--;
          if (inst.remainingTurns <= 0) {
            _removeInstanceAt(i);
          }
        }
      }
    }
    return events;
  }

  /// Advances overworld/dungeon footstep counters by [steps] and returns
  /// emitted periodic [StatusTickEvent]s (e.g. map poison ticks).
  List<StatusTickEvent> advanceMapSteps(int steps) {
    if (steps <= 0 || _instances.isEmpty) {
      return const <StatusTickEvent>[];
    }
    final events = <StatusTickEvent>[];
    for (var i = _instances.length - 1; i >= 0; i--) {
      final inst = _instances[i];
      if (inst.def.tickTrigger == StatusTickTrigger.onMapStep &&
          inst.def.periodicDeltaPerStack != 0.0) {
        inst._stepAccumulator += steps;
        while (inst._stepAccumulator >= inst.def.stepsPerTick) {
          inst._stepAccumulator -= inst.def.stepsPerTick;
          events.add(
            StatusTickEvent(
              statusId: inst.def.id,
              stacks: inst.stacks,
              delta:
                  inst.def.periodicDeltaPerStack * inst.stacks * inst.potency,
            ),
          );
        }
      }
      if (inst.def.durationSteps > 0) {
        inst.remainingSteps -= steps;
        if (inst.remainingSteps <= 0) {
          _removeInstanceAt(i);
        }
      }
    }
    return events;
  }

  StatusEffectInstance? _findFirst(String id) {
    for (var i = 0; i < _instances.length; i++) {
      if (_instances[i].def.id == id) {
        return _instances[i];
      }
    }
    return null;
  }

  void _spawnInstance(
    StatusEffectDef def, {
    required int stacks,
    required double potency,
  }) {
    final key = 'status:${def.id}#${_nextInstanceSerial++}';
    final inst = StatusEffectInstance(
      instanceKey: key,
      def: def,
      stacks: stacks,
      remainingTurns: def.durationTurns,
      remainingSteps: def.durationSteps,
      potency: potency,
    );
    _instances.add(inst);
    _syncModifiers(inst);
  }

  void _syncModifiers(StatusEffectInstance inst) {
    attributes.removeModifiersBySource(inst.instanceKey);
    final scale = inst.stacks * inst.potency;
    for (var i = 0; i < inst.def.modifiers.length; i++) {
      final baseMod = inst.def.modifiers[i];
      final effective = baseMod.op == StatModifierOp.finalOverride
          ? StatModifier(
              id: '${inst.instanceKey}:$i',
              statId: baseMod.statId,
              op: baseMod.op,
              value: baseMod.value,
              sourceId: inst.instanceKey,
              priority: baseMod.priority,
            )
          : baseMod.scaled(
              scale,
              newId: '${inst.instanceKey}:$i',
              newSourceId: inst.instanceKey,
            );
      attributes.addModifier(effective);
    }
  }

  void _removeInstance(StatusEffectInstance inst) {
    final idx = _instances.indexOf(inst);
    if (idx >= 0) {
      _removeInstanceAt(idx);
    }
  }

  void _removeInstanceAt(int index) {
    final removed = _instances.removeAt(index);
    attributes.removeModifiersBySource(removed.instanceKey);
  }
}
