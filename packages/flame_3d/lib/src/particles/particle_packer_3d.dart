part of 'particle_system_3d.dart';

class _ParticleDrawCache() {
  int sortSerial = 0;
  int cachedSortVersion = -1;
  int cachedSortWorldVer = -1;
  bool cachedSortLocal = false;
  final Float32List cachedSortView = Float32List(16);

  int cachedPackVersion = -1;
  int cachedPackSortSerial = -1;
  int cachedPackWorldVer = -1;
  bool cachedPackLocal = false;
  bool cachedPackSorted = false;
  Material? cachedPackMaterial;
  ParticleFlipbook3D? cachedPackFlipbook;
  int cachedPackFrames = -1;
  bool cachedPackBlending = false;
  ParticleCurve? cachedSizeCurve;
  ColorRamp? cachedColorRamp;
  ParticleCurve? cachedOpacityCurve;
  ParticleCurve? cachedRotationCurve;
  double cachedVelStretch = -1;
  double cachedMaxStretch = -1;
  double cachedInstD0 = 0;
  double cachedInstD1 = 0;
  double cachedInstD2 = 0;
  double cachedInstD3 = 0;
}

extension _ParticleSystemPacker on ParticleSystem3D {
  void _syncSortAndPack(
    Matrix4 view,
    bool sorted,
    bool isLocal,
    int worldVer,
    ParticleMaterial? material,
  ) {
    final cache = _drawCache;
    if (sorted) {
      final viewStorage = view.storage;
      if (cache.cachedSortVersion != _stateVersion ||
          cache.cachedSortLocal != isLocal ||
          cache.cachedSortWorldVer != worldVer ||
          !sameMatrix16Approx(viewStorage, cache.cachedSortView)) {
        _sortBackToFront(view);
        cache
          ..cachedSortVersion = _stateVersion
          ..cachedSortLocal = isLocal
          ..cachedSortWorldVer = worldVer;
        for (var i = 0; i < 16; i++) {
          cache.cachedSortView[i] = viewStorage[i];
        }
        cache.sortSerial++;
      }
    }

    final frames = material?.frameCount ?? 0;
    final blending = material?.frameBlending ?? false;
    final instData = instanceData.storage;
    final d0 = instData[0];
    final d1 = instData[1];
    final d2 = instData[2];
    final d3 = instData[3];
    final packStale =
        cache.cachedPackVersion != _stateVersion ||
        cache.cachedPackSorted != sorted ||
        (sorted && cache.cachedPackSortSerial != cache.sortSerial) ||
        cache.cachedPackLocal != isLocal ||
        cache.cachedPackWorldVer != worldVer ||
        !identical(cache.cachedPackMaterial, material) ||
        !identical(cache.cachedPackFlipbook, flipbook) ||
        cache.cachedPackFrames != frames ||
        cache.cachedPackBlending != blending ||
        !identical(cache.cachedSizeCurve, sizeOverLife) ||
        !identical(cache.cachedColorRamp, colorOverLife) ||
        !identical(cache.cachedOpacityCurve, opacityOverLife) ||
        !identical(cache.cachedRotationCurve, rotationOverLife) ||
        cache.cachedVelStretch != velocityStretch ||
        cache.cachedMaxStretch != maxStretch ||
        cache.cachedInstD0 != d0 ||
        cache.cachedInstD1 != d1 ||
        cache.cachedInstD2 != d2 ||
        cache.cachedInstD3 != d3;

    if (packStale) {
      if (material != null) {
        _writeBillboards(sorted, material);
      } else {
        _writeMeshes(sorted);
      }
      cache
        ..cachedPackVersion = _stateVersion
        ..cachedPackSorted = sorted
        ..cachedPackSortSerial = cache.sortSerial
        ..cachedPackLocal = isLocal
        ..cachedPackWorldVer = worldVer
        ..cachedPackMaterial = material
        ..cachedPackFlipbook = flipbook
        ..cachedPackFrames = frames
        ..cachedPackBlending = blending
        ..cachedSizeCurve = sizeOverLife
        ..cachedColorRamp = colorOverLife
        ..cachedOpacityCurve = opacityOverLife
        ..cachedRotationCurve = rotationOverLife
        ..cachedVelStretch = velocityStretch
        ..cachedMaxStretch = maxStretch
        ..cachedInstD0 = d0
        ..cachedInstD1 = d1
        ..cachedInstD2 = d2
        ..cachedInstD3 = d3;
    }
  }

  /// Sorts the particles back to front as seen through [view], into
  /// [_order].
  void _sortBackToFront(Matrix4 view) {
    final b = particles;
    final n = b.length;
    final v = view.storage;
    // The view-space z of a world point is dot(row 2, (x, y, z, 1)); the
    // camera looks along -z, so -z grows away from it.
    var rx = v[2];
    var ry = v[6];
    var rz = v[10];
    var rw = v[14];
    if (space == ParticleSpace.local) {
      // Fold the world transform into the row.
      final m = worldTransformMatrix.storage;
      final lx = rx * m[0] + ry * m[1] + rz * m[2];
      final ly = rx * m[4] + ry * m[5] + rz * m[6];
      final lz = rx * m[8] + ry * m[9] + rz * m[10];
      rw += rx * m[12] + ry * m[13] + rz * m[14];
      rx = lx;
      ry = ly;
      rz = lz;
    }
    final depths = _depths;
    var minDepth = double.infinity;
    var maxDepth = double.negativeInfinity;
    for (var i = 0; i < n; i++) {
      final depth = -(rx * b.posX[i] + ry * b.posY[i] + rz * b.posZ[i] + rw);
      depths[i] = depth;
      if (depth < minDepth) {
        minDepth = depth;
      }
      if (depth > maxDepth) {
        maxDepth = depth;
      }
    }
    final range = maxDepth - minDepth;
    final scale = range > 0 ? 65535 / range : 0.0;
    final keys = _keys;
    for (var i = 0; i < n; i++) {
      // The farthest particle gets the smallest key: it is drawn first.
      keys[i] = 65535 - ((depths[i] - minDepth) * scale).toInt();
    }
    // A stable radix sort on the two bytes of the keys.
    final counts = _counts;
    final scratch = _orderScratch;
    final order = _order;
    counts.fillRange(0, 256, 0);
    for (var i = 0; i < n; i++) {
      counts[keys[i] & 0xFF]++;
    }
    var sum = 0;
    for (var c = 0; c < 256; c++) {
      final value = counts[c];
      counts[c] = sum;
      sum += value;
    }
    for (var i = 0; i < n; i++) {
      scratch[counts[keys[i] & 0xFF]++] = i;
    }
    counts.fillRange(0, 256, 0);
    for (var i = 0; i < n; i++) {
      counts[keys[i] >> 8]++;
    }
    sum = 0;
    for (var c = 0; c < 256; c++) {
      final value = counts[c];
      counts[c] = sum;
      sum += value;
    }
    for (var k = 0; k < n; k++) {
      final i = scratch[k];
      order[counts[keys[i] >> 8]++] = i;
    }
  }

  /// The flipbook frame of the particle at [index], at life progress [t].
  double _frameOf(int index, double t, int frames, bool blending) {
    final flipbook = this.flipbook;
    if (flipbook == null || frames <= 1) {
      return 0;
    }
    final b = particles;
    final start = flipbook.randomStart
        ? (b.seed[index] * frames).floorToDouble()
        : 0.0;
    switch (flipbook.mode) {
      case ParticleFrameMode.overLife:
        final cycles = flipbook.cycles;
        if (cycles == 1 && !flipbook.randomStart) {
          // One pass, ending on the last frame.
          return blending
              ? t * (frames - 1)
              : math.min(t * frames, frames - 1.0).floorToDouble();
        }
        final frame = t * cycles * frames + start;
        return blending ? frame % frames : (frame % frames).floorToDouble();
      case ParticleFrameMode.fps:
        final frame = b.age[index] * flipbook.fps + start;
        return blending ? frame % frames : (frame % frames).floorToDouble();
      case ParticleFrameMode.random:
        return (b.seed[index] * frames).floorToDouble();
    }
  }

  void _writeBillboards(bool sorted, ParticleMaterial material) {
    final b = particles;
    final n = b.length;
    final out = _instances;
    final order = _order;
    final local = space == ParticleSpace.local;
    final m = worldTransformMatrix.storage;
    final scale = ParticleSystem3D._uniformScale(m);
    final sizeCurve = sizeOverLife;
    final colorRamp = colorOverLife;
    final opacityCurve = opacityOverLife;
    final rotationCurve = rotationOverLife;
    final stretchFactor = velocityStretch;
    final stretchMax = math.max(1.0, maxStretch);
    final frames = material.frameCount;
    final blending = material.frameBlending;
    final hasFlipbook = flipbook != null && frames > 1;
    final data = instanceData.storage;
    final d0 = data[0];
    final d1 = data[1];
    final d2 = data[2];
    final d3 = data[3];

    for (var k = 0; k < n; k++) {
      final i = sorted ? order[k] : k;
      var t = b.age[i] * b.invLifespan[i];
      if (t > 1) {
        t = 1;
      }
      var px = b.posX[i];
      var py = b.posY[i];
      var pz = b.posZ[i];
      var vx = b.velX[i];
      var vy = b.velY[i];
      var vz = b.velZ[i];
      if (local) {
        final x = px;
        final y = py;
        final z = pz;
        px = m[0] * x + m[4] * y + m[8] * z + m[12];
        py = m[1] * x + m[5] * y + m[9] * z + m[13];
        pz = m[2] * x + m[6] * y + m[10] * z + m[14];
        final ux = vx;
        final uy = vy;
        final uz = vz;
        vx = m[0] * ux + m[4] * uy + m[8] * uz;
        vy = m[1] * ux + m[5] * uy + m[9] * uz;
        vz = m[2] * ux + m[6] * uy + m[10] * uz;
      }
      final size = (sizeCurve == null ? 1.0 : sizeCurve.transform(t)) * scale;
      var stretch = 1.0;
      if (stretchFactor > 0) {
        final speed = math.sqrt(vx * vx + vy * vy + vz * vz);
        stretch = 1 + speed * stretchFactor;
        if (stretch > stretchMax) {
          stretch = stretchMax;
        }
      }
      final rotation =
          b.rotation[i] +
          (rotationCurve == null ? 0 : rotationCurve.transform(t));
      final frame = hasFlipbook ? _frameOf(i, t, frames, blending) : 0.0;

      final o = k * VertexLayout.instanceStrideInFloats;
      out[o] = px;
      out[o + 1] = py;
      out[o + 2] = pz;
      out[o + 3] = b.width[i] * size;
      out[o + 4] = vx;
      out[o + 5] = vy;
      out[o + 6] = vz;
      out[o + 7] = b.height[i] * size;
      out[o + 8] = rotation;
      out[o + 9] = frame;
      out[o + 10] = b.seed[i];
      out[o + 11] = stretch;
      out[o + 12] = t;
      out[o + 13] = 0;
      out[o + 14] = 0;
      out[o + 15] = 1;
      _writeParticleRgba(out, o, b.color[i], colorRamp, opacityCurve, t);
      out[o + 20] = d0;
      out[o + 21] = d1;
      out[o + 22] = d2;
      out[o + 23] = d3;
    }
  }

  void _writeMeshes(bool sorted) {
    final b = particles;
    final n = b.length;
    final out = _instances;
    final order = _order;
    final local = space == ParticleSpace.local;
    final m = worldTransformMatrix.storage;
    // The linear part of the world transform: the base orientation and scale
    // of every particle.
    final b00 = m[0];
    final b10 = m[1];
    final b20 = m[2];
    final b01 = m[4];
    final b11 = m[5];
    final b21 = m[6];
    final b02 = m[8];
    final b12 = m[9];
    final b22 = m[10];
    final sizeCurve = sizeOverLife;
    final colorRamp = colorOverLife;
    final opacityCurve = opacityOverLife;
    final rotationCurve = rotationOverLife;
    final data = instanceData.storage;
    final d0 = data[0];
    final d1 = data[1];
    final d2 = data[2];
    final d3 = data[3];

    for (var k = 0; k < n; k++) {
      final i = sorted ? order[k] : k;
      var t = b.age[i] * b.invLifespan[i];
      if (t > 1) {
        t = 1;
      }
      var px = b.posX[i];
      var py = b.posY[i];
      var pz = b.posZ[i];
      if (local) {
        final x = px;
        final y = py;
        final z = pz;
        px = m[0] * x + m[4] * y + m[8] * z + m[12];
        py = m[1] * x + m[5] * y + m[9] * z + m[13];
        pz = m[2] * x + m[6] * y + m[10] * z + m[14];
      }
      final size =
          b.width[i] * (sizeCurve == null ? 1.0 : sizeCurve.transform(t));
      final angle =
          b.rotation[i] +
          (rotationCurve == null ? 0 : rotationCurve.transform(t));
      final x = b.axisX[i];
      final y = b.axisY[i];
      final z = b.axisZ[i];
      final c = math.cos(angle);
      final s = math.sin(angle);
      final cc = 1 - c;
      // The rotation about the axis (Rodrigues), column by column.
      final r00 = c + x * x * cc;
      final r10 = y * x * cc + z * s;
      final r20 = z * x * cc - y * s;
      final r01 = x * y * cc - z * s;
      final r11 = c + y * y * cc;
      final r21 = z * y * cc + x * s;
      final r02 = x * z * cc + y * s;
      final r12 = y * z * cc - x * s;
      final r22 = c + z * z * cc;
      // World space: the particle's rotation applies to the system's
      // orientation (R * B); local space: the system's transform applies to
      // the particle (B * R).
      final double l00;
      final double l10;
      final double l20;
      final double l01;
      final double l11;
      final double l21;
      final double l02;
      final double l12;
      final double l22;
      if (local) {
        l00 = b00 * r00 + b01 * r10 + b02 * r20;
        l10 = b10 * r00 + b11 * r10 + b12 * r20;
        l20 = b20 * r00 + b21 * r10 + b22 * r20;
        l01 = b00 * r01 + b01 * r11 + b02 * r21;
        l11 = b10 * r01 + b11 * r11 + b12 * r21;
        l21 = b20 * r01 + b21 * r11 + b22 * r21;
        l02 = b00 * r02 + b01 * r12 + b02 * r22;
        l12 = b10 * r02 + b11 * r12 + b12 * r22;
        l22 = b20 * r02 + b21 * r12 + b22 * r22;
      } else {
        l00 = r00 * b00 + r01 * b10 + r02 * b20;
        l10 = r10 * b00 + r11 * b10 + r12 * b20;
        l20 = r20 * b00 + r21 * b10 + r22 * b20;
        l01 = r00 * b01 + r01 * b11 + r02 * b21;
        l11 = r10 * b01 + r11 * b11 + r12 * b21;
        l21 = r20 * b01 + r21 * b11 + r22 * b21;
        l02 = r00 * b02 + r01 * b12 + r02 * b22;
        l12 = r10 * b02 + r11 * b12 + r12 * b22;
        l22 = r20 * b02 + r21 * b12 + r22 * b22;
      }

      final o = k * VertexLayout.instanceStrideInFloats;
      out[o] = l00 * size;
      out[o + 1] = l10 * size;
      out[o + 2] = l20 * size;
      out[o + 3] = 0;
      out[o + 4] = l01 * size;
      out[o + 5] = l11 * size;
      out[o + 6] = l21 * size;
      out[o + 7] = 0;
      out[o + 8] = l02 * size;
      out[o + 9] = l12 * size;
      out[o + 10] = l22 * size;
      out[o + 11] = 0;
      out[o + 12] = px;
      out[o + 13] = py;
      out[o + 14] = pz;
      out[o + 15] = 1;
      _writeParticleRgba(out, o, b.color[i], colorRamp, opacityCurve, t);
      out[o + 20] = d0;
      out[o + 21] = d1;
      out[o + 22] = d2;
      out[o + 23] = d3;
    }
  }
}

void _writeParticleRgba(
  Float32List out,
  int o,
  int argb,
  ColorRamp? colorRamp,
  ParticleCurve? opacityCurve,
  double t,
) {
  const toUnit = 1 / 255;
  var r = ((argb >> 16) & 0xFF) * toUnit;
  var g = ((argb >> 8) & 0xFF) * toUnit;
  var bl = (argb & 0xFF) * toUnit;
  var a = ((argb >> 24) & 0xFF) * toUnit;
  if (colorRamp != null) {
    final ramp = colorRamp.valueAt(t);
    r *= ((ramp >> 16) & 0xFF) * toUnit;
    g *= ((ramp >> 8) & 0xFF) * toUnit;
    bl *= (ramp & 0xFF) * toUnit;
    a *= ((ramp >> 24) & 0xFF) * toUnit;
  }
  if (opacityCurve != null) {
    final opacity = opacityCurve.transform(t);
    a *= opacity < 0 ? 0 : (opacity > 1 ? 1 : opacity);
  }
  out[o + 16] = r;
  out[o + 17] = g;
  out[o + 18] = bl;
  out[o + 19] = a;
}
