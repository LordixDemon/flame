part of 'animation_retargeter_3d.dart';

/// Cross-rig humanoid skeletal animation retargeter.
abstract final class AnimationRetargeter3D._() {
  /// Retargets [sourceClip] from [sourceProfile] onto [targetProfile] using
  /// model-space rest-pose delta conjugation and `hipsRestHeight`-proportional
  /// root/pelvis translation scaling.
  ///
  /// For each mapped bone:
  /// - Local rotation `q_srcAnim` is converted into a rig-space delta from
  ///   source rest (`W_src * (L_src^-1 * q_srcAnim) * W_src^-1`) and conjugated
  ///   into the target bone's local frame:
  ///   `q_dstAnim = (P_dst^-1 * P_src) * q_srcAnim * (W_src^-1 * W_dst)`.
  /// - Pelvis (`HumanoidBone3D.hips`) displacements from rest are rotated into
  ///   rig space, scaled by
  ///   `targetProfile.hipsRestHeight / sourceProfile.hipsRestHeight`, and
  ///   mapped onto the target `hips` rest translation.
  static ModelAnimation retargetClip(
    ModelAnimation sourceClip, {
    required HumanoidProfile3D sourceProfile,
    required HumanoidProfile3D targetProfile,
    String? newName,
  }) {
    final srcHeight = sourceProfile.hipsRestHeight;
    final dstHeight = targetProfile.hipsRestHeight;
    final heightScale = srcHeight > 1e-6 ? dstHeight / srcHeight : 1.0;

    final retargetedNodes = <int, NodeAnimation>{};

    for (final bone in HumanoidBone3D.values) {
      final srcIdx = sourceProfile.nodeIndexFor(bone);
      final dstIdx = targetProfile.nodeIndexFor(bone);
      if (srcIdx == null || dstIdx == null) {
        continue;
      }
      final srcNodeAnim = sourceClip.nodes[srcIdx];
      if (srcNodeAnim == null) {
        continue;
      }
      final srcRest = sourceProfile._restByNode[srcIdx];
      final dstRest = targetProfile._restByNode[dstIdx];
      if (srcRest == null || dstRest == null) {
        continue;
      }

      // Precompute left & right conjugation factors:
      // `q_dstAnim = qLeft * q_srcAnim * qRight`
      // where `qLeft = inv(P_dstRest) * P_srcRest`
      // and   `qRight = inv(W_srcRest) * W_dstRest`.
      final invDstParent = dstRest.parentWorldRotation.conjugated();
      final invSrcWorld = srcRest.worldRotation.conjugated();
      final qLeft = (invDstParent * srcRest.parentWorldRotation)..normalize();
      final qRight = (invSrcWorld * dstRest.worldRotation)..normalize();

      final newChannels = <AnimationController<dynamic>>[];
      for (final controller in srcNodeAnim.channels) {
        final spline = controller.animation;
        if (spline is RotationAnimationSpline) {
          newChannels.add(
            AnimationController<Quaternion>(
              animation: _retargetRotationSpline(spline, qLeft, qRight),
            ),
          );
        } else if (spline is TranslationAnimationSpline) {
          // Only retarget root/pelvis (`hips`) translations by default, or
          // additive bone offsets scaled proportionally into target parent
          // space.
          newChannels.add(
            AnimationController<Vector3>(
              animation: _retargetTranslationSpline(
                spline,
                srcRest: srcRest,
                dstRest: dstRest,
                parentMapRot: qLeft,
                scale: heightScale,
              ),
            ),
          );
        } else if (spline is ScaleAnimationSpline) {
          newChannels.add(
            AnimationController<Vector3>(
              animation: _retargetScaleSpline(
                spline,
                srcRestScale: srcRest.localScale,
                dstRestScale: dstRest.localScale,
              ),
            ),
          );
        }
      }

      if (newChannels.isNotEmpty || srcNodeAnim.morphWeights != null) {
        retargetedNodes[dstIdx] = NodeAnimation(
          channels: newChannels,
          morphWeights: srcNodeAnim.morphWeights,
        );
      }
    }

    return ModelAnimation(
      name: newName ?? sourceClip.name,
      nodes: retargetedNodes,
      events: sourceClip.events,
    );
  }

  static RotationAnimationSpline _retargetRotationSpline(
    RotationAnimationSpline src,
    Quaternion qLeft,
    Quaternion qRight,
  ) {
    final times = <double>[for (final kf in src.values) kf.time];
    Quaternion mapQuat(Quaternion q) {
      final out = (qLeft * q) * qRight;
      if (out.length2 > 1e-12) {
        out.normalize();
      }
      return out;
    }

    final inT = src.inTangents;
    final outT = src.outTangents;
    if (src.interpolation == AnimationInterpolation.cubicSpline &&
        inT != null &&
        outT != null &&
        inT.length == src.values.length &&
        outT.length == src.values.length) {
      final triplets = <Quaternion>[];
      var prevVal = Quaternion.identity();
      for (var i = 0; i < src.values.length; i++) {
        final inMapped = (qLeft * inT[i]) * qRight;
        final valMapped = mapQuat(src.values[i].value);
        final outMapped = (qLeft * outT[i]) * qRight;
        if (i > 0 && prevVal.dot(valMapped) < 0.0) {
          inMapped.scale(-1.0);
          valMapped.scale(-1.0);
          outMapped.scale(-1.0);
        }
        prevVal = valMapped;
        triplets
          ..add(inMapped)
          ..add(valMapped)
          ..add(outMapped);
      }
      return RotationAnimationSpline.from(
        interpolation: src.interpolation,
        times: times,
        values: triplets,
      );
    }

    final mapped = <Quaternion>[];
    for (var i = 0; i < src.values.length; i++) {
      final q = mapQuat(src.values[i].value);
      if (i > 0 && mapped[i - 1].dot(q) < 0.0) {
        q.scale(-1.0);
      }
      mapped.add(q);
    }
    return RotationAnimationSpline.from(
      interpolation: src.interpolation,
      times: times,
      values: mapped,
    );
  }

  static TranslationAnimationSpline _retargetTranslationSpline(
    TranslationAnimationSpline src, {
    required _BoneRestTransform srcRest,
    required _BoneRestTransform dstRest,
    required Quaternion parentMapRot,
    required double scale,
  }) {
    final times = <double>[for (final kf in src.values) kf.time];
    Vector3 mapPos(Vector3 p) {
      final delta = p - srcRest.localTranslation;
      rotateVectorByQuat(parentMapRot, delta, delta);
      delta.scale(scale);
      return dstRest.localTranslation + delta;
    }

    Vector3 mapTangent(Vector3 t) {
      final v = t.clone();
      rotateVectorByQuat(parentMapRot, v, v);
      v.scale(scale);
      return v;
    }

    final inT = src.inTangents;
    final outT = src.outTangents;
    if (src.interpolation == AnimationInterpolation.cubicSpline &&
        inT != null &&
        outT != null &&
        inT.length == src.values.length &&
        outT.length == src.values.length) {
      final triplets = <Vector3>[];
      for (var i = 0; i < src.values.length; i++) {
        triplets
          ..add(mapTangent(inT[i]))
          ..add(mapPos(src.values[i].value))
          ..add(mapTangent(outT[i]));
      }
      return TranslationAnimationSpline.from(
        interpolation: src.interpolation,
        times: times,
        values: triplets,
      );
    }

    return TranslationAnimationSpline.from(
      interpolation: src.interpolation,
      times: times,
      values: [for (final kf in src.values) mapPos(kf.value)],
    );
  }

  static ScaleAnimationSpline _retargetScaleSpline(
    ScaleAnimationSpline src, {
    required Vector3 srcRestScale,
    required Vector3 dstRestScale,
  }) {
    final times = <double>[for (final kf in src.values) kf.time];
    double ratio(double numVal, double denVal) =>
        denVal.abs() > 1e-6 ? numVal / denVal : 1.0;

    Vector3 mapScale(Vector3 s) {
      return Vector3(
        dstRestScale.x * ratio(s.x, srcRestScale.x),
        dstRestScale.y * ratio(s.y, srcRestScale.y),
        dstRestScale.z * ratio(s.z, srcRestScale.z),
      );
    }

    final inT = src.inTangents;
    final outT = src.outTangents;
    if (src.interpolation == AnimationInterpolation.cubicSpline &&
        inT != null &&
        outT != null &&
        inT.length == src.values.length &&
        outT.length == src.values.length) {
      final triplets = <Vector3>[];
      for (var i = 0; i < src.values.length; i++) {
        triplets
          ..add(inT[i].clone())
          ..add(mapScale(src.values[i].value))
          ..add(outT[i].clone());
      }
      return ScaleAnimationSpline.from(
        interpolation: src.interpolation,
        times: times,
        values: triplets,
      );
    }

    return ScaleAnimationSpline.from(
      interpolation: src.interpolation,
      times: times,
      values: [for (final kf in src.values) mapScale(kf.value)],
    );
  }
}
