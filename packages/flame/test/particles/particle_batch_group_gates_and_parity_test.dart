import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flame/particles.dart';
import 'package:flame/post_process.dart';
import 'package:flame_test/flame_test.dart';
import 'package:flutter_test/flutter_test.dart';

/// Rasterizes only an exclusive emissive-mask auxiliary pass, the way a
/// dual-pass bloom post process does for its second texture.
class _MaskOnlyPostProcess() extends PostProcess {
  this : super(pixelRatio: 1.0);

  @override
  void postProcess(Vector2 size, Canvas canvas) {
    rasterizePass(
      resolutionScale: 0.25,
      passTag: 'mask',
      cameraRenderPass: RenderPass.emissiveMask,
    ).dispose();
  }
}

ParticleEmitterComponent _burst(
  ParticleRenderer renderer, {
  int? cameraMask,
  Vector2? scale,
  double velocityStretch = 0,
}) {
  final emitter = ParticleEmitterComponent(
    scale: scale,
    emitter: ParticleEmitter(
      maxParticles: 16,
      bursts: const <EmitterBurst>[EmitterBurst(0, 10)],
      lifespan: (5, 5),
      speed: (40, 40),
      velocityStretch: velocityStretch,
    ),
    renderer: renderer,
    removeOnFinish: false,
    random: Random(1),
  );
  if (cameraMask != null) {
    emitter.cameraMask = cameraMask;
  }
  return emitter;
}

/// Renders [component] the way a camera pass would and returns the number of
/// `drawRawAtlas` and `drawVertices` calls it issued.
(int, int) _countDraws(Component component, {RenderPass? pass}) {
  final telemetry = RenderFrameTelemetry()..beginRenderFrame();
  final recorder = PictureRecorder();
  final canvas = TelemetryCanvas()..bind(Canvas(recorder), telemetry);
  if (pass != null) {
    CameraComponent.pushRenderPass(pass);
  }
  try {
    component.renderTree(canvas);
  } finally {
    if (pass != null) {
      CameraComponent.popRenderPass();
    }
    canvas.unbind();
  }
  telemetry.endRenderFrame();
  recorder.endRecording().dispose();
  return (telemetry.atlasCalls, telemetry.verticesCalls);
}

/// The number of `drawRawAtlas` calls of one whole game frame.
int _atlasCallsOfFrame(FlameGame game) {
  final telemetry = RenderFrameTelemetry()..beginRenderFrame();
  final recorder = PictureRecorder();
  final canvas = TelemetryCanvas()..bind(Canvas(recorder), telemetry);
  game.render(canvas);
  canvas.unbind();
  telemetry.endRenderFrame();
  recorder.endRecording().dispose();
  return telemetry.atlasCalls;
}

Image _whiteImage(int w, int h) {
  final recorder = PictureRecorder();
  Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    Paint()..color = const Color(0xFFFFFFFF),
  );
  final picture = recorder.endRecording();
  try {
    return picture.toImageSync(w, h);
  } finally {
    picture.dispose();
  }
}

Future<int> _alphaAt(int x, int y, void Function(Canvas canvas) paint) async {
  final recorder = PictureRecorder();
  paint(Canvas(recorder));
  final picture = recorder.endRecording();
  final image = picture.toImageSync(32, 32);
  picture.dispose();
  try {
    final bytes = (await image.toByteData())!;
    return bytes.getUint8((y * 32 + x) * 4 + 3);
  } finally {
    image.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(CircleParticleRenderer.clearTextureCache);

  group('ParticleBatchGroup render gates', () {
    test('merged particles are left out of an exclusive render pass', () {
      final shared = CircleParticleRenderer()..onLoad();
      final group = ParticleBatchGroup(
        children: [_burst(shared)..update(0.016)],
      );

      expect(_countDraws(group), (1, 0));
      expect(group.lastAtlasDrawCalls, 1);
      expect(group.lastBatchedEmitterCount, 1);

      expect(_countDraws(group, pass: RenderPass.emissiveMask), (0, 0));
      // The skipped pass does not overwrite the figures of the real one.
      expect(group.lastAtlasDrawCalls, 1);
      expect(group.lastBatchedEmitterCount, 1);

      // A pass that is not exclusive draws the particles as usual.
      expect(_countDraws(group, pass: RenderPass.translucent), (1, 0));
    });

    test('stretched particles are left out of an exclusive pass too', () {
      final shared = CircleParticleRenderer()..onLoad();
      final group = ParticleBatchGroup(
        children: [_burst(shared, velocityStretch: 0.05)..update(0.016)],
      );

      expect(_countDraws(group), (0, 1));
      expect(_countDraws(group, pass: RenderPass.emissiveMask), (0, 0));
    });

    test('an exclusive pass still reaches multi-pass children', () {
      final shared = CircleParticleRenderer()..onLoad();
      final glow = _GlowComponent();
      final group = ParticleBatchGroup(
        children: [_burst(shared)..update(0.016), glow],
      );

      expect(_countDraws(group, pass: RenderPass.emissiveMask), (0, 0));
      expect(glow.passes, ['emissiveMask']);
    });

    testWithFlameGame(
      'a dual-pass post process gets no merged particles in its mask',
      (game) async {
        game.onGameResize(Vector2(200, 200));

        var standaloneDraws = 0;
        final standalone = _burst(
          CallbackParticleRenderer((_, _) => standaloneDraws++),
        );
        final shared = CircleParticleRenderer();
        await shared.onLoad();
        final group = ParticleBatchGroup(children: [_burst(shared)]);

        await game.world.ensureAddAll([standalone, group]);
        game.camera.postProcess = _MaskOnlyPostProcess();
        await game.ready();
        game.update(0.016);

        final recorder = PictureRecorder();
        game.render(Canvas(recorder));
        recorder.endRecording().dispose();

        expect(standaloneDraws, 0);
        expect(group.lastAtlasDrawCalls + group.lastQuadBatchDrawCalls, 0);
        expect(group.lastBatchedEmitterCount, 0);
      },
    );

    testWithFlameGame(
      'a group hidden from the camera by its cameraMask draws nothing',
      (game) async {
        game.onGameResize(Vector2(200, 200));
        final shared = CircleParticleRenderer();
        await shared.onLoad();
        final group = ParticleBatchGroup(children: [_burst(shared)]);
        await game.world.ensureAdd(group);
        await game.ready();
        game.update(0.016);

        expect(_atlasCallsOfFrame(game), 1);

        group.cameraMask = 0x2;
        game.camera.cameraMask = 0x1;
        expect(_atlasCallsOfFrame(game), 0);

        game.camera.cameraMask = 0x3;
        expect(_atlasCallsOfFrame(game), 1);
      },
    );

    testWithFlameGame(
      'a merged emitter hidden from the camera by its cameraMask is skipped',
      (game) async {
        game.onGameResize(Vector2(200, 200));
        final shared = CircleParticleRenderer();
        await shared.onLoad();
        final hidden = _burst(shared, cameraMask: 0x2);
        final container = PositionComponent(
          children: [_burst(shared)],
        )..cameraMask = 0x2;
        final group = ParticleBatchGroup(children: [hidden, container]);
        var standaloneDraws = 0;
        final standalone = _burst(
          CallbackParticleRenderer((_, _) => standaloneDraws++),
          cameraMask: 0x2,
        );
        game.camera.cameraMask = 0x1;

        await game.world.ensureAddAll([group, standalone]);
        await game.ready();
        game.update(0.016);

        expect(_atlasCallsOfFrame(game), 0);
        expect(standaloneDraws, 0);
        expect(group.lastBatchedEmitterCount, 0);

        // With a camera that sees them, both emitters share one draw call.
        game.camera.cameraMask = 0x3;
        expect(_atlasCallsOfFrame(game), 1);
        expect(group.lastBatchedEmitterCount, 2);
      },
    );

    testWithFlameGame(
      'a group below its minQualityTier draws nothing',
      (game) async {
        game.onGameResize(Vector2(200, 200));
        final shared = CircleParticleRenderer();
        await shared.onLoad();
        final group = ParticleBatchGroup(children: [_burst(shared)]);
        await game.world.ensureAdd(group);
        await game.ready();
        game.update(0.016);
        expect(_atlasCallsOfFrame(game), 1);

        group.minQualityTier = GraphicsQualityTier.ultra;
        game.graphics.setTier(GraphicsQualityTier.low);
        expect(_atlasCallsOfFrame(game), 0);
      },
    );

    test('a nested group with batching switched off renders by itself', () {
      final shared = CircleParticleRenderer()..onLoad();
      final inner = ParticleBatchGroup(
        batchingEnabled: false,
        children: [
          _burst(shared)..update(0.016),
          _burst(shared)..update(0.016),
        ],
      );
      final outer = ParticleBatchGroup(children: [inner]);

      // Not merged by the outer group: each emitter issues its own call.
      expect(_countDraws(outer), (2, 0));
      expect(outer.lastBatchedEmitterCount, 0);

      inner.batchingEnabled = true;
      expect(_countDraws(outer), (1, 0));
      expect(outer.lastBatchedEmitterCount, 2);
    });
  });

  group('Texture particle draw paths agree', () {
    test(
      'a non-square sprite has the same size on the atlas and quad path',
      () {
        final image = _whiteImage(32, 8);
        addTearDown(image.dispose);
        final renderer = SpriteParticleRenderer.fromImage(image);

        final particles = ParticleBuffer(1);
        final i = particles.spawn();
        particles.posX[i] = 0;
        particles.posY[i] = 0;
        particles.size[i] = 16;
        particles.rotation[i] = 0;
        particles.stretch[i] = 1;
        particles.color[i] = 0xffffffff;

        final transforms = Float32List(4);
        renderer.appendToSharedAtlas(
          particles: particles,
          outTransforms: transforms,
          outRects: Float32List(4),
          outColors: Int32List(1),
          startSlot: 0,
          offsetX: 0,
          offsetY: 0,
          cosA: 1,
          sinA: 0,
          uniformScale: 1,
        );
        // The sprite's width equals the particle size on the atlas path.
        expect(transforms[0] * 32, closeTo(16, 1e-4));
        expect(transforms[0] * 8, closeTo(4, 1e-4));

        Float32List quad() {
          final positions = Float32List(8);
          renderer.appendToSharedQuads(
            particles: particles,
            startParticle: 0,
            particleCount: 1,
            outPositions: positions,
            outUvs: Float32List(8),
            outColors: Int32List(4),
            startQuadSlot: 0,
            m00: 1,
            m01: 0,
            m10: 0,
            m11: 1,
            tx: 0,
            ty: 0,
          );
          return positions;
        }

        final unstretched = quad();
        expect(unstretched[2] - unstretched[0], closeTo(16, 1e-4));
        expect(unstretched[7] - unstretched[1], closeTo(4, 1e-4));

        // Stretch lengthens the sprite along its width only.
        particles.stretch[i] = 2.5;
        final stretched = quad();
        expect(stretched[2] - stretched[0], closeTo(40, 1e-4));
        expect(stretched[7] - stretched[1], closeTo(4, 1e-4));
      },
    );

    test(
      'a translucent renderer paint stays translucent when merged',
      () async {
        ParticleEmitterComponent build({Vector2? scale}) {
          final renderer = CircleParticleRenderer(
            paint: Paint()..color = const Color(0x40FFFFFF),
          )..onLoad();
          return ParticleEmitterComponent(
            position: Vector2(16, 16),
            scale: scale,
            emitter: ParticleEmitter(
              maxParticles: 1,
              bursts: const <EmitterBurst>[EmitterBurst(0, 1)],
              lifespan: (10, 10),
              size: (28, 28),
            ),
            renderer: renderer,
            removeOnFinish: false,
            random: Random(1),
          )..update(0.016);
        }

        final standaloneAlpha = await _alphaAt(16, 16, build().renderTree);
        expect(standaloneAlpha, closeTo(0x40, 2));

        final atlasGroup = ParticleBatchGroup(children: [build()]);
        final atlasAlpha = await _alphaAt(16, 16, atlasGroup.renderTree);
        expect(atlasGroup.lastAtlasDrawCalls, 1);
        expect(atlasAlpha, closeTo(standaloneAlpha, 2));

        // A non-uniform scale sends the emitter down the shared quad path.
        final quadGroup = ParticleBatchGroup(
          children: [build(scale: Vector2(1.2, 0.9))],
        );
        final quadAlpha = await _alphaAt(16, 16, quadGroup.renderTree);
        expect(quadGroup.lastQuadBatchDrawCalls, 1);
        expect(quadAlpha, closeTo(standaloneAlpha, 2));
      },
    );

    test('emitters whose paints differ in opacity are not merged', () {
      final opaque = CircleParticleRenderer()..onLoad();
      final faint = CircleParticleRenderer(
        paint: Paint()..color = const Color(0x40FFFFFF),
      )..onLoad();
      final group = ParticleBatchGroup(
        children: [
          _burst(opaque)..update(0.016),
          _burst(faint)..update(0.016),
          _burst(faint)..update(0.016),
        ],
      );

      expect(_countDraws(group), (2, 0));
      expect(group.lastBatchedEmitterCount, 3);
    });

    test('a paint with a mask filter keeps its emitter out of the batch', () {
      final blurred = CircleParticleRenderer(
        paint: Paint()..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
      )..onLoad();
      final group = ParticleBatchGroup(
        children: [_burst(blurred)..update(0.016)],
      );

      expect(_countDraws(group), (1, 0));
      expect(group.lastBatchedEmitterCount, 0);
    });

    test('more stretched particles than one draw call holds are all drawn', () {
      const count = 16383 + 17;
      final renderer = CircleParticleRenderer()..onLoad();
      final particles = ParticleBuffer(count);
      for (var n = 0; n < count; n++) {
        final i = particles.spawn();
        particles.size[i] = 4;
        particles.stretch[i] = 2;
        particles.color[i] = 0xffffffff;
      }
      particles.hasStretch = true;

      final telemetry = RenderFrameTelemetry()..beginRenderFrame();
      final recorder = PictureRecorder();
      final canvas = TelemetryCanvas()..bind(Canvas(recorder), telemetry);
      renderer.render(canvas, particles);
      canvas.unbind();
      telemetry.endRenderFrame();
      recorder.endRecording().dispose();

      expect(telemetry.verticesCalls, 2);
    });
  });
}

class _GlowComponent() extends Component with MultiPassComponent {
  final List<String> passes = [];

  @override
  Set<RenderPass> get activeRenderPasses => const {RenderPass.emissiveMask};

  @override
  void renderPass(Canvas canvas, RenderPass pass) => passes.add(pass.name);
}
