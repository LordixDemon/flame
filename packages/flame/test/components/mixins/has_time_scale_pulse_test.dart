import 'package:flame/components.dart';
import 'package:flutter_test/flutter_test.dart';

class _Layer() extends Component with CustomTraversal, HasTimeScale;

class _Recorder() extends Component {
  final List<double> deltas = <double>[];
  void Function()? onNextUpdate;

  @override
  void update(double dt) {
    deltas.add(double.parse(dt.toStringAsFixed(4)));
    final action = onNextUpdate;
    if (action != null) {
      onNextUpdate = null;
      action();
    }
  }
}

void main() {
  group('HasTimeScale.applyTimePulse', () {
    test('a pulse without a hold starts at its scale and ramps back', () {
      final layer = _Layer()
        ..applyTimePulse(scale: 0.2, realDuration: 0, rampBackDuration: 0.1);

      expect(layer.timeScale, 0.2, reason: 'the first frame is slowed down');

      final seen = <double>[];
      for (var i = 0; i < 6; i++) {
        layer.updateSubtree(0.02);
        seen.add(layer.timeScale);
      }
      for (var i = 1; i < seen.length; i++) {
        expect(seen[i], greaterThanOrEqualTo(seen[i - 1]));
      }
      expect(seen.last, 1.0);
      expect(layer.isTimePulseActive, isFalse);
    });

    test('a pulse with a hold keeps its scale for the whole hold', () {
      final layer = _Layer();
      final recorder = _Recorder();
      layer
        ..add(recorder)
        ..applyTimePulse(scale: 0.5, realDuration: 0.04, rampBackDuration: 0);

      for (var i = 0; i < 4; i++) {
        layer.updateSubtree(0.02);
      }

      // Two frames of hold at half speed, then back to normal.
      expect(recorder.deltas, [0.01, 0.01, 0.02, 0.02]);
    });

    test('a pulse applied from inside the subtree holds for its full '
        'duration', () {
      final layer = _Layer();
      final recorder = _Recorder();
      layer.add(recorder);
      recorder.onNextUpdate = () {
        layer.applyTimePulse(
          scale: 0.5,
          realDuration: 0.04,
          rampBackDuration: 0,
        );
      };

      for (var i = 0; i < 5; i++) {
        layer.updateSubtree(0.02);
      }

      // The frame in which the pulse is requested already ran at full speed;
      // the two frames of the hold follow it.
      expect(recorder.deltas, [0.02, 0.01, 0.01, 0.02, 0.02]);
    });

    test('a freeze-frame pulse applied from inside unfreezes by itself', () {
      final layer = _Layer();
      final recorder = _Recorder();
      layer.add(recorder);
      recorder.onNextUpdate = () {
        layer.applyTimePulse(scale: 0, realDuration: 0.04, rampBackDuration: 0);
      };

      for (var i = 0; i < 5; i++) {
        layer.updateSubtree(0.02);
      }

      expect(recorder.deltas, [0.02, 0.02, 0.02]);
      expect(layer.timeScale, 1.0);
    });
  });
}
