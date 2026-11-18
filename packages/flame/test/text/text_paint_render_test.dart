import 'dart:ui';

import 'package:flame/components.dart';
import 'package:flame/text.dart';
import 'package:flutter_test/flutter_test.dart';

/// A canvas that records where paragraphs are drawn.
class _ParagraphLog() implements Canvas {
  final List<Offset> offsets = [];

  @override
  void drawParagraph(Paragraph paragraph, Offset offset) => offsets.add(offset);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  group('TextPaint.render', () {
    test('draws exactly where a formatted element draws', () {
      final paint = TextPaint(
        style: const TextStyle(fontSize: 13.5, height: 1.3),
      );
      for (final text in ['', 'a', 'Hello, world', 'WgÉ']) {
        for (final anchor in [
          Anchor.topLeft,
          Anchor.center,
          Anchor.bottomRight,
          const Anchor(0.3, 0.7),
        ]) {
          for (final position in [
            Vector2.zero(),
            Vector2(10.5, -3.25),
            Vector2(-0.0, 7),
            Vector2(1e6 + 0.1, -1e-7),
          ]) {
            final direct = _ParagraphLog();
            paint.render(direct, text, position, anchor: anchor);
            final viaElement = _ParagraphLog();
            final element = paint.format(text);
            element.render(viaElement, position, anchor: anchor);
            element.dispose();
            expect(
              direct.offsets,
              viaElement.offsets,
              reason: '"$text" at $position, $anchor',
            );
            expect(
              direct.offsets.single.dx.isNegative,
              viaElement.offsets.single.dx.isNegative,
            );
          }
        }
      }
    });

    test('formats through a subclass that formats differently', () {
      final paint = _Shifted();
      final canvas = _ParagraphLog();
      paint.render(canvas, 'text', Vector2(1, 2));
      expect(paint.formatted, 1);
      final element = TextPaint().format('text');
      final expected = _ParagraphLog();
      element.render(expected, Vector2(1, 2));
      expect(
        canvas.offsets.single,
        expected.offsets.single + const Offset(5, 0),
      );
    });

    test('lays a string out once, and again only when it left the cache', () {
      final paint = TextPaint(cacheSize: 2);
      final canvas = _ParagraphLog();
      for (var i = 0; i < 5; i++) {
        paint.render(canvas, 'one', Vector2.zero());
      }
      expect(paint.layoutCount, 1);
      paint
        ..render(canvas, 'two', Vector2.zero())
        ..render(canvas, 'three', Vector2.zero())
        ..render(canvas, 'one', Vector2.zero());
      expect(paint.layoutCount, 4);
    });

    test('without a cache lays every string out and keeps nothing', () {
      final paint = TextPaint(cacheSize: 0);
      final canvas = _ParagraphLog();
      paint
        ..render(canvas, 'one', Vector2.zero())
        ..render(canvas, 'one', Vector2.zero());
      expect(paint.layoutCount, 2);
      expect(paint.cachedPainterCount, 0);
      expect(canvas.offsets, hasLength(2));
    });

    test('leaves an element that shares its painter drawable', () {
      final paint = TextPaint(cacheSize: 1);
      final element = paint.format('held');
      final canvas = _ParagraphLog();
      // Pushes 'held' out of the cache while the element still holds it.
      paint.render(canvas, 'other', Vector2.zero());
      paint.render(canvas, 'held', Vector2.zero());
      paint.render(canvas, 'other', Vector2.zero());
      element.render(canvas, Vector2.zero());
      expect(canvas.offsets, hasLength(4));
      element.dispose();
    });

    test('draws a picture identical to a formatted element', () async {
      final paint = TextPaint(
        style: const TextStyle(fontSize: 20, color: Color(0xFFFFFFFF)),
      );
      Future<List<int>> draw(void Function(Canvas) body) async {
        final recorder = PictureRecorder();
        body(Canvas(recorder));
        final image = await recorder.endRecording().toImage(120, 40);
        final bytes = await image.toByteData();
        return bytes!.buffer.asUint8List();
      }

      final direct = await draw(
        (canvas) => paint.render(
          canvas,
          'Flame',
          Vector2(60, 20),
          anchor: Anchor.center,
        ),
      );
      final viaElement = await draw((canvas) {
        final element = paint.format('Flame');
        element.render(canvas, Vector2(60, 20), anchor: Anchor.center);
        element.dispose();
      });
      expect(direct, orderedEquals(viaElement));
    });
  });
}

/// A text paint that draws everything 5 pixels further right.
class _Shifted() extends TextPaint {
  int formatted = 0;

  @override
  TextPainterTextElement format(String text) {
    formatted++;
    return super.format(text)..translate(5, 0);
  }
}
