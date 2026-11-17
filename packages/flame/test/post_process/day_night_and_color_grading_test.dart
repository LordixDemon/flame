import 'package:flame/post_process.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a slow day/night clock still advances when every step is tiny',
    () {
      // Real-time clock (1 game hour per real hour), stepped at 300 Hz - or at
      // 60 Hz under a 0.2x slow-motion time scale.
      final clock = DayNightWeatherController(
        hoursPerRealSecond: 1 / 3600,
      );
      const dt = 1 / 300;
      for (var i = 0; i < 300 * 60; i++) {
        clock.update(dt);
      }
      // One real minute = 1/60 h.
      expect(clock.hour, closeTo(12.0 + 1 / 60, 1e-3));
    },
  );

  test(
    'exposure changes the sepia preset matrix',
    () {
      final plain = ColorGradingPostProcess(preset: ColorGradingPreset.sepia);
      final bright = ColorGradingPostProcess(
        preset: ColorGradingPreset.sepia,
        exposure: 1.0,
        contrast: 1.5,
      );
      expect(bright.isIdentityGrading, isFalse);
      expect(
        bright.computeColorMatrix(),
        isNot(equals(plain.computeColorMatrix())),
        reason: 'exposure +1 EV and contrast 1.5 had no effect',
      );
    },
  );
}
