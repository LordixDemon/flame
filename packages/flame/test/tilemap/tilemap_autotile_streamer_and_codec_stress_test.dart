import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flame/math.dart';
import 'package:flame/tilemap.dart';
import 'package:flutter_test/flutter_test.dart';

ui.Image _buildLargeTilesetImage() {
  final rec = ui.PictureRecorder();
  final canvas = ui.Canvas(rec, const ui.Rect.fromLTWH(0, 0, 256, 256));
  for (var y = 0; y < 256; y += 16) {
    for (var x = 0; x < 256; x += 16) {
      canvas.drawRect(
        ui.Rect.fromLTWH(x.toDouble(), y.toDouble(), 16, 16),
        ui.Paint()
          ..color = ui.Color.fromARGB(
            255,
            (x * 7 + 31) & 0xFF,
            (y * 11 + 53) & 0xFF,
            ((x ^ y) * 3 + 97) & 0xFF,
          ),
      );
    }
  }
  final pic = rec.endRecording();
  final img = pic.toImageSync(256, 256);
  pic.dispose();
  return img;
}

class const _LootRefRow(this.id, this.itemId, this.bonusSkillId) {
  final String id;
  final String? itemId;
  final String? bonusSkillId;
}

class const _CatalogRow(this.id) {
  final String id;
}

void main() {
  group('Tilemap 65k-cell stress, seam invalidation & A1 zero-rebuild', () {
    test(
      '256x256 (65,536-cell) ChunkedTilemapComponent frustum culls chunks, '
      'handles 1,000 seam mutations, and cycles 120 A1 frames with 0 rebuilds',
      () async {
        final img = _buildLargeTilesetImage();
        addTearDown(img.dispose);

        final atlas = TilesetAtlas(
          image: img,
          tilePxWidth: 16,
          tilePxHeight: 16,
          autotiles: const <int, AutotileDefinition>{
            100: AutotileDefinition(
              tileId: 100,
              kind: AutotileKind.animatedBlobA1,
              blockOriginPxX: 0,
              blockOriginPxY: 32,
              frameCount: 3,
              frameStridePxX: 32,
            ),
            101: AutotileDefinition(
              tileId: 101,
              kind: AutotileKind.groundBlobA2,
              blockOriginPxX: 96,
              blockOriginPxY: 32,
            ),
            102: AutotileDefinition(
              tileId: 102,
              kind: AutotileKind.facadeRectA3,
              blockOriginPxX: 128,
              blockOriginPxY: 32,
            ),
          },
        );
        addTearDown(atlas.disposeShader);

        final world = World();
        final camera = CameraComponent.withFixedResolution(
          width: 320,
          height: 240,
          world: world,
        );
        final game = FlameGame(world: world, camera: camera)
          ..onGameResize(Vector2(320, 240));
        await game.start();
        addTearDown(game.onRemove);

        final rng = SeededRng(0xCAFE1234);
        final tilemap = ChunkedTilemapComponent(
          tileset: atlas,
          mapWidth: 256,
          mapHeight: 256,
          tileDestWidth: 16,
          tileDestHeight: 16,
        );

        // Populate all 65,536 cells with mixed autotiles and all 8 D4 flips!
        for (var r = 0; r < 256; r++) {
          for (var c = 0; c < 256; c++) {
            final roll = rng.nextInt(8);
            if (roll == 0) {
              tilemap.setTileId(c, r, 100);
            } else if (roll == 1) {
              tilemap.setTileId(c, r, 101);
            } else if (roll == 2) {
              tilemap.setTileId(c, r, 102);
            } else {
              tilemap.setTileGid(
                c,
                r,
                TileGid.pack(
                  1 + rng.nextInt(12),
                  flipH: rng.nextBool(),
                  flipV: rng.nextBool(),
                  quarterTurns: rng.nextInt(4),
                ),
              );
            }
          }
        }

        world.add(tilemap);
        await game.ready();

        void renderFrame() {
          final rec = ui.PictureRecorder();
          game.render(ui.Canvas(rec, const ui.Rect.fromLTWH(0, 0, 320, 240)));
          game.onFrameRendered();
          rec.endRecording().dispose();
        }

        // Sweep camera diagonally across the 4096x4096 pixel world:
        // Total chunks = 16x16 = 256, while 320x240 viewport only sees <= 9!
        for (var step = 0; step < 20; step++) {
          camera.viewfinder.position = Vector2(
            200.0 + step * 180.0,
            160.0 + step * 180.0,
          );
          game.update(0.016);
          renderFrame();
          expect(tilemap.lastRenderedChunkCount, inInclusiveRange(1, 12));
        }

        // Park camera and advance 120 frames of A1 water animation:
        // Once visible chunks are clean, 120 frames MUST incur 0 rebuilds!
        renderFrame();
        var totalAnimRebuilds = 0;
        for (var f = 0; f < 120; f++) {
          game.update(0.05);
          renderFrame();
          totalAnimRebuilds += tilemap.lastChunkRebuildCount;
        }
        expect(totalAnimRebuilds, 0);

        // Hammer 1,000 random mutations along chunk seam lines (15, 16, 31, 32)
        // while panning across the world.
        const seamCoords = <int>[0, 15, 16, 31, 32, 63, 64, 127, 128, 255];
        for (var i = 0; i < 1000; i++) {
          final c = seamCoords[rng.nextInt(seamCoords.length)];
          final r = seamCoords[rng.nextInt(seamCoords.length)];
          tilemap.setTileId(c, r, 100 + rng.nextInt(3));
          if (i % 50 == 0) {
            camera.viewfinder.position = Vector2(c * 16.0, r * 16.0);
            game.update(0.016);
            renderFrame();
            expect(tilemap.lastChunkRebuildCount, lessThanOrEqualTo(12));
          }
        }
      },
    );

    test(
      'exhaustively validates all 256 8-neighbor bitmasks across A2 and A3 '
      'with valid sub-quad indices inside block bounds',
      () {
        final uniqueA2 = <(int, int, int, int, int, int, int, int)>{};
        for (var raw8 = 0; raw8 < 256; raw8++) {
          final quad = AutotileComposer.composeForCell(
            kind: AutotileKind.groundBlobA2,
            col: 1,
            row: 1,
            matchesNeighbor: (c, r) {
              final dc = c - 1;
              final dr = r - 1;
              if (dc == 0 && dr == -1) {
                return (raw8 & 1) != 0;
              }
              if (dc == 1 && dr == -1) {
                return (raw8 & 2) != 0;
              }
              if (dc == 1 && dr == 0) {
                return (raw8 & 4) != 0;
              }
              if (dc == 1 && dr == 1) {
                return (raw8 & 8) != 0;
              }
              if (dc == 0 && dr == 1) {
                return (raw8 & 16) != 0;
              }
              if (dc == -1 && dr == 1) {
                return (raw8 & 32) != 0;
              }
              if (dc == -1 && dr == 0) {
                return (raw8 & 64) != 0;
              }
              if (dc == -1 && dr == -1) {
                return (raw8 & 128) != 0;
              }
              return true;
            },
          );

          for (final qx in <int>[
            quad.tlQx,
            quad.trQx,
            quad.blQx,
            quad.brQx,
          ]) {
            expect(qx, inInclusiveRange(0, 3));
          }
          for (final qy in <int>[
            quad.tlQy,
            quad.trQy,
            quad.blQy,
            quad.brQy,
          ]) {
            expect(qy, inInclusiveRange(0, 5));
          }
          uniqueA2.add((
            quad.tlQx,
            quad.tlQy,
            quad.trQx,
            quad.trQy,
            quad.blQx,
            quad.blQy,
            quad.brQx,
            quad.brQy,
          ));
        }
        // Canonical 8-neighbor corner-gated blob autotile yields 47 states!
        expect(uniqueA2.length, 47);

        for (var mask4 = 0; mask4 < 16; mask4++) {
          final q3 = AutotileComposer.composeRectA3FromMask(mask4);
          expect(q3.tlQx, inInclusiveRange(0, 3));
          expect(q3.tlQy, inInclusiveRange(0, 3));
          expect(q3.brQx, inInclusiveRange(0, 3));
          expect(q3.brQy, inInclusiveRange(0, 3));
        }
      },
    );
  });

  group('ConnectedWorldStreamer LRU thrash, DTMP fuzz & 5k-row DB FK', () {
    test(
      'survives 300 rapid map transitions across a 20-map graph without '
      'evicting active map, and rejects truncated/corrupted DTMP binaries',
      () async {
        final resident = <String>{};
        final streamer = ConnectedWorldStreamer<String>(
          maxLoadedMaps: 4,
          preloadDistance: 32.0,
          loader: (id) async {
            resident.add(id);
            return 'DATA:$id';
          },
          onDisposeMap: (id, _) => resident.remove(id),
        );

        // Build 20-node ring + cross-links.
        for (var i = 0; i < 20; i++) {
          final from = 'zone_$i';
          final next = 'zone_${(i + 1) % 20}';
          final shortcut = 'zone_${(i + 7) % 20}';
          streamer
            ..registerPortal(
              WorldPortalLink(
                id: 'p_next_$i',
                fromMapId: from,
                triggerRect: const ui.Rect.fromLTWH(100, 0, 16, 16),
                toMapId: next,
                targetSpawnPosition: Vector2(8, 8),
              ),
            )
            ..registerPortal(
              WorldPortalLink(
                id: 'p_jump_$i',
                fromMapId: from,
                triggerRect: const ui.Rect.fromLTWH(0, 100, 16, 16),
                toMapId: shortcut,
                targetSpawnPosition: Vector2(8, 8),
              ),
            );
        }

        final rng = SeededRng(9911);
        for (var step = 0; step < 300; step++) {
          final target = 'zone_${rng.nextInt(20)}';
          await streamer.enterMap(target);
          expect(streamer.activeMapId, target);
          expect(streamer.isLoaded(target), isTrue);
          expect(resident, contains(target));
          expect(resident.length, lessThanOrEqualTo(4));
        }

        // Binary DTMP truncation & payload corruption fuzzing!
        final validDoc = TileMapDocument(
          mapId: 'crypt_b4',
          width: 8,
          height: 8,
          tileWidth: 16,
          tileHeight: 16,
          layers: <TileMapLayerData>[
            TileMapLayerData(
              name: 'floor',
              cells: Uint32List.fromList(
                List<int>.generate(64, (i) => TileGid.pack(i + 1).raw),
              ),
            ),
            TileMapLayerData(
              name: 'walls',
              cells: Uint32List(64),
            ),
          ],
          spawns: const <TileMapEntitySpawn>[
            TileMapEntitySpawn(
              id: 'boss_altar',
              prefabId: 'altar',
              x: 64,
              y: 64,
              params: <String, Object?>{'tier': 5, 'cursed': true},
            ),
          ],
        );

        final encoded = validDoc.encodeBinary();
        expect(TileMapDocument.fromBinary(encoded).mapId, 'crypt_b4');

        // Every prefix truncation shorter than valid length MUST throw
        // FormatException cleanly (never RangeError / EndOfData crash!).
        for (var cut = 0; cut < encoded.length; cut += 5) {
          final truncated = Uint8List.sublistView(encoded, 0, cut);
          expect(
            () => TileMapDocument.fromBinary(truncated),
            throwsFormatException,
            reason: 'Truncation to $cut bytes must throw FormatException',
          );
        }

        // Inflate header width/height (offsets 8 and 12) to huge values so
        // layer payload overflows buffer -> must throw FormatException cleanly!
        final forgedDims = Uint8List.fromList(encoded);
        ByteData.sublistView(forgedDims)
          ..setUint32(8, 4096, Endian.little)
          ..setUint32(12, 4096, Endian.little);
        expect(
          () => TileMapDocument.fromBinary(forgedDims),
          throwsFormatException,
        );

        // Zero width/height or NaN tileWidth in header -> FormatException!
        final zeroWidth = Uint8List.fromList(encoded);
        ByteData.sublistView(zeroWidth).setUint32(8, 0, Endian.little);
        expect(
          () => TileMapDocument.fromBinary(zeroWidth),
          throwsFormatException,
        );

        final nanTile = Uint8List.fromList(encoded);
        ByteData.sublistView(nanTile).setFloat32(16, double.nan, Endian.little);
        expect(
          () => TileMapDocument.fromBinary(nanTile),
          throwsFormatException,
        );

        // 5,000-row relational DB stress with multi-column foreign keys.
        final db = DataTableRegistry()
          ..registerTable<_CatalogRow>(
            'items',
            List<_CatalogRow>.generate(2000, (i) => _CatalogRow('itm_$i')),
            idOf: (r) => r.id,
          )
          ..registerTable<_CatalogRow>(
            'skills',
            List<_CatalogRow>.generate(1000, (i) => _CatalogRow('skl_$i')),
            idOf: (r) => r.id,
          )
          ..registerTable<_LootRefRow>(
            'drops',
            List<_LootRefRow>.generate(
              2000,
              (i) => _LootRefRow(
                'drp_$i',
                i == 777 ? 'itm_999999' : 'itm_${i % 2000}',
                i == 1555 ? 'skl_888888' : 'skl_${i % 1000}',
              ),
            ),
            idOf: (r) => r.id,
          )
          ..addForeignKeyRule<_LootRefRow>(
            ForeignKeyRule<_LootRefRow>(
              sourceTable: 'drops',
              targetTable: 'items',
              fieldName: 'itemId',
              extractTargetId: (r) => r.itemId,
            ),
          )
          ..addForeignKeyRule<_LootRefRow>(
            ForeignKeyRule<_LootRefRow>(
              sourceTable: 'drops',
              targetTable: 'skills',
              fieldName: 'bonusSkillId',
              extractTargetId: (r) => r.bonusSkillId,
            ),
          );

        final errors = db.validateForeignKeys();
        expect(errors.length, 2);
        expect(errors.any((e) => e.contains('itm_999999')), isTrue);
        expect(errors.any((e) => e.contains('skl_888888')), isTrue);
      },
    );
  });
}
