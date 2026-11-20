import 'dart:ui';

import 'package:flame_3d/core.dart';
import 'package:flame_3d/model.dart';
import 'package:flame_3d/parser.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter_test/flutter_test.dart';

import 'gltf_test_models.dart';
import 'gpu_test_helpers.dart';

// glTF models drawn with StylizedMaterial: converted with no custom
// attribute and a tint of 1, a model draws the pixels it draws in the
// standard layout; with their masks and textures, converted models batch as
// the stylized meshes beside them do.

const _width = 192;
const _height = 144;

List<Light> _lights() => [
  Light(
    position: Vector3.zero(),
    source: HemisphereLight(
      skyColor: const Color(0xFFB4CCF0),
      groundColor: const Color(0xFF6E7A50),
      intensity: 0.6,
    ),
  ),
  Light(
    position: Vector3.zero(),
    source: DirectionalLight(
      direction: Vector3(0.4, -0.5, -0.8),
      intensity: 0.8,
    ),
  ),
];

List<Surface> _surfaces(Model model) => [
  for (final node in model.nodes.values) ...?node.mesh?.surfaces,
];

/// The pose of the creature's joints: bent at the waist and the neck.
List<Matrix4> _pose(double bend) => [
  Matrix4.identity(),
  Matrix4.translationValues(0, 0.45, 0)
    ..rotateZ(bend)
    ..translateByDouble(0, -0.45, 0, 1),
  Matrix4.translationValues(0, 0.45, 0)
    ..rotateZ(bend)
    ..translateByDouble(0, 0.4, 0, 1)
    ..rotateZ(-bend * 1.5)
    ..translateByDouble(0, -0.85, 0, 1),
];

void main() {
  setUpGpu();

  group('glTF models drawn with StylizedMaterial', () {
    testGpuEngine('converted with a tint of 1 and nothing else, they draw '
        'the pixels of the standard layout', () async {
      Future<Pixels> render({required bool converted}) async {
        final creature = await GlbParser().parseModelBytes(creatureGlb());
        final material = StylizedMaterial(windAmplitude: 0.05, windTime: 1);
        if (converted) {
          const StylizedVertexMapping(
            tint: AttributeChannel.constant(1),
          ).convertModel(creature, materialFor: (_) => material);
        } else {
          for (final surface in _surfaces(creature)) {
            surface.material = material;
          }
        }
        final surface = _surfaces(creature).single;
        final frame = await renderFrame(
          width: _width,
          height: _height,
          lights: _lights(),
          draw: (context) {
            for (var i = 0; i < 4; i++) {
              context.drawSurface(
                surface,
                transform: Matrix4.translationValues(-0.75 + i * 0.5, -0.6, -5)
                  ..rotateY(0.6 * i),
                color: Color.fromARGB(255, 80 + i * 40, 160, 220 - i * 40),
                instanceData: Vector4(0, i == 2 ? 0.3 : 0, 0, 0),
                jointTransforms: _pose(0.25 * i - 0.3),
              );
            }
          },
        );
        return frame.pixels;
      }

      final standard = await render(converted: false);
      final converted = await render(converted: true);
      expect(standard.count((r, g, b, a) => a > 0), greaterThan(3000));
      expect(differingPixels(converted, standard, tolerance: 0), 0);
    });

    testGpuEngine('their masks show, and a textured model and the meshes '
        'beside it batch', () async {
      final png = await encodePng(stavesPixels(), 64, 64);
      final barrel = await GlbParser().parseModelBytes(barrelGlb(png));
      final creature = await GlbParser().parseModelBytes(creatureGlb());
      final barrelMaterial = _surfaces(barrel).single.material;
      expect(barrelMaterial, isA<SpatialMaterial>());

      final barrels = const StylizedVertexMapping(
        accent: AttributeChannel('_TRIM'),
        gloss: AttributeChannel('_TRIM', 1),
      ).convertModel(barrel);
      final stylizedBarrel = barrels.materials[barrelMaterial]!
        ..accentColor = const Color(0xFF8A9098);
      expect(stylizedBarrel.baseColorTexture, isNotNull);

      const StylizedVertexMapping(
        tint: AttributeChannel('_MASKS'),
        accent: AttributeChannel('_MASKS', 1),
        emissive: AttributeChannel('_MASKS', 2),
        gloss: AttributeChannel('_MASKS', 3),
        sway: AttributeChannel('_SWAY'),
      ).convertModel(
        creature,
        materialFor: (_) => StylizedMaterial(
          accentColor: const Color(0xFF6A4020),
          emissiveColor: const Color(0xFF60FFE0),
        ),
      );
      final barrelSurface = _surfaces(barrel).single;
      final creatureSurface = _surfaces(creature).single;
      expect(
        barrelSurface.layout,
        same(StylizedMaterial.texturedVertexLayout),
      );
      expect(
        creatureSurface.layout,
        same(StylizedMaterial.skinnedVertexLayout),
      );
      final crate = StylizedMaterial.buildSurface(
        positions: const [-0.2, 0, 0, 0.2, 0, 0, 0.2, 0.4, 0, -0.2, 0.4, 0],
        normals: const [0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1],
        colors: [
          for (var v = 0; v < 4; v++) ...[0.8, 0.5, 0.3, 1],
        ],
        indices: const [0, 1, 2, 2, 3, 0],
        material: StylizedMaterial(),
      );

      final frame = await renderFrame(
        width: _width,
        height: _height,
        lights: _lights(),
        projection: Matrix4.identity()
          ..setEntry(0, 0, 0.5)
          ..setEntry(1, 1, 0.66)
          ..setEntry(2, 2, -0.1),
        draw: (context) {
          for (var i = 0; i < 6; i++) {
            final x = -1.5 + i * 0.6;
            context
              ..drawSurface(
                barrelSurface,
                transform: Matrix4.translationValues(x, 0.2, -5)
                  ..rotateX(0.3)
                  ..rotateY(i * 0.5),
              )
              ..drawSurface(
                crate,
                transform: Matrix4.translationValues(x + 0.3, -1.2, -6),
              );
          }
          for (var i = 0; i < 3; i++) {
            context.drawSurface(
              creatureSurface,
              transform: Matrix4.translationValues(i - 1.0, -1.3, -4),
              color: Color.fromARGB(255, 60 + i * 80, 120, 200 - i * 60),
              jointTransforms: _pose(0.3 * i - 0.3),
            );
          }
        },
      );
      // 6 barrels in one draw, 6 crates in one, 3 skinned creatures in
      // one each.
      expect(frame.stats.drawCalls, 5);
      // The creatures' glowing eyes: pixels close to the emissive color.
      expect(
        frame.pixels.count(
          (r, g, b, a) => a > 0 && r < 140 && g > 200 && b > 180,
        ),
        greaterThan(5),
      );
    });
  });
}
