import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/components.dart';
import 'package:flame/effects.dart';
import 'package:flutter_test/flutter_test.dart';

class _ElevatedToken({super.position})
    extends PositionComponent
    implements ElevationTarget {
  double currentElevation = 0.0;
  double peakElevation = 0.0;

  @override
  void setElevation(double elevation) {
    currentElevation = elevation;
    if (elevation > peakElevation) {
      peakElevation = elevation;
    }
  }
}

void main() {
  group('ArcMoveEffect & WaypointPathEffect', () {
    test(
      'ArcMoveEffect separates ground position and elevation on target',
      () {
        final token = _ElevatedToken(position: Vector2(10, 20));
        final effect = ArcMoveEffect(
          Vector2(110, 20),
          EffectController(duration: 1.0),
          arcHeight: 36.0,
          target: token,
        )..advance(0.5);

        expect(token.position.x, closeTo(60.0, 1e-4));
        expect(token.position.y, closeTo(20.0, 1e-4));
        expect(token.currentElevation, closeTo(36.0, 1e-4));

        effect.advance(0.5);
        expect(token.position.x, closeTo(110.0, 1e-4));
        expect(token.position.y, closeTo(20.0, 1e-4));
        expect(token.currentElevation, closeTo(0.0, 1e-4));
        expect(token.peakElevation, closeTo(36.0, 1e-4));
      },
    );

    test(
      'ArcMoveEffect offsets 2D position along arcNormal by default',
      () {
        final sprite = PositionComponent(position: Vector2(0, 100));
        final effect = ArcMoveEffect(
          Vector2(80, 100),
          EffectController(duration: 1.0),
          arcHeight: 25.0,
          target: sprite,
        )..advance(0.5);

        expect(sprite.position.x, closeTo(40.0, 1e-4));
        expect(sprite.position.y, closeTo(75.0, 1e-4));

        effect.advance(0.5);
        expect(sprite.position.x, closeTo(80.0, 1e-4));
        expect(sprite.position.y, closeTo(100.0, 1e-4));
      },
    );

    test(
      'WaypointPathEffect traverses spline, orients, and fires callbacks',
      () {
        final reached = <int>[];
        final actor = PositionComponent(position: Vector2.zero());
        final effect = WaypointPathEffect(
          [
            Vector2(50, 0),
            Vector2(50, 50),
            Vector2(100, 50),
          ],
          EffectController(duration: 1.5),
          tension: 0.25,
          oriented: true,
          onWaypointReached: reached.add,
          target: actor,
        )..advance(0.75);

        // Half the time is half the way along the curve, which by the
        // symmetry of this path is the middle of its middle segment.
        expect(actor.position.x, closeTo(50.0, 1e-3));
        expect(actor.position.y, closeTo(25.0, 1e-3));
        expect(reached, [0]);

        effect.advance(0.75);
        expect(actor.position.x, closeTo(100.0, 1e-3));
        expect(actor.position.y, closeTo(50.0, 1e-3));
        expect(actor.angle, closeTo(0.0, 0.25));
        expect(reached, [0, 1, 2]);
      },
    );

    test(
      'MoveAlongPathEffect accepts precomputed PathMetric and resets cleanly',
      () {
        final path = Path()
          ..moveTo(0, 0)
          ..lineTo(0, 40);
        final metric = path.computeMetrics().single;
        final actor = PositionComponent(position: Vector2(5, 10));
        final effect =
            MoveAlongPathEffect(
                path,
                EffectController(duration: 1.0),
                pathMetric: metric,
                oriented: true,
                target: actor,
              )
              ..removeOnFinish = false
              ..advance(1.0);

        expect(actor.position.x, closeTo(5.0, 1e-4));
        expect(actor.position.y, closeTo(50.0, 1e-4));
        expect(actor.angle.abs(), closeTo(math.pi / 2, 1e-3));

        effect.reset();
        actor.position.setValues(5, 10);
        effect.advance(0.5);
        expect(actor.position.y, closeTo(30.0, 1e-4));
      },
    );
  });
}
