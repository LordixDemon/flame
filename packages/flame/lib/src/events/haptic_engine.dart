import 'package:flutter/services.dart';

/// Semantic haptic feedback patterns ordered by physical intensity rank.
enum HapticPattern(final int rank) {
  selectionTick(1),
  lightImpact(2),
  mediumImpact(3),
  successPulse(4),
  warningBuzz(5),
  heavyImpact(6),
  errorBuzz(7),
}

/// Pluggable backend invoked by [HapticEngine] after frame coalescing and
/// cooldown filtering.
abstract interface class HapticBackend() {
  Future<void> trigger(HapticPattern pattern);
}

/// Default platform [HapticBackend] delegating to Flutter's [HapticFeedback].
class const FlutterHapticBackend() implements HapticBackend {
  @override
  Future<void> trigger(HapticPattern pattern) {
    return switch (pattern) {
      HapticPattern.selectionTick => HapticFeedback.selectionClick(),
      HapticPattern.lightImpact => HapticFeedback.lightImpact(),
      HapticPattern.mediumImpact ||
      HapticPattern.successPulse => HapticFeedback.mediumImpact(),
      HapticPattern.warningBuzz ||
      HapticPattern.heavyImpact => HapticFeedback.heavyImpact(),
      HapticPattern.errorBuzz => HapticFeedback.vibrate(),
    };
  }
}

/// Deterministic in-memory [HapticBackend] for unit testing.
class RecordingHapticBackend() implements HapticBackend {
  final List<HapticPattern> emitted = <HapticPattern>[];

  @override
  Future<void> trigger(HapticPattern pattern) async {
    emitted.add(pattern);
  }
}

/// Coalesced, throttled haptic feedback engine preventing platform
/// `MethodChannel` stalls when dozens of gameplay events (coins, impacts, tile
/// steps) trigger in the same frame or burst.
class HapticEngine({
  HapticBackend backend = const FlutterHapticBackend(),
  this.enabled = true,
  this.minCooldownSeconds = 0.04,
}) {
  final HapticBackend _backend = backend;

  /// Global user accessibility/settings toggle.
  bool enabled;

  /// Minimum interval (in seconds) between consecutive haptic emissions.
  double minCooldownSeconds;

  double _clockSeconds = 0.0;
  double _lastEmitTime = -1000.0;
  HapticPattern? _queuedStrongest;
  int _suppressedCount = 0;

  /// Number of redundant haptic requests coalesced or throttled away.
  int get suppressedCount => _suppressedCount;

  /// Requests [pattern] for the current frame. If multiple patterns are
  /// requested before [flushFrame], only the highest-intensity `rank` wins.
  void request(HapticPattern pattern) {
    if (!enabled) {
      _suppressedCount++;
      return;
    }
    final current = _queuedStrongest;
    if (current == null) {
      _queuedStrongest = pattern;
    } else {
      _suppressedCount++;
      if (pattern.rank > current.rank) {
        _queuedStrongest = pattern;
      }
    }
  }

  /// Advances internal cooldown clock by [dt] and dispatches at most **1**
  /// coalesced haptic call for the frame if outside [minCooldownSeconds].
  void flushFrame(double dt) {
    if (dt > 0.0) {
      _clockSeconds += dt;
    }
    final pending = _queuedStrongest;
    _queuedStrongest = null;
    if (pending == null || !enabled) {
      return;
    }
    if (_clockSeconds - _lastEmitTime < minCooldownSeconds) {
      _suppressedCount++;
      return;
    }
    _lastEmitTime = _clockSeconds;
    _backend.trigger(pending);
  }
}
