import 'package:flame/camera.dart';
import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FollowBehavior with smoothing', () {
    test('lands exactly on the goal and then leaves the owner alone', () async {
      final game = FlameGame(
        camera: CameraComponent.withFixedResolution(width: 400, height: 300),
      )..onGameResize(Vector2(400, 300));
      await game.start();

      final target = PositionComponent(position: Vector2(10, 10));
      game.world.add(target);
      await game.ready();
      game.camera.follow(target, smoothing: 8.5);
      await game.ready();

      target.position.setValues(400, 300);
      for (var i = 0; i < 600; i++) {
        game.update(1 / 60);
      }
      final viewfinder = game.camera.viewfinder;
      expect(viewfinder.position.x, 400.0);
      expect(viewfinder.position.y, 300.0);

      final versionAtRest = viewfinder.transform.version;
      for (var i = 0; i < 120; i++) {
        game.update(1 / 60);
      }
      expect(viewfinder.transform.version, versionAtRest);

      // It still eases after the next move of the target.
      target.position.setValues(500, 300);
      game.update(1 / 60);
      expect(viewfinder.position.x, greaterThan(400.0));
      expect(viewfinder.position.x, lessThan(500.0));
    });

    test('rests at the edge of the deadzone', () async {
      final game = FlameGame(
        camera: CameraComponent.withFixedResolution(width: 400, height: 300),
      )..onGameResize(Vector2(400, 300));
      await game.start();

      final target = PositionComponent(position: Vector2(10, 10));
      game.world.add(target);
      await game.ready();
      game.camera.follow(
        target,
        smoothing: 8.5,
        deadzone: const Rect.fromLTRB(-18, -14, 18, 14),
      );
      await game.ready();

      target.position.setValues(400, 300);
      for (var i = 0; i < 600; i++) {
        game.update(1 / 60);
      }
      final viewfinder = game.camera.viewfinder;
      expect(viewfinder.position.x, closeTo(382, 1e-9));
      expect(viewfinder.position.y, closeTo(286, 1e-9));

      final versionAtRest = viewfinder.transform.version;
      for (var i = 0; i < 600; i++) {
        game.update(1 / 60);
      }
      expect(viewfinder.transform.version, versionAtRest);
    });

    test('eases smoothly until less than settleDistance is left', () async {
      final game = FlameGame(
        camera: CameraComponent.withFixedResolution(width: 400, height: 300),
      )..onGameResize(Vector2(400, 300));
      await game.start();

      final target = PositionComponent(position: Vector2(100, 0));
      game.world.add(target);
      await game.ready();
      game.camera.follow(target, smoothing: 8.0);
      await game.ready();

      final viewfinder = game.camera.viewfinder;
      var previousGap = 100.0;
      var landed = false;
      for (var i = 0; i < 300 && !landed; i++) {
        game.update(1 / 60);
        final gap = 100.0 - viewfinder.position.x;
        if (gap == 0.0) {
          // The step that lands may cover at most settleDistance.
          expect(previousGap, lessThanOrEqualTo(FollowBehavior.settleDistance));
          landed = true;
        } else {
          expect(gap, lessThan(previousGap));
          expect(gap, greaterThan(0.0));
        }
        previousGap = gap;
      }
      expect(landed, isTrue);
    });

    testWidgets(
      'on-demand rendering goes idle once a smoothly followed target rests',
      (tester) async {
        final game = FlameGame()..idleRenderMode = IdleRenderMode.onDemand;
        final target = PositionComponent(position: Vector2(10, 10));
        game.world.add(target);
        game.camera.follow(
          target,
          smoothing: 8.5,
          deadzone: const Rect.fromLTRB(-18, -14, 18, 14),
        );
        await tester.pumpWidget(GameWidget(game: game));
        await tester.pump();

        // The target jumps once and then never moves again.
        target.position.setValues(400, 300);
        for (var i = 0; i < 60 * 10; i++) {
          await tester.pump(const Duration(microseconds: 16667));
        }

        final before = game.executedRenderFrames;
        for (var i = 0; i < 120; i++) {
          await tester.pump(const Duration(microseconds: 16667));
        }
        expect(game.executedRenderFrames - before, 0);
      },
    );
  });
}
