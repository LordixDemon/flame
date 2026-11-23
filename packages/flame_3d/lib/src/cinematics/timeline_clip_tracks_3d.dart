part of 'timeline_3d.dart';

// =============================================================================
// CameraShotTrack3D
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
///
/// The shot covering the playhead (the later one where shots overlap) is
/// enabled with its `activePriority` and its `blendDurationOverride`; the
/// cameras of the other shots are disabled and get back the priority and
/// blend duration override they had when the track was created. Where no
/// shot covers the playhead (before the first shot, in a gap, after the
/// last), every camera of the track is disabled: the brain goes to another
/// enabled camera, or holds its last pose when there is none.
class CameraShotTrack3D({
  required List<CameraShot3D> shots,
  super.enabled,
}) extends TimelineTrack3D {
  this {
    for (final s in this.shots) {
      _baselinePriorities.putIfAbsent(s.camera, () => s.camera.priority);
      _baselineBlendOverrides.putIfAbsent(
        s.camera,
        () => s.camera.blendDurationOverride,
      );
    }
  }

  /// Shots ordered by `startTime`.
  final List<CameraShot3D> shots = _sortShots(shots);

  final Map<VirtualCamera3D, int> _baselinePriorities = {};
  final Map<VirtualCamera3D, double?> _baselineBlendOverrides = {};
  // The cameras whose blend duration override a shot replaced.
  final Set<VirtualCamera3D> _overridden = {};

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
      final camera = s.camera;
      if (identical(camera, winner?.camera)) {
        continue;
      }
      camera
        ..enabled = false
        ..priority = _baselinePriorities[camera] ?? 0;
      if (_overridden.remove(camera)) {
        camera.blendDurationOverride = _baselineBlendOverrides[camera];
      }
    }

    if (winner != null) {
      final camera = winner.camera;
      if (winner.blendDurationOverride != null) {
        camera.blendDurationOverride = winner.blendDurationOverride;
        _overridden.add(camera);
      } else if (_overridden.remove(camera)) {
        camera.blendDurationOverride = _baselineBlendOverrides[camera];
      }
      camera
        ..enabled = true
        ..priority = winner.activePriority;
    }
  }
}

// =============================================================================
// AnimationClipTrack3D
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
///
/// While the playhead is inside one of its spans the track owns the model's
/// animation clock: it sets the clock from the timeline and holds the
/// model's [AnimationState.speed] at `0`, so that the model does not advance
/// the clip on its own when the timeline is paused or scrubbed. When the
/// playhead leaves every span, the model gets back the speed it had, and
/// plays on from where the timeline left it. [releaseModelClock] gives it
/// back at once ([Timeline3D] calls it when removed).
class AnimationClipTrack3D({
  required final ModelComponent target,
  required List<AnimationClipSpan3D> clips,
  super.enabled,
}) extends TimelineTrack3D {
  /// Clip spans ordered by `startTime`.
  final List<AnimationClipSpan3D> clips = _sortClips(clips);

  // The model's animation speed when the track took its clock, or `null`
  // while the track does not hold it.
  double? _heldSpeed;

  /// Gives the model back the animation speed it had before the track took
  /// its clock, if the track holds it.
  void releaseModelClock() {
    final held = _heldSpeed;
    if (held != null) {
      _heldSpeed = null;
      target.animationState.speed = held;
    }
  }

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
      releaseModelClock();
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
    _heldSpeed ??= animState.speed;
    animState
      ..speed = 0.0
      ..clock = localClock;
    target
      ..markPoseDirty()
      ..evaluatePose();
  }
}

// =============================================================================
// EventMarkerTrack3D
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
