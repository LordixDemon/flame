import 'dart:math' as math;

import 'package:flame/camera.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TactileCameraController', () {
    double panAfter(double seconds, int fps) {
      final controller = TactileCameraController()..panByWorld(200, 0);
      controller.reset();
      final steps = (seconds * fps).round();
      for (var i = 0; i < steps; i++) {
        controller.update(1 / fps);
      }
      return controller.panX;
    }

    test('spring return follows the same curve at any frame rate', () {
      // returnSpringRate defaults to 7.0 1/s.
      final exact = 200 * math.exp(-7.0 * 0.3);
      for (final fps in [20, 30, 60, 120, 240]) {
        expect(
          panAfter(0.3, fps),
          closeTo(exact, 1e-6),
          reason: 'at $fps fps',
        );
      }
    });

    test('a single long frame decays instead of snapping home', () {
      final controller = TactileCameraController()..panByWorld(200, 0);
      controller.reset();
      controller.update(0.15);
      expect(controller.panX, closeTo(200 * math.exp(-7.0 * 0.15), 1e-9));
      expect(controller.hasManualOverride, isTrue);
    });

    test('zoom factor returns along the same exponential', () {
      final controller = TactileCameraController()..zoomByFactor(1.5);
      controller.reset();
      for (var i = 0; i < 30; i++) {
        controller.update(1 / 60);
      }
      expect(
        controller.zoomFactor,
        closeTo(1.0 + 0.5 * math.exp(-7.0 * 0.5), 1e-9),
      );
    });

    test('settles exactly on neutral framing and stops returning', () {
      final controller = TactileCameraController()
        ..panByWorld(120, -80)
        ..zoomByFactor(1.4);
      controller.reset();
      for (var i = 0; i < 600; i++) {
        controller.update(1 / 60);
      }
      expect(controller.panX, 0.0);
      expect(controller.panY, 0.0);
      expect(controller.zoomFactor, 1.0);
      expect(controller.hasManualOverride, isFalse);
    });

    test('does not return while a gesture is active', () {
      final controller = TactileCameraController()..panByWorld(50, 0);
      controller
        ..beginGesture()
        ..reset()
        ..update(1.0);
      expect(controller.panX, 50.0);
      controller
        ..endGesture()
        ..reset()
        ..update(0.1);
      expect(controller.panX, closeTo(50 * math.exp(-0.7), 1e-9));
    });
  });
}
