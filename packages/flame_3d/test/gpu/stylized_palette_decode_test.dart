import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flame/game.dart' show GameWidget;
import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/game.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter/widgets.dart' show ObjectKey;
import 'package:flutter_test/flutter_test.dart';

import 'gpu_test_helpers.dart';

// StylizedMaterial packs the accent palette index, the rim palette index and
// the fade of an instance into one float, `instanceData.w`. An instance drawn
// with palette entries must look exactly like the same instance drawn with a
// material of those colors alone: on every pixel (the inside of triangles and
// the MSAA edges alike), at every fade, in every layout and render state.
//
// The fragment stage once decoded that float from its interpolated varying.
// A per-instance constant is not exactly constant once interpolated (least so
// with MSAA, where it is extrapolated to samples outside the triangle), so at
// fade 0 a value a few ulps below its slot boundary decoded the previous slot
// with a fade of nearly 1: thousands of pixels of a sphere came out
// transparent, in the wrong color. Pixel probes at the middle of flat quads,
// slots whose packed value is a power of two and fades of 0.5 did not see it.

const _accents = [
  Color(0xFFFF2020),
  Color(0xFF20FF20),
  Color(0xFF2040FF),
  Color(0xFFFFFF20),
  Color(0xFF20FFFF),
  Color(0xFFFF20FF),
  Color(0xFF808080),
  Color(0xFF804000),
  Color(0xFF004080),
  Color(0xFF408000),
  Color(0xFF800040),
  Color(0xFF400080),
  Color(0xFF008040),
  Color(0xFFFF8000),
  Color(0xFF0080FF),
  Color(0xFF80FF00),
];

const _rims = [
  Color(0xFFFFFFFF),
  Color(0xFFFFC000),
  Color(0xC000E0FF),
  Color(0xFFFF4080),
  Color(0x8080FF80),
  Color(0xFF4060FF),
  Color(0xFFFF6000),
  Color(0xFFE0E0FF),
];

/// The (accent, rim) palette indices of the twelve spheres of a frame, from
/// the lowest slots to the highest (accent 15 with rim 7).
const List<(int?, int?)> _combos = [
  (0, null),
  (1, null),
  (2, null),
  (6, null),
  (14, null),
  (15, null),
  (null, 0),
  (null, 7),
  (3, 0),
  (9, 4),
  (15, 6),
  (15, 7),
];

const _fades = [0.0, 0.25, 1.0];
const _msaaSampleCounts = [1, 4];

const _width = 256;
const _height = 192;

/// Looks from the origin down -z.
final Matrix4 _projection = Matrix4.identity()
  ..setAsPerspective(40, _width / _height, 0.5, 20);

/// The twelve spheres of a frame, four by three, apart from each other.
final List<Matrix4> _transforms = [
  for (final y in [0.9, 0.0, -0.9])
    for (final x in [-1.35, -0.45, 0.45, 1.35])
      Matrix4.translationValues(x, y, -4),
];

final List<Light> _lights = [
  Light(position: Vector3.zero(), source: AmbientLight(intensity: 0.5)),
  Light(
    position: Vector3.zero(),
    source: DirectionalLight(direction: Vector3(0.4, -0.6, -1)..normalize()),
  ),
];

final List<Matrix4> _joints = [Matrix4.identity()];

enum _Layout() {
  /// StylizedMaterial.vertexLayout, accent mask everywhere.
  stylized,

  /// StylizedMaterial.skinnedVertexLayout, accent mask everywhere.
  skinned,

  /// The standard layout: no accent mask, so only the rims show.
  standard,
}

enum _State() {
  opaque,
  translucent,
  singlePieceTranslucent,
  ditherFade,
}

StylizedMaterial _material(
  _State state, {
  Color accentColor = const Color(0xFFFFFFFF),
  List<Color> accentPalette = const [],
  List<Color> rimPalette = const [],
}) {
  return StylizedMaterial(
    accentColor: accentColor,
    accentPalette: accentPalette,
    rimPalette: rimPalette,
    rimPaletteStrength: 0.9,
    translucent:
        state == _State.translucent || state == _State.singlePieceTranslucent,
    singlePieceTranslucent: state == _State.singlePieceTranslucent,
    ditherFade: state == _State.ditherFade,
  );
}

/// A sphere of radius 0.4 and [n] x [n] quads in [layout], drawn with
/// [material].
Surface _sphere(_Layout layout, Material material, {int n = 24}) {
  final positions = <double>[];
  final normals = <double>[];
  for (var a = 0; a <= n; a++) {
    final theta = math.pi * a / n;
    for (var b = 0; b <= n; b++) {
      final phi = 2 * math.pi * b / n;
      final x = math.sin(theta) * math.cos(phi);
      final y = math.cos(theta);
      final z = math.sin(theta) * math.sin(phi);
      positions.addAll([x * 0.4, y * 0.4, z * 0.4]);
      normals.addAll([x, y, z]);
    }
  }
  final indices = <int>[];
  for (var a = 0; a < n; a++) {
    for (var b = 0; b < n; b++) {
      final i0 = a * (n + 1) + b;
      final i1 = i0 + 1;
      final i2 = i0 + n + 1;
      final i3 = i2 + 1;
      indices.addAll([i0, i2, i1, i1, i2, i3]);
    }
  }
  final count = positions.length ~/ 3;
  if (layout == _Layout.standard) {
    return Surface(
      vertices: [
        for (var i = 0; i < count; i++)
          Vertex(
            position: Vector3(
              positions[i * 3],
              positions[i * 3 + 1],
              positions[i * 3 + 2],
            ),
            texCoord: Vector2.zero(),
            normal: Vector3(
              normals[i * 3],
              normals[i * 3 + 1],
              normals[i * 3 + 2],
            ),
          ),
      ],
      indices: indices,
      material: material,
    );
  }
  final skinned = layout == _Layout.skinned;
  return StylizedMaterial.buildSurface(
    positions: positions,
    normals: normals,
    accent: List.filled(count, 1),
    joints: skinned ? List.filled(count * 4, 0) : null,
    weights: skinned
        ? [
            for (var i = 0; i < count; i++) ...const [1.0, 0.0, 0.0, 0.0],
          ]
        : null,
    indices: indices,
    material: material,
  );
}

/// Renders the twelve spheres of [surface], sphere `i` drawn with
/// `material(i)` and the instance data `(0, 0, 0, w(i))`.
Future<Pixels> _render(
  Surface surface, {
  required int msaa,
  required Material Function(int i) material,
  required double Function(int i) w,
}) async {
  final skinned = surface.layout == StylizedMaterial.skinnedVertexLayout;
  final frame = await renderFrame(
    width: _width,
    height: _height,
    projection: _projection,
    lights: _lights,
    msaaSampleCount: msaa,
    draw: (context) {
      for (var i = 0; i < _combos.length; i++) {
        context.drawSurface(
          surface,
          transform: _transforms[i],
          instanceData: Vector4(0, 0, 0, w(i)),
          jointTransforms: skinned ? _joints : null,
          material: material(i),
        );
      }
    },
  );
  return frame.pixels;
}

/// The packed `w` of sphere [i] with every palette entry: its own accent and
/// rim.
double _packed(int i, double fade) {
  final (accent, rim) = _combos[i];
  return StylizedMaterial.packPaletteAndFade(
    accent: accent,
    rim: rim,
    fade: fade,
  );
}

/// The `w` of sphere [i] drawn with its own material, whose accent color is
/// the sphere's and whose rim palette holds only the sphere's rim: a plain
/// fade, or rim 0 with that fade.
double _separate(int i, double fade) {
  final (_, rim) = _combos[i];
  return StylizedMaterial.packPaletteAndFade(
    rim: rim == null ? null : 0,
    fade: fade,
  );
}

/// The largest difference of a channel between [a] and [b], and the number
/// of pixels that differ.
(int, int) _compare(Pixels a, Pixels b, {bool alphaOnly = false}) {
  expect(a.width, b.width);
  expect(a.height, b.height);
  var largest = 0;
  var pixels = 0;
  for (var i = 0; i < a.rgba.length; i += 4) {
    var differs = false;
    for (var c = alphaOnly ? 3 : 0; c < 4; c++) {
      final d = (a.rgba[i + c] - b.rgba[i + c]).abs();
      if (d > 0) {
        differs = true;
        largest = math.max(largest, d);
      }
    }
    if (differs) {
      pixels++;
    }
  }
  return (largest, pixels);
}

/// Checks, for [layout] and [state], every MSAA sample count and fade: the
/// spheres drawn with one material and its palettes match, channel for
/// channel, the spheres drawn with one material each; their alpha matches
/// spheres drawn without palettes.
Future<void> _expectPalettesExact(_Layout layout, _State state) async {
  final palette = _material(
    state,
    accentPalette: _accents,
    rimPalette: _rims,
  );
  final separate = [
    for (final (accent, rim) in _combos)
      _material(
        state,
        accentColor: accent == null
            ? const Color(0xFFFFFFFF)
            : _accents[accent],
        rimPalette: [if (rim != null) _rims[rim]],
      ),
  ];
  final plain = _material(state);
  final surface = _sphere(layout, palette);
  expect(
    surface.layout,
    switch (layout) {
      _Layout.stylized => same(StylizedMaterial.vertexLayout),
      _Layout.skinned => same(StylizedMaterial.skinnedVertexLayout),
      _Layout.standard => isNot(
        anyOf(
          same(StylizedMaterial.vertexLayout),
          same(StylizedMaterial.skinnedVertexLayout),
        ),
      ),
    },
  );

  for (final msaa in _msaaSampleCounts) {
    for (final fade in _fades) {
      final packed = await _render(
        surface,
        msaa: msaa,
        material: (_) => palette,
        w: (i) => _packed(i, fade),
      );
      final reference = await _render(
        surface,
        msaa: msaa,
        material: (i) => separate[i],
        w: (i) => _separate(i, fade),
      );
      final unpacked = await _render(
        surface,
        msaa: msaa,
        material: (_) => plain,
        w: (_) => fade,
      );
      final where = '$layout, $state, MSAA $msaa, fade $fade';
      final covered = unpacked.count((r, g, b, a) => a > 0);
      if (fade < 1) {
        expect(covered, greaterThan(12 * 1500), reason: where);
      }
      final (largest, pixels) = _compare(packed, reference);
      expect(
        (largest, pixels),
        (0, 0),
        reason:
            '$where: palettes against one material per color, '
            '(largest channel difference, differing pixels) of $covered '
            'covered pixels',
      );
      final (alphaLargest, alphaPixels) = _compare(
        packed,
        unpacked,
        alphaOnly: true,
      );
      expect(
        (alphaLargest, alphaPixels),
        (0, 0),
        reason:
            '$where: alpha with palettes against alpha without, '
            '(largest difference, differing pixels) of $covered covered '
            'pixels',
      );
    }
  }
}

void main() {
  setUpGpu();

  group('StylizedMaterial palette decoding', () {
    test('decodes every slot and fade exactly in 32-bit floats', () {
      // The value rounded to a 32-bit float, as the GPU holds it.
      double f32(double value) => (Float32List(1)..[0] = value)[0];
      // Multiples of 1/64 (0 and 1 included) are packed as they are; others
      // are rounded to a multiple of 1/16384 at most.
      final fades = [for (var k = 0; k <= 64; k++) k / 64, 0.1, 0.3, 0.7];
      for (
        var accent = -1;
        accent < StylizedMaterial.maxAccentPaletteSize;
        accent++
      ) {
        for (var rim = -1; rim < StylizedMaterial.maxRimPaletteSize; rim++) {
          for (final fade in fades) {
            final w = f32(
              StylizedMaterial.packPaletteAndFade(
                accent: accent < 0 ? null : accent,
                rim: rim < 0 ? null : rim,
                fade: fade,
              ),
            );
            if (accent < 0 && rim < 0) {
              expect(w, f32(fade));
              continue;
            }
            // What the vertex stage computes, rounding every step.
            final slot = f32(w * 0.25).floorToDouble();
            final decoded = f32(w - f32(slot * 4));
            expect(slot, (accent + 1) + 17 * (rim + 1));
            // No step rounded anything.
            expect(decoded, w - slot * 4);
            expect(decoded, closeTo(fade, 1 / 32768));
            if (fade * 64 == (fade * 64).roundToDouble()) {
              expect(decoded, fade);
            }
          }
        }
      }
    });

    for (final layout in _Layout.values) {
      for (final state in _State.values) {
        testGpuEngine(
          'matches one material per color: $layout, $state',
          () => _expectPalettesExact(layout, state),
        );
      }
    }

    testGpu('matches one material per color under weighted blended OIT, '
        'with shadows and the depth-normal prepass', (tester) async {
      final ground = StylizedMaterial(rimStrength: 0, specularStrength: 0);
      final groundSurface = StylizedMaterial.buildSurface(
        positions: const [-3, -3, 0, 3, -3, 0, 3, 3, 0, -3, 3, 0],
        normals: const [0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1],
        indices: const [0, 1, 2, 0, 2, 3],
        material: ground,
      );

      World3D world(
        Material Function(int i) material,
        double Function(int i) w,
      ) {
        return World3D(
          oitMode: OitMode3D.weightedBlended,
          depthPrepassEnabled: true,
          children: [
            LightComponent.ambient(intensity: 0.5),
            LightComponent.directional(
              direction: Vector3(0.3, -0.4, -1)..normalize(),
              shadows: ShadowSettings(),
            ),
            MeshComponent(
              mesh: Mesh()..addSurface(groundSurface),
              position: Vector3(0, 0, -5),
            ),
            for (var i = 0; i < _combos.length; i++)
              MeshComponent(
                mesh: Mesh()
                  ..addSurface(_sphere(_Layout.stylized, material(i))),
                position: _transforms[i].getTranslation(),
                instanceData: Vector4(0, 0, 0, w(i)),
              ),
          ],
        );
      }

      Future<Pixels> snapshot(World3D world, Msaa msaa) async {
        final game = FlameGame3D(world: world);
        await tester.pumpWidget(GameWidget(key: ObjectKey(game), game: game));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 16));
        return (await tester.runAsync(() async {
          final device = GraphicsDevice();
          final context = RenderContext3D(device);
          device.begin();
          final image = world.renderToImage(
            const Size(_width + 0.0, _height + 0.0),
            view: Matrix4.identity(),
            projection: _projection,
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

      final palette = _material(
        _State.translucent,
        accentPalette: _accents,
        rimPalette: _rims,
      );
      final separate = [
        for (final (accent, rim) in _combos)
          _material(
            _State.translucent,
            accentColor: accent == null
                ? const Color(0xFFFFFFFF)
                : _accents[accent],
            rimPalette: [if (rim != null) _rims[rim]],
          ),
      ];
      for (final msaa in Msaa.values) {
        for (final fade in _fades) {
          final packed = await snapshot(
            world((_) => palette, (i) => _packed(i, fade)),
            msaa,
          );
          final reference = await snapshot(
            world((i) => separate[i], (i) => _separate(i, fade)),
            msaa,
          );
          expect(
            _compare(packed, reference),
            (0, 0),
            reason: '$msaa, fade $fade',
          );
        }
      }
    });
  });
}
