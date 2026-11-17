import 'dart:async';
import 'dart:ui' as ui;

import 'package:clock/clock.dart';
import 'package:flame/cache.dart';
import 'package:flame_test/flame_test.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Runs [body] as if [duration] had passed since the real time now.
  T later<T>(Duration duration, T Function() body) {
    return withClock(Clock.fixed(DateTime.now().add(duration)), body);
  }

  group('Images.clearIfUnretained', () {
    test('removes an image that nothing uses', () async {
      final images = Images();
      final image = await images.fetchOrGenerate('img', generateImage);
      images.retain(image);
      images.release(image);

      // The release was a moment ago, which does not keep the image.
      expect(images.clearIfUnretained('img'), greaterThan(0));
      expect(images.containsKey('img'), isFalse);
      expect(image.debugDisposed, isTrue);
    });

    test('keeps a retained image', () async {
      final images = Images();
      final image = await images.fetchOrGenerate('img', generateImage);
      images.retain(image);
      expect(images.clearIfUnretained('img'), 0);
      expect(image.debugDisposed, isFalse);
    });

    test('returns 0 for an unknown key', () {
      expect(Images().clearIfUnretained('nothing'), 0);
    });

    test('keeps an image that is still loading', () async {
      final images = Images();
      final gate = Completer<ui.Image>();
      final pending = images.fetchOrGenerate('img', () => gate.future);

      expect(images.clearIfUnretained('img'), 0);
      expect(images.containsKey('img'), isTrue);

      gate.complete(await generateImage());
      final image = await pending;
      expect(image.debugDisposed, isFalse);
    });

    test(
      'keeps an image that was loaded within the grace period and is not '
      'retained yet',
      () async {
        final images = Images();
        final image = await images.fetchOrGenerate('img', generateImage);

        expect(images.clearIfUnretained('img'), 0);
        expect(image.debugDisposed, isFalse);

        // Once the grace period is over the loader is expected to have
        // retained the image if it still needs it.
        later(images.gracePeriod, () {
          expect(images.clearIfUnretained('img'), greaterThan(0));
        });
        expect(image.debugDisposed, isTrue);
      },
    );

    test('keeps an image that fromCache handed out a moment ago', () async {
      final images = Images();
      final image = await images.fetchOrGenerate('img', generateImage);
      images.retain(image);
      images.release(image);

      expect(images.fromCache('img'), same(image));
      expect(images.clearIfUnretained('img'), 0);
      expect(image.debugDisposed, isFalse);
    });

    test('a retain settles one hand-out, not all of them', () async {
      final images = Images();
      // Two loaders fetch the image, only one of them has retained it so far.
      final first = await images.fetchOrGenerate('img', generateImage);
      final second = await images.load('img');
      expect(second, same(first));
      images.retain(first);
      images.release(first);

      expect(images.clearIfUnretained('img'), 0);
      expect(first.debugDisposed, isFalse);
    });

    test(
      'hand-outs that were never retained expire with the grace period',
      () async {
        final images = Images();
        final image = await images.fetchOrGenerate('img', generateImage);
        expect(images.fromCache('img'), same(image));
        expect(images.clearIfUnretained('img'), 0);

        later(images.gracePeriod * 2, () {
          // A new owner fetches and retains the image long after the stale
          // hand-outs; they must not keep it alive once the owner lets go.
          expect(images.fromCache('img'), same(image));
          images.retain(image);
          images.release(image);
          expect(images.clearIfUnretained('img'), greaterThan(0));
        });
        expect(image.debugDisposed, isTrue);
      },
    );
  });

  group('AssetScope and shared images', () {
    test('frees the images that only it used right away', () async {
      final images = Images();
      final scope = AssetScope(
        name: 'scene',
        images: images,
        entries: [
          const ScopedAssetEntry(path: 'own.png', generator: generateImage),
        ],
      );
      await scope.preload();
      final image = scope.getImage('own.png');

      expect(scope.dispose(), greaterThan(0));
      expect(images.containsKey('own.png'), isFalse);
      expect(image.debugDisposed, isTrue);
    });

    test(
      'a scope that preloads a shared image while the previous scope is '
      'disposed ends up with a live, retained image',
      () async {
        final images = Images();
        var generated = 0;
        Future<ui.Image> generator() {
          generated++;
          return generateImage();
        }

        final previous = AssetScope(
          name: 'previous',
          images: images,
          entries: [
            ScopedAssetEntry(path: 'shared.png', generator: generator),
            ScopedAssetEntry(path: 'previous_only.png', generator: generator),
          ],
        );
        await previous.preload();
        expect(images.retainCount('shared.png'), 1);
        final exclusive = previous.getImage('previous_only.png');

        final next = AssetScope(
          name: 'next',
          images: images,
          entries: [
            ScopedAssetEntry(path: 'shared.png', generator: generator),
          ],
        );
        // Start loading the next scene, drop the previous one, then wait.
        final pending = next.preload();
        previous.dispose();
        await pending;

        expect(next.isLoaded, isTrue);
        final held = next.getImage('shared.png');
        expect(held.debugDisposed, isFalse);
        expect(images.retainCount('shared.png'), 1);
        expect(generated, 2, reason: 'the shared image was not loaded twice');
        // What only the previous scope used is still freed at once.
        expect(exclusive.debugDisposed, isTrue);

        // And the next scope frees the shared image when it goes in turn.
        next.dispose();
        expect(held.debugDisposed, isTrue);
      },
    );

    test(
      'disposing a scope keeps an image that another loader fetched a '
      'moment ago and has not retained yet',
      () async {
        final images = Images();
        final scope = AssetScope(
          name: 'scene',
          images: images,
          entries: [
            const ScopedAssetEntry(
              path: 'shared.png',
              generator: generateImage,
            ),
          ],
        );
        await scope.preload();

        // What a component does in its onLoad; it retains the image only
        // when it is mounted.
        final forComponent = await images.load('shared.png');

        expect(scope.dispose(), 0);
        expect(forComponent.debugDisposed, isFalse);
        expect(images.containsKey('shared.png'), isTrue);

        // The image is not leaked: it falls under the regular eviction.
        later(images.gracePeriod, () {
          expect(images.evictUnused(), greaterThan(0));
        });
        expect(forComponent.debugDisposed, isTrue);
      },
    );

    test(
      'preloading twice does not keep the images from being freed',
      () async {
        final images = Images();
        final scope = AssetScope(
          name: 'scene',
          images: images,
          entries: [
            const ScopedAssetEntry(path: 'own.png', generator: generateImage),
          ],
        );
        await scope.preload();
        await scope.preload();
        expect(images.retainCount('own.png'), 1);
        final image = scope.getImage('own.png');

        scope.dispose();
        expect(image.debugDisposed, isTrue);
      },
    );

    test('two entries with the same key hold the image once', () async {
      final images = Images();
      final scope = AssetScope(
        name: 'scene',
        images: images,
        entries: [
          const ScopedAssetEntry(
            path: 'a.png',
            key: 'same',
            generator: generateImage,
          ),
          const ScopedAssetEntry(
            path: 'b.png',
            key: 'same',
            generator: generateImage,
          ),
        ],
      );
      await scope.preload();
      expect(scope.progress, 1.0);
      expect(images.retainCount('same'), 1);
      final image = scope.getImage('same');

      scope.dispose();
      expect(image.debugDisposed, isTrue);
    });

    test(
      'an image that is cleared while the scope loads it is loaded again',
      () async {
        final images = Images();
        var generated = 0;
        final scope = AssetScope(
          name: 'scene',
          images: images,
          entries: [
            ScopedAssetEntry(
              path: 'img.png',
              generator: () {
                generated++;
                return generateImage();
              },
            ),
          ],
        );
        await images.fetchOrGenerate('img.png', generateImage);

        final pending = scope.preload();
        // Removed between the load completing and the scope retaining it.
        images.clear('img.png');
        await pending;

        expect(generated, 1);
        expect(scope.getImage('img.png').debugDisposed, isFalse);
        expect(images.retainCount('img.png'), 1);
        scope.dispose();
      },
    );
  });
}
