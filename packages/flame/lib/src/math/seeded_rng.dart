import 'dart:math' as math;
import 'dart:typed_data';

import 'package:vector_math/vector_math.dart';

/// Fast, cross-platform deterministic pseudo-random number generator
/// (Xoshiro128** over unsigned 32-bit lanes, bit-identical across Dart VM,
/// AOT, JS, and Wasm) with snapshotable state, named substream forking,
/// weighted selection, and spatial sampling.
class SeededRng([int seed = 0x5EED1234]) implements math.Random {
  this {
    reseed(seed);
  }

  /// Restores a generator directly from a 16-byte snapshot produced by
  /// [saveState].
  factory SeededRng.fromStateBytes(Uint8List bytes) {
    final rng = SeededRng(1)..restoreState(bytes);
    return rng;
  }

  final Uint32List _s = Uint32List(4);
  double? _spareGaussian;

  /// Resets all 4 internal state lanes deterministically from [seed] using
  /// Mulberry32 avalanche mixing.
  void reseed(int seed) {
    _spareGaussian = null;
    var z = (seed ^ 0x9E3779B9) & 0xFFFFFFFF;
    for (var i = 0; i < 4; i++) {
      z = (z + 0x6D2B79F5) & 0xFFFFFFFF;
      var t = z;
      t = _imul32(t ^ (t >>> 15), t | 1);
      t = (t ^ (t + _imul32(t ^ (t >>> 7), t | 61))) & 0xFFFFFFFF;
      _s[i] = (t ^ (t >>> 14)) & 0xFFFFFFFF;
    }
    if (_s[0] == 0 && _s[1] == 0 && _s[2] == 0 && _s[3] == 0) {
      _s[0] = 0x9E3779B9;
    }
  }

  /// Exports the exact 16-byte internal state (plus cached normal-distribution
  /// flag cleared on restore) for deterministic savegames, lockstep, or replay.
  Uint8List saveState() {
    final out = Uint8List(16);
    final view = ByteData.sublistView(out);
    for (var i = 0; i < 4; i++) {
      view.setUint32(i * 4, _s[i], Endian.little);
    }
    return out;
  }

  /// Restores the exact 16-byte state previously captured via [saveState].
  void restoreState(Uint8List stateBytes) {
    if (stateBytes.length < 16) {
      throw ArgumentError.value(
        stateBytes.length,
        'stateBytes.length',
        'Expected at least 16 bytes for SeededRng state',
      );
    }
    _spareGaussian = null;
    final view = ByteData.sublistView(stateBytes);
    for (var i = 0; i < 4; i++) {
      _s[i] = view.getUint32(i * 4, Endian.little);
    }
    if (_s[0] == 0 && _s[1] == 0 && _s[2] == 0 && _s[3] == 0) {
      _s[0] = 1;
    }
  }

  /// Creates an independent child [SeededRng] derived from this generator's
  /// current state and [domainLabel] without advancing this generator!
  SeededRng fork(String domainLabel) {
    var hash = 0x811C9DC5;
    for (var i = 0; i < domainLabel.length; i++) {
      hash ^= domainLabel.codeUnitAt(i);
      hash = _imul32(hash, 0x01000193);
    }
    final mixed =
        (_s[0] ^ _rotl32(_s[1], 7) ^ _rotl32(_s[2], 15) ^ _s[3] ^ hash) &
        0xFFFFFFFF;
    return SeededRng(mixed);
  }

  /// Generates the next unsigned 32-bit integer in `[0, 2^32 - 1]`.
  int nextUint32() {
    final result = _imul32(_rotl32(_imul32(_s[1], 5), 7), 9);
    final t = (_s[1] << 9) & 0xFFFFFFFF;

    _s[2] ^= _s[0];
    _s[3] ^= _s[1];
    _s[1] ^= _s[2];
    _s[0] ^= _s[3];

    _s[2] ^= t;
    _s[3] = _rotl32(_s[3], 11);
    return result;
  }

  @override
  int nextInt(int max) {
    if (max <= 0 || max > 0x100000000) {
      throw RangeError.range(max, 1, 0x100000000, 'max');
    }
    if ((max & (max - 1)) == 0) {
      return nextUint32() & (max - 1);
    }
    // Unbiased rejection threshold: (2^32 - max) % max.
    final threshold = (0x100000000 - max) % max;
    while (true) {
      final r = nextUint32();
      if (r >= threshold) {
        return r % max;
      }
    }
  }

  @override
  double nextDouble() {
    final hi = nextUint32() >>> 5; // 27 bits
    final lo = nextUint32() >>> 6; // 26 bits
    return (hi * 67108864.0 + lo) * (1.0 / 9007199254740992.0);
  }

  @override
  bool nextBool([double probability = 0.5]) {
    if (probability <= 0.0) {
      return false;
    }
    if (probability >= 1.0) {
      return true;
    }
    return nextDouble() < probability;
  }

  /// Inclusive integer sample in `[minInclusive, maxInclusive]`.
  int rangeInt(int minInclusive, int maxInclusive) {
    if (maxInclusive < minInclusive) {
      throw ArgumentError('maxInclusive ($maxInclusive) < minInclusive');
    }
    return minInclusive + nextInt(maxInclusive - minInclusive + 1);
  }

  /// Uniform floating-point sample in `[min, max)`.
  double rangeDouble(double min, double max) =>
      min + (max - min) * nextDouble();

  /// Normal (Gaussian) sample using the Marsaglia polar method.
  double gaussian({double mean = 0.0, double stdDev = 1.0}) {
    final spare = _spareGaussian;
    if (spare != null) {
      _spareGaussian = null;
      return mean + spare * stdDev;
    }
    double u;
    double v;
    double s;
    do {
      u = nextDouble() * 2.0 - 1.0;
      v = nextDouble() * 2.0 - 1.0;
      s = u * u + v * v;
    } while (s >= 1.0 || s == 0.0);
    final mul = math.sqrt(-2.0 * math.log(s) / s);
    _spareGaussian = v * mul;
    return mean + u * mul * stdDev;
  }

  /// Uniformly picks one element from non-empty [items].
  T pick<T>(List<T> items) {
    if (items.isEmpty) {
      throw StateError('Cannot pick from an empty list');
    }
    return items[nextInt(items.length)];
  }

  /// Picks an index `0 .. weights.length - 1` proportional to positive
  /// [weights].
  int weightedPickIndex(List<double> weights) {
    var total = 0.0;
    for (var i = 0; i < weights.length; i++) {
      final w = weights[i];
      if (w > 0.0) {
        total += w;
      }
    }
    if (total <= 0.0) {
      throw StateError('Sum of weights must be positive');
    }
    var roll = nextDouble() * total;
    var lastValid = 0;
    for (var i = 0; i < weights.length; i++) {
      final w = weights[i];
      if (w <= 0.0) {
        continue;
      }
      lastValid = i;
      roll -= w;
      if (roll <= 0.0) {
        return i;
      }
    }
    return lastValid;
  }

  /// Picks an element from [items] according to corresponding [weights].
  T weightedPick<T>(List<T> items, List<double> weights) {
    if (items.length != weights.length || items.isEmpty) {
      throw ArgumentError('items and weights must be non-empty of equal size');
    }
    return items[weightedPickIndex(weights)];
  }

  /// In-place deterministic Fisher–Yates shuffle of [items].
  void shuffle<T>(List<T> items) {
    for (var i = items.length - 1; i > 0; i--) {
      final j = nextInt(i + 1);
      final tmp = items[i];
      items[i] = items[j];
      items[j] = tmp;
    }
  }

  /// Uniformly samples a 2D point inside a disk of [radius], writing to [out].
  void pointInCircle(double radius, Vector2 out) {
    final r = radius * math.sqrt(nextDouble());
    final theta = nextDouble() * math.pi * 2.0;
    out.setValues(r * math.cos(theta), r * math.sin(theta));
  }

  /// Uniformly samples a 2D point inside the ring `[innerRadius, outerRadius]`.
  void pointInAnnulus(double innerRadius, double outerRadius, Vector2 out) {
    final r2Min = innerRadius * innerRadius;
    final r2Max = outerRadius * outerRadius;
    final r = math.sqrt(r2Min + (r2Max - r2Min) * nextDouble());
    final theta = nextDouble() * math.pi * 2.0;
    out.setValues(r * math.cos(theta), r * math.sin(theta));
  }

  static int _rotl32(int x, int k) =>
      ((x << k) | ((x & 0xFFFFFFFF) >>> (32 - k))) & 0xFFFFFFFF;

  static int _imul32(int a, int b) {
    final ah = (a >>> 16) & 0xFFFF;
    final al = a & 0xFFFF;
    final bh = (b >>> 16) & 0xFFFF;
    final bl = b & 0xFFFF;
    return ((al * bl) + (((ah * bl + al * bh) & 0xFFFF) << 16)) & 0xFFFFFFFF;
  }
}

/// Frame-stamped entry inside a [CommandRecorder] deterministic replay log.
class const RecordedCommand<C>({
  required this.tick,
  required this.command,
}) {
  /// Simulation tick index when [command] was executed.
  final int tick;

  /// Domain command payload.
  final C command;
}

/// Deterministic command log pairing an initial RNG seed with frame-stamped
/// commands for lockstep verification, automated bug reproduction, and replays.
class CommandRecorder<C>({final int initialSeed = 0x5EED1234}) {
  final List<RecordedCommand<C>> _entries = <RecordedCommand<C>>[];

  /// Unmodifiable view of recorded commands in chronological tick order.
  List<RecordedCommand<C>> get entries => List.unmodifiable(_entries);

  /// Total number of recorded commands.
  int get length => _entries.length;

  /// Appends [command] at simulation [tick].
  void record(int tick, C command) {
    _entries.add(RecordedCommand<C>(tick: tick, command: command));
  }

  /// Clears all recorded commands.
  void clear() => _entries.clear();

  /// Iterates commands matching [tick] into [out] with zero list allocations.
  void collectForTick(int tick, List<C> out) {
    out.clear();
    for (var i = 0; i < _entries.length; i++) {
      final entry = _entries[i];
      if (entry.tick == tick) {
        out.add(entry.command);
      }
    }
  }

  /// Serializes the seed and command stream to a JSON-compatible map.
  Map<String, Object?> toJson(Object? Function(C command) encodeCommand) {
    return <String, Object?>{
      'initialSeed': initialSeed,
      'entries': <Map<String, Object?>>[
        for (final e in _entries)
          <String, Object?>{
            'tick': e.tick,
            'command': encodeCommand(e.command),
          },
      ],
    };
  }

  /// Reconstructs a [CommandRecorder] from [toJson] output.
  static CommandRecorder<C> fromJson<C>(
    Map<String, Object?> json,
    C Function(Object? raw) decodeCommand,
  ) {
    final recorder = CommandRecorder<C>(
      initialSeed: (json['initialSeed'] as int?) ?? 0x5EED1234,
    );
    final rawEntries = json['entries'];
    if (rawEntries is List) {
      for (final item in rawEntries) {
        if (item is Map<String, Object?>) {
          recorder.record(
            item['tick']! as int,
            decodeCommand(item['command']),
          );
        }
      }
    }
    return recorder;
  }
}
