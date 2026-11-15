import 'dart:ui' as ui;

import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flame/particles.dart';
import 'package:flame/post_process.dart';
import 'package:flame/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

class _RasterStagePostProcess() extends PostProcess {
  int runCount = 0;

  @override
  void postProcess(Vector2 size, ui.Canvas canvas) {
    runCount++;
    final img = rasterizeSubtree();
    try {
      canvas.drawImageRect(
        img,
        ui.Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
        ui.Rect.fromLTWH(0, 0, size.x, size.y),
        ui.Paint(),
      );
    } finally {
      img.dispose();
    }
  }
}

class _AdaptiveProbeComponent({super.minQualityTier})
    extends PositionComponent
    with HasGraphicsAdaptation {
  int updateCalls = 0;
  int renderCalls = 0;
  int profileCallbacks = 0;
  GraphicsQualityTier? lastTier;

  @override
  void onGraphicsProfileChanged(
    GraphicsProfile profile,
    GraphicsQualityTier tier,
  ) {
    profileCallbacks++;
    lastTier = tier;
  }

  @override
  void update(double dt) {
    updateCalls++;
  }

  @override
  void render(ui.Canvas canvas) {
    renderCalls++;
  }
}

class _BudgetSnapshotTile({super.size})
    extends PositionComponent
    with Snapshot {
  @override
  void render(ui.Canvas canvas) {
    canvas.drawRect(
      size.toRect(),
      ui.Paint()..color = const ui.Color(0xFFAB47BC),
    );
  }
}

void main() {
  group('GraphicsSettingsController, DRS, PostProcessPipeline & Budget', () {
    test(
      'GraphicsSettingsController presets & DynamicQualityGovernor DRS (#6,#7)',
      () {
        final ctrl = GraphicsSettingsController();
        expect(ctrl.tier, GraphicsQualityTier.high);
        expect(ctrl.meetsTier(GraphicsQualityTier.medium), isTrue);
        expect(ctrl.meetsTier(GraphicsQualityTier.ultra), isFalse);

        ctrl.setTier(GraphicsQualityTier.low);
        expect(ctrl.effectiveShadowsEnabled, isFalse);
        expect(ctrl.effectivePostProcessEnabled, isFalse);
        expect(ctrl.effectiveRenderScale, closeTo(0.65, 1e-5));

        ctrl.setTier(GraphicsQualityTier.high);
        ctrl.governor
          ..enabled = true
          ..overBudgetFramesThreshold = 3
          ..underBudgetFramesThreshold = 4
          ..cooldownSeconds = 0.5
          ..scaleStepDown = 0.15
          ..scaleStepUp = 0.10;

        // 3 consecutive over-budget frames step down resolution & particles.
        expect(
          ctrl.recordFrameSample(
            frameTimeMs: 22.0,
            targetBudgetMs: 16.67,
            dtSeconds: 0.02,
          ),
          isFalse,
        );
        ctrl.recordFrameSample(
          frameTimeMs: 22.0,
          targetBudgetMs: 16.67,
          dtSeconds: 0.02,
        );
        final steppedDown = ctrl.recordFrameSample(
          frameTimeMs: 22.0,
          targetBudgetMs: 16.67,
          dtSeconds: 0.02,
        );
        expect(steppedDown, isTrue);
        expect(ctrl.effectiveRenderScale, closeTo(0.85, 1e-4));
        expect(ctrl.effectiveParticleDensity, lessThan(1.0));

        // Cooldown prevents immediate step-up until 0.5s elapses.
        for (var i = 0; i < 6; i++) {
          ctrl.recordFrameSample(
            frameTimeMs: 6.0,
            targetBudgetMs: 16.67,
            dtSeconds: 0.12,
          );
        }
        expect(ctrl.effectiveRenderScale, greaterThan(0.85));
      },
    );

    test(
      'PostProcessPipeline bypasses with 0 toImageSync when stages inactive '
      'and auto-syncs DPR',
      () async {
        final game = FlameGame()
          ..collectRenderTelemetry = true
          ..onGameResize(Vector2(300, 200));
        game.overrideDisplayMetrics(devicePixelRatio: 2.0);

        final bloomStage = _RasterStagePostProcess();
        final gradeStage = _RasterStagePostProcess();
        final pipeline = PostProcessPipeline(
          stages: [
            PostProcessStage(
              name: 'bloom',
              postProcess: bloomStage,
              minQualityTier: GraphicsQualityTier.high,
              resolutionScale: 0.5,
            ),
            PostProcessStage(
              name: 'grade',
              postProcess: gradeStage,
              minQualityTier: GraphicsQualityTier.medium,
            ),
          ],
        );
        game.camera.postProcess = pipeline;
        game.world.add(
          RectangleComponent(
            size: Vector2(40, 40),
            paint: ui.Paint()..color = const ui.Color(0xFFFFFFFF),
          ),
        );
        await game.start();

        void renderTelemetryFrame() {
          final recorder = ui.PictureRecorder();
          game.render(ui.Canvas(recorder));
          recorder.endRecording().dispose();
        }

        // High tier: both stages run; bloom runs at 2.0 * 0.5 = 1.0 ratio.
        renderTelemetryFrame();
        expect(pipeline.lastActiveStageCount, 2);
        expect(pipeline.bypassedLastFrame, isFalse);
        expect(bloomStage.pixelRatio, closeTo(1.0, 1e-5));
        expect(gradeStage.pixelRatio, closeTo(2.0, 1e-5));
        expect(game.renderTelemetry.offscreenRasterizations, 2);

        // Low tier: 0 active stages -> direct renderSubtree with ZERO
        // offscreen rasterizations!
        game.graphics.setTier(GraphicsQualityTier.low);
        game.camera.respectGraphicsRenderScale = false;
        renderTelemetryFrame();
        expect(pipeline.lastActiveStageCount, 0);
        expect(pipeline.bypassedLastFrame, isTrue);
        expect(game.renderTelemetry.offscreenRasterizations, 0);
      },
    );

    test(
      'Component.minQualityTier, HasGraphicsAdaptation, particle density & '
      'Shadow3DDecorator gating',
      () async {
        final game = FlameGame()
          ..collectRenderTelemetry = true
          ..onGameResize(Vector2(300, 200));

        final ultraProp = _AdaptiveProbeComponent(
          minQualityTier: GraphicsQualityTier.ultra,
        );
        final emitterComp = ParticleEmitterComponent(
          emitter: ParticleEmitter(
            maxParticles: 256,
            rate: 100,
            lifespan: (2.0, 2.0),
          ),
          renderer: CircleParticleRenderer(),
        );
        final shadowedBox = RectangleComponent(
          size: Vector2(30, 30),
          paint: ui.Paint()..color = const ui.Color(0xFFFFCA28),
        )..decorator.addLast(Shadow3DDecorator());

        game.world.addAll([ultraProp, emitterComp, shadowedBox]);
        await game.start();

        // Default tier is high -> ultraProp is excluded from BOTH update &
        // render!
        ultraProp.updateCalls = 0;
        game.update(0.1);
        expect(ultraProp.updateCalls, 0);
        expect(ultraProp.lastTier, GraphicsQualityTier.high);

        // Particle count at high (density 1.0): 100 * 0.1 = 10 particles.
        expect(emitterComp.particleCount, 10);

        // Switch to low: shadows disabled -> 0 saveLayer calls; particle
        // density = 0.35!
        game.graphics.setTier(GraphicsQualityTier.low);
        game.camera.respectGraphicsRenderScale = false;
        emitterComp.clearParticles();
        game.update(0.2);
        expect(emitterComp.particleCount, 7); // 100 * 0.35 * 0.2 = 7

        final recorder = ui.PictureRecorder();
        game.render(ui.Canvas(recorder));
        recorder.endRecording().dispose();
        expect(game.renderTelemetry.saveLayerCalls, 0);
        expect(ultraProp.renderCalls, 0);

        // Upgrade to ultra -> ultraProp wakes up immediately!
        game.graphics.setTier(GraphicsQualityTier.ultra);
        game.update(0.016);
        expect(ultraProp.updateCalls, 1);
        expect(ultraProp.lastTier, GraphicsQualityTier.ultra);
      },
    );

    testWidgets(
      'Game.backgroundColorValue updates ColoredBox with 0 GameWidget rebuilds '
      'and SceneResourceBudget evicts LRU surfaces',
      (tester) async {
        final game = FlameGame();
        await tester.pumpWidget(GameWidget(game: game));
        await tester.pump();

        var coloredBox = tester.widget<ColoredBox>(find.byType(ColoredBox));
        expect(coloredBox.color, const ui.Color(0xFF000000));

        game.backgroundColorValue = const ui.Color(0xFF1E3A5F);
        await tester.pump();

        coloredBox = tester.widget<ColoredBox>(find.byType(ColoredBox));
        expect(coloredBox.color, const ui.Color(0xFF1E3A5F));

        // SceneResourceBudget LRU eviction across Snapshot raster surfaces:
        // Each 64x64 RGBA8 surface = 16,384 bytes. Cap budget at 36,000 bytes
        // (fits 2 surfaces, evicts oldest on 3rd).
        game.resourceBudget.maxBudgetBytes = 36000;
        final s1 = _BudgetSnapshotTile(size: Vector2.all(64))
          ..snapshotCacheMode = SnapshotCacheMode.rasterImage;
        final s2 = _BudgetSnapshotTile(size: Vector2.all(64))
          ..snapshotCacheMode = SnapshotCacheMode.rasterImage;
        final s3 = _BudgetSnapshotTile(size: Vector2.all(64))
          ..snapshotCacheMode = SnapshotCacheMode.rasterImage;
        game.world.addAll([s1, s2, s3]);
        await tester.pump();
        s1.clearSnapshot();
        s2.clearSnapshot();
        s3.clearSnapshot();
        game.resourceBudget.resetStats();

        void renderSingle(Component c) {
          final rec = ui.PictureRecorder();
          c.renderTree(ui.Canvas(rec));
          rec.endRecording().dispose();
        }

        renderSingle(s1);
        renderSingle(s2);
        // Touch s1 so s2 becomes the least-recently-used entry!
        renderSingle(s1);
        expect(game.resourceBudget.activeSurfaceCount, 2);

        // Rendering s3 exceeds 36 KB -> s2 is evicted while s1 & s3 remain!
        renderSingle(s3);
        expect(game.resourceBudget.evictionCount, 1);
        expect(s1.cachedSnapshotImage, isNotNull);
        expect(s2.cachedSnapshotImage, isNull);
        expect(s3.cachedSnapshotImage, isNotNull);
      },
    );
  });
}
