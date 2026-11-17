import 'dart:math' as math;

/// Canonical hierarchical audio bus identifiers in [AudioMixer].
enum AudioBusId() {
  /// Root mix bus scaling all child buses.
  master,

  /// Background music and adaptive stems.
  music,

  /// Gameplay sound effects.
  sfx,

  /// Environmental loops (wind, crowd, rain, room tone).
  ambience,

  /// Dialogue / announcer voice lines.
  voice,

  /// Button clicks, notifications, and HUD feedback.
  ui,
}

/// Handle to a playing voice managed by an [AudioBackend] and [AudioMixer].
class AudioVoiceHandle({
  required this.voiceId,
  required this.assetId,
  required this.bus,
  required this.startedAtSeconds,
  this.cueId,
  this.loop = false,
  this.durationSeconds = 1.0,
  this.sourceVolume = 1.0,
  this.pitch = 1.0,
  this.pan = 0.0,
}) {
  /// Monotonic unique voice identifier.
  final int voiceId;

  /// Audio clip asset path or identifier.
  final String assetId;

  /// Bus to which this voice is routed.
  final AudioBusId bus;

  /// Optional originating `SoundCue` identifier.
  final String? cueId;

  /// Mixer clock timestamp when playback started.
  final double startedAtSeconds;

  /// Whether this voice loops indefinitely until stopped.
  final bool loop;

  /// Length of the clip in seconds of audio at `pitch == 1.0` (used when
  /// non-looping if backend does not report completion externally).
  ///
  /// [pitch] is a playback rate, so a non-looping voice lives for
  /// `durationSeconds / pitch` seconds of mixer time.
  final double durationSeconds;

  /// Pre-bus voice gain (`0.0 .. 2.0`).
  double sourceVolume;

  /// Playback rate / pitch multiplier (`0.25 .. 4.0`).
  double pitch;

  /// Stereo pan (`-1.0` = full left, `0.0` = center, `+1.0` = full right).
  double pan;

  double _lastAppliedGain = 0.0;
  double _playheadSeconds = 0.0;
  bool _stopped = false;

  /// Most recent post-bus gain pushed to [AudioBackend].
  double get effectiveGain => _lastAppliedGain;

  /// Seconds of clip audio played so far: mixer time weighted by the [pitch]
  /// in effect while it passed. A non-looping voice is retired once this
  /// reaches [durationSeconds].
  double get playheadSeconds => _playheadSeconds;

  /// Whether this voice has finished or been stopped.
  bool get isStopped => _stopped;
}

/// Pluggable low-level audio playback driver consumed by [AudioMixer].
///
/// Games can bind `flame_audio`, `flutter_soloud`, `just_audio`, or custom FFI
/// backends to this interface while keeping mixing, ducking, spatial panning,
/// and voice pooling 100% engine-native and deterministic in tests.
abstract interface class AudioBackend() {
  /// Starts playing [assetId] with initial post-bus [gain], [pitch], [pan],
  /// and [loop].
  void onStartVoice(
    int voiceId,
    String assetId, {
    required double gain,
    required double pitch,
    required double pan,
    required bool loop,
  });

  /// Updates live parameters on an active [voiceId].
  void onUpdateVoice(
    int voiceId, {
    required double gain,
    required double pitch,
    required double pan,
  });

  /// Stops [voiceId] immediately.
  void onStopVoice(int voiceId);
}

/// Deterministic zero-IO [AudioBackend] for unit tests, headless benchmarks,
/// and platforms without audio hardware.
class InMemoryAudioBackend() implements AudioBackend {
  /// Currently active voice states keyed by `voiceId`.
  final Map<
    int,
    ({String assetId, double gain, double pitch, double pan, bool loop})
  >
  activeVoices =
      <
        int,
        ({String assetId, double gain, double pitch, double pan, bool loop})
      >{};

  /// Total voices started since creation or [clear].
  int startedCount = 0;

  /// Total voices stopped since creation or [clear].
  int stoppedCount = 0;

  @override
  void onStartVoice(
    int voiceId,
    String assetId, {
    required double gain,
    required double pitch,
    required double pan,
    required bool loop,
  }) {
    startedCount++;
    activeVoices[voiceId] = (
      assetId: assetId,
      gain: gain,
      pitch: pitch,
      pan: pan,
      loop: loop,
    );
  }

  @override
  void onUpdateVoice(
    int voiceId, {
    required double gain,
    required double pitch,
    required double pan,
  }) {
    final prev = activeVoices[voiceId];
    if (prev != null) {
      activeVoices[voiceId] = (
        assetId: prev.assetId,
        gain: gain,
        pitch: pitch,
        pan: pan,
        loop: prev.loop,
      );
    }
  }

  @override
  void onStopVoice(int voiceId) {
    if (activeVoices.remove(voiceId) != null) {
      stoppedCount++;
    }
  }

  /// Resets recorded counters and active voices.
  void clear() {
    activeVoices.clear();
    startedCount = 0;
    stoppedCount = 0;
  }
}

/// Single gain/mute/fade channel inside [AudioMixer].
class AudioBus({
  required this.id,
  this.parent,
  double volume = 1.0,
  this.muted = false,
}) {
  /// Identifier of this bus.
  final AudioBusId id;

  /// Optional parent bus (`null` only on [AudioBusId.master]).
  final AudioBus? parent;

  double _volume = volume.clamp(0.0, 2.0);
  double _fadeStartVolume = volume.clamp(0.0, 2.0);
  double _fadeTargetVolume = volume.clamp(0.0, 2.0);
  double _fadeDuration = 0.0;
  double _fadeElapsed = 0.0;
  double _duckMultiplier = 1.0;

  /// Whether this bus is muted (`effectiveGain == 0`).
  bool muted;

  /// User/fader volume (`0.0 .. 2.0`) before parent bus and ducking multipliers.
  double get volume => _volume;
  set volume(double value) {
    _volume = value.clamp(0.0, 2.0);
    _fadeDuration = 0.0;
  }

  /// Current sidechain ducking multiplier (`0.0 .. 1.0`) applied to this bus.
  double get duckMultiplier => _duckMultiplier;

  /// Effective linear gain combining parent gain, [muted], [volume], and
  /// [duckMultiplier].
  double get effectiveGain {
    if (muted) {
      return 0.0;
    }
    final parentGain = parent?.effectiveGain ?? 1.0;
    return (parentGain * _volume * _duckMultiplier).clamp(0.0, 2.0);
  }

  /// Smoothly ramps [volume] to [targetVolume] over [durationSeconds].
  void fadeTo(double targetVolume, {required double durationSeconds}) {
    final clamped = targetVolume.clamp(0.0, 2.0);
    if (durationSeconds <= 0.0) {
      volume = clamped;
      return;
    }
    _fadeStartVolume = _volume;
    _fadeTargetVolume = clamped;
    _fadeDuration = durationSeconds;
    _fadeElapsed = 0.0;
  }

  void _tickFade(double dt) {
    if (_fadeDuration <= 0.0) {
      return;
    }
    _fadeElapsed += dt;
    if (_fadeElapsed >= _fadeDuration) {
      _volume = _fadeTargetVolume;
      _fadeDuration = 0.0;
    } else {
      final t = (_fadeElapsed / _fadeDuration).clamp(0.0, 1.0);
      _volume = _fadeStartVolume + (_fadeTargetVolume - _fadeStartVolume) * t;
    }
  }
}

/// Sidechain ducking rule attenuating [targetBus] while [triggerBus] has at
/// least one audible playing voice.
class DuckingRule({
  required this.triggerBus,
  required this.targetBus,
  this.duckGain = 0.35,
  this.attackSeconds = 0.08,
  this.holdSeconds = 0.15,
  this.releaseSeconds = 0.35,
}) {
  /// Bus whose active voices trigger attenuation (e.g. [AudioBusId.voice]).
  final AudioBusId triggerBus;

  /// Bus to attenuate (e.g. [AudioBusId.music]).
  final AudioBusId targetBus;

  /// Target gain multiplier while ducked (`0.0 .. 1.0`).
  final double duckGain;

  /// Time in seconds to ramp down to [duckGain].
  final double attackSeconds;

  /// Hold window in seconds after [triggerBus] goes silent before releasing.
  final double holdSeconds;

  /// Time in seconds to ramp back up to `1.0`.
  final double releaseSeconds;

  double _currentGain = 1.0;
  double _holdRemaining = 0.0;

  /// Current envelope multiplier (`duckGain .. 1.0`).
  double get currentGain => _currentGain;

  double _step(double dt, {required bool triggered}) {
    final target = duckGain.clamp(0.0, 1.0);
    if (triggered) {
      _holdRemaining = holdSeconds;
      if (attackSeconds <= 1e-4) {
        _currentGain = target;
      } else {
        final rate = (1.0 - target) / attackSeconds;
        _currentGain = math.max(target, _currentGain - rate * dt);
      }
    } else if (_holdRemaining > 0.0) {
      _holdRemaining = math.max(0.0, _holdRemaining - dt);
    } else {
      if (releaseSeconds <= 1e-4) {
        _currentGain = 1.0;
      } else {
        final rate = (1.0 - target) / releaseSeconds;
        _currentGain = math.min(1.0, _currentGain + rate * dt);
      }
    }
    return _currentGain;
  }
}

/// Hierarchical multi-bus game audio mixer with sidechain ducking, voice
/// lifecycle tracking, and JSON settings persistence.
class AudioMixer({
  AudioBackend? backend,
  bool installDefaultVoiceDucking = true,
}) {
  this {
    final master = AudioBus(id: AudioBusId.master);
    _buses[AudioBusId.master] = master;
    for (final id in AudioBusId.values) {
      if (id != AudioBusId.master) {
        _buses[id] = AudioBus(id: id, parent: master);
      }
    }
    if (installDefaultVoiceDucking) {
      duckingRules.add(
        DuckingRule(
          triggerBus: AudioBusId.voice,
          targetBus: AudioBusId.music,
          duckGain: 0.32,
        ),
      );
    }
  }

  /// Active low-level playback backend.
  final AudioBackend backend = backend ?? InMemoryAudioBackend();

  final Map<AudioBusId, AudioBus> _buses = <AudioBusId, AudioBus>{};
  final List<AudioVoiceHandle> _voices = <AudioVoiceHandle>[];

  /// Active sidechain ducking rules evaluated every [update].
  final List<DuckingRule> duckingRules = <DuckingRule>[];

  int _nextVoiceId = 1;
  double _clockSeconds = 0.0;

  /// Current mixer clock in seconds.
  double get clockSeconds => _clockSeconds;

  /// Read-only list of currently active voices.
  List<AudioVoiceHandle> get activeVoices =>
      List<AudioVoiceHandle>.unmodifiable(_voices);

  /// Returns the [AudioBus] for [id].
  AudioBus bus(AudioBusId id) => _buses[id]!;

  /// Counts currently active voices routed to [busId] (or matching [cueId]).
  int activeVoiceCount({AudioBusId? busId, String? cueId}) {
    var count = 0;
    for (var i = 0; i < _voices.length; i++) {
      final v = _voices[i];
      if (busId != null && v.bus != busId) {
        continue;
      }
      if (cueId != null && v.cueId != cueId) {
        continue;
      }
      count++;
    }
    return count;
  }

  /// Plays [assetId] on [busId] and returns a live [AudioVoiceHandle].
  AudioVoiceHandle playClip(
    String assetId, {
    AudioBusId busId = AudioBusId.sfx,
    String? cueId,
    double volume = 1.0,
    double pitch = 1.0,
    double pan = 0.0,
    bool loop = false,
    double durationSeconds = 1.0,
  }) {
    final id = _nextVoiceId++;
    final clampedPan = pan.clamp(-1.0, 1.0);
    final clampedPitch = pitch.clamp(0.25, 4.0);
    final handle = AudioVoiceHandle(
      voiceId: id,
      assetId: assetId,
      bus: busId,
      cueId: cueId,
      startedAtSeconds: _clockSeconds,
      loop: loop,
      durationSeconds: math.max(0.01, durationSeconds),
      sourceVolume: volume.clamp(0.0, 2.0),
      pitch: clampedPitch,
      pan: clampedPan,
    );
    final gain = (bus(busId).effectiveGain * handle.sourceVolume).clamp(
      0.0,
      2.0,
    );
    handle._lastAppliedGain = gain;
    _voices.add(handle);
    backend.onStartVoice(
      id,
      assetId,
      gain: gain,
      pitch: clampedPitch,
      pan: clampedPan,
      loop: loop,
    );
    return handle;
  }

  /// Stops [handle] immediately if still active.
  void stopVoice(AudioVoiceHandle handle) {
    if (handle._stopped) {
      return;
    }
    handle._stopped = true;
    _voices.remove(handle);
    backend.onStopVoice(handle.voiceId);
  }

  /// Stops all active voices (optionally filtered by [busId]).
  void stopAll({AudioBusId? busId}) {
    for (var i = _voices.length - 1; i >= 0; i--) {
      final v = _voices[i];
      if (busId == null || v.bus == busId) {
        v._stopped = true;
        _voices.removeAt(i);
        backend.onStopVoice(v.voiceId);
      }
    }
  }

  /// Advances bus fades, sidechain ducking envelopes, non-looping voice
  /// lifetimes, and live backend voice gains by [dt] seconds.
  ///
  /// A non-looping voice is retired (and [AudioBackend.onStopVoice] sent) once
  /// its clip has played through, which takes `durationSeconds / pitch`
  /// seconds: a clip slowed down to half speed lives twice as long.
  void update(double dt) {
    if (dt <= 0.0) {
      return;
    }
    _clockSeconds += dt;

    // Advance playheads and retire one-shot voices that played through.
    for (var i = _voices.length - 1; i >= 0; i--) {
      final v = _voices[i];
      v._playheadSeconds += dt * v.pitch.clamp(0.25, 4.0);
      if (!v.loop && v._playheadSeconds >= v.durationSeconds) {
        v._stopped = true;
        _voices.removeAt(i);
        backend.onStopVoice(v.voiceId);
      }
    }

    // Advance bus fades and reset duck multipliers.
    for (final b in _buses.values) {
      b._tickFade(dt);
      b._duckMultiplier = 1.0;
    }

    // Evaluate sidechain ducking rules.
    for (var i = 0; i < duckingRules.length; i++) {
      final rule = duckingRules[i];
      final triggerBusObj = bus(rule.triggerBus);
      var triggered = false;
      if (!triggerBusObj.muted && triggerBusObj.volume > 1e-3) {
        for (var j = 0; j < _voices.length; j++) {
          final v = _voices[j];
          if (v.bus == rule.triggerBus && v.sourceVolume > 1e-3) {
            triggered = true;
            break;
          }
        }
      }
      final env = rule._step(dt, triggered: triggered);
      final target = bus(rule.targetBus);
      target._duckMultiplier = math.min(target._duckMultiplier, env);
    }

    // Push updated effective gains/pans/pitches to active voices.
    for (var i = 0; i < _voices.length; i++) {
      final v = _voices[i];
      final nextGain = (bus(v.bus).effectiveGain * v.sourceVolume).clamp(
        0.0,
        2.0,
      );
      v._lastAppliedGain = nextGain;
      backend.onUpdateVoice(
        v.voiceId,
        gain: nextGain,
        pitch: v.pitch.clamp(0.25, 4.0),
        pan: v.pan.clamp(-1.0, 1.0),
      );
    }
  }

  /// Exports user volume/mute settings for persistence.
  Map<String, Object?> toSettingsJson() {
    final map = <String, Object?>{};
    for (final b in _buses.values) {
      map[b.id.name] = <String, Object?>{
        'volume': b.volume,
        'muted': b.muted,
      };
    }
    return map;
  }

  /// Restores user volume/mute settings from [json].
  void applySettingsJson(Map<String, Object?> json) {
    for (final id in AudioBusId.values) {
      final entry = json[id.name];
      if (entry is Map<String, Object?>) {
        final b = bus(id);
        final vol = entry['volume'];
        final mut = entry['muted'];
        if (vol is num) {
          b.volume = vol.toDouble();
        }
        if (mut is bool) {
          b.muted = mut;
        }
      }
    }
  }
}
