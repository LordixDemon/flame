import 'dart:math' as math;

import 'package:flame/src/audio/audio_mixer.dart';

/// Metadata for a musical track with an introductory phrase `[0 .. loopStart)`
/// followed by an infinite seamless loop region `[loopStart .. loopEnd)`.
class const LoopRegionTrack({
  required this.assetId,
  required this.durationSeconds,
  this.loopStartSeconds = 0.0,
  double? loopEndSeconds,
  this.defaultVolume = 1.0,
  this.defaultPitch = 1.0,
}) {
  this
    : assert(durationSeconds > 0.0, 'durationSeconds must be > 0.'),
      assert(loopStartSeconds >= 0.0, 'loopStartSeconds must be >= 0.');

  /// Audio asset identifier or path.
  final String assetId;

  /// Full clip length in seconds.
  final double durationSeconds;

  /// Loop-in timestamp in seconds (`0.0` loops from the very beginning).
  final double loopStartSeconds;

  final double? _loopEndSeconds = loopEndSeconds;

  /// Loop-out timestamp in seconds (must be `> loopStartSeconds`).
  double get loopEndSeconds => _loopEndSeconds ?? durationSeconds;

  /// Default base gain (`0.0 .. 2.0`).
  final double defaultVolume;

  /// Default playback pitch/rate (`0.25 .. 4.0`).
  final double defaultPitch;

  /// Length of the repeating loop body (`loopEndSeconds - loopStartSeconds`).
  double get loopSpanSeconds =>
      math.max(1e-6, loopEndSeconds - loopStartSeconds);

  /// Advances [currentCursor] by `dt * pitch`, wrapping arbitrarily large steps
  /// cleanly inside `[loopStartSeconds, loopEndSeconds)`.
  ({double cursor, int wraps}) advanceCursor(
    double currentCursor,
    double deltaTrackSeconds,
  ) {
    assert(
      loopEndSeconds > loopStartSeconds,
      'loopEndSeconds ($loopEndSeconds) must exceed '
      'loopStartSeconds ($loopStartSeconds).',
    );
    if (deltaTrackSeconds <= 0.0) {
      return (cursor: currentCursor, wraps: 0);
    }
    final rawNext = currentCursor + deltaTrackSeconds;
    if (rawNext < loopEndSeconds) {
      return (cursor: rawNext, wraps: 0);
    }
    final span = loopSpanSeconds;
    final pastLoopStart = rawNext - loopStartSeconds;
    final wraps = (pastLoopStart / span).floor();
    final wrappedOffset = pastLoopStart - wraps * span;
    return (
      cursor: (loopStartSeconds + wrappedOffset).clamp(
        loopStartSeconds,
        loopEndSeconds - 1e-9,
      ),
      wraps: math.max(1, wraps),
    );
  }
}

/// Saved BGM transport snapshot pushed onto [BgmTransportStack] when entering
/// a battle, inn, or sub-scene.
class const BgmSavedState({
  required this.track,
  required this.cursorSeconds,
  required this.volume,
  required this.pitch,
  required this.loopWrapCount,
}) {
  /// Interrupted track definition.
  final LoopRegionTrack track;

  /// Exact playback cursor in seconds at the moment of interruption.
  final double cursorSeconds;

  /// Target track volume prior to interruption.
  final double volume;

  /// Track pitch multiplier prior to interruption.
  final double pitch;

  /// Number of loop wraps completed prior to interruption.
  final int loopWrapCount;
}

/// RPG Background Music (BGM) & Musical Effect (ME) transport manager with:
/// - **Intro + Loop-Region Wrapping (`[0..loopStart)` once, then
///   `[loopStart..loopEnd)` forever)**,
/// - **Nested Scene Stack (`pushBgm` / `popAndResumeBgm`)** preserving the
///   exact playback second of the overworld/dungeon theme across battles,
/// - **Musical Fanfare Interruption (`playMusicalEffect`)** freezing or ducking
///   the active BGM until a victory/inn jingle finishes and smoothly fading
///   BGM back in.
class BgmTransportStack({
  this.mixer,
  this.onSeekVoice,
}) {
  /// Optional [AudioMixer] receiving `AudioBusId.music` voice commands.
  final AudioMixer? mixer;

  /// Optional low-level seek hook invoked whenever a track wraps to
  /// `loopStartSeconds` or resumes mid-track after [popAndResumeBgm].
  final void Function(
    String assetId,
    int? voiceId,
    double targetCursorSeconds,
  )?
  onSeekVoice;

  final List<BgmSavedState> _stack = <BgmSavedState>[];

  LoopRegionTrack? _activeTrack;
  AudioVoiceHandle? _activeVoice;
  double _cursorSeconds = 0.0;
  double _baseVolume = 1.0;
  double _pitch = 1.0;
  int _loopWrapCount = 0;

  double _fadeGain = 1.0;
  double _fadeTarget = 1.0;
  double _fadeRatePerSec = 0.0;
  bool _stopAfterFadeOut = false;

  // Musical Effect (ME) fanfare state:
  String? _activeMeAssetId;
  AudioVoiceHandle? _activeMeVoice;
  double _meRemainingSeconds = 0.0;
  double _meBgmDuckGain = 0.0;
  double _meResumeFadeInSeconds = 0.5;

  /// Currently loaded BGM track, or `null` if stopped.
  LoopRegionTrack? get activeTrack => _activeTrack;

  /// Exact playback cursor of [activeTrack] in seconds.
  double get cursorSeconds => _cursorSeconds;

  /// Number of times [activeTrack] has wrapped around `loopEnd -> loopStart`.
  int get loopWrapCount => _loopWrapCount;

  /// Number of interrupted BGM states currently saved on the stack.
  int get savedStackDepth => _stack.length;

  /// Read-only view of saved BGM stack entries.
  List<BgmSavedState> get savedStack =>
      List<BgmSavedState>.unmodifiable(_stack);

  /// Whether a Musical Effect (ME) fanfare is currently playing.
  bool get isMusicalEffectPlaying => _activeMeAssetId != null;

  /// Current post-fade, post-ME-duck effective BGM volume multiplier.
  double get effectiveBgmVolume {
    if (_activeTrack == null) {
      return 0.0;
    }
    final duck = isMusicalEffectPlaying ? _meBgmDuckGain : 1.0;
    return (_baseVolume * _fadeGain * duck).clamp(0.0, 2.0);
  }

  /// Starts playing [track] on the main BGM transport.
  ///
  /// If `track.assetId` is already playing, updates volume/pitch smoothly
  /// without restarting from `0.0` unless [restartIfSame] is `true`.
  void playBgm(
    LoopRegionTrack track, {
    double? volume,
    double? pitch,
    double startAtSeconds = 0.0,
    double fadeInSeconds = 0.0,
    bool restartIfSame = false,
  }) {
    final nextVol = volume ?? track.defaultVolume;
    final nextPitch = pitch ?? track.defaultPitch;

    if (!restartIfSame &&
        _activeTrack != null &&
        _activeTrack!.assetId == track.assetId &&
        !_stopAfterFadeOut) {
      _activeTrack = track;
      _baseVolume = nextVol;
      _pitch = nextPitch;
      _configureFade(target: 1.0, duration: fadeInSeconds);
      _syncMixerVoice();
      return;
    }

    _stopActiveVoice();
    _activeTrack = track;
    _cursorSeconds = startAtSeconds.clamp(0.0, track.loopEndSeconds - 1e-6);
    _baseVolume = nextVol;
    _pitch = nextPitch;
    _loopWrapCount = 0;
    _stopAfterFadeOut = false;

    if (fadeInSeconds > 0.0) {
      _fadeGain = 0.0;
      _configureFade(target: 1.0, duration: fadeInSeconds);
    } else {
      _fadeGain = 1.0;
      _fadeTarget = 1.0;
      _fadeRatePerSec = 0.0;
    }

    _startMixerVoice(track, seekSeconds: _cursorSeconds);
  }

  /// Saves the current BGM + exact [cursorSeconds] onto the stack and starts
  /// [subSceneTrack] (for example when transitioning from Overworld into
  /// Battle).
  void pushBgm(
    LoopRegionTrack subSceneTrack, {
    double fadeInSeconds = 0.25,
    double? volume,
    double? pitch,
  }) {
    if (_activeTrack != null && !_stopAfterFadeOut) {
      _stack.add(
        BgmSavedState(
          track: _activeTrack!,
          cursorSeconds: _cursorSeconds,
          volume: _baseVolume,
          pitch: _pitch,
          loopWrapCount: _loopWrapCount,
        ),
      );
    }
    playBgm(
      subSceneTrack,
      volume: volume,
      pitch: pitch,
      fadeInSeconds: fadeInSeconds,
      restartIfSame: true,
    );
  }

  /// Pops the most recently saved BGM from the stack and resumes it from its
  /// exact saved timestamp (without replaying its `[0..loopStart)` intro if it
  /// was already inside the loop region!).
  ///
  /// Returns `true` if a saved BGM was restored, or `false` (stopping current
  /// BGM) if the stack was empty.
  bool popAndResumeBgm({double fadeInSeconds = 0.4}) {
    if (_stack.isEmpty) {
      stopBgm(fadeOutSeconds: fadeInSeconds);
      return false;
    }
    final restored = _stack.removeLast();
    _stopActiveVoice();
    _activeTrack = restored.track;
    _cursorSeconds = restored.cursorSeconds;
    _baseVolume = restored.volume;
    _pitch = restored.pitch;
    _loopWrapCount = restored.loopWrapCount;
    _stopAfterFadeOut = false;

    if (fadeInSeconds > 0.0) {
      _fadeGain = 0.0;
      _configureFade(target: 1.0, duration: fadeInSeconds);
    } else {
      _fadeGain = 1.0;
      _fadeTarget = 1.0;
      _fadeRatePerSec = 0.0;
    }

    _startMixerVoice(restored.track, seekSeconds: _cursorSeconds);
    return true;
  }

  /// Stops the active BGM, optionally fading out over [fadeOutSeconds].
  void stopBgm({double fadeOutSeconds = 0.0}) {
    if (_activeTrack == null) {
      return;
    }
    if (fadeOutSeconds <= 0.0) {
      _stopActiveVoice();
      _activeTrack = null;
      _cursorSeconds = 0.0;
      _loopWrapCount = 0;
      _stopAfterFadeOut = false;
      return;
    }
    _stopAfterFadeOut = true;
    _configureFade(target: 0.0, duration: fadeOutSeconds);
  }

  /// Plays a non-looping Musical Effect (ME) jingle (such as Victory Fanfare or
  /// Inn Rest), ducking or pausing (`bgmDuckGain == 0.0`) the active BGM until
  /// [durationSeconds] elapses, then fading BGM back in over
  /// [resumeFadeInSeconds].
  void playMusicalEffect(
    String fanfareAssetId, {
    required double durationSeconds,
    double volume = 1.0,
    double bgmDuckGain = 0.0,
    double resumeFadeInSeconds = 0.5,
  }) {
    assert(durationSeconds > 0.0, 'ME durationSeconds must be > 0.');
    _stopActiveMeVoice();
    _activeMeAssetId = fanfareAssetId;
    _meRemainingSeconds = durationSeconds;
    _meBgmDuckGain = bgmDuckGain.clamp(0.0, 1.0);
    _meResumeFadeInSeconds = math.max(0.0, resumeFadeInSeconds);

    final m = mixer;
    if (m != null) {
      _activeMeVoice = m.playClip(
        fanfareAssetId,
        busId: AudioBusId.music,
        volume: volume,
        durationSeconds: durationSeconds,
      );
    }
    _syncMixerVoice();
  }

  /// Advances fade envelopes, Musical Effect timers, and sample-accurate loop
  /// region wrapping by [dt] seconds.
  void update(double dt) {
    if (dt <= 0.0) {
      return;
    }

    // 1. Advance Musical Effect (ME) jingle if active.
    var remainingDtForBgm = dt;
    if (_activeMeAssetId != null) {
      if (dt < _meRemainingSeconds) {
        _meRemainingSeconds -= dt;
        // When bgmDuckGain == 0, freeze BGM cursor completely during fanfare!
        if (_meBgmDuckGain <= 1e-6) {
          remainingDtForBgm = 0.0;
        }
      } else {
        final timeSpentInMe = _meRemainingSeconds;
        _stopActiveMeVoice();
        _activeMeAssetId = null;
        _meRemainingSeconds = 0.0;
        if (_meBgmDuckGain <= 1e-6) {
          remainingDtForBgm = dt - timeSpentInMe;
        }
        if (_activeTrack != null && _meResumeFadeInSeconds > 0.0) {
          _fadeGain = _meBgmDuckGain;
          _configureFade(target: 1.0, duration: _meResumeFadeInSeconds);
        }
      }
    }

    // 2. Advance BGM fade envelope & loop cursor.
    final track = _activeTrack;
    if (track == null) {
      return;
    }

    if (_fadeRatePerSec > 0.0 && (_fadeGain - _fadeTarget).abs() > 1e-6) {
      final step = _fadeRatePerSec * dt;
      if (_fadeGain < _fadeTarget) {
        _fadeGain = math.min(_fadeTarget, _fadeGain + step);
      } else {
        _fadeGain = math.max(_fadeTarget, _fadeGain - step);
      }
      if ((_fadeGain - _fadeTarget).abs() <= 1e-6) {
        _fadeGain = _fadeTarget;
        _fadeRatePerSec = 0.0;
        if (_stopAfterFadeOut && _fadeGain <= 1e-6) {
          _stopActiveVoice();
          _activeTrack = null;
          _cursorSeconds = 0.0;
          _stopAfterFadeOut = false;
          return;
        }
      }
    }

    if (remainingDtForBgm > 0.0) {
      final stepTrackSec = remainingDtForBgm * _pitch;
      final next = track.advanceCursor(_cursorSeconds, stepTrackSec);
      _cursorSeconds = next.cursor;
      if (next.wraps > 0) {
        _loopWrapCount += next.wraps;
        onSeekVoice?.call(track.assetId, _activeVoice?.voiceId, _cursorSeconds);
      }
    }

    _syncMixerVoice();
  }

  /// Clears all saved stack entries and stops active BGM/ME voices.
  void clearAll() {
    _stack.clear();
    _stopActiveMeVoice();
    _activeMeAssetId = null;
    _meRemainingSeconds = 0.0;
    _stopActiveVoice();
    _activeTrack = null;
    _cursorSeconds = 0.0;
    _loopWrapCount = 0;
    _stopAfterFadeOut = false;
  }

  void _configureFade({required double target, required double duration}) {
    _fadeTarget = target.clamp(0.0, 1.0);
    if (duration <= 1e-6) {
      _fadeGain = _fadeTarget;
      _fadeRatePerSec = 0.0;
    } else {
      _fadeRatePerSec = (_fadeTarget - _fadeGain).abs() / duration;
    }
  }

  void _startMixerVoice(LoopRegionTrack track, {required double seekSeconds}) {
    final m = mixer;
    if (m != null) {
      _activeVoice = m.playClip(
        track.assetId,
        busId: AudioBusId.music,
        loop: true,
        volume: effectiveBgmVolume,
        pitch: _pitch,
        durationSeconds: track.durationSeconds,
      );
    }
    if (seekSeconds > 0.0) {
      onSeekVoice?.call(track.assetId, _activeVoice?.voiceId, seekSeconds);
    }
  }

  void _syncMixerVoice() {
    final voice = _activeVoice;
    final m = mixer;
    if (voice != null && m != null && !voice.isStopped) {
      voice
        ..sourceVolume = effectiveBgmVolume
        ..pitch = _pitch;
    }
  }

  void _stopActiveVoice() {
    final voice = _activeVoice;
    final m = mixer;
    if (voice != null && m != null && !voice.isStopped) {
      m.stopVoice(voice);
    }
    _activeVoice = null;
  }

  void _stopActiveMeVoice() {
    final voice = _activeMeVoice;
    final m = mixer;
    if (voice != null && m != null && !voice.isStopped) {
      m.stopVoice(voice);
    }
    _activeMeVoice = null;
  }
}
