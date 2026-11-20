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

// The foam controls of WaterMaterial (foamLightTint, edgeFoamMotion,
// foamSources) and of the water volume (waterlineLightTint) are neutral by
// default: the materials then draw exactly the pixels of the shaders of
// before them (test/gpu/shaders/reference/water_foam_fragment.glsl and
// stylized_volume_foam_fragment.glsl), with every other option on. Each
// control is then checked for what it does: the lit foam keeps its own color
// under a colored light, the mask's foam stands still while the caustics
// move, and foam sources draw collars where they are, and only there.

const _size = 128;

/// 32 pixels per world unit in the top views.
const _pixelsPerUnit = 32.0;

/// A grid of water in [WaterMaterial.vertexLayout] over x = -[half] to
/// [half] and z = -[half] to [half] (in a `+Y`-up world; [v] maps the
/// coordinates for other worlds), [cells] cells a side, whose vertices take
/// the depth and foam mask [depth] and [foam] give for their (x, z).
Mesh _grid(
  WaterMaterial material, {
  double half = 2,
  int cells = 32,
  double Function(double x, double z)? depth,
  double Function(double x, double z)? foam,
  Vector3 Function(double x, double y, double z)? v,
}) {
  final positions = <double>[];
  final depths = <double>[];
  final foams = <double>[];
  final indices = <int>[];
  for (var j = 0; j <= cells; j++) {
    final z = -half + 2 * half * j / cells;
    for (var i = 0; i <= cells; i++) {
      final x = -half + 2 * half * i / cells;
      final p = v?.call(x, 0, z) ?? Vector3(x, 0, z);
      positions.addAll([p.x, p.y, p.z]);
      depths.add(depth?.call(x, z) ?? 1);
      foams.add(foam?.call(x, z) ?? 0);
    }
  }
  for (var j = 0; j < cells; j++) {
    for (var i = 0; i < cells; i++) {
      final a = j * (cells + 1) + i;
      final b = a + cells + 1;
      // Counter-clockwise seen from +y.
      indices.addAll([a, b, b + 1, a, b + 1, a + 1]);
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

/// A top-down orthographic view of the plane y = 0, centered on the origin:
/// world x goes right, world z down.
final Matrix4 _topView = Matrix4.identity()
  ..setAsViewMatrix(Vector3(0, 10, 0), Vector3.zero(), Vector3(0, 0, -1));

/// [_size] pixels for 4 world units.
final Matrix4 _topProjection = Matrix4.identity()
  ..setAsOrthographic(_size / _pixelsPerUnit, 1, 0.1, 30);

/// The pixel of the top view where the world point (x, 0, z) lands.
(int, int) _pixel(double x, double z) => (
  (_size / 2 + x * _pixelsPerUnit).floor(),
  (_size / 2 + z * _pixelsPerUnit).floor(),
);

Future<Frame> _render(
  WidgetTester tester,
  World3D world, {
  Matrix4? view,
  Matrix4? projection,
  Msaa msaa = Msaa.off,
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
      const Size(_size + 0.0, _size + 0.0),
      view: view ?? _topView,
      projection: projection ?? _topProjection,
      msaa: msaa,
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

/// Replaces the fragment stage of [material] by the one of before the foam
/// controls (both vertex stages are unchanged).
void _useFragmentOfBefore(WaterMaterial material) {
  material.fragmentShader = FragmentShader.fromAsset(
    'test/water_foam_reference.shaderbundle',
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

int _brightness(Pixels p, int x, int y) {
  final (r, g, b, _) = p.at(x, y);
  return r + g + b;
}

/// Whether the pixel at ([x], [y]) of [a] and [b] is the same, exactly.
bool _same(Pixels a, Pixels b, int x, int y) => a.at(x, y) == b.at(x, y);

/// A warm, low sun and a dusk sky.
List<Component3D> _duskLights() => [
  LightComponent.directional(
    direction: Vector3(0.5, -0.45, 0.3),
    color: const Color(0xFFFF8A4C),
  ),
  LightComponent.hemisphere(
    skyColor: const Color(0xFF8F86C0),
    groundColor: const Color(0xFF3E3040),
  ),
];

/// A material with only the options a test turns on: no waves, no
/// micro-ripples, opaque, so that nothing else moves or blends.
WaterMaterial _plain({
  double time = 0,
  double foamLightTint = 1,
  double edgeFoamMotion = 1,
  double causticStrength = 0,
  WaterFoamSources? foamSources,
}) {
  return WaterMaterial(
    waveAmplitude: 0,
    rippleStrength: 0,
    foamThreshold: 1,
    opacity: 1,
    time: time,
    foamColor: const Color(0xFFFFFFFF),
    foamLightTint: foamLightTint,
    edgeFoamMotion: edgeFoamMotion,
    causticStrength: causticStrength,
    foamSources: foamSources,
  );
}

/// A wall in the plane z = 0 facing +z, from y = -1 to 1, x = -1.5 to 1.5,
/// crossing the level of the water volumes of the tests (y = 0).
Mesh _wall(Material material) {
  return Mesh()..addSurface(
    StylizedMaterial.buildSurface(
      positions: [
        for (var j = 0; j <= 16; j++)
          for (final x in [-1.5, 1.5]) ...[x, 1 - j / 8, 0.0],
      ],
      normals: [
        for (var i = 0; i < 34; i++) ...[0.0, 0.0, 1.0],
      ],
      colors: [
        for (var i = 0; i < 34; i++) ...[0.75, 0.72, 0.66, 1.0],
      ],
      indices: [
        for (var j = 0; j < 16; j++) ...[
          j * 2,
          j * 2 + 2,
          j * 2 + 3,
          j * 2,
          j * 2 + 3,
          j * 2 + 1,
        ],
      ],
      material: material,
    ),
  );
}

/// The front view of [_wall]: 128 pixels for 2.2 world units, the level
/// (y = 0) on row 64.
final Matrix4 _wallView = Matrix4.identity()
  ..setAsViewMatrix(Vector3(0, 0, 5), Vector3.zero(), Vector3(0, 1, 0));
final Matrix4 _wallProjection = Matrix4.identity()
  ..setAsOrthographic(2.2, 1, 0.1, 20);

void main() {
  setUpGpu();

  group('Foam controls', () {
    setUpAll(() async {
      if (gpuAvailable) {
        await registerTestShaders([
          'water_foam_reference',
          'stylized_volume_foam_reference',
        ]);
      }
    });

    testGpu(
      'are neutral by default: the pixels of before, exactly',
      (tester) async {
        // Every option of before on (caustics, sparkles, swell, depth ramp,
        // foam mask, ripples with foaming crests, waves, micro-ripples),
        // every light, shadows, fog; both vertex layouts, translucent and
        // opaque, +Y and +Z up, perspective, with and without MSAA. The new
        // material also holds an empty set of foam sources and one source
        // of strength 0, which draw nothing.
        for (final zUp in [false, true]) {
          Vector3 v(double x, double y, double z) =>
              zUp ? Vector3(z, x, y) : Vector3(x, y, z);
          for (final opacity in [0.8, 1.0]) {
            WaterMaterial water({required bool before}) {
              final ripples = WaterRipples()
                ..add(v(-0.4, 0, 0.3), time: 0.9, strength: 1.4)
                ..add(v(0.8, 0, -0.6), time: 0.5, radius: 0.3);
              final sources = WaterFoamSources();
              if (!before) {
                sources.addCircle(v(0.2, 0, 0.2), radius: 0.4, strength: 0);
              }
              final material = WaterMaterial(
                opacity: opacity,
                time: 1.3,
                rippleStrength: 0.2,
                upAxis: zUp ? Vector3(0, 0, 1) : null,
                causticStrength: 0.4,
                sparkleStrength: 1.5,
                detailStrength: 0.5,
                depthRange: 0.7,
                ripples: ripples,
                foamSources: before ? null : sources,
              );
              if (before) {
                _useFragmentOfBefore(material);
              }
              return material;
            }

            World3D scene(WaterMaterial material) => World3D(
              fog: FogSettings(start: 2, end: 14, up: v(0, 1, 0)),
              children: [
                LightComponent.directional(
                  direction: v(-0.4, -1, -0.3),
                  color: const Color(0xFFFFA060),
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
                // The water layout: deeper towards +x, foaming towards -x.
                MeshComponent(
                  mesh: _grid(
                    material,
                    v: v,
                    depth: (x, z) => 0.2 + 0.3 * (x + 2),
                    foam: (x, z) => x < -1.2 ? 1 : (x < -0.8 ? 0.5 : 0),
                  ),
                ),
                // The standard layout, beside it.
                MeshComponent(
                  mesh: TerrainMesh3D(
                    columns: 16,
                    rows: 16,
                    width: 2,
                    depth: 2,
                    heights: Float32List(16 * 16),
                    material: material,
                  ),
                  position: v(0, 0.05, 2.6),
                  rotation: zUp
                      ? Quaternion.fromRotation(
                          Matrix3.columns(
                            Vector3(0, 1, 0),
                            Vector3(0, 0, 1),
                            Vector3(1, 0, 0),
                          ),
                        )
                      : null,
                ),
              ],
            );

            final eye = v(1.2, 3.6, 3.4);
            final view = Matrix4.identity()
              ..setAsViewMatrix(eye, v(0, 0, 0.6), v(0, 1, 0));
            final projection = Matrix4.identity()
              ..setAsPerspective(55, 1, 0.5, 40);
            for (final msaa in [Msaa.off, Msaa.sample4]) {
              final where = 'zUp $zUp, opacity $opacity, $msaa';
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
              // The foam mask and the ripples' crests foam.
              expect(
                now.pixels.count((r, g, b, a) => r > 150 && g > 150 && b > 150),
                greaterThan(200),
                reason: where,
              );
              expect(
                differingPixels(now.pixels, before.pixels, tolerance: 0),
                0,
                reason: where,
              );
            }
          }
        }
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    testGpu('foamLightTint keeps the lit foam white under a colored light', (
      tester,
    ) async {
      Future<Pixels> render(double tint, {double foam = 1}) async {
        return (await _render(
          tester,
          World3D(
            children: [
              ..._duskLights(),
              MeshComponent(
                mesh: _grid(
                  _plain(time: 0.4, foamLightTint: tint),
                  foam: (x, z) => x < -0.5 ? foam : 0,
                ),
              ),
            ],
          ),
        )).pixels;
      }

      final warm = await render(1);
      final neutral = await render(0);
      final between = await render(0.5);
      final noFoam = await render(0, foam: 0);

      // The solid foam, left of x = -1.25: under the warm sun it is warm,
      // with a tint of 0 it is grey, about as bright.
      var warmDiff = 0.0;
      var neutralDiff = 0.0;
      var betweenDiff = 0.0;
      var warmBright = 0.0;
      var neutralBright = 0.0;
      var count = 0;
      final (x0, _) = _pixel(-1.25, 0);
      for (var y = 8; y < _size - 8; y += 3) {
        for (var x = 0; x < x0; x += 3) {
          final (r, g, b, _) = warm.at(x, y);
          final (nr, ng, nb, _) = neutral.at(x, y);
          final (br, _, bb, _) = between.at(x, y);
          if (nr + ng + nb < 440) {
            continue; // a hole in the foam, or its edge
          }
          warmDiff += r - b;
          neutralDiff += (nr - nb).abs() + (nr - ng).abs();
          betweenDiff += br - bb;
          warmBright += 0.2126 * r + 0.7152 * warm.at(x, y).$2 + 0.0722 * b;
          neutralBright += 0.2126 * nr + 0.7152 * ng + 0.0722 * nb;
          count++;
        }
      }
      expect(count, greaterThan(100));
      expect(warmDiff / count, greaterThan(40));
      expect(neutralDiff / count, lessThan(4));
      // Half of the tint, about half of the warmth.
      expect(betweenDiff / count, closeTo(warmDiff / count / 2, 12));
      expect(neutralBright / count, closeTo(warmBright / count, 25));

      // The water without foam is the same whatever the tint.
      final (x1, _) = _pixel(0, 0);
      for (var y = 0; y < _size; y++) {
        for (var x = x1; x < _size; x++) {
          expect(_same(warm, neutral, x, y), isTrue, reason: '$x, $y');
          expect(_same(neutral, noFoam, x, y), isTrue, reason: '$x, $y');
        }
      }
    });

    testGpu('foamLightFloor keeps the lit foam bright in low light', (
      tester,
    ) async {
      Future<Pixels> render(
        double floor, {
        bool dim = true,
        double foam = 1,
      }) async {
        final water = _plain(time: 0.4, foamLightTint: 0)
          ..foamLightFloor = floor;
        return (await _render(
          tester,
          World3D(
            children: [
              if (dim) ...[
                // Dusk: a low sun and a dark sky.
                LightComponent.directional(
                  direction: Vector3(0.5, -0.45, 0.3),
                  color: const Color(0xFFFF8A4C),
                  intensity: 0.2,
                ),
                LightComponent.hemisphere(
                  skyColor: const Color(0xFF6A6890),
                  groundColor: const Color(0xFF3E3040),
                  intensity: 0.3,
                ),
              ] else ...[
                LightComponent.directional(
                  direction: Vector3(0.3, -1, 0.2),
                  intensity: 1.2,
                ),
                LightComponent.hemisphere(intensity: 0.8),
              ],
              MeshComponent(
                mesh: _grid(water, foam: (x, z) => x < -0.5 ? foam : 0),
              ),
            ],
          ),
        )).pixels;
      }

      final half = await render(0.5);
      final bright = await render(0.85);
      final noFoam = await render(0.85, foam: 0);

      // The solid foam, left of x = -1.25: half its color by default,
      // 0.85 of it with the raised floor.
      var halfBright = 0.0;
      var raisedBright = 0.0;
      var count = 0;
      final (x0, _) = _pixel(-1.25, 0);
      for (var y = 8; y < _size - 8; y += 3) {
        for (var x = 0; x < x0; x += 3) {
          final (r, g, b, _) = bright.at(x, y);
          if (r + g + b < 3 * 190) {
            continue; // a hole in the foam, or its edge
          }
          final (hr, hg, hb, _) = half.at(x, y);
          halfBright += (hr + hg + hb) / 3;
          raisedBright += (r + g + b) / 3;
          count++;
        }
      }
      expect(count, greaterThan(100));
      // 0.5 and 0.85 of white (linear output): about 128 and 217.
      expect(halfBright / count, closeTo(128, 6));
      expect(raisedBright / count, closeTo(217, 6));

      // The water without foam is the same whatever the floor.
      final (x1, _) = _pixel(0, 0);
      for (var y = 0; y < _size; y++) {
        for (var x = x1; x < _size; x++) {
          expect(_same(half, bright, x, y), isTrue, reason: '$x, $y');
          expect(_same(bright, noFoam, x, y), isTrue, reason: '$x, $y');
        }
      }

      // In a light brighter than the floor, the floor changes nothing.
      expect(
        differingPixels(
          await render(0.5, dim: false),
          await render(0.85, dim: false),
          tolerance: 0,
        ),
        0,
      );
    });

    testGpu('edgeFoamMotion slows the mask foam down or holds it still', (
      tester,
    ) async {
      Future<Pixels> render(
        double time,
        double motion, {
        double caustics = 0,
      }) async {
        return (await _render(
          tester,
          World3D(
            children: [
              ..._duskLights(),
              MeshComponent(
                mesh: _grid(
                  _plain(
                    time: time,
                    edgeFoamMotion: motion,
                    causticStrength: caustics,
                  ),
                  foam: (x, z) => math.max(0, 1 - (x + 2) / 1.5),
                ),
              ),
            ],
          ),
        )).pixels;
      }

      // Today's pace: the band laps and drifts.
      final moving = differingPixels(
        await render(0.5, 1),
        await render(2.1, 1),
        tolerance: 0,
      );
      expect(moving, greaterThan(_size * 4));
      // Held still: the same pixels at any moment.
      final still = await render(0.5, 0);
      expect(differingPixels(still, await render(2.1, 0), tolerance: 0), 0);
      expect(differingPixels(still, await render(7.3, 0), tolerance: 0), 0);
      // At half the pace, the foam at a moment is the foam at half that
      // moment at its own pace.
      expect(
        differingPixels(
          await render(3, 0.5),
          await render(1.5, 1),
          tolerance: 0,
        ),
        0,
      );
      // The caustics keep moving while the foam stands still: away from the
      // band, the water changes.
      final a = await render(0.5, 0, caustics: 1);
      final b = await render(2.1, 0, caustics: 1);
      var changed = 0;
      final (x0, _) = _pixel(0, 0);
      for (var y = 0; y < _size; y++) {
        for (var x = x0; x < _size; x++) {
          if (!_same(a, b, x, y)) {
            changed++;
          }
        }
      }
      expect(changed, greaterThan(_size * 4));
    });

    testGpu(
      'foam sources draw collars where they are, and only there',
      (tester) async {
        final sources = WaterFoamSources();
        Future<Frame> render() => _render(
          tester,
          World3D(
            children: [
              ..._duskLights(),
              MeshComponent(
                mesh: _grid(_plain(time: 0.7, foamSources: sources)),
              ),
            ],
          ),
        );
        final plain = (await render()).pixels;
        // Foam: much brighter than the plain water.
        bool foam(Pixels p, double x, double z) {
          final (px, py) = _pixel(x, z);
          return _brightness(p, px, py) > _brightness(plain, px, py) + 100;
        }

        // A circle of radius 0.3 at (-1, 0, -1), its foam 0.3 wide.
        final circle = sources.addCircle(
          Vector3(-1, 0, -1),
          radius: 0.3,
        );
        // A rectangle 1.2 by 0.5 at (0.8, 0, 0.6), turned by 30° about up
        // (from +x towards -z), with rounded corners.
        final axis = Vector3(math.cos(math.pi / 6), 0, -math.sin(math.pi / 6));
        final rectangle = sources.addRectangle(
          Vector3(0.8, 0, 0.6),
          halfLength: 0.6,
          halfWidth: 0.25,
          cornerRadius: 0.1,
          axis: axis,
          width: 0.2,
        );
        final frame = await render();
        final collars = frame.pixels;
        expect(frame.stats.drawCalls, 1);

        // Against the circle's outline the foam is solid; it stops before
        // the width of its foam, and the water beyond is the plain water.
        var solid = 0;
        for (var k = 0; k < 16; k++) {
          final angle = k * math.pi / 8;
          final x = -1 + 0.31 * math.cos(angle);
          final z = -1 + 0.31 * math.sin(angle);
          if (foam(collars, x, z)) {
            solid++;
          }
        }
        // A few holes in the band.
        expect(solid, greaterThanOrEqualTo(10));
        // The rectangle: foam at the ends of its length, along its turned
        // axis; plain water at the same distance across it.
        var ends = 0;
        var across = 0;
        for (final s in [-1.0, 1.0]) {
          for (final t in [-0.15, 0.0, 0.15]) {
            final ex = 0.8 + s * 0.58 * axis.x - t * axis.z;
            final ez = 0.6 + s * 0.58 * axis.z + t * axis.x;
            if (foam(collars, ex, ez)) {
              ends++;
            }
            // 0.58 across the axis is 0.33 beyond the half width, outside
            // its foam (0.2 wide).
            final cx = 0.8 - s * 0.58 * axis.z + t * axis.x;
            final cz = 0.6 + s * 0.58 * axis.x + t * axis.z;
            final (px, py) = _pixel(cx, cz);
            if (!_same(collars, plain, px, py)) {
              across++;
            }
          }
        }
        expect(ends, greaterThanOrEqualTo(4));
        expect(across, 0);
        // Far from both, nothing changed: the whole right column strip and
        // the bottom-left quarter.
        for (var y = 0; y < _size; y++) {
          for (var x = 0; x < _size; x++) {
            final wx = (x + 0.5 - _size / 2) / _pixelsPerUnit;
            final wz = (y + 0.5 - _size / 2) / _pixelsPerUnit;
            final toCircle =
                math.sqrt((wx + 1) * (wx + 1) + (wz + 1) * (wz + 1)) - 0.3;
            final toRectangle =
                math.sqrt((wx - 0.8) * (wx - 0.8) + (wz - 0.6) * (wz - 0.6)) -
                0.6;
            // Beyond the widths of their foam (and the rectangle's rounded
            // corners), with a pixel to spare.
            if (toCircle > 0.32 && toRectangle > 0.26) {
              expect(_same(collars, plain, x, y), isTrue, reason: '$x, $y');
            }
          }
        }

        // Moved at run time: the foam follows, the old place is plain again.
        sources.move(circle, Vector3(-1, 0, 1));
        final moved = (await render()).pixels;
        var followed = 0;
        for (var k = 0; k < 16; k++) {
          final angle = k * math.pi / 8;
          if (foam(
            moved,
            -1 + 0.31 * math.cos(angle),
            1 + 0.31 * math.sin(angle),
          )) {
            followed++;
          }
        }
        expect(followed, greaterThanOrEqualTo(10));
        for (var y = 0; y < _size ~/ 4; y++) {
          for (var x = 0; x < _size ~/ 3; x++) {
            expect(_same(moved, plain, x, y), isTrue, reason: '$x, $y');
          }
        }

        // Strength 0, or removed: the plain water, exactly.
        sources
          ..setStrength(circle, 0)
          ..setStrength(rectangle, 0);
        expect(
          differingPixels((await render()).pixels, plain, tolerance: 0),
          0,
        );
        sources.clear();
        expect(
          differingPixels((await render()).pixels, plain, tolerance: 0),
          0,
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    testGpu(
      'the waterline keeps its pixels by default and its color with a tint '
      'of 0',
      (tester) async {
        StylizedMaterial material({required bool before}) {
          final material = StylizedMaterial(
            rimStrength: 0,
            specularStrength: 0.3,
          );
          if (before) {
            material.fragmentShader = FragmentShader.fromAsset(
              'test/stylized_volume_foam_reference.shaderbundle',
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

        final view = Matrix4.identity()
          ..setAsViewMatrix(Vector3(0, 0, 5), Vector3.zero(), Vector3(0, 1, 0));
        final projection = Matrix4.identity()
          ..setAsOrthographic(2.2, 1, 0.1, 20);
        Future<Pixels> render(
          StylizedMaterial material, {
          double tint = 1,
          Msaa msaa = Msaa.off,
        }) async {
          return (await _render(
            tester,
            World3D(
              waterVolume: WaterVolumeSettings(
                causticStrength: 0.8,
                waterlineWidth: 0.12,
                waterlineColor: const Color(0xFFFFFFFF),
                waterlineLightTint: tint,
                time: 0.6,
              ),
              children: [
                LightComponent.directional(
                  direction: Vector3(0.3, -0.5, -1),
                  color: const Color(0xFFFF8A4C),
                  intensity: 1.2,
                ),
                LightComponent.point(
                  position: Vector3(0.6, 0.3, 1),
                  color: const Color(0xFFFFB060),
                  intensity: 2,
                  range: 3,
                ),
                LightComponent.hemisphere(
                  skyColor: const Color(0xFF8F86C0),
                  groundColor: const Color(0xFF3E3040),
                ),
                MeshComponent(mesh: _wall(material)),
              ],
            ),
            view: view,
            projection: projection,
            msaa: msaa,
          )).pixels;
        }

        for (final msaa in [Msaa.off, Msaa.sample4]) {
          expect(
            differingPixels(
              await render(material(before: false), msaa: msaa),
              await render(material(before: true), msaa: msaa),
              tolerance: 0,
            ),
            0,
            reason: '$msaa',
          );
        }

        final warm = await render(material(before: false));
        final neutral = await render(material(before: false), tint: 0);
        // The band on the level's rows (y = 0 at row 64): warm by default,
        // grey with a tint of 0; above and below it, the same pixels.
        var warmFoam = 0;
        var greyFoam = 0;
        for (var y = 60; y <= 68; y++) {
          for (var x = 0; x < _size; x++) {
            final (r, g, b, _) = warm.at(x, y);
            final (nr, ng, nb, _) = neutral.at(x, y);
            if (r + g + b > 450 && r - b > 50) {
              warmFoam++;
            }
            if (nr + ng + nb > 400 && (nr - nb).abs() < 8) {
              greyFoam++;
            }
          }
        }
        expect(warmFoam, greaterThan(100));
        expect(greyFoam, greaterThan(100));
        for (final rows in [(0, 40), (88, _size)]) {
          for (var y = rows.$1; y < rows.$2; y++) {
            for (var x = 0; x < _size; x++) {
              expect(_same(warm, neutral, x, y), isTrue, reason: '$x, $y');
            }
          }
        }
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    testGpu('waterlineMotion slows the waterline down or holds it still', (
      tester,
    ) async {
      Future<Pixels> render(
        double time,
        double motion, {
        double caustics = 0.8,
      }) async {
        return (await _render(
          tester,
          World3D(
            waterVolume: WaterVolumeSettings(
              causticStrength: caustics,
              waterlineWidth: 0.12,
              waterlineColor: const Color(0xFFFFFFFF),
              waterlineMotion: motion,
              time: time,
            ),
            children: [
              LightComponent.directional(
                direction: Vector3(0.3, -0.5, -1),
                intensity: 1.2,
              ),
              LightComponent.hemisphere(),
              MeshComponent(mesh: _wall(StylizedMaterial(rimStrength: 0))),
            ],
          ),
          view: _wallView,
          projection: _wallProjection,
        )).pixels;
      }

      /// The pixels of [a] and [b] that differ in the rows [from] to [to].
      int differing(Pixels a, Pixels b, int from, int to) {
        var count = 0;
        for (var y = from; y < to; y++) {
          for (var x = 0; x < _size; x++) {
            if (!_same(a, b, x, y)) {
              count++;
            }
          }
        }
        return count;
      }

      // Above the level (rows 0 to 63) only the band draws: at its pace it
      // laps, held still it is the same at any moment.
      final laps = differing(await render(0.6, 1), await render(2.3, 1), 0, 64);
      expect(laps, greaterThan(_size * 2));
      final still = await render(0.6, 0);
      final later = await render(2.3, 0);
      expect(differing(still, later, 0, 64), 0);
      expect(differing(still, await render(5.9, 0), 0, 64), 0);
      // Below the band, the caustics keep moving.
      expect(differing(still, later, 96, _size), greaterThan(_size * 4));
      // At half the pace, the band at a moment is the band at half that
      // moment at its own pace.
      expect(
        differingPixels(
          await render(3, 0.5, caustics: 0),
          await render(1.5, 1, caustics: 0),
          tolerance: 0,
        ),
        0,
      );
    });

    testGpu('waterlineLightFloor keeps the waterline bright in low light', (
      tester,
    ) async {
      Future<Pixels> render(double floor, {double width = 0.12}) async {
        return (await _render(
          tester,
          World3D(
            waterVolume: WaterVolumeSettings(
              waterlineWidth: width,
              waterlineColor: const Color(0xFFFFFFFF),
              waterlineLightTint: 0,
              waterlineLightFloor: floor,
              time: 0.6,
            ),
            children: [
              // Dusk: a low sun and a dark sky.
              LightComponent.directional(
                direction: Vector3(0.3, -0.5, -1),
                color: const Color(0xFFFF8A4C),
                intensity: 0.25,
              ),
              LightComponent.hemisphere(
                skyColor: const Color(0xFF6A6890),
                groundColor: const Color(0xFF3E3040),
                intensity: 0.3,
              ),
              MeshComponent(mesh: _wall(StylizedMaterial(rimStrength: 0))),
            ],
          ),
          view: _wallView,
          projection: _wallProjection,
        )).pixels;
      }

      final dark = await render(0);
      final bright = await render(0.7);
      // The band, on the level's rows (y = 0 at row 64): the solid foam is
      // dim by default and 0.7 of white with the floor.
      var dimFoam = 0.0;
      var brightFoam = 0.0;
      var count = 0;
      for (var y = 60; y <= 68; y++) {
        for (var x = 0; x < _size; x++) {
          final (r, g, b, _) = bright.at(x, y);
          if (r + g + b < 3 * 165) {
            continue; // not solid foam
          }
          final (dr, dg, db, _) = dark.at(x, y);
          dimFoam += (dr + dg + db) / 3;
          brightFoam += (r + g + b) / 3;
          count++;
        }
      }
      expect(count, greaterThan(100));
      // 0.7 of white (linear output): about 178.
      expect(brightFoam / count, closeTo(178, 8));
      expect(dimFoam / count, lessThan(brightFoam / count - 40));
      // Away from the band, the same pixels.
      for (final rows in [(0, 52), (76, _size)]) {
        for (var y = rows.$1; y < rows.$2; y++) {
          for (var x = 0; x < _size; x++) {
            expect(_same(dark, bright, x, y), isTrue, reason: '$x, $y');
          }
        }
      }
      // Without a waterline, the floor changes nothing.
      expect(
        differingPixels(
          await render(0, width: 0),
          await render(0.7, width: 0),
          tolerance: 0,
        ),
        0,
      );
    });
  });
}
