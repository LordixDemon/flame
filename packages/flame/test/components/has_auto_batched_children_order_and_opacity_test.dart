// Draw order and opacity of the children of a [HasAutoBatchedChildren]: the
// order of the children is the order they are drawn in whatever their blend
// modes, and a batched sprite is modulated by its paint colour (opacity) on
// the drawAtlas path just like on the affine path.
import 'dart:typed_data';
import 'dart:ui';

import 'package:flame/camera.dart';
import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flutter_test/flutter_test.dart';

class _Batched() extends PositionComponent with HasAutoBatchedChildren;

Image _atlas() {
  final rec = PictureRecorder();
  Canvas(rec)
    ..drawRect(
      const Rect.fromLTWH(0, 0, 8, 8),
      Paint()..color = const Color(0xFFFF0000),
    )
    ..drawRect(
      const Rect.fromLTWH(8, 0, 8, 8),
      Paint()..color = const Color(0xFF404040),
    );
  final pic = rec.endRecording();
  try {
    return pic.toImageSync(16, 8);
  } finally {
    pic.dispose();
  }
}

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
  group('HasAutoBatchedChildren blend mode order', () {
    Future<List<int>> centrePixel({required bool batching}) async {
      final game = FlameGame(
        camera: CameraComponent(viewport: FixedSizeViewport(40, 40)),
      )..onGameResize(Vector2(40, 40));
      await game.start();

      final atlas = _atlas();
      final red = Sprite(atlas, srcSize: Vector2(8, 8));
      final grey = Sprite(
        atlas,
        srcPosition: Vector2(8, 0),
        srcSize: Vector2(8, 8),
      );

      SpriteComponent make(Sprite s, {BlendMode? blend}) {
        final c = SpriteComponent(
          sprite: s,
          size: Vector2.all(8),
          anchor: Anchor.center,
        );
        if (blend != null) {
          c.paint.blendMode = blend;
        }
        return c;
      }

      final group = _Batched()..batchingEnabled = batching;
      // Same priority, same atlas, child order: red, additive grey, red.
      group.addAll([
        make(red),
        make(grey, blend: BlendMode.plus),
        make(red),
      ]);
      game.world.add(group);
      await game.ready();

      final image = game.camera.renderToImageSync(
        width: 40,
        height: 40,
        backgroundColor: const Color(0xFF000000),
      );
      final ByteData? bytes;
      try {
        bytes = await image.toByteData();
      } finally {
        image.dispose();
        atlas.dispose();
      }
      const idx = (20 * 40 + 20) * 4;
      return [
        bytes!.getUint8(idx),
        bytes.getUint8(idx + 1),
        bytes.getUint8(idx + 2),
      ];
    }

    test('sanity: unbatched, the last (opaque red) child wins', () async {
      expect(await centrePixel(batching: false), [255, 0, 0]);
    });

    test(
      'batched children with mixed blend modes keep their child order',
      () async {
        expect(
          await centrePixel(batching: true),
          [255, 0, 0],
          reason:
              'the additive child was drawn AFTER the opaque sprite that '
              'follows it in the child list',
        );
      },
    );
  });

  group('HasAutoBatchedChildren opacity', () {
    Future<List<int>> centrePixel({
      required bool batching,
      bool stretched = false,
    }) async {
      final game = FlameGame(
        camera: CameraComponent(viewport: FixedSizeViewport(40, 40)),
      )..onGameResize(Vector2(40, 40));
      await game.start();
      final atlas = _redAtlas();
      final sprite = SpriteComponent(
        sprite: Sprite(atlas),
        // A non-square size forces the affine drawVertices path.
        size: stretched ? Vector2(8, 12) : Vector2.all(8),
        anchor: Anchor.center,
      )..opacity = 0.5;
      final group = _Batched()
        ..batchingEnabled = batching
        ..allowAffineVerticesBatching = stretched;
      group.add(sprite);
      game.world.add(group);
      await game.ready();

      final image = game.camera.renderToImageSync(
        width: 40,
        height: 40,
        backgroundColor: const Color(0xFF000000),
      );
      final bytes = await image.toByteData();
      image.dispose();
      atlas.dispose();
      const idx = (20 * 40 + 20) * 4;
      return [
        bytes!.getUint8(idx),
        bytes.getUint8(idx + 1),
        bytes.getUint8(idx + 2),
      ];
    }

    test('sanity: unbatched 50% red over black is (128, 0, 0)', () async {
      expect(await centrePixel(batching: false), [128, 0, 0]);
    });

    test('sanity: the affine batch path keeps the 50% opacity', () async {
      expect(await centrePixel(batching: true, stretched: true), [128, 0, 0]);
    });

    test('the drawAtlas batch path keeps the 50% opacity', () async {
      expect(
        await centrePixel(batching: true),
        [128, 0, 0],
        reason: 'a half-transparent sprite is drawn fully opaque when batched',
      );
    });
  });
}
