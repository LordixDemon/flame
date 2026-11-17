import 'package:flame/camera.dart';
import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Viewfinder trauma shake', () {
    Future<FlameGame> makeGame() async {
      final game = FlameGame(
        camera: CameraComponent(viewport: FixedSizeViewport(400, 300)),
      )..onGameResize(Vector2(400, 300));
      await game.start();
      await game.ready();
      return game;
    }

    test('clearTrauma requests a repaint when a shake was active', () async {
      final game = await makeGame();
      final viewfinder = game.camera.viewfinder..addTrauma(1.0);
      expect(viewfinder.hasActiveShake, isTrue);

      final before = Game.visualMutationCount;
      viewfinder.clearTrauma();
      expect(viewfinder.hasActiveShake, isFalse);
      expect(Game.visualMutationCount, greaterThan(before));

      // Nothing to repaint when there was no shake.
      final idle = Game.visualMutationCount;
      viewfinder.clearTrauma();
      expect(Game.visualMutationCount, idle);
    });

    test('the tick that ends a shake requests a repaint', () async {
      final game = await makeGame();
      final viewfinder = game.camera.viewfinder
        ..traumaDecay = 10.0
        ..addTrauma(0.5);

      game.update(0.01);
      expect(viewfinder.hasActiveShake, isTrue);

      final before = Game.visualMutationCount;
      game.update(1.0);
      expect(viewfinder.trauma, 0.0);
      expect(viewfinder.hasActiveShake, isFalse);
      expect(Game.visualMutationCount, greaterThan(before));
    });

    testWidgets(
      'on-demand rendering paints the settled frame after clearTrauma',
      (tester) async {
        final game = FlameGame()..idleRenderMode = IdleRenderMode.onDemand;
        await tester.pumpWidget(GameWidget(game: game));
        await tester.pump();
        game.camera.viewfinder
          ..traumaDecay = 0.0
          ..addTrauma(1.0);
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }

        game.camera.viewfinder.clearTrauma();
        final before = game.executedRenderFrames;
        await tester.pump(const Duration(milliseconds: 16));
        expect(game.executedRenderFrames, before + 1);

        // ... and then the game is idle again.
        final settled = game.executedRenderFrames;
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(game.executedRenderFrames, settled);
      },
    );
  });
}
