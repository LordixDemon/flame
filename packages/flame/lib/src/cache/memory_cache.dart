import 'dart:collection';

/// A bounded least-recently-used (LRU) cache with an optional disposal
/// callback [onEvict].
///
/// The cache holds at most [cacheSize] entries. An entry counts as used when
/// it is written with [setValue] or read with [getValue], and when the cache
/// is full the entry that has gone unused the longest is evicted. Reading
/// and writing are both `O(1)`.
///
/// When [onEvict] is given, the cache owns its values: the callback is
/// invoked for every value that leaves the cache (eviction, replacement,
/// [clear] and [clearCache]), which is where native resources should be
/// released. A value that is still referenced elsewhere must not be released
/// from [onEvict] unless the callback can tell that it is no longer in use.
class MemoryCache<K, V>({
  final int cacheSize = 10,
  final void Function(K key, V value)? onEvict,
}) {
  this : assert(cacheSize >= 0, 'cacheSize must be >= 0: $cacheSize');

  /// Entries ordered from the least to the most recently used.
  final LinkedHashMap<K, V> _cache = LinkedHashMap();

  /// Adds the [value] to the cache under [key] and marks it as the most
  /// recently used entry.
  ///
  /// If that [key] is already used, updates the value and invokes [onEvict] on
  /// the displaced entry if it is a distinct instance. If the cache then holds
  /// more than [cacheSize] entries, the least recently used ones are evicted,
  /// which with a [cacheSize] of `0` is the value that was just added.
  void setValue(K key, V value) {
    if (_cache.containsKey(key)) {
      final previous = _cache.remove(key) as V;
      _cache[key] = value;
      if (!identical(previous, value)) {
        onEvict?.call(key, previous);
      }
      return;
    }

    _cache[key] = value;
    while (_cache.length > cacheSize) {
      final k = _cache.keys.first;
      final evicted = _cache.remove(k) as V;
      onEvict?.call(k, evicted);
    }
  }

  /// Removes the value from the cache and invokes [onEvict] if present.
  void clear(K key) {
    if (_cache.containsKey(key)) {
      final evicted = _cache.remove(key) as V;
      onEvict?.call(key, evicted);
    }
  }

  /// Removes all the values from the cache and invokes [onEvict] for each.
  void clearCache() {
    if (onEvict != null && _cache.isNotEmpty) {
      final entries = _cache.entries.toList(growable: false);
      _cache.clear();
      for (final entry in entries) {
        onEvict!(entry.key, entry.value);
      }
    } else {
      _cache.clear();
    }
  }

  /// Gets the value under [key] and marks it as the most recently used entry,
  /// or returns `null` when there is none.
  V? getValue(K key) {
    if (!_cache.containsKey(key)) {
      return null;
    }
    final value = _cache.remove(key) as V;
    _cache[key] = value;
    return value;
  }

  /// Checks whether the cache has any value under [key], without counting as
  /// a use of that entry.
  bool containsKey(K key) => _cache.containsKey(key);

  /// Returns the number of values saved in this memory cache.
  int get size => _cache.length;

  /// The keys that currently have values, from the least to the most recently
  /// used.
  ///
  /// This is a snapshot, so that the cache can be read with [getValue] (which
  /// reorders the entries) while iterating over it.
  Iterable<K> get keys => List<K>.unmodifiable(_cache.keys);
}
