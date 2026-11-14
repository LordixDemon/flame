import 'dart:math';
import 'dart:ui';

import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flame/particles.dart';
import 'package:flutter_test/flutter_test.dart';

Image _makeAtlas(int w, int h) {
  final rec = PictureRecorder();
  Canvas(rec).drawRect(
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    Paint()..color = const Color(0xFFFFFFFF),
  );
  final pic = rec.endRecording();
  try {
    return pic.toImageSync(w, h);
  } finally {
    pic.dispose();
  }
}

void main() {
  group('ParticleBuffer, reconfigure, worldSpace & multi-bursts', () {
    tearDown(CircleParticleRenderer.clearTextureCache);

    test(
      'reconfigure reuses SoA capacity when <= cap & grows cleanly when larger',
      () {
        final smallEmitter = ParticleEmitter(
          maxParticles: 16,
          duration: 0.25,
          bursts: const <EmitterBurst>[
            EmitterBurst(0.0, 6),
            EmitterBurst(0.10, 5),
          ],
          lifespan: (0.2, 0.2),
        );
        final comp = ParticleEmitterComponent(
          emitter: smallEmitter,
          renderer: CircleParticleRenderer(),
          random: Random(11),
        );
        final bufBefore = comp.particles;

        comp.update(0.02);
        expect(comp.particleCount, 6);
        comp.update(0.10);
        expect(comp.particleCount, 11);

        // Advance past duration + lifespan -> isFinished becomes true!
        comp.update(0.5);
        expect(comp.particleCount, 0);
        expect(comp.isFinished, isTrue);

        // Reconfigure with equal/smaller maxParticles keeps exact same buffer!
        final fitEmitter = ParticleEmitter(
          maxParticles: 12,
          bursts: const <EmitterBurst>[EmitterBurst(0.0, 10)],
          lifespan: (0.4, 0.4),
        );
        comp.reconfigure(position: Vector2(50, 75), nextEmitter: fitEmitter);
        expect(identical(comp.particles, bufBefore), isTrue);
        expect(comp.position, Vector2(50, 75));
        expect(comp.isFinished, isFalse);
        comp.update(0.016);
        expect(comp.particleCount, 10);

        // Reconfigure with larger maxParticles grows capacity cleanly!
        final hugeEmitter = ParticleEmitter(
          maxParticles: 64,
          bursts: const <EmitterBurst>[EmitterBurst(0.0, 40)],
          lifespan: (0.4, 0.4),
        );
        comp.reconfigure(nextEmitter: hugeEmitter);
        expect(comp.particles.capacity, 64);
        comp.update(0.016);
        expect(comp.particleCount, 40);
      },
    );

    test(
      'worldSpace trails keep older particles behind when emitter translates',
      () async {
        final game = FlameGame()..onGameResize(Vector2(400, 300));
        await game.start();

        final worldEmitter = ParticleEmitterComponent(
          position: Vector2(10, 50),
          worldSpace: true,
          emitter: ParticleEmitter(
            maxParticles: 32,
            rate: 120,
            lifespan: (2.0, 2.0),
          ),
          renderer: CircleParticleRenderer(),
          random: Random(3),
        );
        game.world.add(worldEmitter);
        await game.ready();

        game.update(0.05);
        expect(worldEmitter.particleCount, greaterThan(0));
        final firstParticleLocalXBefore = worldEmitter.particles.posX[0];

        // Translate emitter +100px right in world space: previously spawned
        // stationary world particle shifts by -100px in emitter-local space!
        worldEmitter.position.x += 100.0;
        game.update(0.02);
        expect(
          worldEmitter.particles.posX[0],
          closeTo(firstParticleLocalXBefore - 100.0, 1e-3),
        );
      },
    );
  });

  group('ParticleBatchGroup multi-blend split & force-field edge cases', () {
    tearDown(CircleParticleRenderer.clearTextureCache);

    test(
      'ParticleBatchGroup coalesces matching (Image, BlendMode) & splits plus',
      () async {
        final normalA = CircleParticleRenderer(softness: 0.3);
        final normalB = CircleParticleRenderer(softness: 0.3);
        final additive = CircleParticleRenderer(
          softness: 0.3,
          blendMode: BlendMode.plus,
        );
        await normalA.onLoad();
        await normalB.onLoad();
        await additive.onLoad();

        ParticleEmitterComponent spawn10(ParticleRenderer r, double x) {
          return ParticleEmitterComponent(
            position: Vector2(x, 20),
            emitter: ParticleEmitter(
              maxParticles: 16,
              bursts: const <EmitterBurst>[EmitterBurst(0, 10)],
            ),
            renderer: r,
            random: Random(5),
          )..update(0.016);
        }

        // Two srcOver emitters merge into call #1; additive splits into #2!
        final batch = ParticleBatchGroup(
          children: <Component>[
            spawn10(normalA, 0),
            spawn10(normalB, 30),
            spawn10(additive, 60),
          ],
        );

        final telemetry = RenderFrameTelemetry()..beginRenderFrame();
        final rec = PictureRecorder();
        final telCanvas = TelemetryCanvas()..bind(Canvas(rec), telemetry);
        batch.renderTree(telCanvas);
        telCanvas.unbind();
        telemetry.endRenderFrame();
        rec.endRecording().dispose();

        expect(batch.lastBatchedEmitterCount, 3);
        expect(batch.lastAtlasDrawCalls, 2);
        expect(telemetry.atlasCalls, 2);
      },
    );

    test(
      'non-consuming attractor, multi-bounce floor decay & flipbook clamping',
      () {
        // Non-consuming attractor keeps particles alive inside arrivalRadius.
        var arrivedCallbacks = 0;
        final orbitAttractor = ParticleAttractor(
          position: Vector2.zero(),
          strength: 1200,
          arrivalRadius: 20,
          consumeOnArrival: false,
          onParticlesArrived: (c) => arrivedCallbacks += c,
        );
        final orbiter = ParticleEmitterComponent(
          emitter: ParticleEmitter(
            maxParticles: 8,
            bursts: const <EmitterBurst>[EmitterBurst(0, 4)],
            speed: (5, 5),
            lifespan: (3.0, 3.0),
            fields: <ParticleForceField>[orbitAttractor],
          ),
          renderer: CircleParticleRenderer(),
          random: Random(21),
        )..update(0.05);
        expect(orbiter.particleCount, 4);
        expect(arrivedCallbacks, 4);

        // Floor bounce with restitution < 1 stays above/at floorY with zero NaN.
        final bouncer = ParticleEmitterComponent(
          emitter: ParticleEmitter(
            maxParticles: 4,
            bursts: const <EmitterBurst>[EmitterBurst(0, 1)],
            direction: pi / 2,
            spread: 0,
            speed: (120, 120),
            gravity: Vector2(0, 500),
            lifespan: (5.0, 5.0),
            floorY: 30.0,
            floorRestitution: 0.5,
          ),
          renderer: CircleParticleRenderer(),
        );
        for (var i = 0; i < 90; i++) {
          bouncer.update(1 / 60);
          expect(bouncer.particles.posY[0], lessThanOrEqualTo(30.001));
          expect(bouncer.particles.velY[0].isNaN, isFalse);
        }

        // Flipbook & Variant renderers clamp out-of-bounds progress/variant!
        final atlas = _makeAtlas(64, 64);
        addTearDown(atlas.dispose);
        final flip = FlipbookParticleRenderer(
          image: atlas,
          columns: 2,
          rows: 2,
        );
        final buf = ParticleBuffer(2);
        final idx = buf.spawn();
        buf.age[idx] = 9.9; // > lifespan (clamped to last frame 3 -> (32, 32))!
        buf.invLifespan[idx] = 1.0;
        expect(
          flip.frameRectForParticle(buf, idx),
          const Rect.fromLTWH(32, 32, 32, 32),
        );

        final variants = VariantSpriteParticleRenderer(
          image: atlas,
          sourceRects: const <Rect>[
            Rect.fromLTWH(0, 0, 16, 16),
            Rect.fromLTWH(16, 0, 16, 16),
          ],
        );
        buf.variant[idx] = 99; // wraps/clamps safely without RangeError!
        final rect = variants.frameRectForParticle(buf, idx);
        expect(rect.width, 16);
      },
    );
  });
}
