import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/game.dart' show GameWidget;
import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/game.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/particles.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter/widgets.dart' show ObjectKey;
import 'package:flutter_test/flutter_test.dart';

import 'gpu_test_helpers.dart';

final Matrix4 _view = Matrix4.identity()
  ..setAsViewMatrix(Vector3(0, 0, 4), Vector3.zero(), Vector3(0, 1, 0));
final Matrix4 _projection = Matrix4.identity()
  ..setAsPerspective(60, 1, 0.2, 40);

const _size = 64;

Future<Pixels> _snapshot(
  WidgetTester tester,
  World3D world, {
  Matrix4? view,
  Color clearValue = const Color(0xFF000000),
  Msaa msaa = Msaa.off,
}) async {
  if (!world.isMounted) {
    final game = FlameGame3D(world: world);
    await tester.pumpWidget(GameWidget(key: ObjectKey(game), game: game));
    await tester.pump();
  }
  await tester.pump(const Duration(milliseconds: 16));
  return (await tester.runAsync(() async {
    final device = GraphicsDevice();
    final context = RenderContext3D(device);
    device.begin();
    final image = world.renderToImage(
      const Size(_size + 0.0, _size + 0.0),
      view: view ?? _view,
      projection: _projection,
      clearValue: clearValue,
      msaa: msaa,
      device: device,
      context: context,
    );
    device.end();
    final pixels = await readImage(image);
    image.dispose();
    return pixels;
  }))!;
}

/// A thin box facing the camera, covering the middle of the frame.
MeshComponent _panel(Material material, {double size = 2.4, double x = 0}) {
  return MeshComponent(
    position: Vector3(x, 0, 0),
    mesh: CuboidMesh(size: Vector3(size, size, 0.02), material: material),
  );
}

double _srgbToLinear(double c) =>
    c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();

/// The AgX sigmoid of a gray linear [value], as display-encoded output.
double _agxGray(double value) {
  final v = ((math.log(math.max(value, 1e-10)) / math.ln2 + 12.47393) / 16.5)
      .clamp(0.0, 1.0);
  double p(int n) => math.pow(v, n).toDouble();
  return (15.5 * p(6) -
          40.14 * p(5) +
          31.96 * p(4) -
          6.868 * p(3) +
          0.4298 * p(2) +
          0.1191 * v -
          0.00232)
      .clamp(0.0, 1.0);
}

void main() {
  setUpGpu();

  testGpu('ToneMapMode.agx maps black to black and grays to the AgX curve', (
    tester,
  ) async {
    final world = World3D(
      hdrEnabled: true,
      postProcess: PostProcessSettings(toneMap: ToneMapMode.agx),
      children: [
        _panel(opaqueUnlit(const Color(0xFF808080)), size: 1.2, x: -0.8),
      ],
    );
    final pixels = await _snapshot(tester, world);

    // The black clear color stays black.
    final (r, g, b, _) = pixels.at(_size - 4, _size ~/ 2);
    expect((r, g, b), (0, 0, 0));

    // The 50% gray panel (linear 0.216) follows the AgX sigmoid.
    final expected = (_agxGray(_srgbToLinear(128 / 255)) * 255).round();
    final (gr, gg, gb, _) = pixels.at(18, _size ~/ 2);
    expect(gr, closeTo(expected, 3));
    expect(gg, closeTo(expected, 3));
    expect(gb, closeTo(expected, 3));
  });

  group('hdrEnabled with tone mapping off keeps the LDR brightness of', () {
    final materials = <String, (Object3D Function(), Matrix4?)>{
      'UnlitMaterial': (
        () => _panel(opaqueUnlit(const Color(0xFF8040C0))),
        null,
      ),
      'translucent UnlitMaterial': (
        () => _panel(UnlitMaterial(albedoColor: const Color(0x99604830))),
        null,
      ),
      'StylizedMaterial': (
        () => _panel(StylizedMaterial(albedoColor: const Color(0xFF8040C0))),
        null,
      ),
      'ParticleMaterial': (
        () =>
            ParticleSystem3D(
              capacity: 1,
              material: ParticleMaterial(sprite: ParticleSprite.texture),
            )..spawn(
              position: Vector3.zero(),
              size: 2,
              color: const Color(0xFF8040C0),
            ),
        null,
      ),
      'WaterMaterial': (
        () => MeshComponent(
          mesh: PlaneMesh(
            size: Vector2(8, 8),
            material: WaterMaterial(opacity: 1),
          ),
        ),
        Matrix4.identity()..setAsViewMatrix(
          Vector3(0, 4, 0.5),
          Vector3.zero(),
          Vector3(0, 1, 0),
        ),
      ),
    };

    for (final MapEntry(key: name, value: (build, view)) in materials.entries) {
      testGpu(name, (tester) async {
        World3D world({required bool hdr}) => World3D(
          hdrEnabled: hdr,
          bloom: hdr
              ? BloomSettings(threshold: 1, softKnee: 0, intensity: 1)
              : null,
          postProcess: hdr ? PostProcessSettings() : null,
          children: [
            LightComponent.ambient(intensity: 0.6),
            LightComponent.directional(
              direction: Vector3(0.2, -0.6, -1)..normalize(),
              intensity: 0.8,
            ),
            build(),
          ],
        );
        final ldr = await _snapshot(tester, world(hdr: false), view: view);
        final hdr = await _snapshot(tester, world(hdr: true), view: view);

        final center = ldr.at(_size ~/ 2, _size ~/ 2);
        expect(center, isNot((0, 0, 0, 255)), reason: 'nothing drawn');
        expect(differingPixels(ldr, hdr, tolerance: 3), 0);
      });
    }
  });

  testGpu('grading leaves the transparent pixels of a layer transparent', (
    tester,
  ) async {
    final world = World3D(
      postProcess: PostProcessSettings(contrast: 0.5, saturation: 0.5),
      children: [_panel(opaqueUnlit(const Color(0xFFFF0000)), size: 1)],
    );
    final pixels = await _snapshot(
      tester,
      world,
      clearValue: const Color(0x00000000),
    );

    expect(pixels.at(2, 2), (0, 0, 0, 0));
    // The panel is graded: contrast 0.5, then saturation 0.5, of pure red.
    const red = 0.75;
    const other = 0.25;
    const luma = 0.299 * red + (0.587 + 0.114) * other;
    final (r, g, b, a) = pixels.at(_size ~/ 2, _size ~/ 2);
    expect(a, 255);
    expect(r, closeTo((luma + red) / 2 * 255, 3));
    expect(g, closeTo((luma + other) / 2 * 255, 3));
    expect(b, g);
  });

  testGpu('an afterScene custom pass draws over the scene', (tester) async {
    final overlay = quad(opaqueUnlit(const Color(0xFFFF0000)), halfSize: 0.25);
    final world = World3D(
      customPasses: [
        CustomRenderPass3D(
          name: 'overlay',
          execute: (pass) {
            pass.device.beginTexturePass(pass.sceneTarget!, keepContents: true);
            pass.renderContext
              ..setCamera(defaultView, defaultProjection)
              ..drawSurface(
                overlay,
                transform: Matrix4.translationValues(-0.7, 0, -1),
              )
              ..flush();
            pass.device.endTexturePass();
          },
        ),
      ],
      children: [_panel(opaqueUnlit(const Color(0xFF00C000)), size: 1)],
    );
    final pixels = await _snapshot(tester, world);

    expect(pixels.at(_size ~/ 2, _size ~/ 2), (0, 192, 0, 255));
    expect(pixels.at(10, _size ~/ 2), (255, 0, 0, 255));
  });

  group('MSAA applies through', () {
    final cases = <String, World3D Function(Object3D panel)>{
      'post-processing': (panel) => World3D(
        postProcess: PostProcessSettings(saturation: 0.9),
        children: [panel],
      ),
      'HDR': (panel) => World3D(hdrEnabled: true, children: [panel]),
      'order-independent transparency': (panel) => World3D(
        oitMode: OitMode3D.weightedBlended,
        children: [
          panel,
          // A red translucent panel at the side (counted out by its green).
          _panel(
            UnlitMaterial(albedoColor: const Color(0x40400000)),
            size: 0.4,
            x: 1.6,
          ),
        ],
      ),
    };
    for (final MapEntry(key: name, value: build) in cases.entries) {
      testGpu(name, (tester) async {
        Future<int> partialPixels(Msaa msaa) async {
          final panel = MeshComponent(
            rotation: Quaternion.axisAngle(Vector3(0, 0, 1), 0.5),
            mesh: CuboidMesh(
              size: Vector3(1.4, 1.4, 0.02),
              material: opaqueUnlit(const Color(0xFFFFFFFF)),
            ),
          );
          final pixels = await _snapshot(
            tester,
            build(panel),
            clearValue: const Color(0x00000000),
            msaa: msaa,
          );
          return pixels.count((r, g, b, a) => a > 0 && a < 255 && g > 0);
        }

        expect(await partialPixels(Msaa.off), 0);
        expect(await partialPixels(Msaa.sample4), greaterThan(20));
      });
    }
  });
}
