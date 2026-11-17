import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/game.dart';
import 'package:flame/tilemap.dart';
import 'package:flutter_test/flutter_test.dart';

ui.Image _tilesetImage() {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    const ui.Rect.fromLTWH(0, 0, 256, 128),
    ui.Paint()..color = const ui.Color(0xFF808080),
  );
  final picture = recorder.endRecording();
  final image = picture.toImageSync(256, 128);
  picture.dispose();
  return image;
}

void _renderOnce(ChunkedTilemapComponent map) {
  final recorder = ui.PictureRecorder();
  map.render(ui.Canvas(recorder));
  recorder.endRecording().dispose();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ui.Image image;
  setUp(() => image = _tilesetImage());
  tearDown(() => image.dispose());

  /// Tile id 9 is an animated water autotile with 3 frames.
  TilesetAtlas tileset() => TilesetAtlas(
    image: image,
    tilePxWidth: 16,
    tilePxHeight: 16,
    autotiles: const {
      9: AutotileDefinition(
        tileId: 9,
        kind: AutotileKind.animatedBlobA1,
        blockOriginPxX: 0,
        blockOriginPxY: 0,
        frameCount: 3,
        frameStridePxX: 32,
      ),
    },
  );

  ChunkedTilemapComponent map(List<int> cells) => ChunkedTilemapComponent(
    tileset: tileset(),
    mapWidth: 4,
    mapHeight: 4,
    tileDestWidth: 16,
    tileDestHeight: 16,
    initialCells: Uint32List.fromList(cells),
  );

  /// The visual mutations and subtree versions caused by 2 seconds of
  /// updates, which is 8 animation steps.
  (int, int) changesOverTwoSeconds(ChunkedTilemapComponent map) {
    final mutations = Game.visualMutationCount;
    final version = map.subtreeVersion;
    for (var i = 0; i < 20; i++) {
      map.update(0.1);
    }
    return (
      Game.visualMutationCount - mutations,
      map.subtreeVersion - version,
    );
  }

  group('ChunkedTilemapComponent animation steps', () {
    test('a map without animated tiles stays clean', () {
      final static = map(List<int>.filled(16, 1));
      _renderOnce(static);
      final stepBefore = static.animationStep;

      expect(changesOverTwoSeconds(static), (0, 0));
      // The animation clock itself keeps running.
      expect(static.animationStep, stepBefore + 8);
    });

    test('a map with animated tiles in view is dirty once per step', () {
      final animated = map(List<int>.filled(16, 9));
      _renderOnce(animated);

      final (mutations, versions) = changesOverTwoSeconds(animated);
      expect(mutations, 8);
      expect(versions, greaterThanOrEqualTo(8));
    });

    test('putting an animated tile on a static map starts the steps', () {
      final edited = map(List<int>.filled(16, 1));
      _renderOnce(edited);
      expect(changesOverTwoSeconds(edited).$1, 0);

      edited.setTileId(1, 1, 9);
      _renderOnce(edited);
      expect(changesOverTwoSeconds(edited).$1, 8);

      edited.setTileId(1, 1, 1);
      _renderOnce(edited);
      expect(changesOverTwoSeconds(edited).$1, 0);
    });

    test('a hidden layer does not report steps', () {
      final hidden = map(List<int>.filled(16, 9));
      _renderOnce(hidden);
      hidden.opacity = 0;
      _renderOnce(hidden);
      expect(changesOverTwoSeconds(hidden).$1, 0);
    });
  });

  group('ChunkedTilemapComponent mirrored tiles', () {
    test('rebuilding a chunk and removing the component keep drawing '
        'correctly', () async {
      // A horizontally flipped tile is drawn through a vertex buffer.
      final flipped = TileGid.pack(1, flipH: true).raw;
      final tilemap = map(List<int>.filled(16, flipped));
      final game = FlameGame()..onGameResize(Vector2(200, 200));
      await game.start();
      game.world.add(tilemap);
      await game.ready();

      _renderOnce(tilemap);
      expect(tilemap.lastChunkRebuildCount, 1);
      expect(tilemap.lastDrawCallCount, 1);

      // An edit replaces the vertex buffer of the chunk.
      tilemap.setTileGid(0, 0, TileGid.pack(1, flipV: true));
      expect(() => _renderOnce(tilemap), returnsNormally);
      expect(tilemap.lastChunkRebuildCount, 1);

      // Removing releases the buffers; they are built again on demand.
      tilemap.removeFromParent();
      game.processLifecycleEvents();
      game.world.add(tilemap);
      await game.ready();
      expect(() => _renderOnce(tilemap), returnsNormally);
      expect(tilemap.lastChunkRebuildCount, 1);
      expect(tilemap.lastDrawCallCount, 1);
    });
  });
}
