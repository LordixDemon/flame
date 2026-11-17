// With CameraComponent.renderPasses set, an ordinary component (one that is
// not a MultiPassComponent) is painted once per frame, not once per pass.
import 'dart:ui';

import 'package:flame/camera.dart';
import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flutter_test/flutter_test.dart';

class _Ordinary() extends PositionComponent {
  int renderCount = 0;

  @override
  void render(Canvas canvas) => renderCount++;
}

class _Tower() extends PositionComponent with MultiPassComponent {
  final List<String> passes = [];

  @override
  void renderPass(Canvas canvas, RenderPass pass) => passes.add(pass.name);
}

void main() {
  test(
    'an ordinary component is painted once per frame under '
    'RenderPass.standardPipeline',
    () async {
      final game = FlameGame(
        camera: CameraComponent(viewport: FixedSizeViewport(400, 300)),
      )..onGameResize(Vector2(400, 300));
      await game.start();

      final sprite = _Ordinary();
      final tower = _Tower();
      game.world.addAll([sprite, tower]);
      await game.ready();
      game.camera.renderPasses = RenderPass.standardPipeline;

      final rec = PictureRecorder();
      game.camera.renderTree(Canvas(rec, const Rect.fromLTWH(0, 0, 400, 300)));
      rec.endRecording().dispose();

      // The multi-pass component behaves as documented.
      expect(tower.passes, [
        'shadows',
        'opaque',
        'translucent',
        'emissive',
        'overlay',
      ]);
      expect(
        sprite.renderCount,
        1,
        reason: 'ordinary component was painted once per pass',
      );
    },
  );
}
