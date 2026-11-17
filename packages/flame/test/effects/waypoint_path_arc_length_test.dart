import 'dart:math' as math;

import 'package:flame/components.dart';
import 'package:flame/effects.dart';
import 'package:flutter_test/flutter_test.dart';

/// Advances [effect] in [steps] equal steps over [duration] seconds and
/// returns the distance its [actor] covered in each of them.
List<double> _stepLengths(
  Effect effect,
  PositionComponent actor, {
  required double duration,
  required int steps,
}) {
  final lengths = <double>[];
  var previous = actor.position.clone();
  for (var i = 0; i < steps; i++) {
    effect.advance(duration / steps);
    lengths.add(actor.position.distanceTo(previous));
    previous = actor.position.clone();
  }
  return lengths;
}

void main() {
  group('WaypointPathEffect arc-length parameterization', () {
    // A bendy path whose waypoints are very unevenly spaced.
    List<Vector2> bendyPath() => [
      Vector2(20, 0),
      Vector2(30, 60),
      Vector2(150, 70),
      Vector2(160, 0),
      Vector2(400, 10),
    ];

    test('a linear controller moves the target at constant speed along the '
        'curve', () {
      final actor = PositionComponent(position: Vector2.zero());
      final effect = WaypointPathEffect(
        bendyPath(),
        EffectController(duration: 2.0),
        target: actor,
      );

      final lengths = _stepLengths(effect, actor, duration: 2.0, steps: 200);
      final mean = lengths.reduce((a, b) => a + b) / lengths.length;
      expect(lengths.reduce(math.min), greaterThan(mean * 0.93));
      expect(lengths.reduce(math.max), lessThan(mean * 1.07));
      expect(actor.position.x, closeTo(400, 1e-6));
      expect(actor.position.y, closeTo(10, 1e-6));
    });

    test('measure returns the length of the curve, not of its chords', () {
      final actor = PositionComponent(position: Vector2.zero());
      final effect = WaypointPathEffect(
        bendyPath(),
        EffectController(duration: 1.0),
        samplesPerSegment: 64,
        target: actor,
      );
      final lengths = _stepLengths(effect, actor, duration: 1.0, steps: 4000);
      final travelled = lengths.reduce((a, b) => a + b);

      var chords = 0.0;
      var previous = Vector2.zero();
      for (final point in bendyPath()) {
        chords += point.distanceTo(previous);
        previous = point;
      }

      expect(effect.measure(), closeTo(travelled, travelled * 0.002));
      expect(effect.measure(), greaterThan(chords * 1.02));
    });

    test('more samples per segment measure a curved path more closely', () {
      double measured(int samples) {
        final actor = PositionComponent(position: Vector2.zero());
        final effect = WaypointPathEffect(
          bendyPath(),
          EffectController(duration: 1.0),
          samplesPerSegment: samples,
          target: actor,
        )..advance(0.0);
        return effect.measure();
      }

      final coarse = measured(1);
      final normal = measured(16);
      final fine = measured(256);
      expect(coarse, lessThan(normal));
      expect(normal, lessThanOrEqualTo(fine));
      expect(normal, closeTo(fine, fine * 0.01));
    });

    test('waypoints are reported in order as the target passes them', () {
      final reachedAt = <int, Vector2>{};
      final actor = PositionComponent(position: Vector2.zero());
      final waypoints = bendyPath();
      late final WaypointPathEffect effect;
      effect = WaypointPathEffect(
        waypoints,
        EffectController(duration: 2.0),
        onWaypointReached: (index) {
          expect(reachedAt.length, index);
          reachedAt[index] = actor.position.clone();
        },
        target: actor,
      );
      _stepLengths(effect, actor, duration: 2.0, steps: 2000);

      expect(reachedAt.keys, [0, 1, 2, 3, 4]);
      final stepLength = effect.measure() / 2000;
      for (var i = 0; i < waypoints.length; i++) {
        expect(
          reachedAt[i]!.distanceTo(waypoints[i]),
          lessThan(stepLength * 1.5),
          reason: 'waypoint $i',
        );
      }
    });

    test('straight segments keep their exact length and timing', () {
      final actor = PositionComponent(position: Vector2.zero());
      final effect = WaypointPathEffect(
        [Vector2(30, 0), Vector2(30, 40), Vector2(60, 40)],
        EffectController(duration: 1.0),
        tension: 1.0,
        target: actor,
      )..advance(0.3);

      expect(effect.measure(), closeTo(100, 1e-9));
      expect(actor.position.x, closeTo(30, 1e-9));
      expect(actor.position.y, closeTo(0, 1e-9));

      effect.advance(0.2);
      expect(actor.position.x, closeTo(30, 1e-9));
      expect(actor.position.y, closeTo(20, 1e-9));

      effect.advance(0.5);
      expect(actor.position.x, closeTo(60, 1e-9));
      expect(actor.position.y, closeTo(40, 1e-9));
    });
  });
}
