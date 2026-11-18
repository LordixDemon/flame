import 'dart:math';

import 'package:flame_3d/core.dart';
import 'package:flame_3d/src/parser/gltf/animation_interpolation.dart';

/// A single keyframe inside an animation; [T] is the type of value being
/// animated.
typedef AnimationKeyframe<T> = ({double time, T value});

/// Base class for animation splines. Animations are a sequence of
/// keyframes over either:
/// * position ([TranslationAnimationSpline]),
/// * angle ([RotationAnimationSpline]),
/// * scale ([ScaleAnimationSpline]).
abstract class AnimationSpline<T> {
  final AnimationInterpolation interpolation;
  final List<AnimationKeyframe<T>> values;

  AnimationSpline({
    required this.interpolation,
    required this.values,
  });

  AnimationSpline.from({
    required this.interpolation,
    required List<double> times,
    required List<T> values,
  }) : values = List.generate(times.length, (index) {
         return (time: times[index], value: values[index]);
       });

  T lerp(T a, T b, double t);
  void transform(Matrix4 matrix, T value);

  /// Applies the interpolated channel value between [a] and [b] at [t] directly
  /// into the TRS components `(translation, rotation, scale)` without
  /// allocating.
  void applyTrs(
    T a,
    T b,
    double t,
    Vector3 translation,
    Quaternion rotation,
    Vector3 scale,
  );
}

/// An animation spline over the position of a transformation (translation).
class TranslationAnimationSpline.from({
  required super.interpolation,
  required super.times,
  required super.values,
}) extends AnimationSpline<Vector3> {
  this : super.from();

  @override
  Vector3 lerp(Vector3 a, Vector3 b, double t) {
    return interpolation.lerp(a, b, t);
  }

  @override
  void transform(Matrix4 matrix, Vector3 value) {
    matrix.setTranslation(value);
  }

  @override
  void applyTrs(
    Vector3 a,
    Vector3 b,
    double t,
    Vector3 translation,
    Quaternion rotation,
    Vector3 scale,
  ) {
    interpolation.lerpInto(a, b, t, translation);
  }
}

/// An animation spline over the angle of a transformation (rotation).
class RotationAnimationSpline.from({
  required super.interpolation,
  required super.times,
  required super.values,
}) extends AnimationSpline<Quaternion> {
  this : super.from();

  @override
  Quaternion lerp(Quaternion a, Quaternion b, double t) {
    return interpolation.slerp(a, b, t);
  }

  @override
  void transform(Matrix4 matrix, Quaternion value) {
    matrix.setRotation(value.asRotationMatrix());
  }

  @override
  void applyTrs(
    Quaternion a,
    Quaternion b,
    double t,
    Vector3 translation,
    Quaternion rotation,
    Vector3 scale,
  ) {
    interpolation.slerpInto(a, b, t, rotation);
  }
}

/// An animation spline over the scale of a transformation (scaling).
class ScaleAnimationSpline.from({
  required super.interpolation,
  required super.times,
  required super.values,
}) extends AnimationSpline<Vector3> {
  this : super.from();

  @override
  Vector3 lerp(Vector3 a, Vector3 b, double t) {
    return interpolation.lerp(a, b, t);
  }

  @override
  void transform(Matrix4 matrix, Vector3 value) {
    matrix.scaleByVector3(value);
  }

  @override
  void applyTrs(
    Vector3 a,
    Vector3 b,
    double t,
    Vector3 translation,
    Quaternion rotation,
    Vector3 scale,
  ) {
    interpolation.lerpInto(a, b, t, scale);
  }
}

/// Allows sampling of an animation by interpolating keyframes in `O(log K)`.
class AnimationController<T>({
  required final AnimationSpline<T> animation,
}) {
  final double lastTime = animation.values.isEmpty
      ? 0.0
      : animation.values.last.time;

  T sample(double time) {
    final values = animation.values;
    if (values.length == 1 || time <= values.first.time) {
      return values.first.value;
    }
    if (time >= values.last.time) {
      return values.last.value;
    }
    final i = _segmentIndex(values, time);
    final t0 = values[i].time;
    final t1 = values[i + 1].time;
    final span = t1 - t0;
    final t = span > 1e-12 ? (time - t0) / span : 0.0;
    return animation.lerp(values[i].value, values[i + 1].value, t);
  }

  void sampleInto(double time, Matrix4 matrix) {
    final value = sample(time);
    animation.transform(matrix, value);
  }

  /// Samples the channel at [time] straight into `(translation, rotation,
  /// scale)` with zero heap allocations.
  void sampleTrsInto(
    double time,
    Vector3 translation,
    Quaternion rotation,
    Vector3 scale,
  ) {
    final values = animation.values;
    if (values.isEmpty) {
      return;
    }
    if (values.length == 1 || time <= values.first.time) {
      final first = values.first.value;
      animation.applyTrs(first, first, 0.0, translation, rotation, scale);
      return;
    }
    if (time >= values.last.time) {
      final last = values.last.value;
      animation.applyTrs(last, last, 0.0, translation, rotation, scale);
      return;
    }
    final i = _segmentIndex(values, time);
    final t0 = values[i].time;
    final t1 = values[i + 1].time;
    final span = t1 - t0;
    final t = span > 1e-12 ? (time - t0) / span : 0.0;
    animation.applyTrs(
      values[i].value,
      values[i + 1].value,
      t,
      translation,
      rotation,
      scale,
    );
  }

  static int _segmentIndex<T>(List<AnimationKeyframe<T>> values, double time) {
    var lo = 0;
    var hi = values.length - 2;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (time < values[mid].time) {
        hi = mid - 1;
      } else if (time >= values[mid + 1].time) {
        lo = mid + 1;
      } else {
        return mid;
      }
    }
    return lo.clamp(0, values.length - 2);
  }
}

/// Groups the animations of a single node in a `Model`, which can be
/// controlled by multiple animation channels.
class NodeAnimation({
  required final List<AnimationController> channels,
}) {
  final double lastTime = channels.isEmpty
      ? 0.0
      : channels.map((e) => e.lastTime).reduce(max);

  void sampleInto(double time, Matrix4 matrix) {
    for (final channel in channels) {
      channel.sampleInto(time, matrix);
    }
  }

  /// Samples all channels for [time] into `(translation, rotation, scale)`
  /// starting from the node's rest TRS.
  void sampleTrsInto(
    double time,
    Vector3 translation,
    Quaternion rotation,
    Vector3 scale,
  ) {
    for (var i = 0; i < channels.length; i++) {
      channels[i].sampleTrsInto(time, translation, rotation, scale);
    }
  }
}

/// Groups the animations for all nodes of a `Model`.
class ModelAnimation({
  required final String? name,
  required final Map<int, NodeAnimation> nodes,
}) {
  final double lastTime = nodes.isEmpty
      ? 0.0
      : nodes.values.map((e) => e.lastTime).reduce(max);
}
