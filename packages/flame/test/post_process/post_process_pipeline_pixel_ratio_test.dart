import 'dart:ui' as ui;

import 'package:flame/components.dart';
import 'package:flame/post_process.dart';
import 'package:flame_test/flame_test.dart';
import 'package:flutter_test/flutter_test.dart';

class _RatioProbe({super.pixelRatio}) extends PostProcess {
  @override
  void postProcess(Vector2 size, ui.Canvas canvas) {
    renderSubtree(canvas);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWithFlameGame(
    'a pipeline stage keeps the explicit pixelRatio it was constructed with',
    (game) async {
      game.onGameResize(Vector2(200, 100));
      game.overrideDisplayMetrics(devicePixelRatio: 3.0);

      final explicit = _RatioProbe(pixelRatio: 1.0);
      expect(explicit.autoSyncDevicePixelRatio, isFalse);

      final pipeline = PostProcessPipeline(
        stages: [PostProcessStage(name: 'probe', postProcess: explicit)],
      );
      game.camera.postProcess = pipeline;
      await game.ready();

      final recorder = ui.PictureRecorder();
      game.render(ui.Canvas(recorder));
      recorder.endRecording().dispose();

      expect(pipeline.lastActiveStageCount, 1);
      expect(
        explicit.pixelRatio,
        1.0,
        reason: 'constructed with pixelRatio: 1.0 (autoSync is off)',
      );
    },
  );

  // A pipeline built without a ratio and a stage built with an explicit one
  // are both capped by hand later (for example when the window is resized).
  testWithFlameGame(
    'a manual pixelRatio cap on pipeline and stage survives the next frame',
    (game) async {
      game.onGameResize(Vector2(200, 100));
      game.overrideDisplayMetrics(devicePixelRatio: 3.0);

      final stagePost = _RatioProbe(pixelRatio: 1.0);
      final pipeline = PostProcessPipeline(
        stages: [PostProcessStage(name: 'probe', postProcess: stagePost)],
      );
      game.camera.postProcess = pipeline;
      await game.ready();

      stagePost.pixelRatio = 1.5;
      pipeline.pixelRatio = 1.5;

      final recorder = ui.PictureRecorder();
      game.render(ui.Canvas(recorder));
      recorder.endRecording().dispose();

      expect(stagePost.pixelRatio, 1.5);
    },
  );
}
