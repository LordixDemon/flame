part of 'timeline_3d.dart';

// =============================================================================
// TransformTrack3D
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
  final Vector3 _zeroVec3 = Vector3.zero();
  final Quaternion _zeroQuat = Quaternion(0, 0, 0, 0);

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

  void _sampleVec3(
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

  void _sampleQuat(
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
        if (b0 != null || a1 != null) {
          AnimationInterpolation.cubicHermiteQuaternionInto(
            k0.value,
            b0 ?? _zeroQuat,
            k1.value,
            a1 ?? _zeroQuat,
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
}

// =============================================================================
// MorphWeightTrack3D
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
