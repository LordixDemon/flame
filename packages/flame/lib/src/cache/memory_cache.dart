import 'dart:collection';

/// Simple class to cache values with size based eviction and optional
/// disposal callback [onEvict].
class MemoryCache<K, V>({
  final int cacheSize = 10,
  final void Function(K key, V value)? onEvict,
}) {
  final LinkedHashMap<K, V> _cache = LinkedHashMap();

  /// Adds the [value] to the cache under [key].
  ///
  /// If that [key] is already used, updates the value and invokes [onEvict] on
  /// the displaced entry if it is a distinct instance.
  void setValue(K key, V value) {
    final preexisting = _cache.containsKey(key);
    if (preexisting) {
      final previous = _cache[key] as V;
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

  /// Gets the value under [key].
  V? getValue(K key) => _cache[key];

  /// Checks whether the cache has any value under [key].
  bool containsKey(K key) => _cache.containsKey(key);

  /// Returns the number of values saved in this memory cache.
  int get size => _cache.length;

  /// Iterates over all existing keys with values.
  Iterable<K> get keys => _cache.keys;
}
