import 'dart:ui' as ui;

import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flutter_test/flutter_test.dart';

class _WorldMarker({
  required super.position,
  required super.size,
  required this.color,
}) extends PositionComponent {
  final ui.Color color;

  this : super(anchor: Anchor.center);

  @override
  void render(ui.Canvas canvas) {
    canvas.drawRect(size.toRect(), ui.Paint()..color = color);
  }
}

void main() {
  group('FollowBehavior v2, Viewfinder Trauma, & Camera renderToImage', () {
    test(
      'FollowBehavior deadzone ignores small jitter and leadFactor leads '
      'moving targets smoothly',
      () async {
        final game = FlameGame(
          camera: CameraComponent.withFixedResolution(width: 400, height: 300),
        )..onGameResize(Vector2(400, 300));
        await game.start();

        final target = PositionComponent(position: Vector2.zero());
        game.world.add(target);
        await game.ready();

        game.camera.follow(
          target,
          smoothing: 8.0,
          deadzone: const ui.Rect.fromLTRB(-20, -20, 20, 20),
          leadFactor: 0.25,
          maxLeadDistance: 100.0,
        );
        await game.ready();

        // Target moves inside deadzone -> camera stays motionless at (0, 0).
        target.position.setValues(15, -10);
        game.update(1 / 60);
        expect(game.camera.viewfinder.position.x, 0.0);
        expect(game.camera.viewfinder.position.y, 0.0);

        // Target sprints right at 400 px/s -> camera chases with smooth lead.
        for (var i = 0; i < 30; i++) {
          target.position.x += 400.0 / 60.0;
          game.update(1 / 60);
        }
        expect(game.camera.viewfinder.position.x, greaterThan(100.0));
      },
    );

    test(
      'Viewfinder.addTrauma applies quadratic render shake & decay without '
      'mutating viewfinder.position or visibleWorldRect',
      () async {
        final game = FlameGame(
          camera: CameraComponent.withFixedResolution(width: 400, height: 300),
        )..onGameResize(Vector2(400, 300));
        await game.start();

        game.camera.viewfinder.position = Vector2(50, -30);
        final baselineRect = game.camera.visibleWorldRect;

        game.camera.viewfinder.addTrauma(0.8);
        expect(game.camera.viewfinder.trauma, closeTo(0.8, 1e-6));
        expect(game.camera.viewfinder.shakeOffset.length, greaterThan(0.0));

        // Render while shaking -> position and visibleWorldRect remain exact!
        final rec = ui.PictureRecorder();
        game.render(ui.Canvas(rec));
        rec.endRecording().dispose();

        expect(game.camera.viewfinder.position, Vector2(50, -30));
        expect(game.camera.visibleWorldRect, baselineRect);

        // Decay back to rest
        for (var i = 0; i < 60; i++) {
          game.update(1 / 30);
        }
        expect(game.camera.viewfinder.trauma, 0.0);
        expect(game.camera.viewfinder.shakeOffset, Vector2.zero());
        expect(game.camera.viewfinder.shakeRoll, 0.0);
      },
    );

    test(
      'CameraComponent.renderToImageSync & renderToImage capture crisp '
      'offscreen snapshots without touching screen canvas',
      () async {
        final game = FlameGame(
          camera: CameraComponent.withFixedResolution(width: 200, height: 100),
        )..onGameResize(Vector2(400, 300));
        await game.start();

        game.world.add(
          _WorldMarker(
            position: Vector2.zero(),
            size: Vector2(80, 60),
            color: const ui.Color(0xFFFF2244),
          ),
        );
        await game.ready();

        final syncImg = game.camera.renderToImageSync(
          width: 100,
          height: 50,
          backgroundColor: const ui.Color(0xFF102030),
        );
        addTearDown(syncImg.dispose);
        expect(syncImg.width, 100);
        expect(syncImg.height, 50);

        final bytes = await syncImg.toByteData();
        expect(bytes, isNotNull);

        // Center pixel (50, 25) should be the red marker (0xFFFF2244 -> RGBA)
        const centerIdx = (25 * 100 + 50) * 4;
        expect(bytes!.getUint8(centerIdx), greaterThan(220));
        expect(bytes.getUint8(centerIdx + 1), lessThan(60));

        // Corner pixel (2, 2) should be backgroundColor (0xFF102030)
        const cornerIdx = (2 * 100 + 2) * 4;
        expect(bytes.getUint8(cornerIdx), 0x10);
        expect(bytes.getUint8(cornerIdx + 1), 0x20);
        expect(bytes.getUint8(cornerIdx + 2), 0x30);

        final asyncImg = await game.camera.renderToImage(pixelRatio: 0.5);
        addTearDown(asyncImg.dispose);
        expect(asyncImg.width, 100);
        expect(asyncImg.height, 50);
      },
    );
  });
}
