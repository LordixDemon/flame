import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/canvas3d.dart';
import 'package:flame/components.dart';
import 'package:flame/particles.dart';
import 'package:flame_test/flame_test.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Elemental Particle Physics, Force Fields & Cloud Renderer', () {
    test(
      'ParticleCurlNoiseField has near-zero numerical divergence '
      'across 2D grid',
      () {
        final curl = ParticleCurlNoiseField(
          seed: 777,
          spatialScale: 0.02,
          strength: 180.0,
        );
        const h = 0.5;
        var maxNormalizedDiv = 0.0;
        for (var gx = -5; gx <= 5; gx++) {
          for (var gy = -5; gy <= 5; gy++) {
            final x = gx * 14.0 + 3.1;
            final y = gy * 14.0 - 2.7;
            final (axP, _) = curl.sampleAcceleration(x + h, y, 1.2, 0.5);
            final (axM, _) = curl.sampleAcceleration(x - h, y, 1.2, 0.5);
            final (_, ayP) = curl.sampleAcceleration(x, y + h, 1.2, 0.5);
            final (_, ayM) = curl.sampleAcceleration(x, y - h, 1.2, 0.5);
            final dAxDx = (axP - axM) / (2.0 * h);
            final dAyDy = (ayP - ayM) / (2.0 * h);
            final div = (dAxDx + dAyDy).abs();
            maxNormalizedDiv = math.max(maxNormalizedDiv, div);
          }
        }
        // Analytical curl of C^2 Simplex polynomial has divergence ~ 0 up to
        // finite-difference truncation error (< 0.08 out of strength 180).
        expect(maxNormalizedDiv, lessThan(0.15));
      },
    );

    test(
      'ParticleBuoyancyField cools over life and ParticleWindField '
      'modulates gusts',
      () {
        final buoyancy = ParticleBuoyancyField(
          liftAcceleration: -240.0,
          coolingPower: 1.5,
          swayAmplitude: 20.0,
        );
        final (_, liftFresh) = buoyancy.sampleAcceleration(0.0, 0.5, 0.0);
        final (_, liftMid) = buoyancy.sampleAcceleration(0.5, 0.5, 0.0);
        final (_, liftCool) = buoyancy.sampleAcceleration(1.0, 0.5, 0.0);

        expect(liftFresh, closeTo(-240.0, 1e-6));
        expect(liftMid, lessThan(0.0));
        expect(liftMid.abs(), lessThan(liftFresh.abs()));
        expect(liftCool, closeTo(0.0, 1e-6));

        final wind = ParticleWindField(
          baseAcceleration: Vector2(50.0, 0.0),
          gustStrength: 90.0,
        );
        final (w0, _) = wind.sampleAcceleration(10.0, 20.0, 0.0);
        final (w1, _) = wind.sampleAcceleration(10.0, 20.0, 1.3);
        expect((w1 - w0).abs(), greaterThan(1.0));
      },
    );

    testWithFlameGame(
      'ParticleRepulsor hardBoundary and ParticlePlaneCollider deflect '
      'particles and onFloorBounce fires',
      (game) async {
        var floorBounces = 0;
        var maxBounceSpeed = 0.0;
        final dome = ParticleRepulsor(
          position: Vector2(0.0, 40.0),
          radius: 22.0,
          strength: 250.0,
          hardBoundary: true,
          restitution: 0.65,
        );
        final slantedWall = ParticlePlaneCollider(
          normalX: -1.0,
          normalY: -1.0,
          offset: -90.0,
          restitution: 0.5,
        );

        final comp = ParticleEmitterComponent(
          renderer: CircleParticleRenderer(softness: 0.4),
          removeOnFinish: false,
          random: math.Random(42),
          emitter: ParticleEmitter(
            maxParticles: 64,
            bursts: const <EmitterBurst>[EmitterBurst(0.0, 48)],
            lifespan: (2.0, 2.5),
            shape: const RectangleEmitterShape(30.0, 8.0),
            speed: (60.0, 110.0),
            direction: math.pi * 0.5,
            spread: 0.5,
            gravity: Vector2(0.0, 220.0),
            floorY: 85.0,
            floorRestitution: 0.55,
            onFloorBounce: (x, y, impactSpeed) {
              floorBounces++;
              if (impactSpeed > maxBounceSpeed) {
                maxBounceSpeed = impactSpeed;
              }
            },
            fields: <ParticleForceField>[dome, slantedWall],
          ),
        );

        await game.ensureAdd(comp);
        for (var step = 0; step < 60; step++) {
          game.update(1 / 60);
          final buf = comp.particles;
          for (var i = 0; i < buf.length; i++) {
            final dx = buf.posX[i] - dome.position.x;
            final dy = buf.posY[i] - dome.position.y;
            final dist = math.sqrt(dx * dx + dy * dy);
            expect(dist, greaterThanOrEqualTo(dome.radius - 1e-3));
            final planeSigned =
                buf.posX[i] * slantedWall.normalX +
                buf.posY[i] * slantedWall.normalY -
                slantedWall.offset;
            expect(planeSigned, greaterThanOrEqualTo(-1e-3));
          }
        }
        expect(floorBounces, greaterThan(0));
        expect(maxBounceSpeed, greaterThan(10.0));
      },
    );

    testWithFlameGame(
      'NoiseCloudParticleRenderer caches shared atlas and coalesces '
      'ElementalParticles in ParticleBatchGroup',
      (game) async {
        NoiseCloudParticleRenderer.clearAtlasCache();
        final r1 = NoiseCloudParticleRenderer(seed: 99, puffiness: 0.5);
        final r2 = NoiseCloudParticleRenderer(seed: 99, puffiness: 0.5);
        final fireRenderer = NoiseCloudParticleRenderer(
          seed: 99,
          puffiness: 0.5,
          blendMode: BlendMode.plus,
        );

        final batchGroup = ParticleBatchGroup();
        final smoke = ParticleEmitterComponent(
          position: Vector2(-30, 0),
          renderer: r1,
          emitter: ElementalParticles.fireSmoke(rate: 40),
        );
        final mist = ParticleEmitterComponent(
          position: Vector2(30, 10),
          renderer: r2,
          emitter: ElementalParticles.groundMist(rate: 30),
        );
        final fire = ParticleEmitterComponent(
          position: Vector2(0, 0),
          renderer: fireRenderer,
          emitter: ElementalParticles.fireCore(rate: 50),
        );
        final steam = ParticleEmitterComponent(
          position: Vector2(15, -10),
          renderer: r1,
          emitter: ElementalParticles.steamJet(rate: 35),
        );

        await game.ensureAdd(batchGroup);
        await batchGroup.ensureAddAll(<Component>[smoke, mist, steam, fire]);

        expect(NoiseCloudParticleRenderer.cachedAtlasCount, 1);
        expect(identical(r1.texture, r2.texture), isTrue);

        for (var i = 0; i < 20; i++) {
          game.update(1 / 60);
        }

        final recorder = PictureRecorder();
        final canvas = Canvas(recorder);
        game.render(canvas);
        recorder.endRecording().dispose();

        // `smoke` + `mist` + `steam` (`velocityStretch == 0`, `srcOver`)
        // coalesce into 1 `drawRawAtlas` call; `fire` (`BlendMode.plus`,
        // `velocityStretch > 0`) takes 1 `Vertices.raw` quad batch call.
        expect(batchGroup.lastAtlasDrawCalls, 1);
        expect(batchGroup.lastQuadBatchDrawCalls, 1);
      },
    );

    test(
      'ParticlePool3D simulates flame, smoke, waterDrop, turbulence, '
      'and perspective projection',
      () {
        var groundHits = 0;
        final pool = ParticlePool3D(
          capacity: 128,
          windX: 0.8,
          turbulenceStrength: 1.5,
          onGroundImpact: (x, y, speed) => groundHits++,
        );
        pool.spawnFlamePlume(0.0, 0.0, count: 12);
        pool.spawnWaterSplash3D(1.0, -0.5, count: 16);
        expect(pool.activeCount, 28);

        for (var step = 0; step < 45; step++) {
          pool.update(1 / 60);
        }
        expect(groundHits, greaterThan(0));

        final cam = CameraRig3D(
          projectionMode: CameraProjectionMode3D.perspective,
          cameraDistance: 16.0,
          fovYRad: math.pi / 3.0,
        );
        final recorder = PictureRecorder();
        pool.render(Canvas(recorder), cam);
        recorder.endRecording().dispose();
        expect(pool.lastDrawCalls, inInclusiveRange(1, 3));
      },
    );
  });
}
