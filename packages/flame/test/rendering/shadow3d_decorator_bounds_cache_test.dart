import 'dart:ui';

import 'package:flame/components.dart';
import 'package:flame/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

class _Box({super.position, super.size}) extends PositionComponent {
  @override
  void render(Canvas canvas) {
    canvas.drawRect(size.toRect(), Paint()..color = const Color(0xFF3366FF));
  }
}

void _render(PositionComponent c) {
  final recorder = PictureRecorder();
  c.renderTree(Canvas(recorder));
  recorder.endRecording().dispose();
}

void main() {
  group('Shadow3DDecorator bounded layer cache', () {
    test('every property change keeps the shadow layer bounded and moves '
        'its bounds', () {
      final box = _Box(position: Vector2(100, 100), size: Vector2(40, 60));
      final shadow = Shadow3DDecorator(
        base: Vector2(0, 60),
        angle: -0.9,
        xShift: 18,
        yScale: 1.4,
        blur: 3.0,
      );
      box.decorator.addLast(shadow);

      _render(box);
      var previous = shadow.lastSaveLayerBounds;
      expect(previous, isNotNull);

      final changes = <String, void Function()>{
        'xShift': () => shadow.xShift = 40,
        'ascent': () => shadow.ascent = 12,
        'angle': () => shadow.angle = -1.1,
        'yScale': () => shadow.yScale = 2.0,
        'blur': () => shadow.blur = 6.0,
        'base': () => shadow.base = Vector2(4, 58),
      };
      for (final MapEntry(key: name, value: change) in changes.entries) {
        change();
        _render(box);
        final bounds = shadow.lastSaveLayerBounds;
        expect(bounds, isNotNull, reason: 'unbounded after $name changed');
        expect(bounds, isNot(equals(previous)), reason: '$name ignored');
        previous = bounds;
      }
    });

    test('an animated shadow stays bounded on every frame and the bounds '
        'match a freshly built decorator', () {
      final box = _Box(position: Vector2(100, 100), size: Vector2(40, 60));
      final shadow = Shadow3DDecorator(base: Vector2(0, 60), blur: 2.0);
      box.decorator.addLast(shadow);
      _render(box);
      expect(shadow.lastSaveLayerBounds, isNotNull);

      for (var i = 1; i <= 10; i++) {
        shadow.ascent = i * 2.0;
        _render(box);
        expect(shadow.lastSaveLayerBounds, isNotNull, reason: 'frame $i');

        final fresh = Shadow3DDecorator(
          base: Vector2(0, 60),
          blur: 2.0,
          ascent: i * 2.0,
        );
        final freshBox = _Box(
          position: Vector2(100, 100),
          size: Vector2(40, 60),
        )..decorator.addLast(fresh);
        _render(freshBox);
        expect(shadow.lastSaveLayerBounds, fresh.lastSaveLayerBounds);
      }
    });

    test('unchanged properties reuse the cached bounds', () {
      final box = _Box(position: Vector2(100, 100), size: Vector2(40, 60));
      final shadow = Shadow3DDecorator(base: Vector2(0, 60), blur: 2.0);
      box.decorator.addLast(shadow);
      _render(box);
      final first = shadow.lastSaveLayerBounds;
      _render(box);
      expect(identical(shadow.lastSaveLayerBounds, first), isTrue);
    });
  });
}
