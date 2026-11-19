import 'dart:math' as math;

import 'package:flame/components.dart' show Component;
import 'package:flame_3d/camera.dart' show World3D;
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/src/audio/spatial_audio_3d.dart';
import 'package:flame_3d/src/audio/spatial_audio_registry_3d.dart';
import 'package:meta/meta.dart';

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
///
/// A zone only describes reverb settings; `SpatialAudioMixer3D` blends the
/// zones' presets at the listener and hands the result to its backend, which
/// must apply it.
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
      assert(fadeDistance >= 0, 'fadeDistance must be non-negative');

  /// Order of this zone when overlapping zones are blended: zones with a
  /// higher [audioPriority] are applied later and win (`priority` in the
  /// constructor).
  ///
  /// This is not the component [priority], which orders the component among
  /// its siblings for updates and rendering.
  int audioPriority = priority;

  @override
  void onMount() {
    super.onMount();
    if (worldOrNull case final world?) {
      SpatialAudioRegistry3D.of(world).zones.add(this);
    }
  }

  @override
  void onRemove() {
    SpatialAudioRegistry3D.maybeOf(worldOrNull)?.zones.remove(this);
    super.onRemove();
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

/// The audio engine behind a [SpatialAudioMixer3D], written by the caller.
///
/// The mixer decides which emitters get a real voice and with which
/// parameters; the backend starts, updates and stops the voices of an actual
/// audio engine (for example `audioplayers`). The package ships no backend.
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

class _EvaluatedEmitterEntry() {
  SpatialAudioEmitter3D? emitter;
  AudioVoiceParams3D? params;
  double priorityScore = 0.0;
}

int _byScoreDescending(_EvaluatedEmitterEntry a, _EvaluatedEmitterEntry b) {
  return b.priorityScore.compareTo(a.priorityScore);
}

/// Computes, every update, the voice parameters (gain, pan, pitch, low-pass
/// cutoff, playback position and reverb) of many [SpatialAudioEmitter3D]s and
/// hands them to an [AudioVoiceBackend3D] that the caller supplies.
///
/// It produces no sound and does no signal processing: it ranks the playing
/// emitters, keeps the `maxRealVoices` most audible ones on real voices of the
/// backend (`startVoice` / `updateVoice` / `stopVoice`), and tracks the others
/// as virtual voices, which use no backend voice but are still evaluated every
/// update (with their occlusion raycast, if any) and keep their playback
/// position. Occlusion becomes a low-pass cutoff value and [AudioZone3D]
/// presets are blended into one [currentReverb]; applying both is up to the
/// backend.
///
/// Mounted in a [World3D], it uses the emitters and zones mounted in that
/// world, which register themselves on mount (no tree walk per update);
/// [registerEmitter] and [registerZone] add others.
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
}) extends Component {
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

  /// Optional listener notified when [currentReverb] changes (not on
  /// updates that leave it as it was).
  void Function(ReverbPreset3D reverb)? onReverbChanged;

  final List<SpatialAudioEmitter3D> _registeredEmitters = [];
  final List<AudioZone3D> _registeredZones = [];
  final List<AudioZone3D> _allZones = [];
  // Emitters of the world that `unregisterEmitter` excluded.
  final Set<SpatialAudioEmitter3D> _excluded = {};

  final Map<SpatialAudioEmitter3D, int> _realVoiceHandles = {};
  final Map<SpatialAudioEmitter3D, AudioVoiceParams3D> _lastVoiceParams = {};
  int _virtualVoiceCount = 0;
  late ReverbPreset3D _currentReverb;
  World3D? _world;

  final Vector3 _emitterWorldPos = Vector3.zero();
  final List<_EvaluatedEmitterEntry> _entryPool = [];
  final List<_EvaluatedEmitterEntry> _candidates = [];
  final Map<SpatialAudioEmitter3D, AudioVoiceParams3D> _winners = {};
  final List<SpatialAudioEmitter3D> _scratchEmitters = [];

  /// Current smoothly crossfaded global reverb state.
  ReverbPreset3D get currentReverb => _currentReverb;

  /// Number of emitters currently backed by a real [AudioVoiceBackend3D] voice.
  int get realVoiceCount => _realVoiceHandles.length;

  /// Number of playing emitters currently tracked as virtual voices (no
  /// backend voice; still evaluated every update).
  int get virtualVoiceCount => _virtualVoiceCount;

  /// Whether [emitter] currently owns a real hardware/backend voice.
  bool isEmitterReal(SpatialAudioEmitter3D emitter) =>
      _realVoiceHandles.containsKey(emitter);

  /// Latest evaluated [AudioVoiceParams3D] for [emitter], or `null`.
  AudioVoiceParams3D? voiceParamsFor(SpatialAudioEmitter3D emitter) =>
      _lastVoiceParams[emitter];

  /// Registers [emitter] for mixing when it is not mounted in the mixer's
  /// [World3D] (or undoes an earlier [unregisterEmitter]).
  ///
  /// A registered emitter stays in the mix until [unregisterEmitter] is
  /// called, wherever it is mounted.
  void registerEmitter(SpatialAudioEmitter3D emitter) {
    _excluded.remove(emitter);
    if (!_registeredEmitters.contains(emitter)) {
      _registeredEmitters.add(emitter);
    }
  }

  /// Takes [emitter] out of the mix and releases its real voice if active.
  ///
  /// An emitter mounted in the mixer's world stays out of the mix until
  /// [registerEmitter] is called for it or it is removed from the world.
  void unregisterEmitter(SpatialAudioEmitter3D emitter) {
    _registeredEmitters.remove(emitter);
    if (_world != null && identical(emitter.worldOrNull, _world)) {
      _excluded.add(emitter);
    }
    _releaseEmitter(emitter);
  }

  /// Called when [emitter] leaves the mixer's world: stops its voice and
  /// drops every reference to it, unless it was registered explicitly.
  @internal
  void forgetEmitter(SpatialAudioEmitter3D emitter) {
    _excluded.remove(emitter);
    if (!_registeredEmitters.contains(emitter)) {
      _releaseEmitter(emitter);
    }
  }

  void _releaseEmitter(SpatialAudioEmitter3D emitter) {
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
  void onMount() {
    super.onMount();
    _world = null;
    for (final ancestor in ancestors()) {
      if (ancestor is World3D) {
        _world = ancestor;
        break;
      }
    }
    if (_world case final world?) {
      SpatialAudioRegistry3D.of(world).mixers.add(this);
    }
  }

  @override
  void update(double dt) {
    super.update(dt);
    final registry = SpatialAudioRegistry3D.maybeOf(_world);
    final activeListener = listener ?? registry?.firstListener;
    if (activeListener == null) {
      return;
    }
    final earPos = activeListener.earPosition; // syncs the listener once

    // 1. Evaluate & smoothly crossfade AudioZone3D reverb presets at `earPos`.
    _allZones
      ..clear()
      ..addAll(_registeredZones);
    if (registry != null) {
      for (final zone in registry.zones) {
        if (!_registeredZones.contains(zone)) {
          _allZones.add(zone);
        }
      }
    }
    final targetReverb = _evaluateTargetReverb(earPos);
    final alpha = dt > 0.0 && reverbCrossfadeSpeed > 0.0
        ? (1.0 - math.exp(-reverbCrossfadeSpeed * dt)).clamp(0.0, 1.0)
        : 1.0;
    final previousReverb = _currentReverb;
    final nextReverb = ReverbPreset3D.lerp(previousReverb, targetReverb, alpha);
    if (nextReverb.wetMix != previousReverb.wetMix ||
        nextReverb.decaySeconds != previousReverb.decaySeconds ||
        nextReverb.preDelayMs != previousReverb.preDelayMs ||
        nextReverb.name != previousReverb.name) {
      _currentReverb = nextReverb;
      onReverbChanged?.call(nextReverb);
    }

    // 2. Evaluate mix, pluggable occlusion, playback cursor, and audibility
    // priority for every emitter: those mounted in the world, then the
    // registered ones that are not.
    _candidates.clear();
    var playingCount = 0;
    if (registry != null) {
      final worldEmitters = registry.emitters;
      for (var i = 0; i < worldEmitters.length; i++) {
        final em = worldEmitters[i];
        if (_excluded.isNotEmpty && _excluded.contains(em)) {
          continue;
        }
        if (_mixEmitter(em, activeListener, earPos, dt)) {
          playingCount++;
        }
      }
    }
    for (var i = 0; i < _registeredEmitters.length; i++) {
      final em = _registeredEmitters[i];
      if (registry != null && identical(em.worldOrNull, _world)) {
        continue; // already mixed with the world's emitters
      }
      if (_mixEmitter(em, activeListener, earPos, dt)) {
        playingCount++;
      }
    }

    // 3. Rank audible candidates descending by `priorityScore` and pick top
    // `maxRealVoices`.
    _candidates.sort(_byScoreDescending);
    final realWinners = _winners..clear();
    final limit = math.min(maxRealVoices, _candidates.length);
    for (var i = 0; i < limit; i++) {
      realWinners[_candidates[i].emitter!] = _candidates[i].params!;
    }
    for (var i = 0; i < _candidates.length; i++) {
      _candidates[i]
        ..emitter = null
        ..params = null;
    }

    // 4. Demote any real voices no longer in `realWinners` -> `stopVoice`.
    final toDemote = _scratchEmitters..clear();
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
    toDemote.clear();

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

    _virtualVoiceCount = math.max(0, playingCount - realWinners.length);
    realWinners.clear();
  }

  /// Evaluates [em] for this update and adds it to the candidates when it is
  /// audible. Returns whether it is playing.
  bool _mixEmitter(
    SpatialAudioEmitter3D em,
    SpatialAudioListener3D activeListener,
    Vector3 earPos,
    double dt,
  ) {
    if (!em.playing) {
      _lastVoiceParams.remove(em);
      return false;
    }

    // Evaluate spatial mix (temporarily disable built-in binary occlusion if
    // custom continuous `occlusionQuery` is supplied so we don't double-apply
    // `occlusionGain`!).
    final query = occlusionQuery;
    final savedOcc = em.enableOcclusion;
    if (query != null) {
      em.enableOcclusion = false;
    }
    final baseMix = em.evaluateMixSynced(
      activeListener,
      world: em.worldOrNull ?? _world,
    );
    em
      ..enableOcclusion = savedOcc
      ..markMixedByMixer();
    em.onMixChanged?.call(baseMix);

    final m = em.worldTransformMatrix.storage;
    _emitterWorldPos.setValues(m[12], m[13], m[14]);

    final double occ;
    if (query != null) {
      occ = query(earPos, _emitterWorldPos).clamp(0.0, 1.0);
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
          return false;
        } else {
          em.playbackPosition = nextPos;
        }
      } else {
        em.playbackPosition = nextPos;
      }
    }

    final gainMult = query != null
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

    if (finalVolume >= virtualThresholdVolume && maxRealVoices > 0) {
      // Hysteresis bonus (`+0.015`) prevents rapid voice-stealing oscillation
      // between two nearly identical emitters.
      final alreadyRealBonus = _realVoiceHandles.containsKey(em) ? 0.015 : 0.0;
      final priorityBoost = 1.0 + em.audioPriority * 0.1;
      final score =
          finalVolume * math.max(0.1, priorityBoost) + alreadyRealBonus;
      final index = _candidates.length;
      if (index == _entryPool.length) {
        _entryPool.add(_EvaluatedEmitterEntry());
      }
      _candidates.add(
        _entryPool[index]
          ..emitter = em
          ..params = params
          ..priorityScore = score,
      );
    }
    return true;
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
    _lastVoiceParams.clear();
    SpatialAudioRegistry3D.maybeOf(_world)?.mixers.remove(this);
    _world = null;
    super.onRemove();
  }

  ReverbPreset3D _evaluateTargetReverb(Vector3 earPos) {
    if (_allZones.isEmpty) {
      return defaultReverb;
    }
    // Sort zones ascending by priority so higher-priority inner zones override
    // lower-priority outer zones proportionally to their weight `[0..1]`.
    _allZones.sort(_byAudioPriority);
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

  static int _byAudioPriority(AudioZone3D a, AudioZone3D b) {
    return a.audioPriority.compareTo(b.audioPriority);
  }
}
