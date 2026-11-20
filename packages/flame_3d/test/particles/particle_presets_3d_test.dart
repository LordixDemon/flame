import 'dart:math' as math;

import 'package:flame_3d/core.dart';
import 'package:flame_3d/particles.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  void run(ParticleSystem3D system, double seconds, {double dt = 1 / 60}) {
    var remaining = seconds;
    while (remaining > 1e-9) {
      final step = math.min(dt, remaining);
      system.update(step);
      remaining -= step;
    }
  }

  /// The highest a particle of [system] gets along z over [seconds].
  double highest(ParticleSystem3D system, double seconds) {
    var top = double.negativeInfinity;
    var remaining = seconds;
    while (remaining > 1e-9) {
      system.update(1 / 60);
      remaining -= 1 / 60;
      final b = system.particles;
      for (var i = 0; i < b.length; i++) {
        top = math.max(top, b.posZ[i]);
      }
    }
    return top;
  }

  final up = Vector3(0, 0, 1);

  group('ParticlePresets3D splashes', () {
    test('a crown rises, falls back and dies at the water level', () {
      final hits = <Vector3>[];
      final crown = ParticlePresets3D.splashCrown(
        up: up,
        waterLevel: 0.5,
        onGroundHit: (position, _) => hits.add(position.clone()),
      );
      expect(crown.burst(40, at: Vector3(1, 2, 0.5)), 40);
      final top = highest(crown, 2);
      // Thrown 10 to 20 cm up by a 20 cm object.
      expect(top - 0.5, inInclusiveRange(0.08, 0.3));
      expect(crown.particleCount, 0);
      expect(crown.isFinished, isTrue);
      expect(hits, hasLength(40));
      for (final hit in hits) {
        expect(hit.z, closeTo(0.5, 1e-6));
        // Out of the ring they were thrown from.
        final away = math.sqrt(
          math.pow(hit.x - 1, 2) + math.pow(hit.y - 2, 2),
        );
        expect(away, greaterThan(0.1));
      }
    });

    test('a bigger crown rises higher, in scene units', () {
      double heightOf({double size = 1, double scale = 1}) {
        final crown = ParticlePresets3D.splashCrown(
          up: up,
          size: size,
          scale: scale,
        )..burst(40, at: Vector3.zero());
        return highest(crown, 2);
      }

      final base = heightOf();
      expect(heightOf(size: 2), closeTo(base * 2, base * 0.35));
      // Measured in units of half a meter: twice the numbers.
      expect(heightOf(scale: 2), closeTo(base * 2, base * 0.35));
    });

    test('drips wait for start, then thin out over their duration', () {
      var hits = 0;
      final drips = ParticlePresets3D.runoffDrips(
        width: 2,
        depth: 1,
        up: up,
        onGroundHit: (_, _) => hits++,
      )..position.setValues(0, 0, 0.3);
      run(drips, 0.5);
      expect(drips.particleCount, 0);

      drips.start();
      drips.update(1 / 60);
      // They start on the outline of the slab's top.
      final b = drips.particles;
      expect(b.length, greaterThan(0));
      for (var i = 0; i < b.length; i++) {
        final onX = (b.posX[i].abs() - 1).abs() < 0.02;
        final onY = (b.posY[i].abs() - 0.5).abs() < 0.02;
        expect(onX || onY, isTrue);
        expect(b.posZ[i], closeTo(0.3, 0.02));
      }

      var early = 0;
      var late = 0;
      var spawned = b.length;
      for (var t = 1 / 60; t < 2.5; t += 1 / 60) {
        final before = hits + drips.particleCount;
        drips.update(1 / 60);
        final born = hits + drips.particleCount - before;
        spawned += born;
        if (t < 0.6) {
          early += born;
        } else if (t > 1.0 && t < 1.6) {
          late += born;
        }
      }
      expect(early, greaterThan(late * 3));
      expect(drips.particleCount, 0);
      expect(hits, spawned);
      expect(drips.isFinished, isTrue);
    });

    test('foam lies flat on the water and spreads', () {
      final foam = ParticlePresets3D.foamBurst(up: up);
      expect(foam.material!.billboard, ParticleBillboard.flat);
      expect(foam.material!.axis, up);
      foam.burst(14, at: Vector3(0, 0, 0.2));
      run(foam, 0.3);
      final b = foam.particles;
      expect(b.length, 14);
      var spread = 0.0;
      for (var i = 0; i < b.length; i++) {
        expect(b.posZ[i], closeTo(0.2, 0.02));
        spread = math.max(
          spread,
          math.sqrt(b.posX[i] * b.posX[i] + b.posY[i] * b.posY[i]),
        );
      }
      expect(spread, greaterThan(0.05));
      run(foam, 1);
      expect(foam.isFinished, isTrue);
    });

    test('mist starts above the water, drifts up and fades', () {
      final mist = ParticlePresets3D.mistPuff(up: up)
        ..burst(10, at: Vector3.zero());
      final b = mist.particles;
      for (var i = 0; i < b.length; i++) {
        expect(b.posZ[i], greaterThanOrEqualTo(0.12 - 1e-6));
      }
      run(mist, 0.5);
      var sum = 0.0;
      for (var i = 0; i < b.length; i++) {
        sum += b.posZ[i];
      }
      expect(sum / b.length, greaterThan(0.18));
      run(mist, 1.2);
      expect(mist.isFinished, isTrue);
    });

    test('keep their bounds around the splash', () {
      final crown = ParticlePresets3D.splashCrown(up: up)
        ..burst(40, at: Vector3(5, 5, 0));
      run(crown, 0.15);
      final bounds = crown.particleBounds!;
      expect(bounds.min.x, greaterThan(4.5));
      expect(bounds.max.x, lessThan(5.5));
      expect(bounds.min.z, greaterThan(-0.05));
      expect(bounds.max.z, lessThan(0.4));
    });
  });
}
