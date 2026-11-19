import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flame/components.dart' show RectangleComponent, World;
import 'package:flame/game.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/debug.dart';
import 'package:flame_3d/extensions.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/ui3d.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/widgets.dart' show GlobalKey, RepaintBoundary;
import 'package:flutter_test/flutter_test.dart';

import 'gpu_test_helpers.dart';

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

/// Shows the [layer] over a gray 2D ground in a 160x120 view and returns the
/// pixels of the third frame.
Future<Pixels> _renderLayer(WidgetTester tester, Scene3DComponent layer) async {
  final game = FlameGame(
    world: World(
      children: [
        RectangleComponent(
          position: Vector2.all(-5000),
          size: Vector2.all(10000),
          paint: Paint()..color = _ground2D,
        ),
        layer,
      ],
    ),
  );
  game.camera.viewfinder
    ..position = layer.positionOf(layer.scenePointToLocal(Vector3(3, 2, 0.7)))
    ..zoom = 0.5;
  tester.view
    ..physicalSize = const Size(160, 120)
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

/// The columns of [pixels] that hold a drawn (not clear) pixel, as
/// `(first, last)`, or `null` when nothing is drawn.
(int, int)? _drawnColumns(Pixels pixels) {
  int? first;
  int? last;
  for (var x = 0; x < pixels.width; x++) {
    for (var y = 0; y < pixels.height; y++) {
      if (!pixels.isClear(x, y)) {
        first ??= x;
        last = x;
        break;
      }
    }
  }
  return first == null ? null : (first, last!);
}

/// A view from [eye] looking at the point (0, 0, -5), y up.
Matrix4 _viewFrom(Vector3 eye) =>
    Matrix4.identity()
      ..setAsViewMatrix(eye, Vector3(0, 0, -5), Vector3(0, 1, 0));

void main() {
  setUpGpu();

  group('BillboardBatch3D', () {
    BillboardBatch3D redBatch() =>
        BillboardBatch3D(
          material: BillboardMaterial3D(albedoColor: const Color(0xFFFF0000)),
        )..addBillboard(
          position: Vector3.zero(),
          width: 0.25,
          height: 0.25,
          orientation: BillboardOrientation3D.spherical,
          anchorY: 0,
          unlit: 1,
        );

    bool isRed(Pixels pixels, double x, double y) {
      final (px, py) = pixelAt(x, y);
      final (r, g, b, a) = pixels.at(px, py);
      return r > 200 && g < 50 && b < 50 && a == 255;
    }

    testGpuEngine('places its billboards with its transform', () async {
      final batch = redBatch()..position.setValues(0.5, 0, -5);
      var frame = await renderFrame(draw: batch.draw);
      expect(isRed(frame.pixels, 0.5, 0), isTrue);
      expect(frame.pixels.isClear(32, 32), isTrue);
      // The bounds used for culling are where it is drawn.
      expect(batch.aabb.containsVector3(Vector3(0.5, 0, -5)), isTrue);

      // Scaling the batch scales the sizes: a quarter wide at scale 1, half
      // at scale 2.
      expect(isRed(frame.pixels, 0.7, 0), isFalse);
      batch.scale.setValues(2, 2, 2);
      frame = await renderFrame(draw: batch.draw);
      expect(isRed(frame.pixels, 0.7, 0), isTrue);
      expect(isRed(frame.pixels, 0.5, 0.2), isTrue);
    });

    testGpuEngine('anchors and rolls sprites as rigid quads', () async {
      final batch =
          BillboardBatch3D(
              material: BillboardMaterial3D(
                albedoColor: const Color(0xFFFF0000),
              ),
            )
            ..position.setValues(0, 0, -5)
            // A wide sprite turned a quarter turn becomes tall.
            ..addBillboard(
              position: Vector3.zero(),
              width: 0.5,
              height: 0.1,
              orientation: BillboardOrientation3D.spherical,
              anchorY: 0,
              rollRadians: math.pi / 2,
              unlit: 1,
            )
            // A sprite whose left edge is at its position.
            ..addBillboard(
              position: Vector3(0.4, -0.6, 0),
              width: 0.3,
              height: 0.1,
              orientation: BillboardOrientation3D.spherical,
              anchorY: 0,
              anchorX: -0.5,
              unlit: 1,
            );
      final frame = await renderFrame(draw: batch.draw);
      expect(isRed(frame.pixels, 0, 0.2), isTrue);
      expect(isRed(frame.pixels, 0, -0.2), isTrue);
      expect(isRed(frame.pixels, 0.2, 0), isFalse);
      expect(isRed(frame.pixels, 0.65, -0.6), isTrue);
      expect(isRed(frame.pixels, 0.3, -0.6), isFalse);
    });
  });

  group('BillboardMaterial3D', () {
    /// A 1x1 texture of the RGBA bytes [rgba].
    Texture texel(List<int> rgba) => Texture(
      ByteData.sublistView(Uint8List.fromList(rgba)),
      width: 1,
      height: 1,
    );

    Future<Pixels> renderSprite(BillboardMaterial3D material) async {
      final batch = BillboardBatch3D(material: material)
        ..addBillboard(
          position: Vector3(0, 0, -5),
          width: 1,
          height: 1,
          orientation: BillboardOrientation3D.spherical,
          anchorY: 0,
          unlit: 1,
        );
      return (await renderFrame(draw: batch.draw)).pixels;
    }

    void expectColor(Pixels pixels, (int, int, int, int) expected) {
      final (r, g, b, a) = pixels.at(32, 32);
      expect(r, closeTo(expected.$1, 2));
      expect(g, closeTo(expected.$2, 2));
      expect(b, closeTo(expected.$3, 2));
      expect(a, closeTo(expected.$4, 2));
    }

    testGpuEngine('blends a premultiplied texture once', () async {
      // 50 % white, premultiplied, over the clear target.
      final pixels = await renderSprite(
        BillboardMaterial3D(
          albedoTexture: texel([128, 128, 128, 128]),
          translucent: true,
        ),
      );
      expectColor(pixels, (128, 128, 128, 128));
    });

    testGpuEngine('blends a straight-alpha texture', () async {
      final pixels = await renderSprite(
        BillboardMaterial3D(
          albedoTexture: texel([255, 255, 255, 128]),
          translucent: true,
          premultipliedTexture: false,
        ),
      );
      expectColor(pixels, (128, 128, 128, 128));
    });

    testGpuEngine('keeps the color of cut-out premultiplied texels', () async {
      // A half transparent red texel above the cutoff is drawn opaque, in
      // its full color.
      final pixels = await renderSprite(
        BillboardMaterial3D(albedoTexture: texel([128, 0, 0, 128])),
      );
      expectColor(pixels, (255, 0, 0, 255));
    });

    testGpuEngine(
      'draws a translucent label background at its alpha',
      () async {
        final label = Text3DComponent(
          text: '',
          backgroundColor: const Color(0x80FFFFFF),
          borderColor: null,
          position: Vector3(0, 0, -5),
          worldHeight: 0.5,
        );
        final frame = await renderFrame(draw: label.draw);
        expectColor(frame.pixels, (128, 128, 128, 128));
      },
    );
  });

  group('MsdfTextBatch3D', () {
    testGpuEngine(
      'keeps camera-facing text as wide seen from any side',
      () async {
        for (final mode in [
          TextBillboardMode3D.spherical,
          TextBillboardMode3D.cylindrical,
        ]) {
          final text = MsdfTextBatch3D()
            ..addText(
              'HELLO WORLD',
              position: Vector3(0, 0, -5),
              fontSize: 0.12,
              mode: mode,
              align: TextAlign3D.center,
            );
          final widths = <int>[];
          for (final eye in [
            Vector3.zero(), // in front
            Vector3(5, 0, -5), // on the right side
            Vector3(-3.5, 0, -8.5), // behind, on the left
          ]) {
            final frame = await renderFrame(
              draw: text.draw,
              view: _viewFrom(eye),
            );
            final (first, last) = _drawnColumns(frame.pixels)!;
            // Centered on the string's position.
            expect((first + last) / 2, closeTo(31.5, 1.5), reason: '$eye');
            widths.add(last - first);
          }
          // About 11 glyphs of 0.62 * 0.12 units: 26 pixels.
          expect(widths.first, greaterThan(20), reason: '$mode');
          for (final width in widths) {
            expect(width, closeTo(widths.first, 1), reason: '$mode');
          }
        }
      },
    );

    testGpuEngine('follows the transform of the batch', () async {
      final text = MsdfTextBatch3D()
        ..addText(
          'MOVE',
          position: Vector3.zero(),
          fontSize: 0.12,
          align: TextAlign3D.center,
        )
        ..position.setValues(0.5, 0, -5);
      for (final x in [0.5, -0.5]) {
        text.position.x = x;
        final frame = await renderFrame(draw: text.draw);
        final (first, last) = _drawnColumns(frame.pixels)!;
        expect((first + last) / 2, closeTo((x + 1) * 32, 1.5), reason: '$x');
      }
    });
  });

  group('DebugRenderer3D', () {
    /// A shadow catcher ground, a red cube floating above it and a sun
    /// casting shadows, with [extra] components added to the world.
    Future<Pixels> renderShadowScene(
      WidgetTester tester, {
      List<Component3D> extra = const [],
    }) {
      final layer = Scene3DComponent(projection: _boardProjection());
      layer.world.addAll([
        LightComponent.directional(
          direction: Vector3(1, 0, -1),
          shadows: ShadowSettings(),
        ),
        MeshComponent(
          mesh: PlaneMesh(
            size: Vector2.all(10),
            material: ShadowCatcherMaterial(),
          ),
          position: Vector3(2, 2, 0),
          rotation: Quaternion.axisAngle(Vector3(1, 0, 0), math.pi / 2),
        ),
        MeshComponent(
          mesh: CuboidMesh(
            size: Vector3.all(1),
            material: opaqueUnlit(const Color(0xFFFF0000)),
          ),
          position: Vector3(2, 2, 1.5),
        ),
        ...extra,
      ]);
      return _renderLayer(tester, layer);
    }

    int shadowPixels(Pixels pixels) =>
        pixels.count((r, g, b, a) => r < 0x70 && g < 0x70 && b < 0x70);

    testGpu('does not change the sun shadows it is added to', (tester) async {
      final plain = await renderShadowScene(tester);
      final shadowed = shadowPixels(plain);
      // The cube's shadow on the catcher: about 2 by 1 scene units.
      expect(shadowed, greaterThan(300));

      final withDebug = await renderShadowScene(
        tester,
        extra: [
          DebugRenderer3D(
            showObjectBounds: false,
            showSkeletons: false,
            showLightVolumes: false,
          ),
        ],
      );
      expect(shadowPixels(withDebug), shadowed);
      expect(differingPixels(plain, withDebug), 0);
    });
  });
}
