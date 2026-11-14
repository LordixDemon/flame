import 'dart:typed_data';
import 'dart:ui';

import 'package:flame/camera.dart';
import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flame/layers.dart';
import 'package:flame/rendering.dart';
import 'package:flutter/painting.dart' show EdgeInsets;
import 'package:flutter_test/flutter_test.dart';

class _SolidWorld(final Color color) extends World {
  @override
  void renderFromCamera(Canvas canvas) {
    canvas.drawRect(
      const Rect.fromLTWH(-500, -500, 1000, 1000),
      Paint()..color = color,
    );
    super.renderFromCamera(canvas);
  }
}

class _BillboardPinProbe({super.position, super.size})
    extends PositionComponent
    with CameraBillboard, ViewportClampedPin {
  this : super(anchor: Anchor.center);

  Rect? lastScreenBounds;

  @override
  void render(Canvas canvas) {
    final m = canvas.getTransform();
    final x0 = m[12];
    final y0 = m[13];
    final x1 = m[0] * size.x + m[4] * size.y + m[12];
    final y1 = m[1] * size.x + m[5] * size.y + m[13];
    lastScreenBounds = Rect.fromPoints(Offset(x0, y0), Offset(x1, y1));
  }
}

class _TestPreRenderedLayer() extends PreRenderedLayer {
  int drawCount = 0;

  @override
  void drawLayer() {
    drawCount++;
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 10, 10),
      Paint()..color = const Color(0xFFFFFFFF),
    );
  }
}

Future<Uint8List> _readCenterPixel(
  WidgetTester tester,
  CameraComponent camera,
) async {
  return (await tester.runAsync(() async {
    final image = camera.renderToImageSync(width: 64, height: 64);
    try {
      final bytes = await image.toByteData();
      const idx = (32 * 64 + 32) * 4;
      return Uint8List.fromList([
        bytes!.getUint8(idx),
        bytes.getUint8(idx + 1),
        bytes.getUint8(idx + 2),
        bytes.getUint8(idx + 3),
      ]);
    } finally {
      image.dispose();
    }
  }))!;
}

void main() {
  group('SceneTransition, WorldRoute & Layer dispose (#5)', () {
    test('PreRenderedLayer reRender and dispose release retained Picture', () {
      final layer = _TestPreRenderedLayer();
      expect(layer.drawCount, 1);
      layer.reRender();
      expect(layer.drawCount, 2);

      final recorder = PictureRecorder();
      layer.render(Canvas(recorder));
      recorder.endRecording().dispose();

      layer.dispose();
      final recorder2 = PictureRecorder();
      layer.render(Canvas(recorder2));
      recorder2.endRecording().dispose();
    });

    testWidgets(
      'CameraComponent.transitionToWorld cross-fades outgoing snapshot cleanly',
      (tester) async {
        final redWorld = _SolidWorld(const Color(0xFFFF0000));
        final blueWorld = _SolidWorld(const Color(0xFF0000FF));
        final game = FlameGame(
          world: redWorld,
          camera: CameraComponent.withFixedResolution(width: 64, height: 64),
        );

        await tester.pumpWidget(GameWidget(game: game));
        await tester.pump();

        final before = await _readCenterPixel(tester, game.camera);
        expect(before[0], greaterThan(240));
        expect(before[2], lessThan(15));

        final future = game.camera.transitionToWorld(blueWorld);
        game.processLifecycleEvents();
        expect(game.camera.hasActiveSceneTransition, isTrue);

        game.update(0.2);
        final recorder = PictureRecorder();
        game.render(Canvas(recorder));
        final pic = recorder.endRecording();
        final midBytes = await tester.runAsync(() async {
          final img = pic.toImageSync(64, 64);
          try {
            return await img.toByteData();
          } finally {
            img.dispose();
            pic.dispose();
          }
        });
        expect(midBytes, isNotNull);

        game.update(0.25);
        await future;
        expect(game.camera.hasActiveSceneTransition, isFalse);

        final after = await _readCenterPixel(tester, game.camera);
        expect(after[2], greaterThan(240));
        expect(after[0], lessThan(15));
      },
    );

    testWidgets(
      'CircularRevealSceneTransition and WorldRoute render effects work',
      (tester) async {
        late RouterComponent router;
        final game = FlameGame(
          camera: CameraComponent.withFixedResolution(width: 80, height: 80),
          children: [
            router = RouterComponent(
              initialRoute: '/w1',
              routes: {
                '/w1': WorldRoute(
                  () => _SolidWorld(const Color(0xFF22AA44)),
                ),
                '/w2': WorldRoute(
                  () => _SolidWorld(const Color(0xFFDD8822)),
                  transition: CircularRevealSceneTransition(
                    duration: 0.3,
                    ringColor: const Color(0xFFFFFFFF),
                  ),
                ),
              },
            ),
          ],
        );

        await tester.pumpWidget(GameWidget(game: game));
        await tester.pump();
        await tester.pump();

        final route1 = router.currentRoute as WorldRoute;
        final tintDecorator = PaintDecorator.tint(const Color(0x88000000));
        route1.addRenderEffect(tintDecorator);
        expect(game.world.decorator.isLastDecorator, isFalse);
        route1.removeRenderEffect();
        expect(game.world.decorator.isLastDecorator, isTrue);

        router.pushNamed('/w2');
        game.processLifecycleEvents();
        expect(game.camera.hasActiveSceneTransition, isTrue);
        game.update(0.15);

        final recorder = PictureRecorder();
        game.render(Canvas(recorder));
        recorder.endRecording().dispose();

        game.update(0.2);
        expect(game.camera.hasActiveSceneTransition, isFalse);
      },
    );
  });

  group('CameraBillboard & ViewportClampedPin (#6)', () {
    testWidgets(
      'stabilizes pixel width across zoom and clamps into safe viewport',
      (tester) async {
        final world = World();
        final camera = CameraComponent(
          viewport: FixedSizeViewport(200, 100),
          world: world,
        );
        final game = FlameGame(world: world, camera: camera);
        final pin = _BillboardPinProbe(
          position: Vector2.zero(),
          size: Vector2(40, 20),
        )..viewportPinMargin = const EdgeInsets.all(10);
        world.add(pin);

        await tester.pumpWidget(GameWidget(game: game));
        await tester.pump();

        void renderOnce() {
          final rec = PictureRecorder();
          camera.renderTree(Canvas(rec, const Rect.fromLTWH(0, 0, 200, 100)));
          rec.endRecording().dispose();
        }

        camera.viewfinder.zoom = 1.0;
        renderOnce();
        final widthAtZoom1 = pin.lastScreenBounds!.width;

        camera.viewfinder.zoom = 2.0;
        renderOnce();
        final widthAtZoom2 = pin.lastScreenBounds!.width;

        expect(pin.lastBillboardScale, closeTo(0.5, 1e-4));
        expect(widthAtZoom2, closeTo(widthAtZoom1, 1e-2));

        camera.viewfinder.zoom = 1.0;
        pin.position.setValues(500, -400);
        renderOnce();
        expect(pin.lastClampDelta.x, lessThan(-350));
        expect(pin.lastClampDelta.y, greaterThan(300));
        expect(pin.lastScreenBounds!.right, lessThanOrEqualTo(190.1));
        expect(pin.lastScreenBounds!.top, greaterThanOrEqualTo(9.9));
      },
    );
  });
}
