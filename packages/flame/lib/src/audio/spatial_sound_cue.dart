import 'dart:math' as math;

import 'package:flame/camera.dart';
import 'package:flame/src/audio/audio_mixer.dart';
import 'package:flame/src/math/seeded_rng.dart';

/// Weighted clip variation entry inside a [SoundCue].
class SoundClipEntry({
  required final String assetId,
  final double weight = 1.0,
  final double durationSeconds = 0.8,
});

/// Policy used when a [SoundCue] reaches [SoundCue.maxConcurrentVoices].
enum VoiceStealPolicy() {
  /// Drops the new playback request.
  rejectNewest,

  /// Stops the longest-playing voice of this cue and plays the new one.
  stealOldest,

  /// Stops the lowest-gain voice of this cue and plays the new one.
  stealQuietest,
}

/// Declarative game sound cue combining weighted clip variations, anti-phasing
/// cooldown, concurrency voice stealing, and randomized pitch/volume jitter.
class SoundCue({
  required final String id,
  required final List<SoundClipEntry> clips,
  final AudioBusId bus = AudioBusId.sfx,
  final int maxConcurrentVoices = 4,
  final VoiceStealPolicy stealPolicy = VoiceStealPolicy.stealOldest,
  final double cooldownSeconds = 0.035,
  final double baseVolume = 1.0,
  final double volumeVariance = 0.06,
  final double basePitch = 1.0,
  final double pitchVariance = 0.05,
}) {
  this
    : assert(clips.isNotEmpty, 'SoundCue requires at least 1 SoundClipEntry');
}

extension SoundCueMixerPlayer on AudioMixer {
  static final Expando<Map<String, double>> _lastCueTriggerTimes =
      Expando<Map<String, double>>('SoundCueLastTrigger');
  static final SeededRng _fallbackRng = SeededRng(0x51A7E2D3);

  /// Plays [cue] through this [AudioMixer], enforcing `cooldownSeconds`,
  /// `maxConcurrentVoices` ([VoiceStealPolicy]), weighted clip selection, and
  /// pitch/volume variance.
  ///
  /// Returns the started [AudioVoiceHandle], or `null` if throttled by cooldown
  /// or rejected by [VoiceStealPolicy.rejectNewest].
  AudioVoiceHandle? playCue(
    SoundCue cue, {
    double volumeMultiplier = 1.0,
    double pan = 0.0,
    SeededRng? rng,
  }) {
    final triggerMap = _lastCueTriggerTimes[this] ??= <String, double>{};
    final lastTime = triggerMap[cue.id];
    if (lastTime != null && (clockSeconds - lastTime) < cue.cooldownSeconds) {
      return null;
    }

    // Check active voice concurrency for this cue.
    var cueVoices = 0;
    AudioVoiceHandle? oldest;
    AudioVoiceHandle? quietest;
    for (var i = 0; i < activeVoices.length; i++) {
      final v = activeVoices[i];
      if (v.cueId != cue.id) {
        continue;
      }
      cueVoices++;
      if (oldest == null || v.startedAtSeconds < oldest.startedAtSeconds) {
        oldest = v;
      }
      if (quietest == null || v.effectiveGain < quietest.effectiveGain) {
        quietest = v;
      }
    }

    if (cueVoices >= cue.maxConcurrentVoices) {
      switch (cue.stealPolicy) {
        case VoiceStealPolicy.rejectNewest:
          return null;
        case VoiceStealPolicy.stealOldest:
          if (oldest != null) {
            stopVoice(oldest);
          }
        case VoiceStealPolicy.stealQuietest:
          if (quietest != null) {
            stopVoice(quietest);
          }
      }
    }

    final random = rng ?? _fallbackRng;
    final selectedClip = _pickClip(cue.clips, random);
    final volJitter = cue.volumeVariance > 0.0
        ? (random.nextDouble() * 2.0 - 1.0) * cue.volumeVariance
        : 0.0;
    final pitchJitter = cue.pitchVariance > 0.0
        ? (random.nextDouble() * 2.0 - 1.0) * cue.pitchVariance
        : 0.0;

    final finalVol = ((cue.baseVolume + volJitter) * volumeMultiplier).clamp(
      0.0,
      2.0,
    );
    final finalPitch = (cue.basePitch + pitchJitter).clamp(0.25, 4.0);
    triggerMap[cue.id] = clockSeconds;

    return playClip(
      selectedClip.assetId,
      busId: cue.bus,
      cueId: cue.id,
      volume: finalVol,
      pitch: finalPitch,
      pan: pan,
      durationSeconds: selectedClip.durationSeconds,
    );
  }

  SoundClipEntry _pickClip(List<SoundClipEntry> clips, SeededRng rng) {
    if (clips.length == 1) {
      return clips.first;
    }
    var totalWeight = 0.0;
    for (var i = 0; i < clips.length; i++) {
      totalWeight += math.max(0.0, clips[i].weight);
    }
    if (totalWeight <= 0.0) {
      return clips[rng.nextInt(clips.length)];
    }
    var roll = rng.nextDouble() * totalWeight;
    for (var i = 0; i < clips.length; i++) {
      roll -= math.max(0.0, clips[i].weight);
      if (roll <= 0.0) {
        return clips[i];
      }
    }
    return clips.last;
  }
}

/// Distance attenuation curve for [SpatialAudioListener2D].
enum SpatialRolloffMode() {
  /// Linear attenuation from `1.0` at `minDistance` to `0.0` at `maxDistance`.
  linear,

  /// Smooth Hermite falloff (`1 - smoothstep`).
  smoothStep,

  /// Inverse-distance rolloff clamped to `0.0` at `maxDistance`.
  inverseSquare,
}

/// 2D spatial audio listener computing stereo pan (`-1.0 .. +1.0`) and distance
/// attenuation (`0.0 .. 1.0`) relative to a world listener point or
/// [CameraComponent].
class SpatialAudioListener2D({
  this.listenerX = 0.0,
  this.listenerY = 0.0,
  this.minDistance = 80.0,
  this.maxDistance = 900.0,
  this.stereoSpreadDistance = 420.0,
  this.maxPan = 0.85,
  this.rolloff = SpatialRolloffMode.smoothStep,
}) {
  /// Listener world X position.
  double listenerX;

  /// Listener world Y position.
  double listenerY;

  /// Inner radius inside which attenuation remains `1.0`.
  double minDistance;

  /// Outer radius beyond which sound is completely silent (`0.0`).
  double maxDistance;

  /// Horizontal offset from [listenerX] at which stereo pan reaches [maxPan].
  double stereoSpreadDistance;

  /// Maximum stereo pan magnitude (`0.0 .. 1.0`).
  double maxPan;

  /// Distance rolloff curve.
  SpatialRolloffMode rolloff;

  /// Synchronizes [listenerX] and [listenerY] from [camera]'s viewfinder
  /// position.
  void syncFromCamera(CameraComponent camera) {
    final pos = camera.viewfinder.position;
    listenerX = pos.x;
    listenerY = pos.y;
  }

  /// Evaluates `(gain, pan)` for an emitter at `(worldX, worldY)`.
  (double gain, double pan) evaluate(double worldX, double worldY) {
    final dx = worldX - listenerX;
    final dy = worldY - listenerY;
    final dist = math.sqrt(dx * dx + dy * dy);
    if (dist >= maxDistance) {
      return (0.0, 0.0);
    }

    final spread = math.max(1.0, stereoSpreadDistance);
    final pan = (dx / spread).clamp(-1.0, 1.0) * maxPan.clamp(0.0, 1.0);

    if (dist <= minDistance) {
      return (1.0, pan);
    }

    final span = math.max(1e-4, maxDistance - minDistance);
    final t = ((dist - minDistance) / span).clamp(0.0, 1.0);
    final double gain;
    switch (rolloff) {
      case SpatialRolloffMode.linear:
        gain = 1.0 - t;
      case SpatialRolloffMode.smoothStep:
        gain = 1.0 - t * t * (3.0 - 2.0 * t);
      case SpatialRolloffMode.inverseSquare:
        final raw = 1.0 / (1.0 + 8.0 * t * t);
        // Smoothly reach 0 at t == 1.
        gain = raw * (1.0 - t);
    }
    return (gain.clamp(0.0, 1.0), pan);
  }

  /// Plays [cue] on [mixer] with 2D spatial attenuation and stereo panning
  /// computed at `(worldX, worldY)` (skipping playback if out of earshot).
  AudioVoiceHandle? playCueAt(
    AudioMixer mixer,
    SoundCue cue, {
    required double worldX,
    required double worldY,
    double volumeMultiplier = 1.0,
    SeededRng? rng,
  }) {
    final (gain, pan) = evaluate(worldX, worldY);
    if (gain <= 1e-3) {
      return null;
    }
    return mixer.playCue(
      cue,
      volumeMultiplier: gain * volumeMultiplier,
      pan: pan,
      rng: rng,
    );
  }
}
