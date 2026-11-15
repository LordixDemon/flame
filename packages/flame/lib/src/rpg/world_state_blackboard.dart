/// Callback invoked when a watched switch, variable, or self-switch mutates.
typedef BlackboardListener = void Function();

/// Persistent per-entity override record inside `WorldStateBlackboard`.
class MapEntityDelta({
  this.erased = false,
  this.col,
  this.row,
  this.elevation,
  this.facingIndex,
  Map<String, Object?>? extra,
}) {
  factory MapEntityDelta.fromJson(Map<String, Object?> json) {
    final rawExtra = json['extra'];
    return MapEntityDelta(
      erased: json['erased'] as bool? ?? false,
      col: (json['col'] as num?)?.toInt(),
      row: (json['row'] as num?)?.toInt(),
      elevation: (json['elevation'] as num?)?.toInt(),
      facingIndex: (json['facingIndex'] as num?)?.toInt(),
      extra: rawExtra is Map<String, Object?> ? rawExtra : null,
    );
  }

  bool erased;
  int? col;
  int? row;
  int? elevation;
  int? facingIndex;
  final Map<String, Object?> extra = extra != null
      ? Map<String, Object?>.of(extra)
      : <String, Object?>{};

  Map<String, Object?> toJson() => <String, Object?>{
    'erased': erased,
    if (col != null) 'col': col,
    if (row != null) 'row': row,
    if (elevation != null) 'elevation': elevation,
    if (facingIndex != null) 'facingIndex': facingIndex,
    if (extra.isNotEmpty) 'extra': extra,
  };
}

/// Reactive, snapshot-serializable RPG world state store combining:
/// - Bit-packed global boolean **Switches** (`Uint32List`, 30 bits per word for
///   JS/VM parity),
/// - Typed global **Variables** (`int`, `double`, `String`),
/// - Composite-key **Self-Switches** (`(mapId, eventId, channel)` -> `bool`),
/// - Persistent **Map Entity Deltas** (`erased`, moved coordinates, facing),
/// - Targeted `O(affected)` dependency subscriptions so flipping `Switch #12`
///   wakes ONLY event pages conditioned on `Switch #12`.
class WorldStateBlackboard({int initialSwitchCapacity = 256}) {
  static const int _bitsPerWord = 30;

  final List<int> _switchWords = List<int>.filled(
    (initialSwitchCapacity + _bitsPerWord - 1) ~/ _bitsPerWord,
    0,
    growable: true,
  );

  final Map<int, Object> _variables = <int, Object>{};
  final Map<String, bool> _selfSwitches = <String, bool>{};
  final Map<String, Map<String, MapEntityDelta>> _mapDeltas =
      <String, Map<String, MapEntityDelta>>{};

  final Map<int, Set<BlackboardListener>> _switchWatchers =
      <int, Set<BlackboardListener>>{};
  final Map<int, Set<BlackboardListener>> _variableWatchers =
      <int, Set<BlackboardListener>>{};
  final Map<String, Set<BlackboardListener>> _selfSwitchWatchers =
      <String, Set<BlackboardListener>>{};
  final Set<BlackboardListener> _globalWatchers = <BlackboardListener>{};

  int _version = 0;

  /// Monotonic mutation counter across all switches, variables, self-switches,
  /// and map deltas.
  int get version => _version;

  // --- Global Switches ---

  /// Reads boolean switch [switchId] (`>= 0`, defaults to `false`).
  bool getSwitch(int switchId) {
    if (switchId < 0) {
      return false;
    }
    final word = switchId ~/ _bitsPerWord;
    if (word >= _switchWords.length) {
      return false;
    }
    final bit = switchId % _bitsPerWord;
    return (_switchWords[word] & (1 << bit)) != 0;
  }

  /// Sets boolean switch [switchId] (`>= 0`), firing only watchers registered
  /// for [switchId] when its value changes.
  void setSwitch(int switchId, {required bool value}) {
    if (switchId < 0) {
      throw RangeError.value(switchId, 'switchId', 'Must be non-negative');
    }
    final word = switchId ~/ _bitsPerWord;
    while (word >= _switchWords.length) {
      _switchWords.add(0);
    }
    final mask = 1 << (switchId % _bitsPerWord);
    final prev = (_switchWords[word] & mask) != 0;
    if (prev == value) {
      return;
    }
    if (value) {
      _switchWords[word] |= mask;
    } else {
      _switchWords[word] &= ~mask;
    }
    _version++;
    _notifySet(_switchWatchers[switchId]);
    _notifySet(_globalWatchers);
  }

  // --- Global Variables ---

  /// Reads integer variable [varId] (`0` if unset or non-numeric).
  int getInt(int varId) {
    final v = _variables[varId];
    return v is num ? v.toInt() : 0;
  }

  /// Reads floating-point variable [varId] (`0.0` if unset or non-numeric).
  double getDouble(int varId) {
    final v = _variables[varId];
    return v is num ? v.toDouble() : 0.0;
  }

  /// Reads string variable [varId] (`''` if unset).
  String getString(int varId) {
    final v = _variables[varId];
    return v?.toString() ?? '';
  }

  /// Raw value of variable [varId] (`int`, `double`, `String`, or `null`).
  Object? getRawVariable(int varId) => _variables[varId];

  /// Sets numeric or string variable [varId] to [value].
  void setVariable(int varId, Object value) {
    if (value is! int && value is! double && value is! String) {
      throw ArgumentError.value(
        value,
        'value',
        'Variable must be int, double, or String',
      );
    }
    final prev = _variables[varId];
    if (prev == value) {
      return;
    }
    if (value == 0) {
      _variables.remove(varId);
    } else {
      _variables[varId] = value;
    }
    _version++;
    _notifySet(_variableWatchers[varId]);
    _notifySet(_globalWatchers);
  }

  /// Adds [delta] to integer variable [varId] and returns the updated value.
  int addInt(int varId, int delta) {
    final next = getInt(varId) + delta;
    setVariable(varId, next);
    return next;
  }

  // --- Self-Switches ---

  static String selfSwitchKey(String mapId, String eventId, String channel) =>
      '$mapId\x1F$eventId\x1F$channel';

  /// Reads local self-switch `(mapId, eventId, channel)` (`false` by default).
  bool getSelfSwitch(String mapId, String eventId, String channel) =>
      _selfSwitches[selfSwitchKey(mapId, eventId, channel)] ?? false;

  /// Sets local self-switch `(mapId, eventId, channel)`.
  void setSelfSwitch(
    String mapId,
    String eventId,
    String channel, {
    required bool value,
  }) {
    final k = selfSwitchKey(mapId, eventId, channel);
    final prev = _selfSwitches[k] ?? false;
    if (prev == value) {
      return;
    }
    if (value) {
      _selfSwitches[k] = true;
    } else {
      _selfSwitches.remove(k);
    }
    _version++;
    _notifySet(_selfSwitchWatchers[k]);
    _notifySet(_globalWatchers);
  }

  // --- Map Entity Deltas ---

  /// Returns or creates a mutable [MapEntityDelta] for `(mapId, entityId)` and
  /// bumps [version].
  MapEntityDelta upsertEntityDelta(String mapId, String entityId) {
    final mapBag = _mapDeltas.putIfAbsent(
      mapId,
      () => <String, MapEntityDelta>{},
    );
    final delta = mapBag.putIfAbsent(entityId, MapEntityDelta.new);
    _version++;
    _notifySet(_globalWatchers);
    return delta;
  }

  /// Looks up a recorded [MapEntityDelta] for `(mapId, entityId)`, or `null`.
  MapEntityDelta? getEntityDelta(String mapId, String entityId) =>
      _mapDeltas[mapId]?[entityId];

  /// Clears transient deltas for [mapId] (e.g. resetting puzzle boulders when
  /// leaving a dungeon room).
  void clearMapDeltas(String mapId) {
    if (_mapDeltas.remove(mapId) != null) {
      _version++;
      _notifySet(_globalWatchers);
    }
  }

  // --- Targeted Subscriptions ---

  void watchSwitch(int switchId, BlackboardListener listener) {
    _switchWatchers
        .putIfAbsent(switchId, () => <BlackboardListener>{})
        .add(
          listener,
        );
  }

  void unwatchSwitch(int switchId, BlackboardListener listener) {
    final s = _switchWatchers[switchId];
    if (s != null) {
      s.remove(listener);
      if (s.isEmpty) {
        _switchWatchers.remove(switchId);
      }
    }
  }

  void watchVariable(int varId, BlackboardListener listener) {
    _variableWatchers
        .putIfAbsent(varId, () => <BlackboardListener>{})
        .add(
          listener,
        );
  }

  void unwatchVariable(int varId, BlackboardListener listener) {
    final s = _variableWatchers[varId];
    if (s != null) {
      s.remove(listener);
      if (s.isEmpty) {
        _variableWatchers.remove(varId);
      }
    }
  }

  void watchSelfSwitch(
    String mapId,
    String eventId,
    String channel,
    BlackboardListener listener,
  ) {
    final k = selfSwitchKey(mapId, eventId, channel);
    _selfSwitchWatchers
        .putIfAbsent(k, () => <BlackboardListener>{})
        .add(
          listener,
        );
  }

  void unwatchSelfSwitch(
    String mapId,
    String eventId,
    String channel,
    BlackboardListener listener,
  ) {
    final k = selfSwitchKey(mapId, eventId, channel);
    final s = _selfSwitchWatchers[k];
    if (s != null) {
      s.remove(listener);
      if (s.isEmpty) {
        _selfSwitchWatchers.remove(k);
      }
    }
  }

  void addGlobalListener(BlackboardListener listener) =>
      _globalWatchers.add(listener);

  void removeGlobalListener(BlackboardListener listener) =>
      _globalWatchers.remove(listener);

  static void _notifySet(Set<BlackboardListener>? listeners) {
    if (listeners == null || listeners.isEmpty) {
      return;
    }
    final copy = List<BlackboardListener>.of(listeners, growable: false);
    for (var i = 0; i < copy.length; i++) {
      copy[i]();
    }
  }

  // --- Snapshot Serialization (compatible with StateSnapshotStore) ---

  Map<String, Object?> toJson() {
    final activeSwitches = <int>[];
    for (var w = 0; w < _switchWords.length; w++) {
      final word = _switchWords[w];
      if (word == 0) {
        continue;
      }
      for (var b = 0; b < _bitsPerWord; b++) {
        if ((word & (1 << b)) != 0) {
          activeSwitches.add(w * _bitsPerWord + b);
        }
      }
    }

    final varsJson = <String, Object?>{};
    _variables.forEach((k, v) {
      varsJson[k.toString()] = v;
    });

    final deltasJson = <String, Object?>{};
    _mapDeltas.forEach((mapId, entities) {
      final entJson = <String, Object?>{};
      entities.forEach((entId, delta) {
        entJson[entId] = delta.toJson();
      });
      deltasJson[mapId] = entJson;
    });

    return <String, Object?>{
      'switches': activeSwitches,
      'variables': varsJson,
      'selfSwitches': Map<String, Object?>.of(_selfSwitches),
      'mapDeltas': deltasJson,
    };
  }

  void loadFromJson(Map<String, Object?> json) {
    for (var i = 0; i < _switchWords.length; i++) {
      _switchWords[i] = 0;
    }
    _variables.clear();
    _selfSwitches.clear();
    _mapDeltas.clear();

    final rawSwitches = json['switches'];
    if (rawSwitches is List<Object?>) {
      for (final item in rawSwitches) {
        final id = (item! as num).toInt();
        if (id >= 0) {
          final word = id ~/ _bitsPerWord;
          while (word >= _switchWords.length) {
            _switchWords.add(0);
          }
          _switchWords[word] |= 1 << (id % _bitsPerWord);
        }
      }
    }

    final rawVars = json['variables'];
    if (rawVars is Map<Object?, Object?>) {
      rawVars.forEach((k, v) {
        final id = int.parse(k.toString());
        if (v is int) {
          _variables[id] = v;
        } else if (v is double) {
          _variables[id] = v;
        } else if (v is String) {
          _variables[id] = v;
        }
      });
    }

    final rawSelf = json['selfSwitches'];
    if (rawSelf is Map<Object?, Object?>) {
      rawSelf.forEach((k, v) {
        if (v == true) {
          _selfSwitches[k.toString()] = true;
        }
      });
    }

    final rawDeltas = json['mapDeltas'];
    if (rawDeltas is Map<Object?, Object?>) {
      rawDeltas.forEach((mapId, entities) {
        if (entities is Map<Object?, Object?>) {
          final mapBag = <String, MapEntityDelta>{};
          entities.forEach((entId, deltaMap) {
            if (deltaMap is Map<String, Object?>) {
              mapBag[entId.toString()] = MapEntityDelta.fromJson(deltaMap);
            }
          });
          _mapDeltas[mapId.toString()] = mapBag;
        }
      });
    }

    _version++;
    // Notify all watchers after bulk snapshot restore:
    for (final set in _switchWatchers.values) {
      _notifySet(set);
    }
    for (final set in _variableWatchers.values) {
      _notifySet(set);
    }
    for (final set in _selfSwitchWatchers.values) {
      _notifySet(set);
    }
    _notifySet(_globalWatchers);
  }
}
