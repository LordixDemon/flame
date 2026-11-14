import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flutter_test/flutter_test.dart';

class _TimeScaledLayer({
  super.children,
}) extends Component with CustomTraversal, HasTimeScale;

class _DualStepper() extends Component with HasFixedUpdate {
  double variableElapsed = 0.0;
  double fixedElapsed = 0.0;
  int fixedCalls = 0;

  @override
  void update(double dt) {
    variableElapsed += dt;
  }

  @override
  void fixedUpdate(double dt) {
    fixedElapsed += dt;
    fixedCalls++;
  }
}

class _TimeScaledGame() extends FlameGame with HasTimeScale;

void main() {
  group('effectiveTimeScale, HasFixedUpdate scaling, & applyTimePulse', () {
    test(
      'scales HasFixedUpdate in lockstep with subtree HasTimeScale without '
      'double-scaling root FlameGame with HasTimeScale',
      () async {
        final game = _TimeScaledGame()
          ..fixedTimeStep = 0.01
          ..maxFixedSubSteps = 16
          ..onGameResize(Vector2(200, 200));
        await game.start();

        final stepper = _DualStepper();
        final subLayer = _TimeScaledLayer(children: [stepper])..timeScale = 0.5;
        game.world.add(subLayer);
        await game.ready();

        game.timeScale = 0.5;
        expect(stepper.effectiveTimeScale, closeTo(0.25, 1e-6));

        // 0.20s real time * 0.5 game.timeScale = 0.10s -> 10 fixed steps,
        // each scaled by subLayer.timeScale (0.5) => 10 * 0.005 = 0.05s!
        game.update(0.20);
        expect(stepper.variableElapsed, closeTo(0.05, 1e-6));
        expect(stepper.fixedCalls, 10);
        expect(stepper.fixedElapsed, closeTo(0.05, 1e-6));
      },
    );

    test(
      'applyTimePulse supports pure 0.0 freeze-frame hit-stop and unfreezes '
      'automatically via unscaled real dt',
      () async {
        final game = FlameGame()
          ..fixedTimeStep = 0.01
          ..onGameResize(Vector2(200, 200));
        await game.start();

        final stepper = _DualStepper();
        final fxLayer = _TimeScaledLayer(children: [stepper]);
        game.world.add(fxLayer);
        await game.ready();

        fxLayer.applyTimePulse(
          scale: 0.0,
          realDuration: 0.06,
          rampBackDuration: 0.04,
        );
        expect(fxLayer.isTimePulseActive, isTrue);
        expect(fxLayer.timeScale, 0.0);

        // First two 30ms real ticks are completely frozen (60ms hold).
        game.update(0.03);
        expect(stepper.variableElapsed, 0.0);
        expect(stepper.fixedCalls, 0);

        game.update(0.03);
        expect(stepper.variableElapsed, 0.0);
        expect(stepper.fixedCalls, 0);
        // After 60ms real time, ramp-back has begun!
        expect(fxLayer.isTimePulseActive, isTrue);

        // Two more 30ms ticks finish the 40ms smoothstep ramp back to 1.0.
        game.update(0.03);
        expect(fxLayer.timeScale, greaterThan(0.0));
        game.update(0.03);
        expect(fxLayer.isTimePulseActive, isFalse);
        expect(fxLayer.timeScale, closeTo(1.0, 1e-6));

        // Subsequent tick runs at full 1.0x speed.
        final prevVar = stepper.variableElapsed;
        game.update(0.05);
        expect(stepper.variableElapsed - prevVar, closeTo(0.05, 1e-6));
      },
    );
  });
}
