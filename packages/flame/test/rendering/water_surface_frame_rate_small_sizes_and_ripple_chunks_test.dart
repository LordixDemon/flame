import 'dart:ui';

import 'package:flame/components.dart';
import 'package:flame/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void _render(Component component) {
  final recorder = PictureRecorder();
  component.render(Canvas(recorder));
  recorder.endRecording().dispose();
}

WaterSurface2DComponent _splashed() {
  return WaterSurface2DComponent(
    size: Vector2(960, 60),
    simulationColumns: 97, // 10 px per column
    waveSpeed: 0,
    waveDamping: 0,
  )..splash(480, 300, radius: 10);
}

/// Distance in px from the splash centre that the wave front (last column
/// with `|height| > 0.05`) has reached after [seconds] at time step [dt].
double _frontReach(double dt, double seconds) {
  final water = _splashed();
  final steps = (seconds / dt).round();
  for (var i = 0; i < steps; i++) {
    water.update(dt);
  }
  var reach = 0.0;
  for (var x = 480.0; x <= 960.0; x += 10.0) {
    if (water.sampleDynamicWaveHeight(x).abs() > 0.05) {
      reach = x - 480.0;
    }
  }
  return reach;
}

void main() {
  group('WaterSurface2DComponent', () {
    test('render accepts strips narrower than 8 px and thinner than 1 px', () {
      for (final size in <Vector2>[
        Vector2(6, 40),
        Vector2(0.5, 40),
        Vector2(200, 0.5),
        Vector2(3, 0.25),
      ]) {
        final water = WaterSurface2DComponent(size: size)
          ..splash(1, 20)
          ..update(1 / 60);
        expect(() => _render(water), returnsNormally, reason: '$size');
      }
    });

    test('a splash spreads equally far at every frame rate', () {
      final reference = _frontReach(1 / 120, 0.5);
      expect(reference, greaterThan(50));
      // 1/119 used to run twice the smoothing passes of 1/120.
      for (final fps in <double>[119, 100, 61, 60, 59, 30, 24]) {
        expect(
          _frontReach(1 / fps, 0.5),
          closeTo(reference, 10.0),
          reason: 'front after 0.5 s at $fps fps (120 fps: $reference px)',
        );
      }
    });

    test('frames shorter than the 1/120 s simulation step accumulate', () {
      final fast = _splashed();
      final slow = _splashed();
      for (var i = 0; i < 240; i++) {
        fast.update(1 / 480);
      }
      for (var i = 0; i < 60; i++) {
        slow.update(1 / 120);
      }
      for (var x = 0.0; x <= 960.0; x += 40.0) {
        expect(
          fast.sampleDynamicWaveHeight(x),
          closeTo(slow.sampleDynamicWaveHeight(x), 1e-3),
        );
      }
    });

    test('undamped waves keep their energy bounded over a long run', () {
      final water = _splashed();
      final initial = water.waveMechanicalEnergy;
      expect(initial, greaterThan(0));
      for (var i = 0; i < 20 * 60; i++) {
        water.update(1 / 60);
      }
      expect(water.waveMechanicalEnergy.isFinite, isTrue);
      expect(water.waveMechanicalEnergy, lessThan(initial * 1.5));
    });
  });

  group('WaterRipplePoolComponent', () {
    test('more than 16383 visible ripples are drawn in chunks that 16-bit '
        'vertex indices can address', () {
      final pool = WaterRipplePoolComponent(capacity: 20000);
      for (var i = 0; i < 20000; i++) {
        pool.spawnRipple(i % 200 * 4.0, i ~/ 200 * 4.0);
      }
      expect(pool.activeCount, 20000);
      expect(() => _render(pool), returnsNormally);
      expect(pool.lastDrawCalls, 2);
    });

    test('a normal pool still draws in one call and recycles slots', () {
      final pool = WaterRipplePoolComponent(capacity: 8);
      for (var i = 0; i < 20; i++) {
        pool.spawnRipple(i * 10.0, 0);
      }
      expect(pool.activeCount, 8);
      _render(pool);
      expect(pool.lastDrawCalls, 1);
      pool
        ..update(double.nan)
        ..update(5);
      expect(pool.activeCount, 0);
      _render(pool);
      expect(pool.lastDrawCalls, 0);
    });
  });
}
