import 'dart:ui';

import 'package:flame/components.dart';
import 'package:flame/rendering.dart';
import 'package:flame_test/flame_test.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Interactive WaterSurface2DComponent & WaterRipplePoolComponent', () {
    testWithFlameGame(
      'splash impulse propagates outward to neighbor columns and '
      'dissipates smoothly',
      (game) async {
        final water = WaterSurface2DComponent(
          size: Vector2(320, 96),
          waveSpeed: 0.0,
          simulationColumns: 41,
          springStiffness: 150.0,
          waveDamping: 2.8,
          waveSpread: 0.28,
        );
        await game.ensureAdd(water);

        expect(water.sampleDynamicWaveHeight(160.0), 0.0);
        expect(water.sampleDynamicWaveHeight(40.0), 0.0);

        water.splash(160.0, 85.0, radius: 14.0);
        final initialEnergy = water.waveMechanicalEnergy;
        expect(initialEnergy, greaterThan(100.0));

        // Advance 0.18s: wave packet travels outward toward x = 80 and x = 240.
        for (var i = 0; i < 11; i++) {
          game.update(1 / 60);
        }
        expect(water.sampleDynamicWaveHeight(90.0).abs(), greaterThan(0.05));
        expect(water.sampleDynamicWaveHeight(230.0).abs(), greaterThan(0.05));
        expect(water.sampleSlope(120.0).abs(), greaterThan(1e-4));

        // Advance 1.5s: damping strictly reduces total mechanical energy.
        for (var i = 0; i < 90; i++) {
          game.update(1 / 60);
        }
        expect(water.waveMechanicalEnergy, lessThan(initialEnergy * 0.25));

        final recorder = PictureRecorder();
        game.render(Canvas(recorder));
        recorder.endRecording().dispose();
      },
    );

    testWithFlameGame(
      'WaterRipplePoolComponent batches isometric ripples in 1 GPU draw call '
      'and wraps at capacity',
      (game) async {
        final ripples = WaterRipplePoolComponent(
          capacity: 8,
          aspectRatio: 0.5,
        );
        await game.ensureAdd(ripples);

        for (var i = 0; i < 20; i++) {
          ripples.spawnRipple(i * 12.0, i * 6.0, lifespan: 0.8);
        }
        expect(ripples.activeCount, 8);

        game.update(0.25);
        final recorder = PictureRecorder();
        ripples.render(Canvas(recorder));
        recorder.endRecording().dispose();

        expect(ripples.lastDrawCalls, 1);

        game.update(1.0);
        expect(ripples.activeCount, 0);
      },
    );
  });
}
