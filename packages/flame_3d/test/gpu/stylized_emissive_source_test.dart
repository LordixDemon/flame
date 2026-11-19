import 'dart:math' as math;
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

// StylizedMaterial.emissiveColorSource: the vertices of the emissive mask glow
// in a color of their instance (its color, its accent, its rim palette entry)
// instead of the material's emissive color, so that the instances of one mesh
// glow in colors of their own in one draw. An instance must look exactly like
// the same instance drawn with a material whose emissive color is its glow
// color: on every pixel, MSAA edges included, in every layout and render
// state, at every strength. The default source must draw exactly as the
// material did before it had sources.

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

/// Six of the eight entries a rim palette may hold, so that indices 6 and 7
/// pick nothing. The alpha of an entry is the strength of its rim, which the
/// glow does not use: entry 2 glows without a rim.
const _rims = [
  Color(0xFFFFFFFF),
  Color(0xFFFFC000),
  Color(0x0000E0FF),
  Color(0xC0FF4080),
  Color(0x8080FF80),
  Color(0xFF4060FF),
];

const _emissive = Color(0xFFFFE0A0);
const _boostColor = Color(0xFF30FFD0);
const _accentColor = Color(0xFFC8C8C8);

/// The twelve spheres of a frame: their accent and rim palette indices (or
/// none), instance color, emissive boost and fade. The fades are multiples of
/// `1 / 64`, which packing keeps as they are (see packPaletteAndFade).
const List<(int?, int?, Color, double, double)> _spheres = [
  (0, null, Color(0xFFE04030), 0, 0),
  (5, 0, Color(0xFF30C060), 0.25, 0.25),
  (15, 3, Color(0xFF3050E0), 1, 0),
  (null, 1, Color(0xFFF0D020), 0, 0.5),
  (9, 7, Color(0xC0A040E0), 0.6, 0),
  (null, null, Color(0xFF20D0D0), 0, 0.25),
  (3, 2, Color(0xFFFFFFFF), 0.4, 0),
  (14, 5, Color(0xFF101010), 1.5, 0),
  (1, 6, Color(0xFF8020FF), 0, 0),
  (7, 4, Color(0xFFFF8080), 0.1, 0.25),
  (12, 0, Color(0xFF406080), 0.8, 0.5),
  (2, null, Color(0xFFE0E0E0), 0.3, 0),
];

/// The emissive strength and boost color of a material: no glow without a
/// boost, a partial glow, a full glow towards a boost color of its own.
const List<(double, Color?)> _strengths = [
  (0, null),
  (0.6, null),
  (1, _boostColor),
];

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
  /// StylizedMaterial.vertexLayout, with masks that vary over the sphere.
  stylized,

  /// StylizedMaterial.skinnedVertexLayout, with the same masks.
  skinned,

  /// The standard layout: no emissive mask, so nothing glows.
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
  EmissiveColorSource source = EmissiveColorSource.emissiveColor,
  Color emissiveColor = _emissive,
  double emissiveStrength = 1,
  Color? emissiveBoostColor,
  Color accentColor = _accentColor,
  List<Color> accentPalette = const [],
  List<Color> rimPalette = const [],
}) {
  return StylizedMaterial(
    emissiveColorSource: source,
    emissiveColor: emissiveColor,
    emissiveStrength: emissiveStrength,
    emissiveBoostColor: emissiveBoostColor,
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
/// [material]. In the stylized layouts its emissive mask goes from `0` at
/// the bottom to `1` at the top, its tint mask from left to right and its
/// accent mask from back to front, and it is glossy.
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
    emissive: [for (var i = 0; i < count; i++) 0.5 + 0.5 * normals[i * 3 + 1]],
    tint: [for (var i = 0; i < count; i++) 0.5 + 0.5 * normals[i * 3]],
    accent: [for (var i = 0; i < count; i++) 0.5 + 0.5 * normals[i * 3 + 2]],
    gloss: List.filled(count, 0.5),
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
/// `material(i)`, its instance color and the instance data
/// `(boost, 0, 0, w(i))`.
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
      for (var i = 0; i < _spheres.length; i++) {
        final (_, _, color, boost, _) = _spheres[i];
        context.drawSurface(
          surface,
          transform: _transforms[i],
          color: color,
          instanceData: Vector4(boost, 0, 0, w(i)),
          jointTransforms: skinned ? _joints : null,
          material: material(i),
        );
      }
    },
  );
  return frame.pixels;
}

/// Whether sphere [i] picks an entry of [_rims].
bool _hasRim(int i) {
  final rim = _spheres[i].$2;
  return rim != null && rim < _rims.length;
}

/// The accent of sphere [i]: its palette entry, or the accent color.
Color _accentOf(int i) {
  final accent = _spheres[i].$1;
  return accent == null ? _accentColor : _accents[accent];
}

/// The color sphere [i] glows in with [source].
Color _glowOf(int i, EmissiveColorSource source) => switch (source) {
  EmissiveColorSource.emissiveColor => _emissive,
  EmissiveColorSource.instanceColor => _spheres[i].$3,
  EmissiveColorSource.accent => _accentOf(i),
  EmissiveColorSource.rim => _hasRim(i) ? _rims[_spheres[i].$2!] : _emissive,
};

/// The packed `w` of sphere [i] with every palette entry: its own accent and
/// rim, and its fade.
double _packed(int i) {
  final (accent, rim, _, _, fade) = _spheres[i];
  return StylizedMaterial.packPaletteAndFade(
    accent: accent,
    rim: rim,
    fade: fade,
  );
}

/// The `w` of sphere [i] drawn with its own material, whose rim palette holds
/// only the sphere's rim: a plain fade, or rim 0 with that fade.
double _separate(int i) {
  return StylizedMaterial.packPaletteAndFade(
    rim: _hasRim(i) ? 0 : null,
    fade: _spheres[i].$5,
  );
}

/// The largest difference of a channel between [a] and [b], and the number
/// of pixels that differ.
(int, int) _compare(Pixels a, Pixels b) {
  expect(a.width, b.width);
  expect(a.height, b.height);
  var largest = 0;
  var pixels = 0;
  for (var i = 0; i < a.rgba.length; i += 4) {
    var differs = false;
    for (var c = 0; c < 4; c++) {
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

const _instanceSources = [
  EmissiveColorSource.instanceColor,
  EmissiveColorSource.accent,
  EmissiveColorSource.rim,
];

/// Checks, for [layout] and [state], every instance source, MSAA sample count
/// and strength: the spheres drawn with one material glowing in their own
/// colors match, channel for channel, the spheres drawn with one material
/// each, glowing in its emissive color.
Future<void> _expectSourcesExact(_Layout layout, _State state) async {
  for (final (strength, boostColor) in _strengths) {
    final plain = _material(
      state,
      emissiveStrength: strength,
      emissiveBoostColor: boostColor,
      accentPalette: _accents,
      rimPalette: _rims,
    );
    final surface = _sphere(layout, plain);
    for (final source in _instanceSources) {
      final shared = _material(
        state,
        source: source,
        emissiveStrength: strength,
        emissiveBoostColor: boostColor,
        accentPalette: _accents,
        rimPalette: _rims,
      );
      final separate = [
        for (var i = 0; i < _spheres.length; i++)
          _material(
            state,
            emissiveColor: _glowOf(i, source),
            emissiveStrength: strength,
            emissiveBoostColor: boostColor,
            accentColor: _accentOf(i),
            rimPalette: [if (_hasRim(i)) _rims[_spheres[i].$2!]],
          ),
      ];
      for (final msaa in _msaaSampleCounts) {
        final where =
            '$layout, $state, $source, MSAA $msaa, strength '
            '$strength, boost color $boostColor';
        final glowing = await _render(
          surface,
          msaa: msaa,
          material: (_) => shared,
          w: _packed,
        );
        final reference = await _render(
          surface,
          msaa: msaa,
          material: (i) => separate[i],
          w: _separate,
        );
        final covered = reference.count((r, g, b, a) => a > 0);
        expect(covered, greaterThan(12 * 1000), reason: where);
        expect(
          _compare(glowing, reference),
          (0, 0),
          reason:
              '$where: (largest channel difference, differing pixels) of '
              '$covered covered pixels',
        );

        // The source changes the picture where the spheres glow; in the
        // standard layout, which has no emissive mask, it changes nothing.
        final unsourced = await _render(
          surface,
          msaa: msaa,
          material: (_) => plain,
          w: _packed,
        );
        final (_, changed) = _compare(glowing, unsourced);
        if (layout == _Layout.standard) {
          expect(changed, 0, reason: '$where: no emissive mask, no glow');
        } else {
          expect(changed, greaterThan(3000), reason: where);
        }
      }
    }
  }
}

/// Checks, for [layout] and [state], that the material with the default
/// source draws exactly as its fragment shader of before did, with palettes,
/// boosts, fades, strengths and a boost color.
Future<void> _expectDefaultAsBefore(_Layout layout, _State state) async {
  for (final (strength, boostColor) in _strengths) {
    StylizedMaterial material({required bool before}) {
      final material = _material(
        state,
        emissiveStrength: strength,
        emissiveBoostColor: boostColor,
        accentPalette: _accents,
        rimPalette: _rims,
      );
      if (before) {
        material.fragmentShader = FragmentShader.fromAsset(
          'test/stylized_emissive_reference.shaderbundle',
          slots: [
            'matCapTexture',
            'gemMatCapTexture',
            'Material',
            RenderContext3D.stylizedPassBlock,
            RenderContext3D.shadowMapSampler,
          ],
        );
      }
      return material;
    }

    final now = material(before: false);
    final before = material(before: true);
    final surface = _sphere(layout, now);
    for (final msaa in _msaaSampleCounts) {
      final where =
          '$layout, $state, MSAA $msaa, strength $strength, '
          'boost color $boostColor';
      final pixels = await _render(
        surface,
        msaa: msaa,
        material: (_) => now,
        w: _packed,
      );
      final reference = await _render(
        surface,
        msaa: msaa,
        material: (_) => before,
        w: _packed,
      );
      expect(
        reference.count((r, g, b, a) => a > 0),
        greaterThan(12 * 1000),
        reason: where,
      );
      expect(_compare(pixels, reference), (0, 0), reason: where);
    }
  }
}

void main() {
  setUpGpu();

  group('StylizedMaterial emissive color sources', () {
    test('defaults to the emissive color', () {
      expect(
        StylizedMaterial().emissiveColorSource,
        EmissiveColorSource.emissiveColor,
      );
      // The shader numbers them in this order.
      expect(EmissiveColorSource.values, [
        EmissiveColorSource.emissiveColor,
        EmissiveColorSource.instanceColor,
        EmissiveColorSource.accent,
        EmissiveColorSource.rim,
      ]);
    });

    for (final layout in _Layout.values) {
      for (final state in _State.values) {
        testGpuEngine(
          'match one material per glow color: $layout, $state',
          () => _expectSourcesExact(layout, state),
        );
      }
    }

    for (final layout in _Layout.values) {
      for (final state in _State.values) {
        testGpuEngine('the default draws as before: $layout, $state', () async {
          await registerTestShaders(['stylized_emissive_reference']);
          await _expectDefaultAsBefore(layout, state);
        });
      }
    }

    testGpuEngine('keeps one draw call for every glow color', () async {
      final material = _material(
        _State.opaque,
        source: EmissiveColorSource.instanceColor,
      );
      final surface = _sphere(_Layout.stylized, material);
      final frame = await renderFrame(
        projection: _projection,
        lights: _lights,
        draw: (context) {
          for (var i = 0; i < _spheres.length; i++) {
            context.drawSurface(
              surface,
              transform: _transforms[i],
              color: _spheres[i].$3,
            );
          }
        },
      );
      expect(frame.stats.drawCalls, 1);
      expect(frame.stats.instances, _spheres.length);
    });

    testGpuEngine('leaves the shadow pass alone', () async {
      final lights = [
        Light(position: Vector3.zero(), source: AmbientLight(intensity: 0.3)),
        Light(
          position: Vector3.zero(),
          source: DirectionalLight(
            direction: Vector3(0.3, 0, -1),
            shadows: ShadowSettings(),
          ),
        ),
      ];
      final ground = StylizedMaterial.buildSurface(
        positions: const [-1, -1, 0, 1, -1, 0, 1, 1, 0, -1, 1, 0],
        normals: const [0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1],
        indices: const [0, 1, 2, 0, 2, 3],
        material: StylizedMaterial(rimStrength: 0, specularStrength: 0),
      );

      Future<Pixels> render(EmissiveColorSource source) async {
        final material = _material(
          _State.opaque,
          source: source,
          rimPalette: _rims,
        );
        final caster = _sphere(_Layout.stylized, material);
        final device = GraphicsDevice();
        final context = RenderContext3D(device);
        void draw(RenderContext3D context) => context
          ..drawSurface(ground, transform: Matrix4.translationValues(0, 0, -5))
          ..drawSurface(
            caster,
            transform: Matrix4.translationValues(-0.3, 0, -2),
            color: const Color(0xFF2040FF),
            instanceData: Vector4(
              1,
              0,
              0,
              StylizedMaterial.packPaletteAndFade(rim: 1),
            ),
          );
        device.begin();
        context
          ..lights = lights
          ..setCamera(defaultView, defaultProjection);
        if (context.beginShadowPass(
          projection: DirectionalShadowProjection(),
          sceneBounds: Aabb3.minMax(Vector3(-1, -1, -5), Vector3(1, 1, -1.7)),
        )) {
          draw(context);
          context.endShadowPass();
        }
        device.beginPass(const Size(64, 64), frontFace: context.frontFace);
        draw(context);
        context.flush();
        final image = device.endPass();
        device.end();
        final pixels = await readImage(image);
        image.dispose();
        return pixels;
      }

      final plain = await render(EmissiveColorSource.emissiveColor);
      final (sx, sy) = pixelAt(0.6, 0);
      final (gx, gy) = pixelAt(0.6, 0.85);
      expect(plain.at(sx, sy).$1, lessThan(plain.at(gx, gy).$1 - 30));
      for (final source in _instanceSources) {
        final glowing = await render(source);
        // The ground, in and out of the shadow, is the same...
        expect(glowing.at(sx, sy), plain.at(sx, sy), reason: '$source');
        expect(glowing.at(gx, gy), plain.at(gx, gy), reason: '$source');
        // ...only the sphere, glowing in another color, differs.
        final changed = differingPixels(plain, glowing);
        expect(changed, greaterThan(100), reason: '$source');
        expect(changed, lessThan(900), reason: '$source');
      }
    });

    testGpu('match one material per glow color under weighted blended OIT, '
        'HDR and bloom, with shadows and the depth-normal prepass', (
      tester,
    ) async {
      final ground = StylizedMaterial(rimStrength: 0, specularStrength: 0);
      final groundSurface = StylizedMaterial.buildSurface(
        positions: const [-3, -3, 0, 3, -3, 0, 3, 3, 0, -3, 3, 0],
        normals: const [0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1],
        indices: const [0, 1, 2, 0, 2, 3],
        material: ground,
      );

      World3D world(
        Material Function(int i) material,
        double Function(int i) w, {
        required bool bloom,
      }) {
        return World3D(
          oitMode: OitMode3D.weightedBlended,
          depthPrepassEnabled: true,
          hdrEnabled: true,
          bloom: bloom ? BloomSettings(threshold: 0.6) : null,
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
            for (var i = 0; i < _spheres.length; i++)
              MeshComponent(
                mesh: Mesh()
                  ..addSurface(_sphere(_Layout.stylized, material(i))),
                position: _transforms[i].getTranslation(),
                color: _spheres[i].$3,
                instanceData: Vector4(_spheres[i].$4, 0, 0, w(i)),
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

      for (final source in _instanceSources) {
        final shared = _material(
          _State.translucent,
          source: source,
          emissiveStrength: 0.6,
          accentPalette: _accents,
          rimPalette: _rims,
        );
        final separate = [
          for (var i = 0; i < _spheres.length; i++)
            _material(
              _State.translucent,
              emissiveColor: _glowOf(i, source),
              emissiveStrength: 0.6,
              accentColor: _accentOf(i),
              rimPalette: [if (_hasRim(i)) _rims[_spheres[i].$2!]],
            ),
        ];
        for (final msaa in Msaa.values) {
          final glowing = await snapshot(
            world((_) => shared, _packed, bloom: true),
            msaa,
          );
          final reference = await snapshot(
            world((i) => separate[i], _separate, bloom: true),
            msaa,
          );
          expect(
            _compare(glowing, reference),
            (0, 0),
            reason: '$source, $msaa',
          );
        }
        // The glow reaches the bloom: it spreads light around the spheres.
        final unbloomed = await snapshot(
          world((_) => shared, _packed, bloom: false),
          Msaa.off,
        );
        final bloomed = await snapshot(
          world((_) => shared, _packed, bloom: true),
          Msaa.off,
        );
        expect(differingPixels(unbloomed, bloomed), greaterThan(1000));
      }
    });
  });
}
