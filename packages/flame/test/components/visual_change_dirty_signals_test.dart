import 'dart:ui' as ui;

import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flame/parallax.dart';
import 'package:flame_test/flame_test.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// The two signals that a component has to raise when it starts drawing
/// something else without moving:
///  - `Component.subtreeVersion` on itself and on its ancestors, which the
///    retained camera layers (`CameraLayerCacheMode.splitRetained`) read;
///  - `Game.visualMutationCount`, which on-demand rendering
///    (`IdleRenderMode`) reads.
class _DirtySignals(Component component, FlameGame game) {
  final Component _component = component;
  final FlameGame _game = game;
  int _subtree = component.subtreeVersion;
  int _world = game.world.subtreeVersion;
  int _visual = Game.visualMutationCount;
  int _transforms = Transform2D.globalMutationCount;

  void reset() {
    _subtree = _component.subtreeVersion;
    _world = _game.world.subtreeVersion;
    _visual = Game.visualMutationCount;
    _transforms = Transform2D.globalMutationCount;
  }

  /// Expects that both signals were raised since the last [reset], and that
  /// this did not happen as a side effect of a transform change.
  void expectRaised(String what) {
    expect(
      _component.subtreeVersion,
      greaterThan(_subtree),
      reason: '$what must mark the component subtree dirty',
    );
    expect(
      _game.world.subtreeVersion,
      greaterThan(_world),
      reason: '$what must mark the ancestors of the component dirty',
    );
    expect(
      Game.visualMutationCount,
      greaterThan(_visual),
      reason: '$what must notify a visual mutation',
    );
    expect(
      Transform2D.globalMutationCount,
      _transforms,
      reason: '$what is not expected to change a transform in this test',
    );
    reset();
  }

  void expectQuiet(String what) {
    expect(_component.subtreeVersion, _subtree, reason: what);
    expect(Game.visualMutationCount, _visual, reason: what);
  }
}

Future<FlameGame> _startGame({CameraComponent? camera, World? world}) async {
  final game = FlameGame(world: world, camera: camera)
    ..onGameResize(Vector2(400, 300));
  await game.start();
  return game;
}

/// Renders one frame the way `GameRenderBox.paint` does.
void _renderFrame(FlameGame game) {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder, const ui.Rect.fromLTWH(0, 0, 400, 300));
  game.onFrameRendered();
  game.render(canvas);
  recorder.endRecording().dispose();
}

Future<int> _paintsDuring(
  WidgetTester tester,
  FlameGame game,
  int frames,
) async {
  final before = game.executedRenderFrames;
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(microseconds: 16667));
  }
  return game.executedRenderFrames - before;
}

Future<void> main() async {
  final imageA = await generateImage(8, 8);
  final imageB = await generateImage(8, 8);

  SpriteAnimation twoFrames({bool loop = true}) => SpriteAnimation.spriteList(
    [Sprite(imageA), Sprite(imageB)],
    stepTime: 0.1,
    loop: loop,
  );

  group('Both dirty signals are raised when the picture changes', () {
    test('SpriteComponent.sprite', () async {
      final game = await _startGame();
      final component = SpriteComponent(
        sprite: Sprite(imageA),
        size: Vector2.all(8),
      );
      game.world.add(component);
      await game.ready();
      final signals = _DirtySignals(component, game);

      component.sprite = Sprite(imageB);
      signals.expectRaised('assigning another sprite');
    });

    test('SpriteGroupComponent.current, sprites and updateSprite', () async {
      final game = await _startGame();
      final component = SpriteGroupComponent<int>(
        sprites: {0: Sprite(imageA), 1: Sprite(imageB)},
        current: 0,
        size: Vector2.all(8),
      );
      game.world.add(component);
      await game.ready();
      final signals = _DirtySignals(component, game);

      component.current = 1;
      signals.expectRaised('selecting another sprite');

      component.current = 1;
      signals.expectQuiet('selecting the current sprite again');

      component.updateSprite(1, Sprite(imageA));
      signals.expectRaised('replacing a sprite of the group');

      component.sprites = {0: Sprite(imageB), 1: Sprite(imageA)};
      signals.expectRaised('replacing the sprites of the group');
    });

    test('SpriteAnimationComponent frames and animation', () async {
      final game = await _startGame();
      final component = SpriteAnimationComponent(
        animation: twoFrames(),
        size: Vector2.all(8),
      );
      game.world.add(component);
      await game.ready();
      game.update(0);
      final signals = _DirtySignals(component, game);

      game.update(0.05);
      signals.expectQuiet('a tick that stays on the same frame');

      game.update(0.06);
      signals.expectRaised('advancing to the next frame');

      component.animation = twoFrames(loop: false);
      signals.expectRaised('assigning another animation');

      // The ticker is moved from the outside while the animation is paused.
      component.playing = false;
      component.animationTicker!.setToLast();
      game.update(0.01);
      signals.expectRaised('moving the ticker to another frame');

      game.update(0.5);
      signals.expectQuiet('a paused animation');
    });

    test('SpriteAnimationGroupComponent frames, current and '
        'animations', () async {
      final game = await _startGame();
      final component = SpriteAnimationGroupComponent<int>(
        animations: {0: twoFrames(), 1: twoFrames()},
        current: 0,
        size: Vector2.all(8),
      );
      game.world.add(component);
      await game.ready();
      game.update(0);
      final signals = _DirtySignals(component, game);

      game.update(0.11);
      signals.expectRaised('advancing to the next frame');

      component.current = 1;
      signals.expectRaised('selecting another animation');

      component.animations = {0: twoFrames(), 1: twoFrames()};
      signals.expectRaised('replacing the animations of the group');

      component.playing = false;
      game.update(0.5);
      signals.expectQuiet('a paused animation');
    });

    test('ParallaxComponent scrolling', () async {
      final game = await _startGame();
      final parallax = Parallax(
        [ParallaxLayer(ParallaxImage(imageA))],
        size: Vector2(400, 300),
        baseVelocity: Vector2(20, 0),
      );
      final component = ParallaxComponent(
        parallax: parallax,
        size: Vector2(400, 300),
      );
      game.world.add(component);
      await game.ready();
      game.update(0);
      final signals = _DirtySignals(component, game);

      game.update(1 / 60);
      signals.expectRaised('scrolling the layers');

      parallax.baseVelocity.setZero();
      game.update(1 / 60);
      signals.expectQuiet('a parallax that stands still');

      component.parallax = Parallax(
        [ParallaxLayer(ParallaxImage(imageB))],
        size: Vector2(400, 300),
      );
      signals.expectRaised('assigning another parallax');
    });

    test('TextBoxComponent typewriter text', () async {
      final game = await _startGame();
      final component = TextBoxComponent(
        text: 'A line of text that is typed out one character at a time',
        boxConfig: const TextBoxConfig(timePerChar: 0.1),
        size: Vector2(300, 100),
      );
      game.world.add(component);
      await game.ready();
      await component.redraw();
      final typedBefore = component.cache;
      final visualBefore = Game.visualMutationCount;
      final subtreeBefore = component.subtreeVersion;

      // Half a second later five more characters are visible; the new image
      // of the box is rendered asynchronously.
      game.update(0.5);
      for (var i = 0; i < 200 && identical(component.cache, typedBefore); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      expect(component.cache, isNot(same(typedBefore)));
      expect(component.subtreeVersion, greaterThan(subtreeBefore));
      expect(Game.visualMutationCount, greaterThan(visualBefore));
    });

    test('HasPaint.paint', () async {
      final game = await _startGame();
      final component = RectangleComponent(size: Vector2.all(20));
      game.world.add(component);
      await game.ready();
      final signals = _DirtySignals(component, game);

      component.paint = Paint()..color = const Color(0xFF00FF00);
      signals.expectRaised('assigning another paint');

      // Reassigning the same object is how a change that was made directly
      // on the paint is published.
      component.paint = component.paint..color = const Color(0xFF0000FF);
      signals.expectRaised('reassigning the changed paint');
    });
  });

  group('On-demand rendering repaints after the picture changed', () {
    Future<FlameGame> pumpGame(
      WidgetTester tester,
      Component component, {
      bool inWorld = true,
    }) async {
      final game = FlameGame()..idleRenderMode = IdleRenderMode.onDemand;
      if (inWorld) {
        game.world.add(component);
      } else {
        game.add(component);
      }
      await tester.pumpWidget(GameWidget(game: game));
      await tester.pump();
      await _paintsDuring(tester, game, 10);
      return game;
    }

    testWidgets('a static scene is not repainted', (tester) async {
      final game = await pumpGame(
        tester,
        SpriteComponent(sprite: Sprite(imageA), size: Vector2.all(8)),
      );
      expect(await _paintsDuring(tester, game, 30), 0);
    });

    testWidgets('SpriteComponent.sprite', (tester) async {
      final component = SpriteComponent(
        sprite: Sprite(imageA),
        size: Vector2.all(8),
      );
      final game = await pumpGame(tester, component);
      expect(await _paintsDuring(tester, game, 10), 0);

      component.sprite = Sprite(imageB);
      expect(await _paintsDuring(tester, game, 2), 1);
    });

    testWidgets('SpriteGroupComponent.current', (tester) async {
      final component = SpriteGroupComponent<int>(
        sprites: {0: Sprite(imageA), 1: Sprite(imageB)},
        current: 0,
        size: Vector2.all(8),
      );
      final game = await pumpGame(tester, component);
      expect(await _paintsDuring(tester, game, 10), 0);

      component.current = 1;
      expect(await _paintsDuring(tester, game, 2), 1);
    });

    testWidgets('HasPaint.paint', (tester) async {
      final component = RectangleComponent(size: Vector2.all(20));
      final game = await pumpGame(tester, component);
      expect(await _paintsDuring(tester, game, 10), 0);

      component.paint = Paint()..color = const Color(0xFF00FF00);
      expect(await _paintsDuring(tester, game, 2), 1);
    });

    testWidgets('a scrolling ParallaxComponent is repainted every frame', (
      tester,
    ) async {
      final parallax = Parallax(
        [ParallaxLayer(ParallaxImage(imageA))],
        baseVelocity: Vector2(20, 0),
      );
      final game = await pumpGame(
        tester,
        ParallaxComponent(parallax: parallax),
        inWorld: false,
      );
      expect(await _paintsDuring(tester, game, 30), 30);

      // Once it stops scrolling, the scene is clean again.
      parallax.baseVelocity.setZero();
      await _paintsDuring(tester, game, 2);
      expect(await _paintsDuring(tester, game, 30), 0);
    });
  });

  group('A retained world layer is re-recorded after the picture changed', () {
    Future<(FlameGame, CameraComponent)> startRetainedGame(
      Component component,
    ) async {
      final world = World();
      final camera = CameraComponent(
        world: world,
        layerCacheMode: CameraLayerCacheMode.splitRetained,
      );
      final game = await _startGame(world: world, camera: camera);
      world.add(component);
      await game.ready();
      game.update(1 / 60);
      _renderFrame(game);
      game.update(1 / 60);
      _renderFrame(game);
      return (game, camera);
    }

    void expectRerecorded(
      FlameGame game,
      CameraComponent camera,
      void Function() change,
    ) {
      // An unchanged frame is served from the retained picture.
      final rebuildsBefore = camera.worldCacheRebuildCount;
      final hitsBefore = camera.worldCacheHitCount;
      game.update(1 / 60);
      _renderFrame(game);
      expect(camera.worldCacheRebuildCount, rebuildsBefore);
      expect(camera.worldCacheHitCount, hitsBefore + 1);

      change();
      game.update(1 / 60);
      _renderFrame(game);
      expect(
        camera.worldCacheRebuildCount,
        rebuildsBefore + 1,
        reason: 'the retained picture still shows the old state',
      );
    }

    test('SpriteComponent.sprite', () async {
      final component = SpriteComponent(
        sprite: Sprite(imageA),
        size: Vector2.all(8),
      );
      final (game, camera) = await startRetainedGame(component);
      expectRerecorded(game, camera, () => component.sprite = Sprite(imageB));
    });

    test('SpriteGroupComponent.current', () async {
      final component = SpriteGroupComponent<int>(
        sprites: {0: Sprite(imageA), 1: Sprite(imageB)},
        current: 0,
        size: Vector2.all(8),
      );
      final (game, camera) = await startRetainedGame(component);
      expectRerecorded(game, camera, () => component.current = 1);
    });

    test('SpriteAnimationGroupComponent.current', () async {
      final component = SpriteAnimationGroupComponent<int>(
        animations: {0: twoFrames(), 1: twoFrames()},
        current: 0,
        playing: false,
        size: Vector2.all(8),
      );
      final (game, camera) = await startRetainedGame(component);
      expectRerecorded(game, camera, () => component.current = 1);
    });

    test('HasPaint.paint', () async {
      final component = RectangleComponent(size: Vector2.all(20));
      final (game, camera) = await startRetainedGame(component);
      expectRerecorded(
        game,
        camera,
        () => component.paint = (Paint()..color = const Color(0xFF00FF00)),
      );
    });

    test('ParallaxComponent scrolling', () async {
      final parallax = Parallax(
        [ParallaxLayer(ParallaxImage(imageA))],
        size: Vector2(400, 300),
      );
      final component = ParallaxComponent(
        parallax: parallax,
        size: Vector2(400, 300),
      );
      final (game, camera) = await startRetainedGame(component);
      expectRerecorded(
        game,
        camera,
        () => parallax.baseVelocity.setValues(20, 0),
      );
    });
  });
}
