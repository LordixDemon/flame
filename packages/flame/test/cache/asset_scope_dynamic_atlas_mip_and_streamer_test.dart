import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/cache.dart';
import 'package:flame/game.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

ui.Image _makeTestImageSync(int width, int height, Color color) {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = color,
  );
  final pic = recorder.endRecording();
  try {
    return pic.toImageSync(width, height);
  } finally {
    pic.dispose();
  }
}

void main() {
  group('AssetScope, DynamicSpriteAtlas, MipChainImage & AsyncStreamer', () {
    test(
      'AssetScope tracks progress and preserves shared textures until last '
      'retaining scope disposes',
      () async {
        final images = Images();
        final loadOrder = <String>[];

        Future<ui.Image> gen(String tag, int size, Color c) async {
          loadOrder.add(tag);
          return _makeTestImageSync(size, size, c);
        }

        final scopeA = AssetScope(
          name: 'level_a',
          images: images,
          entries: <ScopedAssetEntry>[
            ScopedAssetEntry(
              path: 'low_prio.png',
              key: 'exclusive_a',
              priority: 1,
              generator: () => gen('exclusive_a', 16, const Color(0xFFFF0000)),
            ),
            ScopedAssetEntry(
              path: 'shared_hud.png',
              key: 'shared_hud',
              priority: 10,
              generator: () => gen('shared_hud', 16, const Color(0xFF00FF00)),
            ),
          ],
        );

        await scopeA.preload(concurrency: 1);
        expect(scopeA.isLoaded, isTrue);
        expect(scopeA.progress, 1.0);
        // Priority 10 loads before priority 1!
        expect(loadOrder, <String>['shared_hud', 'exclusive_a']);

        final scopeB = AssetScope(
          name: 'level_b',
          images: images,
          entries: <ScopedAssetEntry>[
            ScopedAssetEntry(
              path: 'shared_hud.png',
              key: 'shared_hud',
              generator: () => gen('shared_hud_b', 16, const Color(0xFF00FF00)),
            ),
          ],
        );
        await scopeB.preload(concurrency: 1);

        // Disposing Scope A frees 'exclusive_a' immediately while 'shared_hud'
        // stays alive for Scope B!
        final freedA = scopeA.dispose();
        expect(freedA, greaterThan(0));
        expect(images.containsKey('exclusive_a'), isFalse);
        expect(images.containsKey('shared_hud'), isTrue);

        // Disposing Scope B releases the last retain on 'shared_hud' -> freed!
        final freedB = scopeB.dispose();
        expect(freedB, greaterThan(0));
        expect(images.containsKey('shared_hud'), isFalse);
      },
    );

    test(
      'MaxRectsBinPacker & DynamicSpriteAtlas pack images and procedural '
      'icons with border extrusion',
      () {
        final srcA = _makeTestImageSync(24, 24, const Color(0xFFE91E63));
        final srcB = _makeTestImageSync(32, 16, const Color(0xFF2196F3));
        try {
          final builder = DynamicSpriteAtlas.builder()
            ..addImage('gem', srcA)
            ..addImage('shield', srcB)
            ..addProcedural(
              'coin',
              width: 20,
              height: 20,
              painter: (canvas, size) {
                canvas.drawCircle(
                  Offset(size.width * 0.5, size.height * 0.5),
                  8,
                  Paint()..color = const Color(0xFFFFCA28),
                );
              },
            );

          final atlas = builder.buildSync();
          try {
            expect(atlas.keys.toSet(), <String>{'gem', 'shield', 'coin'});
            final gemRect = atlas.regionOf('gem')!;
            final shieldRect = atlas.regionOf('shield')!;
            // Extruded padding guarantees non-overlapping regions separated by
            // at least 4px (2px + 2px)!
            expect(gemRect.inflate(1.9).overlaps(shieldRect), isFalse);
            expect(atlas.spriteOf('coin').srcSize, Vector2(20, 20));
          } finally {
            atlas.dispose();
          }
          expect(atlas.isDisposed, isTrue);
        } finally {
          srcA.dispose();
          srcB.dispose();
        }
      },
    );

    test(
      'MipChainImage selects crisp downsampled LOD levels & '
      'ResolutionVariantResolver maps quality tiers',
      () {
        final base = _makeTestImageSync(128, 128, const Color(0xFF8BC34A));
        final mip = MipChainImage.generateSync(
          base,
          ownsBaseImage: true,
        );
        try {
          expect(mip.levelCount, 4);
          expect(mip.imageAtLevel(0).width, 128);
          expect(mip.imageAtLevel(1).width, 64);
          expect(mip.imageAtLevel(2).width, 32);
          expect(mip.imageAtLevel(3).width, 16);

          expect(mip.selectLevelForScale(1.0), 0);
          expect(mip.selectLevelForScale(0.5), 1);
          expect(mip.selectLevelForScale(0.25), 2);
          expect(mip.selectLevelForScale(0.1), 3);
        } finally {
          mip.dispose();
        }
        expect(mip.isDisposed, isTrue);

        const resolver = ResolutionVariantResolver();
        expect(
          resolver.resolveAssetPath(
            'tiles/board.png',
            tier: GraphicsQualityTier.low,
            devicePixelRatio: 3.0,
          ),
          'tiles/board.png',
        );
        expect(
          resolver.resolveAssetPath(
            'tiles/board.png',
            tier: GraphicsQualityTier.ultra,
            devicePixelRatio: 3.0,
          ),
          'tiles/3.0x/board.png',
        );
      },
    );

    test(
      'AsyncAssetStreamer parses large JSON on background isolate and honors '
      'FrameBudgetScheduler + StreamCancellationToken',
      () async {
        final scheduler = FrameBudgetScheduler();
        final streamer = AsyncAssetStreamer(scheduler: scheduler);

        final bigJson = jsonEncode(<String, Object?>{
          'items': List<int>.generate(600, (i) => i),
        });

        final future = streamer.parseJsonInBackground<int>(
          bigJson,
          (decoded) {
            final map = decoded! as Map<String, Object?>;
            return (map['items']! as List<Object?>).length;
          },
          isolateThresholdChars: 64,
        );

        // Pump scheduler once worker isolate finishes decoding.
        for (var i = 0; i < 40 && scheduler.pendingTaskCount == 0; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        scheduler.drainWithinBudget(
          elapsedUpdateMicros: 0,
          frameBudgetMicros: 16667,
        );
        expect(await future, 600);
        expect(streamer.completedStreams, 1);

        final byteFuture = streamer.transformBytesInBackground<int, int>(
          Uint8List.fromList(const <int>[1, 2, 3, 4]),
          (bytes) => bytes.fold<int>(0, (a, b) => a + b),
          (sum) => sum * 2,
        );
        for (var i = 0; i < 40 && scheduler.pendingTaskCount == 0; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        scheduler.flushAllSync();
        expect(await byteFuture, 20);
        expect(streamer.completedStreams, 2);

        final cancelledToken = StreamCancellationToken()..cancel();
        await expectLater(
          () => streamer.parseJsonInBackground<int>(
            '{"x":1}',
            (_) => 1,
            cancelToken: cancelledToken,
          ),
          throwsA(isA<AssetStreamCancelledException>()),
        );
      },
    );
  });
}
