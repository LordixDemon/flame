import 'dart:ui';

import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flame/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

class _PaintedBox({
  super.position,
  super.size,
}) extends PositionComponent {
  @override
  void render(Canvas canvas) {
    canvas.drawRect(
      size.toRect(),
      Paint()..color = const Color(0xFFFF6633),
    );
  }
}

void main() {
  group('Bounded Decorator saveLayer', () {
    test('PaintDecorator passes tight local bounds for leaf component', () {
      final box = _PaintedBox(
        position: Vector2(200, 150),
        size: Vector2(48, 32),
      );
      final tint = PaintDecorator.tint(const Color(0x8800FFAA));
      box.decorator.addLast(tint);

      final recorder = PictureRecorder();
      final canvas = Canvas(recorder);
      box.renderTree(canvas);
      recorder.endRecording().dispose();

      final saved = tint.lastSaveLayerBounds;
      expect(saved, isNotNull);
      // Leaf size (48x32) inflated by 2.0px AA margin.
      expect(saved!.left, closeTo(-2.0, 1e-4));
      expect(saved.top, closeTo(-2.0, 1e-4));
      expect(saved.width, closeTo(52.0, 1e-4));
      expect(saved.height, closeTo(36.0, 1e-4));
    });

    test('PaintDecorator.blur inflates saveLayer bounds by 4*sigma + 4', () {
      final box = _PaintedBox(size: Vector2(40, 20));
      final blur = PaintDecorator.blur(5.0);
      box.decorator.addLast(blur);

      final recorder = PictureRecorder();
      box.renderTree(Canvas(recorder));
      recorder.endRecording().dispose();

      final saved = blur.lastSaveLayerBounds!;
      // pad = 4 * 5 + 4 = 24
      expect(saved.left, closeTo(-24.0, 1e-4));
      expect(saved.top, closeTo(-24.0, 1e-4));
      expect(saved.width, closeTo(40.0 + 48.0, 1e-4));
      expect(saved.height, closeTo(20.0 + 48.0, 1e-4));
    });

    test(
      'container with children defaults to unbounded unless decoratorBounds '
      'is explicitly supplied',
      () {
        final parent = _PaintedBox(size: Vector2(50, 50));
        final child = _PaintedBox(
          position: Vector2(120, 120),
          size: Vector2(30, 30),
        );
        parent.add(child);

        final game = FlameGame(children: [parent])
          ..onGameResize(Vector2(400, 400));
        final tint = PaintDecorator.grayscale(opacity: 0.7);
        parent.decorator.addLast(tint);

        return game.ready().then((_) {
          final recorder = PictureRecorder();
          game.render(Canvas(recorder));
          recorder.endRecording().dispose();

          // Because parent has children that may overflow 50x50, automatic
          // bounds are skipped to avoid clipping children.
          expect(tint.lastSaveLayerBounds, isNull);

          // Explicit decoratorBounds opts back into bounded saveLayer.
          parent.decoratorBounds = const Rect.fromLTWH(0, 0, 160, 160);
          final recorder2 = PictureRecorder();
          game.render(Canvas(recorder2));
          recorder2.endRecording().dispose();

          expect(tint.lastSaveLayerBounds, isNotNull);
          expect(tint.lastSaveLayerBounds!.width, closeTo(164.0, 1e-4));
        });
      },
    );

    test('Shadow3DDecorator projects 4 corners + blur into tight bounds', () {
      final box = _PaintedBox(
        position: Vector2(100, 100),
        size: Vector2(40, 60),
      );
      final shadow = Shadow3DDecorator(
        base: Vector2(0, 60),
        angle: -0.9,
        xShift: 18,
        yScale: 1.4,
        blur: 3.0,
      );
      box.decorator.addLast(shadow);

      final recorder = PictureRecorder();
      box.renderTree(Canvas(recorder));
      recorder.endRecording().dispose();

      final saved = shadow.lastSaveLayerBounds;
      expect(saved, isNotNull);
      expect(saved!.width, lessThan(260.0));
      expect(saved.height, lessThan(260.0));
      expect(saved.width, greaterThan(40.0));
    });
  });
}
