part of 'barrier_material.dart';

extension _BarrierUniforms on BarrierMaterial {
  /// Writes this material's values into the shaders of [target] (this
  /// material, or its reaction material with [reactionScale] above `0`).
  void _write(
    Material target,
    RenderContext3D context,
    double reactionScale,
    CameraPassApplyCache applyCache,
  ) {
    final vertex = target.vertexShaderFor(BarrierMesh.layout)..resource;
    final shader = target.fragmentShader..resource;
    final lookIdx = shader.blockIndexOf('BarrierLook');
    if (applyCache.isShaderAndVersionValid(target.version, vertex, shader)) {
      if (lookIdx >= 0) {
        final lb = shader.blockAt(lookIdx);
        final lo =
            (lb.cachedWriterOffsets as _BarrierLookOffsets?) ??
            (lb.cachedWriterOffsets = _BarrierLookOffsets(lb));
        if (lo._viewer >= 0) {
          _writeViewerTo(context, lb, lo._viewer);
        }
      }
      return;
    }

    final appear = this.appear.clamp(0.0, 1.0);
    final count = _packImpacts();

    // The vertex stage: the height, the wobble and the impacts it moves the
    // surface around.
    final wavelength = math.max(wobbleWavelength, 1e-3);
    final radius = math.max(wobbleRadius, 1e-3);
    final amplitude = wobbleAmplitude > 0 ? wobbleAmplitude : 0.0;
    final shapeIdx = vertex.blockIndexOf('BarrierShape');
    final p = _packedImpacts;
    if (shapeIdx >= 0) {
      final sb = vertex.blockAt(shapeIdx);
      final so =
          (sb.cachedWriterOffsets as _BarrierShapeOffsets?) ??
          (sb.cachedWriterOffsets = _BarrierShapeOffsets(sb));
      if (so._params >= 0) {
        sb.writeVec4ValuesAt(
          so._params,
          appear,
          math.max(heightScale, 0),
          amplitude,
          count.toDouble(),
        );
      }
      if (so._wobble >= 0) {
        sb.writeVec4ValuesAt(
          so._wobble,
          2 * math.pi / wavelength,
          math.max(wobbleFrequency, 0) * wavelength,
          math.max(wobbleDecay, 0),
          1 / (radius * radius),
        );
      }
      if (so._wobbleExtra >= 0) {
        sb.writeVec4ValuesAt(
          so._wobbleExtra,
          1 / math.max(impactDuration, 1e-3),
          2 / wavelength,
          0,
          0,
        );
      }
      if (so._impactPositions >= 0) {
        for (var i = 0; i < BarrierMaterial.maxImpactSlots; i++) {
          final o = i * 8;
          sb.writeVec4ValuesAt(
            so._impactPositions + i * 4,
            p[o],
            p[o + 1],
            p[o + 2],
            p[o + 3],
          );
        }
      }
      if (so._impactStrengths >= 0) {
        sb
          ..writeVec4ValuesAt(
            so._impactStrengths,
            p[7],
            p[15],
            p[23],
            p[31],
          )
          ..writeVec4ValuesAt(
            so._impactStrengths + 4,
            p[39],
            p[47],
            p[55],
            p[63],
          );
      }
    }

    final blend = renderState.blend;
    final colors = _colors;
    if (lookIdx < 0) {
      return;
    }
    final lb = shader.blockAt(lookIdx);
    final lo =
        (lb.cachedWriterOffsets as _BarrierLookOffsets?) ??
        (lb.cachedWriterOffsets = _BarrierLookOffsets(lb));

    if (lo._footColor >= 0) {
      lb.writeVec4ValuesAt(
        lo._footColor,
        colors[0],
        colors[1],
        colors[2],
        colors[3],
      );
    }
    if (lo._topColor >= 0) {
      lb.writeVec4ValuesAt(
        lo._topColor,
        colors[4],
        colors[5],
        colors[6],
        colors[7],
      );
    }
    if (lo._shape >= 0) {
      lb.writeVec4ValuesAt(
        lo._shape,
        appear,
        heightFalloff,
        intensity,
        footGlow,
      );
    }
    if (lo._pattern >= 0) {
      lb.writeVec4ValuesAt(
        lo._pattern,
        pattern.index.toDouble(),
        patternScale,
        patternOffset,
        patternStrength,
      );
    }
    if (lo._patternExtra >= 0) {
      lb.writeVec4ValuesAt(
        lo._patternExtra,
        patternHeight,
        patternPeriod,
        patternSpeed < 0 ? -1 : 1,
        _wrap(time * patternTwinkleSpeed, 2 * math.pi),
      );
    }
    if (lo._glint >= 0) {
      lb.writeVec4ValuesAt(
        lo._glint,
        glintStrength,
        glintPower,
        blend == BlendState.alpha ? 0 : 1,
        appearSoftness,
      );
    }
    if (lo._impactShape >= 0) {
      lb.writeVec4ValuesAt(
        lo._impactShape,
        impactRingSpeed,
        impactRingWidth,
        impactDuration,
        impactFlashRadius,
      );
    }
    if (lo._extra >= 0) {
      lb.writeVec4ValuesAt(
        lo._extra,
        nearSideFade,
        farSideFade,
        sideFadeSoftness,
        count.toDouble(),
      );
    }
    if (lo._viewer >= 0) {
      _writeViewerTo(context, lb, lo._viewer);
    }
    for (var i = 0; i < BarrierMaterial.maxImpactSlots; i++) {
      final o = i * 8;
      if (lo._impactPositions >= 0) {
        lb.writeVec4ValuesAt(
          lo._impactPositions + i * 4,
          p[o],
          p[o + 1],
          p[o + 2],
          p[o + 3],
        );
      }
      if (lo._impactColors >= 0) {
        lb.writeVec4ValuesAt(
          lo._impactColors + i * 4,
          p[o + 4],
          p[o + 5],
          p[o + 6],
          p[o + 7],
        );
      }
    }

    // The fade between two heights.
    final remap = fadeStart != 0 || fadeEnd != 1;
    final flicker = _flicker();
    if (lo._profile >= 0) {
      lb.writeVec4ValuesAt(
        lo._profile,
        fadeStart,
        1 / math.max(fadeEnd - fadeStart, 1e-4),
        remap ? 1 : 0,
        flicker,
      );
    }
    final topEdgeOn = topEdgeStrength > 0 && topEdgeWidth > 0;
    final edge = colors[BarrierMaterial._topEdge * 4 + 3] * topEdgeStrength;
    if (lo._topEdge >= 0) {
      if (topEdgeOn) {
        lb.writeVec4ValuesAt(
          lo._topEdge,
          colors[BarrierMaterial._topEdge * 4] * edge,
          colors[BarrierMaterial._topEdge * 4 + 1] * edge,
          colors[BarrierMaterial._topEdge * 4 + 2] * edge,
          1 / topEdgeWidth,
        );
      } else {
        lb.writeVec4ValuesAt(lo._topEdge, 0, 0, 0, 0);
      }
    }
    if (lo._fill >= 0) {
      lb.writeVec4ValuesAt(
        lo._fill,
        colors[BarrierMaterial._fill * 4],
        colors[BarrierMaterial._fill * 4 + 1],
        colors[BarrierMaterial._fill * 4 + 2],
        (fillOpacity * colors[BarrierMaterial._fill * 4 + 3]).clamp(0.0, 1.0),
      );
    }

    final pulse = pulseValue;
    final wobbleShade = amplitude > 0 && count > 0 && wobbleShading != 0;
    final extras =
        topEdgeOn ||
        pulse > 0 ||
        noiseStrength > 0 ||
        flicker != 1 ||
        wobbleShade;
    if (lo._mode >= 0) {
      lb.writeVec4ValuesAt(
        lo._mode,
        fillFade.clamp(0.0, 1.0),
        preserveHue ? 1 : 0,
        extras ? 1 : 0,
        reactionScale,
      );
    }
    if (lo._patternStyle >= 0) {
      lb.writeVec4ValuesAt(
        lo._patternStyle,
        math.max(patternRows, 1).toDouble(),
        math.max(patternLineWidth, 0),
        patternTwinkle.clamp(0.0, 1.0),
        _wrap(time * patternRiseSpeed, 16),
      );
    }
    if (lo._patternColor >= 0) {
      lb.writeVec4ValuesAt(
        lo._patternColor,
        colors[BarrierMaterial._patternColor * 4],
        colors[BarrierMaterial._patternColor * 4 + 1],
        colors[BarrierMaterial._patternColor * 4 + 2],
        _hasPatternColor ? 1 : 0,
      );
    }
    if (lo._patternMore >= 0) {
      lb.writeVec4ValuesAt(
        lo._patternMore,
        patternRiseSpeed != 0 ? 1 : 0,
        proximityPatternBoost,
        wobbleShade ? wobbleShading : 0,
        0,
      );
    }

    // The noise: fitted to the loop like the pattern.
    var noiseAlong = math.max(noiseScale, 1e-3);
    var noisePeriod = 256.0;
    if (patternLoopLength > 0) {
      noisePeriod = math
          .max(1, (patternLoopLength * noiseAlong).round())
          .toDouble();
      noiseAlong = noisePeriod / patternLoopLength;
    }
    if (lo._noise >= 0) {
      lb.writeVec4ValuesAt(
        lo._noise,
        math.max(noiseStrength, 0),
        noiseAlong,
        math.max(noiseScale, 1e-3),
        _wrap(time * noiseSpeed * noiseScale, 256),
      );
    }
    if (lo._noiseExtra >= 0) {
      lb.writeVec4ValuesAt(lo._noiseExtra, noisePeriod, 0, 0, 0);
    }
    if (lo._rings >= 0) {
      lb.writeVec4ValuesAt(
        lo._rings,
        impactRingCount.clamp(1, BarrierMaterial.maxImpactRings).toDouble(),
        math.max(impactRingInterval, 0),
        impactRingStrength,
        math.max(impactRingReach, 0),
      );
    }
    if (lo._flash >= 0) {
      lb.writeVec4ValuesAt(
        lo._flash,
        impactFlashStrength,
        1 / math.max(impactFlashDuration, 1e-3),
        0,
        0,
      );
    }
    if (lo._pulse >= 0) {
      lb.writeVec4ValuesAt(
        lo._pulse,
        _pulseRgb[0] * pulse,
        _pulseRgb[1] * pulse,
        _pulseRgb[2] * pulse,
        pulse,
      );
    }

    // The near points, the active ones first.
    var near = 0;
    const c = BarrierMaterial._proximityColor * 4;
    for (var i = 0; i < BarrierMaterial.maxNearPoints; i++) {
      final o = i * 8;
      final strength = _nearPoints[o + 3];
      if (!(strength > 0)) {
        continue;
      }
      final useDefault = _nearPoints[o + 7] > 0.5;
      if (lo._nearPositions >= 0) {
        lb.writeVec4ValuesAt(
          lo._nearPositions + near * 4,
          _nearPoints[o],
          _nearPoints[o + 1],
          _nearPoints[o + 2],
          strength,
        );
      }
      if (lo._nearColors >= 0) {
        if (useDefault) {
          lb.writeVec4ValuesAt(
            lo._nearColors + near * 4,
            colors[c] * colors[c + 3],
            colors[c + 1] * colors[c + 3],
            colors[c + 2] * colors[c + 3],
            0,
          );
        } else {
          lb.writeVec4ValuesAt(
            lo._nearColors + near * 4,
            _nearPoints[o + 4],
            _nearPoints[o + 5],
            _nearPoints[o + 6],
            0,
          );
        }
      }
      near++;
    }
    for (var i = near; i < BarrierMaterial.maxNearPoints; i++) {
      if (lo._nearPositions >= 0) {
        lb.writeVec4ValuesAt(lo._nearPositions + i * 4, 0, 0, 0, 0);
      }
      if (lo._nearColors >= 0) {
        lb.writeVec4ValuesAt(lo._nearColors + i * 4, 0, 0, 0, 0);
      }
    }
    if (lo._proximity >= 0) {
      lb.writeVec4ValuesAt(
        lo._proximity,
        math.max(proximityRadius, 1e-4),
        proximityStrength,
        near.toDouble(),
        0,
      );
    }
  }

  /// Packs the active impacts into [_packedImpacts], oldest slot first, with
  /// their age, and clears the rest; returns how many are active.
  int _packImpacts() {
    final packed = _packedImpacts;
    var n = 0;
    final slots = _slots;
    for (var i = 0; i < slots; i++) {
      if (!isImpactActive(i)) {
        continue;
      }
      final o = i * 8;
      final to = n * 8;
      packed
        ..[to] = _impacts[o]
        ..[to + 1] = _impacts[o + 1]
        ..[to + 2] = _impacts[o + 2]
        ..[to + 3] = time - _impacts[o + 3]
        ..[to + 4] = _impacts[o + 4]
        ..[to + 5] = _impacts[o + 5]
        ..[to + 6] = _impacts[o + 6]
        ..[to + 7] = _impacts[o + 7];
      n++;
    }
    for (var i = n; i < BarrierMaterial.maxImpactSlots; i++) {
      final to = i * 8;
      packed
        ..fillRange(to, to + 8, 0)
        ..[to + 3] = -1;
    }
    return n;
  }

  /// The multiplier of the wall's light the flicker sets at the current
  /// [time]: `1` without flicker.
  double _flicker() {
    if (!(flickerStrength > 0)) {
      return 1;
    }
    final x = _wrap(time * flickerSpeed, 4096);
    final i = x.floorToDouble();
    final f = x - i;
    final u = f * f * (3 - 2 * f);
    final a = _hash(i);
    final b = _hash(i + 1);
    final n = a + (b - a) * u;
    return 1 - flickerStrength.clamp(0.0, 1.0) * n;
  }

  /// Writes where the viewer is: the camera's center of projection
  /// (`w = 1`), or the direction towards the viewer for a parallel
  /// projection (`w = 0`).
  ///
  /// Both come from the inverse of the view-projection matrix, the point or
  /// direction that the clip-space depth axis `(0, 0, 1, 0)` comes from, so
  /// they hold for oblique and mirroring projections too, such as the affine
  /// ones of `Scene3DComponent`.
  void _writeViewerTo(
    RenderContext3D context,
    UniformBlock block,
    int offset,
  ) => context.writeViewerTo(block, offset);
}

double _hash(double n) {
  final s = math.sin(n * 12.9898 + 78.233) * 43758.5453;
  return s - s.floorToDouble();
}

/// [value] wrapped to `[0, period)`, or `0` when it is not finite.
double _wrap(double value, double period) {
  final wrapped = value % period;
  return wrapped.isFinite ? wrapped : 0;
}

class _BarrierShapeOffsets(final UniformBlock _b) {
  late final int _params = _b.resolveOffset('params');
  late final int _wobble = _b.resolveOffset('wobble');
  late final int _wobbleExtra = _b.resolveOffset('wobbleExtra');
  late final int _impactPositions = _b.resolveOffset('impactPositions');
  late final int _impactStrengths = _b.resolveOffset('impactStrengths');
}

class _BarrierLookOffsets(final UniformBlock _b) {
  late final int _footColor = _b.resolveOffset('footColor');
  late final int _topColor = _b.resolveOffset('topColor');
  late final int _shape = _b.resolveOffset('shape');
  late final int _pattern = _b.resolveOffset('pattern');
  late final int _patternExtra = _b.resolveOffset('patternExtra');
  late final int _glint = _b.resolveOffset('glint');
  late final int _impactShape = _b.resolveOffset('impactShape');
  late final int _extra = _b.resolveOffset('extra');
  late final int _viewer = _b.resolveOffset('viewer');
  late final int _impactPositions = _b.resolveOffset('impactPositions');
  late final int _impactColors = _b.resolveOffset('impactColors');
  late final int _profile = _b.resolveOffset('profile');
  late final int _topEdge = _b.resolveOffset('topEdge');
  late final int _fill = _b.resolveOffset('fill');
  late final int _mode = _b.resolveOffset('mode');
  late final int _patternStyle = _b.resolveOffset('patternStyle');
  late final int _patternColor = _b.resolveOffset('patternColor');
  late final int _patternMore = _b.resolveOffset('patternMore');
  late final int _noise = _b.resolveOffset('noise');
  late final int _noiseExtra = _b.resolveOffset('noiseExtra');
  late final int _rings = _b.resolveOffset('rings');
  late final int _flash = _b.resolveOffset('flash');
  late final int _pulse = _b.resolveOffset('pulse');
  late final int _nearPositions = _b.resolveOffset('nearPositions');
  late final int _nearColors = _b.resolveOffset('nearColors');
  late final int _proximity = _b.resolveOffset('proximity');
}
