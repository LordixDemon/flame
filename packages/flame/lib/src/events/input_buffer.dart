/// Time-windowed input press buffer (`100–200 ms` grace window) for responsive
/// controls when a player presses `roll` / `jump` / `confirm` a few frames
/// before the current animation or cooldown finishes.
class InputBuffer({this.defaultWindowSeconds = 0.15}) {
  /// Default retention window in seconds for buffered actions.
  final double defaultWindowSeconds;

  final Map<String, double> _remainingTtl = <String, double>{};

  /// Buffers [action] for [windowSeconds] (defaults to [defaultWindowSeconds]).
  void buffer(String action, {double? windowSeconds}) {
    final ttl = windowSeconds ?? defaultWindowSeconds;
    if (ttl > 0.0) {
      _remainingTtl[action] = ttl;
    }
  }

  /// Advances buffered action timers by [dt] seconds, expiring stale entries.
  void update(double dt) {
    if (_remainingTtl.isEmpty || dt <= 0.0) {
      return;
    }
    final expired = <String>[];
    for (final entry in _remainingTtl.entries) {
      final next = entry.value - dt;
      if (next <= 0.0) {
        expired.add(entry.key);
      } else {
        _remainingTtl[entry.key] = next;
      }
    }
    for (var i = 0; i < expired.length; i++) {
      _remainingTtl.remove(expired[i]);
    }
  }

  /// Returns `true` if [action] currently has a non-expired buffered press
  /// without consuming it.
  bool hasBuffered(String action) => (_remainingTtl[action] ?? 0.0) > 0.0;

  /// Consumes and returns `true` if [action] had a live buffered press.
  bool consume(String action) {
    final ttl = _remainingTtl.remove(action);
    return ttl != null && ttl > 0.0;
  }

  /// Clears all buffered actions.
  void clear() => _remainingTtl.clear();
}
