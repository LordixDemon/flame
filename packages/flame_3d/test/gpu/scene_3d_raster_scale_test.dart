import 'dart:ui';

import 'package:flame/components.dart' show RectangleComponent, World;
import 'package:flame/game.dart';
import 'package:flame/post_process.dart';
import 'package:flame/rendering.dart' show RasterScale;
import 'package:flame_3d/components.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/widgets.dart' show GlobalKey, RepaintBoundary;
import 'package:flutter_test/flutter_test.dart';

import 'gpu_test_helpers.dart';

const _width = 160.0;
const _height = 120.0;
const _pixelRatio = 2.0;

/// Rasterizes the world with `rasterizeSubtree`, which tells the components
/// they draw into a picture of [pixelRatio] pixels per logical pixel, and
/// draws the image back unfiltered.
class _Rasterizing() extends PostProcess {
  this : super(pixelRatio: _pixelRatio);

  final Paint _paint = Paint()..filterQuality = FilterQuality.none;

  @override
  void postProcess(Vector2 size, Canvas canvas) {
    final image = rasterizeSubtree();
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Offset.zero & size.toSize(),
      _paint,
    );
    image.dispose();
  }
}

/// Rasterizes the world as `rasterizeSubtree` does (a picture scaled by
/// [pixelRatio] and clipped to the image) without telling the components:
/// what `rasterizeSubtree` did before `RasterScale`, and what a post process
/// of a game's own may still do.
class _RasterizingUnannounced() extends PostProcess {
  this : super(pixelRatio: _pixelRatio);

  final Paint _paint = Paint()..filterQuality = FilterQuality.none;

  @override
  void postProcess(Vector2 size, Canvas canvas) {
    final width = (size.x * pixelRatio).ceil();
    final height = (size.y * pixelRatio).ceil();
    final recorder = PictureRecorder();
    final inner = Canvas(recorder)
      ..clipRect(Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()))
      ..scale(pixelRatio);
    renderSubtree(inner);
    final picture = recorder.endRecording();
    final image = picture.toImageSync(width, height);
    picture.dispose();
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Offset.zero & size.toSize(),
      _paint,
    );
    image.dispose();
  }
}

/// Rasterizes the world as `rasterizeSubtree` does, without telling the
/// components and without clipping the picture's canvas: what
/// `rasterizeSubtree` did before `RasterScale`.
class _RasterizingUnannouncedUnclipped() extends PostProcess {
  this : super(pixelRatio: _pixelRatio);

  final Paint _paint = Paint()..filterQuality = FilterQuality.none;

  @override
  void postProcess(Vector2 size, Canvas canvas) {
    final recorder = PictureRecorder();
    final inner = Canvas(recorder)..scale(pixelRatio);
    renderSubtree(inner);
    final picture = recorder.endRecording();
    final image = picture.toImageSync(
      (size.x * pixelRatio).ceil(),
      (size.y * pixelRatio).ceil(),
    );
    picture.dispose();
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Offset.zero & size.toSize(),
      _paint,
    );
    image.dispose();
  }
}

/// Rasterizes the world into a picture scaled by [pixelRatio] whose canvas
/// it does not clip, announcing the scale with `RasterScale`: a renderer of a
/// game's own that forgets the clip.
class _RasterizingAnnouncedUnclipped() extends PostProcess {
  this : super(pixelRatio: _pixelRatio);

  final Paint _paint = Paint()..filterQuality = FilterQuality.none;

  @override
  void postProcess(Vector2 size, Canvas canvas) {
    final recorder = PictureRecorder();
    final inner = Canvas(recorder)..scale(pixelRatio);
    RasterScale.push(pixelRatio);
    try {
      renderSubtree(inner);
    } finally {
      RasterScale.pop();
    }
    final picture = recorder.endRecording();
    final image = picture.toImageSync(
      (size.x * pixelRatio).ceil(),
      (size.y * pixelRatio).ceil(),
    );
    picture.dispose();
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Offset.zero & size.toSize(),
      _paint,
    );
    image.dispose();
  }
}

/// A 2D backdrop and a retained layer showing a lit, turned cube with hard
/// edges, whose pixels depend on the resolution the layer renders at, and
/// with `grid`, small cubes across the whole view (and no caching).
class _Scene({
  PostProcess? postProcess,
  double renderScale = 1,
  bool grid = false,
}) {
  this {
    // A layer that renders every frame keeps the statistics of a pass.
    if (grid) {
      layer.cacheMode = Scene3DCacheMode.none;
    }
    if (grid) {
      final mesh = CuboidMesh(
        size: Vector3.all(0.3),
        material: SpatialMaterial(albedoColor: const Color(0xFF60D060)),
      );
      for (var i = -2.0; i <= 6; i += 0.5) {
        for (var j = -2.0; j <= 6; j += 0.5) {
          layer.world.add(
            MeshComponent(mesh: mesh, position: Vector3(i, j, 0.15)),
          );
        }
      }
    }
    layer.world.addAll([
      LightComponent.ambient(intensity: 0.3),
      LightComponent.directional(direction: Vector3(-0.4, -0.7, -1)),
      MeshComponent(
        mesh: CuboidMesh(
          size: Vector3.all(1.4),
          material: SpatialMaterial(
            albedoColor: const Color(0xFFC08040),
            roughness: 0.4,
          ),
        ),
        position: Vector3(2, 2, 0.7),
        rotation: Quaternion.axisAngle(Vector3(0, 0, 1), 0.37),
      ),
    ]);
    layer.renderScale = renderScale;
    game = FlameGame(
      world: World(
        children: [
          RectangleComponent(
            position: Vector2.all(-500),
            size: Vector2.all(1000),
            paint: Paint()..color = const Color(0xFF406080),
          ),
          layer,
        ],
      ),
    );
    game.camera.viewfinder
      ..position = layer.scenePointToLocal(Vector3(2, 2, 0.7))
      ..zoom = 0.6
      ..angle = 0.2;
    if (postProcess != null) {
      game.camera.postProcess = postProcess;
    }
  }

  final Scene3DComponent layer = Scene3DComponent(
    projection: Scene3DProjection.affine(
      origin: Vector2(0, -18),
      xAxis: Vector2(44, 22),
      yAxis: Vector2(-44, 22),
      zAxis: Vector2(0, -53.889),
      towardsViewer: Vector3(0.6124, 0.6124, 0.5),
      near: -100,
      far: 100,
    ),
    cacheMode: Scene3DCacheMode.retained,
  );
  late final FlameGame game;

  /// The width of the render target of the layer's last render.
  int get targetWidth => layer.debugRetainedTarget!.width;

  Future<Pixels> render(WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(_width, _height)
      ..devicePixelRatio = _pixelRatio;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: GameWidget(game: game),
      ),
    );
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    return (await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: _pixelRatio);
      final pixels = await readImage(image);
      image.dispose();
      return pixels;
    }))!;
  }
}

/// The number of pixels that are not the backdrop's.
int _cubePixels(Pixels pixels) => pixels.count(
  (r, g, b, a) => (r - 0x40).abs() + (g - 0x60).abs() + (b - 0x80).abs() > 30,
);

void main() {
  setUpGpu();

  group('a Scene3DComponent under a rasterizing post process', () {
    testGpu('renders as with the manual renderScale correction', (
      tester,
    ) async {
      // The correction callers made by hand: renderScale / devicePixelRatio
      // under a post process that does not announce its raster scale.
      final manual = _Scene(
        postProcess: _RasterizingUnannounced(),
        renderScale: 1 / _pixelRatio,
      );
      final manualPixels = await manual.render(tester);
      // Detected: rasterizeSubtree announces its scale, and the layer keeps
      // its renderScale of 1.
      final detected = _Scene(postProcess: _Rasterizing());
      final detectedPixels = await detected.render(tester);

      expect(detected.targetWidth, manual.targetWidth);
      expect(differingPixels(manualPixels, detectedPixels, tolerance: 0), 0);
      // The cube is in the picture.
      expect(_cubePixels(detectedPixels), greaterThan(1000));
    });

    testGpu('renders at the resolution of the screen, as without it', (
      tester,
    ) async {
      final direct = _Scene();
      final directPixels = await direct.render(tester);
      final rasterized = _Scene(postProcess: _Rasterizing());
      final rasterizedPixels = await rasterized.render(tester);
      expect(rasterized.targetWidth, direct.targetWidth);
      expect(
        differingPixels(directPixels, rasterizedPixels, tolerance: 0),
        0,
      );
      expect(_cubePixels(directPixels), greaterThan(1000));

      // Without the announcement, the layer renders at twice the needed
      // resolution in each direction.
      final unannounced = _Scene(postProcess: _RasterizingUnannounced());
      await unannounced.render(tester);
      expect(
        unannounced.targetWidth,
        closeTo(2 * direct.targetWidth, 64),
      );
    });

    testGpu('a camera with a worldRenderScale renders the layer at it', (
      tester,
    ) async {
      // A world render scale of 0.5 at a device pixel ratio of 2 rasterizes
      // the world at 1 pixel per logical pixel: the layer renders as at a
      // device pixel ratio of 1 with renderScale 1.
      final scaled = _Scene();
      scaled.game.camera
        ..respectGraphicsRenderScale = false
        ..worldRenderScale = 0.5;
      final scaledPixels = await scaled.render(tester);
      expect(scaled.game.camera.lastWorldSurfaceWidth, _width ~/ 2);
      // The layer covers the 80 by 60 pixels of the surface.
      expect(scaled.layer.renderedRect, const Rect.fromLTWH(0, 0, 80, 60));
      expect(scaled.targetWidth, 128);
      expect(_cubePixels(scaledPixels), greaterThan(1000));
    });

    group('without a clip of its own', () {
      // Each frame draws the cubes of the grid it does not cull: the
      // number of triangles tells how much of the scene the pass covers.
      testGpu('the whole visible scene is drawn, as with the manual fix', (
        tester,
      ) async {
        final direct = _Scene(grid: true);
        final directPixels = await direct.render(tester);
        final drawn = direct.layer.renderStats.triangles;
        expect(drawn, greaterThan(60));

        // rasterizeSubtree: the layer keeps renderScale 1, no clip needed.
        final detected = _Scene(grid: true, postProcess: _Rasterizing());
        final detectedPixels = await detected.render(tester);
        expect(detected.layer.renderStats.triangles, drawn);
        expect(
          detected.layer.renderedRect,
          const Rect.fromLTWH(0, 0, _width, _height),
        );

        // What callers did by hand: a clip to the picture and renderScale
        // divided by the device pixel ratio.
        final manual = _Scene(
          grid: true,
          postProcess: _RasterizingUnannounced(),
          renderScale: 1 / _pixelRatio,
        );
        final manualPixels = await manual.render(tester);
        expect(manual.layer.renderStats.triangles, drawn);
        expect(
          differingPixels(manualPixels, detectedPixels, tolerance: 0),
          0,
        );
        expect(differingPixels(directPixels, detectedPixels, tolerance: 0), 0);

        // Before RasterScale, without the clip: the pass was bounded by the
        // game's logical size taken in the picture's pixels, a quarter of
        // the view.
        final unclipped = _Scene(
          grid: true,
          postProcess: _RasterizingUnannouncedUnclipped(),
          renderScale: 1 / _pixelRatio,
        );
        await unclipped.render(tester);
        expect(unclipped.layer.renderStats.triangles, lessThan(drawn));
        expect(
          unclipped.layer.renderedRect,
          const Rect.fromLTWH(0, 0, _width / 2, _height / 2),
        );
      });

      testGpu('a renderer that announces its scale needs no clip', (
        tester,
      ) async {
        final detected = _Scene(grid: true, postProcess: _Rasterizing());
        final detectedPixels = await detected.render(tester);
        final announced = _Scene(
          grid: true,
          postProcess: _RasterizingAnnouncedUnclipped(),
        );
        final announcedPixels = await announced.render(tester);
        expect(
          announced.layer.renderStats.triangles,
          detected.layer.renderStats.triangles,
        );
        expect(
          differingPixels(announcedPixels, detectedPixels, tolerance: 0),
          0,
        );
      });

      testGpu('visibleRect narrows the pass, and bounds it within the view', (
        tester,
      ) async {
        final whole = _Scene(grid: true, postProcess: _Rasterizing());
        await whole.render(tester);
        final drawn = whole.layer.renderStats.triangles;

        // A visibleRect larger than the view changes nothing.
        final large = _Scene(grid: true, postProcess: _Rasterizing());
        large.layer.visibleRect = const Rect.fromLTWH(-1000, -1000, 2000, 2000);
        await large.render(tester);
        expect(large.layer.renderStats.triangles, drawn);
        expect(
          large.layer.renderedRect,
          const Rect.fromLTWH(0, 0, _width, _height),
        );

        // One around the cube at (2, 2) narrows the pass to its picture.
        final narrow = _Scene(grid: true, postProcess: _Rasterizing());
        final center = narrow.layer.scenePointToLocal(Vector3(2, 2, 0.7));
        narrow.layer.visibleRect = Rect.fromCenter(
          center: Offset(center.x, center.y),
          width: 60,
          height: 40,
        );
        final narrowPixels = await narrow.render(tester);
        expect(narrow.layer.renderStats.triangles, lessThan(drawn));
        expect(narrow.layer.renderedRect.width, lessThan(_width));
        expect(_cubePixels(narrowPixels), greaterThan(500));
      });
    });
  });
}
