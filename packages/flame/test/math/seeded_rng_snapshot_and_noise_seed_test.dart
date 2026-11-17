import 'dart:typed_data';

import 'package:flame/math.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SeededRng snapshots', () {
    test('a generator restored after an odd number of gaussian samples '
        'continues exactly like the original', () {
      final original = SeededRng(42);
      original.gaussian(); // leaves the second sample of the pair pending

      final snapshot = original.saveState();
      expect(snapshot.length, 24);
      final restored = SeededRng.fromStateBytes(snapshot);

      final a = <double>[for (var i = 0; i < 5; i++) original.gaussian()];
      final b = <double>[for (var i = 0; i < 5; i++) restored.gaussian()];
      expect(b, a);
      expect(restored.nextUint32(), original.nextUint32());
    });

    test('a snapshot with no gaussian sample pending is the 16 lane bytes', () {
      final rng = SeededRng(7);
      expect(rng.saveState().length, 16);

      rng
        ..gaussian()
        ..gaussian();
      final snapshot = rng.saveState();
      expect(snapshot.length, 16);

      final expected = <int>[for (var i = 0; i < 4; i++) rng.nextUint32()];
      rng.restoreState(snapshot);
      expect(<int>[for (var i = 0; i < 4; i++) rng.nextUint32()], expected);
    });

    test('restoring a 16-byte snapshot drops a pending gaussian sample', () {
      final clean = SeededRng(99);
      final lanes = clean.saveState();

      final other = SeededRng(5)..gaussian();
      other.restoreState(lanes);
      expect(other.saveState(), lanes);
      expect(other.gaussian(), clean.gaussian());
    });

    test('rejects a snapshot shorter than the lanes', () {
      expect(
        () => SeededRng().restoreState(Uint8List(15)),
        throwsArgumentError,
      );
    });
  });

  group('platform-independent sequences', () {
    // These constants must hold on the Dart VM, in AOT builds and when
    // compiled to JavaScript or Wasm alike.
    test('SeededRng produces the reference stream', () {
      final rng = SeededRng(42);
      expect(rng.nextUint32(), 261665062);
      expect(rng.nextUint32(), 3154372797);
      expect(rng.nextDouble(), 0.7772120263464348);
      expect(rng.fork('dice').nextUint32(), 1525766620);
    });

    test('SimplexNoise2D derives the reference field from its seed', () {
      const reference = <int, List<double>>{
        1337: [0.6747522410697512, -0.0165293703010547, 0.3037672039568567],
        42: [-0.2555289232359819, 0.7081057495520956, -0.49385702762469713],
        0x7FFFFFFF: [
          -0.357263954564835,
          0.22612572467749262,
          0.39031350649090585,
        ],
        0xDEADBEEF: [
          -0.25518670848751157,
          -0.588427191054215,
          0.5373774603543192,
        ],
      };
      reference.forEach((seed, expected) {
        final noise = SimplexNoise2D(seed: seed);
        expect(noise.sample(0.3, 0.7), closeTo(expected[0], 1e-12));
        expect(noise.sample(12.5, -4.25), closeTo(expected[1], 1e-12));
        expect(noise.fbm(3.1, 9.9), closeTo(expected[2], 1e-12));
      });
    });
  });
}
