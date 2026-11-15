import 'dart:ui';

import 'package:vector_math/vector_math.dart';

/// Portal / seamless edge link between two world maps.
class WorldPortalLink({
  required this.id,
  required this.fromMapId,
  required this.triggerRect,
  required this.toMapId,
  required this.targetSpawnPosition,
  this.seamlessWorldOffset,
}) {
  final String id;
  final String fromMapId;
  final Rect triggerRect;
  final String toMapId;
  final Vector2 targetSpawnPosition;

  /// Non-null when [toMapId] stitches seamlessly in world space at this offset
  /// relative to `(0, 0)` (e.g. Chrono Trigger / Pokemon overworld borders).
  final Vector2? seamlessWorldOffset;
}

/// Manages map portal transitions, neighbor pre-warming within
/// [preloadDistance], and LRU/distance eviction for multi-map RPG worlds.
class ConnectedWorldStreamer<M>({
  required this.loader,
  this.onDisposeMap,
  this.preloadDistance = 256.0,
  this.maxLoadedMaps = 6,
}) {
  final Future<M> Function(String mapId) loader;
  final void Function(String mapId, M map)? onDisposeMap;
  final double preloadDistance;
  final int maxLoadedMaps;

  final List<WorldPortalLink> _portals = <WorldPortalLink>[];
  final Map<String, M> _loaded = <String, M>{};
  final Map<String, Future<M>> _inFlight = <String, Future<M>>{};
  final List<String> _lruOrder = <String>[];

  String? _activeMapId;

  String? get activeMapId => _activeMapId;

  M? get activeMap => _activeMapId == null ? null : _loaded[_activeMapId];

  Iterable<String> get loadedMapIds => _loaded.keys;

  void registerPortal(WorldPortalLink link) {
    _portals.add(link);
  }

  bool isLoaded(String mapId) => _loaded.containsKey(mapId);

  /// Ensures [mapId] is loaded and returns it (coalescing duplicate concurrent
  /// requests).
  Future<M> ensureLoaded(String mapId, {bool deferEviction = false}) {
    final existing = _loaded[mapId];
    if (existing != null) {
      _touchLru(mapId);
      return Future<M>.value(existing);
    }
    final pending = _inFlight[mapId];
    if (pending != null) {
      return pending;
    }
    final fut = loader(mapId).then((loaded) {
      _inFlight.remove(mapId);
      _loaded[mapId] = loaded;
      _touchLru(mapId);
      if (!deferEviction) {
        _evictExcess();
      }
      return loaded;
    });
    _inFlight[mapId] = fut;
    return fut;
  }

  /// Activates [mapId] as the primary map and evicts oldest non-active maps
  /// exceeding [maxLoadedMaps].
  Future<M> enterMap(String mapId) async {
    final map = await ensureLoaded(mapId, deferEviction: true);
    _activeMapId = mapId;
    _touchLru(mapId);
    _evictExcess();
    return map;
  }

  /// Checks active-map portals around `(playerX, playerY)`:
  /// - Initiates background preloads for portals within [preloadDistance],
  /// - Returns the triggered [WorldPortalLink] if `(playerX, playerY)` stepped
  ///   inside `triggerRect`.
  WorldPortalLink? updatePlayerPosition(double playerX, double playerY) {
    final cur = _activeMapId;
    if (cur == null) {
      return null;
    }
    final pt = Offset(playerX, playerY);
    WorldPortalLink? hit;

    for (var i = 0; i < _portals.length; i++) {
      final p = _portals[i];
      if (p.fromMapId != cur) {
        continue;
      }
      if (hit == null && p.triggerRect.contains(pt)) {
        hit = p;
      }
      final expanded = p.triggerRect.inflate(preloadDistance);
      if (expanded.contains(pt) &&
          !_loaded.containsKey(p.toMapId) &&
          !_inFlight.containsKey(p.toMapId)) {
        ensureLoaded(p.toMapId);
      }
    }
    return hit;
  }

  void _touchLru(String mapId) {
    _lruOrder
      ..remove(mapId)
      ..add(mapId);
  }

  void _evictExcess() {
    while (_loaded.length > maxLoadedMaps && _lruOrder.isNotEmpty) {
      String? victim;
      for (var i = 0; i < _lruOrder.length; i++) {
        if (_lruOrder[i] != _activeMapId) {
          victim = _lruOrder[i];
          break;
        }
      }
      if (victim == null) {
        break;
      }
      _lruOrder.remove(victim);
      final removed = _loaded.remove(victim);
      if (removed != null && onDisposeMap != null) {
        onDisposeMap!(victim, removed);
      }
    }
  }
}
