part of 'animation_state.dart';

extension _AnimationStateSampling on AnimationState {
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
      _ensure1DBracket(space1D);
      final idxA = _cached1DIndexA;
      final idxB = _cached1DIndexB;
      final w = _cached1DT;
      final sampleA = space1D.samples[idxA];
      final sampleB = space1D.samples[idxB];
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
          : _sampleClocks[idxA];
      nodeA?.sampleTrsInto(timeA, outT, outR, outS);

      if (idxA != idxB && w > 0.0) {
        final timeB = synced
            ? phase * sampleB.animation.lastTime
            : _sampleClocks[idxB];
        _t0.setFrom(restTranslation);
        _r0.setFrom(restRotation);
        _s0.setFrom(restScale);
        nodeB?.sampleTrsInto(timeB, _t0, _r0, _s0);
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
      final count = _ensure2DWeights(space2D);
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
  void _writeNodeTransformImpl(
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
  int _sampleNodeMorphWeightsImpl(int nodeIndex, List<double> out) {
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
      _ensure1DBracket(space1D);
      final idxA = _cached1DIndexA;
      final idxB = _cached1DIndexB;
      final w = _cached1DT;
      final sampleA = space1D.samples[idxA];
      final sampleB = space1D.samples[idxB];
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
            : _sampleClocks[idxA];
        morphA.sampleInto(timeA, out);
      }
      if (idxA != idxB && w > 0.0) {
        _ensureZeroedList(_morphBlendScratch, targetCount);
        if (morphB != null) {
          final timeB = space1D.syncNormalizedPhase
              ? _normalizedPhase * sampleB.animation.lastTime
              : _sampleClocks[idxB];
          morphB.sampleInto(timeB, _morphBlendScratch);
        }
        for (var k = 0; k < targetCount; k++) {
          out[k] += (_morphBlendScratch[k] - out[k]) * w;
        }
      }
      return targetCount;
    }

    final space2D = _blendSpace2D;
    if (space2D != null) {
      final count = _ensure2DWeights(space2D);
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
}
