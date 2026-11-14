import 'dart:ui' as ui;

import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flame/post_process.dart';
import 'package:flutter_test/flutter_test.dart';

class _MetricsProbeGame() extends FlameGame {
  int metricsChangeCount = 0;
  double lastDpr = 0;
  double lastHz = 0;

  @override
  void onDisplayMetricsChanged(double devicePixelRatio, double refreshRate) {
    super.onDisplayMetricsChanged(devicePixelRatio, refreshRate);
    metricsChangeCount++;
    lastDpr = devicePixelRatio;
    lastHz = refreshRate;
  }
}

class _TransformProbeComponent({super.size}) extends PositionComponent {
  double? lastCanvasTx;
  double? lastCanvasTy;
  double? lastScaleX;

  @override
  void render(ui.Canvas canvas) {
    final m = canvas.getTransform();
    lastScaleX = m[0];
    lastCanvasTx = m[12];
    lastCanvasTy = m[13];
    canvas.drawRect(
      size.toRect(),
      ui.Paint()..color = const ui.Color(0xFF42A5F5),
    );
  }
}

class _SnapshotBox({super.size}) extends PositionComponent with Snapshot {
  @override
  void render(ui.Canvas canvas) {
    canvas.drawRect(
      size.toRect(),
      ui.Paint()..color = const ui.Color(0xFFFF7043),
    );
  }
}

void main() {
  group('HiDPI DisplayMetrics, worldRenderScale, Snapshot & PixelSnap', () {
    test('DisplayMetrics & Game DPR cap and override hooks (#1)', () {
      const m1 = DisplayMetrics(
        devicePixelRatio: 2.0,
        physicalSize: ui.Size(2560, 1600),
        refreshRate: 120.0,
      );
      expect(m1.logicalSize, const ui.Size(1280, 800));

      final game = _MetricsProbeGame()..onGameResize(Vector2(800, 600));
      game.maxDevicePixelRatio = 2.0;
      game.overrideDisplayMetrics(devicePixelRatio: 3.0, refreshRate: 144.0);

      expect(game.rawDevicePixelRatio, 3.0);
      expect(game.devicePixelRatio, 2.0);
      expect(game.displayRefreshRate, 144.0);
      expect(game.physicalCanvasSize, Vector2(1600, 1200));
      expect(game.metricsChangeCount, 1);
      expect(game.lastDpr, 2.0);
      expect(game.lastHz, 144.0);
    });

    testWidgets(
      'GameRenderBox syncs live FlutterView DPR on didChangeMetrics (#1)',
      (tester) async {
        tester.view.devicePixelRatio = 2.0;
        addTearDown(tester.view.resetDevicePixelRatio);

        final game = _MetricsProbeGame();
        game.graphics.setCustomProfile(
          const GraphicsProfile(maxDevicePixelRatio: 4.0),
        );

        await tester.pumpWidget(GameWidget(game: game));
        await tester.pump();
        expect(game.devicePixelRatio, 2.0);

        tester.view.devicePixelRatio = 3.0;
        tester.binding.handleMetricsChanged();
        await tester.pump();

        expect(game.rawDevicePixelRatio, 3.0);
        expect(game.devicePixelRatio, 3.0);
        expect(game.metricsChangeCount, greaterThanOrEqualTo(1));
      },
    );

    test(
      'CameraComponent.worldRenderScale scales world while keeping HUD 1:1 '
      '(#2)',
      () async {
        final game = FlameGame()..onGameResize(Vector2(400, 300));
        game.overrideDisplayMetrics(devicePixelRatio: 2.0);
        final worldProbe = _TransformProbeComponent(size: Vector2.all(40));
        final hudProbe = _TransformProbeComponent(size: Vector2.all(20));
        game.world.add(worldProbe);
        game.camera.viewport.add(hudProbe);
        await game.start();

        // 0.5x upscale on 2.0 DPR -> 400 * 2.0 * 0.5 = 400x300 surface.
        game.camera.worldRenderScale = 0.5;
        game.camera.upscaleSharpness = 0.4;
        {
          final recorder = ui.PictureRecorder();
          game.render(ui.Canvas(recorder));
          recorder.endRecording().dispose();
        }
        expect(game.camera.lastWorldSurfaceWidth, 400);
        expect(game.camera.lastWorldSurfaceHeight, 300);
        expect(game.camera.offscreenWorldRenderCount, 1);
        expect(hudProbe.lastScaleX, closeTo(1.0, 1e-5));

        // 1.5x SSAA on 2.0 DPR -> 400 * 2.0 * 1.5 = 1200x900 surface.
        game.camera.worldRenderScale = 1.5;
        {
          final recorder = ui.PictureRecorder();
          game.render(ui.Canvas(recorder));
          recorder.endRecording().dispose();
        }
        expect(game.camera.lastWorldSurfaceWidth, 1200);
        expect(game.camera.lastWorldSurfaceHeight, 900);
        expect(game.camera.offscreenWorldRenderCount, 2);
        expect(hudProbe.lastScaleX, closeTo(1.0, 1e-5));
      },
    );

    test(
      'SnapshotResolutionPolicy autoHiDpiAndZoom quantizes zoom with '
      'hysteresis and max dimension cap (#3)',
      () async {
        final game = FlameGame()..onGameResize(Vector2(400, 300));
        game.overrideDisplayMetrics(devicePixelRatio: 2.0);
        final snap = _SnapshotBox(size: Vector2(100, 100))
          ..snapshotCacheMode = SnapshotCacheMode.rasterImage
          ..snapshotResolutionPolicy =
              SnapshotResolutionPolicy.autoHiDpiAndZoom;
        game.world.add(snap);
        await game.start();

        void renderOnce() {
          final recorder = ui.PictureRecorder();
          game.render(ui.Canvas(recorder));
          recorder.endRecording().dispose();
        }

        // Initial zoom 1.0 * DPR 2.0 -> 200x200 texture, bake #1.
        renderOnce();
        expect(snap.activeZoomBucket, 1.0);
        expect(snap.snapshotRasterBakeCount, 1);
        expect(snap.cachedSnapshotImage!.width, 200);

        // Small zoom jitter within 12% hysteresis of 1.5 bucket (1.5 * 1.12 =
        // 1.68) does NOT trigger a rebake!
        game.camera.viewfinder.zoom = 1.55;
        renderOnce();
        expect(snap.activeZoomBucket, 1.0);
        expect(snap.snapshotRasterBakeCount, 1);

        // Crossing hysteresis threshold (1.75 >= 1.68) upgrades to 1.5 bucket!
        game.camera.viewfinder.zoom = 1.75;
        renderOnce();
        expect(snap.activeZoomBucket, 1.5);
        expect(snap.snapshotRasterBakeCount, 2);
        expect(snap.cachedSnapshotImage!.width, 300);

        // Slight zoom drop to 1.40 stays in 1.5 bucket (1.5 * 0.88 = 1.32).
        game.camera.viewfinder.zoom = 1.40;
        renderOnce();
        expect(snap.activeZoomBucket, 1.5);
        expect(snap.snapshotRasterBakeCount, 2);

        // Texture dimension safety ceiling clamps oversized snapshots.
        snap.maxSnapshotTextureDimension = 256;
        game.camera.viewfinder.zoom = 3.5;
        renderOnce();
        expect(snap.cachedSnapshotImage!.width, 256);
        expect(snap.cachedSnapshotImage!.height, 256);
      },
    );

    test(
      'PixelSnapMode snaps rendered translation without mutating '
      'viewfinder.position (#4)',
      () async {
        final game = FlameGame()..onGameResize(Vector2(400, 300));
        game.overrideDisplayMetrics(devicePixelRatio: 2.0);
        final probe = _TransformProbeComponent(size: Vector2.all(16));
        game.world.add(probe);
        await game.start();

        game.camera.viewfinder.position = Vector2(10.33, -4.19);
        game.camera.pixelSnapMode = PixelSnapMode.physicalPixel;
        {
          final recorder = ui.PictureRecorder();
          game.render(ui.Canvas(recorder));
          recorder.endRecording().dispose();
        }

        // Logical position is untouched; rendered translation lands on 0.5px
        // physical steps (since DPR = 2.0 -> 2 * tx is an exact integer).
        expect(game.camera.viewfinder.position.x, closeTo(10.33, 1e-6));
        expect(game.camera.viewfinder.position.y, closeTo(-4.19, 1e-6));
        final doubledTx = probe.lastCanvasTx! * 2.0;
        final doubledTy = probe.lastCanvasTy! * 2.0;
        expect((doubledTx - doubledTx.round()).abs(), lessThan(1e-4));
        expect((doubledTy - doubledTy.round()).abs(), lessThan(1e-4));

        game.camera.pixelSnapMode = PixelSnapMode.logicalPixel;
        {
          final recorder = ui.PictureRecorder();
          game.render(ui.Canvas(recorder));
          recorder.endRecording().dispose();
        }
        expect(
          (probe.lastCanvasTx! - probe.lastCanvasTx!.round()).abs(),
          lessThan(1e-4),
        );
      },
    );

    test(
      'ContrastAdaptiveSharpenPostProcess & tiled renderHighResImageSync (#5)',
      () async {
        final game = FlameGame()..onGameResize(Vector2(320, 180));
        game.world.add(
          RectangleComponent(
            position: Vector2(-80, -40),
            size: Vector2(160, 80),
            paint: ui.Paint()..color = const ui.Color(0xFF26A69A),
          ),
        );
        game.camera.postProcess = ContrastAdaptiveSharpenPostProcess(
          strength: 0.5,
        );
        await game.start();

        final recorder = ui.PictureRecorder();
        game.render(ui.Canvas(recorder));
        recorder.endRecording().dispose();

        // Tiled 2400x1200 export with tileSize 1024 -> 3 x 2 = 6 tiles.
        final exported = game.camera.renderHighResImageSync(
          width: 2400,
          height: 1200,
          tileSize: 1024,
          backgroundColor: const ui.Color(0xFF10141C),
        );
        try {
          expect(exported.width, 2400);
          expect(exported.height, 1200);
          expect(game.camera.lastHighResTileCount, 6);
        } finally {
          exported.dispose();
        }
      },
    );
  });
}
