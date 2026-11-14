import 'dart:ui';

import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flutter_test/flutter_test.dart';

class _RenderCounterTile({
  required super.position,
  required super.size,
}) extends PositionComponent {
  int renderCount = 0;

  @override
  void render(Canvas canvas) {
    renderCount++;
  }
}

class _CullBoundsParent({
  super.children,
}) extends PositionComponent with CullWhenOffscreen, CullBoundsChildren {
  @override
  Iterable<PositionComponent> get cullBoundsChildren =>
      children.whereType<PositionComponent>();
}

void main() {
  group('SpatialCullGroup & cached CullBoundsChildren', () {
    test(
      'skips entire offscreen group in 1 check without visiting children and '
      'recomputes static bounds only once',
      () async {
        final game = FlameGame(
          camera: CameraComponent.withFixedResolution(width: 200, height: 200),
        )..onGameResize(Vector2(200, 200));
        await game.start();

        final visibleTiles = [
          for (var i = 0; i < 5; i++)
            _RenderCounterTile(
              position: Vector2(-40.0 + i * 15, -20),
              size: Vector2(12, 12),
            ),
        ];
        final offscreenTiles = [
          for (var i = 0; i < 8; i++)
            _RenderCounterTile(
              position: Vector2(900.0 + i * 20, 900),
              size: Vector2(16, 16),
            ),
        ];

        final sectorA = SpatialCullGroup(
          staticBounds: true,
          children: visibleTiles,
        );
        final sectorB = SpatialCullGroup(
          staticBounds: true,
          children: offscreenTiles,
        );
        game.world.addAll([sectorA, sectorB]);
        await game.ready();

        for (var f = 0; f < 4; f++) {
          final recorder = PictureRecorder();
          game.render(Canvas(recorder));
          recorder.endRecording().dispose();
        }

        expect(sectorA.wasGroupCulledLastFrame, isFalse);
        expect(sectorB.wasGroupCulledLastFrame, isTrue);
        expect(sectorA.boundsComputeCount, 1);
        expect(sectorB.boundsComputeCount, 1);
        expect(visibleTiles.every((t) => t.renderCount == 4), isTrue);
        expect(offscreenTiles.every((t) => t.renderCount == 0), isTrue);
        expect(game.camera.lastFrameCulledCount, 1);
        expect(game.camera.lastFrameVisibleCount, 1);
      },
    );

    test(
      'dynamic SpatialCullGroup invalidates bounds automatically when child '
      'moves into camera view',
      () async {
        final game = FlameGame(
          camera: CameraComponent.withFixedResolution(width: 200, height: 200),
        )..onGameResize(Vector2(200, 200));
        await game.start();

        final mover = _RenderCounterTile(
          position: Vector2(600, 600),
          size: Vector2(20, 20),
        );
        final dynamicGroup = SpatialCullGroup(children: [mover]);
        game.world.add(dynamicGroup);
        await game.ready();

        final rec1 = PictureRecorder();
        game.render(Canvas(rec1));
        rec1.endRecording().dispose();
        expect(dynamicGroup.wasGroupCulledLastFrame, isTrue);
        expect(mover.renderCount, 0);

        // Move child into view -> Transform2D.version invalidates group bounds.
        mover.position.setValues(0, 0);
        final rec2 = PictureRecorder();
        game.render(Canvas(rec2));
        rec2.endRecording().dispose();
        expect(dynamicGroup.wasGroupCulledLastFrame, isFalse);
        expect(mover.renderCount, 1);
      },
    );

    test(
      'CullBoundsChildren caches union rect when children do not move',
      () async {
        final c1 = PositionComponent(
          position: Vector2(10, 20),
          size: Vector2(30, 40),
        );
        final c2 = PositionComponent(
          position: Vector2(80, 50),
          size: Vector2(20, 20),
        );
        final group = _CullBoundsParent(children: [c1, c2]);
        final game = FlameGame()..onGameResize(Vector2(400, 400));
        await game.start();
        game.world.add(group);
        await game.ready();

        final r1 = group.cullBounds;
        final r2 = group.cullBounds;
        final r3 = group.cullBounds;
        expect(r1, const Rect.fromLTRB(0, 0, 100, 70));
        expect(r2, r1);
        expect(r3, r1);
        expect(group.cullUnionRecomputeCount, 1);

        c2.position.x = 120;
        final r4 = group.cullBounds;
        expect(r4, const Rect.fromLTRB(0, 0, 140, 70));
        expect(group.cullUnionRecomputeCount, 2);
      },
    );
  });
}
