import 'dart:math' as math;

/// Tracks estimated GPU byte consumption of cached offscreen textures
/// (`Snapshot` raster images, static `SceneLayerComponent` surfaces, and custom
/// RTT caches) and evicts least-recently-used entries when exceeding
/// [maxBudgetBytes].
class SceneResourceBudget({
  var int maxBudgetBytes = 96 * 1024 * 1024,
  var bool autoEnforceBudget = true,
}) {
  final Map<Object, _BudgetEntry> _entries = <Object, _BudgetEntry>{};
  int _clock = 0;
  int _totalBytes = 0;
  int _evictionCount = 0;

  /// Total estimated VRAM bytes across all currently registered surfaces.
  int get totalEstimatedBytes => _totalBytes;

  /// Number of currently tracked GPU surfaces.
  int get activeSurfaceCount => _entries.length;

  /// Total number of LRU evictions performed since creation or [resetStats].
  int get evictionCount => _evictionCount;

  /// Estimates RGBA8 GPU byte footprint (`width * height * 4`).
  static int estimateRgbaBytes(int width, int height) {
    if (width <= 0 || height <= 0) {
      return 0;
    }
    return width * height * 4;
  }

  /// Registers or updates [owner]'s cached GPU byte footprint and eviction
  /// callback.
  ///
  /// When [autoEnforceBudget] is `true` and [totalEstimatedBytes] exceeds
  /// [maxBudgetBytes], older surfaces (excluding [owner] when possible) are
  /// evicted in least-recently-used order.
  void registerSurface(
    Object owner, {
    required int bytes,
    required void Function() onEvict,
  }) {
    final clampedBytes = math.max(0, bytes);
    final existing = _entries[owner];
    final stamp = ++_clock;
    if (existing != null) {
      _totalBytes += clampedBytes - existing.bytes;
      existing
        ..bytes = clampedBytes
        ..onEvict = onEvict
        ..lastUsedStamp = stamp;
    } else {
      _entries[owner] = _BudgetEntry(
        owner: owner,
        bytes: clampedBytes,
        lastUsedStamp: stamp,
        onEvict: onEvict,
      );
      _totalBytes += clampedBytes;
    }
    if (autoEnforceBudget && _totalBytes > maxBudgetBytes) {
      _trimToBudget(maxBudgetBytes, protectedOwner: owner);
    }
  }

  /// Marks [owner] as recently used in `O(1)` time with zero heap allocations.
  void touchSurface(Object owner) {
    final entry = _entries[owner];
    if (entry != null) {
      entry.lastUsedStamp = ++_clock;
    }
  }

  /// Removes [owner] from budget tracking without invoking its `onEvict`
  /// callback (call when the owner disposes its own resource directly).
  void unregisterSurface(Object owner) {
    final removed = _entries.remove(owner);
    if (removed != null) {
      _totalBytes = math.max(0, _totalBytes - removed.bytes);
    }
  }

  /// Evicts least-recently-used surfaces until [totalEstimatedBytes] is at or
  /// below [targetBytes] (defaults to [maxBudgetBytes]), returning the number
  /// of freed bytes.
  int trimToBudget([int? targetBytes]) =>
      _trimToBudget(targetBytes ?? maxBudgetBytes);

  int _trimToBudget(int targetBytes, {Object? protectedOwner}) {
    final limit = math.max(0, targetBytes);
    if (_totalBytes <= limit || _entries.isEmpty) {
      return 0;
    }
    final candidates = _entries.values.toList(growable: false)
      ..sort((a, b) => a.lastUsedStamp.compareTo(b.lastUsedStamp));

    var freed = 0;
    for (final candidate in candidates) {
      if (_totalBytes <= limit) {
        break;
      }
      if (protectedOwner != null &&
          identical(candidate.owner, protectedOwner)) {
        continue;
      }
      if (_entries.remove(candidate.owner) != null) {
        _totalBytes = math.max(0, _totalBytes - candidate.bytes);
        freed += candidate.bytes;
        _evictionCount++;
        candidate.onEvict();
      }
    }
    return freed;
  }

  /// Immediately evicts all tracked surfaces.
  void evictAll() {
    if (_entries.isEmpty) {
      return;
    }
    final snapshot = _entries.values.toList(growable: false);
    _entries.clear();
    _totalBytes = 0;
    for (final entry in snapshot) {
      _evictionCount++;
      entry.onEvict();
    }
  }

  /// Resets [evictionCount] for testing and profiling.
  void resetStats() {
    _evictionCount = 0;
  }
}

class _BudgetEntry({
  required final Object owner,
  required var int bytes,
  required var int lastUsedStamp,
  required var void Function() onEvict,
});
