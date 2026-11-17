import 'dart:math';
import 'dart:ui';

import 'package:flame/particles.dart';
import 'package:flame/src/particles/shared_particle_texture_cache.dart';
import 'package:flutter_test/flutter_test.dart';

Image _image() {
  final recorder = PictureRecorder();
  Canvas(recorder).drawRect(
    const Rect.fromLTWH(0, 0, 2, 2),
    Paint()..color = const Color(0xFFFFFFFF),
  );
  final picture = recorder.endRecording();
  try {
    return picture.toImageSync(2, 2);
  } finally {
    picture.dispose();
  }
}

ParticleEmitterComponent _emitterWith(ParticleRenderer renderer) {
  return ParticleEmitterComponent(
    emitter: ParticleEmitter(
      maxParticles: 8,
      bursts: const <EmitterBurst>[EmitterBurst(0, 4)],
      lifespan: (5, 5),
    ),
    renderer: renderer,
    removeOnFinish: false,
    random: Random(1),
  )..update(0.016);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SharedParticleTextureCache', () {
    test('hands the same texture to every owner of a key', () {
      final cache = SharedParticleTextureCache<int>(capacity: 4);
      final ownerA = Object();
      final ownerB = Object();
      var created = 0;
      Image create() {
        created++;
        return _image();
      }

      final a = cache.acquire(1, ownerA, create);
      final b = cache.acquire(1, ownerB, create);
      expect(b, same(a));
      expect(created, 1);
      expect(cache.size, 1);

      cache
        ..release(a, ownerA)
        ..release(b, ownerB)
        ..clear();
      expect(a.isDisposed, isTrue);
    });

    test('evicts and disposes only textures nobody uses', () {
      final cache = SharedParticleTextureCache<int>(capacity: 2);
      final owner = Object();
      final held = cache.acquire(0, owner, _image);
      final idle = cache.acquire(1, owner, _image);
      cache.release(idle, owner);

      // Over capacity: the idle texture goes, the held one stays.
      final next = cache.acquire(2, owner, _image);
      expect(cache.size, 2);
      expect(idle.isDisposed, isTrue);
      expect(idle.image.debugDisposed, isTrue);
      expect(held.isDisposed, isFalse);
      expect(held.image.debugDisposed, isFalse);

      // With every texture in use the cache grows instead of disposing one.
      final extra = cache.acquire(3, owner, _image);
      expect(cache.size, 3);
      expect(held.isDisposed, isFalse);
      expect(next.isDisposed, isFalse);

      // Releasing brings it back under its capacity.
      cache.release(extra, owner);
      expect(cache.size, 2);
      expect(extra.isDisposed, isTrue);

      cache
        ..release(held, owner)
        ..release(next, owner)
        ..clear();
    });

    test('clear keeps textures in use alive until their last release', () {
      final cache = SharedParticleTextureCache<int>(capacity: 4);
      final ownerA = Object();
      final ownerB = Object();
      final shared = cache.acquire(0, ownerA, _image);
      cache.acquire(0, ownerB, _image);
      final idle = cache.acquire(1, ownerA, _image);
      cache
        ..release(idle, ownerA)
        ..clear();

      expect(cache.size, 0);
      expect(idle.isDisposed, isTrue);
      expect(shared.isDisposed, isFalse);

      // A new owner of the same key gets a new texture.
      final ownerC = Object();
      final fresh = cache.acquire(0, ownerC, _image);
      expect(fresh, isNot(same(shared)));

      cache.release(shared, ownerA);
      expect(shared.isDisposed, isFalse);
      cache.release(shared, ownerB);
      expect(shared.isDisposed, isTrue);
      expect(fresh.isDisposed, isFalse);

      cache
        ..release(fresh, ownerC)
        ..clear();
    });
  });

  group('CircleParticleRenderer shared texture', () {
    tearDown(CircleParticleRenderer.clearTextureCache);

    test('a loaded renderer keeps drawing after clearTextureCache', () async {
      // A long-lived renderer shared by many emitters.
      final shared = CircleParticleRenderer(softness: 0.36);
      await shared.onLoad();
      final emitter = _emitterWith(shared);
      final texture = shared.texture;

      CircleParticleRenderer.clearTextureCache();
      expect(CircleParticleRenderer.cachedTextureCount, 0);
      // What an emitter that is added to the tree again does.
      await shared.onLoad();

      expect(shared.texture, same(texture));
      expect(shared.texture!.debugDisposed, isFalse);
      final recorder = PictureRecorder();
      expect(() => emitter.render(Canvas(recorder)), returnsNormally);
      recorder.endRecording().dispose();

      // Renderers loaded after the clear share a new texture.
      final later = CircleParticleRenderer(softness: 0.36);
      await later.onLoad();
      expect(later.texture, isNot(same(texture)));
      expect(later.texture!.debugDisposed, isFalse);
    });

    test('a loaded renderer survives more softness values than fit', () async {
      final first = CircleParticleRenderer();
      await first.onLoad();
      final others = <CircleParticleRenderer>[];
      for (var i = 1; i <= 30; i++) {
        final renderer = CircleParticleRenderer(softness: i / 64);
        await renderer.onLoad();
        others.add(renderer);
      }

      expect(first.texture!.debugDisposed, isFalse);
      for (final renderer in others) {
        expect(renderer.texture!.debugDisposed, isFalse);
      }
    });

    test(
      'dispose gives the texture back and onLoad takes a live one',
      () async {
        final renderer = CircleParticleRenderer(softness: 0.5);
        await renderer.onLoad();
        final texture = renderer.texture!;

        renderer.dispose();
        expect(renderer.texture, isNull);
        // Still cached for the next renderer of that softness.
        expect(texture.debugDisposed, isFalse);

        CircleParticleRenderer.clearTextureCache();
        expect(texture.debugDisposed, isTrue);

        await renderer.onLoad();
        expect(renderer.texture, isNotNull);
        expect(renderer.texture!.debugDisposed, isFalse);
        final emitter = _emitterWith(renderer);
        final recorder = PictureRecorder();
        expect(() => emitter.render(Canvas(recorder)), returnsNormally);
        recorder.endRecording().dispose();
      },
    );

    test('a texture in use is disposed with its last renderer', () async {
      final a = CircleParticleRenderer(softness: 0.25);
      final b = CircleParticleRenderer(softness: 0.25);
      await a.onLoad();
      await b.onLoad();
      final texture = a.texture!;
      expect(b.texture, same(texture));

      CircleParticleRenderer.clearTextureCache();
      a.dispose();
      expect(texture.debugDisposed, isFalse);
      b.dispose();
      expect(texture.debugDisposed, isTrue);
    });
  });

  group('NoiseCloudParticleRenderer shared atlas', () {
    tearDown(NoiseCloudParticleRenderer.clearAtlasCache);

    test(
      'a loaded renderer survives more seeds than the cache holds',
      () async {
        final first = NoiseCloudParticleRenderer(seed: 1);
        await first.onLoad();
        final others = <NoiseCloudParticleRenderer>[];
        for (var seed = 2; seed <= 20; seed++) {
          final renderer = NoiseCloudParticleRenderer(seed: seed);
          await renderer.onLoad();
          others.add(renderer);
        }

        expect(first.texture!.debugDisposed, isFalse);
        final emitter = _emitterWith(first);
        final recorder = PictureRecorder();
        expect(() => emitter.render(Canvas(recorder)), returnsNormally);
        recorder.endRecording().dispose();
      },
    );

    test('a loaded renderer keeps drawing after clearAtlasCache', () async {
      final shared = NoiseCloudParticleRenderer();
      await shared.onLoad();
      final atlas = shared.texture;

      NoiseCloudParticleRenderer.clearAtlasCache();
      await shared.onLoad();

      expect(shared.texture, same(atlas));
      expect(shared.texture!.debugDisposed, isFalse);
    });

    test(
      'renderers share an atlas only for the same seed and puffiness',
      () async {
        final a = NoiseCloudParticleRenderer(seed: 5);
        final same5 = NoiseCloudParticleRenderer(seed: 5);
        final wrapped = NoiseCloudParticleRenderer(seed: 5 + 65536);
        final puffier = NoiseCloudParticleRenderer(seed: 5, puffiness: 0.9);
        for (final renderer in [a, same5, wrapped, puffier]) {
          await renderer.onLoad();
        }

        expect(same5.texture, same(a.texture));
        expect(wrapped.texture, isNot(same(a.texture)));
        expect(puffier.texture, isNot(same(a.texture)));
        expect(NoiseCloudParticleRenderer.cachedAtlasCount, 3);
      },
    );
  });
}
