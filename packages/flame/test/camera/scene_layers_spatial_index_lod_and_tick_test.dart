import 'dart:ui';

import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flutter_test/flutter_test.dart';

class _LayerProbe({required final String tag, super.size})
    extends PositionComponent {
  static final List<String> renderLog = <String>[];
  double? lastTx;

  @override
  void render(Canvas canvas) {
    renderLog.add(tag);
    lastTx = canvas.getTransform()[12];
  }
}

class _SpatialActor({
  required final int id,
  super.position,
  super.size,
  super.priority,
  super.sortKey,
}) extends PositionComponent with CullWhenOffscreen {
  static final List<int> renderedIds = <int>[];
  int updateTicks = 0;
  double totalUpdatedDt = 0.0;

  @override
  void update(double dt) {
    updateTicks++;
    totalUpdatedDt += dt;
  }

  @override
  void render(Canvas canvas) {
    renderedIds.add(id);
  }
}

class _LodActor({super.size}) extends PositionComponent with HasSceneLod {
  int renderCount = 0;
  final List<LodLevel> observedChanges = <LodLevel>[];

  @override
  void onLodChanged(LodLevel previous, LodLevel current) {
    observedChanges.add(current);
  }

  @override
  void render(Canvas canvas) {
    renderCount++;
  }
}

void main() {
  group('SceneLayer, WorldSpatialIndex, HasSceneLod & OffscreenTick', () {
    test(
      'SceneLayerComponent filters by CameraComponent.layerMask, applies '
      'parallax, and caches Picture (#16)',
      () async {
        final game = FlameGame()..onGameResize(Vector2(400, 300));
        const bitSky = 1 << 0;
        const bitWorld = 1 << 1;
        const bitWeather = 1 << 2;

        final skyProbe = _LayerProbe(tag: 'sky', size: Vector2.all(20));
        final skyLayer = SceneLayerComponent(
          name: 'sky',
          parallaxFactor: Vector2.all(0.25),
          cacheAsPicture: true,
          children: [skyProbe],
        );
        final worldLayer = SceneLayerComponent(
          name: 'world',
          layerBit: bitWorld,
          children: [_LayerProbe(tag: 'world', size: Vector2.all(20))],
        );
        final weatherLayer = SceneLayerComponent(
          name: 'weather',
          layerBit: bitWeather,
          minQualityTier: GraphicsQualityTier.high,
          children: [_LayerProbe(tag: 'weather', size: Vector2.all(20))],
        );

        game.world.addAll([skyLayer, worldLayer, weatherLayer]);
        await game.start();

        void renderFrame() {
          _LayerProbe.renderLog.clear();
          final rec = PictureRecorder();
          game.render(Canvas(rec));
          rec.endRecording().dispose();
        }

        // Frame 1: all 3 layers render; skyLayer bakes its Picture once.
        renderFrame();
        expect(_LayerProbe.renderLog, ['sky', 'world', 'weather']);
        expect(skyLayer.pictureBakeCount, 1);

        // Frame 2: skyLayer replays cached Picture -> skyProbe.render NOT
        // called again!
        renderFrame();
        expect(_LayerProbe.renderLog, ['world', 'weather']);
        expect(skyLayer.pictureBakeCount, 1);

        // Minimap mask hiding weather & sky -> only world renders.
        game.camera.layerMask = bitWorld;
        renderFrame();
        expect(_LayerProbe.renderLog, ['world']);

        // Restore mask, drop graphics to low -> weather (minQualityTier: high)
        // is skipped automatically; markLayerDirty re-bakes sky Picture.
        game.camera.layerMask = bitSky | bitWorld | bitWeather;
        game.camera.respectGraphicsRenderScale = false;
        game.graphics.setTier(GraphicsQualityTier.low);
        skyLayer.markLayerDirty();
        game.camera.viewfinder.position = Vector2(100, 0);
        renderFrame();
        expect(_LayerProbe.renderLog, ['sky', 'world']);
        expect(skyLayer.pictureBakeCount, 2);
      },
    );

    test(
      'WorldSpatialIndex matches exact render & hit-test order in O(visible) '
      '(#17)',
      () async {
        final world = World(spatialIndexEnabled: true, spatialCellSize: 128);
        final game = FlameGame(world: world)..onGameResize(Vector2(200, 200));

        // Add 40 off-screen actors and 3 overlapping on-screen actors with
        // distinct (priority, sortKey, mountOrder).
        final offscreenActors = <_SpatialActor>[];
        for (var i = 0; i < 40; i++) {
          final off = _SpatialActor(
            id: 100 + i,
            position: Vector2(2000.0 + i * 80.0, 2000.0),
            size: Vector2.all(24),
          );
          offscreenActors.add(off);
          world.add(off);
        }

        final aBack = _SpatialActor(
          id: 1,
          position: Vector2(-10, -10),
          size: Vector2.all(40),
          priority: 5,
          sortKey: 1.0,
        );
        final aMid = _SpatialActor(
          id: 2,
          position: Vector2(-10, -10),
          size: Vector2.all(40),
          priority: 5,
          sortKey: 2.0,
        );
        final aFront = _SpatialActor(
          id: 3,
          position: Vector2(-10, -10),
          size: Vector2.all(40),
          priority: 8,
        );
        world.addAll([aFront, aMid, aBack]);
        await game.start();

        void renderFrame() {
          _SpatialActor.renderedIds.clear();
          final rec = PictureRecorder();
          game.render(Canvas(rec));
          rec.endRecording().dispose();
        }

        renderFrame();
        expect(_SpatialActor.renderedIds, [1, 2, 3]);
        expect(world.lastSpatialRenderedCount, 3);
        expect(game.camera.lastFrameVisibleCount, 3);
        expect(game.camera.lastFrameCulledCount, 40);
        expect(aBack.wasCulledLastFrame, isFalse);
        expect(offscreenActors.first.wasCulledLastFrame, isTrue);

        // Stationary frame performs ZERO AABB sync passes!
        final syncBefore = world.spatialIndex.syncPassCount;
        renderFrame();
        expect(world.spatialIndex.syncPassCount, syncBefore);

        // Point hit-test returns front-to-back [3, 2, 1].
        final hits = game
            .componentsAtPoint(Vector2(100, 100))
            .whereType<_SpatialActor>()
            .map((e) => e.id)
            .toList();
        expect(hits, [3, 2, 1]);

        // Direct spatial radius query finds the 3 center actors.
        final near = <PositionComponent>[];
        expect(world.querySpatialRadius(Vector2.zero(), 64.0, near), 3);
      },
    );

    test(
      'HasSceneLod selects tiers with hysteresis, lodBias, and auto-cull (#18)',
      () async {
        final game = FlameGame()..onGameResize(Vector2(400, 300));
        final prop = _LodActor(size: Vector2.all(50))
          ..highLodMinPixels = 80.0
          ..mediumLodMinPixels = 40.0
          ..lowLodMinPixels = 16.0
          ..impostorLodMinPixels = 5.0
          ..lodHysteresisRatio = 0.10;
        game.world.add(prop);
        await game.start();

        void renderAtZoom(double zoom) {
          game.camera.viewfinder.zoom = zoom;
          final rec = PictureRecorder();
          game.render(Canvas(rec));
          rec.endRecording().dispose();
        }

        // 50px * zoom 2.0 = 100px >= 80 -> high.
        renderAtZoom(2.0);
        expect(prop.lodLevel, LodLevel.high);
        expect(prop.renderCount, 1);

        // 50px * zoom 1.50 = 75px >= 80 * (1 - 0.10) = 72px -> hysteresis
        // keeps LodLevel.high without popping!
        renderAtZoom(1.50);
        expect(prop.lodLevel, LodLevel.high);

        // 50px * zoom 1.0 = 50px < 72px -> drops to medium.
        renderAtZoom(1.0);
        expect(prop.lodLevel, LodLevel.medium);

        // Extreme zoom-out 0.05 -> 2.5px < 5.0 -> culled (render skipped!).
        final prevRenders = prop.renderCount;
        renderAtZoom(0.05);
        expect(prop.lodLevel, LodLevel.culled);
        expect(prop.renderCount, prevRenders);
      },
    );

    test(
      'OffscreenTickPolicy decimates everyNFrames with exact accumulated dt '
      'and sleeps off-screen actors (#19)',
      () async {
        final game = FlameGame()..onGameResize(Vector2(200, 200));
        final decimated = _SpatialActor(
          id: 10,
          position: Vector2(1500, 1500),
          size: Vector2.all(32),
        )..offscreenTickPolicy = const OffscreenTickPolicy.everyNFrames(4);
        final sleeping = _SpatialActor(
          id: 11,
          position: Vector2(1800, 1800),
          size: Vector2.all(32),
        )..offscreenTickPolicy = OffscreenTickPolicy.sleepWhenOffscreen;

        game.world.addAll([decimated, sleeping]);
        await game.start();
        decimated
          ..updateTicks = 0
          ..totalUpdatedDt = 0.0;
        sleeping
          ..updateTicks = 0
          ..totalUpdatedDt = 0.0;

        // Run 8 off-screen ticks of 0.01s: decimated runs twice (4th & 8th)
        // receiving total 0.08s; sleeping runs 0 times!
        for (var i = 0; i < 8; i++) {
          game.update(0.01);
        }
        expect(decimated.updateTicks, 2);
        expect(decimated.totalUpdatedDt, closeTo(0.08, 1e-6));
        expect(decimated.skippedOffscreenTicks, 6);
        expect(sleeping.updateTicks, 0);
        expect(sleeping.skippedOffscreenTicks, 8);

        // Bring sleeping actor on-screen -> immediately resumes full-rate
        // updates!
        sleeping.position.setValues(0, 0);
        game.update(0.02);
        expect(sleeping.updateTicks, 1);
        expect(sleeping.totalUpdatedDt, closeTo(0.02, 1e-6));
      },
    );
  });
}
