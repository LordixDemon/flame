import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/components.dart';
import 'package:flame/text.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records the quads of every `drawRawAtlas` call and ignores the rest.
class _SpyCanvas() implements ui.Canvas {
  final List<({ui.Image image, Float32List transforms, Float32List rects})>
  atlasCalls = [];

  @override
  void drawRawAtlas(
    ui.Image atlas,
    Float32List rstTransforms,
    Float32List rects,
    Int32List? colors,
    ui.BlendMode? blendMode,
    ui.Rect? cullRect,
    ui.Paint paint,
  ) {
    atlasCalls.add((
      image: atlas,
      transforms: Float32List.fromList(rstTransforms),
      rects: Float32List.fromList(rects),
    ));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

ui.Image _solidImage(int size) {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    ui.Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
    ui.Paint()..color = const ui.Color(0xFFFFFFFF),
  );
  final picture = recorder.endRecording();
  final image = picture.toImageSync(size, size);
  picture.dispose();
  return image;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('RichBatchedTextComponent inline icons', () {
    test('every icon is drawn on the first render, however many there are', () {
      final atlas = RasterFontAtlas.bake(
        style: const TextStyle(fontSize: 12),
        charset: ' x',
      );
      addTearDown(atlas.dispose);
      final icon = _solidImage(8);
      addTearDown(icon.dispose);

      // More icons than the icon buffer holds at first, so that it has to
      // grow (twice) in the middle of the render pass.
      const iconCount = 20;
      final text = RichBatchedTextComponent(
        atlas: atlas,
        markup: List<String>.filled(iconCount, '[icon:gem]').join(),
        icons: <String, RichTextIconSpan>{
          'gem': RichTextIconSpan(
            image: icon,
            srcRect: const ui.Rect.fromLTWH(0, 0, 8, 8),
            logicalWidth: 8,
            logicalHeight: 8,
          ),
        },
      );

      final spy = _SpyCanvas();
      text.render(spy);

      final iconCall = spy.atlasCalls.singleWhere(
        (c) => identical(c.image, icon),
      );
      expect(iconCall.transforms.length, iconCount * 4);
      for (var i = 0; i < iconCount; i++) {
        expect(iconCall.transforms[i * 4], 1.0, reason: 'scale of icon $i');
        expect(
          iconCall.transforms[i * 4 + 2],
          closeTo(i * 8.0, 1e-4),
          reason: 'x of icon $i',
        );
        expect(iconCall.rects[i * 4 + 2], 8.0, reason: 'source of icon $i');
      }
    });
  });

  group('GlyphBatchRenderer line breaks', () {
    late RasterFontAtlas atlas;

    setUp(() {
      atlas = RasterFontAtlas.bake(
        style: const TextStyle(fontSize: 16),
        charset: ' abc?',
      );
    });

    tearDown(() => atlas.dispose());

    ({Float32List transforms, Float32List rects}) quadsOf(
      String text, {
      Anchor anchor = Anchor.topLeft,
    }) {
      final spy = _SpyCanvas();
      GlyphBatchRenderer()
        ..begin()
        ..addText(atlas, text, x: 100, y: 50, anchor: anchor)
        ..flush(spy, atlas);
      final call = spy.atlasCalls.single;
      return (transforms: call.transforms, rects: call.rects);
    }

    test('a line feed starts a new line instead of drawing a glyph', () {
      final single = quadsOf('ab');
      final broken = quadsOf('ab\nc');
      final placeholder = atlas.metricsForRune(0x3F)!.atlasRect;

      // Three glyphs: no quad for the line feed, and none of them is the
      // fallback glyph.
      expect(broken.transforms.length, 3 * 4);
      for (var i = 0; i < 3; i++) {
        final isPlaceholder =
            broken.rects[i * 4] == placeholder.left &&
            broken.rects[i * 4 + 1] == placeholder.top;
        expect(isPlaceholder, isFalse, reason: 'glyph $i');
      }
      // The first line is where a single-line text is.
      for (var i = 0; i < 8; i++) {
        expect(broken.transforms[i], single.transforms[i]);
      }
      // The second line starts back at the left, one line height lower.
      expect(broken.transforms[2 * 4 + 2], single.transforms[2]);
      expect(
        broken.transforms[2 * 4 + 3],
        closeTo(single.transforms[3] + atlas.lineHeight, 1e-4),
      );

      // A carriage return before the line feed changes nothing.
      final crlf = quadsOf('ab\r\nc');
      expect(crlf.transforms, broken.transforms);
    });

    test('the anchor centres each line and the whole block', () {
      final wide = atlas.measureWidth('abc');
      final narrow = atlas.measureWidth('a');
      expect(atlas.measureWidth('abc\na'), wide);
      expect(atlas.measureWidth('a\nabc'), wide);
      expect(atlas.lineCountOf('a\nabc'), 2);
      expect(atlas.lineCountOf('abc'), 1);

      final centred = quadsOf('abc\na', anchor: Anchor.center);
      final offsetX = atlas.metricsForRune(0x61)!.drawOffsetX;
      final offsetY = atlas.metricsForRune(0x61)!.drawOffsetY;
      // First glyph of the wide line and the only glyph of the narrow one.
      expect(centred.transforms[2], closeTo(100 - wide / 2 + offsetX, 1e-3));
      expect(
        centred.transforms[3 * 4 + 2],
        closeTo(100 - narrow / 2 + offsetX, 1e-3),
      );
      // Two lines centred on y = 50.
      expect(
        centred.transforms[3],
        closeTo(50 - atlas.lineHeight + offsetY, 1e-3),
      );
      expect(centred.transforms[3 * 4 + 3], closeTo(50 + offsetY, 1e-3));
    });

    test('a BatchedTextComponent is as tall as its lines', () {
      final label = BatchedTextComponent(atlas: atlas, text: 'ab\nc\nabc');
      expect(label.size.x, closeTo(atlas.measureWidth('abc'), 1e-6));
      expect(label.size.y, closeTo(atlas.lineHeight * 3, 1e-6));
    });
  });

  group('DynamicFontAtlas', () {
    test('pads glyph cells for the reach of the style shadows', () {
      final plain = DynamicFontAtlas(
        style: const TextStyle(fontSize: 16),
        preloadCharset: '',
      );
      addTearDown(plain.dispose);
      final shadowed = DynamicFontAtlas(
        style: const TextStyle(
          fontSize: 16,
          shadows: <Shadow>[
            Shadow(offset: Offset(3, 4), blurRadius: 2),
          ],
        ),
        preloadCharset: '',
      );
      addTearDown(shadowed.dispose);

      final a = plain.ensureGlyph(0x41);
      final b = shadowed.ensureGlyph(0x41);
      // Offset 4 plus twice the blur radius of 2 on every side.
      expect(b.logicalWidth - a.logicalWidth, closeTo(16.0, 1.0));
      expect(b.logicalHeight - a.logicalHeight, closeTo(16.0, 1.0));
      expect(b.drawOffsetX, closeTo(a.drawOffsetX - 8.0, 1e-6));
      expect(b.advance, a.advance);
    });

    test('breaks lines in drawText without baking control characters', () {
      final atlas = DynamicFontAtlas(
        style: const TextStyle(fontSize: 16),
        preloadCharset: '',
      );
      addTearDown(atlas.dispose);

      final spy = _SpyCanvas();
      expect(atlas.drawText(spy, 'ab\r\nc', x: 10, y: 20), 1);
      expect(atlas.glyphCount, 3);

      final transforms = spy.atlasCalls.single.transforms;
      expect(transforms.length, 3 * 4);
      expect(transforms[2 * 4 + 2], transforms[2]);
      expect(
        transforms[2 * 4 + 3],
        closeTo(transforms[3] + atlas.lineHeight, 1e-4),
      );
    });

    test('a disposed atlas draws nothing and refuses to bake', () {
      final atlas = DynamicFontAtlas(style: const TextStyle(fontSize: 16));
      expect(atlas.isDisposed, isFalse);
      expect(atlas.pageCount, 1);

      atlas.dispose();
      atlas.dispose();
      expect(atlas.isDisposed, isTrue);
      expect(atlas.pageCount, 0);
      expect(atlas.glyphCount, 0);

      final spy = _SpyCanvas();
      expect(atlas.drawText(spy, 'abc', x: 0, y: 0), 0);
      expect(spy.atlasCalls, isEmpty);
      expect(() => atlas.ensureGlyph(0x41), throwsStateError);
      expect(() => atlas.ensureGlyphsForText('abc'), throwsStateError);
    });
  });
}
