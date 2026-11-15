import 'dart:math' as math;

import 'package:flame/extensions.dart';
import 'package:flame/math.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('GameMath, OklabColor, SimplexNoise2D & SeededRng (#11, #30)', () {
    test('GameMath angle wrapping, remap, pingPong, and splines', () {
      expect(
        GameMath.deltaAngle(0.1, math.pi * 2 - 0.1),
        closeTo(-0.2, 1e-6),
      );
      expect(
        GameMath.deltaAngle(math.pi - 0.1, -math.pi + 0.1),
        closeTo(0.2, 1e-6),
      );

      expect(GameMath.inverseLerp(10, 30, 20), closeTo(0.5, 1e-6));
      expect(GameMath.inverseLerp(10, 10, 20), 0.0);
      expect(
        GameMath.remap(5, 0, 10, 100, 200, clampResult: true),
        closeTo(150.0, 1e-6),
      );
      expect(
        GameMath.remap(25, 0, 10, 100, 200, clampResult: true),
        closeTo(200.0, 1e-6),
      );

      expect(GameMath.pingPong(0.0, 4.0), closeTo(0.0, 1e-6));
      expect(GameMath.pingPong(4.0, 4.0), closeTo(4.0, 1e-6));
      expect(GameMath.pingPong(6.0, 4.0), closeTo(2.0, 1e-6));

      expect(GameMath.hermite(0, 0, 10, 0, 0.0), closeTo(0.0, 1e-6));
      expect(GameMath.hermite(0, 0, 10, 0, 0.5), closeTo(5.0, 1e-6));
      expect(GameMath.hermite(0, 0, 10, 0, 1.0), closeTo(10.0, 1e-6));

      expect(GameMath.cubicBezier(0, 0, 10, 10, 0.5), closeTo(5.0, 1e-6));
    });

    test(
      'GameMath.smoothDamp, smoothDampAngle & smoothDampVector2 converge '
      'without overshoot',
      () {
        final state = SmoothDampState();
        var pos = 0.0;
        for (var i = 0; i < 120; i++) {
          pos = GameMath.smoothDamp(pos, 100.0, state, 0.15, 1.0 / 60.0);
          expect(pos, lessThanOrEqualTo(100.0001));
        }
        expect(pos, closeTo(100.0, 0.05));

        final angleState = SmoothDampState();
        var angle = math.pi - 0.05;
        const targetAngle = -math.pi + 0.05;
        for (var i = 0; i < 90; i++) {
          angle = GameMath.smoothDampAngle(
            angle,
            targetAngle,
            angleState,
            0.1,
            1.0 / 60.0,
          );
        }
        expect(GameMath.deltaAngle(angle, targetAngle).abs(), lessThan(0.01));

        final vCurr = Vector2.zero();
        final vTarget = Vector2(50, -30);
        final vVel = Vector2.zero();
        final vOut = Vector2.zero();
        for (var i = 0; i < 120; i++) {
          GameMath.smoothDampVector2(
            vCurr,
            vTarget,
            vVel,
            0.12,
            1.0 / 60.0,
            vOut,
          );
          vCurr.setFrom(vOut);
        }
        expect(vCurr.distanceTo(vTarget), lessThan(0.05));
      },
    );

    test('OklabColor roundtrips sRGB and interpolates cleanly', () {
      const sample = Color(0xFFE53935);
      final roundtripped = OklabColor.fromColor(sample).toColor();
      expect((roundtripped.r - sample.r).abs(), lessThan(0.01));
      expect((roundtripped.g - sample.g).abs(), lessThan(0.01));
      expect((roundtripped.b - sample.b).abs(), lessThan(0.01));

      const blue = Color(0xFF1E88E5);
      const yellow = Color(0xFFFDD835);
      final midLab = OklabColor.lerp(blue, yellow, 0.5);
      final midLch = OklabColor.lerpOklch(blue, yellow, 0.5);
      expect(midLab.a, closeTo(1.0, 1e-4));
      expect(midLch.a, closeTo(1.0, 1e-4));
      expect(OklabColor.fromColor(midLch).l, greaterThan(0.55));
    });

    test(
      'SimplexNoise2D is seed-deterministic and bounded in [-1, 1]',
      () {
        final noiseA = SimplexNoise2D(seed: 42);
        final noiseB = SimplexNoise2D(seed: 42);
        final noiseC = SimplexNoise2D(seed: 99);

        var differsFromOtherSeed = false;
        for (var y = 0; y < 12; y++) {
          for (var x = 0; x < 12; x++) {
            final sx = x * 0.23;
            final sy = y * 0.37;
            final a = noiseA.sample(sx, sy);
            final b = noiseB.sample(sx, sy);
            final c = noiseC.sample(sx, sy);
            expect(a, b);
            expect(a, inInclusiveRange(-1.0, 1.0));
            if ((a - c).abs() > 1e-4) {
              differsFromOtherSeed = true;
            }
            final fbmVal = noiseA.fbm(sx, sy);
            expect(fbmVal, inInclusiveRange(-1.0, 1.0));
          }
        }
        expect(differsFromOtherSeed, isTrue);
      },
    );

    test(
      'SeededRng determinism, saveState/restoreState, non-mutating fork, and '
      'spatial sampling',
      () {
        final rng1 = SeededRng(2026);
        final rng2 = SeededRng(2026);

        for (var i = 0; i < 20; i++) {
          expect(rng1.nextUint32(), rng2.nextUint32());
        }

        // Snapshot state mid-stream and verify forked substream does NOT
        // advance parent!
        final saved = rng1.saveState();
        final lootForkA = rng1.fork('loot_drop');
        final lootForkB = rng2.fork('loot_drop');
        expect(lootForkA.nextUint32(), lootForkB.nextUint32());

        // Parent generators remain bit-for-bit synchronized after fork().
        final expectedSeq = <double>[
          for (var i = 0; i < 10; i++) rng1.nextDouble(),
        ];
        final restored = SeededRng.fromStateBytes(saved);
        final replayedSeq = <double>[
          for (var i = 0; i < 10; i++) restored.nextDouble(),
        ];
        expect(replayedSeq, expectedSeq);

        // Weighted pick & shuffle & spatial sampling.
        final counts = <String, int>{'common': 0, 'rare': 0};
        for (var i = 0; i < 400; i++) {
          final item = rng1.weightedPick<String>(
            const <String>['common', 'rare'],
            const <double>[9.0, 1.0],
          );
          counts[item] = (counts[item] ?? 0) + 1;
        }
        expect(counts['common'], greaterThan((counts['rare'] ?? 0) * 3));

        final deck = <int>[1, 2, 3, 4, 5, 6];
        SeededRng(77).shuffle(deck);
        final deckCopy = <int>[1, 2, 3, 4, 5, 6];
        SeededRng(77).shuffle(deckCopy);
        expect(deck, deckCopy);

        final pt = Vector2.zero();
        for (var i = 0; i < 32; i++) {
          rng1.pointInCircle(10.0, pt);
          expect(pt.length, lessThanOrEqualTo(10.0001));
          rng1.pointInAnnulus(4.0, 8.0, pt);
          expect(pt.length, inInclusiveRange(3.9999, 8.0001));
        }
      },
    );

    test(
      'CommandRecorder serializes and replays tick-stamped commands',
      () {
        final recorder = CommandRecorder<String>(initialSeed: 9001)
          ..record(0, 'spawn_hero')
          ..record(4, 'roll_dice')
          ..record(4, 'use_card');

        final json = recorder.toJson((cmd) => cmd);
        final decoded = CommandRecorder.fromJson<String>(
          json,
          (raw) => raw! as String,
        );

        expect(decoded.initialSeed, 9001);
        expect(decoded.length, 3);
        final tick4 = <String>[];
        decoded.collectForTick(4, tick4);
        expect(tick4, <String>['roll_dice', 'use_card']);
      },
    );
  });
}
