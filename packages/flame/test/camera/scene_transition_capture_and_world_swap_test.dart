import 'dart:async';
import 'dart:ui';

import 'package:flame/camera.dart';
import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records how the camera drives a transition.
class _ProbeTransition({
  super.capturePixelRatio,
  super.aboveViewportHud,
}) extends SceneTransition {
  this : super(duration: 0.4);

  int drawCalls = 0;
  int? snapshotWidth;
  int? snapshotHeight;
  final List<double> progress = [];

  @override
  void renderTransition(
    Canvas canvas,
    Image outgoingSnapshot,
    Rect viewportBounds,
    double progress,
  ) {
    drawCalls++;
    snapshotWidth = outgoingSnapshot.width;
    snapshotHeight = outgoingSnapshot.height;
    this.progress.add(progress);
  }
}

class _SlowWorld() extends World {
  final Completer<void> assets = Completer<void>();

  @override
  Future<void> onLoad() => assets.future;
}

class _RenderCounter() extends Component {
  int renderCount = 0;

  @override
  void render(Canvas canvas) => renderCount++;
}

void main() {
  Future<FlameGame> makeGame({double width = 390, double height = 844}) async {
    final game = FlameGame(
      camera: CameraComponent(viewport: FixedSizeViewport(width, height)),
    )..onGameResize(Vector2(width, height));
    await game.start();
    await game.ready();
    return game;
  }

  void frame(FlameGame game, double dt) {
    game.update(dt);
    final rec = PictureRecorder();
    game.render(Canvas(rec, const Rect.fromLTWH(0, 0, 390, 844)));
    rec.endRecording().dispose();
  }

  group('SceneTransition snapshot resolution', () {
    test('defaults to the device pixel ratio of the game', () async {
      final game = await makeGame();
      game.overrideDisplayMetrics(devicePixelRatio: 2.0);
      expect(game.devicePixelRatio, 2.0);

      final transition = _ProbeTransition();
      unawaited(game.camera.startSceneTransition(transition));
      frame(game, 1 / 60);

      expect(transition.snapshotWidth, 780);
      expect(transition.snapshotHeight, 1688);
      game.camera.cancelSceneTransition();
    });

    test('built-in transitions leave capturePixelRatio unset', () {
      expect(const CrossFadeSceneTransition().capturePixelRatio, isNull);
      expect(CircularRevealSceneTransition().capturePixelRatio, isNull);
    });

    test('an explicit capturePixelRatio is used as given', () async {
      final game = await makeGame();
      game.overrideDisplayMetrics(devicePixelRatio: 2.0);

      final transition = _ProbeTransition(capturePixelRatio: 0.5);
      unawaited(game.camera.startSceneTransition(transition));
      frame(game, 1 / 60);

      expect(transition.snapshotWidth, 195);
      expect(transition.snapshotHeight, 422);
      game.camera.cancelSceneTransition();
    });

    test('never exceeds maxRenderTextureDimension', () async {
      final game = await makeGame();
      game.overrideDisplayMetrics(devicePixelRatio: 2.0);
      game.camera.maxRenderTextureDimension = 1000;

      final transition = _ProbeTransition();
      unawaited(game.camera.startSceneTransition(transition));
      frame(game, 1 / 60);

      expect(transition.snapshotHeight, 1000);
      expect(transition.snapshotWidth, closeTo(390 * 1000 / 844, 1.0));
      game.camera.cancelSceneTransition();
    });
  });

  group('transitionToWorld', () {
    test('holds the outgoing frame while the next world loads', () async {
      final game = await makeGame();
      final hud = _RenderCounter();
      game.camera.viewport.add(hud);
      await game.ready();
      frame(game, 1 / 60);

      final transition = _ProbeTransition();
      final next = _SlowWorld();
      var finished = false;
      unawaited(
        game.camera
            .transitionToWorld(next, transition: transition)
            .then((_) => finished = true),
      );
      expect(game.camera.hasActiveSceneTransition, isTrue);

      // The next world takes 0.5 s to load, longer than the transition.
      final hudRendersBefore = hud.renderCount;
      for (var i = 0; i < 30; i++) {
        frame(game, 1 / 60);
      }
      expect(next.isMounted, isFalse);

      // The snapshot was drawn on every frame, at the very start of the
      // transition, and the viewport elements stayed on screen.
      expect(transition.drawCalls, 30);
      expect(transition.progress, everyElement(0.0));
      expect(hud.renderCount, hudRendersBefore + 30);
      expect(game.camera.sceneTransitionProgress, 0.0);
      expect(finished, isFalse);

      // Once the world is there the transition plays in full.
      next.assets.complete();
      await game.ready();
      expect(next.isMounted, isTrue);
      frame(game, 0.1);
      expect(game.camera.hasActiveSceneTransition, isTrue);
      expect(game.camera.sceneTransitionProgress, greaterThan(0.0));
      expect(game.camera.sceneTransitionProgress, lessThan(1.0));

      for (var i = 0; i < 4; i++) {
        frame(game, 0.1);
      }
      await Future<void>.delayed(Duration.zero);
      expect(game.camera.hasActiveSceneTransition, isFalse);
      expect(finished, isTrue);
    });

    test('draws a snapshot that includes the HUD above the HUD', () async {
      final game = await makeGame();
      final hud = _RenderCounter();
      game.camera.viewport.add(hud);
      await game.ready();
      frame(game, 1 / 60);

      final transition = _ProbeTransition(aboveViewportHud: true);
      final next = _SlowWorld();
      unawaited(game.camera.transitionToWorld(next, transition: transition));
      frame(game, 1 / 60);

      expect(transition.drawCalls, 1);
      game.camera.cancelSceneTransition();
    });

    test(
      'cancelling while the next world loads completes the future',
      () async {
        final game = await makeGame();
        final next = _SlowWorld();
        var finished = false;
        unawaited(
          game.camera
              .transitionToWorld(next, transition: _ProbeTransition())
              .then((_) => finished = true),
        );
        frame(game, 1 / 60);

        game.camera.cancelSceneTransition();
        await Future<void>.delayed(Duration.zero);
        expect(finished, isTrue);
        expect(game.camera.hasActiveSceneTransition, isFalse);
      },
    );

    test('a transition within the same world is not held', () async {
      final game = await makeGame();
      final transition = _ProbeTransition();
      unawaited(game.camera.startSceneTransition(transition));
      frame(game, 0.2);
      expect(game.camera.sceneTransitionProgress, greaterThan(0.0));
      frame(game, 0.3);
      expect(game.camera.hasActiveSceneTransition, isFalse);
    });
  });
}
