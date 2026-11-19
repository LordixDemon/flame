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
      device: device,
      context: context,
    );
    device.end();
    final pixels = await readImage(image);
    image.dispose();
    return pixels;
  }))!;
}

/// A thin box facing the camera; with back faces culled only its front face
/// is drawn.
MeshComponent _panel(Material material, {double size = 2, double z = 0}) {
  return MeshComponent(
    position: Vector3(0, 0, z),
    mesh: CuboidMesh(size: Vector3(size, size, 0.02), material: material),
  );
}

List<Component3D> _lights() => [
  LightComponent.ambient(intensity: 0.5),
  LightComponent.directional(
    direction: Vector3(0.3, -0.5, -1)..normalize(),
    intensity: 0.9,
  ),
];

const _culled = CullMode.backFace;

void main() {
  setUpGpu();

  group('OitMode3D.weightedBlended', () {
    testGpu('draws translucent surfaces into an HDR scene', (tester) async {
      World3D world({required OitMode3D oit}) => World3D(
        hdrEnabled: true,
        oitMode: oit,
        postProcess: PostProcessSettings(),
        children: [
          _panel(
            UnlitMaterial(albedoColor: const Color(0x80800000))
              ..renderState = RenderState.premultipliedAlphaBlend.copyWith(
                cullMode: _culled,
              ),
          ),
        ],
      );
      final sorted = await _snapshot(
        tester,
        world(oit: OitMode3D.none),
        clearValue: const Color(0x00000000),
      );
      final oit = await _snapshot(
        tester,
        world(oit: OitMode3D.weightedBlended),
        clearValue: const Color(0x00000000),
      );
      expect(sorted.at(_size ~/ 2, _size ~/ 2), (128, 0, 0, 128));
      expect(differingPixels(sorted, oit), 0);
    });

    testGpu('keeps the clear color', (tester) async {
      World3D world() => World3D(
        oitMode: OitMode3D.weightedBlended,
        children: [
          _panel(UnlitMaterial(albedoColor: const Color(0x80008000))),
        ],
      );
      final green = await _snapshot(
        tester,
        world(),
        clearValue: const Color(0xFF203040),
      );
      expect(green.at(1, 1), (0x20, 0x30, 0x40, 255));

      final transparent = await _snapshot(
        tester,
        world(),
        clearValue: const Color(0x00000000),
      );
      expect(transparent.at(1, 1), (0, 0, 0, 0));
    });

    final materials = <String, Object3D Function()>{
      'SpatialMaterial, straight alpha': () => _panel(
        SpatialMaterial(albedoColor: const Color(0x99D04020), roughness: 0.5)
          ..renderState = RenderState.alphaBlend.copyWith(cullMode: _culled),
      ),
      'SpatialMaterial, premultiplied alpha': () => _panel(
        SpatialMaterial(albedoColor: const Color(0x9920A040), roughness: 0.5)
          ..renderState = RenderState.premultipliedAlphaBlend.copyWith(
            cullMode: _culled,
          ),
      ),
      'StylizedMaterial': () => _panel(
        StylizedMaterial(
            albedoColor: const Color(0x998040C0),
            translucent: true,
          )
          ..renderState = StylizedMaterial.translucentRenderState.copyWith(
            cullMode: _culled,
          ),
      ),
      'ParticleMaterial': () =>
          ParticleSystem3D(
            capacity: 1,
            material: ParticleMaterial(sprite: ParticleSprite.softCircle),
          )..spawn(
            position: Vector3.zero(),
            size: 2,
            color: const Color(0xCCE0A030),
          ),
      'additive ParticleMaterial behind an opaque panel': () =>
          ParticleSystem3D(
              capacity: 2,
              material: ParticleMaterial(
                sprite: ParticleSprite.softCircle,
                renderState: RenderState.additive,
              ),
            )
            ..spawn(
              position: Vector3(-0.6, 0, -1.2),
              size: 1.6,
              color: const Color(0xFF406080),
            )
            ..spawn(
              position: Vector3(0.6, 0, 1),
              size: 1.2,
              color: const Color(0xFF806040),
            ),
    };

    for (final MapEntry(key: name, value: build) in materials.entries) {
      testGpu('shades one layer of $name as the sorted path does', (
        tester,
      ) async {
        World3D world({required OitMode3D oit}) => World3D(
          oitMode: oit,
          children: [
            ..._lights(),
            _panel(opaqueUnlit(const Color(0xFF305070)), size: 1.2, z: -0.5),
            build(),
          ],
        );
        final sorted = await _snapshot(tester, world(oit: OitMode3D.none));
        final oit = await _snapshot(
          tester,
          world(oit: OitMode3D.weightedBlended),
        );
        expect(
          sorted.count((r, g, b, _) => r + g + b > 0),
          greaterThan(400),
          reason: 'nothing drawn',
        );
        expect(differingPixels(sorted, oit, tolerance: 3), 0);
      });
    }
  });
}
