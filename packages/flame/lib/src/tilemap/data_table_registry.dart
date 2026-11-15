/// Foreign-key integrity constraint between two tables inside a
/// [DataTableRegistry].
class ForeignKeyRule<S>({
  required this.sourceTable,
  required this.targetTable,
  required this.fieldName,
  required this.extractTargetId,
  this.allowNullOrEmpty = true,
}) {
  final String sourceTable;
  final String targetTable;
  final String fieldName;
  final String? Function(S row) extractTargetId;
  final bool allowNullOrEmpty;
}

/// Typed, immutable, primary-key-indexed RPG database registry (modeling RPG
/// Maker's `Actors`, `Classes`, `Skills`, `Items`, `Weapons`, `Armors`,
/// `Enemies`, `States`, and `Tilesets` tables) with `O(1)` ID lookups and
/// deterministic foreign-key validation at load time.
class DataTableRegistry() {
  final Map<String, Map<String, Object>> _tables =
      <String, Map<String, Object>>{};
  final List<List<String> Function()> _fkCheckers = <List<String> Function()>[];

  /// Registers table [tableName] with rows indexed by [idOf].
  ///
  /// Throws [ArgumentError] immediately if duplicate primary keys exist.
  void registerTable<T extends Object>(
    String tableName,
    Iterable<T> rows, {
    required String Function(T row) idOf,
  }) {
    final map = <String, Object>{};
    for (final row in rows) {
      final id = idOf(row);
      if (map.containsKey(id)) {
        throw ArgumentError(
          'Duplicate primary key "$id" in table "$tableName"',
        );
      }
      map[id] = row;
    }
    _tables[tableName] = Map<String, Object>.unmodifiable(map);
  }

  /// Registers a foreign-key constraint checked by [validateForeignKeys].
  void addForeignKeyRule<S extends Object>(ForeignKeyRule<S> rule) {
    _fkCheckers.add(() {
      final errors = <String>[];
      final src = _tables[rule.sourceTable];
      final dst = _tables[rule.targetTable];
      if (src == null) {
        errors.add('Missing source table "${rule.sourceTable}"');
        return errors;
      }
      if (dst == null) {
        errors.add('Missing target table "${rule.targetTable}"');
        return errors;
      }
      src.forEach((srcId, row) {
        final targetId = rule.extractTargetId(row as S);
        if (targetId == null || targetId.isEmpty) {
          if (!rule.allowNullOrEmpty) {
            errors.add(
              '${rule.sourceTable}[$srcId].${rule.fieldName} is null/empty',
            );
          }
          return;
        }
        if (!dst.containsKey(targetId)) {
          errors.add(
            '${rule.sourceTable}[$srcId].${rule.fieldName} -> '
            'missing ${rule.targetTable}[$targetId]',
          );
        }
      });
      return errors;
    });
  }

  /// `O(1)` lookup by `[tableName]` and `[id]` (`null` if absent).
  T? tryGet<T extends Object>(String tableName, String id) {
    final obj = _tables[tableName]?[id];
    return obj is T ? obj : null;
  }

  /// `O(1)` required lookup throwing [StateError] when missing.
  T getRequired<T extends Object>(String tableName, String id) {
    final found = tryGet<T>(tableName, id);
    if (found == null) {
      throw StateError('Missing $T "$id" in table "$tableName"');
    }
    return found;
  }

  /// Returns all rows in [tableName] cast to `T`.
  Iterable<T> all<T extends Object>(String tableName) {
    final table = _tables[tableName];
    if (table == null) {
      return Iterable<T>.empty();
    }
    return table.values.whereType<T>();
  }

  /// Validates all registered [ForeignKeyRule]s and returns human-readable
  /// broken-reference diagnostics (`empty` when the database is valid).
  List<String> validateForeignKeys() {
    final violations = <String>[];
    for (var i = 0; i < _fkCheckers.length; i++) {
      violations.addAll(_fkCheckers[i]());
    }
    return violations;
  }
}
