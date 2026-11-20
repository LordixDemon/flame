import 'dart:typed_data';
import 'dart:ui';

import 'package:flame_3d/core.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter_test/flutter_test.dart';

import 'gpu_test_helpers.dart';

// StylizedMaterial's base color texture: a white texture multiplying the
// vertex color draws every pixel as no texture does, a texture colors the
// surface under the same lighting, replaces the vertex color, cuts pixels out
// and keeps the instances of a surface in one draw.

const _width = 192;
const _height = 144;

/// A tube of `rings` rings along y, from -0.4 to 0.4, with per-vertex colors,
/// masks, gloss, occlusion and wind, texture coordinates going once around
/// it and joints bending its top: the arrays of a StylizedMaterial surface.
class _Tube({int rings = 7}) {
  this {
    const half = 0.12;
    const sides = [
      ((0.0, 1.0), (-half, half), (half, half)),
      ((1.0, 0.0), (half, half), (half, -half)),
      ((0.0, -1.0), (half, -half), (-half, -half)),
      ((-1.0, 0.0), (-half, -half), (-half, half)),
    ];
    for (final (side, ((nx, nz), (ax, az), (bx, bz))) in sides.indexed) {
      final first = positions.length ~/ 3;
      for (var r = 0; r < rings; r++) {
        final t = r / (rings - 1);
        final y = -0.4 + 0.8 * t;
        positions.addAll([ax, y, az, bx, y, bz]);
        normals.addAll([nx, 0.2, nz, nx, 0.2, nz]);
        texCoords.addAll([side / 4, 1 - t, (side + 1) / 4, 1 - t]);
        for (var k = 0; k < 2; k++) {
          colors.addAll([0.5 + 0.4 * t, 0.7, 0.9 - 0.5 * t, 1]);
          tint.add(side == 0 ? 1 : 0);
          accent.add(side == 1 ? 1 : 0);
          emissive.add(r == rings - 1 ? 0.6 : 0);
          gloss.add(side == 2 ? 0.9 : 0.2);
          occlusion.add(0.6 + 0.4 * t);
          sway.add(t);
          joints.addAll([0, 1, 0, 0]);
          weights.addAll([1 - t, t, 0, 0]);
        }
      }
      for (var r = 0; r + 1 < rings; r++) {
        final a = first + r * 2;
        indices.addAll([a, a + 1, a + 3, a + 3, a + 2, a]);
      }
    }
  }

  final List<double> positions = [];
  final List<double> normals = [];
  final List<double> texCoords = [];
  final List<double> colors = [];
  final List<double> tint = [];
  final List<double> accent = [];
  final List<double> emissive = [];
  final List<double> gloss = [];
  final List<double> occlusion = [];
  final List<double> sway = [];
  final List<double> joints = [];
  final List<double> weights = [];
  final List<int> indices = [];

  Surface surface(
    Material material, {
    bool textured = false,
    bool skinned = false,
  }) => StylizedMaterial.buildSurface(
    positions: positions,
    normals: normals,
    colors: colors,
    tint: tint,
    accent: accent,
    emissive: emissive,
    gloss: gloss,
    occlusion: occlusion,
    sway: sway,
    texCoords: textured ? texCoords : null,
    joints: skinned ? joints : null,
    weights: skinned ? weights : null,
    indices: indices,
    material: material,
  );
}

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
  Light(
    position: Vector3(0.3, 0.2, -4),
    source: PointLight(color: const Color(0xFFFFC080), intensity: 0.6),
  ),
];

StylizedMaterial _material({Texture? texture}) => StylizedMaterial(
  baseColorTexture: texture,
  accentColor: const Color(0xFFE0B040),
  emissiveColor: const Color(0xFF60FFE0),
  windTime: 0.7,
  windAmplitude: 0.04,
);

/// A texture of [width] x [height] pixels whose pixel (x, y) is
/// `color(x, y)`, sampled at the nearest pixel.
Texture _texture(int width, int height, Color Function(int x, int y) color) {
  final bytes = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final c = color(x, y);
      final o = (y * width + x) * 4;
      bytes
        ..[o] = (c.r * 255).round()
        ..[o + 1] = (c.g * 255).round()
        ..[o + 2] = (c.b * 255).round()
        ..[o + 3] = (c.a * 255).round();
    }
  }
  return Texture(ByteData.sublistView(bytes), width: width, height: height);
}

/// Rows of tubes, their standard-layout twins and skinned tubes, turned,
/// tinted and with instance data. With [textured], their materials have
/// [texture] and their surfaces texture coordinates.
Future<Frame> _render({required bool textured, Texture? texture}) {
  final tube = _Tube();
  final material = _material(texture: textured ? texture : null);
  final own = tube.surface(material, textured: textured);
  final skinned = tube.surface(material, textured: textured, skinned: true);
  final cube = CuboidMesh(size: Vector3.all(0.22), material: material);
  final bend = Matrix4.identity()..rotateZ(-0.5);
  return renderFrame(
    width: _width,
    height: _height,
    lights: _lights(),
    draw: (context) {
      for (var i = 0; i < 6; i++) {
        final x = -0.8 + i * 0.32;
        context
          ..drawSurface(
            own,
            transform: Matrix4.translationValues(x, 0.45, -5)
              ..rotateY(0.4 * i)
              ..rotateX(0.3),
            color: Color.fromARGB(255, 220, 60 + i * 30, 80),
            instanceData: Vector4(i / 10, i == 3 ? 0.3 : 0, 0, 0),
          )
          ..drawSurface(
            skinned,
            transform: Matrix4.translationValues(x, -0.1, -5)
              ..rotateY(-0.3 * i),
            jointTransforms: [Matrix4.identity(), bend],
          );
        context.drawMesh(
          cube,
          transform: Matrix4.translationValues(x, -0.65, -5)
            ..rotateX(0.6)
            ..rotateY(0.5 + i * 0.2),
        );
      }
    },
  );
}

void main() {
  setUpGpu();

  group('StylizedMaterial base color texture', () {
    testGpuEngine('a white texture that multiplies draws the pixels of no '
        'texture', () async {
      final reference = await _render(textured: false);
      final white = await _render(
        textured: true,
        texture: ColorTexture(const Color(0xFFFFFFFF)),
      );

      expect(
        reference.pixels.count((r, g, b, a) => a > 0),
        greaterThan(6000),
      );
      expect(differingPixels(white.pixels, reference.pixels, tolerance: 0), 0);
      // The same draws: the textured stages batch as the others do.
      expect(white.stats.drawCalls, reference.stats.drawCalls);
    });

    testGpuEngine('the texture colors the surface under the same '
        'lighting', () async {
      final reference = await _render(textured: false);
      // Four vertical bands around the tube: red, white, blue, white.
      final banded = await _render(
        textured: true,
        texture: _texture(
          4,
          1,
          (x, y) => switch (x) {
            0 => const Color(0xFFFF4040),
            2 => const Color(0xFF4060FF),
            _ => const Color(0xFFFFFFFF),
          },
        ),
      );
      // The white bands are drawn as before, the colored ones differ.
      final differing = differingPixels(
        banded.pixels,
        reference.pixels,
        tolerance: 0,
      );
      expect(differing, greaterThan(800));
      expect(
        differing,
        lessThan(reference.pixels.count((r, g, b, a) => a > 0)),
      );
    });

    testGpuEngine('replaces the vertex color and cuts pixels out', () async {
      final backdrop = quad(
        opaqueUnlit(const Color(0xFFFFFF00)),
        halfSize: 0.9,
      );
      Future<Pixels> drawQuad(StylizedMaterial material) async {
        final surface = StylizedMaterial.buildSurface(
          positions: const [
            -0.6,
            -0.6,
            0,
            0.6,
            -0.6,
            0,
            0.6,
            0.6,
            0,
            -0.6,
            0.6,
            0,
          ],
          normals: const [0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1],
          // A green vertex color.
          colors: const [0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1],
          texCoords: const [0, 1, 1, 1, 1, 0, 0, 0],
          indices: const [0, 1, 2, 2, 3, 0],
          material: material,
        );
        final frame = await renderFrame(
          lights: [
            Light(
              position: Vector3.zero(),
              source: AmbientLight(intensity: 1),
            ),
          ],
          draw: (context) => context
            // An opaque yellow wall behind.
            ..drawSurface(
              backdrop,
              transform: Matrix4.translationValues(0, 0, -8),
            )
            ..drawSurface(
              surface,
              transform: Matrix4.translationValues(0, 0, -5),
            ),
        );
        return frame.pixels;
      }

      // Left half magenta, right half transparent.
      final texture = _texture(
        2,
        1,
        (x, y) => x == 0 ? const Color(0xFFFF00FF) : const Color(0x00000000),
      );
      StylizedMaterial material(BaseColorTextureMode mode, double cutoff) =>
          StylizedMaterial(
            baseColorTexture: texture,
            baseColorTextureMode: mode,
            alphaCutoff: cutoff,
          );

      final (lx, ly) = pixelAt(-0.3, 0);
      final (rx, ry) = pixelAt(0.3, 0);

      // Multiplied by green, magenta is black.
      final multiplied = await drawQuad(
        material(BaseColorTextureMode.multiply, 0),
      );
      final (mr, mg, mb, ma) = multiplied.at(lx, ly);
      expect(ma, 255);
      expect(mr + mg + mb, lessThan(30));

      // Replaced, magenta shows.
      final replaced = await drawQuad(
        material(BaseColorTextureMode.replace, 0),
      );
      final (rr, rg, rb, _) = replaced.at(lx, ly);
      expect(rr, greaterThan(150));
      expect(rg, lessThan(40));
      expect(rb, greaterThan(150));
      // Opaque without a cutoff: the transparent half is drawn over the
      // wall, transparent black.
      expect(replaced.at(rx, ry), (0, 0, 0, 0));

      // With a cutoff the transparent half is cut out: the wall shows.
      final cut = await drawQuad(material(BaseColorTextureMode.replace, 0.5));
      expect(cut.at(rx, ry), (255, 255, 0, 255));
      expect(cut.at(lx, ly), replaced.at(lx, ly));
    });

    testGpuEngine('instances of a textured surface are one draw', () async {
      final tube = _Tube();
      final texture = ColorTexture(const Color(0xFFC0A080));
      final textured = tube.surface(
        _material(texture: texture),
        textured: true,
      );
      final plain = tube.surface(_material());
      final frame = await renderFrame(
        width: _width,
        height: _height,
        lights: _lights(),
        draw: (context) {
          for (var i = 0; i < 24; i++) {
            final x = -0.85 + (i % 8) * 0.24;
            final y = 0.5 - (i ~/ 8) * 0.5;
            context
              ..drawSurface(
                textured,
                transform: Matrix4.translationValues(x, y, -5)
                  ..scaleByDouble(0.5, 0.5, 0.5, 1),
              )
              ..drawSurface(
                plain,
                transform: Matrix4.translationValues(x + 0.1, y, -6)
                  ..scaleByDouble(0.5, 0.5, 0.5, 1),
              );
          }
        },
      );
      expect(frame.stats.drawCalls, 2);
    });
  });
}
