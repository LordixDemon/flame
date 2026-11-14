import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flame/game.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

class _TrackpadViewportTarget() extends PositionComponent with ScaleCallbacks {
  this : super(size: Vector2(800, 600));

  int starts = 0;
  int updates = 0;
  double lastScale = 1.0;
  double lastRotation = 0.0;
  final Vector2 totalDelta = Vector2.zero();

  @override
  void onScaleStart(ScaleStartEvent event) {
    super.onScaleStart(event);
    starts++;
  }

  @override
  void onScaleUpdate(ScaleUpdateEvent event) {
    super.onScaleUpdate(event);
    updates++;
    lastScale = event.scale;
    lastRotation = event.rotation;
    totalDelta.add(event.focalPointDelta);
  }
}

void main() {
  group('Zero-Deadzone Trackpad Pan/Zoom/Rotate (#9 part 2)', () {
    testWidgets(
      'trackpadImmediateScale = true fires onScaleStart/onScaleUpdate on tiny '
      '0.4% pinch, 1px two-finger pan, and pure rotation',
      (tester) async {
        final game = FlameGame()..trackpadImmediateScale = true;
        final target = _TrackpadViewportTarget();

        await tester.pumpWidget(
          SizedBox(
            width: 800,
            height: 600,
            child: GameWidget(game: game),
          ),
        );
        await tester.pump();
        game.camera.viewport.add(target);
        await game.ready();
        await tester.pump();

        final trackpad = TestPointer(1, PointerDeviceKind.trackpad);
        const center = Offset(400, 300);

        // 1. Sub-threshold 0.4% pinch (1.004 < default 1.05) fires immediately!
        await tester.sendEventToBinding(trackpad.panZoomStart(center));
        await tester.sendEventToBinding(
          trackpad.panZoomUpdate(center, scale: 1.004),
        );
        await tester.sendEventToBinding(trackpad.panZoomEnd());
        expect(target.starts, equals(1));
        expect(target.updates, equals(1));
        expect(target.lastScale, closeTo(1.004, 1e-6));

        // 2. Sub-slop 1.5px two-finger pan (< 18px panSlop) fires immediately!
        await tester.sendEventToBinding(trackpad.panZoomStart(center));
        await tester.sendEventToBinding(
          trackpad.panZoomUpdate(center, pan: const Offset(1.5, -1.0)),
        );
        await tester.sendEventToBinding(trackpad.panZoomEnd());
        expect(target.starts, equals(2));
        expect(target.totalDelta.x, closeTo(1.5, 1e-5));
        expect(target.totalDelta.y, closeTo(-1.0, 1e-5));

        // 3. Pure two-finger trackpad rotation (0.008 rad) fires immediately!
        await tester.sendEventToBinding(trackpad.panZoomStart(center));
        await tester.sendEventToBinding(
          trackpad.panZoomUpdate(center, rotation: 0.008),
        );
        await tester.sendEventToBinding(trackpad.panZoomEnd());
        expect(target.starts, equals(3));
        expect(target.lastRotation, closeTo(0.008, 1e-6));
      },
    );
  });
}
