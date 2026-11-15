import 'dart:math' as math;
import 'dart:typed_data';

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
