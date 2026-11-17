// A SpriteBatchComponent baked into a cached picture (Snapshot) must keep
// drawing after the camera moves: the picture is replayed for every camera
// position, so the batch must not carry the visible rect of the bake frame as
// its drawAtlas cull rect.
import 'dart:ui';

import 'package:flame/camera.dart';
import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flame/sprite.dart';
import 'package:flutter_test/flutter_test.dart';

class _BakedTiles({super.children}) extends PositionComponent with Snapshot;

Image _redAtlas() {
  final rec = PictureRecorder();
  Canvas(rec).drawRect(
    const Rect.fromLTWH(0, 0, 8, 8),
    Paint()..color = const Color(0xFFFF0000),
  );
  final pic = rec.endRecording();
  try {
    return pic.toImageSync(8, 8);
  } finally {
    pic.dispose();
  }
}

void main() {
  Future<List<int>> centrePixelAfterPan({
    required bool cached,
    bool autoCullRect = true,
  }) async {
    final game = FlameGame(
      camera: CameraComponent(viewport: FixedSizeViewport(40, 40)),
    )..onGameResize(Vector2(40, 40));
    await game.start();

    final atlas = _redAtlas();
    const src = Rect.fromLTWH(0, 0, 8, 8);
    final batch = SpriteBatch(atlas)
      // One tile under the camera's start position ...
      ..add(source: src, offset: Vector2(-4, -4))
      // ... and one where the camera is going to pan to.
      ..add(source: src, offset: Vector2(2996, -4));
    final tiles = _BakedTiles(
      children: [
        SpriteBatchComponent(spriteBatch: batch, autoCullRect: autoCullRect),
      ],
    )..renderSnapshot = cached;
    game.world.add(tiles);
    await game.ready();

    Future<List<int>> centre() async {
      final image = game.camera.renderToImageSync(
        width: 40,
        height: 40,
        backgroundColor: const Color(0xFF000000),
      );
      final bytes = await image.toByteData();
      image.dispose();
      const idx = (20 * 40 + 20) * 4;
      return [
        bytes!.getUint8(idx),
        bytes.getUint8(idx + 1),
        bytes.getUint8(idx + 2),
      ];
    }

    // Frame at the start position: bakes the snapshot (when cached).
    expect(await centre(), [255, 0, 0]);

    game.camera.viewfinder.position = Vector2(3000, 0);
    game.update(0);
    final result = await centre();
    atlas.dispose();
    return result;
  }

  test('sanity: live SpriteBatchComponent is visible after the pan', () async {
    expect(await centrePixelAfterPan(cached: false), [255, 0, 0]);
  });

  test('sanity: baked with autoCullRect off it is visible too', () async {
    expect(
      await centrePixelAfterPan(cached: true, autoCullRect: false),
      [255, 0, 0],
    );
  });

  test(
    'a SpriteBatchComponent baked into a Snapshot is still visible after the '
    'camera pans to another part of it',
    () async {
      expect(
        await centrePixelAfterPan(cached: true),
        [255, 0, 0],
        reason:
            'the baked drawAtlas call carries the visible rect of the bake '
            'frame as its cullRect and is rejected after the pan',
      );
    },
  );
}
