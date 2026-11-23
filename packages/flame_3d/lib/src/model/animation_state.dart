import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show VoidCallback;

import 'package:flame_3d/core.dart';
import 'package:flame_3d/src/model/blend_space_3d.dart';
import 'package:flame_3d/src/model/model_animation.dart';
import 'package:flame_3d/src/parser/gltf/animation_interpolation.dart';

/// Callback signature invoked when an [AnimationEvent3D] is crossed during
/// playback.
typedef AnimationEventCallback3D = void Function(AnimationEvent3D event);

/// How an animation clip advances once its clock reaches the end of the clip.
enum AnimationPlayMode() {
  /// Wraps around seamlessly to the beginning.
  loop,

  /// Clamps at the end of the clip and marks the state completed.
  once,

  /// Alternates forward and backward across the clip.
  pingPong,
}

/// Masked animation layer blended on top of a base [AnimationState] for a
/// subset of bone indices (e.g. upper-body attack/wave over lower-body walk).
class AnimationLayer3D({
  required final Set<int> nodeIndices,
  var double weight = 1.0,
}) {
  final AnimationState state = AnimationState();
}

/// Couples [ModelAnimation] clips or 1D/2D blend spaces with playback clocks,
/// [AnimationEvent3D] dispatch, playback modes, and allocation-free TRS
/// crossfading (plus optional masked [layers]).
class AnimationState() {
  ModelAnimation? animationRef;
  double clock = 0.0;

  /// Optional masked overlay layers evaluated in order on top of this base
  /// state.
  final List<AnimationLayer3D> layers = [];

  /// Playback rate multiplier (`1.0` = real time, `0.0` = paused).
  double speed = 1.0;

  /// How [animationRef] behaves at its end time.
  AnimationPlayMode mode = AnimationPlayMode.loop;

  /// Optional callback invoked when a [AnimationPlayMode.once] clip finishes.
  VoidCallback? onComplete;

  /// Optional callback invoked whenever an [AnimationEvent3D] is crossed.
  AnimationEventCallback3D? onEvent;

  final List<AnimationEventCallback3D> _eventListeners = [];
  AnimationEventCallback3D? _activeParentSink;
  late final AnimationEventCallback3D _dispatchCallback =
      _dispatchEventCallback;

  void _dispatchEventCallback(AnimationEvent3D event) {
    onEvent?.call(event);
    for (var i = 0; i < _eventListeners.length; i++) {
      _eventListeners[i](event);
    }
    _activeParentSink?.call(event);
  }

  bool _completed = false;
  int _pingPongDirection = 1;
  bool _atInitialStart = true;
  int _lastLoopWrapCount = 0;

  // Outgoing side of a crossfade: either the single clip in [_previousRef]
  // (a crossfade started from a plain clip) or the whole previous state in
  // [_outgoing] (a crossfade started during another crossfade or from a blend
  // space), which keeps advancing and blending until the fade ends.
  ModelAnimation? _previousRef;
  double _previousClock = 0.0;
  AnimationPlayMode _previousMode = AnimationPlayMode.loop;
  int _previousPingPongDir = 1;
  AnimationState? _outgoing;
  double _blendElapsed = 0.0;
  double _blendDuration = 0.0;

  /// How many interrupted crossfades can be nested: starting a crossfade
  /// while one is running keeps the running one as the outgoing side, up to
  /// this depth. Deeper, the oldest fade is completed at once (its weight in
  /// the pose is the smallest).
  static const int maxNestedCrossFades = 4;

  // Instance scratch for the outgoing side, so nested states can be evaluated
  // while the caller's results live in the shared static scratch.
  final Vector3 _fadeT = Vector3.zero();
  final Quaternion _fadeR = Quaternion.identity();
  final Vector3 _fadeS = Vector3.all(1.0);
  final List<double> _fadeMorph = [];

  // Active 1D / 2D blend spaces.
  BlendSpace1D? _blendSpace1D;
  BlendSpace2D? _blendSpace2D;

  /// Current 1D blend parameter driving [activeBlendSpace1D].
  double blendParameter1D = 0.0;
  double _seenParam1D = 0.0;
  final Vector2 _blendParam2D = Vector2.zero();
  double _seenParam2DX = 0.0;
  double _seenParam2DY = 0.0;
  double _normalizedPhase = 0.0;
  Float64List _sampleClocks = Float64List(0);

  final Int32List _active2DIndices = Int32List(4);
  final Float64List _active2DWeights = Float64List(4);

  /// Registers [listener] to be notified whenever an [AnimationEvent3D] fires
  /// on this state (or any active [layers]).
  void addEventListener(AnimationEventCallback3D listener) {
    _eventListeners.add(listener);
  }

  /// Unregisters a previously added [AnimationEvent3D] [listener].
  void removeEventListener(AnimationEventCallback3D listener) {
    _eventListeners.remove(listener);
  }

  /// Active 1D blend space, or `null` when playing a single clip or 2D space.
  BlendSpace1D? get activeBlendSpace1D => _blendSpace1D;

  /// Active 2D blend space, or `null` when playing a single clip or 1D space.
  BlendSpace2D? get activeBlendSpace2D => _blendSpace2D;

  /// Current 2D blend parameter driving [activeBlendSpace2D] (may also be
  /// mutated in place via `.setValues(...)`).
  Vector2 get blendParameter2D => _blendParam2D;
  set blendParameter2D(Vector2 value) {
    _blendParam2D.setFrom(value);
  }

  /// Shared normalized `[0, 1)` cycle phase when playing a phase-synced
  /// [BlendSpace1D] or [BlendSpace2D].
  double get normalizedPhase => _normalizedPhase;

  /// Effective normalized `[0, 1]` phase of whichever clip or blend space is
  /// currently active (`0` when idle or zero-length).
  double get currentNormalizedPhase {
    if (_blendSpace1D != null || _blendSpace2D != null) {
      return _normalizedPhase;
    }
    final anim = animationRef;
    if (anim != null && anim.lastTime > 1e-9) {
      return (clock / anim.lastTime).clamp(0.0, 1.0);
    }
    return 0.0;
  }

  /// Sets the active playback cursor to [phase] in `[0, 1)` across single
  /// clips, [BlendSpace1D], and [BlendSpace2D].
  void setNormalizedPhase(double phase) {
    final p = phase - phase.floorToDouble();
    _normalizedPhase = p;
    if (_blendSpace1D case final s1?) {
      _ensureSampleClocks(s1.samples.length, reset: false);
      for (var i = 0; i < s1.samples.length; i++) {
        _sampleClocks[i] = p * s1.samples[i].animation.lastTime;
      }
      final bracket = s1.resolveBracket(blendParameter1D);
      final domIdx = bracket.t < 0.5 ? bracket.indexA : bracket.indexB;
      clock = p * s1.samples[domIdx].animation.lastTime;
      _atInitialStart = p == 0.0;
    } else if (_blendSpace2D case final s2?) {
      _ensureSampleClocks(s2.samples.length, reset: false);
      for (var i = 0; i < s2.samples.length; i++) {
        _sampleClocks[i] = p * s2.samples[i].animation.lastTime;
      }
      clock = p * s2.samples[0].animation.lastTime;
      _atInitialStart = p == 0.0;
    } else if (animationRef case final anim?) {
      clock = p * anim.lastTime;
      _atInitialStart = clock == 0.0;
    }
  }

  /// Signed number of loop wrap-arounds executed on the most recent [update].
  int get lastLoopWrapCount => _lastLoopWrapCount;

  /// Whether any active clip, crossfade, or blend space is attached.
  bool get hasActiveEvaluation =>
      animationRef != null ||
      isCrossFading ||
      _blendSpace1D != null ||
      _blendSpace2D != null;

  /// Whether a non-looping clip has reached its final keyframe.
  bool get isCompleted => _completed;

  /// Whether a crossfade transition is currently in progress.
  bool get isCrossFading =>
      (_previousRef != null || _outgoing != null) && _blendDuration > 0.0;

  /// Current crossfade blend weight in `[0, 1]` (`1` when not crossfading).
  double get crossFadeProgress => _blendDuration > 0.0
      ? (_blendElapsed / _blendDuration).clamp(0.0, 1.0)
      : 1.0;

  /// Whether calling [update] with `dt > 0` will advance an active animation.
  bool get isPlaying =>
      speed != 0.0 &&
      ((animationRef != null && !_completed) ||
          isCrossFading ||
          _blendSpace1D != null ||
          _blendSpace2D != null);

  /// Returns `true` and updates seen snapshots if [blendParameter1D] or
  /// [blendParameter2D] changed since the last check.
  bool consumeParameterChanges() {
    var dirty = false;
    if (_blendSpace1D != null && blendParameter1D != _seenParam1D) {
      _seenParam1D = blendParameter1D;
      dirty = true;
    }
    if (_blendSpace2D != null &&
        (_blendParam2D.x != _seenParam2DX ||
            _blendParam2D.y != _seenParam2DY)) {
      _seenParam2DX = _blendParam2D.x;
      _seenParam2DY = _blendParam2D.y;
      dirty = true;
    }
    for (var i = 0; i < layers.length; i++) {
      if (layers[i].weight > 0.0 && layers[i].state.consumeParameterChanges()) {
        dirty = true;
      }
    }
    return dirty;
  }

  /// Starts [animation] immediately, canceling any active crossfade or blend
  /// space.
  void startAnimation(
    ModelAnimation? animation, {
    bool resetClock = true,
    AnimationPlayMode mode = AnimationPlayMode.loop,
    VoidCallback? onComplete,
  }) {
    _cancelCrossFade();
    _activateClip(
      animation,
      resetClock: resetClock,
      mode: mode,
      onComplete: onComplete,
    );
  }

  void _activateClip(
    ModelAnimation? animation, {
    required bool resetClock,
    required AnimationPlayMode mode,
    required VoidCallback? onComplete,
  }) {
    _blendSpace1D = null;
    _blendSpace2D = null;
    animationRef = animation;
    this.mode = mode;
    this.onComplete = onComplete;
    _completed = false;
    _pingPongDirection = 1;
    _lastLoopWrapCount = 0;
    if (resetClock) {
      reset();
    } else {
      _atInitialStart = clock == 0.0;
    }
  }

  /// Activates a 1D [BlendSpace1D] at [initialValue].
  void playBlendSpace1D(
    BlendSpace1D space, {
    double initialValue = 0.0,
    bool resetClock = true,
  }) {
    _cancelCrossFade();
    _activateBlendSpace1D(
      space,
      initialValue: initialValue,
      resetClock: resetClock,
    );
  }

  void _activateBlendSpace1D(
    BlendSpace1D space, {
    required double initialValue,
    required bool resetClock,
  }) {
    animationRef = null;
    _blendSpace2D = null;
    _blendSpace1D = space;
    blendParameter1D = initialValue;
    _seenParam1D = initialValue;
    _completed = false;
    _lastLoopWrapCount = 0;
    _ensureSampleClocks(space.samples.length, reset: resetClock);
    if (resetClock) {
      _normalizedPhase = 0.0;
      clock = 0.0;
      _atInitialStart = true;
    }
  }

  /// Activates a 2D [BlendSpace2D] at [initialValue] (`(0, 0)` when `null`).
  void playBlendSpace2D(
    BlendSpace2D space, {
    Vector2? initialValue,
    bool resetClock = true,
  }) {
    _cancelCrossFade();
    _activateBlendSpace2D(
      space,
      initialValue: initialValue,
      resetClock: resetClock,
    );
  }

  void _activateBlendSpace2D(
    BlendSpace2D space, {
    required Vector2? initialValue,
    required bool resetClock,
  }) {
    animationRef = null;
    _blendSpace1D = null;
    _blendSpace2D = space;
    if (initialValue != null) {
      _blendParam2D.setFrom(initialValue);
    } else {
      _blendParam2D.setZero();
    }
    _seenParam2DX = _blendParam2D.x;
    _seenParam2DY = _blendParam2D.y;
    _completed = false;
    _lastLoopWrapCount = 0;
    _ensureSampleClocks(space.samples.length, reset: resetClock);
    if (resetClock) {
      _normalizedPhase = 0.0;
      clock = 0.0;
      _atInitialStart = true;
    }
  }

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
    while (depth < maxNestedCrossFades) {
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

  /// Smoothly blends from the current pose to [animation] over [duration]
  /// seconds using allocation-free TRS interpolation (LERP + shortest-arc
  /// SLERP).
  ///
  /// The outgoing side is whatever plays now: a clip, a blend space with all
  /// its samples, or a running crossfade, which keeps blending (up to
  /// [maxNestedCrossFades] nested fades), so interrupting a fade does not pop.
  void crossFadeTo(
    ModelAnimation? animation, {
    double duration = 0.25,
    bool resetClock = true,
    AnimationPlayMode mode = AnimationPlayMode.loop,
    bool allowSelfTransition = false,
    VoidCallback? onComplete,
  }) {
    if (duration <= 0.0 ||
        !hasActiveEvaluation ||
        (!allowSelfTransition && identical(animation, animationRef))) {
      startAnimation(
        animation,
        resetClock: resetClock,
        mode: mode,
        onComplete: onComplete,
      );
      return;
    }
    _beginOutgoing();
    _activateClip(
      animation,
      resetClock: resetClock,
      mode: mode,
      onComplete: onComplete,
    );
    _blendElapsed = 0.0;
    _blendDuration = duration;
  }

  /// Smoothly crossfades from the current clip, blend space or crossfade into
  /// [space] over [duration] seconds (see [crossFadeTo]).
  void crossFadeToBlendSpace1D(
    BlendSpace1D space, {
    double duration = 0.25,
    double initialValue = 0.0,
    bool resetClock = true,
    bool allowSelfTransition = false,
  }) {
    if (duration <= 0.0 ||
        !hasActiveEvaluation ||
        (!allowSelfTransition && identical(space, _blendSpace1D))) {
      playBlendSpace1D(
        space,
        initialValue: initialValue,
        resetClock: resetClock,
      );
      return;
    }
    _beginOutgoing();
    _activateBlendSpace1D(
      space,
      initialValue: initialValue,
      resetClock: resetClock,
    );
    _blendElapsed = 0.0;
    _blendDuration = duration;
  }

  /// Smoothly crossfades from the current clip, blend space or crossfade into
  /// [space] over [duration] seconds (see [crossFadeTo]).
  void crossFadeToBlendSpace2D(
    BlendSpace2D space, {
    double duration = 0.25,
    Vector2? initialValue,
    bool resetClock = true,
    bool allowSelfTransition = false,
  }) {
    if (duration <= 0.0 ||
        !hasActiveEvaluation ||
        (!allowSelfTransition && identical(space, _blendSpace2D))) {
      playBlendSpace2D(
        space,
        initialValue: initialValue,
        resetClock: resetClock,
      );
      return;
    }
    _beginOutgoing();
    _activateBlendSpace2D(
      space,
      initialValue: initialValue,
      resetClock: resetClock,
    );
    _blendElapsed = 0.0;
    _blendDuration = duration;
  }

  /// Advances active clocks by [dt] seconds; returns `true` when any pose
  /// changed.
  bool update(double dt) => _updateInternal(dt);

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

  static void _fireForwardRange(
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

  static void _fireBackwardRange(
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

  static ({double clock, int direction, bool completed, int wraps})
  _advanceClip(
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

  /// Legacy compatibility helper returning a new [Matrix4] for [nodeIndex].
  /// Prefer [writeNodeTransform] for zero-allocation evaluation.
  Matrix4 maybeTransform(int nodeIndex, Matrix4 transform) {
    if (!hasActiveEvaluation && layers.isEmpty) {
      return transform;
    }
    final out = Matrix4.identity();
    final restT = Vector3.zero();
    final restR = Quaternion.identity();
    final restS = Vector3.all(1.0);
    transform.decompose(restT, restR, restS);
    writeNodeTransform(nodeIndex, restT, restR, restS, transform, out);
    return out;
  }

  /// Evaluates the base pose of [nodeIndex] (target and crossfade, without
  /// layers) into [outT], [outR] and [outS]; returns `false`, leaving the rest
  /// pose in the outputs, when nothing animates the node.
  bool _evaluateBaseNodeTrs(
    int nodeIndex,
    Vector3 restTranslation,
    Quaternion restRotation,
    Vector3 restScale,
    Vector3 outT,
    Quaternion outR,
    Vector3 outS, {
    double? overrideNormalizedPhase,
    double? overrideClipClock,
  }) {
    final targetAnimated = _evaluateTargetTrs(
      nodeIndex,
      restTranslation,
      restRotation,
      restScale,
      outT,
      outR,
      outS,
      overrideNormalizedPhase: overrideNormalizedPhase,
      overrideClipClock: overrideClipClock,
    );
    if (!isCrossFading ||
        overrideClipClock != null ||
        overrideNormalizedPhase != null) {
      return targetAnimated;
    }

    // The target is fully evaluated: the static scratch is free for the
    // outgoing side, which writes into this state's own scratch.
    final bool outgoingAnimated;
    final nested = _outgoing;
    if (nested != null) {
      outgoingAnimated = nested._evaluateBaseNodeTrs(
        nodeIndex,
        restTranslation,
        restRotation,
        restScale,
        _fadeT,
        _fadeR,
        _fadeS,
      );
    } else {
      _fadeT.setFrom(restTranslation);
      _fadeR.setFrom(restRotation);
      _fadeS.setFrom(restScale);
      final prevNode = _previousRef?.nodes[nodeIndex];
      prevNode?.sampleTrsInto(_previousClock, _fadeT, _fadeR, _fadeS);
      outgoingAnimated = prevNode != null;
    }
    if (!targetAnimated && !outgoingAnimated) {
      return false;
    }

    final w = crossFadeProgress;
    outT.setValues(
      _fadeT.x + (outT.x - _fadeT.x) * w,
      _fadeT.y + (outT.y - _fadeT.y) * w,
      _fadeT.z + (outT.z - _fadeT.z) * w,
    );
    AnimationInterpolation.slerpQuaternionsInto(_fadeR, outR, w, outR);
    outS.setValues(
      _fadeS.x + (outS.x - _fadeS.x) * w,
      _fadeS.y + (outS.y - _fadeS.y) * w,
      _fadeS.z + (outS.z - _fadeS.z) * w,
    );
    return true;
  }

  /// Evaluates the current target (clip or blend space, no crossfade) of
  /// [nodeIndex]; the outputs start from the rest pose.
  bool _evaluateTargetTrs(
    int nodeIndex,
    Vector3 restTranslation,
    Quaternion restRotation,
    Vector3 restScale,
    Vector3 outT,
    Quaternion outR,
    Vector3 outS, {
    double? overrideNormalizedPhase,
    double? overrideClipClock,
  }) {
    outT.setFrom(restTranslation);
    outR.setFrom(restRotation);
    outS.setFrom(restScale);

    final space1D = _blendSpace1D;
    if (space1D != null) {
      final bracket = space1D.resolveBracket(blendParameter1D);
      final sampleA = space1D.samples[bracket.indexA];
      final sampleB = space1D.samples[bracket.indexB];
      final nodeA = sampleA.animation.nodes[nodeIndex];
      final nodeB = sampleB.animation.nodes[nodeIndex];
      if (nodeA == null && nodeB == null) {
        return false;
      }
      final phase = overrideNormalizedPhase ?? _normalizedPhase;
      final synced =
          space1D.syncNormalizedPhase || overrideNormalizedPhase != null;
      final timeA = synced
          ? phase * sampleA.animation.lastTime
          : _sampleClocks[bracket.indexA];
      nodeA?.sampleTrsInto(timeA, outT, outR, outS);

      if (bracket.indexA != bracket.indexB && bracket.t > 0.0) {
        final timeB = synced
            ? phase * sampleB.animation.lastTime
            : _sampleClocks[bracket.indexB];
        _t0.setFrom(restTranslation);
        _r0.setFrom(restRotation);
        _s0.setFrom(restScale);
        nodeB?.sampleTrsInto(timeB, _t0, _r0, _s0);
        final w = bracket.t;
        outT.setValues(
          outT.x + (_t0.x - outT.x) * w,
          outT.y + (_t0.y - outT.y) * w,
          outT.z + (_t0.z - outT.z) * w,
        );
        AnimationInterpolation.slerpQuaternionsInto(outR, _r0, w, outR);
        outS.setValues(
          outS.x + (_s0.x - outS.x) * w,
          outS.y + (_s0.y - outS.y) * w,
          outS.z + (_s0.z - outS.z) * w,
        );
      }
      return true;
    }

    final space2D = _blendSpace2D;
    if (space2D != null) {
      final count = space2D.evaluateWeights(
        _blendParam2D,
        _active2DIndices,
        _active2DWeights,
      );
      var anyAnimated = false;
      for (var k = 0; k < count; k++) {
        if (space2D.samples[_active2DIndices[k]].animation.nodes[nodeIndex] !=
            null) {
          anyAnimated = true;
          break;
        }
      }
      if (!anyAnimated) {
        return false;
      }
      final phase = overrideNormalizedPhase ?? _normalizedPhase;
      final synced =
          space2D.syncNormalizedPhase || overrideNormalizedPhase != null;
      var cumW = 0.0;
      for (var k = 0; k < count; k++) {
        final w = _active2DWeights[k];
        if (w <= 0.0) {
          continue;
        }
        final idx = _active2DIndices[k];
        final sample = space2D.samples[idx];
        final timeK = synced
            ? phase * sample.animation.lastTime
            : _sampleClocks[idx];
        _t0.setFrom(restTranslation);
        _r0.setFrom(restRotation);
        _s0.setFrom(restScale);
        sample.animation.nodes[nodeIndex]?.sampleTrsInto(
          timeK,
          _t0,
          _r0,
          _s0,
        );
        if (cumW == 0.0) {
          outT.setFrom(_t0);
          outR.setFrom(_r0);
          outS.setFrom(_s0);
          cumW = w;
        } else {
          cumW += w;
          final alpha = w / cumW;
          outT.setValues(
            outT.x + (_t0.x - outT.x) * alpha,
            outT.y + (_t0.y - outT.y) * alpha,
            outT.z + (_t0.z - outT.z) * alpha,
          );
          AnimationInterpolation.slerpQuaternionsInto(outR, _r0, alpha, outR);
          outS.setValues(
            outS.x + (_s0.x - outS.x) * alpha,
            outS.y + (_s0.y - outS.y) * alpha,
            outS.z + (_s0.z - outS.z) * alpha,
          );
        }
      }
      return true;
    }

    final currentNode = animationRef?.nodes[nodeIndex];
    if (currentNode == null) {
      return false;
    }
    final clipTime =
        overrideClipClock ??
        (overrideNormalizedPhase != null
            ? overrideNormalizedPhase * (animationRef?.lastTime ?? 0.0)
            : clock);
    currentNode.sampleTrsInto(clipTime, outT, outR, outS);
    return true;
  }

  /// Writes the evaluated (and optionally crossfaded / blend-space-interpolated)
  /// local [Matrix4] of [nodeIndex] into [out] without allocating.
  void writeNodeTransform(
    int nodeIndex,
    Vector3 restTranslation,
    Quaternion restRotation,
    Vector3 restScale,
    Matrix4 restMatrix,
    Matrix4 out, {
    double? overrideNormalizedPhase,
    double? overrideClipClock,
  }) {
    final baseChanged = _evaluateBaseNodeTrs(
      nodeIndex,
      restTranslation,
      restRotation,
      restScale,
      _t1,
      _r1,
      _s1,
      overrideNormalizedPhase: overrideNormalizedPhase,
      overrideClipClock: overrideClipClock,
    );

    var hasActiveLayer = false;
    if (overrideNormalizedPhase == null && overrideClipClock == null) {
      for (var i = 0; i < layers.length; i++) {
        final l = layers[i];
        if (l.weight > 0.0 &&
            l.nodeIndices.contains(nodeIndex) &&
            l.state.hasActiveEvaluation) {
          hasActiveLayer = true;
          break;
        }
      }
    }

    if (!baseChanged && !hasActiveLayer) {
      out.setFrom(restMatrix);
      return;
    }
    if (!baseChanged) {
      _t1.setFrom(restTranslation);
      _r1.setFrom(restRotation);
      _s1.setFrom(restScale);
    }

    if (hasActiveLayer) {
      for (var i = 0; i < layers.length; i++) {
        final layer = layers[i];
        final lw = layer.weight.clamp(0.0, 1.0);
        if (lw <= 0.0 || !layer.nodeIndices.contains(nodeIndex)) {
          continue;
        }
        final ls = layer.state;
        final layerAnimated = ls._evaluateBaseNodeTrs(
          nodeIndex,
          restTranslation,
          restRotation,
          restScale,
          _lt,
          _lr,
          _ls,
        );
        if (!layerAnimated) {
          continue;
        }
        _t1.setValues(
          _t1.x + (_lt.x - _t1.x) * lw,
          _t1.y + (_lt.y - _t1.y) * lw,
          _t1.z + (_lt.z - _t1.z) * lw,
        );
        AnimationInterpolation.slerpQuaternionsInto(_r1, _lr, lw, _r1);
        _s1.setValues(
          _s1.x + (_ls.x - _s1.x) * lw,
          _s1.y + (_ls.y - _s1.y) * lw,
          _s1.z + (_ls.z - _s1.z) * lw,
        );
      }
    }

    out.setFromTranslationRotationScale(_t1, _r1, _s1);
  }

  /// Samples active morph-target weights for [nodeIndex] (across single clips,
  /// crossfades, 1D/2D blend spaces, and [layers]) into [out], returning the
  /// number of morph targets written (`0` if un-animated).
  int sampleNodeMorphWeights(int nodeIndex, List<double> out) {
    final baseCount = _sampleBaseMorphWeights(nodeIndex, out);
    var totalTargets = baseCount;

    for (var li = 0; li < layers.length; li++) {
      final layer = layers[li];
      final lw = layer.weight.clamp(0.0, 1.0);
      if (lw <= 0.0 || !layer.nodeIndices.contains(nodeIndex)) {
        continue;
      }
      final layerCount = layer.state._sampleBaseMorphWeights(
        nodeIndex,
        _morphLayerScratch,
      );
      if (layerCount <= 0) {
        continue;
      }
      while (out.length < layerCount) {
        out.add(0.0);
      }
      if (layerCount > totalTargets) {
        for (var k = totalTargets; k < layerCount; k++) {
          out[k] = 0.0;
        }
        totalTargets = layerCount;
      }
      for (var k = 0; k < layerCount; k++) {
        out[k] += (_morphLayerScratch[k] - out[k]) * lw;
      }
    }
    return totalTargets;
  }

  int _sampleBaseMorphWeights(int nodeIndex, List<double> out) {
    final targetCount = _sampleTargetMorphWeights(nodeIndex, out);
    if (!isCrossFading) {
      return targetCount;
    }
    // The target is sampled: the static scratch is free for the outgoing
    // side, which writes into this state's own list.
    final int outgoingCount;
    final nested = _outgoing;
    if (nested != null) {
      outgoingCount = nested._sampleBaseMorphWeights(nodeIndex, _fadeMorph);
    } else {
      final prevMorph = _previousRef?.nodes[nodeIndex]?.morphWeights;
      outgoingCount = prevMorph?.targetCount ?? 0;
      if (prevMorph != null) {
        _ensureZeroedList(_fadeMorph, outgoingCount);
        prevMorph.sampleInto(_previousClock, _fadeMorph);
      }
    }
    final count = math.max(targetCount, outgoingCount);
    if (count <= 0) {
      return 0;
    }
    for (var k = targetCount; k < count; k++) {
      if (k < out.length) {
        out[k] = 0.0;
      } else {
        out.add(0.0);
      }
    }
    while (_fadeMorph.length < count) {
      _fadeMorph.add(0.0);
    }
    for (var k = outgoingCount; k < count; k++) {
      _fadeMorph[k] = 0.0;
    }
    final w = crossFadeProgress;
    for (var k = 0; k < count; k++) {
      out[k] = _fadeMorph[k] + (out[k] - _fadeMorph[k]) * w;
    }
    return count;
  }

  /// Samples the morph weights of the current target (clip or blend space, no
  /// crossfade) of [nodeIndex] into [out]; returns the number of targets.
  int _sampleTargetMorphWeights(int nodeIndex, List<double> out) {
    final space1D = _blendSpace1D;
    if (space1D != null) {
      final bracket = space1D.resolveBracket(blendParameter1D);
      final sampleA = space1D.samples[bracket.indexA];
      final sampleB = space1D.samples[bracket.indexB];
      final morphA = sampleA.animation.nodes[nodeIndex]?.morphWeights;
      final morphB = sampleB.animation.nodes[nodeIndex]?.morphWeights;
      final targetCount = math.max(
        morphA?.targetCount ?? 0,
        morphB?.targetCount ?? 0,
      );
      if (targetCount <= 0) {
        return 0;
      }
      _ensureZeroedList(out, targetCount);
      if (morphA != null) {
        final timeA = space1D.syncNormalizedPhase
            ? _normalizedPhase * sampleA.animation.lastTime
            : _sampleClocks[bracket.indexA];
        morphA.sampleInto(timeA, out);
      }
      if (bracket.indexA != bracket.indexB && bracket.t > 0.0) {
        _ensureZeroedList(_morphBlendScratch, targetCount);
        if (morphB != null) {
          final timeB = space1D.syncNormalizedPhase
              ? _normalizedPhase * sampleB.animation.lastTime
              : _sampleClocks[bracket.indexB];
          morphB.sampleInto(timeB, _morphBlendScratch);
        }
        final w = bracket.t;
        for (var k = 0; k < targetCount; k++) {
          out[k] += (_morphBlendScratch[k] - out[k]) * w;
        }
      }
      return targetCount;
    }

    final space2D = _blendSpace2D;
    if (space2D != null) {
      final count = space2D.evaluateWeights(
        _blendParam2D,
        _active2DIndices,
        _active2DWeights,
      );
      var targetCount = 0;
      for (var k = 0; k < count; k++) {
        final m = space2D
            .samples[_active2DIndices[k]]
            .animation
            .nodes[nodeIndex]
            ?.morphWeights;
        if (m != null && m.targetCount > targetCount) {
          targetCount = m.targetCount;
        }
      }
      if (targetCount <= 0) {
        return 0;
      }
      _ensureZeroedList(out, targetCount);
      for (var k = 0; k < count; k++) {
        final w = _active2DWeights[k];
        if (w <= 0.0) {
          continue;
        }
        final idx = _active2DIndices[k];
        final s = space2D.samples[idx];
        final m = s.animation.nodes[nodeIndex]?.morphWeights;
        if (m == null) {
          continue;
        }
        _ensureZeroedList(_morphBlendScratch, m.targetCount);
        final timeK = space2D.syncNormalizedPhase
            ? _normalizedPhase * s.animation.lastTime
            : _sampleClocks[idx];
        m.sampleInto(timeK, _morphBlendScratch);
        for (var j = 0; j < m.targetCount; j++) {
          out[j] += _morphBlendScratch[j] * w;
        }
      }
      return targetCount;
    }

    final curMorph = animationRef?.nodes[nodeIndex]?.morphWeights;
    final targetCount = curMorph?.targetCount ?? 0;
    if (curMorph == null || targetCount <= 0) {
      return 0;
    }
    _ensureZeroedList(out, targetCount);
    curMorph.sampleInto(clock, out);
    return targetCount;
  }

  static void _ensureZeroedList(List<double> list, int count) {
    while (list.length < count) {
      list.add(0.0);
    }
    for (var i = 0; i < count; i++) {
      list[i] = 0.0;
    }
  }

  void reset() {
    clock = 0.0;
    _normalizedPhase = 0.0;
    _completed = false;
    _pingPongDirection = 1;
    _atInitialStart = true;
    _lastLoopWrapCount = 0;
    if (_sampleClocks.isNotEmpty) {
      _sampleClocks.fillRange(0, _sampleClocks.length, 0.0);
    }
  }

  static final Vector3 _t0 = Vector3.zero();
  static final Quaternion _r0 = Quaternion.identity();
  static final Vector3 _s0 = Vector3.all(1.0);
  static final Vector3 _t1 = Vector3.zero();
  static final Quaternion _r1 = Quaternion.identity();
  static final Vector3 _s1 = Vector3.all(1.0);
  static final Vector3 _lt = Vector3.zero();
  static final Quaternion _lr = Quaternion.identity();
  static final Vector3 _ls = Vector3.all(1.0);
  static final List<double> _morphBlendScratch = [];
  static final List<double> _morphLayerScratch = [];
  static final List<AnimationState> _spareStates = [];
}
