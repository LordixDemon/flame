import 'dart:typed_data';
import 'dart:ui';

import 'package:flame/components.dart';
import 'package:flame_test/flame_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockCanvas() extends Mock implements Canvas;

class _FakeImage() extends Fake implements Image;

class _AutoBatchV2Group() extends PositionComponent with HasAutoBatchedChildren;

class _CustomBadgeBatchComponent(
  final Image atlas, {
  final BlendMode blendMode = BlendMode.srcOver,
  super.size,
}) extends PositionComponent with SpriteBatchItemProvider {
  @override
  SpriteBatchEntry? provideSpriteBatchItem() => SpriteBatchEntry(
    image: atlas,
    sourceRect: const Rect.fromLTWH(0, 0, 8, 8),
    blendMode: blendMode,
  );
}

class _SpireCullComponent({
  super.position,
  super.size,
}) extends PositionComponent with CullWhenOffscreen {
  int renderCount = 0;

  @override
  void render(Canvas canvas) {
    renderCount++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Image sharedAtlas;
  late Vertices fallbackVertices;

  setUpAll(() async {
    registerFallbackValue(_FakeImage());
    fallbackVertices = Vertices.raw(
      VertexMode.triangles,
      Float32List.fromList([0, 0, 1, 0, 0, 1]),
    );
    registerFallbackValue(fallbackVertices);
    registerFallbackValue(BlendMode.srcOver);
    registerFallbackValue(Paint());
    registerFallbackValue(Rect.zero);
    sharedAtlas = await generateImage(16, 16);
  });

  tearDownAll(() {
    fallbackVertices.dispose();
  });

  group('Enhanced HasAutoBatchedChildren v2', () {
    testWithFlameGame(
      'batches SpriteBatchItemProvider alongside SpriteComponent and separates '
      'BlendMode.plus batches cleanly',
      (game) async {
        final group = _AutoBatchV2Group();
        await game.ensureAdd(group);

        final sprite = Sprite(sharedAtlas, srcSize: Vector2.all(8));
        final additivePaint = Paint()..blendMode = BlendMode.plus;

        await group.ensureAddAll([
          SpriteComponent(sprite: sprite, size: Vector2.all(8)),
          _CustomBadgeBatchComponent(sharedAtlas, size: Vector2.all(8)),
          SpriteComponent(
            sprite: sprite,
            size: Vector2.all(8),
            paint: additivePaint,
          ),
          _CustomBadgeBatchComponent(
            sharedAtlas,
            size: Vector2.all(8),
            blendMode: BlendMode.plus,
          ),
        ]);

        final canvas = _MockCanvas();
        group.renderTree(canvas);

        verify(
          () => canvas.drawAtlas(
            any(),
            any(),
            any(),
            any(),
            any(),
            any(),
            any(),
          ),
        ).called(2);
        verifyNever(() => canvas.drawImageRect(any(), any(), any(), any()));
      },
    );

    testWithFlameGame(
      'allowAffineVerticesBatching batches non-uniformly scaled sprites into a '
      'single drawVertices call',
      (game) async {
        final group = _AutoBatchV2Group()..allowAffineVerticesBatching = true;
        await game.ensureAdd(group);

        final sprite = Sprite(sharedAtlas, srcSize: Vector2.all(16));
        for (var i = 0; i < 4; i++) {
          await group.ensureAdd(
            SpriteComponent(
              sprite: sprite,
              size: Vector2(24, 10),
              scale: Vector2(1.4, 0.7),
              angle: 0.3 * i,
              position: Vector2(i * 30.0, 12.0),
            ),
          );
        }

        final canvas = _MockCanvas();
        group.renderTree(canvas);

        verify(() => canvas.drawVertices(any(), any(), any())).called(1);
        verifyNever(() => canvas.drawImageRect(any(), any(), any(), any()));

        group.removeFromParent();
        await game.ready();
      },
    );
  });

  group('Cached 2.5D/3D Frustum Culling', () {
    testWithFlameGame(
      'caches world bounds via Transform2D.version and respects directional '
      'cullBoundsOutset for tall 3D spires',
      (game) async {
        game.onGameResize(Vector2(200, 200));
        game.camera.viewfinder
          ..position = Vector2.zero()
          ..zoom = 1.0;

        final spire = _SpireCullComponent(
          position: Vector2(-10, 130),
          size: Vector2(20, 20),
        )..cullBoundsOutset = const Rect.fromLTRB(8, 60, 8, 10);

        final farOffscreen = _SpireCullComponent(
          position: Vector2(500, 500),
          size: Vector2(20, 20),
        );

        await game.world.ensureAddAll([spire, farOffscreen]);

        for (var i = 0; i < 30; i++) {
          final recorder = PictureRecorder();
          game.render(Canvas(recorder));
          recorder.endRecording().dispose();
        }

        expect(spire.renderCount, equals(30));
        expect(farOffscreen.renderCount, equals(0));
        expect(spire.wasCulledLastFrame, isFalse);
        expect(farOffscreen.wasCulledLastFrame, isTrue);
        expect(game.camera.lastFrameVisibleCount, equals(1));
        expect(game.camera.lastFrameCulledCount, equals(1));

        expect(spire.cullBoundsComputeCount, equals(1));
        expect(farOffscreen.cullBoundsComputeCount, equals(1));

        spire.position = Vector2(-10, 220);
        final recorder = PictureRecorder();
        game.render(Canvas(recorder));
        recorder.endRecording().dispose();

        expect(spire.cullBoundsComputeCount, equals(2));
        expect(spire.wasCulledLastFrame, isTrue);
        expect(game.camera.lastFrameCulledCount, equals(2));
      },
    );

    testWithFlameGame(
      'caches world bounds across frames when nested inside plain '
      'non-transforming Component layer containers under World',
      (game) async {
        game.onGameResize(Vector2(200, 200));
        game.camera.viewfinder
          ..position = Vector2.zero()
          ..zoom = 1.0;

        final standingLayer = Component(priority: 10);
        await game.world.ensureAdd(standingLayer);

        final layeredBuilding = _SpireCullComponent(
          position: Vector2(0, 0),
          size: Vector2(24, 24),
        );
        await standingLayer.ensureAdd(layeredBuilding);

        for (var i = 0; i < 15; i++) {
          final recorder = PictureRecorder();
          game.render(Canvas(recorder));
          recorder.endRecording().dispose();
        }

        expect(layeredBuilding.renderCount, equals(15));
        expect(layeredBuilding.cullBoundsComputeCount, equals(1));
      },
    );
  });
}
