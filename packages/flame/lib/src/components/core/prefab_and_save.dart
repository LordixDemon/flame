import 'dart:convert';
import 'dart:typed_data';

import 'package:flame/src/components/core/component.dart';

/// Reusable factory entry inside a [PrefabRegistry].
typedef PrefabFactory<T extends Component> = T Function(
  Map<String, Object?> params,
);

/// Declarative registry of reusable, parameterized [Component] prefabs.
class PrefabRegistry() {
  final Map<String, PrefabFactory<Component>> _factories =
      <String, PrefabFactory<Component>>{};
  final Map<String, Map<String, Object?>> _defaults =
      <String, Map<String, Object?>>{};

  /// Whether a prefab with [id] is registered.
  bool contains(String id) => _factories.containsKey(id);

  /// Registered prefab identifiers.
  Iterable<String> get ids => _factories.keys;

  /// Registers prefab [id] with [factory] and optional [defaultParams] merged
  /// beneath caller overrides on [instantiate].
  void register<T extends Component>(
    String id,
    PrefabFactory<T> factory, {
    Map<String, Object?> defaultParams = const <String, Object?>{},
  }) {
    _factories[id] = factory;
    _defaults[id] = Map<String, Object?>.unmodifiable(defaultParams);
  }

  /// Removes prefab [id] if registered.
  bool unregister(String id) {
    _defaults.remove(id);
    return _factories.remove(id) != null;
  }

  /// Instantiates prefab [id], merging [overrides] onto its `defaultParams`.
  T instantiate<T extends Component>(
    String id, [
    Map<String, Object?> overrides = const <String, Object?>{},
  ]) {
    final factory = _factories[id];
    if (factory == null) {
      throw StateError('Unknown prefab "$id"');
    }
    final defaults = _defaults[id]!;
    final merged = overrides.isEmpty
        ? defaults
        : (defaults.isEmpty
              ? overrides
              : <String, Object?>{...defaults, ...overrides});
    final created = factory(merged);
    if (created is! T) {
      throw StateError(
        'Prefab "$id" produced ${created.runtimeType}, expected $T',
      );
    }
    return created;
  }
}

/// Single deterministic schema upgrade step (`fromVersion -> fromVersion + 1`).
typedef SaveMigrationStep = Map<String, Object?> Function(
  Map<String, Object?> oldPayload,
);

/// Ordered chain of schema migrations upgrading historical save payloads up to
/// [currentVersion].
class SaveMigrationChain({required this.currentVersion}) {
  /// Target latest schema version (`>= 1`).
  final int currentVersion;

  final Map<int, SaveMigrationStep> _steps = <int, SaveMigrationStep>{};

  /// Registers a migration upgrading a payload from `fromVersion` to
  /// `fromVersion + 1`.
  void addStep(int fromVersion, SaveMigrationStep migrate) {
    if (fromVersion < 1 || fromVersion >= currentVersion) {
      throw RangeError.range(fromVersion, 1, currentVersion - 1, 'fromVersion');
    }
    _steps[fromVersion] = migrate;
  }

  /// Upgrades [payload] from [sourceVersion] up to [currentVersion].
  Map<String, Object?> migrateToCurrent(
    int sourceVersion,
    Map<String, Object?> payload,
  ) {
    if (sourceVersion > currentVersion) {
      throw FormatException(
        'Save version $sourceVersion is newer than supported $currentVersion',
      );
    }
    var current = Map<String, Object?>.of(payload);
    for (var v = sourceVersion; v < currentVersion; v++) {
      final step = _steps[v];
      if (step == null) {
        throw StateError(
          'Missing save migration step from v$v to v${v + 1}',
        );
      }
      current = step(current);
    }
    return current;
  }
}

/// Versioned, CRC32-checksummed snapshot serializer protecting game save states
/// and world snapshots from silent corruption while running automatic
/// [SaveMigrationChain] upgrades on load.
class StateSnapshotStore({required this.migrations}) {
  /// Schema migration chain applied when decoding older snapshots.
  final SaveMigrationChain migrations;

  static final Uint32List _crcTable = _buildCrc32Table();

  /// Encodes [payload] into a checksummed JSON envelope string.
  String encodeJsonEnvelope(Map<String, Object?> payload) {
    final canonicalBody = jsonEncode(payload);
    final crc = computeCrc32(utf8.encode(canonicalBody));
    return jsonEncode(<String, Object?>{
      'schemaVersion': migrations.currentVersion,
      'crc32': crc,
      'body': canonicalBody,
    });
  }

  /// Verifies CRC32 integrity of [envelopeJson], runs any needed schema
  /// migrations, and returns the upgraded payload map.
  Map<String, Object?> decodeJsonEnvelope(String envelopeJson) {
    final decoded = jsonDecode(envelopeJson);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Invalid snapshot envelope root');
    }
    final version = decoded['schemaVersion'];
    final expectedCrc = decoded['crc32'];
    final body = decoded['body'];
    if (version is! int || expectedCrc is! int || body is! String) {
      throw const FormatException('Malformed snapshot envelope header');
    }
    final actualCrc = computeCrc32(utf8.encode(body));
    if (actualCrc != expectedCrc) {
      throw FormatException(
        'Snapshot CRC32 mismatch (expected $expectedCrc, got $actualCrc)',
      );
    }
    final rawMap = jsonDecode(body);
    if (rawMap is! Map<String, Object?>) {
      throw const FormatException('Snapshot body must decode to a JSON object');
    }
    return migrations.migrateToCurrent(version, rawMap);
  }

  /// Standard IEEE 802.3 unsigned 32-bit CRC checksum.
  static int computeCrc32(List<int> bytes) {
    var crc = 0xFFFFFFFF;
    for (var i = 0; i < bytes.length; i++) {
      final idx = (crc ^ (bytes[i] & 0xFF)) & 0xFF;
      crc = (crc >>> 8) ^ _crcTable[idx];
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }

  static Uint32List _buildCrc32Table() {
    final table = Uint32List(256);
    for (var i = 0; i < 256; i++) {
      var c = i;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
      }
      table[i] = c & 0xFFFFFFFF;
    }
    return table;
  }
}
