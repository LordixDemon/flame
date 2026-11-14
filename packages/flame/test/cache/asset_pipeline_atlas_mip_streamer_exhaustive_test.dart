import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/cache.dart';
import 'package:flame/game.dart';
import 'package:flutter_test/flutter_test.dart';

ui.Image _solidImageSync(int w, int h, ui.Color color) {
  final rec = ui.PictureRecorder();
  ui.Canvas(rec).drawRect(
    ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    ui.Paint()
      ..color = color
      ..blendMode = ui.BlendMode.src
      ..isAntiAlias = false,
  );
  final pic = rec.endRecording();
  try {
    return pic.toImageSync(w, h);
  } finally {
    pic.dispose();
  }
}

void main() {
  group('AssetScope ref-counted multi-scene lifecycle', () {
    test(
      'shared textures survive until last scope disposes; handles empty/owned',
      () async {
        final images = Images();
        final emptyScope = AssetScope(name: 'empty', images: images);
        await emptyScope.preload();
        expect(emptyScope.progress, 1.0);
        expect(emptyScope.isLoaded, isTrue);
        expect(emptyScope.dispose(), 0);
        // Disposing twice is a safe no-op; preload after dispose throws.
        expect(emptyScope.dispose(), 0);
        expect(emptyScope.preload, throwsStateError);

        var customDisposed = 0;
        final scopeLevel1 = AssetScope(
          name: 'level_1',
          images: images,
          entries: <ScopedAssetEntry>[
            ScopedAssetEntry(
              path: 'shared_hud.png',
              priority: 10,
              generator: () async =>
                  _solidImageSync(8, 8, const ui.Color(0xFFFF0000)),
            ),
            ScopedAssetEntry(
              path: 'forest_bg.png',
              priority: 1,
              generator: () async =>
                  _solidImageSync(16, 16, const ui.Color(0xFF00FF00)),
            ),
          ],
        )..ownDisposable(() => customDisposed++);

        final scopeLevel2 =
            AssetScope(
                name: 'level_2',
                images: images,
              )
              ..addAsset(
                'shared_hud.png',
                priority: 10,
                generator: () async =>
                    _solidImageSync(8, 8, const ui.Color(0xFFFF0000)),
              )
              ..addAsset(
                'castle_bg.png',
                generator: () async =>
                    _solidImageSync(16, 16, const ui.Color(0xFF0000FF)),
              );

        final progressSteps = <double>[];
        scopeLevel1.progressListenable.addListener(
          () => progressSteps.add(scopeLevel1.progress),
        );

        await scopeLevel1.preload(concurrency: 1);
        await scopeLevel2.preload(concurrency: 2);
        expect(progressSteps.last, 1.0);
        expect(
          identical(
            scopeLevel1.getImage('shared_hud.png'),
            scopeLevel2.getImage('shared_hud.png'),
          ),
          isTrue,
        );

        // Disposing level_1 evicts forest_bg.png (16*16*4 = 1024 B) while
        // keeping shared_hud.png alive for level_2!
        final freed1 = scopeLevel1.dispose();
        expect(customDisposed, 1);
        expect(freed1, 16 * 16 * 4);
        expect(images.containsKey('forest_bg.png'), isFalse);
        expect(images.containsKey('shared_hud.png'), isTrue);

        // Registering ownDisposable on a disposed scope runs immediately.
        scopeLevel1.ownDisposable(() => customDisposed++);
        expect(customDisposed, 2);

        // Disposing level_2 frees shared_hud (8*8*4) + castle_bg (16*16*4).
        final freed2 = scopeLevel2.dispose();
        expect(freed2, 8 * 8 * 4 + 16 * 16 * 4);
        expect(images.containsKey('shared_hud.png'), isFalse);
        expect(images.containsKey('castle_bg.png'), isFalse);
      },
    );
  });

  group('MaxRectsBinPacker & DynamicSpriteAtlas border extrusion', () {
    test(
      'packs 36 heterogeneous rects with zero overlap & handles overflow',
      () {
        final packer = MaxRectsBinPacker(binWidth: 128, binHeight: 128);
        expect(packer.insert(0, 10), isNull);
        expect(packer.insert(10, -2), isNull);
        expect(packer.insert(200, 16), isNull);

        final placed = <ui.Rect>[];
        for (var i = 0; i < 36; i++) {
          final w = 10 + (i % 5) * 4;
          final h = 8 + ((i * 3) % 6) * 3;
          final node = packer.insert(w, h);
          expect(node, isNotNull);
          final rect = node!.toRect();
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.top, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(128));
          expect(rect.bottom, lessThanOrEqualTo(128));
          for (final prev in placed) {
            final overlap = rect.intersect(prev);
            expect(overlap.width <= 0 || overlap.height <= 0, isTrue);
          }
          placed.add(rect);
        }
        expect(packer.occupancy, inExclusiveRange(0.0, 1.0));
      },
    );

    test(
      'DynamicSpriteAtlas replicates extruded border texels into GPU gutter',
      () async {
        expect(
          () => DynamicSpriteAtlas.builder().buildSync(),
          throwsStateError,
        );

        final redTile = _solidImageSync(6, 6, const ui.Color(0xFFDC143C));
        DynamicSpriteAtlas? atlas;
        try {
          final builder =
              DynamicSpriteAtlas.builder(
                  maxAtlasDimension: 128,
                )
                ..addImage('crimson', redTile)
                ..addProcedural(
                  'badge',
                  width: 12,
                  height: 12,
                  painter: (canvas, size) {
                    canvas.drawCircle(
                      ui.Offset(size.width * 0.5, size.height * 0.5),
                      5,
                      ui.Paint()..color = const ui.Color(0xFF1E88E5),
                    );
                  },
                );
          atlas = builder.buildSync();
          expect(atlas.keys, containsAll(<String>['crimson', 'badge']));
          expect(() => atlas!.spriteOf('missing'), throwsArgumentError);

          final region = atlas.regionOf('crimson')!;
          expect(region.width, 6);
          expect(region.height, 6);

          // Read raw RGBA pixels from GPU texture to prove 2px border extrusion
          // surrounds `region` on all 4 sides & corners!
          final rgba = await atlas.atlasImage.toByteData();
          expect(rgba, isNotNull);
          final stride = atlas.atlasImage.width * 4;

          (int, int, int, int) pixelAt(int px, int py) {
            final off = py * stride + px * 4;
            return (
              rgba!.getUint8(off),
              rgba.getUint8(off + 1),
              rgba.getUint8(off + 2),
              rgba.getUint8(off + 3),
            );
          }

          final rx = region.left.toInt();
          final ry = region.top.toInt();
          // Center pixel + 1px & 2px extruded top-left / bottom-right gutters!
          for (final (gx, gy) in <(int, int)>[
            (rx + 2, ry + 2),
            (rx - 1, ry),
            (rx - 2, ry - 2),
            (rx + 6, ry + 3),
            (rx + 7, ry + 7),
          ]) {
            final (r, g, b, a) = pixelAt(gx, gy);
            expect(r, closeTo(0xDC, 2));
            expect(g, closeTo(0x14, 2));
            expect(b, closeTo(0x3C, 2));
            expect(a, 0xFF);
          }
        } finally {
          redTile.dispose();
          atlas?.dispose();
          atlas?.dispose(); // idempotent
        }
      },
    );
  });

  group('MipChainImage, ResolutionVariantResolver & AsyncAssetStreamer', () {
    test(
      'MipChainImage handles NPOT sizes, mipBias & base-image ownership',
      () {
        final base = _solidImageSync(100, 60, const ui.Color(0xFF4CAF50));
        final chain = MipChainImage.generateSync(base);
        // 100x60 -> 50x30 -> 25x15 (15 < 16 default minDimension stops!): 2!
        expect(chain.levelCount, 2);
        expect(chain.imageAtLevel(0).width, 100);
        expect(chain.imageAtLevel(1).width, 50);
        expect(chain.scaleAtLevel(0), 1.0);
        expect(chain.scaleAtLevel(1), 0.5);
        expect(chain.selectLevelForScale(1.5), 0);
        expect(chain.selectLevelForScale(0.45), 1);
        expect(chain.selectLevelForScale(0.8, mipBias: 0.8), 1);

        chain.dispose();
        expect(chain.isDisposed, isTrue);
        // Base image is still valid because ownsBaseImage defaulted to false!
        expect(base.width, 100);
        base.dispose();
      },
    );

    test(
      'ResolutionVariantResolver maps quality tiers and DPRs accurately',
      () {
        const resolver = ResolutionVariantResolver(
          availableScales: <double>[0.5, 1.0, 2.0, 3.0],
        );
        expect(
          resolver.resolveAssetPath(
            'ui/frame.png',
            tier: GraphicsQualityTier.low,
            devicePixelRatio: 3.0,
          ),
          'ui/frame.png',
        );
        expect(
          resolver.resolveAssetPath(
            'ui/frame.png',
            tier: GraphicsQualityTier.ultra,
            devicePixelRatio: 3.0,
          ),
          'ui/3.0x/frame.png',
        );
        expect(
          resolver.resolveAssetPath(
            'logo.png',
            tier: GraphicsQualityTier.medium,
            devicePixelRatio: 2.0,
          ),
          '2.0x/logo.png',
        );
        expect(
          resolver.resolveAssetPath(
            'tiles/grass.png',
            tier: GraphicsQualityTier.low,
            devicePixelRatio: 0.5,
          ),
          'tiles/0.5x/grass.png',
        );
      },
    );

    test(
      'AsyncAssetStreamer runs isolate parse, priority commit & cancellation',
      () async {
        final scheduler = FrameBudgetScheduler();
        final streamer = AsyncAssetStreamer(scheduler: scheduler);

        final bigPayload = jsonEncode(<String, Object?>{
          'items': List<int>.generate(600, (i) => i),
        });
        final commitOrder = <String>[];

        final lowFut = streamer.parseJsonInBackground<int>(
          bigPayload,
          (decoded) {
            commitOrder.add('low');
            return ((decoded! as Map<String, Object?>)['items']! as List)
                .length;
          },
          isolateThresholdChars: 128,
          priority: 1,
        );
        final highFut = streamer.parseJsonInBackground<int>(
          '{"items":[1,2,3]}',
          (decoded) {
            commitOrder.add('high');
            return ((decoded! as Map<String, Object?>)['items']! as List)
                .length;
          },
          priority: 50,
        );

        final cancelTok = StreamCancellationToken()..cancel();
        await expectLater(
          streamer.transformBytesInBackground<int, int>(
            Uint8List.fromList(<int>[1, 2, 3, 4]),
            (b) => b.length,
            (n) => n,
            cancelToken: cancelTok,
          ),
          throwsA(isA<AssetStreamCancelledException>()),
        );

        // Give background isolate decode a moment to enqueue into scheduler.
        await Future<void>.delayed(const Duration(milliseconds: 50));
        while (scheduler.hasPendingTasks) {
          scheduler.drainWithinBudget(
            elapsedUpdateMicros: 0,
            frameBudgetMicros: 16000,
          );
        }

        expect(await highFut, 3);
        expect(await lowFut, 600);
        expect(streamer.completedStreams, 2);
        expect(commitOrder, containsAll(<String>['high', 'low']));
      },
    );
  });
}
