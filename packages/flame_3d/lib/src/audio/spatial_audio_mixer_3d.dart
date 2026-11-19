import 'dart:math' as math;

import 'package:flame/components.dart' show Component, HasWorldRef;
import 'package:flame_3d/camera.dart' show World3D;
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/src/audio/spatial_audio_3d.dart';

/// Acoustic reverb impulse/algorithmic preset parameters blended across
/// [AudioZone3D] volumes by [SpatialAudioMixer3D].
class const ReverbPreset3D({
  required final double wetMix,
  required final double decaySeconds,
  required final double preDelayMs,
  final String name = 'custom',
}) {
  /// Linearly interpolates between [a] and [b] by [t] in `[0, 1]`.
  factory ReverbPreset3D.lerp(
    ReverbPreset3D a,
    ReverbPreset3D b,
    double t,
  ) {
    final u = t.clamp(0.0, 1.0);
    return ReverbPreset3D(
      wetMix: a.wetMix + (b.wetMix - a.wetMix) * u,
      decaySeconds: a.decaySeconds + (b.decaySeconds - a.decaySeconds) * u,
      preDelayMs: a.preDelayMs + (b.preDelayMs - a.preDelayMs) * u,
      name: u < 0.5 ? a.name : b.name,
    );
  }

  /// Dry outdoor / anechoic baseline (`wetMix: 0`).
  static const ReverbPreset3D dry = ReverbPreset3D(
    wetMix: 0.0,
    decaySeconds: 0.2,
    preDelayMs: 0.0,
    name: 'dry',
  );

  /// Compact indoor room preset.
  static const ReverbPreset3D room = ReverbPreset3D(
    wetMix: 0.25,
    decaySeconds: 0.9,
    preDelayMs: 8.0,
    name: 'room',
  );

  /// Stone cavern / tunnel preset.
  static const ReverbPreset3D cave = ReverbPreset3D(
    wetMix: 0.6,
    decaySeconds: 2.8,
    preDelayMs: 24.0,
    name: 'cave',
  );

  /// Large reverberant hall / cathedral preset.
  static const ReverbPreset3D cathedral = ReverbPreset3D(
    wetMix: 0.78,
    decaySeconds: 4.5,
    preDelayMs: 42.0,
    name: 'cathedral',
  );
}

/// 3D spatial reverb zone (spherical [radius] or OBB [halfExtents]) with a
/// smooth outer [fadeDistance] feather margin.
class AudioZone3D({
  required var ReverbPreset3D preset,
  var double radius = 8.0,
  Vector3? halfExtents,
  var double fadeDistance = 2.0,
  var bool enabled = true,
  int priority = 0,
  super.position,
  super.rotation,
  super.scale,
  super.children,
}) extends Component3D {
  this
    : assert(radius >= 0, 'radius must be non-negative'),
      assert(fadeDistance >= 0, 'fadeDistance must be non-negative') {
    this.priority = priority;
  }

  /// Optional local box half-extents; when `null`, uses spherical [radius].
  final Vector3? halfExtents = halfExtents?.clone();

  final Matrix4 _invWorld = Matrix4.identity();
  final Vector3 _localPt = Vector3.zero();

  /// Computes spatial influence weight in `[0, 1]` at [worldPoint] (`1.0`
  /// inside the inner volume, tapering to `0.0` across [fadeDistance]).
  double weightAt(Vector3 worldPoint) {
    if (!enabled) {
      return 0.0;
    }
    final box = halfExtents;
    double signedDistOutside;
    if (box != null) {
      _invWorld.setFrom(worldTransformMatrix);
      if (_invWorld.invert().abs() < 1e-15) {
        return 0.0;
      }
      _localPt.setFrom(worldPoint);
      _invWorld.transform3(_localPt);
      final qx = math.max(0.0, _localPt.x.abs() - box.x);
      final qy = math.max(0.0, _localPt.y.abs() - box.y);
      final qz = math.max(0.0, _localPt.z.abs() - box.z);
      signedDistOutside = math.sqrt(qx * qx + qy * qy + qz * qz);
    } else {
      final s = worldTransformMatrix.storage;
      final dx = worldPoint.x - s[12];
      final dy = worldPoint.y - s[13];
      final dz = worldPoint.z - s[14];
      final dist = math.sqrt(dx * dx + dy * dy + dz * dz);
      signedDistOutside = math.max(0.0, dist - radius);
    }

    if (signedDistOutside <= 0.0) {
      return 1.0;
    }
    if (fadeDistance <= 1e-6 || signedDistOutside >= fadeDistance) {
      return 0.0;
    }
    final t = 1.0 - (signedDistOutside / fadeDistance);
    return t * t * (3.0 - 2.0 * t);
  }
}

/// Evaluated per-voice channel parameters handed to an [AudioVoiceBackend3D].
class AudioVoiceParams3D({
  required final String clipId,
  required final double volume,
  required final double pan,
  required final double pitch,
  required final double lowPassCutoffHz,
  required final double occlusion,
  required final double playbackPosition,
  required final bool looping,
  required final ReverbPreset3D reverb,
});

/// Pluggable hardware/software audio channel backend driven by
/// [SpatialAudioMixer3D].
abstract interface class AudioVoiceBackend3D() {
  /// Allocates a real audio channel for [emitter] starting at
  /// `params.playbackPosition` and returns a non-negative voice handle.
  int startVoice(SpatialAudioEmitter3D emitter, AudioVoiceParams3D params);

  /// Updates real audio channel [voiceHandle] for [emitter] with [params].
  void updateVoice(
    int voiceHandle,
    SpatialAudioEmitter3D emitter,
    AudioVoiceParams3D params,
  );

  /// Releases real audio channel [voiceHandle] when [emitter] stops or demotes
  /// to a virtual voice.
  void stopVoice(int voiceHandle, SpatialAudioEmitter3D emitter);
}

/// Pluggable geometry raycast occlusion callback returning an occlusion factor
/// in `[0, 1]` (`0.0` = clear line-of-sight, `1.0` = fully blocked).
typedef AudioOcclusionQuery3D = double Function(
  Vector3 listenerPos,
  Vector3 emitterPos,
);

class _EvaluatedEmitterEntry({
  required final SpatialAudioEmitter3D emitter,
  required var AudioVoiceParams3D params,
  required var double priorityScore,
});

/// Priority voice-pooled 3D spatial audio mixer managing unlimited
/// [SpatialAudioEmitter3D]s across `<= maxRealVoices` real backend channels and
/// zero-cost virtual voices, with pluggable geometry occlusion, acoustic
/// low-pass filtering, and smooth [AudioZone3D] reverb crossfading.
class SpatialAudioMixer3D({
  required final AudioVoiceBackend3D backend,
  this.listener,
  var int maxRealVoices = 16,
  var double virtualThresholdVolume = 0.005,
  var double maxLowPassCutoffHz = 20000.0,
  var double minLowPassCutoffHz = 800.0,
  var double reverbCrossfadeSpeed = 5.0,
  var ReverbPreset3D defaultReverb = ReverbPreset3D.dry,
  this.occlusionQuery,
  List<SpatialAudioEmitter3D> emitters = const [],
  List<AudioZone3D> zones = const [],
  this.onReverbChanged,
  super.priority,
}) extends Component with HasWorldRef<World3D> {
  this : assert(maxRealVoices >= 0, 'maxRealVoices must be >= 0') {
    _registeredEmitters.addAll(emitters);
    _registeredZones.addAll(zones);
    _currentReverb = defaultReverb;
  }

  /// Optional explicit listener; when `null`, discovers the first mounted
  /// [SpatialAudioListener3D] in the enclosing [World3D].
  SpatialAudioListener3D? listener;

  /// Optional geometry occlusion callback (`0.0` clear .. `1.0` occluded).
  AudioOcclusionQuery3D? occlusionQuery;

  /// Optional listener notified whenever [currentReverb] updates.
  void Function(ReverbPreset3D reverb)? onReverbChanged;

  final List<SpatialAudioEmitter3D> _registeredEmitters = [];
  final List<AudioZone3D> _registeredZones = [];
  final List<SpatialAudioEmitter3D> _allEmitters = [];
  final List<AudioZone3D> _allZones = [];

  final Map<SpatialAudioEmitter3D, int> _realVoiceHandles = {};
  final Map<SpatialAudioEmitter3D, AudioVoiceParams3D> _lastVoiceParams = {};
  int _virtualVoiceCount = 0;
  late ReverbPreset3D _currentReverb;

  final Vector3 _emitterWorldPos = Vector3.zero();

  /// Current smoothly crossfaded global reverb state.
  ReverbPreset3D get currentReverb => _currentReverb;

  /// Number of emitters currently backed by a real [AudioVoiceBackend3D] voice.
  int get realVoiceCount => _realVoiceHandles.length;

  /// Number of playing emitters currently tracked virtually at zero channel
  /// cost.
  int get virtualVoiceCount => _virtualVoiceCount;

  /// Whether [emitter] currently owns a real hardware/backend voice.
  bool isEmitterReal(SpatialAudioEmitter3D emitter) =>
      _realVoiceHandles.containsKey(emitter);

  /// Latest evaluated [AudioVoiceParams3D] for [emitter], or `null`.
  AudioVoiceParams3D? voiceParamsFor(SpatialAudioEmitter3D emitter) =>
      _lastVoiceParams[emitter];

  /// Registers [emitter] for standalone mixing outside a [World3D].
  void registerEmitter(SpatialAudioEmitter3D emitter) {
    if (!_registeredEmitters.contains(emitter)) {
      _registeredEmitters.add(emitter);
    }
  }

  /// Unregisters [emitter] and releases its real voice if active.
  void unregisterEmitter(SpatialAudioEmitter3D emitter) {
    _registeredEmitters.remove(emitter);
    final handle = _realVoiceHandles.remove(emitter);
    if (handle != null) {
      backend.stopVoice(handle, emitter);
    }
    _lastVoiceParams.remove(emitter);
  }

  /// Registers an [AudioZone3D] reverb volume.
  void registerZone(AudioZone3D zone) {
    if (!_registeredZones.contains(zone)) {
      _registeredZones.add(zone);
    }
  }

  /// Unregisters an [AudioZone3D] reverb volume.
  void unregisterZone(AudioZone3D zone) {
    _registeredZones.remove(zone);
  }

  @override
  void update(double dt) {
    super.update(dt);
    final activeListener = listener ?? _findListener();
    if (activeListener == null) {
      return;
    }
    activeListener.syncFrame();
    final earPos = activeListener.earPosition;

    _collectSceneItems();

    // 1. Evaluate & smoothly crossfade AudioZone3D reverb presets at `earPos`.
    final targetReverb = _evaluateTargetReverb(earPos);
    final alpha = dt > 0.0 && reverbCrossfadeSpeed > 0.0
        ? (1.0 - math.exp(-reverbCrossfadeSpeed * dt)).clamp(0.0, 1.0)
        : 1.0;
    _currentReverb = ReverbPreset3D.lerp(_currentReverb, targetReverb, alpha);
    onReverbChanged?.call(_currentReverb);

    // 2. Evaluate mix, pluggable occlusion, playback cursor, and audibility
    // priority for every emitter.
    final candidates = <_EvaluatedEmitterEntry>[];
    final seenPlaying = <SpatialAudioEmitter3D>{};
    final enclWorld = _findWorld();

    for (var i = 0; i < _allEmitters.length; i++) {
      final em = _allEmitters[i];
      if (!em.playing) {
        _lastVoiceParams.remove(em);
        continue;
      }

      // Evaluate spatial mix ( Temporarily disable built-in binary occlusion if
      // custom continuous `occlusionQuery` is supplied so we don't double-apply
      // `occlusionGain`!).
      final savedOcc = em.enableOcclusion;
      if (occlusionQuery != null) {
        em.enableOcclusion = false;
      }
      final baseMix = em.evaluateMix(activeListener, world: enclWorld);
      em.enableOcclusion = savedOcc;

      final m = em.worldTransformMatrix.storage;
      _emitterWorldPos.setValues(m[12], m[13], m[14]);

      final double occ;
      if (occlusionQuery != null) {
        occ = occlusionQuery!(earPos, _emitterWorldPos).clamp(0.0, 1.0);
      } else {
        occ = baseMix.occluded ? 1.0 : 0.0;
      }

      // Advance `playbackPosition` continuously whether virtual or real!
      if (dt > 0.0) {
        final nextPos = em.playbackPosition + dt * baseMix.pitch;
        final dur = em.clipDuration;
        if (dur > 1e-6) {
          if (em.looping) {
            em.playbackPosition = nextPos % dur;
          } else if (nextPos >= dur) {
            em
              ..playbackPosition = dur
              ..playing = false;
            _lastVoiceParams.remove(em);
            continue;
          } else {
            em.playbackPosition = nextPos;
          }
        } else {
          em.playbackPosition = nextPos;
        }
      }

      final gainMult = occlusionQuery != null
          ? 1.0 - occ * (1.0 - em.occlusionGain.clamp(0.0, 1.0))
          : 1.0;
      final finalVolume = (baseMix.volume * gainMult)
          .clamp(0.0, math.max(1.0, em.baseVolume))
          .toDouble();

      final maxHz = math.max(100.0, maxLowPassCutoffHz);
      final minHz = minLowPassCutoffHz.clamp(20.0, maxHz);
      final cutoffHz = occ <= 1e-6
          ? maxHz
          : maxHz * math.pow(minHz / maxHz, occ).toDouble();

      final params = AudioVoiceParams3D(
        clipId: em.clipId,
        volume: finalVolume,
        pan: baseMix.pan,
        pitch: baseMix.pitch,
        lowPassCutoffHz: cutoffHz,
        occlusion: occ,
        playbackPosition: em.playbackPosition,
        looping: em.looping,
        reverb: _currentReverb,
      );
      _lastVoiceParams[em] = params;
      seenPlaying.add(em);

      if (finalVolume >= virtualThresholdVolume && maxRealVoices > 0) {
        // Hysteresis bonus (`+0.015`) prevents rapid voice-stealing oscillation
        // between two nearly identical emitters.
        final alreadyRealBonus = _realVoiceHandles.containsKey(em)
            ? 0.015
            : 0.0;
        final priorityBoost = 1.0 + em.priority * 0.1;
        final score =
            finalVolume * math.max(0.1, priorityBoost) + alreadyRealBonus;
        candidates.add(
          _EvaluatedEmitterEntry(
            emitter: em,
            params: params,
            priorityScore: score,
          ),
        );
      }
    }

    // 3. Rank audible candidates descending by `priorityScore` and pick top
    // `maxRealVoices`.
    candidates.sort((a, b) => b.priorityScore.compareTo(a.priorityScore));
    final realWinners = <SpatialAudioEmitter3D, AudioVoiceParams3D>{};
    final limit = math.min(maxRealVoices, candidates.length);
    for (var i = 0; i < limit; i++) {
      realWinners[candidates[i].emitter] = candidates[i].params;
    }

    // 4. Demote any real voices no longer in `realWinners` -> `stopVoice`.
    final toDemote = <SpatialAudioEmitter3D>[];
    for (final existing in _realVoiceHandles.keys) {
      if (!realWinners.containsKey(existing)) {
        toDemote.add(existing);
      }
    }
    for (var i = 0; i < toDemote.length; i++) {
      final em = toDemote[i];
      final handle = _realVoiceHandles.remove(em)!;
      backend.stopVoice(handle, em);
    }

    // 5. Update continuing real voices and promote newly selected virtual
    // voices -> `startVoice` at their current `playbackPosition`!
    for (final entry in realWinners.entries) {
      final em = entry.key;
      final params = entry.value;
      final existingHandle = _realVoiceHandles[em];
      if (existingHandle != null) {
        backend.updateVoice(existingHandle, em, params);
      } else {
        final newHandle = backend.startVoice(em, params);
        _realVoiceHandles[em] = newHandle;
      }
    }

    _virtualVoiceCount = math.max(0, seenPlaying.length - realWinners.length);
  }

  /// Stops and releases all active real voices on removal/disposal.
  void stopAllRealVoices() {
    final entries = _realVoiceHandles.entries.toList(growable: false);
    _realVoiceHandles.clear();
    for (final entry in entries) {
      backend.stopVoice(entry.value, entry.key);
    }
  }

  @override
  void onRemove() {
    stopAllRealVoices();
    super.onRemove();
  }

  ReverbPreset3D _evaluateTargetReverb(Vector3 earPos) {
    if (_allZones.isEmpty) {
      return defaultReverb;
    }
    // Sort zones ascending by priority so higher-priority inner zones override
    // lower-priority outer zones proportionally to their weight `[0..1]`.
    _allZones.sort((a, b) => a.priority.compareTo(b.priority));
    var accum = defaultReverb;
    for (var i = 0; i < _allZones.length; i++) {
      final z = _allZones[i];
      final w = z.weightAt(earPos);
      if (w > 0.0) {
        accum = ReverbPreset3D.lerp(accum, z.preset, w);
      }
    }
    return accum;
  }

  World3D? _findWorld() {
    if (!isMounted) {
      return null;
    }
    for (final anc in ancestors()) {
      if (anc is World3D) {
        return anc;
      }
    }
    return null;
  }

  SpatialAudioListener3D? _findListener() {
    final w = _findWorld();
    if (w == null) {
      return null;
    }
    SpatialAudioListener3D? found;
    void visit(Component c) {
      if (found != null) {
        return;
      }
      if (c is SpatialAudioListener3D) {
        found = c;
        return;
      }
      for (final child in c.children) {
        visit(child);
      }
    }

    visit(w);
    return found;
  }

  void _collectSceneItems() {
    _allEmitters
      ..clear()
      ..addAll(_registeredEmitters);
    _allZones
      ..clear()
      ..addAll(_registeredZones);

    final w = _findWorld();
    if (w != null) {
      void visit(Component c) {
        if (c is SpatialAudioEmitter3D && !_allEmitters.contains(c)) {
          _allEmitters.add(c);
        } else if (c is AudioZone3D && !_allZones.contains(c)) {
          _allZones.add(c);
        }
        for (final child in c.children) {
          visit(child);
        }
      }

      visit(w);
    }
  }
}
