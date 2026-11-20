import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter_test/flutter_test.dart';

import 'gpu_test_helpers.dart';

const _width = 256;
const _height = 128;

/// A flat wall facing the default camera, at depth [z]: from x = -1 (along
/// 0) to x = 1 (along 2), its foot at y = -0.5 and its top at y = 0.5, in
/// [columns] by [rows] quads.
///
/// Its normal is [normalZ] along z: towards the camera (its outside faces the
/// viewer, the near side of a closed wall) when positive. With [footAtOrigin]
/// its foot is at y = 0 and its top at y = 1, as a `BarrierMesh`'s: draw it
/// moved down by 0.5.
Surface _wall(
  Material material, {
  double z = -5,
  double normalZ = 1,
  int columns = 1,
  int rows = 1,
  bool footAtOrigin = false,
}) {
  final stride = BarrierMesh.layout.strideInFloats;
  final vertices = Float32List((columns + 1) * (rows + 1) * stride);
  var o = 0;
  for (var j = 0; j <= rows; j++) {
    for (var i = 0; i <= columns; i++) {
      final u = i / columns;
      final v = j / rows;
      vertices
        ..[o] = -1 + 2 * u
        ..[o + 1] = footAtOrigin ? v : v - 0.5
        ..[o + 2] = z
        ..[o + 3] = 2 * u
        ..[o + 4] = v
        ..[o + 5] = 0
        ..[o + 6] = 0
        ..[o + 7] = normalZ;
      o += stride;
    }
  }
  final indices = <int>[];
  for (var j = 0; j < rows; j++) {
    for (var i = 0; i < columns; i++) {
      final a = j * (columns + 1) + i;
      final b = a + 1;
      final c = a + columns + 1;
      final d = c + 1;
      indices.addAll([a, b, d, a, d, c]);
    }
  }
  return Surface.fromBuffers(
    vertices: vertices,
    indices: Uint16List.fromList(indices),
    layout: BarrierMesh.layout,
    material: material,
  );
}

/// A barrier showing only what a test looks at: no pattern, no glint, no
/// foot line, an even white light (unless given colors) that does not thin
/// out with height.
BarrierMaterial _barrier({
  BarrierPattern pattern = BarrierPattern.plain,
  Color footColor = const Color(0xFFFFFFFF),
  Color topColor = const Color(0xFFFFFFFF),
  double heightFalloff = 0.01,
  double intensity = 0.5,
  RenderState renderState = RenderState.additive,
}) {
  return BarrierMaterial(
    pattern: pattern,
    footColor: footColor,
    topColor: topColor,
    heightFalloff: heightFalloff,
    footGlow: 0,
    glintStrength: 0,
    nearSideFade: 0,
    intensity: intensity,
    appearSoftness: 0.1,
    renderState: renderState,
  );
}

/// A barrier that shows nothing but its reactions.
BarrierMaterial _dark({RenderState renderState = RenderState.additive}) {
  return _barrier(
    footColor: const Color(0x00FFFFFF),
    topColor: const Color(0x00FFFFFF),
    intensity: 1,
    renderState: renderState,
  );
}

Future<Frame> _render(
  void Function(RenderContext3D context) draw, {
  Matrix4? projection,
  Matrix4? view,
  int msaa = 1,
}) {
  return renderFrame(
    width: _width,
    height: _height,
    draw: draw,
    projection: projection,
    view: view,
    msaaSampleCount: msaa,
  );
}

/// The height up the default wall (0 at its foot, 1 at its top) at pixel row
/// [row].
double _heightAtRow(int row) => 1 - 2 * (row + 0.5) / _height + 0.5;

/// The pixel row at the height [v] up the default wall.
int _rowAt(double v) => ((1 - (v - 0.5)) / 2 * _height).floor();

/// The pixel column at [x] along the default view.
int _columnAt(double x) => ((x + 1) / 2 * _width).floor();

int _brightness(Pixels pixels, int x, int y) {
  final (r, g, b, _) = pixels.at(x, y);
  return math.max(r, math.max(g, b));
}

/// The brightness of every pixel of row [row].
List<int> _row(Pixels pixels, int row) => [
  for (var x = 0; x < _width; x++) _brightness(pixels, x, row),
];

/// Swaps the shaders of [material] for the barrier's shaders as they were
/// before its controls existed.
void _useReferenceShaders(Material material) {
  material
    ..vertexShader = VertexShader.fromAsset(
      'test/barrier_reference.shaderbundle',
      slots: const [RenderContext3D.cameraMatricesBlock, 'BarrierShape'],
    )
    ..fragmentShader = FragmentShader.fromAsset(
      'test/barrier_reference.shaderbundle',
      slots: const ['BarrierLook'],
    );
}

void main() {
  setUpGpu();

  setUpAll(() async {
    if (gpuAvailable) {
      await registerTestShaders(['barrier_reference']);
    }
  });

  group('BarrierMaterial controls', () {
    testGpuEngine(
      'with the defaults, draws exactly the pixels it drew before them, '
      'with its lean and its full shaders',
      () async {
        final perspective = Matrix4.identity()
          ..setAsPerspective(50, 2, 0.5, 30);
        final mirror = Matrix4.diagonal3Values(-1, 1, 1)
          ..multiply(defaultProjection);

        // Each case: a name, the material, and what to draw.
        final cases =
            <
              (
                String,
                BarrierMaterial Function(),
                void Function(RenderContext3D, BarrierMaterial),
                Matrix4?,
                int,
              )
            >[];
        void wall(RenderContext3D c, BarrierMaterial m) =>
            c.drawSurface(_wall(m));
        void farWall(RenderContext3D c, BarrierMaterial m) =>
            c.drawSurface(_wall(m, normalZ: -1));
        void ring(RenderContext3D c, BarrierMaterial m) {
          final mesh = BarrierMesh.ring(radius: 0.6, height: 0.5, material: m);
          c.drawMesh(
            mesh,
            transform: Matrix4.translationValues(0.1, -0.2, -5)
              ..rotateX(0.9)
              ..rotateY(0.4),
          );
        }

        void box(RenderContext3D c, BarrierMaterial m) {
          final mesh = BarrierMesh.roundedRectangle(
            width: 1.6,
            depth: 1,
            height: 0.6,
            cornerRadius: 0.2,
            material: m,
          );
          m.fitPatternTo(mesh.length, motifLength: 0.3);
          c.drawMesh(
            mesh,
            transform: Matrix4.translationValues(0, -0.4, -4)
              ..rotateX(0.6)
              ..rotateY(-0.5),
            color: const Color(0xCCFFE0C0),
          );
        }

        BarrierMaterial hit(BarrierMaterial m) {
          m
            ..time = 1
            ..impact(Vector3(-0.4, 0.1, -5))
            ..time = 1.2
            ..impact(Vector3(0.1, -0.1, -5), color: const Color(0xFF60C0FF))
            ..time = 1.5
            ..impact(Vector3(0.5, 0.2, -5), color: const Color(0xFFFF8060))
            ..time = 1.75;
          return m;
        }

        // A gap among the slots: slot 0 has ended, 1 and 2 still show.
        BarrierMaterial gap(BarrierMaterial m) {
          hit(m).time = 2.05;
          return m;
        }

        for (final pattern in BarrierPattern.values.take(4)) {
          cases
            ..add((
              'near side, ${pattern.name}',
              () => BarrierMaterial(pattern: pattern)..time = 3.3,
              wall,
              null,
              1,
            ))
            ..add((
              'far side, ${pattern.name}, impacts',
              () => hit(BarrierMaterial(pattern: pattern, patternSpeed: -0.4)),
              farWall,
              null,
              1,
            ));
        }
        cases.addAll([
          (
            'rising, premultiplied',
            () => BarrierMaterial(
              appear: 0.55,
              renderState: RenderState.premultipliedAlphaBlend,
            )..time = 0.7,
            wall,
            null,
            1,
          ),
          (
            'alpha blend, impacts with a gap',
            () => gap(BarrierMaterial(renderState: RenderState.alphaBlend)),
            farWall,
            null,
            1,
          ),
          (
            'four impacts, a fifth replacing the oldest',
            () {
              final m = hit(BarrierMaterial(pattern: BarrierPattern.dashes))
                ..impact(Vector3(-0.7, -0.3, -5))
                ..time = 1.8
                ..impact(Vector3(0.8, 0.3, -5), strength: 0.6)
                ..time = 1.9;
              return m;
            },
            wall,
            null,
            1,
          ),
          (
            'ring, perspective',
            () => hit(BarrierMaterial(pattern: BarrierPattern.dashes)),
            ring,
            perspective,
            1,
          ),
          (
            'ring, mirrored',
            () => hit(BarrierMaterial(pattern: BarrierPattern.diamonds)),
            ring,
            mirror,
            1,
          ),
          (
            'rounded rectangle, tinted, 4x MSAA',
            () => hit(BarrierMaterial())..time = 1.6,
            box,
            perspective,
            4,
          ),
        ]);

        for (final (name, make, draw, projection, msaa) in cases) {
          final shipped = make();
          // The full shaders, for an option that changes nothing here: a
          // fifth impact slot.
          final full = make()..impactSlots = 5;
          final reference = make();
          _useReferenceShaders(reference);
          expect(shipped.usesFullShader, isFalse, reason: name);
          expect(full.usesFullShader, isTrue, reason: name);
          final before = await _render(
            (c) => draw(c, reference),
            projection: projection,
            msaa: msaa,
          );
          expect(
            before.pixels.count((r, g, b, a) => r + g + b > 30),
            greaterThan(250),
            reason: name,
          );
          for (final (variant, material) in [
            ('lean', shipped),
            ('full', full),
          ]) {
            final now = await _render(
              (c) => draw(c, material),
              projection: projection,
              msaa: msaa,
            );
            expect(
              differingPixels(now.pixels, before.pixels, tolerance: 0),
              0,
              reason: '$name, $variant',
            );
          }
        }
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    testGpuEngine('heightScale scales the wall about its foot', () async {
      final material = _barrier();
      final wall = _wall(material, footAtOrigin: true);
      final down = Matrix4.translationValues(0, -0.5, 0);
      Future<Pixels> render(double scale) async {
        material.heightScale = scale;
        return (await _render(
          (c) => c.drawSurface(wall, transform: down),
        )).pixels;
      }

      final full = await render(1);
      final half = await render(0.5);
      final taller = await render(1.4);
      const x = _width ~/ 2;
      // Lit up to the top at 1, to half its height at 0.5, above its top at
      // 1.4 (the wall rises from y = -0.5).
      expect(_brightness(full, x, _rowAt(0.95)), greaterThan(100));
      expect(_brightness(half, x, _rowAt(0.45)), greaterThan(100));
      expect(_brightness(half, x, _rowAt(0.55)), 0);
      expect(_brightness(full, x, _rowAt(1.2)), 0);
      expect(_brightness(taller, x, _rowAt(1.3)), greaterThan(100));
      expect(_brightness(taller, x, _rowAt(1.5)), 0);

      final none = await render(0);
      expect(none.count((r, g, b, a) => r + g + b + a > 0), 0);
    });

    testGpuEngine('fades between fadeStart and fadeEnd', () async {
      final material = _barrier(heightFalloff: 1, intensity: 1)
        ..fadeStart = 0.3
        ..fadeEnd = 0.7;
      final frame = await _render((c) => c.drawSurface(_wall(material)));
      const x = _width ~/ 2;
      // Full below the start, linear between, dark above the end.
      for (final v in const [0.05, 0.2, 0.28]) {
        expect(_brightness(frame.pixels, x, _rowAt(v)), closeTo(255, 2));
      }
      for (final v in const [0.4, 0.5, 0.6]) {
        final row = _rowAt(v);
        final expected = (1 - (_heightAtRow(row) - 0.3) / 0.4) * 255;
        expect(_brightness(frame.pixels, x, row), closeTo(expected, 3));
      }
      for (final v in const [0.75, 0.9]) {
        expect(_brightness(frame.pixels, x, _rowAt(v)), 0);
      }
    });

    testGpuEngine('draws a glowing top edge of its own color', () async {
      final material = _dark()
        ..topEdgeColor = const Color(0xFF00FF00)
        ..topEdgeStrength = 0.8
        ..topEdgeWidth = 0.08;
      final frame = await _render((c) => c.drawSurface(_wall(material)));
      const x = _width ~/ 2;
      final (r, g, b, _) = frame.pixels.at(x, _rowAt(0.99));
      expect(g, closeTo(0.8 * 255, 6));
      expect((r, b), (0, 0));
      // About e^-1 of it a width below the top, nothing far below.
      expect(
        _brightness(frame.pixels, x, _rowAt(0.92)),
        closeTo(0.8 * 255 * math.exp(-1), 12),
      );
      expect(_brightness(frame.pixels, x, _rowAt(0.6)), 0);
    });

    testGpuEngine('fills its body, covering what is behind it under '
        'alpha blending', () async {
      final background = quad(
        opaqueUnlit(const Color(0xFF0000FF)),
        halfSize: 2,
      );
      final behind = Matrix4.translationValues(0, 0, -8);
      Future<(int, int, int, int)> pixel(BarrierMaterial material) async {
        final frame = await _render((c) {
          c
            ..drawSurface(background, transform: behind)
            ..drawSurface(_wall(material));
        });
        return frame.pixels.at(_width ~/ 2, _rowAt(0.5));
      }

      BarrierMaterial filled(RenderState state, double opacity) =>
          _dark(renderState: state)
            ..fillColor = const Color(0xFFFF0000)
            ..fillOpacity = opacity;

      // Premultiplied: 70 % red over the blue.
      final (r, g, b, a) = await pixel(
        filled(RenderState.premultipliedAlphaBlend, 0.7),
      );
      expect(r, closeTo(0.7 * 255, 2));
      expect(b, closeTo(0.3 * 255, 2));
      expect((g, a), (0, 255));
      // Straight alpha: the same.
      final (r2, _, b2, _) = await pixel(filled(RenderState.alphaBlend, 0.7));
      expect(r2, closeTo(0.7 * 255, 2));
      expect(b2, closeTo(0.3 * 255, 2));
      // Additive: the red is added, the blue stays.
      final (r3, _, b3, _) = await pixel(filled(RenderState.additive, 0.7));
      expect(r3, closeTo(0.7 * 255, 2));
      expect(b3, 255);

      // fillFade makes it follow the light's fade.
      final fading = filled(RenderState.premultipliedAlphaBlend, 1)
        ..heightFalloff = 1
        ..fillFade = 1;
      final frame = await _render((c) => c.drawSurface(_wall(fading)));
      final row = _rowAt(0.75);
      expect(
        frame.pixels.at(_width ~/ 2, row).$1,
        closeTo((1 - _heightAtRow(row)) * 255, 3),
      );
    });

    testGpuEngine('draws rows of motifs, thicker lines, its own motif color '
        'and the new motifs', () async {
      BarrierMaterial motifs(BarrierPattern pattern) => _dark()
        ..pattern = pattern
        ..patternHeight = 1
        ..patternStrength = 1
        ..patternScale = 3
        ..patternSpeed = 0
        ..patternTwinkle = 0;

      int lit(Pixels p) => p.count((r, g, b, a) => r + g + b > 120);
      // The number of times the columns at 16 places go from dark to lit.
      int crossings(Pixels p) {
        var count = 0;
        for (var k = 0; k < 16; k++) {
          final x = 7 + k * 15;
          var wasLit = false;
          for (var y = 0; y < _height; y++) {
            final isLit = _brightness(p, x, y) > 60;
            if (isLit && !wasLit) {
              count++;
            }
            wasLit = isLit;
          }
        }
        return count;
      }

      Future<Pixels> render(BarrierMaterial m) async =>
          (await _render((c) => c.drawSurface(_wall(m)))).pixels;

      for (final pattern in BarrierPattern.values.skip(1)) {
        final one = await render(motifs(pattern));
        final three = await render(motifs(pattern)..patternRows = 3);
        final thick = await render(
          motifs(pattern)
            ..patternRows = 3
            ..patternLineWidth = 2,
        );
        expect(lit(one), greaterThan(300), reason: pattern.name);
        expect(
          crossings(three),
          greaterThan(crossings(one) * 1.5),
          reason: pattern.name,
        );
        expect(lit(thick), greaterThan(lit(three) * 1.3), reason: pattern.name);
      }

      final green = await render(
        motifs(BarrierPattern.hexagons)
          ..patternRows = 3
          ..patternColor = const Color(0xFF00FF00),
      );
      expect(green.count((r, g, b, a) => g > 120), greaterThan(300));
      expect(green.count((r, g, b, a) => r > 0 || b > 0), 0);
    });

    testGpuEngine(
      'raises its motifs up the band at patternRiseSpeed',
      () async {
        final material = _dark()
          ..pattern = BarrierPattern.grid
          ..patternHeight = 1
          ..patternStrength = 1
          ..patternRows = 4
          ..patternSpeed = 0
          ..patternTwinkle = 0
          ..patternRiseSpeed = 0.5;
        const x = _width ~/ 2 + 10;
        Future<List<int>> column(double time) async {
          material.time = time;
          final frame = await _render((c) => c.drawSurface(_wall(material)));
          return [
            for (var y = 0; y < _height; y++) _brightness(frame.pixels, x, y),
          ];
        }

        final first = await column(4);
        final second = await column(4.2);
        // 0.1 rows of 32 pixels: about 3 pixels up.
        var best = 0;
        var bestSum = -1;
        for (var shift = -8; shift <= 8; shift++) {
          var sum = 0;
          for (var y = 30; y < _height - 30; y++) {
            sum += first[y] * second[y + shift];
          }
          if (sum > bestSum) {
            bestSum = sum;
            best = shift;
          }
        }
        expect(best, inInclusiveRange(-4, -2));
      },
    );

    testGpuEngine('breaks up its light with noise and flickers', () async {
      final material = _barrier();
      Future<List<int>> row() async => _row(
        (await _render((c) => c.drawSurface(_wall(material)))).pixels,
        _rowAt(0.5),
      );
      double spread(List<int> values) {
        final mean = values.reduce((a, b) => a + b) / values.length;
        return math.sqrt(
          values.map((v) => (v - mean) * (v - mean)).reduce((a, b) => a + b) /
              values.length,
        );
      }

      final flat = await row();
      expect(spread(flat), lessThan(1));
      material.noiseStrength = 0.8;
      final noisy = await row();
      expect(spread(noisy), greaterThan(12));

      material
        ..noiseStrength = 0
        ..flickerStrength = 1
        ..flickerSpeed = 3;
      final levels = <int>{};
      for (var t = 0.0; t < 3; t += 0.37) {
        material.time = t;
        levels.add((await row())[_width ~/ 2]);
      }
      expect(levels.reduce(math.max), lessThanOrEqualTo(flat[_width ~/ 2]));
      expect(levels.reduce(math.min), lessThan(flat[_width ~/ 2] - 30));
    });

    testGpuEngine('thins out the side whose inside faces the viewer', () async {
      final material = _barrier()
        ..nearSideFade = 0
        ..farSideFade = 0.6;
      const x = _width ~/ 2;
      final y = _rowAt(0.5);
      final near = await _render((c) => c.drawSurface(_wall(material)));
      final far = await _render(
        (c) => c.drawSurface(_wall(material, normalZ: -1)),
      );
      final nearValue = _brightness(near.pixels, x, y);
      expect(nearValue, closeTo(128, 2));
      expect(_brightness(far.pixels, x, y), closeTo(nearValue * 0.4, 2));
    });

    testGpuEngine('sends several rings per impact, each dimmer, up to their '
        'reach', () async {
      final material = _dark()
        ..impactRingSpeed = 1
        ..impactRingWidth = 0.03
        ..impactDuration = 2
        ..impactFlashStrength = 0
        ..impactRingCount = 3
        ..impactRingInterval = 0.2;
      final wall = _wall(material);
      material.impact(Vector3(-1, 0, -5));
      material.time = 0.9;
      final frame = await _render((c) => c.drawSurface(wall));
      final row = _row(frame.pixels, _rowAt(0.5));
      int peakNear(List<int> row, double x) {
        final at = _columnAt(x);
        return [for (var i = at - 2; i <= at + 2; i++) row[i]].reduce(math.max);
      }

      // Rings at 0.9, 0.7 and 0.5 units from x = -1: 128 pixels per unit.
      final peaks = [
        for (final d in const [0.9, 0.7, 0.5]) peakNear(row, -1 + d),
      ];
      expect(peaks[0], greaterThan(60));
      expect(peaks[1], closeTo(peaks[0] * 0.7, 6));
      expect(peaks[2], closeTo(peaks[0] * 0.49, 6));
      // Between rings: dark.
      expect(row[_columnAt(-1 + 0.8)], lessThan(4));

      // A reach of 0.7 units hides the outer rings and keeps the inner one.
      material.impactRingReach = 0.7;
      final reached = _row(
        (await _render((c) => c.drawSurface(wall))).pixels,
        _rowAt(0.5),
      );
      expect(peakNear(reached, -1 + 0.9), 0);
      expect(peakNear(reached, -1 + 0.7), 0);
      expect(peakNear(reached, -1 + 0.5), greaterThan(peaks[2] * 0.6));
    });

    testGpuEngine(
      'scales the rings and the flash, and shortens the flash',
      () async {
        final material = _dark()
          ..impactRingSpeed = 1
          ..impactRingWidth = 0.03
          ..impactDuration = 1
          ..impactFlashRadius = 0.05;
        final wall = _wall(material);
        material
          ..impact(Vector3(0, 0, -5))
          ..time = 0.1;
        Future<(int, int)> ringAndFlash() async {
          final row = _row(
            (await _render((c) => c.drawSurface(wall))).pixels,
            _rowAt(0.5),
          );
          return (row[_columnAt(0.1)], row[_width ~/ 2]);
        }

        final (ring, flash) = await ringAndFlash();
        material
          ..impactRingStrength = 0.5
          ..impactFlashStrength = 0.4;
        final (halfRing, halfFlash) = await ringAndFlash();
        expect(halfRing, closeTo(ring * 0.5, 3));
        expect(halfFlash, closeTo(flash * 0.5, 4));

        // A flash that lasts a tenth of the impact is gone at 0.1 s.
        material.impactFlashDuration = 0.1;
        final (_, gone) = await ringAndFlash();
        expect(gone, lessThan(halfFlash ~/ 4));
      },
    );

    testGpuEngine('shows eight impacts at once with eight slots', () async {
      final material = _dark()
        ..impactSlots = 8
        ..impactRingSpeed = 0.001
        ..impactFlashRadius = 0.04
        ..impactDuration = 5;
      final wall = _wall(material);
      for (var i = 0; i < 8; i++) {
        material.impact(Vector3(-0.875 + i * 0.25, 0, -5));
      }
      material.time = 0.05;
      expect(material.activeImpactCount, 8);
      final row = _row(
        (await _render((c) => c.drawSurface(wall))).pixels,
        _rowAt(0.5),
      );
      for (var i = 0; i < 8; i++) {
        expect(row[_columnAt(-0.875 + i * 0.25)], greaterThan(150));
      }
      // With four slots, the last four replaced the first four.
      material
        ..impactSlots = 4
        ..clearImpacts()
        ..time = 0;
      for (var i = 0; i < 8; i++) {
        material.impact(Vector3(-0.875 + i * 0.25, 0, -5));
      }
      material.time = 0.05;
      final four = _row(
        (await _render((c) => c.drawSurface(wall))).pixels,
        _rowAt(0.5),
      );
      expect(four[_columnAt(-0.875)], lessThan(5));
      expect(four[_columnAt(0.875)], greaterThan(150));
    });

    testGpuEngine('wobbles its surface around an impact and settles', () async {
      // Seen at 45 degrees: a move along the wall's normal (z) moves it
      // across the picture.
      final material = _barrier(intensity: 1)
        ..impactRingSpeed = 0
        ..impactFlashStrength = 0
        ..impactDuration = 3
        ..wobbleAmplitude = 0.08
        ..wobbleFrequency = 2
        ..wobbleWavelength = 1
        ..wobbleDecay = 0.5
        ..wobbleRadius = 3
        ..wobbleShading = 0;
      final wall = _wall(material, columns: 40, rows: 4);
      final side = Matrix4.identity()
        ..setAsViewMatrix(
          Vector3(5, 0, 0),
          Vector3(0, 0, -5),
          Vector3(0, 1, 0),
        );
      material.impact(Vector3(0, 0, -5));

      Future<double> centerOfLight(double time) async {
        material.time = time;
        final frame = await _render(
          (c) => c.drawSurface(wall),
          view: side,
        );
        // The mean column of the lit pixels of the middle row.
        final row = _row(frame.pixels, _rowAt(0.5));
        var sum = 0.0;
        var weight = 0.0;
        for (var x = 0; x < _width; x++) {
          sum += x * row[x];
          weight += row[x];
        }
        return weight > 0 ? sum / weight : double.nan;
      }

      // The waves reach the ends of the wall, 1 unit away, after 0.5 s and
      // move its light across the picture.
      final still = await centerOfLight(0);
      var moved = 0.0;
      for (final t in const [0.6, 0.75, 0.9, 1.05]) {
        moved = math.max(moved, (await centerOfLight(t) - still).abs());
      }
      expect(moved, greaterThan(1.5));
      // Once the impact is over, it stands straight again.
      expect(await centerOfLight(3.1), closeTo(still, 0.01));

      // Without the wobble, an impact moves nothing.
      material
        ..wobbleAmplitude = 0
        ..time = 0;
      expect(await centerOfLight(0.75), closeTo(still, 0.01));
    });

    testGpuEngine('pulses: lights up the whole wall and falls back', () async {
      final material = _barrier(intensity: 0.3)
        ..pulseColor = const Color(0xFFFF0000)
        ..pulseDuration = 1
        ..pulseAttack = 0.2;
      final wall = _wall(material);
      Future<(int, int, int, int)> at(double time) async {
        material.time = time;
        return (await _render(
          (c) => c.drawSurface(wall),
        )).pixels.at(_width ~/ 2, _rowAt(0.3));
      }

      final (r0, g0, _, _) = await at(0);
      material.pulse();
      final (r1, g1, _, _) = await at(0.2);
      final (r2, _, _, _) = await at(0.6);
      final (r3, g3, _, _) = await at(1.01);
      expect(r1, greaterThan(r0 + 60));
      expect(g1, g0);
      expect(r2, inExclusiveRange(r0, r1));
      expect((r3, g3), (r0, g0));
    });

    testGpuEngine('glows where a near point comes close', () async {
      final material = _dark()
        ..proximityRadius = 0.5
        ..proximityColor = const Color(0xFF00FFFF);
      final wall = _wall(material);
      material.setNearPoint(0, Vector3(0.5, 0, -5.1));
      final row = _row(
        (await _render((c) => c.drawSurface(wall))).pixels,
        _rowAt(0.5),
      );
      expect(row[_columnAt(0.5)], greaterThan(100));
      expect(row[_columnAt(0.5)], greaterThan(row[_columnAt(0.75)]));
      expect(row[_columnAt(-0.5)], 0);

      material.clearNearPoints();
      final none = await _render((c) => c.drawSurface(wall));
      expect(none.pixels.count((r, g, b, a) => r + g + b > 0), 0);
    });

    testGpuEngine('keeps its hue instead of clipping to white', () async {
      final material = _barrier(
        footColor: const Color(0xFFFFA040),
        topColor: const Color(0xFFFFA040),
        intensity: 2.5,
      );
      Future<(int, int, int, int)> pixel() async => (await _render(
        (c) => c.drawSurface(_wall(material)),
      )).pixels.at(_width ~/ 2, _rowAt(0.5));

      final (_, g, b, _) = await pixel();
      // Clipped: the green and blue run up towards white.
      expect(g, greaterThan(230));
      material.preserveHue = true;
      final (r2, g2, b2, _) = await pixel();
      expect(r2, greaterThan(240));
      expect(g2 / r2, closeTo(0xA0 / 0xFF, 0.03));
      expect(b2 / r2, closeTo(0x40 / 0xFF, 0.03));
      expect(b2, lessThan(b));
    });

    testGpuEngine('draws the reaction over what stands in front of the wall '
        'with reactionInFront', () async {
      final material = _dark()
        ..impactRingSpeed = 1
        ..impactRingWidth = 0.04
        ..impactDuration = 2
        ..impactFlashStrength = 0;
      final wall = BarrierMesh.ring(radius: 0.9, height: 1, material: material);
      // Seen from the side, the ring's far side behind a grey block.
      final transform = Matrix4.translationValues(0, -0.5, -5);
      final block = quad(opaqueUnlit(const Color(0xFF404040)), halfSize: 0.3);
      final blockAt = Matrix4.translationValues(0, 0, -4);
      material
        ..impact(Vector3(0, 0, -5.9))
        ..time = 0.2;

      Future<Frame> render() => _render((c) {
        c
          ..drawSurface(block, transform: blockAt)
          ..drawMesh(wall, transform: transform);
      });

      // The block hides the ring on the far side.
      final hidden = await render();
      expect(_brightness(hidden.pixels, _columnAt(0.15), _rowAt(0.5)), 0x40);

      material.reactionInFront = 1;
      final shown = await render();
      final x = _columnAt(0.15);
      final y = _rowAt(0.5);
      expect(
        shown.pixels.count((r, g, b, a) => r > 0x60),
        greaterThan(hidden.pixels.count((r, g, b, a) => r > 0x60) + 40),
      );
      expect(_brightness(shown.pixels, x, y), greaterThanOrEqualTo(0x40));
      // One more draw, for the reaction.
      expect(shown.stats.drawCalls, hidden.stats.drawCalls + 1);
      // Nothing changes where nothing stands in front of the wall.
      for (var py = 0; py < _height; py++) {
        for (var px = 0; px < _width; px++) {
          final inBlock =
              px >= _columnAt(-0.3) - 1 &&
              px <= _columnAt(0.3) + 1 &&
              py >= _rowAt(0.8) - 1 &&
              py <= _rowAt(0.2) + 1;
          if (!inBlock) {
            expect(
              shown.pixels.at(px, py),
              hidden.pixels.at(px, py),
              reason: '($px, $py)',
            );
          }
        }
      }

      // Without a reaction, no second draw.
      material
        ..clearImpacts()
        ..reactionInFront = 1;
      final calm = await render();
      expect(calm.stats.drawCalls, hidden.stats.drawCalls);
    });
  });
}
