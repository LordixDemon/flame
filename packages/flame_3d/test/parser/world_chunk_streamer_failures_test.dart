import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/parser.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WorldChunkStreamer3D', () {
    test('a failing loader is reported once per chunk, then retried after '
        'the delay', () async {
      var calls = 0;
      final failures = <ChunkCoord3D>[];
      final streamer = WorldChunkStreamer3D(
        chunkSize: 10,
        loadRadius: 12,
        failedLoadRetryDelay: 2,
        onChunkLoadFailed: (coord, error, _) {
          expect(error, isA<StateError>());
          failures.add(coord);
        },
        chunkLoader: (coord) async {
          calls++;
          throw StateError('missing chunk file');
        },
      )..updateFocus(Vector3(5, 0, 5));
      await streamer.flushPending();
      // The focus cell and its four neighbors.
      expect(calls, 5);
      for (var i = 0; i < 5; i++) {
        streamer.update(0.1);
        await streamer.flushPending();
      }
      expect(calls, 5);
      expect(failures, hasLength(5));
      expect(streamer.failedLoadCount, 5);
      expect(streamer.failedChunks, hasLength(5));
      expect(streamer.loadingChunks, isEmpty);

      streamer.update(2);
      await streamer.flushPending();
      expect(calls, 10);

      streamer
        ..retryFailedChunks()
        ..refreshStreaming();
      await streamer.flushPending();
      expect(calls, 15);
    });

    test(
      'without a callback, failures go to FlutterError.reportError',
      () async {
        final reported = <FlutterErrorDetails>[];
        final previous = FlutterError.onError;
        FlutterError.onError = reported.add;
        addTearDown(() => FlutterError.onError = previous);
        final streamer = WorldChunkStreamer3D(
          chunkSize: 10,
          loadRadius: 4,
          chunkLoader: (_) => Future.error(const FormatException('corrupt')),
        )..updateFocus(Vector3(5, 0, 5));
        await streamer.flushPending();
        expect(reported, hasLength(1));
        expect(reported.single.exception, isA<FormatException>());
      },
    );

    test('removing the streamer evicts its active and cached chunks', () async {
      final evicted = <ChunkCoord3D>{};
      final unmounted = <ChunkCoord3D>{};
      final streamer = WorldChunkStreamer3D(
        chunkSize: 10,
        loadRadius: 4,
        unloadRadius: 6,
        onChunkEvicted: (coord, _) => evicted.add(coord),
        onChunkUnmounted: (coord, _) => unmounted.add(coord),
        chunkLoader: (coord) async => [Group3D()],
      )..updateFocus(Vector3(5, 0, 5));
      await streamer.flushPending();
      // Move away: chunk (0, 0) goes to the cache, chunk (10, 10) is active.
      streamer.updateFocus(Vector3(105, 0, 105));
      await streamer.flushPending();
      expect(streamer.activeChunks, {const ChunkCoord3D(10, 10)});
      expect(streamer.cachedChunkCount, 1);
      expect(evicted, isEmpty);

      streamer.onRemove();
      expect(unmounted, {const ChunkCoord3D(0, 0), const ChunkCoord3D(10, 10)});
      expect(evicted, {const ChunkCoord3D(0, 0), const ChunkCoord3D(10, 10)});
      expect(streamer.cachedChunkCount, 0);
    });
  });
}
