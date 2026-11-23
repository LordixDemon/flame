import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show VoidCallback;

import 'package:flame_3d/core.dart';
import 'package:flame_3d/src/model/blend_space_3d.dart';
import 'package:flame_3d/src/model/model_animation.dart';
import 'package:flame_3d/src/parser/gltf/animation_interpolation.dart';

part 'animation_pose_workspace.dart';
part 'animation_sampling.dart';

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

  /// Writes the evaluated local [Matrix4] of [nodeIndex] into [out].
  void writeNodeTransform(
    int nodeIndex,
    Vector3 restTranslation,
    Quaternion restRotation,
    Vector3 restScale,
    Matrix4 restMatrix,
    Matrix4 out, {
    double? overrideNormalizedPhase,
    double? overrideClipClock,
  }) => _writeNodeTransformImpl(
    nodeIndex,
    restTranslation,
    restRotation,
    restScale,
    restMatrix,
    out,
    overrideNormalizedPhase: overrideNormalizedPhase,
    overrideClipClock: overrideClipClock,
  );

  /// Writes the evaluated morph target weights of [nodeIndex] into [out].
  int sampleNodeMorphWeights(int nodeIndex, List<double> out) =>
      _sampleNodeMorphWeightsImpl(nodeIndex, out);

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
}
