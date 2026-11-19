import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/components.dart' show RectangleComponent, World;
import 'package:flame/game.dart';
import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/widgets.dart' show GlobalKey, RepaintBoundary;
import 'package:flutter_test/flutter_test.dart';

import 'gpu_test_helpers.dart';

const _width = 320.0;
const _height = 240.0;
const _ground2D = Color(0xFF808080);

/// The projection of dimetric 2D art: scene points (i, j, z), z up.
Scene3DProjection _boardProjection() {
  return Scene3DProjection.affine(
    origin: Vector2(0, -18),
    xAxis: Vector2(44, 22),
    yAxis: Vector2(-44, 22),
    zAxis: Vector2(0, -53.889),
    towardsViewer: Vector3(0.6124, 0.6124, 0.5),
    near: -100,
    far: 100,
  );
}

/// A shadow catcher in the z = 0 plane, [size] wide, centered on ([i], [j]).
MeshComponent _catcher(double i, double j, double size) {
  return MeshComponent(
    mesh: PlaneMesh(
      size: Vector2.all(size),
      material: ShadowCatcherMaterial(),
    ),
    position: Vector3(i, j, 0),
    // The plane faces +y: turned to face +z.
    rotation: Quaternion.axisAngle(Vector3(1, 0, 0), math.pi / 2),
  );
}

/// A box of 0.5 by 0.5 by 0.5 floating 0.5 to 1 above ([i], [j]): with the
/// sun along (1, 1, -1), its shadow covers i and j from 0.25 to 1.25 more
/// than its center's.
MeshComponent _box(double i, double j, Color color) {
  return MeshComponent(
    mesh: CuboidMesh(size: Vector3.all(0.5), material: opaqueUnlit(color)),
    position: Vector3(i, j, 0.75),
  );
}

LightComponent _sun({bool cacheWhenStatic = false, int cascades = 1}) {
  return LightComponent.directional(
    direction: Vector3(1, 1, -1),
    shadows: ShadowSettings(
      cacheWhenStatic: cacheWhenStatic,
      cascades: cascades,
    ),
  );
}

/// Two layers of one [ShadowGroup] that cover different parts of the screen:
/// the upper part shows the ground and the box of [still], the lower part
/// those of [moving]. The sun is in the still world; the moving one borrows
/// it.
class _Layers({
  bool retained = false,
  bool movingFirst = false,
  bool cacheWhenStatic = false,
  int cascades = 1,
}) {
  this {
    still
      ..cacheMode = retained ? Scene3DCacheMode.retained : Scene3DCacheMode.none
      ..priority = movingFirst ? 2 : 1;
    moving.priority = movingFirst ? 1 : 2;
    still.world
      ..shadowGroup = group
      ..addAll([
        _sun(cacheWhenStatic: cacheWhenStatic, cascades: cascades),
        _catcher(-2, -2, 2),
        _box(-2.5, -2.5, const Color(0xFF0000FF)),
      ]);
    moving.world
      ..shadowGroup = group
      ..lightsFrom = still.world
      ..addAll([_catcher(3, 3, 4), movingBox]);
    game = FlameGame(
      world: World(
        children: [
          RectangleComponent(
            position: Vector2.all(-5000),
            size: Vector2.all(10000),
            paint: Paint()..color = _ground2D,
          ),
          still,
          moving,
        ],
      ),
    );
    game.camera.viewfinder
      ..position = Vector2.zero()
      ..zoom = 0.5;
  }

  final ShadowGroup group = ShadowGroup();
  final Scene3DComponent still = Scene3DComponent(
    projection: _boardProjection(),
  );
  final Scene3DComponent moving = Scene3DComponent(
    projection: _boardProjection(),
  );
  final MeshComponent movingBox = _box(3.5, 3.5, const Color(0xFFFF0000));
  late final FlameGame game;
  GlobalKey? _key;

  Future<void> show(WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(_width, _height)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = _key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: GameWidget(game: game),
      ),
    );
    for (var i = 0; i < 2; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  /// Pumps one frame and returns its pixels.
  Future<Pixels> frame(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 16));
    final boundary =
        _key!.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    return (await tester.runAsync(() async {
      final image = await boundary.toImage();
      final pixels = await readImage(image);
      image.dispose();
      return pixels;
    }))!;
  }

  /// The red channel of the pixel where the ground point ([i], [j]) is.
  int redAt(Pixels pixels, double i, double j) {
    final at = game.camera.localToGlobal(
      still.positionOf(still.scenePointToLocal(Vector3(i, j, 0))),
    );
    return pixels.at(at.x.floor(), at.y.floor()).$1;
  }
}

void main() {
  setUpGpu();

  // Half opaque black over the gray, the catcher's default color.
  final darkened = (0x80 * (1 - 128 / 255)).round();

  group('The map of a ShadowGroup fitted to the view', () {
    for (final (movingFirst, cascades) in [
      (false, 1),
      (true, 1),
      (false, 2),
    ]) {
      testGpu('covers what every layer shows, '
          '${movingFirst ? 'the lower' : 'the upper'} one rendered first, '
          'with $cascades cascade${cascades == 1 ? '' : 's'}', (
        tester,
      ) async {
        final layers = _Layers(movingFirst: movingFirst, cascades: cascades);
        await layers.show(tester);
        final pixels = await layers.frame(tester);
        // Each box's shadow, on the ground of its own layer, outside the
        // part of the screen the other layer covers.
        expect(layers.redAt(pixels, -1.75, -1.75), closeTo(darkened, 2));
        expect(layers.redAt(pixels, 4.25, 4.25), closeTo(darkened, 2));
        // Lit ground next to them.
        expect(layers.redAt(pixels, -2.6, -1.3), 0x80);
        expect(layers.redAt(pixels, 2, 4), 0x80);
        // One shadow pass for the group.
        final passes =
            layers.still.renderStats.shadowPasses +
            layers.moving.renderStats.shadowPasses;
        expect(passes, 1);
      });
    }

    testGpu('does not depend on which layer renders: a retained layer and '
        'an animated one look as without caching', (tester) async {
      // The moving layer changes the color of its box (which moves no
      // shadow) on every frame; the 2D camera pans on frames 1 and 2; the
      // still layer is told to render again on frame 5.
      const frames = 8;
      const panning = {1, 2};
      const cached = {0, 4, 6, 7};
      Future<List<Pixels>> run({required bool retained}) async {
        final layers = _Layers(retained: retained);
        await layers.show(tester);
        final pixels = <Pixels>[];
        for (var k = 0; k < frames; k++) {
          layers.movingBox.color = k.isEven
              ? const Color(0xFFFF8080)
              : const Color(0xFFFFFFFF);
          if (panning.contains(k)) {
            layers.game.camera.viewfinder.position.x += 10;
          }
          if (k == 5) {
            layers.still.markDirty();
          }
          pixels.add(await layers.frame(tester));
          expect(layers.moving.renderStats.renderPasses, isNot(0));
          if (retained && (cached.contains(k) || panning.contains(k))) {
            expect(
              layers.still.renderStats.renderPasses,
              cached.contains(k) ? 0 : isNot(0),
              reason: 'frame $k',
            );
          }
          expect(
            layers.redAt(pixels.last, 4.25, 4.25),
            closeTo(darkened, 2),
            reason: 'frame $k',
          );
          expect(
            layers.redAt(pixels.last, -1.75, -1.75),
            closeTo(darkened, 2),
            reason: 'frame $k',
          );
        }
        return pixels;
      }

      final fresh = await run(retained: false);
      final reused = await run(retained: true);
      for (var k = 0; k < frames; k++) {
        expect(
          differingPixels(fresh[k], reused[k], tolerance: 0),
          0,
          reason: 'frame $k',
        );
      }
    });

    testGpu('keeps a static map cached across the layers', (tester) async {
      final layers = _Layers(cacheWhenStatic: true);
      await layers.show(tester);
      final before = await layers.frame(tester);
      final after = await layers.frame(tester);
      expect(layers.still.renderStats.shadowPasses, 0);
      expect(layers.moving.renderStats.shadowPasses, 0);
      expect(differingPixels(before, after, tolerance: 0), 0);
      expect(layers.redAt(after, 4.25, 4.25), closeTo(darkened, 2));
      expect(layers.redAt(after, -1.75, -1.75), closeTo(darkened, 2));

      // Moving the box of one layer renders the map again, once.
      layers.movingBox.position.x += 0.25;
      await layers.frame(tester);
      expect(
        layers.still.renderStats.shadowPasses +
            layers.moving.renderStats.shadowPasses,
        1,
      );
      await layers.frame(tester);
      expect(
        layers.still.renderStats.shadowPasses +
            layers.moving.renderStats.shadowPasses,
        0,
      );
    });
  });
}
