import 'dart:async';
import 'dart:math';

import 'package:flame/components.dart';
import 'package:flame/extensions.dart';
import 'package:flame/src/particles/particle_buffer.dart';
import 'package:flame/src/particles/particle_emitter.dart';
import 'package:flame/src/particles/particle_force_field.dart';
import 'package:flame/src/particles/particle_range.dart';
import 'package:flame/src/particles/particle_renderer.dart';
import 'package:meta/meta.dart';

/// A component that spawns, simulates, and renders particles described by a
/// [ParticleEmitter].
///
/// Supports zero-allocation pooling via [RecyclableComponent] (`ComponentPool`)
/// and automatic multi-emitter `drawRawAtlas` merging when placed inside a
/// `ParticleBatchGroup`.
class ParticleEmitterComponent({
  /// The description of what to spawn and how particles behave.
  required var ParticleEmitter emitter,

  /// The renderer that draws the live particles.
  required final ParticleRenderer renderer,

  /// Whether the component removes itself once emission has finished and no
  /// particles are alive.
  var bool removeOnFinish = true,

  /// When true, live particles keep their world position while the
  /// component moves, so a moving emitter leaves a trail behind.
  ///
  /// Only translation is compensated: ancestors of the component (and the
  /// component itself) should not be rotated or scaled.
  final bool worldSpace = false,
  var bool _emitting = true,
  Random? random,
  super.position,
  super.size,
  super.scale,
  super.angle,
  super.anchor,
  super.children,
  super.priority,
  super.sortKey,
  super.key,
}) extends PositionComponent with RecyclableComponent {
  /// The random source used for all sampling; seed it for determinism.
  final Random random = random ?? Random();

  late ParticleBuffer _buffer = ParticleBuffer(emitter.maxParticles);
  late List<bool> _burstFired = List.filled(emitter.bursts.length, false);
  final Vector2 _sampledPosition = Vector2.zero();
  final Vector2 _fieldScratch = Vector2.zero();
  List<int> _arrivedScratch = const [];
  Vector2? _lastAbsolutePosition;

  /// Set to `true` by an ancestor `ParticleBatchGroup` while rendering so the
  /// group can merge all compatible child emitters into one `drawRawAtlas`.
  @internal
  bool renderedByBatchGroup = false;

  bool _completed = false;
  double _clock = 0;
  double _emitDebt = 0;

  /// The live particles. Exposed for custom renderers, custom behaviors,
  /// and tests; treat it as read-only unless you know what you are doing.
  ParticleBuffer get particles => _buffer;

  /// The number of currently live particles.
  int get particleCount => _buffer.length;

  /// Whether the emission timeline is running.
  bool get emitting => _emitting;

  /// Whether emission has naturally finished and no particles are alive.
  bool get isFinished => _completed && _buffer.length == 0;

  @override
  FutureOr<void> onLoad() => renderer.onLoad();

  /// Reconfigures and restarts this emitter in-place without reallocating its
  /// [ParticleBuffer] unless the new [nextEmitter] exceeds `_buffer.capacity`.
  void reconfigure({
    Vector2? position,
    ParticleEmitter? nextEmitter,
    bool autoStart = true,
  }) {
    if (position != null) {
      this.position.setFrom(position);
    }
    if (nextEmitter != null && !identical(nextEmitter, emitter)) {
      if (nextEmitter.maxParticles > _buffer.capacity) {
        _buffer = ParticleBuffer(nextEmitter.maxParticles);
      }
      if (_burstFired.length != nextEmitter.bursts.length) {
        _burstFired = List.filled(nextEmitter.bursts.length, false);
      }
      emitter = nextEmitter;
    }
    _buffer.clear();
    _clock = 0;
    _emitDebt = 0;
    _burstFired.fillRange(0, _burstFired.length, false);
    _completed = false;
    _lastAbsolutePosition = null;
    _emitting = autoStart;
  }

  @override
  void onAcquire() {
    reconfigure();
  }

  @override
  void onRelease() {
    _buffer.clear();
    _emitting = false;
    _lastAbsolutePosition = null;
  }

  /// Starts (or resumes) emission; if emission had finished, the timeline
  /// restarts from the beginning.
  void start() {
    if (_completed) {
      _clock = 0;
      _emitDebt = 0;
      _burstFired.fillRange(0, _burstFired.length, false);
      _completed = false;
    }
    _emitting = true;
  }

  /// Pauses emission; live particles keep simulating.
  void stop() => _emitting = false;

  /// Immediately spawns [count] particles, independently of the emission
  /// timeline. Spawns beyond the emitter's `maxParticles` are dropped.
  void emit(int count) => _spawnMany(count);

  /// Removes all live particles.
  void clearParticles() => _buffer.clear();

  @override
  void update(double dt) {
    super.update(dt);
    if (worldSpace) {
      _compensateMovement();
    }
    if (_emitting && !_completed) {
      _advanceEmission(dt);
    }
    _simulate(dt);
    if (removeOnFinish && isFinished) {
      removeFromParent();
    }
  }

  @override
  void render(Canvas canvas) {
    super.render(canvas);
    if (!renderedByBatchGroup) {
      renderer.render(canvas, _buffer);
    }
  }

  void _compensateMovement() {
    final current = absolutePosition;
    final last = _lastAbsolutePosition;
    if (last == null) {
      _lastAbsolutePosition = current.clone();
      return;
    }
    final dx = current.x - last.x;
    final dy = current.y - last.y;
    if (dx != 0 || dy != 0) {
      final buffer = _buffer;
      for (var i = 0; i < buffer.length; i++) {
        buffer.posX[i] -= dx;
        buffer.posY[i] -= dy;
      }
    }
    last.setFrom(current);
  }

  void _advanceEmission(double dt) {
    final end = emitter.emissionEndTime;
    final previous = _clock;
    _clock += dt;
    if (emitter.rate > 0) {
      final activeTime = min(_clock, end) - previous;
      if (activeTime > 0) {
        _emitDebt += emitter.rate * activeTime;
        final count = _emitDebt.floor();
        _emitDebt -= count;
        _spawnMany(count);
      }
    }
    final bursts = emitter.bursts;
    for (var i = 0; i < bursts.length; i++) {
      if (!_burstFired[i] && _clock >= bursts[i].time) {
        _burstFired[i] = true;
        _spawnMany(bursts[i].count);
      }
    }
    if (_clock >= end) {
      if (emitter.loop) {
        // duration is asserted to be set and positive when looping.
        _clock = _clock % end;
        _burstFired.fillRange(0, _burstFired.length, false);
      } else {
        _completed = true;
      }
    }
  }

  void _spawnMany(int count) {
    for (var i = 0; i < count; i++) {
      if (!_spawnOne()) {
        break;
      }
    }
  }

  bool _spawnOne() {
    final buffer = _buffer;
    final index = buffer.spawn();
    if (index < 0) {
      return false;
    }
    emitter.shape.samplePosition(random, _sampledPosition);
    buffer.posX[index] = _sampledPosition.x;
    buffer.posY[index] = _sampledPosition.y;
    final direction =
        emitter.direction + (random.nextDouble() - 0.5) * emitter.spread;
    final speed = emitter.speed.sample(random);
    buffer.velX[index] = cos(direction) * speed;
    buffer.velY[index] = sin(direction) * speed;
    final lifespan = max(emitter.lifespan.sample(random), 1e-4);
    buffer.age[index] = 0;
    buffer.invLifespan[index] = 1 / lifespan;
    final size = emitter.size.sample(random);
    buffer.baseSize[index] = size;
    final scaleCurve = emitter.scaleOverLife;
    buffer.size[index] = scaleCurve == null
        ? size
        : size * scaleCurve.transform(0);
    final vStretch = emitter.velocityStretch;
    buffer.rotation[index] = (emitter.rotateToVelocity || vStretch > 0)
        ? direction
        : emitter.rotation.sample(random);
    buffer.spin[index] = emitter.spin.sample(random);
    buffer.color[index] = _colorAt(0);
    buffer.variant[index] = random.nextInt(0x10000);
    if (vStretch > 0) {
      final st = 1.0 + speed * vStretch;
      buffer.stretch[index] = st;
      if (st > 1.001) {
        buffer.hasStretch = true;
      }
    } else {
      buffer.stretch[index] = 1.0;
    }
    return true;
  }

  void _simulate(double dt) {
    final buffer = _buffer;
    if (buffer.length == 0) {
      buffer.hasStretch = false;
      return;
    }
    final accelerationX = emitter.gravity.x;
    final accelerationY = emitter.gravity.y;
    final damping = emitter.drag > 0 ? 1 / (1 + emitter.drag * dt) : 1.0;
    final scaleCurve = emitter.scaleOverLife;
    final tintsOverLife =
        emitter.colorOverLife != null || emitter.opacityOverLife != null;
    final fields = emitter.fields;
    final hasFields = fields.isNotEmpty;
    if (hasFields && _arrivedScratch.length < fields.length) {
      _arrivedScratch = List<int>.filled(fields.length, 0);
    } else if (hasFields) {
      _arrivedScratch.fillRange(0, fields.length, 0);
    }

    final floorY = emitter.floorY;
    final restitution = emitter.floorRestitution;
    final friction = emitter.floorFriction;
    final vStretch = emitter.velocityStretch;
    final orientToVel = emitter.rotateToVelocity || vStretch > 0;
    var anyStretch = false;

    var i = 0;
    particleLoop:
    while (i < buffer.length) {
      final age = buffer.age[i] + dt;
      final progress = age * buffer.invLifespan[i];
      if (progress >= 1) {
        buffer.removeAt(i);
        continue;
      }
      buffer.age[i] = age;

      var ax = accelerationX;
      var ay = accelerationY;
      final px = buffer.posX[i];
      final py = buffer.posY[i];

      if (hasFields) {
        for (var f = 0; f < fields.length; f++) {
          final field = fields[f];
          switch (field) {
            case ParticleAttractor():
              field.resolveTarget(_fieldScratch);
              final dx = _fieldScratch.x - px;
              final dy = _fieldScratch.y - py;
              final distSq = dx * dx + dy * dy;
              final r = field.arrivalRadius;
              if (distSq <= r * r) {
                _arrivedScratch[f]++;
                if (field.consumeOnArrival) {
                  buffer.removeAt(i);
                  continue particleLoop;
                }
              }
              if (distSq > 1e-8) {
                final invDist = 1.0 / sqrt(distSq);
                final nx = dx * invDist;
                final ny = dy * invDist;
                ax += nx * field.strength - ny * field.swirl;
                ay += ny * field.strength + nx * field.swirl;
              }
            case ParticleVortex():
              field.resolveCenter(_fieldScratch);
              final dx = px - _fieldScratch.x;
              final dy = py - _fieldScratch.y;
              final distSq = dx * dx + dy * dy;
              final maxR = field.radius;
              if (distSq > 1e-8 && distSq < maxR * maxR) {
                final dist = sqrt(distSq);
                final falloff = 1.0 - dist / maxR;
                final nx = dx / dist;
                final ny = dy / dist;
                // Tangential (-ny, nx) + inward (-nx, -ny)
                ax +=
                    (-ny * field.angularAcceleration - nx * field.radialPull) *
                    falloff;
                ay +=
                    (nx * field.angularAcceleration - ny * field.radialPull) *
                    falloff;
              }
          }
        }
      }

      final velX = (buffer.velX[i] + ax * dt) * damping;
      var velY = (buffer.velY[i] + ay * dt) * damping;
      final nextX = px + velX * dt;
      var nextY = py + velY * dt;

      var finalVelX = velX;
      if (floorY != null && nextY >= floorY && velY > 0) {
        nextY = floorY - (nextY - floorY) * restitution;
        velY = -velY * restitution;
        finalVelX = velX * friction;
        if (velY.abs() < 4.0) {
          velY = 0;
          nextY = floorY;
        }
      }

      buffer.velX[i] = finalVelX;
      buffer.velY[i] = velY;
      buffer.posX[i] = nextX;
      buffer.posY[i] = nextY;

      if (orientToVel) {
        if (finalVelX != 0 || velY != 0) {
          buffer.rotation[i] = atan2(velY, finalVelX);
        }
      } else {
        buffer.rotation[i] += buffer.spin[i] * dt;
      }

      if (vStretch > 0) {
        final spd = sqrt(finalVelX * finalVelX + velY * velY);
        final st = 1.0 + spd * vStretch;
        buffer.stretch[i] = st;
        if (st > 1.001) {
          anyStretch = true;
        }
      } else {
        buffer.stretch[i] = 1.0;
      }

      if (scaleCurve != null) {
        buffer.size[i] = buffer.baseSize[i] * scaleCurve.transform(progress);
      }
      if (tintsOverLife) {
        buffer.color[i] = _colorAt(progress);
      }
      i++;
    }

    buffer.hasStretch = anyStretch;

    if (hasFields) {
      for (var f = 0; f < fields.length; f++) {
        final count = _arrivedScratch[f];
        if (count > 0) {
          final field = fields[f];
          if (field is ParticleAttractor) {
            field.onParticlesArrived?.call(count);
          }
        }
      }
    }
  }

  int _colorAt(double progress) {
    var color = emitter.colorOverLife?.valueAt(progress) ?? 0xffffffff;
    final opacityCurve = emitter.opacityOverLife;
    if (opacityCurve != null) {
      final opacity = opacityCurve.transform(progress).clamp(0.0, 1.0);
      final alpha = (((color >> 24) & 0xff) * opacity).round();
      color = (alpha << 24) | (color & 0x00ffffff);
    }
    return color;
  }
}
