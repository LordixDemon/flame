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
