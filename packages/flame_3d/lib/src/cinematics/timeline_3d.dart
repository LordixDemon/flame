import 'dart:math' as math;
import 'dart:ui' show VoidCallback;

import 'package:flame/components.dart' show Component;
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/game.dart' show NotifyingQuaternion;
import 'package:flame_3d/model.dart';
import 'package:flame_3d/src/cinematics/virtual_camera_3d.dart';

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
// 1. CameraShotTrack3D
// =============================================================================

/// A scheduled camera cut/blend span on a [CameraShotTrack3D].
class CameraShot3D({
  required final VirtualCamera3D camera,
  required final double startTime,
  required final double endTime,
  final int activePriority = 100,
  final double? blendDurationOverride,
}) {
  this : assert(endTime >= startTime, 'endTime must be >= startTime');
}

/// Activates [VirtualCamera3D] shots over `[startTime..endTime]` intervals so
/// a [VirtualCameraBrain3D] automatically cuts or cross-blends between them.
class CameraShotTrack3D({
  required List<CameraShot3D> shots,
  super.enabled,
}) extends TimelineTrack3D {
  this {
    for (final s in this.shots) {
      _baselinePriorities.putIfAbsent(s.camera, () => s.camera.priority);
    }
  }

  /// Shots ordered by `startTime`.
  final List<CameraShot3D> shots = _sortShots(shots);

  final Map<VirtualCamera3D, int> _baselinePriorities = {};

  static List<CameraShot3D> _sortShots(List<CameraShot3D> raw) {
    final copy = List<CameraShot3D>.of(raw)
      ..sort((a, b) => a.startTime.compareTo(b.startTime));
    return List<CameraShot3D>.unmodifiable(copy);
  }

  @override
  double get endTime {
    var best = 0.0;
    for (var i = 0; i < shots.length; i++) {
      if (shots[i].endTime > best) {
        best = shots[i].endTime;
      }
    }
    return best;
  }

  @override
  void evaluate(double time) {
    // Later overlapping shots win when `[startTime..endTime]` spans overlap.
    CameraShot3D? winner;
    for (var i = 0; i < shots.length; i++) {
      final s = shots[i];
      final isLast = i == shots.length - 1;
      final inStart = time >= s.startTime - 1e-9;
      final inEnd = isLast ? time <= s.endTime + 1e-9 : time < s.endTime - 1e-9;
      if (inStart && inEnd) {
        winner = s;
      }
    }

    for (var i = 0; i < shots.length; i++) {
      final s = shots[i];
      if (!identical(s, winner)) {
        s.camera
          ..enabled = false
          ..priority = _baselinePriorities[s.camera] ?? 0;
      }
    }

    if (winner != null) {
      if (winner.blendDurationOverride != null) {
        winner.camera.blendDurationOverride = winner.blendDurationOverride;
      }
      winner.camera
        ..enabled = true
        ..priority = winner.activePriority;
    }
  }
}

// =============================================================================
// 2. TransformTrack3D
// =============================================================================

/// Keyframe entry for [TransformTrack3D] channels.
class TransformKeyframe3D<T>({
  required final double time,
  required final T value,
  final TimelineInterpolation3D interpolation = TimelineInterpolation3D.linear,
  final T? inTangent,
  final T? outTangent,
});

/// Keyframed 3D `position`, `rotation`, and `scale` track driving a
/// [Component3D] with step, linear, and cubic Hermite interpolation.
class TransformTrack3D({
  required final Component3D target,
  List<TransformKeyframe3D<Vector3>> positionKeys = const [],
  List<TransformKeyframe3D<Quaternion>> rotationKeys = const [],
  List<TransformKeyframe3D<Vector3>> scaleKeys = const [],
  super.enabled,
}) extends TimelineTrack3D {
  /// Sorted translation keyframes.
  final List<TransformKeyframe3D<Vector3>> positionKeys = _sortKeys(
    positionKeys,
  );

  /// Sorted rotation keyframes.
  final List<TransformKeyframe3D<Quaternion>> rotationKeys = _sortKeys(
    rotationKeys,
  );

  /// Sorted scale keyframes.
  final List<TransformKeyframe3D<Vector3>> scaleKeys = _sortKeys(scaleKeys);

  final Vector3 _posScratch = Vector3.zero();
  final Quaternion _rotScratch = Quaternion.identity();
  final Vector3 _scaleScratch = Vector3.all(1.0);
  final NotifyingQuaternion _notifyRot = NotifyingQuaternion(
    0.0,
    0.0,
    0.0,
    1.0,
  );

  static List<TransformKeyframe3D<T>> _sortKeys<T>(
    List<TransformKeyframe3D<T>> raw,
  ) {
    if (raw.isEmpty) {
      return const [];
    }
    final sorted = List<TransformKeyframe3D<T>>.of(raw)
      ..sort((a, b) => a.time.compareTo(b.time));
    return List<TransformKeyframe3D<T>>.unmodifiable(sorted);
  }

  @override
  double get endTime {
    var best = 0.0;
    if (positionKeys.isNotEmpty && positionKeys.last.time > best) {
      best = positionKeys.last.time;
    }
    if (rotationKeys.isNotEmpty && rotationKeys.last.time > best) {
      best = rotationKeys.last.time;
    }
    if (scaleKeys.isNotEmpty && scaleKeys.last.time > best) {
      best = scaleKeys.last.time;
    }
    return best;
  }

  @override
  void evaluate(double time) {
    if (positionKeys.isNotEmpty) {
      _sampleVec3(positionKeys, time, _posScratch);
      target.position.setFrom(_posScratch);
    }
    if (rotationKeys.isNotEmpty) {
      _sampleQuat(rotationKeys, time, _rotScratch);
      _notifyRot.setFrom(_rotScratch);
      target.rotation.setFrom(_notifyRot);
    }
    if (scaleKeys.isNotEmpty) {
      _sampleVec3(scaleKeys, time, _scaleScratch);
      target.scale.setFrom(_scaleScratch);
    }
  }

  static int _findSegment<T>(List<TransformKeyframe3D<T>> keys, double time) {
    var lo = 0;
    var hi = keys.length - 2;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (time < keys[mid].time) {
        hi = mid - 1;
      } else if (time >= keys[mid + 1].time) {
        lo = mid + 1;
      } else {
        return mid;
      }
    }
    return lo.clamp(0, keys.length - 2);
  }

  static void _sampleVec3(
    List<TransformKeyframe3D<Vector3>> keys,
    double time,
    Vector3 out,
  ) {
    if (keys.length == 1 || time <= keys.first.time) {
      out.setFrom(keys.first.value);
      return;
    }
    if (time >= keys.last.time) {
      out.setFrom(keys.last.value);
      return;
    }
    final i = _findSegment(keys, time);
    final k0 = keys[i];
    final k1 = keys[i + 1];
    final dt = k1.time - k0.time;
    final t = dt > 1e-12 ? ((time - k0.time) / dt).clamp(0.0, 1.0) : 0.0;

    switch (k0.interpolation) {
      case TimelineInterpolation3D.step:
        out.setFrom(k0.value);
      case TimelineInterpolation3D.linear:
        out.setValues(
          k0.value.x + (k1.value.x - k0.value.x) * t,
          k0.value.y + (k1.value.y - k0.value.y) * t,
          k0.value.z + (k1.value.z - k0.value.z) * t,
        );
      case TimelineInterpolation3D.cubicHermite:
        final b0 = k0.outTangent;
        final a1 = k1.inTangent;
        if (b0 != null || a1 != null) {
          AnimationInterpolation.cubicHermiteVector3Into(
            k0.value,
            b0 ?? _zeroVec3,
            k1.value,
            a1 ?? _zeroVec3,
            dt,
            t,
            out,
          );
        } else {
          final u = t * t * (3.0 - 2.0 * t);
          out.setValues(
            k0.value.x + (k1.value.x - k0.value.x) * u,
            k0.value.y + (k1.value.y - k0.value.y) * u,
            k0.value.z + (k1.value.z - k0.value.z) * u,
          );
        }
    }
  }

  static void _sampleQuat(
    List<TransformKeyframe3D<Quaternion>> keys,
    double time,
    Quaternion out,
  ) {
    if (keys.length == 1 || time <= keys.first.time) {
      out.setFrom(keys.first.value);
      return;
    }
    if (time >= keys.last.time) {
      out.setFrom(keys.last.value);
      return;
    }
    final i = _findSegment(keys, time);
    final k0 = keys[i];
    final k1 = keys[i + 1];
    final dt = k1.time - k0.time;
    final t = dt > 1e-12 ? ((time - k0.time) / dt).clamp(0.0, 1.0) : 0.0;

    switch (k0.interpolation) {
      case TimelineInterpolation3D.step:
        out.setFrom(k0.value);
      case TimelineInterpolation3D.linear:
        AnimationInterpolation.slerpQuaternionsInto(
          k0.value,
          k1.value,
          t,
          out,
        );
      case TimelineInterpolation3D.cubicHermite:
        final b0 = k0.outTangent;
        final a1 = k1.inTangent;
        if (b0 != null && a1 != null) {
          AnimationInterpolation.cubicHermiteQuaternionInto(
            k0.value,
            b0,
            k1.value,
            a1,
            dt,
            t,
            out,
          );
        } else {
          final u = t * t * (3.0 - 2.0 * t);
          AnimationInterpolation.slerpQuaternionsInto(
            k0.value,
            k1.value,
            u,
            out,
          );
        }
    }
  }

  static final Vector3 _zeroVec3 = Vector3.zero();
}

// =============================================================================
// 3. AnimationClipTrack3D
// =============================================================================

/// Scheduled skeletal [ModelAnimation] clip placement along an
/// [AnimationClipTrack3D].
class AnimationClipSpan3D({
  required final ModelAnimation animation,
  required final double startTime,
  double? endTime,
  final double clipOffset = 0.0,
  final double speed = 1.0,
  final bool loop = false,
}) {
  /// End timestamp on the timeline (`startTime + animation.lastTime / speed`
  /// by default).
  final double endTime =
      endTime ??
      (startTime +
          (speed.abs() > 1e-6 ? animation.lastTime / speed.abs() : 0.0));
}

/// Triggers and deterministically scrubs [ModelAnimation] clips on a
/// [ModelComponent] across forward playback and arbitrary `seek` jumps.
class AnimationClipTrack3D({
  required final ModelComponent target,
  required List<AnimationClipSpan3D> clips,
  super.enabled,
}) extends TimelineTrack3D {
  /// Clip spans ordered by `startTime`.
  final List<AnimationClipSpan3D> clips = _sortClips(clips);

  static List<AnimationClipSpan3D> _sortClips(List<AnimationClipSpan3D> raw) {
    final sorted = List<AnimationClipSpan3D>.of(raw)
      ..sort((a, b) => a.startTime.compareTo(b.startTime));
    return List<AnimationClipSpan3D>.unmodifiable(sorted);
  }

  @override
  double get endTime {
    var best = 0.0;
    for (var i = 0; i < clips.length; i++) {
      if (clips[i].endTime > best) {
        best = clips[i].endTime;
      }
    }
    return best;
  }

  @override
  void evaluate(double time) {
    if (clips.isEmpty) {
      return;
    }
    AnimationClipSpan3D? active;
    for (var i = 0; i < clips.length; i++) {
      final c = clips[i];
      if (time >= c.startTime - 1e-9 && time <= c.endTime + 1e-9) {
        active = c;
      }
    }
    if (active == null) {
      return;
    }

    final dur = active.animation.lastTime;
    var localClock =
        active.clipOffset +
        math.max(0.0, time - active.startTime) * active.speed;
    if (dur > 1e-9) {
      if (active.loop) {
        localClock %= dur;
        if (localClock < 0.0) {
          localClock += dur;
        }
      } else {
        localClock = localClock.clamp(0.0, dur);
      }
    } else {
      localClock = 0.0;
    }

    final animState = target.animationState;
    if (!identical(animState.animationRef, active.animation)) {
      animState.startAnimation(
        active.animation,
        mode: active.loop ? AnimationPlayMode.loop : AnimationPlayMode.once,
      );
    }
    animState.clock = localClock;
    target
      ..markPoseDirty()
      ..evaluatePose();
  }
}

// =============================================================================
// 4. MorphWeightTrack3D
// =============================================================================

/// Keyframe of facial/shape morph target weights on a [MorphWeightTrack3D].
class MorphWeightKeyframe3D({
  required final double time,
  required List<double> weights,
  final TimelineInterpolation3D interpolation = TimelineInterpolation3D.linear,
  List<double>? inTangents,
  List<double>? outTangents,
}) {
  /// Morph target weights at [time].
  final List<double> weights = List<double>.unmodifiable(weights);

  /// Optional incoming Hermite slopes (`weights.length` entries).
  final List<double>? inTangents = inTangents != null
      ? List<double>.unmodifiable(inTangents)
      : null;

  /// Optional outgoing Hermite slopes (`weights.length` entries).
  final List<double>? outTangents = outTangents != null
      ? List<double>.unmodifiable(outTangents)
      : null;
}

/// Keyframed morph-target weight track driving a [ModelComponent] (optionally
/// scoped to [nodeName]).
class MorphWeightTrack3D({
  required final ModelComponent target,
  required List<MorphWeightKeyframe3D> keyframes,
  final String? nodeName,
  super.enabled,
}) extends TimelineTrack3D {
  /// Sorted morph weight keyframes.
  final List<MorphWeightKeyframe3D> keyframes = _sort(keyframes);

  final List<double> _scratchWeights = [];

  static List<MorphWeightKeyframe3D> _sort(List<MorphWeightKeyframe3D> raw) {
    if (raw.isEmpty) {
      return const [];
    }
    final copy = List<MorphWeightKeyframe3D>.of(raw)
      ..sort((a, b) => a.time.compareTo(b.time));
    return List<MorphWeightKeyframe3D>.unmodifiable(copy);
  }

  @override
  double get endTime => keyframes.isEmpty ? 0.0 : keyframes.last.time;

  /// Latest evaluated morph weights (for inspection/testing).
  List<double> get currentWeights => List<double>.unmodifiable(_scratchWeights);

  @override
  void evaluate(double time) {
    if (keyframes.isEmpty) {
      return;
    }
    if (keyframes.length == 1 || time <= keyframes.first.time) {
      _copyWeights(keyframes.first.weights);
      target.setMorphWeights(_scratchWeights, nodeName: nodeName);
      return;
    }
    if (time >= keyframes.last.time) {
      _copyWeights(keyframes.last.weights);
      target.setMorphWeights(_scratchWeights, nodeName: nodeName);
      return;
    }

    var lo = 0;
    var hi = keyframes.length - 2;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (time < keyframes[mid].time) {
        hi = mid - 1;
      } else if (time >= keyframes[mid + 1].time) {
        lo = mid + 1;
      } else {
        lo = mid;
        break;
      }
    }
    final i = lo.clamp(0, keyframes.length - 2);
    final k0 = keyframes[i];
    final k1 = keyframes[i + 1];
    final count = math.max(k0.weights.length, k1.weights.length);
    _ensureLength(count);

    final dt = k1.time - k0.time;
    final t = dt > 1e-12 ? ((time - k0.time) / dt).clamp(0.0, 1.0) : 0.0;

    switch (k0.interpolation) {
      case TimelineInterpolation3D.step:
        for (var j = 0; j < count; j++) {
          _scratchWeights[j] = j < k0.weights.length ? k0.weights[j] : 0.0;
        }
      case TimelineInterpolation3D.linear:
        for (var j = 0; j < count; j++) {
          final v0 = j < k0.weights.length ? k0.weights[j] : 0.0;
          final v1 = j < k1.weights.length ? k1.weights[j] : 0.0;
          _scratchWeights[j] = v0 + (v1 - v0) * t;
        }
      case TimelineInterpolation3D.cubicHermite:
        final b0 = k0.outTangents;
        final a1 = k1.inTangents;
        if (b0 != null || a1 != null) {
          final t2 = t * t;
          final t3 = t2 * t;
          final h00 = 2.0 * t3 - 3.0 * t2 + 1.0;
          final h10 = (t3 - 2.0 * t2 + t) * dt;
          final h01 = -2.0 * t3 + 3.0 * t2;
          final h11 = (t3 - t2) * dt;
          for (var j = 0; j < count; j++) {
            final v0 = j < k0.weights.length ? k0.weights[j] : 0.0;
            final v1 = j < k1.weights.length ? k1.weights[j] : 0.0;
            final m0 = b0 != null && j < b0.length ? b0[j] : 0.0;
            final m1 = a1 != null && j < a1.length ? a1[j] : 0.0;
            _scratchWeights[j] = h00 * v0 + h10 * m0 + h01 * v1 + h11 * m1;
          }
        } else {
          final u = t * t * (3.0 - 2.0 * t);
          for (var j = 0; j < count; j++) {
            final v0 = j < k0.weights.length ? k0.weights[j] : 0.0;
            final v1 = j < k1.weights.length ? k1.weights[j] : 0.0;
            _scratchWeights[j] = v0 + (v1 - v0) * u;
          }
        }
    }
    target.setMorphWeights(_scratchWeights, nodeName: nodeName);
  }

  void _ensureLength(int count) {
    while (_scratchWeights.length < count) {
      _scratchWeights.add(0.0);
    }
    if (_scratchWeights.length > count) {
      _scratchWeights.removeRange(count, _scratchWeights.length);
    }
  }

  void _copyWeights(List<double> src) {
    _ensureLength(src.length);
    for (var i = 0; i < src.length; i++) {
      _scratchWeights[i] = src[i];
    }
  }
}

// =============================================================================
// 5. EventMarkerTrack3D
// =============================================================================

/// Direction-aware marker callback signature.
typedef EventMarkerCallback3D = void Function(
  EventMarker3D marker,
  TimelineDirection3D direction,
);

/// One-shot cue / event marker along an [EventMarkerTrack3D].
class EventMarker3D({
  required final String name,
  required final double time,
  final Object? payload,
  final VoidCallback? onTrigger,
  final EventMarkerCallback3D? onDirectionalTrigger,
});

/// Direction-aware marker track firing [EventMarker3D] cues during forward
/// play, reverse play, loop wrap-around, and `Timeline3D.seek`.
class EventMarkerTrack3D({
  required List<EventMarker3D> markers,
  this.onMarker,
  super.enabled,
}) extends TimelineTrack3D {
  /// Markers sorted ascending by [EventMarker3D.time].
  final List<EventMarker3D> markers = _sortMarkers(markers);

  /// Optional track-wide listener invoked whenever a marker is crossed.
  EventMarkerCallback3D? onMarker;

  static List<EventMarker3D> _sortMarkers(List<EventMarker3D> raw) {
    if (raw.isEmpty) {
      return const [];
    }
    final sorted = List<EventMarker3D>.of(raw)
      ..sort((a, b) => a.time.compareTo(b.time));
    return List<EventMarker3D>.unmodifiable(sorted);
  }

  @override
  double get endTime => markers.isEmpty ? 0.0 : markers.last.time;

  @override
  void evaluate(double time) {
    // Range-based firing is driven by `Timeline3D` via `fireRange`.
  }

  /// Fires markers within `[from..to]` in [direction] order.
  void fireRange(
    double from,
    double to, {
    required TimelineDirection3D direction,
    required bool inclusiveStart,
  }) {
    if (!enabled || markers.isEmpty) {
      return;
    }
    if (direction == TimelineDirection3D.forward) {
      if (to < from || (!inclusiveStart && to <= from)) {
        return;
      }
      for (var i = 0; i < markers.length; i++) {
        final m = markers[i];
        final afterStart = inclusiveStart
            ? m.time >= from - 1e-9
            : m.time > from + 1e-9;
        if (afterStart && m.time <= to + 1e-9) {
          m.onTrigger?.call();
          m.onDirectionalTrigger?.call(m, TimelineDirection3D.forward);
          onMarker?.call(m, TimelineDirection3D.forward);
        }
      }
    } else {
      // Backward from higher `from` down to lower `to`:
      if (from < to || (!inclusiveStart && from <= to)) {
        return;
      }
      for (var i = markers.length - 1; i >= 0; i--) {
        final m = markers[i];
        final beforeFrom = inclusiveStart
            ? m.time <= from + 1e-9
            : m.time < from - 1e-9;
        if (beforeFrom && m.time >= to - 1e-9) {
          m.onTrigger?.call();
          m.onDirectionalTrigger?.call(m, TimelineDirection3D.backward);
          onMarker?.call(m, TimelineDirection3D.backward);
        }
      }
    }
  }
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

  /// Starts or resumes playback from [currentTime] (rewinding to `0` first if
  /// non-looping playback already reached [duration]).
  void play() {
    final dur = duration;
    if (!loop && dur > 0.0 && _currentTime >= dur - 1e-9) {
      _currentTime = 0.0;
      _atInitialStart = true;
    }
    _isPlaying = true;
    _evaluateNonEventTracks(_currentTime);
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
