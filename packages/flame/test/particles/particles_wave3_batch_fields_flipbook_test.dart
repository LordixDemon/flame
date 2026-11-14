import 'dart:math';
import 'dart:ui';

import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flame/particles.dart';
import 'package:flutter_test/flutter_test.dart';

Image _makeTestAtlas(int width, int height) {
  final recorder = PictureRecorder();
  Canvas(recorder)
    ..drawRect(
      Rect.fromLTWH(0, 0, width * 0.5, height.toDouble()),
      Paint()..color = const Color(0xFFFF4444),
    )
    ..drawRect(
      Rect.fromLTWH(width * 0.5, 0, width * 0.5, height.toDouble()),
      Paint()..color = const Color(0xFF44FF88),
    );
  final picture = recorder.endRecording();
  final image = picture.toImageSync(width, height);
  picture.dispose();
  return image;
}

void main() {
  group('Wave-3 Particles (#1, #2, #3)', () {
    tearDown(CircleParticleRenderer.clearTextureCache);

    test(
      'CircleParticleRenderer shares GPU textures across instances',
      () async {
        CircleParticleRenderer.clearTextureCache();
        expect(CircleParticleRenderer.cachedTextureCount, 0);

        final r1 = CircleParticleRenderer(softness: 0.5);
        final r2 = CircleParticleRenderer(softness: 0.5);
        final r3 = CircleParticleRenderer();

        expect(r1.texture, isNull);
        await r1.onLoad();
        await r2.onLoad();
        await r3.onLoad();

        expect(r1.texture, isNotNull);
        expect(identical(r1.texture, r2.texture), isTrue);
        expect(identical(r1.texture, r3.texture), isFalse);
        expect(CircleParticleRenderer.cachedTextureCount, 2);

        CircleParticleRenderer.clearTextureCache();
        expect(CircleParticleRenderer.cachedTextureCount, 0);
      },
    );

    test(
      'ParticleEmitterComponent pools via RecyclableComponent without realloc',
      () {
        final emitterDef = ParticleEmitter(
          maxParticles: 16,
          bursts: const [EmitterBurst(0, 8)],
          lifespan: (0.5, 0.5),
        );
        final renderer = CircleParticleRenderer();
        final pool = ComponentPool<ParticleEmitterComponent>(
          factory: () => ParticleEmitterComponent(
            emitter: emitterDef,
            renderer: renderer,
          ),
          maxSize: 4,
        );

        final comp = pool.acquire();
        final originalBuffer = comp.particles;
        comp.update(0.016);
        expect(comp.particleCount, 8);

        pool.release(comp);
        expect(comp.particleCount, 0);
        expect(comp.emitting, isFalse);

        final reacquired = pool.acquire();
        expect(identical(reacquired, comp), isTrue);
        expect(identical(reacquired.particles, originalBuffer), isTrue);
        reacquired.update(0.016);
        expect(reacquired.particleCount, 8);
      },
    );

    test(
      'ParticleBatchGroup merges multiple emitters into 1 drawRawAtlas call',
      () async {
        final r1 = CircleParticleRenderer(softness: 0.25);
        final r2 = CircleParticleRenderer(softness: 0.25);
        final r3 = CircleParticleRenderer(softness: 0.25);
        await r1.onLoad();
        await r2.onLoad();
        await r3.onLoad();

        ParticleEmitterComponent makeBurst(Vector2 pos, ParticleRenderer r) {
          return ParticleEmitterComponent(
            position: pos,
            emitter: ParticleEmitter(
              maxParticles: 16,
              bursts: const [EmitterBurst(0, 10)],
            ),
            renderer: r,
            random: Random(7),
          )..update(0.016);
        }

        final group = ParticleBatchGroup(
          children: [
            makeBurst(Vector2(10, 20), r1),
            makeBurst(Vector2(50, 40), r2),
            makeBurst(Vector2(90, 60), r3),
          ],
        );

        final telemetry = RenderFrameTelemetry()..beginRenderFrame();
        final recorder = PictureRecorder();
        final rawCanvas = Canvas(recorder);
        final telCanvas = TelemetryCanvas()..bind(rawCanvas, telemetry);

        group.renderTree(telCanvas);
        telCanvas.unbind();
        telemetry.endRenderFrame();
        recorder.endRecording().dispose();

        expect(group.lastBatchedEmitterCount, 3);
        expect(group.lastAtlasDrawCalls, 1);
        expect(telemetry.atlasCalls, 1);
      },
    );

    test(
      'ParticleAttractor absorbs homing particles and fires onParticlesArrived',
      () {
        var arrivedTotal = 0;
        final attractor = ParticleAttractor(
          position: Vector2(40, 0),
          strength: 2400,
          arrivalRadius: 10,
          swirl: 60,
          onParticlesArrived: (count) => arrivedTotal += count,
        );
        final comp = ParticleEmitterComponent(
          emitter: ParticleEmitter(
            maxParticles: 12,
            bursts: const [EmitterBurst(0, 6)],
            speed: (10, 10),
            spread: 0.2,
            lifespan: (3.0, 3.0),
            fields: [attractor],
          ),
          renderer: CircleParticleRenderer(),
          random: Random(42),
        );

        for (var step = 0; step < 30; step++) {
          comp.update(1 / 60);
        }

        expect(arrivedTotal, 6);
        expect(comp.particleCount, 0);
      },
    );

    test(
      'ParticleVortex, floorY bounce, and velocityStretch simulate and render',
      () async {
        final renderer = CircleParticleRenderer();
        await renderer.onLoad();

        final vortex = ParticleVortex(
          center: Vector2.zero(),
          angularAcceleration: 400,
          radialPull: 50,
          radius: 200,
        );
        final comp = ParticleEmitterComponent(
          emitter: ParticleEmitter(
            maxParticles: 8,
            bursts: const [EmitterBurst(0, 4)],
            direction: pi / 2,
            spread: 0,
            speed: (160, 160),
            gravity: Vector2(0, 300),
            lifespan: (2.0, 2.0),
            fields: [vortex],
            floorY: 20.0,
            floorRestitution: 0.7,
            velocityStretch: 0.02,
          ),
          renderer: renderer,
          random: Random(9),
        );

        comp
          ..update(0.05)
          ..update(0.12);
        expect(comp.particles.hasStretch, isTrue);
        expect(comp.particles.posY[0], lessThanOrEqualTo(20.0));
        expect(comp.particles.velY[0], lessThan(0.0));
        expect(comp.particles.velX[0].abs(), greaterThan(0.1));

        final telemetry = RenderFrameTelemetry()..beginRenderFrame();
        final recorder = PictureRecorder();
        final telCanvas = TelemetryCanvas()..bind(Canvas(recorder), telemetry);
        comp.render(telCanvas);
        telCanvas.unbind();
        telemetry.endRenderFrame();
        recorder.endRecording().dispose();

        expect(telemetry.verticesCalls, 1);
      },
    );

    test(
      'FlipbookParticleRenderer and VariantSpriteParticleRenderer frames',
      () {
        final atlas = _makeTestAtlas(64, 32);
        addTearDown(atlas.dispose);

        final flipbook = FlipbookParticleRenderer(
          image: atlas,
          columns: 2,
          rows: 1,
        );
        final buffer = ParticleBuffer(4);
        final i0 = buffer.spawn();
        buffer.age[i0] = 0.1;
        buffer.invLifespan[i0] = 1.0;
        final i1 = buffer.spawn();
        buffer.age[i1] = 0.8;
        buffer.invLifespan[i1] = 1.0;

        expect(
          flipbook.frameRectForParticle(buffer, i0),
          const Rect.fromLTWH(0, 0, 32, 32),
        );
        expect(
          flipbook.frameRectForParticle(buffer, i1),
          const Rect.fromLTWH(32, 0, 32, 32),
        );

        final variantRenderer = VariantSpriteParticleRenderer(
          image: atlas,
          sourceRects: const [
            Rect.fromLTWH(0, 0, 32, 32),
            Rect.fromLTWH(32, 0, 32, 32),
          ],
        );
        buffer.variant[i0] = 0;
        buffer.variant[i1] = 1;
        expect(
          variantRenderer.frameRectForParticle(buffer, i0),
          const Rect.fromLTWH(0, 0, 32, 32),
        );
        expect(
          variantRenderer.frameRectForParticle(buffer, i1),
          const Rect.fromLTWH(32, 0, 32, 32),
        );
      },
    );
  });
}
