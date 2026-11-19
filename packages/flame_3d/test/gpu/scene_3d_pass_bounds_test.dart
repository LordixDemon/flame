import 'dart:ui';

import 'package:flame/components.dart' show World;
import 'package:flame/game.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/widgets.dart' show GlobalKey, RepaintBoundary;
import 'package:flutter_test/flutter_test.dart';

import 'gpu_test_helpers.dart';

/// A layer whose scene is a red floor much larger than the 128x128 view.
Scene3DComponent _floorLayer() {
  final layer = Scene3DComponent(
    projection: Scene3DProjection.affine(
      origin: Vector2(64, 64),
      xAxis: Vector2(16, 0),
      yAxis: Vector2(0, 16),
      zAxis: Vector2(0, -16),
      towardsViewer: Vector3(0, 0, 1),
      near: -50,
      far: 50,
    ),
  );
  layer.world.add(
    MeshComponent(
      mesh: CuboidMesh(
        size: Vector3(40, 40, 0.1),
        material: UnlitMaterial(albedoColor: const Color(0xFFE02020)),
      ),
    ),
  );
  return layer;
}

Future<Pixels> _render(WidgetTester tester, Scene3DComponent layer) async {
  final game = FlameGame(world: World(children: [layer]));
  game.camera.viewfinder.position = Vector2(64, 64);
  tester.view
    ..physicalSize = const Size(128, 128)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final key = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: key,
      child: GameWidget(game: game),
    ),
  );
  await tester.pump(const Duration(milliseconds: 16));
  await tester.pump(const Duration(milliseconds: 16));
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  return (await tester.runAsync(() async {
    final image = await boundary.toImage();
    final data = await image.toByteData();
    final out = Pixels(image.width, image.height, data!.buffer.asUint8List());
    image.dispose();
    return out;
  }))!;
}

bool _red(int r, int g, int b, int a) => r > 180 && g < 90 && b < 90;

bool _redAt(Pixels pixels, int x, int y) {
  final (r, g, b, a) = pixels.at(x, y);
  return _red(r, g, b, a);
}

void main() {
  setUpGpu();

  group('Scene3DComponent pass bounds', () {
    testGpu('visibleRect bounds the pass to a local rectangle', (
      tester,
    ) async {
      final layer = _floorLayer()
        ..visibleRect = const Rect.fromLTWH(32, 40, 40, 30);
      final pixels = await _render(tester, layer);

      expect(pixels.count(_red), 40 * 30);
      expect(_redAt(pixels, 31, 50), isFalse);
      expect(_redAt(pixels, 72, 50), isFalse);
      expect(_redAt(pixels, 32, 40), isTrue);
      expect(layer.renderedRect, const Rect.fromLTWH(32, 40, 40, 30));
    });

    testGpu('visibleRect follows a rotated layer', (tester) async {
      final layer = _floorLayer()
        ..position = Vector2(64, 64)
        ..angle = 0.5
        ..visibleRect = const Rect.fromLTWH(-20, -15, 40, 30);
      final pixels = await _render(tester, layer);

      // The rotated rectangle keeps its area, give or take its edges.
      expect(pixels.count(_red), closeTo(40 * 30, 150));
      expect(_redAt(pixels, 64, 64), isTrue);
      // Corners of the unrotated rectangle fall outside the rotated one.
      expect(_redAt(pixels, 45, 50), isFalse);
    });

    testGpu('visibleSceneBounds bounds the pass to the picture of a box', (
      tester,
    ) async {
      // From x, y = -1 to 1 in the scene: 32 by 32 pixels around the
      // centre.
      final layer = _floorLayer()
        ..visibleSceneBounds = Aabb3.minMax(
          Vector3(-1, -1, -1),
          Vector3(1, 1, 1),
        );
      final pixels = await _render(tester, layer);

      // The box's picture spans 32 + 32 (its height along z) by 32 pixels.
      expect(pixels.count(_red), greaterThan(32 * 32 - 64));
      expect(pixels.count(_red), lessThanOrEqualTo(32 * 64));
      expect(_redAt(pixels, 10, 10), isFalse);
      expect(_redAt(pixels, 120, 64), isFalse);
    });
  });
}
