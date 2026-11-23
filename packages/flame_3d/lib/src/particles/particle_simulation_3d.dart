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
}
