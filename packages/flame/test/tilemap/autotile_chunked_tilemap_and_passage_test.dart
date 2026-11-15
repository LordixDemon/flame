import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/components.dart';
import 'package:flame/grid.dart';
import 'package:flame/tilemap.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds a deterministic test atlas image where:
/// - Tile `1` `(0, 0, 16, 16)` has 4 distinct quadrant colors:
///   `TL = Red`, `TR = Green`, `BL = Blue`, `BR = Yellow` (tests all 8 D4
///   dihedral flip/rotation symmetries at pixel level!).
/// - `A1` animated water frames `0, 1, 2` sit at `y = 16`, `x = 0, 32, 64`
///   (`32x48` each) filled with pure Cyan, Magenta, and White respectively.
ui.Image _buildTestTilesetImage() {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder, const ui.Rect.fromLTWH(0, 0, 128, 128));

  // Tile 1 at (0, 0, 16, 16): 4 colored 8x8 quadrants
  canvas
    ..drawRect(
      const ui.Rect.fromLTWH(0, 0, 8, 8),
      ui.Paint()..color = const ui.Color(0xFFFF0000), // TL Red
    )
    ..drawRect(
      const ui.Rect.fromLTWH(8, 0, 8, 8),
      ui.Paint()..color = const ui.Color(0xFF00FF00), // TR Green
    )
    ..drawRect(
      const ui.Rect.fromLTWH(0, 8, 8, 8),
      ui.Paint()..color = const ui.Color(0xFF0000FF), // BL Blue
    )
    ..drawRect(
      const ui.Rect.fromLTWH(8, 8, 8, 8),
      ui.Paint()..color = const ui.Color(0xFFFFFF00), // BR Yellow
    )
    // A1 Frame 0 at (0, 16, 32, 48): Cyan
    ..drawRect(
      const ui.Rect.fromLTWH(0, 16, 32, 48),
      ui.Paint()..color = const ui.Color(0xFF00FFFF),
    )
    // A1 Frame 1 at (32, 16, 32, 48): Magenta
    ..drawRect(
      const ui.Rect.fromLTWH(32, 16, 32, 48),
      ui.Paint()..color = const ui.Color(0xFFFF00FF),
    )
    // A1 Frame 2 at (64, 16, 32, 48): White
    ..drawRect(
      const ui.Rect.fromLTWH(64, 16, 32, 48),
      ui.Paint()..color = const ui.Color(0xFFFFFFFF),
    );

  final picture = recorder.endRecording();
  final img = picture.toImageSync(128, 128);
  picture.dispose();
  return img;
}

Future<ByteData> _renderComponentRgba(
  Component component,
  int width,
  int height,
) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(
    recorder,
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
  );
  component.renderTree(canvas);
  final pic = recorder.endRecording();
  final img = pic.toImageSync(width, height);
  pic.dispose();
  final bytes = (await img.toByteData())!;
  img.dispose();
  return bytes;
}

ui.Color _pixelAt(ByteData rgba, int imgWidth, int x, int y) {
  final off = (y * imgWidth + x) * 4;
  return ui.Color.fromARGB(
    rgba.getUint8(off + 3),
    rgba.getUint8(off),
    rgba.getUint8(off + 1),
    rgba.getUint8(off + 2),
  );
}

class _ColorBoxComponent({
  required this.color,
  required super.position,
  required super.size,
}) extends PositionComponent {
  final ui.Color color;

  @override
  void render(ui.Canvas canvas) {
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, size.x, size.y),
      ui.Paint()..color = color,
    );
  }
}

class const _ItemRow(this.id, this.skillId) {
  final String id;
  final String? skillId;
}

class const _SkillRow(this.id) {
  final String id;
}

void main() {
  group('TileGid & AutotileComposer (A1/A2 47-state, A3/A4 16-state)', () {
    test('packs and unpacks 24-bit tileId and all D4 flip/rotation flags', () {
      expect(TileGid.empty.isEmpty, isTrue);
      expect(TileGid.empty.isNotEmpty, isFalse);

      for (final id in <int>[1, 42, 0x00ABCDEF, 0x00FFFFFF]) {
        for (final fh in <bool>[false, true]) {
          for (final fv in <bool>[false, true]) {
            for (var rot = 0; rot < 4; rot++) {
              final gid = TileGid.pack(
                id,
                flipH: fh,
                flipV: fv,
                quarterTurns: rot,
              );
              expect(gid.tileId, id);
              expect(gid.flipH, fh);
              expect(gid.flipV, fv);
              expect(gid.quarterTurns, rot);
              expect(gid.isNotEmpty, isTrue);

              final toggled = gid.copyWith(
                flipH: !fh,
                quarterTurns: (rot + 1) & 3,
              );
              expect(toggled.tileId, id);
              expect(toggled.flipH, !fh);
              expect(toggled.flipV, fv);
              expect(toggled.quarterTurns, (rot + 1) & 3);
            }
          }
        }
      }
    });

    test(
      'produces exactly 47 unique A2 blob quads and 16 unique A3/A4 quads',
      () {
        final uniqueA2 = <AutotileSubtileQuad>{};
        for (var raw8 = 0; raw8 < 256; raw8++) {
          final quad = AutotileComposer.composeForCell(
            kind: AutotileKind.groundBlobA2,
            col: 1,
            row: 1,
            matchesNeighbor: (c, r) {
              if (c == 1 && r == 0) {
                return (raw8 & AutoTileBitmask.north) != 0;
              }
              if (c == 2 && r == 0) {
                return (raw8 & AutoTileBitmask.northEast) != 0;
              }
              if (c == 2 && r == 1) {
                return (raw8 & AutoTileBitmask.east) != 0;
              }
              if (c == 2 && r == 2) {
                return (raw8 & AutoTileBitmask.southEast) != 0;
              }
              if (c == 1 && r == 2) {
                return (raw8 & AutoTileBitmask.south) != 0;
              }
              if (c == 0 && r == 2) {
                return (raw8 & AutoTileBitmask.southWest) != 0;
              }
              if (c == 0 && r == 1) {
                return (raw8 & AutoTileBitmask.west) != 0;
              }
              if (c == 0 && r == 0) {
                return (raw8 & AutoTileBitmask.northWest) != 0;
              }
              return true;
            },
          );
          uniqueA2.add(quad);
        }
        expect(uniqueA2.length, 47);

        final uniqueA3 = <AutotileSubtileQuad>{};
        for (var mask4 = 0; mask4 < 16; mask4++) {
          uniqueA3.add(AutotileComposer.composeRectA3FromMask(mask4));
        }
        expect(uniqueA3.length, 16);

        final uniqueWaterfall = <AutotileSubtileQuad>{
          AutotileComposer.composeWaterfall(
            westMatches: false,
            eastMatches: false,
          ),
          AutotileComposer.composeWaterfall(
            westMatches: true,
            eastMatches: false,
          ),
          AutotileComposer.composeWaterfall(
            westMatches: false,
            eastMatches: true,
          ),
          AutotileComposer.composeWaterfall(
            westMatches: true,
            eastMatches: true,
          ),
        };
        expect(uniqueWaterfall.length, 4);
      },
    );

    test('resolves 0-1-2-1 ping-pong and linear animation frames cleanly', () {
      const pingPong = AutotileDefinition(
        tileId: 10,
        kind: AutotileKind.animatedBlobA1,
        blockOriginPxX: 0,
        blockOriginPxY: 16,
        frameCount: 3,
        frameStridePxX: 32,
      );
      expect(pingPong.phaseCount, 4);
      expect(
        <int>[for (var s = 0; s < 8; s++) pingPong.resolveAtlasFrame(s)],
        <int>[0, 1, 2, 1, 0, 1, 2, 1],
      );

      const linear = AutotileDefinition(
        tileId: 11,
        kind: AutotileKind.waterfallA1,
        blockOriginPxX: 0,
        blockOriginPxY: 0,
        frameCount: 3,
        pingPongAnimation: false,
      );
      expect(linear.phaseCount, 3);
      expect(
        <int>[for (var s = 0; s < 6; s++) linear.resolveAtlasFrame(s)],
        <int>[0, 1, 2, 0, 1, 2],
      );
    });
  });

  group('ChunkedTilemapComponent rendering, D4 mirrors & rebuilds', () {
    test(
      'renders all 8 D4 rotations/flips (including mirrored Vertices.raw) '
      'with exact quadrant pixel colors',
      () async {
        final img = _buildTestTilesetImage();
        addTearDown(img.dispose);
        final atlas = TilesetAtlas(
          image: img,
          tilePxWidth: 16,
          tilePxHeight: 16,
        );
        addTearDown(atlas.disposeShader);

        final map = ChunkedTilemapComponent(
          tileset: atlas,
          mapWidth: 4,
          mapHeight: 2,
          tileDestWidth: 16,
          tileDestHeight: 16,
        );

        // Row 0: unflipped rotations 0, 1 (90 CW), 2 (180), 3 (270 CW)
        // Row 1: flipH=true with rotations 0, 1, 2, 3 (uses Vertices.raw!)
        for (var rot = 0; rot < 4; rot++) {
          map
            ..setTileGid(rot, 0, TileGid.pack(1, quarterTurns: rot))
            ..setTileGid(
              rot,
              1,
              TileGid.pack(1, flipH: true, quarterTurns: rot),
            );
        }

        final rgba = await _renderComponentRgba(map, 64, 32);

        const red = ui.Color(0xFFFF0000);
        const green = ui.Color(0xFF00FF00);
        const blue = ui.Color(0xFF0000FF);
        const yellow = ui.Color(0xFFFFFF00);

        // Tile (0,0) identity: TL=R, TR=G, BL=B, BR=Y
        expect(_pixelAt(rgba, 64, 2, 2), red);
        expect(_pixelAt(rgba, 64, 13, 2), green);
        expect(_pixelAt(rgba, 64, 2, 13), blue);
        expect(_pixelAt(rgba, 64, 13, 13), yellow);

        // Tile (1,0) 90° CW: TL=Blue, TR=Red, BR=Green, BL=Yellow
        expect(_pixelAt(rgba, 64, 16 + 2, 2), blue);
        expect(_pixelAt(rgba, 64, 16 + 13, 2), red);
        expect(_pixelAt(rgba, 64, 16 + 13, 13), green);
        expect(_pixelAt(rgba, 64, 16 + 2, 13), yellow);

        // Tile (2,0) 180°: TL=Yellow, TR=Blue, BL=Green, BR=Red
        expect(_pixelAt(rgba, 64, 32 + 2, 2), yellow);
        expect(_pixelAt(rgba, 64, 32 + 13, 2), blue);
        expect(_pixelAt(rgba, 64, 32 + 2, 13), green);
        expect(_pixelAt(rgba, 64, 32 + 13, 13), red);

        // Tile (0,1) flipH only (det = -1 -> Vertices.raw!):
        // TL=Green, TR=Red, BL=Yellow, BR=Blue
        expect(_pixelAt(rgba, 64, 2, 16 + 2), green);
        expect(_pixelAt(rgba, 64, 13, 16 + 2), red);
        expect(_pixelAt(rgba, 64, 2, 16 + 13), yellow);
        expect(_pixelAt(rgba, 64, 13, 16 + 13), blue);
      },
    );

    test(
      'advances A1 water frames 0->1->2->1 with ZERO chunk geometry rebuilds '
      'and dirties only 1..4 chunks on surgical setTileGid',
      () async {
        final img = _buildTestTilesetImage();
        addTearDown(img.dispose);
        final atlas = TilesetAtlas(
          image: img,
          tilePxWidth: 16,
          tilePxHeight: 16,
          autotiles: <int, AutotileDefinition>{
            50: const AutotileDefinition(
              tileId: 50,
              kind: AutotileKind.animatedBlobA1,
              blockOriginPxX: 0,
              blockOriginPxY: 16,
              frameCount: 3,
              frameStridePxX: 32,
            ),
          },
        );
        addTearDown(atlas.disposeShader);

        // 32x32 map with chunkSize=16 => 2x2 = 4 chunks
        final map = ChunkedTilemapComponent(
          tileset: atlas,
          mapWidth: 32,
          mapHeight: 32,
          tileDestWidth: 16,
          tileDestHeight: 16,
        )..setTileId(2, 2, 50);

        final frame0 = await _renderComponentRgba(map, 64, 64);
        expect(map.lastChunkRebuildCount, 4);
        expect(_pixelAt(frame0, 64, 36, 36), const ui.Color(0xFF00FFFF));

        // Advance to step 1 (Magenta): 0 chunk rebuilds!
        map.update(0.26);
        final frame1 = await _renderComponentRgba(map, 64, 64);
        expect(map.lastChunkRebuildCount, 0);
        expect(_pixelAt(frame1, 64, 36, 36), const ui.Color(0xFFFF00FF));

        // Advance to step 2 (White): 0 chunk rebuilds!
        map.update(0.25);
        final frame2 = await _renderComponentRgba(map, 64, 64);
        expect(map.lastChunkRebuildCount, 0);
        expect(_pixelAt(frame2, 64, 36, 36), const ui.Color(0xFFFFFFFF));

        // Advance to step 3 (ping-pong back to Magenta): 0 chunk rebuilds!
        map.update(0.25);
        final frame3 = await _renderComponentRgba(map, 64, 64);
        expect(map.lastChunkRebuildCount, 0);
        expect(_pixelAt(frame3, 64, 36, 36), const ui.Color(0xFFFF00FF));

        // Interior tile edit at (5, 5) touches ONLY chunk (0, 0) => 1 rebuild!
        map.setTileId(5, 5, 1);
        await _renderComponentRgba(map, 64, 64);
        expect(map.lastChunkRebuildCount, 1);

        // Seam corner edit at (15, 15) has 3x3 neighborhood [14..16]x[14..16]
        // crossing all 4 chunks => 4 rebuilds!
        map.setTileId(15, 15, 50);
        await _renderComponentRgba(map, 64, 64);
        expect(map.lastChunkRebuildCount, 4);
      },
    );

    test('YSortLayerComponent orders overlapping sprites by foot Y', () async {
      final layer = YSortLayerComponent();
      final backRed = _ColorBoxComponent(
        color: const ui.Color(0xFFFF0000),
        position: Vector2(0, 4),
        size: Vector2(16, 16),
      );
      final frontBlue = _ColorBoxComponent(
        color: const ui.Color(0xFF0000FF),
        position: Vector2(0, 8),
        size: Vector2(16, 16),
      );
      // Add frontBlue FIRST to prove YSort overrides insertion order!
      layer
        ..add(frontBlue)
        ..add(backRed);

      final pass1 = await _renderComponentRgba(layer, 16, 24);
      // Overlap region (8, 12) must show frontBlue (higher Y) on top:
      expect(_pixelAt(pass1, 16, 8, 12), const ui.Color(0xFF0000FF));

      // Move backRed's foot below frontBlue via position.y = 12:
      backRed.position.y = 12;
      final pass2 = await _renderComponentRgba(layer, 16, 28);
      expect(_pixelAt(pass2, 16, 8, 14), const ui.Color(0xFFFF0000));
    });
  });

  group('TilePassageGrid bridges, counters, cutaway & RoomCameraBounds', () {
    test(
      'isolates z=0 underpass from z=1 bridge deck while allowing approach '
      'ramps',
      () {
        // 5x5 map:
        // Column 2 is a North-South canyon floor (z=0 passable N/S only, walls
        // E/W so ground walker cannot climb canyon walls).
        // Row 2 has an East-West overpass bridge at (2, 2) connecting high
        // ground (1, 2) and (3, 2)!
        final grid = TilePassageGrid(width: 5, height: 5);
        for (var r = 0; r < 5; r++) {
          grid.setFlags(
            2,
            r,
            TilePassageFlags.pack(
              passMask: TilePassageFlags.passNorth | TilePassageFlags.passSouth,
            ),
          );
        }
        // High cliffs at (1, 2) and (3, 2) block dropping East/West onto z=0
        // canyon floor, except via the bridge deck at (2, 2)!
        grid.setBridgeDeck(
          2,
          2,
          deckPassMask: TilePassageFlags.passEast | TilePassageFlags.passWest,
        );

        // 1. Ground walker at (2, 1, z=0) walks South UNDER the bridge at (2,2)
        // and stays at z=0, then cannot step East onto high cliff (3,2)!
        final under = grid.tryStep(
          const GridCell(2, 1),
          GridCardinalDirection.south,
        );
        expect(under, const GridCell(2, 2));
        expect(under!.elevation, 0);
        expect(
          grid.tryStep(under, GridCardinalDirection.east),
          isNull,
        );
        final outSouth = grid.tryStep(under, GridCardinalDirection.south);
        expect(outSouth, const GridCell(2, 3));

        // 2. High-ground walker at (1, 2, z=0) steps East onto bridge deck
        // (2, 2) -> promoted to z=1! On the bridge deck they CANNOT step North
        // off the bridge railing, and stepping East lands cleanly on (3, 2)!
        final onBridge = grid.tryStep(
          const GridCell(1, 2),
          GridCardinalDirection.east,
        );
        expect(onBridge, const GridCell(2, 2, 1));
        expect(
          grid.tryStep(onBridge!, GridCardinalDirection.north),
          isNull,
        );
        final across = grid.tryStep(onBridge, GridCardinalDirection.east);
        expect(across, const GridCell(3, 2));
      },
    );

    test('resolves counter reach-through and roof cutaway fading', () {
      final grid = TilePassageGrid(width: 6, height: 6)
        ..setFlags(
          2,
          2,
          TilePassageFlags.pack(
            passMask: TilePassageFlags.impassable,
            counter: true,
            terrainTag: 7,
            regionId: 199,
          ),
        );
      expect(grid.terrainTag(2, 2), 7);
      expect(grid.regionId(2, 2), 199);

      final probed = <GridCell>[];
      // Player at (2, 3) facing North toward counter (2, 2) reaches shopkeeper
      // at (2, 1)!
      grid.resolveInteractionProbe(
        const GridCell(2, 3),
        GridCardinalDirection.north,
        probed,
      );
      expect(probed, const <GridCell>[GridCell(2, 2), GridCell(2, 1)]);

      final roofCtrl = RoofCutawayController()
        ..addRoofZone(
          RoofOcclusionZone(
            id: 'inn_roof',
            bounds: const ui.Rect.fromLTWH(32, 32, 96, 96),
            fadeSpeedPerSecond: 5.0,
          ),
        )
        ..addSilhouetteBlocker(const ui.Rect.fromLTWH(200, 200, 32, 64));

      expect(roofCtrl.zones.single.currentOpacity, 1.0);
      expect(roofCtrl.update(64, 64, 0.5), isTrue);
      expect(roofCtrl.zones.single.currentOpacity, 0.0);
      expect(roofCtrl.zones.single.isActorInside, isTrue);
      expect(
        roofCtrl.isActorOccludedForSilhouette(
          const ui.Rect.fromLTWH(205, 210, 16, 24),
        ),
        isTrue,
      );
    });

    test(
      'RoomCameraBounds auto-centers small interiors without edge oscillation',
      () {
        // Interior room is 160x120 while camera viewport is 320x240!
        final smallRoom = RoomCameraBounds(
          roomBounds: const ui.Rect.fromLTWH(100, 50, 160, 120),
          smoothingRate: 0, // immediate
        );
        final camPos = Vector2.zero();

        smallRoom.step(
          focusPoint: Vector2(105, 55),
          baseZoom: 1.0,
          viewportPixelWidth: 320,
          viewportPixelHeight: 240,
          dt: 0.016,
          outCameraPos: camPos,
        );
        expect(camPos.x, closeTo(180.0, 1e-6));
        expect(camPos.y, closeTo(110.0, 1e-6));

        // Walking to the opposite corner of the small room keeps the camera
        // rock-steady at the exact room center (180, 110)!
        smallRoom.step(
          focusPoint: Vector2(255, 165),
          baseZoom: 1.0,
          viewportPixelWidth: 320,
          viewportPixelHeight: 240,
          dt: 0.016,
          outCameraPos: camPos,
        );
        expect(camPos.x, closeTo(180.0, 1e-6));
        expect(camPos.y, closeTo(110.0, 1e-6));
      },
    );

    test(
      'ConnectedWorldStreamer preloads adjacent maps and evicts LRU excess, '
      'and TileMapDocument + DataTableRegistry validate codecs & foreign keys',
      () async {
        final loadedLog = <String>[];
        final disposedLog = <String>[];
        final streamer =
            ConnectedWorldStreamer<String>(
              maxLoadedMaps: 2,
              preloadDistance: 48.0,
              loader: (id) async {
                loadedLog.add(id);
                return 'MAP:$id';
              },
              onDisposeMap: (id, _) => disposedLog.add(id),
            )..registerPortal(
              WorldPortalLink(
                id: 'to_forest',
                fromMapId: 'town',
                triggerRect: const ui.Rect.fromLTWH(300, 0, 16, 64),
                toMapId: 'forest',
                targetSpawnPosition: Vector2(16, 32),
              ),
            );

        await streamer.enterMap('town');
        // Approaching portal within 48px preloads 'forest' without triggering:
        final nearHit = streamer.updatePlayerPosition(265, 32);
        expect(nearHit, isNull);
        await Future<void>.delayed(Duration.zero);
        expect(streamer.isLoaded('forest'), isTrue);

        // Stepping inside portal triggers transition:
        final portalHit = streamer.updatePlayerPosition(308, 32);
        expect(portalHit?.toMapId, 'forest');

        // Entering a 3rd map ('cave') evicts LRU non-active 'town':
        await streamer.enterMap('cave');
        expect(disposedLog, contains('town'));
        expect(streamer.activeMapId, 'cave');

        // TileMapDocument JSON & DTMP binary roundtrips + Prefab instantiation:
        final cells = Uint32List.fromList(<int>[
          TileGid.pack(1).raw,
          TileGid.pack(2, flipH: true).raw,
          0,
          TileGid.pack(3, quarterTurns: 2).raw,
        ]);
        final doc = TileMapDocument(
          mapId: 'shrine_01',
          width: 2,
          height: 2,
          tileWidth: 32,
          tileHeight: 32,
          layers: <TileMapLayerData>[
            TileMapLayerData(name: 'ground', cells: cells, priority: -5),
          ],
          spawns: const <TileMapEntitySpawn>[
            TileMapEntitySpawn(
              id: 'chest_1',
              prefabId: 'treasure_chest',
              x: 48,
              y: 16,
            ),
          ],
        );

        final fromJson = TileMapDocument.fromJson(doc.encodeJson());
        expect(fromJson.mapId, 'shrine_01');
        expect(fromJson.layers.single.cells, orderedEquals(cells));

        final bin = doc.encodeBinary();
        final fromBin = TileMapDocument.fromBinary(bin);
        expect(fromBin.mapId, 'shrine_01');
        expect(fromBin.layers.single.cells, orderedEquals(cells));

        // Corrupt magic header must throw FormatException:
        final corrupt = Uint8List.fromList(bin)..[0] = 0x00;
        expect(
          () => TileMapDocument.fromBinary(corrupt),
          throwsFormatException,
        );

        final prefabs = PrefabRegistry()
          ..register<PositionComponent>(
            'treasure_chest',
            (_) => PositionComponent(size: Vector2.all(16)),
          );
        final spawned = fromBin.instantiateSpawns(prefabs);
        expect(spawned.single, isA<PositionComponent>());
        expect(
          (spawned.single as PositionComponent).position,
          Vector2(48, 16),
        );

        // DataTableRegistry duplicate PK & broken FK detection:
        final db = DataTableRegistry()
          ..registerTable<_SkillRow>(
            'skills',
            const <_SkillRow>[_SkillRow('heal_1')],
            idOf: (r) => r.id,
          )
          ..registerTable<_ItemRow>(
            'items',
            const <_ItemRow>[
              _ItemRow('potion', 'heal_1'),
              _ItemRow('broken_scroll', 'missing_meteor_99'),
            ],
            idOf: (r) => r.id,
          )
          ..addForeignKeyRule<_ItemRow>(
            ForeignKeyRule<_ItemRow>(
              sourceTable: 'items',
              targetTable: 'skills',
              fieldName: 'skillId',
              extractTargetId: (r) => r.skillId,
            ),
          );

        final fkErrors = db.validateForeignKeys();
        expect(fkErrors, hasLength(1));
        expect(fkErrors.single, contains('missing_meteor_99'));
        expect(
          () => db.registerTable<_SkillRow>(
            'dup',
            const <_SkillRow>[_SkillRow('a'), _SkillRow('a')],
            idOf: (r) => r.id,
          ),
          throwsArgumentError,
        );
      },
    );
  });
}
