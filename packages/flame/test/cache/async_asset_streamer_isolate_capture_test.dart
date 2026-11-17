import 'dart:isolate';
import 'dart:typed_data';

import 'package:flame/cache.dart';
import 'package:flutter_test/flutter_test.dart';

int _sum(Uint8List bytes) => bytes.fold<int>(0, (a, b) => a + b);

void main() {
  group('AsyncAssetStreamer keeps main-thread callbacks out of the worker', () {
    // Stands in for anything that only lives on the calling isolate and can
    // not be sent to another one (a GPU image, a game instance, a port).
    late RawReceivePort mainThreadOnly;

    setUp(() => mainThreadOnly = RawReceivePort());
    tearDown(() => mainThreadOnly.close());

    test('transformBytesInBackground: the finalizer can use main-thread '
        'state', () async {
      final streamer = AsyncAssetStreamer();
      final bytes = Uint8List.fromList([1, 2, 3]);

      final result = await streamer.transformBytesInBackground<int, String>(
        bytes,
        _sum,
        (sum) => 'sum=$sum port=${mainThreadOnly.sendPort.hashCode != 0}',
      );

      expect(result, 'sum=6 port=true');
      expect(streamer.completedStreams, 1);
      // The caller's buffer is copied, not taken away.
      expect(bytes, [1, 2, 3]);
    });

    test(
      'parseJsonInBackground: the mapper can use main-thread state',
      () async {
        final streamer = AsyncAssetStreamer();

        final result = await streamer.parseJsonInBackground<int>(
          '{"a": [1, 2, 3]}',
          (decoded) {
            mainThreadOnly.sendPort;
            return ((decoded! as Map)['a'] as List).length;
          },
          // Forces the worker isolate also for this short text.
          isolateThresholdChars: 1,
        );

        expect(result, 3);
      },
    );

    test('a cancelled token still aborts before the finalizer runs', () async {
      final streamer = AsyncAssetStreamer();
      final token = StreamCancellationToken();
      var finalized = false;

      final pending = streamer.transformBytesInBackground<int, int>(
        Uint8List.fromList([4, 5]),
        _sum,
        (sum) {
          finalized = true;
          return sum;
        },
        cancelToken: token,
      );
      token.cancel();

      await expectLater(
        pending,
        throwsA(isA<AssetStreamCancelledException>()),
      );
      expect(finalized, isFalse);
      expect(streamer.completedStreams, 0);
    });
  });
}
