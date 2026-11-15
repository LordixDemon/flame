import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame/src/math/seeded_rng.dart';

/// Level-based progression curve mapping character level (`1..maxLevel`) to a
/// base attribute value.
class const StatCurve._(this._values, {required this.maxLevel}) {
  /// Creates a [StatCurve] backed by an explicit lookup table (`index 0` =
  /// level `1`).
  factory StatCurve.table(List<double> valuesByLevel) {
    assert(valuesByLevel.isNotEmpty, 'valuesByLevel cannot be empty.');
    return StatCurve._(
      Float64List.fromList(valuesByLevel),
      maxLevel: valuesByLevel.length,
    );
  }

  /// Creates a smooth polynomial growth curve between [level1Value] and
  /// [maxLevelValue] across `1..[maxLevel]`.
  factory StatCurve.polynomial({
    required double level1Value,
    required double maxLevelValue,
    int maxLevel = 99,
    double exponent = 1.0,
  }) {
    assert(maxLevel >= 1, 'maxLevel must be >= 1.');
    assert(exponent > 0.0, 'exponent must be > 0.');
    final table = Float64List(maxLevel);
    if (maxLevel == 1) {
      table[0] = level1Value;
    } else {
      final span = maxLevel - 1;
      for (var i = 0; i < maxLevel; i++) {
        final t = i / span;
        table[i] =
            level1Value +
            (maxLevelValue - level1Value) * math.pow(t, exponent).toDouble();
      }
    }
    return StatCurve._(table, maxLevel: maxLevel);
  }

  final Float64List _values;

  /// Maximum level defined on this curve.
  final int maxLevel;

  /// Evaluates the base stat value at [level] (clamped to `1..maxLevel`).
  double valueAtLevel(int level) {
    final idx = (level - 1).clamp(0, _values.length - 1);
    return _values[idx];
  }
}

/// Evaluation stage for a [StatModifier] inside [AttributeSet].
///
/// Pipeline order:
/// `((base + sum(flatAdd)) * (1 + sum(percentAdd))) * prod(percentMul)`
/// followed by highest-priority `finalOverride` (if any) and `[min, max]`
/// clamping.
enum StatModifierOp() {
  /// Added directly to the base attribute (`+15 ATK`).
  flatAdd,

  /// Summed additively as a percentage multiplier (`+0.20` = `+20%`).
  percentAdd,

  /// Multiplied independently after additive percentages (`0.5` = half,
  /// `1.5` = `1.5x`).
  percentMul,

  /// Overrides the computed attribute value (for example petrify forcing
  /// `SPD = 0` or super-armor locking `DEF = 999`).
  finalOverride,
}

/// Immutable attribute modifier contributed by equipment, passives, or buffs.
class const StatModifier({
  required this.id,
  required this.statId,
  required this.op,
  required this.value,
  this.sourceId = '',
  this.priority = 0,
}) {
  /// Unique identifier of this modifier instance.
  final String id;

  /// Target attribute name (e.g. `'atk'`, `'def'`, `'maxHp'`, `'critRate'`).
  final String statId;

  /// Mathematical stage at which [value] applies.
  final StatModifierOp op;

  /// Numerical operand for [op].
  final double value;

  /// Optional grouping tag (e.g. `'equip:mainHand'` or `'status:haste'`) used
  /// by [AttributeSet.removeModifiersBySource].
  final String sourceId;

  /// Tie-breaker priority for [StatModifierOp.finalOverride] (higher wins).
  final int priority;

  /// Returns a scaled copy with `value * factor` (for stacking buffs).
  StatModifier scaled(double factor, {String? newId, String? newSourceId}) =>
      StatModifier(
        id: newId ?? id,
        statId: statId,
        op: op,
        value: value * factor,
        sourceId: newSourceId ?? sourceId,
        priority: priority,
      );
}

class _StatBounds(this.min, this.max) {
  final double min;
  final double max;
}

/// Hierarchical Gameplay-Ability-System (GAS) attribute container with per-stat
/// dirty caching.
class AttributeSet() {
  final Map<String, double> _baseValues = <String, double>{};
  final Map<String, StatCurve> _curves = <String, StatCurve>{};
  final Map<String, _StatBounds> _bounds = <String, _StatBounds>{};
  final Map<String, List<StatModifier>> _modifiersByStat =
      <String, List<StatModifier>>{};
  final Map<String, double> _cachedFinal = <String, double>{};
  final Set<String> _dirtyStats = <String>{};

  int _level = 1;
  int _version = 0;
  int _recalculationCount = 0;

  /// Current character level driving registered [StatCurve]s.
  int get level => _level;

  /// Monotonically incremented whenever base values, level, or modifiers
  /// mutate.
  int get version => _version;

  /// Diagnostic count of stat pipeline evaluations performed since creation or
  /// [resetDiagnostics].
  int get recalculationCount => _recalculationCount;

  /// Resets [recalculationCount] to `0` for benchmarking / unit tests.
  void resetDiagnostics() {
    _recalculationCount = 0;
  }

  /// Registers a growth [curve] for [statId] and updates its base value for
  /// the current [level].
  void setCurve(String statId, StatCurve curve) {
    _curves[statId] = curve;
    _baseValues[statId] = curve.valueAtLevel(_level);
    _markDirty(statId);
  }

  /// Updates [level] and refreshes all curve-backed base attributes.
  void setLevel(int newLevel) {
    final clamped = math.max(1, newLevel);
    if (_level == clamped) {
      return;
    }
    _level = clamped;
    for (final entry in _curves.entries) {
      _baseValues[entry.key] = entry.value.valueAtLevel(_level);
      _dirtyStats.add(entry.key);
    }
    _version++;
  }

  /// Sets the explicit base value of [statId].
  void setBase(String statId, double value) {
    if (_baseValues[statId] == value) {
      return;
    }
    _baseValues[statId] = value;
    _markDirty(statId);
  }

  /// Queries the unmodified base value of [statId] (`0.0` if unregistered).
  double getBase(String statId) => _baseValues[statId] ?? 0.0;

  /// Configures `[min, max]` clamping bounds for [statId].
  void setBounds(
    String statId, {
    double min = double.negativeInfinity,
    double max = double.infinity,
  }) {
    assert(min <= max, 'min must be <= max.');
    _bounds[statId] = _StatBounds(min, max);
    _markDirty(statId);
  }

  /// Adds or replaces (by [StatModifier.id]) a [modifier].
  void addModifier(StatModifier modifier) {
    final list = _modifiersByStat.putIfAbsent(
      modifier.statId,
      () => <StatModifier>[],
    );
    list.removeWhere((m) => m.id == modifier.id);
    list.add(modifier);
    _markDirty(modifier.statId);
  }

  /// Removes a modifier with [modifierId] across all stats, returning `true` if
  /// found.
  bool removeModifierById(String modifierId) {
    var removedAny = false;
    for (final entry in _modifiersByStat.entries) {
      final before = entry.value.length;
      entry.value.removeWhere((m) => m.id == modifierId);
      if (entry.value.length != before) {
        _dirtyStats.add(entry.key);
        removedAny = true;
      }
    }
    if (removedAny) {
      _version++;
    }
    return removedAny;
  }

  /// Removes all modifiers tagged with [sourceId], returning the number of
  /// removed modifiers.
  int removeModifiersBySource(String sourceId) {
    var removedCount = 0;
    for (final entry in _modifiersByStat.entries) {
      final before = entry.value.length;
      entry.value.removeWhere((m) => m.sourceId == sourceId);
      final delta = before - entry.value.length;
      if (delta > 0) {
        removedCount += delta;
        _dirtyStats.add(entry.key);
      }
    }
    if (removedCount > 0) {
      _version++;
    }
    return removedCount;
  }

  /// Evaluates (or returns cached) final value for [statId].
  double get(String statId) {
    if (!_dirtyStats.contains(statId) && _cachedFinal.containsKey(statId)) {
      return _cachedFinal[statId]!;
    }
    _dirtyStats.remove(statId);
    _recalculationCount++;

    final base = _baseValues[statId] ?? 0.0;
    final mods = _modifiersByStat[statId];
    var result = base;

    if (mods != null && mods.isNotEmpty) {
      var flatSum = 0.0;
      var pctAddSum = 0.0;
      var pctMulProd = 1.0;
      StatModifier? winningOverride;

      for (var i = 0; i < mods.length; i++) {
        final m = mods[i];
        switch (m.op) {
          case StatModifierOp.flatAdd:
            flatSum += m.value;
          case StatModifierOp.percentAdd:
            pctAddSum += m.value;
          case StatModifierOp.percentMul:
            pctMulProd *= m.value;
          case StatModifierOp.finalOverride:
            if (winningOverride == null ||
                m.priority > winningOverride.priority ||
                (m.priority == winningOverride.priority &&
                    m.id.compareTo(winningOverride.id) >= 0)) {
              winningOverride = m;
            }
        }
      }

      if (winningOverride != null) {
        result = winningOverride.value;
      } else {
        result = (base + flatSum) * (1.0 + pctAddSum) * pctMulProd;
      }
    }

    final bound = _bounds[statId];
    if (bound != null) {
      result = result.clamp(bound.min, bound.max);
    }
    if (result.isNaN || result.isInfinite) {
      result = 0.0;
    }
    _cachedFinal[statId] = result;
    return result;
  }

  /// All known stat identifiers across bases and modifiers.
  Iterable<String> get statIds => <String>{
    ..._baseValues.keys,
    ..._modifiersByStat.keys,
  };

  /// Creates a deep copy of this [AttributeSet] for hypothetical stat diff
  /// previews without mutating live combatant attributes.
  AttributeSet clone() {
    final copy = AttributeSet().._level = _level;
    copy._baseValues.addAll(_baseValues);
    copy._curves.addAll(_curves);
    copy._bounds.addAll(_bounds);
    for (final entry in _modifiersByStat.entries) {
      copy._modifiersByStat[entry.key] = List<StatModifier>.of(entry.value);
    }
    copy._dirtyStats.addAll(copy.statIds);
    return copy;
  }

  void _markDirty(String statId) {
    _dirtyStats.add(statId);
    _version++;
  }
}

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
          // Replace the instance closest to expiring.
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

    // If this newly applied buff grants immunities, purge newly-resisted
    // ailments immediately!
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

// ============================================================================
// AOT-Safe Bytecode FormulaVM (RPG Maker `a.atk * 4 - b.def * 2` & beyond)
// ============================================================================

enum _FormulaOp(this.code) {
  pushConst(0),
  loadAttackerStat(1),
  loadDefenderStat(2),
  loadWorldVar(3),
  loadContextVar(4),
  neg(5),
  not(6),
  add(7),
  sub(8),
  mul(9),
  div(10),
  mod(11),
  lt(12),
  le(13),
  gt(14),
  ge(15),
  eq(16),
  ne(17),
  and(18),
  or(19),
  fnAbs(20),
  fnFloor(21),
  fnCeil(22),
  fnRound(23),
  fnSqrt(24),
  fnMin(25),
  fnMax(26),
  fnPow(27),
  fnClamp(28),
  fnLerp(29),
  fnIf(30);

  final int code;
}

enum _TokKind() {
  number,
  ident,
  lParen,
  rParen,
  comma,
  op,
}

class _Token(this.kind, this.lexeme, [this.numValue = 0.0]) {
  final _TokKind kind;
  final String lexeme;
  final double numValue;
}

/// Pre-compiled, immutable RPN bytecode program produced by [FormulaVM.compile]
/// for zero-allocation combat damage, healing, hit-chance, and AI utility
/// scoring.
class CompiledFormula._({
  required this.source,
  required this._opcodes,
  required this._operands,
  required this._constants,
  required this._symbols,
}) {
  /// Original human-readable formula string.
  final String source;

  final Int32List _opcodes;
  final Int32List _operands;
  final Float64List _constants;
  final List<String> _symbols;

  /// Number of bytecode instructions in this compiled formula.
  int get instructionCount => _opcodes.length;
}

/// AOT-safe mathematical & RPG combat expression compiler and zero-allocation
/// stack machine.
///
/// Supported syntax:
/// - Scoped attributes: `a.atk`, `b.def` (`attacker` / `defender`
///   [AttributeSet]s)
/// - World variables: `v[10]` or `v.10`
/// - Context bindings: `level`, `power`, `combo`, etc.
/// - Operators: unary `-`, `!`, binary `* / %`, `+ -`, `< <= > >=`, `== !=`,
///   `&&`, `||`
/// - Functions: `abs`, `floor`, `ceil`, `round`, `sqrt`, `min`, `max`, `pow`,
///   `clamp`, `lerp`, `if(cond, thenExpr, elseExpr)`
/// - Safe division/modulo by zero (`0.0`) and `NaN`/`Infinity` clamping.
class FormulaVM({int stackCapacity = 64}) {
  Float64List _stack = Float64List(math.max(16, stackCapacity));

  /// Compiles [expression] into a reusable [CompiledFormula], throwing
  /// [FormatException] on syntax or arity errors.
  static CompiledFormula compile(String expression) {
    final tokens = _tokenize(expression);
    if (tokens.isEmpty) {
      throw const FormatException('Formula expression cannot be empty.');
    }

    final opcodes = <int>[];
    final operands = <int>[];
    final constants = <double>[];
    final symbols = <String>[];
    final symbolIndex = <String, int>{};

    int internSymbol(String s) => symbolIndex.putIfAbsent(s, () {
      symbols.add(s);
      return symbols.length - 1;
    });

    void emit(_FormulaOp op, [int operand = 0]) {
      opcodes.add(op.code);
      operands.add(operand);
    }

    // Recursive-descent Pratt / precedence-climbing parser guarantees exact
    // unary minus, function arity, and parentheses validation!
    var cursor = 0;

    _Token? peek() => cursor < tokens.length ? tokens[cursor] : null;
    _Token consume() => tokens[cursor++];

    void parseExpr(int minPrec) {
      // Prefix / primary atom
      final tok = peek();
      if (tok == null) {
        throw FormatException(
          'Unexpected end of formula in "$expression".',
        );
      }

      if (tok.kind == _TokKind.number) {
        consume();
        final cIdx = constants.length;
        constants.add(tok.numValue);
        emit(_FormulaOp.pushConst, cIdx);
      } else if (tok.kind == _TokKind.op &&
          (tok.lexeme == '-' || tok.lexeme == '+' || tok.lexeme == '!')) {
        consume();
        // Unary prefix binds tighter than binary *, /, +, -
        parseExpr(70);
        if (tok.lexeme == '-') {
          emit(_FormulaOp.neg);
        } else if (tok.lexeme == '!') {
          emit(_FormulaOp.not);
        }
      } else if (tok.kind == _TokKind.lParen) {
        consume();
        parseExpr(0);
        final close = peek();
        if (close == null || close.kind != _TokKind.rParen) {
          throw FormatException('Missing closing ")" in "$expression".');
        }
        consume();
      } else if (tok.kind == _TokKind.ident) {
        consume();
        final ident = tok.lexeme;
        if (peek()?.kind == _TokKind.lParen) {
          // Function call!
          consume(); // '('
          final fnSpec = _lookupFunction(ident, expression);
          var argCount = 0;
          if (peek()?.kind != _TokKind.rParen) {
            while (true) {
              parseExpr(0);
              argCount++;
              if (peek()?.kind == _TokKind.comma) {
                consume();
              } else {
                break;
              }
            }
          }
          if (peek()?.kind != _TokKind.rParen) {
            throw FormatException(
              'Missing ")" after call to $ident in "$expression".',
            );
          }
          consume();
          if (argCount != fnSpec.arity) {
            throw FormatException(
              'Function "$ident" expects ${fnSpec.arity} arguments, '
              'got $argCount in "$expression".',
            );
          }
          emit(fnSpec.op);
        } else if (ident.startsWith('a.') && ident.length > 2) {
          emit(_FormulaOp.loadAttackerStat, internSymbol(ident.substring(2)));
        } else if (ident.startsWith('b.') && ident.length > 2) {
          emit(_FormulaOp.loadDefenderStat, internSymbol(ident.substring(2)));
        } else if (ident.startsWith('v[') && ident.endsWith(']')) {
          final idStr = ident.substring(2, ident.length - 1);
          final varId = int.tryParse(idStr);
          if (varId == null) {
            throw FormatException('Invalid variable index "$ident".');
          }
          emit(_FormulaOp.loadWorldVar, varId);
        } else if (ident.startsWith('v.') && ident.length > 2) {
          final varId = int.tryParse(ident.substring(2));
          if (varId == null) {
            throw FormatException('Invalid variable index "$ident".');
          }
          emit(_FormulaOp.loadWorldVar, varId);
        } else {
          emit(_FormulaOp.loadContextVar, internSymbol(ident));
        }
      } else {
        throw FormatException(
          'Unexpected token "${tok.lexeme}" in "$expression".',
        );
      }

      // Infix binary operators
      while (true) {
        final next = peek();
        if (next == null || next.kind != _TokKind.op) {
          break;
        }
        final bin = _binaryInfo(next.lexeme);
        if (bin == null || bin.prec < minPrec) {
          break;
        }
        consume();
        parseExpr(bin.prec + 1);
        emit(bin.op);
      }
    }

    parseExpr(0);
    if (cursor != tokens.length) {
      throw FormatException(
        'Unexpected trailing token "${tokens[cursor].lexeme}" '
        'in "$expression".',
      );
    }

    return CompiledFormula._(
      source: expression,
      opcodes: Int32List.fromList(opcodes),
      operands: Int32List.fromList(operands),
      constants: Float64List.fromList(constants),
      symbols: List<String>.unmodifiable(symbols),
    );
  }

  /// Evaluates [formula] with zero heap allocations.
  ///
  /// When [variance] `> 0.0` and [rng] is supplied, applies uniform RPG Maker
  /// damage spread in `[1.0 - variance, 1.0 + variance]`.
  double evaluate(
    CompiledFormula formula, {
    AttributeSet? attacker,
    AttributeSet? defender,
    double Function(int varId)? worldVariableLookup,
    Map<String, double>? contextVars,
    double variance = 0.0,
    SeededRng? rng,
    bool isCritical = false,
    double criticalMultiplier = 2.0,
    double? minResult,
    double? maxResult,
  }) {
    final ops = formula._opcodes;
    final args = formula._operands;
    final consts = formula._constants;
    final syms = formula._symbols;

    var sp = 0;
    void push(double v) {
      if (sp >= _stack.length) {
        final grown = Float64List(_stack.length * 2)
          ..setRange(0, _stack.length, _stack);
        _stack = grown;
      }
      _stack[sp++] = (v.isNaN || v.isInfinite) ? 0.0 : v;
    }

    for (var ip = 0; ip < ops.length; ip++) {
      final op = ops[ip];
      final arg = args[ip];
      switch (op) {
        case 0: // pushConst
          push(consts[arg]);
        case 1: // loadAttackerStat
          push(attacker?.get(syms[arg]) ?? 0.0);
        case 2: // loadDefenderStat
          push(defender?.get(syms[arg]) ?? 0.0);
        case 3: // loadWorldVar
          push(worldVariableLookup?.call(arg) ?? 0.0);
        case 4: // loadContextVar
          push(contextVars?[syms[arg]] ?? 0.0);
        case 5: // neg
          _stack[sp - 1] = -_stack[sp - 1];
        case 6: // not
          _stack[sp - 1] = _stack[sp - 1] == 0.0 ? 1.0 : 0.0;
        case 7: // add
          final b = _stack[--sp];
          _stack[sp - 1] = _sanitize(_stack[sp - 1] + b);
        case 8: // sub
          final b = _stack[--sp];
          _stack[sp - 1] = _sanitize(_stack[sp - 1] - b);
        case 9: // mul
          final b = _stack[--sp];
          _stack[sp - 1] = _sanitize(_stack[sp - 1] * b);
        case 10: // div
          final b = _stack[--sp];
          _stack[sp - 1] = b.abs() <= 1e-12
              ? 0.0
              : _sanitize(_stack[sp - 1] / b);
        case 11: // mod
          final b = _stack[--sp];
          _stack[sp - 1] = b.abs() <= 1e-12
              ? 0.0
              : _sanitize(_stack[sp - 1] % b);
        case 12: // lt
          final b = _stack[--sp];
          _stack[sp - 1] = _stack[sp - 1] < b ? 1.0 : 0.0;
        case 13: // le
          final b = _stack[--sp];
          _stack[sp - 1] = _stack[sp - 1] <= b ? 1.0 : 0.0;
        case 14: // gt
          final b = _stack[--sp];
          _stack[sp - 1] = _stack[sp - 1] > b ? 1.0 : 0.0;
        case 15: // ge
          final b = _stack[--sp];
          _stack[sp - 1] = _stack[sp - 1] >= b ? 1.0 : 0.0;
        case 16: // eq
          final b = _stack[--sp];
          _stack[sp - 1] = (_stack[sp - 1] - b).abs() <= 1e-9 ? 1.0 : 0.0;
        case 17: // ne
          final b = _stack[--sp];
          _stack[sp - 1] = (_stack[sp - 1] - b).abs() > 1e-9 ? 1.0 : 0.0;
        case 18: // and
          final b = _stack[--sp];
          _stack[sp - 1] = (_stack[sp - 1] != 0.0 && b != 0.0) ? 1.0 : 0.0;
        case 19: // or
          final b = _stack[--sp];
          _stack[sp - 1] = (_stack[sp - 1] != 0.0 || b != 0.0) ? 1.0 : 0.0;
        case 20: // fnAbs
          _stack[sp - 1] = _stack[sp - 1].abs();
        case 21: // fnFloor
          _stack[sp - 1] = _stack[sp - 1].floorToDouble();
        case 22: // fnCeil
          _stack[sp - 1] = _stack[sp - 1].ceilToDouble();
        case 23: // fnRound
          _stack[sp - 1] = _stack[sp - 1].roundToDouble();
        case 24: // fnSqrt
          final x = _stack[sp - 1];
          _stack[sp - 1] = x <= 0.0 ? 0.0 : _sanitize(math.sqrt(x));
        case 25: // fnMin
          final b = _stack[--sp];
          _stack[sp - 1] = math.min(_stack[sp - 1], b);
        case 26: // fnMax
          final b = _stack[--sp];
          _stack[sp - 1] = math.max(_stack[sp - 1], b);
        case 27: // fnPow
          final b = _stack[--sp];
          _stack[sp - 1] = _sanitize(math.pow(_stack[sp - 1], b).toDouble());
        case 28: // fnClamp
          final hi = _stack[--sp];
          final lo = _stack[--sp];
          final effLo = math.min(lo, hi);
          final effHi = math.max(lo, hi);
          _stack[sp - 1] = _stack[sp - 1].clamp(effLo, effHi);
        case 29: // fnLerp
          final t = _stack[--sp];
          final b = _stack[--sp];
          final a = _stack[sp - 1];
          _stack[sp - 1] = _sanitize(a + (b - a) * t);
        case 30: // fnIf
          final elseVal = _stack[--sp];
          final thenVal = _stack[--sp];
          final cond = _stack[sp - 1];
          _stack[sp - 1] = cond != 0.0 ? thenVal : elseVal;
      }
    }

    var result = sp > 0 ? _sanitize(_stack[0]) : 0.0;
    if (isCritical) {
      result = _sanitize(result * criticalMultiplier);
    }
    if (variance > 0.0 && rng != null) {
      final v = variance.clamp(0.0, 1.0);
      final factor = 1.0 - v + rng.nextDouble() * (2.0 * v);
      result = _sanitize(result * factor);
    }
    if (minResult != null && result < minResult) {
      result = minResult;
    }
    if (maxResult != null && result > maxResult) {
      result = maxResult;
    }
    return _sanitize(result);
  }

  static double _sanitize(double v) => (v.isNaN || v.isInfinite) ? 0.0 : v;

  static ({_FormulaOp op, int arity}) _lookupFunction(
    String name,
    String fullExpr,
  ) => switch (name) {
    'abs' => (op: _FormulaOp.fnAbs, arity: 1),
    'floor' => (op: _FormulaOp.fnFloor, arity: 1),
    'ceil' => (op: _FormulaOp.fnCeil, arity: 1),
    'round' => (op: _FormulaOp.fnRound, arity: 1),
    'sqrt' => (op: _FormulaOp.fnSqrt, arity: 1),
    'min' => (op: _FormulaOp.fnMin, arity: 2),
    'max' => (op: _FormulaOp.fnMax, arity: 2),
    'pow' => (op: _FormulaOp.fnPow, arity: 2),
    'clamp' => (op: _FormulaOp.fnClamp, arity: 3),
    'lerp' => (op: _FormulaOp.fnLerp, arity: 3),
    'if' => (op: _FormulaOp.fnIf, arity: 3),
    _ => throw FormatException(
      'Unknown formula function "$name" in "$fullExpr".',
    ),
  };

  static ({_FormulaOp op, int prec})? _binaryInfo(String lex) => switch (lex) {
    '||' => (op: _FormulaOp.or, prec: 10),
    '&&' => (op: _FormulaOp.and, prec: 20),
    '==' => (op: _FormulaOp.eq, prec: 30),
    '!=' => (op: _FormulaOp.ne, prec: 30),
    '<' => (op: _FormulaOp.lt, prec: 40),
    '<=' => (op: _FormulaOp.le, prec: 40),
    '>' => (op: _FormulaOp.gt, prec: 40),
    '>=' => (op: _FormulaOp.ge, prec: 40),
    '+' => (op: _FormulaOp.add, prec: 50),
    '-' => (op: _FormulaOp.sub, prec: 50),
    '*' => (op: _FormulaOp.mul, prec: 60),
    '/' => (op: _FormulaOp.div, prec: 60),
    '%' => (op: _FormulaOp.mod, prec: 60),
    _ => null,
  };

  static List<_Token> _tokenize(String src) {
    final out = <_Token>[];
    final len = src.length;
    var i = 0;

    bool isDigit(int c) => c >= 0x30 && c <= 0x39;
    bool isIdentStart(int c) =>
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F;
    bool isIdentPart(int c) => isIdentStart(c) || isDigit(c) || c == 0x2E;

    while (i < len) {
      final ch = src.codeUnitAt(i);
      if (ch == 0x20 || ch == 0x09 || ch == 0x0A || ch == 0x0D) {
        i++;
        continue;
      }
      if (isDigit(ch) ||
          (ch == 0x2E && i + 1 < len && isDigit(src.codeUnitAt(i + 1)))) {
        final start = i;
        var seenDot = false;
        while (i < len) {
          final c = src.codeUnitAt(i);
          if (isDigit(c)) {
            i++;
          } else if (c == 0x2E && !seenDot) {
            seenDot = true;
            i++;
          } else {
            break;
          }
        }
        final text = src.substring(start, i);
        final parsed = double.tryParse(text);
        if (parsed == null) {
          throw FormatException('Malformed number "$text" in "$src".');
        }
        out.add(_Token(_TokKind.number, text, parsed));
        continue;
      }

      if (isIdentStart(ch)) {
        final start = i;
        i++;
        while (i < len && isIdentPart(src.codeUnitAt(i))) {
          i++;
        }
        // Support `v[12]` bracket notation for world variables.
        if (i < len &&
            src.substring(start, i) == 'v' &&
            src.codeUnitAt(i) == 0x5B) {
          i++; // '['
          while (i < len && src.codeUnitAt(i) != 0x5D) {
            i++;
          }
          if (i >= len || src.codeUnitAt(i) != 0x5D) {
            throw FormatException('Unclosed v[...] in "$src".');
          }
          i++; // ']'
        }
        out.add(_Token(_TokKind.ident, src.substring(start, i)));
        continue;
      }

      if (ch == 0x28) {
        out.add(_Token(_TokKind.lParen, '('));
        i++;
        continue;
      }
      if (ch == 0x29) {
        out.add(_Token(_TokKind.rParen, ')'));
        i++;
        continue;
      }
      if (ch == 0x2C) {
        out.add(_Token(_TokKind.comma, ','));
        i++;
        continue;
      }

      // Two-character operators: <=, >=, ==, !=, &&, ||
      if (i + 1 < len) {
        final two = src.substring(i, i + 2);
        if (two == '<=' ||
            two == '>=' ||
            two == '==' ||
            two == '!=' ||
            two == '&&' ||
            two == '||') {
          out.add(_Token(_TokKind.op, two));
          i += 2;
          continue;
        }
      }

      final one = src[i];
      if (one == '+' ||
          one == '-' ||
          one == '*' ||
          one == '/' ||
          one == '%' ||
          one == '<' ||
          one == '>' ||
          one == '!') {
        out.add(_Token(_TokKind.op, one));
        i++;
        continue;
      }

      throw FormatException('Unexpected character "$one" in "$src".');
    }
    return out;
  }
}
