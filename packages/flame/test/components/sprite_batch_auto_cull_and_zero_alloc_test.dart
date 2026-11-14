import 'dart:ui';

import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flame/sprite.dart';
import 'package:flame_test/flame_test.dart';
import 'package:flutter_test/flutter_test.dart';

class _AutoBatchWorldLayer() extends Component with HasAutoBatchedChildren;

class _RotatedBatchContainer()
    extends PositionComponent
    with HasAutoBatchedChildren {
  this : super(angle: 0.4);
}

void main() {
  group('SpriteBatch zero-alloc add & automatic World cullRect', () {
    test(
      'SpriteBatchComponent & HasAutoBatchedChildren pass visibleWorldRect '
      'when in direct World space and null under rotated transforms',
      () async {
        final image = await generateImage(32, 32);
        addTearDown(image.dispose);

        final game = FlameGame(
          camera: CameraComponent.withFixedResolution(width: 240, height: 160),
        )..onGameResize(Vector2(240, 160));
        await game.start();
        game.camera.viewfinder.position = Vector2(50, 25);

        final batch = SpriteBatch(image)
          ..add(source: const Rect.fromLTWH(0, 0, 16, 16))
          ..add(
            source: const Rect.fromLTWH(0, 0, 16, 16),
            offset: Vector2(40, 20),
            scale: 1.5,
            rotation: 0.25,
          );
        final batchComp = SpriteBatchComponent(spriteBatch: batch);

        final worldLayer = _AutoBatchWorldLayer()
          ..add(
            SpriteComponent(
              sprite: Sprite(image),
              position: Vector2(10, 10),
              size: Vector2(16, 16),
            ),
          );

        final rotatedLayer = _RotatedBatchContainer()
          ..add(
            SpriteComponent(
              sprite: Sprite(image),
              position: Vector2(10, 10),
              size: Vector2(16, 16),
            ),
          );

        game.world.addAll([batchComp, worldLayer, rotatedLayer]);
        await game.ready();

        final recorder = PictureRecorder();
        game.render(Canvas(recorder));
        recorder.endRecording().dispose();

        final expectedWorldRect = game.camera.visibleWorldRect;
        expect(batchComp.lastEffectiveCullRect, expectedWorldRect);
        expect(worldLayer.lastEffectiveCullRect, expectedWorldRect);
        // Rotated local space differs from world space -> safe null cullRect!
        expect(rotatedLayer.lastEffectiveCullRect, isNull);
      },
    );
  });
}
