import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flame/components.dart';
import 'package:flame/extensions.dart';
import 'package:flame/game.dart';
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
  required ParticleEmitter emitter,

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

  ParticleEmitter _emitter = emitter;

  /// The description of what to spawn and how particles behave.
  ///
  /// Assigning another emitter takes effect on the next simulation step: live
  /// particles are kept and continue under the new emitter's rules, the
  /// particle storage grows when the new emitter allows more particles, and
  /// the emission clock keeps running, so bursts of the new emitter that lie
  /// before the current time do not fire. Use [reconfigure] to restart the
  /// component from scratch instead.
  ParticleEmitter get emitter => _emitter;
  set emitter(ParticleEmitter value) {
    if (!identical(value, _emitter)) {
      _adoptEmitter(value, keepParticles: true);
    }
  }

  late ParticleBuffer _buffer = ParticleBuffer(_emitter.maxParticles);
  late List<bool> _burstFired = List.filled(_emitter.bursts.length, false);
  final Vector2 _sampledPosition = Vector2.zero();
  final Vector2 _fieldScratch = Vector2.zero();
  List<int> _arrivedScratch = const [];
  Float64List _fieldPoints = Float64List(0);
  Float32List _bounceScratch = Float32List(0);
  Vector2? _lastAbsolutePosition;

  /// When `true`, [render] does not draw the particles, because a parent
  /// draws them as part of a larger batch.
  ///
  /// `ParticleBatchGroup` does not need this flag (it never calls [render]
  /// on the emitters it merges); it exists for custom batching parents.
  @internal
  bool renderedByBatchGroup = false;

  bool _completed = false;
  double _clock = 0;
  double _simTime = 0;
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

  void _adoptEmitter(ParticleEmitter next, {required bool keepParticles}) {
    if (next.maxParticles > _buffer.capacity) {
      final grown = ParticleBuffer(next.maxParticles);
      if (keepParticles) {
        grown.copyLiveFrom(_buffer);
      }
      _buffer = grown;
    }
    final bursts = next.bursts;
    if (_burstFired.length != bursts.length) {
      _burstFired = List.filled(bursts.length, false);
    }
    if (keepParticles) {
      // The clock keeps running: bursts that lie in the past stay unfired.
      for (var i = 0; i < bursts.length; i++) {
        _burstFired[i] = bursts[i].time < _clock;
      }
    }
    _emitter = next;
  }

  /// Reconfigures and restarts this emitter in-place: moves it to [position],
  /// switches to [nextEmitter], removes all live particles and restarts the
  /// emission timeline (paused when [autoStart] is false).
  ///
  /// The [ParticleBuffer] is reused, and only replaced by a larger one when
  /// [nextEmitter] allows more particles than it can hold. A buffer that is
  /// larger than needed is kept, but the number of live particles is always
  /// limited by the current emitter's `maxParticles`.
  void reconfigure({
    Vector2? position,
    ParticleEmitter? nextEmitter,
    bool autoStart = true,
  }) {
    if (position != null) {
      this.position.setFrom(position);
    }
    if (nextEmitter != null && !identical(nextEmitter, _emitter)) {
      _adoptEmitter(nextEmitter, keepParticles: false);
    }
    _buffer.clear();
    _clock = 0;
    _simTime = 0;
    _emitDebt = 0;
    _burstFired.fillRange(0, _burstFired.length, false);
    _completed = false;
    _lastAbsolutePosition = null;
    _emitting = autoStart;
    markSubtreeDirty();
    Game.notifyVisualMutation();
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
  void emit(int count) {
    final before = _buffer.length;
    _spawnMany(count);
    if (_buffer.length != before) {
      markSubtreeDirty();
      Game.notifyVisualMutation();
    }
  }

  /// Removes all live particles.
  void clearParticles() {
    if (_buffer.length > 0) {
      _buffer.clear();
      markSubtreeDirty();
      Game.notifyVisualMutation();
    }
  }

  @override
  void update(double dt) {
    super.update(dt);
    _simTime += dt;
    if (worldSpace) {
      _compensateMovement();
    }
    if (_emitting && !_completed) {
      _advanceEmission(dt);
    }
    final hadParticles = _buffer.length > 0;
    _simulate(dt);
    if ((hadParticles || _buffer.length > 0) && dt > 0.0) {
      markSubtreeDirty();
      Game.notifyVisualMutation();
    }
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

  /// Whether continuous emission rate and burst counts automatically scale by
  /// `FlameGame.graphics.effectiveParticleDensity`.
  bool respectGraphicsParticleDensity = true;

  double _resolveParticleDensity() {
    if (!respectGraphicsParticleDensity) {
      return 1.0;
    }
    final game = findGame();
    if (game is FlameGame) {
      return game.graphics.effectiveParticleDensity;
    }
    return 1.0;
  }

  void _advanceEmission(double dt) {
    final density = _resolveParticleDensity();
    final end = emitter.emissionEndTime;
    final previous = _clock;
    _clock += dt;
    if (emitter.rate > 0 && density > 0.0) {
      final activeTime = min(_clock, end) - previous;
      if (activeTime > 0) {
        _emitDebt += emitter.rate * density * activeTime;
        final count = _emitDebt.floor();
        _emitDebt -= count;
        _spawnMany(count);
      }
    }
    final bursts = emitter.bursts;
    for (var i = 0; i < bursts.length; i++) {
      if (!_burstFired[i] && _clock >= bursts[i].time) {
        _burstFired[i] = true;
        if (density > 0.0 && bursts[i].count > 0) {
          final scaledCount = max(1, (bursts[i].count * density).round());
          _spawnMany(scaledCount);
        }
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
    // The buffer of a reused component can be larger than the current
    // emitter allows, so the emitter's own limit is checked first.
    if (buffer.length >= emitter.maxParticles) {
      return false;
    }
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
    buffer.fieldFlags[index] = 0;
    if (vStretch > 0) {
      final st = min(1.0 + speed * vStretch, emitter.maxStretch);
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
    final onFloorBounce = emitter.onFloorBounce;
    var bounceCount = 0;
    // A particle bounces at most once per step, so three floats per slot
    // record every bounce of the step.
    if (onFloorBounce != null && _bounceScratch.length < buffer.capacity * 3) {
      _bounceScratch = Float32List(buffer.capacity * 3);
    }
    final vStretch = emitter.velocityStretch;
    final maxStretch = emitter.maxStretch;
    final orientToVel = emitter.rotateToVelocity || vStretch > 0;
    var anyStretch = false;
    var hasPostColliders = false;
    // Field targets and centers are resolved once per step, not once per
    // particle: a provider is called a single time and every particle of the
    // step sees the same point.
    if (hasFields) {
      if (_fieldPoints.length < fields.length * 2) {
        _fieldPoints = Float64List(fields.length * 2);
      }
      for (var f = 0; f < fields.length; f++) {
        final fld = fields[f];
        switch (fld) {
          case ParticleAttractor():
            fld.resolveTarget(_fieldScratch);
          case ParticleVortex():
            fld.resolveCenter(_fieldScratch);
          case ParticleRepulsor():
            fld.resolveCenter(_fieldScratch);
            if (fld.hardBoundary) {
              hasPostColliders = true;
            }
          case ParticlePlaneCollider():
            hasPostColliders = true;
            continue;
          case ParticleCurlNoiseField():
          case ParticleBuoyancyField():
          case ParticleWindField():
            continue;
        }
        _fieldPoints[f * 2] = _fieldScratch.x;
        _fieldPoints[f * 2 + 1] = _fieldScratch.y;
      }
    }
    final fieldPoints = _fieldPoints;

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
              final dx = fieldPoints[f * 2] - px;
              final dy = fieldPoints[f * 2 + 1] - py;
              final distSq = dx * dx + dy * dy;
              final r = field.arrivalRadius;
              // One state bit per field remembers that the particle is
              // inside the radius, so an arrival is counted when it enters,
              // not on every step it stays.
              final bit = f < 32 ? 1 << f : 0;
              if (distSq <= r * r) {
                final flags = buffer.fieldFlags[i];
                if (bit == 0 || (flags & bit) == 0) {
                  buffer.fieldFlags[i] = flags | bit;
                  _arrivedScratch[f]++;
                }
                if (field.consumeOnArrival) {
                  buffer.removeAt(i);
                  continue particleLoop;
                }
              } else if (bit != 0) {
                buffer.fieldFlags[i] &= ~bit;
              }
              if (distSq > 1e-8) {
                final invDist = 1.0 / sqrt(distSq);
                final nx = dx * invDist;
                final ny = dy * invDist;
                ax += nx * field.strength - ny * field.swirl;
                ay += ny * field.strength + nx * field.swirl;
              }
            case ParticleVortex():
              final dx = px - fieldPoints[f * 2];
              final dy = py - fieldPoints[f * 2 + 1];
              final distSq = dx * dx + dy * dy;
              final maxR = field.radius;
              if (distSq > 1e-8 && distSq < maxR * maxR) {
                final dist = sqrt(distSq);
                final falloff = 1.0 - dist / maxR;
                final nx = dx / dist;
                final ny = dy / dist;
                ax +=
                    (-ny * field.angularAcceleration - nx * field.radialPull) *
                    falloff;
                ay +=
                    (nx * field.angularAcceleration - ny * field.radialPull) *
                    falloff;
              }
            case ParticleCurlNoiseField():
              final (cx, cy) = field.sampleAcceleration(
                px,
                py,
                _simTime,
                progress,
              );
              ax += cx;
              ay += cy;
            case ParticleBuoyancyField():
              final phase = (buffer.variant[i] & 0xff) * 0.02454369;
              final (bx, by) = field.sampleAcceleration(
                progress,
                _simTime,
                phase,
              );
              ax += bx;
              ay += by;
            case ParticleWindField():
              final (wx, wy) = field.sampleAcceleration(px, py, _simTime);
              ax += wx;
              ay += wy;
            case ParticleRepulsor():
              final dx = px - fieldPoints[f * 2];
              final dy = py - fieldPoints[f * 2 + 1];
              final distSq = dx * dx + dy * dy;
              final maxR = field.radius;
              if (distSq < maxR * maxR) {
                if (distSq > 1e-8) {
                  final dist = sqrt(distSq);
                  final falloff = 1.0 - dist / maxR;
                  ax += (dx / dist) * field.strength * falloff;
                  ay += (dy / dist) * field.strength * falloff;
                } else {
                  ay -= field.strength;
                }
              }
            case ParticlePlaneCollider():
              // Evaluated as position/velocity projection after integration.
              break;
          }
        }
      }

      var finalVelX = (buffer.velX[i] + ax * dt) * damping;
      var velY = (buffer.velY[i] + ay * dt) * damping;
      var nextX = px + finalVelX * dt;
      var nextY = py + velY * dt;

      if (floorY != null && nextY >= floorY && velY > 0) {
        final impactSpeed = velY;
        nextY = floorY - (nextY - floorY) * restitution;
        velY = -velY * restitution;
        finalVelX = finalVelX * friction;
        if (velY.abs() < 4.0) {
          velY = 0;
          nextY = floorY;
        } else if (onFloorBounce != null) {
          final base = bounceCount * 3;
          _bounceScratch[base] = nextX;
          _bounceScratch[base + 1] = floorY;
          _bounceScratch[base + 2] = impactSpeed;
          bounceCount++;
        }
      }

      if (hasPostColliders) {
        for (var f = 0; f < fields.length; f++) {
          final field = fields[f];
          if (field is ParticleRepulsor && field.hardBoundary) {
            final centerX = fieldPoints[f * 2];
            final centerY = fieldPoints[f * 2 + 1];
            final dx = nextX - centerX;
            final dy = nextY - centerY;
            final distSq = dx * dx + dy * dy;
            final r = field.radius;
            if (distSq < r * r) {
              double nx;
              double ny;
              if (distSq > 1e-8) {
                final invD = 1.0 / sqrt(distSq);
                nx = dx * invD;
                ny = dy * invD;
              } else {
                nx = 0.0;
                ny = -1.0;
              }
              nextX = centerX + nx * r;
              nextY = centerY + ny * r;
              final vn = finalVelX * nx + velY * ny;
              if (vn < 0) {
                final impulse = -(1.0 + field.restitution) * vn;
                finalVelX += impulse * nx;
                velY += impulse * ny;
              }
            }
          } else if (field is ParticlePlaneCollider) {
            final nx = field.normalX;
            final ny = field.normalY;
            final signedDist = nextX * nx + nextY * ny - field.offset;
            if (signedDist < 0) {
              nextX -= signedDist * nx;
              nextY -= signedDist * ny;
              final vn = finalVelX * nx + velY * ny;
              if (vn < 0) {
                final vxTan = finalVelX - vn * nx;
                final vyTan = velY - vn * ny;
                final bounceVn = -vn * field.restitution;
                finalVelX = vxTan * field.friction + bounceVn * nx;
                velY = vyTan * field.friction + bounceVn * ny;
              }
            }
          }
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
        final st = min(1.0 + spd * vStretch, maxStretch);
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

    if (onFloorBounce != null && bounceCount > 0) {
      for (var b = 0; b < bounceCount; b++) {
        final base = b * 3;
        onFloorBounce(
          _bounceScratch[base],
          _bounceScratch[base + 1],
          _bounceScratch[base + 2],
        );
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
