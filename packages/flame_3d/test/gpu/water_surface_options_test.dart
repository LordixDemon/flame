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

// WaterMaterial's options (caustics, sparkles, the swell of the normals, the
// depth ramp, the foam mask, ripples) are off by default: the material must
// then draw exactly as its shaders of before did
// (test/gpu/shaders/water_reference.*). Each option is checked on its own:
// the caustics are anchored to the world and loop over their period, the
// depth ramp makes the water more opaque where it is deeper, the foam mask
// foams where it says and nowhere else, ripples spread at their speed and
// die after their lifetime, and the surface stays one draw.

const _size = 128;

/// One 6 by 6 water surface in the standard layout, flat on y = 0.
TerrainMesh3D _terrain(WaterMaterial material) => TerrainMesh3D(
  columns: 32,
  rows: 32,
  width: 6,
  depth: 6,
  heights: Float32List(32 * 32),
  material: material,
);

/// A strip of water in [WaterMaterial.vertexLayout] from x = -3 to 3 and
/// z = -1 to 1 on y = 0, [columns] cells long, whose vertices take the depth
/// and foam mask [depth] and [foam] give for their x.
Mesh _strip(
  WaterMaterial material, {
  double Function(double x)? depth,
  double Function(double x)? foam,
  int columns = 48,
}) {
  final positions = <double>[];
  final depths = <double>[];
  final foams = <double>[];
  final indices = <int>[];
  for (var i = 0; i <= columns; i++) {
    final x = -3 + 6 * i / columns;
    for (final z in [-1.0, 1.0]) {
      positions.addAll([x, 0, z]);
      depths.add(depth?.call(x) ?? 1);
      foams.add(foam?.call(x) ?? 0);
    }
    if (i < columns) {
      final a = i * 2;
      // Counter-clockwise seen from +y.
      indices.addAll([a, a + 1, a + 3, a, a + 3, a + 2]);
    }
  }
  return Mesh()..addSurface(
    WaterMaterial.buildSurface(
      positions: positions,
      depths: depths,
      foam: foams,
      indices: indices,
      material: material,
    ),
  );
}

/// A top-down orthographic view of the plane y = 0, `width` world units
/// across, centered on ([x], [z]): world x goes right, world z down.
Matrix4 _topView({double x = 0, double z = 0}) =>
    Matrix4.identity()
      ..setAsViewMatrix(Vector3(x, 10, z), Vector3(x, 0, z), Vector3(0, 0, -1));

Matrix4 _topProjection(double width) =>
    Matrix4.identity()..setAsOrthographic(width, 1, 0.1, 30);

/// The pixels of [world] and the statistics of its frame.
Future<Frame> _render(
  WidgetTester tester,
  World3D world, {
  required Matrix4 view,
  required Matrix4 projection,
  int width = _size,
  int height = _size,
  Msaa msaa = Msaa.off,
  Color clear = const Color(0x00000000),
}) async {
  // Mounted, so that the shadows are fitted to its components.
  final game = FlameGame3D(world: world);
  await tester.pumpWidget(GameWidget(key: ObjectKey(game), game: game));
  await tester.pump();
  return (await tester.runAsync(() async {
    final device = GraphicsDevice();
    final context = RenderContext3D(device);
    device.begin();
    final image = world.renderToImage(
      Size(width.toDouble(), height.toDouble()),
      view: view,
      projection: projection,
      msaa: msaa,
      clearValue: clear,
      device: device,
      context: context,
    );
    device.end();
    final stats = RenderStats()..setFrom(device.lastFrameStats);
    final pixels = await readImage(image);
    image.dispose();
    return Frame(pixels, stats);
  }))!;
}

/// Replaces the shaders of [material] by those of before its options.
void _useShadersOfBefore(WaterMaterial material) {
  material
    ..vertexShader = VertexShader.fromAsset(
      'test/water_reference.shaderbundle',
      slots: [RenderContext3D.cameraMatricesBlock, 'WaterVertex'],
    )
    ..fragmentShader = FragmentShader.fromAsset(
      'test/water_reference.shaderbundle',
      slots: [
        'WaterMaterial',
        RenderContext3D.stylizedPassBlock,
        RenderContext3D.shadowMapSampler,
        RenderContext3D.depthNormalSampler,
        RenderContext3D.depthNormalBlock,
        RenderContext3D.sceneColorSampler,
        RenderContext3D.sceneColorBlock,
      ],
    );
}

/// The number of channels of [a] and [b] that differ, and the largest
/// difference.
(int, int) _compare(Pixels a, Pixels b) {
  var count = 0;
  var largest = 0;
  for (var i = 0; i < a.rgba.length; i++) {
    final d = (a.rgba[i] - b.rgba[i]).abs();
    if (d > 0) {
      count++;
      largest = math.max(largest, d);
    }
  }
  return (count, largest);
}

int _brightness(Pixels p, int x, int y) {
  final (r, g, b, _) = p.at(x, y);
  return r + g + b;
}

/// A material with only the options a test turns on: no waves and no
/// micro-ripples, so that nothing else moves.
WaterMaterial _still({
  double causticStrength = 0,
  double sparkleStrength = 0,
  double depthRange = 0,
  double time = 0,
  WaterRipples? ripples,
  double opacity = 1,
}) {
  return WaterMaterial(
    waveAmplitude: 0,
    rippleStrength: 0,
    opacity: opacity,
    time: time,
    causticStrength: causticStrength,
    causticScale: 0.5,
    sparkleStrength: sparkleStrength,
    depthRange: depthRange,
    ripples: ripples,
  );
}

List<Component3D> _sunAndSky() => [
  LightComponent.directional(direction: Vector3(0.3, -1, 0.2)),
  LightComponent.hemisphere(
    skyColor: const Color(0xFF9CC8FF),
    groundColor: const Color(0xFF404040),
  ),
];

void main() {
  setUpGpu();

  group('WaterMaterial options', () {
    setUpAll(() async {
      if (gpuAvailable) {
        await registerTestShaders(['water_reference']);
      }
    });

    testGpu('are off by default: the pixels of before, exactly', (
      tester,
    ) async {
      // Every light, shadows, fog, waves, micro-ripples, translucent and
      // opaque, +Y and +Z up, perspective and parallel, with and without
      // MSAA.
      for (final zUp in [false, true]) {
        for (final opacity in [0.86, 1.0]) {
          World3D scene(WaterMaterial water) {
            Vector3 v(double x, double y, double z) =>
                zUp ? Vector3(z, x, y) : Vector3(x, y, z);
            return World3D(
              fog: FogSettings(start: 2, end: 14, up: v(0, 1, 0)),
              children: [
                LightComponent.directional(
                  direction: v(-0.4, -1, -0.3),
                  intensity: 1.2,
                  shadows: ShadowSettings(resolution: 512),
                ),
                LightComponent.point(
                  position: v(1, 1.2, 1),
                  color: const Color(0xFFFFB060),
                  intensity: 3,
                  range: 4,
                ),
                LightComponent.spot(
                  position: v(-1.5, 2, 0),
                  direction: v(0.3, -1, 0),
                  intensity: 4,
                  outerConeAngle: 0.6,
                ),
                LightComponent.hemisphere(
                  up: v(0, 1, 0),
                  skyColor: const Color(0xFFA0C8FF),
                ),
                MeshComponent(
                  mesh: CuboidMesh(
                    size: Vector3.all(0.6),
                    material: StylizedMaterial(),
                  ),
                  position: v(0.5, 0.3, -0.5),
                ),
                MeshComponent(
                  rotation: zUp
                      ? Quaternion.fromRotation(
                          Matrix3.columns(
                            Vector3(0, 1, 0),
                            Vector3(0, 0, 1),
                            Vector3(1, 0, 0),
                          ),
                        )
                      : null,
                  mesh: _terrain(water),
                ),
              ],
            );
          }

          WaterMaterial water({required bool before}) {
            final material = WaterMaterial(
              opacity: opacity,
              time: 1.3,
              rippleStrength: 0.2,
              upAxis: zUp ? Vector3(0, 0, 1) : null,
            );
            if (before) {
              _useShadersOfBefore(material);
            }
            return material;
          }

          final eye = zUp ? Vector3(3, 1.2, 3.2) : Vector3(1.2, 3.2, 3);
          final up = zUp ? Vector3(0, 0, 1) : Vector3(0, 1, 0);
          for (final perspective in [true, false]) {
            final view = Matrix4.identity()
              ..setAsViewMatrix(eye, Vector3.zero(), up);
            final projection = perspective
                ? (Matrix4.identity()..setAsPerspective(50, 1, 0.5, 40))
                : (Matrix4.identity()..setAsOrthographic(7, 1, -20, 20));
            for (final msaa in [Msaa.off, Msaa.sample4]) {
              final where =
                  'zUp $zUp, opacity $opacity, perspective $perspective, '
                  '$msaa';
              final now = await _render(
                tester,
                scene(water(before: false)),
                view: view,
                projection: projection,
                msaa: msaa,
              );
              final before = await _render(
                tester,
                scene(water(before: true)),
                view: view,
                projection: projection,
                msaa: msaa,
              );
              expect(
                now.pixels.count((r, g, b, a) => a > 0),
                greaterThan(_size * _size ~/ 3),
                reason: where,
              );
              expect(_compare(now.pixels, before.pixels), (
                0,
                0,
              ), reason: where);
            }
          }
        }
      }
    });

    testGpu('caustics are anchored to the world and loop over the period', (
      tester,
    ) async {
      Future<Pixels> render({
        double x = 0,
        double time = 0.6,
        bool mirrored = false,
        double strength = 1,
      }) async {
        final projection = _topProjection(4);
        if (mirrored) {
          projection.setEntry(0, 0, -projection.entry(0, 0));
        }
        return (await _render(
          tester,
          World3D(
            children: [
              ..._sunAndSky(),
              MeshComponent(
                mesh: _terrain(_still(causticStrength: strength, time: time)),
              ),
            ],
          ),
          view: _topView(x: x),
          projection: projection,
        )).pixels;
      }

      final without = await render(strength: 0);
      final with_ = await render();
      // The network brightens some pixels, and not others.
      var brighter = 0;
      for (var y = 0; y < _size; y++) {
        for (var x = 0; x < _size; x++) {
          if (_brightness(with_, x, y) > _brightness(without, x, y) + 30) {
            brighter++;
          }
        }
      }
      expect(brighter, greaterThan(_size * _size ~/ 20));
      expect(brighter, lessThan(_size * _size * 3 ~/ 4));

      // A camera moved by 16 pixels (half a world unit) sees the same
      // network, moved by 16 pixels: it does not swim with the view.
      final moved = await render(x: 0.5);
      var differing = 0;
      for (var y = 0; y < _size; y++) {
        for (var x = 0; x < _size - 16; x++) {
          final a = with_.at(x + 16, y);
          final b = moved.at(x, y);
          if ((a.$1 - b.$1).abs() > 2 ||
              (a.$2 - b.$2).abs() > 2 ||
              (a.$3 - b.$3).abs() > 2) {
            differing++;
          }
        }
      }
      expect(differing, lessThan(_size));

      // A mirrored projection shows its mirror image.
      final mirrored = await render(mirrored: true);
      var mirrorDiffering = 0;
      for (var y = 0; y < _size; y++) {
        for (var x = 0; x < _size; x++) {
          final a = with_.at(x, y);
          final b = mirrored.at(_size - 1 - x, y);
          if ((a.$1 - b.$1).abs() > 2 ||
              (a.$2 - b.$2).abs() > 2 ||
              (a.$3 - b.$3).abs() > 2) {
            mirrorDiffering++;
          }
        }
      }
      expect(mirrorDiffering, lessThan(_size));

      // One period (8 s by default) later, the same picture.
      final later = await render(time: 8.6);
      expect(differingPixels(with_, later, tolerance: 1), 0);
      // Half a period later, another one.
      final half = await render(time: 4.6);
      expect(differingPixels(with_, half), greaterThan(_size * 4));
    });

    testGpu('sparkles flash in the light', (tester) async {
      Future<Pixels> render(double strength, {double sun = 1}) async {
        return (await _render(
          tester,
          World3D(
            children: [
              LightComponent.directional(
                direction: Vector3(0.3, -1, 0.2),
                intensity: sun,
              ),
              LightComponent.ambient(intensity: 0.4),
              MeshComponent(
                mesh: _terrain(_still(sparkleStrength: strength, time: 0.3)),
              ),
            ],
          ),
          view: _topView(),
          projection: _topProjection(4),
        )).pixels;
      }

      final without = await render(0);
      final with_ = await render(3);
      final dark = await render(3, sun: 0);
      final darkWithout = await render(0, sun: 0);
      final flashes = differingPixels(without, with_, tolerance: 20);
      expect(flashes, greaterThan(20));
      // Small points: a few percent of the surface at most.
      expect(flashes, lessThan(_size * _size ~/ 10));
      // Without the light, no sparkle.
      expect(differingPixels(dark, darkWithout), 0);
    });

    testGpu('the depth ramp makes deeper water more opaque and darker', (
      tester,
    ) async {
      final water = WaterMaterial(
        waveAmplitude: 0,
        rippleStrength: 0,
        opacity: 0.9,
        shallowOpacity: 0.1,
        depthRange: 0.8,
        shallowColor: const Color(0xFF80E0F0),
        deepColor: const Color(0xFF103060),
      );
      final frame = await _render(
        tester,
        World3D(
          children: [
            LightComponent.ambient(intensity: 1),
            MeshComponent(mesh: _strip(water, depth: (x) => (x + 3) * 0.5)),
          ],
        ),
        view: _topView(),
        projection: _topProjection(6),
      );
      final pixels = frame.pixels;
      const row = _size ~/ 2;
      var previousAlpha = -1;
      var previousBlue = 999.0;
      for (var x = 2; x < _size - 2; x += 4) {
        final (_, _, b, a) = pixels.at(x, row);
        expect(a, greaterThanOrEqualTo(previousAlpha - 1), reason: 'x $x');
        // Blended over transparent black, the target holds the color times
        // the alpha: divided by it, the water's own color darkens.
        final blue = b / a;
        expect(blue, lessThanOrEqualTo(previousBlue + 0.02), reason: 'x $x');
        previousAlpha = a;
        previousBlue = blue;
      }
      expect(
        pixels.at(_size - 3, row).$4,
        greaterThan(pixels.at(2, row).$4 + 120),
      );
      expect(pixels.at(2, row).$4, lessThan(70));
    });

    testGpu('the foam mask foams where it says, and nowhere else', (
      tester,
    ) async {
      Future<Pixels> render({required bool foam}) async {
        final water = _still();
        return (await _render(
          tester,
          World3D(
            children: [
              ..._sunAndSky(),
              MeshComponent(
                mesh: _strip(
                  water,
                  foam: foam ? (x) => x < -1 ? 1.0 : 0.0 : null,
                ),
              ),
            ],
          ),
          view: _topView(),
          projection: _topProjection(6),
        )).pixels;
      }

      final plain = await render(foam: false);
      final foamy = await render(foam: true);
      // Left of x = -1.125 (the last vertex of mask 1 is at x = -1.125, the
      // first of mask 0 at x = -1): foam, solid towards the left.
      var white = 0;
      for (var y = 40; y < 88; y++) {
        for (var x = 0; x < 32; x++) {
          final (r, g, b, _) = foamy.at(x, y);
          if (r > 200 && g > 200 && b > 200) {
            white++;
          }
        }
      }
      expect(white, greaterThan(32 * 48 ~/ 3));
      // Right of x = -1, exactly the water without foam.
      for (var y = 0; y < _size; y++) {
        for (var x = 46; x < _size; x++) {
          expect(foamy.at(x, y), plain.at(x, y), reason: '$x, $y');
        }
      }
    });

    testGpu('ripples spread at their speed and die after their lifetime', (
      tester,
    ) async {
      final ripples = WaterRipples();
      ripples.add(
        Vector3.zero(),
        time: 1,
        speed: 1,
        wavelength: 0.2,
        trail: 2,
        lifetime: 2,
      );
      Future<Pixels> render(double time, {bool withRipples = true}) async {
        return (await _render(
          tester,
          World3D(
            children: [
              ..._sunAndSky(),
              MeshComponent(
                mesh: _terrain(
                  _still(time: time, ripples: withRipples ? ripples : null),
                ),
              ),
            ],
          ),
          view: _topView(),
          projection: _topProjection(4),
        )).pixels;
      }

      /// The distance from the center, in world units (32 pixels per unit),
      /// of the farthest pixel of the row through the center that the ripple
      /// changed.
      double front(Pixels a, Pixels b) {
        const row = _size ~/ 2;
        var farthest = 0;
        for (var x = _size ~/ 2; x < _size; x++) {
          if ((_brightness(a, x, row) - _brightness(b, x, row)).abs() > 6) {
            farthest = x - _size ~/ 2;
          }
        }
        return farthest / 32;
      }

      for (final age in [0.6, 1.2]) {
        final reference = await render(1 + age, withRipples: false);
        final rippled = await render(1 + age);
        // The front is `speed * age` from the center; the packet rises up
        // to 0.6 wavelengths ahead of it.
        expect(
          front(rippled, reference),
          closeTo(age + 0.06, 0.08),
          reason: 'age $age',
        );
      }
      // Before it starts and after its lifetime, the water is untouched.
      for (final time in [0.9, 3.0, 3.5]) {
        final reference = await render(time, withRipples: false);
        final rippled = await render(time);
        expect(_compare(rippled, reference), (0, 0), reason: 'time $time');
      }
    });

    testGpu('the surface is one draw, with every option, instanced', (
      tester,
    ) async {
      final ripples = WaterRipples()
        ..add(Vector3.zero(), time: 0)
        ..add(Vector3(1, 0, 1), time: 0.2);
      final water = WaterMaterial(
        time: 0.5,
        causticStrength: 0.5,
        sparkleStrength: 1,
        detailStrength: 0.5,
        depthRange: 0.6,
        opacity: 0.8,
        ripples: ripples,
      );
      final mesh = _strip(water, foam: (x) => x < 0 ? 0.5 : 0);
      final frame = await _render(
        tester,
        World3D(
          children: [
            ..._sunAndSky(),
            MeshComponent(mesh: mesh),
            MeshComponent(mesh: mesh, position: Vector3(0, 0, 2)),
          ],
        ),
        view: _topView(z: 1),
        projection: _topProjection(7),
      );
      expect(frame.stats.drawCalls, 1);
      expect(frame.stats.instances, 2);
    });
  });
}
