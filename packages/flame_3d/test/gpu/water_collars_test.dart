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

// The collars of WaterFoamSources: the pixels no source reaches skip the
// sources (the vertices tell them), and the material then draws exactly the
// pixels of the fragment stage of before
// (test/gpu/shaders/reference/water_collars_fragment.glsl), whatever the
// size of the triangles; a source can carry its pattern along.

const _size = 128;

/// 32 pixels per world unit in the top views.
const _pixelsPerUnit = 32.0;

/// A grid of water in [WaterMaterial.vertexLayout] over x = -[half] to
/// [half] and z = -[half] to [half] (in a `+Y`-up world; [v] maps the
/// coordinates for other worlds), [cells] cells a side, deeper towards +x
/// and foaming towards -x, or, [plain], 1 deep everywhere without foam.
Mesh _grid(
  WaterMaterial material, {
  double half = 2,
  int cells = 32,
  bool plain = false,
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
      depths.add(plain ? 1 : 0.2 + 0.3 * (x + 2));
      foams.add(plain ? 0 : (x < -1.6 ? 1 : (x < -1.2 ? 0.5 : 0)));
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

/// One quad of water in the standard layout over the same square: two
/// triangles whose vertices are far from every source.
Mesh _quad(WaterMaterial material, {required bool zUp}) => TerrainMesh3D(
  columns: 2,
  rows: 2,
  width: 4,
  depth: 4,
  heights: Float32List(4),
  upAxis: zUp ? TerrainUpAxis.z : TerrainUpAxis.y,
  material: material,
);

/// A top-down orthographic view of the plane y = 0 (or z = 0), centered on
/// the origin.
Matrix4 _topView({required bool zUp}) => Matrix4.identity()
  ..setAsViewMatrix(
    zUp ? Vector3(0, 0, 10) : Vector3(0, 10, 0),
    Vector3.zero(),
    zUp ? Vector3(0, 1, 0) : Vector3(0, 0, -1),
  );

/// [_size] pixels for 4 world units.
final Matrix4 _topProjection = Matrix4.identity()
  ..setAsOrthographic(_size / _pixelsPerUnit, 1, 0.1, 30);

Future<Frame> _render(
  WidgetTester tester,
  World3D world, {
  required Matrix4 view,
  required Matrix4 projection,
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
      view: view,
      projection: projection,
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

/// Replaces the fragment stage of [material] by the one of before the
/// pixels no source reaches skipped the sources (both vertex stages are the
/// material's own).
void _useFragmentOfBefore(WaterMaterial material) {
  material.fragmentShader = FragmentShader.fromAsset(
    'test/water_collars_reference.shaderbundle',
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

/// Collars of every kind over the square of [_grid], in a world mapped by
/// [v]: circles, a point, rectangles turned or not, strong and faint, one
/// partly off the water, one in the middle of each triangle of [_quad].
WaterFoamSources _collars(Vector3 Function(double x, double y, double z) v) {
  final axis = v(math.cos(math.pi / 6), 0, -math.sin(math.pi / 6));
  return WaterFoamSources()
    ..addCircle(v(-1.1, 0, -0.9), radius: 0.3)
    ..addCircle(v(0.3, 0, -1.2), radius: 0, width: 0.12, strength: 1.3)
    ..addRectangle(
      v(0.8, 0, 0.6),
      halfLength: 0.6,
      halfWidth: 0.25,
      cornerRadius: 0.1,
      axis: axis,
      width: 0.2,
    )
    ..addRectangle(
      v(-0.6, 0, 1.0),
      halfLength: 0.4,
      halfWidth: 0.4,
      cornerRadius: 0.04,
      strength: 0.6,
    )
    // A hidden source, whose slot stays between the others.
    ..addCircle(v(0, 0, 0), radius: 0.5, strength: 0)
    ..addCircle(v(1.9, 0, -1.8), radius: 0.2, width: 0.25)
    ..addCircle(v(-0.7, 0, -0.1), radius: 0.15, width: 0.2)
    ..addCircle(v(0.7, 0, 0.1), radius: 0.1, width: 0.15, strength: 0.9);
}

void main() {
  setUpGpu();

  group('Water collars', () {
    setUpAll(() async {
      if (gpuAvailable) {
        await registerTestShaders(['water_collars_reference']);
      }
    });

    testGpu(
      'skip the pixels they do not reach: the pixels of before, exactly',
      (tester) async {
        for (final zUp in [false, true]) {
          Vector3 v(double x, double y, double z) =>
              zUp ? Vector3(x, -z, y) : Vector3(x, y, z);
          WaterMaterial water({required bool before}) {
            final material = WaterMaterial(
              opacity: 0.85,
              time: 1.3,
              rippleStrength: 0.2,
              upAxis: zUp ? Vector3(0, 0, 1) : null,
              causticStrength: 0.4,
              sparkleStrength: 1.5,
              detailStrength: 0.5,
              depthRange: 0.7,
              ripples: WaterRipples()
                ..add(v(-0.4, 0, 0.3), time: 0.9, strength: 1.4),
              foamSources: _collars(v),
            );
            if (before) {
              _useFragmentOfBefore(material);
            }
            return material;
          }

          for (final quad in [false, true]) {
            World3D scene(WaterMaterial material) => World3D(
              children: [
                LightComponent.directional(
                  direction: v(-0.4, -1, -0.3),
                  color: const Color(0xFFFFC890),
                  intensity: 1.1,
                ),
                LightComponent.point(
                  position: v(1, 1.2, 1),
                  color: const Color(0xFFFFB060),
                  intensity: 2,
                  range: 4,
                ),
                LightComponent.hemisphere(
                  up: v(0, 1, 0),
                  skyColor: const Color(0xFFA0C8FF),
                ),
                MeshComponent(
                  mesh: quad
                      ? _quad(material, zUp: zUp)
                      : _grid(material, v: v),
                ),
              ],
            );

            final eye = v(1.2, 3.6, 3.4);
            final views = [
              (_topView(zUp: zUp), _topProjection),
              (
                Matrix4.identity()
                  ..setAsViewMatrix(eye, v(0, 0, 0), v(0, 1, 0)),
                Matrix4.identity()..setAsPerspective(55, 1, 0.5, 40),
              ),
            ];
            for (final (view, projection) in views) {
              for (final msaa in [Msaa.off, Msaa.sample4]) {
                final where = 'zUp $zUp, quad $quad, $msaa, $view';
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
                // The collars foam.
                expect(
                  now.pixels.count(
                    (r, g, b, a) => r > 180 && g > 180 && b > 180,
                  ),
                  greaterThan(150),
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
        }
      },
      timeout: const Timeout(Duration(minutes: 4)),
    );

    testGpu(
      'carry their pattern along when asked, and leave it in the world '
      'otherwise',
      (tester) async {
        final sources = WaterFoamSources();
        final material = WaterMaterial(
          waveAmplitude: 0,
          rippleStrength: 0,
          foamThreshold: 1,
          opacity: 1,
          time: 0.7,
          foamColor: const Color(0xFFFFFFFF),
          foamSources: sources,
        );
        Future<Pixels> render() async => (await _render(
          tester,
          World3D(
            children: [
              LightComponent.directional(direction: Vector3(0.3, -1, 0.2)),
              LightComponent.hemisphere(),
              MeshComponent(mesh: _grid(material, plain: true)),
            ],
          ),
          view: _topView(zUp: false),
          projection: _topProjection,
        )).pixels;

        /// The pixels around the world point (x, z), within [radius] world
        /// units, of [a] that differ by more than 2 from those of [b] around
        /// (x + dx, z + dz), [b] read through [map] (a quarter turn, for
        /// one).
        int differing(
          Pixels a,
          Pixels b, {
          required double x,
          required double z,
          double dx = 0,
          double dz = 0,
          double radius = 0.62,
          (int, int) Function(int i, int j)? map,
        }) {
          final cx = (_size / 2 + x * _pixelsPerUnit).round();
          final cz = (_size / 2 + z * _pixelsPerUnit).round();
          final ox = (dx * _pixelsPerUnit).round();
          final oz = (dz * _pixelsPerUnit).round();
          final r = (radius * _pixelsPerUnit).round();
          var count = 0;
          for (var j = -r; j < r; j++) {
            for (var i = -r; i < r; i++) {
              final (bi, bj) = map?.call(i, j) ?? (i, j);
              final (ar, ag, ab, _) = a.at(cx + i, cz + j);
              final (br, bg, bb, _) = b.at(cx + ox + bi, cz + oz + bj);
              if ((ar - br).abs() > 2 ||
                  (ag - bg).abs() > 2 ||
                  (ab - bb).abs() > 2) {
                count++;
              }
            }
          }
          return count;
        }

        int foam(Pixels p, double x, double z) {
          final cx = (_size / 2 + x * _pixelsPerUnit).round();
          final cz = (_size / 2 + z * _pixelsPerUnit).round();
          var count = 0;
          for (var j = -20; j < 20; j++) {
            for (var i = -20; i < 20; i++) {
              final (r, g, b, _) = p.at(cx + i, cz + j);
              if (r > 200 && g > 200 && b > 200) {
                count++;
              }
            }
          }
          return count;
        }

        // A collar that carries its pattern, moved by one unit (32 pixels):
        // the same foam, one unit further.
        final slot = sources.addRectangle(
          Vector3(-0.75, 0, -0.5),
          halfLength: 0.3,
          halfWidth: 0.2,
          cornerRadius: 0.05,
          carryPattern: true,
        );
        final here = await render();
        expect(foam(here, -0.75, -0.5), greaterThan(150));
        sources.move(slot, Vector3(0.25, 0, -0.5));
        final there = await render();
        expect(
          differing(here, there, x: -0.75, z: -0.5, dx: 1),
          lessThan(12),
        );
        // Turned a quarter turn about up with it (+x to -z, so the pixel
        // i, j of before is at j, -i), the foam turns with it.
        sources.move(slot, Vector3(0.25, 0, -0.5), axis: Vector3(0, 0, -1));
        final turned = await render();
        expect(
          differing(
            there,
            turned,
            x: 0.25,
            z: -0.5,
            map: (i, j) => (j, -i - 1),
          ),
          lessThan(12),
        );

        // Left in the world, the collar moves through its pattern: its foam
        // changes as it moves.
        sources.setCarryPattern(slot, carry: false);
        sources.move(slot, Vector3(-0.75, 0, -0.5), axis: Vector3(1, 0, 0));
        final worldHere = await render();
        sources.move(slot, Vector3(0.25, 0, -0.5));
        final worldThere = await render();
        expect(
          differing(worldHere, worldThere, x: -0.75, z: -0.5, dx: 1),
          greaterThan(150),
        );

        // Two collars of one shape that carry their patterns, in two slots:
        // different foam.
        sources
          ..setRectangle(
            slot,
            Vector3(-0.75, 0, 0.75),
            halfLength: 0.3,
            halfWidth: 0.2,
            cornerRadius: 0.05,
            carryPattern: true,
          )
          ..addRectangle(
            Vector3(0.75, 0, 0.75),
            halfLength: 0.3,
            halfWidth: 0.2,
            cornerRadius: 0.05,
            carryPattern: true,
          );
        final pair = await render();
        expect(foam(pair, 0.75, 0.75), greaterThan(150));
        expect(
          differing(pair, pair, x: -0.75, z: 0.75, dx: 1.5),
          greaterThan(150),
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });
}
