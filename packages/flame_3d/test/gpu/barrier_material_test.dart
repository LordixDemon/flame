import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Color, Size;

import 'package:flame/game.dart' show GameWidget;
import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/game.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter/widgets.dart' show ObjectKey;
import 'package:flutter_test/flutter_test.dart';

import 'gpu_test_helpers.dart';

const _width = 256;
const _height = 128;

/// A flat wall facing the default camera, at depth [z]: from x = -1 (along
/// 0) to x = 1 (along 2), its foot at y = -0.5 and its top at y = 0.5.
///
/// Its normal is [normalZ] along z: towards the camera (its outside faces the
/// viewer, the near side of a closed wall) when positive.
Surface _wall(Material material, {double z = -5, double normalZ = 1}) {
  final n = normalZ;
  final vertices = Float32List.fromList([
    -1, -0.5, z, 0, 0, 0, 0, n, //
    1, -0.5, z, 2, 0, 0, 0, n, //
    1, 0.5, z, 2, 1, 0, 0, n, //
    -1, 0.5, z, 0, 1, 0, 0, n, //
  ]);
  return Surface.fromBuffers(
    vertices: vertices,
    indices: Uint16List.fromList([0, 1, 2, 0, 2, 3]),
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
  double appear = 1,
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
    appear: appear,
    appearSoftness: 0.1,
    renderState: renderState,
  );
}

Future<Frame> _render(
  void Function(RenderContext3D context) draw, {
  Matrix4? projection,
  Matrix4? view,
}) {
  return renderFrame(
    width: _width,
    height: _height,
    draw: draw,
    projection: projection,
    view: view,
  );
}

/// The height up the default wall (0 at its foot, 1 at its top) at pixel row
/// [row].
double _heightAtRow(int row) => 1 - 2 * (row + 0.5) / _height + 0.5;

/// The pixel row at the height [v] up the default wall.
int _rowAt(double v) => ((1 - (v - 0.5)) / 2 * _height).floor();

int _brightness(Pixels pixels, int x, int y) {
  final (r, g, b, _) = pixels.at(x, y);
  return math.max(r, math.max(g, b));
}

void main() {
  setUpGpu();

  group('BarrierMaterial', () {
    testGpuEngine('draws nothing at an appear factor of 0', () async {
      final background = quad(
        opaqueUnlit(const Color(0xFF404040)),
        halfSize: 2,
      );
      final backgroundTransform = Matrix4.translationValues(0, 0, -8);
      final wall = _wall(_barrier(appear: 0, intensity: 2));

      final without = await _render((context) {
        context.drawSurface(background, transform: backgroundTransform);
      });
      final hidden = await _render((context) {
        context
          ..drawSurface(background, transform: backgroundTransform)
          ..drawSurface(wall);
      });
      expect(differingPixels(without.pixels, hidden.pixels, tolerance: 0), 0);

      final alone = await _render((context) => context.drawSurface(wall));
      expect(alone.pixels.count((r, g, b, a) => r + g + b + a > 0), 0);
    });

    testGpuEngine('rises from its foot with the appear factor', () async {
      for (final appear in const [0.25, 0.5, 0.75, 1.0]) {
        final frame = await _render(
          (context) => context.drawSurface(_wall(_barrier(appear: appear))),
        );
        final front = appear * 1.1;
        for (var row = _rowAt(0.999); row <= _rowAt(0.001); row++) {
          final v = _heightAtRow(row);
          final value = _brightness(frame.pixels, _width ~/ 2, row);
          if (v < front - 0.13) {
            expect(value, greaterThan(100), reason: 'appear $appear, v $v');
          } else if (v > front + 0.02) {
            expect(value, 0, reason: 'appear $appear, v $v');
          }
        }
      }
    });

    testGpuEngine('is brightest at its foot and thins out above', () async {
      final frame = await _render(
        (context) => context.drawSurface(
          _wall(_barrier(heightFalloff: 1.8, intensity: 1)),
        ),
      );
      var previous = 256;
      for (var row = _rowAt(0.02); row >= _rowAt(0.98); row--) {
        final value = _brightness(frame.pixels, _width ~/ 2, row);
        expect(value, lessThanOrEqualTo(previous + 1), reason: 'row $row');
        previous = value;
      }
      // (1 - v) ^ 1.8 of the light at the foot.
      for (final v in const [0.03, 0.3, 0.6]) {
        final row = _rowAt(v);
        final expected = math.pow(1 - _heightAtRow(row), 1.8) * 255;
        expect(
          _brightness(frame.pixels, _width ~/ 2, row),
          closeTo(expected, 2),
        );
      }
    });

    testGpuEngine('thins out the side that faces the viewer', () async {
      final material = _barrier()..nearSideFade = 0.75;
      final near = await _render(
        (context) => context.drawSurface(_wall(material)),
      );
      final far = await _render(
        (context) => context.drawSurface(_wall(material, normalZ: -1)),
      );
      const x = _width ~/ 2;
      final y = _rowAt(0.5);
      final farValue = _brightness(far.pixels, x, y);
      expect(farValue, closeTo(128, 2));
      expect(_brightness(near.pixels, x, y), closeTo(farValue * 0.25, 2));
    });

    testGpuEngine('adds its light and keeps the alpha of the target', () async {
      final wall = _wall(_barrier(intensity: 0.4));
      final grey = quad(opaqueUnlit(const Color(0xFF404040)), halfSize: 2);
      final greyTransform = Matrix4.translationValues(0, 0, -8);

      final alone = await _render((context) => context.drawSurface(wall));
      final over = await _render((context) {
        context
          ..drawSurface(grey, transform: greyTransform)
          ..drawSurface(wall);
      });
      const x = _width ~/ 2;
      final y = _rowAt(0.5);
      final (r, g, b, a) = alone.pixels.at(x, y);
      // Light added over a transparent target leaves it transparent.
      expect(a, 0);
      expect(r, greaterThan(90));
      expect((g, b), (r, r));
      // Over the grey, the light is added to it.
      final (r2, g2, b2, a2) = over.pixels.at(x, y);
      expect(a2, 255);
      expect(r2, closeTo(0x40 + r, 2));
      expect((g2, b2), (r2, r2));
    });

    testGpuEngine('blends as a veil with premultiplied alpha', () async {
      final frame = await _render(
        (context) => context.drawSurface(
          _wall(
            _barrier(
              intensity: 0.4,
              renderState: RenderState.premultipliedAlphaBlend,
            ),
          ),
        ),
      );
      final (r, g, b, a) = frame.pixels.at(_width ~/ 2, _rowAt(0.5));
      expect(r, greaterThan(90));
      expect((g, b, a), (r, r, r));
    });

    testGpuEngine('is hidden behind opaque geometry', () async {
      final wall = _wall(_barrier());
      final front = quad(opaqueUnlit(const Color(0xFF0000FF)));
      final frame = await _render((context) {
        context
          ..drawSurface(wall)
          ..drawSurface(front, transform: Matrix4.translationValues(-1, 0, -2));
      });
      final row = _rowAt(0.5);
      expect(frame.pixels.at(_width ~/ 8, row), (0, 0, 255, 255));
      expect(_brightness(frame.pixels, _width * 3 ~/ 4, row), greaterThan(90));
    });

    testGpuEngine('moves its pattern along the wall at its speed', () async {
      // Only the motifs: the wall's own light is zero.
      final material = _barrier(
        pattern: BarrierPattern.chevrons,
        footColor: const Color(0x00FFFFFF),
        topColor: const Color(0x00FFFFFF),
        intensity: 1,
      )..patternHeight = 0.6;
      material
        ..patternScale = 2
        ..patternSpeed = 0.25;
      final wall = _wall(material);
      final row = _rowAt(0.18);

      Future<List<int>> rowAt(double time) async {
        material.time = time;
        final frame = await _render((context) => context.drawSurface(wall));
        return [
          for (var x = 0; x < _width; x++) _brightness(frame.pixels, x, row),
        ];
      }

      final first = await rowAt(10);
      final second = await rowAt(10.4);
      expect(first.reduce(math.max), greaterThan(80));
      // The shift that lines up the two rows best: 0.1 units at 128 pixels
      // per unit, towards +x (the direction along the wall).
      var bestShift = 0;
      var best = -1.0;
      for (var shift = -40; shift <= 40; shift++) {
        var sum = 0.0;
        for (var x = 48; x < _width - 48; x++) {
          sum += first[x] * second[x + shift];
        }
        if (sum > best) {
          best = sum;
          bestShift = shift;
        }
      }
      expect(bestShift, inInclusiveRange(12, 14));
    });

    testGpuEngine('sends a ring across the wall from an impact that expands '
        'and dies', () async {
      final material =
          _barrier(
              footColor: const Color(0x00FFFFFF),
              topColor: const Color(0x00FFFFFF),
              intensity: 1,
            )
            ..impactRingSpeed = 1
            ..impactRingWidth = 0.03
            ..impactDuration = 1
            ..impactFlashRadius = 0.05;
      final wall = _wall(material);
      material.impact(Vector3(0, 0, -5));
      final row = _rowAt(0.5);

      Future<(int, int)> ringAt(double time) async {
        material.time = time;
        final frame = await _render((context) => context.drawSurface(wall));
        // The brightest pixel right of the center: the ring's distance from
        // the impact, in pixels, and its brightness.
        var peak = 0;
        var at = 0;
        for (var x = _width ~/ 2 + 12; x < _width; x++) {
          final value = _brightness(frame.pixels, x, row);
          if (value > peak) {
            peak = value;
            at = x;
          }
        }
        return (at - _width ~/ 2, peak);
      }

      final (near, nearPeak) = await ringAt(0.3);
      final (far, farPeak) = await ringAt(0.6);
      expect(near, closeTo(0.3 * 128, 2));
      expect(far, closeTo(0.6 * 128, 2));
      expect(farPeak, lessThan(nearPeak));
      expect(farPeak, greaterThan(20));

      material.time = 1.05;
      final over = await _render((context) => context.drawSurface(wall));
      expect(over.pixels.count((r, g, b, a) => r + g + b > 0), 0);
      expect(material.activeImpactCount, 0);
    });

    testGpuEngine('lights each impact in its own color', () async {
      final material = _barrier(
        footColor: const Color(0x00FFFFFF),
        topColor: const Color(0x00FFFFFF),
        intensity: 1,
      );
      final wall = _wall(material);
      material
        ..impact(Vector3(-0.5, 0, -5), color: const Color(0xFFFF0000))
        ..impact(Vector3(0.5, 0, -5), color: const Color(0xFF0000FF))
        ..time = 0.05;
      final frame = await _render((context) => context.drawSurface(wall));
      final row = _rowAt(0.5);
      final (r1, g1, b1, _) = frame.pixels.at(_width ~/ 4, row);
      final (r2, g2, b2, _) = frame.pixels.at(_width * 3 ~/ 4, row);
      expect(r1, greaterThan(150));
      expect((g1, b1), (0, 0));
      expect(b2, greaterThan(150));
      expect((r2, g2), (0, 0));
    });

    testGpuEngine(
      'draws the mirror image under a mirroring projection',
      () async {
        final material = BarrierMaterial(pattern: BarrierPattern.dashes)
          ..time = 3.3
          ..impact(Vector3(0.3, 0.1, -4.4), color: const Color(0xFF60C0FF));
        material.time = 3.5;
        final ring = BarrierMesh.ring(
          radius: 0.6,
          height: 0.5,
          material: material,
        );
        // Tilted towards the camera: the inside, the outside and the edges
        // seen at grazing angles all show.
        final transform = Matrix4.translationValues(0.1, -0.2, -5)
          ..rotateX(0.9)
          ..rotateY(0.4);
        void draw(RenderContext3D context) {
          context.drawMesh(ring, transform: transform);
        }

        final plain = await _render(draw);
        final mirror = Matrix4.diagonal3Values(-1, 1, 1)
          ..multiply(defaultProjection);
        final mirrored = await _render(draw, projection: mirror);

        expect(plain.pixels.count((r, g, b, a) => r > 40), greaterThan(2000));
        var differing = 0;
        for (var y = 0; y < _height; y++) {
          for (var x = 0; x < _width; x++) {
            final a = plain.pixels.at(x, y);
            final b = mirrored.pixels.at(_width - 1 - x, y);
            if ((a.$1 - b.$1).abs() > 2 ||
                (a.$2 - b.$2).abs() > 2 ||
                (a.$3 - b.$3).abs() > 2) {
              differing++;
            }
          }
        }
        expect(differing, lessThan(20));
      },
    );

    testGpu('blooms where it goes above white in an HDR scene', (
      tester,
    ) async {
      Future<Pixels> render({required bool hdr}) async {
        final material = _barrier(intensity: 3, heightFalloff: 1);
        final world = World3D(
          hdrEnabled: hdr,
          bloom: hdr ? BloomSettings(threshold: 0.9, intensity: 1) : null,
          children: [MeshComponent(mesh: Mesh()..addSurface(_wall(material)))],
        );
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
            projection: defaultProjection,
            clearValue: const Color(0xFF000000),
            device: device,
            context: context,
          );
          device.end();
          final pixels = await readImage(image);
          image.dispose();
          return pixels;
        }))!;
      }

      final ldr = await render(hdr: false);
      final hdr = await render(hdr: true);
      // Just below the foot, outside the wall: dark without bloom, lit by
      // the bloom of the bright foot with it.
      final below = _rowAt(-0.06);
      expect(_brightness(ldr, _width ~/ 2, below), 0);
      expect(_brightness(hdr, _width ~/ 2, below), greaterThan(8));
      // The foot is white either way.
      expect(_brightness(ldr, _width ~/ 2, _rowAt(0.05)), 255);
      expect(_brightness(hdr, _width ~/ 2, _rowAt(0.05)), greaterThan(240));
    });

    testGpu('is left out of the shadow passes and the depth-normal prepass', (
      tester,
    ) async {
      Future<RenderStats> render({required bool barrier}) async {
        final world = World3D(
          depthPrepassEnabled: true,
          children: [
            LightComponent.directional(
              direction: Vector3(0.2, -1, -0.3)..normalize(),
              shadows: ShadowSettings(),
            ),
            MeshComponent(
              mesh: CuboidMesh(
                size: Vector3.all(0.5),
                material: opaqueUnlit(const Color(0xFF808080)),
              ),
              position: Vector3(0, -0.6, -5),
            ),
            if (barrier)
              MeshComponent(
                mesh: BarrierMesh.ring(
                  radius: 0.8,
                  height: 0.6,
                  material: BarrierMaterial(),
                ),
                position: Vector3(0, -0.8, -5),
              ),
          ],
        );
        final game = FlameGame3D(world: world);
        await tester.pumpWidget(GameWidget(key: ObjectKey(game), game: game));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 16));
        return (await tester.runAsync(() async {
          final device = GraphicsDevice();
          final context = RenderContext3D(device);
          device.begin();
          world
              .renderToImage(
                const Size(64, 64),
                view: Matrix4.identity(),
                projection: defaultProjection,
                device: device,
                context: context,
              )
              .dispose();
          device.end();
          return RenderStats()..setFrom(device.lastFrameStats);
        }))!;
      }

      final without = await render(barrier: false);
      final withBarrier = await render(barrier: true);
      expect(without.shadowDrawCalls, greaterThan(0));
      expect(withBarrier.shadowDrawCalls, without.shadowDrawCalls);
      // One draw more: the main pass's, none in the prepass.
      expect(withBarrier.drawCalls, without.drawCalls + 1);
    });
  });
}
