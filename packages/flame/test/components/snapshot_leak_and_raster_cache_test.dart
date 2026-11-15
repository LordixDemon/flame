import 'dart:ui';

import 'package:flame/components.dart';
import 'package:flame_test/flame_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockCanvas() extends Mock implements Canvas;

class _FakeImage() extends Fake implements Image;

class _FakePicture() extends Fake implements Picture;

class _SnapshotVectorLayer({super.size})
    extends PositionComponent
    with Snapshot {
  int childRenderCount = 0;

  @override
  void render(Canvas canvas) {
    childRenderCount++;
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.x, size.y),
      Paint()..color = const Color(0xFF44AAFF),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(_FakeImage());
    registerFallbackValue(_FakePicture());
    registerFallbackValue(Paint());
    registerFallbackValue(Rect.zero);
  });

  group('Snapshot GPU leak fixes & SnapshotCacheMode.rasterImage', () {
    testWithFlameGame(
      'deterministically disposes Picture and Image across clearSnapshot, '
      'retake, transform snapshotAsImage, and onRemove',
      (game) async {
        final layer = _SnapshotVectorLayer(size: Vector2(64, 48));
        await game.ensureAdd(layer);

        layer.takeSnapshot();
        expect(layer.hasSnapshot, isTrue);
        expect(layer.snapshotDisposalCount, equals(0));

        layer.takeSnapshot();
        expect(layer.snapshotDisposalCount, equals(1));

        final img = layer.snapshotAsImage(
          64,
          48,
          transform: Matrix4.identity(),
        );
        img.dispose();
        expect(layer.snapshotDisposalCount, equals(2));

        layer.clearSnapshot();
        expect(layer.hasSnapshot, isFalse);
        expect(layer.snapshotDisposalCount, equals(3));

        // Re-populate Picture and raster Image, then unmount -> disposes 2!
        layer
          ..snapshotCacheMode = SnapshotCacheMode.rasterImage
          ..snapshotPixelRatio = 2.0;
        final recorder = PictureRecorder();
        layer.renderTree(Canvas(recorder));
        recorder.endRecording().dispose();

        expect(layer.cachedSnapshotImage, isNotNull);
        expect(layer.cachedSnapshotImage!.width, equals(128));
        expect(layer.cachedSnapshotImage!.height, equals(96));

        layer.removeFromParent();
        await game.ready();

        expect(layer.hasSnapshot, isFalse);
        expect(layer.cachedSnapshotImage, isNull);
        expect(layer.snapshotDisposalCount, equals(5));
      },
    );

    testWithFlameGame(
      'SnapshotCacheMode.rasterImage blits cached GPU texture via a single '
      'drawImageRect call without re-executing child draws',
      (game) async {
        final layer = _SnapshotVectorLayer(size: Vector2(50, 30))
          ..snapshotCacheMode = SnapshotCacheMode.rasterImage
          ..snapshotPixelRatio = 2.0;
        await game.ensureAdd(layer);

        final canvas = _MockCanvas();
        layer.renderTree(canvas);
        layer.renderTree(canvas);
        layer.renderTree(canvas);

        expect(layer.childRenderCount, equals(1));
        verify(
          () => canvas.drawImageRect(any(), any(), any(), any()),
        ).called(3);
        verifyNever(() => canvas.drawPicture(any()));
      },
    );
  });
}
