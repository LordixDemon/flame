import 'dart:math' as math;
import 'dart:typed_data';
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
MeshComponent _box(double i, double j, Color color, {bool casts = true}) {
  return MeshComponent(
    mesh: CuboidMesh(size: Vector3.all(0.5), material: opaqueUnlit(color)),
    position: Vector3(i, j, 0.75),
    castsShadows: casts,
  );
}

/// A layer that can be left out of a frame, as a layer with nothing to show
/// is.
class _Layer({required super.projection}) extends Scene3DComponent {
  bool drawn = true;

  @override
  void render(Canvas canvas) {
    if (drawn) {
      super.render(canvas);
    }
  }
}

/// Two layers of one [ShadowGroup], as the board of a game: the lower one
/// holds the sun, the ground and a box, the upper one a box of its own and
/// borrows the sun. The upper one is drawn alone in the first frame, so it
/// is the one that starts the group's gathering of cameras afterwards.
class _Layers({
  required ShadowFit fit,
  bool cacheStillCasters = false,
  bool withBounds = true,
}) {
  this {
    sun = LightComponent.directional(
      direction: Vector3(1, 1, -1),
      shadows: ShadowSettings(
        fit: fit,
        bounds: withBounds ? receivers : null,
        casterBounds: Aabb3.minMax(Vector3(-8, -8, -1), Vector3(8, 8, 3)),
        cacheStillCasters: cacheStillCasters,
        stillCasterFrames: 1,
      ),
    );
    lower.world
      ..shadowGroup = group
      ..addAll([
        sun,
        _catcher(0, 0, 10),
        lowerBox,
        nonCaster,
      ]);
    upper.world
      ..shadowGroup = group
      ..lightsFrom = lower.world
      ..add(upperBox);
    upper.priority = 2;
    game = FlameGame(
      world: World(
        children: [
          RectangleComponent(
            position: Vector2.all(-5000),
            size: Vector2.all(10000),
            paint: Paint()..color = _ground2D,
          ),
          lower,
          upper,
        ],
      ),
    );
    game.camera.viewfinder
      ..position = Vector2.zero()
      ..zoom = 0.5;
  }

  final Aabb3 receivers = Aabb3.minMax(Vector3(-5, -5, 0), Vector3(5, 5, 1));
  final ShadowGroup group = ShadowGroup();
  late final LightComponent sun;
  final _Layer lower = _Layer(projection: _boardProjection())..priority = 1;
  final _Layer upper = _Layer(projection: _boardProjection());
  final MeshComponent lowerBox = _box(-2, -2, const Color(0xFF0000FF));
  final MeshComponent upperBox = _box(2, 1, const Color(0xFFFF0000));

  /// A box that casts no shadow, high above the board (it grows the bounds
  /// of the scene).
  final MeshComponent nonCaster = _box(
    -1,
    3,
    const Color(0xFF00FF00),
    casts: false,
  )..position.z = 2;
  late final FlameGame game;
  GlobalKey? _key;

  int get passes =>
      lower.renderStats.shadowPasses + upper.renderStats.shadowPasses;

  Float64List get projection =>
      Float64List.fromList(group.projection.viewProjection.storage);

  Future<void> show(WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(_width, _height)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = _key = GlobalKey();
    lower.drawn = false;
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: GameWidget(game: game),
      ),
    );
    await tester.pump(const Duration(milliseconds: 16));
    lower.drawn = true;
    await tester.pump(const Duration(milliseconds: 16));
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
      lower.positionOf(lower.scenePointToLocal(Vector3(i, j, 0))),
    );
    return pixels.at(at.x.floor(), at.y.floor()).$1;
  }
}

void main() {
  setUpGpu();

  // Half opaque black over the gray, the catcher's default color.
  final darkened = (0x80 * (1 - 128 / 255)).round();

  group('ShadowFit.fixed', () {
    testGpu('keeps one projection to the last bit while the cameras pan and '
        'zoom and things that cast nothing move', (tester) async {
      final layers = _Layers(fit: ShadowFit.fixed);
      await layers.show(tester);
      await layers.frame(tester);
      final first = layers.projection;
      for (var k = 0; k < 6; k++) {
        layers.game.camera.viewfinder
          ..position.x += 9
          ..position.y -= 4
          ..zoom = 0.5 + 0.1 * k;
        layers.nonCaster.position
          ..z = 2.0 + k
          ..x = -1 - 3.0 * k;
        if (k == 3) {
          layers.lower.world.add(
            _box(30, -30, const Color(0xFF00FFFF), casts: false),
          );
        }
        await layers.frame(tester);
        expect(layers.projection, first, reason: 'frame $k');
      }
      // A caster that moves changes the map, not its projection.
      layers.upperBox.position.x += 0.5;
      await layers.frame(tester);
      expect(layers.projection, first);
      expect(layers.passes, 1);
    });

    testGpu('keeps the layer of still casters while the cameras pan, and '
        'draws it again only when a caster changes', (tester) async {
      final layers = _Layers(fit: ShadowFit.fixed, cacheStillCasters: true);
      await layers.show(tester);
      // The casters join the still layer.
      for (var k = 0; k < 3; k++) {
        await layers.frame(tester);
      }
      for (var k = 0; k < 4; k++) {
        layers.game.camera.viewfinder.position.x += 9;
        layers.nonCaster.position.z = 3.0 + k;
        final pixels = await layers.frame(tester);
        // Nothing that casts changed: the map is reused whole.
        expect(layers.passes, 0, reason: 'frame $k');
        expect(layers.lower.renderStats.shadowLayersRendered, 0);
        expect(
          layers.redAt(pixels, -1.25, -1.25),
          closeTo(darkened, 2),
          reason: 'frame $k',
        );
      }
      // A still caster that moves has the layer drawn again without it (one
      // pass), then the map over it (another).
      layers.lowerBox.position.y += 0.25;
      await layers.frame(tester);
      expect(layers.lower.renderStats.shadowLayersRendered, 1);
      expect(layers.passes, 2);
    });

    testGpu('needs the bounds that receive shadows', (tester) async {
      final layers = _Layers(fit: ShadowFit.fixed, withBounds: false);
      tester.view
        ..physicalSize = const Size(_width, _height)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(GameWidget(game: layers.game));
      Object? error;
      for (var k = 0; k < 3 && error == null; k++) {
        await tester.pump(const Duration(milliseconds: 16));
        error = tester.takeException();
      }
      expect(error, isA<StateError>());
    });
  });
}
