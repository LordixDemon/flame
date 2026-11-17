import 'dart:ui' as ui;

import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flame/post_process.dart';
import 'package:flame_test/flame_test.dart';
import 'package:flutter_test/flutter_test.dart';

void _renderFrame(FlameGame game) {
  final recorder = ui.PictureRecorder();
  game.render(ui.Canvas(recorder));
  recorder.endRecording().dispose();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWithFlameGame(
    'a bypassed PostProcessPipeline keeps the reduced world render scale',
    (game) async {
      game.onGameResize(Vector2(400, 200));
      game.overrideDisplayMetrics(devicePixelRatio: 1.0);
      await game.world.ensureAdd(
        RectangleComponent(size: Vector2.all(50)),
      );
      game.graphics.setTier(GraphicsQualityTier.low);
      expect(game.camera.effectiveWorldRenderScale, closeTo(0.65, 1e-6));

      // Control: no post process -> world goes through a 0.65x surface.
      _renderFrame(game);
      expect(game.camera.lastWorldSurfaceWidth, 260);
      expect(game.camera.lastWorldSurfaceHeight, 130);
      final offscreenBefore = game.camera.offscreenWorldRenderCount;

      // Same camera, pipeline whose only stage is gated to `ultra`.
      final pipeline = PostProcessPipeline(
        stages: [
          PostProcessStage(
            name: 'grade',
            postProcess: ColorGradingPostProcess(
              preset: ColorGradingPreset.warmSunset,
            ),
            minQualityTier: GraphicsQualityTier.ultra,
          ),
        ],
      );
      game.camera.postProcess = pipeline;
      await game.ready();
      _renderFrame(game);

      expect(pipeline.bypassedLastFrame, isTrue);
      expect(
        game.camera.offscreenWorldRenderCount,
        greaterThan(offscreenBefore),
        reason:
            'render scale is 0.65 but the world was drawn directly at full '
            'resolution (no reduced offscreen pass, no image rasterized: '
            '${pipeline.lastRasterizedImageCount})',
      );
    },
  );
}
