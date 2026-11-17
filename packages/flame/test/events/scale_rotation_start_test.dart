import 'dart:math' as math;

import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flame/game.dart';
import 'package:flutter_test/flutter_test.dart';

class _Surface() extends PositionComponent with TapCallbacks, ScaleCallbacks {
  this : super(size: Vector2(800, 600));

  int scaleStarts = 0;
  int scaleEnds = 0;
  int tapUps = 0;
  int tapCancels = 0;
  final List<double> rotations = <double>[];

  @override
  void onScaleStart(ScaleStartEvent event) {
    super.onScaleStart(event);
    scaleStarts++;
  }

  @override
  void onScaleUpdate(ScaleUpdateEvent event) {
    rotations.add(event.rotation);
  }

  @override
  void onScaleEnd(ScaleEndEvent event) {
    super.onScaleEnd(event);
    scaleEnds++;
  }

  @override
  void onTapUp(TapUpEvent event) => tapUps++;

  @override
  void onTapCancel(TapCancelEvent event) => tapCancels++;
}

Future<_Surface> _pumpSurface(WidgetTester tester) async {
  final surface = _Surface();
  final game = FlameGame();
  game.camera.viewport.add(surface);
  await tester.pumpWidget(GameWidget(game: game));
  await tester.pump();
  await tester.pump();
  return surface;
}

void main() {
  group('rotation as the start of a scale gesture', () {
    testWidgets('a sub-pixel wobble of two level fingers neither starts a '
        'scale gesture nor cancels their taps', (tester) async {
      final surface = await _pumpSurface(tester);

      // First finger on the left, second on the right, same height: the line
      // between them lies on the +pi/-pi seam of atan2.
      final left = await tester.startGesture(
        const Offset(300, 300),
        pointer: 11,
      );
      final right = await tester.startGesture(
        const Offset(400, 300),
        pointer: 12,
      );
      await tester.pump();

      await left.moveTo(const Offset(300, 300.2));
      await tester.pump();
      await left.moveTo(const Offset(300, 299.8));
      await tester.pump();
      expect(surface.scaleStarts, 0);

      await left.up();
      await right.up();
      await tester.pump(const Duration(milliseconds: 500));
      expect(surface.tapCancels, 0);
      expect(surface.tapUps, 2);
    });

    testWidgets('two close fingers that only jitter do not start a scale '
        'gesture, however large the angle', (tester) async {
      final surface = await _pumpSurface(tester);

      // 20 px apart: a 3 px sideways jitter turns the line by ~0.15 rad, well
      // past the angle threshold, but nobody travelled past the scale slop.
      final a = await tester.startGesture(const Offset(300, 300), pointer: 21);
      final b = await tester.startGesture(const Offset(320, 300), pointer: 22);
      await tester.pump();
      await b.moveTo(const Offset(320, 301));
      await tester.pump();
      await b.moveTo(const Offset(320, 303));
      await tester.pump();
      await b.moveTo(const Offset(320, 297));
      await tester.pump();
      expect(surface.scaleStarts, 0);

      await a.up();
      await b.up();
      await tester.pump(const Duration(milliseconds: 500));
      expect(surface.tapUps, 2);
    });

    testWidgets('a deliberate twist with constant finger distance starts a '
        'scale gesture and reports the turn', (tester) async {
      final surface = await _pumpSurface(tester);

      // Two fingers 200 px apart turn about their midpoint (400, 300).
      Offset onCircle(double angle, {required bool first}) {
        final sign = first ? -1.0 : 1.0;
        return Offset(
          400 + sign * 100 * math.cos(angle),
          300 + sign * 100 * math.sin(angle),
        );
      }

      final first = await tester.startGesture(
        onCircle(0, first: true),
        pointer: 31,
      );
      final second = await tester.startGesture(
        onCircle(0, first: false),
        pointer: 32,
      );
      await tester.pump();

      // Establish the baseline with a hair's movement, then turn by 0.4 rad
      // in small steps; span and focal point stay put throughout.
      await first.moveTo(onCircle(0.001, first: true));
      await second.moveTo(onCircle(0.001, first: false));
      for (var step = 1; step <= 8; step++) {
        final angle = 0.05 * step;
        await first.moveTo(onCircle(angle, first: true));
        await second.moveTo(onCircle(angle, first: false));
        await tester.pump();
      }

      expect(surface.scaleStarts, 1);
      expect(surface.rotations, isNotEmpty);
      expect(surface.rotations.last, closeTo(0.4, 0.01));
      // The reported turn grows steadily: it never jumps by a full circle
      // although the line started on the atan2 seam.
      for (final rotation in surface.rotations) {
        expect(rotation.abs(), lessThan(0.5));
      }

      await first.up();
      await second.up();
      await tester.pump(const Duration(milliseconds: 500));
      expect(surface.scaleEnds, 1);
    });
  });
}
