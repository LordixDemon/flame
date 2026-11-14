import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/canvas3d.dart';
import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flame/particles.dart';
import 'package:flame/post_process.dart';
import 'package:flame/rendering.dart';
import 'package:flame/text.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show MouseCursor, MouseRegion;
import 'package:flutter_test/flutter_test.dart';

class _ContextSpyComponent() extends PositionComponent {
  final List<(PostProcess?, Object?)> observedPasses =
      <(PostProcess?, Object?)>[];

  @override
  void render(ui.Canvas canvas) {
    final active = findPostProcessFromContext();
    observedPasses.add((active, active?.currentPassTag));
    canvas.drawRect(
      const ui.Rect.fromLTWH(0, 0, 80, 80),
      ui.Paint()..color = const ui.Color(0xFF4090E0),
    );
  }
}

class _TaggedMultiPassPostProcess({super.pixelRatio}) extends PostProcess {
  @override
  void postProcess(Vector2 size, ui.Canvas canvas) {
    final mask = rasterizePass(passTag: 'emissive_mask');
    mask.dispose();
    renderSubtree(canvas);
  }
}

class _CustomTransparentHudBox({
  super.position,
  super.angle,
  super.children,
}) extends PositionComponent with BatchTransparentContainer;

class _PaintBoxComponent() extends PositionComponent with HasPaint;

Future<ui.Image> _makeSolidImage(int w, int h, ui.Color color) async {
  final rec = ui.PictureRecorder();
  final canvas = ui.Canvas(rec);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    ui.Paint()..color = color,
  );
  final pic = rec.endRecording();
  try {
    return pic.toImageSync(w, h);
  } finally {
    pic.dispose();
  }
}

Future<ByteData> _rasterizeRgba(
  int width,
  int height,
  void Function(ui.Canvas canvas) paint,
) async {
  final rec = ui.PictureRecorder();
  final canvas = ui.Canvas(rec);
  paint(canvas);
  final pic = rec.endRecording();
  final img = pic.toImageSync(width, height);
  pic.dispose();
  try {
    final bytes = await img.toByteData();
    return bytes!;
  } finally {
    img.dispose();
  }
}

void main() {
  group('Wave 6 — PostProcessPipeline Chaining/Folding, Universal '
      'ParticleBatchGroup & Zero-Rebuild Cursor / Dirty Auto-Wakeup', () {
    test(
      'Unlock #5a: PostProcessPipeline & PostProcessSequentialGroup propagate '
      'inner PostProcess context and currentPassTag to world components',
      () async {
        final spy = _ContextSpyComponent();
        final taggedStage = _TaggedMultiPassPostProcess(pixelRatio: 1.0);
        final gradeStage = ColorGradingPostProcess(
          preset: ColorGradingPreset.warmSunset,
          pixelRatio: 1.0,
        );

        final pipeline = PostProcessPipeline(
          pixelRatio: 1.0,
          stages: [
            PostProcessStage(name: 'tagged', postProcess: taggedStage),
            PostProcessStage(name: 'grade', postProcess: gradeStage),
          ],
        );

        final world = World(children: [spy]);
        final camera = CameraComponent.withFixedResolution(
          world: world,
          width: 80,
          height: 80,
        )..postProcess = pipeline;
        final game = FlameGame(world: world, camera: camera);
        game.onGameResize(Vector2(80, 80));
        await game.start();
        await game.ready();
        game.update(1 / 60);

        final rec = ui.PictureRecorder();
        game.render(ui.Canvas(rec));
        rec.endRecording().dispose();

        // spy rendered twice inside taggedStage:
        // 1) rasterizePass('emissive_mask') -> (taggedStage, 'emissive_mask')
        // 2) renderSubtree(canvas) -> (taggedStage, null)
        expect(spy.observedPasses.length, 2);
        expect(spy.observedPasses[0].$1, same(taggedStage));
        expect(spy.observedPasses[0].$2, 'emissive_mask');
        expect(spy.observedPasses[1].$1, same(taggedStage));
        expect(spy.observedPasses[1].$2, isNull);

        // Verify PostProcessSequentialGroup also propagates inner stage context
        spy.observedPasses.clear();
        camera.postProcess = PostProcessSequentialGroup(
          postProcesses: [taggedStage, gradeStage],
        );
        final recSeq = ui.PictureRecorder();
        game.render(ui.Canvas(recSeq));
        recSeq.endRecording().dispose();

        expect(spy.observedPasses.length, 2);
        expect(spy.observedPasses[0].$1, same(taggedStage));
        expect(spy.observedPasses[0].$2, 'emissive_mask');
        expect(spy.observedPasses[1].$1, same(taggedStage));
        expect(spy.observedPasses[1].$2, isNull);
      },
    );

    test(
      'Unlock #5b: PostProcessPipeline chains ui.Image inputs, folds '
      'consecutive ColorGradingPostProcess 4x5 matrices, and auto-bypasses '
      'zero-intensity no-op stages',
      () async {
        final bloom = BloomPostProcess(
          intensity: 0.75,
          threshold: 0.4,
          sigma: 4.0,
          pixelRatio: 1.0,
        );
        final gradeWarm = ColorGradingPostProcess(
          preset: ColorGradingPreset.warmSunset,
          exposure: 0.25,
          temperature: 0.2,
          pixelRatio: 1.0,
        );
        final gradePop = ColorGradingPostProcess(
          preset: ColorGradingPreset.vibrantPop,
          contrast: 1.15,
          saturation: 1.2,
          pixelRatio: 1.0,
        );
        final vignette = VignettePostProcess(
          intensity: 0.5,
          pixelRatio: 1.0,
        );

        final pipeline = PostProcessPipeline(
          pixelRatio: 1.0,
          stages: [
            PostProcessStage(name: 'bloom', postProcess: bloom),
            PostProcessStage(name: 'gradeWarm', postProcess: gradeWarm),
            PostProcessStage(name: 'gradePop', postProcess: gradePop),
            PostProcessStage(name: 'vignette', postProcess: vignette),
          ],
        );

        final comp = PostProcessComponent(
          postProcess: pipeline,
          size: Vector2(64, 64),
          children: [
            RectangleComponent(
              size: Vector2(64, 64),
              paint: ui.Paint()..color = const ui.Color(0xFFD09050),
            ),
          ],
        );
        final game = FlameGame(children: [comp]);
        game.onGameResize(Vector2(64, 64));
        await game.start();
        await game.ready();

        final rec1 = ui.PictureRecorder();
        game.render(ui.Canvas(rec1));
        rec1.endRecording().dispose();

        // 4 active stages; 2 consecutive ColorGrading stages folded into 1 op;
        // ONLY 1 offscreen Picture.toImageSync allocation (from Bloom)!
        expect(pipeline.lastActiveStageCount, 4);
        expect(pipeline.lastFoldedColorGradingCount, 1);
        expect(pipeline.lastSkippedNoOpStageCount, 0);
        expect(pipeline.bypassedLastFrame, isFalse);
        expect(pipeline.lastRasterizedImageCount, 1);

        // Direct renderFromImage consumes pre-rasterized GPU image with ZERO
        // offscreen rasterizations! Use an unclipped midtone (0xFF706050) so
        // intermediate 8-bit saveLayer does not saturate at 255.
        final srcImg = await _makeSolidImage(
          64,
          64,
          const ui.Color(0xFF706050),
        );
        try {
          final recImg = ui.PictureRecorder();
          final handled = pipeline.renderFromImage(
            srcImg,
            Vector2(64, 64),
            ui.Canvas(recImg),
          );
          recImg.endRecording().dispose();
          expect(handled, isTrue);
          expect(pipeline.lastRasterizedImageCount, 0);
          expect(pipeline.lastFoldedColorGradingCount, 1);

          // Verify pixel-level mathematical equivalence of 4x5 matrix folding:
          // sequential saveLayer(gradePop) -> saveLayer(gradeWarm) vs single
          // ColorGradingPostProcess.concatColorMatrices(pop, warm)!
          final mWarm = gradeWarm.computeColorMatrix();
          final mPop = gradePop.computeColorMatrix();
          final mFolded = ColorGradingPostProcess.concatColorMatrices(
            mPop,
            mWarm,
          );

          final seqBytes = await _rasterizeRgba(16, 16, (canvas) {
            canvas.saveLayer(
              const ui.Rect.fromLTWH(0, 0, 16, 16),
              ui.Paint()..colorFilter = ui.ColorFilter.matrix(mPop),
            );
            canvas.saveLayer(
              const ui.Rect.fromLTWH(0, 0, 16, 16),
              ui.Paint()..colorFilter = ui.ColorFilter.matrix(mWarm),
            );
            canvas.drawImage(srcImg, ui.Offset.zero, ui.Paint());
            canvas
              ..restore()
              ..restore();
          });

          final foldedBytes = await _rasterizeRgba(16, 16, (canvas) {
            canvas.drawImage(
              srcImg,
              ui.Offset.zero,
              ui.Paint()..colorFilter = ui.ColorFilter.matrix(mFolded),
            );
          });

          for (var c = 0; c < 4; c++) {
            expect(
              (foldedBytes.getUint8(c) - seqBytes.getUint8(c)).abs(),
              lessThanOrEqualTo(2),
            );
          }
        } finally {
          srcImg.dispose();
        }

        // Set all stages to zero-intensity / neutral identity while leaving
        // stage.enabled = true (except gradePop disabled): pipeline must skip
        // all 3 no-op stages and bypass rasterization completely!
        bloom.intensity = 0.0;
        gradeWarm
          ..preset = ColorGradingPreset.neutral
          ..exposure = 0.0
          ..contrast = 1.0
          ..saturation = 1.0
          ..temperature = 0.0;
        gradePop.enabled = false;
        vignette.intensity = 0.0;

        final recNoOp = ui.PictureRecorder();
        game.render(ui.Canvas(recNoOp));
        recNoOp.endRecording().dispose();

        expect(pipeline.lastSkippedNoOpStageCount, 4);
        expect(pipeline.lastActiveStageCount, 0);
        expect(pipeline.bypassedLastFrame, isTrue);
        expect(pipeline.lastRasterizedImageCount, 0);

        pipeline.dispose();
      },
    );

    test(
      'Unlock #7: ParticleBatchGroup coalesces arbitrary Anchor, angle, '
      'nested containers into 1 drawRawAtlas with pixel parity, and batches '
      'velocityStretch / non-uniform scale into 1 quad drawVertices call',
      () async {
        ParticleBatchGroup buildTestParticleHierarchy({required bool batched}) {
          ParticleEmitter preset(int count) => ParticleEmitter(
            maxParticles: count,
            bursts: [EmitterBurst(0.0, count)],
            lifespan: (2.0, 2.0),
            speed: (24.0, 24.0),
            size: (12.0, 12.0),
          );

          final e1 = ParticleEmitterComponent(
            emitter: preset(6),
            renderer: CircleParticleRenderer(),
            random: Random(101),
            position: Vector2(45, 45),
            size: Vector2(30, 30),
            anchor: Anchor.center,
            angle: 0.55,
            scale: Vector2.all(1.25),
            removeOnFinish: false,
          );
          final e2 = ParticleEmitterComponent(
            emitter: preset(6),
            renderer: CircleParticleRenderer(),
            random: Random(202),
            position: Vector2(115, 50),
            size: Vector2(24, 36),
            anchor: Anchor.bottomRight,
            angle: -0.4,
            removeOnFinish: false,
          );
          final nestedPosContainer = PositionComponent(
            position: Vector2(50, 115),
            angle: 0.35,
            scale: Vector2.all(1.1),
            children: [
              ParticleEmitterComponent(
                emitter: preset(5),
                renderer: CircleParticleRenderer(),
                random: Random(303),
                position: Vector2(6, -4),
                size: Vector2.all(16),
                anchor: Anchor.center,
                removeOnFinish: false,
              ),
            ],
          );
          final nestedTransparentHud = _CustomTransparentHudBox(
            position: Vector2(115, 115),
            angle: -0.25,
            children: [
              ParticleEmitterComponent(
                emitter: preset(5),
                renderer: CircleParticleRenderer(),
                random: Random(404),
                size: Vector2.all(20),
                anchor: Anchor.topRight,
                removeOnFinish: false,
              ),
            ],
          );

          return ParticleBatchGroup(
            batchingEnabled: batched,
            children: [e1, e2, nestedPosContainer, nestedTransparentHud],
          );
        }

        final batchedGroup = buildTestParticleHierarchy(batched: true);
        final unbatchedGroup = buildTestParticleHierarchy(batched: false);

        final gameBatched = FlameGame(children: [batchedGroup])
          ..onGameResize(Vector2(160, 160));
        final gameUnbatched = FlameGame(children: [unbatchedGroup])
          ..onGameResize(Vector2(160, 160));
        await gameBatched.start();
        await gameUnbatched.start();
        await gameBatched.ready();
        await gameUnbatched.ready();

        gameBatched.update(0.05);
        gameUnbatched.update(0.05);

        final rgbaBatched = await _rasterizeRgba(
          160,
          160,
          batchedGroup.renderTree,
        );
        final rgbaUnbatched = await _rasterizeRgba(
          160,
          160,
          unbatchedGroup.renderTree,
        );

        // All 4 transformed/anchored/nested emitters MUST merge into a SINGLE
        // drawRawAtlas call!
        expect(batchedGroup.lastBatchedEmitterCount, 4);
        expect(batchedGroup.lastAtlasDrawCalls, 1);
        expect(batchedGroup.lastQuadBatchDrawCalls, 0);

        var litPixelsBatched = 0;
        var litPixelsUnbatched = 0;
        var maxChannelDiff = 0;
        for (var i = 0; i < 160 * 160 * 4; i += 4) {
          final aB = rgbaBatched.getUint8(i + 3);
          final aU = rgbaUnbatched.getUint8(i + 3);
          if (aB > 16) {
            litPixelsBatched++;
          }
          if (aU > 16) {
            litPixelsUnbatched++;
          }
          final diff = (aB - aU).abs();
          if (diff > maxChannelDiff) {
            maxChannelDiff = diff;
          }
        }
        expect(litPixelsBatched, greaterThan(200));
        // Batched vs unbatched lit pixel count & alpha match closely!
        expect(
          (litPixelsBatched - litPixelsUnbatched).abs(),
          lessThan(litPixelsUnbatched * 0.05 + 4),
        );
        expect(maxChannelDiff, lessThanOrEqualTo(16));

        // Now verify velocityStretch > 0 + non-uniform scale emitters coalesce
        // into 1 shared Vertices.raw quad draw call!
        final stretchPreset = ParticleEmitter(
          maxParticles: 8,
          bursts: const [EmitterBurst(0.0, 8)],
          lifespan: (2.0, 2.0),
          speed: (180.0, 180.0),
          size: (10.0, 10.0),
          velocityStretch: 0.03,
        );
        final quadGroup = ParticleBatchGroup(
          children: [
            ParticleEmitterComponent(
              emitter: stretchPreset,
              renderer: CircleParticleRenderer(),
              random: Random(11),
              position: Vector2(40, 80),
              anchor: Anchor.center,
              size: Vector2.all(20),
              removeOnFinish: false,
            ),
            ParticleEmitterComponent(
              emitter: stretchPreset,
              renderer: CircleParticleRenderer(),
              random: Random(22),
              position: Vector2(90, 80),
              angle: 0.7,
              removeOnFinish: false,
            ),
            // Non-uniform scale (2.0, 0.5) also routes into the shared quad
            // batch!
            ParticleEmitterComponent(
              emitter: ParticleEmitter(
                maxParticles: 6,
                bursts: const [EmitterBurst(0.0, 6)],
                lifespan: (2.0, 2.0),
                size: (10.0, 10.0),
              ),
              renderer: CircleParticleRenderer(),
              random: Random(33),
              position: Vector2(130, 80),
              scale: Vector2(2.0, 0.5),
              removeOnFinish: false,
            ),
          ],
        );
        final gameQuad = FlameGame(children: [quadGroup])
          ..onGameResize(Vector2(160, 160));
        await gameQuad.start();
        await gameQuad.ready();
        gameQuad.update(0.04);

        final rgbaQuad = await _rasterizeRgba(
          160,
          160,
          quadGroup.renderTree,
        );
        expect(quadGroup.lastBatchedEmitterCount, 3);
        expect(quadGroup.lastAtlasDrawCalls, 0);
        expect(quadGroup.lastQuadBatchDrawCalls, 1);

        var quadLit = 0;
        for (var i = 3; i < rgbaQuad.lengthInBytes; i += 4) {
          if (rgbaQuad.getUint8(i) > 16) {
            quadLit++;
          }
        }
        expect(quadLit, greaterThan(100));
      },
    );

    testWidgets(
      'Unlock #8a: Game.mouseCursorListenable updates MouseRegion with 0 '
      'GameWidgetState rebuilds and handles resize-phase mutations safely',
      (tester) async {
        final game = FlameGame();
        await tester.pumpWidget(
          GameWidget(
            game: game,
            mouseCursor: SystemMouseCursors.basic,
          ),
        );
        await tester.pump();

        final state = tester.state<GameWidgetState<FlameGame>>(
          find.byType(GameWidget<FlameGame>),
        );
        final baselineBuilds = state.debugBuildCount;

        const cursors = <MouseCursor>[
          SystemMouseCursors.click,
          SystemMouseCursors.grab,
          SystemMouseCursors.grabbing,
          SystemMouseCursors.precise,
          SystemMouseCursors.move,
          SystemMouseCursors.forbidden,
        ];

        for (var i = 0; i < 30; i++) {
          final next = cursors[i % cursors.length];
          game.mouseCursor = next;
          await tester.pump();

          final mouseRegion = tester.widget<MouseRegion>(
            find.byWidgetPredicate(
              (w) => w is MouseRegion && w.cursor == next,
            ),
          );
          expect(mouseRegion.cursor, next);
        }

        // Zero GameWidgetState rebuilds across 30 cursor updates!
        expect(state.debugBuildCount, baselineBuilds);
      },
    );

    test(
      'Unlock #8b: Game.visualMutationCount wakes IdleRenderMode.onDemand '
      'automatically across particles, 3D particles, sprite ticker, HasPaint, '
      'animated RichBatchedTextComponent, RibbonTrail, VerletRope2D & Node3D',
      () async {
        final fontAtlas = RasterFontAtlas.bake(
          style: const TextStyle(fontSize: 14),
          pixelRatio: 1.0,
        );
        final spriteImg = await _makeSolidImage(
          32,
          16,
          const ui.Color(0xFFFFFFFF),
        );

        try {
          final game = FlameGame()
            ..idleRenderMode = IdleRenderMode.onDemand
            ..onGameResize(Vector2(200, 200));
          await game.start();
          await game.ready();
          game.update(1 / 60);

          final recInit = ui.PictureRecorder();
          game.render(ui.Canvas(recInit));
          recInit.endRecording().dispose();
          game.onFrameRendered();

          // Calm scene -> skips paint!
          expect(game.shouldRenderThisTick(1 / 60), isFalse);
          expect(game.skippedCleanPaints, 1);

          void assertWakesAndResets(void Function() mutate, String reason) {
            final before = Game.visualMutationCount;
            mutate();
            expect(
              Game.visualMutationCount,
              greaterThan(before),
              reason: '$reason should increment Game.visualMutationCount',
            );
            expect(
              game.shouldRenderThisTick(1 / 60),
              isTrue,
              reason: '$reason should wake IdleRenderMode.onDemand',
            );
            game.onFrameRendered();
            expect(
              game.shouldRenderThisTick(1 / 60),
              isFalse,
              reason: 'Clean tick after $reason should skip paint again',
            );
          }

          // 1. 2D ParticleEmitterComponent simulation step
          final emitterComp = ParticleEmitterComponent(
            emitter: ParticleEmitter(
              maxParticles: 4,
              bursts: const [EmitterBurst(0.0, 4)],
              speed: (20.0, 20.0),
            ),
            renderer: CircleParticleRenderer(),
            removeOnFinish: false,
          );
          game.add(emitterComp);
          await game.ready();
          game.onFrameRendered();
          assertWakesAndResets(
            () => emitterComp.update(1 / 60),
            'ParticleEmitterComponent.update',
          );

          // 2. 3D ParticlePool3D spawn & update
          final pool3d = ParticlePool3D(capacity: 16);
          assertWakesAndResets(
            () => pool3d.spawn(
              x: 0,
              y: 0,
              vx: 1,
              vy: 0,
              vz: 2,
              color: const ui.Color(0xFFFFD54F),
            ),
            'ParticlePool3D.spawn',
          );
          assertWakesAndResets(
            () => pool3d.update(1 / 60),
            'ParticlePool3D.update',
          );

          // 3. SpriteAnimationTicker frame advance
          final anim = SpriteAnimation.fromFrameData(
            spriteImg,
            SpriteAnimationData.sequenced(
              amount: 2,
              stepTime: 0.1,
              textureSize: Vector2(16, 16),
            ),
          );
          final ticker = anim.createTicker();
          // Sub-frame advance within frame 0 stays calm; crossing 0.1s advances
          // currentIndex 0 -> 1 and notifies visual mutation!
          final mutBeforeSubFrame = Game.visualMutationCount;
          ticker.update(0.04);
          expect(Game.visualMutationCount, mutBeforeSubFrame);
          assertWakesAndResets(
            () => ticker.update(0.08),
            'SpriteAnimationTicker frame boundary advance',
          );

          // 4. HasPaint opacity & tint mutations
          final paintBox = _PaintBoxComponent();
          assertWakesAndResets(
            () => paintBox.opacity = 0.6,
            'HasPaint.opacity',
          );
          assertWakesAndResets(
            () => paintBox.tint(const ui.Color(0x88FF0000)),
            'HasPaint.tint',
          );

          // 5. RichBatchedTextComponent: static text stays calm, <wave> wakes!
          final staticRich = RichBatchedTextComponent(
            atlas: fontAtlas,
            markup: 'STATIC',
          );
          final mutBeforeStaticRich = Game.visualMutationCount;
          staticRich.update(1 / 60);
          expect(Game.visualMutationCount, mutBeforeStaticRich);

          final waveRich = RichBatchedTextComponent(
            atlas: fontAtlas,
            markup: '<wave>WAVE</wave>',
          );
          game.onFrameRendered();
          assertWakesAndResets(
            () => waveRich.update(1 / 60),
            'RichBatchedTextComponent <wave> update',
          );

          // 6. RibbonTrailComponent point addition & aging
          final ribbon = RibbonTrailComponent()
            ..addPointXY(0, 0, force: true)
            ..addPointXY(20, 10, force: true);
          game.onFrameRendered();
          assertWakesAndResets(
            () => ribbon.update(1 / 60),
            'RibbonTrailComponent.update',
          );

          // 7. VerletRope2D physics step
          final rope = VerletRope2D(
            nodeCount: 5,
            start: Vector2(0, 0),
            end: Vector2(40, 0),
          );
          assertWakesAndResets(
            () => rope.step(1 / 60),
            'VerletRope2D.step',
          );

          // 8. Node3D, MorphMeshWorkspace3D, SkinnedMeshWorkspace3D &
          //    StaticMeshChunk3D mutations
          final node3d = Node3D(name: 'prop');
          assertWakesAndResets(
            () => node3d.setLocalQuaternion(0, 0, 0.7071, 0.7071),
            'Node3D.setLocalQuaternion',
          );

          final cube = Mesh3D.box();
          final morphWs = MorphMeshWorkspace3D(
            baseMesh: cube,
            targets: [
              MorphTarget3D(
                name: 'pop',
                positionDeltas: Float32List(cube.positions.length)..[2] = 0.5,
              ),
            ],
          );
          assertWakesAndResets(
            () => morphWs.setWeight(0, 0.75),
            'MorphMeshWorkspace3D.setWeight',
          );

          final skinWs = SkinnedMeshWorkspace3D(
            baseMesh: cube,
            bones: [Bone3D(name: 'root')],
            boneIndices0: Uint16List(cube.vertexCount),
          );
          assertWakesAndResets(
            () => skinWs.setBonePose(0, qz: 0.3827, qw: 0.9239),
            'SkinnedMeshWorkspace3D.setBonePose',
          );

          final staticChunk = StaticMeshChunk3D();
          late int chunkSlot;
          assertWakesAndResets(
            () => chunkSlot = staticChunk.addInstance(
              StaticMeshInstance3D(mesh: cube, worldX: 0, worldY: 0),
            ),
            'StaticMeshChunk3D.addInstance',
          );
          assertWakesAndResets(
            () => staticChunk.setInstanceVisible(chunkSlot, visible: false),
            'StaticMeshChunk3D.setInstanceVisible',
          );
        } finally {
          spriteImg.dispose();
          fontAtlas.dispose();
        }
      },
    );

    test(
      'Combined stress: 6-stage PostProcessPipeline (Bloom + 2x ColorGrading + '
      'ChromaticAberration + Vignette + CAS) renderFromImage & mirrored / '
      'multi-blend ParticleBatchGroup run splitting',
      () async {
        // Build a sharp high-contrast checkerboard image to exercise CAS +
        // ChromaticAberration + Bloom + folded ColorGrading + Vignette!
        final recSrc = ui.PictureRecorder();
        final cSrc = ui.Canvas(recSrc);
        cSrc.drawRect(
          const ui.Rect.fromLTWH(0, 0, 64, 64),
          ui.Paint()..color = const ui.Color(0xFF283040),
        );
        cSrc.drawRect(
          const ui.Rect.fromLTWH(16, 16, 32, 32),
          ui.Paint()..color = const ui.Color(0xFFE8D8B0),
        );
        final picSrc = recSrc.endRecording();
        final checkerImg = picSrc.toImageSync(64, 64);
        picSrc.dispose();

        final fullPipeline = PostProcessPipeline(
          pixelRatio: 1.0,
          stages: [
            PostProcessStage(
              name: 'bloom',
              postProcess: BloomPostProcess(intensity: 0.4, pixelRatio: 1.0),
            ),
            PostProcessStage(
              name: 'grade1',
              postProcess: ColorGradingPostProcess(
                exposure: 0.1,
                pixelRatio: 1.0,
              ),
            ),
            PostProcessStage(
              name: 'grade2',
              postProcess: ColorGradingPostProcess(
                saturation: 1.15,
                pixelRatio: 1.0,
              ),
            ),
            PostProcessStage(
              name: 'aberration',
              postProcess: ChromaticAberrationPostProcess(
                offsetPx: 2.0,
                pixelRatio: 1.0,
              ),
            ),
            PostProcessStage(
              name: 'vignette',
              postProcess: VignettePostProcess(
                intensity: 0.35,
                pixelRatio: 1.0,
              ),
            ),
            PostProcessStage(
              name: 'cas',
              postProcess: ContrastAdaptiveSharpenPostProcess(
                strength: 0.65,
                pixelRatio: 1.0,
              ),
            ),
          ],
        );

        try {
          final outBytes = await _rasterizeRgba(64, 64, (canvas) {
            final ok = fullPipeline.renderFromImage(
              checkerImg,
              Vector2(64, 64),
              canvas,
            );
            expect(ok, isTrue);
          });

          // 6 active stages -> ONLY 2 intermediate rasterizations (for the 2
          // multi-tap spatial stages ChromaticAberration & CAS) instead of 6!
          expect(fullPipeline.lastActiveStageCount, 6);
          expect(fullPipeline.lastFoldedColorGradingCount, 1);
          expect(fullPipeline.lastRasterizedImageCount, 2);

          // Center pixel must be bright, corner pixel darkened by vignette!
          const centerOff = (32 * 64 + 32) * 4;
          const cornerOff = (2 * 64 + 2) * 4;
          expect(
            outBytes.getUint8(centerOff),
            greaterThan(outBytes.getUint8(cornerOff) + 80),
          );

          // ParticleBatchGroup: negative mirror scale (-1, 1) routes safely to
          // quad batch while interleaved BlendMode.srcOver / BlendMode.plus
          // emitters split cleanly into exact blend runs!
          ParticleEmitter burst(int n) => ParticleEmitter(
            maxParticles: n,
            bursts: [EmitterBurst(0.0, n)],
            lifespan: (2.0, 2.0),
            size: (10.0, 10.0),
          );
          final mixedGroup = ParticleBatchGroup(
            children: [
              ParticleEmitterComponent(
                emitter: burst(4),
                renderer: CircleParticleRenderer(),
                position: Vector2(30, 30),
                removeOnFinish: false,
              ),
              ParticleEmitterComponent(
                emitter: burst(4),
                renderer: CircleParticleRenderer(blendMode: ui.BlendMode.plus),
                position: Vector2(50, 30),
                removeOnFinish: false,
              ),
              ParticleEmitterComponent(
                emitter: burst(4),
                renderer: CircleParticleRenderer(),
                position: Vector2(30, 50),
                scale: Vector2(-1.0, 1.0),
                removeOnFinish: false,
              ),
            ],
          );
          final gameMix = FlameGame(children: [mixedGroup])
            ..onGameResize(Vector2(80, 80));
          await gameMix.start();
          await gameMix.ready();
          gameMix.update(0.02);

          final mixRgba = await _rasterizeRgba(
            80,
            80,
            mixedGroup.renderTree,
          );
          expect(mixedGroup.lastBatchedEmitterCount, 3);
          expect(mixedGroup.lastAtlasDrawCalls, 2); // srcOver + plus
          expect(mixedGroup.lastQuadBatchDrawCalls, 1); // mirrored (-1, 1)
          var nonZero = 0;
          for (var i = 3; i < mixRgba.lengthInBytes; i += 4) {
            if (mixRgba.getUint8(i) > 0) {
              nonZero++;
            }
          }
          expect(nonZero, greaterThan(40));
        } finally {
          fullPipeline.dispose();
          checkerImg.dispose();
        }
      },
    );
  });
}
