import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flame/particles.dart';
import 'package:flame/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('20,000-particle SoA batching, pooling & force-field conservation', () {
    tearDown(CircleParticleRenderer.clearTextureCache);

    test(
      'simulates 20,000 active particles across 40 pooled emitters, coalesces '
      'into minimal GPU draw calls, and conserves homing attractor arrivals',
      () async {
        final sharedRenderer = CircleParticleRenderer(softness: 0.35);
        final stretchRenderer = CircleParticleRenderer(
          softness: 0.35,
          blendMode: ui.BlendMode.plus,
        );
        await sharedRenderer.onLoad();
        await stretchRenderer.onLoad();

        var arrivedCount = 0;
        final attractor = ParticleAttractor(
          position: Vector2(0, -40),
          strength: 1800,
          arrivalRadius: 14,
          swirl: 90,
          onParticlesArrived: (n) => arrivedCount += n,
        );
        final vortex = ParticleVortex(
          center: Vector2(20, 10),
          angularAcceleration: 260,
          radialPull: 40,
          radius: 300,
        );

        final baseEmitter = ParticleEmitter(
          maxParticles: 500,
          bursts: const <EmitterBurst>[EmitterBurst(0.0, 500)],
          speed: (30, 160),
          lifespan: (4.0, 4.0),
          gravity: Vector2(0, 140),
          floorY: 120.0,
          floorRestitution: 0.65,
          fields: <ParticleForceField>[attractor, vortex],
        );

        var seedCounter = 1;
        final pool = ComponentPool<ParticleEmitterComponent>(
          maxSize: 48,
          factory: () => ParticleEmitterComponent(
            emitter: baseEmitter,
            renderer: sharedRenderer,
            random: math.Random(seedCounter++),
          ),
        );

        final pooledEmitters = <ParticleEmitterComponent>[];
        for (var i = 0; i < 39; i++) {
          final comp = pool.acquire()
            ..reconfigure(
              position: Vector2((i % 8) * 35.0 - 120.0, (i ~/ 8) * 25.0 - 50.0),
              nextEmitter: baseEmitter,
            );
          pooledEmitters.add(comp);
        }
        final stretchComp = ParticleEmitterComponent(
          position: Vector2(90, 60),
          emitter: ParticleEmitter(
            maxParticles: 500,
            bursts: const <EmitterBurst>[EmitterBurst(0.0, 500)],
            speed: (80, 200),
            lifespan: (4.0, 4.0),
            velocityStretch: 0.025,
            fields: <ParticleForceField>[vortex],
          ),
          renderer: stretchRenderer,
          random: math.Random(999),
        );

        final activeEmitters = <ParticleEmitterComponent>[
          ...pooledEmitters,
          stretchComp,
        ];
        final batchGroup = ParticleBatchGroup(children: activeEmitters);

        // Initial tick spawns all 40 * 500 = 20,000 particles!
        batchGroup.updateTree(0.001);
        var totalAlive = 0;
        for (final e in activeEmitters) {
          totalAlive += e.particleCount;
        }
        expect(totalAlive + arrivedCount, 20000);

        // Render all 20,000 particles through TelemetryCanvas:
        // 39 uniform emitters coalesce into 1 drawRawAtlas call, and 1
        // velocityStretch additive emitter batches into 1 drawVertices call!
        final telemetry = RenderFrameTelemetry()..beginRenderFrame();
        final rec = ui.PictureRecorder();
        final telCanvas = TelemetryCanvas()
          ..bind(
            ui.Canvas(rec, const ui.Rect.fromLTWH(-500, -500, 1000, 1000)),
            telemetry,
          );
        batchGroup.renderTree(telCanvas);
        telCanvas.unbind();
        telemetry.endRenderFrame();
        rec.endRecording().dispose();

        expect(batchGroup.lastAtlasDrawCalls, 1);
        expect(telemetry.atlasCalls, 1);
        expect(telemetry.verticesCalls, 1);

        // Step 30 frames including dt=0, tiny dt, and a lag spike; verify exact
        // conservation on the 39 homing emitters (500 * 39 = 19,500)!
        const dtSchedule = <double>[0.0, 1e-6, 0.016, 0.033, 0.12];
        for (var step = 0; step < 30; step++) {
          batchGroup.updateTree(dtSchedule[step % dtSchedule.length]);
        }
        var homingAlive = 0;
        for (final c in pooledEmitters) {
          homingAlive += c.particleCount;
          for (var p = 0; p < c.particleCount; p++) {
            expect(c.particles.posX[p].isFinite, isTrue);
            expect(c.particles.posY[p].isFinite, isTrue);
          }
        }
        expect(homingAlive + arrivedCount, 19500);
        expect(arrivedCount, greaterThan(1000));

        // Release all 39 pooled emitters and re-acquire: buffers are reused
        // with 0 reallocations!
        final savedBuffers = <ParticleBuffer>[
          for (final c in pooledEmitters) c.particles,
        ];
        for (final c in pooledEmitters) {
          c.removeFromParent();
          pool.release(c);
        }
        for (var i = 0; i < 39; i++) {
          final reacquired = pool.acquire();
          expect(
            savedBuffers.any((b) => identical(b, reacquired.particles)),
            isTrue,
          );
        }
      },
    );
  });

  group('128-node VerletRope2D teleport, 5k RibbonTrail & Light2D stress', () {
    test(
      '128-node VerletRope2D survives +5,000px single-frame teleport without '
      'NaN, RibbonTrailComponent wraps 5,000 points, and Light2DLayer renders '
      '32 lights x 80 shadow occluders safely',
      () {
        final rope = VerletRope2D(
          nodeCount: 128,
          start: Vector2(0, 0),
          end: Vector2(254, 0),
          constraintIterations: 20,
        );

        // Violently teleport pinned root by +5,000px in one frame, then settle!
        rope
          ..setNodePin(0, 5000, -1200)
          ..step(0.0)
          ..step(0.25);
        for (var i = 0; i < 120; i++) {
          rope.step(1 / 60);
        }

        expect(rope.posX[0], 5000.0);
        expect(rope.posY[0], -1200.0);
        final controlPts = <Vector2>[];
        for (var n = 0; n < 128; n++) {
          expect(rope.posX[n].isFinite, isTrue);
          expect(rope.posY[n].isFinite, isTrue);
          if (n % 8 == 0) {
            controlPts.add(Vector2(rope.posX[n], rope.posY[n]));
          }
        }

        final strip = SplineStripMesh2D.fromCatmullRom(
          controlPoints: controlPts,
          subdivisionsPerSegment: 4,
          startWidth: 10,
          endWidth: 3,
        );
        final recRope = ui.PictureRecorder();
        strip.render(ui.Canvas(recRope));
        recRope.endRecording().dispose();

        // Push 5,000 samples through a 64-slot RibbonTrailComponent ring!
        var cursor = Vector2.zero();
        final ribbon = RibbonTrailComponent(
          maxPoints: 64,
          lifetime: 0.4,
          minPointDistance: 2.0,
          targetProvider: () => cursor,
        );
        for (var i = 0; i < 5000; i++) {
          cursor = Vector2(i * 3.5, math.sin(i * 0.1) * 30.0);
          ribbon.update(0.005);
        }
        expect(ribbon.pointCount, 64);
        final recRibbon = ui.PictureRecorder();
        ribbon.render(ui.Canvas(recRibbon));
        recRibbon.endRecording().dispose();

        // Light2DLayer with 32 lights & 80 occluders (including degenerate
        // coincident light-on-vertex placements).
        final lightLayer = Light2DLayer(
          bounds: const ui.Rect.fromLTWH(0, 0, 1024, 1024),
        );
        for (var i = 0; i < 80; i++) {
          final ox = (i % 10) * 90.0 + 40.0;
          final oy = (i ~/ 10) * 110.0 + 40.0;
          lightLayer.occluders.add(
            i.isEven
                ? ShadowOccluder2D.rect(ui.Rect.fromLTWH(ox, oy, 28, 28))
                : ShadowOccluder2D.segment(
                    Vector2(ox, oy),
                    Vector2(ox + 32, oy + 16),
                  ),
          );
        }
        for (var l = 0; l < 32; l++) {
          final lx = (l % 8) * 110.0 + 40.0;
          final ly = (l ~/ 8) * 220.0 + 40.0;
          lightLayer.pointLights.add(
            PointLight2D(
              position: Vector2(lx, ly),
              radius: 220,
              flickerAmplitude: 0.15,
            ),
          );
        }

        lightLayer.update(0.033);
        final recLight = ui.PictureRecorder();
        lightLayer.render(ui.Canvas(recLight));
        recLight.endRecording().dispose();

        expect(lightLayer.lastRenderedLights, 32);
        expect(lightLayer.lastShadowQuads, greaterThan(100));
      },
    );
  });
}
