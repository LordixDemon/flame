part of 'particle_system_3d.dart';

extension _ParticleSystemSimulation on ParticleSystem3D {
  void _simulate(double h) {
    final b = particles;
    _hitCount = 0;
    final attractorCount = attractors.length;
    for (var a = 0; a < attractorCount; a++) {
      _arrivals[a] = 0;
    }
    _hasRawBounds = false;
    if (b.length == 0) {
      _maxExtent = 0;
      return;
    }

    final gx = gravity.x;
    final gy = gravity.y;
    final gz = gravity.z;
    final wx = wind.x;
    final wy = wind.y;
    final wz = wind.z;
    final damping = drag > 0 ? 1 / (1 + drag * h) : 1.0;

    final turbulence = this.turbulence;
    final hasTurbulence = turbulence != null && turbulence.strength != 0;
    final turbulenceFrequency = turbulence?.frequency ?? 1;
    final turbulenceStrength = turbulence?.strength ?? 0;
    final turbulenceTime = _time * (turbulence?.speed ?? 0);
    final curl = _curl;

    final ground = this.ground;
    final hasGround = ground != null;
    final normal = ground?.normal;
    final nx = normal?.x ?? 0;
    final ny = normal?.y ?? 1;
    final nz = normal?.z ?? 0;
    final groundHeight = ground?.height ?? 0;
    final restitution = ground?.restitution ?? 0;
    final friction = ground?.friction ?? 1;
    final slide = 1 / (1 + (ground?.slideDrag ?? 0) * h);
    final restSpeed = ground?.restSpeed ?? 0;
    final sizeOffset = ground?.sizeOffset ?? 0;
    final killOnHit = ground?.killOnHit ?? false;
    final settle = ground?.settleRotation ?? false;
    final settleFactor = 1 - math.exp(-12 * h);
    final sizeCurve = sizeOverLife;
    final spinCurve = spinOverLife;
    final hits = _hits;
    final reportHits = onGroundHit != null && !_muted;

    var i = 0;
    while (i < b.length) {
      final invLifespan = b.invLifespan[i];
      final age = b.age[i] + h;
      if (age * invLifespan >= 1) {
        b.removeAt(i);
        continue;
      }
      b.age[i] = age;
      final t = age * invLifespan;

      final px0 = b.posX[i];
      final py0 = b.posY[i];
      final pz0 = b.posZ[i];
      final vx0 = b.velX[i];
      final vy0 = b.velY[i];
      final vz0 = b.velZ[i];

      final gs = b.gravityScale[i];
      var ax = gx * gs + wx;
      var ay = gy * gs + wy;
      var az = gz * gs + wz;
      if (hasTurbulence) {
        _curlNoise.sample(
          px0,
          py0,
          pz0,
          turbulenceTime,
          turbulenceFrequency,
          turbulenceStrength,
          curl,
        );
        ax += curl.x;
        ay += curl.y;
        az += curl.z;
      }
      if (attractorCount > 0) {
        var flags = b.attractorFlags[i];
        var consumed = false;
        for (var a = 0; a < attractorCount; a++) {
          final attractor = attractors[a];
          final target = attractor.target;
          final dx = target.x - px0;
          final dy = target.y - py0;
          final dz = target.z - pz0;
          final d2 = dx * dx + dy * dy + dz * dz;
          final radius = attractor.arrivalRadius;
          final bit = 1 << a;
          if (d2 <= radius * radius) {
            if (flags & bit == 0) {
              flags |= bit;
              _arrivals[a]++;
              if (attractor.consumeOnArrival) {
                consumed = true;
                break;
              }
            }
          } else {
            flags &= ~bit;
            if (d2 > 0) {
              final k = attractor.strength / math.sqrt(d2);
              ax += dx * k;
              ay += dy * k;
              az += dz * k;
            }
          }
        }
        if (consumed) {
          b.removeAt(i);
          continue;
        }
        b.attractorFlags[i] = flags;
      }

      var vx = (vx0 + ax * h) * damping;
      var vy = (vy0 + ay * h) * damping;
      var vz = (vz0 + az * h) * damping;
      var px = px0 + vx * h;
      var py = py0 + vy * h;
      var pz = pz0 + vz * h;
      var spin = b.spin[i];
      var resting = false;

      if (hasGround) {
        final level =
            groundHeight +
            (sizeOffset == 0
                ? 0
                : sizeOffset *
                      b.width[i] *
                      (sizeCurve == null ? 1 : sizeCurve.transform(t)));
        final below = px * nx + py * ny + pz * nz - level;
        if (below < 0) {
          // The speed into the ground at the moment of contact, from the
          // state at the start of the step: one step of gravity does not
          // count as an impact for a particle already lying on the ground.
          final above = px0 * nx + py0 * ny + pz0 * nz - level;
          final normalSpeed0 = vx0 * nx + vy0 * ny + vz0 * nz;
          double impact;
          if (above >= 0) {
            final an = ax * nx + ay * ny + az * nz;
            final square = normalSpeed0 * normalSpeed0 - 2 * an * above;
            impact = square > 0 ? math.sqrt(square) : 0;
          } else {
            impact = -(vx * nx + vy * ny + vz * nz);
            if (impact < 0) {
              impact = 0;
            }
          }
          px -= nx * below;
          py -= ny * below;
          pz -= nz * below;
          final normalSpeed = vx * nx + vy * ny + vz * nz;
          var tx = vx - nx * normalSpeed;
          var ty = vy - ny * normalSpeed;
          var tz = vz - nz * normalSpeed;
          if (killOnHit || impact > restSpeed) {
            if (reportHits) {
              final o = _hitCount * 4;
              hits[o] = px;
              hits[o + 1] = py;
              hits[o + 2] = pz;
              hits[o + 3] = impact;
              _hitCount++;
            }
            if (killOnHit) {
              b.removeAt(i);
              continue;
            }
            final bounce = impact * restitution;
            tx *= friction;
            ty *= friction;
            tz *= friction;
            vx = tx + nx * bounce;
            vy = ty + ny * bounce;
            vz = tz + nz * bounce;
          } else {
            vx = tx * slide;
            vy = ty * slide;
            vz = tz * slide;
            spin *= slide;
            resting = true;
          }
        }
      }

      var rotation = b.rotation[i];
      if (resting && settle) {
        const turn = 2 * math.pi;
        final target = (rotation / turn).roundToDouble() * turn;
        rotation += (target - rotation) * settleFactor;
        spin = 0;
      } else if (spin != 0) {
        rotation += spin * (spinCurve == null ? 1 : spinCurve.transform(t)) * h;
      }

      b.posX[i] = px;
      b.posY[i] = py;
      b.posZ[i] = pz;
      b.velX[i] = vx;
      b.velY[i] = vy;
      b.velZ[i] = vz;
      b.rotation[i] = rotation;
      b.spin[i] = spin;
      _includeInBounds(px, py, pz);
      i++;
    }
    if (b.length == 0) {
      _maxExtent = 0;
    }
  }

  void _dispatchEvents() {
    final hitCount = _hitCount;
    _hitCount = 0;
    final onGroundHit = this.onGroundHit;
    if (onGroundHit != null && hitCount > 0 && !_muted) {
      final hits = _hits;
      for (var i = 0; i < hitCount; i++) {
        final o = i * 4;
        _hitPosition.setValues(hits[o], hits[o + 1], hits[o + 2]);
        onGroundHit(_hitPosition, hits[o + 3]);
      }
    }
    for (var a = 0; a < attractors.length; a++) {
      final count = _arrivals[a];
      _arrivals[a] = 0;
      if (count > 0 && !_muted) {
        attractors[a].onArrived?.call(count);
      }
    }
  }

  /// Sets [_bounds] from the particle centers and sizes, and tells the
  /// component tree that the bounds changed.
  void _publishBounds() {
    if (!_hasRawBounds || particles.length == 0) {
      if (!_publishedEmpty) {
        _publishedEmpty = true;
        markAabbDirty();
      }
      return;
    }
    _publishedEmpty = false;
    final scale = space == ParticleSpace.world
        ? ParticleSystem3D._uniformScale(worldTransformMatrix.storage)
        : 1.0;
    final double pad;
    if (mesh != null) {
      pad = _radiusOfMesh * _maxExtent * _sizeCurveMax * scale;
    } else {
      final stretch = velocityStretch > 0 ? math.max(1, maxStretch) : 1;
      // Half the diagonal of the largest quad, stretched.
      pad = 0.71 * _maxExtent * _sizeCurveMax * stretch * scale;
    }
    _bounds.min.setValues(_minX - pad, _minY - pad, _minZ - pad);
    _bounds.max.setValues(_maxX + pad, _maxY + pad, _maxZ + pad);
    markAabbDirty();
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
