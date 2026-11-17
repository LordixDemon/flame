import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/camera.dart';
import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flutter_test/flutter_test.dart';

class _Probe({super.position, super.size}) extends PositionComponent {
  int renderCount = 0;

  @override
  void render(Canvas canvas) => renderCount++;
}

class _CullProbe({super.position, super.size})
    extends _Probe
    with CullWhenOffscreen;

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

  group('Viewfinder trauma shake and culling', () {
    const screen = Rect.fromLTWH(0, 0, 400, 300);

    Future<FlameGame> makeGame({required bool spatialIndex}) async {
      final world = World(spatialIndexEnabled: spatialIndex);
      final game = FlameGame(
        world: world,
        camera: CameraComponent(
          world: world,
          viewport: FixedSizeViewport(400, 300),
        ),
      )..onGameResize(Vector2(400, 300));
      await game.start();
      await game.ready();
      return game;
    }

    void renderOnce(FlameGame game) {
      final rec = PictureRecorder();
      game.camera.renderTree(Canvas(rec, screen));
      rec.endRecording().dispose();
    }

    test('cullWorldRect is visibleWorldRect while nothing shakes', () async {
      final game = await makeGame(spatialIndex: false);
      expect(
        identical(game.camera.cullWorldRect, game.camera.visibleWorldRect),
        isTrue,
      );
    });

    test(
      'cullWorldRect grows by the shake and visibleWorldRect does not',
      () async {
        final game = await makeGame(spatialIndex: false);
        final viewfinder = game.camera.viewfinder
          ..maxShakeRoll = 0.0
          ..traumaDecay = 0.0
          ..addTrauma(1.0);
        final offset = viewfinder.shakeOffset;
        final bound = math.sqrt(offset.x * offset.x + offset.y * offset.y);
        expect(bound, greaterThan(1.0));

        const visible = Rect.fromLTRB(-200, -150, 200, 150);
        expect(game.camera.visibleWorldRect, visible);
        final cull = game.camera.cullWorldRect;
        expect(cull.left, closeTo(-200 - bound, 1e-9));
        expect(cull.right, closeTo(200 + bound, 1e-9));
        expect(cull.top, closeTo(-150 - bound, 1e-9));
        expect(cull.bottom, closeTo(150 + bound, 1e-9));
        // Stable between calls of one frame.
        expect(identical(game.camera.cullWorldRect, cull), isTrue);

        // World units: twice the zoom, half the margin.
        viewfinder.zoom = 2.0;
        expect(game.camera.cullWorldRect.left, closeTo(-100 - bound / 2, 1e-9));

        viewfinder.clearTrauma();
        expect(
          identical(game.camera.cullWorldRect, game.camera.visibleWorldRect),
          isTrue,
        );
      },
    );

    test('cullWorldRect covers what a shake roll swings into view', () async {
      final game = await makeGame(spatialIndex: false);
      final viewfinder = game.camera.viewfinder
        ..maxShakeOffset = 0.0
        ..maxShakeRoll = 0.035
        ..traumaDecay = 0.0
        ..addTrauma(1.0);
      final roll = viewfinder.shakeRoll.abs();
      expect(roll, greaterThan(0.01));

      // The furthest corner is 250 px away from the centre of a 400x300 view.
      final bound = 2 * 250 * math.sin(roll / 2);
      expect(viewfinder.shakeDisplacementBound, closeTo(bound, 1e-9));
      expect(game.camera.cullWorldRect.left, closeTo(-200 - bound, 1e-9));
    });

    for (final spatialIndex in [false, true]) {
      final mode = spatialIndex ? 'with' : 'without';
      test(
        'components that the shake moves onto the screen are drawn '
        '($mode the spatial index)',
        () async {
          final game = await makeGame(spatialIndex: spatialIndex);
          final viewfinder = game.camera.viewfinder
            ..maxShakeRoll = 0.0
            ..maxShakeOffset = 14.0
            ..traumaDecay = 0.0
            ..addTrauma(1.0);
          // The picture moves right and up by about (4.3, -4.2) px.
          final shake = viewfinder.shakeOffset.clone();
          expect(shake.x, greaterThan(4.0));

          // 3x20 boxes just left of visibleWorldRect ([-203.5, -200.5]); the
          // shake brings them on screen at x in [0.8, 3.8].
          final plain = _Probe(
            position: Vector2(-203.5, 0),
            size: Vector2(3, 20),
          );
          final cullable = _CullProbe(
            position: Vector2(-203.5, 40),
            size: Vector2(3, 20),
          );
          final grouped = _Probe(
            position: Vector2(-203.5, 80),
            size: Vector2(3, 20),
          );
          // Far away: still culled.
          final far = _CullProbe(
            position: Vector2(-900, 0),
            size: Vector2(3, 20),
          );
          game.world.addAll([
            plain,
            cullable,
            SpatialCullGroup(children: [grouped]),
            far,
          ]);
          await game.ready();

          renderOnce(game);

          expect(plain.renderCount, 1);
          expect(cullable.renderCount, 1);
          expect(grouped.renderCount, 1);
          expect(far.renderCount, 0);
        },
      );
    }

    test('nothing extra is drawn once the shake is over', () async {
      final game = await makeGame(spatialIndex: true);
      final cullable = _CullProbe(
        position: Vector2(-203.5, 40),
        size: Vector2(3, 20),
      );
      game.world.add(cullable);
      await game.ready();

      renderOnce(game);
      expect(cullable.renderCount, 0);

      game.camera.viewfinder
        ..maxShakeRoll = 0.0
        ..traumaDecay = 0.0
        ..addTrauma(1.0);
      renderOnce(game);
      expect(cullable.renderCount, 1);

      game.camera.viewfinder.clearTrauma();
      renderOnce(game);
      expect(cullable.renderCount, 1);
    });
  });
}
