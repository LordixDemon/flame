import 'dart:math' as math;

import 'package:flame/components.dart' show HasFixedUpdate;
import 'package:flame/game.dart' show FlameGame;
import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/effects.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_test/flame_test.dart';
import 'package:flutter_test/flutter_test.dart';

class _Node({super.position, super.rotation}) extends Component3D;

class _Ball()
    extends Component3D
    with HasFixedUpdate, FixedTransformInterpolation3D {
  final Vector3 velocity = Vector3(6, 0, 0);
  bool frozen = false;

  @override
  void fixedUpdate(double fixedDt) {
    if (frozen) {
      return;
    }
    captureFixedState();
    position.addScaled(velocity, fixedDt);
  }
}

FlameGame _game() => FlameGame(world: World3D());

void main() {
  group('3D effects with speed-based controllers', () {
    testWithGame('MoveToEffect3D moves at the given speed', _game, (
      game,
    ) async {
      final node = _Node(position: Vector3(1, 0, 0));
      await game.world.ensureAdd(node);
      var done = false;
      await node.ensureAdd(
        MoveToEffect3D(
          Vector3(1, 0, 8),
          EffectController(speed: 2),
          onComplete: () => done = true,
        ),
      );
      game.update(1);
      expect(node.position, closeToVector3(Vector3(1, 0, 2), 1e-6));
      game.update(2.9);
      expect(done, isFalse);
      game.update(0.2); // 8 m at 2 m/s: done after 4 s
      expect(done, isTrue);
      expect(node.position, closeToVector3(Vector3(1, 0, 8), 1e-6));
    });

    testWithGame(
      'MoveByEffect3D and ScaleToEffect3D measure their change',
      _game,
      (
        game,
      ) async {
        final node = _Node();
        await game.world.ensureAdd(node);
        final move = MoveByEffect3D(
          Vector3(3, 4, 0),
          EffectController(speed: 5),
        );
        final scale = ScaleToEffect3D(
          Vector3(1, 1, 3),
          EffectController(speed: 1),
        );
        await node.ensureAddAll([move, scale]);
        game.update(0.5);
        expect(node.position, closeToVector3(Vector3(1.5, 2, 0), 1e-6));
        expect(node.scale.z, closeTo(1.5, 1e-6));
        expect(move.controller.duration, closeTo(1, 1e-9));
        expect(scale.controller.duration, closeTo(2, 1e-9));
      },
    );

    testWithGame('rotation effects turn at the given angular speed', _game, (
      game,
    ) async {
      final node = _Node(rotation: Quaternion.identity());
      await game.world.ensureAdd(node);
      final rotateTo = RotateToEffect3D(
        Quaternion.axisAngle(Vector3(0, 1, 0), math.pi / 2),
        EffectController(speed: math.pi),
      );
      await node.ensureAdd(rotateTo);
      game.update(0.01);
      expect(rotateTo.controller.duration, closeTo(0.5, 1e-6));

      final spin = RotateAroundEffect3D(
        axis: Vector3(0, 1, 0),
        radians: 3 * math.pi,
        controller: EffectController(speed: math.pi),
      );
      await node.ensureAdd(spin);
      game.update(0.01);
      expect(spin.controller.duration, closeTo(3, 1e-9));
    });

    testWithGame('arc and spline paths are measured by their length', _game, (
      game,
    ) async {
      Future<double> durationOf(Effect effect) async {
        final node = _Node();
        await game.world.ensureAdd(node);
        await node.ensureAdd(effect);
        game.update(0.01);
        return effect.controller.duration!;
      }

      final flat = await durationOf(
        ArcMoveEffect3D(
          Vector3(4, 0, 0),
          EffectController(speed: 2),
          arcHeight: 0,
        ),
      );
      expect(flat, closeTo(2, 1e-6));

      // The parabola over 4 m with a 1 m peak is 2 * (sqrt(2) + asinh(1)),
      // about 4.591 m long.
      final arc = await durationOf(
        ArcMoveEffect3D(
          Vector3(4, 0, 0),
          EffectController(speed: 2),
          arcHeight: 1,
        ),
      );
      const exact = 2 * (math.sqrt2 + 0.881373587019543);
      expect(arc, closeTo(exact / 2, 0.005));

      final line = await durationOf(
        SplinePathEffect3D(
          CatmullRomSpline3D([
            Vector3.zero(),
            Vector3(3, 0, 0),
            Vector3(6, 0, 0),
          ]),
          EffectController(speed: 3),
        ),
      );
      expect(line, closeTo(2, 1e-6));
    });
  });

  group('FixedTransformInterpolation3D with HasFixedUpdate', () {
    testWithGame(
      'blends between fixed steps by itself with renderInterpolationAlpha',
      () => FlameGame(world: World3D())..fixedTimeStep = 0.1,
      (game) async {
        final ball = _Ball();
        await game.world.ensureAdd(ball);

        game.update(0.1); // one step: x = 0 -> 0.6, alpha = 0
        expect(game.lastFrameFixedSteps, 1);
        expect(ball.position.x, closeTo(0.0, 1e-6));

        game.update(0.05); // no step, alpha = 0.5
        expect(game.lastFrameFixedSteps, 0);
        expect(ball.position.x, closeTo(0.3, 1e-6));

        game.update(0.025); // no step, alpha = 0.75
        expect(ball.position.x, closeTo(0.45, 1e-6));

        game.update(0.05); // one step: x = 0.6 -> 1.2, alpha = 0.25
        expect(ball.position.x, closeTo(0.75, 1e-6));

        ball.restoreSimulatedState();
        expect(ball.position.x, closeTo(1.2, 1e-6));
      },
    );

    testWithGame(
      'shows the simulated transform when its fixed step was skipped',
      () => FlameGame(world: World3D())..fixedTimeStep = 0.1,
      (game) async {
        final ball = _Ball();
        await game.world.ensureAdd(ball);
        game.update(0.1);
        game.update(0.15); // step to 1.2, alpha 0.5 -> 0.9
        expect(ball.position.x, closeTo(0.9, 1e-6));

        ball.frozen = true;
        game.update(0.1); // a step ran, the ball did not move
        expect(ball.position.x, closeTo(1.2, 1e-6));
        game.update(0.03);
        expect(ball.position.x, closeTo(1.2, 1e-6));
      },
    );

    testWithGame(
      'leaves components without HasFixedUpdate to their own driver',
      () => FlameGame(world: World3D())..fixedTimeStep = 0.1,
      (game) async {
        final body = _ManualBody();
        await game.world.ensureAdd(body);
        body
          ..captureFixedState()
          ..position.setValues(1, 0, 0)
          ..commitFixedState()
          ..applyInterpolationAlpha(0.5);
        game.update(0.05);
        expect(body.position.x, closeTo(0.5, 1e-6));
      },
    );
  });
}

class _ManualBody() extends Component3D with FixedTransformInterpolation3D;
