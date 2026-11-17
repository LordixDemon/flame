import 'dart:ui';

import 'package:flame/components.dart';
import 'package:flame/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

const int _canvasSize = 200;

/// Paints 10 px beyond its 20x20 size box on every side.
class _OverflowingBox({super.position}) extends PositionComponent {
  this : super(size: Vector2.all(20));

  @override
  void render(Canvas canvas) {
    canvas.drawRect(
      const Rect.fromLTRB(-10, -10, 30, 30),
      Paint()..color = const Color(0xFFFF0000),
    );
  }
}

class _InBoundsBox({super.position, super.size}) extends PositionComponent {
  @override
  void render(Canvas canvas) {
    canvas.drawRect(size.toRect(), Paint()..color = const Color(0xFF00AA00));
  }
}

/// Renders [component] and returns the alpha channel of the picture.
Future<List<int>> _alphaOf(Component component) async {
  final recorder = PictureRecorder();
  component.renderTree(Canvas(recorder));
  final picture = recorder.endRecording();
  final image = picture.toImageSync(_canvasSize, _canvasSize);
  picture.dispose();
  final data = (await image.toByteData())!;
  image.dispose();
  return [
    for (var i = 3; i < data.lengthInBytes; i += 4) data.getUint8(i),
  ];
}

int _at(List<int> alpha, int x, int y) => alpha[y * _canvasSize + x];

RectangleComponent _strokedBox() {
  // 20x20 box at (30, 30) with a 12 px stroke: the stroke covers 6 px on each
  // side of the box edge, which is x in [24, 36] for the left edge.
  return RectangleComponent(
    position: Vector2(30, 30),
    size: Vector2.all(20),
    paint: Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 12
      ..color = const Color(0xFFFF0000),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PositionComponent decorator bounds', () {
    testWidgets('an undecorated leaf paints outside its size box', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final alpha = await _alphaOf(_strokedBox());
        expect(_at(alpha, 25, 40), 255);
      });
    });

    testWidgets(
      'a PaintDecorator does not clip what a leaf paints outside its size box',
      (tester) async {
        await tester.runAsync(() async {
          final tint = PaintDecorator.tint(const Color(0x00000000));
          final box = _strokedBox()..decorator.addLast(tint);

          final alpha = await _alphaOf(box);

          expect(_at(alpha, 31, 40), 255, reason: 'inside the box edge');
          expect(_at(alpha, 25, 40), 255, reason: '5 px outside the box');
          expect(tint.lastSaveLayerBounds, isNull);
        });
      },
    );

    testWidgets(
      'a PaintDecorator does not clip custom painting that overflows the size '
      'box',
      (tester) async {
        await tester.runAsync(() async {
          final box = _OverflowingBox(position: Vector2(50, 50))
            ..decorator.addLast(PaintDecorator.tint(const Color(0x00FFFFFF)));

          final alpha = await _alphaOf(box);

          expect(_at(alpha, 60, 60), 255, reason: 'inside the size box');
          expect(_at(alpha, 43, 43), 255, reason: '7 px outside the size box');
        });
      },
    );

    testWidgets(
      'a Shadow3DDecorator chained after a PaintDecorator keeps its shadow',
      (tester) async {
        await tester.runAsync(() async {
          final box =
              _InBoundsBox(position: Vector2(60, 100), size: Vector2(30, 30))
                ..decorator.addLast(
                  PaintDecorator.tint(const Color(0x00FFFFFF)),
                )
                ..decorator.addLast(
                  // The shadow falls in front of the box, about 20 px below.
                  Shadow3DDecorator(
                    base: Vector2(0, 30),
                    xShift: 0,
                    angle: 1.8,
                    yScale: 3.0,
                  ),
                );

          final alpha = await _alphaOf(box);

          // The box covers (60..90, 100..130). Whatever is painted more than
          // 4 px outside of it can only be the shadow.
          var shadowPixels = 0;
          for (var y = 0; y < _canvasSize; y++) {
            for (var x = 0; x < _canvasSize; x++) {
              final inside = x >= 56 && x < 94 && y >= 96 && y < 134;
              if (!inside && _at(alpha, x, y) > 0) {
                shadowPixels++;
              }
            }
          }
          expect(shadowPixels, greaterThan(50));
        });
      },
    );

    testWidgets('explicit decoratorBounds bound the offscreen layer', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final tint = PaintDecorator.tint(const Color(0x00000000));
        final box = _strokedBox()
          ..decoratorBounds = const Rect.fromLTRB(-6, -6, 26, 26)
          ..decorator.addLast(tint);

        final alpha = await _alphaOf(box);

        expect(_at(alpha, 25, 40), 255, reason: 'covered by the bounds');
        final saved = tint.lastSaveLayerBounds!;
        expect(saved.left, closeTo(-8, 1e-4));
        expect(saved.width, closeTo(36, 1e-4));
      });
    });

    test('a container forwards explicit decoratorBounds only', () {
      final tint = PaintDecorator.tint(const Color(0x8800FFAA));
      final parent = PositionComponent(size: Vector2.all(50))
        ..add(_InBoundsBox(position: Vector2(120, 120), size: Vector2.all(30)))
        ..decorator.addLast(tint);

      void render() {
        final recorder = PictureRecorder();
        parent.renderTree(Canvas(recorder));
        recorder.endRecording().dispose();
      }

      render();
      expect(tint.lastSaveLayerBounds, isNull);

      parent.decoratorBounds = const Rect.fromLTWH(0, 0, 160, 160);
      render();
      expect(tint.lastSaveLayerBounds!.width, closeTo(164, 1e-4));
    });
  });
}
