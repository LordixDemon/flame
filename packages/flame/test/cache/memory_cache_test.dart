import 'package:flame/cache.dart';
import 'package:test/test.dart';

void main() {
  group('MemoryCache', () {
    test('basic cache access', () {
      final cache = MemoryCache<int, String>();
      cache.setValue(0, 'bla');
      expect(cache.getValue(0), 'bla');
    });

    test('containsKey', () {
      final cache = MemoryCache<int, String>();
      expect(cache.keys.length, 0);
      cache.setValue(0, 'bla');
      expect(cache.containsKey(0), true);
      expect(cache.containsKey(1), false);
      expect(cache.keys.length, 1);
    });

    test('updates key', () {
      final cache = MemoryCache<int, String>();
      cache.setValue(0, 'bla');
      expect(cache.getValue(0), 'bla');
      cache.setValue(0, 'ble');
      expect(cache.getValue(0), 'ble');
    });

    test('cache size', () {
      final cache = MemoryCache<int, String>(cacheSize: 1);
      cache.setValue(0, 'bla');
      cache.setValue(1, 'ble');
      expect(cache.containsKey(0), false);
      expect(cache.containsKey(1), true);
      expect(cache.getValue(0), null);
      expect(cache.getValue(1), 'ble');
      expect(cache.size, 1);
    });

    test('clear', () {
      final cache = MemoryCache<int, String>();
      cache.setValue(0, 'bla');
      expect(cache.containsKey(0), true);
      expect(cache.size, 1);
      cache.clear(0);
      expect(cache.containsKey(0), false);
      expect(cache.size, 0);
    });

    test('clearCache', () {
      final cache = MemoryCache<int, String>();
      cache.setValue(0, 'bla');
      cache.setValue(1, 'ble');
      expect(cache.containsKey(0), true);
      expect(cache.containsKey(1), true);
      expect(cache.size, 2);
      cache.clearCache();
      expect(cache.containsKey(0), false);
      expect(cache.containsKey(1), false);
      expect(cache.size, 0);
    });

    group('least recently used eviction', () {
      test('reading an entry protects it from eviction', () {
        final evicted = <String>[];
        final cache = MemoryCache<String, int>(
          cacheSize: 2,
          onEvict: (key, _) => evicted.add(key),
        );
        cache.setValue('hot', 1);
        cache.setValue('cold', 2);
        for (var i = 0; i < 100; i++) {
          expect(cache.getValue('hot'), 1);
        }
        cache.setValue('new', 3);

        expect(evicted, ['cold']);
        expect(cache.containsKey('hot'), isTrue);
        expect(cache.keys, ['hot', 'new']);
      });

      test('writing an existing key counts as a use', () {
        final cache = MemoryCache<String, int>(cacheSize: 2);
        cache.setValue('a', 1);
        cache.setValue('b', 2);
        cache.setValue('a', 10);
        cache.setValue('c', 3);
        expect(cache.keys, ['a', 'c']);
        expect(cache.getValue('a'), 10);
      });

      test('containsKey and a missed read do not count as a use', () {
        final cache = MemoryCache<String, int>(cacheSize: 2);
        cache.setValue('a', 1);
        cache.setValue('b', 2);
        expect(cache.containsKey('a'), isTrue);
        expect(cache.getValue('missing'), isNull);
        cache.setValue('c', 3);
        expect(cache.keys, ['b', 'c']);
      });

      test('entries without reads leave in insertion order', () {
        final evicted = <int>[];
        final cache = MemoryCache<int, int>(
          cacheSize: 3,
          onEvict: (key, _) => evicted.add(key),
        );
        for (var i = 0; i < 6; i++) {
          cache.setValue(i, i);
        }
        expect(evicted, [0, 1, 2]);
        expect(cache.keys, [3, 4, 5]);
      });

      test('the cache can be read while iterating over its keys', () {
        final cache = MemoryCache<int, String>(cacheSize: 3);
        cache.setValue(0, 'a');
        cache.setValue(1, 'b');
        cache.setValue(2, 'c');
        final values = [for (final key in cache.keys) cache.getValue(key)];
        expect(values, ['a', 'b', 'c']);
      });

      test('null values are cached like any other', () {
        final cache = MemoryCache<String, int?>(cacheSize: 2);
        cache.setValue('none', null);
        cache.setValue('b', 2);
        expect(cache.getValue('none'), isNull);
        cache.setValue('c', 3);
        expect(cache.containsKey('none'), isTrue);
        expect(cache.containsKey('b'), isFalse);
      });
    });

    group('onEvict', () {
      test('is called for eviction, replacement, clear and clearCache', () {
        final evicted = <(String, int)>[];
        final cache = MemoryCache<String, int>(
          cacheSize: 2,
          onEvict: (key, value) => evicted.add((key, value)),
        );
        cache.setValue('a', 1);
        cache.setValue('b', 2);
        expect(evicted, isEmpty);

        cache.setValue('c', 3);
        expect(evicted, [('a', 1)]);

        cache.setValue('b', 20);
        expect(evicted, [('a', 1), ('b', 2)]);

        // Setting the identical instance again is not a replacement.
        cache.setValue('b', 20);
        expect(evicted.length, 2);

        cache.clear('c');
        expect(evicted.last, ('c', 3));
        cache.clear('c');
        expect(evicted.length, 3);

        cache.clearCache();
        expect(evicted.last, ('b', 20));
        expect(cache.size, 0);
      });

      test('a cacheSize of 0 keeps nothing', () {
        final evicted = <int>[];
        final cache = MemoryCache<int, int>(
          cacheSize: 0,
          onEvict: (key, _) => evicted.add(key),
        );
        cache.setValue(1, 1);
        expect(cache.size, 0);
        expect(cache.getValue(1), isNull);
        expect(evicted, [1]);
      });
    });
  });
}
