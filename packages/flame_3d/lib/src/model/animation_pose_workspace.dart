part of 'animation_state.dart';

final Vector3 _t0 = Vector3.zero();
final Quaternion _r0 = Quaternion.identity();
final Vector3 _s0 = Vector3.all(1.0);
final Vector3 _t1 = Vector3.zero();
final Quaternion _r1 = Quaternion.identity();
final Vector3 _s1 = Vector3.all(1.0);
final Vector3 _lt = Vector3.zero();
final Quaternion _lr = Quaternion.identity();
final Vector3 _ls = Vector3.all(1.0);
final List<double> _morphBlendScratch = [];
final List<double> _morphLayerScratch = [];
final List<AnimationState> _spareStates = [];

extension _AnimationStatePlayback on AnimationState {
  void _ensureSampleClocks(int length, {required bool reset}) {
    if (_sampleClocks.length < length) {
      final next = Float64List(length);
      if (!reset) {
        next.setRange(0, _sampleClocks.length, _sampleClocks);
      }
      _sampleClocks = next;
    } else if (reset) {
      _sampleClocks.fillRange(0, length, 0.0);
    }
  }

  /// Ends any crossfade at once, dropping its outgoing side.
  void _cancelCrossFade() {
    _previousRef = null;
    _releaseOutgoing();
    _blendDuration = 0.0;
    _blendElapsed = 0.0;
  }

  void _releaseOutgoing() {
    var nested = _outgoing;
    _outgoing = null;
    while (nested != null) {
      final deeper = nested._outgoing;
      nested
        .._outgoing = null
        .._previousRef = null
        ..animationRef = null
        .._blendSpace1D = null
        .._blendSpace2D = null
        .._blendDuration = 0.0
        .._blendElapsed = 0.0;
      if (_spareStates.length < 32) {
        _spareStates.add(nested);
      }
      nested = deeper;
    }
  }

  /// Moves what is playing now to the outgoing side of a new crossfade.
  ///
  /// A plain clip becomes [_previousRef]; anything else (a running crossfade,
  /// a blend space) is copied whole into a nested state that keeps advancing
  /// and blending, so the pose does not jump. Returns `false` when nothing is
  /// playing.
  bool _beginOutgoing() {
    if (!hasActiveEvaluation) {
      return false;
    }
    final plainClip =
        animationRef != null &&
        !isCrossFading &&
        _blendSpace1D == null &&
        _blendSpace2D == null;
    if (plainClip) {
      _releaseOutgoing();
      _previousRef = animationRef;
      _previousClock = clock;
      _previousMode = mode;
      _previousPingPongDir = _pingPongDirection;
      return true;
    }
    final nested = _spareStates.isNotEmpty
        ? _spareStates.removeLast()
        : AnimationState();
    nested._copyEvaluationFrom(this);
    // The nested state now owns the previous outgoing chain.
    _outgoing = nested;
    _previousRef = null;

    var level = nested;
    var depth = 1;
    while (depth < AnimationState.maxNestedCrossFades) {
      final deeper = level._outgoing;
      if (deeper == null) {
        break;
      }
      level = deeper;
      depth++;
    }
    if (level._outgoing != null) {
      level._cancelCrossFade();
    }
    return true;
  }

  /// Copies the evaluation state of [source] (target clip or blend space,
  /// clocks, parameters and its crossfade) into this state, taking over
  /// [source]'s outgoing chain.
  void _copyEvaluationFrom(AnimationState source) {
    animationRef = source.animationRef;
    clock = source.clock;
    mode = source.mode;
    speed = 1.0;
    onComplete = null;
    onEvent = null;
    _completed = source._completed;
    _pingPongDirection = source._pingPongDirection;
    _atInitialStart = false;
    _lastLoopWrapCount = 0;
    _previousRef = source._previousRef;
    _previousClock = source._previousClock;
    _previousMode = source._previousMode;
    _previousPingPongDir = source._previousPingPongDir;
    _outgoing = source._outgoing;
    source._outgoing = null;
    _blendElapsed = source._blendElapsed;
    _blendDuration = source._blendDuration;
    _blendSpace1D = source._blendSpace1D;
    _blendSpace2D = source._blendSpace2D;
    blendParameter1D = source.blendParameter1D;
    _seenParam1D = source._seenParam1D;
    _blendParam2D.setFrom(source._blendParam2D);
    _seenParam2DX = source._seenParam2DX;
    _seenParam2DY = source._seenParam2DY;
    _normalizedPhase = source._normalizedPhase;
    final samples = source._sampleClocks.length;
    _ensureSampleClocks(samples, reset: true);
    _sampleClocks.setRange(0, samples, source._sampleClocks);
  }

  bool _updateInternal(double dt, {AnimationEventCallback3D? parentSink}) {
    _lastLoopWrapCount = 0;
    final paramChanged = consumeParameterChanges();
    if (dt == 0.0 || speed == 0.0) {
      return paramChanged;
    }
    final scaledDt = dt * speed;
    var changed = paramChanged;
    final prevSink = _activeParentSink;
    _activeParentSink = parentSink;
    try {
      if (isCrossFading) {
        final nested = _outgoing;
        if (nested != null) {
          // The outgoing state fires no events and calls no callbacks.
          nested
            ..speed = speed
            .._updateInternal(dt);
        } else if (_previousRef case final prev?) {
          final step = _advanceClip(
            prev,
            _previousClock,
            scaledDt,
            _previousMode,
            _previousPingPongDir,
            atStart: false,
            onEvent: null,
          );
          _previousClock = step.clock;
          _previousPingPongDir = step.direction;
        }
        _blendElapsed += dt.abs();
        if (_blendElapsed >= _blendDuration) {
          _cancelCrossFade();
        }
        changed = true;
      }

      final space1D = _blendSpace1D;
      final space2D = _blendSpace2D;
      if (space1D != null) {
        _advanceBlendSpace1D(space1D, scaledDt, _dispatchCallback);
        changed = true;
      } else if (space2D != null) {
        _advanceBlendSpace2D(space2D, scaledDt, _dispatchCallback);
        changed = true;
      } else if (animationRef case final animation? when !_completed) {
        final wasAtStart = _atInitialStart;
        _atInitialStart = false;
        final step = _advanceClip(
          animation,
          clock,
          scaledDt,
          mode,
          _pingPongDirection,
          atStart: wasAtStart,
          onEvent: animation.events.isNotEmpty ? _dispatchCallback : null,
        );
        clock = step.clock;
        _pingPongDirection = step.direction;
        _lastLoopWrapCount = step.wraps;
        changed = true;
        if (step.completed && !_completed) {
          _completed = true;
          onComplete?.call();
        }
      }

      for (var i = 0; i < layers.length; i++) {
        final layer = layers[i];
        if (layer.weight > 0.0 &&
            layer.state._updateInternal(dt, parentSink: _dispatchCallback)) {
          changed = true;
        }
      }
    } finally {
      _activeParentSink = prevSink;
    }

    return changed;
  }

  void _advanceBlendSpace1D(
    BlendSpace1D space,
    double scaledDt,
    AnimationEventCallback3D fire,
  ) {
    final bracket = space.resolveBracket(blendParameter1D);
    final a = space.samples[bracket.indexA];
    final b = space.samples[bracket.indexB];
    final t = bracket.t;

    if (space.syncNormalizedPhase) {
      final durA = a.animation.lastTime;
      final durB = b.animation.lastTime;
      final effDur = durA > 1e-9 && durB > 1e-9
          ? durA + (durB - durA) * t
          : math.max(durA, durB);
      final effSpeed = a.speed + (b.speed - a.speed) * t;
      if (effDur > 1e-9) {
        final prevPhase = _normalizedPhase;
        final wasStart = _atInitialStart;
        _atInitialStart = false;
        final deltaPhase = (scaledDt * effSpeed) / effDur;
        final rawNext = prevPhase + deltaPhase;
        var wraps = 0;
        if (rawNext >= 1.0 || rawNext < 0.0) {
          wraps = rawNext.floor();
          _normalizedPhase = rawNext - wraps;
        } else {
          _normalizedPhase = rawNext;
        }
        _lastLoopWrapCount = wraps;
        final dom = t < 0.5 ? a.animation : b.animation;
        final domDur = dom.lastTime;
        clock = _normalizedPhase * domDur;
        if (dom.events.isNotEmpty && domDur > 1e-9) {
          _advanceClip(
            dom,
            prevPhase * domDur,
            deltaPhase * domDur,
            AnimationPlayMode.loop,
            1,
            atStart: wasStart,
            onEvent: fire,
          );
        }
      }
    } else {
      final domIdx = t < 0.5 ? bracket.indexA : bracket.indexB;
      _advanceUnsyncedSamples(space.samples, domIdx, scaledDt, fire);
    }
  }

  /// Advances every sample of a blend space without phase sync on its own
  /// clock. The dominant sample [domIdx] fires its events, counts loop wraps
  /// and gives [clock] and [normalizedPhase] (so state-machine exit times
  /// advance).
  void _advanceUnsyncedSamples(
    List<BlendSample> samples,
    int domIdx,
    double scaledDt,
    AnimationEventCallback3D fire,
  ) {
    final wasStart = _atInitialStart;
    _atInitialStart = false;
    for (var i = 0; i < samples.length; i++) {
      final s = samples[i];
      final animation = s.animation;
      final dur = animation.lastTime;
      if (i == domIdx) {
        final step = _advanceClip(
          animation,
          _sampleClocks[i],
          scaledDt * s.speed,
          AnimationPlayMode.loop,
          1,
          atStart: wasStart,
          onEvent: animation.events.isNotEmpty ? fire : null,
        );
        _sampleClocks[i] = step.clock;
        _lastLoopWrapCount = step.wraps;
      } else if (dur > 1e-9) {
        var next = _sampleClocks[i] + scaledDt * s.speed;
        next %= dur;
        if (next < 0.0) {
          next += dur;
        }
        _sampleClocks[i] = next;
      }
    }
    clock = _sampleClocks[domIdx];
    final domDur = samples[domIdx].animation.lastTime;
    _normalizedPhase = domDur > 1e-9 ? (clock / domDur).clamp(0.0, 1.0) : 0.0;
  }

  void _advanceBlendSpace2D(
    BlendSpace2D space,
    double scaledDt,
    AnimationEventCallback3D fire,
  ) {
    final activeCount = space.evaluateWeights(
      _blendParam2D,
      _active2DIndices,
      _active2DWeights,
    );
    if (space.syncNormalizedPhase) {
      var effDur = 0.0;
      var durWeightSum = 0.0;
      var effSpeed = 0.0;
      for (var k = 0; k < activeCount; k++) {
        final s = space.samples[_active2DIndices[k]];
        final w = _active2DWeights[k];
        effSpeed += s.speed * w;
        final d = s.animation.lastTime;
        if (d > 1e-9) {
          effDur += d * w;
          durWeightSum += w;
        }
      }
      if (durWeightSum > 1e-9) {
        effDur /= durWeightSum;
      }
      if (effDur > 1e-9) {
        final prevPhase = _normalizedPhase;
        final wasStart = _atInitialStart;
        _atInitialStart = false;
        final deltaPhase = (scaledDt * effSpeed) / effDur;
        final rawNext = prevPhase + deltaPhase;
        var wraps = 0;
        if (rawNext >= 1.0 || rawNext < 0.0) {
          wraps = rawNext.floor();
          _normalizedPhase = rawNext - wraps;
        } else {
          _normalizedPhase = rawNext;
        }
        _lastLoopWrapCount = wraps;
        final dom = space.samples[_active2DIndices[0]].animation;
        final domDur = dom.lastTime;
        clock = _normalizedPhase * domDur;
        if (dom.events.isNotEmpty && domDur > 1e-9) {
          _advanceClip(
            dom,
            prevPhase * domDur,
            deltaPhase * domDur,
            AnimationPlayMode.loop,
            1,
            atStart: wasStart,
            onEvent: fire,
          );
        }
      }
    } else {
      _advanceUnsyncedSamples(
        space.samples,
        _active2DIndices[0],
        scaledDt,
        fire,
      );
    }
  }
}

void _fireForwardRange(
  List<AnimationEvent3D> events,
  double from,
  double to, {
  required bool inclusiveStart,
  required AnimationEventCallback3D onEvent,
}) {
  if (to < from) {
    return;
  }
  if (!inclusiveStart && to <= from) {
    return;
  }
  for (var i = 0; i < events.length; i++) {
    final e = events[i];
    final t = e.time;
    final afterStart = inclusiveStart ? t >= from - 1e-9 : t > from + 1e-9;
    if (afterStart && t <= to + 1e-9) {
      onEvent(e);
    }
  }
}

void _fireBackwardRange(
  List<AnimationEvent3D> events,
  double low,
  double high, {
  required bool inclusiveHigh,
  required AnimationEventCallback3D onEvent,
}) {
  if (high < low) {
    return;
  }
  if (!inclusiveHigh && high <= low) {
    return;
  }
  for (var i = events.length - 1; i >= 0; i--) {
    final e = events[i];
    final t = e.time;
    final beforeHigh = inclusiveHigh ? t <= high + 1e-9 : t < high - 1e-9;
    if (beforeHigh && t >= low - 1e-9) {
      onEvent(e);
    }
  }
}

({double clock, int direction, bool completed, int wraps}) _advanceClip(
  ModelAnimation animation,
  double currentClock,
  double dt,
  AnimationPlayMode mode,
  int direction, {
  required bool atStart,
  required AnimationEventCallback3D? onEvent,
}) {
  final duration = animation.lastTime;
  final events = animation.events;
  if (duration <= 1e-9) {
    if (atStart && onEvent != null && events.isNotEmpty) {
      for (var i = 0; i < events.length; i++) {
        onEvent(events[i]);
      }
    }
    return (
      clock: 0.0,
      direction: direction,
      completed: mode == AnimationPlayMode.once,
      wraps: 0,
    );
  }

  switch (mode) {
    case AnimationPlayMode.loop:
      if (dt >= 0.0) {
        var cur = currentClock;
        var rem = dt;
        var inc = atStart;
        var wraps = 0;
        const maxEventWraps = 64;
        while (cur + rem > duration && wraps < maxEventWraps) {
          if (onEvent != null && events.isNotEmpty) {
            _fireForwardRange(
              events,
              cur,
              duration,
              inclusiveStart: inc,
              onEvent: onEvent,
            );
          }
          rem -= duration - cur;
          cur = 0.0;
          inc = true;
          wraps++;
        }
        if (cur + rem > duration) {
          final extraWraps = ((cur + rem) / duration).floor();
          wraps += extraWraps;
          cur = (cur + rem) % duration;
          rem = 0.0;
        }
        final next = cur + rem;
        if (onEvent != null && events.isNotEmpty) {
          _fireForwardRange(
            events,
            cur,
            next,
            inclusiveStart: inc,
            onEvent: onEvent,
          );
        }
        return (clock: next, direction: 1, completed: false, wraps: wraps);
      } else {
        var cur = currentClock;
        var rem = -dt;
        var inc = atStart;
        var wraps = 0;
        const maxEventWraps = 64;
        while (cur - rem < 0.0 && -wraps < maxEventWraps) {
          if (onEvent != null && events.isNotEmpty) {
            _fireBackwardRange(
              events,
              0.0,
              cur,
              inclusiveHigh: inc,
              onEvent: onEvent,
            );
          }
          rem -= cur;
          cur = duration;
          inc = true;
          wraps--;
        }
        if (cur - rem < 0.0) {
          var wrapped = (cur - rem) % duration;
          if (wrapped < 0.0) {
            wrapped += duration;
          }
          return (
            clock: wrapped,
            direction: 1,
            completed: false,
            wraps: wraps - 1,
          );
        }
        final next = cur - rem;
        if (onEvent != null && events.isNotEmpty) {
          _fireBackwardRange(
            events,
            next,
            cur,
            inclusiveHigh: inc,
            onEvent: onEvent,
          );
        }
        return (clock: next, direction: 1, completed: false, wraps: wraps);
      }

    case AnimationPlayMode.once:
      final rawNext = currentClock + dt;
      if (dt >= 0.0) {
        final clamped = rawNext >= duration ? duration : rawNext;
        if (onEvent != null && events.isNotEmpty) {
          _fireForwardRange(
            events,
            currentClock,
            clamped,
            inclusiveStart: atStart,
            onEvent: onEvent,
          );
        }
        return (
          clock: clamped,
          direction: 1,
          completed: rawNext >= duration,
          wraps: 0,
        );
      } else {
        final clamped = rawNext <= 0.0 ? 0.0 : rawNext;
        if (onEvent != null && events.isNotEmpty) {
          _fireBackwardRange(
            events,
            clamped,
            currentClock,
            inclusiveHigh: atStart,
            onEvent: onEvent,
          );
        }
        return (
          clock: clamped,
          direction: 1,
          completed: rawNext <= 0.0,
          wraps: 0,
        );
      }

    case AnimationPlayMode.pingPong:
      var cur = currentClock;
      var rem = dt.abs();
      var stepDir = dt >= 0.0 ? direction : -direction;
      var inc = atStart;
      var guard = 0;
      while (rem > 0.0 && guard++ < 128) {
        if (stepDir > 0) {
          final toMax = duration - cur;
          if (rem <= toMax) {
            final next = cur + rem;
            if (onEvent != null && events.isNotEmpty) {
              _fireForwardRange(
                events,
                cur,
                next,
                inclusiveStart: inc,
                onEvent: onEvent,
              );
            }
            cur = next;
            rem = 0.0;
            break;
          }
          if (onEvent != null && events.isNotEmpty && (toMax > 0.0 || inc)) {
            _fireForwardRange(
              events,
              cur,
              duration,
              inclusiveStart: inc,
              onEvent: onEvent,
            );
          }
          rem -= toMax;
          cur = duration;
          stepDir = -1;
          inc = false;
        } else {
          final toMin = cur;
          if (rem <= toMin) {
            final next = cur - rem;
            if (onEvent != null && events.isNotEmpty) {
              _fireBackwardRange(
                events,
                next,
                cur,
                inclusiveHigh: inc,
                onEvent: onEvent,
              );
            }
            cur = next;
            rem = 0.0;
            break;
          }
          if (onEvent != null && events.isNotEmpty && (toMin > 0.0 || inc)) {
            _fireBackwardRange(
              events,
              0.0,
              cur,
              inclusiveHigh: inc,
              onEvent: onEvent,
            );
          }
          rem -= toMin;
          cur = 0.0;
          stepDir = 1;
          inc = false;
        }
      }
      final finalDir = dt >= 0.0 ? stepDir : -stepDir;
      return (clock: cur, direction: finalDir, completed: false, wraps: 0);
  }
}

void _ensureZeroedList(List<double> list, int count) {
  while (list.length < count) {
    list.add(0.0);
  }
  for (var i = 0; i < count; i++) {
    list[i] = 0.0;
  }
}
