import 'dart:ui';

import 'package:flame/components.dart';
import 'package:flame/rendering.dart';
import 'package:flame_test/flame_test.dart';
import 'package:flutter_test/flutter_test.dart';

/// Moves 10 px to the right per 1/60 s fixed step.
class _Body()
    extends PositionComponent
    with HasFixedUpdate, FixedTransformInterpolation {
  double lastPaintedX = double.nan;
  double lastPaintedY = double.nan;

  @override
  void fixedUpdate(double fixedDt) {
    position.x += 600 * fixedDt;
  }

  @override
  void render(Canvas canvas) {
    final matrix = canvas.getTransform();
    lastPaintedX = matrix[12];
    lastPaintedY = matrix[13];
  }
}

class _HidableBody()
    extends PositionComponent
    with HasVisibility, HasFixedUpdate, FixedTransformInterpolation {
  int paintCount = 0;

  @override
  void fixedUpdate(double fixedDt) {
    position.x += 600 * fixedDt;
  }

  @override
  void render(Canvas canvas) => paintCount++;
}

class _PausableLayer() extends Component with CustomTraversal, HasTimeScale;

void _paint(Component component) {
  final recorder = PictureRecorder();
  component.renderTree(Canvas(recorder));
  recorder.endRecording().dispose();
}

double _round(double value) => double.parse(value.toStringAsFixed(3));

void main() {
  group('FixedTransformInterpolation', () {
    testWithFlameGame(
      'paints a moving body between its previous and its current fixed state',
      (game) async {
        game.fixedTimeStep = 1 / 60;
        final body = _Body()
          ..anchor = Anchor.center
          ..size = Vector2(8, 4)
          ..scale = Vector2(2, 3)
          ..angle = 0.4
          ..position = Vector2(0, 50);
        game.world.add(body);
        await game.ready();

        // Two full steps and half a step: previous x = 10, current x = 20.
        game.update(2.5 / 60);
        expect(game.lastFrameFixedSteps, 2);
        expect(game.renderInterpolationAlpha, closeTo(0.5, 1e-6));
        expect(body.position.x, closeTo(20, 1e-9));

        _paint(body);
        final interpolatedX = body.lastPaintedX;
        final interpolatedY = body.lastPaintedY;

        // The same body drawn at its logical transform, 5 px further right.
        body.fixedInterpolationEnabled = false;
        _paint(body);
        expect(interpolatedX, closeTo(body.lastPaintedX - 5, 1e-6));
        expect(interpolatedY, closeTo(body.lastPaintedY, 1e-6));
      },
    );

    testWithFlameGame(
      'a body whose fixed step is paused settles on its logical position',
      (game) async {
        game.fixedTimeStep = 1 / 60;
        final layer = _PausableLayer();
        final body = _Body();
        layer.add(body);
        game.world.add(layer);
        await game.ready();

        // Three full steps: the body moves, previous != current.
        game.update(3 / 60 + 1e-4);
        expect(game.lastFrameFixedSteps, 3);
        final restX = body.position.x;

        // Pause the subtree (pause menu, hit-stop).
        layer.pause();

        // 120 Hz display frames: the interpolation alpha of the game keeps
        // sweeping between 0 and 1 while the body stands still.
        final painted = <double>[];
        for (var i = 0; i < 8; i++) {
          game.update(1 / 120);
          _paint(body);
          painted.add(_round(body.lastPaintedX));
        }

        expect(body.position.x, restX, reason: 'logically it does not move');
        for (var i = 1; i < painted.length; i++) {
          expect(
            painted[i],
            greaterThanOrEqualTo(painted[i - 1]),
            reason: 'the paused body moved backwards on screen: $painted',
          );
        }
        // Once a fixed pass has run without the body, it is drawn at rest.
        expect(painted.sublist(2).toSet(), {_round(restX)});
      },
    );

    testWithFlameGame(
      'a body that was put to sleep settles on its logical position',
      (game) async {
        game.fixedTimeStep = 1 / 60;
        final body = _Body();
        game.world.add(body);
        await game.ready();
        game.update(3 / 60 + 1e-4);
        final restX = body.position.x;

        body.sleepUpdates();

        final painted = <double>[];
        for (var i = 0; i < 8; i++) {
          game.update(1 / 120);
          _paint(body);
          painted.add(_round(body.lastPaintedX));
        }

        expect(body.position.x, restX);
        expect(painted.sublist(2).toSet(), {_round(restX)});
        expect(game.hasMovingFixedInterpolation, isFalse);
      },
    );

    testWithFlameGame(
      'interpolation resumes when the fixed step runs again',
      (game) async {
        game.fixedTimeStep = 1 / 60;
        final layer = _PausableLayer();
        final body = _Body();
        layer.add(body);
        game.world.add(layer);
        await game.ready();
        game.update(2 / 60 + 1e-4);
        layer.pause();
        game.update(2 / 60);
        layer.resume();

        // One step and a half: previous = current - 10, alpha = 0.5.
        game.resetFixedUpdateAccumulator();
        game.update(1.5 / 60);
        _paint(body);

        expect(game.hasMovingFixedInterpolation, isTrue);
        expect(body.lastPaintedX, closeTo(body.position.x - 5, 1e-6));
      },
    );

    testWithFlameGame(
      'an invisible component is not painted while it moves',
      (game) async {
        game.fixedTimeStep = 1 / 60;
        final body = _HidableBody()..isVisible = false;
        game.world.add(body);
        await game.ready();

        // One full step plus half a step: previous != current, alpha == 0.5.
        game.update(1.5 / 60);
        expect(game.lastFrameFixedSteps, 1);
        expect(game.renderInterpolationAlpha, closeTo(0.5, 1e-6));

        _paint(body);
        expect(body.paintCount, 0);

        body.isVisible = true;
        _paint(body);
        expect(body.paintCount, 1);
      },
    );

    testWithFlameGame(
      'explicit decorator bounds reach the decorators while interpolating',
      (game) async {
        game.fixedTimeStep = 1 / 60;
        final tint = PaintDecorator.tint(const Color(0x40FF0000));
        final body = _Body()
          ..size = Vector2(20, 10)
          ..decoratorBounds = const Rect.fromLTWH(0, 0, 20, 10)
          ..decorator.addLast(tint);
        game.world.add(body);
        await game.ready();
        game.update(1.5 / 60);

        _paint(body);

        expect(tint.lastSaveLayerBounds, isNotNull);
        expect(body.lastPaintedX, closeTo(body.position.x - 5, 1e-6));
      },
    );
  });
}
