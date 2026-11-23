import 'dart:math' as math;
import 'dart:ui' show VoidCallback;

import 'package:flame/components.dart' show Component;
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/model.dart';
import 'package:flame_3d/src/cinematics/virtual_camera_3d.dart';

part 'timeline_clip_tracks_3d.dart';
part 'timeline_keyframe_tracks_3d.dart';

/// Interpolation curve between adjacent keyframes on a [Timeline3D] track.
enum TimelineInterpolation3D() {
  /// Holds the previous keyframe value until the next keyframe time.
  step,

  /// Linearly interpolates (`Vector3` LERP / shortest-arc `Quaternion` SLERP).
  linear,

  /// Cubic Hermite spline interpolation using explicit incoming/outgoing
  /// tangents (or zero-tangent smoothstep `3t^2 - 2t^3` when tangents are
  /// omitted).
  cubicHermite,
}

/// Playback / scrub direction passed to [EventMarkerTrack3D] listeners.
enum TimelineDirection3D() {
  /// Advancing toward higher timestamps (`dt > 0` or forward `seek`).
  forward,

  /// Scrubbing or playing toward lower timestamps (`dt < 0` / reverse `seek`).
  backward,
}

/// Base track inside a [Timeline3D] cutscene or choreography sequence.
abstract class TimelineTrack3D({
  var bool enabled = true,
}) {
  /// Latest keyframe or clip end timestamp (in seconds) on this track.
  double get endTime;

  /// Evaluates and applies this track at [time] seconds.
  void evaluate(double time);
}

// =============================================================================
// Timeline3D Sequencer Component
// =============================================================================

/// Multi-track deterministic 3D cinematic & choreography sequencer.
class Timeline3D({
  List<TimelineTrack3D> tracks = const [],
  double? duration,
  var bool loop = false,
  var bool autoPlay = false,
  var double speed = 1.0,
  this.onComplete,
  super.priority,
}) extends Component {
  this {
    _tracks.addAll(tracks);
    _explicitDuration = duration;
    if (autoPlay) {
      play();
    }
  }

  final List<TimelineTrack3D> _tracks = [];
  double? _explicitDuration;
  double _currentTime = 0.0;
  bool _isPlaying = false;
  bool _atInitialStart = true;

  /// Optional callback invoked when non-looping playback reaches [duration].
  VoidCallback? onComplete;

  /// Registered tracks in evaluation order.
  List<TimelineTrack3D> get tracks =>
      List<TimelineTrack3D>.unmodifiable(_tracks);

  /// Appends [track] to this timeline.
  void addTrack(TimelineTrack3D track) {
    _tracks.add(track);
  }

  /// Total sequence duration in seconds (explicit override or max track
  /// `endTime`).
  double get duration {
    final explicit = _explicitDuration;
    if (explicit != null) {
      return math.max(0.0, explicit);
    }
    var best = 0.0;
    for (var i = 0; i < _tracks.length; i++) {
      final end = _tracks[i].endTime;
      if (end > best) {
        best = end;
      }
    }
    return best;
  }

  set duration(double value) {
    _explicitDuration = math.max(0.0, value);
  }

  /// Current playhead position in seconds (`[0..duration]`).
  double get currentTime => _currentTime;

  /// Whether playback is currently active.
  bool get isPlaying => _isPlaying;

  /// Starts or resumes playback from [currentTime].
  ///
  /// A non-looping timeline that already reached the end it plays towards
  /// starts over from the other end: from `0` when it reached [duration]
  /// playing forward, from [duration] when it reached `0` playing backward
  /// (a negative [speed]).
  void play() {
    final dur = duration;
    if (!loop && dur > 0.0) {
      if (speed < 0.0) {
        if (_currentTime <= 1e-9) {
          _currentTime = dur;
          _atInitialStart = true;
        }
      } else if (_currentTime >= dur - 1e-9) {
        _currentTime = 0.0;
        _atInitialStart = true;
      }
    }
    _isPlaying = true;
    _evaluateNonEventTracks(_currentTime);
  }

  @override
  void onRemove() {
    for (final track in _tracks) {
      if (track is AnimationClipTrack3D) {
        track.releaseModelClock();
      }
    }
    super.onRemove();
  }

  /// Pauses playback at the current playhead timestamp.
  void pause() {
    _isPlaying = false;
  }

  /// Stops playback and rewinds the playhead to `0.0`.
  void stop() {
    _isPlaying = false;
    _currentTime = 0.0;
    _atInitialStart = true;
    _evaluateNonEventTracks(0.0);
  }

  /// Deterministically jumps the playhead to [timeSeconds] (clamped to
  /// `[0..duration]`), evaluating every track and optionally firing crossed
  /// [EventMarkerTrack3D] cues in the seek direction.
  void seek(double timeSeconds, {bool fireEvents = true}) {
    final dur = duration;
    final clamped = dur > 0.0
        ? timeSeconds.clamp(0.0, dur)
        : math.max(0.0, timeSeconds);
    final prev = _currentTime;
    final wasInitial = _atInitialStart;
    _currentTime = clamped;
    _atInitialStart = false;

    if (fireEvents) {
      if (clamped > prev || (wasInitial && clamped == prev)) {
        _fireMarkers(
          prev,
          clamped,
          direction: TimelineDirection3D.forward,
          inclusiveStart: wasInitial,
        );
      } else if (clamped < prev) {
        _fireMarkers(
          prev,
          clamped,
          direction: TimelineDirection3D.backward,
          inclusiveStart: false,
        );
      }
    }
    _evaluateNonEventTracks(_currentTime);
  }

  @override
  void update(double dt) {
    super.update(dt);
    if (!_isPlaying || dt == 0.0 || speed == 0.0) {
      return;
    }
    final delta = dt * speed;
    final dur = duration;

    if (dur <= 1e-9) {
      if (_atInitialStart) {
        _atInitialStart = false;
        _fireMarkers(
          0.0,
          0.0,
          direction: TimelineDirection3D.forward,
          inclusiveStart: true,
        );
      }
      _evaluateNonEventTracks(0.0);
      if (!loop) {
        _isPlaying = false;
        onComplete?.call();
      }
      return;
    }

    if (delta > 0.0) {
      if (loop) {
        var cur = _currentTime;
        var rem = delta;
        var inc = _atInitialStart;
        _atInitialStart = false;
        var guard = 0;
        while (cur + rem > dur && guard++ < 64) {
          _fireMarkers(
            cur,
            dur,
            direction: TimelineDirection3D.forward,
            inclusiveStart: inc,
          );
          rem -= dur - cur;
          cur = 0.0;
          inc = true;
        }
        if (cur + rem > dur) {
          cur = (cur + rem) % dur;
          rem = 0.0;
        }
        final next = cur + rem;
        _fireMarkers(
          cur,
          next,
          direction: TimelineDirection3D.forward,
          inclusiveStart: inc,
        );
        _currentTime = next;
      } else {
        final rawNext = _currentTime + delta;
        final next = math.min(dur, rawNext);
        final inc = _atInitialStart;
        _atInitialStart = false;
        _fireMarkers(
          _currentTime,
          next,
          direction: TimelineDirection3D.forward,
          inclusiveStart: inc,
        );
        _currentTime = next;
        _evaluateNonEventTracks(_currentTime);
        if (rawNext >= dur - 1e-9) {
          _isPlaying = false;
          onComplete?.call();
        }
        return;
      }
    } else {
      final backAmount = -delta;
      if (loop) {
        var cur = _currentTime;
        var rem = backAmount;
        var inc = _atInitialStart;
        _atInitialStart = false;
        var guard = 0;
        while (cur - rem < 0.0 && guard++ < 64) {
          _fireMarkers(
            cur,
            0.0,
            direction: TimelineDirection3D.backward,
            inclusiveStart: inc,
          );
          rem -= cur;
          cur = dur;
          inc = true;
        }
        final next = (cur - rem).clamp(0.0, dur);
        _fireMarkers(
          cur,
          next,
          direction: TimelineDirection3D.backward,
          inclusiveStart: inc,
        );
        _currentTime = next;
      } else {
        final rawNext = _currentTime - backAmount;
        final next = math.max(0.0, rawNext);
        final inc = _atInitialStart;
        _atInitialStart = false;
        _fireMarkers(
          _currentTime,
          next,
          direction: TimelineDirection3D.backward,
          inclusiveStart: inc,
        );
        _currentTime = next;
        _evaluateNonEventTracks(_currentTime);
        if (rawNext <= 1e-9) {
          _isPlaying = false;
          onComplete?.call();
        }
        return;
      }
    }

    _evaluateNonEventTracks(_currentTime);
  }

  void _fireMarkers(
    double from,
    double to, {
    required TimelineDirection3D direction,
    required bool inclusiveStart,
  }) {
    for (var i = 0; i < _tracks.length; i++) {
      final track = _tracks[i];
      if (track is EventMarkerTrack3D && track.enabled) {
        track.fireRange(
          from,
          to,
          direction: direction,
          inclusiveStart: inclusiveStart,
        );
      }
    }
  }

  void _evaluateNonEventTracks(double time) {
    for (var i = 0; i < _tracks.length; i++) {
      final track = _tracks[i];
      if (track.enabled && track is! EventMarkerTrack3D) {
        track.evaluate(time);
      }
    }
  }
}
