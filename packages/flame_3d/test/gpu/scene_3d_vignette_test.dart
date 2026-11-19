import 'dart:ui';

import 'package:flame/components.dart' show World;
import 'package:flame/game.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/widgets.dart' show GlobalKey, RepaintBoundary;
import 'package:flutter_test/flutter_test.dart';

import 'gpu_test_helpers.dart';

// A view whose size is not a multiple of the 64 pixels the render targets
// of a layer are rounded up to.
const _width = 100;
const _height = 70;

/// A layer showing a white panel facing the viewer, from x = [left] to
/// [right] in scene units of 10 logical pixels, across the whole height of
/// the view, with a strong vignette.
Future<Pixels> _render(
  WidgetTester tester, {
  double left = -5,
  double right = 15,
  Rect? visibleRect,
}) async {
  final layer = Scene3DComponent(
    projection: Scene3DProjection.affine(
      origin: Vector2.zero(),
      xAxis: Vector2(10, 0),
      yAxis: Vector2(0, 10),
      zAxis: Vector2.zero(),
      towardsViewer: Vector3(0, 0, -1),
      near: -10,
      far: 10,
    ),
    postProcess: PostProcessSettings(
      vignetteIntensity: 0.9,
      vignetteSmoothness: 0.6,
    ),
  )..visibleRect = visibleRect;
  layer.world.add(
    MeshComponent(
      mesh: CuboidMesh(
        size: Vector3(right - left, 20, 0.02),
        material: opaqueUnlit(const Color(0xFFFFFFFF)),
      ),
      position: Vector3((left + right) / 2, 3.5, 0),
    ),
  );
  final game = FlameGame(world: World(children: [layer]));
  // The world's origin at the top left of the view.
  game.camera.viewfinder.position = Vector2(_width / 2, _height / 2);

  tester.view
    ..physicalSize = Size(_width.toDouble(), _height.toDouble())
    ..devicePixelRatio = 1;
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
    final image = await boundary.toImage();
    final pixels = await readImage(image);
    image.dispose();
    return pixels;
  }))!;
}

int _red(Pixels pixels, int x, int y) => pixels.at(x, y).$1;

void main() {
  setUpGpu();

  group('the vignette of a Scene3DComponent', () {
    testGpu('is centered on the view, not on the render target', (
      tester,
    ) async {
      final pixels = await _render(tester);
      const midX = _width ~/ 2;
      const midY = _height ~/ 2;
      expect(_red(pixels, midX, midY), greaterThan(250));
      // Opposite edges darken alike.
      expect(
        _red(pixels, 1, midY),
        closeTo(_red(pixels, _width - 2, midY), 2),
      );
      expect(
        _red(pixels, midX, 1),
        closeTo(_red(pixels, midX, _height - 2), 2),
      );
      expect(
        _red(pixels, 1, 1),
        closeTo(_red(pixels, _width - 2, _height - 2), 2),
      );
      expect(_red(pixels, 1, 1), lessThan(_red(pixels, 1, midY) - 20));
    });

    testGpu('does not follow the part of the view the scene covers', (
      tester,
    ) async {
      final full = await _render(tester);
      // The panel covers only the left half of the view: the layer renders
      // that half, and the vignette stays centered on the whole view.
      final half = await _render(tester, right: 5);
      for (var y = 0; y < _height; y += 3) {
        for (var x = 0; x < 45; x += 3) {
          expect(
            _red(half, x, y),
            closeTo(_red(full, x, y), 1),
            reason: 'at ($x, $y)',
          );
        }
      }
    });

    testGpu('is centered on the visibleRect of the layer', (tester) async {
      // The layer shows the right 60 by 40 pixels from (40, 30).
      final pixels = await _render(
        tester,
        visibleRect: const Rect.fromLTWH(40, 30, 60, 40),
      );
      expect(_red(pixels, 70, 50), greaterThan(250));
      expect(_red(pixels, 41, 50), closeTo(_red(pixels, 98, 50), 2));
      expect(_red(pixels, 70, 31), closeTo(_red(pixels, 70, 68), 2));
      // Outside the rectangle, the game's black background shows.
      expect(_red(pixels, 20, 20), 0);
    });
  });
}
