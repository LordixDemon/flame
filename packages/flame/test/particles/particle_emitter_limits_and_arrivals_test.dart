import 'dart:math';

import 'package:flame/components.dart';
import 'package:flame/particles.dart';
import 'package:flutter_test/flutter_test.dart';

ParticleEmitterComponent _component(ParticleEmitter emitter, {int seed = 7}) {
  return ParticleEmitterComponent(
    emitter: emitter,
    renderer: CallbackParticleRenderer((_, _) {}),
    removeOnFinish: false,
    random: Random(seed),
  );
}

void main() {
  group('ParticleEmitterComponent particle limit', () {
    test('reconfigure to a smaller preset honors the new maxParticles', () {
      final comp = _component(
        ParticleEmitter(
          maxParticles: 64,
          bursts: const <EmitterBurst>[EmitterBurst(0, 1)],
        ),
      );
      final buffer = comp.particles;

      // The way a pooled emitter is re-armed for its next effect.
      comp.reconfigure(
        nextEmitter: ParticleEmitter(
          maxParticles: 4,
          rate: 1000,
          lifespan: (10, 10),
        ),
      );
      comp.update(0.1);

      // The larger storage is reused, but the emitter's own limit applies.
      expect(comp.particles, same(buffer));
      expect(comp.particleCount, 4);
    });

    test('emit drops spawns beyond the maxParticles of the new preset', () {
      final comp = _component(ParticleEmitter(maxParticles: 64));
      comp.reconfigure(
        nextEmitter: ParticleEmitter(maxParticles: 4, lifespan: (10, 10)),
        autoStart: false,
      );
      comp.emit(20);
      expect(comp.particleCount, 4);

      // Going back to a preset that allows more lifts the limit again.
      comp.reconfigure(
        nextEmitter: ParticleEmitter(maxParticles: 32, lifespan: (10, 10)),
        autoStart: false,
      );
      comp.emit(20);
      expect(comp.particleCount, 20);
    });
  });

  group('ParticleEmitterComponent.emitter setter', () {
    test('keeps the live particles when the new emitter allows more', () {
      final comp = _component(
        ParticleEmitter(
          maxParticles: 4,
          bursts: const <EmitterBurst>[EmitterBurst(0, 4)],
          lifespan: (10, 10),
          shape: const CircleEmitterShape(20),
        ),
      )..update(0.016);
      expect(comp.particleCount, 4);
      final xs = [for (var i = 0; i < 4; i++) comp.particles.posX[i]];

      comp.emitter = ParticleEmitter(
        maxParticles: 16,
        lifespan: (10, 10),
        shape: const CircleEmitterShape(20),
      );

      expect(comp.particles.capacity, 16);
      expect(comp.particleCount, 4);
      expect(
        [for (var i = 0; i < 4; i++) comp.particles.posX[i]],
        xs,
      );
      comp.emit(20);
      expect(comp.particleCount, 16);
    });

    test('a new emitter with more bursts continues on the same clock', () {
      final comp = _component(
        ParticleEmitter(
          maxParticles: 64,
          bursts: const <EmitterBurst>[EmitterBurst(0, 2)],
          duration: 10,
          lifespan: (10, 10),
        ),
      )..update(0.5);
      expect(comp.particleCount, 2);

      comp.emitter = ParticleEmitter(
        maxParticles: 64,
        bursts: const <EmitterBurst>[
          EmitterBurst(0.1, 5),
          EmitterBurst(0.2, 5),
          EmitterBurst(1, 3),
        ],
        duration: 10,
        lifespan: (10, 10),
      );

      // The bursts at 0.1 s and 0.2 s lie in the past and stay silent.
      comp.update(0.1);
      expect(comp.particleCount, 2);
      // The burst at 1 s is still ahead and fires on time.
      comp.update(0.5);
      expect(comp.particleCount, 5);
    });
  });

  group('ParticleAttractor arrivals', () {
    test('a non-consuming attractor reports an arrival once', () {
      var arrived = 0;
      final attractor = ParticleAttractor(
        position: Vector2.zero(),
        strength: 0,
        arrivalRadius: 20,
        consumeOnArrival: false,
        onParticlesArrived: (count) => arrived += count,
      );
      final comp = _component(
        ParticleEmitter(
          maxParticles: 8,
          bursts: const <EmitterBurst>[EmitterBurst(0, 4)],
          lifespan: (60, 60),
          fields: <ParticleForceField>[attractor],
        ),
      );

      // Four particles spawn on the target with zero speed and stay there.
      for (var i = 0; i < 10; i++) {
        comp.update(1 / 60);
      }
      expect(comp.particleCount, 4);
      expect(arrived, 4);

      // Leaving the radius does not count...
      attractor.position.setValues(500, 0);
      comp.update(1 / 60);
      expect(arrived, 4);

      // ...and entering it again is a new arrival.
      attractor.position.setZero();
      comp
        ..update(1 / 60)
        ..update(1 / 60);
      expect(arrived, 8);
    });

    test('a consuming attractor reports every absorbed particle', () {
      final arrivals = <int>[];
      final comp = _component(
        ParticleEmitter(
          maxParticles: 8,
          bursts: const <EmitterBurst>[EmitterBurst(0, 5)],
          lifespan: (60, 60),
          fields: <ParticleForceField>[
            ParticleAttractor(
              position: Vector2.zero(),
              arrivalRadius: 20,
              onParticlesArrived: arrivals.add,
            ),
          ],
        ),
      );

      comp
        ..update(1 / 60)
        ..update(1 / 60);
      expect(comp.particleCount, 0);
      // One callback for the step in which they arrived, none afterwards.
      expect(arrivals, [5]);
    });

    test('a target provider is asked once per simulation step', () {
      var calls = 0;
      final target = Vector2(300, 0);
      final comp = _component(
        ParticleEmitter(
          maxParticles: 16,
          bursts: const <EmitterBurst>[EmitterBurst(0, 12)],
          lifespan: (60, 60),
          fields: <ParticleForceField>[
            ParticleAttractor(
              positionProvider: () {
                calls++;
                return target;
              },
            ),
          ],
        ),
      );

      for (var i = 0; i < 3; i++) {
        comp.update(1 / 60);
      }
      expect(comp.particleCount, 12);
      expect(calls, 3);
    });
  });

  group('velocityStretch and maxStretch', () {
    ParticleEmitterComponent fast({double? maxStretch, double speed = 1000}) {
      return _component(
        ParticleEmitter(
          maxParticles: 4,
          bursts: const <EmitterBurst>[EmitterBurst(0, 1)],
          lifespan: (10, 10),
          speed: (speed, speed),
          velocityStretch: 0.02,
          maxStretch: maxStretch ?? 4,
        ),
      );
    }

    test('stretch is capped at the default maxStretch', () {
      final comp = fast()..emit(1);
      // 1 + 1000 * 0.02 would be 21 without the cap.
      expect(comp.particles.stretch[0], 4);
      comp.update(1 / 60);
      expect(comp.particles.stretch[0], 4);
      expect(comp.particles.hasStretch, isTrue);
    });

    test('a custom maxStretch replaces the default', () {
      final comp = fast(maxStretch: 2.5)..update(1 / 60);
      expect(comp.particles.stretch[0], 2.5);

      final uncapped = fast(maxStretch: double.infinity)..update(1 / 60);
      expect(uncapped.particles.stretch[0], closeTo(21, 1e-3));
    });

    test('stretch below the cap is left alone', () {
      final comp = fast(speed: 50)..update(1 / 60);
      expect(comp.particles.stretch[0], closeTo(2, 1e-4));
    });

    test('maxStretch below 1 is rejected', () {
      expect(
        () => ParticleEmitter(velocityStretch: 0.01, maxStretch: 0.5),
        throwsAssertionError,
      );
    });
  });

  test('every floor bounce of a step is reported', () {
    var bounces = 0;
    final comp = _component(
      ParticleEmitter(
        maxParticles: 128,
        bursts: const <EmitterBurst>[EmitterBurst(0, 100)],
        lifespan: (10, 10),
        direction: pi / 2,
        spread: 0,
        speed: (300, 300),
        floorY: 1,
        floorRestitution: 0.9,
        onFloorBounce: (_, _, _) => bounces++,
      ),
    );

    // All 100 particles start just above the floor and hit it together.
    comp.update(1 / 60);
    expect(comp.particleCount, 100);
    expect(bounces, 100);
  });
}
