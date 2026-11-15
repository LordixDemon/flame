import 'dart:ui';

import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flame/text.dart';
import 'package:flutter/painting.dart' show FontWeight, TextStyle;
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RasterFontAtlas & GlyphBatchLayer', () {
    test('RasterFontAtlas bakes glyphs synchronously and measures widths', () {
      final atlas = RasterFontAtlas.bake(
        style: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w700,
        ),
        outlineWidth: 2.0,
        includeCyrillic: true,
      );
      addTearDown(atlas.dispose);

      expect(atlas.isDisposed, isFalse);
      expect(atlas.image.width, greaterThan(32));
      expect(atlas.image.height, greaterThan(16));
      expect(atlas.glyphCount, greaterThan(140));

      final wShort = atlas.measureWidth('+50');
      final wLong = atlas.measureWidth('+50000×2');
      final wCyr = atlas.measureWidth('Рента');
      expect(wShort, greaterThan(0));
      expect(wLong, greaterThan(wShort));
      expect(wCyr, greaterThan(0));

      atlas.dispose();
      expect(atlas.isDisposed, isTrue);
    });

    test(
      'GlyphBatchLayer merges 8 BatchedTextComponents into 1 drawRawAtlas',
      () {
        final atlas = RasterFontAtlas.bake(
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          outlineWidth: 1.5,
        );
        addTearDown(atlas.dispose);

        final layer = GlyphBatchLayer();
        final labels = <String>[
          '240',
          'x2',
          '560',
          '+1200',
          '80',
          'x4',
          '990',
          '1500',
        ];
        for (var i = 0; i < labels.length; i++) {
          layer.add(
            BatchedTextComponent(
              atlas: atlas,
              text: labels[i],
              position: Vector2(i * 40.0, 20.0),
              anchor: Anchor.center,
              color: const Color(0xFFFFE082),
            ),
          );
        }
        // Force immediate mount via a minimal parent tree.
        final root = FlameGame();
        root.world.add(layer);
        root.processLifecycleEvents();

        final telemetry = RenderFrameTelemetry()..beginRenderFrame();
        final recorder = PictureRecorder();
        final telCanvas = TelemetryCanvas()..bind(Canvas(recorder), telemetry);

        layer.renderTree(telCanvas);
        telCanvas.unbind();
        telemetry.endRenderFrame();
        recorder.endRecording().dispose();

        expect(layer.lastBatchedComponentCount, 8);
        expect(layer.lastBatchedGlyphCount, greaterThanOrEqualTo(23));
        expect(layer.lastAtlasDrawCalls, 1);
        expect(telemetry.atlasCalls, 1);
      },
    );
  });
}
