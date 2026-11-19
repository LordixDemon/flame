import 'dart:ui' as ui;

import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flame/post_process.dart';
import 'package:flame/rendering.dart';
import 'package:flame_test/flame_test.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records [RasterScale.current] and the scale of the canvas transform each
/// time it renders.
class _Probe() extends PositionComponent {
  this : super(size: Vector2.all(10));

  final List<double?> scales = [];
  final List<double> canvasScales = [];
  final List<ui.Rect> clips = [];

  @override
  void render(ui.Canvas canvas) {
    scales.add(RasterScale.current);
    canvasScales.add(canvas.getTransform()[0]);
    clips.add(canvas.getDestinationClipBounds());
  }
}

class _Rasterizing({super.pixelRatio}) extends PostProcess {
  @override
  void postProcess(Vector2 size, ui.Canvas canvas) {
    final image = rasterizeSubtree();
    canvas.drawImage(image, ui.Offset.zero, ui.Paint());
    image.dispose();
  }
}

class _RasterizingPass({super.pixelRatio}) extends PostProcess {
  @override
  void postProcess(Vector2 size, ui.Canvas canvas) {
    rasterizePass(resolutionScale: 0.5).dispose();
  }
}

void _renderFrame(FlameGame game) {
  final recorder = ui.PictureRecorder();
  game.render(ui.Canvas(recorder));
  recorder.endRecording().dispose();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('RasterScale', () {
    test('a stack of the scales pushed', () {
      expect(RasterScale.isActive, isFalse);
      expect(RasterScale.current, isNull);
      RasterScale.push(2);
      RasterScale.push(0.5);
      expect(RasterScale.isActive, isTrue);
      expect(RasterScale.depth, 2);
      expect(RasterScale.current, 0.5);
      RasterScale.pop();
      expect(RasterScale.current, 2);
      RasterScale.pop();
      expect(RasterScale.isActive, isFalse);
      expect(RasterScale.pop, throwsAssertionError);
      expect(() => RasterScale.push(0), throwsAssertionError);
      expect(() => RasterScale.push(double.infinity), throwsAssertionError);
    });

    test('rasterizeSubtree pushes its pixel ratio, renderSubtree does not', () {
      final probe = _Probe();
      final rasterizing = _Rasterizing(pixelRatio: 3);
      rasterizing.render(
        ui.Canvas(ui.PictureRecorder()),
        Vector2(20, 20),
        probe.render,
        (_) {},
      );
      expect(probe.scales, [3.0]);
      expect(probe.canvasScales, [3.0]);
      // The canvas is clipped to the image, in its pixels.
      expect(probe.clips.single, const ui.Rect.fromLTWH(0, 0, 60, 60));
      expect(RasterScale.isActive, isFalse);

      final direct = _DirectPostProcess();
      direct.render(
        ui.Canvas(ui.PictureRecorder()),
        Vector2(20, 20),
        probe.render,
        (_) {},
      );
      expect(probe.scales, [3.0, null]);
    });

    test('rasterizePass pushes the scale it rasterizes at', () {
      final probe = _Probe();
      _RasterizingPass(pixelRatio: 2).render(
        ui.Canvas(ui.PictureRecorder()),
        Vector2(20, 20),
        probe.render,
        (_) {},
      );
      expect(probe.scales, [1.0]);
      expect(probe.canvasScales, [1.0]);
      expect(probe.clips.single, const ui.Rect.fromLTWH(0, 0, 20, 20));
    });

    test('the scale is popped when the subtree throws', () {
      expect(
        () => _Rasterizing(pixelRatio: 2).render(
          ui.Canvas(ui.PictureRecorder()),
          Vector2(20, 20),
          (_) => throw StateError('broken'),
          (_) {},
        ),
        throwsStateError,
      );
      expect(RasterScale.isActive, isFalse);
    });

    testWithFlameGame('a world on screen sees no raster scale', (game) async {
      game.onGameResize(Vector2(200, 100));
      final probe = _Probe();
      await game.world.ensureAdd(probe);
      _renderFrame(game);
      expect(probe.scales, [null]);
    });

    testWithFlameGame('the scaled offscreen world pushes its scale', (
      game,
    ) async {
      game.onGameResize(Vector2(200, 100));
      game.overrideDisplayMetrics(devicePixelRatio: 2.0);
      final probe = _Probe();
      await game.world.ensureAdd(probe);
      game.camera
        ..respectGraphicsRenderScale = false
        ..worldRenderScale = 0.5;
      _renderFrame(game);
      expect(game.camera.lastWorldSurfaceWidth, 200);
      expect(probe.scales.single, 1.0);
      expect(probe.canvasScales.single, 1.0);
      expect(probe.clips.single, const ui.Rect.fromLTWH(0, 0, 200, 100));
      expect(RasterScale.isActive, isFalse);
    });

    testWithFlameGame('a camera post process pushes its pixel ratio', (
      game,
    ) async {
      game.onGameResize(Vector2(200, 100));
      game.overrideDisplayMetrics(devicePixelRatio: 2.0);
      final probe = _Probe();
      await game.world.ensureAdd(probe);
      game.camera.postProcess = _Rasterizing(pixelRatio: 2);
      await game.ready();
      _renderFrame(game);
      expect(probe.scales.single, 2.0);
      expect(probe.canvasScales.single, 2.0);
      expect(probe.clips.single, const ui.Rect.fromLTWH(0, 0, 400, 200));
    });

    testWithFlameGame('renderToImageSync pushes its pixel ratio', (
      game,
    ) async {
      game.onGameResize(Vector2(200, 100));
      final probe = _Probe();
      await game.world.ensureAdd(probe);
      game.camera.renderToImageSync(pixelRatio: 1.5).dispose();
      expect(probe.scales.single, 1.5);
      expect(probe.canvasScales.single, 1.5);
      // With a post process that rasterizes, the innermost picture counts.
      game.camera.postProcess = _Rasterizing(pixelRatio: 3);
      await game.ready();
      game.camera.renderToImageSync(pixelRatio: 1.5).dispose();
      expect(probe.scales.last, 3.0);
      expect(RasterScale.isActive, isFalse);
    });

    testWithFlameGame('high resolution tiles push their scale', (game) async {
      game.onGameResize(Vector2(200, 100));
      final probe = _Probe();
      await game.world.ensureAdd(probe);
      game.camera
          .renderHighResImageSync(width: 400, height: 200, tileSize: 256)
          .dispose();
      expect(probe.scales, isNotEmpty);
      expect(probe.scales, everyElement(2.0));
    });
  });
}

class _DirectPostProcess() extends PostProcess;
