import 'dart:ui' as ui;

import 'package:flame/components.dart';
import 'package:flame/post_process.dart';
import 'package:flame_test/flame_test.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWithFlameGame(
    'a tilt-shift post process drops its last frame image when switched off',
    (game) async {
      game.onGameResize(Vector2(200, 100));
      final tilt = TiltShiftPostProcess();
      game.camera.postProcess = tilt;
      await game.ready();

      void renderFrame() {
        final recorder = ui.PictureRecorder();
        game.render(ui.Canvas(recorder));
        recorder.endRecording().dispose();
      }

      renderFrame();
      expect(tilt.holdsFrameImage, isTrue);

      tilt.enabled = false;
      renderFrame();
      expect(tilt.holdsFrameImage, isFalse);

      tilt.enabled = true;
      renderFrame();
      expect(tilt.holdsFrameImage, isTrue);
    },
  );

  testWithFlameGame(
    'a pipeline releases the image of a stage that turns inactive',
    (game) async {
      game.onGameResize(Vector2(200, 100));
      final tilt = TiltShiftPostProcess();
      final pipeline = PostProcessPipeline(
        stages: [PostProcessStage(name: 'tilt', postProcess: tilt)],
      );
      game.camera.postProcess = pipeline;
      await game.ready();

      void renderFrame() {
        final recorder = ui.PictureRecorder();
        game.render(ui.Canvas(recorder));
        recorder.endRecording().dispose();
      }

      renderFrame();
      expect(tilt.holdsFrameImage, isTrue);

      tilt.enabled = false;
      renderFrame();
      expect(tilt.holdsFrameImage, isFalse);
    },
  );

  test('UniformSlotBuffer writes every float straight through', () {
    final buffer = UniformSlotBuffer();
    final sent = <(int, double)>[];
    final target = Object();
    for (var i = 0; i < 3; i++) {
      buffer.setFloatCustom(target, 0, 1.0, (s, v) => sent.add((s, v)));
    }
    // The custom uploader path stays dirty-checked: one upload, two skips.
    expect(sent, [(0, 1.0)]);
    expect(buffer.skippedCount, 2);
    expect(buffer.uploadedCount, 1);
  });
}
