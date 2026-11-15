import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flame/components.dart';
import 'package:flame/src/tilemap/chunked_tilemap_component.dart';
import 'package:flame/src/tilemap/tile_passage_grid.dart';
import 'package:flame/src/tilemap/world_portal_streamer.dart';

/// Spawn marker descriptor embedded in a [TileMapDocument].
class const TileMapEntitySpawn({
  required this.id,
  required this.prefabId,
  required this.x,
  required this.y,
  this.params = const <String, Object?>{},
}) {
  final String id;
  final String prefabId;
  final double x;
  final double y;
  final Map<String, Object?> params;
}

/// Single tile layer inside a [TileMapDocument].
class TileMapLayerData({
  required this.name,
  required this.cells,
  this.priority = 0,
  this.opacity = 1.0,
}) {
  final String name;
  final Uint32List cells;
  final int priority;
  final double opacity;
}

/// Zero-XML RPG/2D map document supporting both JSON (`encodeJson` /
/// `decodeJson`) and compact binary `DTMP` (`encodeBinary` / `decodeBinary`)
/// formats, plus automatic [ChunkedTilemapComponent], [TilePassageGrid],
/// [CameraZone], and [PrefabRegistry] instantiation.
class TileMapDocument({
  required this.mapId,
  required this.width,
  required this.height,
  required this.tileWidth,
  required this.tileHeight,
  required this.layers,
  Uint32List? groundPassageFlags,
  Uint32List? upperPassageFlags,
  this.spawns = const <TileMapEntitySpawn>[],
  this.cameraZones = const <CameraZone>[],
}) {
  static const int _binaryMagic = 0x44544D50; // 'DTMP'
  static const int _binaryVersion = 1;

  final String mapId;
  final int width;
  final int height;
  final double tileWidth;
  final double tileHeight;
  final List<TileMapLayerData> layers;
  final Uint32List groundPassageFlags =
      groundPassageFlags ??
      (Uint32List(width * height)
        ..fillRange(0, width * height, TilePassageFlags.passAll4));
  final Uint32List upperPassageFlags =
      upperPassageFlags ?? Uint32List(width * height);
  final List<TileMapEntitySpawn> spawns;
  final List<CameraZone> cameraZones;

  /// Builds a ready-to-use [TilePassageGrid] populated from this document.
  TilePassageGrid buildPassageGrid() {
    final grid = TilePassageGrid(width: width, height: height);
    final total = width * height;
    for (var i = 0; i < total; i++) {
      final c = i % width;
      final r = i ~/ width;
      if (i < groundPassageFlags.length) {
        grid.setFlags(c, r, groundPassageFlags[i]);
      }
      if (i < upperPassageFlags.length && upperPassageFlags[i] != 0) {
        grid.setFlags(c, r, upperPassageFlags[i], elevation: 1);
      }
    }
    return grid;
  }

  /// Builds [ChunkedTilemapComponent] layers bound to [tileset].
  List<ChunkedTilemapComponent> buildLayerComponents(
    TilesetAtlas tileset, {
    int chunkSize = 16,
  }) {
    return <ChunkedTilemapComponent>[
      for (final layer in layers)
        ChunkedTilemapComponent(
          tileset: tileset,
          mapWidth: width,
          mapHeight: height,
          tileDestWidth: tileWidth,
          tileDestHeight: tileHeight,
          chunkSize: chunkSize,
          opacity: layer.opacity,
          priority: layer.priority,
          initialCells: layer.cells,
        ),
    ];
  }

  /// Instantiates all [spawns] through [prefabs], positioning any resulting
  /// [PositionComponent] at `(spawn.x, spawn.y)` unless overridden by the
  /// prefab factory.
  List<Component> instantiateSpawns(PrefabRegistry prefabs) {
    final created = <Component>[];
    for (var i = 0; i < spawns.length; i++) {
      final s = spawns[i];
      final comp = prefabs.instantiate<Component>(
        s.prefabId,
        <String, Object?>{
          'id': s.id,
          'x': s.x,
          'y': s.y,
          ...s.params,
        },
      );
      if (comp is PositionComponent &&
          comp.position.x == 0.0 &&
          comp.position.y == 0.0 &&
          (s.x != 0.0 || s.y != 0.0)) {
        comp.position.setValues(s.x, s.y);
      }
      created.add(comp);
    }
    return created;
  }

  /// Serializes this map document to canonical JSON.
  String encodeJson() {
    return jsonEncode(<String, Object?>{
      'mapId': mapId,
      'width': width,
      'height': height,
      'tileWidth': tileWidth,
      'tileHeight': tileHeight,
      'groundPassage': groundPassageFlags.toList(growable: false),
      'upperPassage': upperPassageFlags.toList(growable: false),
      'layers': <Map<String, Object?>>[
        for (final l in layers)
          <String, Object?>{
            'name': l.name,
            'priority': l.priority,
            'opacity': l.opacity,
            'cells': l.cells.toList(growable: false),
          },
      ],
      'spawns': <Map<String, Object?>>[
        for (final s in spawns)
          <String, Object?>{
            'id': s.id,
            'prefabId': s.prefabId,
            'x': s.x,
            'y': s.y,
            'params': s.params,
          },
      ],
      'cameraZones': <Map<String, Object?>>[
        for (final z in cameraZones)
          <String, Object?>{
            'id': z.id,
            'rect': <double>[
              z.triggerBounds.left,
              z.triggerBounds.top,
              z.triggerBounds.width,
              z.triggerBounds.height,
            ],
            'zoom': z.targetZoom,
            'priority': z.priority,
          },
      ],
    });
  }

  /// Parses a [TileMapDocument] from JSON produced by [encodeJson].
  factory TileMapDocument.fromJson(String jsonSource) {
    final raw = jsonDecode(jsonSource);
    if (raw is! Map<String, Object?>) {
      throw const FormatException('TileMapDocument root must be a JSON object');
    }
    final mapId = raw['mapId'] as String? ?? 'unnamed';
    final width = (raw['width']! as num).toInt();
    final height = (raw['height']! as num).toInt();
    final tileW = (raw['tileWidth']! as num).toDouble();
    final tileH = (raw['tileHeight']! as num).toDouble();
    if (width <= 0 || height <= 0) {
      throw FormatException('Invalid map dimensions: ${width}x$height');
    }

    Uint32List? decodeU32(Object? listObj) {
      if (listObj is! List) {
        return null;
      }
      final out = Uint32List(listObj.length);
      for (var i = 0; i < listObj.length; i++) {
        out[i] = (listObj[i]! as num).toInt();
      }
      return out;
    }

    final rawLayers = raw['layers'] as List<Object?>? ?? const <Object?>[];
    final layers = <TileMapLayerData>[];
    for (final entry in rawLayers) {
      final m = entry! as Map<String, Object?>;
      layers.add(
        TileMapLayerData(
          name: m['name'] as String? ?? 'layer',
          priority: (m['priority'] as num?)?.toInt() ?? 0,
          opacity: (m['opacity'] as num?)?.toDouble() ?? 1.0,
          cells: decodeU32(m['cells']) ?? Uint32List(width * height),
        ),
      );
    }

    final rawSpawns = raw['spawns'] as List<Object?>? ?? const <Object?>[];
    final spawns = <TileMapEntitySpawn>[];
    for (final entry in rawSpawns) {
      final m = entry! as Map<String, Object?>;
      final p = m['params'];
      spawns.add(
        TileMapEntitySpawn(
          id: m['id']! as String,
          prefabId: m['prefabId']! as String,
          x: (m['x']! as num).toDouble(),
          y: (m['y']! as num).toDouble(),
          params: p is Map<String, Object?> ? p : const <String, Object?>{},
        ),
      );
    }

    final rawZones = raw['cameraZones'] as List<Object?>? ?? const <Object?>[];
    final zones = <CameraZone>[];
    for (final entry in rawZones) {
      final m = entry! as Map<String, Object?>;
      final r = (m['rect']! as List<Object?>)
          .map((v) => (v! as num).toDouble())
          .toList(growable: false);
      zones.add(
        CameraZone(
          id: m['id']! as String,
          triggerBounds: Rect.fromLTWH(r[0], r[1], r[2], r[3]),
          targetZoom: (m['zoom'] as num?)?.toDouble(),
          priority: (m['priority'] as num?)?.toInt() ?? 0,
        ),
      );
    }

    return TileMapDocument(
      mapId: mapId,
      width: width,
      height: height,
      tileWidth: tileW,
      tileHeight: tileH,
      layers: layers,
      groundPassageFlags: decodeU32(raw['groundPassage']),
      upperPassageFlags: decodeU32(raw['upperPassage']),
      spawns: spawns,
      cameraZones: zones,
    );
  }

  /// Encodes tile & passage buffers in compact little-endian `DTMP` binary
  /// format (avoiding huge JSON integer arrays on `256x256+` maps), storing
  /// lightweight metadata JSON in a trailing footer.
  Uint8List encodeBinary() {
    final totalCells = width * height;
    final metaJson = utf8.encode(
      jsonEncode(<String, Object?>{
        'mapId': mapId,
        'layerMeta': <Map<String, Object?>>[
          for (final l in layers)
            <String, Object?>{
              'name': l.name,
              'priority': l.priority,
              'opacity': l.opacity,
            },
        ],
        'spawns': <Map<String, Object?>>[
          for (final s in spawns)
            <String, Object?>{
              'id': s.id,
              'prefabId': s.prefabId,
              'x': s.x,
              'y': s.y,
              'params': s.params,
            },
        ],
      }),
    );

    // Header (28B) + ground + upper + layers + metaLen(4B) + meta
    final u32ArraysBytes = (2 + layers.length) * totalCells * 4;
    final totalBytes = 28 + u32ArraysBytes + 4 + metaJson.length;
    final out = Uint8List(totalBytes);
    final bd = ByteData.sublistView(out);

    var off = 0;
    bd.setUint32(off, _binaryMagic);
    off += 4;
    bd.setUint32(off, _binaryVersion, Endian.little);
    off += 4;
    bd.setUint32(off, width, Endian.little);
    off += 4;
    bd.setUint32(off, height, Endian.little);
    off += 4;
    bd.setFloat32(off, tileWidth, Endian.little);
    off += 4;
    bd.setFloat32(off, tileHeight, Endian.little);
    off += 4;
    bd.setUint32(off, layers.length, Endian.little);
    off += 4;

    void writeGrid(Uint32List src) {
      for (var i = 0; i < totalCells; i++) {
        bd.setUint32(off, i < src.length ? src[i] : 0, Endian.little);
        off += 4;
      }
    }

    writeGrid(groundPassageFlags);
    writeGrid(upperPassageFlags);
    for (final l in layers) {
      writeGrid(l.cells);
    }

    bd.setUint32(off, metaJson.length, Endian.little);
    off += 4;
    out.setRange(off, off + metaJson.length, metaJson);
    return out;
  }

  /// Decodes a binary `DTMP` buffer produced by [encodeBinary].
  factory TileMapDocument.fromBinary(Uint8List bytes) {
    if (bytes.length < 32) {
      throw const FormatException('DTMP buffer truncated');
    }
    final bd = ByteData.sublistView(bytes);
    var off = 0;
    final magic = bd.getUint32(off);
    off += 4;
    if (magic != _binaryMagic) {
      throw FormatException(
        'Invalid DTMP magic: 0x${magic.toRadixString(16)}',
      );
    }
    final version = bd.getUint32(off, Endian.little);
    off += 4;
    if (version != _binaryVersion) {
      throw FormatException('Unsupported DTMP version: $version');
    }
    final width = bd.getUint32(off, Endian.little);
    off += 4;
    final height = bd.getUint32(off, Endian.little);
    off += 4;
    final tileW = bd.getFloat32(off, Endian.little);
    off += 4;
    final tileH = bd.getFloat32(off, Endian.little);
    off += 4;
    final layerCount = bd.getUint32(off, Endian.little);
    off += 4;

    if (width == 0 ||
        height == 0 ||
        width > 65536 ||
        height > 65536 ||
        layerCount > 1024 ||
        !tileW.isFinite ||
        !tileH.isFinite ||
        tileW <= 0 ||
        tileH <= 0) {
      throw FormatException(
        'Invalid DTMP header dimensions: ${width}x$height '
        '(layers=$layerCount, tile=${tileW}x$tileH)',
      );
    }

    final totalCells = width * height;
    final needed = 28 + (2 + layerCount) * totalCells * 4 + 4;
    if (bytes.length < needed) {
      throw const FormatException('DTMP cell payload truncated');
    }

    Uint32List readGrid() {
      final dst = Uint32List(totalCells);
      for (var i = 0; i < totalCells; i++) {
        dst[i] = bd.getUint32(off, Endian.little);
        off += 4;
      }
      return dst;
    }

    final ground = readGrid();
    final upper = readGrid();
    final rawGrids = List<Uint32List>.generate(layerCount, (_) => readGrid());

    final metaLen = bd.getUint32(off, Endian.little);
    off += 4;
    if (bytes.length < off + metaLen) {
      throw const FormatException('DTMP metadata footer truncated');
    }
    final decodedMeta = jsonDecode(
      utf8.decode(Uint8List.sublistView(bytes, off, off + metaLen)),
    );
    if (decodedMeta is! Map<String, Object?>) {
      throw const FormatException('DTMP metadata footer must be a JSON object');
    }
    final meta = decodedMeta;

    final layerMetas = meta['layerMeta'];
    if (layerMetas is! List<Object?> || layerMetas.length < layerCount) {
      throw const FormatException('DTMP layerMeta count mismatch');
    }
    final layers = <TileMapLayerData>[];
    for (var i = 0; i < layerCount; i++) {
      final m = layerMetas[i]! as Map<String, Object?>;
      layers.add(
        TileMapLayerData(
          name: m['name'] as String? ?? 'layer_$i',
          priority: (m['priority'] as num?)?.toInt() ?? 0,
          opacity: (m['opacity'] as num?)?.toDouble() ?? 1.0,
          cells: rawGrids[i],
        ),
      );
    }

    final rawSpawns = meta['spawns'] as List<Object?>? ?? const <Object?>[];
    final spawns = <TileMapEntitySpawn>[];
    for (final entry in rawSpawns) {
      final m = entry! as Map<String, Object?>;
      final p = m['params'];
      spawns.add(
        TileMapEntitySpawn(
          id: m['id']! as String,
          prefabId: m['prefabId']! as String,
          x: (m['x']! as num).toDouble(),
          y: (m['y']! as num).toDouble(),
          params: p is Map<String, Object?> ? p : const <String, Object?>{},
        ),
      );
    }

    return TileMapDocument(
      mapId: meta['mapId'] as String? ?? 'unnamed',
      width: width,
      height: height,
      tileWidth: tileW,
      tileHeight: tileH,
      layers: layers,
      groundPassageFlags: ground,
      upperPassageFlags: upper,
      spawns: spawns,
    );
  }
}

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
