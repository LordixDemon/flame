import 'dart:ui';

import 'package:flame/cache.dart';
import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

class _PaintCarrier() extends Component with HasPaint;

void main() {
  group('Text fast opacity modulation, MemoryCache.onEvict, & HasPaint', () {
    test('HasPaint.getAlpha returns 0..255 instead of 0 for float alpha', () {
      final carrier = _PaintCarrier();
      expect(carrier.getAlpha(), 255);
      carrier.setOpacity(0.5);
      expect(carrier.getAlpha(), closeTo(128, 1));
      carrier.setAlpha(64);
      expect(carrier.getAlpha(), 64);
      carrier.setOpacity(0.0);
      expect(carrier.getAlpha(), 0);
    });

    test(
      'MemoryCache.onEvict fires on FIFO eviction, overwrite, and clear',
      () {
        final evicted = <(String, int)>[];
        final cache = MemoryCache<String, int>(
          cacheSize: 2,
          onEvict: (k, v) => evicted.add((k, v)),
        );

        cache.setValue('a', 1);
        cache.setValue('b', 2);
        expect(evicted, isEmpty);

        // Exceeding capacity evicts 'a'.
        cache.setValue('c', 3);
        expect(evicted, [('a', 1)]);

        // Non-identical overwrite evicts previous value for 'b'.
        cache.setValue('b', 20);
        expect(evicted, [('a', 1), ('b', 2)]);

        // Clear single key & clearCache notify remaining entries.
        cache.clear('b');
        expect(evicted, [('a', 1), ('b', 2), ('b', 20)]);

        cache.clearCache();
        expect(evicted, [('a', 1), ('b', 2), ('b', 20), ('c', 3)]);
      },
    );

    test(
      'TextComponent with TextPaint performs 0 extra layouts across 60 '
      'opacity frames and copyWithPaint avoids color/foreground assert',
      () async {
        final renderer = TextPaint(
          style: const TextStyle(
            fontSize: 18,
            color: Color(0xFFFFDD66),
          ),
        );
        // Verify copyWithPaint never triggers TextStyle color+foreground assert
        final copied = renderer.copyWithPaint(
          Paint()..color = const Color(0x80FFFFFF),
        );
        expect(copied.style.color, isNull);
        expect(copied.style.foreground, isNotNull);
        copied.dispose();

        final label = TextComponent(
          text: '+450G',
          textRenderer: renderer,
        );
        expect(renderer.layoutCount, 1);

        final game = FlameGame(children: [label])
          ..onGameResize(Vector2(400, 300));
        await game.start();

        for (var i = 0; i < 60; i++) {
          label.setOpacity((60 - i) / 60.0);
          final recorder = PictureRecorder();
          game.render(Canvas(recorder));
          recorder.endRecording().dispose();
        }

        // HarfBuzz layout ran once at creation, zero times across 60 fade steps
        expect(renderer.layoutCount, 1);

        renderer.dispose();
        expect(renderer.cachedPainterCount, 0);
      },
    );

    test(
      'owned default TextPaint disposes on remove and rehydrates on remount',
      () async {
        final label = TextComponent(text: 'Recycled');
        final game = FlameGame()..onGameResize(Vector2(300, 200));
        await game.start();

        game.world.add(label);
        await game.ready();

        label.removeFromParent();
        game.processLifecycleEvents();
        expect(label.isMounted, isFalse);

        // Re-adding to tree re-hydrates element cleanly without error.
        game.world.add(label);
        await game.ready();
        final recorder = PictureRecorder();
        game.render(Canvas(recorder));
        recorder.endRecording().dispose();
        expect(label.isMounted, isTrue);
      },
    );
  });
}
