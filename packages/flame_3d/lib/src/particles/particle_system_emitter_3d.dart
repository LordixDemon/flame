part of 'particle_system_3d.dart';

extension _ParticleSystemEmitter on ParticleSystem3D {
  /// Reports that what the system draws changed: its world's
  /// `World3D.sceneVersion` increases (and its `World3D.castersVersion` for
  /// mesh particles that cast shadows), so that a retained
  /// `Scene3DComponent` renders it again, and a game that only renders
  /// changed frames wakes up.
  ///
  /// [update] calls it once per frame while there are live particles, and
  /// the calls that change the particles outside it ([burst], [spawn],
  /// [clear], [prewarm]) once each.
  void _markDrawChanged() {
    _stateVersion++;
    if (worldOrNull != null) {
      markDrawDirty(shadows: castsShadows && mesh != null);
    } else {
      Game.notifyVisualMutation();
    }
  }

  /// Reads the system's world origin, and its velocity over the last [frame]
  /// seconds.
  void _syncOrigin(double frame) {
    final m = worldTransformMatrix.storage;
    _origin.setValues(m[12], m[13], m[14]);
    if (!_hasOrigin) {
      _lastOrigin.setFrom(_origin);
      _hasOrigin = true;
    }
    if (frame > 0) {
      _originVelocity
        ..setFrom(_origin)
        ..sub(_lastOrigin)
        ..scale(1 / frame);
    } else {
      _originVelocity.setZero();
    }
  }

  /// Simulates one step of [h] seconds, then spawns the particles of the
  /// emitters for that step, the system's origin having travelled
  /// [distance].
  void _advance(double h, double distance) {
    _simulate(h);
    if (emitting) {
      for (var i = 0; i < emitters.length; i++) {
        _emit(emitters[i], h, distance);
      }
    }
    _time += h;
    _dispatchEvents();
  }

  _EmitterState _stateFor(ParticleEmitter3D emitter) {
    final state = _states[emitter];
    if (state != null) {
      return state;
    }
    if (_states.length > emitters.length) {
      _states.removeWhere((key, _) => !emitters.contains(key));
    }
    return _states[emitter] = _EmitterState(emitter.bursts.length);
  }

  void _emit(ParticleEmitter3D emitter, double h, double distance) {
    final state = _stateFor(emitter);
    if (state.completed) {
      return;
    }
    final end = emitter.emissionEndTime;
    final previous = state.clock;
    state.clock += h;
    final density = this.density;
    if (density > 0 && previous < end) {
      final active = math.min(state.clock, end) - previous;
      if (emitter.rate > 0 && active > 0) {
        state.debt += emitter.rate * density * active;
        final count = state.debt.floor();
        state.debt -= count;
        _spawnSpread(emitter, count, h);
      }
      if (emitter.ratePerDistance > 0 && distance > 0) {
        state.distanceDebt += emitter.ratePerDistance * density * distance;
        final count = state.distanceDebt.floor();
        state.distanceDebt -= count;
        _spawnSpread(emitter, count, h);
      }
    }
    final bursts = emitter.bursts;
    for (var i = 0; i < bursts.length; i++) {
      final burst = bursts[i];
      if (!state.fired[i] && state.clock >= burst.time) {
        state.fired[i] = true;
        if (density > 0) {
          final count = density == 1
              ? burst.count
              : math.max(1, (burst.count * density).round());
          final age = math.min(state.clock - burst.time, h);
          final f = _motionEnd - (_motionEnd - _motionStart) * (age / h);
          for (var k = 0; k < count; k++) {
            if (!_spawnAtMotion(emitter, f, age)) {
              break;
            }
          }
        }
      }
    }
    if (state.clock >= end) {
      if (emitter.loop) {
        state.clock %= end;
        state.fired.fillRange(0, state.fired.length, false);
      } else {
        state.completed = true;
      }
    }
  }

  /// Spawns [count] particles born at regular times over the last step of
  /// [h] seconds, along the way the system's origin travelled.
  void _spawnSpread(ParticleEmitter3D emitter, int count, double h) {
    for (var k = 0; k < count; k++) {
      final birth = (k + 0.5) / count;
      final f = _motionStart + (_motionEnd - _motionStart) * birth;
      if (!_spawnAtMotion(emitter, f, h * (1 - birth))) {
        break;
      }
    }
  }

  /// Spawns a particle at the system's origin as it was at [fraction] of the
  /// current frame's motion, aged [age] seconds.
  bool _spawnAtMotion(ParticleEmitter3D emitter, double fraction, double age) {
    if (space == ParticleSpace.local) {
      return _spawn(emitter, 0, 0, 0, age, null);
    }
    final a = _lastOrigin;
    final b = _origin;
    return _spawn(
      emitter,
      a.x + (b.x - a.x) * fraction,
      a.y + (b.y - a.y) * fraction,
      a.z + (b.z - a.z) * fraction,
      age,
      null,
    );
  }

  /// A slot for a new particle, or `-1` when the system is full and drops
  /// particles.
  int _slot() {
    final index = particles.spawn();
    if (index >= 0) {
      return index;
    }
    if (overflow == ParticleOverflow.drop) {
      return -1;
    }
    final slot = _recycleCursor;
    _recycleCursor = (_recycleCursor + 1) % capacity;
    return slot;
  }

  /// Spawns a particle of [emitter] around ([x], [y], [z]) in the simulation
  /// space, aged [age] seconds, of [color] when given.
  bool _spawn(
    ParticleEmitter3D emitter,
    double x,
    double y,
    double z,
    double age,
    Color? color,
  ) {
    final index = _slot();
    if (index < 0) {
      return false;
    }
    final random = this.random;
    final position = _position;
    final direction = _direction;
    emitter.shape.sample(random, position, direction);
    position.add(emitter.offset);
    if (space == ParticleSpace.world) {
      // Oriented, scaled and placed by the system's world transform.
      final m = worldTransformMatrix.storage;
      final px = position.x;
      final py = position.y;
      final pz = position.z;
      position.setValues(
        x + m[0] * px + m[4] * py + m[8] * pz,
        y + m[1] * px + m[5] * py + m[9] * pz,
        z + m[2] * px + m[6] * py + m[10] * pz,
      );
      final dx = direction.x;
      final dy = direction.y;
      final dz = direction.z;
      direction.setValues(
        m[0] * dx + m[4] * dy + m[8] * dz,
        m[1] * dx + m[5] * dy + m[9] * dz,
        m[2] * dx + m[6] * dy + m[10] * dz,
      );
      final length = direction.length;
      if (length > 0) {
        direction.scale(1 / length);
      }
    } else {
      position.setValues(position.x + x, position.y + y, position.z + z);
    }
    if (emitter.spread > 0) {
      EmitterShape3D.randomDirectionInCone(
        random,
        direction,
        emitter.spread,
        direction,
      );
    }
    final speed = emitter.speed.sample(random);
    final inherit = emitter.inheritVelocity;
    final velocity = emitter.velocity;
    var vx = direction.x * speed + velocity.x;
    var vy = direction.y * speed + velocity.y;
    var vz = direction.z * speed + velocity.z;
    if (inherit != 0 && space == ParticleSpace.world) {
      vx += _originVelocity.x * inherit;
      vy += _originVelocity.y * inherit;
      vz += _originVelocity.z * inherit;
    }

    final b = particles;
    b.posX[index] = position.x + vx * age;
    b.posY[index] = position.y + vy * age;
    b.posZ[index] = position.z + vz * age;
    b.velX[index] = vx;
    b.velY[index] = vy;
    b.velZ[index] = vz;
    final lifespan = math.max(emitter.lifespan.sample(random), 1e-4);
    b.invLifespan[index] = 1 / lifespan;
    b.age[index] = math.min(age, lifespan * 0.999);
    final width = emitter.size.sample(random);
    b.width[index] = width;
    b.height[index] = width * emitter.aspect.sample(random);
    b.rotation[index] = emitter.rotation.sample(random);
    b.spin[index] = emitter.spin.sample(random);
    b.gravityScale[index] = emitter.gravityScale.sample(random);
    final colors = emitter.colors;
    b.color[index] =
        (color ??
                (colors.length == 1
                    ? colors[0]
                    : colors[random.nextInt(colors.length)]))
            .toARGB32();
    b.seed[index] = random.nextDouble();
    b.attractorFlags[index] = 0;
    _spinAxisInto(index);
    _spawned(index);
    return true;
  }

  /// Sets the spin axis of the particle at [index]: the system's
  /// [spinAxis], or a random one for mesh particles.
  void _spinAxisInto(int index) {
    final b = particles;
    final fixed = spinAxis;
    if (fixed != null) {
      b.axisX[index] = fixed.x;
      b.axisY[index] = fixed.y;
      b.axisZ[index] = fixed.z;
    } else if (mesh != null) {
      EmitterShape3D.randomDirection(random, _axis);
      b.axisX[index] = _axis.x;
      b.axisY[index] = _axis.y;
      b.axisZ[index] = _axis.z;
    } else {
      b.axisX[index] = 0;
      b.axisY[index] = 1;
      b.axisZ[index] = 0;
    }
  }

  /// Takes the particle just spawned at [index] into account in the bounds.
  void _spawned(int index) {
    final b = particles;
    _everSpawned = true;
    final extent = math.max(b.width[index], b.height[index]);
    if (extent > _maxExtent) {
      _maxExtent = extent;
    }
    _includeInBounds(b.posX[index], b.posY[index], b.posZ[index]);
  }

  void _includeInBounds(double x, double y, double z) {
    if (!_hasRawBounds) {
      _minX = _maxX = x;
      _minY = _maxY = y;
      _minZ = _maxZ = z;
      _hasRawBounds = true;
      return;
    }
    if (x < _minX) {
      _minX = x;
    } else if (x > _maxX) {
      _maxX = x;
    }
    if (y < _minY) {
      _minY = y;
    } else if (y > _maxY) {
      _maxY = y;
    }
    if (z < _minZ) {
      _minZ = z;
    } else if (z > _maxZ) {
      _maxZ = z;
    }
  }
}

/// The timeline of an emitter within a system.
class _EmitterState(int bursts) {
  double clock = 0;
  double debt = 0;
  double distanceDebt = 0;
  bool completed = false;
  final List<bool> fired = List.filled(bursts, false);

  void restart() {
    clock = 0;
    debt = 0;
    distanceDebt = 0;
    completed = false;
    fired.fillRange(0, fired.length, false);
  }
}
