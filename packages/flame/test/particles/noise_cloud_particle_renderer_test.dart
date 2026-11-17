import 'package:flame/particles.dart';
import 'package:flutter_test/flutter_test.dart';

/// The alpha values of the atlas of [renderer], plus the largest alpha on the
/// border and at the center of the region each puff variant samples.
Future<({int border, int center})> _measure(
  NoiseCloudParticleRenderer renderer,
) async {
  await renderer.onLoad();
  final atlas = renderer.texture!;
  final bytes = (await atlas.toByteData())!;
  int alphaAt(int x, int y) => bytes.getUint8((y * atlas.width + x) * 4 + 3);

  final probe = ParticleBuffer(1)..spawn();
  var border = 0;
  var center = 255;
  for (var v = 0; v < NoiseCloudParticleRenderer.variantCount; v++) {
    probe.variant[0] = v;
    final rect = renderer.frameRectForParticle(probe, 0);
    final l = rect.left.round();
    final t = rect.top.round();
    final r = rect.right.round() - 1;
    final b = rect.bottom.round() - 1;
    for (var x = l; x <= r; x++) {
      border = [border, alphaAt(x, t), alphaAt(x, b)].reduce(
        (a, c) => a > c ? a : c,
      );
    }
    for (var y = t; y <= b; y++) {
      border = [border, alphaAt(l, y), alphaAt(r, y)].reduce(
        (a, c) => a > c ? a : c,
      );
    }
    final centerAlpha = alphaAt(rect.center.dx.round(), rect.center.dy.round());
    if (centerAlpha < center) {
      center = centerAlpha;
    }
  }
  return (border: border, center: center);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(NoiseCloudParticleRenderer.clearAtlasCache);

  group('NoiseCloudParticleRenderer atlas', () {
    test('a default puff fades out before the edge of its region', () async {
      final measured = await _measure(NoiseCloudParticleRenderer());
      expect(measured.border, 0);
      expect(measured.center, greaterThan(150));
    });

    test('the puffiest puff still fits its region', () async {
      final measured = await _measure(
        NoiseCloudParticleRenderer(puffiness: 1.0),
      );
      expect(measured.border, 0);
      expect(measured.center, greaterThan(100));
    });

    test('puffs of other seeds and puffiness fit as well', () async {
      for (final seed in [1, 42, 9001]) {
        for (final puffiness in [0.0, 0.3, 0.8]) {
          final measured = await _measure(
            NoiseCloudParticleRenderer(seed: seed, puffiness: puffiness),
          );
          expect(
            measured.border,
            0,
            reason: 'seed $seed, puffiness $puffiness',
          );
        }
      }
    });
  });
}
