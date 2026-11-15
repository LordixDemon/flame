import 'dart:ui';

import 'package:flame/components.dart';
import 'package:flame/post_process.dart';
import 'package:flame/rendering.dart';
import 'package:flame_test/flame_test.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WeatherPrecipitationLayer v2 Parallax, Gusts & Splash Coupling', () {
    test(
      'assigns 3 monotonic depth parallax speed bands and modulates wind gusts',
      () {
        final weather = WeatherPrecipitationLayer(
          particleCount: 90,
          gustStrength: 55.0,
          gustFrequency: 2.0,
        );

        // Compare indices with identical `(i % 7)` across bands 0, 1, 2:
        // i = 0 -> band 0 (0%7=0); i = 7 -> band 1 (7%7=0); i = 14 -> band 2!
        expect(weather.depthBandOf(0), 0);
        expect(weather.depthBandOf(7), 1);
        expect(weather.depthBandOf(14), 2);
        expect(weather.speedScaleOf(7), greaterThan(weather.speedScaleOf(0)));
        expect(weather.speedScaleOf(14), greaterThan(weather.speedScaleOf(7)));

        final w0 = weather.currentWindVelocityX;
        weather.update(0.6);
        final w1 = weather.currentWindVelocityX;
        expect((w1 - w0).abs(), greaterThan(5.0));
      },
    );

    testWithFlameGame(
      'rain and hail trigger onDropImpact to excite WaterRipplePoolComponent '
      'and WaterSurface2DComponent',
      (game) async {
        final ripples = WaterRipplePoolComponent(capacity: 64);
        final water = WaterSurface2DComponent(
          position: Vector2(0, 220),
          size: Vector2(400, 100),
          waveSpeed: 0.0,
        );
        var splashCallbacks = 0;

        final storm = WeatherPrecipitationLayer(
          particleCount: 96,
          splashRate: 45.0,
          fallbackBounds: const Rect.fromLTWH(0, 0, 400, 320),
          onDropImpact: (wx, wy) {
            splashCallbacks++;
            ripples.spawnRipple(wx, wy, maxRadius: 18.0, lifespan: 0.6);
            water.splash(wx, 18.0, radius: 12.0);
          },
        );

        await game.ensureAddAll(<Component>[water, ripples, storm]);
        for (var step = 0; step < 30; step++) {
          game.update(1 / 60);
        }

        expect(splashCallbacks, greaterThanOrEqualTo(20));
        expect(ripples.activeCount, greaterThan(0));
        expect(water.waveMechanicalEnergy, greaterThan(0.0));

        // Verify hail and ash presets also render cleanly without errors:
        for (final preset in <WeatherKind>[
          WeatherKind.rain,
          WeatherKind.hail,
          WeatherKind.ash,
        ]) {
          storm.kind = preset;
          game.update(1 / 60);
          final rec = PictureRecorder();
          storm.render(Canvas(rec));
          rec.endRecording().dispose();
          expect(storm.lastActiveDropCount, 96);
        }
      },
    );
  });
}
