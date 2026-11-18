import 'dart:ui' show VoidCallback;

import 'package:flame_3d/core.dart';
import 'package:flame_3d/src/model/model_animation.dart';
import 'package:flame_3d/src/parser/gltf/animation_interpolation.dart';

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

/// Couples one or two [ModelAnimation] clips with playback clocks, playback
/// modes, and allocation-free TRS crossfading (plus optional masked
/// [layers]).
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

  bool _completed = false;
  int _pingPongDirection = 1;

  // Outgoing clip during a crossfade.
  ModelAnimation? _previousRef;
  double _previousClock = 0.0;
  AnimationPlayMode _previousMode = AnimationPlayMode.loop;
  int _previousPingPongDir = 1;
  double _blendElapsed = 0.0;
  double _blendDuration = 0.0;

  /// Whether a non-looping clip has reached its final keyframe.
  bool get isCompleted => _completed;

  /// Whether a crossfade transition is currently in progress.
  bool get isCrossFading => _previousRef != null && _blendDuration > 0.0;

  /// Current crossfade blend weight in `[0, 1]` (`1` when not crossfading).
  double get crossFadeProgress => _blendDuration > 0.0
      ? (_blendElapsed / _blendDuration).clamp(0.0, 1.0)
      : 1.0;

  /// Whether calling [update] with `dt > 0` will advance an active animation.
  bool get isPlaying =>
      speed != 0.0 && ((animationRef != null && !_completed) || isCrossFading);

  /// Starts [animation] immediately, canceling any active crossfade.
  void startAnimation(
    ModelAnimation? animation, {
    bool resetClock = true,
    AnimationPlayMode mode = AnimationPlayMode.loop,
    VoidCallback? onComplete,
  }) {
    _previousRef = null;
    _blendDuration = 0.0;
    _blendElapsed = 0.0;
    animationRef = animation;
    this.mode = mode;
    this.onComplete = onComplete;
    _completed = false;
    _pingPongDirection = 1;
    if (resetClock) {
      reset();
    }
  }

  /// Smoothly blends from the current pose/clip to [animation] over [duration]
  /// seconds using allocation-free TRS interpolation (LERP + shortest-arc
  /// SLERP).
  void crossFadeTo(
    ModelAnimation? animation, {
    double duration = 0.25,
    bool resetClock = true,
    AnimationPlayMode mode = AnimationPlayMode.loop,
    VoidCallback? onComplete,
  }) {
    if (duration <= 0.0 ||
        animationRef == null ||
        identical(animation, animationRef)) {
      startAnimation(
        animation,
        resetClock: resetClock,
        mode: mode,
        onComplete: onComplete,
      );
      return;
    }

    _previousRef = animationRef;
    _previousClock = clock;
    _previousMode = this.mode;
    _previousPingPongDir = _pingPongDirection;
    _blendElapsed = 0.0;
    _blendDuration = duration;

    animationRef = animation;
    this.mode = mode;
    this.onComplete = onComplete;
    _completed = false;
    _pingPongDirection = 1;
    if (resetClock) {
      clock = 0.0;
    }
  }

  /// Advances active clocks by [dt] seconds; returns `true` when any pose
  /// changed.
  bool update(double dt) {
    if (dt == 0.0 || speed == 0.0) {
      return false;
    }
    final scaledDt = dt * speed;
    var changed = false;

    if (_previousRef case final prev?) {
      final step = _advanceClip(
        prev,
        _previousClock,
        scaledDt,
        _previousMode,
        _previousPingPongDir,
      );
      _previousClock = step.clock;
      _previousPingPongDir = step.direction;
      _blendElapsed += dt.abs();
      if (_blendElapsed >= _blendDuration) {
        _previousRef = null;
        _blendDuration = 0.0;
        _blendElapsed = 0.0;
      }
      changed = true;
    }

    final animation = animationRef;
    if (animation != null && !_completed) {
      final step = _advanceClip(
        animation,
        clock,
        scaledDt,
        mode,
        _pingPongDirection,
      );
      clock = step.clock;
      _pingPongDirection = step.direction;
      changed = true;
      if (step.completed && !_completed) {
        _completed = true;
        onComplete?.call();
      }
    }

    for (var i = 0; i < layers.length; i++) {
      final layer = layers[i];
      if (layer.weight > 0.0 && layer.state.update(dt)) {
        changed = true;
      }
    }

    return changed;
  }

  static ({double clock, int direction, bool completed}) _advanceClip(
    ModelAnimation animation,
    double currentClock,
    double dt,
    AnimationPlayMode mode,
    int direction,
  ) {
    final duration = animation.lastTime;
    if (duration <= 1e-9) {
      return (
        clock: 0.0,
        direction: direction,
        completed: mode == AnimationPlayMode.once,
      );
    }

    switch (mode) {
      case AnimationPlayMode.loop:
        var next = currentClock + dt;
        if (next > duration || next < 0.0) {
          next = next % duration;
          if (next < 0.0) {
            next += duration;
          }
        }
        return (clock: next, direction: 1, completed: false);

      case AnimationPlayMode.once:
        final next = currentClock + dt;
        if (next >= duration) {
          return (clock: duration, direction: 1, completed: true);
        }
        if (next <= 0.0) {
          return (clock: 0.0, direction: 1, completed: dt < 0.0);
        }
        return (clock: next, direction: 1, completed: false);

      case AnimationPlayMode.pingPong:
        var next = currentClock + dt * direction;
        var dir = direction;
        while (next > duration || next < 0.0) {
          if (next > duration) {
            next = 2.0 * duration - next;
            dir = -1;
          } else if (next < 0.0) {
            next = -next;
            dir = 1;
          }
        }
        return (clock: next, direction: dir, completed: false);
    }
  }

  /// Legacy compatibility helper returning a new [Matrix4] for [nodeIndex].
  /// Prefer [writeNodeTransform] for zero-allocation evaluation.
  Matrix4 maybeTransform(int nodeIndex, Matrix4 transform) {
    if (animationRef == null && _previousRef == null) {
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

  /// Writes the evaluated (and optionally crossfaded) local [Matrix4] of
  /// [nodeIndex] into [out] without allocating.
  void writeNodeTransform(
    int nodeIndex,
    Vector3 restTranslation,
    Quaternion restRotation,
    Vector3 restScale,
    Matrix4 restMatrix,
    Matrix4 out,
  ) {
    final currentNode = animationRef?.nodes[nodeIndex];
    final prevNode = isCrossFading ? _previousRef?.nodes[nodeIndex] : null;
    var hasActiveLayer = false;
    for (var i = 0; i < layers.length; i++) {
      final l = layers[i];
      if (l.weight > 0.0 &&
          l.nodeIndices.contains(nodeIndex) &&
          (l.state.animationRef != null || l.state.isCrossFading)) {
        hasActiveLayer = true;
        break;
      }
    }
    if (currentNode == null && prevNode == null && !hasActiveLayer) {
      out.setFrom(restMatrix);
      return;
    }

    _t1.setFrom(restTranslation);
    _r1.setFrom(restRotation);
    _s1.setFrom(restScale);
    currentNode?.sampleTrsInto(clock, _t1, _r1, _s1);

    if (isCrossFading) {
      _t0.setFrom(restTranslation);
      _r0.setFrom(restRotation);
      _s0.setFrom(restScale);
      prevNode?.sampleTrsInto(_previousClock, _t0, _r0, _s0);

      final w = crossFadeProgress;
      _t1.setValues(
        _t0.x + (_t1.x - _t0.x) * w,
        _t0.y + (_t1.y - _t0.y) * w,
        _t0.z + (_t1.z - _t0.z) * w,
      );
      AnimationInterpolation.slerpQuaternionsInto(_r0, _r1, w, _r1);
      _s1.setValues(
        _s0.x + (_s1.x - _s0.x) * w,
        _s0.y + (_s1.y - _s0.y) * w,
        _s0.z + (_s1.z - _s0.z) * w,
      );
    }

    for (var i = 0; i < layers.length; i++) {
      final layer = layers[i];
      final lw = layer.weight.clamp(0.0, 1.0);
      if (lw <= 0.0 || !layer.nodeIndices.contains(nodeIndex)) {
        continue;
      }
      final ls = layer.state;
      final lCur = ls.animationRef?.nodes[nodeIndex];
      final lPrev = ls.isCrossFading ? ls._previousRef?.nodes[nodeIndex] : null;
      if (lCur == null && lPrev == null) {
        continue;
      }
      _lt.setFrom(restTranslation);
      _lr.setFrom(restRotation);
      _ls.setFrom(restScale);
      lCur?.sampleTrsInto(ls.clock, _lt, _lr, _ls);
      if (ls.isCrossFading) {
        _t0.setFrom(restTranslation);
        _r0.setFrom(restRotation);
        _s0.setFrom(restScale);
        lPrev?.sampleTrsInto(ls._previousClock, _t0, _r0, _s0);
        final cw = ls.crossFadeProgress;
        _lt.setValues(
          _t0.x + (_lt.x - _t0.x) * cw,
          _t0.y + (_lt.y - _t0.y) * cw,
          _t0.z + (_lt.z - _t0.z) * cw,
        );
        AnimationInterpolation.slerpQuaternionsInto(_r0, _lr, cw, _lr);
        _ls.setValues(
          _s0.x + (_ls.x - _s0.x) * cw,
          _s0.y + (_ls.y - _s0.y) * cw,
          _s0.z + (_ls.z - _s0.z) * cw,
        );
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

    out.setFromTranslationRotationScale(_t1, _r1, _s1);
  }

  void reset() {
    clock = 0.0;
    _completed = false;
    _pingPongDirection = 1;
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
}
