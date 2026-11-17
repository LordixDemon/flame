import 'dart:math' as math;

import 'package:flame/src/audio/audio_mixer.dart';

/// Vertical stem descriptor inside an adaptive soundtrack.
///
/// A stem with a positive [minIntensity] is silent up to that intensity, rises
/// along a smoothstep curve to [maxVolume] at [fullIntensity] and stays there.
/// If [fullIntensity] does not exceed [minIntensity] there is nothing to fade
/// along and the stem switches on at [minIntensity].
///
/// A stem whose [minIntensity] is `0.0` or less (the default) is a base layer:
/// it plays at [maxVolume] at every intensity.
///
/// Either way the volume of a stem never drops when the intensity rises.
class MusicStemLayer({
  required final String assetId,
  final double minIntensity = 0.0,
  final double fullIntensity = 1.0,
  final double maxVolume = 1.0,
});

/// Adaptive soundtrack controller supporting smooth horizontal track crossfades
/// and vertical intensity stem layering (`intensity` in `0.0 .. 1.0`) over
/// [AudioMixer].
class AdaptiveMusicController({
  required this.mixer,
  this.smoothingRate = 4.0,
}) {
  /// Target mixer (`AudioBusId.music`).
  final AudioMixer mixer;

  /// Exponential smoothing rate (per second) for stem intensity changes.
  double smoothingRate;

  double _targetIntensity = 0.0;
  double _smoothedIntensity = 0.0;

  String? _activeTrackId;
  AudioVoiceHandle? _currentTrackVoice;
  AudioVoiceHandle? _fadingOutVoice;
  double _crossfadeDuration = 0.0;
  double _crossfadeElapsed = 0.0;
  double _currentTrackBaseVolume = 1.0;

  /// Volume the outgoing track had when the cross-fade began.
  double _fadingOutStartVolume = 0.0;

  final List<(MusicStemLayer, AudioVoiceHandle)> _activeStems =
      <(MusicStemLayer, AudioVoiceHandle)>[];

  /// Target normalized gameplay intensity (`0.0 .. 1.0`).
  double get targetIntensity => _targetIntensity;
  set targetIntensity(double value) {
    _targetIntensity = value.clamp(0.0, 1.0);
  }

  /// Current smoothed intensity (`0.0 .. 1.0`).
  double get currentIntensity => _smoothedIntensity;

  /// Currently playing primary track asset ID.
  String? get activeTrackId => _activeTrackId;

  /// Crossfades horizontally to [trackAssetId] over [crossfadeSeconds].
  ///
  /// The outgoing track fades from the volume it has at this moment down to
  /// silence while the new one rises from silence to [volume]. Switching again
  /// before a cross-fade has finished stops the track that was already fading
  /// out and fades the half-risen one out from where it is.
  void playTrack(
    String trackAssetId, {
    double volume = 1.0,
    double crossfadeSeconds = 1.2,
  }) {
    if (_activeTrackId == trackAssetId && _currentTrackVoice != null) {
      return;
    }
    if (_fadingOutVoice != null) {
      mixer.stopVoice(_fadingOutVoice!);
      _fadingOutVoice = null;
    }
    _activeTrackId = trackAssetId;
    _currentTrackBaseVolume = volume.clamp(0.0, 2.0);

    if (_currentTrackVoice != null && crossfadeSeconds > 1e-3) {
      _fadingOutVoice = _currentTrackVoice;
      _fadingOutStartVolume = _currentTrackVoice!.sourceVolume;
      _crossfadeDuration = crossfadeSeconds;
      _crossfadeElapsed = 0.0;
      _currentTrackVoice = mixer.playClip(
        trackAssetId,
        busId: AudioBusId.music,
        volume: 0.0,
        loop: true,
      );
    } else {
      if (_currentTrackVoice != null) {
        mixer.stopVoice(_currentTrackVoice!);
      }
      _crossfadeDuration = 0.0;
      _currentTrackVoice = mixer.playClip(
        trackAssetId,
        busId: AudioBusId.music,
        volume: _currentTrackBaseVolume,
        loop: true,
      );
    }
  }

  /// Starts synchronized vertical [stems] whose gains track [targetIntensity].
  void startLayeredStems(List<MusicStemLayer> stems) {
    stopLayeredStems();
    for (var i = 0; i < stems.length; i++) {
      final stem = stems[i];
      final w = _computeStemWeight(stem, _smoothedIntensity);
      final voice = mixer.playClip(
        stem.assetId,
        busId: AudioBusId.music,
        volume: w,
        loop: true,
      );
      _activeStems.add((stem, voice));
    }
  }

  /// Stops all vertical stem voices.
  void stopLayeredStems() {
    for (var i = 0; i < _activeStems.length; i++) {
      mixer.stopVoice(_activeStems[i].$2);
    }
    _activeStems.clear();
  }

  double _computeStemWeight(MusicStemLayer stem, double intensity) {
    if (stem.minIntensity <= 0.0) {
      // Base layer: always on.
      return stem.maxVolume;
    }
    final span = stem.fullIntensity - stem.minIntensity;
    if (span <= 1e-5) {
      // No ramp to fade along: the stem switches on at `minIntensity`.
      return intensity >= stem.minIntensity ? stem.maxVolume : 0.0;
    }
    final t = ((intensity - stem.minIntensity) / span).clamp(0.0, 1.0);
    return t * t * (3.0 - 2.0 * t) * stem.maxVolume;
  }

  /// Steps crossfades and stem intensity envelopes by [dt] seconds.
  void update(double dt) {
    if (dt <= 0.0) {
      return;
    }
    final alpha = 1.0 - math.exp(-math.max(0.1, smoothingRate) * dt);
    _smoothedIntensity += (_targetIntensity - _smoothedIntensity) * alpha;

    if (_crossfadeDuration > 0.0) {
      _crossfadeElapsed += dt;
      final t = (_crossfadeElapsed / _crossfadeDuration).clamp(0.0, 1.0);
      _currentTrackVoice?.sourceVolume = _currentTrackBaseVolume * t;
      _fadingOutVoice?.sourceVolume = _fadingOutStartVolume * (1.0 - t);
      if (t >= 1.0 && _fadingOutVoice != null) {
        mixer.stopVoice(_fadingOutVoice!);
        _fadingOutVoice = null;
        _crossfadeDuration = 0.0;
      }
    }

    for (var i = 0; i < _activeStems.length; i++) {
      final (stem, voice) = _activeStems[i];
      voice.sourceVolume = _computeStemWeight(stem, _smoothedIntensity);
    }
  }
}
