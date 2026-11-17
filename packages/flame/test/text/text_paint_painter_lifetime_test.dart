import 'dart:ui';

import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flame/text.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

Canvas _canvas() => Canvas(PictureRecorder());

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TextPaint painter lifetime', () {
    test('an element stays drawable after its string left the cache', () {
      final shared = TextPaint(style: const TextStyle(fontSize: 12));
      final first = shared.format('label 0');
      for (var i = 1; i <= 25; i++) {
        shared.format('label $i');
      }
      expect(shared.cachedPainterCount, 10);
      expect(first.textPainter.debugDisposed, isFalse);
      expect(() => first.draw(_canvas()), returnsNormally);
    });

    test('more components than cache entries can share one TextPaint', () {
      final shared = TextPaint(style: const TextStyle(fontSize: 12));
      final labels = [
        for (var i = 0; i < 25; i++)
          TextComponent(text: 'label $i', textRenderer: shared),
      ];
      // A second pass, as the following frames do.
      for (var pass = 0; pass < 2; pass++) {
        for (final label in labels) {
          expect(
            () => label.render(_canvas()),
            returnsNormally,
            reason: '"${label.text}" must still be drawable',
          );
        }
      }
    });

    test('a static label survives other labels changing their text', () {
      final shared = TextPaint(style: const TextStyle(fontSize: 12));
      final fixed = TextComponent(text: 'fixed', textRenderer: shared);
      final counter = TextComponent(text: '0', textRenderer: shared);
      for (var i = 1; i <= 40; i++) {
        counter.text = '$i';
        expect(() => fixed.render(_canvas()), returnsNormally);
        expect(() => counter.render(_canvas()), returnsNormally);
      }
    });

    test('dispose() keeps the painters of elements that are in use', () {
      final renderer = TextPaint(style: const TextStyle(fontSize: 12));
      final inUse = renderer.format('in use');
      final released = renderer.format('released');
      final releasedPainter = released.textPainter;
      released.dispose();

      renderer.dispose();

      expect(renderer.cachedPainterCount, 0);
      expect(releasedPainter.debugDisposed, isTrue);
      expect(inUse.textPainter.debugDisposed, isFalse);
      expect(() => inUse.draw(_canvas()), returnsNormally);

      // The last user going away releases the native paragraph.
      final painter = inUse.textPainter;
      inUse.dispose();
      expect(painter.debugDisposed, isTrue);
    });

    test('a disposed TextPaint can still be used by its components', () {
      final shared = TextPaint(style: const TextStyle(fontSize: 12));
      final label = TextComponent(text: 'still here', textRenderer: shared);
      shared.dispose();
      expect(() => label.render(_canvas()), returnsNormally);
      label.text = 'and again';
      expect(() => label.render(_canvas()), returnsNormally);
    });

    test('an evicted painter that nothing draws with is disposed', () {
      final renderer = TextPaint(
        style: const TextStyle(fontSize: 12),
        cacheSize: 2,
      );
      final element = renderer.format('a');
      final painter = element.textPainter;
      element.dispose();
      // Still cached, so it can be reused without a new layout.
      expect(painter.debugDisposed, isFalse);

      renderer.format('b').dispose();
      renderer.format('c').dispose();
      expect(renderer.cachedPainterCount, 2);
      expect(painter.debugDisposed, isTrue);
    });

    test('two elements of the same string share one painter', () {
      final renderer = TextPaint(
        style: const TextStyle(fontSize: 12),
        cacheSize: 1,
      );
      final a = renderer.format('same');
      final b = renderer.format('same');
      expect(renderer.layoutCount, 1);
      expect(identical(a.textPainter, b.textPainter), isTrue);
      final painter = a.textPainter;

      renderer.format('other').dispose();
      a.dispose();
      expect(painter.debugDisposed, isFalse);
      expect(() => b.draw(_canvas()), returnsNormally);
      b.dispose();
      expect(painter.debugDisposed, isTrue);
      // Disposing an element twice does not release someone else's hold.
      final c = renderer.format('third');
      final d = renderer.format('third');
      c.dispose();
      c.dispose();
      renderer.dispose();
      expect(() => d.draw(_canvas()), returnsNormally);
    });

    test('a string that is used again is the last one to be evicted', () {
      final renderer = TextPaint(
        style: const TextStyle(fontSize: 12),
        cacheSize: 2,
      );
      renderer.getLineMetrics('hot');
      renderer.getLineMetrics('cold');
      renderer.getLineMetrics('hot');
      renderer.getLineMetrics('new');
      expect(renderer.layoutCount, 3);

      renderer.getLineMetrics('hot');
      expect(renderer.layoutCount, 3, reason: '"hot" was laid out again');
      renderer.getLineMetrics('cold');
      expect(renderer.layoutCount, 4);
    });

    test('measuring and rendering leave nothing behind to keep alive', () {
      final renderer = TextPaint(
        style: const TextStyle(fontSize: 12),
        cacheSize: 1,
      );
      final element = renderer.format('probe');
      final painter = element.textPainter;
      final formatted = element.metrics;
      element.dispose();

      final measured = renderer.getLineMetrics('probe');
      expect(measured.width, formatted.width);
      expect(measured.height, formatted.height);
      expect(measured.ascent, formatted.ascent);
      renderer.render(_canvas(), 'probe', Vector2(3, 4));
      expect(renderer.layoutCount, 1);

      renderer.getLineMetrics('next');
      expect(painter.debugDisposed, isTrue);
    });

    test('toTextPainter hands out a painter that is never disposed', () {
      final renderer = TextPaint(
        style: const TextStyle(fontSize: 12),
        cacheSize: 1,
      );
      final painter = renderer.toTextPainter('kept by the caller');
      renderer.toTextPainter('another');
      renderer.dispose();
      expect(painter.debugDisposed, isFalse);
      expect(() => painter.paint(_canvas(), Offset.zero), returnsNormally);
    });

    test('a cacheSize of 0 lays out every time and caches nothing', () {
      final renderer = TextPaint(
        style: const TextStyle(fontSize: 12),
        cacheSize: 0,
      );
      expect(() => renderer.toTextPainter('a'), returnsNormally);
      final element = renderer.format('a');
      expect(renderer.cachedPainterCount, 0);
      expect(renderer.layoutCount, 2);
      expect(() => element.draw(_canvas()), returnsNormally);
      final painter = element.textPainter;
      element.dispose();
      expect(painter.debugDisposed, isTrue);
    });

    test('copyWith keeps the cache size', () {
      final renderer = TextPaint(cacheSize: 3);
      expect(renderer.copyWith((style) => style).cacheSize, 3);
      expect(renderer.copyWithPaint(Paint()).cacheSize, 3);
    });
  });

  group('TextComponent with a shared TextPaint', () {
    test('changing the text gives the previous painter back', () {
      final shared = TextPaint(
        style: const TextStyle(fontSize: 12),
        cacheSize: 1,
      );
      final label = TextComponent(text: 'one', textRenderer: shared);
      final first = shared.format('one');
      final firstPainter = first.textPainter;
      first.dispose();

      label.text = 'two';
      expect(firstPainter.debugDisposed, isTrue);
      expect(() => label.render(_canvas()), returnsNormally);
    });

    test(
      'a removed component gives its painter back and can come back',
      () async {
        final shared = TextPaint(
          style: const TextStyle(fontSize: 12),
          cacheSize: 1,
        );
        final label = TextComponent(text: 'gone', textRenderer: shared);
        final probe = shared.format('gone');
        final painter = probe.textPainter;
        probe.dispose();

        final game = FlameGame()..onGameResize(Vector2(300, 200));
        await game.start();
        game.world.add(label);
        await game.ready();

        label.removeFromParent();
        game.processLifecycleEvents();
        // Nothing draws with it any more, so one more string evicts and
        // disposes it.
        shared.getLineMetrics('other');
        expect(painter.debugDisposed, isTrue);

        game.world.add(label);
        await game.ready();
        expect(() => game.render(_canvas()), returnsNormally);
      },
    );
  });
}
