import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flame/math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';

class const _SimCmd(final String action, final int delta);

void main() {
  group('GameMath exhaustive edge cases & invariants', () {
    test('deltaAngle handles multi-turn wrap-around and +-pi seam', () {
      expect(GameMath.deltaAngle(0.0, 0.0), closeTo(0.0, 1e-9));
      expect(
        GameMath.deltaAngle(0.1, 2 * math.pi - 0.1),
        closeTo(-0.2, 1e-9),
      );
      expect(
        GameMath.deltaAngle(2 * math.pi - 0.1, 0.1),
        closeTo(0.2, 1e-9),
      );
      expect(
        GameMath.deltaAngle(-3.0 * math.pi + 0.25, 5.0 * math.pi - 0.15),
        closeTo(-0.4, 1e-9),
      );
      expect(
        GameMath.deltaAngle(0.0, math.pi).abs(),
        closeTo(math.pi, 1e-9),
      );
    });

    test(
      'inverseLerp and remap handle zero-span, inverted & clamped spans',
      () {
        expect(GameMath.inverseLerp(10.0, 10.0, 10.0), 0.0);
        expect(GameMath.inverseLerp(10.0, 20.0, 5.0), 0.0);
        expect(GameMath.inverseLerp(10.0, 20.0, 25.0), 1.0);
        expect(GameMath.inverseLerp(20.0, 10.0, 17.5), closeTo(0.25, 1e-9));

        // Zero input span returns outMin safely without NaN/Infinity.
        expect(GameMath.remap(5.0, 3.0, 3.0, 100.0, 200.0), 100.0);

        // Unclamped extrapolation vs clamped output, including inverted output.
        expect(
          GameMath.remap(15.0, 0.0, 10.0, 100.0, 0.0),
          closeTo(-50.0, 1e-9),
        );
        expect(
          GameMath.remap(15.0, 0.0, 10.0, 100.0, 0.0, clampResult: true),
          closeTo(0.0, 1e-9),
        );
        expect(
          GameMath.remap(-5.0, 0.0, 10.0, 100.0, 0.0, clampResult: true),
          closeTo(100.0, 1e-9),
        );
      },
    );

    test('pingPong handles zero/negative length and negative time', () {
      expect(GameMath.pingPong(5.0, 0.0), 0.0);
      expect(GameMath.pingPong(5.0, -3.0), 0.0);
      expect(GameMath.pingPong(0.0, 4.0), closeTo(0.0, 1e-9));
      expect(GameMath.pingPong(4.0, 4.0), closeTo(4.0, 1e-9));
      expect(GameMath.pingPong(6.5, 4.0), closeTo(1.5, 1e-9));
      expect(GameMath.pingPong(-1.25, 4.0), closeTo(1.25, 1e-9));
      expect(GameMath.pingPong(-6.5, 4.0), closeTo(1.5, 1e-9));
    });

    test('smoothDamp, smoothDampAngle & smoothDampVector2 never overshoot', () {
      final s = SmoothDampState();
      // Zero / negative dt is a strict no-op.
      expect(GameMath.smoothDamp(2.0, 10.0, s, 0.2, 0.0), 2.0);
      expect(GameMath.smoothDamp(2.0, 10.0, s, 0.2, -0.016), 2.0);

      var x = 0.0;
      for (var i = 0; i < 180; i++) {
        x = GameMath.smoothDamp(x, 100.0, s, 0.12, 1.0 / 60.0);
        expect(x, lessThanOrEqualTo(100.0));
        expect(x, greaterThanOrEqualTo(0.0));
      }
      expect(x, closeTo(100.0, 1e-2));

      // Respects maxSpeed ceiling on initial step.
      final cappedState = SmoothDampState();
      final step1 = GameMath.smoothDamp(
        0.0,
        1000.0,
        cappedState,
        0.05,
        0.1,
        maxSpeed: 20.0,
      );
      expect(step1, lessThan(5.0));

      // Angular spring crosses +pi/-pi along shortest arc.
      final angState = SmoothDampState();
      var angle = math.pi - 0.15;
      const targetAngle = -math.pi + 0.15;
      for (var i = 0; i < 90; i++) {
        angle = GameMath.smoothDampAngle(
          angle,
          targetAngle,
          angState,
          0.08,
          1.0 / 60.0,
        );
      }
      expect(GameMath.deltaAngle(angle, targetAngle).abs(), lessThan(1e-3));

      // 2D vector critically damped spring with zero-dt guard and maxSpeed.
      final curr = Vector2(0, 0);
      final target = Vector2(300, -400);
      final vel = Vector2.zero();
      final out = Vector2(-1, -1);
      GameMath.smoothDampVector2(curr, target, vel, 0.15, 0.0, out);
      expect(out, Vector2.zero());

      for (var i = 0; i < 180; i++) {
        GameMath.smoothDampVector2(
          curr,
          target,
          vel,
          0.12,
          1.0 / 60.0,
          out,
          maxSpeed: 2500.0,
        );
        curr.setFrom(out);
      }
      expect(curr.distanceTo(target), lessThan(0.05));
    });

    test(
      'hermite and cubicBezier satisfy endpoint and midpoint identities',
      () {
        expect(GameMath.hermite(2.0, 5.0, 10.0, -3.0, 0.0), closeTo(2.0, 1e-9));
        expect(
          GameMath.hermite(2.0, 5.0, 10.0, -3.0, 1.0),
          closeTo(10.0, 1e-9),
        );
        // Zero tangents produce smooth S-curve with exact midpoint 0.5*(p0+p1).
        expect(GameMath.hermite(0.0, 0.0, 10.0, 0.0, 0.5), closeTo(5.0, 1e-9));

        expect(
          GameMath.cubicBezier(1.0, 4.0, 8.0, 12.0, 0.0),
          closeTo(1.0, 1e-9),
        );
        expect(
          GameMath.cubicBezier(1.0, 4.0, 8.0, 12.0, 1.0),
          closeTo(12.0, 1e-9),
        );
        // Collinear control points reproduce linear interpolation.
        expect(
          GameMath.cubicBezier(0.0, 10.0 / 3.0, 20.0 / 3.0, 10.0, 0.37),
          closeTo(3.7, 1e-9),
        );
      },
    );
  });

  group('OklabColor & SimplexNoise2D exhaustive verification', () {
    test('OklabColor roundtrips primaries, greys & alpha accurately', () {
      const palette = <Color>[
        Color(0xFF000000),
        Color(0xFFFFFFFF),
        Color(0xFFFF0000),
        Color(0xFF00FF00),
        Color(0xFF0000FF),
        Color(0x8034A853),
        Color(0xCCFBBC05),
        Color(0x407E57C2),
      ];
      for (final c in palette) {
        final back = OklabColor.fromColor(c).toColor();
        expect(back.r, closeTo(c.r, 0.01));
        expect(back.g, closeTo(c.g, 0.01));
        expect(back.b, closeTo(c.b, 0.01));
        expect(back.a, closeTo(c.a, 0.005));
      }

      // Oklab/OKLCH midpoint between pure cyan and pure red stays bright, not
      // dark muddy sRGB grey, and degenerates gracefully on achromatic stops.
      final midLab = OklabColor.lerp(
        const Color(0xFF00FFFF),
        const Color(0xFFFF0000),
        0.5,
      );
      final midLch = OklabColor.lerpOklch(
        const Color(0xFF00FFFF),
        const Color(0xFFFF0000),
        0.5,
      );
      expect(OklabColor.fromColor(midLab).l, greaterThan(0.65));
      expect(OklabColor.fromColor(midLch).l, greaterThan(0.65));

      final greySweep = OklabColor.lerpOklch(
        const Color(0xFF000000),
        const Color(0xFFFFFFFF),
        0.5,
      );
      expect(greySweep.r, closeTo(greySweep.g, 0.01));
      expect(greySweep.g, closeTo(greySweep.b, 0.01));
    });

    test('SimplexNoise2D is bounded, continuous, and seed-isolated', () {
      final n1 = SimplexNoise2D(seed: 42);
      final n1Clone = SimplexNoise2D(seed: 42);
      final n2 = SimplexNoise2D(seed: 9999);

      var diffSeeds = 0;
      for (var y = -10; y <= 10; y++) {
        for (var x = -10; x <= 10; x++) {
          final px = x * 0.37;
          final py = y * 0.41;
          final v = n1.sample(px, py);
          expect(v, inInclusiveRange(-1.0, 1.0));
          expect(v, n1Clone.sample(px, py));
          if ((v - n2.sample(px, py)).abs() > 1e-4) {
            diffSeeds++;
          }
          final f = n1.fbm(px, py, octaves: 5, lacunarity: 2.1, gain: 0.48);
          expect(f, inInclusiveRange(-1.0, 1.0));
        }
      }
      expect(diffSeeds, greaterThan(350));
      expect(n1.fbm(1.2, 3.4, octaves: 0), 0.0);

      // Local spatial continuity check (tiny step produces tiny delta).
      final base = n1.sample(3.14, -2.71);
      final nearby = n1.sample(3.1405, -2.7095);
      expect((nearby - base).abs(), lessThan(0.02));
    });
  });

  group('SeededRng & CommandRecorder determinism and boundary guards', () {
    test('saveState/restoreState/fromStateBytes & fork non-mutation', () {
      final rng = SeededRng(0xCAFEBABE);
      for (var i = 0; i < 25; i++) {
        rng.nextUint32();
      }
      // Prime spare Gaussian before snapshot to verify clean cache reset.
      rng.gaussian();
      final snap = rng.saveState();
      expect(snap.length, 16);

      // Forking must NOT mutate parent stream!
      final childLoot = rng.fork('loot');
      final childLootSame = SeededRng.fromStateBytes(snap).fork('loot');
      final childAi = SeededRng.fromStateBytes(snap).fork('ai');
      expect(childLoot.nextUint32(), childLootSame.nextUint32());
      expect(childLoot.nextUint32(), isNot(childAi.nextUint32()));

      final restored = SeededRng.fromStateBytes(snap);
      for (var i = 0; i < 100; i++) {
        expect(rng.nextUint32(), restored.nextUint32());
      }

      // All-zero state bytes recover safely to non-zero Xoshiro lane.
      final zeroRng = SeededRng(1)..restoreState(Uint8List(16));
      expect(zeroRng.nextUint32(), greaterThan(0));
      expect(
        () => zeroRng.restoreState(Uint8List(15)),
        throwsArgumentError,
      );
    });

    test('distributions, spatial samplers & invalid-argument guards', () {
      final rng = SeededRng(2026);
      // Power-of-two and non-power-of-two nextInt bounds.
      for (var i = 0; i < 200; i++) {
        expect(rng.nextInt(16), inInclusiveRange(0, 15));
        expect(rng.nextInt(13), inInclusiveRange(0, 12));
        expect(rng.rangeInt(-5, 5), inInclusiveRange(-5, 5));
        expect(rng.rangeDouble(-2.0, 3.0), inInclusiveRange(-2.0, 3.0));
      }
      expect(rng.rangeInt(7, 7), 7);
      expect(rng.nextBool(0.0), isFalse);
      expect(rng.nextBool(1.0), isTrue);

      // Gaussian empirical mean & stdDev across 2,000 samples.
      var sum = 0.0;
      var sumSq = 0.0;
      const n = 2000;
      for (var i = 0; i < n; i++) {
        final g = rng.gaussian(mean: 10.0, stdDev: 2.0);
        sum += g;
        sumSq += (g - 10.0) * (g - 10.0);
      }
      expect(sum / n, closeTo(10.0, 0.2));
      expect(math.sqrt(sumSq / n), closeTo(2.0, 0.2));

      // Weighted pick ignores zero/negative weights and matches ratios.
      final counts = <int>[0, 0, 0];
      for (var i = 0; i < 4000; i++) {
        counts[rng.weightedPickIndex(<double>[0.0, 1.0, 3.0])]++;
      }
      expect(counts[0], 0);
      expect(counts[2] / counts[1], closeTo(3.0, 0.35));
      expect(
        rng.weightedPick(<String>['a', 'b'], <double>[0.0, 5.0]),
        'b',
      );

      // Shuffle preserves multiset.
      final deck = List<int>.generate(20, (i) => i);
      rng.shuffle(deck);
      expect(deck.toSet().length, 20);

      // Spatial disk & annulus strict radius bounds.
      final pt = Vector2.zero();
      for (var i = 0; i < 200; i++) {
        rng.pointInCircle(12.0, pt);
        expect(pt.length, lessThanOrEqualTo(12.0 + 1e-6));
        rng.pointInAnnulus(5.0, 9.0, pt);
        expect(pt.length, inInclusiveRange(5.0 - 1e-6, 9.0 + 1e-6));
      }

      // Guard throws.
      expect(() => rng.nextInt(0), throwsRangeError);
      expect(() => rng.rangeInt(5, 4), throwsArgumentError);
      expect(() => rng.pick(<int>[]), throwsStateError);
      expect(() => rng.weightedPickIndex(<double>[0, -1]), throwsStateError);
      expect(
        () => rng.weightedPick(<String>['a'], <double>[1.0, 2.0]),
        throwsArgumentError,
      );
    });

    test('CommandRecorder roundtrips JSON and replays bit-identically', () {
      int runSimulation(CommandRecorder<_SimCmd> log) {
        final rng = SeededRng(log.initialSeed);
        final tickCmds = <_SimCmd>[];
        var score = 0;
        for (var tick = 0; tick < 20; tick++) {
          log.collectForTick(tick, tickCmds);
          for (final cmd in tickCmds) {
            if (cmd.action == 'boost') {
              score += cmd.delta * rng.rangeInt(1, 6);
            } else if (cmd.action == 'shield') {
              score -= cmd.delta;
            }
          }
          score += rng.nextInt(10);
        }
        return score;
      }

      final rec = CommandRecorder<_SimCmd>(initialSeed: 0x1234F00D)
        ..record(0, const _SimCmd('boost', 3))
        ..record(4, const _SimCmd('boost', 5))
        ..record(4, const _SimCmd('shield', 2))
        ..record(15, const _SimCmd('boost', 7));
      expect(rec.length, 4);
      expect(() => rec.entries.clear(), throwsUnsupportedError);

      final scoreA = runSimulation(rec);
      final encoded = jsonEncode(
        rec.toJson(
          (c) => <String, Object?>{'a': c.action, 'd': c.delta},
        ),
      );
      final restored = CommandRecorder.fromJson<_SimCmd>(
        jsonDecode(encoded) as Map<String, Object?>,
        (raw) {
          final m = raw! as Map<String, Object?>;
          return _SimCmd(m['a']! as String, m['d']! as int);
        },
      );
      expect(runSimulation(restored), scoreA);

      restored.clear();
      expect(restored.length, 0);
    });
  });
}
