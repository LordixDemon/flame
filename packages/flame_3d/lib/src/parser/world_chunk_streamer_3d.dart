import 'dart:async';
import 'dart:collection';

import 'package:flame/components.dart' show Component, HasWorldRef;
import 'package:flame_3d/camera.dart' show CameraComponent3D, World3D;
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flutter/foundation.dart'
    show ErrorDescription, FlutterError, FlutterErrorDetails;
import 'package:meta/meta.dart';

/// Discrete integer grid coordinate of a streamable 3D world cell.
@immutable
class const ChunkCoord3D(
  final int x,
  final int z, [
  final int y = 0,
]) {
  @override
  bool operator ==(Object other) =>
      other is ChunkCoord3D && other.x == x && other.y == y && other.z == z;

  @override
  int get hashCode => Object.hash(x, y, z);

  @override
  String toString() => 'ChunkCoord3D($x, $y, $z)';
}

/// Async factory loading the 3D scene components belonging to [coord].
typedef ChunkLoaderCallback3D = Future<List<Component3D>> Function(
  ChunkCoord3D coord,
);

/// Called when the [ChunkLoaderCallback3D] of a [WorldChunkStreamer3D] throws
/// (or returns a failed future) for [coord].
typedef ChunkLoadFailedCallback3D = void Function(
  ChunkCoord3D coord,
  Object error,
  StackTrace stackTrace,
);

/// Spatial grid/radius world chunk streamer with hysteresis
/// (`[loadRadius..unloadRadius]`), `maxConcurrentLoads` throttling,
/// closest-cell prioritization, and an LRU unloaded chunk cache.
class WorldChunkStreamer3D({
  required final double chunkSize,
  required final double loadRadius,
  required final ChunkLoaderCallback3D chunkLoader,
  double? unloadRadius,
  var int maxConcurrentLoads = 4,
  var int maxCachedUnloadedChunks = 16,
  var bool enableVerticalStreaming = false,
  this.camera,
  this.focusTarget,
  Vector3? focusPosition,
  this.chunkContainer,
  this.onChunkMounted,
  this.onChunkUnmounted,
  this.onChunkEvicted,
  this.onChunkLoadFailed,

  /// Seconds of [update] time before a chunk whose load failed is requested
  /// again (`double.infinity` never retries it on its own, see
  /// [retryFailedChunks]).
  var double failedLoadRetryDelay = 5.0,
  super.priority,
}) extends Component with HasWorldRef<World3D> {
  this
    : assert(chunkSize > 0, 'chunkSize must be positive'),
      assert(loadRadius > 0, 'loadRadius must be positive'),
      assert(maxConcurrentLoads >= 1, 'maxConcurrentLoads must be >= 1'),
      assert(
        maxCachedUnloadedChunks >= 0,
        'maxCachedUnloadedChunks must be >= 0',
      ) {
    final resolvedUnload = unloadRadius ?? loadRadius * 1.35;
    if (resolvedUnload < loadRadius) {
      throw ArgumentError.value(
        resolvedUnload,
        'unloadRadius',
        'unloadRadius must be >= loadRadius ($loadRadius)',
      );
    }
    this.unloadRadius = resolvedUnload;
  }

  /// Distance beyond which mounted chunks are unmounted into the LRU cache.
  late double unloadRadius;

  /// Optional camera whose eye position drives chunk streaming.
  CameraComponent3D? camera;

  /// Optional target [Component3D] (e.g. player) whose world position drives
  /// chunk streaming when [camera] is `null`.
  Component3D? focusTarget;

  /// Explicit focus position used when both [camera] and [focusTarget] are
  /// `null`.
  final Vector3 focusPosition = focusPosition?.clone() ?? Vector3.zero();

  /// Optional parent container where loaded chunk components are mounted
  /// (defaults to the enclosing [World3D] or [parent] when mounted).
  Component? chunkContainer;

  /// Optional hook invoked whenever a chunk's components become active.
  void Function(ChunkCoord3D coord, List<Component3D> components)?
  onChunkMounted;

  /// Optional hook invoked whenever an active chunk moves beyond
  /// [unloadRadius].
  void Function(ChunkCoord3D coord, List<Component3D> components)?
  onChunkUnmounted;

  /// Optional hook invoked when an unloaded chunk is evicted from the LRU
  /// cache, when a chunk that finished loading after the streamer was removed
  /// is dropped, and for every active or cached chunk when the streamer is
  /// removed: release the chunk's resources here.
  void Function(ChunkCoord3D coord, List<Component3D> components)?
  onChunkEvicted;

  /// Optional hook invoked when [chunkLoader] fails for a chunk. Without it,
  /// the error is reported through `FlutterError.reportError`. Either way the
  /// chunk is requested again only after [failedLoadRetryDelay].
  ChunkLoadFailedCallback3D? onChunkLoadFailed;

  final Map<ChunkCoord3D, List<Component3D>> _activeChunks = {};
  final Set<ChunkCoord3D> _inFlight = {};
  final List<ChunkCoord3D> _pendingQueue = [];
  final LinkedHashMap<ChunkCoord3D, List<Component3D>> _lruCache =
      LinkedHashMap<ChunkCoord3D, List<Component3D>>();
  final List<Future<void>> _activeTasks = [];

  // Chunks whose load failed, with the [_clock] time they may be retried.
  final Map<ChunkCoord3D, double> _failedUntil = {};
  double _clock = 0;

  int _cacheHitCount = 0;
  int _totalLoadsCompleted = 0;
  int _failedLoadCount = 0;
  bool _disposed = false;
  final Vector3 _resolvedFocus = Vector3.zero();

  /// Coordinates of all currently active/mounted chunks.
  Set<ChunkCoord3D> get activeChunks =>
      Set<ChunkCoord3D>.unmodifiable(_activeChunks.keys);

  /// Coordinates currently loading asynchronously.
  Set<ChunkCoord3D> get loadingChunks =>
      Set<ChunkCoord3D>.unmodifiable(_inFlight);

  /// Number of chunks waiting in the concurrency queue.
  int get queuedChunkCount => _pendingQueue.length;

  /// Number of unloaded chunks currently retained in the LRU cache.
  int get cachedChunkCount => _lruCache.length;

  /// Number of times a chunk remounted from the LRU cache with zero loader IO.
  int get cacheHitCount => _cacheHitCount;

  /// Total number of async [chunkLoader] invocations that have completed.
  int get totalLoadsCompleted => _totalLoadsCompleted;

  /// Total number of [chunkLoader] invocations that failed.
  int get failedLoadCount => _failedLoadCount;

  /// Coordinates whose last load failed and that wait for
  /// [failedLoadRetryDelay] before being requested again.
  Set<ChunkCoord3D> get failedChunks =>
      Set<ChunkCoord3D>.unmodifiable(_failedUntil.keys);

  /// Lets every chunk whose load failed be requested again at the next
  /// refresh, without waiting for [failedLoadRetryDelay].
  void retryFailedChunks() => _failedUntil.clear();

  /// Returns the active component list for [coord], or `null` if not active.
  List<Component3D>? componentsForChunk(ChunkCoord3D coord) {
    final list = _activeChunks[coord];
    return list == null ? null : List<Component3D>.unmodifiable(list);
  }

  /// Converts a world-space [position] to its enclosing [ChunkCoord3D].
  ChunkCoord3D coordForWorldPosition(Vector3 position) {
    final cx = (position.x / chunkSize).floor();
    final cz = (position.z / chunkSize).floor();
    final cy = enableVerticalStreaming ? (position.y / chunkSize).floor() : 0;
    return ChunkCoord3D(cx, cz, cy);
  }

  /// Computes the world-space center of [coord].
  Vector3 chunkCenterWorld(ChunkCoord3D coord) {
    return Vector3(
      (coord.x + 0.5) * chunkSize,
      enableVerticalStreaming ? (coord.y + 0.5) * chunkSize : 0.0,
      (coord.z + 0.5) * chunkSize,
    );
  }

  /// Updates [focusPosition] and immediately refreshes streaming state.
  void updateFocus(Vector3 worldFocus) {
    focusPosition.setFrom(worldFocus);
    refreshStreaming();
  }

  @override
  void update(double dt) {
    super.update(dt);
    _clock += dt;
    refreshStreaming();
  }

  /// Evaluates chunk load/unload radii around the current focus point and
  /// schedules or unmounts chunks as needed.
  void refreshStreaming() {
    if (_disposed) {
      return;
    }
    _resolveFocusInto(_resolvedFocus);
    final unloadR2 = unloadRadius * unloadRadius;
    final loadR2 = loadRadius * loadRadius;

    // 1. Collect active chunks beyond `unloadRadius` (deferred until after
    // reclaiming any LRU cache hits for the new focus so outgoing chunks never
    // evict incoming cached chunks on a teleport!).
    final toUnload = <ChunkCoord3D>[];
    for (final coord in _activeChunks.keys) {
      if (_distSqToFocus(coord, _resolvedFocus) > unloadR2) {
        toUnload.add(coord);
      }
    }
    if (toUnload.length > 1) {
      // Unload farthest chunks first so the closest unloaded chunks remain
      // most-recently-used in the bounded LRU cache.
      toUnload.sort(
        (a, b) => _distSqToFocus(
          b,
          _resolvedFocus,
        ).compareTo(_distSqToFocus(a, _resolvedFocus)),
      );
    }

    // 2. Drop queued (not yet started) loads that fell outside `unloadRadius`.
    _pendingQueue.removeWhere(
      (coord) => _distSqToFocus(coord, _resolvedFocus) > unloadR2,
    );

    // 3. Discover chunks within `loadRadius` (reclaiming LRU hits immediately).
    final minX = ((_resolvedFocus.x - loadRadius) / chunkSize).floor();
    final maxX = ((_resolvedFocus.x + loadRadius) / chunkSize).floor();
    final minZ = ((_resolvedFocus.z - loadRadius) / chunkSize).floor();
    final maxZ = ((_resolvedFocus.z + loadRadius) / chunkSize).floor();
    final minY = enableVerticalStreaming
        ? ((_resolvedFocus.y - loadRadius) / chunkSize).floor()
        : 0;
    final maxY = enableVerticalStreaming
        ? ((_resolvedFocus.y + loadRadius) / chunkSize).floor()
        : 0;

    for (var cy = minY; cy <= maxY; cy++) {
      for (var cz = minZ; cz <= maxZ; cz++) {
        for (var cx = minX; cx <= maxX; cx++) {
          final coord = ChunkCoord3D(cx, cz, cy);
          if (_activeChunks.containsKey(coord) || _inFlight.contains(coord)) {
            continue;
          }
          if (_distSqToFocus(coord, _resolvedFocus) > loadR2) {
            continue;
          }
          final retryAt = _failedUntil[coord];
          if (retryAt != null) {
            if (_clock < retryAt) {
              continue;
            }
            _failedUntil.remove(coord);
          }

          // Instant LRU cache hit!
          final cached = _lruCache.remove(coord);
          if (cached != null) {
            _cacheHitCount++;
            _mountChunk(coord, cached);
            continue;
          }

          if (!_pendingQueue.contains(coord)) {
            _pendingQueue.add(coord);
          }
        }
      }
    }

    // 4. Unmount outgoing chunks into the remaining LRU cache slots.
    for (var i = 0; i < toUnload.length; i++) {
      _unmountChunk(toUnload[i]);
    }

    // Sort pending queue closest-first and pump up to `maxConcurrentLoads`.
    if (_pendingQueue.length > 1) {
      _pendingQueue.sort(
        (a, b) => _distSqToFocus(
          a,
          _resolvedFocus,
        ).compareTo(_distSqToFocus(b, _resolvedFocus)),
      );
    }
    _pumpQueue();
  }

  /// Waits until all currently in-flight and queued chunk loads settle.
  Future<void> flushPending() async {
    var guard = 0;
    while ((_activeTasks.isNotEmpty || _pendingQueue.isNotEmpty) &&
        guard++ < 128) {
      final snapshot = List<Future<void>>.of(_activeTasks);
      if (snapshot.isEmpty) {
        _pumpQueue();
        if (_activeTasks.isEmpty) {
          break;
        }
        continue;
      }
      await Future.wait(snapshot);
    }
  }

  /// Stops streaming for good: active chunks are unmounted (reported to
  /// [onChunkUnmounted]), then every active and cached chunk is reported to
  /// [onChunkEvicted], as are loads that finish later.
  @override
  void onRemove() {
    _disposed = true;
    _pendingQueue.clear();
    final coords = _activeChunks.keys.toList(growable: false);
    for (final c in coords) {
      final comps = _activeChunks.remove(c)!;
      for (var i = 0; i < comps.length; i++) {
        final component = comps[i];
        if (component.parent != null) {
          component.removeFromParent();
        }
      }
      onChunkUnmounted?.call(c, comps);
      onChunkEvicted?.call(c, comps);
    }
    final cached = List.of(_lruCache.entries);
    _lruCache.clear();
    for (final entry in cached) {
      onChunkEvicted?.call(entry.key, entry.value);
    }
    super.onRemove();
  }

  void _pumpQueue() {
    while (!_disposed &&
        _inFlight.length < maxConcurrentLoads &&
        _pendingQueue.isNotEmpty) {
      final coord = _pendingQueue.removeAt(0);
      _inFlight.add(coord);
      late final Future<void> task;
      task = _loadChunkAsync(coord).whenComplete(() {
        _activeTasks.remove(task);
      });
      _activeTasks.add(task);
    }
  }

  Future<void> _loadChunkAsync(ChunkCoord3D coord) async {
    try {
      final List<Component3D> loaded;
      try {
        loaded = await chunkLoader(coord);
      } on Object catch (error, stackTrace) {
        _failedLoadCount++;
        _failedUntil[coord] = _clock + failedLoadRetryDelay;
        _reportLoadFailure(coord, error, stackTrace);
        return;
      }
      _inFlight.remove(coord);
      _totalLoadsCompleted++;
      if (_disposed) {
        onChunkEvicted?.call(coord, loaded);
        return;
      }
      _resolveFocusInto(_resolvedFocus);
      final withinUnload =
          _distSqToFocus(coord, _resolvedFocus) <= unloadRadius * unloadRadius;
      if (withinUnload) {
        _mountChunk(coord, loaded);
      } else {
        _insertIntoLru(coord, loaded);
      }
    } finally {
      _inFlight.remove(coord);
      if (!_disposed) {
        _pumpQueue();
      }
    }
  }

  void _reportLoadFailure(
    ChunkCoord3D coord,
    Object error,
    StackTrace stackTrace,
  ) {
    final callback = onChunkLoadFailed;
    if (callback != null) {
      callback(coord, error, stackTrace);
      return;
    }
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'flame_3d',
        context: ErrorDescription('while loading the world chunk $coord'),
      ),
    );
  }

  void _mountChunk(ChunkCoord3D coord, List<Component3D> comps) {
    _activeChunks[coord] = comps;
    final host = _resolveContainer();
    if (host != null) {
      for (var i = 0; i < comps.length; i++) {
        final c = comps[i];
        if (c.parent == null) {
          host.add(c);
        }
      }
    }
    onChunkMounted?.call(coord, comps);
  }

  void _unmountChunk(ChunkCoord3D coord) {
    final comps = _activeChunks.remove(coord);
    if (comps == null) {
      return;
    }
    for (var i = 0; i < comps.length; i++) {
      final c = comps[i];
      if (c.parent != null) {
        c.removeFromParent();
      }
    }
    onChunkUnmounted?.call(coord, comps);
    _insertIntoLru(coord, comps);
  }

  void _insertIntoLru(ChunkCoord3D coord, List<Component3D> comps) {
    if (maxCachedUnloadedChunks <= 0) {
      onChunkEvicted?.call(coord, comps);
      return;
    }
    _lruCache.remove(coord);
    _lruCache[coord] = comps;
    while (_lruCache.length > maxCachedUnloadedChunks) {
      final oldestKey = _lruCache.keys.first;
      final evicted = _lruCache.remove(oldestKey)!;
      onChunkEvicted?.call(oldestKey, evicted);
    }
  }

  Component? _resolveContainer() {
    if (chunkContainer != null) {
      return chunkContainer;
    }
    if (isMounted) {
      for (final anc in ancestors()) {
        if (anc is World3D) {
          return anc;
        }
      }
      return parent;
    }
    return null;
  }

  void _resolveFocusInto(Vector3 out) {
    final cam = camera;
    if (cam != null) {
      out.setFrom(cam.eyePosition);
      return;
    }
    final tgt = focusTarget;
    if (tgt != null) {
      final s = tgt.worldTransformMatrix.storage;
      out.setValues(s[12], s[13], s[14]);
      return;
    }
    out.setFrom(focusPosition);
  }

  double _distSqToFocus(ChunkCoord3D coord, Vector3 focus) {
    final cx = (coord.x + 0.5) * chunkSize;
    final cz = (coord.z + 0.5) * chunkSize;
    final dx = cx - focus.x;
    final dz = cz - focus.z;
    if (!enableVerticalStreaming) {
      return dx * dx + dz * dz;
    }
    final cy = (coord.y + 0.5) * chunkSize;
    final dy = cy - focus.y;
    return dx * dx + dy * dy + dz * dz;
  }
}
